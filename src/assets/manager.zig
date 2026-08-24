const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const render = @import("../render/api.zig");
const resource = @import("../render/resource.zig");
const animation = @import("animation.zig");
const image = @import("image.zig");

const Entry = struct {
    texture: handles.TextureId,
    width: u32,
    height: u32,
    references: usize = 1,
    last_used_frame: u64 = 0,
};

const AnimatedEntry = struct {
    player: animation.Player,
    texture: handles.TextureId,
    references: usize = 1,
};

const ImageKey = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const Manager = struct {
    const AnimationPool = handles.SlotPool(AnimatedEntry, handles.AnimationId);

    allocator: std.mem.Allocator,
    renderer: render.Renderer,
    resources: *resource.Manager,
    entries: std.AutoHashMap(ImageKey, Entry),
    animations: AnimationPool,
    limits: image.Limits,
    frame: u64 = 0,
    maximum_images: usize,
    maximum_animations: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        renderer: render.Renderer,
        resources: *resource.Manager,
        limits: image.Limits,
    ) Manager {
        return initWithLimits(allocator, renderer, resources, limits, 65_536, 4_096);
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        renderer: render.Renderer,
        resources: *resource.Manager,
        limits: image.Limits,
        maximum_images: usize,
        maximum_animations: usize,
    ) Manager {
        return .{
            .allocator = allocator,
            .renderer = renderer,
            .resources = resources,
            .entries = std.AutoHashMap(ImageKey, Entry).init(allocator),
            .animations = AnimationPool.init(allocator),
            .limits = limits,
            .maximum_images = maximum_images,
            .maximum_animations = maximum_animations,
        };
    }

    pub fn deinit(self: *Manager) void {
        var animation_iterator = self.animations.iterator();
        while (animation_iterator.next()) |entry| {
            self.resources.destroyTextureOnRenderer(self.renderer, entry.value.texture) catch {};
            entry.value.player.deinit();
        }
        self.animations.deinit();
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| self.resources.destroyTextureOnRenderer(self.renderer, entry.value_ptr.texture) catch {};
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn loadAnimation(self: *Manager, bytes: []const u8, now_ns: u64) Error!handles.AnimationId {
        if (self.animations.live_count >= self.maximum_animations) return error.BudgetExceeded;
        var player = try animation.Player.init(self.allocator, bytes, self.limits, now_ns);
        errdefer player.deinit();
        const frame = player.frame() orelse return error.InvalidImage;
        const texture = try self.resources.createTexture(.{
            .width = frame.width,
            .height = frame.height,
            .format = .rgba8_srgb,
            .usage = .sampled,
        }, frame.pixels, true);
        errdefer self.resources.destroyTextureOnRenderer(self.renderer, texture) catch {};
        try self.resources.realize(self.renderer, texture);
        return self.animations.insert(.{ .player = player, .texture = texture });
    }

    pub fn retainAnimation(self: *Manager, id: handles.AnimationId) Error!void {
        const entry = self.animations.get(id) orelse return error.InvalidHandle;
        if (entry.references == std.math.maxInt(usize)) return error.BudgetExceeded;
        entry.references += 1;
    }

    pub fn releaseAnimation(self: *Manager, id: handles.AnimationId) Error!void {
        const entry = self.animations.get(id) orelse return error.InvalidHandle;
        if (entry.references > 1) {
            entry.references -= 1;
            return;
        }
        const entry_value = self.animations.get(id) orelse return error.InvalidHandle;
        try self.resources.destroyTextureOnRenderer(self.renderer, entry_value.texture);
        var removed = self.animations.remove(id) orelse return error.InvalidHandle;
        removed.player.deinit();
    }

    pub fn animationTexture(self: *const Manager, id: handles.AnimationId) ?handles.TextureId {
        const entry = self.animations.getConst(id) orelse return null;
        return entry.texture;
    }

    pub fn animationFrame(self: *const Manager, id: handles.AnimationId) ?animation.Frame {
        const entry = self.animations.getConst(id) orelse return null;
        return entry.player.frame();
    }

    pub fn playAnimation(self: *Manager, id: handles.AnimationId, now_ns: u64) Error!void {
        const entry = self.animations.get(id) orelse return error.InvalidHandle;
        try entry.player.play(now_ns);
    }

    pub fn pauseAnimation(self: *Manager, id: handles.AnimationId) Error!void {
        const entry = self.animations.get(id) orelse return error.InvalidHandle;
        entry.player.pause();
    }

    pub fn restartAnimation(self: *Manager, id: handles.AnimationId, now_ns: u64) Error!void {
        const entry = self.animations.get(id) orelse return error.InvalidHandle;
        try entry.player.restart(now_ns);
        try self.uploadAnimation(entry);
    }

    pub fn advanceAnimation(self: *Manager, id: handles.AnimationId, now_ns: u64) Error!bool {
        const entry = self.animations.get(id) orelse return error.InvalidHandle;
        if (!try entry.player.advance(now_ns)) return false;
        try self.uploadAnimation(entry);
        return true;
    }

    pub fn advanceTexture(self: *Manager, texture: handles.TextureId, now_ns: u64) Error!bool {
        var iterator = self.animations.iterator();
        while (iterator.next()) |entry| if (entry.value.texture.eql(texture)) {
            if (!try entry.value.player.advance(now_ns)) return false;
            try self.uploadAnimation(entry.value);
            return true;
        };
        return false;
    }

    pub fn isPlayingTexture(self: *Manager, texture: handles.TextureId) bool {
        var iterator = self.animations.iterator();
        while (iterator.next()) |entry| if (entry.value.texture.eql(texture)) return entry.value.player.isPlaying();
        return false;
    }

    fn uploadAnimation(self: *Manager, entry: *AnimatedEntry) Error!void {
        const frame = entry.player.frame() orelse return error.InvalidImage;
        try self.resources.upload(self.renderer, entry.texture, .{
            .width = frame.width,
            .height = frame.height,
        }, frame.pixels, frame.stride);
    }

    pub fn beginFrame(self: *Manager, frame: u64) void {
        self.frame = frame;
        self.resources.collect(self.renderer.completedEpoch());
    }

    pub fn load(self: *Manager, bytes: []const u8) Error!handles.TextureId {
        var key: ImageKey = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &key, .{});
        if (self.entries.getPtr(key)) |existing| {
            if (existing.references == std.math.maxInt(usize)) return error.BudgetExceeded;
            existing.references += 1;
            existing.last_used_frame = self.frame;
            return existing.texture;
        }
        if (self.entries.count() >= self.maximum_images) return error.BudgetExceeded;
        var decoded = try image.decode(self.allocator, bytes, self.limits);
        defer decoded.deinit(self.allocator);
        const texture = try self.resources.createTexture(.{
            .width = decoded.width,
            .height = decoded.height,
            .format = .rgba8_srgb,
            .usage = .sampled,
        }, decoded.pixels, true);
        errdefer self.resources.destroyTextureOnRenderer(self.renderer, texture) catch {};
        try self.resources.realize(self.renderer, texture);
        try self.entries.put(key, .{
            .texture = texture,
            .width = decoded.width,
            .height = decoded.height,
            .last_used_frame = self.frame,
        });
        return texture;
    }

    pub fn retain(self: *Manager, texture: handles.TextureId) Error!void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.texture.eql(texture)) {
            if (entry.value_ptr.references == std.math.maxInt(usize)) return error.BudgetExceeded;
            entry.value_ptr.references += 1;
            return;
        };
        return error.InvalidHandle;
    }

    pub fn release(self: *Manager, texture: handles.TextureId) Error!void {
        var remove_key: ?ImageKey = null;
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.texture.eql(texture)) continue;
            if (entry.value_ptr.references > 1) {
                entry.value_ptr.references -= 1;
                return;
            }
            remove_key = entry.key_ptr.*;
            break;
        }
        const key = remove_key orelse return error.InvalidHandle;
        const entry = self.entries.get(key) orelse return error.InvalidHandle;
        try self.resources.destroyTextureOnRenderer(self.renderer, entry.texture);
        _ = self.entries.remove(key);
    }

    pub fn dimensions(self: *const Manager, texture: handles.TextureId) ?struct { width: u32, height: u32 } {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.texture.eql(texture)) return .{
            .width = entry.value_ptr.width,
            .height = entry.value_ptr.height,
        };
        return null;
    }
};
