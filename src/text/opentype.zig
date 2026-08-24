const std = @import("std");
const Error = @import("../core/error.zig").Error;
const font_outline = @import("font_outline.zig");
const cff = @import("cff.zig");
const variation = @import("opentype_variation.zig");

pub const Tag = [4]u8;

pub const Bounds = font_outline.Bounds;

pub const HorizontalMetric = struct {
    advance: i32,
    left_bearing: i32,
};

pub const OutlinePoint = font_outline.Point;
pub const Outline = font_outline.Outline;

const maximum_outline_points = 1_048_576;
const maximum_outline_contours = 262_144;

/// Conservative Unicode coverage for lazy system-font fallback. Each bit
/// represents one 256-scalar block. Candidates are verified against cmap after
/// loading, so block-level false positives are harmless while false negatives
/// are avoided for the cmap formats supported by the in-tree shaper.
pub const Coverage = struct {
    const scalar_block_count = 0x1100;
    const word_count = scalar_block_count / 64;

    words: [word_count]u64 = @splat(0),

    pub fn mayContain(self: *const Coverage, scalar: u21) bool {
        const block: usize = @as(usize, scalar) >> 8;
        return self.words[block / 64] & (@as(u64, 1) << @intCast(block % 64)) != 0;
    }

    fn includeRange(self: *Coverage, first_value: u32, last_value: u32) void {
        if (first_value > last_value or first_value > 0x10ffff) return;
        const first: usize = @as(usize, first_value) >> 8;
        const last: usize = @as(usize, @min(last_value, 0x10ffff)) >> 8;
        var block = first;
        while (block <= last) : (block += 1)
            self.words[block / 64] |= @as(u64, 1) << @intCast(block % 64);
    }
};

