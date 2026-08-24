const std = @import("std");
const Error = @import("../core/error.zig").Error;
const image = @import("image.zig");
const animation = @import("animation_api.zig");
const color_profile = @import("color_profile.zig");

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    interlace: u8,
};

const Palette = struct {
    colors: [256][4]u8 = undefined,
    count: usize = 0,
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], &.{ 137, 80, 78, 71, 13, 10, 26, 10 })) return error.InvalidImage;
    var header: ?Header = null;
    var palette: Palette = .{};
    var transparency: [256]u8 = @splat(255);
    var transparent_gray: ?u16 = null;
    var transparent_rgb: ?[3]u16 = null;
    var color_space: image.ColorSpace = .srgb;
    var image_gamma: ?f64 = null;
    var chromaticities: ?image.Chromaticities = null;
    var profile: ?color_profile.Profile = null;
    defer if (profile) |*value| value.deinit();
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    var offset: usize = 8;
    var saw_end = false;
    var saw_palette = false;
    var saw_transparency = false;
    var saw_idat = false;
    var idat_ended = false;
    var chunk_index: usize = 0;
    var saw_srgb = false;
    var saw_gamma = false;
    var saw_chromaticities = false;
    var saw_iccp = false;
    while (offset + 12 <= bytes.len) {
        const length = readU32(bytes, offset) catch return error.InvalidImage;
        const chunk_end = std.math.add(usize, offset, 12 + @as(usize, length)) catch return error.BudgetExceeded;
        if (chunk_end > bytes.len) return error.InvalidImage;
        const kind = bytes[offset + 4 .. offset + 8];
        if (!validChunkType(kind)) return error.InvalidImage;
        if (saw_idat and !std.mem.eql(u8, kind, "IDAT") and !std.mem.eql(u8, kind, "IEND")) idat_ended = true;
        const data = bytes[offset + 8 .. offset + 8 + length];
        const expected_crc = readU32(bytes, offset + 8 + length) catch return error.InvalidImage;
        if (crc32(bytes[offset + 4 .. offset + 8 + length]) != expected_crc) return error.InvalidImage;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (chunk_index != 0 or header != null or data.len != 13) return error.InvalidImage;
            const value: Header = .{
                .width = readU32(data, 0) catch return error.InvalidImage,
                .height = readU32(data, 4) catch return error.InvalidImage,
                .bit_depth = data[8],
                .color_type = data[9],
                .interlace = data[12],
            };
            if (data[10] != 0 or data[11] != 0 or value.interlace > 1 or !validDepth(value.color_type, value.bit_depth)) return error.InvalidImage;
            _ = try image.validateDimensions(value.width, value.height, limits);
            header = value;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            const value = header orelse return error.InvalidImage;
            if (saw_palette or saw_idat or value.color_type == 0 or value.color_type == 4) return error.InvalidImage;
            if (data.len == 0 or data.len % 3 != 0 or data.len / 3 > 256) return error.InvalidImage;
            if (value.color_type == 3 and data.len / 3 > (@as(usize, 1) << @intCast(value.bit_depth))) return error.InvalidImage;
            saw_palette = true;
            palette.count = data.len / 3;
            for (0..palette.count) |index| palette.colors[index] = .{ data[index * 3], data[index * 3 + 1], data[index * 3 + 2], transparency[index] };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            const value = header orelse return error.InvalidImage;
            if (saw_transparency or saw_idat) return error.InvalidImage;
            saw_transparency = true;
            switch (value.color_type) {
                0 => {
                    if (data.len != 2) return error.InvalidImage;
                    transparent_gray = try readU16(data, 0);
                },
                2 => {
                    if (data.len != 6) return error.InvalidImage;
                    transparent_rgb = .{ try readU16(data, 0), try readU16(data, 2), try readU16(data, 4) };
                },
                3 => {
                    if (!saw_palette or data.len > palette.count) return error.InvalidImage;
                    @memcpy(transparency[0..data.len], data);
                    for (0..@min(data.len, palette.count)) |index| palette.colors[index][3] = data[index];
                },
                else => return error.InvalidImage,
            }
        } else if (std.mem.eql(u8, kind, "sRGB")) {
            if (saw_srgb or saw_iccp or saw_palette or saw_idat or data.len != 1 or data[0] > 3) return error.InvalidImage;
            saw_srgb = true;
            color_space = .srgb;
        } else if (std.mem.eql(u8, kind, "gAMA")) {
            if (saw_gamma or saw_palette or saw_idat or data.len != 4) return error.InvalidImage;
            saw_gamma = true;
            const gamma = readU32(data, 0) catch return error.InvalidImage;
            if (gamma == 0) return error.InvalidImage;
            image_gamma = @as(f64, @floatFromInt(gamma)) / 100_000;
        } else if (std.mem.eql(u8, kind, "cHRM")) {
            if (saw_chromaticities or saw_palette or saw_idat or data.len != 32) return error.InvalidImage;
            saw_chromaticities = true;
            chromaticities = try parseChromaticities(data);
        } else if (std.mem.eql(u8, kind, "iCCP")) {
            if (saw_iccp or saw_srgb or saw_palette or saw_idat) return error.InvalidImage;
            saw_iccp = true;
            const terminator = std.mem.indexOfScalar(u8, data, 0) orelse return error.InvalidImage;
            if (terminator + 2 >= data.len or !validKeyword(data[0..terminator]) or data[terminator + 1] != 0) return error.InvalidImage;
            profile = try color_profile.Profile.fromCompressed(allocator, data[terminator + 2 ..], limits.maximum_color_profile_bytes);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (header == null) return error.InvalidImage;
            if (idat_ended) return error.InvalidImage;
            saw_idat = true;
            if (compressed.items.len > limits.maximum_compressed_bytes -| data.len) return error.BudgetExceeded;
            try compressed.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            if (data.len != 0 or !saw_idat or chunk_end != bytes.len) return error.InvalidImage;
            saw_end = true;
            break;
        } else {
            if (kind[0] & 0x20 == 0) return error.InvalidImage;
        }
        offset = chunk_end;
        chunk_index += 1;
    }
    const value = header orelse return error.InvalidImage;
    if (!saw_end or compressed.items.len == 0 or (value.color_type == 3 and palette.count == 0)) return error.InvalidImage;
    const pixel_count = try image.validateDimensions(value.width, value.height, limits);
    const rgba_length = std.math.mul(usize, pixel_count, 4) catch return error.BudgetExceeded;
    const filtered_length = try expectedFilteredLength(value);
    const row_scratch = std.math.mul(usize, try packedRowBytes(value.width, value), 2) catch return error.BudgetExceeded;
    const decoded_without_output = std.math.add(usize, filtered_length, row_scratch) catch return error.BudgetExceeded;
    if (decoded_without_output > limits.maximum_decoded_bytes -| rgba_length) return error.BudgetExceeded;
    const filtered = try allocator.alloc(u8, filtered_length);
    defer allocator.free(filtered);
    var reader: std.Io.Reader = .fixed(compressed.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
    decompressor.reader.readSliceAll(filtered) catch return error.InvalidImage;
    var extra: [1]u8 = undefined;
    if ((decompressor.reader.readSliceShort(&extra) catch 0) != 0) return error.InvalidImage;

    const rgba = try allocator.alloc(u8, rgba_length);
    errdefer allocator.free(rgba);
    if (value.interlace == 0) {
        try decodePass(allocator, filtered, rgba, value, palette, transparent_gray, transparent_rgb, 0, 0, 1, 1);
    } else {
        const passes = [_][4]u8{
            .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 },
            .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 },
        };
        var source_offset: usize = 0;
        for (passes) |pass| {
            const pass_width = passDimension(value.width, pass[0], pass[2]);
            const pass_height = passDimension(value.height, pass[1], pass[3]);
            if (pass_width == 0 or pass_height == 0) continue;
            const row_bytes = try packedRowBytes(pass_width, value);
            const pass_length = std.math.mul(usize, std.math.add(usize, row_bytes, 1) catch return error.BudgetExceeded, pass_height) catch return error.BudgetExceeded;
            const pass_end = std.math.add(usize, source_offset, pass_length) catch return error.BudgetExceeded;
            if (pass_end > filtered.len) return error.InvalidImage;
            try decodePass(allocator, filtered[source_offset .. source_offset + pass_length], rgba, value, palette, transparent_gray, transparent_rgb, pass[0], pass[1], pass[2], pass[3]);
            source_offset = pass_end;
        }
        if (source_offset != filtered.len) return error.InvalidImage;
    }
    var result: image.Image = .{ .width = value.width, .height = value.height, .stride = @as(usize, value.width) * 4, .pixels = rgba, .color_space = color_space };
    if (profile) |*value_profile| {
        value_profile.applyToSrgb(result.pixels);
        result.color_space = .srgb;
    } else if (!saw_srgb and image_gamma != null) {
        try image.convertGammaPrimariesToSrgb(result.pixels, image_gamma.?, chromaticities);
        result.color_space = .srgb;
    } else image.convertToSrgb(&result);
    return result;
}

