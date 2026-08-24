const std = @import("std");
const Error = @import("../core/error.zig").Error;
const opentype = @import("opentype.zig");
const unicode = @import("unicode.zig");
const layout = @import("opentype_layout.zig");
const aat = @import("opentype_aat.zig");
const gsub = @import("opentype_gsub.zig");
const gpos = @import("opentype_gpos.zig");

pub const Input = struct { scalar: u21, cluster_utf8: u32 };

pub fn shape(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    input: []const Input,
    options: layout.Options,
) Error!layout.Buffer {
    if (input.len > layout.maximum_buffer_glyphs) return error.BudgetExceeded;
    var normalized: std.ArrayList(Input) = .empty;
    defer normalized.deinit(allocator);
    try normalizeShapingInput(allocator, font, input, &normalized);
    var buffer: layout.Buffer = .{};
    errdefer buffer.deinit(allocator);
    try buffer.glyphs.ensureTotalCapacity(allocator, normalized.items.len);
    var normalized_index: usize = 0;
    while (normalized_index < normalized.items.len) {
        const value = normalized.items[normalized_index];
        if (isVariationSelector(value.scalar)) {
            normalized_index += 1;
            continue;
        }
        var glyph = try font.glyphIndex(value.scalar);
        if (normalized_index + 1 < normalized.items.len and isVariationSelector(normalized.items[normalized_index + 1].scalar)) {
            glyph = (try font.variationGlyphIndex(value.scalar, normalized.items[normalized_index + 1].scalar)) orelse glyph;
            normalized_index += 1;
        }
        buffer.glyphs.appendAssumeCapacity(.{
            .id = glyph,
            .cluster_utf8 = value.cluster_utf8,
            .scalar = value.scalar,
        });
        normalized_index += 1;
    }
    assignJoiningForms(buffer.glyphs.items);
    var resolved_options = options;
    resolved_options.joining = hasJoiningForms(buffer.glyphs.items);
    const indic = prepareIndic(buffer.glyphs.items);
    if (indic) try insertDottedCircles(allocator, font, &buffer);
    resolved_options.indic = indic;

    if (font.optionalTable("morx".*) != null) {
        try aat.apply(allocator, font, &buffer, resolved_options);
    } else if (font.optionalTable("GSUB".*)) |table| {
        const applications = try layout.collectLookups(allocator, font, table, resolved_options, false);
        defer allocator.free(applications);
        if (indic) {
            const late_start = lateIndicFeatureStart(applications);
            try gsub.apply(allocator, font, &buffer, applications[0..late_start]);
            resolveIndicBases(buffer.glyphs.items);
            try gsub.apply(allocator, font, &buffer, applications[late_start..]);
            reorderResolvedIndic(buffer.glyphs.items);
        } else {
            try gsub.apply(allocator, font, &buffer, applications);
        }
    } else if (indic) {
        resolveIndicBases(buffer.glyphs.items);
        reorderResolvedIndic(buffer.glyphs.items);
    }
    for (buffer.glyphs.items) |*glyph| {
        if (glyph.id == 0 and unicode.isDefaultIgnorable(glyph.scalar)) {
            glyph.advance_x = 0;
            glyph.advance_y = 0;
            continue;
        }
        const metric = try font.horizontalMetric(allocator, glyph.id);
        glyph.advance_x = metric.advance;
    }
    var positioned_kern = false;
    if (font.optionalTable("GPOS".*)) |table| {
        const applications = try layout.collectLookups(allocator, font, table, resolved_options, true);
        defer allocator.free(applications);
        var positioning_font = font;
        positioning_font.pixels_per_em = resolved_options.ppem;
        positioned_kern = try gpos.apply(allocator, positioning_font, &buffer, applications, resolved_options.direction);
    }
    if (!positioned_kern) applyLegacyKerning(font, buffer.glyphs.items);
    if (options.direction == .right_to_left) std.mem.reverse(layout.Glyph, buffer.glyphs.items);
    return buffer;
}

