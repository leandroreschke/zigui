//! OpenType variation primitives implemented in-tree.
//!
//! Coordinates are retained as F2DOT14 values after the required `fvar`
//! normalization and optional `avar` remapping.  This keeps instance identity
//! deterministic and gives all consumers (`gvar`, HVAR, MVAR, GDEF, COLR and
//! CFF2) one coordinate representation.

const std = @import("std");
const Error = @import("../core/error.zig").Error;
const outline = @import("font_outline.zig");
const api = @import("api.zig");

pub const maximum_axes = 64;

pub const Setting = api.FontVariation;

pub const DeltaSetIndex = struct {
    outer: u16,
    inner: u16,
};

pub const GlyphKind = enum { simple, composite };

pub fn axisCount(fvar: []const u8) Error!u16 {
    if (fvar.len < 16 or try u16be(fvar, 0) != 1 or try u16be(fvar, 2) != 0 or try u16be(fvar, 6) != 2) return error.InvalidFont;
    const axes_offset = try u16be(fvar, 4);
    const count = try u16be(fvar, 8);
    const size = try u16be(fvar, 10);
    if (count == 0) return 0;
    if (axes_offset < 16 or count > maximum_axes or size < 20) return error.InvalidFont;
    const bytes = std.math.mul(usize, count, size) catch return error.InvalidFont;
    if (axes_offset > fvar.len or bytes > fvar.len - axes_offset) return error.InvalidFont;
    return count;
}

pub fn hasAxis(fvar: []const u8, tag: [4]u8) bool {
    const count = axisCount(fvar) catch return false;
    if (count == 0) return false;
    const axes_offset = u16be(fvar, 4) catch return false;
    const size = u16be(fvar, 10) catch return false;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const record = @as(usize, axes_offset) + index * size;
        if (std.mem.eql(u8, fvar[record..][0..4], &tag)) return true;
    }
    return false;
}

/// Normalize user-space settings in the axis order declared by `fvar`.
/// Unspecified axes use the font's default coordinate; duplicate settings use
/// the final value so application overrides can follow semantic defaults.
pub fn normalize(
    allocator: std.mem.Allocator,
    fvar: []const u8,
    avar: ?[]const u8,
    settings: []const Setting,
) Error![]i16 {
    const count = try axisCount(fvar);
    const result = try allocator.alloc(i16, count);
    errdefer allocator.free(result);
    const axes_offset = try u16be(fvar, 4);
    const axis_size = try u16be(fvar, 10);
    var axis: usize = 0;
    while (axis < count) : (axis += 1) {
        const record = @as(usize, axes_offset) + axis * axis_size;
        const tag: [4]u8 = fvar[record..][0..4].*;
        if (try u16be(fvar, record + 16) & ~@as(u16, 1) != 0) return error.InvalidFont;
        var earlier: usize = 0;
        while (earlier < axis) : (earlier += 1) {
            const earlier_record = @as(usize, axes_offset) + earlier * axis_size;
            if (std.mem.eql(u8, fvar[earlier_record..][0..4], &tag)) return error.InvalidFont;
        }
        const minimum = try i32be(fvar, record + 4);
        const default = try i32be(fvar, record + 8);
        const maximum = try i32be(fvar, record + 12);
        if (minimum > default or default > maximum) return error.InvalidFont;
        var selected = default;
        for (settings) |setting| {
            if (!std.mem.eql(u8, &setting.tag, &tag)) continue;
            selected = try floatToFixed(setting.value);
        }
        selected = std.math.clamp(selected, minimum, maximum);
        result[axis] = normalizeAxis(selected, minimum, default, maximum);
    }
    if (avar) |table| try remapAvar(table, result);
    return result;
}

pub fn coordinatesEqual(a: []const i16, b: []const i16) bool {
    return std.mem.eql(i16, a, b);
}

pub fn allDefault(coordinates: []const i16) bool {
    for (coordinates) |coordinate| if (coordinate != 0) return false;
    return true;
}

