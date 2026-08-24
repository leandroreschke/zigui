const std = @import("std");
const Error = @import("../core/error.zig").Error;
const data = @import("unicode_data.zig");

pub const Segment = struct { start: usize, end: usize };

const Decoded = struct {
    scalar: u21,
    start: usize,
    end: usize,
};

pub const GraphemeIterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn next(self: *GraphemeIterator) Error!?[]const u8 {
        if (self.cursor >= self.bytes.len) return null;
        const start = self.cursor;
        var current = try decodeForward(self.bytes, start);
        var state = ClusterState.init(current.scalar);
        var previous = current;
        while (current.end < self.bytes.len) {
            current = try decodeForward(self.bytes, current.end);
            if (graphemeBreak(previous.scalar, current.scalar, state)) {
                self.cursor = current.start;
                return self.bytes[start..current.start];
            }
            state.accept(current.scalar);
            previous = current;
        }
        self.cursor = self.bytes.len;
        return self.bytes[start..];
    }
};

const IndicState = enum { none, consonant, linker };

const ClusterState = struct {
    regional_count: usize = 0,
    extended_pictographic_chain: bool = false,
    pictographic_zwj: bool = false,
    indic: IndicState = .none,

    fn init(first: u21) ClusterState {
        var result: ClusterState = .{};
        result.accept(first);
        return result;
    }

    fn accept(self: *ClusterState, scalar: u21) void {
        const property = data.properties(scalar);
        if (property.grapheme == .regional_indicator) self.regional_count += 1 else self.regional_count = 0;

        if (property.extendedPictographic()) {
            self.extended_pictographic_chain = true;
            self.pictographic_zwj = false;
        } else if (property.grapheme == .extend and self.extended_pictographic_chain) {
            self.pictographic_zwj = false;
        } else if (property.grapheme == .zwj and self.extended_pictographic_chain) {
            self.pictographic_zwj = true;
            self.extended_pictographic_chain = false;
        } else {
            self.extended_pictographic_chain = false;
            self.pictographic_zwj = false;
        }

        switch (property.indic_conjunct) {
            .consonant => self.indic = .consonant,
            .linker => {
                if (self.indic == .consonant or self.indic == .linker) {
                    self.indic = .linker;
                } else self.indic = .none;
            },
            .extend => {},
            .none => self.indic = .none,
        }
    }
};

fn graphemeBreak(previous_scalar: u21, current_scalar: u21, state: ClusterState) bool {
    const previous = data.properties(previous_scalar);
    const current = data.properties(current_scalar);
    if (previous.grapheme == .cr and current.grapheme == .lf) return false;
    if (isGraphemeControl(previous.grapheme) or isGraphemeControl(current.grapheme)) return true;
    if (previous.grapheme == .l and switch (current.grapheme) {
        .l, .v, .lv, .lvt => true,
        else => false,
    }) return false;
    if ((previous.grapheme == .lv or previous.grapheme == .v) and (current.grapheme == .v or current.grapheme == .t)) return false;
    if ((previous.grapheme == .lvt or previous.grapheme == .t) and current.grapheme == .t) return false;
    if (current.grapheme == .extend or current.grapheme == .zwj) return false;
    if (current.grapheme == .spacingmark) return false;
    if (previous.grapheme == .prepend) return false;
    if (current.indic_conjunct == .consonant and state.indic == .linker) return false;
    if (current.extendedPictographic() and state.pictographic_zwj) return false;
    if (previous.grapheme == .regional_indicator and current.grapheme == .regional_indicator)
        return state.regional_count % 2 == 0;
    return true;
}

fn isGraphemeControl(value: data.GraphemeClass) bool {
    return value == .control or value == .cr or value == .lf;
}

pub const WordIterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn next(self: *WordIterator) Error!?Segment {
        if (self.cursor >= self.bytes.len) return null;
        const start = self.cursor;
        var position = (try decodeForward(self.bytes, start)).end;
        while (position < self.bytes.len and !(try isWordBoundary(self.bytes, position)))
            position = (try decodeForward(self.bytes, position)).end;
        self.cursor = position;
        return .{ .start = start, .end = position };
    }
};

