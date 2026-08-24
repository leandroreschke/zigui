const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const image = @import("../assets/image.zig");
const api = @import("api.zig");
const opentype = @import("opentype.zig");
const raster = @import("truetype_raster.zig");
const colr_v1 = @import("colr_v1.zig");

const maximum_text_size: f32 = 1_000_000;
const maximum_scale_factor: f32 = 64;
const maximum_raster_dimension: usize = 8192;
const maximum_raster_pixels: usize = 4 * 1024 * 1024;
const maximum_colr_layers: usize = 4096;
const maximum_live_layer_pixels: usize = 16 * 1024 * 1024;

const EmbeddedBitmap = struct {
    bytes: []const u8,
    origin_x: i16,
    origin_y: i16,
    source_ppem: u16,
};

pub fn hasGlyph(font: opentype.Font, glyph: u16) bool {
    return glyphKind(font, glyph) != .none;
}

pub fn glyphKind(font: opentype.Font, glyph: u16) api.ColorGlyphKind {
    if (colr_v1.hasGlyph(font, glyph)) return if (colr_v1.usesForeground(font, glyph)) .foreground else .fixed;
    if (colrLayers(font, glyph) catch null) |layers| {
        for (0..layers.count) |index| if ((u16be(layers.records, index * 4 + 2) catch 0) == 0xffff) return .foreground;
        return .fixed;
    }
    if (sbixBitmap(font, glyph, 16, 0) catch null != null) return .fixed;
    if (cbdtBitmap(font, glyph, 16) catch null != null) return .fixed;
    if (svgDocument(font, glyph) catch null != null) return .fixed;
    return .none;
}

pub fn rasterize(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    glyph: u16,
    size: f32,
    scale_factor: f32,
    foreground: geometry.Color,
) Error!api.RasterizedGlyph {
    if (!(size > 0) or size > maximum_text_size or !(scale_factor > 0) or scale_factor > maximum_scale_factor or
        !std.math.isFinite(size) or !std.math.isFinite(scale_factor)) return error.InvalidConfiguration;
    if (colr_v1.hasGlyph(font, glyph)) return colr_v1.rasterize(allocator, font, glyph, size, scale_factor, foreground);
    if (try colrLayers(font, glyph)) |layers| return rasterizeColr0(allocator, font, layers, size, scale_factor, foreground);
    const target_ppem: u16 = @intFromFloat(std.math.clamp(@round(size * scale_factor), 1, std.math.maxInt(u16)));
    if (try sbixBitmap(font, glyph, target_ppem, 0)) |bitmap| return rasterizeEmbedded(allocator, bitmap, target_ppem);
    if (try cbdtBitmap(font, glyph, target_ppem)) |bitmap| return rasterizeEmbedded(allocator, bitmap, target_ppem);
    // SVG glyph documents are exposed separately so the SVG provider can
    // paint them through the vector scene path without creating a dependency
    // cycle between the text and optional SVG modules.
    if (try svgDocument(font, glyph) != null) return error.Unsupported;
    return error.Unsupported;
}

const LayerSlice = struct {
    records: []const u8,
    count: u16,
};

fn colrLayers(font: opentype.Font, glyph: u16) Error!?LayerSlice {
    const table = font.optionalTable("COLR".*) orelse return null;
    if (table.len < 14) return error.InvalidFont;
    const version = try u16be(table, 0);
    if (version > 1) return error.InvalidFont;
    const count = try u16be(table, 2);
    const base_offset = try u32be(table, 4);
    const layer_offset = try u32be(table, 8);
    const layer_count = try u16be(table, 12);
    const base_bytes = std.math.mul(usize, @as(usize, count), 6) catch return error.InvalidFont;
    const layer_bytes = std.math.mul(usize, @as(usize, layer_count), 4) catch return error.InvalidFont;
    if (!rangeFits(table.len, base_offset, base_bytes) or
        !rangeFits(table.len, layer_offset, layer_bytes)) return error.InvalidFont;
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const middle = (low + high) / 2;
        const candidate = try u16be(table, @as(usize, base_offset) + middle * 6);
        if (candidate < glyph) low = middle + 1 else high = middle;
    }
    if (low >= count) return null;
    const record = @as(usize, base_offset) + low * 6;
    if (try u16be(table, record) != glyph) return null;
    const first = try u16be(table, record + 2);
    const layers = try u16be(table, record + 4);
    if (@as(usize, first) + @as(usize, layers) > layer_count) return error.InvalidFont;
    const start = try checkedAdd(layer_offset, try checkedMul(first, 4));
    return .{ .records = table[start..][0 .. @as(usize, layers) * 4], .count = layers };
}

