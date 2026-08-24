const std = @import("std");

const maximum_scalar = 0x10ffff;

const Property = struct {
    grapheme: u8 = 0,
    word: u8 = 0,
    sentence: u8 = 0,
    line: u8 = 43,
    bidi: u8 = 9,
    script: u16 = 0,
    category: u8 = 2,
    combining: u8 = 0,
    joining: u8 = 0,
    east_asian_width: u8 = 3,
    indic_conjunct: u8 = 0,
    flags: u8 = 0,
};

const IndicProperty = struct {
    syllabic: u8 = 0,
    positional: u8 = 0,
};

const Decomposition = struct {
    scalar: u21,
    offset: u32,
    length: u8,
    compatibility: bool,
};

const CaseMapping = struct {
    scalar: u21,
    upper: u21,
    lower: u21,
    title: u21,
};

const Composition = struct {
    first: u21,
    second: u21,
    composed: u21,
};

const Mirror = struct { scalar: u21, mirror: u21 };
const Bracket = struct { scalar: u21, pair: u21, opening: bool };

const ScriptExtension = struct {
    first: u21,
    last: u21,
    offset: u32,
    length: u8,
};

const Range = struct { first: u21, last: u21 };

const ParsedLine = struct {
    range: Range,
    fields: [4][]const u8,
    field_count: u8,
};

const AssignmentIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    fn init(bytes: []const u8) AssignmentIterator {
        return .{ .lines = std.mem.splitScalar(u8, bytes, '\n') };
    }

    fn next(self: *AssignmentIterator) !?ParsedLine {
        while (self.lines.next()) |raw| {
            const comment = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
            const line = std.mem.trim(u8, raw[0..comment], " \t\r");
            if (line.len == 0) continue;
            var fields_it = std.mem.splitScalar(u8, line, ';');
            const range_text = std.mem.trim(u8, fields_it.next() orelse continue, " \t");
            var fields: [4][]const u8 = .{ "", "", "", "" };
            var count: u8 = 0;
            while (fields_it.next()) |field| {
                if (count == fields.len) break;
                fields[count] = std.mem.trim(u8, field, " \t");
                count += 1;
            }
            if (count == 0) continue;
            return .{ .range = try parseRange(range_text), .fields = fields, .field_count = count };
        }
        return null;
    }
};

const NameValue = struct { name: []const u8, value: u8 };

const grapheme_names = [_][]const u8{
    "Other",       "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator", "Prepend",
    "SpacingMark", "L",  "V",  "T",       "LV",     "LVT",
};

const word_names = [_][]const u8{
    "Other",    "CR",            "LF",        "Newline",      "Extend",       "ZWJ",       "Regional_Indicator", "Format",
    "Katakana", "Hebrew_Letter", "ALetter",   "Single_Quote", "Double_Quote", "MidNumLet", "MidLetter",          "MidNum",
    "Numeric",  "ExtendNumLet",  "WSegSpace",
};

const sentence_names = [_][]const u8{
    "Other",   "CR",    "LF",    "Sep",   "Extend",    "Format", "Sp", "Lower", "Upper", "OLetter",
    "Numeric", "ATerm", "STerm", "Close", "SContinue",
};

const line_names = [_][]const u8{
    "AI", "AK", "AL", "AP", "AS", "B2", "BA", "BB", "BK", "CB",  "CJ", "CL", "CM",
    "CP", "CR", "EB", "EM", "EX", "GL", "H2", "H3", "HH", "HL",  "HY", "ID", "IN",
    "IS", "JL", "JT", "JV", "LF", "NL", "NS", "NU", "OP", "PO",  "PR", "QU", "RI",
    "SA", "SG", "SP", "SY", "XX", "VF", "VI", "WJ", "ZW", "ZWJ",
};

const bidi_names = [_][]const u8{
    "AL",  "AN", "B",   "BN",  "CS", "EN",  "ES",  "ET",  "FSI", "L",  "LRE", "LRI", "LRO",
    "NSM", "ON", "PDF", "PDI", "R",  "RLE", "RLI", "RLO", "S",   "WS",
};

const category_names = [_][]const u8{
    "Cc", "Cf", "Cn", "Co", "Cs", "Ll", "Lm", "Lo", "Lt", "Lu", "Mc", "Me", "Mn",
    "Nd", "Nl", "No", "Pc", "Pd", "Pe", "Pf", "Pi", "Po", "Ps", "Sc", "Sk", "Sm",
    "So", "Zl", "Zp", "Zs",
};