pub const Font = struct {
    bytes: []const u8,
    face_offset: usize = 0,
    variation_coordinates: []const i16 = &.{},
    pixels_per_em: ?u16 = null,

    pub fn faceCount(bytes: []const u8) Error!u32 {
        if (bytes.len < 12) return error.InvalidFont;
        if (!std.mem.eql(u8, bytes[0..4], "ttcf")) return 1;
        const count = try readU32(bytes, 8);
        if (count == 0 or count > 4096 or 12 + @as(usize, count) * 4 > bytes.len) return error.InvalidFont;
        return count;
    }

    pub fn init(bytes: []const u8, face_index: u32) Error!Font {
        if (bytes.len < 12) return error.InvalidFont;
        var offset: usize = 0;
        if (std.mem.eql(u8, bytes[0..4], "ttcf")) {
            const version = try readU32(bytes, 4);
            if (version != 0x00010000 and version != 0x00020000) return error.InvalidFont;
            const count = try readU32(bytes, 8);
            if (count == 0 or count > 4096 or face_index >= count or 12 + @as(usize, count) * 4 > bytes.len) return error.InvalidFont;
            offset = try readU32(bytes, 12 + @as(usize, face_index) * 4);
        } else if (face_index != 0) return error.InvalidFont;
        if (offset > bytes.len or 12 > bytes.len - offset) return error.InvalidFont;
        const signature = try readU32(bytes, offset);
        if (signature != 0x00010000 and signature != 0x4f54544f and signature != 0x74727565) return error.InvalidFont;
        const font: Font = .{ .bytes = bytes, .face_offset = offset };
        _ = try font.table("head".*);
        _ = try font.table("maxp".*);
        _ = try font.table("cmap".*);
        return font;
    }

    pub fn table(self: Font, tag: Tag) Error![]const u8 {
        const count = try readU16(self.bytes, self.face_offset + 4);
        const directory = std.math.add(usize, self.face_offset, 12) catch return error.InvalidFont;
        const directory_size = std.math.mul(usize, @as(usize, count), 16) catch return error.InvalidFont;
        if (directory > self.bytes.len or directory_size > self.bytes.len - directory) return error.InvalidFont;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const entry = directory + index * 16;
            if (!std.mem.eql(u8, self.bytes[entry..][0..4], &tag)) continue;
            const offset = try readU32(self.bytes, entry + 8);
            const length = try readU32(self.bytes, entry + 12);
            if (offset > self.bytes.len or length > self.bytes.len - @as(usize, offset)) return error.InvalidFont;
            return self.bytes[offset..][0..length];
        }
        return error.InvalidFont;
    }

    pub fn optionalTable(self: Font, tag: Tag) ?[]const u8 {
        return self.table(tag) catch null;
    }

    pub fn withVariation(self: Font, coordinates: []const i16) Error!Font {
        const fvar = self.optionalTable("fvar".*) orelse {
            if (coordinates.len != 0) return error.InvalidFont;
            return self;
        };
        if (try variation.axisCount(fvar) != coordinates.len) return error.InvalidFont;
        var result = self;
        result.variation_coordinates = coordinates;
        return result;
    }

    pub fn isVariable(self: Font) bool {
        const fvar = self.optionalTable("fvar".*) orelse return false;
        return (variation.axisCount(fvar) catch return false) != 0;
    }

    pub fn unitsPerEm(self: Font) Error!u16 {
        const head = try self.table("head".*);
        const value = try readU16(head, 18);
        if (value < 16 or value > 16_384) return error.InvalidFont;
        return value;
    }

    pub fn glyphCount(self: Font) Error!u16 {
        const maxp = try self.table("maxp".*);
        const count = try readU16(maxp, 4);
        if (count == 0) return error.InvalidFont;
        return count;
    }

    pub fn ascender(self: Font) Error!f32 {
        const fallback = try readI16(try self.table("hhea".*), 4);
        const base = if (self.optionalTable("OS/2".*)) |os2| if (os2.len >= 74) try readI16(os2, 68) else fallback else fallback;
        return @as(f32, @floatFromInt(base)) + try self.mvarDelta("hasc".*);
    }

    pub fn descender(self: Font) Error!f32 {
        const fallback = try readI16(try self.table("hhea".*), 6);
        const base = if (self.optionalTable("OS/2".*)) |os2| if (os2.len >= 74) try readI16(os2, 70) else fallback else fallback;
        return @as(f32, @floatFromInt(base)) + try self.mvarDelta("hdsc".*);
    }

    pub fn lineGap(self: Font) Error!f32 {
        const fallback = try readI16(try self.table("hhea".*), 8);
        const base = if (self.optionalTable("OS/2".*)) |os2| if (os2.len >= 74) try readI16(os2, 72) else fallback else fallback;
        return @as(f32, @floatFromInt(base)) + try self.mvarDelta("hlgp".*);
    }

    pub fn xHeight(self: Font) Error!?f32 {
        const os2 = self.optionalTable("OS/2".*) orelse return null;
        if (os2.len < 88 or try readU16(os2, 0) < 2) return null;
        return @as(f32, @floatFromInt(try readI16(os2, 86))) + try self.mvarDelta("xhgt".*);
    }

    pub fn capHeight(self: Font) Error!?f32 {
        const os2 = self.optionalTable("OS/2".*) orelse return null;
        if (os2.len < 90 or try readU16(os2, 0) < 2) return null;
        return @as(f32, @floatFromInt(try readI16(os2, 88))) + try self.mvarDelta("cpht".*);
    }

    pub fn underlinePosition(self: Font) Error!f32 {
        const post = try self.table("post".*);
        return @as(f32, @floatFromInt(try readI16(post, 8))) + try self.mvarDelta("undo".*);
    }

    pub fn underlineThickness(self: Font) Error!f32 {
        const post = try self.table("post".*);
        return @as(f32, @floatFromInt(try readI16(post, 10))) + try self.mvarDelta("unds".*);
    }

    pub fn weightClass(self: Font) u16 {
        const os2 = self.optionalTable("OS/2".*) orelse return 400;
        const value = readU16(os2, 4) catch return 400;
        return std.math.clamp(value, 1, 1000);
    }

    pub fn widthClass(self: Font) u16 {
        const os2 = self.optionalTable("OS/2".*) orelse return 5;
        const value = readU16(os2, 6) catch return 5;
        return std.math.clamp(value, 1, 9);
    }

    pub fn isItalic(self: Font) bool {
        if (self.optionalTable("OS/2".*)) |os2| {
            const selection = readU16(os2, 62) catch 0;
            if (selection & 1 != 0) return true;
        }
        const head = self.optionalTable("head".*) orelse return false;
        return (readU16(head, 44) catch 0) & 2 != 0;
    }

    pub fn mvarDelta(self: Font, tag: Tag) Error!f32 {
        if (self.variation_coordinates.len == 0 or variation.allDefault(self.variation_coordinates)) return 0;
        const mvar = self.optionalTable("MVAR".*) orelse return 0;
        if (mvar.len < 12 or try readU16(mvar, 0) != 1 or try readU16(mvar, 2) != 0 or try readU16(mvar, 4) != 0) return error.InvalidFont;
        const record_size = try readU16(mvar, 6);
        const record_count = try readU16(mvar, 8);
        const store_offset = try readU16(mvar, 10);
        if (record_count == 0) return 0;
        if (record_size < 8 or 12 + @as(usize, record_size) * record_count > mvar.len or store_offset == 0 or store_offset > mvar.len) return error.InvalidFont;
        var low: usize = 0;
        var high: usize = record_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const record = 12 + middle * record_size;
            switch (std.mem.order(u8, mvar[record..][0..4], &tag)) {
                .lt => low = middle + 1,
                else => high = middle,
            }
        }
        if (low >= record_count) return 0;
        const record = 12 + low * record_size;
        if (!std.mem.eql(u8, mvar[record..][0..4], &tag)) return 0;
        return variation.itemDelta(mvar[store_offset..], self.variation_coordinates, .{
            .outer = try readU16(mvar, record + 4),
            .inner = try readU16(mvar, record + 6),
        });
    }

    pub fn layoutVariationDelta(self: Font, outer: u16, inner: u16) Error!f32 {
        if (self.variation_coordinates.len == 0 or variation.allDefault(self.variation_coordinates)) return 0;
        const gdef = self.optionalTable("GDEF".*) orelse return 0;
        if (gdef.len < 18 or try readU16(gdef, 0) != 1 or try readU16(gdef, 2) < 3) return 0;
        const store_offset = try readU32(gdef, 14);
        if (store_offset == 0) return 0;
        if (store_offset > gdef.len) return error.InvalidFont;
        return variation.itemDelta(gdef[store_offset..], self.variation_coordinates, .{ .outer = outer, .inner = inner });
    }

    pub fn glyphIndex(self: Font, scalar: u21) Error!u16 {
        const cmap = try self.table("cmap".*);
        const tables = try selectCmaps(cmap);
        var glyph: u16 = 0;
        if (tables.format12) |table_value| glyph = try cmapFormat12(table_value, scalar);
        if (glyph == 0) {
            if (tables.format10) |table_value| glyph = try cmapFormat10(table_value, scalar);
        }
        if (glyph == 0) {
            if (tables.format4) |table_value| glyph = try cmapFormat4(table_value, scalar);
        }
        if (glyph == 0) {
            if (tables.format6) |table_value| glyph = try cmapFormat6(table_value, scalar);
        }
        if (glyph == 0) {
            if (tables.format0) |table_value| glyph = try cmapFormat0(table_value, scalar);
        }
        if (glyph == 0) {
            if (tables.format13) |table_value| glyph = try cmapFormat13(table_value, scalar);
        }
        return if (glyph < try self.glyphCount()) glyph else 0;
    }

    /// Resolves a Unicode variation sequence through cmap format 14. A null
    /// result means the font has no mapping for the sequence; callers should
    /// retain the default glyph for `scalar` and consume the selector as a
    /// default-ignorable character.
    pub fn variationGlyphIndex(self: Font, scalar: u21, selector: u21) Error!?u16 {
        const tables = try selectCmaps(try self.table("cmap".*));
        const format14 = tables.format14 orelse return null;
        const mapped = try cmapFormat14(format14, scalar, selector) orelse return null;
        const glyph = switch (mapped) {
            .default => try self.glyphIndex(scalar),
            .glyph => |value| value,
        };
        return if (glyph < try self.glyphCount()) glyph else null;
    }

    pub fn coverage(self: Font) Error!Coverage {
        const cmap = try self.table("cmap".*);
        const tables = try selectCmaps(cmap);
        var result: Coverage = .{};
        if (tables.format12) |table_value| try appendFormat12Coverage(table_value, &result);
        if (tables.format13) |table_value| try appendFormat13Coverage(table_value, &result);
        if (tables.format10) |table_value| try appendFormat10Coverage(table_value, &result);
        if (tables.format4) |table_value| try appendFormat4Coverage(table_value, &result);
        if (tables.format6) |table_value| try appendFormat6Coverage(table_value, &result);
        if (tables.format0) |table_value| try appendFormat0Coverage(table_value, &result);
        return result;
    }

    pub fn horizontalMetric(self: Font, allocator: std.mem.Allocator, glyph: u16) Error!HorizontalMetric {
        const hhea = try self.table("hhea".*);
        const hmtx = try self.table("hmtx".*);
        const metric_count = try readU16(hhea, 34);
        if (metric_count == 0) return error.InvalidFont;
        const glyph_count = try self.glyphCount();
        if (glyph >= glyph_count) return error.InvalidFont;
        var result: HorizontalMetric = if (glyph < metric_count)
            .{
                .advance = try readU16(hmtx, @as(usize, glyph) * 4),
                .left_bearing = try readI16(hmtx, @as(usize, glyph) * 4 + 2),
            }
        else
            .{
                .advance = try readU16(hmtx, (@as(usize, metric_count) - 1) * 4),
                .left_bearing = try readI16(hmtx, @as(usize, metric_count) * 4 + @as(usize, glyph - metric_count) * 2),
            };
        if (self.variation_coordinates.len != 0 and !variation.allDefault(self.variation_coordinates)) {
            if (self.optionalTable("HVAR".*)) |hvar| {
                result.advance += @intFromFloat(@round(try variation.hvarAdvanceDelta(hvar, self.variation_coordinates, glyph)));
                result.left_bearing += @intFromFloat(@round(try variation.hvarLeftBearingDelta(hvar, self.variation_coordinates, glyph)));
            } else if (self.optionalTable("gvar".*)) |gvar| {
                const count = try self.glyphVariationPointCount(glyph);
                const dummy = try allocator.alloc(OutlinePoint, count);
                defer allocator.free(dummy);
                @memset(dummy, .{ .x = 0, .y = 0, .on_curve = true });
                var phantoms: [4]OutlinePoint = undefined;
                try variation.applyGvar(
                    allocator,
                    gvar,
                    self.variation_coordinates,
                    glyph,
                    .composite,
                    dummy,
                    &.{},
                    &phantoms,
                );
                result.advance += @intFromFloat(@round(phantoms[1].x - phantoms[0].x));
            }
        }
        return result;
    }

    fn glyphVariationPointCount(self: Font, glyph: u16) Error!usize {
        const data = try self.glyphData(glyph);
        if (data.len == 0) return 0;
        if (data.len < 10) return error.InvalidFont;
        const contour_count = try readI16(data, 0);
        if (contour_count >= 0) {
            if (contour_count == 0) return 0;
            return @as(usize, try readU16(data, 10 + (@as(usize, @intCast(contour_count)) - 1) * 2)) + 1;
        }
        var offset: usize = 10;
        var count: usize = 0;
        var more = true;
        while (more) {
            const flags = try readU16(data, offset);
            _ = try readU16(data, offset + 2);
            if (flags & ~@as(u16, 0x1fef) != 0 or flags & 0x1800 == 0x1800 or (flags & 0x0100 != 0 and flags & 0x0020 != 0)) return error.InvalidFont;
            if (@popCount(flags & 0x00c8) > 1) return error.InvalidFont;
            offset += 4;
            offset += if (flags & 0x0001 != 0) 4 else 2;
            if (flags & 0x0008 != 0) offset += 2 else if (flags & 0x0040 != 0) offset += 4 else if (flags & 0x0080 != 0) offset += 8;
            if (offset > data.len) return error.InvalidFont;
            count += 1;
            if (count > 4096) return error.InvalidFont;
            more = flags & 0x0020 != 0;
        }
        return count;
    }

    pub fn kerning(self: Font, left: u16, right: u16) i16 {
        const kern = self.optionalTable("kern".*) orelse return 0;
        if (kern.len < 4) return 0;
        const table_count = readU16(kern, 2) catch return 0;
        var offset: usize = 4;
        var index: usize = 0;
        while (index < table_count and offset + 6 <= kern.len) : (index += 1) {
            const length = readU16(kern, offset + 2) catch return 0;
            const coverage_value = readU16(kern, offset + 4) catch return 0;
            const format = coverage_value >> 8;
            if (format == 0 and offset + length <= kern.len) {
                const subtable = kern[offset + 6 .. offset + length];
                const pairs = readU16(subtable, 0) catch return 0;
                var low: usize = 0;
                var high: usize = pairs;
                const key = (@as(u32, left) << 16) | right;
                while (low < high) {
                    const middle = (low + high) / 2;
                    const pair_offset = 8 + middle * 6;
                    const pair_key = readU32(subtable, pair_offset) catch return 0;
                    if (pair_key < key) low = middle + 1 else high = middle;
                }
                if (low < pairs) {
                    const pair_offset = 8 + low * 6;
                    if ((readU32(subtable, pair_offset) catch return 0) == key) return readI16(subtable, pair_offset + 4) catch 0;
                }
            }
            offset += length;
        }
        return 0;
    }

    pub fn familyName(self: Font, allocator: std.mem.Allocator) Error![]u8 {
        const name = try self.table("name".*);
        if (name.len < 6) return error.InvalidFont;
        const count = try readU16(name, 2);
        const strings_offset = try readU16(name, 4);
        var preferred: ?struct { platform: u16, offset: usize, length: usize, score: u8 } = null;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const record = 6 + index * 12;
            if (record + 12 > name.len) return error.InvalidFont;
            const platform = try readU16(name, record);
            const language = try readU16(name, record + 4);
            const name_id = try readU16(name, record + 6);
            if (name_id != 1 and name_id != 16) continue;
            const length = try readU16(name, record + 8);
            const offset = @as(usize, strings_offset) + try readU16(name, record + 10);
            if (offset + length > name.len) continue;
            const score: u8 = (if (name_id == 16) @as(u8, 4) else 0) + (if (platform == 3 or platform == 0) @as(u8, 2) else 0) + (if (language == 0x0409 or language == 0) @as(u8, 1) else 0);
            if (preferred == null or score > preferred.?.score) preferred = .{ .platform = platform, .offset = offset, .length = length, .score = score };
        }
        const selected = preferred orelse return error.InvalidFont;
        if (selected.platform == 0 or selected.platform == 3) return utf16BeToUtf8(allocator, name[selected.offset..][0..selected.length]);
        return allocator.dupe(u8, name[selected.offset..][0..selected.length]);
    }

    pub fn outline(self: Font, allocator: std.mem.Allocator, glyph: u16) Error!Outline {
        if (glyph >= try self.glyphCount()) return error.InvalidFont;
        if (self.optionalTable("glyf".*) == null) return cff.outline(
            allocator,
            self.bytes,
            self.optionalTable("CFF ".*),
            self.optionalTable("CFF2".*),
            self.variation_coordinates,
            glyph,
        );
        var points: std.ArrayList(OutlinePoint) = .empty;
        errdefer points.deinit(allocator);
        var contours: std.ArrayList(u32) = .empty;
        errdefer contours.deinit(allocator);
        _ = try self.appendGlyph(allocator, glyph, .{}, &points, &contours, 0);
        const varied_bounds = outlineBounds(points.items);
        const owned_points = try points.toOwnedSlice(allocator);
        errdefer allocator.free(owned_points);
        const owned_contours = try contours.toOwnedSlice(allocator);
        return .{
            .points = owned_points,
            .contour_ends = owned_contours,
            .bounds = varied_bounds,
            .curve_kind = .quadratic,
        };
    }

    fn appendGlyph(
        self: Font,
        allocator: std.mem.Allocator,
        glyph: u16,
        transform: Transform,
        points: *std.ArrayList(OutlinePoint),
        contours: *std.ArrayList(u32),
        depth: u8,
    ) Error!Bounds {
        if (depth > 32) return error.InvalidFont;
        if (points.items.len > maximum_outline_points or contours.items.len > maximum_outline_contours)
            return error.BudgetExceeded;
        if (!finiteTransform(transform)) return error.InvalidFont;
        const data = try self.glyphData(glyph);
        if (data.len == 0) return .{ .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 };
        if (data.len < 10) return error.InvalidFont;
        const contour_count = try readI16(data, 0);
        const bounds: Bounds = .{
            .x_min = try readI16(data, 2),
            .y_min = try readI16(data, 4),
            .x_max = try readI16(data, 6),
            .y_max = try readI16(data, 8),
        };
        if (contour_count >= 0) {
            var local_points: std.ArrayList(OutlinePoint) = .empty;
            defer local_points.deinit(allocator);
            var local_contours: std.ArrayList(u32) = .empty;
            defer local_contours.deinit(allocator);
            try appendSimpleGlyph(allocator, data, @intCast(contour_count), .{}, &local_points, &local_contours);
            if (self.optionalTable("gvar".*)) |gvar| try variation.applyGvar(
                allocator,
                gvar,
                self.variation_coordinates,
                glyph,
                .simple,
                local_points.items,
                local_contours.items,
                null,
            );
            if (local_points.items.len > maximum_outline_points or local_contours.items.len > maximum_outline_contours)
                return error.BudgetExceeded;
            const next_point_count = std.math.add(usize, points.items.len, local_points.items.len) catch return error.BudgetExceeded;
            const next_contour_count = std.math.add(usize, contours.items.len, local_contours.items.len) catch return error.BudgetExceeded;
            if (next_point_count > maximum_outline_points or next_contour_count > maximum_outline_contours)
                return error.BudgetExceeded;
            const base: u32 = @intCast(points.items.len);
            try points.ensureUnusedCapacity(allocator, local_points.items.len);
            for (local_points.items) |point| {
                var transformed = transform.apply(point.x, point.y);
                if (!finitePoint(transformed)) return error.InvalidFont;
                transformed.on_curve = point.on_curve;
                points.appendAssumeCapacity(transformed);
            }
            try contours.ensureUnusedCapacity(allocator, local_contours.items.len);
            for (local_contours.items) |end| contours.appendAssumeCapacity(base + end);
        } else {
            try self.appendCompositeGlyph(allocator, glyph, data, transform, points, contours, depth);
        }
        return bounds;
    }

    fn glyphData(self: Font, glyph: u16) Error![]const u8 {
        if (glyph >= try self.glyphCount()) return error.InvalidFont;
        const loca = try self.table("loca".*);
        const glyf = try self.table("glyf".*);
        const head = try self.table("head".*);
        const format = try readI16(head, 50);
        if (format != 0 and format != 1) return error.InvalidFont;
        const start: usize = if (format == 0) @as(usize, try readU16(loca, @as(usize, glyph) * 2)) * 2 else try readU32(loca, @as(usize, glyph) * 4);
        const end: usize = if (format == 0) @as(usize, try readU16(loca, (@as(usize, glyph) + 1) * 2)) * 2 else try readU32(loca, (@as(usize, glyph) + 1) * 4);
        if (start > end or end > glyf.len) return error.InvalidFont;
        return glyf[start..end];
    }

    fn appendCompositeGlyph(
        self: Font,
        allocator: std.mem.Allocator,
        composite_glyph: u16,
        data: []const u8,
        parent_transform: Transform,
        points: *std.ArrayList(OutlinePoint),
        contours: *std.ArrayList(u32),
        depth: u8,
    ) Error!void {
        const Component = struct {
            flags: u16,
            glyph: u16,
            argument1: i16,
            argument2: i16,
            transform: Transform,
        };
        var components: std.ArrayList(Component) = .empty;
        defer components.deinit(allocator);
        var offset: usize = 10;
        var more = true;
        var final_flags: u16 = 0;
        while (more) {
            const flags = try readU16(data, offset);
            const glyph = try readU16(data, offset + 2);
            if (flags & ~@as(u16, 0x1fef) != 0 or flags & 0x1800 == 0x1800) return error.InvalidFont;
            if (flags & 0x0100 != 0 and flags & 0x0020 != 0) return error.InvalidFont;
            const transform_flags = @popCount(flags & 0x00c8);
            if (transform_flags > 1) return error.InvalidFont;
            offset += 4;
            var argument1: i16 = 0;
            var argument2: i16 = 0;
            if (flags & 0x0001 != 0) {
                argument1 = try readI16(data, offset);
                argument2 = try readI16(data, offset + 2);
                offset += 4;
            } else {
                if (offset + 2 > data.len) return error.InvalidFont;
                if (flags & 0x0002 != 0) {
                    argument1 = @as(i8, @bitCast(data[offset]));
                    argument2 = @as(i8, @bitCast(data[offset + 1]));
                } else {
                    argument1 = data[offset];
                    argument2 = data[offset + 1];
                }
                offset += 2;
            }
            var child: Transform = .{};
            if (flags & 0x0002 != 0) {
                child.tx = @floatFromInt(argument1);
                child.ty = @floatFromInt(argument2);
            }
            if (flags & 0x0008 != 0) {
                const scale = try readF2Dot14(data, offset);
                offset += 2;
                child.xx = scale;
                child.yy = scale;
            } else if (flags & 0x0040 != 0) {
                child.xx = try readF2Dot14(data, offset);
                child.yy = try readF2Dot14(data, offset + 2);
                offset += 4;
            } else if (flags & 0x0080 != 0) {
                child.xx = try readF2Dot14(data, offset);
                child.yx = try readF2Dot14(data, offset + 2);
                child.xy = try readF2Dot14(data, offset + 4);
                child.yy = try readF2Dot14(data, offset + 6);
                offset += 8;
            }
            try components.append(allocator, .{
                .flags = flags,
                .glyph = glyph,
                .argument1 = argument1,
                .argument2 = argument2,
                .transform = child,
            });
            if (components.items.len > 4096) return error.InvalidFont;
            final_flags = flags;
            more = flags & 0x0020 != 0;
        }

        if (final_flags & 0x0100 != 0) {
            const instruction_length = try readU16(data, offset);
            offset = std.math.add(usize, offset, 2) catch return error.InvalidFont;
            if (instruction_length > data.len - offset) return error.InvalidFont;
            offset += instruction_length;
        }

        if (components.items.len == 0) return error.InvalidFont;
        const component_offsets = try allocator.alloc(OutlinePoint, components.items.len);
        defer allocator.free(component_offsets);
        for (components.items, 0..) |component, index| component_offsets[index] = .{
            .x = component.transform.tx,
            .y = component.transform.ty,
            .on_curve = true,
        };
        if (self.optionalTable("gvar".*)) |gvar| try variation.applyGvar(
            allocator,
            gvar,
            self.variation_coordinates,
            composite_glyph,
            .composite,
            component_offsets,
            &.{},
            null,
        );

        const composite_base = points.items.len;
        for (components.items, component_offsets) |component, varied_offset| {
            if (!finitePoint(varied_offset)) return error.InvalidFont;
            var child = component.transform;
            if (component.flags & 0x0002 != 0) {
                child.tx = varied_offset.x;
                child.ty = varied_offset.y;
                if (component.flags & 0x0800 != 0) {
                    const scaled_x = child.tx * child.xx + child.ty * child.xy;
                    const scaled_y = child.tx * child.yx + child.ty * child.yy;
                    child.tx = scaled_x;
                    child.ty = scaled_y;
                }
                if (component.flags & 0x0004 != 0) {
                    child.tx = @round(child.tx);
                    child.ty = @round(child.ty);
                }
                const combined = Transform.mul(parent_transform, child);
                if (!finiteTransform(combined)) return error.InvalidFont;
                _ = try self.appendGlyph(allocator, component.glyph, combined, points, contours, depth + 1);
                continue;
            }

            const parent_point = composite_base + @as(usize, @intCast(@as(u16, @bitCast(component.argument1))));
            if (parent_point >= points.items.len) return error.InvalidFont;
            child.tx = 0;
            child.ty = 0;
            const child_base = points.items.len;
            const combined = Transform.mul(parent_transform, child);
            if (!finiteTransform(combined)) return error.InvalidFont;
            _ = try self.appendGlyph(allocator, component.glyph, combined, points, contours, depth + 1);
            const child_point = child_base + @as(usize, @intCast(@as(u16, @bitCast(component.argument2))));
            if (child_point >= points.items.len) return error.InvalidFont;
            const delta_x = points.items[parent_point].x - points.items[child_point].x;
            const delta_y = points.items[parent_point].y - points.items[child_point].y;
            for (points.items[child_base..]) |*point| {
                point.x += delta_x;
                point.y += delta_y;
                if (!finitePoint(point.*)) return error.InvalidFont;
            }
        }
    }
};

