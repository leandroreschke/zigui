const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const render = @import("../render/api.zig");
const resource = @import("../render/resource.zig");
const surface_resource = @import("../render/surface_resource.zig");
const api = @import("api.zig");

pub const Player = struct {
    source: api.Source,
    renderer: render.Renderer,
    resources: *resource.Manager,
    surfaces: *surface_resource.Manager,
    visual: ?api.Visual = null,
    state: api.State = .playing,
    anchor_host_ns: u64,
    anchor_media_ns: u64 = 0,
    paused_media_ns: u64 = 0,
    playback_rate: f64 = 1,

    pub fn init(
        source: api.Source,
        renderer: render.Renderer,
        resources: *resource.Manager,
        surfaces: *surface_resource.Manager,
        now_ns: u64,
    ) Player {
        return .{
            .source = source,
            .renderer = renderer,
            .resources = resources,
            .surfaces = surfaces,
            .anchor_host_ns = now_ns,
        };
    }

    pub fn deinit(self: *Player) void {
        self.destroyVisual() catch {};
        self.source.deinit();
        self.* = undefined;
    }

    pub fn tick(self: *Player, now_ns: u64) Error!bool {
        if (self.state != .playing) return false;
        const target = self.mediaTime(now_ns);
        return switch (try self.source.poll(target)) {
            .unchanged => false,
            .ended => blk: {
                self.state = .ended;
                self.paused_media_ns = target;
                break :blk false;
            },
            .frame => |frame| blk: {
                defer frame.release();
                try self.present(frame.content);
                break :blk true;
            },
        };
    }

    pub fn play(self: *Player, now_ns: u64) void {
        if (self.state == .playing) return;
        self.anchor_host_ns = now_ns;
        self.anchor_media_ns = self.paused_media_ns;
        self.state = .playing;
    }

    pub fn pause(self: *Player, now_ns: u64) void {
        if (self.state != .playing) return;
        self.paused_media_ns = self.mediaTime(now_ns);
        self.state = .paused;
    }

    pub fn seek(self: *Player, media_ns: u64, now_ns: u64) Error!void {
        try self.source.seek(media_ns);
        self.anchor_media_ns = media_ns;
        self.paused_media_ns = media_ns;
        self.anchor_host_ns = now_ns;
        if (self.state == .ended) self.state = .paused;
    }

    pub fn setRate(self: *Player, rate: f64, now_ns: u64) Error!void {
        if (!(rate > 0) or !@import("std").math.isFinite(rate) or rate > 16) return error.InvalidConfiguration;
        const current = if (self.state == .playing) self.mediaTime(now_ns) else self.paused_media_ns;
        self.playback_rate = rate;
        self.anchor_host_ns = now_ns;
        self.anchor_media_ns = current;
        self.paused_media_ns = current;
    }

    pub fn deviceLost(self: *Player, now_ns: u64) Error!void {
        const current_media = if (self.state == .playing) self.mediaTime(now_ns) else self.paused_media_ns;
        if (self.visual) |visual| switch (visual) {
            .surface => {
                try self.destroyVisual();
                try self.source.seek(current_media);
                switch (try self.source.poll(current_media)) {
                    .frame => |frame| {
                        defer frame.release();
                        try self.present(frame.content);
                    },
                    .unchanged, .ended => {},
                }
            },
            .texture => {},
        };
    }

    fn mediaTime(self: *const Player, now_ns: u64) u64 {
        const elapsed = now_ns -| self.anchor_host_ns;
        const scaled: f64 = @as(f64, @floatFromInt(elapsed)) * self.playback_rate;
        if (scaled >= @as(f64, @floatFromInt(@import("std").math.maxInt(u64) -| self.anchor_media_ns))) return @import("std").math.maxInt(u64);
        return self.anchor_media_ns + @as(u64, @intFromFloat(scaled));
    }

    fn present(self: *Player, content: api.Content) Error!void {
        switch (content) {
            .cpu => |frame| try self.presentCpu(frame),
            .native => |descriptor| try self.presentNative(descriptor),
        }
    }

    fn presentCpu(self: *Player, frame: api.CpuFrame) Error!void {
        if (frame.width == 0 or frame.height == 0) return error.InvalidMedia;
        const descriptor: render.TextureDescriptor = .{
            .width = frame.width,
            .height = frame.height,
            .format = frame.format,
            .usage = .sampled,
        };
        const expected = try descriptor.byteLength();
        const pixel_count = std.math.mul(usize, frame.width, frame.height) catch return error.BudgetExceeded;
        const bytes_per_pixel: usize = expected / pixel_count;
        const row_bytes = std.math.mul(usize, frame.width, bytes_per_pixel) catch return error.BudgetExceeded;
        const source_bytes = std.math.mul(usize, frame.stride, frame.height) catch return error.BudgetExceeded;
        if (frame.stride < row_bytes or frame.pixels.len < source_bytes)
            return error.InvalidMedia;
        if (self.visual) |visual| switch (visual) {
            .texture => |texture| if (texture.width == frame.width and texture.height == frame.height and texture.format == frame.format) {
                try self.resources.upload(self.renderer, texture.id, .{ .width = frame.width, .height = frame.height }, frame.pixels, frame.stride);
                return;
            },
            else => {},
        };
        var packed_pixels: ?[]u8 = null;
        defer if (packed_pixels) |value| self.resources.allocator.free(value);
        const source = if (frame.stride == row_bytes)
            frame.pixels[0..expected]
        else blk: {
            const value = try self.resources.allocator.alloc(u8, expected);
            packed_pixels = value;
            for (0..frame.height) |row|
                @memcpy(value[row * row_bytes ..][0..row_bytes], frame.pixels[row * frame.stride ..][0..row_bytes]);
            break :blk value;
        };
        const texture = try self.resources.createTexture(descriptor, source, true);
        errdefer self.resources.destroyTextureOnRenderer(self.renderer, texture) catch {};
        try self.resources.realize(self.renderer, texture);
        try self.destroyVisual();
        self.visual = .{ .texture = .{ .id = texture, .width = frame.width, .height = frame.height, .format = frame.format } };
    }

    fn presentNative(self: *Player, descriptor: render.ExternalSurfaceDescriptor) Error!void {
        if (self.visual) |visual| switch (visual) {
            .surface => |surface| {
                try self.surfaces.replace(surface.id, descriptor);
                self.visual = .{ .surface = .{
                    .id = surface.id,
                    .width = descriptor.width,
                    .height = descriptor.height,
                    .color_space = descriptor.color_space,
                } };
                return;
            },
            else => {},
        };
        const id = try self.surfaces.import(descriptor);
        errdefer self.surfaces.destroy(id) catch {};
        try self.destroyVisual();
        self.visual = .{ .surface = .{ .id = id, .width = descriptor.width, .height = descriptor.height, .color_space = descriptor.color_space } };
    }

    fn destroyVisual(self: *Player) Error!void {
        const visual = self.visual orelse return;
        switch (visual) {
            .texture => |value| try self.resources.destroyTextureOnRenderer(self.renderer, value.id),
            .surface => |value| try self.surfaces.destroy(value.id),
        }
        self.visual = null;
    }
};