const joining_names = [_][]const u8{ "U", "R", "D", "C", "T", "L" };
const east_asian_width_names = [_][]const u8{ "A", "F", "H", "N", "Na", "W" };
const indic_conjunct_names = [_][]const u8{ "None", "Linker", "Consonant", "Extend" };
const indic_syllabic_names = [_][]const u8{
    "Other",
    "Avagraha",
    "Bindu",
    "Brahmi_Joining_Number",
    "Cantillation_Mark",
    "Consonant",
    "Consonant_Dead",
    "Consonant_Final",
    "Consonant_Head_Letter",
    "Consonant_Initial_Postfixed",
    "Consonant_Killer",
    "Consonant_Medial",
    "Consonant_Placeholder",
    "Consonant_Preceding_Repha",
    "Consonant_Prefixed",
    "Consonant_Subjoined",
    "Consonant_Succeeding_Repha",
    "Consonant_With_Stacker",
    "Gemination_Mark",
    "Invisible_Stacker",
    "Joiner",
    "Modifying_Letter",
    "Non_Joiner",
    "Nukta",
    "Number",
    "Number_Joiner",
    "Pure_Killer",
    "Register_Shifter",
    "Reordering_Killer",
    "Syllable_Modifier",
    "Tone_Letter",
    "Tone_Mark",
    "Virama",
    "Visarga",
    "Vowel",
    "Vowel_Dependent",
    "Vowel_Independent",
};
const indic_positional_names = [_][]const u8{
    "Not_Applicable",
    "Bottom",
    "Bottom_And_Left",
    "Bottom_And_Right",
    "Left",
    "Left_And_Right",
    "Overstruck",
    "Right",
    "Top",
    "Top_And_Bottom",
    "Top_And_Bottom_And_Left",
    "Top_And_Bottom_And_Right",
    "Top_And_Left",
    "Top_And_Left_And_Right",
    "Top_And_Right",
    "Visual_Order_Left",
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;
    const root = args[1];
    const output_path = args[2];

    const properties = try allocator.alloc(Property, maximum_scalar + 1);
    @memset(properties, .{});

    var script_ids = std.StringHashMap(u16).init(allocator);
    var script_names: std.ArrayList([]const u8) = .empty;
    try script_names.append(allocator, "Unknown");
    try script_ids.put("Unknown", 0);

    const scripts_bytes = try readSource(io, allocator, root, "Scripts.txt");
    var scripts_it = AssignmentIterator.init(scripts_bytes);
    while (try scripts_it.next()) |line| {
        const id = try internScript(allocator, &script_ids, &script_names, line.fields[0]);
        fillField(properties, line.range, .script, id);
    }

    try applyNamedProperty(io, allocator, root, "auxiliary/GraphemeBreakProperty.txt", properties, .grapheme, &grapheme_names);
    try applyNamedProperty(io, allocator, root, "auxiliary/WordBreakProperty.txt", properties, .word, &word_names);
    try applyNamedProperty(io, allocator, root, "auxiliary/SentenceBreakProperty.txt", properties, .sentence, &sentence_names);
    try applyNamedProperty(io, allocator, root, "LineBreak.txt", properties, .line, &line_names);
    try applyNamedProperty(io, allocator, root, "extracted/DerivedBidiClass.txt", properties, .bidi, &bidi_names);
    try applyNamedProperty(io, allocator, root, "EastAsianWidth.txt", properties, .east_asian_width, &east_asian_width_names);

    var decomposition_scalars: std.ArrayList(u21) = .empty;
    var decompositions: std.ArrayList(Decomposition) = .empty;
    var cases: std.ArrayList(CaseMapping) = .empty;
    try applyUnicodeData(
        io,
        allocator,
        root,
        properties,
        &decomposition_scalars,
        &decompositions,
        &cases,
    );

    try applyDerivedCore(io, allocator, root, properties);
    try applyFlagFile(io, allocator, root, "PropList.txt", properties, "White_Space", 7);
    try applyFlagFile(io, allocator, root, "emoji/emoji-data.txt", properties, "Extended_Pictographic", 0);
    try applyFlagFile(io, allocator, root, "emoji/emoji-data.txt", properties, "Emoji_Presentation", 6);
    try applyArabicShaping(io, allocator, root, properties);

    const indic_properties = try allocator.alloc(IndicProperty, maximum_scalar + 1);
    @memset(indic_properties, .{});
    try applyIndicProperty(
        io,
        allocator,
        root,
        "IndicSyllabicCategory.txt",
        indic_properties,
        .syllabic,
        &indic_syllabic_names,
    );
    try applyIndicProperty(
        io,
        allocator,
        root,
        "IndicPositionalCategory.txt",
        indic_properties,
        .positional,
        &indic_positional_names,
    );

    const exclusions = try allocator.alloc(bool, maximum_scalar + 1);
    @memset(exclusions, false);
    try applyCompositionExclusions(io, allocator, root, exclusions);
    var compositions: std.ArrayList(Composition) = .empty;
    for (decompositions.items) |decomposition| {
        if (decomposition.compatibility or decomposition.length != 2 or exclusions[decomposition.scalar]) continue;
        try compositions.append(allocator, .{
            .first = decomposition_scalars.items[decomposition.offset],
            .second = decomposition_scalars.items[decomposition.offset + 1],
            .composed = decomposition.scalar,
        });
    }
    std.mem.sort(Composition, compositions.items, {}, lessComposition);

    var mirrors: std.ArrayList(Mirror) = .empty;
    try parseMirrors(io, allocator, root, &mirrors);
    var brackets: std.ArrayList(Bracket) = .empty;
    try parseBrackets(io, allocator, root, &brackets);

    var alias_ids = std.StringHashMap(u16).init(allocator);
    const script_tags = try allocator.alloc([4]u8, script_names.items.len);
    @memset(script_tags, "Zzzz".*);
    try parseScriptAliases(io, allocator, root, &script_ids, &alias_ids, script_tags);
    var extension_values: std.ArrayList(u16) = .empty;
    var extensions: std.ArrayList(ScriptExtension) = .empty;
    try parseScriptExtensions(io, allocator, root, &alias_ids, &extension_values, &extensions);

    var output: std.Io.Writer.Allocating = .init(allocator);
    try emit(
        &output.writer,
        properties,
        indic_properties,
        script_names.items,
        script_tags,
        decomposition_scalars.items,
        decompositions.items,
        compositions.items,
        cases.items,
        mirrors.items,
        brackets.items,
        extension_values.items,
        extensions.items,
    );
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = output.written() });
}