pub const AnimationDecoder = struct {
    const Control = struct {
        width: u32,
        height: u32,
        x: u32,
        y: u32,
        delay_numerator: u16,
        delay_denominator: u16,
        disposal: u8,
        blend: u8,
    };

    const Record = struct {
        control: Control,
        chunk_start: usize,
        chunk_count: usize = 0,
    };

    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: image.Limits,
    header: Header,
    palette: Palette,
    transparent_gray: ?u16,
    transparent_rgb: ?[3]u16,
    color_space: image.ColorSpace = .srgb,
    image_gamma: ?f64 = null,
    chromaticities: ?image.Chromaticities = null,
    explicit_srgb: bool = false,
    profile: ?color_profile.Profile = null,
    records: std.ArrayList(Record) = .empty,
    chunks: std.ArrayList([]const u8) = .empty,
    canvas: []u8,
    restore_canvas: ?[]u8 = null,
    previous: ?Control = null,
    frame_index: usize = 0,
    looping: animation.Looping = .once,

    /// Parses APNG control records without copying compressed frame payloads.
    /// The source byte slice therefore remains caller-owned and borrowed.
    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!AnimationDecoder {
        if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], &.{ 137, 80, 78, 71, 13, 10, 26, 10 })) return error.InvalidImage;
        if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
        var result: AnimationDecoder = .{
            .allocator = allocator,
            .bytes = bytes,
            .limits = limits,
            .header = undefined,
            .palette = .{},
            .transparent_gray = null,
            .transparent_rgb = null,
            .color_space = .srgb,
            .canvas = &.{},
        };
        errdefer result.deinit();

        var transparency: [256]u8 = @splat(255);
        var header: ?Header = null;
        var declared_frames: ?u32 = null;
        var declared_plays: u32 = 1;
        var expected_sequence: u32 = 0;
        var offset: usize = 8;
        var saw_end = false;
        var saw_idat = false;
        var idat_ended = false;
        var first_control_precedes_idat = false;
        var saw_palette = false;
        var saw_transparency = false;
        var saw_srgb = false;
        var saw_gamma = false;
        var saw_chromaticities = false;
        var saw_iccp = false;
        var encoded_payload_bytes: usize = 0;
        var chunk_index: usize = 0;
        while (offset + 12 <= bytes.len) {
            const length = readU32(bytes, offset) catch return error.InvalidImage;
            const chunk_end = std.math.add(usize, offset, 12 + @as(usize, length)) catch return error.BudgetExceeded;
            if (chunk_end > bytes.len) return error.InvalidImage;
            const kind = bytes[offset + 4 .. offset + 8];
            if (!validChunkType(kind)) return error.InvalidImage;
            if (saw_idat and !std.mem.eql(u8, kind, "IDAT") and !std.mem.eql(u8, kind, "IEND")) idat_ended = true;
            const data = bytes[offset + 8 .. offset + 8 + length];
            const expected_crc = readU32(bytes, offset + 8 + length) catch return error.InvalidImage;
            if (crc32(bytes[offset + 4 .. offset + 8 + length]) != expected_crc) return error.InvalidImage;

            if (std.mem.eql(u8, kind, "IHDR")) {
                if (chunk_index != 0 or header != null or data.len != 13) return error.InvalidImage;
                const value: Header = .{
                    .width = try readU32(data, 0),
                    .height = try readU32(data, 4),
                    .bit_depth = data[8],
                    .color_type = data[9],
                    .interlace = data[12],
                };
                if (data[10] != 0 or data[11] != 0 or value.interlace > 1 or !validDepth(value.color_type, value.bit_depth)) return error.InvalidImage;
                _ = try image.validateDimensions(value.width, value.height, limits);
                header = value;
            } else if (std.mem.eql(u8, kind, "acTL")) {
                if (header == null or declared_frames != null or data.len != 8 or saw_idat) return error.InvalidImage;
                const frame_count = try readU32(data, 0);
                if (frame_count == 0 or frame_count > limits.maximum_animation_frames) return error.BudgetExceeded;
                declared_frames = frame_count;
                declared_plays = try readU32(data, 4);
            } else if (std.mem.eql(u8, kind, "fcTL")) {
                const root = header orelse return error.InvalidImage;
                if (declared_frames == null or data.len != 26) return error.InvalidImage;
                const sequence = try readU32(data, 0);
                if (sequence != expected_sequence) return error.InvalidImage;
                expected_sequence = std.math.add(u32, expected_sequence, 1) catch return error.InvalidImage;
                const control: Control = .{
                    .width = try readU32(data, 4),
                    .height = try readU32(data, 8),
                    .x = try readU32(data, 12),
                    .y = try readU32(data, 16),
                    .delay_numerator = try readU16(data, 20),
                    .delay_denominator = try readU16(data, 22),
                    .disposal = data[24],
                    .blend = data[25],
                };
                if (control.width == 0 or control.height == 0 or control.x > root.width -| control.width or control.y > root.height -| control.height or
                    control.width > root.width or control.height > root.height or control.disposal > 2 or control.blend > 1)
                    return error.InvalidImage;
                if (result.records.items.len == 0) first_control_precedes_idat = !saw_idat;
                if (result.records.items.len != 0 and result.records.items[result.records.items.len - 1].chunk_count == 0) return error.InvalidImage;
                if (result.records.items.len >= limits.maximum_animation_frames or
                    result.records.items.len >= @as(usize, declared_frames.?)) return error.InvalidImage;
                try result.records.append(allocator, .{ .control = control, .chunk_start = result.chunks.items.len });
            } else if (std.mem.eql(u8, kind, "IDAT")) {
                if (header == null or declared_frames == null) return error.InvalidImage;
                if (idat_ended) return error.InvalidImage;
                saw_idat = true;
                if (first_control_precedes_idat and result.records.items.len == 1) {
                    if (result.chunks.items.len >= limits.maximum_animation_chunks) return error.BudgetExceeded;
                    if (encoded_payload_bytes > limits.maximum_compressed_bytes -| data.len) return error.BudgetExceeded;
                    encoded_payload_bytes += data.len;
                    try result.chunks.append(allocator, data);
                    result.records.items[0].chunk_count += 1;
                }
            } else if (std.mem.eql(u8, kind, "fdAT")) {
                if (!saw_idat or data.len <= 4 or result.records.items.len == 0) return error.InvalidImage;
                if (first_control_precedes_idat and result.records.items.len == 1) return error.InvalidImage;
                const sequence = try readU32(data, 0);
                if (sequence != expected_sequence) return error.InvalidImage;
                expected_sequence = std.math.add(u32, expected_sequence, 1) catch return error.InvalidImage;
                if (result.chunks.items.len >= limits.maximum_animation_chunks) return error.BudgetExceeded;
                if (encoded_payload_bytes > limits.maximum_compressed_bytes -| (data.len - 4)) return error.BudgetExceeded;
                encoded_payload_bytes += data.len - 4;
                try result.chunks.append(allocator, data[4..]);
                result.records.items[result.records.items.len - 1].chunk_count += 1;
            } else if (std.mem.eql(u8, kind, "PLTE")) {
                const root = header orelse return error.InvalidImage;
                if (saw_palette or saw_idat or root.color_type == 0 or root.color_type == 4) return error.InvalidImage;
                if (data.len == 0 or data.len % 3 != 0 or data.len / 3 > 256) return error.InvalidImage;
                if (root.color_type == 3 and data.len / 3 > (@as(usize, 1) << @intCast(root.bit_depth))) return error.InvalidImage;
                saw_palette = true;
                result.palette.count = data.len / 3;
                for (0..result.palette.count) |index| result.palette.colors[index] = .{
                    data[index * 3], data[index * 3 + 1], data[index * 3 + 2], transparency[index],
                };
            } else if (std.mem.eql(u8, kind, "tRNS")) {
                const root = header orelse return error.InvalidImage;
                if (saw_transparency or saw_idat) return error.InvalidImage;
                saw_transparency = true;
                switch (root.color_type) {
                    0 => {
                        if (data.len != 2) return error.InvalidImage;
                        result.transparent_gray = try readU16(data, 0);
                    },
                    2 => {
                        if (data.len != 6) return error.InvalidImage;
                        result.transparent_rgb = .{ try readU16(data, 0), try readU16(data, 2), try readU16(data, 4) };
                    },
                    3 => {
                        if (!saw_palette or data.len > result.palette.count) return error.InvalidImage;
                        @memcpy(transparency[0..data.len], data);
                        for (0..@min(data.len, result.palette.count)) |index| result.palette.colors[index][3] = data[index];
                    },
                    else => return error.InvalidImage,
                }
            } else if (std.mem.eql(u8, kind, "sRGB")) {
                if (saw_srgb or saw_iccp or saw_palette or saw_idat or data.len != 1 or data[0] > 3) return error.InvalidImage;
                saw_srgb = true;
                result.explicit_srgb = true;
                result.color_space = .srgb;
            } else if (std.mem.eql(u8, kind, "gAMA")) {
                if (saw_gamma or saw_palette or saw_idat or data.len != 4) return error.InvalidImage;
                saw_gamma = true;
                const gamma = try readU32(data, 0);
                if (gamma == 0) return error.InvalidImage;
                result.image_gamma = @as(f64, @floatFromInt(gamma)) / 100_000;
            } else if (std.mem.eql(u8, kind, "cHRM")) {
                if (saw_chromaticities or saw_palette or saw_idat or data.len != 32) return error.InvalidImage;
                saw_chromaticities = true;
                result.chromaticities = try parseChromaticities(data);
            } else if (std.mem.eql(u8, kind, "iCCP")) {
                if (saw_iccp or saw_srgb or saw_palette or saw_idat) return error.InvalidImage;
                saw_iccp = true;
                const terminator = std.mem.indexOfScalar(u8, data, 0) orelse return error.InvalidImage;
                if (terminator + 2 >= data.len or !validKeyword(data[0..terminator]) or data[terminator + 1] != 0) return error.InvalidImage;
                result.profile = try color_profile.Profile.fromCompressed(allocator, data[terminator + 2 ..], limits.maximum_color_profile_bytes);
            } else if (std.mem.eql(u8, kind, "IEND")) {
                if (data.len != 0 or !saw_idat or chunk_end != bytes.len) return error.InvalidImage;
                saw_end = true;
                break;
            } else if (kind[0] & 0x20 == 0) return error.InvalidImage;
            offset = chunk_end;
            chunk_index += 1;
        }
        const root = header orelse return error.InvalidImage;
        const frame_count = declared_frames orelse return error.InvalidImage;
        if (!saw_end or result.records.items.len != @as(usize, frame_count) or result.records.items.len == 0 or
            result.records.items[result.records.items.len - 1].chunk_count == 0 or (root.color_type == 3 and result.palette.count == 0))
            return error.InvalidImage;
        const pixel_count = try image.validateDimensions(root.width, root.height, limits);
        const canvas_bytes = std.math.mul(usize, pixel_count, 4) catch return error.BudgetExceeded;
        if (canvas_bytes > limits.maximum_animation_canvas_bytes) return error.BudgetExceeded;
        result.canvas = try allocator.alloc(u8, canvas_bytes);
        @memset(result.canvas, 0);
        result.header = root;
        result.looping = if (declared_plays == 0) .infinite else if (declared_plays == 1) .once else .{ .repetitions = declared_plays - 1 };
        return result;
    }

    pub fn deinit(self: *AnimationDecoder) void {
        if (self.profile) |*value| value.deinit();
        if (self.restore_canvas) |value| self.allocator.free(value);
        if (self.canvas.len != 0) self.allocator.free(self.canvas);
        self.records.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *AnimationDecoder) void {
        self.previous = null;
        self.frame_index = 0;
        @memset(self.canvas, 0);
        if (self.restore_canvas) |value| @memset(value, 0);
    }

    pub fn next(self: *AnimationDecoder) Error!?animation.Frame {
        if (self.frame_index >= self.records.items.len) return null;
        self.applyPreviousDisposal();
        const record = self.records.items[self.frame_index];
        if (record.control.disposal == 2) {
            if (self.restore_canvas == null) {
                if (self.canvas.len > self.limits.maximum_animation_canvas_bytes -| self.canvas.len) return error.BudgetExceeded;
                if (self.canvas.len > self.limits.maximum_decoded_bytes -| self.canvas.len) return error.BudgetExceeded;
                self.restore_canvas = try self.allocator.alloc(u8, self.canvas.len);
            }
            @memcpy(self.restore_canvas.?, self.canvas);
        }
        try self.decodeRecord(record);
        self.previous = record.control;
        const index = self.frame_index;
        self.frame_index += 1;
        const denominator: u64 = if (record.control.delay_denominator == 0) 100 else record.control.delay_denominator;
        const numerator: u64 = record.control.delay_numerator;
        const duration = @max(std.time.ns_per_ms, (numerator * std.time.ns_per_s) / denominator);
        return .{
            .pixels = self.canvas,
            .width = self.header.width,
            .height = self.header.height,
            .stride = @as(usize, self.header.width) * 4,
            .duration_ns = duration,
            .index = index,
        };
    }

    fn decodeRecord(self: *AnimationDecoder, record: Record) Error!void {
        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(self.allocator);
        for (self.chunks.items[record.chunk_start..][0..record.chunk_count]) |chunk| {
            if (compressed.items.len > self.limits.maximum_compressed_bytes -| chunk.len) return error.BudgetExceeded;
            try compressed.appendSlice(self.allocator, chunk);
        }
        var frame_header = self.header;
        frame_header.width = record.control.width;
        frame_header.height = record.control.height;
        const filtered_length = try expectedFilteredLength(frame_header);
        const frame_pixel_count = try image.validateDimensions(frame_header.width, frame_header.height, self.limits);
        const frame_bytes = std.math.mul(usize, frame_pixel_count, 4) catch return error.BudgetExceeded;
        const row_scratch = std.math.mul(usize, try packedRowBytes(frame_header.width, frame_header), 2) catch return error.BudgetExceeded;
        const persistent_bytes = std.math.add(usize, self.canvas.len, if (self.restore_canvas) |value| value.len else 0) catch return error.BudgetExceeded;
        const decoded_peak = std.math.add(usize, std.math.add(usize, persistent_bytes, filtered_length) catch return error.BudgetExceeded, row_scratch) catch return error.BudgetExceeded;
        if (decoded_peak > self.limits.maximum_decoded_bytes -| frame_bytes) return error.BudgetExceeded;
        const filtered = try self.allocator.alloc(u8, filtered_length);
        defer self.allocator.free(filtered);
        var reader: std.Io.Reader = .fixed(compressed.items);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor: std.compress.flate.Decompress = .init(&reader, .zlib, &window);
        decompressor.reader.readSliceAll(filtered) catch return error.InvalidImage;
        var extra: [1]u8 = undefined;
        if ((decompressor.reader.readSliceShort(&extra) catch 0) != 0) return error.InvalidImage;

        const frame_pixels = try self.allocator.alloc(u8, frame_bytes);
        defer self.allocator.free(frame_pixels);
        @memset(frame_pixels, 0);
        if (frame_header.interlace == 0) {
            try decodePass(self.allocator, filtered, frame_pixels, frame_header, self.palette, self.transparent_gray, self.transparent_rgb, 0, 0, 1, 1);
        } else {
            const passes = [_][4]u8{
                .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 },
                .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 },
            };
            var source_offset: usize = 0;
            for (passes) |pass| {
                const pass_width = passDimension(frame_header.width, pass[0], pass[2]);
                const pass_height = passDimension(frame_header.height, pass[1], pass[3]);
                if (pass_width == 0 or pass_height == 0) continue;
                const row_bytes = try packedRowBytes(pass_width, frame_header);
                const pass_length = std.math.mul(usize, std.math.add(usize, row_bytes, 1) catch return error.BudgetExceeded, pass_height) catch return error.BudgetExceeded;
                const pass_end = std.math.add(usize, source_offset, pass_length) catch return error.BudgetExceeded;
                if (pass_end > filtered.len) return error.InvalidImage;
                try decodePass(self.allocator, filtered[source_offset .. source_offset + pass_length], frame_pixels, frame_header, self.palette, self.transparent_gray, self.transparent_rgb, pass[0], pass[1], pass[2], pass[3]);
                source_offset = pass_end;
            }
            if (source_offset != filtered.len) return error.InvalidImage;
        }
        if (self.profile) |*value| {
            value.applyToSrgb(frame_pixels);
        } else if (!self.explicit_srgb and self.image_gamma != null) {
            const gamma = self.image_gamma.?;
            try image.convertGammaPrimariesToSrgb(frame_pixels, gamma, self.chromaticities);
        } else image.convertPixelsToSrgb(frame_pixels, self.color_space);
        self.composite(record.control, frame_pixels);
    }

    fn composite(self: *AnimationDecoder, control: Control, source: []const u8) void {
        for (0..control.height) |row| for (0..control.width) |column| {
            const source_offset = (row * control.width + column) * 4;
            const destination_offset = ((@as(usize, control.y) + row) * self.header.width + @as(usize, control.x) + column) * 4;
            const destination = self.canvas[destination_offset..][0..4];
            const pixel = source[source_offset..][0..4];
            if (control.blend == 0) @memcpy(destination, pixel) else blendOver(destination, pixel);
        };
    }

    fn applyPreviousDisposal(self: *AnimationDecoder) void {
        const control = self.previous orelse return;
        switch (control.disposal) {
            1 => for (0..control.height) |row| {
                const start = ((@as(usize, control.y) + row) * self.header.width + control.x) * 4;
                @memset(self.canvas[start..][0 .. @as(usize, control.width) * 4], 0);
            },
            2 => if (self.restore_canvas) |value| @memcpy(self.canvas, value),
            else => {},
        }
        self.previous = null;
    }
};