const Transform = struct {
    xx: f32 = 1,
    xy: f32 = 0,
    yx: f32 = 0,
    yy: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    fn apply(self: Transform, x: f32, y: f32) OutlinePoint {
        return .{ .x = x * self.xx + y * self.xy + self.tx, .y = x * self.yx + y * self.yy + self.ty, .on_curve = false };
    }

    fn mul(a: Transform, b: Transform) Transform {
        return .{
            .xx = a.xx * b.xx + a.xy * b.yx,
            .xy = a.xx * b.xy + a.xy * b.yy,
            .yx = a.yx * b.xx + a.yy * b.yx,
            .yy = a.yx * b.xy + a.yy * b.yy,
            .tx = a.xx * b.tx + a.xy * b.ty + a.tx,
            .ty = a.yx * b.tx + a.yy * b.ty + a.ty,
        };
    }
};

fn finitePoint(point: OutlinePoint) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn finiteTransform(transform: Transform) bool {
    return std.math.isFinite(transform.xx) and std.math.isFinite(transform.xy) and
        std.math.isFinite(transform.yx) and std.math.isFinite(transform.yy) and
        std.math.isFinite(transform.tx) and std.math.isFinite(transform.ty);
}

fn outlineBounds(points: []const OutlinePoint) Bounds {
    if (points.len == 0) return .{ .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 };
    var minimum_x = points[0].x;
    var minimum_y = points[0].y;
    var maximum_x = points[0].x;
    var maximum_y = points[0].y;
    for (points[1..]) |point| {
        minimum_x = @min(minimum_x, point.x);
        minimum_y = @min(minimum_y, point.y);
        maximum_x = @max(maximum_x, point.x);
        maximum_y = @max(maximum_y, point.y);
    }
    return .{
        .x_min = clampOutlineCoordinate(minimum_x),
        .y_min = clampOutlineCoordinate(minimum_y),
        .x_max = clampOutlineCoordinate(maximum_x),
        .y_max = clampOutlineCoordinate(maximum_y),
    };
}

