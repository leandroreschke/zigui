const std = @import("std");
const Error = @import("../core/error.zig").Error;
const api = @import("api.zig");
const opentype = @import("opentype.zig");
const opentype_language = @import("opentype_language.zig");
const unicode = @import("unicode.zig");

pub const Direction = enum { left_to_right, right_to_left };
pub const JoiningForm = enum { none, isolated, initial, medial, final };
pub const IndicRole = enum(u8) {
    none,
    pre_base_mark,
    pre_base_consonant,
    pre_base,
    base,
    below_base,
    post_base,
    above_base,
    reph,
    mark,
};

pub const indic_rphf: u16 = 1 << 0;
pub const indic_rkrf: u16 = 1 << 1;
pub const indic_pref: u16 = 1 << 2;
pub const indic_blwf: u16 = 1 << 3;
pub const indic_half: u16 = 1 << 4;
pub const indic_pstf: u16 = 1 << 5;
pub const indic_init: u16 = 1 << 6;
pub const indic_basic_form_mask: u16 = indic_rphf | indic_rkrf | indic_pref | indic_blwf | indic_half | indic_pstf;
pub const maximum_buffer_glyphs = 1_000_000;
pub const maximum_lookup_applications = 65_536;
pub const maximum_lookup_work_units = 16_000_000;

pub const Glyph = struct {
    id: u16,
    cluster_utf8: u32,
    scalar: u21,
    advance_x: i64 = 0,
    advance_y: i64 = 0,
    offset_x: i64 = 0,
    offset_y: i64 = 0,
    joining_form: JoiningForm = .none,
    indic_role: IndicRole = .none,
    indic_syllable: u32 = 0,
    indic_mask: u16 = 0,
    ligature_id: u32 = 0,
    ligature_component: u16 = 0,
};

pub const Buffer = struct {
    glyphs: std.ArrayList(Glyph) = .empty,
    next_ligature_id: u32 = 1,
    lookup_work_units: usize = 0,

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.glyphs.deinit(allocator);
        self.* = undefined;
    }

    pub fn replace(self: *Buffer, allocator: std.mem.Allocator, index: usize, count: usize, values: []const Glyph) Error!void {
        if (index > self.glyphs.items.len or count > self.glyphs.items.len - index) return error.InvalidFont;
        const retained = self.glyphs.items.len - count;
        if (retained > maximum_buffer_glyphs or values.len > maximum_buffer_glyphs - retained) return error.BudgetExceeded;
        try self.glyphs.replaceRange(allocator, index, count, values);
    }

    pub fn chargeLookupWork(self: *Buffer, amount: usize) Error!void {
        self.lookup_work_units = std.math.add(usize, self.lookup_work_units, amount) catch return error.BudgetExceeded;
        if (self.lookup_work_units > maximum_lookup_work_units) return error.BudgetExceeded;
    }
};

pub const Options = struct {
    script: [4]u8,
    language: [4]u8 = "dflt".*,
    direction: Direction,
    indic: bool = false,
    joining: bool = false,
    ppem: ?u16 = null,
    features: []const api.Feature = &.{},
};

