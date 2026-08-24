const std = @import("std");
const Error = @import("../core/error.zig").Error;
const outline_types = @import("font_outline.zig");
const variation = @import("opentype_variation.zig");

const maximum_stack = 513;
const maximum_subroutine_depth = 10;
const maximum_steps = 1_000_000;
const maximum_outline_points = 1_048_576;
const maximum_outline_contours = 262_144;

const Index = struct {
    bytes: []const u8,
    count: u32,
    offsets: usize,
    data_start: usize,
    off_size: u8,
    end: usize,

    fn init(bytes: []const u8, start: usize, cff2: bool) Error!Index {
        const count_bytes: usize = if (cff2) 4 else 2;
        const count: u32 = if (cff2) try readU32(bytes, start) else try readU16(bytes, start);
        const count_end = std.math.add(usize, start, count_bytes) catch return error.InvalidFont;
        if (count == 0) return .{ .bytes = bytes, .count = 0, .offsets = count_end, .data_start = count_end, .off_size = 0, .end = count_end };
        if (count_end >= bytes.len) return error.InvalidFont;
        const off_size = bytes[count_end];
        if (off_size < 1 or off_size > 4) return error.InvalidFont;
        const offsets = std.math.add(usize, count_end, 1) catch return error.InvalidFont;
        const offset_count = std.math.add(usize, @as(usize, count), 1) catch return error.InvalidFont;
        const offsets_size = std.math.mul(usize, offset_count, @as(usize, off_size)) catch return error.InvalidFont;
        if (offsets > bytes.len or offsets_size > bytes.len - offsets) return error.InvalidFont;
        const data_start = offsets + offsets_size;
        var previous = try readOffset(bytes, offsets, off_size);
        if (previous != 1) return error.InvalidFont;
        var offset_index: usize = 1;
        while (offset_index < offset_count) : (offset_index += 1) {
            const entry = std.math.add(usize, offsets, std.math.mul(usize, offset_index, @as(usize, off_size)) catch return error.InvalidFont) catch return error.InvalidFont;
            const current = try readOffset(bytes, entry, off_size);
            if (current == 0 or current < previous) return error.InvalidFont;
            previous = current;
        }
        const final_offset = previous;
        const end = std.math.add(usize, data_start, final_offset - 1) catch return error.InvalidFont;
        if (end > bytes.len) return error.InvalidFont;
        return .{ .bytes = bytes, .count = count, .offsets = offsets, .data_start = data_start, .off_size = off_size, .end = end };
    }

    fn get(self: Index, item: u32) Error![]const u8 {
        if (item >= self.count) return error.InvalidFont;
        const first_entry = std.math.add(usize, self.offsets, std.math.mul(usize, @as(usize, item), @as(usize, self.off_size)) catch return error.InvalidFont) catch return error.InvalidFont;
        const last_entry = std.math.add(usize, first_entry, @as(usize, self.off_size)) catch return error.InvalidFont;
        const first = try readOffset(self.bytes, first_entry, self.off_size);
        const last = try readOffset(self.bytes, last_entry, self.off_size);
        if (first == 0 or last < first) return error.InvalidFont;
        const start = std.math.add(usize, self.data_start, first - 1) catch return error.InvalidFont;
        const end = std.math.add(usize, self.data_start, last - 1) catch return error.InvalidFont;
        if (end > self.end or start > end) return error.InvalidFont;
        return self.bytes[start..end];
    }
};

const DictInfo = struct {
    charstring_type: ?u8 = null,
    char_strings: ?u32 = null,
    charset: u32 = 0,
    private_size: u32 = 0,
    private_offset: u32 = 0,
    local_subrs: ?u32 = null,
    fd_array: ?u32 = null,
    fd_select: ?u32 = null,
    variation_store: ?u32 = null,
    variation_index: u16 = 0,
    initial_random_seed: u32 = 0,
    cid: bool = false,
};

const Program = struct {
    charstring: []const u8,
    global_subrs: Index,
    local_subrs: ?Index,
    cff2: bool,
    cff_bytes: []const u8 = &.{},
    charset: u32 = 0,
    glyph_count: u32 = 0,
    allow_seac: bool = false,
    variation_store: ?[]const u8 = null,
    variation_coordinates: []const i16 = &.{},
    default_variation_index: u16 = 0,
    initial_random_seed: u32 = 0,
};

const PrivateInfo = struct {
    local_subrs: ?Index,
    variation_index: u16,
    initial_random_seed: u32,
};

pub fn outline(
    allocator: std.mem.Allocator,
    font_bytes: []const u8,
    cff1_table: ?[]const u8,
    cff2_table: ?[]const u8,
    variation_coordinates: []const i16,
    glyph: u16,
) Error!outline_types.Outline {
    _ = font_bytes;
    const cff2 = cff2_table != null;
    const bytes = cff2_table orelse cff1_table orelse return error.InvalidFont;
    const program = if (cff2) try cff2Program(bytes, variation_coordinates, glyph) else try cff1Program(bytes, glyph);
    var state: State = .{ .allocator = allocator, .random_state = program.initial_random_seed };
    defer state.deinit();
    try state.selectVariation(program, program.default_variation_index);
    try state.execute(program, program.charstring, 0);
    try state.finishContour();
    if (state.points.items.len > maximum_outline_points or state.contours.items.len > maximum_outline_contours)
        return error.BudgetExceeded;
    for (state.points.items) |point| if (!finitePoint(point)) return error.InvalidFont;
    const points = try state.points.toOwnedSlice(allocator);
    errdefer allocator.free(points);
    const contours = try state.contours.toOwnedSlice(allocator);
    errdefer allocator.free(contours);
    return .{
        .points = points,
        .contour_ends = contours,
        .bounds = bounds(points),
        .curve_kind = .cubic,
    };
}

