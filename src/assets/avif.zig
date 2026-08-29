const std = @import("std");
const config = @import("../config.zig");
const Error = @import("../core/error.zig").Error;
const image = @import("image.zig");

const CFData = opaque {};
const CGImageSource = opaque {};
const CGImage = opaque {};
const CGColorSpace = opaque {};
const CGContext = opaque {};

extern "C" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, length: c_long) ?*CFData;
extern "C" fn CFRelease(value: ?*const anyopaque) void;
extern "C" fn CGImageSourceCreateWithData(data: *CFData, options: ?*const anyopaque) ?*CGImageSource;
extern "C" fn CGImageSourceCreateImageAtIndex(source: *CGImageSource, index: usize, options: ?*const anyopaque) ?*CGImage;
extern "C" fn CGImageGetWidth(value: *CGImage) usize;
extern "C" fn CGImageGetHeight(value: *CGImage) usize;
extern "C" fn CGColorSpaceCreateDeviceRGB() ?*CGColorSpace;
extern "C" fn CGColorSpaceRelease(value: *CGColorSpace) void;
extern "C" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    color_space: *CGColorSpace,
    bitmap_info: u32,
) ?*CGContext;
extern "C" fn CGContextDrawImage(context: *CGContext, rect: CGRect, value: *CGImage) void;
extern "C" fn CGContextRelease(value: *CGContext) void;

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const cg_alpha_premultiplied_last: u32 = 1;

pub fn isAvif(bytes: []const u8) bool {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[4..8], "ftyp")) return false;
    const box_size = std.mem.readInt(u32, bytes[0..4], .big);
    if (box_size < 16 or box_size > bytes.len or box_size & 3 != 0) return false;
    if (isAvifBrand(bytes[8..12])) return true;
    var offset: usize = 16;
    while (offset + 4 <= box_size) : (offset += 4) {
        if (isAvifBrand(bytes[offset..][0..4])) return true;
    }
    return false;
}

fn isAvifBrand(brand: []const u8) bool {
    return std.mem.eql(u8, brand, "avif") or std.mem.eql(u8, brand, "avis");
}

/// Decode a still AVIF through the selected macOS ImageIO provider. Other
/// platforms keep the explicit Unsupported contract rather than selecting a
/// hidden application codec or CPU fallback.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    if (config.compiled_platform != .macos) return error.Unsupported;
    if (!isAvif(bytes)) return error.InvalidImage;
    if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;

    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.InvalidImage;
    defer CFRelease(data);
    const source = CGImageSourceCreateWithData(data, null) orelse return error.InvalidImage;
    defer CFRelease(source);
    const source_image = CGImageSourceCreateImageAtIndex(source, 0, null) orelse return error.InvalidImage;
    defer CFRelease(source_image);

    const width = CGImageGetWidth(source_image);
    const height = CGImageGetHeight(source_image);
    if (width == 0 or height == 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return error.InvalidImage;
    _ = try image.validateDimensions(@intCast(width), @intCast(height), limits);
    const stride = std.math.mul(usize, width, 4) catch return error.BudgetExceeded;
    const byte_count = std.math.mul(usize, stride, height) catch return error.BudgetExceeded;
    const pixels = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    const color_space = CGColorSpaceCreateDeviceRGB() orelse return error.InvalidImage;
    defer CGColorSpaceRelease(color_space);
    const context = CGBitmapContextCreate(pixels.ptr, width, height, 8, stride, color_space, cg_alpha_premultiplied_last) orelse return error.InvalidImage;
    defer CGContextRelease(context);
    CGContextDrawImage(context, .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    }, source_image);
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .stride = stride,
        .pixels = pixels,
        .color_space = .srgb,
    };
}

test "AVIF classifier requires an avif or avis ftyp brand" {
    try std.testing.expect(isAvif("\x00\x00\x00\x20ftypavif\x00\x00\x00\x00MiPravifmiafmif1"));
    try std.testing.expect(isAvif("\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00miafavis"));
    try std.testing.expect(!isAvif("\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00miafmif1"));
    try std.testing.expect(!isAvif("\x00\x00\x01\x00ftypavif\x00\x00\x00\x00"));
    try std.testing.expect(!isAvif("not an image"));
}

test "AVIF decode stays an explicit platform capability" {
    if (config.compiled_platform == .macos) return error.SkipZigTest;
    try std.testing.expectError(error.Unsupported, decode(
        std.testing.allocator,
        "\x00\x00\x00\x10ftypavif\x00\x00\x00\x00",
        .{},
    ));
}