fn rasterizeColr0(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    layers: LayerSlice,
    size: f32,
    scale_factor: f32,
    foreground: geometry.Color,
) Error!api.RasterizedGlyph {
    if (layers.count == 0) return error.Unsupported;
    if (layers.count > maximum_colr_layers) return error.BudgetExceeded;
    const masks = try allocator.alloc(api.RasterizedGlyph, layers.count);
    defer allocator.free(masks);
    var initialized: usize = 0;
    defer for (masks[0..initialized]) |*mask| mask.deinit(allocator);
    var left = std.math.inf(f32);
    var top = std.math.inf(f32);
    var right = -std.math.inf(f32);
    var bottom = -std.math.inf(f32);
    var live_layer_pixels: usize = 0;
    for (0..layers.count) |index| {
        const glyph = try u16be(layers.records, index * 4);
        masks[index] = try raster.rasterize(allocator, font, glyph, size, scale_factor);
        initialized += 1;
        const mask = masks[index];
        live_layer_pixels = std.math.add(usize, live_layer_pixels, mask.pixels.len) catch return error.BudgetExceeded;
        if (live_layer_pixels > maximum_live_layer_pixels) return error.BudgetExceeded;
        if (!finitePoint(mask.origin) or !finiteSize(mask.size)) return error.InvalidFont;
        left = @min(left, mask.origin.x);
        top = @min(top, mask.origin.y);
        right = @max(right, mask.origin.x + mask.size.width);
        bottom = @max(bottom, mask.origin.y + mask.size.height);
    }
    if (!std.math.isFinite(left) or !std.math.isFinite(top) or !std.math.isFinite(right) or !std.math.isFinite(bottom) or
        right <= left or bottom <= top) return emptyColor(allocator);
    const width_value = @ceil(right - left);
    const height_value = @ceil(bottom - top);
    if (!std.math.isFinite(width_value) or !std.math.isFinite(height_value)) return error.InvalidFont;
    if (width_value > maximum_raster_dimension or height_value > maximum_raster_dimension) return error.BudgetExceeded;
    const width: usize = @intFromFloat(width_value);
    const height: usize = @intFromFloat(height_value);
    const pixel_count = std.math.mul(usize, width, height) catch return error.BudgetExceeded;
    if (pixel_count > maximum_raster_pixels) return error.BudgetExceeded;
    const stride = std.math.mul(usize, width, 4) catch return error.BudgetExceeded;
    const pixels = try allocator.alloc(u8, std.math.mul(usize, stride, height) catch return error.BudgetExceeded);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    for (masks, 0..) |mask, index| {
        const palette_index = try u16be(layers.records, index * 4 + 2);
        const color = try paletteColor(font, palette_index, foreground);
        try compositeMask(pixels, stride, width, height, left, top, mask, color);
    }
    return .{
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        .origin = .{ .x = left, .y = top },
        .stride = stride,
        .pixels = pixels,
        .mode = .color,
    };
}