fn cff1Program(bytes: []const u8, glyph: u16) Error!Program {
    if (bytes.len < 4 or bytes[0] != 1 or bytes[1] != 0 or bytes[3] < 1 or bytes[3] > 4) return error.InvalidFont;
    const header_size = bytes[2];
    if (header_size < 4 or header_size > bytes.len) return error.InvalidFont;
    const names = try Index.init(bytes, header_size, false);
    if (names.count != 1) return error.InvalidFont;
    const top_dicts = try Index.init(bytes, names.end, false);
    if (top_dicts.count != 1) return error.InvalidFont;
    const strings = try Index.init(bytes, top_dicts.end, false);
    const global_subrs = try Index.init(bytes, strings.end, false);
    const top = try parseDict(try top_dicts.get(0), false);
    if ((top.charstring_type orelse 2) != 2) return error.InvalidFont;
    const charstrings = try Index.init(bytes, top.char_strings orelse return error.InvalidFont, false);
    if (glyph >= charstrings.count) return error.InvalidFont;
    const private = try selectedPrivate(bytes, top, glyph, charstrings.count, false);
    return .{
        .charstring = try charstrings.get(glyph),
        .global_subrs = global_subrs,
        .local_subrs = private.local_subrs,
        .cff2 = false,
        .cff_bytes = bytes,
        .charset = top.charset,
        .glyph_count = charstrings.count,
        .allow_seac = !top.cid,
        .initial_random_seed = private.initial_random_seed,
    };
}

fn cff2Program(bytes: []const u8, coordinates: []const i16, glyph: u16) Error!Program {
    if (bytes.len < 5 or bytes[0] != 2 or bytes[1] != 0) return error.InvalidFont;
    const header_size = bytes[2];
    const top_length = try readU16(bytes, 3);
    if (header_size != 5 or top_length == 0 or top_length > bytes.len - header_size) return error.InvalidFont;
    const top = try parseDict(bytes[header_size..][0..top_length], true);
    if (top.fd_array == null) return error.InvalidFont;
    const global_subrs_offset = std.math.add(usize, header_size, top_length) catch return error.InvalidFont;
    const global_subrs = try Index.init(bytes, global_subrs_offset, true);
    const charstrings = try Index.init(bytes, top.char_strings orelse return error.InvalidFont, true);
    if (glyph >= charstrings.count) return error.InvalidFont;
    const private = try selectedPrivate(bytes, top, glyph, charstrings.count, true);
    var store: ?[]const u8 = null;
    if (top.variation_store) |store_offset| {
        if (store_offset > bytes.len or bytes.len - store_offset < 2) return error.InvalidFont;
        const length = try readU16(bytes, store_offset);
        const start = @as(usize, store_offset) + 2;
        if (length == 0 or start > bytes.len or length > bytes.len - start) return error.InvalidFont;
        store = bytes[start..][0..length];
    } else if (!variation.allDefault(coordinates)) return error.InvalidFont;
    return .{
        .charstring = try charstrings.get(glyph),
        .global_subrs = global_subrs,
        .local_subrs = private.local_subrs,
        .cff2 = true,
        .variation_store = store,
        .variation_coordinates = coordinates,
        .default_variation_index = private.variation_index,
    };
}

fn selectedPrivate(bytes: []const u8, top: DictInfo, glyph: u16, glyph_count: u32, cff2: bool) Error!PrivateInfo {
    var private_size = top.private_size;
    var private_offset = top.private_offset;
    if (top.fd_array) |fd_array_offset| {
        const fd_array = try Index.init(bytes, fd_array_offset, cff2);
        if (fd_array.count == 0) return error.InvalidFont;
        const fd_index: u16 = if (cff2 and fd_array.count == 1) blk: {
            if (top.fd_select != null) return error.InvalidFont;
            break :blk 0;
        } else try selectFd(bytes, top.fd_select orelse return error.InvalidFont, glyph, glyph_count);
        if (fd_index >= fd_array.count) return error.InvalidFont;
        const fd = try parseDict(try fd_array.get(fd_index), cff2);
        private_size = fd.private_size;
        private_offset = fd.private_offset;
    } else if (cff2) {
        return error.InvalidFont;
    }
    if ((private_size == 0) != (private_offset == 0)) return error.InvalidFont;
    if (private_size == 0) return .{ .local_subrs = null, .variation_index = 0, .initial_random_seed = 0 };
    if (private_offset > bytes.len or private_size > bytes.len - private_offset) return error.InvalidFont;
    const private = bytes[private_offset..][0..private_size];
    const info = try parseDict(private, cff2);
    const local_subrs = if (info.local_subrs) |subr_relative| blk: {
        const subr_offset = std.math.add(usize, @as(usize, private_offset), @as(usize, subr_relative)) catch return error.InvalidFont;
        break :blk try Index.init(bytes, subr_offset, cff2);
    } else null;
    return .{ .local_subrs = local_subrs, .variation_index = info.variation_index, .initial_random_seed = info.initial_random_seed };
}

fn selectFd(bytes: []const u8, offset: usize, glyph: u16, glyph_count: u32) Error!u16 {
    if (offset >= bytes.len) return error.InvalidFont;
    return switch (bytes[offset]) {
        0 => blk: {
            const array_start = std.math.add(usize, offset, 1) catch return error.InvalidFont;
            if (glyph_count > bytes.len - array_start) return error.InvalidFont;
            break :blk bytes[offset + 1 + @as(usize, glyph)];
        },
        3 => blk: {
            const count = try readU16(bytes, offset + 1);
            if (count == 0) return error.InvalidFont;
            const records_start = std.math.add(usize, offset, 3) catch return error.InvalidFont;
            const records_size = std.math.mul(usize, @as(usize, count), 3) catch return error.InvalidFont;
            const sentinel_offset = std.math.add(usize, records_start, records_size) catch return error.InvalidFont;
            const sentinel = try readU16(bytes, sentinel_offset);
            if (sentinel != glyph_count) return error.InvalidFont;
            var selected: ?u16 = null;
            var previous_first: ?u16 = null;
            var index: usize = 0;
            while (index < count) : (index += 1) {
                const record = records_start + index * 3;
                const first = try readU16(bytes, record);
                if (previous_first) |previous| {
                    if (first <= previous) return error.InvalidFont;
                } else if (first != 0) return error.InvalidFont;
                const next = if (index + 1 < count) try readU16(bytes, record + 3) else sentinel;
                if (next <= first) return error.InvalidFont;
                if (glyph >= first and glyph < next) selected = bytes[record + 2];
                previous_first = first;
            }
            break :blk selected orelse return error.InvalidFont;
        },
        4 => blk: {
            const count = try readU32(bytes, offset + 1);
            if (count == 0) return error.InvalidFont;
            const records_start = std.math.add(usize, offset, 5) catch return error.InvalidFont;
            const records_size = std.math.mul(usize, @as(usize, count), 6) catch return error.InvalidFont;
            const sentinel_offset = std.math.add(usize, records_start, records_size) catch return error.InvalidFont;
            const sentinel = try readU32(bytes, sentinel_offset);
            if (sentinel != glyph_count) return error.InvalidFont;
            var selected: ?u16 = null;
            var previous_first: ?u32 = null;
            var index: usize = 0;
            while (index < count) : (index += 1) {
                const record = records_start + index * 6;
                const first = try readU32(bytes, record);
                if (previous_first) |previous| {
                    if (first <= previous) return error.InvalidFont;
                } else if (first != 0) return error.InvalidFont;
                const next = if (index + 1 < count) try readU32(bytes, record + 6) else sentinel;
                if (next <= first) return error.InvalidFont;
                if (glyph >= first and glyph < next) selected = try readU16(bytes, record + 4);
                previous_first = first;
            }
            break :blk selected orelse return error.InvalidFont;
        },
        else => error.InvalidFont,
    };
}