pub fn isAnimated(bytes: []const u8) bool {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], &.{ 137, 80, 78, 71, 13, 10, 26, 10 })) return false;
    var offset: usize = 8;
    while (offset + 12 <= bytes.len) {
        const length = readU32(bytes, offset) catch return false;
        if (offset + 12 + @as(usize, length) > bytes.len) return false;
        if (std.mem.eql(u8, bytes[offset + 4 .. offset + 8], "acTL")) return true;
        if (std.mem.eql(u8, bytes[offset + 4 .. offset + 8], "IDAT")) return false;
        offset += 12 + @as(usize, length);
    }
    return false;
}

fn blendOver(destination: []u8, source: []const u8) void {
    const source_alpha = @as(f32, @floatFromInt(source[3])) / 255;
    if (source[3] == 255) {
        @memcpy(destination, source);
        return;
    }
    if (source[3] == 0) return;
    const destination_alpha = @as(f32, @floatFromInt(destination[3])) / 255;
    const output_alpha = source_alpha + destination_alpha * (1 - source_alpha);
    if (output_alpha <= 0) {
        @memset(destination, 0);
        return;
    }
    for (0..3) |channel| {
        const source_linear = decodeSrgbByte(source[channel]);
        const destination_linear = decodeSrgbByte(destination[channel]);
        const output_linear = (source_linear * source_alpha + destination_linear * destination_alpha * (1 - source_alpha)) / output_alpha;
        destination[channel] = encodeSrgbFloat(output_linear);
    }
    destination[3] = @intFromFloat(@round(std.math.clamp(output_alpha, 0, 1) * 255));
}