pub fn coordinateFloat(value: i16) f32 {
    return @as(f32, @floatFromInt(value)) / 16384.0;
}

/// Resolve one row in an OpenType ItemVariationStore. The caller supplies the
/// store slice beginning at its format field and an already-normalized instance.
pub fn itemDelta(
    store: []const u8,
    coordinates: []const i16,
    index: DeltaSetIndex,
) Error!f32 {
    if (index.outer == 0xffff and index.inner == 0xffff) return 0;
    if (store.len < 8 or try u16be(store, 0) != 1) return error.InvalidFont;
    const region_list_offset = try u32be(store, 2);
    const data_count = try u16be(store, 6);
    if (index.outer >= data_count) return 0;
    const offsets_end = 8 + @as(usize, data_count) * 4;
    if (offsets_end > store.len) return error.InvalidFont;
    const data_offset = try u32be(store, 8 + @as(usize, index.outer) * 4);
    if (data_offset == 0) return 0;
    if (data_offset > store.len or region_list_offset > store.len) return error.InvalidFont;
    const regions = store[region_list_offset..];
    if (regions.len < 4) return error.InvalidFont;
    const axis_count = try u16be(regions, 0);
    const region_count = try u16be(regions, 2);
    if (axis_count != coordinates.len or axis_count > maximum_axes or region_count & 0x8000 != 0) return error.InvalidFont;
    const region_bytes = std.math.mul(usize, @as(usize, axis_count) * 6, region_count) catch return error.InvalidFont;
    if (4 + region_bytes > regions.len) return error.InvalidFont;

    const data = store[data_offset..];
    if (data.len < 6) return error.InvalidFont;
    const item_count = try u16be(data, 0);
    if (index.inner >= item_count) return 0;
    const packed_word_count = try u16be(data, 2);
    const long_words = packed_word_count & 0x8000 != 0;
    const word_count = packed_word_count & 0x7fff;
    const used_region_count = try u16be(data, 4);
    if (word_count > used_region_count) return error.InvalidFont;
    const indexes_end = 6 + @as(usize, used_region_count) * 2;
    if (indexes_end > data.len) return error.InvalidFont;
    const row_size = if (long_words)
        @as(usize, used_region_count) * 2 + @as(usize, word_count) * 2
    else
        @as(usize, used_region_count) + @as(usize, word_count);
    const row_offset = std.math.add(usize, indexes_end, std.math.mul(usize, index.inner, row_size) catch return error.InvalidFont) catch return error.InvalidFont;
    if (row_offset > data.len or row_size > data.len - row_offset) return error.InvalidFont;

    var result: f32 = 0;
    var delta_cursor = row_offset;
    var column: usize = 0;
    while (column < used_region_count) : (column += 1) {
        const region_index = try u16be(data, 6 + column * 2);
        if (region_index >= region_count) return error.InvalidFont;
        const delta: i32 = if (long_words) blk: {
            if (column < word_count) {
                const value = try i32be(data, delta_cursor);
                delta_cursor += 4;
                break :blk value;
            }
            const value = try i16be(data, delta_cursor);
            delta_cursor += 2;
            break :blk value;
        } else blk: {
            if (column < word_count) {
                const value = try i16be(data, delta_cursor);
                delta_cursor += 2;
                break :blk value;
            }
            if (delta_cursor >= data.len) return error.InvalidFont;
            const value: i8 = @bitCast(data[delta_cursor]);
            delta_cursor += 1;
            break :blk value;
        };
        const region_offset = 4 + @as(usize, region_index) * @as(usize, axis_count) * 6;
        const scalar = try regionScalar(regions[region_offset..], coordinates);
        result += @as(f32, @floatFromInt(delta)) * scalar;
    }
    return result;
}