fn paletteColor(font: opentype.Font, index: u16, foreground: geometry.Color) Error!geometry.Color {
    if (index == 0xffff) return foreground;
    const table = font.optionalTable("CPAL".*) orelse return error.InvalidFont;
    if (table.len < 12) return error.InvalidFont;
    const entries = try u16be(table, 2);
    const palettes = try u16be(table, 4);
    const records = try u16be(table, 6);
    const records_offset = try u32be(table, 8);
    if (palettes == 0 or index >= entries) return error.InvalidFont;
    const first = try u16be(table, 12);
    const record_index = @as(usize, first) + index;
    if (record_index >= records) return error.InvalidFont;
    const offset = try checkedAdd(records_offset, try checkedMul(record_index, 4));
    if (!rangeFits(table.len, offset, 4)) return error.InvalidFont;
    return geometry.Color.rgba8(table[offset + 2], table[offset + 1], table[offset], table[offset + 3]);
}

fn compositeMask(
    target: []u8,
    target_stride: usize,
    width: usize,
    height: usize,
    left: f32,
    top: f32,
    mask: api.RasterizedGlyph,
    color: geometry.Color,
) Error!void {
    const raw_offset_x = @round(mask.origin.x - left);
    const raw_offset_y = @round(mask.origin.y - top);
    if (!std.math.isFinite(raw_offset_x) or !std.math.isFinite(raw_offset_y) or
        @abs(raw_offset_x) > maximum_raster_dimension or @abs(raw_offset_y) > maximum_raster_dimension) return error.InvalidFont;
    const offset_x: isize = @intFromFloat(raw_offset_x);
    const offset_y: isize = @intFromFloat(raw_offset_y);
    const mask_width: usize = @intFromFloat(mask.size.width);
    const mask_height: usize = @intFromFloat(mask.size.height);
    const mask_bytes = std.math.mul(usize, mask.stride, mask_height) catch return error.InvalidFont;
    if (mask.stride < mask_width or mask_bytes > mask.pixels.len) return error.InvalidFont;
    for (0..mask_height) |source_y| {
        const destination_y = offset_y + @as(isize, @intCast(source_y));
        if (destination_y < 0 or destination_y >= @as(isize, @intCast(height))) continue;
        for (0..mask_width) |source_x| {
            const destination_x = offset_x + @as(isize, @intCast(source_x));
            if (destination_x < 0 or destination_x >= @as(isize, @intCast(width))) continue;
            const coverage = mask.pixels[source_y * mask.stride + source_x];
            const source_alpha = (@as(f32, @floatFromInt(coverage)) / 255) * std.math.clamp(color.a, 0, 1);
            if (source_alpha <= 0) continue;
            const destination = @as(usize, @intCast(destination_y)) * target_stride + @as(usize, @intCast(destination_x)) * 4;
            const destination_alpha = @as(f32, @floatFromInt(target[destination + 3])) / 255;
            const inverse = 1 - source_alpha;
            const output_alpha = source_alpha + destination_alpha * inverse;
            for (0..3) |channel| {
                const source_linear = switch (channel) {
                    0 => color.r,
                    1 => color.g,
                    else => color.b,
                };
                const destination_linear = srgbToLinear(@as(f32, @floatFromInt(target[destination + channel])) / 255);
                const output_linear = if (output_alpha <= 0) 0 else (source_linear * source_alpha + destination_linear * destination_alpha * inverse) / output_alpha;
                target[destination + channel] = linearToSrgbByte(output_linear);
            }
            target[destination + 3] = @intFromFloat(@round(std.math.clamp(output_alpha, 0, 1) * 255));
        }
    }
}

fn srgbToLinear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn linearToSrgbByte(value: f32) u8 {
    const linear = std.math.clamp(value, 0, 1);
    const encoded = if (linear <= 0.0031308) linear * 12.92 else 1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255));
}

