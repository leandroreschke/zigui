const std = @import("std");
const config = @import("../config.zig");
const Error = @import("../core/error.zig").Error;
const animation = @import("animation_api.zig");
const image = @import("image.zig");

// ImageIO is deliberately kept behind the selected macOS platform.  WebP is
// not a system codec on the other ZigUI targets; those targets report the
// typed Unsupported error from image.decode/animation.Decoder instead of
// silently selecting a different decoder.
const CFData = opaque {};
const CGImageSource = opaque {};
const CGImage = opaque {};
const CGColorSpace = opaque {};
const CGContext = opaque {};

extern "C" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, length: c_long) ?*CFData;
extern "C" fn CFRelease(value: ?*const anyopaque) void;
extern "C" fn CGImageSourceCreateWithData(data: *CFData, options: ?*const anyopaque) ?*CGImageSource;
extern "C" fn CGImageSourceGetCount(source: *CGImageSource) usize;
extern "C" fn CGImageSourceCreateImageAtIndex(source: *CGImageSource, index: usize, options: ?*const anyopaque) ?*CGImage;
extern "C" fn CGImageGetWidth(image: *CGImage) usize;
extern "C" fn CGImageGetHeight(image: *CGImage) usize;
extern "C" fn CGColorSpaceCreateDeviceRGB() ?*CGColorSpace;
extern "C" fn CGColorSpaceRelease(space: *CGColorSpace) void;
extern "C" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    color_space: *CGColorSpace,
    bitmap_info: u32,
) ?*CGContext;
extern "C" fn CGContextDrawImage(context: *CGContext, rect: CGRect, image: *CGImage) void;
extern "C" fn CGContextRelease(context: *CGContext) void;

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

const cg_alpha_premultiplied_last: u32 = 1;
const default_frame_duration_ns: u64 = 100 * std.time.ns_per_ms;

const FrameSpec = struct {
    duration_ns: u64,
};

const ParsedContainer = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    animated: bool,
    looping: animation.Looping,
    frames: []u64,

    fn deinit(self: *ParsedContainer) void {
        self.allocator.free(self.frames);
        self.* = undefined;
    }
};

const RenderedFrame = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

/// Returns true only for a complete RIFF/WebP container carrying an
/// animation marker.  It is intentionally a cheap classifier; Decoder.init
/// performs the complete structural and ImageIO validation before decoding.
pub fn isAnimated(bytes: []const u8) bool {
    if (!isWebp(bytes) or bytes.len < 20) return false;
    const riff_size = readU32(bytes, 4) orelse return false;
    const end = std.math.add(usize, 8, @as(usize, riff_size)) catch return false;
    if (end != bytes.len or end < 12) return false;

    var cursor: usize = 12;
    while (cursor < end) {
        if (end - cursor < 8) return false;
        const size = readU32(bytes, cursor + 4) orelse return false;
        const padded = std.math.add(usize, @as(usize, size), @as(usize, size & 1)) catch return false;
        const chunk_end = std.math.add(usize, cursor + 8, padded) catch return false;
        if (chunk_end > end) return false;
        if (size & 1 != 0 and bytes[cursor + 8 + size] != 0) return false;
        const kind = bytes[cursor .. cursor + 4];
        const payload = bytes[cursor + 8 .. cursor + 8 + size];
        if (std.mem.eql(u8, kind, "VP8X")) {
            if (payload.len < 10) return false;
            if (payload[0] & 0x02 != 0) return true;
        } else if (std.mem.eql(u8, kind, "ANIM") or std.mem.eql(u8, kind, "ANMF")) {
            return true;
        }
        cursor = chunk_end;
    }
    return false;
}

pub fn isWebp(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP");
}

/// Decode the first ImageIO frame into ZigUI's owned RGBA8 image contract.
/// Animated WebP is accepted here just like animated GIF/APNG: callers that
/// need playback should use animation.Decoder instead.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    if (config.compiled_platform != .macos) return error.Unsupported;
    var decoder = try Decoder.init(allocator, bytes, limits);
    defer decoder.deinit();
    _ = try decoder.next() orelse return error.InvalidImage;
    const pixels = decoder.takeCurrentPixels() orelse return error.InvalidImage;
    return .{
        .width = decoder.width,
        .height = decoder.height,
        .stride = @as(usize, decoder.width) * 4,
        .pixels = pixels,
        .color_space = .srgb,
    };
}