/// Return the region scalars selected by one ItemVariationData subtable. CFF2
/// uses this view because its delta values live in CharStrings rather than in
/// the ItemVariationStore rows.
pub fn dataRegionScalars(
    allocator: std.mem.Allocator,
    store: []const u8,
    coordinates: []const i16,
    outer: u16,
) Error![]f32 {
    if (store.len < 8 or try u16be(store, 0) != 1) return error.InvalidFont;
    const region_list_offset = try u32be(store, 2);
    const data_count = try u16be(store, 6);
    if (outer >= data_count) return error.InvalidFont;
    if (8 + @as(usize, data_count) * 4 > store.len or region_list_offset > store.len) return error.InvalidFont;
    const data_offset = try u32be(store, 8 + @as(usize, outer) * 4);
    if (data_offset == 0 or data_offset > store.len) return error.InvalidFont;
    const regions = store[region_list_offset..];
    if (regions.len < 4) return error.InvalidFont;
    const axis_count = try u16be(regions, 0);
    const region_count = try u16be(regions, 2);
    if (axis_count != coordinates.len or axis_count > maximum_axes or region_count & 0x8000 != 0) return error.InvalidFont;
    const regions_length = std.math.mul(usize, @as(usize, axis_count) * 6, region_count) catch return error.InvalidFont;
    if (4 + regions_length > regions.len) return error.InvalidFont;
    const data = store[data_offset..];
    if (data.len < 6) return error.InvalidFont;
    if (try u16be(data, 0) != 0 or try u16be(data, 2) != 0) return error.InvalidFont;
    const selected_count = try u16be(data, 4);
    if (6 + @as(usize, selected_count) * 2 > data.len) return error.InvalidFont;
    const result = try allocator.alloc(f32, selected_count);
    errdefer allocator.free(result);
    for (result, 0..) |*scalar, index| {
        const region_index = try u16be(data, 6 + index * 2);
        if (region_index >= region_count) return error.InvalidFont;
        scalar.* = try regionScalar(regions[4 + @as(usize, region_index) * @as(usize, axis_count) * 6 ..], coordinates);
    }
    return result;
}

pub fn deltaSetIndex(map: []const u8, item: u32) Error!DeltaSetIndex {
    if (map.len < 4) return error.InvalidFont;
    const format = map[0];
    const entry_format = map[1];
    if (entry_format & 0xc0 != 0) return error.InvalidFont;
    const count: u32 = switch (format) {
        0 => try u16be(map, 2),
        1 => try u32be(map, 2),
        else => return error.InvalidFont,
    };
    if (count == 0) return error.InvalidFont;
    const header_size: usize = if (format == 0) 4 else 6;
    const entry_size: usize = ((entry_format & 0x30) >> 4) + 1;
    const selected = @min(item, count - 1);
    const offset = std.math.add(usize, header_size, std.math.mul(usize, selected, entry_size) catch return error.InvalidFont) catch return error.InvalidFont;
    if (offset > map.len or entry_size > map.len - offset) return error.InvalidFont;
    var packed_index: u32 = 0;
    for (map[offset..][0..entry_size]) |byte| packed_index = (packed_index << 8) | byte;
    const inner_bits: u5 = @intCast((entry_format & 0x0f) + 1);
    const inner_mask: u32 = (@as(u32, 1) << inner_bits) - 1;
    const outer = packed_index >> inner_bits;
    if (outer > std.math.maxInt(u16)) return error.InvalidFont;
    return .{ .outer = @intCast(outer), .inner = @intCast(packed_index & inner_mask) };
}

pub fn hvarAdvanceDelta(hvar: []const u8, coordinates: []const i16, glyph: u16) Error!f32 {
    if (hvar.len < 20 or try u16be(hvar, 0) != 1 or try u16be(hvar, 2) != 0) return error.InvalidFont;
    const store_offset = try u32be(hvar, 4);
    if (store_offset == 0 or store_offset > hvar.len) return error.InvalidFont;
    const map_offset = try u32be(hvar, 8);
    const index: DeltaSetIndex = if (map_offset == 0)
        .{ .outer = 0, .inner = glyph }
    else blk: {
        if (map_offset > hvar.len) return error.InvalidFont;
        break :blk try deltaSetIndex(hvar[map_offset..], glyph);
    };
    return itemDelta(hvar[store_offset..], coordinates, index);
}