fn clampOutlineCoordinate(value: f32) i16 {
    return @intFromFloat(std.math.clamp(@round(value), @as(f32, @floatFromInt(std.math.minInt(i16))), @as(f32, @floatFromInt(std.math.maxInt(i16)))));
}

fn appendSimpleGlyph(
    allocator: std.mem.Allocator,
    data: []const u8,
    contour_count: usize,
    transform: Transform,
    points: *std.ArrayList(OutlinePoint),
    contours: *std.ArrayList(u32),
) Error!void {
    if (contour_count == 0) return;
    if (points.items.len > maximum_outline_points or contours.items.len > maximum_outline_contours or
        contour_count > maximum_outline_contours - contours.items.len) return error.BudgetExceeded;
    if (!finiteTransform(transform)) return error.InvalidFont;
    var offset: usize = 10;
    const base: u32 = @intCast(points.items.len);
    var last_end: u16 = 0;
    var index: usize = 0;
    while (index < contour_count) : (index += 1) {
        const end = try readU16(data, offset);
        if (index != 0 and end <= last_end) return error.InvalidFont;
        last_end = end;
        offset += 2;
        const contour_end = std.math.add(u32, base, last_end) catch return error.InvalidFont;
        try contours.append(allocator, contour_end);
    }
    const point_count = @as(usize, last_end) + 1;
    const next_point_count = std.math.add(usize, points.items.len, point_count) catch return error.BudgetExceeded;
    if (next_point_count > maximum_outline_points) return error.BudgetExceeded;
    const instruction_length = try readU16(data, offset);
    offset = std.math.add(usize, offset, 2 + @as(usize, instruction_length)) catch return error.InvalidFont;
    if (offset > data.len) return error.InvalidFont;
    const flags = try allocator.alloc(u8, point_count);
    defer allocator.free(flags);
    index = 0;
    while (index < point_count) {
        if (offset >= data.len) return error.InvalidFont;
        const flag = data[offset];
        if (flag & 0x80 != 0) return error.InvalidFont;
        offset += 1;
        flags[index] = flag;
        index += 1;
        if (flag & 0x08 != 0) {
            if (offset >= data.len) return error.InvalidFont;
            const repeats = data[offset];
            offset += 1;
            if (index + repeats > point_count) return error.InvalidFont;
            @memset(flags[index..][0..repeats], flag);
            index += repeats;
        }
    }
    const xs = try allocator.alloc(i32, point_count);
    defer allocator.free(xs);
    const ys = try allocator.alloc(i32, point_count);
    defer allocator.free(ys);
    var coordinate: i32 = 0;
    for (flags, 0..) |flag, point_index| {
        var delta: i32 = 0;
        if (flag & 0x02 != 0) {
            if (offset >= data.len) return error.InvalidFont;
            delta = data[offset];
            offset += 1;
            if (flag & 0x10 == 0) delta = -delta;
        } else if (flag & 0x10 == 0) {
            delta = try readI16(data, offset);
            offset += 2;
        }
        coordinate = std.math.add(i32, coordinate, delta) catch return error.InvalidFont;
        xs[point_index] = coordinate;
    }
    coordinate = 0;
    for (flags, 0..) |flag, point_index| {
        var delta: i32 = 0;
        if (flag & 0x04 != 0) {
            if (offset >= data.len) return error.InvalidFont;
            delta = data[offset];
            offset += 1;
            if (flag & 0x20 == 0) delta = -delta;
        } else if (flag & 0x20 == 0) {
            delta = try readI16(data, offset);
            offset += 2;
        }
        coordinate = std.math.add(i32, coordinate, delta) catch return error.InvalidFont;
        ys[point_index] = coordinate;
    }
    for (flags, 0..) |flag, point_index| {
        var point = transform.apply(@floatFromInt(xs[point_index]), @floatFromInt(ys[point_index]));
        if (!finitePoint(point)) return error.InvalidFont;
        point.on_curve = flag & 0x01 != 0;
        try points.append(allocator, point);
    }
}