pub const LookupApplication = struct {
    index: u16,
    tag: [4]u8,
    value: u32,
    start_utf8: usize,
    end_utf8: usize,

    pub fn applies(self: LookupApplication, glyph: Glyph) bool {
        const cluster: usize = glyph.cluster_utf8;
        if (cluster < self.start_utf8 or cluster >= self.end_utf8) return false;
        if (std.mem.eql(u8, &self.tag, "rphf")) return glyph.indic_mask & indic_rphf != 0;
        if (std.mem.eql(u8, &self.tag, "rkrf") or std.mem.eql(u8, &self.tag, "vatu")) return glyph.indic_mask & indic_rkrf != 0;
        if (std.mem.eql(u8, &self.tag, "pref")) return glyph.indic_mask & indic_pref != 0;
        if (std.mem.eql(u8, &self.tag, "blwf")) return glyph.indic_mask & indic_blwf != 0;
        if (std.mem.eql(u8, &self.tag, "half")) return glyph.indic_mask & indic_half != 0;
        if (std.mem.eql(u8, &self.tag, "pstf")) return glyph.indic_mask & indic_pstf != 0;
        if (std.mem.eql(u8, &self.tag, "isol")) return glyph.joining_form == .isolated;
        if (std.mem.eql(u8, &self.tag, "init")) return if (glyph.indic_syllable != 0)
            glyph.indic_mask & indic_init != 0
        else
            glyph.joining_form == .initial;
        if (std.mem.eql(u8, &self.tag, "medi")) return glyph.joining_form == .medial;
        if (std.mem.eql(u8, &self.tag, "fina")) return glyph.joining_form == .final;
        return true;
    }

    pub fn substituted(self: LookupApplication, glyph: *Glyph) void {
        if (glyph.indic_syllable == 0) return;
        const was_base = glyph.indic_role == .base;
        const retained: u16 = if (std.mem.eql(u8, &self.tag, "rphf")) blk: {
            glyph.indic_role = .reph;
            break :blk indic_rphf;
        } else if (std.mem.eql(u8, &self.tag, "pref")) blk: {
            glyph.indic_role = .pre_base_consonant;
            break :blk indic_pref;
        } else if (std.mem.eql(u8, &self.tag, "blwf")) blk: {
            glyph.indic_role = .below_base;
            break :blk indic_blwf;
        } else if (std.mem.eql(u8, &self.tag, "half")) blk: {
            glyph.indic_role = .pre_base;
            break :blk indic_half;
        } else if (std.mem.eql(u8, &self.tag, "pstf")) blk: {
            glyph.indic_role = .post_base;
            break :blk indic_pstf;
        } else if (std.mem.eql(u8, &self.tag, "rkrf") or std.mem.eql(u8, &self.tag, "vatu")) blk: {
            glyph.indic_role = .post_base;
            break :blk indic_rkrf;
        } else return;
        if (was_base and !std.mem.eql(u8, &self.tag, "rphf")) glyph.indic_role = .base;
        glyph.indic_mask &= ~(indic_basic_form_mask & ~retained);
    }
};

pub const Lookup = struct {
    table: []const u8,
    kind: u16,
    flags: u16,
    subtables: []const u8,
    subtable_count: u16,
    mark_filtering_set: ?u16,

    pub fn subtable(self: Lookup, index: usize) Error![]const u8 {
        if (index >= self.subtable_count) return error.InvalidFont;
        const offset = try readU16(self.subtables, index * 2);
        if (offset == 0) return error.InvalidFont;
        return offsetSlice(self.table, offset, 2);
    }
};

pub fn layoutTable(font: opentype.Font, tag: [4]u8) ?[]const u8 {
    return font.optionalTable(tag);
}

pub fn lookup(table: []const u8, lookup_index: u16) Error!Lookup {
    if (table.len < 10) return error.InvalidFont;
    const lookup_list_offset = try readU16(table, 8);
    const lookup_list = try offsetSlice(table, lookup_list_offset, 2);
    const count = try readU16(lookup_list, 0);
    if (lookup_index >= count) return error.InvalidFont;
    const offset = try readU16(lookup_list, 2 + @as(usize, lookup_index) * 2);
    const value = try offsetSlice(lookup_list, offset, 6);
    const kind = try readU16(value, 0);
    const flags = try readU16(value, 2);
    if (flags & 0x00e0 != 0) return error.InvalidFont;
    const subtable_count = try readU16(value, 4);
    if (subtable_count == 0) return error.InvalidFont;
    const offsets_length = std.math.mul(usize, subtable_count, 2) catch return error.InvalidFont;
    if (6 + offsets_length > value.len) return error.InvalidFont;
    const filtering = if (flags & 0x0010 != 0) try readU16(value, 6 + offsets_length) else null;
    return .{
        .table = value,
        .kind = kind,
        .flags = flags,
        .subtables = value[6..][0..offsets_length],
        .subtable_count = subtable_count,
        .mark_filtering_set = filtering,
    };
}