pub fn hvarLeftBearingDelta(hvar: []const u8, coordinates: []const i16, glyph: u16) Error!f32 {
    if (hvar.len < 20 or try u16be(hvar, 0) != 1 or try u16be(hvar, 2) != 0) return error.InvalidFont;
    const store_offset = try u32be(hvar, 4);
    const map_offset = try u32be(hvar, 12);
    if (store_offset == 0 or store_offset > hvar.len or map_offset == 0) return 0;
    if (map_offset > hvar.len) return error.InvalidFont;
    return itemDelta(hvar[store_offset..], coordinates, try deltaSetIndex(hvar[map_offset..], glyph));
}

/// Apply `gvar` deltas to simple-glyph points or composite component offsets.
/// Four phantom points are included while decoding as required by the table,
/// but only the caller-supplied points are mutated.
pub fn applyGvar(
    allocator: std.mem.Allocator,
    gvar: []const u8,
    coordinates: []const i16,
    glyph: u16,
    kind: GlyphKind,
    points: []outline.Point,
    contour_ends: []const u32,
    phantom_output: ?*[4]outline.Point,
) Error!void {
    if (phantom_output) |output| output.* = @splat(.{ .x = 0, .y = 0, .on_curve = true });
    if (coordinates.len == 0 or allDefault(coordinates)) return;
    if (gvar.len < 20 or try u16be(gvar, 0) != 1 or try u16be(gvar, 2) != 0) return error.InvalidFont;
    const axis_count = try u16be(gvar, 4);
    const shared_count = try u16be(gvar, 6);
    const shared_offset = try u32be(gvar, 8);
    const glyph_count = try u16be(gvar, 12);
    const flags = try u16be(gvar, 14);
    const data_array_offset = try u32be(gvar, 16);
    if (axis_count != coordinates.len or axis_count > maximum_axes or glyph >= glyph_count or flags & ~@as(u16, 1) != 0) return error.InvalidFont;
    const long_offsets = flags & 1 != 0;
    const offset_size: usize = if (long_offsets) 4 else 2;
    const offsets_bytes = std.math.mul(usize, @as(usize, glyph_count) + 1, offset_size) catch return error.InvalidFont;
    if (20 + offsets_bytes > gvar.len or shared_offset > gvar.len or data_array_offset > gvar.len) return error.InvalidFont;
    const first_relative: usize = if (long_offsets)
        try u32be(gvar, 20 + @as(usize, glyph) * 4)
    else
        @as(usize, try u16be(gvar, 20 + @as(usize, glyph) * 2)) * 2;
    const last_relative: usize = if (long_offsets)
        try u32be(gvar, 20 + (@as(usize, glyph) + 1) * 4)
    else
        @as(usize, try u16be(gvar, 20 + (@as(usize, glyph) + 1) * 2)) * 2;
    if (first_relative == last_relative) return;
    if (first_relative > last_relative or first_relative > gvar.len - data_array_offset or last_relative > gvar.len - data_array_offset) return error.InvalidFont;
    const glyph_data = gvar[data_array_offset + first_relative .. data_array_offset + last_relative];
    if (glyph_data.len < 4) return error.InvalidFont;

    const target_count = std.math.add(usize, points.len, 4) catch return error.InvalidFont;
    const base_x = try allocator.alloc(f32, target_count);
    defer allocator.free(base_x);
    const base_y = try allocator.alloc(f32, target_count);
    defer allocator.free(base_y);
    for (points, 0..) |point, index| {
        base_x[index] = point.x;
        base_y[index] = point.y;
    }
    @memset(base_x[points.len..], 0);
    @memset(base_y[points.len..], 0);
    const net_x = try allocator.alloc(f32, target_count);
    defer allocator.free(net_x);
    const net_y = try allocator.alloc(f32, target_count);
    defer allocator.free(net_y);
    @memset(net_x, 0);
    @memset(net_y, 0);

    const packed_count = try u16be(glyph_data, 0);
    const tuple_count = packed_count & 0x0fff;
    if (packed_count & 0x7000 != 0) return error.InvalidFont;
    if (tuple_count == 0) return;
    const serialized_offset = try u16be(glyph_data, 2);
    if (serialized_offset > glyph_data.len) return error.InvalidFont;
    var serialized_cursor: usize = serialized_offset;
    var shared_points: ?[]u16 = null;
    defer if (shared_points) |value| allocator.free(value);
    if (packed_count & 0x8000 != 0)
        shared_points = try readPackedPoints(allocator, glyph_data, &serialized_cursor, target_count);

    var header_cursor: usize = 4;
    var tuple_index: usize = 0;
    while (tuple_index < tuple_count) : (tuple_index += 1) {
        const data_size = try u16be(glyph_data, header_cursor);
        const tuple_flags = try u16be(glyph_data, header_cursor + 2);
        if (tuple_flags & 0x1000 != 0) return error.InvalidFont;
        header_cursor += 4;
        var peak: [maximum_axes]i16 = @splat(0);
        var start: [maximum_axes]i16 = @splat(0);
        var end: [maximum_axes]i16 = @splat(0);
        if (tuple_flags & 0x8000 != 0) {
            try readTuple(glyph_data, &header_cursor, peak[0..axis_count]);
        } else {
            const selected = tuple_flags & 0x0fff;
            if (selected >= shared_count) return error.InvalidFont;
            const tuple_offset = std.math.add(usize, shared_offset, std.math.mul(usize, selected, @as(usize, axis_count) * 2) catch return error.InvalidFont) catch return error.InvalidFont;
            var cursor = tuple_offset;
            try readTuple(gvar, &cursor, peak[0..axis_count]);
        }
        if (tuple_flags & 0x4000 != 0) {
            try readTuple(glyph_data, &header_cursor, start[0..axis_count]);
            try readTuple(glyph_data, &header_cursor, end[0..axis_count]);
        } else {
            for (peak[0..axis_count], 0..) |value, axis| {
                start[axis] = @min(value, 0);
                end[axis] = @max(value, 0);
            }
        }
        if (header_cursor > serialized_offset) return error.InvalidFont;
        if (serialized_cursor > glyph_data.len or data_size > glyph_data.len - serialized_cursor) return error.InvalidFont;
        const tuple_data = glyph_data[serialized_cursor..][0..data_size];
        serialized_cursor += data_size;
        const scalar = scalarForTuples(coordinates, start[0..axis_count], peak[0..axis_count], end[0..axis_count]);
        if (scalar == 0) continue;

        var tuple_cursor: usize = 0;
        var private_points: ?[]u16 = null;
        defer if (private_points) |value| allocator.free(value);
        const selected_points: ?[]const u16 = if (tuple_flags & 0x2000 != 0) blk: {
            private_points = try readPackedPoints(allocator, tuple_data, &tuple_cursor, target_count);
            break :blk private_points;
        } else shared_points;
        const delta_count = if (selected_points) |selected| selected.len else target_count;
        const packed_x = try allocator.alloc(i32, delta_count);
        defer allocator.free(packed_x);
        const packed_y = try allocator.alloc(i32, delta_count);
        defer allocator.free(packed_y);
        try readPackedDeltas(tuple_data, &tuple_cursor, packed_x);
        try readPackedDeltas(tuple_data, &tuple_cursor, packed_y);
        if (tuple_cursor > tuple_data.len) return error.InvalidFont;

        const tuple_x = try allocator.alloc(f32, target_count);
        defer allocator.free(tuple_x);
        const tuple_y = try allocator.alloc(f32, target_count);
        defer allocator.free(tuple_y);
        const explicit = try allocator.alloc(bool, target_count);
        defer allocator.free(explicit);
        @memset(tuple_x, 0);
        @memset(tuple_y, 0);
        @memset(explicit, false);
        if (selected_points) |selected| {
            for (selected, 0..) |point_index, delta_index| {
                if (point_index >= target_count) return error.InvalidFont;
                tuple_x[point_index] += @floatFromInt(packed_x[delta_index]);
                tuple_y[point_index] += @floatFromInt(packed_y[delta_index]);
                explicit[point_index] = true;
            }
        } else {
            for (0..target_count) |point_index| {
                tuple_x[point_index] = @floatFromInt(packed_x[point_index]);
                tuple_y[point_index] = @floatFromInt(packed_y[point_index]);
                explicit[point_index] = true;
            }
        }
        if (kind == .simple) {
            try inferContourDeltas(base_x, tuple_x, explicit, contour_ends, points.len);
            try inferContourDeltas(base_y, tuple_y, explicit, contour_ends, points.len);
        }
        for (0..target_count) |point_index| {
            net_x[point_index] += tuple_x[point_index] * scalar;
            net_y[point_index] += tuple_y[point_index] * scalar;
        }
    }
    for (points, 0..) |*point, index| {
        point.x += net_x[index];
        point.y += net_y[index];
    }
    if (phantom_output) |output| for (output, 0..) |*point, index| {
        point.* = .{
            .x = net_x[points.len + index],
            .y = net_y[points.len + index],
            .on_curve = true,
        };
    };
}