const CmapSelection = struct {
    format0: ?[]const u8 = null,
    format4: ?[]const u8 = null,
    format6: ?[]const u8 = null,
    format10: ?[]const u8 = null,
    format12: ?[]const u8 = null,
    format13: ?[]const u8 = null,
    format14: ?[]const u8 = null,
};

fn selectCmaps(cmap: []const u8) Error!CmapSelection {
    if (cmap.len < 4 or try readU16(cmap, 0) != 0) return error.InvalidFont;
    const count = try readU16(cmap, 2);
    if (4 + @as(usize, count) * 8 > cmap.len) return error.InvalidFont;
    var result: CmapSelection = .{};
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const record = 4 + index * 8;
        const platform = try readU16(cmap, record);
        const encoding = try readU16(cmap, record + 2);
        const offset: usize = try readU32(cmap, record + 4);
        if (offset > cmap.len or 2 > cmap.len - offset) continue;
        const subtable = cmap[offset..];
        const format = readU16(subtable, 0) catch continue;
        const unicode_bmp = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
        const unicode_full = platform == 0 or (platform == 3 and encoding == 10);
        switch (format) {
            0 => {
                if (unicode_bmp and result.format0 == null) result.format0 = subtable;
            },
            4 => {
                if (unicode_bmp and result.format4 == null) result.format4 = subtable;
            },
            6 => {
                if (unicode_bmp and result.format6 == null) result.format6 = subtable;
            },
            10 => {
                if (unicode_full and result.format10 == null) result.format10 = subtable;
            },
            12 => {
                if (unicode_full and result.format12 == null) result.format12 = subtable;
            },
            13 => {
                if (unicode_full and result.format13 == null) result.format13 = subtable;
            },
            14 => {
                if (platform == 0 and result.format14 == null) result.format14 = subtable;
            },
            else => {},
        }
    }
    if (result.format0 == null and result.format4 == null and result.format6 == null and
        result.format10 == null and result.format12 == null and result.format13 == null) return error.InvalidFont;
    return result;
}