fn parseDict(bytes: []const u8, cff2: bool) Error!DictInfo {
    var info: DictInfo = .{};
    var seen: u16 = 0;
    var operands: [maximum_stack]f64 = undefined;
    var count: usize = 0;
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const byte = bytes[cursor];
        if (isDictNumber(byte)) {
            const stack_limit: usize = if (cff2) maximum_stack else 48;
            if (count == stack_limit) return error.InvalidFont;
            operands[count] = try dictNumber(bytes, &cursor);
            count += 1;
            continue;
        }
        cursor += 1;
        var operator: u16 = byte;
        if (byte == 12) {
            if (cursor >= bytes.len) return error.InvalidFont;
            operator = 0x0c00 | @as(u16, bytes[cursor]);
            cursor += 1;
        }
        switch (operator) {
            0x0c06 => {
                try markDictOperator(&seen, 7);
                if (count != 1) return error.InvalidFont;
                const value = try toOffset(operands[0]);
                if (value > std.math.maxInt(u8)) return error.InvalidFont;
                info.charstring_type = @intCast(value);
            },
            17 => {
                try markDictOperator(&seen, 0);
                if (count != 1) return error.InvalidFont;
                info.char_strings = try toOffset(operands[0]);
            },
            15 => {
                try markDictOperator(&seen, 9);
                if (count != 1) return error.InvalidFont;
                info.charset = try toOffset(operands[0]);
            },
            18 => {
                try markDictOperator(&seen, 1);
                if (count != 2) return error.InvalidFont;
                info.private_size = try toOffset(operands[0]);
                info.private_offset = try toOffset(operands[1]);
            },
            19 => {
                try markDictOperator(&seen, 2);
                if (count != 1) return error.InvalidFont;
                info.local_subrs = try toOffset(operands[0]);
            },
            22 => {
                try markDictOperator(&seen, 3);
                if (count != 1) return error.InvalidFont;
                const value = try toOffset(operands[0]);
                if (value > std.math.maxInt(u16)) return error.InvalidFont;
                info.variation_index = @intCast(value);
            },
            24 => {
                try markDictOperator(&seen, 4);
                if (count != 1) return error.InvalidFont;
                info.variation_store = try toOffset(operands[0]);
            },
            0x0c24 => {
                try markDictOperator(&seen, 5);
                if (count != 1) return error.InvalidFont;
                info.fd_array = try toOffset(operands[0]);
            },
            0x0c25 => {
                try markDictOperator(&seen, 6);
                if (count != 1) return error.InvalidFont;
                info.fd_select = try toOffset(operands[0]);
            },
            0x0c13 => {
                try markDictOperator(&seen, 8);
                if (count != 1) return error.InvalidFont;
                const seed = try toI32(operands[0]);
                info.initial_random_seed = @bitCast(seed);
            },
            0x0c1e => {
                try markDictOperator(&seen, 10);
                if (count != 3) return error.InvalidFont;
                info.cid = true;
            },
            else => {},
        }
        count = 0;
    }
    return info;
}

fn markDictOperator(seen: *u16, bit: u4) Error!void {
    const mask = @as(u16, 1) << bit;
    if (seen.* & mask != 0) return error.InvalidFont;
    seen.* |= mask;
}

// CFF 1 Appendix C predefined charsets, in GID order beginning at GID 1.
// ISOAdobe is the contiguous SID range 1...228 and does not need a table.
const expert_charset = [_]u16{
    1,   229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 13,  14,  15,  99,  239,
    240, 241, 242, 243, 244, 245, 246, 247, 248, 27,  28,  249, 250, 251, 252, 253,
    254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 109, 110, 267,
    268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283,
    284, 285, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299,
    300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314, 315,
    316, 317, 318, 158, 155, 163, 319, 320, 321, 322, 323, 324, 325, 326, 150, 164,
    169, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341,
    342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356, 357,
    358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373,
    374, 375, 376, 377, 378,
};

const expert_subset_charset = [_]u16{
    1,   231, 232, 235, 236, 237, 238, 13,  14,  15,  99,  239, 240, 241, 242,
    243, 244, 245, 246, 247, 248, 27,  28,  249, 250, 251, 253, 254, 255, 256,
    257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 109, 110, 267, 268, 269,
    270, 272, 300, 301, 302, 305, 314, 315, 158, 155, 163, 320, 321, 322, 323,
    324, 325, 326, 150, 164, 169, 327, 328, 329, 330, 331, 332, 333, 334, 335,
    336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346,
};

fn standardEncodingSid(code: u8) u16 {
    if (code >= 32 and code <= 126) return @as(u16, code) - 31;
    return switch (code) {
        161...175 => @as(u16, code) - 65,
        177...180 => @as(u16, code) - 66,
        182...189 => @as(u16, code) - 67,
        191 => 123,
        193...200 => @as(u16, code) - 69,
        202 => 132,
        203 => 133,
        205 => 134,
        206 => 135,
        207 => 136,
        208 => 137,
        225 => 138,
        227 => 139,
        232 => 140,
        233 => 141,
        234 => 142,
        235 => 143,
        241 => 144,
        245 => 145,
        248 => 146,
        249 => 147,
        250 => 148,
        251 => 149,
        else => 0,
    };
}

fn standardEncodingGlyph(program: Program, code: u8) Error!u16 {
    const sid = standardEncodingSid(code);
    if (sid == 0) return error.InvalidFont;
    return (try glyphForSid(program, sid)) orelse error.InvalidFont;
}