fn remapAvar(avar: []const u8, coordinates: []i16) Error!void {
    if (avar.len < 8) return error.InvalidFont;
    if (try u16be(avar, 0) != 1 or try u16be(avar, 2) != 0) return error.InvalidFont;
    if (try u16be(avar, 4) != 0 or try u16be(avar, 6) != coordinates.len) return error.InvalidFont;
    var cursor: usize = 8;
    for (coordinates) |*coordinate| {
        const pair_count = try u16be(avar, cursor);
        cursor += 2;
        var previous_from: ?i16 = null;
        var previous_to: i16 = 0;
        var mapped: ?i16 = null;
        var has_negative_anchor = false;
        var has_zero_anchor = false;
        var has_positive_anchor = false;
        var pair: usize = 0;
        while (pair < pair_count) : (pair += 1) {
            const from = try i16be(avar, cursor);
            const to = try i16be(avar, cursor + 2);
            cursor += 4;
            if (previous_from) |previous| if (from <= previous or to < previous_to) continue;
            has_negative_anchor = has_negative_anchor or (from == -16384 and to == -16384);
            has_zero_anchor = has_zero_anchor or (from == 0 and to == 0);
            has_positive_anchor = has_positive_anchor or (from == 16384 and to == 16384);
            if (mapped == null and coordinate.* <= from) {
                mapped = if (previous_from) |previous|
                    interpolateF2Dot14(coordinate.*, previous, from, previous_to, to)
                else
                    to;
            }
            previous_from = from;
            previous_to = to;
        }
        if (has_negative_anchor and has_zero_anchor and has_positive_anchor)
            coordinate.* = mapped orelse previous_to;
    }
}

