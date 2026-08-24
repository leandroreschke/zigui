const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const render = @import("../render/api.zig");

pub const Timestamp = u64;

pub const Info = struct {
    width: u32,
    height: u32,
    duration_ns: ?u64 = null,
    frame_rate_numerator: u32 = 0,
    frame_rate_denominator: u32 = 1,
    seekable: bool = false,
};

pub const CpuFrame = struct {
    width: u32,
    height: u32,
    stride: usize,
    format: render.PixelFormat,
    pixels: []const u8,
};

pub const Content = union(enum) {
    cpu: CpuFrame,
    native: render.ExternalSurfaceDescriptor,
};

/// A borrowed decoded frame. `release` is called exactly once after ZigUI has
/// copied the CPU bytes or retained the native image through the renderer.
pub const Frame = struct {
    presentation_time_ns: Timestamp,
    duration_ns: u64,
    content: Content,
    release_context: ?*anyopaque = null,
    release_fn: ?*const fn (*anyopaque) void = null,

    pub fn release(self: Frame) void {
        if (self.release_fn) |callback| if (self.release_context) |context| callback(context);
    }
};

pub const Poll = union(enum) {
    unchanged,
    frame: Frame,
    ended,
};

/// Nonblocking media source contract. `poll` returns the newest frame whose
/// presentation time is at or before the requested media time and may skip
/// older frames internally. Decoding on a worker is source-owned; callbacks
/// into application state are never made from that worker.
pub const Source = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        info: *const fn (*anyopaque) Info,
        poll: *const fn (*anyopaque, Timestamp) Error!Poll,
        seek: *const fn (*anyopaque, Timestamp) Error!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn info(self: Source) Error!Info {
        const result = self.vtable.info(self.context);
        try validateInfo(result);
        return result;
    }

    pub fn poll(self: Source, target: Timestamp) Error!Poll {
        const result = try self.vtable.poll(self.context, target);
        switch (result) {
            .frame => |frame| validateFrame(frame, target) catch |err| {
                frame.release();
                return err;
            },
            .unchanged, .ended => {},
        }
        return result;
    }
    pub fn seek(self: Source, target: Timestamp) Error!void {
        try self.vtable.seek(self.context, target);
    }
    pub fn deinit(self: Source) void {
        self.vtable.deinit(self.context);
    }
};

pub const Visual = union(enum) {
    texture: struct {
        id: handles.TextureId,
        width: u32,
        height: u32,
        format: render.PixelFormat,
    },
    surface: struct {
        id: handles.SurfaceId,
        width: u32,
        height: u32,
        color_space: render.ColorSpace,
    },

    pub fn width(self: Visual) u32 {
        return switch (self) {
            .texture => |value| value.width,
            .surface => |value| value.width,
        };
    }

    pub fn height(self: Visual) u32 {
        return switch (self) {
            .texture => |value| value.height,
            .surface => |value| value.height,
        };
    }
};

pub fn validateVisual(value: Visual) Error!void {
    switch (value) {
        .texture => |texture| {
            if (!texture.id.isValid()) return error.InvalidHandle;
            if (texture.width == 0 or texture.height == 0) return error.InvalidMedia;
        },
        .surface => |surface| {
            if (!surface.id.isValid()) return error.InvalidHandle;
            if (surface.width == 0 or surface.height == 0) return error.InvalidMedia;
        },
    }
}

pub const State = enum { playing, paused, ended };

pub const Services = struct {
    create_context: *anyopaque,
    create_fn: *const fn (*anyopaque, Source, Timestamp) Error!handles.MediaId,
};

comptime {
    _ = std;
}

fn validateInfo(value: Info) Error!void {
    if (value.width == 0 or value.height == 0 or value.frame_rate_denominator == 0)
        return error.InvalidMedia;
    if (value.duration_ns) |duration| if (duration == 0) return error.InvalidMedia;
}

fn validateFrame(frame: Frame, target: Timestamp) Error!void {
    if ((frame.release_context == null) != (frame.release_fn == null) or frame.duration_ns == 0 or
        frame.presentation_time_ns > target) return error.InvalidMedia;
    switch (frame.content) {
        .cpu => |value| {
            const descriptor: render.TextureDescriptor = .{
                .width = value.width,
                .height = value.height,
                .format = value.format,
                .usage = .sampled,
            };
            const expected = try descriptor.byteLength();
            const row_bytes = std.math.mul(usize, value.width, bytesPerPixel(value.format)) catch
                return error.BudgetExceeded;
            if (value.stride < row_bytes) return error.InvalidMedia;
            const required = std.math.mul(usize, value.stride, value.height) catch return error.BudgetExceeded;
            if (value.pixels.len < required or expected == 0) return error.InvalidMedia;
        },
        .native => |value| render.validateExternalSurfaceDescriptor(value) catch |err| switch (err) {
            error.BudgetExceeded, error.OutOfMemory => return err,
            else => return error.InvalidMedia,
        },
    }
}

fn bytesPerPixel(format: render.PixelFormat) usize {
    return switch (format) {
        .a8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba16_float => 8,
    };
}
