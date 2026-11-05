const std = @import("std");
const config = @import("../config.zig");
const Error = @import("../core/error.zig").Error;

pub const PixelFormat = enum { rgba8 };
pub const ColorSpace = enum { srgb, linear_srgb, display_p3, rec2020, unknown };

pub const Chromaticities = struct {
    white: [2]f64,
    red: [2]f64,
    green: [2]f64,
    blue: [2]f64,
};

pub const Orientation = enum(u8) {
    normal = 1,
    mirror_horizontal = 2,
    rotate_180 = 3,
    mirror_vertical = 4,
    transpose = 5,
    rotate_90_clockwise = 6,
    transverse = 7,
    rotate_90_counterclockwise = 8,
};

pub const Image = struct {
    width: u32,
    height: u32,
    stride: usize,
    pixels: []u8,
    format: PixelFormat = .rgba8,
    color_space: ColorSpace = .srgb,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

/// Quartz bitmap contexts expose premultiplied RGBA. ZigUI texture sampling
/// accepts straight RGBA and applies alpha exactly once in the shader.
pub fn unpremultiplyRgba8(pixels: []u8, width: usize, height: usize, stride: usize) void {
    if (stride == 0) return;
    if (width > stride / 4 or height > pixels.len / stride) return;
    for (0..height) |y| for (0..width) |x| {
        const offset = y * stride + x * 4;
        const alpha: u16 = pixels[offset + 3];
        if (alpha == 0) {
            @memset(pixels[offset..][0..3], 0);
        } else if (alpha != 255) {
            inline for (0..3) |channel| {
                const premultiplied: u16 = pixels[offset + channel];
                pixels[offset + channel] = @intCast(@min(@as(u16, 255), (premultiplied * 255 + alpha / 2) / alpha));
            }
        }
    };
}

test "premultiplied native pixels are normalized to straight RGBA" {
    var pixels = [_]u8{ 64, 32, 16, 128, 9, 8, 7, 0, 12, 34, 56, 255 };
    unpremultiplyRgba8(&pixels, 3, 1, pixels.len);
    try std.testing.expectEqualSlices(u8, &.{ 128, 64, 32, 128, 0, 0, 0, 0, 12, 34, 56, 255 }, &pixels);
}

/// Normalizes encoded orientation into top-left row-major pixels. Rendering
/// and hit testing therefore never need format-specific orientation branches.
pub fn applyOrientation(
    allocator: std.mem.Allocator,
    value: *Image,
    orientation: Orientation,
    maximum_working_bytes: usize,
) Error!void {
    try validateImage(value.*);
    if (orientation == .normal) return;
    const swaps_axes = switch (orientation) {
        .transpose, .rotate_90_clockwise, .transverse, .rotate_90_counterclockwise => true,
        else => false,
    };
    const destination_width = if (swaps_axes) value.height else value.width;
    const destination_height = if (swaps_axes) value.width else value.height;
    const length = std.math.mul(usize, std.math.mul(usize, destination_width, destination_height) catch return error.BudgetExceeded, 4) catch return error.BudgetExceeded;
    if (value.pixels.len > maximum_working_bytes -| length) return error.BudgetExceeded;
    const transformed = try allocator.alloc(u8, length);
    errdefer allocator.free(transformed);
    for (0..destination_height) |destination_y| for (0..destination_width) |destination_x| {
        const source: struct { x: usize, y: usize } = switch (orientation) {
            .normal => unreachable,
            .mirror_horizontal => .{ .x = value.width - 1 - destination_x, .y = destination_y },
            .rotate_180 => .{ .x = value.width - 1 - destination_x, .y = value.height - 1 - destination_y },
            .mirror_vertical => .{ .x = destination_x, .y = value.height - 1 - destination_y },
            .transpose => .{ .x = destination_y, .y = destination_x },
            .rotate_90_clockwise => .{ .x = destination_y, .y = value.height - 1 - destination_x },
            .transverse => .{ .x = value.width - 1 - destination_y, .y = value.height - 1 - destination_x },
            .rotate_90_counterclockwise => .{ .x = value.width - 1 - destination_y, .y = destination_x },
        };
        const source_offset = source.y * value.stride + source.x * 4;
        const destination_offset = (destination_y * destination_width + destination_x) * 4;
        @memcpy(transformed[destination_offset..][0..4], value.pixels[source_offset..][0..4]);
    };
    allocator.free(value.pixels);
    value.pixels = transformed;
    value.width = destination_width;
    value.height = destination_height;
    value.stride = @as(usize, destination_width) * 4;
}

pub fn convertToSrgb(value: *Image) void {
    if (value.color_space == .srgb or value.color_space == .unknown) return;
    convertPixelsToSrgb(value.pixels, value.color_space);
    value.color_space = .srgb;
}

pub fn convertPixelsToSrgb(pixels: []u8, source: ColorSpace) void {
    if (source == .srgb or source == .unknown) return;
    var offset: usize = 0;
    while (offset + 4 <= pixels.len) : (offset += 4) {
        var red = @as(f32, @floatFromInt(pixels[offset])) / 255;
        var green = @as(f32, @floatFromInt(pixels[offset + 1])) / 255;
        var blue = @as(f32, @floatFromInt(pixels[offset + 2])) / 255;
        switch (source) {
            .linear_srgb => {},
            .display_p3 => {
                red = inverseSrgb(red);
                green = inverseSrgb(green);
                blue = inverseSrgb(blue);
                const source_red = red;
                const source_green = green;
                const source_blue = blue;
                red = 1.224745 * source_red - 0.224904 * source_green - 0.000001 * source_blue;
                green = -0.042058 * source_red + 1.042081 * source_green - 0.000079 * source_blue;
                blue = -0.019642 * source_red - 0.078655 * source_green + 1.098537 * source_blue;
            },
            .rec2020 => {
                red = inverseBt2020(red);
                green = inverseBt2020(green);
                blue = inverseBt2020(blue);
                const source_red = red;
                const source_green = green;
                const source_blue = blue;
                red = 1.660491 * source_red - 0.587641 * source_green - 0.072850 * source_blue;
                green = -0.124550 * source_red + 1.132900 * source_green - 0.008349 * source_blue;
                blue = -0.018151 * source_red - 0.100579 * source_green + 1.118730 * source_blue;
            },
            .srgb, .unknown => unreachable,
        }
        pixels[offset] = encodeSrgb(red);
        pixels[offset + 1] = encodeSrgb(green);
        pixels[offset + 2] = encodeSrgb(blue);
    }
}

/// Converts PNG-style encoded RGB samples to sRGB using the file gamma and,
/// when supplied, its cHRM primaries/white point. The Bradford adaptation and
/// matrices are evaluated once; the pixel loop remains allocation-free.
pub fn convertGammaPrimariesToSrgb(
    pixels: []u8,
    image_gamma: f64,
    chromaticities: ?Chromaticities,
) Error!void {
    if (pixels.len % 4 != 0) return error.InvalidImage;
    if (!(image_gamma > 0.01 and image_gamma < 10) or !std.math.isFinite(image_gamma)) return error.InvalidImage;
    const source_to_xyz = if (chromaticities) |value| try rgbToXyz(value) else identity3();
    const adaptation = if (chromaticities) |value| try bradfordAdaptation(try xyToXyz(value.white), .{ 0.95047, 1.0, 1.08883 }) else identity3();
    const xyz_to_srgb: [3][3]f64 = .{
        .{ 3.2404542, -1.5371385, -0.4985314 },
        .{ -0.9692660, 1.8760108, 0.0415560 },
        .{ 0.0556434, -0.2040259, 1.0572252 },
    };
    const color_matrix = if (chromaticities != null)
        matrixMul(xyz_to_srgb, matrixMul(adaptation, source_to_xyz))
    else
        identity3();
    if (!finiteMatrix(color_matrix)) return error.InvalidImage;
    var offset: usize = 0;
    while (offset + 4 <= pixels.len) : (offset += 4) {
        const linear_source: [3]f64 = .{
            std.math.pow(f64, @as(f64, @floatFromInt(pixels[offset])) / 255, 1.0 / image_gamma),
            std.math.pow(f64, @as(f64, @floatFromInt(pixels[offset + 1])) / 255, 1.0 / image_gamma),
            std.math.pow(f64, @as(f64, @floatFromInt(pixels[offset + 2])) / 255, 1.0 / image_gamma),
        };
        const linear_srgb = matrixVector(color_matrix, linear_source);
        pixels[offset] = encodeSrgb(@floatCast(linear_srgb[0]));
        pixels[offset + 1] = encodeSrgb(@floatCast(linear_srgb[1]));
        pixels[offset + 2] = encodeSrgb(@floatCast(linear_srgb[2]));
    }
}

fn rgbToXyz(value: Chromaticities) Error![3][3]f64 {
    const red = try xyToXyz(value.red);
    const green = try xyToXyz(value.green);
    const blue = try xyToXyz(value.blue);
    const primaries: [3][3]f64 = .{
        .{ red[0], green[0], blue[0] },
        .{ red[1], green[1], blue[1] },
        .{ red[2], green[2], blue[2] },
    };
    const scales = matrixVector(try inverse3(primaries), try xyToXyz(value.white));
    var result = primaries;
    for (0..3) |row| {
        for (0..3) |column| result[row][column] *= scales[column];
    }
    return result;
}

fn xyToXyz(value: [2]f64) Error![3]f64 {
    const x = value[0];
    const y = value[1];
    if (!(x > 0 and y > 0 and x < 1 and y < 1 and x + y <= 1) or !std.math.isFinite(x) or !std.math.isFinite(y))
        return error.InvalidImage;
    const result: [3]f64 = .{ x / y, 1, (1 - x - y) / y };
    for (result) |component| if (!std.math.isFinite(component)) return error.InvalidImage;
    return result;
}

fn bradfordAdaptation(source_white: [3]f64, destination_white: [3]f64) Error![3][3]f64 {
    const bradford: [3][3]f64 = .{
        .{ 0.8951, 0.2664, -0.1614 },
        .{ -0.7502, 1.7135, 0.0367 },
        .{ 0.0389, -0.0685, 1.0296 },
    };
    const inverse_bradford: [3][3]f64 = .{
        .{ 0.9869929, -0.1470543, 0.1599627 },
        .{ 0.4323053, 0.5183603, 0.0492912 },
        .{ -0.0085287, 0.0400428, 0.9684867 },
    };
    const source_cone = matrixVector(bradford, source_white);
    const destination_cone = matrixVector(bradford, destination_white);
    var scale = identity3();
    for (0..3) |index| {
        if (@abs(source_cone[index]) < 1e-12) return error.InvalidImage;
        scale[index][index] = destination_cone[index] / source_cone[index];
    }
    return matrixMul(inverse_bradford, matrixMul(scale, bradford));
}

fn inverse3(value: [3][3]f64) Error![3][3]f64 {
    const determinant = value[0][0] * (value[1][1] * value[2][2] - value[1][2] * value[2][1]) -
        value[0][1] * (value[1][0] * value[2][2] - value[1][2] * value[2][0]) +
        value[0][2] * (value[1][0] * value[2][1] - value[1][1] * value[2][0]);
    if (!std.math.isFinite(determinant) or @abs(determinant) < 1e-12) return error.InvalidImage;
    const inverse = 1.0 / determinant;
    return .{
        .{ (value[1][1] * value[2][2] - value[1][2] * value[2][1]) * inverse, (value[0][2] * value[2][1] - value[0][1] * value[2][2]) * inverse, (value[0][1] * value[1][2] - value[0][2] * value[1][1]) * inverse },
        .{ (value[1][2] * value[2][0] - value[1][0] * value[2][2]) * inverse, (value[0][0] * value[2][2] - value[0][2] * value[2][0]) * inverse, (value[0][2] * value[1][0] - value[0][0] * value[1][2]) * inverse },
        .{ (value[1][0] * value[2][1] - value[1][1] * value[2][0]) * inverse, (value[0][1] * value[2][0] - value[0][0] * value[2][1]) * inverse, (value[0][0] * value[1][1] - value[0][1] * value[1][0]) * inverse },
    };
}

fn matrixMul(a: [3][3]f64, b: [3][3]f64) [3][3]f64 {
    var result: [3][3]f64 = undefined;
    for (0..3) |row| for (0..3) |column| {
        result[row][column] = 0;
        for (0..3) |inner| result[row][column] += a[row][inner] * b[inner][column];
    };
    return result;
}

fn matrixVector(matrix: [3][3]f64, value: [3]f64) [3]f64 {
    return .{
        matrix[0][0] * value[0] + matrix[0][1] * value[1] + matrix[0][2] * value[2],
        matrix[1][0] * value[0] + matrix[1][1] * value[1] + matrix[1][2] * value[2],
        matrix[2][0] * value[0] + matrix[2][1] * value[1] + matrix[2][2] * value[2],
    };
}

fn identity3() [3][3]f64 {
    return .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
}

fn finiteMatrix(value: [3][3]f64) bool {
    for (value) |row| for (row) |component| if (!std.math.isFinite(component)) return false;
    return true;
}

fn inverseSrgb(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn inverseBt2020(value: f32) f32 {
    return if (value < 0.08145) value / 4.5 else std.math.pow(f32, (value + 0.0993) / 1.0993, 1.0 / 0.45);
}

fn encodeSrgb(value: f32) u8 {
    if (!std.math.isFinite(value)) return 0;
    const clamped = std.math.clamp(value, 0, 1);
    const encoded = if (clamped <= 0.0031308) 12.92 * clamped else 1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255));
}