fn normalizeAxis(value: i32, minimum: i32, default: i32, maximum: i32) i16 {
    if (value == default) return 0;
    const numerator = @as(i64, value) - @as(i64, default);
    const denominator = if (value < default)
        @as(i64, default) - @as(i64, minimum)
    else
        @as(i64, maximum) - @as(i64, default);
    if (denominator == 0) return 0;
    const scaled = numerator * 16384;
    var rounded = @divTrunc(scaled, denominator);
    const remainder = @rem(scaled, denominator);
    if (@abs(remainder) * 2 >= denominator) rounded += if (scaled < 0) -1 else 1;
    return @intCast(std.math.clamp(rounded, -16384, 16384));
}

fn floatToFixed(value: f32) Error!i32 {
    if (!std.math.isFinite(value)) return error.InvalidConfiguration;
    const scaled = @as(f64, value) * 65536.0;
    const rounded = @round(scaled);
    return @intFromFloat(std.math.clamp(rounded, @as(f64, @floatFromInt(std.math.minInt(i32))), @as(f64, @floatFromInt(std.math.maxInt(i32)))));
}

fn interpolateF2Dot14(value: i16, from_a: i16, from_b: i16, to_a: i16, to_b: i16) i16 {
    if (from_a == from_b) return to_a;
    const numerator = (@as(i64, value) - @as(i64, from_a)) * (@as(i64, to_b) - @as(i64, to_a));
    const mapped = @as(i64, to_a) + @divTrunc(numerator, @as(i64, from_b) - @as(i64, from_a));
    return @intCast(std.math.clamp(mapped, -16384, 16384));
}

