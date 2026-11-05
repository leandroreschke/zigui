const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const metrics = @import("../core/metrics.zig");
const api = @import("api.zig");

pub const TextureDescriptor = api.TextureDescriptor;

pub const Texture = struct {
    descriptor: TextureDescriptor,
    device_generation: api.DeviceGeneration,
    resident: bool = false,
    last_submission: api.SubmissionEpoch = 0,
    cpu_copy: ?[]u8 = null,
    cpu_allocator: ?std.mem.Allocator = null,
    byte_length: usize,
};

const RetiredTexture = struct {
    resource: Texture,
    release_after: api.SubmissionEpoch,
};

pub const Manager = struct {
    const Pool = handles.SlotPool(Texture, handles.TextureId);

    allocator: std.mem.Allocator,
    textures: Pool,
    retired: std.ArrayList(RetiredTexture) = .empty,
    device_generation: api.DeviceGeneration = 1,
    gpu_budget: usize,
    cpu_budget: usize,
    gpu_reserved: usize = 0,
    cpu_reserved: usize = 0,
    counters: ?*metrics.Counters = null,
    maximum_textures: usize,

    pub fn init(allocator: std.mem.Allocator, gpu_budget: usize, cpu_budget: usize) Manager {
        return initWithLimit(allocator, gpu_budget, cpu_budget, 262_144);
    }

    pub fn initWithLimit(
        allocator: std.mem.Allocator,
        gpu_budget: usize,
        cpu_budget: usize,
        maximum_textures: usize,
    ) Manager {
        return .{
            .allocator = allocator,
            .textures = Pool.init(allocator),
            .gpu_budget = gpu_budget,
            .cpu_budget = cpu_budget,
            .maximum_textures = maximum_textures,
        };
    }

    pub fn deinit(self: *Manager) void {
        var iterator = self.textures.iterator();
        while (iterator.next()) |entry| releaseTexture(self.allocator, entry.value.*);
        for (self.retired.items) |entry| releaseTexture(self.allocator, entry.resource);
        self.textures.deinit();
        self.retired.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn bindCounters(self: *Manager, counters: *metrics.Counters) void {
        self.counters = counters;
    }

    pub fn createTexture(
        self: *Manager,
        descriptor: TextureDescriptor,
        source: ?[]const u8,
        retain_cpu_copy: bool,
    ) Error!handles.TextureId {
        if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
        if (self.textures.live_count +| self.retired.items.len >= self.maximum_textures) return error.BudgetExceeded;
        const byte_length = try descriptor.byteLength();
        if (byte_length > self.gpu_budget -| self.gpu_reserved) return error.BudgetExceeded;
        var cpu_copy: ?[]u8 = null;
        errdefer if (cpu_copy) |copy| self.allocator.free(copy);
        if (retain_cpu_copy) {
            const pixels = source orelse return error.InvalidConfiguration;
            if (pixels.len != byte_length) return error.InvalidConfiguration;
            if (byte_length > self.cpu_budget -| self.cpu_reserved) return error.BudgetExceeded;
            cpu_copy = try self.allocator.dupe(u8, pixels);
        }
        const id = try self.textures.insert(.{
            .descriptor = descriptor,
            .device_generation = self.device_generation,
            .cpu_copy = cpu_copy,
            .byte_length = byte_length,
        });
        self.gpu_reserved += byte_length;
        if (cpu_copy != null) self.cpu_reserved += byte_length;
        return id;
    }

    /// Takes ownership only on success. The original allocator follows the
    /// pixels through retirement and device recovery.
    pub fn createTextureOwned(self: *Manager, descriptor: TextureDescriptor, pixels: []u8, pixel_allocator: std.mem.Allocator) Error!handles.TextureId {
        if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
        const byte_length = try descriptor.byteLength();
        if (pixels.len != byte_length) return error.InvalidConfiguration;
        if (self.textures.live_count +| self.retired.items.len >= self.maximum_textures or
            byte_length > self.gpu_budget -| self.gpu_reserved or
            byte_length > self.cpu_budget -| self.cpu_reserved) return error.BudgetExceeded;
        const id = try self.textures.insert(.{
            .descriptor = descriptor,
            .device_generation = self.device_generation,
            .cpu_copy = pixels,
            .cpu_allocator = pixel_allocator,
            .byte_length = byte_length,
        });
        self.gpu_reserved += byte_length;
        self.cpu_reserved += byte_length;
        return id;
    }

    pub fn get(self: *Manager, id: handles.TextureId) ?*Texture {
        return self.textures.get(id);
    }

    pub fn getConst(self: *const Manager, id: handles.TextureId) ?*const Texture {
        return self.textures.getConst(id);
    }

    pub fn setResident(self: *Manager, id: handles.TextureId, backend_handle: u64) Error!void {
        _ = backend_handle;
        const texture = self.textures.get(id) orelse return error.InvalidHandle;
        texture.device_generation = self.device_generation;
        texture.resident = true;
    }

    pub fn realize(self: *Manager, renderer: api.Renderer, id: handles.TextureId) Error!void {
        const texture = self.textures.get(id) orelse return error.InvalidHandle;
        if (texture.resident and texture.device_generation == self.device_generation) return;
        try renderer.createTexture(id, texture.descriptor);
        errdefer renderer.destroyTexture(id, renderer.completedEpoch()) catch {};
        if (texture.cpu_copy) |pixels| {
            const stride = @as(usize, texture.descriptor.width) * bytesPerPixel(texture.descriptor.format);
            try renderer.writeTexture(id, .{
                .width = texture.descriptor.width,
                .height = texture.descriptor.height,
            }, pixels, stride);
        }
        texture.resident = true;
        texture.device_generation = self.device_generation;
        if (self.counters) |counters| counters.gpu_resources_created +|= 1;
    }

    pub fn upload(
        self: *Manager,
        renderer: api.Renderer,
        id: handles.TextureId,
        region: api.TextureRegion,
        pixels: []const u8,
        stride: usize,
    ) Error!void {
        const texture = self.textures.get(id) orelse return error.InvalidHandle;
        const bpp = bytesPerPixel(texture.descriptor.format);
        const row_bytes = std.math.mul(usize, region.width, bpp) catch return error.BudgetExceeded;
        if (region.x > texture.descriptor.width or region.width > texture.descriptor.width - region.x or
            region.y > texture.descriptor.height or region.height > texture.descriptor.height - region.y or
            stride < row_bytes) return error.InvalidConfiguration;
        const source_bytes = std.math.mul(usize, stride, region.height) catch return error.BudgetExceeded;
        if (pixels.len < source_bytes) return error.InvalidConfiguration;
        if (!texture.resident or texture.device_generation != self.device_generation) try self.realize(renderer, id);
        try renderer.writeTexture(id, region, pixels, stride);
        if (self.counters) |counters| counters.upload_bytes +|= source_bytes;
        if (texture.cpu_copy) |copy| {
            const destination_stride = @as(usize, texture.descriptor.width) * bpp;
            for (0..region.height) |row| {
                const source_start = row * stride;
                const destination_start = (@as(usize, region.y) + row) * destination_stride + @as(usize, region.x) * bpp;
                @memcpy(copy[destination_start..][0..row_bytes], pixels[source_start..][0..row_bytes]);
            }
        }
    }

    pub fn markUsed(self: *Manager, id: handles.TextureId, submission: api.SubmissionEpoch) Error!void {
        const texture = self.textures.get(id) orelse return error.InvalidHandle;
        if (texture.device_generation != self.device_generation) return error.DeviceLost;
        texture.last_submission = @max(texture.last_submission, submission);
    }

    pub fn destroyTexture(self: *Manager, id: handles.TextureId) Error!void {
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        const texture = self.textures.remove(id) orelse return error.InvalidHandle;
        self.retired.appendAssumeCapacity(.{
            .resource = texture,
            .release_after = texture.last_submission,
        });
    }

    pub fn destroyTextureOnRenderer(self: *Manager, renderer: api.Renderer, id: handles.TextureId) Error!void {
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        const texture = self.textures.getConst(id) orelse return error.InvalidHandle;
        try renderer.destroyTexture(id, texture.last_submission);
        try self.destroyTexture(id);
    }

    pub fn collect(self: *Manager, completed: api.SubmissionEpoch) void {
        var write: usize = 0;
        for (self.retired.items) |entry| {
            if (entry.release_after <= completed) {
                self.gpu_reserved -|= entry.resource.byte_length;
                if (entry.resource.cpu_copy != null) self.cpu_reserved -|= entry.resource.byte_length;
                releaseTexture(self.allocator, entry.resource);
            } else {
                self.retired.items[write] = entry;
                write += 1;
            }
        }
        self.retired.items.len = write;
    }

    pub fn deviceLost(self: *Manager) void {
        self.device_generation +%= 1;
        if (self.device_generation == 0) self.device_generation = 1;
        var iterator = self.textures.iterator();
        while (iterator.next()) |entry| {
            entry.value.device_generation = self.device_generation;
            entry.value.resident = false;
            entry.value.last_submission = 0;
        }
        for (self.retired.items) |*entry| entry.release_after = 0;
    }

    pub fn recordAtlasEviction(self: *Manager) void {
        if (self.counters) |counters| counters.atlas_evictions +|= 1;
    }

    pub const Stats = struct {
        live_textures: usize,
        retired_textures: usize,
        gpu_reserved: usize,
        gpu_budget: usize,
        cpu_reserved: usize,
        cpu_budget: usize,
        device_generation: api.DeviceGeneration,
    };

    pub fn stats(self: *const Manager) Stats {
        return .{
            .live_textures = self.textures.live_count,
            .retired_textures = self.retired.items.len,
            .gpu_reserved = self.gpu_reserved,
            .gpu_budget = self.gpu_budget,
            .cpu_reserved = self.cpu_reserved,
            .cpu_budget = self.cpu_budget,
            .device_generation = self.device_generation,
        };
    }
};

fn releaseTexture(allocator: std.mem.Allocator, texture: Texture) void {
    if (texture.cpu_copy) |copy| (texture.cpu_allocator orelse allocator).free(copy);
}

fn bytesPerPixel(format: api.PixelFormat) usize {
    return switch (format) {
        .a8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba16_float => 8,
    };
}