fn validChunkType(kind: []const u8) bool {
    if (kind.len != 4) return false;
    for (kind) |byte| if (!std.ascii.isAlphabetic(byte)) return false;
    // The third PNG chunk-type letter is reserved and must be uppercase.
    return kind[2] & 0x20 == 0;
}

fn validKeyword(value: []const u8) bool {
    if (value.len == 0 or value.len > 79 or value[0] == ' ' or value[value.len - 1] == ' ') return false;
    var previous_space = false;
    for (value) |byte| {
        if (!((byte >= 32 and byte <= 126) or byte >= 161)) return false;
        if (byte == ' ' and previous_space) return false;
        previous_space = byte == ' ';
    }
    return true;
}

fn parseChromaticities(data: []const u8) Error!image.Chromaticities {
    if (data.len != 32) return error.InvalidImage;
    var values: [8]f64 = undefined;
    for (0..values.len) |index| values[index] = @as(f64, @floatFromInt(try readU32(data, index * 4))) / 100_000;
    const result: image.Chromaticities = .{
        .white = .{ values[0], values[1] },
        .red = .{ values[2], values[3] },
        .green = .{ values[4], values[5] },
        .blue = .{ values[6], values[7] },
    };
    // Validate immediately, including degenerate primary matrices, by asking
    // the public transform to process an empty image.
    var empty: [0]u8 = .{};
    try image.convertGammaPrimariesToSrgb(&empty, 1, result);
    return result;
}