fn glyphForSid(program: Program, sid: u16) Error!?u16 {
    if (program.cff2 or program.glyph_count == 0) return error.InvalidFont;
    switch (program.charset) {
        0 => return if (sid <= 228 and sid < program.glyph_count) sid else null,
        1 => return predefinedGlyph(&expert_charset, program.glyph_count, sid),
        2 => return predefinedGlyph(&expert_subset_charset, program.glyph_count, sid),
        else => {},
    }

    const start: usize = @intCast(program.charset);
    if (start >= program.cff_bytes.len) return error.InvalidFont;
    var cursor = start + 1;
    var gid: u32 = 1;
    switch (program.cff_bytes[start]) {
        0 => while (gid < program.glyph_count) : (gid += 1) {
            const current = try readU16(program.cff_bytes, cursor);
            cursor = std.math.add(usize, cursor, 2) catch return error.InvalidFont;
            if (current == sid) return @intCast(gid);
        },
        1, 2 => |format| while (gid < program.glyph_count) {
            const first = try readU16(program.cff_bytes, cursor);
            cursor = std.math.add(usize, cursor, 2) catch return error.InvalidFont;
            const left: u32 = if (format == 1) blk: {
                if (cursor >= program.cff_bytes.len) return error.InvalidFont;
                const value = program.cff_bytes[cursor];
                cursor += 1;
                break :blk value;
            } else blk: {
                const value = try readU16(program.cff_bytes, cursor);
                cursor = std.math.add(usize, cursor, 2) catch return error.InvalidFont;
                break :blk value;
            };
            const span = std.math.add(u32, left, 1) catch return error.InvalidFont;
            if (span > program.glyph_count - gid or @as(u32, first) + left > std.math.maxInt(u16)) return error.InvalidFont;
            if (sid >= first and @as(u32, sid) <= @as(u32, first) + left)
                return @intCast(gid + @as(u32, sid) - first);
            gid += span;
        },
        else => return error.InvalidFont,
    }
    if (gid != program.glyph_count) return error.InvalidFont;
    return null;
}

fn predefinedGlyph(charset: []const u16, glyph_count: u32, sid: u16) ?u16 {
    for (charset, 0..) |candidate, index| {
        const gid: u32 = @intCast(index + 1);
        if (gid >= glyph_count) return null;
        if (candidate == sid) return @intCast(gid);
    }
    return null;
}

