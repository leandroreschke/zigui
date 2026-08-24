const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const render = @import("api.zig");

pub const Surface = struct {
    width: u32,
    height: u32,
    format: render.PixelFormat,
    color_space: render.ColorSpace,
    device_generation: render.DeviceGeneration,
    last_submission: render.SubmissionEpoch = 0,
    resident: bool = true,
};

/// Tracks application/media-owned native images without taking ownership away
/// from their provider. The selected renderer retains each imported native
/// image and releases it only after its last GPU submission completes.
pub const Manager = struct {
    const Pool = handles.SlotPool(Surface, handles.SurfaceId);

    allocator: std.mem.Allocator,
    renderer: render.Renderer,
    surfaces: Pool,
    maximum_surfaces: usize,

    pub fn init(allocator: std.mem.Allocator, renderer: render.Renderer) Manager {
        return initWithLimit(allocator, renderer, 16_384);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, renderer: render.Renderer, maximum_surfaces: usize) Manager {
        return .{
            .allocator = allocator,
            .renderer = renderer,
            .surfaces = Pool.init(allocator),
            .maximum_surfaces = maximum_surfaces,
        };
    }

    pub fn deinit(self: *Manager) void {
        var iterator = self.surfaces.iterator();
        while (iterator.next()) |entry| {
            self.renderer.destroyExternalSurface(entry.id, entry.value.last_submission) catch {};
        }
        self.surfaces.deinit();
        self.* = undefined;
    }

    pub fn import(self: *Manager, descriptor: render.ExternalSurfaceDescriptor) Error!handles.SurfaceId {
        try validate(descriptor);
        if (self.surfaces.live_count >= self.maximum_surfaces) return error.BudgetExceeded;
        const id = try self.surfaces.insert(.{
            .width = descriptor.width,
            .height = descriptor.height,
            .format = descriptor.format,
            .color_space = descriptor.color_space,
            .device_generation = self.renderer.deviceGeneration(),
        });
        errdefer _ = self.surfaces.remove(id);
        try self.renderer.importExternalSurface(id, descriptor);
        return id;
    }

    pub fn replace(self: *Manager, id: handles.SurfaceId, descriptor: render.ExternalSurfaceDescriptor) Error!void {
        try validate(descriptor);
        const surface = self.surfaces.get(id) orelse return error.InvalidHandle;
        if (!surface.resident or surface.device_generation != self.renderer.deviceGeneration()) {
            try self.renderer.importExternalSurface(id, descriptor);
        } else {
            try self.renderer.replaceExternalSurface(id, descriptor, surface.last_submission);
        }
        surface.* = .{
            .width = descriptor.width,
            .height = descriptor.height,
            .format = descriptor.format,
            .color_space = descriptor.color_space,
            .device_generation = self.renderer.deviceGeneration(),
            .resident = true,
        };
    }

    pub fn markUsed(self: *Manager, id: handles.SurfaceId, submission: render.SubmissionEpoch) Error!void {
        const surface = self.surfaces.get(id) orelse return error.InvalidHandle;
        if (!surface.resident or surface.device_generation != self.renderer.deviceGeneration()) return error.DeviceLost;
        surface.last_submission = @max(surface.last_submission, submission);
    }

    pub fn validateUse(self: *const Manager, id: handles.SurfaceId) Error!void {
        const surface = self.surfaces.getConst(id) orelse return error.InvalidHandle;
        if (!surface.resident or surface.device_generation != self.renderer.deviceGeneration()) return error.DeviceLost;
    }

    pub fn destroy(self: *Manager, id: handles.SurfaceId) Error!void {
        const surface = self.surfaces.getConst(id) orelse return error.InvalidHandle;
        if (surface.resident) try self.renderer.destroyExternalSurface(id, surface.last_submission);
        _ = self.surfaces.remove(id) orelse return error.InvalidHandle;
    }

    pub fn get(self: *const Manager, id: handles.SurfaceId) ?Surface {
        const surface = self.surfaces.getConst(id) orelse return null;
        return surface.*;
    }

    pub fn deviceLost(self: *Manager) void {
        var iterator = self.surfaces.iterator();
        while (iterator.next()) |entry| {
            entry.value.resident = false;
            entry.value.last_submission = 0;
        }
    }
};

fn validate(descriptor: render.ExternalSurfaceDescriptor) Error!void {
    if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
}