fn decodeSrgbByte(value: u8) f32 {
    const encoded = @as(f32, @floatFromInt(value)) / 255;
    return if (encoded <= 0.04045) encoded / 12.92 else std.math.pow(f32, (encoded + 0.055) / 1.055, 2.4);
}

fn encodeSrgbFloat(value: f32) u8 {
    const linear = std.math.clamp(value, 0, 1);
    const encoded = if (linear <= 0.0031308) linear * 12.92 else 1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255));
}

fn decodePass(
    allocator: std.mem.Allocator,
    filtered: []const u8,
    rgba: []u8,
    header: Header,
    palette: Palette,
    transparent_gray: ?u16,
    transparent_rgb: ?[3]u16,
    start_x: u8,
    start_y: u8,
    step_x: u8,
    step_y: u8,
) Error!void {
    const width = passDimension(header.width, start_x, step_x);
    const height = passDimension(header.height, start_y, step_y);
    if (width == 0 or height == 0) return;
    const row_bytes = try packedRowBytes(width, header);
    const bytes_per_pixel = @max(1, (channels(header.color_type) * header.bit_depth + 7) / 8);
    var previous: [*]u8 = undefined;
    var row_storage: [2][]u8 = undefined;
    row_storage[0] = try allocator.alloc(u8, row_bytes);
    defer allocator.free(row_storage[0]);
    row_storage[1] = try allocator.alloc(u8, row_bytes);
    defer allocator.free(row_storage[1]);
    @memset(row_storage[0], 0);
    previous = row_storage[0].ptr;
    var source_offset: usize = 0;
    var row_index: usize = 0;
    while (row_index < height) : (row_index += 1) {
        const filter = filtered[source_offset];
        source_offset += 1;
        const current = row_storage[(row_index + 1) % 2];
        @memcpy(current, filtered[source_offset .. source_offset + row_bytes]);
        source_offset += row_bytes;
        try unfilter(current, previous[0..row_bytes], bytes_per_pixel, filter);
        var column: usize = 0;
        while (column < width) : (column += 1) {
            const pixel = try readPixel(current, column, header, palette, transparent_gray, transparent_rgb);
            const destination_x = @as(usize, start_x) + column * step_x;
            const destination_y = @as(usize, start_y) + row_index * step_y;
            const destination = (destination_y * header.width + destination_x) * 4;
            @memcpy(rgba[destination..][0..4], &pixel);
        }
        previous = current.ptr;
    }
}