fn normalizeShapingInput(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    input: []const Input,
    output: *std.ArrayList(Input),
) Error!void {
    for (input) |value| {
        const category = unicode.indicProperties(value.scalar).syllabic;
        if (category == .other or unicode.data.decomposition(value.scalar, false) == null) {
            try appendNormalized(allocator, output, value);
            continue;
        }
        const checkpoint = output.items.len;
        try appendCanonicalDecomposition(allocator, output, value.scalar, value.cluster_utf8, 0);
        var missing_component = false;
        for (output.items[checkpoint..]) |component| if (try font.glyphIndex(component.scalar) == 0) {
            missing_component = true;
            break;
        };
        if (missing_component and try font.glyphIndex(value.scalar) != 0) {
            output.items.len = checkpoint;
            try appendNormalized(allocator, output, value);
        }
    }
    canonicalOrder(output.items);
}

fn isVariationSelector(scalar: u21) bool {
    return (scalar >= 0xfe00 and scalar <= 0xfe0f) or (scalar >= 0xe0100 and scalar <= 0xe01ef);
}

fn appendCanonicalDecomposition(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(Input),
    scalar: u21,
    cluster_utf8: u32,
    depth: u8,
) Error!void {
    if (depth >= 32) return error.InvalidFont;
    const decomposition = unicode.data.decomposition(scalar, false) orelse {
        try appendNormalized(allocator, output, .{ .scalar = scalar, .cluster_utf8 = cluster_utf8 });
        return;
    };
    for (decomposition) |component| try appendCanonicalDecomposition(
        allocator,
        output,
        component,
        cluster_utf8,
        depth + 1,
    );
}

fn appendNormalized(allocator: std.mem.Allocator, output: *std.ArrayList(Input), value: Input) Error!void {
    if (output.items.len == layout.maximum_buffer_glyphs) return error.BudgetExceeded;
    try output.append(allocator, value);
}

fn canonicalOrder(input: []Input) void {
    var index: usize = 1;
    while (index < input.len) : (index += 1) {
        const combining = unicode.properties(input[index].scalar).combining;
        if (combining == 0) continue;
        const value = input[index];
        var destination = index;
        while (destination > 0) {
            const previous = unicode.properties(input[destination - 1].scalar).combining;
            if (previous == 0 or previous <= combining) break;
            input[destination] = input[destination - 1];
            destination -= 1;
        }
        input[destination] = value;
    }
}

fn assignJoiningForms(glyphs: []layout.Glyph) void {
    for (glyphs, 0..) |*glyph, index| {
        const joining = unicode.properties(glyph.scalar).joining;
        if (joining == .u or joining == .t) continue;
        const previous = previousJoining(glyphs, index);
        const next = nextJoining(glyphs, index + 1);
        const connected_previous = if (previous) |position|
            joinsFollowing(unicode.properties(glyphs[position].scalar).joining) and joinsPrevious(joining)
        else
            false;
        const connected_next = if (next) |position|
            joinsFollowing(joining) and joinsPrevious(unicode.properties(glyphs[position].scalar).joining)
        else
            false;
        glyph.joining_form = if (connected_previous and connected_next)
            .medial
        else if (connected_previous)
            .final
        else if (connected_next)
            .initial
        else
            .isolated;
    }
}

fn hasJoiningForms(glyphs: []const layout.Glyph) bool {
    for (glyphs) |glyph| {
        const joining = unicode.properties(glyph.scalar).joining;
        if (joining != .u and joining != .t) return true;
    }
    return false;
}

fn previousJoining(glyphs: []const layout.Glyph, start: usize) ?usize {
    var index = start;
    while (index > 0) {
        index -= 1;
        if (unicode.properties(glyphs[index].scalar).joining != .t) return index;
    }
    return null;
}

