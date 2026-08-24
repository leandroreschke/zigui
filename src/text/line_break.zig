const std = @import("std");
const Error = @import("../core/error.zig").Error;
const data = @import("unicode_data.zig");

pub const Opportunity = enum { prohibited, allowed, mandatory };

pub const Boundary = struct {
    utf8_offset: usize,
    opportunity: Opportunity,
};

pub const Analysis = struct {
    boundaries: []Boundary,

    pub fn deinit(self: *Analysis, allocator: std.mem.Allocator) void {
        allocator.free(self.boundaries);
        self.* = undefined;
    }

    pub fn at(self: Analysis, utf8_offset: usize) Opportunity {
        var low: usize = 0;
        var high = self.boundaries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const boundary = self.boundaries[middle];
            if (utf8_offset < boundary.utf8_offset) high = middle else if (utf8_offset > boundary.utf8_offset) low = middle + 1 else return boundary.opportunity;
        }
        return .prohibited;
    }
};

const Unit = struct {
    scalar: u21,
    start: usize,
    end: usize,
    raw: data.LineClass,
    class: data.LineClass,
};

pub fn analyze(allocator: std.mem.Allocator, text: []const u8) Error!Analysis {
    var units: std.ArrayList(Unit) = .empty;
    defer units.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[cursor]) catch return error.InvalidUtf8;
        if (cursor + length > text.len) return error.InvalidUtf8;
        const scalar = std.unicode.utf8Decode(text[cursor..][0..length]) catch return error.InvalidUtf8;
        const raw = data.properties(scalar).line;
        try units.append(allocator, .{ .scalar = scalar, .start = cursor, .end = cursor + length, .raw = raw, .class = resolveAmbiguous(scalar, raw) });
        cursor += length;
    }
    resolveCombining(units.items);

    const result = try allocator.alloc(Boundary, units.items.len + 1);
    errdefer allocator.free(result);
    result[0] = .{ .utf8_offset = 0, .opportunity = .prohibited };
    var index: usize = 1;
    while (index < units.items.len) : (index += 1) result[index] = .{
        .utf8_offset = units.items[index].start,
        .opportunity = boundaryAt(units.items, index),
    };
    result[units.items.len] = .{ .utf8_offset = text.len, .opportunity = .mandatory };
    return .{ .boundaries = result };
}

pub fn between(previous: u21, current: u21) Opportunity {
    var units = [_]Unit{
        .{ .scalar = previous, .start = 0, .end = 1, .raw = data.properties(previous).line, .class = resolveAmbiguous(previous, data.properties(previous).line) },
        .{ .scalar = current, .start = 1, .end = 2, .raw = data.properties(current).line, .class = resolveAmbiguous(current, data.properties(current).line) },
    };
    resolveCombining(&units);
    return boundaryAt(&units, 1);
}

fn resolveAmbiguous(scalar: u21, value: data.LineClass) data.LineClass {
    return switch (value) {
        .ai, .sg, .xx => .al,
        .sa => switch (data.properties(scalar).category) {
            .mn, .mc => .cm,
            else => .al,
        },
        .cj => .ns,
        else => value,
    };
}

fn resolveCombining(units: []Unit) void {
    for (units, 0..) |*unit, index| {
        if (unit.class != .cm and unit.class != .zwj) continue;
        if (index == 0 or isHard(units[index - 1].class) or units[index - 1].class == .sp or units[index - 1].class == .zw)
            unit.class = .al
        else
            unit.class = units[index - 1].class;
    }
}