pub fn collectLookups(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    table: []const u8,
    options: Options,
    positioning: bool,
) Error![]LookupApplication {
    if (table.len < 10 or try readU16(table, 0) != 1 or try readU16(table, 2) > 1) return error.InvalidFont;
    const script_list = try offsetSlice(table, try readU16(table, 4), 2);
    const feature_list = try offsetSlice(table, try readU16(table, 6), 2);
    const language = (try selectLanguage(script_list, options.script, options.language)) orelse return allocator.alloc(LookupApplication, 0);
    const substitutions = try selectFeatureSubstitutions(table, font.variation_coordinates);
    const required = try readU16(language, 2);
    const language_feature_count = try readU16(language, 4);
    if (6 + @as(usize, language_feature_count) * 2 > language.len) return error.InvalidFont;
    const total_feature_count = try readU16(feature_list, 0);
    const appended = try allocator.alloc(bool, total_feature_count);
    defer allocator.free(appended);
    @memset(appended, false);
    var result: std.ArrayList(LookupApplication) = .empty;
    errdefer result.deinit(allocator);
    if (required != 0xffff) try appendFeatureIndex(
        allocator,
        feature_list,
        substitutions,
        required,
        true,
        positioning,
        options,
        appended,
        &result,
    );
    for (orderedFeatureTags(options.script, options.indic, options.joining, positioning)) |tag| try appendFeatureTag(
        allocator,
        feature_list,
        language,
        language_feature_count,
        substitutions,
        tag,
        positioning,
        options,
        appended,
        &result,
    );
    for (options.features) |setting| try appendFeatureTag(
        allocator,
        feature_list,
        language,
        language_feature_count,
        substitutions,
        setting.tag,
        positioning,
        options,
        appended,
        &result,
    );
    var index: usize = 0;
    while (index < language_feature_count) : (index += 1) {
        const feature_index = try readU16(language, 6 + index * 2);
        if (feature_index == required) continue;
        try appendFeatureIndex(
            allocator,
            feature_list,
            substitutions,
            feature_index,
            false,
            positioning,
            options,
            appended,
            &result,
        );
    }
    return result.toOwnedSlice(allocator);
}

fn appendFeatureTag(
    allocator: std.mem.Allocator,
    feature_list: []const u8,
    language: []const u8,
    language_feature_count: u16,
    substitutions: ?[]const u8,
    tag: [4]u8,
    positioning: bool,
    options: Options,
    appended: []bool,
    output: *std.ArrayList(LookupApplication),
) Error!void {
    var index: usize = 0;
    while (index < language_feature_count) : (index += 1) {
        const feature_index = try readU16(language, 6 + index * 2);
        if (@as(usize, feature_index) >= appended.len) return error.InvalidFont;
        const record = 2 + @as(usize, feature_index) * 6;
        if (record + 6 > feature_list.len) return error.InvalidFont;
        if (!std.mem.eql(u8, feature_list[record..][0..4], &tag)) continue;
        try appendFeatureIndex(
            allocator,
            feature_list,
            substitutions,
            feature_index,
            false,
            positioning,
            options,
            appended,
            output,
        );
    }
}

fn appendFeatureIndex(
    allocator: std.mem.Allocator,
    feature_list: []const u8,
    substitutions: ?[]const u8,
    feature_index: u16,
    required: bool,
    positioning: bool,
    options: Options,
    appended: []bool,
    output: *std.ArrayList(LookupApplication),
) Error!void {
    if (@as(usize, feature_index) >= appended.len) return error.InvalidFont;
    if (appended[feature_index]) return;
    appended[feature_index] = true;
    try appendFeatureLookups(allocator, feature_list, substitutions, feature_index, required, positioning, options, output);
}