fn nextJoining(glyphs: []const layout.Glyph, start: usize) ?usize {
    var index = start;
    while (index < glyphs.len) : (index += 1) if (unicode.properties(glyphs[index].scalar).joining != .t) return index;
    return null;
}

fn joinsFollowing(value: unicode.JoiningType) bool {
    return value == .d or value == .l or value == .c;
}

fn joinsPrevious(value: unicode.JoiningType) bool {
    return value == .d or value == .r or value == .c;
}

fn prepareIndic(glyphs: []layout.Glyph) bool {
    var found = false;
    for (glyphs) |glyph| if (unicode.indicProperties(glyph.scalar).syllabic != .other) {
        found = true;
        break;
    };
    if (!found) return false;

    var start: usize = 0;
    var syllable: u32 = 1;
    while (start < glyphs.len) {
        const end = nextIndicSyllableEnd(glyphs, start);
        if (containsIndic(glyphs[start..end])) {
            prepareIndicSyllable(glyphs[start..end], syllable);
            syllable +%= 1;
            if (syllable == 0) syllable = 1;
        }
        start = end;
    }
    return true;
}

fn insertDottedCircles(allocator: std.mem.Allocator, font: opentype.Font, buffer: *layout.Buffer) Error!void {
    const dotted_glyph = try font.glyphIndex(0x25cc);
    if (dotted_glyph == 0) return;
    var start: usize = 0;
    while (start < buffer.glyphs.items.len) {
        const syllable = buffer.glyphs.items[start].indic_syllable;
        if (syllable == 0) {
            start += 1;
            continue;
        }
        var end = start + 1;
        var has_base = isBaseCategory(unicode.indicProperties(buffer.glyphs.items[start].scalar).syllabic);
        while (end < buffer.glyphs.items.len and buffer.glyphs.items[end].indic_syllable == syllable) : (end += 1)
            has_base = has_base or isBaseCategory(unicode.indicProperties(buffer.glyphs.items[end].scalar).syllabic);
        if (!has_base) {
            const cluster = buffer.glyphs.items[start].cluster_utf8;
            const dotted: layout.Glyph = .{
                .id = dotted_glyph,
                .cluster_utf8 = cluster,
                .scalar = 0x25cc,
                .indic_role = .base,
                .indic_syllable = syllable,
            };
            try buffer.replace(allocator, start, 0, &.{dotted});
            end += 1;
        }
        start = end;
    }
}

fn containsIndic(glyphs: []const layout.Glyph) bool {
    for (glyphs) |glyph| if (unicode.indicProperties(glyph.scalar).syllabic != .other) return true;
    return false;
}

fn nextIndicSyllableEnd(glyphs: []const layout.Glyph, start: usize) usize {
    const first = unicode.indicProperties(glyphs[start].scalar).syllabic;
    if (first == .other and unicode.properties(glyphs[start].scalar).combining == 0 and
        !unicode.isDefaultIgnorable(glyphs[start].scalar)) return start + 1;

    var has_base = isBaseCategory(first);
    var link_pending = isLinker(first);
    var index = start + 1;
    while (index < glyphs.len) : (index += 1) {
        const scalar = glyphs[index].scalar;
        const category = unicode.indicProperties(scalar).syllabic;
        if (isBaseCategory(category)) {
            if (has_base and !link_pending) break;
            has_base = true;
            link_pending = false;
            continue;
        }
        if (isLinker(category)) {
            link_pending = true;
            continue;
        }
        if (isJoinControl(category) or isAttachmentCategory(category)) continue;
        const property = unicode.properties(scalar);
        if (category == .other and (property.combining != 0 or property.defaultIgnorable())) continue;
        break;
    }
    return index;
}