fn readSource(io: std.Io, allocator: std.mem.Allocator, root: []const u8, sub_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, sub_path });
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024));
}

fn parseRange(text: []const u8) !Range {
    if (std.mem.indexOf(u8, text, "..")) |separator| return .{
        .first = @intCast(try std.fmt.parseInt(u32, text[0..separator], 16)),
        .last = @intCast(try std.fmt.parseInt(u32, text[separator + 2 ..], 16)),
    };
    const scalar: u21 = @intCast(try std.fmt.parseInt(u32, text, 16));
    return .{ .first = scalar, .last = scalar };
}

fn lookupName(name: []const u8, names: []const []const u8) !u8 {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, name, candidate)) return @intCast(index);
    return error.UnknownUnicodeProperty;
}

fn applyNamedProperty(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    sub_path: []const u8,
    properties: []Property,
    comptime field: std.meta.FieldEnum(Property),
    names: []const []const u8,
) !void {
    const bytes = try readSource(io, allocator, root, sub_path);
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| fillField(properties, line.range, field, try lookupName(line.fields[0], names));
}

fn applyIndicProperty(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    sub_path: []const u8,
    properties: []IndicProperty,
    comptime field: std.meta.FieldEnum(IndicProperty),
    names: []const []const u8,
) !void {
    const bytes = try readSource(io, allocator, root, sub_path);
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| {
        const value = try lookupName(line.fields[0], names);
        var scalar: usize = line.range.first;
        while (scalar <= line.range.last) : (scalar += 1)
            @field(properties[scalar], @tagName(field)) = value;
    }
}

fn fillField(properties: []Property, range: Range, comptime field: std.meta.FieldEnum(Property), value: anytype) void {
    var scalar: usize = range.first;
    while (scalar <= range.last) : (scalar += 1) @field(properties[scalar], @tagName(field)) = @intCast(value);
}

fn setFlag(properties: []Property, range: Range, bit: u3) void {
    var scalar: usize = range.first;
    while (scalar <= range.last) : (scalar += 1) properties[scalar].flags |= @as(u8, 1) << bit;
}