fn orderedFeatureTags(script: [4]u8, indic: bool, joining: bool, positioning: bool) []const [4]u8 {
    if (positioning) {
        if (indic or isIndicScriptTag(script)) return &.{ "dist".*, "abvm".*, "blwm".*, "kern".*, "mark".*, "mkmk".* };
        if (joining or isJoiningScriptTag(script)) return &.{ "curs".*, "kern".*, "mark".*, "mkmk".* };
        return &.{ "kern".*, "mark".*, "mkmk".*, "curs".*, "dist".* };
    }
    if (joining or isJoiningScriptTag(script)) return &.{
        "rvrn".*, "locl".*, "ccmp".*, "rlig".*, "isol".*, "fina".*, "fin2".*, "fin3".*,
        "medi".*, "med2".*, "init".*, "calt".*, "mset".*, "liga".*, "clig".*,
    };
    if (indic or isIndicScriptTag(script)) return &.{
        "rvrn".*, "locl".*, "ccmp".*, "nukt".*, "akhn".*, "rphf".*, "rkrf".*, "pref".*,
        "blwf".*, "half".*, "vatu".*, "pstf".*, "cjct".*, "init".*, "pres".*, "abvs".*,
        "blws".*, "psts".*, "haln".*, "calt".*, "rlig".*, "liga".*, "clig".*,
    };
    if (std.mem.eql(u8, &script, "hang")) return &.{ "rvrn".*, "locl".*, "ccmp".*, "ljmo".*, "vjmo".*, "tjmo".* };
    return &.{ "rvrn".*, "locl".*, "ccmp".*, "rlig".*, "liga".*, "clig".*, "calt".* };
}

fn isJoiningScriptTag(script: [4]u8) bool {
    return std.mem.eql(u8, &script, "arab") or std.mem.eql(u8, &script, "syrc") or
        std.mem.eql(u8, &script, "nko ") or std.mem.eql(u8, &script, "adlm") or
        std.mem.eql(u8, &script, "mong");
}

fn isIndicScriptTag(script: [4]u8) bool {
    return anyTag(script, &.{
        "dev2".*, "bng2".*, "gur2".*, "gjr2".*, "ory2".*, "tml2".*, "tel2".*,
        "knd2".*, "mlm2".*, "sinh".*, "mym2".*, "khmr".*,
    });
}

fn legacyIndicTag(script: [4]u8) ?[4]u8 {
    if (std.mem.eql(u8, &script, "dev2")) return "deva".*;
    if (std.mem.eql(u8, &script, "bng2")) return "beng".*;
    if (std.mem.eql(u8, &script, "gur2")) return "guru".*;
    if (std.mem.eql(u8, &script, "gjr2")) return "gujr".*;
    if (std.mem.eql(u8, &script, "ory2")) return "orya".*;
    if (std.mem.eql(u8, &script, "tml2")) return "taml".*;
    if (std.mem.eql(u8, &script, "tel2")) return "telu".*;
    if (std.mem.eql(u8, &script, "knd2")) return "knda".*;
    if (std.mem.eql(u8, &script, "mlm2")) return "mlym".*;
    if (std.mem.eql(u8, &script, "mym2")) return "mymr".*;
    return null;
}

fn selectLanguage(script_list: []const u8, script_tag: [4]u8, language_tag: [4]u8) Error!?[]const u8 {
    const count = try readU16(script_list, 0);
    var selected: ?[]const u8 = null;
    var legacy_selected: ?[]const u8 = null;
    var default_script: ?[]const u8 = null;
    const legacy_tag = legacyIndicTag(script_tag);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const record = 2 + index * 6;
        if (record + 6 > script_list.len) return error.InvalidFont;
        const tag = script_list[record..][0..4];
        const script = try offsetSlice(script_list, try readU16(script_list, record + 4), 4);
        if (std.mem.eql(u8, tag, &script_tag)) selected = script;
        if (legacy_tag) |legacy| {
            if (std.mem.eql(u8, tag, &legacy)) legacy_selected = script;
        }
        if (std.mem.eql(u8, tag, "DFLT")) default_script = script;
    }
    const script = selected orelse legacy_selected orelse default_script orelse return null;
    const default_offset = try readU16(script, 0);
    const language_count = try readU16(script, 2);
    var selected_language: ?[]const u8 = null;
    index = 0;
    while (index < language_count) : (index += 1) {
        const record = 4 + index * 6;
        if (record + 6 > script.len) return error.InvalidFont;
        if (std.mem.eql(u8, script[record..][0..4], &language_tag))
            selected_language = try offsetSlice(script, try readU16(script, record + 4), 6);
    }
    if (selected_language) |value| return value;
    if (default_offset != 0) return try offsetSlice(script, default_offset, 6);
    if (language_count != 0) return try offsetSlice(script, try readU16(script, 8), 6);
    return null;
}