const State = struct {
    allocator: std.mem.Allocator,
    points: std.ArrayList(outline_types.Point) = .empty,
    contours: std.ArrayList(u32) = .empty,
    operands: [maximum_stack]f32 = undefined,
    operand_count: usize = 0,
    x: f32 = 0,
    y: f32 = 0,
    contour_start: usize = 0,
    contour_open: bool = false,
    stem_count: usize = 0,
    steps: usize = 0,
    terminated: bool = false,
    variation_index: ?u16 = null,
    region_scalars: []f32 = &.{},
    charstring_vsindex_used: bool = false,
    blend_used: bool = false,
    transient: [32]f32 = @splat(0),
    transient_set: [32]bool = @splat(false),
    random_state: u32 = 0,

    fn deinit(self: *State) void {
        self.points.deinit(self.allocator);
        self.contours.deinit(self.allocator);
        if (self.variation_index != null) self.allocator.free(self.region_scalars);
    }

    fn selectVariation(self: *State, program: Program, index: u16) Error!void {
        if (!program.cff2) return;
        if (self.variation_index != null and self.variation_index.? == index) return;
        const store = program.variation_store orelse {
            if (index != 0) return error.InvalidFont;
            return;
        };
        const scalars = try variation.dataRegionScalars(self.allocator, store, program.variation_coordinates, index);
        if (self.variation_index != null) self.allocator.free(self.region_scalars);
        self.region_scalars = scalars;
        self.variation_index = index;
    }

    fn execute(self: *State, program: Program, bytes: []const u8, depth: u8) Error!void {
        if (self.terminated) return;
        if (depth > maximum_subroutine_depth or bytes.len > 65_535) return error.InvalidFont;
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            self.steps += 1;
            if (self.steps > maximum_steps) return error.InvalidFont;
            const byte = bytes[cursor];
            if (isCharStringNumber(byte)) {
                const stack_limit: usize = if (program.cff2) maximum_stack else 48;
                if (self.operand_count == stack_limit) return error.InvalidFont;
                self.operands[self.operand_count] = try charStringNumber(bytes, &cursor);
                self.operand_count += 1;
                continue;
            }
            cursor += 1;
            switch (byte) {
                1, 3, 18, 23 => {
                    self.consumeWidthForStems(program.cff2);
                    if (self.operand_count < 2 or self.operand_count % 2 != 0) return error.InvalidFont;
                    self.stem_count = std.math.add(usize, self.stem_count, self.operand_count / 2) catch return error.InvalidFont;
                    self.clear();
                },
                19, 20 => {
                    self.consumeWidthForStems(program.cff2);
                    if (self.operand_count % 2 != 0) return error.InvalidFont;
                    self.stem_count = std.math.add(usize, self.stem_count, self.operand_count / 2) catch return error.InvalidFont;
                    self.clear();
                    const mask_bytes = (self.stem_count + 7) / 8;
                    if (mask_bytes > bytes.len - cursor) return error.InvalidFont;
                    cursor += mask_bytes;
                },
                4 => {
                    self.consumeMoveWidth(program.cff2, 1);
                    if (self.operand_count != 1) return error.InvalidFont;
                    self.y += self.operands[0];
                    try self.moveTo();
                    self.clear();
                },
                21 => {
                    self.consumeMoveWidth(program.cff2, 2);
                    if (self.operand_count != 2) return error.InvalidFont;
                    self.x += self.operands[0];
                    self.y += self.operands[1];
                    try self.moveTo();
                    self.clear();
                },
                22 => {
                    self.consumeMoveWidth(program.cff2, 1);
                    if (self.operand_count != 1) return error.InvalidFont;
                    self.x += self.operands[0];
                    try self.moveTo();
                    self.clear();
                },
                5 => {
                    if (self.operand_count < 2 or self.operand_count % 2 != 0) return error.InvalidFont;
                    var item: usize = 0;
                    while (item < self.operand_count) : (item += 2) {
                        self.x += self.operands[item];
                        self.y += self.operands[item + 1];
                        try self.lineTo();
                    }
                    self.clear();
                },
                6, 7 => {
                    if (self.operand_count == 0) return error.InvalidFont;
                    var horizontal = byte == 6;
                    for (self.operands[0..self.operand_count]) |value| {
                        if (horizontal) self.x += value else self.y += value;
                        try self.lineTo();
                        horizontal = !horizontal;
                    }
                    self.clear();
                },
                8 => {
                    if (self.operand_count < 6 or self.operand_count % 6 != 0) return error.InvalidFont;
                    var item: usize = 0;
                    while (item < self.operand_count) : (item += 6) try self.relativeCurve(self.operands[item..][0..6]);
                    self.clear();
                },
                10, 29 => {
                    if (self.operand_count == 0) return error.InvalidFont;
                    self.operand_count -= 1;
                    const number = try stackInteger(self.operands[self.operand_count]);
                    const index = if (byte == 10) program.local_subrs orelse return error.InvalidFont else program.global_subrs;
                    const biased = number + subroutineBias(index.count);
                    if (biased < 0 or @as(u32, @intCast(biased)) >= index.count) return error.InvalidFont;
                    try self.execute(program, try index.get(@intCast(biased)), depth + 1);
                    if (self.terminated) return;
                },
                11 => {
                    if (program.cff2 or depth == 0) return error.InvalidFont;
                    return;
                },
                14 => {
                    if (program.cff2) return error.InvalidFont;
                    if (self.operand_count == 1) self.consumeMoveWidth(false, 0) else if (self.operand_count == 5) {
                        @memmove(self.operands[0..4], self.operands[1..5]);
                        self.operand_count = 4;
                    }
                    if (self.operand_count == 4) {
                        if (!program.allow_seac or self.points.items.len != 0 or self.contour_open) return error.InvalidFont;
                        const adx = self.operands[0];
                        const ady = self.operands[1];
                        const base_code = try seacCode(self.operands[2]);
                        const accent_code = try seacCode(self.operands[3]);
                        self.clear();
                        try self.appendSeac(program, base_code, accent_code, adx, ady);
                    } else if (self.operand_count != 0) return error.InvalidFont;
                    self.clear();
                    try self.finishContour();
                    self.terminated = true;
                    return;
                },
                24 => {
                    if (self.operand_count < 8 or (self.operand_count - 2) % 6 != 0) return error.InvalidFont;
                    var item: usize = 0;
                    while (self.operand_count - item > 2) : (item += 6) try self.relativeCurve(self.operands[item..][0..6]);
                    self.x += self.operands[self.operand_count - 2];
                    self.y += self.operands[self.operand_count - 1];
                    try self.lineTo();
                    self.clear();
                },
                25 => {
                    if (self.operand_count < 8 or (self.operand_count - 6) % 2 != 0) return error.InvalidFont;
                    var item: usize = 0;
                    while (self.operand_count - item > 6) : (item += 2) {
                        self.x += self.operands[item];
                        self.y += self.operands[item + 1];
                        try self.lineTo();
                    }
                    try self.relativeCurve(self.operands[self.operand_count - 6 ..][0..6]);
                    self.clear();
                },
                26 => try self.vvCurve(),
                27 => try self.hhCurve(),
                30, 31 => try self.alternatingCurve(byte == 31),
                12 => {
                    if (cursor >= bytes.len) return error.InvalidFont;
                    const escaped = bytes[cursor];
                    cursor += 1;
                    try self.escape(program, escaped);
                },
                15 => {
                    if (!program.cff2 or self.operand_count != 1 or self.charstring_vsindex_used or self.blend_used) return error.InvalidFont;
                    const raw = self.operands[0];
                    if (!std.math.isFinite(raw) or raw < 0 or raw > std.math.maxInt(u16) or @trunc(raw) != raw) return error.InvalidFont;
                    self.clear();
                    try self.selectVariation(program, @intFromFloat(raw));
                    self.charstring_vsindex_used = true;
                },
                16 => {
                    if (!program.cff2) return error.InvalidFont;
                    try self.blend();
                    self.blend_used = true;
                },
                else => return error.InvalidFont,
            }
        }
        if (!program.cff2 and !self.terminated) return error.InvalidFont;
    }

    fn appendSeac(self: *State, program: Program, base_code: u8, accent_code: u8, adx: f32, ady: f32) Error!void {
        const base_glyph = try standardEncodingGlyph(program, base_code);
        const accent_glyph = try standardEncodingGlyph(program, accent_code);
        try self.appendComponent(program, base_glyph, 0, 0);
        try self.appendComponent(program, accent_glyph, adx, ady);
    }

    fn appendComponent(self: *State, parent: Program, glyph: u16, offset_x: f32, offset_y: f32) Error!void {
        var program = try cff1Program(parent.cff_bytes, glyph);
        program.allow_seac = false;
        var component: State = .{
            .allocator = self.allocator,
            .steps = self.steps,
            .random_state = program.initial_random_seed,
        };
        defer component.deinit();
        try component.execute(program, program.charstring, 0);
        if (!component.terminated) return error.InvalidFont;
        try component.finishContour();
        self.steps = component.steps;

        const point_start = self.points.items.len;
        const final_point_count = std.math.add(usize, point_start, component.points.items.len) catch return error.BudgetExceeded;
        const final_contour_count = std.math.add(usize, self.contours.items.len, component.contours.items.len) catch return error.BudgetExceeded;
        if (final_point_count > maximum_outline_points or final_contour_count > maximum_outline_contours) return error.BudgetExceeded;
        try self.points.ensureUnusedCapacity(self.allocator, component.points.items.len);
        for (component.points.items) |point| {
            const transformed: outline_types.Point = .{
                .x = point.x + offset_x,
                .y = point.y + offset_y,
                .on_curve = point.on_curve,
            };
            if (!finitePoint(transformed)) return error.InvalidFont;
            self.points.appendAssumeCapacity(transformed);
        }
        try self.contours.ensureUnusedCapacity(self.allocator, component.contours.items.len);
        for (component.contours.items) |contour| self.contours.appendAssumeCapacity(@intCast(point_start + contour));
    }

    fn consumeWidthForStems(self: *State, cff2: bool) void {
        if (!cff2 and self.operand_count % 2 == 1) {
            @memmove(self.operands[0 .. self.operand_count - 1], self.operands[1..self.operand_count]);
            self.operand_count -= 1;
        }
    }

    fn consumeMoveWidth(self: *State, cff2: bool, required: usize) void {
        if (!cff2 and self.operand_count > required) {
            @memmove(self.operands[0 .. self.operand_count - 1], self.operands[1..self.operand_count]);
            self.operand_count -= 1;
        }
    }

    fn moveTo(self: *State) Error!void {
        try self.finishContour();
        try self.validatePoints(&.{ self.x, self.y });
        try self.reservePoints(1);
        self.contour_start = self.points.items.len;
        self.contour_open = true;
        try self.points.append(self.allocator, .{ .x = self.x, .y = self.y, .on_curve = true });
    }

    fn lineTo(self: *State) Error!void {
        if (!self.contour_open) return error.InvalidFont;
        try self.validatePoints(&.{ self.x, self.y });
        try self.reservePoints(1);
        try self.points.append(self.allocator, .{ .x = self.x, .y = self.y, .on_curve = true });
    }

    fn curveTo(self: *State, c1x: f32, c1y: f32, c2x: f32, c2y: f32, end_x: f32, end_y: f32) Error!void {
        if (!self.contour_open) return error.InvalidFont;
        try self.validatePoints(&.{ c1x, c1y, c2x, c2y, end_x, end_y });
        try self.reservePoints(3);
        try self.points.append(self.allocator, .{ .x = c1x, .y = c1y, .on_curve = false });
        try self.points.append(self.allocator, .{ .x = c2x, .y = c2y, .on_curve = false });
        try self.points.append(self.allocator, .{ .x = end_x, .y = end_y, .on_curve = true });
        self.x = end_x;
        self.y = end_y;
    }

    fn relativeCurve(self: *State, values: []const f32) Error!void {
        const c1x = self.x + values[0];
        const c1y = self.y + values[1];
        const c2x = c1x + values[2];
        const c2y = c1y + values[3];
        try self.curveTo(c1x, c1y, c2x, c2y, c2x + values[4], c2y + values[5]);
    }

    fn vvCurve(self: *State) Error!void {
        if (self.operand_count < 4) return error.InvalidFont;
        var item: usize = 0;
        var dx1: f32 = 0;
        if (self.operand_count % 4 == 1) {
            dx1 = self.operands[0];
            item = 1;
        }
        while (item + 3 < self.operand_count) : (item += 4) {
            const c1x = self.x + dx1;
            const c1y = self.y + self.operands[item];
            const c2x = c1x + self.operands[item + 1];
            const c2y = c1y + self.operands[item + 2];
            try self.curveTo(c1x, c1y, c2x, c2y, c2x, c2y + self.operands[item + 3]);
            dx1 = 0;
        }
        if (item != self.operand_count) return error.InvalidFont;
        self.clear();
    }

    fn hhCurve(self: *State) Error!void {
        if (self.operand_count < 4) return error.InvalidFont;
        var item: usize = 0;
        var dy1: f32 = 0;
        if (self.operand_count % 4 == 1) {
            dy1 = self.operands[0];
            item = 1;
        }
        while (item + 3 < self.operand_count) : (item += 4) {
            const c1x = self.x + self.operands[item];
            const c1y = self.y + dy1;
            const c2x = c1x + self.operands[item + 1];
            const c2y = c1y + self.operands[item + 2];
            try self.curveTo(c1x, c1y, c2x, c2y, c2x + self.operands[item + 3], c2y);
            dy1 = 0;
        }
        if (item != self.operand_count) return error.InvalidFont;
        self.clear();
    }

    fn alternatingCurve(self: *State, horizontal_first: bool) Error!void {
        if (self.operand_count < 4) return error.InvalidFont;
        var item: usize = 0;
        var horizontal = horizontal_first;
        while (item + 3 < self.operand_count) {
            const remaining = self.operand_count - item;
            if (horizontal) {
                const c1x = self.x + self.operands[item];
                const c1y = self.y;
                const c2x = c1x + self.operands[item + 1];
                const c2y = c1y + self.operands[item + 2];
                const extra = if (remaining == 5) self.operands[item + 4] else 0;
                try self.curveTo(c1x, c1y, c2x, c2y, c2x + extra, c2y + self.operands[item + 3]);
            } else {
                const c1x = self.x;
                const c1y = self.y + self.operands[item];
                const c2x = c1x + self.operands[item + 1];
                const c2y = c1y + self.operands[item + 2];
                const extra = if (remaining == 5) self.operands[item + 4] else 0;
                try self.curveTo(c1x, c1y, c2x, c2y, c2x + self.operands[item + 3], c2y + extra);
            }
            item += if (remaining == 5) 5 else 4;
            horizontal = !horizontal;
        }
        if (item != self.operand_count) return error.InvalidFont;
        self.clear();
    }

    fn escape(self: *State, program: Program, operator: u8) Error!void {
        switch (operator) {
            34 => {
                if (self.operand_count != 7) return error.InvalidFont;
                const start_x = self.x;
                const start_y = self.y;
                var first = [_]f32{ self.operands[0], 0, self.operands[1], self.operands[2], self.operands[3], 0 };
                try self.relativeCurve(&first);
                var second = [_]f32{ self.operands[4], 0, self.operands[5], -self.operands[2], self.operands[6], start_y - self.y };
                try self.relativeCurve(&second);
                _ = start_x;
            },
            35 => {
                if (self.operand_count != 13) return error.InvalidFont;
                try self.relativeCurve(self.operands[0..6]);
                try self.relativeCurve(self.operands[6..12]);
            },
            36 => {
                if (self.operand_count != 9) return error.InvalidFont;
                const start_y = self.y;
                var first = [_]f32{ self.operands[0], self.operands[1], self.operands[2], self.operands[3], self.operands[4], 0 };
                try self.relativeCurve(&first);
                var second = [_]f32{ self.operands[5], 0, self.operands[6], self.operands[7], self.operands[8], start_y - self.y - self.operands[7] };
                try self.relativeCurve(&second);
            },
            37 => {
                if (self.operand_count != 11) return error.InvalidFont;
                const start_x = self.x;
                const start_y = self.y;
                try self.relativeCurve(self.operands[0..6]);
                var second = [_]f32{ self.operands[6], self.operands[7], self.operands[8], self.operands[9], 0, 0 };
                const dx = self.x + second[0] + second[2] - start_x;
                const dy = self.y + second[1] + second[3] - start_y;
                if (@abs(dx) > @abs(dy)) second[4] = self.operands[10] else second[5] = self.operands[10];
                try self.relativeCurve(&second);
            },
            else => {
                if (program.cff2) return error.InvalidFont;
                return self.escapeCff1(operator);
            },
        }
        self.clear();
    }

    fn escapeCff1(self: *State, operator: u8) Error!void {
        switch (operator) {
            0 => if (self.operand_count != 0) return error.InvalidFont,
            3, 4, 10, 11, 12, 15, 24 => {
                if (self.operand_count < 2) return error.InvalidFont;
                const left = self.operands[self.operand_count - 2];
                const right = self.operands[self.operand_count - 1];
                const result: f32 = switch (operator) {
                    3 => if (left != 0 and right != 0) 1 else 0,
                    4 => if (left != 0 or right != 0) 1 else 0,
                    10 => left + right,
                    11 => left - right,
                    12 => if (right == 0) return error.InvalidFont else left / right,
                    15 => if (left == right) 1 else 0,
                    24 => left * right,
                    else => unreachable,
                };
                if (!std.math.isFinite(result)) return error.InvalidFont;
                self.operand_count -= 1;
                self.operands[self.operand_count - 1] = result;
            },
            5, 9, 14, 26 => {
                if (self.operand_count == 0) return error.InvalidFont;
                const value = self.operands[self.operand_count - 1];
                const result: f32 = switch (operator) {
                    5 => if (value == 0) 1 else 0,
                    9 => @abs(value),
                    14 => -value,
                    26 => if (value < 0) return error.InvalidFont else @sqrt(value),
                    else => unreachable,
                };
                if (!std.math.isFinite(result)) return error.InvalidFont;
                self.operands[self.operand_count - 1] = result;
            },
            18 => {
                if (self.operand_count == 0) return error.InvalidFont;
                self.operand_count -= 1;
            },
            20 => {
                if (self.operand_count < 2) return error.InvalidFont;
                const index = try stackInteger(self.operands[self.operand_count - 1]);
                if (index < 0) return error.InvalidFont;
                const selected: usize = @intCast(index);
                if (selected >= self.transient.len) return error.InvalidFont;
                self.transient[selected] = self.operands[self.operand_count - 2];
                self.transient_set[selected] = true;
                self.operand_count -= 2;
            },
            21 => {
                if (self.operand_count == 0) return error.InvalidFont;
                const index = try stackInteger(self.operands[self.operand_count - 1]);
                if (index < 0) return error.InvalidFont;
                const selected: usize = @intCast(index);
                if (selected >= self.transient.len) return error.InvalidFont;
                if (!self.transient_set[selected]) return error.InvalidFont;
                self.operands[self.operand_count - 1] = self.transient[selected];
            },
            22 => {
                if (self.operand_count < 4) return error.InvalidFont;
                const start = self.operand_count - 4;
                const selected = if (self.operands[start + 2] <= self.operands[start + 3]) self.operands[start] else self.operands[start + 1];
                self.operands[start] = selected;
                self.operand_count -= 3;
            },
            23 => {
                if (self.operand_count == 48) return error.InvalidFont;
                self.random_state = self.random_state *% 1_664_525 +% 1_013_904_223;
                const numerator = @as(u32, self.random_state >> 8) + 1;
                self.operands[self.operand_count] = @as(f32, @floatFromInt(numerator)) / 16_777_216.0;
                self.operand_count += 1;
            },
            27 => {
                if (self.operand_count == 0 or self.operand_count == 48) return error.InvalidFont;
                self.operands[self.operand_count] = self.operands[self.operand_count - 1];
                self.operand_count += 1;
            },
            28 => {
                if (self.operand_count < 2) return error.InvalidFont;
                std.mem.swap(f32, &self.operands[self.operand_count - 2], &self.operands[self.operand_count - 1]);
            },
            29 => {
                if (self.operand_count == 0) return error.InvalidFont;
                self.operand_count -= 1;
                var distance = try stackInteger(self.operands[self.operand_count]);
                if (distance < 0) distance = 0;
                const selected: usize = @intCast(distance);
                if (selected >= self.operand_count or self.operand_count == 48) return error.InvalidFont;
                self.operands[self.operand_count] = self.operands[self.operand_count - 1 - selected];
                self.operand_count += 1;
            },
            30 => {
                if (self.operand_count < 2) return error.InvalidFont;
                const amount = try stackInteger(self.operands[self.operand_count - 1]);
                const count = try stackInteger(self.operands[self.operand_count - 2]);
                self.operand_count -= 2;
                if (count < 0) return error.InvalidFont;
                if (count == 0) return;
                const item_count: usize = @intCast(count);
                if (item_count > self.operand_count) return error.InvalidFont;
                const normalized: usize = @intCast(@mod(amount, count));
                if (normalized == 0) return;
                const start = self.operand_count - item_count;
                var rotated: [48]f32 = undefined;
                for (self.operands[start..self.operand_count], 0..) |value, index|
                    rotated[(index + normalized) % item_count] = value;
                @memcpy(self.operands[start..self.operand_count], rotated[0..item_count]);
            },
            else => return error.InvalidFont,
        }
    }

    fn blend(self: *State) Error!void {
        if (self.operand_count == 0 or self.variation_index == null) return error.InvalidFont;
        const count_float = self.operands[self.operand_count - 1];
        if (!std.math.isFinite(count_float) or count_float <= 0 or count_float > maximum_stack or @trunc(count_float) != count_float) return error.InvalidFont;
        const count: usize = @intFromFloat(count_float);
        const region_count = self.region_scalars.len;
        const blended_operand_count = std.math.mul(usize, count, region_count + 1) catch return error.InvalidFont;
        const required = std.math.add(usize, blended_operand_count, 1) catch return error.InvalidFont;
        if (count == 0 or required > self.operand_count) return error.InvalidFont;
        const start = self.operand_count - required;
        var item: usize = 0;
        while (item < count) : (item += 1) {
            var value = self.operands[start + item];
            for (self.region_scalars, 0..) |scalar, region|
                value += self.operands[start + count + item * region_count + region] * scalar;
            self.operands[start + item] = value;
        }
        self.operand_count = start + count;
    }

    fn finishContour(self: *State) Error!void {
        if (!self.contour_open) return;
        if (self.points.items.len > self.contour_start) {
            if (self.contours.items.len >= maximum_outline_contours) return error.BudgetExceeded;
            try self.contours.append(self.allocator, @intCast(self.points.items.len - 1));
        }
        self.contour_open = false;
    }

    fn reservePoints(self: *State, count: usize) Error!void {
        const next = std.math.add(usize, self.points.items.len, count) catch return error.BudgetExceeded;
        if (next > maximum_outline_points) return error.BudgetExceeded;
    }

    fn validatePoints(_: *State, values: []const f32) Error!void {
        for (values) |value| if (!std.math.isFinite(value)) return error.InvalidFont;
    }

    fn clear(self: *State) void {
        self.operand_count = 0;
    }
};