fn internScript(
    allocator: std.mem.Allocator,
    ids: *std.StringHashMap(u16),
    names: *std.ArrayList([]const u8),
    name: []const u8,
) !u16 {
    if (ids.get(name)) |id| return id;
    const id: u16 = @intCast(names.items.len);
    try names.append(allocator, name);
    try ids.put(name, id);
    return id;
}

fn applyUnicodeData(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    properties: []Property,
    decomposition_scalars: *std.ArrayList(u21),
    decompositions: *std.ArrayList(Decomposition),
    cases: *std.ArrayList(CaseMapping),
) !void {
    const bytes = try readSource(io, allocator, root, "UnicodeData.txt");
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var pending_first: ?struct { scalar: u21, category: u8, combining: u8 } = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var split = std.mem.splitScalar(u8, line, ';');
        var fields: [15][]const u8 = undefined;
        for (&fields) |*field| field.* = split.next() orelse return error.InvalidUnicodeData;
        const scalar: u21 = @intCast(try std.fmt.parseInt(u32, fields[0], 16));
        const category = try lookupName(fields[2], &category_names);
        const combining = try std.fmt.parseInt(u8, fields[3], 10);
        if (std.mem.endsWith(u8, fields[1], ", First>")) {
            pending_first = .{ .scalar = scalar, .category = category, .combining = combining };
            continue;
        }
        if (std.mem.endsWith(u8, fields[1], ", Last>")) {
            const first = pending_first orelse return error.InvalidUnicodeData;
            if (first.category != category or first.combining != combining) return error.InvalidUnicodeData;
            fillField(properties, .{ .first = first.scalar, .last = scalar }, .category, category);
            fillField(properties, .{ .first = first.scalar, .last = scalar }, .combining, combining);
            pending_first = null;
            continue;
        }
        properties[scalar].category = category;
        properties[scalar].combining = combining;

        if (fields[5].len != 0) {
            var decomposition = fields[5];
            var compatibility = false;
            if (decomposition[0] == '<') {
                const close = std.mem.indexOfScalar(u8, decomposition, '>') orelse return error.InvalidUnicodeData;
                compatibility = true;
                decomposition = std.mem.trim(u8, decomposition[close + 1 ..], " ");
            }
            const offset: u32 = @intCast(decomposition_scalars.items.len);
            var values = std.mem.splitScalar(u8, decomposition, ' ');
            var length: u8 = 0;
            while (values.next()) |value| if (value.len != 0) {
                try decomposition_scalars.append(allocator, @intCast(try std.fmt.parseInt(u32, value, 16)));
                length += 1;
            };
            if (length != 0) try decompositions.append(allocator, .{
                .scalar = scalar,
                .offset = offset,
                .length = length,
                .compatibility = compatibility,
            });
        }

        const upper: u21 = if (fields[12].len == 0) scalar else @intCast(try std.fmt.parseInt(u32, fields[12], 16));
        const lower: u21 = if (fields[13].len == 0) scalar else @intCast(try std.fmt.parseInt(u32, fields[13], 16));
        const title: u21 = if (fields[14].len == 0) upper else @intCast(try std.fmt.parseInt(u32, fields[14], 16));
        if (upper != scalar or lower != scalar or title != scalar) try cases.append(allocator, .{
            .scalar = scalar,
            .upper = upper,
            .lower = lower,
            .title = title,
        });
    }
    if (pending_first != null) return error.InvalidUnicodeData;
}

fn applyDerivedCore(io: std.Io, allocator: std.mem.Allocator, root: []const u8, properties: []Property) !void {
    const bytes = try readSource(io, allocator, root, "DerivedCoreProperties.txt");
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| {
        const property = line.fields[0];
        if (std.mem.eql(u8, property, "Default_Ignorable_Code_Point")) setFlag(properties, line.range, 1) else if (std.mem.eql(u8, property, "Alphabetic")) setFlag(properties, line.range, 2) else if (std.mem.eql(u8, property, "Cased")) setFlag(properties, line.range, 3) else if (std.mem.eql(u8, property, "Case_Ignorable")) setFlag(properties, line.range, 4) else if (std.mem.eql(u8, property, "Grapheme_Extend")) setFlag(properties, line.range, 5) else if (std.mem.eql(u8, property, "InCB") and line.field_count >= 2)
            fillField(properties, line.range, .indic_conjunct, try lookupName(line.fields[1], &indic_conjunct_names));
    }
}