fn appendFeatureLookups(
    allocator: std.mem.Allocator,
    feature_list: []const u8,
    substitutions: ?[]const u8,
    feature_index: u16,
    required: bool,
    positioning: bool,
    options: Options,
    output: *std.ArrayList(LookupApplication),
) Error!void {
    const feature_count = try readU16(feature_list, 0);
    if (feature_index >= feature_count) return error.InvalidFont;
    const record = 2 + @as(usize, feature_index) * 6;
    if (record + 6 > feature_list.len) return error.InvalidFont;
    const tag: [4]u8 = feature_list[record..][0..4].*;
    const setting = featureSetting(tag, required, positioning, options.features) orelse return;
    if (setting.value == 0) return;
    const feature = if (substitutions) |table|
        (try alternateFeature(table, feature_index)) orelse try offsetSlice(feature_list, try readU16(feature_list, record + 4), 4)
    else
        try offsetSlice(feature_list, try readU16(feature_list, record + 4), 4);
    const lookup_count = try readU16(feature, 2);
    if (4 + @as(usize, lookup_count) * 2 > feature.len) return error.InvalidFont;
    if (output.items.len > maximum_lookup_applications -| @as(usize, lookup_count)) return error.BudgetExceeded;
    var index: usize = 0;
    while (index < lookup_count) : (index += 1) try output.append(allocator, .{
        .index = try readU16(feature, 4 + index * 2),
        .tag = tag,
        .value = setting.value,
        .start_utf8 = setting.start_utf8,
        .end_utf8 = setting.end_utf8,
    });
}

fn selectFeatureSubstitutions(table: []const u8, coordinates: []const i16) Error!?[]const u8 {
    if (try readU16(table, 2) < 1) return null;
    if (table.len < 14) return error.InvalidFont;
    const variations_offset = try readU32(table, 10);
    if (variations_offset == 0) return null;
    const variations = try offsetSlice(table, variations_offset, 8);
    if (try readU16(variations, 0) != 1 or try readU16(variations, 2) != 0) return null;
    const record_count = try readU32(variations, 4);
    if (8 + @as(usize, record_count) * 8 > variations.len) return error.InvalidFont;
    var record: usize = 0;
    while (record < record_count) : (record += 1) {
        const condition_offset = try readU32(variations, 8 + record * 8);
        if (condition_offset == 0) return error.InvalidFont;
        if (!try conditionSetMatches(variations, condition_offset, coordinates)) continue;
        const substitution_offset = try readU32(variations, 8 + record * 8 + 4);
        if (substitution_offset == 0) return null;
        const substitutions = try offsetSlice(variations, substitution_offset, 6);
        if (try readU16(substitutions, 0) != 1) continue;
        return substitutions;
    }
    return null;
}

fn conditionSetMatches(base: []const u8, set_offset: usize, coordinates: []const i16) Error!bool {
    const set = try offsetSlice(base, set_offset, 2);
    const count = try readU16(set, 0);
    if (2 + @as(usize, count) * 4 > set.len) return error.InvalidFont;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const condition_offset = try readU32(set, 2 + index * 4);
        const condition = try offsetSlice(set, condition_offset, 8);
        if (try readU16(condition, 0) != 1) return false;
        const axis = try readU16(condition, 2);
        if (axis >= coordinates.len) return false;
        const minimum = try readI16(condition, 4);
        const maximum = try readI16(condition, 6);
        if (minimum < -16384 or maximum > 16384 or minimum > maximum) return error.InvalidFont;
        if (coordinates[axis] < minimum or coordinates[axis] > maximum) return false;
    }
    return true;
}

fn alternateFeature(substitutions: []const u8, feature_index: u16) Error!?[]const u8 {
    if (substitutions.len < 6 or try readU16(substitutions, 0) != 1 or try readU16(substitutions, 2) != 0) return error.InvalidFont;
    const count = try readU16(substitutions, 4);
    if (6 + @as(usize, count) * 6 > substitutions.len) return error.InvalidFont;
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (try readU16(substitutions, 6 + middle * 6) < feature_index) low = middle + 1 else high = middle;
    }
    if (low >= count or try readU16(substitutions, 6 + low * 6) != feature_index) return null;
    return try offsetSlice(substitutions, try readU32(substitutions, 6 + low * 6 + 2), 4);
}