fn prepareIndicSyllable(glyphs: []layout.Glyph, syllable: u32) void {
    for (glyphs) |*glyph| {
        glyph.indic_syllable = syllable;
        glyph.indic_role = roleForScalar(glyph.scalar);
        glyph.indic_mask = 0;
    }

    const reph_end = initialRephEnd(glyphs);
    var provisional_base: ?usize = null;
    for (glyphs, 0..) |glyph, index| {
        if (!isConsonantBase(unicode.indicProperties(glyph.scalar).syllabic)) continue;
        if (reph_end != null and index < reph_end.?) continue;
        provisional_base = index;
        break;
    }
    if (provisional_base == null) for (glyphs, 0..) |glyph, index| {
        if (isBaseCategory(unicode.indicProperties(glyph.scalar).syllabic)) {
            provisional_base = index;
            break;
        }
    };

    if (provisional_base) |base| glyphs[base].indic_role = .base;
    var consonants: usize = 0;
    for (glyphs) |glyph| if (isConsonantBase(unicode.indicProperties(glyph.scalar).syllabic)) {
        consonants += 1;
    };
    if (consonants > 1) for (glyphs) |*glyph| {
        glyph.indic_mask |= layout.indic_rkrf | layout.indic_pref | layout.indic_blwf;
    };
    if (reph_end) |end| {
        for (glyphs[0..end]) |*glyph| glyph.indic_mask |= layout.indic_rphf;
    }

    if (provisional_base) |base| movePrebaseMarks(glyphs, base);
    for (glyphs) |*glyph| if (glyph.indic_role == .pre_base_mark) {
        glyph.indic_mask |= layout.indic_init;
        break;
    };
}

fn initialRephEnd(glyphs: []const layout.Glyph) ?usize {
    var first: ?usize = null;
    for (glyphs, 0..) |glyph, index| {
        const category = unicode.indicProperties(glyph.scalar).syllabic;
        if (isConsonantBase(category)) {
            first = index;
            break;
        }
        if (!isAttachmentCategory(category)) return null;
    }
    const consonant = first orelse return null;
    var cursor = consonant + 1;
    while (cursor < glyphs.len and unicode.indicProperties(glyphs[cursor].scalar).syllabic == .nukta) : (cursor += 1) {}
    if (cursor >= glyphs.len or !isLinker(unicode.indicProperties(glyphs[cursor].scalar).syllabic)) return null;
    cursor += 1;
    if (cursor < glyphs.len and isJoinControl(unicode.indicProperties(glyphs[cursor].scalar).syllabic)) return null;
    for (glyphs[cursor..]) |glyph| if (isConsonantBase(unicode.indicProperties(glyph.scalar).syllabic)) return cursor;
    return null;
}

fn movePrebaseMarks(glyphs: []layout.Glyph, provisional_base: usize) void {
    var base = provisional_base;
    var insert = provisional_base;
    var index = provisional_base + 1;
    while (index < glyphs.len) {
        if (glyphs[index].indic_role != .pre_base_mark) {
            index += 1;
            continue;
        }
        moveGlyph(glyphs, index, insert);
        insert += 1;
        base += 1;
        index = @max(index, base + 1);
    }
}

fn lateIndicFeatureStart(applications: []const layout.LookupApplication) usize {
    for (applications, 0..) |application, index| if (isLateIndicFeature(application.tag)) return index;
    return applications.len;
}

fn isLateIndicFeature(tag: [4]u8) bool {
    return tagEqual(tag, "half") or tagEqual(tag, "vatu") or tagEqual(tag, "pstf") or
        tagEqual(tag, "cjct") or tagEqual(tag, "init") or tagEqual(tag, "pres") or
        tagEqual(tag, "abvs") or tagEqual(tag, "blws") or tagEqual(tag, "psts") or
        tagEqual(tag, "haln") or tagEqual(tag, "calt") or tagEqual(tag, "rlig") or
        tagEqual(tag, "liga") or tagEqual(tag, "clig");
}

fn tagEqual(left: [4]u8, right: *const [4]u8) bool {
    return std.mem.eql(u8, &left, right);
}