fn sbixBitmap(font: opentype.Font, glyph: u16, target_ppem: u16, depth: u8) Error!?EmbeddedBitmap {
    if (depth > 8) return error.InvalidFont;
    const table = font.optionalTable("sbix".*) orelse return null;
    if (table.len < 8) return error.InvalidFont;
    const strike_count = try u32be(table, 4);
    const strike_index_bytes = std.math.mul(usize, @as(usize, strike_count), 4) catch return error.InvalidFont;
    if (strike_count == 0 or strike_count > 4096 or !rangeFits(table.len, 8, strike_index_bytes)) return error.InvalidFont;
    const glyph_count = try font.glyphCount();
    if (glyph >= glyph_count) return null;
    const selected = try selectSbixStrike(table, strike_count, glyph_count, glyph, target_ppem) orelse return null;
    const origin_x = try i16be(table, selected.start);
    const origin_y = try i16be(table, selected.start + 2);
    const kind = table[selected.start + 4 ..][0..4];
    const payload = table[selected.start + 8 .. selected.end];
    if (std.mem.eql(u8, kind, "dupe")) {
        if (payload.len < 2) return error.InvalidFont;
        return sbixBitmap(font, try u16be(payload, 0), target_ppem, depth + 1);
    }
    return .{ .bytes = payload, .origin_x = origin_x, .origin_y = origin_y, .source_ppem = selected.ppem };
}

const SbixStrike = struct {
    start: usize,
    end: usize,
    ppem: u16,
};

fn selectSbixStrike(table: []const u8, strike_count: u32, glyph_count: u16, glyph: u16, target_ppem: u16) Error!?SbixStrike {
    var selected: ?SbixStrike = null;
    var selected_distance: u32 = std.math.maxInt(u32);
    for (0..strike_count) |strike_index| {
        const strike_offset = try u32be(table, 8 + strike_index * 4);
        const glyph_offsets_bytes = std.math.mul(usize, @as(usize, glyph_count) + 1, 4) catch continue;
        if (!rangeFits(table.len, strike_offset, 4 + glyph_offsets_bytes)) continue;
        const ppem = try u16be(table, strike_offset);
        const start = try checkedAdd(strike_offset, try u32be(table, @as(usize, strike_offset) + 4 + @as(usize, glyph) * 4));
        const end = try checkedAdd(strike_offset, try u32be(table, @as(usize, strike_offset) + 4 + (@as(usize, glyph) + 1) * 4));
        if (start == end) continue;
        if (start > end or end > table.len or end - start < 8) return error.InvalidFont;
        const kind = table[start + 4 ..][0..4];
        if (!std.mem.eql(u8, kind, "dupe") and !std.mem.eql(u8, kind, "png ") and
            !std.mem.eql(u8, kind, "jpg ") and !std.mem.eql(u8, kind, "jpeg")) continue;
        const distance: u32 = if (ppem > target_ppem) ppem - target_ppem else target_ppem - ppem;
        if (selected == null or distance < selected_distance or (distance == selected_distance and ppem > selected.?.ppem)) {
            selected = .{ .start = start, .end = end, .ppem = ppem };
            selected_distance = distance;
        }
    }
    return selected;
}

test "sbix chooses the nearest strike that actually contains the glyph" {
    var table: [60]u8 = @splat(0);
    putU32be(&table, 4, 2);
    putU32be(&table, 8, 16);
    putU32be(&table, 12, 44);

    putU16be(&table, 16, 16);
    putU32be(&table, 20, 16);
    putU32be(&table, 24, 16);
    putU32be(&table, 28, 28);
    @memcpy(table[36..40], "png ");

    putU16be(&table, 44, 48);
    putU32be(&table, 48, 16);
    putU32be(&table, 52, 16);
    putU32be(&table, 56, 16);

    const selected = (try selectSbixStrike(&table, 2, 2, 1, 48)).?;
    try std.testing.expectEqual(@as(u16, 16), selected.ppem);
    try std.testing.expectEqual(@as(usize, 32), selected.start);
    try std.testing.expectEqual(@as(usize, 44), selected.end);
}

fn putU16be(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn putU32be(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value >> 24);
    bytes[offset + 1] = @truncate(value >> 16);
    bytes[offset + 2] = @truncate(value >> 8);
    bytes[offset + 3] = @truncate(value);
}

