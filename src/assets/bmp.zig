const std = @import("std");
const Error = @import("../core/error.zig").Error;
const image = @import("image.zig");
const color_profile = @import("color_profile.zig");

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    if (bytes.len < 54 or bytes[0] != 'B' or bytes[1] != 'M') return error.InvalidImage;
    if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
    const declared_file_size = readU32(bytes, 2) orelse return error.InvalidImage;
    const pixel_offset = readU32(bytes, 10) orelse return error.InvalidImage;
    const header_size = readU32(bytes, 14) orelse return error.InvalidImage;
    const dib_end = std.math.add(usize, 14, @as(usize, header_size)) catch return error.BudgetExceeded;
    if (header_size < 40 or dib_end > bytes.len) return error.InvalidImage;
    const signed_width = readI32(bytes, 18) orelse return error.InvalidImage;
    const signed_height = readI32(bytes, 22) orelse return error.InvalidImage;
    if (signed_width <= 0 or signed_height == 0 or signed_height == std.math.minInt(i32)) return error.InvalidImage;
    const width: u32 = @intCast(signed_width);
    const height: u32 = @intCast(@abs(signed_height));
    const top_down = signed_height < 0;
    const planes = readU16(bytes, 26) orelse return error.InvalidImage;
    const bits = readU16(bytes, 28) orelse return error.InvalidImage;
    const compression = readU32(bytes, 30) orelse return error.InvalidImage;
    if (planes != 1 or
        !((bits == 24 and compression == 0) or (bits == 32 and (compression == 0 or compression == 3 or compression == 6))))
        return error.InvalidImage;
    const count = try image.validateDimensions(width, height, limits);
    const row_bits = std.math.mul(usize, @as(usize, width), @as(usize, bits)) catch return error.BudgetExceeded;
    const source_stride = std.math.mul(usize, (std.math.add(usize, row_bits, 31) catch return error.BudgetExceeded) / 32, 4) catch return error.BudgetExceeded;
    const source_bytes = std.math.mul(usize, source_stride, @as(usize, height)) catch return error.BudgetExceeded;
    const pixel_end = std.math.add(usize, @as(usize, pixel_offset), source_bytes) catch return error.BudgetExceeded;
    const declared_size: usize = declared_file_size;
    if (pixel_end > bytes.len or (declared_size != 0 and (declared_size > bytes.len or pixel_end > declared_size))) return error.InvalidImage;
    const output = try allocator.alloc(u8, std.math.mul(usize, count, 4) catch return error.BudgetExceeded);
    errdefer allocator.free(output);
    var profile: ?color_profile.Profile = null;
    defer if (profile) |*value| value.deinit();
    if (header_size >= 108) {
        const color_space = readU32(bytes, 14 + 56) orelse return error.InvalidImage;
        switch (color_space) {
            0x73524742, 0x57696e20 => {}, // LCS_sRGB / LCS_WINDOWS_COLOR_SPACE
            0x4d424544 => { // PROFILE_EMBEDDED
                if (header_size < 124) return error.InvalidImage;
                const relative: usize = readU32(bytes, 14 + 112) orelse return error.InvalidImage;
                const profile_size: usize = readU32(bytes, 14 + 116) orelse return error.InvalidImage;
                if (profile_size == 0 or profile_size > limits.maximum_color_profile_bytes) return error.BudgetExceeded;
                const start = std.math.add(usize, 14, relative) catch return error.BudgetExceeded;
                const end = std.math.add(usize, start, profile_size) catch return error.BudgetExceeded;
                if (end > bytes.len or !(end <= @as(usize, pixel_offset) or start >= pixel_end)) return error.InvalidImage;
                const owned = try allocator.dupe(u8, bytes[start..end]);
                errdefer allocator.free(owned);
                profile = try color_profile.Profile.initOwned(allocator, owned);
            },
            0x4c494e4b => return error.Unsupported, // PROFILE_LINKED
            else => return error.Unsupported,
        }
    }
    var red_mask: u32 = 0x00ff0000;
    var green_mask: u32 = 0x0000ff00;
    var blue_mask: u32 = 0x000000ff;
    var alpha_mask: u32 = 0;
    var minimum_pixel_offset = dib_end;
    if (compression == 3 or compression == 6) {
        if (header_size != 40 and header_size < 52) return error.InvalidImage;
        if (compression == 6 and header_size != 40 and header_size < 56) return error.InvalidImage;
        const mask_offset: usize = 14 + 40;
        const external_mask_bytes: usize = if (header_size == 40) (if (compression == 6) 16 else 12) else 0;
        minimum_pixel_offset = std.math.add(usize, dib_end, external_mask_bytes) catch return error.BudgetExceeded;
        red_mask = readU32(bytes, mask_offset) orelse return error.InvalidImage;
        green_mask = readU32(bytes, mask_offset + 4) orelse return error.InvalidImage;
        blue_mask = readU32(bytes, mask_offset + 8) orelse return error.InvalidImage;
        if (header_size >= 56 or compression == 6) alpha_mask = readU32(bytes, mask_offset + 12) orelse return error.InvalidImage;
        if (!validMasks(red_mask, green_mask, blue_mask, alpha_mask, compression == 6)) return error.InvalidImage;
    }
    if (@as(usize, pixel_offset) < minimum_pixel_offset) return error.InvalidImage;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const source_y = if (top_down) y else @as(usize, height) - 1 - y;
        const row = bytes[@as(usize, pixel_offset) + source_y * source_stride ..];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const destination = (y * width + x) * 4;
            if (bits == 24) {
                output[destination] = row[x * 3 + 2];
                output[destination + 1] = row[x * 3 + 1];
                output[destination + 2] = row[x * 3];
                output[destination + 3] = 255;
            } else {
                const value = readU32(row, x * 4) orelse return error.InvalidImage;
                output[destination] = extract(value, red_mask);
                output[destination + 1] = extract(value, green_mask);
                output[destination + 2] = extract(value, blue_mask);
                output[destination + 3] = if (alpha_mask == 0) 255 else extract(value, alpha_mask);
            }
        }
    }
    if (profile) |*value| value.applyToSrgb(output);
    return .{ .width = width, .height = height, .stride = @as(usize, width) * 4, .pixels = output };
}

fn extract(value: u32, mask: u32) u8 {
    if (mask == 0) return 0;
    const shift: u5 = @intCast(@ctz(mask));
    const maximum = mask >> shift;
    return @intCast((@as(u64, (value & mask) >> shift) * 255) / maximum);
}

fn validMasks(red: u32, green: u32, blue: u32, alpha: u32, require_alpha: bool) bool {
    if (red == 0 or green == 0 or blue == 0 or (require_alpha and alpha == 0)) return false;
    if (!contiguousMask(red) or !contiguousMask(green) or !contiguousMask(blue) or (alpha != 0 and !contiguousMask(alpha))) return false;
    if (red & green != 0 or red & blue != 0 or green & blue != 0) return false;
    if (alpha != 0 and alpha & (red | green | blue) != 0) return false;
    return true;
}

fn contiguousMask(mask: u32) bool {
    if (mask == 0) return true;
    const shifted = mask >> @intCast(@ctz(mask));
    return shifted & (shifted +% 1) == 0;
}
fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}
fn readU32(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) | (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24);
}
fn readI32(bytes: []const u8, offset: usize) ?i32 {
    return @bitCast(readU32(bytes, offset) orelse return null);
}