pub fn isWordBoundary(bytes: []const u8, position: usize) Error!bool {
    if (position == 0 or position == bytes.len) return true;
    if (position > bytes.len) return error.InvalidUtf8;
    const immediate_left = try decodeBackward(bytes, position);
    const immediate_right = try decodeForward(bytes, position);
    const il = data.properties(immediate_left.scalar);
    const ir = data.properties(immediate_right.scalar);

    if (il.word == .cr and ir.word == .lf) return false;
    if (isWordNewline(il.word) or isWordNewline(ir.word)) return true;
    if (il.word == .zwj and ir.extendedPictographic()) return false;
    if (il.word == .wsegspace and ir.word == .wsegspace) return false;
    if (isWordIgnored(ir.word)) return false;

    const left = (try previousWordSignificant(bytes, position)) orelse return true;
    const right = (try nextWordSignificant(bytes, position)) orelse return true;
    const l = data.properties(left.scalar).word;
    const r = data.properties(right.scalar).word;
    if (isAhLetter(l) and isAhLetter(r)) return false;
    if (l == .hebrew_letter and r == .single_quote) return false;
    if (l == .numeric and r == .numeric) return false;
    if ((isAhLetter(l) and r == .numeric) or (l == .numeric and isAhLetter(r))) return false;
    if (l == .katakana and r == .katakana) return false;
    if ((isWordCore(l) and r == .extendnumlet) or (l == .extendnumlet and isWordCore(r))) return false;

    const before_left = try previousWordSignificant(bytes, left.start);
    const after_right = try nextWordSignificant(bytes, right.end);
    if (isAhLetter(l) and isMidLetterLike(r) and after_right != null and isAhLetter(data.properties(after_right.?.scalar).word)) return false;
    if (before_left != null and isAhLetter(data.properties(before_left.?.scalar).word) and isMidLetterLike(l) and isAhLetter(r)) return false;
    if (l == .hebrew_letter and r == .double_quote and after_right != null and data.properties(after_right.?.scalar).word == .hebrew_letter) return false;
    if (before_left != null and data.properties(before_left.?.scalar).word == .hebrew_letter and l == .double_quote and r == .hebrew_letter) return false;
    if (l == .numeric and isMidNumeric(r) and after_right != null and data.properties(after_right.?.scalar).word == .numeric) return false;
    if (before_left != null and data.properties(before_left.?.scalar).word == .numeric and isMidNumeric(l) and r == .numeric) return false;
    if (l == .regional_indicator and r == .regional_indicator) return try regionalCountBefore(bytes, right.start) % 2 == 0;
    return true;
}

fn isWordNewline(value: data.WordClass) bool {
    return value == .newline or value == .cr or value == .lf;
}

fn isWordIgnored(value: data.WordClass) bool {
    return value == .extend or value == .format or value == .zwj;
}

fn isAhLetter(value: data.WordClass) bool {
    return value == .aletter or value == .hebrew_letter;
}

fn isMidLetterLike(value: data.WordClass) bool {
    return value == .midletter or value == .midnumlet or value == .single_quote;
}

fn isMidNumeric(value: data.WordClass) bool {
    return value == .midnum or value == .midnumlet or value == .single_quote;
}

fn isWordCore(value: data.WordClass) bool {
    return isAhLetter(value) or value == .numeric or value == .katakana or value == .extendnumlet;
}

fn previousWordSignificant(bytes: []const u8, position: usize) Error!?Decoded {
    var cursor = position;
    while (cursor > 0) {
        const decoded = try decodeBackward(bytes, cursor);
        if (!isWordIgnored(data.properties(decoded.scalar).word)) return decoded;
        cursor = decoded.start;
    }
    return null;
}

fn nextWordSignificant(bytes: []const u8, position: usize) Error!?Decoded {
    var cursor = position;
    while (cursor < bytes.len) {
        const decoded = try decodeForward(bytes, cursor);
        if (!isWordIgnored(data.properties(decoded.scalar).word)) return decoded;
        cursor = decoded.end;
    }
    return null;
}

fn regionalCountBefore(bytes: []const u8, position: usize) Error!usize {
    var cursor = position;
    var count: usize = 0;
    while (try previousWordSignificant(bytes, cursor)) |decoded| {
        if (data.properties(decoded.scalar).word != .regional_indicator) break;
        count += 1;
        cursor = decoded.start;
    }
    return count;
}

