const std = @import("std");
const Error = @import("../core/error.zig").Error;
const image = @import("image.zig");
const color_profile = @import("color_profile.zig");

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
    var result = if (isProgressive(bytes))
        try @import("jpeg_progressive.zig").decode(allocator, bytes, limits)
    else
        try @import("jpeg_progressive.zig").decodeSequential(allocator, bytes, limits);
    errdefer result.deinit(allocator);
    var metadata = try parseMetadata(allocator, bytes, limits);
    defer metadata.deinit();
    if (metadata.profile) |*profile| profile.applyToSrgb(result.pixels);
    try image.applyOrientation(allocator, &result, metadata.orientation, limits.maximum_decoded_bytes);
    result.color_space = .srgb;
    return result;
}

const Metadata = struct {
    allocator: std.mem.Allocator,
    orientation: image.Orientation = .normal,
    profile: ?color_profile.Profile = null,

    fn deinit(self: *Metadata) void {
        if (self.profile) |*value| value.deinit();
        self.* = undefined;
    }
};

fn parseMetadata(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!Metadata {
    var result: Metadata = .{ .allocator = allocator };
    errdefer result.deinit();
    var profile_segments: [255]?[]const u8 = @splat(null);
    var profile_segment_count: usize = 0;
    var profile_bytes: usize = 0;
    var offset: usize = 2;
    while (offset + 4 <= bytes.len) {
        while (offset < bytes.len and bytes[offset] != 0xff) offset += 1;
        while (offset < bytes.len and bytes[offset] == 0xff) offset += 1;
        if (offset >= bytes.len) break;
        const marker = bytes[offset];
        offset += 1;
        if (marker == 0xda or marker == 0xd9) break;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        const length = readU16(bytes, offset) orelse return error.InvalidImage;
        if (length < 2 or offset + length > bytes.len) return error.InvalidImage;
        const data = bytes[offset + 2 .. offset + length];
        if (marker == 0xe1 and data.len >= 14 and std.mem.eql(u8, data[0..6], "Exif\x00\x00"))
            result.orientation = parseExifOrientation(data[6..]) orelse result.orientation;
        if (marker == 0xe2 and data.len >= 14 and std.mem.eql(u8, data[0..12], "ICC_PROFILE\x00")) {
            const sequence = data[12];
            const count = data[13];
            if (sequence == 0 or count == 0 or sequence > count or data.len == 14) return error.InvalidImage;
            if (profile_segment_count == 0) profile_segment_count = count else if (profile_segment_count != count) return error.InvalidImage;
            const index = @as(usize, sequence - 1);
            if (profile_segments[index] != null) return error.InvalidImage;
            const payload = data[14..];
            profile_bytes = std.math.add(usize, profile_bytes, payload.len) catch return error.BudgetExceeded;
            if (profile_bytes > limits.maximum_color_profile_bytes) return error.BudgetExceeded;
            profile_segments[index] = payload;
        }
        offset += length;
    }
    if (profile_segment_count != 0) {
        const owned = try allocator.alloc(u8, profile_bytes);
        errdefer allocator.free(owned);
        var write: usize = 0;
        for (profile_segments[0..profile_segment_count]) |maybe_segment| {
            const segment = maybe_segment orelse return error.InvalidImage;
            @memcpy(owned[write..][0..segment.len], segment);
            write += segment.len;
        }
        result.profile = try color_profile.Profile.initOwned(allocator, owned);
    }
    return result;
}

fn parseExifOrientation(tiff: []const u8) ?image.Orientation {
    if (tiff.len < 8) return null;
    const little = if (std.mem.eql(u8, tiff[0..2], "II")) true else if (std.mem.eql(u8, tiff[0..2], "MM")) false else return null;
    if (readExifU16(tiff, 2, little) != 42) return null;
    const ifd_offset = readExifU32(tiff, 4, little) orelse return null;
    if (ifd_offset > tiff.len -| 2) return null;
    const count = readExifU16(tiff, ifd_offset, little) orelse return null;
    var entry_offset: usize = @as(usize, ifd_offset) + 2;
    for (0..count) |_| {
        if (entry_offset + 12 > tiff.len) return null;
        const tag = readExifU16(tiff, entry_offset, little) orelse return null;
        if (tag == 0x0112) {
            const kind = readExifU16(tiff, entry_offset + 2, little) orelse return null;
            const value_count = readExifU32(tiff, entry_offset + 4, little) orelse return null;
            if (kind != 3 or value_count != 1) return null;
            const raw = readExifU16(tiff, entry_offset + 8, little) orelse return null;
            return std.enums.fromInt(image.Orientation, raw);
        }
        entry_offset += 12;
    }
    return null;
}

fn readExifU16(bytes: []const u8, offset: usize, little: bool) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return if (little)
        @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8)
    else
        (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readExifU32(bytes: []const u8, offset: usize, little: bool) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return if (little)
        @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) | (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24)
    else
        (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) | (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}

fn isProgressive(bytes: []const u8) bool {
    var offset: usize = 2;
    while (offset + 1 < bytes.len) {
        while (offset < bytes.len and bytes[offset] != 0xff) offset += 1;
        while (offset < bytes.len and bytes[offset] == 0xff) offset += 1;
        if (offset >= bytes.len) return false;
        const marker = bytes[offset];
        offset += 1;
        if (marker == 0xc2) return true;
        if (marker == 0xda or marker == 0xd9) return false;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        const length = readU16(bytes, offset) orelse return false;
        if (length < 2 or offset + length > bytes.len) return false;
        offset += length;
    }
    return false;
}

fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}