/// Bounded ImageIO-backed WebP frame source.  The source and all decoded
/// pixels are owned by this value; no Objective-C object escapes the public
/// ZigUI animation contract.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    data: *CFData,
    source: *CGImageSource,
    limits: image.Limits,
    width: u32,
    height: u32,
    frames: []u64,
    looping: animation.Looping,
    next_index: usize = 0,
    current_pixels: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!Decoder {
        if (config.compiled_platform != .macos) return error.Unsupported;
        var parsed = try parseContainer(allocator, bytes, limits);
        errdefer parsed.deinit();
        const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.InvalidImage;
        errdefer CFRelease(data);
        const source = CGImageSourceCreateWithData(data, null) orelse return error.InvalidImage;
        errdefer CFRelease(source);
        const count = CGImageSourceGetCount(source);
        if (count == 0 or count != (if (parsed.animated) parsed.frames.len else 1)) return error.InvalidImage;
        const frames = parsed.frames;
        parsed.frames = &.{};
        const result: Decoder = .{
            .allocator = allocator,
            .data = data,
            .source = source,
            .limits = limits,
            .width = parsed.width,
            .height = parsed.height,
            .frames = frames,
            .looping = parsed.looping,
        };
        parsed.deinit();
        return result;
    }

    pub fn deinit(self: *Decoder) void {
        if (self.current_pixels) |pixels| self.allocator.free(pixels);
        self.allocator.free(self.frames);
        CFRelease(self.source);
        CFRelease(self.data);
        self.* = undefined;
    }

    pub fn reset(self: *Decoder) void {
        if (self.current_pixels) |pixels| self.allocator.free(pixels);
        self.current_pixels = null;
        self.next_index = 0;
    }

    pub fn next(self: *Decoder) Error!?animation.Frame {
        if (self.next_index >= (if (self.frames.len == 0) 1 else self.frames.len)) return null;
        const index = self.next_index;
        var rendered = try renderFrame(self.allocator, self.source, index, self.limits);
        errdefer self.allocator.free(rendered.pixels);
        if (rendered.width != self.width or rendered.height != self.height) return error.InvalidImage;
        if (self.current_pixels) |pixels| self.allocator.free(pixels);
        self.current_pixels = rendered.pixels;
        rendered.pixels = &.{};
        self.next_index += 1;
        return .{
            .pixels = self.current_pixels.?,
            .width = self.width,
            .height = self.height,
            .stride = @as(usize, self.width) * 4,
            .duration_ns = if (self.frames.len == 0) default_frame_duration_ns else self.frames[index],
            .index = index,
        };
    }

    pub fn loopingValue(self: *const Decoder) animation.Looping {
        return self.looping;
    }

    pub fn isAnimatedValue(self: *const Decoder) bool {
        return self.frames.len > 0;
    }

    pub fn takeCurrentPixels(self: *Decoder) ?[]u8 {
        const pixels = self.current_pixels orelse return null;
        self.current_pixels = null;
        return pixels;
    }
};