fn boundaryAt(units: []const Unit, index: usize) Opportunity {
    const previous = units[index - 1];
    const current = units[index];
    const left = previous.class;
    const right = current.class;

    if (left == .bk) return .mandatory;
    if (left == .cr and right == .lf) return .prohibited;
    if (left == .cr or left == .lf or left == .nl) return .mandatory;
    if (isHard(right)) return .prohibited;
    if (right == .sp or right == .zw) return .prohibited;
    if (previous.raw == .zw) return .allowed;
    if (previous.raw == .zwj) return .prohibited;
    if (left == .wj or right == .wj) return .prohibited;
    if (left == .gl) return .prohibited;
    if (right == .gl and left != .sp and left != .ba and left != .hy) return .prohibited;
    if (isClosing(right)) return .prohibited;

    const non_space_index = previousNonSpace(units, index);
    const non_space = units[non_space_index].class;
    if (non_space == .op) return .prohibited;
    if (non_space == .qu and right == .op) return .prohibited;
    if ((non_space == .cl or non_space == .cp) and right == .ns) return .prohibited;
    if (non_space == .b2 and right == .b2) return .prohibited;
    if (left == .sp) return .allowed;

    if (left == .qu or right == .qu) return .prohibited;
    if (left == .cb or right == .cb) return .allowed;
    if (right == .ba or right == .hy or right == .ns or left == .bb) return .prohibited;
    if (left == .hl and (right == .hy or right == .ba)) return .prohibited;
    if (right == .in) return .prohibited;
    if ((isAlphabetic(left) and right == .nu) or (left == .nu and isAlphabetic(right))) return .prohibited;
    if ((left == .pr and isIdeographicEmoji(right)) or (isIdeographicEmoji(left) and right == .po)) return .prohibited;
    if (((left == .pr or left == .po) and isAlphabetic(right)) or (isAlphabetic(left) and (right == .pr or right == .po))) return .prohibited;
    if (numericSequenceNoBreak(left, right)) return .prohibited;
    if (hangulNoBreak(left, right)) return .prohibited;
    if ((isHangul(left) and (right == .in or right == .po)) or (left == .pr and isHangul(right))) return .prohibited;
    if (isAlphabetic(left) and isAlphabetic(right)) return .prohibited;
    if (brahmicNoBreak(left, right)) return .prohibited;
    if (left == .is and isAlphabetic(right)) return .prohibited;
    if (nonEastAsianOpening(units[index].scalar, right) and (isAlphabetic(left) or left == .nu)) return .prohibited;
    if (nonEastAsianClosing(units[index - 1].scalar, left) and (isAlphabetic(right) or right == .nu)) return .prohibited;
    if (left == .ri and right == .ri) return if (regionalCount(units, index) % 2 == 1) .prohibited else .allowed;
    if (left == .eb and right == .em) return .prohibited;
    return .allowed;
}

fn previousNonSpace(units: []const Unit, boundary: usize) usize {
    var index = boundary - 1;
    while (index > 0 and units[index].class == .sp) index -= 1;
    return index;
}

fn isHard(value: data.LineClass) bool {
    return value == .bk or value == .cr or value == .lf or value == .nl;
}

fn isClosing(value: data.LineClass) bool {
    return value == .cl or value == .cp or value == .ex or value == .is or value == .sy;
}

fn isAlphabetic(value: data.LineClass) bool {
    return value == .al or value == .hl;
}

fn isIdeographicEmoji(value: data.LineClass) bool {
    return value == .id or value == .eb or value == .em;
}

fn numericSequenceNoBreak(left: data.LineClass, right: data.LineClass) bool {
    if ((left == .cl or left == .cp or left == .nu) and (right == .po or right == .pr)) return true;
    if ((left == .po or left == .pr) and (right == .op or right == .nu)) return true;
    if ((left == .hy or left == .is or left == .nu or left == .sy) and right == .nu) return true;
    return false;
}

fn hangulNoBreak(left: data.LineClass, right: data.LineClass) bool {
    if (left == .jl and (right == .jl or right == .jv or right == .h2 or right == .h3)) return true;
    if ((left == .jv or left == .h2) and (right == .jv or right == .jt)) return true;
    if ((left == .jt or left == .h3) and right == .jt) return true;
    return false;
}

fn isHangul(value: data.LineClass) bool {
    return value == .jl or value == .jv or value == .jt or value == .h2 or value == .h3;
}

fn brahmicNoBreak(left: data.LineClass, right: data.LineClass) bool {
    if (left == .ap and (right == .ak or right == .as)) return true;
    if ((left == .ak or left == .as) and (right == .vf or right == .vi)) return true;
    if ((left == .ak or left == .as) and (right == .ak or right == .as)) return true;
    return false;
}

fn nonEastAsianOpening(scalar: u21, class: data.LineClass) bool {
    if (class != .op) return false;
    const width = data.properties(scalar).east_asian_width;
    return width != .f and width != .w and width != .h;
}

fn nonEastAsianClosing(scalar: u21, class: data.LineClass) bool {
    if (class != .cp) return false;
    const width = data.properties(scalar).east_asian_width;
    return width != .f and width != .w and width != .h;
}

fn regionalCount(units: []const Unit, boundary: usize) usize {
    var index = boundary;
    var count: usize = 0;
    while (index > 0) {
        index -= 1;
        if (units[index].class != .ri) break;
        count += 1;
    }
    return count;
}