fn cmapFormat0(table: []const u8, scalar: u21) Error!u16 {
    if (scalar > 0xff or table.len < 262 or try readU16(table, 0) != 0) return 0;
    const length = try readU16(table, 2);
    if (length < 262 or length > table.len) return error.InvalidFont;
    return table[6 + @as(usize, scalar)];
}

fn cmapFormat6(table: []const u8, scalar: u21) Error!u16 {
    if (scalar > 0xffff or table.len < 10 or try readU16(table, 0) != 6) return 0;
    const length = try readU16(table, 2);
    const first = try readU16(table, 6);
    const count = try readU16(table, 8);
    if (length < 10 or length > table.len or 10 + @as(usize, count) * 2 > length) return error.InvalidFont;
    if (scalar < first or @as(u32, scalar) - first >= count) return 0;
    return readU16(table, 10 + @as(usize, scalar - first) * 2);
}

fn cmapFormat10(table: []const u8, scalar: u21) Error!u16 {
    if (table.len < 20 or try readU16(table, 0) != 10 or try readU16(table, 2) != 0) return error.InvalidFont;
    const length = try readU32(table, 4);
    const first = try readU32(table, 12);
    const count = try readU32(table, 16);
    const entries_size = std.math.mul(usize, @as(usize, count), 2) catch return error.InvalidFont;
    if (length < 20 or length > table.len or entries_size > @as(usize, length) - 20) return error.InvalidFont;
    if (scalar < first or @as(u32, scalar) - first >= count) return 0;
    return readU16(table, 20 + @as(usize, @as(u32, scalar) - first) * 2);
}