/// Worker-prepared, tightly packed straight-alpha sRGB pixels. `deinit` is
/// also safe after adoption. Hashing belongs on the worker with decoding.
pub const Prepared = struct {
    allocator: std.mem.Allocator,
    value: Image,
    key: [32]u8,

    /// Takes ownership on success only.
    pub fn init(allocator: std.mem.Allocator, value: Image) Error!Prepared {
        try validateImage(value);
        if (value.stride != @as(usize, value.width) * 4 or value.pixels.len != value.stride * value.height or value.color_space != .srgb)
            return error.InvalidImage;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(std.mem.asBytes(&value.width));
        hash.update(std.mem.asBytes(&value.height));
        hash.update(value.pixels);
        return .{ .allocator = allocator, .value = value, .key = hash.finalResult() };
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Prepared {
        var value = try @import("image.zig").decode(allocator, bytes, limits);
        errdefer value.deinit(allocator);
        return init(allocator, value);
    }

    pub fn deinit(self: *Prepared) void {
        self.allocator.free(self.value.pixels);
        self.value.pixels = &.{};
    }
};

pub const Limits = struct {
    maximum_width: u32 = 32_768,
    maximum_height: u32 = 32_768,
    maximum_pixels: usize = 268_435_456,
    maximum_compressed_bytes: usize = 512 * 1024 * 1024,
    /// Peak decoder-owned pixel/coefficient/filter working memory. GPU copies
    /// and the encoded source are accounted separately.
    maximum_decoded_bytes: usize = 1024 * 1024 * 1024,
    maximum_color_profile_bytes: usize = 16 * 1024 * 1024,
    maximum_animation_frames: usize = 16_384,
    /// Maximum number of borrowed IDAT/fdAT payload spans retained by an
    /// incremental animation decoder. This independently bounds metadata even
    /// when an input consists of millions of tiny chunks.
    maximum_animation_chunks: usize = 1_048_576,
    maximum_animation_canvas_bytes: usize = 256 * 1024 * 1024,
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Image {
    if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
    var result = if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &.{ 137, 80, 78, 71, 13, 10, 26, 10 }))
        try @import("png.zig").decode(allocator, bytes, limits)
    else if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "qoif"))
        try @import("qoi.zig").decode(allocator, bytes, limits)
    else if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xd8)
        try @import("jpeg.zig").decode(allocator, bytes, limits)
    else if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a")))
        try @import("gif.zig").decodeFirstFrame(allocator, bytes, limits)
    else if (bytes.len >= 2 and bytes[0] == 'B' and bytes[1] == 'M')
        try @import("bmp.zig").decode(allocator, bytes, limits)
    else if (@import("avif.zig").isAvif(bytes)) if (config.compiled_platform == .macos)
        try @import("avif.zig").decode(allocator, bytes, limits)
    else
        return error.Unsupported else if (isWebp(bytes)) if (config.compiled_platform == .macos)
        try @import("webp.zig").decode(allocator, bytes, limits)
    else
        return error.Unsupported else return error.InvalidImage;
    errdefer result.deinit(allocator);
    try validateImage(result);
    return result;
}

pub fn isWebp(bytes: []const u8) bool {
    return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and
        std.mem.eql(u8, bytes[8..12], "WEBP");
}

pub fn validateDimensions(width: u32, height: u32, limits: Limits) Error!usize {
    if (width == 0 or height == 0 or width > limits.maximum_width or height > limits.maximum_height) return error.InvalidImage;
    const count = std.math.mul(usize, width, height) catch return error.BudgetExceeded;
    if (count > limits.maximum_pixels) return error.BudgetExceeded;
    const rgba_bytes = std.math.mul(usize, count, 4) catch return error.BudgetExceeded;
    if (rgba_bytes > limits.maximum_decoded_bytes) return error.BudgetExceeded;
    return count;
}

pub fn validateImage(value: Image) Error!void {
    if (value.width == 0 or value.height == 0) return error.InvalidImage;
    const row_bytes = std.math.mul(usize, value.width, 4) catch return error.InvalidImage;
    if (value.stride < row_bytes) return error.InvalidImage;
    const required = std.math.mul(usize, value.stride, value.height) catch return error.InvalidImage;
    if (value.pixels.len < required) return error.InvalidImage;
}