fn parseContainer(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!ParsedContainer {
    if (config.compiled_platform != .macos) return error.Unsupported;
    if (!isWebp(bytes) or bytes.len > limits.maximum_compressed_bytes) {
        return if (bytes.len > limits.maximum_compressed_bytes) error.BudgetExceeded else error.InvalidImage;
    }
    const riff_size = readU32(bytes, 4) orelse return error.InvalidImage;
    const end = std.math.add(usize, 8, @as(usize, riff_size)) catch return error.BudgetExceeded;
    if (end != bytes.len or end < 12) return error.InvalidImage;

    var width: ?u32 = null;
    var height: ?u32 = null;
    var saw_vp8x = false;
    var animation_flag = false;
    var saw_anim = false;
    var saw_image = false;
    var frame_specs: std.ArrayList(FrameSpec) = .empty;
    defer frame_specs.deinit(allocator);
    var loop_count: u16 = 1;
    var cursor: usize = 12;
    while (cursor < end) {
        if (end - cursor < 8) return error.InvalidImage;
        const size = readU32(bytes, cursor + 4) orelse return error.InvalidImage;
        const padded = std.math.add(usize, @as(usize, size), @as(usize, size & 1)) catch return error.BudgetExceeded;
        const chunk_end = std.math.add(usize, cursor + 8, padded) catch return error.BudgetExceeded;
        if (chunk_end > end) return error.InvalidImage;
        if (size & 1 != 0 and bytes[cursor + 8 + size] != 0) return error.InvalidImage;
        const kind = bytes[cursor .. cursor + 4];
        const payload = bytes[cursor + 8 .. cursor + 8 + size];
        if (std.mem.eql(u8, kind, "VP8X")) {
            if (saw_vp8x or payload.len != 10) return error.InvalidImage;
            saw_vp8x = true;
            animation_flag = payload[0] & 0x02 != 0;
            width = std.math.add(u32, read24(payload[4..7]), 1) catch return error.InvalidImage;
            height = std.math.add(u32, read24(payload[7..10]), 1) catch return error.InvalidImage;
        } else if (std.mem.eql(u8, kind, "VP8 ")) {
            if (saw_image or payload.len < 10) return error.InvalidImage;
            const image_width = readU16(payload, 6) orelse return error.InvalidImage;
            const image_height = readU16(payload, 8) orelse return error.InvalidImage;
            if (payload[3] != 0x9d or payload[4] != 0x01 or payload[5] != 0x2a or
                image_width & 0x3fff == 0 or image_height & 0x3fff == 0)
                return error.InvalidImage;
            if (width == null) width = image_width & 0x3fff;
            if (height == null) height = image_height & 0x3fff;
            saw_image = true;
        } else if (std.mem.eql(u8, kind, "VP8L")) {
            if (saw_image or payload.len < 5 or payload[0] != 0x2f) return error.InvalidImage;
            const bits: u32 = @as(u32, payload[1]) |
                (@as(u32, payload[2]) << 8) |
                (@as(u32, payload[3]) << 16) |
                (@as(u32, payload[4]) << 24);
            if ((bits >> 28) & 0x07 != 0) return error.InvalidImage;
            if (width == null) width = (bits & 0x3fff) + 1;
            if (height == null) height = ((bits >> 14) & 0x3fff) + 1;
            saw_image = true;
        } else if (std.mem.eql(u8, kind, "ANIM")) {
            if (saw_anim or payload.len != 6) return error.InvalidImage;
            saw_anim = true;
            loop_count = readU16(payload, 4) orelse return error.InvalidImage;
        } else if (std.mem.eql(u8, kind, "ANMF")) {
            if (!saw_vp8x or payload.len < 16 or frame_specs.items.len >= limits.maximum_animation_frames)
                return if (frame_specs.items.len >= limits.maximum_animation_frames) error.BudgetExceeded else error.InvalidImage;
            const canvas_width = width orelse return error.InvalidImage;
            const canvas_height = height orelse return error.InvalidImage;
            const frame_x = std.math.mul(u32, read24(payload[0..3]), 2) catch return error.InvalidImage;
            const frame_y = std.math.mul(u32, read24(payload[3..6]), 2) catch return error.InvalidImage;
            const frame_width = std.math.add(u32, read24(payload[6..9]), 1) catch return error.InvalidImage;
            const frame_height = std.math.add(u32, read24(payload[9..12]), 1) catch return error.InvalidImage;
            if (frame_x > canvas_width or frame_y > canvas_height or frame_width > canvas_width - frame_x or
                frame_height > canvas_height - frame_y or payload[15] & 0xfc != 0)
                return error.InvalidImage;
            const milliseconds = read24(payload[12..15]);
            try frame_specs.append(allocator, .{ .duration_ns = @max(@as(u64, milliseconds) * std.time.ns_per_ms, std.time.ns_per_ms) });
        }
        cursor = chunk_end;
    }

    const final_width = width orelse return error.InvalidImage;
    const final_height = height orelse return error.InvalidImage;
    _ = try image.validateDimensions(final_width, final_height, limits);
    const animated = animation_flag or saw_anim or frame_specs.items.len != 0;
    if (animated) {
        if (!saw_vp8x or !animation_flag or !saw_anim or frame_specs.items.len == 0 or saw_image)
            return error.InvalidImage;
    } else if (saw_vp8x and animation_flag) {
        return error.InvalidImage;
    } else if (!saw_image) {
        return error.InvalidImage;
    }
    if (animated) {
        const canvas_pixels = try image.validateDimensions(final_width, final_height, limits);
        const canvas_bytes = std.math.mul(usize, canvas_pixels, 4) catch return error.BudgetExceeded;
        if (canvas_bytes > limits.maximum_animation_canvas_bytes) return error.BudgetExceeded;
    }

    const frames = if (animated) blk: {
        const result = try allocator.alloc(u64, frame_specs.items.len);
        errdefer allocator.free(result);
        for (frame_specs.items, 0..) |frame, index| result[index] = frame.duration_ns;
        break :blk result;
    } else try allocator.alloc(u64, 0);
    return .{
        .allocator = allocator,
        .width = final_width,
        .height = final_height,
        .animated = animated,
        .looping = if (!animated) .once else if (loop_count == 0) .infinite else .{ .repetitions = @as(u32, loop_count) - 1 },
        .frames = frames,
    };
}

fn renderFrame(
    allocator: std.mem.Allocator,
    source: *CGImageSource,
    index: usize,
    limits: image.Limits,
) Error!RenderedFrame {
    const image_value = CGImageSourceCreateImageAtIndex(source, index, null) orelse return error.InvalidImage;
    defer CFRelease(image_value);
    const width = CGImageGetWidth(image_value);
    const height = CGImageGetHeight(image_value);
    if (width == 0 or height == 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return error.InvalidImage;
    _ = try image.validateDimensions(@intCast(width), @intCast(height), limits);
    const stride = std.math.mul(usize, width, 4) catch return error.BudgetExceeded;
    const bytes = std.math.mul(usize, stride, height) catch return error.BudgetExceeded;
    const pixels = try allocator.alloc(u8, bytes);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    const color_space = CGColorSpaceCreateDeviceRGB() orelse return error.InvalidImage;
    defer CGColorSpaceRelease(color_space);
    const context = CGBitmapContextCreate(pixels.ptr, width, height, 8, stride, color_space, cg_alpha_premultiplied_last) orelse
        return error.InvalidImage;
    defer CGContextRelease(context);
    CGContextDrawImage(context, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    }, image_value);
    return .{ .pixels = pixels, .width = @intCast(width), .height = @intCast(height) };
}

fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn read24(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
}