fn applyFlagFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    sub_path: []const u8,
    properties: []Property,
    wanted: []const u8,
    bit: u3,
) !void {
    const bytes = try readSource(io, allocator, root, sub_path);
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| if (std.mem.eql(u8, line.fields[0], wanted)) setFlag(properties, line.range, bit);
}

fn applyArabicShaping(io: std.Io, allocator: std.mem.Allocator, root: []const u8, properties: []Property) !void {
    const bytes = try readSource(io, allocator, root, "ArabicShaping.txt");
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| {
        if (line.field_count < 2) return error.InvalidUnicodeData;
        fillField(properties, line.range, .joining, try lookupName(line.fields[1], &joining_names));
    }
}

fn applyCompositionExclusions(io: std.Io, allocator: std.mem.Allocator, root: []const u8, excluded: []bool) !void {
    const bytes = try readSource(io, allocator, root, "DerivedNormalizationProps.txt");
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| if (std.mem.eql(u8, line.fields[0], "Full_Composition_Exclusion")) {
        var scalar: usize = line.range.first;
        while (scalar <= line.range.last) : (scalar += 1) excluded[scalar] = true;
    };
}

fn parseMirrors(io: std.Io, allocator: std.mem.Allocator, root: []const u8, output: *std.ArrayList(Mirror)) !void {
    const bytes = try readSource(io, allocator, root, "BidiMirroring.txt");
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| try output.append(allocator, .{
        .scalar = line.range.first,
        .mirror = @intCast(try std.fmt.parseInt(u32, line.fields[0], 16)),
    });
}

fn parseBrackets(io: std.Io, allocator: std.mem.Allocator, root: []const u8, output: *std.ArrayList(Bracket)) !void {
    const bytes = try readSource(io, allocator, root, "BidiBrackets.txt");
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| {
        if (line.field_count < 2) return error.InvalidUnicodeData;
        try output.append(allocator, .{
            .scalar = line.range.first,
            .pair = @intCast(try std.fmt.parseInt(u32, line.fields[0], 16)),
            .opening = std.mem.eql(u8, line.fields[1], "o"),
        });
    }
}

fn parseScriptAliases(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    script_ids: *const std.StringHashMap(u16),
    aliases: *std.StringHashMap(u16),
    tags: [][4]u8,
) !void {
    const bytes = try readSource(io, allocator, root, "PropertyValueAliases.txt");
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const comment = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const line = std.mem.trim(u8, raw[0..comment], " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, ';');
        const property = std.mem.trim(u8, fields.next() orelse continue, " \t");
        if (!std.mem.eql(u8, property, "sc")) continue;
        const alias = std.mem.trim(u8, fields.next() orelse return error.InvalidUnicodeData, " \t");
        const long_name = std.mem.trim(u8, fields.next() orelse return error.InvalidUnicodeData, " \t");
        const id = script_ids.get(long_name) orelse continue;
        if (alias.len != 4 or id >= tags.len) return error.InvalidUnicodeData;
        tags[id] = alias[0..4].*;
        try aliases.put(alias, id);
        try aliases.put(long_name, id);
    }
}

fn parseScriptExtensions(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    aliases: *const std.StringHashMap(u16),
    values: *std.ArrayList(u16),
    records: *std.ArrayList(ScriptExtension),
) !void {
    const bytes = try readSource(io, allocator, root, "ScriptExtensions.txt");
    var iterator = AssignmentIterator.init(bytes);
    while (try iterator.next()) |line| {
        const offset: u32 = @intCast(values.items.len);
        var names = std.mem.splitScalar(u8, line.fields[0], ' ');
        var count: u8 = 0;
        while (names.next()) |name| if (name.len != 0) {
            try values.append(allocator, aliases.get(name) orelse return error.UnknownUnicodeProperty);
            count += 1;
        };
        try records.append(allocator, .{ .first = line.range.first, .last = line.range.last, .offset = offset, .length = count });
    }
}

fn lessComposition(_: void, left: Composition, right: Composition) bool {
    return left.first < right.first or (left.first == right.first and left.second < right.second);
}

fn packProperty(property: Property) u64 {
    return @as(u64, property.grapheme) |
        (@as(u64, property.word) << 4) |
        (@as(u64, property.sentence) << 9) |
        (@as(u64, property.line) << 13) |
        (@as(u64, property.bidi) << 19) |
        (@as(u64, property.script) << 24) |
        (@as(u64, property.category) << 33) |
        (@as(u64, property.combining) << 38) |
        (@as(u64, property.joining) << 46) |
        (@as(u64, property.east_asian_width) << 49) |
        (@as(u64, property.indic_conjunct) << 52) |
        (@as(u64, property.flags) << 54);
}