fn readPixel(row: []const u8, index: usize, header: Header, palette: Palette, transparent_gray: ?u16, transparent_rgb: ?[3]u16) Error![4]u8 {
    var samples: [4]u16 = .{ 0, 0, 0, maxSample(header.bit_depth) };
    const count = channels(header.color_type);
    for (0..count) |sample_index| samples[sample_index] = extractSample(row, index * count + sample_index, header.bit_depth);
    const max = maxSample(header.bit_depth);
    return switch (header.color_type) {
        0 => blk: {
            const gray = scaleSample(samples[0], max);
            break :blk .{ gray, gray, gray, if (transparent_gray != null and samples[0] == transparent_gray.?) 0 else 255 };
        },
        2 => .{
            scaleSample(samples[0], max),                                                                         scaleSample(samples[1], max), scaleSample(samples[2], max),
            if (transparent_rgb != null and std.mem.eql(u16, samples[0..3], transparent_rgb.?[0..3])) 0 else 255,
        },
        3 => {
            if (samples[0] >= palette.count) return error.InvalidImage;
            return palette.colors[samples[0]];
        },
        4 => blk: {
            const gray = scaleSample(samples[0], max);
            break :blk .{ gray, gray, gray, scaleSample(samples[1], max) };
        },
        6 => .{ scaleSample(samples[0], max), scaleSample(samples[1], max), scaleSample(samples[2], max), scaleSample(samples[3], max) },
        else => return error.InvalidImage,
    };
}