pub const SentenceIterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn next(self: *SentenceIterator) Error!?Segment {
        if (self.cursor >= self.bytes.len) return null;
        const start = self.cursor;
        var position = (try decodeForward(self.bytes, start)).end;
        while (position < self.bytes.len and !(try isSentenceBoundary(self.bytes, position)))
            position = (try decodeForward(self.bytes, position)).end;
        self.cursor = position;
        return .{ .start = start, .end = position };
    }
};

pub fn isSentenceBoundary(bytes: []const u8, position: usize) Error!bool {
    if (position == 0 or position == bytes.len) return true;
    if (position > bytes.len) return error.InvalidUtf8;
    const immediate_left = try decodeBackward(bytes, position);
    const immediate_right = try decodeForward(bytes, position);
    const il = data.properties(immediate_left.scalar).sentence;
    const ir = data.properties(immediate_right.scalar).sentence;
    if (il == .cr and ir == .lf) return false;
    if (isSentenceSeparator(il)) return true;
    if (isSentenceSeparator(ir)) return false;
    if (isSentenceIgnored(ir)) return false;

    const left = (try previousSentenceSignificant(bytes, position)) orelse return true;
    const right = (try nextSentenceSignificant(bytes, position)) orelse return true;
    const l = data.properties(left.scalar).sentence;
    const r = data.properties(right.scalar).sentence;
    if (l == .aterm and r == .numeric) return false;
    if (l == .aterm and r == .upper) {
        const before = try previousSentenceSignificant(bytes, left.start);
        if (before != null) {
            const value = data.properties(before.?.scalar).sentence;
            if (value == .upper or value == .lower) return false;
        }
    }

    var terminal = left;
    var terminal_class = l;
    while (terminal_class == .close or terminal_class == .sp) {
        terminal = (try previousSentenceSignificant(bytes, terminal.start)) orelse return false;
        terminal_class = data.properties(terminal.scalar).sentence;
    }
    if (terminal_class == .aterm and r == .lower) return false;
    if ((terminal_class == .aterm or terminal_class == .sterm) and
        (r == .scontinue or r == .aterm or r == .sterm)) return false;
    if ((terminal_class == .aterm or terminal_class == .sterm) and (l == .close or l == .sp)) return false;
    if ((l == .aterm or l == .sterm) and (r == .close or r == .sp)) return false;
    if (terminal_class == .aterm or terminal_class == .sterm) return true;
    return false;
}

fn isSentenceSeparator(value: data.SentenceClass) bool {
    return value == .sep or value == .cr or value == .lf;
}

fn isSentenceIgnored(value: data.SentenceClass) bool {
    return value == .extend or value == .format;
}

fn previousSentenceSignificant(bytes: []const u8, position: usize) Error!?Decoded {
    var cursor = position;
    while (cursor > 0) {
        const decoded = try decodeBackward(bytes, cursor);
        if (!isSentenceIgnored(data.properties(decoded.scalar).sentence)) return decoded;
        cursor = decoded.start;
    }
    return null;
}

fn nextSentenceSignificant(bytes: []const u8, position: usize) Error!?Decoded {
    var cursor = position;
    while (cursor < bytes.len) {
        const decoded = try decodeForward(bytes, cursor);
        if (!isSentenceIgnored(data.properties(decoded.scalar).sentence)) return decoded;
        cursor = decoded.end;
    }
    return null;
}

fn decodeForward(bytes: []const u8, start: usize) Error!Decoded {
    if (start >= bytes.len) return error.InvalidUtf8;
    const length = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return error.InvalidUtf8;
    if (start + length > bytes.len) return error.InvalidUtf8;
    const scalar = std.unicode.utf8Decode(bytes[start..][0..length]) catch return error.InvalidUtf8;
    return .{ .scalar = scalar, .start = start, .end = start + length };
}

fn decodeBackward(bytes: []const u8, end: usize) Error!Decoded {
    if (end == 0 or end > bytes.len) return error.InvalidUtf8;
    var start = end - 1;
    while (start > 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
    const decoded = decodeForward(bytes, start) catch return error.InvalidUtf8;
    if (decoded.end != end) return error.InvalidUtf8;
    return decoded;
}