fn cmapFormat12(table: []const u8, scalar: u21) Error!u16 {
    if (table.len < 16 or try readU16(table, 0) != 12 or try readU16(table, 2) != 0) return error.InvalidFont;
    const length = try readU32(table, 4);
    const groups = try readU32(table, 12);
    const records_size = std.math.mul(usize, @as(usize, groups), 12) catch return error.InvalidFont;
    if (length < 16 or length > table.len or records_size > @as(usize, length) - 16) return error.InvalidFont;
    const bytes = table[0..length];
    var low: usize = 0;
    var high: usize = groups;
    while (low < high) {
        const middle = (low + high) / 2;
        const offset = 16 + middle * 12;
        const end = try readU32(bytes, offset + 4);
        if (end < scalar) low = middle + 1 else high = middle;
    }
    if (low >= groups) return 0;
    const offset = 16 + low * 12;
    const start = try readU32(bytes, offset);
    const end = try readU32(bytes, offset + 4);
    if (scalar < start or scalar > end) return 0;
    const delta = @as(u32, scalar) - start;
    const glyph = std.math.add(u32, try readU32(bytes, offset + 8), delta) catch return error.InvalidFont;
    if (glyph > std.math.maxInt(u16)) return 0;
    return @intCast(glyph);
}

fn cmapFormat13(table: []const u8, scalar: u21) Error!u16 {
    if (table.len < 16 or try readU16(table, 0) != 13 or try readU16(table, 2) != 0) return error.InvalidFont;
    const length = try readU32(table, 4);
    const groups = try readU32(table, 12);
    const records_size = std.math.mul(usize, @as(usize, groups), 12) catch return error.InvalidFont;
    if (length < 16 or length > table.len or records_size > @as(usize, length) - 16) return error.InvalidFont;
    const bytes = table[0..length];
    var low: usize = 0;
    var high: usize = groups;
    while (low < high) {
        const middle = (low + high) / 2;
        if (try readU32(bytes, 16 + middle * 12 + 4) < scalar) low = middle + 1 else high = middle;
    }
    if (low >= groups) return 0;
    const offset = 16 + low * 12;
    const first = try readU32(bytes, offset);
    const last = try readU32(bytes, offset + 4);
    if (scalar < first or scalar > last) return 0;
    const glyph = try readU32(bytes, offset + 8);
    return if (glyph <= std.math.maxInt(u16)) @intCast(glyph) else 0;
}

const VariationMapping = union(enum) { default, glyph: u16 };

fn cmapFormat14(table: []const u8, scalar: u21, selector: u21) Error!?VariationMapping {
    if (table.len < 10 or try readU16(table, 0) != 14) return error.InvalidFont;
    const length = try readU32(table, 2);
    const record_count = try readU32(table, 6);
    const record_bytes = std.math.mul(usize, @as(usize, record_count), 11) catch return error.InvalidFont;
    if (length < 10 or length > table.len or record_bytes > @as(usize, length) - 10) return error.InvalidFont;
    const bytes = table[0..length];
    var previous_selector: ?u32 = null;
    var selected_record: ?usize = null;
    var index: usize = 0;
    while (index < record_count) : (index += 1) {
        const record = 10 + index * 11;
        const value = try readU24(bytes, record);
        if (value > 0x10ffff or (previous_selector != null and value <= previous_selector.?)) return error.InvalidFont;
        previous_selector = value;
        if (value == selector) selected_record = record;
    }
    const record = selected_record orelse return null;

    const non_default_offset = try readU32(bytes, record + 7);
    if (non_default_offset != 0) {
        const mappings = try offset32Slice(bytes, non_default_offset, 4);
        const count = try readU32(mappings, 0);
        const size = std.math.mul(usize, @as(usize, count), 5) catch return error.InvalidFont;
        if (size > mappings.len - 4) return error.InvalidFont;
        var previous: ?u32 = null;
        var low: usize = 0;
        var high: usize = count;
        index = 0;
        while (index < count) : (index += 1) {
            const value = try readU24(mappings, 4 + index * 5);
            if (value > 0x10ffff or (previous != null and value <= previous.?)) return error.InvalidFont;
            previous = value;
        }
        while (low < high) {
            const middle = (low + high) / 2;
            if (try readU24(mappings, 4 + middle * 5) < scalar) low = middle + 1 else high = middle;
        }
        if (low < count and try readU24(mappings, 4 + low * 5) == scalar)
            return .{ .glyph = try readU16(mappings, 4 + low * 5 + 3) };
    }

    const default_offset = try readU32(bytes, record + 3);
    if (default_offset == 0) return null;
    const ranges = try offset32Slice(bytes, default_offset, 4);
    const count = try readU32(ranges, 0);
    const size = std.math.mul(usize, @as(usize, count), 4) catch return error.InvalidFont;
    if (size > ranges.len - 4) return error.InvalidFont;
    var previous_end: ?u32 = null;
    index = 0;
    while (index < count) : (index += 1) {
        const start = try readU24(ranges, 4 + index * 4);
        const end = std.math.add(u32, start, ranges[4 + index * 4 + 3]) catch return error.InvalidFont;
        if (end > 0x10ffff or (previous_end != null and start <= previous_end.?)) return error.InvalidFont;
        previous_end = end;
        if (scalar >= start and scalar <= end) return .default;
    }
    return null;
}

fn offset32Slice(base: []const u8, offset: u32, minimum: usize) Error![]const u8 {
    const start: usize = offset;
    if (start > base.len or minimum > base.len - start) return error.InvalidFont;
    return base[start..];
}

fn cmapFormat4(table: []const u8, scalar: u21) Error!u16 {
    if (scalar > 0xffff) return 0;
    if (table.len < 16 or try readU16(table, 0) != 4) return error.InvalidFont;
    const length = try readU16(table, 2);
    if (length < 16 or length > table.len) return error.InvalidFont;
    const bytes = table[0..length];
    const segment_count_x2 = try readU16(bytes, 6);
    if (segment_count_x2 == 0 or segment_count_x2 % 2 != 0) return error.InvalidFont;
    const segment_count = segment_count_x2 / 2;
    const end_codes = 14;
    const start_codes = end_codes + @as(usize, segment_count) * 2 + 2;
    const deltas = start_codes + @as(usize, segment_count) * 2;
    const range_offsets = deltas + @as(usize, segment_count) * 2;
    if (range_offsets + @as(usize, segment_count) * 2 > bytes.len) return error.InvalidFont;
    if (try readU16(bytes, end_codes + (@as(usize, segment_count) - 1) * 2) != 0xffff) return error.InvalidFont;
    var low: usize = 0;
    var high: usize = segment_count;
    while (low < high) {
        const middle = (low + high) / 2;
        if ((try readU16(bytes, end_codes + middle * 2)) < scalar) low = middle + 1 else high = middle;
    }
    if (low >= segment_count) return 0;
    const start = try readU16(bytes, start_codes + low * 2);
    if (scalar < start) return 0;
    const delta = try readI16(bytes, deltas + low * 2);
    const range = try readU16(bytes, range_offsets + low * 2);
    if (range == 0) return @truncate(@as(u32, scalar) +% @as(u16, @bitCast(delta)));
    const glyph_offset = range_offsets + low * 2 + range + @as(usize, scalar - start) * 2;
    const glyph = try readU16(bytes, glyph_offset);
    if (glyph == 0) return 0;
    return @truncate(@as(u32, glyph) +% @as(u16, @bitCast(delta)));
}