fn resolveIndicBases(glyphs: []layout.Glyph) void {
    var start: usize = 0;
    while (start < glyphs.len) {
        if (glyphs[start].indic_syllable == 0) {
            start += 1;
            continue;
        }
        const syllable = glyphs[start].indic_syllable;
        var end = start + 1;
        while (end < glyphs.len and glyphs[end].indic_syllable == syllable) end += 1;
        resolveIndicSyllable(glyphs[start..end]);
        start = end;
    }
}

fn resolveIndicSyllable(glyphs: []layout.Glyph) void {
    var old_base: ?usize = null;
    var new_base: ?usize = null;
    for (glyphs, 0..) |glyph, index| {
        if (glyph.indic_role == .base) old_base = index;
        if (glyph.indic_role == .none and isBaseCategory(unicode.indicProperties(glyph.scalar).syllabic)) new_base = index;
    }
    const base = new_base orelse old_base orelse blk: {
        var fallback: ?usize = null;
        for (glyphs, 0..) |glyph, index| {
            if (isBaseCategory(unicode.indicProperties(glyph.scalar).syllabic)) fallback = index;
        }
        break :blk fallback orelse {
            assignBrokenSyllableRoles(glyphs);
            reorderIndicSyllable(glyphs);
            return;
        };
    };
    if (new_base != null and old_base != null and old_base.? != base and glyphs[old_base.?].indic_role == .base)
        glyphs[old_base.?].indic_role = .none;
    glyphs[base].indic_role = .base;

    for (glyphs, 0..) |*glyph, index| {
        if (glyph.indic_role == .reph or glyph.indic_role == .pre_base_consonant or
            glyph.indic_role == .below_base or glyph.indic_role == .post_base or
            glyph.indic_role == .above_base or glyph.indic_role == .pre_base_mark or
            glyph.indic_role == .mark or index == base) continue;
        glyph.indic_role = if (index < base) .pre_base else .post_base;
    }
    for (glyphs[0..base]) |*glyph| if (glyph.indic_role != .reph and glyph.indic_role != .pre_base_mark) {
        glyph.indic_mask |= layout.indic_half;
    };
    for (glyphs[base..]) |*glyph| glyph.indic_mask |= layout.indic_pstf;
    suppressHalfAcrossNonJoiners(glyphs, base);
    reorderIndicSyllable(glyphs);
}

fn assignBrokenSyllableRoles(glyphs: []layout.Glyph) void {
    for (glyphs) |*glyph| {
        if (glyph.indic_role == .none) glyph.indic_role = roleForScalar(glyph.scalar);
    }
}

fn suppressHalfAcrossNonJoiners(glyphs: []layout.Glyph, base: usize) void {
    for (glyphs[0..base], 0..) |glyph, index| {
        if (unicode.indicProperties(glyph.scalar).syllabic != .non_joiner) continue;
        var cursor = index + 1;
        while (cursor > 0) {
            cursor -= 1;
            glyphs[cursor].indic_mask &= ~layout.indic_half;
            if (isConsonantBase(unicode.indicProperties(glyphs[cursor].scalar).syllabic)) break;
        }
    }
}

fn reorderResolvedIndic(glyphs: []layout.Glyph) void {
    var start: usize = 0;
    while (start < glyphs.len) {
        if (glyphs[start].indic_syllable == 0) {
            start += 1;
            continue;
        }
        const syllable = glyphs[start].indic_syllable;
        var end = start + 1;
        while (end < glyphs.len and glyphs[end].indic_syllable == syllable) end += 1;
        reorderIndicSyllable(glyphs[start..end]);
        start = end;
    }
}

fn reorderIndicSyllable(glyphs: []layout.Glyph) void {
    var index: usize = 1;
    while (index < glyphs.len) : (index += 1) {
        const value = glyphs[index];
        const rank = indicRoleRank(value.indic_role);
        var destination = index;
        while (destination > 0 and indicRoleRank(glyphs[destination - 1].indic_role) > rank) : (destination -= 1)
            glyphs[destination] = glyphs[destination - 1];
        glyphs[destination] = value;
    }
}