fn regionScalar(bytes: []const u8, coordinates: []const i16) Error!f32 {
    if (bytes.len < coordinates.len * 6) return error.InvalidFont;
    var result: f32 = 1;
    for (coordinates, 0..) |coordinate, axis| {
        const start = try i16be(bytes, axis * 6);
        const peak = try i16be(bytes, axis * 6 + 2);
        const end = try i16be(bytes, axis * 6 + 4);
        if (start < -16384 or start > 16384 or peak < -16384 or peak > 16384 or end < -16384 or end > 16384 or start > peak or peak > end or (start < 0 and end > 0 and peak != 0)) return error.InvalidFont;
        result *= axisScalar(coordinate, start, peak, end);
        if (result == 0) break;
    }
    return result;
}

fn scalarForTuples(coordinates: []const i16, start: []const i16, peak: []const i16, end: []const i16) f32 {
    if (coordinates.len != start.len or coordinates.len != peak.len or coordinates.len != end.len) return 0;
    var result: f32 = 1;
    for (coordinates, start, peak, end) |coordinate, first, maximum, last| {
        result *= axisScalar(coordinate, first, maximum, last);
        if (result == 0) break;
    }
    return result;
}

fn axisScalar(coordinate: i16, start: i16, peak: i16, end: i16) f32 {
    if (start > peak or peak > end or (start < 0 and end > 0 and peak != 0) or peak == 0) return 1;
    if (coordinate < start or coordinate > end) return 0;
    if (coordinate == peak) return 1;
    if (coordinate < peak) {
        if (peak == start) return 0;
        return @as(f32, @floatFromInt(@as(i32, coordinate) - @as(i32, start))) /
            @as(f32, @floatFromInt(@as(i32, peak) - @as(i32, start)));
    }
    if (end == peak) return 0;
    return @as(f32, @floatFromInt(@as(i32, end) - @as(i32, coordinate))) /
        @as(f32, @floatFromInt(@as(i32, end) - @as(i32, peak)));
}

fn readTuple(bytes: []const u8, cursor: *usize, output: []i16) Error!void {
    for (output) |*value| {
        value.* = try i16be(bytes, cursor.*);
        if (value.* < -16384 or value.* > 16384) return error.InvalidFont;
        cursor.* += 2;
    }
}

fn readPackedPoints(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    cursor: *usize,
    maximum: usize,
) Error!?[]u16 {
    if (cursor.* >= bytes.len) return error.InvalidFont;
    const first = bytes[cursor.*];
    cursor.* += 1;
    if (first == 0) return null;
    const count: usize = if (first & 0x80 == 0)
        first
    else blk: {
        if (cursor.* >= bytes.len) return error.InvalidFont;
        const value = (@as(u16, first & 0x7f) << 8) | bytes[cursor.*];
        cursor.* += 1;
        break :blk value;
    };
    if (count == 0 or count > maximum) return error.InvalidFont;
    const result = try allocator.alloc(u16, count);
    errdefer allocator.free(result);
    var produced: usize = 0;
    var previous: u32 = 0;
    while (produced < count) {
        if (cursor.* >= bytes.len) return error.InvalidFont;
        const control = bytes[cursor.*];
        cursor.* += 1;
        const run_count: usize = @as(usize, control & 0x7f) + 1;
        if (run_count > count - produced) return error.InvalidFont;
        var run: usize = 0;
        while (run < run_count) : (run += 1) {
            const delta: u16 = if (control & 0x80 != 0) blk: {
                const value = try u16be(bytes, cursor.*);
                cursor.* += 2;
                break :blk value;
            } else blk: {
                if (cursor.* >= bytes.len) return error.InvalidFont;
                const value = bytes[cursor.*];
                cursor.* += 1;
                break :blk value;
            };
            previous = std.math.add(u32, previous, delta) catch return error.InvalidFont;
            if (previous >= maximum or previous > std.math.maxInt(u16)) return error.InvalidFont;
            result[produced] = @intCast(previous);
            produced += 1;
        }
    }
    return result;
}