fn appendFormat12Coverage(table: []const u8, result: *Coverage) Error!void {
    if (table.len < 16) return error.InvalidFont;
    const length = try readU32(table, 4);
    const groups = try readU32(table, 12);
    if (length > table.len or 16 + @as(usize, groups) * 12 > length) return error.InvalidFont;
    var previous_end: ?u32 = null;
    var index: usize = 0;
    while (index < groups) : (index += 1) {
        const offset = 16 + index * 12;
        const first = try readU32(table, offset);
        const last = try readU32(table, offset + 4);
        if (first > last or last > 0x10ffff) return error.InvalidFont;
        if (previous_end) |end| if (first <= end) return error.InvalidFont;
        previous_end = last;
        result.includeRange(first, last);
    }
}

fn appendFormat13Coverage(table: []const u8, result: *Coverage) Error!void {
    if (table.len < 16 or try readU16(table, 0) != 13 or try readU16(table, 2) != 0) return error.InvalidFont;
    const length = try readU32(table, 4);
    const groups = try readU32(table, 12);
    if (length < 16 or length > table.len or 16 + @as(usize, groups) * 12 > length) return error.InvalidFont;
    var previous_end: ?u32 = null;
    var index: usize = 0;
    while (index < groups) : (index += 1) {
        const offset = 16 + index * 12;
        const first = try readU32(table, offset);
        const last = try readU32(table, offset + 4);
        const glyph = try readU32(table, offset + 8);
        if (first > last or last > 0x10ffff or glyph > std.math.maxInt(u16)) return error.InvalidFont;
        if (previous_end) |end| if (first <= end) return error.InvalidFont;
        previous_end = last;
        if (glyph != 0) result.includeRange(first, last);
    }
}

fn appendFormat10Coverage(table: []const u8, result: *Coverage) Error!void {
    if (table.len < 20 or try readU16(table, 0) != 10 or try readU16(table, 2) != 0) return error.InvalidFont;
    const length = try readU32(table, 4);
    const first = try readU32(table, 12);
    const count = try readU32(table, 16);
    const entries_size = std.math.mul(usize, @as(usize, count), 2) catch return error.InvalidFont;
    if (length < 20 or length > table.len or entries_size > @as(usize, length) - 20) return error.InvalidFont;
    if (count == 0) return;
    const last = std.math.add(u32, first, count - 1) catch return error.InvalidFont;
    if (last > 0x10ffff) return error.InvalidFont;
    result.includeRange(first, last);
}

fn appendFormat6Coverage(table: []const u8, result: *Coverage) Error!void {
    if (table.len < 10 or try readU16(table, 0) != 6) return error.InvalidFont;
    const length = try readU16(table, 2);
    const first = try readU16(table, 6);
    const count = try readU16(table, 8);
    if (length < 10 or length > table.len or 10 + @as(usize, count) * 2 > length) return error.InvalidFont;
    if (count != 0) result.includeRange(first, @as(u32, first) + count - 1);
}

fn appendFormat0Coverage(table: []const u8, result: *Coverage) Error!void {
    if (table.len < 262 or try readU16(table, 0) != 0) return error.InvalidFont;
    const length = try readU16(table, 2);
    if (length < 262 or length > table.len) return error.InvalidFont;
    var run_start: ?u32 = null;
    for (table[6..262], 0..) |glyph, scalar| {
        if (glyph != 0 and run_start == null) run_start = @intCast(scalar);
        if (glyph == 0 and run_start != null) {
            result.includeRange(run_start.?, @intCast(scalar - 1));
            run_start = null;
        }
    }
    if (run_start) |first| result.includeRange(first, 255);
}

fn appendFormat4Coverage(table: []const u8, result: *Coverage) Error!void {
    if (table.len < 16) return error.InvalidFont;
    const length = try readU16(table, 2);
    if (length > table.len) return error.InvalidFont;
    const segment_count = (try readU16(table, 6)) / 2;
    if (segment_count == 0) return error.InvalidFont;
    const end_codes = 14;
    const start_codes = end_codes + @as(usize, segment_count) * 2 + 2;
    const deltas = start_codes + @as(usize, segment_count) * 2;
    const range_offsets = deltas + @as(usize, segment_count) * 2;
    if (range_offsets + @as(usize, segment_count) * 2 > length) return error.InvalidFont;
    var index: usize = 0;
    while (index < segment_count) : (index += 1) {
        const first = try readU16(table, start_codes + index * 2);
        const last = try readU16(table, end_codes + index * 2);
        if (first > last) return error.InvalidFont;
        if (first == 0xffff and last == 0xffff) continue;
        result.includeRange(first, last);
    }
}

fn utf16BeToUtf8(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    if (bytes.len % 2 != 0) return error.InvalidFont;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const first = try readU16(bytes, index);
        index += 2;
        var scalar: u21 = first;
        if (first >= 0xd800 and first <= 0xdbff) {
            if (index >= bytes.len) return error.InvalidFont;
            const second = try readU16(bytes, index);
            index += 2;
            if (second < 0xdc00 or second > 0xdfff) return error.InvalidFont;
            scalar = 0x10000 + (@as(u21, first - 0xd800) << 10) + (second - 0xdc00);
        }
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(scalar, &encoded) catch return error.InvalidFont;
        try output.appendSlice(allocator, encoded[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

pub fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or 2 > bytes.len - offset) return error.InvalidFont;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

pub fn readI16(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try readU16(bytes, offset));
}

fn readU24(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or 3 > bytes.len - offset) return error.InvalidFont;
    return (@as(u32, bytes[offset]) << 16) | (@as(u32, bytes[offset + 1]) << 8) | bytes[offset + 2];
}

pub fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or 4 > bytes.len - offset) return error.InvalidFont;
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}

fn readF2Dot14(bytes: []const u8, offset: usize) Error!f32 {
    return @as(f32, @floatFromInt(try readI16(bytes, offset))) / 16384.0;
}