fn cbdtBitmap(font: opentype.Font, glyph: u16, target_ppem: u16) Error!?EmbeddedBitmap {
    const location = font.optionalTable("CBLC".*) orelse font.optionalTable("EBLC".*) orelse return null;
    const data = font.optionalTable("CBDT".*) orelse font.optionalTable("EBDT".*) orelse return null;
    if (location.len < 8 or data.len < 4) return error.InvalidFont;
    const size_count = try u32be(location, 4);
    const strike_bytes = std.math.mul(usize, @as(usize, size_count), 48) catch return error.InvalidFont;
    if (size_count == 0 or size_count > 4096 or !rangeFits(location.len, 8, strike_bytes)) return error.InvalidFont;
    var selected: ?usize = null;
    var selected_distance: u32 = std.math.maxInt(u32);
    for (0..size_count) |index| {
        const strike = 8 + index * 48;
        const first = try u16be(location, strike + 40);
        const last = try u16be(location, strike + 42);
        if (glyph < first or glyph > last) continue;
        const ppem = location[strike + 45];
        const distance: u32 = if (ppem > target_ppem) ppem - target_ppem else target_ppem - ppem;
        if (selected == null or distance < selected_distance) {
            selected = strike;
            selected_distance = distance;
        }
    }
    const strike = selected orelse return null;
    const array_offset = try u32be(location, strike);
    const subtable_count = try u32be(location, strike + 8);
    const subtable_bytes = std.math.mul(usize, @as(usize, subtable_count), 8) catch return error.InvalidFont;
    if (!rangeFits(location.len, array_offset, subtable_bytes)) return error.InvalidFont;
    for (0..subtable_count) |index| {
        const record = @as(usize, array_offset) + index * 8;
        const first = try u16be(location, record);
        const last = try u16be(location, record + 2);
        if (glyph < first or glyph > last) continue;
        const subtable = try checkedAdd(array_offset, try u32be(location, record + 4));
        const span = try bitmapDataSpan(location, subtable, first, last, glyph);
        if (span.start > span.end or span.end > data.len) return error.InvalidFont;
        const format = try u16be(location, subtable + 2);
        return decodeBitmapRecord(data[span.start..span.end], format, location[strike + 45]);
    }
    return null;
}

const Span = struct { start: usize, end: usize };

fn bitmapDataSpan(table: []const u8, subtable: usize, first: u16, _: u16, glyph: u16) Error!Span {
    if (!rangeFits(table.len, subtable, 8)) return error.InvalidFont;
    const format = try u16be(table, subtable);
    const image_offset = try u32be(table, subtable + 4);
    const relative = @as(usize, glyph - first);
    return switch (format) {
        1 => .{
            .start = try checkedAdd(image_offset, try u32be(table, subtable + 8 + relative * 4)),
            .end = try checkedAdd(image_offset, try u32be(table, subtable + 8 + (relative + 1) * 4)),
        },
        2 => blk: {
            const image_size = try u32be(table, subtable + 8);
            break :blk .{
                .start = try checkedAdd(image_offset, try checkedMul(relative, image_size)),
                .end = try checkedAdd(image_offset, try checkedMul(relative + 1, image_size)),
            };
        },
        3 => .{
            .start = try checkedAdd(image_offset, try u16be(table, subtable + 8 + relative * 2)),
            .end = try checkedAdd(image_offset, try u16be(table, subtable + 8 + (relative + 1) * 2)),
        },
        4 => blk: {
            const count = try u32be(table, subtable + 8);
            var found: ?usize = null;
            for (0..count) |index| if (try u16be(table, subtable + 12 + index * 4) == glyph) {
                found = index;
                break;
            };
            const index = found orelse return error.InvalidFont;
            break :blk .{
                .start = try checkedAdd(image_offset, try u16be(table, subtable + 14 + index * 4)),
                .end = try checkedAdd(image_offset, try u16be(table, subtable + 14 + (index + 1) * 4)),
            };
        },
        5 => blk: {
            const image_size = try u32be(table, subtable + 8);
            const count = try u32be(table, subtable + 20);
            var found: ?usize = null;
            for (0..count) |index| if (try u16be(table, subtable + 24 + index * 2) == glyph) {
                found = index;
                break;
            };
            const index = found orelse return error.InvalidFont;
            break :blk .{
                .start = try checkedAdd(image_offset, try checkedMul(index, image_size)),
                .end = try checkedAdd(image_offset, try checkedMul(index + 1, image_size)),
            };
        },
        else => return error.Unsupported,
    };
}