fn emit(
    writer: *std.Io.Writer,
    properties: []const Property,
    indic_properties: []const IndicProperty,
    scripts: []const []const u8,
    script_tags: []const [4]u8,
    decomposition_scalars: []const u21,
    decompositions: []const Decomposition,
    compositions: []const Composition,
    cases: []const CaseMapping,
    mirrors: []const Mirror,
    brackets: []const Bracket,
    extension_values: []const u16,
    extensions: []const ScriptExtension,
) !void {
    try writer.writeAll(
        "//! Generated from the Unicode Character Database 17.0.0 by tools/generate_unicode.zig.\n" ++
            "//! Do not edit by hand. No Unicode data is loaded at build time or runtime.\n\n" ++
            "pub const version = \"17.0.0\";\n\n",
    );
    try emitEnum(writer, "GraphemeClass", "u8", &grapheme_names);
    try emitEnum(writer, "WordClass", "u8", &word_names);
    try emitEnum(writer, "SentenceClass", "u8", &sentence_names);
    try emitEnum(writer, "LineClass", "u8", &line_names);
    try emitEnum(writer, "BidiClass", "u8", &bidi_names);
    try emitEnum(writer, "GeneralCategory", "u8", &category_names);
    try emitEnum(writer, "JoiningType", "u8", &joining_names);
    try emitEnum(writer, "EastAsianWidth", "u8", &east_asian_width_names);
    try emitEnum(writer, "IndicConjunctBreak", "u8", &indic_conjunct_names);
    try emitEnum(writer, "IndicSyllabicCategory", "u8", &indic_syllabic_names);
    try emitEnum(writer, "IndicPositionalCategory", "u8", &indic_positional_names);
    try emitEnum(writer, "Script", "u16", scripts);
    try writer.writeAll("const script_iso_tags = [_][4]u8{\n");
    for (script_tags) |tag| try writer.print("    \"{s}\".*,\n", .{tag});
    try writer.writeAll(
        "};\n" ++
            "pub fn scriptIsoTag(script: Script) [4]u8 { return script_iso_tags[@intFromEnum(script)]; }\n\n",
    );

    try writer.writeAll(
        "pub const Properties = struct {\n" ++
            "    grapheme: GraphemeClass, word: WordClass, sentence: SentenceClass, line: LineClass,\n" ++
            "    bidi: BidiClass, script: Script, category: GeneralCategory, combining: u8,\n" ++
            "    joining: JoiningType, east_asian_width: EastAsianWidth, indic_conjunct: IndicConjunctBreak, flags: u8,\n" ++
            "    pub fn extendedPictographic(self: Properties) bool { return self.flags & 1 != 0; }\n" ++
            "    pub fn defaultIgnorable(self: Properties) bool { return self.flags & 2 != 0; }\n" ++
            "    pub fn alphabetic(self: Properties) bool { return self.flags & 4 != 0; }\n" ++
            "    pub fn cased(self: Properties) bool { return self.flags & 8 != 0; }\n" ++
            "    pub fn caseIgnorable(self: Properties) bool { return self.flags & 16 != 0; }\n" ++
            "    pub fn graphemeExtend(self: Properties) bool { return self.flags & 32 != 0; }\n" ++
            "    pub fn emojiPresentation(self: Properties) bool { return self.flags & 64 != 0; }\n" ++
            "    pub fn whitespace(self: Properties) bool { return self.flags & 128 != 0; }\n" ++
            "};\n\n" ++
            "const Range = struct { first: u21, last: u21, bits: u64 };\n" ++
            "const ranges = [_]Range{\n",
    );
    var first: usize = 0;
    while (first < properties.len) {
        const bits = packProperty(properties[first]);
        var last = first;
        while (last + 1 < properties.len and packProperty(properties[last + 1]) == bits) last += 1;
        try writer.print("    .{{ .first = 0x{x}, .last = 0x{x}, .bits = 0x{x} }},\n", .{ first, last, bits });
        first = last + 1;
    }
    try writer.writeAll(
        "};\n\n" ++
            "pub fn properties(scalar: u21) Properties {\n" ++
            "    var low: usize = 0; var high: usize = ranges.len;\n" ++
            "    while (low < high) { const middle = low + (high - low) / 2; const range = ranges[middle];\n" ++
            "        if (scalar < range.first) high = middle else if (scalar > range.last) low = middle + 1 else return unpack(range.bits);\n" ++
            "    }\n" ++
            "    return unpack(0);\n" ++
            "}\n\n" ++
            "fn unpack(value: u64) Properties { return .{\n" ++
            "    .grapheme = @enumFromInt(value & 0xf), .word = @enumFromInt((value >> 4) & 0x1f),\n" ++
            "    .sentence = @enumFromInt((value >> 9) & 0xf), .line = @enumFromInt((value >> 13) & 0x3f),\n" ++
            "    .bidi = @enumFromInt((value >> 19) & 0x1f), .script = @enumFromInt((value >> 24) & 0x1ff),\n" ++
            "    .category = @enumFromInt((value >> 33) & 0x1f), .combining = @intCast((value >> 38) & 0xff),\n" ++
            "    .joining = @enumFromInt((value >> 46) & 0x7), .east_asian_width = @enumFromInt((value >> 49) & 0x7),\n" ++
            "    .indic_conjunct = @enumFromInt((value >> 52) & 0x3), .flags = @intCast((value >> 54) & 0xff),\n" ++
            "}; }\n\n",
    );

    try writer.writeAll(
        "pub const IndicProperties = struct { syllabic: IndicSyllabicCategory, positional: IndicPositionalCategory };\n" ++
            "const IndicRange = struct { first: u21, last: u21, syllabic: IndicSyllabicCategory, positional: IndicPositionalCategory };\n" ++
            "const indic_ranges = [_]IndicRange{\n",
    );
    first = 0;
    while (first < indic_properties.len) {
        const property = indic_properties[first];
        var last = first;
        while (last + 1 < indic_properties.len and
            std.meta.eql(indic_properties[last + 1], property)) last += 1;
        if (property.syllabic != 0 or property.positional != 0) try writer.print(
            "    .{{ .first = 0x{x}, .last = 0x{x}, .syllabic = @enumFromInt({}), .positional = @enumFromInt({}) }},\n",
            .{ first, last, property.syllabic, property.positional },
        );
        first = last + 1;
    }
    try writer.writeAll(
        "};\n" ++
            "pub fn indicProperties(scalar: u21) IndicProperties {\n" ++
            "    var low: usize = 0; var high: usize = indic_ranges.len;\n" ++
            "    while (low < high) { const middle = low + (high - low) / 2; const range = indic_ranges[middle];\n" ++
            "        if (scalar < range.first) high = middle else if (scalar > range.last) low = middle + 1 else return .{ .syllabic = range.syllabic, .positional = range.positional };\n" ++
            "    }\n" ++
            "    return .{ .syllabic = .other, .positional = .not_applicable };\n" ++
            "}\n\n",
    );

    try writer.writeAll("pub const Decomposition = struct { scalar: u21, offset: u32, length: u8, compatibility: bool };\nconst decomposition_scalars = [_]u21{\n");
    for (decomposition_scalars, 0..) |scalar, index| {
        if (index % 12 == 0) try writer.writeAll("    ");
        try writer.print("0x{x}, ", .{scalar});
        if (index % 12 == 11) try writer.writeByte('\n');
    }
    try writer.writeAll("\n};\nconst decompositions = [_]Decomposition{\n");
    for (decompositions) |record| try writer.print(
        "    .{{ .scalar = 0x{x}, .offset = {}, .length = {}, .compatibility = {} }},\n",
        .{ record.scalar, record.offset, record.length, record.compatibility },
    );
    try writer.writeAll(
        "};\npub fn decomposition(scalar: u21, compatibility: bool) ?[]const u21 {\n" ++
            "    var low: usize = 0; var high: usize = decompositions.len; while (low < high) { const middle = low + (high - low) / 2; const value = decompositions[middle];\n" ++
            "        if (scalar < value.scalar) high = middle else if (scalar > value.scalar) low = middle + 1 else { if (value.compatibility and !compatibility) return null; return decomposition_scalars[value.offset..][0..value.length]; }\n" ++
            "    } return null;\n}\n\n",
    );

    try writer.writeAll("const Composition = struct { first: u21, second: u21, composed: u21 };\nconst compositions = [_]Composition{\n");
    for (compositions) |record| try writer.print("    .{{ .first = 0x{x}, .second = 0x{x}, .composed = 0x{x} }},\n", .{ record.first, record.second, record.composed });
    try writer.writeAll(
        "};\npub fn compose(first_scalar: u21, second_scalar: u21) ?u21 { var low: usize = 0; var high: usize = compositions.len; while (low < high) { const middle = low + (high - low) / 2; const value = compositions[middle];\n" ++
            "    if (first_scalar < value.first or (first_scalar == value.first and second_scalar < value.second)) high = middle else if (first_scalar > value.first or (first_scalar == value.first and second_scalar > value.second)) low = middle + 1 else return value.composed; } return null; }\n\n",
    );

    try writer.writeAll("pub const CaseMapping = struct { scalar: u21, upper: u21, lower: u21, title: u21 };\nconst case_mappings = [_]CaseMapping{\n");
    for (cases) |record| try writer.print("    .{{ .scalar = 0x{x}, .upper = 0x{x}, .lower = 0x{x}, .title = 0x{x} }},\n", .{ record.scalar, record.upper, record.lower, record.title });
    try writer.writeAll(
        "};\npub fn caseMapping(scalar: u21) ?CaseMapping { var low: usize = 0; var high: usize = case_mappings.len; while (low < high) { const middle = low + (high - low) / 2; const value = case_mappings[middle]; if (scalar < value.scalar) high = middle else if (scalar > value.scalar) low = middle + 1 else return value; } return null; }\n\n",
    );

    try writer.writeAll("const Mirror = struct { scalar: u21, mirror: u21 };\nconst mirrors = [_]Mirror{\n");
    for (mirrors) |record| try writer.print("    .{{ .scalar = 0x{x}, .mirror = 0x{x} }},\n", .{ record.scalar, record.mirror });
    try writer.writeAll("};\npub fn mirror(scalar: u21) ?u21 { var low: usize = 0; var high: usize = mirrors.len; while (low < high) { const middle = low + (high - low) / 2; const value = mirrors[middle]; if (scalar < value.scalar) high = middle else if (scalar > value.scalar) low = middle + 1 else return value.mirror; } return null; }\n\n");

    try writer.writeAll("pub const Bracket = struct { pair: u21, opening: bool };\nconst brackets = [_]struct { scalar: u21, pair: u21, opening: bool }{\n");
    for (brackets) |record| try writer.print("    .{{ .scalar = 0x{x}, .pair = 0x{x}, .opening = {} }},\n", .{ record.scalar, record.pair, record.opening });
    try writer.writeAll("};\npub fn bracket(scalar: u21) ?Bracket { var low: usize = 0; var high: usize = brackets.len; while (low < high) { const middle = low + (high - low) / 2; const value = brackets[middle]; if (scalar < value.scalar) high = middle else if (scalar > value.scalar) low = middle + 1 else return .{ .pair = value.pair, .opening = value.opening }; } return null; }\n\n");

    try writer.writeAll("const script_extension_values = [_]Script{\n");
    for (extension_values, 0..) |value, index| {
        if (index % 12 == 0) try writer.writeAll("    ");
        try writer.print("@enumFromInt({}), ", .{value});
        if (index % 12 == 11) try writer.writeByte('\n');
    }
    try writer.writeAll("\n};\nconst script_extensions = [_]struct { first: u21, last: u21, offset: u32, length: u8 }{\n");
    for (extensions) |record| try writer.print("    .{{ .first = 0x{x}, .last = 0x{x}, .offset = {}, .length = {} }},\n", .{ record.first, record.last, record.offset, record.length });
    try writer.writeAll(
        "};\npub fn scriptExtensions(scalar: u21) []const Script { var low: usize = 0; var high: usize = script_extensions.len; while (low < high) { const middle = low + (high - low) / 2; const value = script_extensions[middle]; if (scalar < value.first) high = middle else if (scalar > value.last) low = middle + 1 else return script_extension_values[value.offset..][0..value.length]; } return &.{}; }\n",
    );
}

fn emitEnum(writer: *std.Io.Writer, name: []const u8, backing: []const u8, names: []const []const u8) !void {
    try writer.print("pub const {s} = enum({s}) {{\n", .{ name, backing });
    for (names, 0..) |value, index| {
        try writer.writeAll("    @\"");
        for (value) |byte| try writer.writeByte(if (byte == '-' or byte == ' ') '_' else std.ascii.toLower(byte));
        try writer.print("\" = {},\n", .{index});
    }
    try writer.writeAll("};\n\n");
}
