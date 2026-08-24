const std = @import("std");
const Error = @import("../core/error.zig").Error;
const image = @import("image.zig");

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    if (bytes.len < 22 or !std.mem.eql(u8, bytes[0..4], "qoif")) return error.InvalidImage;
    if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
    if (!std.mem.eql(u8, bytes[bytes.len - 8 ..], &.{ 0, 0, 0, 0, 0, 0, 0, 1 })) return error.InvalidImage;
    const width = readU32(bytes, 4);
    const height = readU32(bytes, 8);
    const channels = bytes[12];
    if ((channels != 3 and channels != 4) or bytes[13] > 1) return error.InvalidImage;
    const count = try image.validateDimensions(width, height, limits);
    const output = try allocator.alloc(u8, std.math.mul(usize, count, 4) catch return error.BudgetExceeded);
    errdefer allocator.free(output);
    var cache: [64][4]u8 = @splat(.{ 0, 0, 0, 0 });
    var pixel: [4]u8 = .{ 0, 0, 0, 255 };
    var input_index: usize = 14;
    var output_index: usize = 0;
    var run: usize = 0;
    while (output_index < count) : (output_index += 1) {
        if (run != 0) {
            run -= 1;
        } else {
            if (input_index >= bytes.len - 8) return error.InvalidImage;
            const tag = bytes[input_index];
            input_index += 1;
            if (tag == 0xfe) {
                if (input_index + 3 > bytes.len) return error.InvalidImage;
                pixel[0] = bytes[input_index];
                pixel[1] = bytes[input_index + 1];
                pixel[2] = bytes[input_index + 2];
                input_index += 3;
            } else if (tag == 0xff) {
                if (input_index + 4 > bytes.len) return error.InvalidImage;
                @memcpy(&pixel, bytes[input_index..][0..4]);
                input_index += 4;
            } else switch (tag >> 6) {
                0 => pixel = cache[tag & 0x3f],
                1 => {
                    pixel[0] +%= ((tag >> 4) & 0x03) -% 2;
                    pixel[1] +%= ((tag >> 2) & 0x03) -% 2;
                    pixel[2] +%= (tag & 0x03) -% 2;
                },
                2 => {
                    if (input_index >= bytes.len) return error.InvalidImage;
                    const next = bytes[input_index];
                    input_index += 1;
                    const green_delta: i16 = @as(i16, tag & 0x3f) - 32;
                    pixel[0] +%= @bitCast(@as(i8, @intCast(green_delta + @as(i16, next >> 4) - 8)));
                    pixel[1] +%= @bitCast(@as(i8, @intCast(green_delta)));
                    pixel[2] +%= @bitCast(@as(i8, @intCast(green_delta + @as(i16, next & 0x0f) - 8)));
                },
                3 => run = tag & 0x3f,
                else => unreachable,
            }
            cache[hash(pixel)] = pixel;
        }
        @memcpy(output[output_index * 4 ..][0..4], &pixel);
    }
    if (run != 0 or input_index != bytes.len - 8) return error.InvalidImage;
    var result: image.Image = .{
        .width = width,
        .height = height,
        .stride = @as(usize, width) * 4,
        .pixels = output,
        .color_space = if (bytes[13] == 0) .srgb else .linear_srgb,
    };
    image.convertToSrgb(&result);
    return result;
}

fn hash(pixel: [4]u8) usize {
    return (@as(usize, pixel[0]) * 3 + @as(usize, pixel[1]) * 5 + @as(usize, pixel[2]) * 7 + @as(usize, pixel[3]) * 11) % 64;
}
fn readU32(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) | (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}