fn finitePoint(point: outline_types.Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn bounds(points: []const outline_types.Point) outline_types.Bounds {
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
        .x_min = clampI16(minimum_x),
        .y_min = clampI16(minimum_y),
        .x_max = clampI16(maximum_x),
        .y_max = clampI16(maximum_y),
    };
}

fn clampI16(value: f32) i16 {
    return @intFromFloat(std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn subroutineBias(count: u32) i32 {
    return if (count < 1240) 107 else if (count < 33900) 1131 else 32768;
}

fn stackInteger(value: f32) Error!i32 {
    if (!std.math.isFinite(value) or @trunc(value) != value) return error.InvalidFont;
    const widened: f64 = value;
    if (widened < @as(f64, @floatFromInt(std.math.minInt(i32))) or widened > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return error.InvalidFont;
    return @intFromFloat(value);
}

fn seacCode(value: f32) Error!u8 {
    const integer = try stackInteger(value);
    if (integer < 0 or integer > std.math.maxInt(u8)) return error.InvalidFont;
    return @intCast(integer);
}

fn isDictNumber(byte: u8) bool {
    return byte == 28 or byte == 29 or byte == 30 or byte == 255 or byte >= 32;
}

fn isCharStringNumber(byte: u8) bool {
    return byte == 28 or byte == 255 or byte >= 32;
}

fn dictNumber(bytes: []const u8, cursor: *usize) Error!f64 {
    const byte = bytes[cursor.*];
    cursor.* += 1;
    if (byte == 28) {
        const value = try readI16(bytes, cursor.*);
        cursor.* += 2;
        return value;
    }
    if (byte == 29) {
        const value: i32 = @bitCast(try readU32(bytes, cursor.*));
        cursor.* += 4;
        return value;
    }
    if (byte == 30) return try realNumber(bytes, cursor);
    if (byte == 255) {
        const value: i32 = @bitCast(try readU32(bytes, cursor.*));
        cursor.* += 4;
        return @as(f64, @floatFromInt(value)) / 65536.0;
    }
    return integerNumber(bytes, cursor, byte);
}

fn charStringNumber(bytes: []const u8, cursor: *usize) Error!f32 {
    const byte = bytes[cursor.*];
    cursor.* += 1;
    if (byte == 28) {
        const value = try readI16(bytes, cursor.*);
        cursor.* += 2;
        return @floatFromInt(value);
    }
    if (byte == 255) {
        const value: i32 = @bitCast(try readU32(bytes, cursor.*));
        cursor.* += 4;
        return @as(f32, @floatFromInt(value)) / 65536.0;
    }
    return @floatCast(try integerNumber(bytes, cursor, byte));
}

fn integerNumber(bytes: []const u8, cursor: *usize, byte: u8) Error!f64 {
    if (byte >= 32 and byte <= 246) return @as(i16, byte) - 139;
    if (byte >= 247 and byte <= 250) {
        if (cursor.* >= bytes.len) return error.InvalidFont;
        const result = (@as(i32, byte) - 247) * 256 + bytes[cursor.*] + 108;
        cursor.* += 1;
        return result;
    }
    if (byte >= 251 and byte <= 254) {
        if (cursor.* >= bytes.len) return error.InvalidFont;
        const result = -((@as(i32, byte) - 251) * 256) - bytes[cursor.*] - 108;
        cursor.* += 1;
        return result;
    }
    return error.InvalidFont;
}

fn realNumber(bytes: []const u8, cursor: *usize) Error!f64 {
    var buffer: [96]u8 = undefined;
    var length: usize = 0;
    var done = false;
    while (!done) {
        if (cursor.* >= bytes.len) return error.InvalidFont;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        const nibbles = [_]u8{ byte >> 4, byte & 0xf };
        for (nibbles) |nibble| switch (nibble) {
            0...9 => {
                if (length == buffer.len) return error.InvalidFont;
                buffer[length] = '0' + nibble;
                length += 1;
            },
            0xa => {
                if (length == buffer.len) return error.InvalidFont;
                buffer[length] = '.';
                length += 1;
            },
            0xb => {
                if (length == buffer.len) return error.InvalidFont;
                buffer[length] = 'E';
                length += 1;
            },
            0xc => {
                if (length + 2 > buffer.len) return error.InvalidFont;
                buffer[length] = 'E';
                buffer[length + 1] = '-';
                length += 2;
            },
            0xe => {
                if (length == buffer.len) return error.InvalidFont;
                buffer[length] = '-';
                length += 1;
            },
            0xf => {
                done = true;
                break;
            },
            else => return error.InvalidFont,
        };
    }
    return std.fmt.parseFloat(f64, buffer[0..length]) catch return error.InvalidFont;
}

fn toOffset(value: f64) Error!u32 {
    if (!std.math.isFinite(value) or value < 0 or value > std.math.maxInt(u32) or @trunc(value) != value) return error.InvalidFont;
    return @intFromFloat(value);
}

fn toI32(value: f64) Error!i32 {
    if (!std.math.isFinite(value) or value < @as(f64, @floatFromInt(std.math.minInt(i32))) or value > @as(f64, @floatFromInt(std.math.maxInt(i32))) or @trunc(value) != value) return error.InvalidFont;
    return @intFromFloat(value);
}

fn readOffset(bytes: []const u8, offset: usize, size: u8) Error!usize {
    if (offset > bytes.len or size > bytes.len - offset) return error.InvalidFont;
    var result: usize = 0;
    var index: usize = 0;
    while (index < size) : (index += 1) result = (result << 8) | bytes[offset + index];
    return result;
}

fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or 2 > bytes.len - offset) return error.InvalidFont;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readI16(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try readU16(bytes, offset));
}

fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or 4 > bytes.len - offset) return error.InvalidFont;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