fn decodeBitmapRecord(record: []const u8, format: u16, ppem: u16) Error!?EmbeddedBitmap {
    var origin_x: i16 = 0;
    var origin_y: i16 = 0;
    var data_offset: usize = 0;
    var data_length: usize = 0;
    switch (format) {
        17 => {
            if (record.len < 9) return error.InvalidFont;
            origin_x = @as(i8, @bitCast(record[2]));
            origin_y = @as(i8, @bitCast(record[3]));
            data_length = try u32be(record, 5);
            data_offset = 9;
        },
        18 => {
            if (record.len < 12) return error.InvalidFont;
            origin_x = @as(i8, @bitCast(record[2]));
            origin_y = @as(i8, @bitCast(record[3]));
            data_length = try u32be(record, 8);
            data_offset = 12;
        },
        19 => {
            if (record.len < 4) return error.InvalidFont;
            data_length = try u32be(record, 0);
            data_offset = 4;
        },
        else => return null,
    }
    if (data_offset > record.len or data_length > record.len - data_offset) return error.InvalidFont;
    return .{ .bytes = record[data_offset..][0..data_length], .origin_x = origin_x, .origin_y = origin_y, .source_ppem = ppem };
}

fn rasterizeEmbedded(allocator: std.mem.Allocator, bitmap: EmbeddedBitmap, target_ppem: u16) Error!api.RasterizedGlyph {
    var decoded = image.decode(allocator, bitmap.bytes, .{
        .maximum_width = 8192,
        .maximum_height = 8192,
        .maximum_pixels = maximum_raster_pixels,
        .maximum_compressed_bytes = 64 * 1024 * 1024,
    }) catch return error.InvalidFont;
    defer decoded.deinit(allocator);
    const ratio = @as(f32, @floatFromInt(target_ppem)) / @as(f32, @floatFromInt(@max(bitmap.source_ppem, 1)));
    const width_value = @round(@as(f32, @floatFromInt(decoded.width)) * ratio);
    const height_value = @round(@as(f32, @floatFromInt(decoded.height)) * ratio);
    if (!std.math.isFinite(ratio) or !std.math.isFinite(width_value) or !std.math.isFinite(height_value)) return error.InvalidFont;
    if (width_value > maximum_raster_dimension or height_value > maximum_raster_dimension) return error.BudgetExceeded;
    const width: usize = @max(1, @as(usize, @intFromFloat(width_value)));
    const height: usize = @max(1, @as(usize, @intFromFloat(height_value)));
    const pixel_count = std.math.mul(usize, width, height) catch return error.BudgetExceeded;
    if (pixel_count > maximum_raster_pixels) return error.BudgetExceeded;
    const stride = std.math.mul(usize, width, 4) catch return error.BudgetExceeded;
    const pixels = try allocator.alloc(u8, std.math.mul(usize, stride, height) catch return error.BudgetExceeded);
    errdefer allocator.free(pixels);
    if (width == decoded.width and height == decoded.height) {
        for (0..height) |row| @memcpy(pixels[row * stride ..][0..stride], decoded.pixels[row * decoded.stride ..][0..stride]);
    } else {
        resampleRgba(decoded.pixels, decoded.width, decoded.height, decoded.stride, pixels, width, height, stride);
    }
    return .{
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        .origin = .{
            .x = @as(f32, @floatFromInt(bitmap.origin_x)) * ratio,
            .y = -(@as(f32, @floatFromInt(bitmap.origin_y)) * ratio + @as(f32, @floatFromInt(height))),
        },
        .stride = stride,
        .pixels = pixels,
        .mode = .color,
    };
}

fn finitePoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}