fn readPackedDeltas(bytes: []const u8, cursor: *usize, output: []i32) Error!void {
    var produced: usize = 0;
    while (produced < output.len) {
        if (cursor.* >= bytes.len) return error.InvalidFont;
        const control = bytes[cursor.*];
        cursor.* += 1;
        const run_count: usize = @as(usize, control & 0x3f) + 1;
        if (run_count > output.len - produced or control & 0xc0 == 0xc0) return error.InvalidFont;
        if (control & 0x80 != 0) {
            @memset(output[produced..][0..run_count], 0);
            produced += run_count;
            continue;
        }
        var run: usize = 0;
        while (run < run_count) : (run += 1) {
            if (control & 0x40 != 0) {
                output[produced] = try i16be(bytes, cursor.*);
                cursor.* += 2;
            } else {
                if (cursor.* >= bytes.len) return error.InvalidFont;
                output[produced] = @as(i8, @bitCast(bytes[cursor.*]));
                cursor.* += 1;
            }
            produced += 1;
        }
    }
}

fn inferContourDeltas(
    base: []const f32,
    deltas: []f32,
    explicit: []const bool,
    contour_ends: []const u32,
    outline_point_count: usize,
) Error!void {
    if (base.len != deltas.len or base.len != explicit.len or outline_point_count > base.len) return error.InvalidFont;
    var contour_start: usize = 0;
    for (contour_ends) |end_u32| {
        const contour_end: usize = end_u32;
        if (contour_end < contour_start or contour_end >= outline_point_count) return error.InvalidFont;
        var first: ?usize = null;
        var explicit_count: usize = 0;
        for (contour_start..contour_end + 1) |index| if (explicit[index]) {
            if (first == null) first = index;
            explicit_count += 1;
        };
        if (explicit_count == 1) {
            for (contour_start..contour_end + 1) |index| {
                if (!explicit[index]) deltas[index] = deltas[first.?];
            }
        } else if (explicit_count > 1) {
            var preceding = first.?;
            while (true) {
                var following = if (preceding == contour_end) contour_start else preceding + 1;
                while (!explicit[following]) following = if (following == contour_end) contour_start else following + 1;
                var target = if (preceding == contour_end) contour_start else preceding + 1;
                while (target != following) {
                    deltas[target] = inferDelta(base[target], base[preceding], base[following], deltas[preceding], deltas[following]);
                    target = if (target == contour_end) contour_start else target + 1;
                }
                preceding = following;
                if (preceding == first.?) break;
            }
        }
        contour_start = contour_end + 1;
    }
    if (contour_start != outline_point_count) return error.InvalidFont;
}

fn inferDelta(value: f32, first_value: f32, second_value: f32, first_delta: f32, second_delta: f32) f32 {
    if (first_value == second_value) return if (first_delta == second_delta) first_delta else 0;
    if (value <= @min(first_value, second_value)) return if (first_value < second_value) first_delta else second_delta;
    if (value >= @max(first_value, second_value)) return if (first_value > second_value) first_delta else second_delta;
    return first_delta + (value - first_value) * (second_delta - first_delta) / (second_value - first_value);
}

fn u16be(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or 2 > bytes.len - offset) return error.InvalidFont;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn i16be(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try u16be(bytes, offset));
}

fn u32be(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or 4 > bytes.len - offset) return error.InvalidFont;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

fn i32be(bytes: []const u8, offset: usize) Error!i32 {
    return @bitCast(try u32be(bytes, offset));
}
