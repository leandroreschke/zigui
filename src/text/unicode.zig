const std = @import("std");
const Error = @import("../core/error.zig").Error;
pub const data = @import("unicode_data.zig");
pub const normalization = @import("normalization.zig");
pub const segmentation = @import("segmentation.zig");
pub const bidi = @import("bidi.zig");
pub const line_break = @import("line_break.zig");

pub const unicode_version = data.version;
pub const Script = data.Script;
pub const GraphemeClass = data.GraphemeClass;
pub const WordClass = data.WordClass;
pub const SentenceClass = data.SentenceClass;
pub const LineClass = data.LineClass;
pub const BidiClass = data.BidiClass;
pub const GeneralCategory = data.GeneralCategory;
pub const JoiningType = data.JoiningType;
pub const IndicSyllabicCategory = data.IndicSyllabicCategory;
pub const IndicPositionalCategory = data.IndicPositionalCategory;
pub const IndicProperties = data.IndicProperties;
pub const Properties = data.Properties;

pub const Scalar = struct {
    value: u21,
    start: usize,
    end: usize,
};

pub const Iterator = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn next(self: *Iterator) Error!?Scalar {
        if (self.index >= self.bytes.len) return null;
        const start = self.index;
        const sequence_length = std.unicode.utf8ByteSequenceLength(self.bytes[start]) catch return error.InvalidUtf8;
        if (start + sequence_length > self.bytes.len) return error.InvalidUtf8;
        const value = std.unicode.utf8Decode(self.bytes[start..][0..sequence_length]) catch return error.InvalidUtf8;
        self.index += sequence_length;
        return .{ .value = value, .start = start, .end = self.index };
    }
};

pub const ReverseIterator = struct {
    bytes: []const u8,
    index: usize,

    pub fn init(bytes: []const u8) ReverseIterator {
        return .{ .bytes = bytes, .index = bytes.len };
    }

    pub fn next(self: *ReverseIterator) Error!?Scalar {
        if (self.index == 0) return null;
        const end = self.index;
        var start = end - 1;
        while (start > 0 and self.bytes[start] & 0xc0 == 0x80) start -= 1;
        const length = std.unicode.utf8ByteSequenceLength(self.bytes[start]) catch return error.InvalidUtf8;
        if (start + length != end) return error.InvalidUtf8;
        const value = std.unicode.utf8Decode(self.bytes[start..end]) catch return error.InvalidUtf8;
        self.index = start;
        return .{ .value = value, .start = start, .end = end };
    }
};

pub const GraphemeIterator = segmentation.GraphemeIterator;
pub const WordIterator = segmentation.WordIterator;
pub const SentenceIterator = segmentation.SentenceIterator;
pub const Segment = segmentation.Segment;
pub const LineBreak = line_break.Opportunity;
pub const LineBreakAnalysis = line_break.Analysis;
pub const BidiResult = bidi.Result;
pub const NormalizationForm = normalization.Form;

pub fn properties(value: u21) Properties {
    return data.properties(value);
}

pub fn indicProperties(value: u21) IndicProperties {
    return data.indicProperties(value);
}

pub fn script(value: u21) Script {
    return data.properties(value).script;
}

pub fn bidiClass(value: u21) BidiClass {
    return data.properties(value).bidi;
}

pub fn lineBreakBetween(previous: u21, current: u21) LineBreak {
    return line_break.between(previous, current);
}

pub fn analyzeLineBreaks(allocator: std.mem.Allocator, text: []const u8) Error!LineBreakAnalysis {
    return line_break.analyze(allocator, text);
}

pub fn resolveBidi(allocator: std.mem.Allocator, scalars: []const u21, requested_rtl: ?bool) Error!BidiResult {
    return bidi.resolve(allocator, scalars, requested_rtl);
}

pub fn normalize(allocator: std.mem.Allocator, input: []const u8, form: NormalizationForm) Error![]u8 {
    return normalization.normalize(allocator, input, form);
}

pub fn isNormalized(allocator: std.mem.Allocator, input: []const u8, form: NormalizationForm) Error!bool {
    return normalization.isNormalized(allocator, input, form);
}

pub fn isWordBoundary(bytes: []const u8, position: usize) Error!bool {
    return segmentation.isWordBoundary(bytes, position);
}

pub fn isSentenceBoundary(bytes: []const u8, position: usize) Error!bool {
    return segmentation.isSentenceBoundary(bytes, position);
}

pub fn isWhitespace(value: u21) bool {
    return data.properties(value).whitespace();
}

pub fn isExtend(value: u21) bool {
    const property = data.properties(value);
    return property.grapheme == .extend or property.graphemeExtend();
}

pub fn isAlphabetic(value: u21) bool {
    return data.properties(value).alphabetic();
}

pub fn isDefaultIgnorable(value: u21) bool {
    return data.properties(value).defaultIgnorable();
}

pub fn mirrored(value: u21) u21 {
    return data.mirror(value) orelse value;
}

pub fn simpleUpper(value: u21) u21 {
    return if (data.caseMapping(value)) |mapping| mapping.upper else value;
}

pub fn simpleLower(value: u21) u21 {
    return if (data.caseMapping(value)) |mapping| mapping.lower else value;
}

pub fn simpleTitle(value: u21) u21 {
    return if (data.caseMapping(value)) |mapping| mapping.title else value;
}