fn finiteSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and
        value.width >= 0 and value.height >= 0 and
        @trunc(value.width) == value.width and @trunc(value.height) == value.height and
        value.width <= maximum_raster_dimension and value.height <= maximum_raster_dimension;
}

fn resampleRgba(source: []const u8, source_width: usize, source_height: usize, source_stride: usize, target: []u8, width: usize, height: usize, stride: usize) void {
    for (0..height) |y| {
        const source_y = (@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(source_height)) / @as(f32, @floatFromInt(height)) - 0.5;
        const y0: usize = @intFromFloat(@floor(std.math.clamp(source_y, 0, @as(f32, @floatFromInt(source_height - 1)))));
        const y1 = @min(y0 + 1, source_height - 1);
        const fy = std.math.clamp(source_y - @as(f32, @floatFromInt(y0)), 0, 1);
        for (0..width) |x| {
            const source_x = (@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(source_width)) / @as(f32, @floatFromInt(width)) - 0.5;
            const x0: usize = @intFromFloat(@floor(std.math.clamp(source_x, 0, @as(f32, @floatFromInt(source_width - 1)))));
            const x1 = @min(x0 + 1, source_width - 1);
            const fx = std.math.clamp(source_x - @as(f32, @floatFromInt(x0)), 0, 1);
            for (0..4) |channel| {
                const a = @as(f32, @floatFromInt(source[y0 * source_stride + x0 * 4 + channel]));
                const b = @as(f32, @floatFromInt(source[y0 * source_stride + x1 * 4 + channel]));
                const c = @as(f32, @floatFromInt(source[y1 * source_stride + x0 * 4 + channel]));
                const d = @as(f32, @floatFromInt(source[y1 * source_stride + x1 * 4 + channel]));
                target[y * stride + x * 4 + channel] = @intFromFloat(@round((a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy));
            }
        }
    }
}

pub const SvgGlyph = struct { document: []const u8, start_glyph: u16, end_glyph: u16 };

pub fn svgDocument(font: opentype.Font, glyph: u16) Error!?SvgGlyph {
    const table = font.optionalTable("SVG ".*) orelse return null;
    if (table.len < 10) return error.InvalidFont;
    const index_offset = try u32be(table, 2);
    if (!rangeFits(table.len, index_offset, 2)) return error.InvalidFont;
    const count = try u16be(table, index_offset);
    const records_bytes = std.math.mul(usize, @as(usize, count), 12) catch return error.InvalidFont;
    if (!rangeFits(table.len, index_offset, 2 + records_bytes)) return error.InvalidFont;
    for (0..count) |index| {
        const record = @as(usize, index_offset) + 2 + index * 12;
        const start = try u16be(table, record);
        const end = try u16be(table, record + 2);
        if (glyph < start or glyph > end) continue;
        const offset = try u32be(table, record + 4);
        const length = try u32be(table, record + 8);
        if (!rangeFits(table.len, offset, length)) return error.InvalidFont;
        return .{ .document = table[offset..][0..length], .start_glyph = start, .end_glyph = end };
    }
    return null;
}

fn emptyColor(allocator: std.mem.Allocator) Error!api.RasterizedGlyph {
    return .{ .size = .zero, .origin = .{}, .stride = 0, .pixels = try allocator.alloc(u8, 0), .mode = .color };
}

fn rangeFits(total: usize, offset: anytype, length: anytype) bool {
    const start: usize = @intCast(offset);
    const count: usize = @intCast(length);
    return start <= total and count <= total - start;
}

fn checkedAdd(left: anytype, right: anytype) Error!usize {
    return std.math.add(usize, @as(usize, @intCast(left)), @as(usize, @intCast(right))) catch return error.InvalidFont;
}

fn checkedMul(left: anytype, right: anytype) Error!usize {
    return std.math.mul(usize, @as(usize, @intCast(left)), @as(usize, @intCast(right))) catch return error.InvalidFont;
}

fn u16be(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return error.InvalidFont;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn i16be(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try u16be(bytes, offset));
}

fn u32be(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.InvalidFont;
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}