fn moveGlyph(glyphs: []layout.Glyph, from: usize, to: usize) void {
    if (from == to) return;
    const value = glyphs[from];
    if (from > to) {
        var index = from;
        while (index > to) : (index -= 1) glyphs[index] = glyphs[index - 1];
        glyphs[to] = value;
    } else {
        var index = from;
        while (index < to) : (index += 1) glyphs[index] = glyphs[index + 1];
        glyphs[to] = value;
    }
}

fn indicRoleRank(role: layout.IndicRole) u8 {
    return switch (role) {
        .pre_base_mark => 0,
        .pre_base_consonant => 1,
        .pre_base => 2,
        .base => 3,
        .below_base => 4,
        .post_base => 5,
        .reph => 6,
        .above_base => 7,
        .mark => 8,
        .none => 9,
    };
}

fn roleForScalar(scalar: u21) layout.IndicRole {
    const property = unicode.indicProperties(scalar);
    if (isPrebasePosition(property.positional)) return .pre_base_mark;
    if (property.syllabic == .consonant_preceding_repha) return .reph;
    if (isBelowPosition(property.positional)) return .below_base;
    if (isRightPosition(property.positional)) return .post_base;
    if (isAbovePosition(property.positional)) return .above_base;
    if (isBaseCategory(property.syllabic)) return .none;
    return .mark;
}

fn isBaseCategory(category: unicode.IndicSyllabicCategory) bool {
    return isConsonantBase(category) or category == .consonant_placeholder or
        category == .vowel or category == .vowel_independent or category == .number or
        category == .brahmi_joining_number;
}

fn isConsonantBase(category: unicode.IndicSyllabicCategory) bool {
    return switch (category) {
        .consonant, .consonant_dead, .consonant_head_letter, .consonant_initial_postfixed, .consonant_killer, .consonant_prefixed, .consonant_with_stacker => true,
        else => false,
    };
}

fn isLinker(category: unicode.IndicSyllabicCategory) bool {
    return category == .virama or category == .invisible_stacker or category == .number_joiner;
}

fn isJoinControl(category: unicode.IndicSyllabicCategory) bool {
    return category == .joiner or category == .non_joiner;
}

fn isAttachmentCategory(category: unicode.IndicSyllabicCategory) bool {
    return switch (category) {
        .avagraha, .bindu, .cantillation_mark, .consonant_final, .consonant_medial, .consonant_subjoined, .consonant_succeeding_repha, .gemination_mark, .joiner, .modifying_letter, .non_joiner, .nukta, .pure_killer, .register_shifter, .reordering_killer, .syllable_modifier, .tone_letter, .tone_mark, .visarga, .vowel_dependent, .consonant_preceding_repha => true,
        else => false,
    };
}

fn isPrebasePosition(position: unicode.IndicPositionalCategory) bool {
    return switch (position) {
        .left, .bottom_and_left, .left_and_right, .top_and_bottom_and_left, .top_and_left, .top_and_left_and_right, .visual_order_left => true,
        else => false,
    };
}

fn isBelowPosition(position: unicode.IndicPositionalCategory) bool {
    return switch (position) {
        .bottom, .bottom_and_right, .top_and_bottom, .top_and_bottom_and_right => true,
        else => false,
    };
}

fn isRightPosition(position: unicode.IndicPositionalCategory) bool {
    return position == .right or position == .top_and_right;
}

fn isAbovePosition(position: unicode.IndicPositionalCategory) bool {
    return position == .top or position == .overstruck;
}

fn applyLegacyKerning(font: opentype.Font, glyphs: []layout.Glyph) void {
    if (glyphs.len < 2) return;
    var index: usize = 1;
    while (index < glyphs.len) : (index += 1) glyphs[index - 1].advance_x += font.kerning(glyphs[index - 1].id, glyphs[index].id);
}