fn unfilter(row: []u8, previous: []const u8, bpp: usize, filter: u8) Error!void {
    for (row, 0..) |*byte, index| {
        const left: u8 = if (index >= bpp) row[index - bpp] else 0;
        const up = previous[index];
        const upper_left: u8 = if (index >= bpp) previous[index - bpp] else 0;
        byte.* +%= switch (filter) {
            0 => 0,
            1 => left,
            2 => up,
            3 => @intCast((@as(u16, left) + up) / 2),
            4 => paeth(left, up, upper_left),
            else => return error.InvalidImage,
        };
    }
}

fn expectedFilteredLength(header: Header) Error!usize {
    if (header.interlace == 0) {
        const row = std.math.add(usize, try packedRowBytes(header.width, header), 1) catch return error.BudgetExceeded;
        return std.math.mul(usize, row, header.height) catch return error.BudgetExceeded;
    }
    const passes = [_][4]u8{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };
    var result: usize = 0;
    for (passes) |pass| {
        const width = passDimension(header.width, pass[0], pass[2]);
        const height = passDimension(header.height, pass[1], pass[3]);
        if (width != 0 and height != 0) {
            const row = std.math.add(usize, try packedRowBytes(width, header), 1) catch return error.BudgetExceeded;
            const pass_bytes = std.math.mul(usize, row, height) catch return error.BudgetExceeded;
            result = std.math.add(usize, result, pass_bytes) catch return error.BudgetExceeded;
        }
    }
    return result;
}