fn featureSetting(tag: [4]u8, required: bool, positioning: bool, features: []const api.Feature) ?api.Feature {
    if (required) return .{ .tag = tag, .value = 1 };
    var selected: ?api.Feature = null;
    for (features) |feature| {
        if (std.mem.eql(u8, &feature.tag, &tag)) selected = feature;
    }
    if (selected) |value| return value;
    if (defaultFeature(tag, positioning)) return .{ .tag = tag, .value = 1 };
    return null;
}

fn defaultFeature(tag: [4]u8, positioning: bool) bool {
    if (positioning) return anyTag(tag, &.{
        "abvm".*, "blwm".*, "curs".*, "dist".*, "kern".*, "mark".*, "mkmk".*, "vkrn".*,
    });
    return anyTag(tag, &.{
        "abvf".*, "abvs".*, "akhn".*, "blwf".*, "blws".*, "calt".*, "ccmp".*, "cjct".*,
        "clig".*, "fin2".*, "fin3".*, "fina".*, "half".*, "haln".*, "init".*, "isol".*,
        "liga".*, "ljmo".*, "locl".*, "medi".*, "med2".*, "mset".*, "nukt".*, "pref".*,
        "pres".*, "pstf".*, "psts".*, "rclt".*, "rlig".*, "rkrf".*, "rphf".*, "rvrn".*,
        "tjmo".*, "vatu".*, "vjmo".*,
    });
}

fn anyTag(tag: [4]u8, values: []const [4]u8) bool {
    for (values) |value| if (std.mem.eql(u8, &tag, &value)) return true;
    return false;
}

pub fn scriptTag(script: unicode.Script) [4]u8 {
    return switch (script) {
        .bengali => "bng2".*,
        .devanagari => "dev2".*,
        .gujarati => "gjr2".*,
        .gurmukhi => "gur2".*,
        .kannada => "knd2".*,
        .malayalam => "mlm2".*,
        .myanmar => "mym2".*,
        .oriya => "ory2".*,
        .tamil => "tml2".*,
        .telugu => "tel2".*,
        .hiragana, .katakana => "kana".*,
        .nko => "nko ".*,
        .lao => "lao ".*,
        .vai => "vai ".*,
        .yi => "yi  ".*,
        .unknown, .common, .inherited => "DFLT".*,
        else => blk: {
            var tag = unicode.data.scriptIsoTag(script);
            for (&tag) |*byte| byte.* = std.ascii.toLower(byte.*);
            break :blk tag;
        },
    };
}

pub fn languageTag(locale: []const u8) [4]u8 {
    return opentype_language.tag(locale);
}

pub fn coverageIndex(base: []const u8, offset: usize, glyph: u16) Error!?u16 {
    const coverage = try offsetSlice(base, offset, 4);
    return switch (try readU16(coverage, 0)) {
        1 => blk: {
            const count = try readU16(coverage, 2);
            var low: usize = 0;
            var high: usize = count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const value = try readU16(coverage, 4 + middle * 2);
                if (value < glyph) low = middle + 1 else high = middle;
            }
            if (low < count and try readU16(coverage, 4 + low * 2) == glyph) break :blk @intCast(low);
            break :blk null;
        },
        2 => blk: {
            const count = try readU16(coverage, 2);
            var low: usize = 0;
            var high: usize = count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const record = 4 + middle * 6;
                const end = try readU16(coverage, record + 2);
                if (end < glyph) low = middle + 1 else high = middle;
            }
            if (low >= count) break :blk null;
            const record = 4 + low * 6;
            const start = try readU16(coverage, record);
            const end = try readU16(coverage, record + 2);
            if (glyph < start or glyph > end) break :blk null;
            const result = @as(u32, try readU16(coverage, record + 4)) + glyph - start;
            if (result > std.math.maxInt(u16)) return error.InvalidFont;
            break :blk @intCast(result);
        },
        else => error.InvalidFont,
    };
}