fn packedRowBytes(width: usize, header: Header) Error!usize {
    const bits = std.math.mul(usize, width, channels(header.color_type) * header.bit_depth) catch return error.BudgetExceeded;
    return (std.math.add(usize, bits, 7) catch return error.BudgetExceeded) / 8;
}

fn channels(color_type: u8) u8 {
    return switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => 0,
    };
}
fn validDepth(color_type: u8, depth: u8) bool {
    return switch (color_type) {
        0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        2 => depth == 8 or depth == 16,
        3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        4, 6 => depth == 8 or depth == 16,
        else => false,
    };
}
fn maxSample(depth: u8) u16 {
    return if (depth == 16) 65535 else (@as(u16, 1) << @intCast(depth)) - 1;
}
fn scaleSample(value: u16, maximum: u16) u8 {
    return @intCast((@as(u32, value) * 255 + maximum / 2) / maximum);
}
fn extractSample(row: []const u8, index: usize, depth: u8) u16 {
    if (depth == 16) return (@as(u16, row[index * 2]) << 8) | row[index * 2 + 1];
    if (depth == 8) return row[index];
    const bit = index * depth;
    const shift: u3 = @intCast(8 - depth - bit % 8);
    return (row[bit / 8] >> shift) & @as(u8, @intCast(maxSample(depth)));
}
fn passDimension(total: u32, start: u8, step: u8) usize {
    return if (total <= start) 0 else (@as(usize, total - start) + step - 1) / step;
}
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}
fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset + 2 > bytes.len) return error.InvalidImage;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}
fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset + 4 > bytes.len) return error.InvalidImage;
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) | (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}
fn crc32(bytes: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    for (bytes) |byte| {
        crc ^= byte;
        for (0..8) |_| crc = if (crc & 1 != 0) (crc >> 1) ^ 0xedb88320 else crc >> 1;
    }
    return ~crc;
}