pub fn classValue(base: []const u8, offset: usize, glyph: u16) Error!u16 {
    if (offset == 0) return 0;
    const table = try offsetSlice(base, offset, 4);
    return switch (try readU16(table, 0)) {
        1 => blk: {
            const start = try readU16(table, 2);
            const count = try readU16(table, 4);
            if (glyph < start or glyph - start >= count) break :blk 0;
            break :blk try readU16(table, 6 + @as(usize, glyph - start) * 2);
        },
        2 => blk: {
            const count = try readU16(table, 2);
            var low: usize = 0;
            var high: usize = count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                const record = 4 + middle * 6;
                if (try readU16(table, record + 2) < glyph) low = middle + 1 else high = middle;
            }
            if (low >= count) break :blk 0;
            const record = 4 + low * 6;
            if (glyph < try readU16(table, record) or glyph > try readU16(table, record + 2)) break :blk 0;
            break :blk try readU16(table, record + 4);
        },
        else => error.InvalidFont,
    };
}

pub fn ignored(font: opentype.Font, glyph: Glyph, lookup_value: Lookup) bool {
    const glyph_class = glyphClass(font, glyph.id) catch 0;
    if (lookup_value.flags & 0x0002 != 0 and glyph_class == 1) return true;
    if (lookup_value.flags & 0x0004 != 0 and glyph_class == 2) return true;
    if (lookup_value.flags & 0x0008 != 0 and glyph_class == 3) return true;
    if (glyph_class == 3) {
        const attachment = @as(u16, lookup_value.flags >> 8);
        if (attachment != 0 and (markAttachmentClass(font, glyph.id) catch 0) != attachment) return true;
        if (lookup_value.mark_filtering_set) |set| if (!(markInSet(font, glyph.id, set) catch false)) return true;
    }
    return false;
}

pub fn nextIncluded(font: opentype.Font, buffer: *Buffer, start: usize, lookup_value: Lookup) Error!?usize {
    var index = start;
    while (index < buffer.glyphs.items.len) : (index += 1) {
        try buffer.chargeLookupWork(1);
        if (!ignored(font, buffer.glyphs.items[index], lookup_value)) return index;
    }
    return null;
}

pub fn previousIncluded(font: opentype.Font, buffer: *Buffer, start: usize, lookup_value: Lookup) Error!?usize {
    var index = start;
    while (index > 0) {
        index -= 1;
        try buffer.chargeLookupWork(1);
        if (!ignored(font, buffer.glyphs.items[index], lookup_value)) return index;
    }
    return null;
}

fn glyphClass(font: opentype.Font, glyph: u16) Error!u16 {
    const gdef = font.optionalTable("GDEF".*) orelse return 0;
    if (gdef.len < 4) return error.InvalidFont;
    return classValue(gdef, try readU16(gdef, 4), glyph);
}

fn markAttachmentClass(font: opentype.Font, glyph: u16) Error!u16 {
    const gdef = font.optionalTable("GDEF".*) orelse return 0;
    if (gdef.len < 12) return 0;
    return classValue(gdef, try readU16(gdef, 10), glyph);
}

fn markInSet(font: opentype.Font, glyph: u16, set_index: u16) Error!bool {
    const gdef = font.optionalTable("GDEF".*) orelse return false;
    if (gdef.len < 14) return false;
    const major = try readU16(gdef, 0);
    const minor = try readU16(gdef, 2);
    if (major < 1 or minor < 2) return false;
    const sets_offset = try readU16(gdef, 12);
    if (sets_offset == 0) return false;
    const sets = try offsetSlice(gdef, sets_offset, 4);
    if (try readU16(sets, 0) != 1 or set_index >= try readU16(sets, 2)) return false;
    const coverage_offset = try readU32(sets, 4 + @as(usize, set_index) * 4);
    return try coverageIndex(sets, coverage_offset, glyph) != null;
}

pub fn offsetSlice(base: []const u8, offset: usize, minimum: usize) Error![]const u8 {
    if (offset > base.len or minimum > base.len - offset) return error.InvalidFont;
    return base[offset..];
}

pub fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or 2 > bytes.len - offset) return error.InvalidFont;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

pub fn readI16(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try readU16(bytes, offset));
}

pub fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or 4 > bytes.len - offset) return error.InvalidFont;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

// Preserve the concise table-reader surface used by GSUB/GPOS modules while
// avoiding Zig 0.17's primitive-name shadowing rule inside this module.
pub const @"u16" = readU16;
pub const @"i16" = readI16;
pub const @"u32" = readU32;
