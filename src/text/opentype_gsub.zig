const std = @import("std");
const Error = @import("../core/error.zig").Error;
const opentype = @import("opentype.zig");
const layout = @import("opentype_layout.zig");

const maximum_context = 256;
const maximum_expanded_context = 65_536;

pub fn apply(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    applications: []const layout.LookupApplication,
) Error!void {
    for (applications) |application| {
        const lookup_value = try layout.lookup(try font.table("GSUB".*), application.index);
        try buffer.chargeLookupWork(lookup_value.subtable_count);
        if (try lookupIsReverse(lookup_value)) {
            var reverse_index = buffer.glyphs.items.len;
            while (reverse_index > 0) {
                reverse_index -= 1;
                _ = try applyLookupAt(allocator, font, buffer, lookup_value, application, reverse_index, 0, null);
            }
            continue;
        }
        var index: usize = 0;
        while (index < buffer.glyphs.items.len) {
            var next_index = index + 1;
            const applied = try applyLookupAt(allocator, font, buffer, lookup_value, application, index, 0, &next_index);
            index = if (applied) @min(@max(index + 1, next_index), buffer.glyphs.items.len) else index + 1;
        }
    }
}

fn lookupIsReverse(lookup_value: layout.Lookup) Error!bool {
    if (lookup_value.kind == 8) return true;
    if (lookup_value.kind != 7) return false;
    var nested_kind: ?u16 = null;
    var index: usize = 0;
    while (index < lookup_value.subtable_count) : (index += 1) {
        const subtable = try lookup_value.subtable(index);
        if (try layout.u16(subtable, 0) != 1) return error.InvalidFont;
        const kind = try layout.u16(subtable, 2);
        if (kind == 7) return error.InvalidFont;
        if (nested_kind) |selected| {
            if (selected != kind) return error.InvalidFont;
        } else nested_kind = kind;
    }
    return nested_kind != null and nested_kind.? == 8;
}

fn applyLookupAt(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    depth: u8,
    next_index: ?*usize,
) Error!bool {
    try buffer.chargeLookupWork(1);
    if (depth >= 32) return error.InvalidFont;
    if (index >= buffer.glyphs.items.len) return false;
    if (layout.ignored(font, buffer.glyphs.items[index], lookup_value) or !application.applies(buffer.glyphs.items[index])) return false;
    var subtable_index: usize = 0;
    while (subtable_index < lookup_value.subtable_count) : (subtable_index += 1) {
        try buffer.chargeLookupWork(1);
        const subtable = try lookup_value.subtable(subtable_index);
        if (try applySubtable(allocator, font, buffer, lookup_value, application, index, lookup_value.kind, subtable, depth, next_index)) return true;
    }
    return false;
}

fn applySubtable(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    kind: u16,
    subtable: []const u8,
    depth: u8,
    next_index: ?*usize,
) Error!bool {
    return switch (kind) {
        1 => single(buffer, application, index, subtable),
        2 => multiple(allocator, buffer, application, index, subtable, next_index),
        3 => alternate(buffer, application, index, subtable),
        4 => ligature(font, buffer, lookup_value, application, index, subtable, next_index),
        5 => context(allocator, font, buffer, lookup_value, application, index, subtable, false, depth + 1, next_index),
        6 => context(allocator, font, buffer, lookup_value, application, index, subtable, true, depth + 1, next_index),
        7 => extension(allocator, font, buffer, lookup_value, application, index, subtable, depth + 1, next_index),
        8 => reverse(font, buffer, lookup_value, application, index, subtable),
        else => error.InvalidFont,
    };
}

fn single(buffer: *layout.Buffer, application: layout.LookupApplication, index: usize, subtable: []const u8) Error!bool {
    const format = try layout.u16(subtable, 0);
    const coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    if (!application.applies(buffer.glyphs.items[index])) return false;
    buffer.glyphs.items[index].id = switch (format) {
        1 => @bitCast(@as(i16, @bitCast(buffer.glyphs.items[index].id)) +% try layout.i16(subtable, 4)),
        2 => blk: {
            const count = try layout.u16(subtable, 4);
            if (coverage >= count) return error.InvalidFont;
            break :blk try layout.u16(subtable, 6 + @as(usize, coverage) * 2);
        },
        else => return error.InvalidFont,
    };
    application.substituted(&buffer.glyphs.items[index]);
    return true;
}

fn multiple(
    allocator: std.mem.Allocator,
    buffer: *layout.Buffer,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
    next_index: ?*usize,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1 or !application.applies(buffer.glyphs.items[index])) return false;
    const coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    const count = try layout.u16(subtable, 4);
    if (coverage >= count) return error.InvalidFont;
    const sequence = try layout.offsetSlice(subtable, try layout.u16(subtable, 6 + @as(usize, coverage) * 2), 2);
    const glyph_count = try layout.u16(sequence, 0);
    if (glyph_count == 0 or 2 + @as(usize, glyph_count) * 2 > sequence.len) return error.InvalidFont;
    const replacement = try allocator.alloc(layout.Glyph, glyph_count);
    defer allocator.free(replacement);
    for (replacement, 0..) |*glyph, replacement_index| {
        glyph.* = buffer.glyphs.items[index];
        glyph.id = try layout.u16(sequence, 2 + replacement_index * 2);
        application.substituted(glyph);
    }
    try buffer.replace(allocator, index, 1, replacement);
    if (next_index) |value| value.* = index + glyph_count;
    return true;
}

fn alternate(buffer: *layout.Buffer, application: layout.LookupApplication, index: usize, subtable: []const u8) Error!bool {
    if (try layout.u16(subtable, 0) != 1 or !application.applies(buffer.glyphs.items[index])) return false;
    const coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    if (coverage >= try layout.u16(subtable, 4)) return error.InvalidFont;
    const set = try layout.offsetSlice(subtable, try layout.u16(subtable, 6 + @as(usize, coverage) * 2), 2);
    const count = try layout.u16(set, 0);
    if (count == 0) return false;
    const selected: usize = @min(@as(usize, @max(application.value, 1)) - 1, count - 1);
    buffer.glyphs.items[index].id = try layout.u16(set, 2 + selected * 2);
    application.substituted(&buffer.glyphs.items[index]);
    return true;
}

fn ligature(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
    next_index: ?*usize,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1 or !application.applies(buffer.glyphs.items[index])) return false;
    const coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    if (coverage >= try layout.u16(subtable, 4)) return error.InvalidFont;
    const set = try layout.offsetSlice(subtable, try layout.u16(subtable, 6 + @as(usize, coverage) * 2), 2);
    const ligature_count = try layout.u16(set, 0);
    var ligature_index: usize = 0;
    while (ligature_index < ligature_count) : (ligature_index += 1) {
        try buffer.chargeLookupWork(1);
        const value = try layout.offsetSlice(set, try layout.u16(set, 2 + ligature_index * 2), 4);
        const component_count = try layout.u16(value, 2);
        if (component_count == 0 or component_count > maximum_context) return error.InvalidFont;
        var positions: [maximum_context]usize = undefined;
        positions[0] = index;
        var matched: usize = 1;
        var cursor = index + 1;
        while (matched < component_count) : (matched += 1) {
            const position = (try layout.nextIncluded(font, buffer, cursor, lookup_value)) orelse break;
            if (!application.applies(buffer.glyphs.items[position])) break;
            if (buffer.glyphs.items[position].id != try layout.u16(value, 4 + (matched - 1) * 2)) break;
            positions[matched] = position;
            cursor = position + 1;
        }
        if (matched != component_count) continue;
        var cluster = buffer.glyphs.items[index].cluster_utf8;
        var combined_role = buffer.glyphs.items[index].indic_role;
        var combined_mask = buffer.glyphs.items[index].indic_mask;
        for (positions[0..component_count]) |position| {
            cluster = @min(cluster, buffer.glyphs.items[position].cluster_utf8);
            combined_role = mergeIndicRole(combined_role, buffer.glyphs.items[position].indic_role);
            combined_mask |= buffer.glyphs.items[position].indic_mask;
        }
        const ligature_id = buffer.next_ligature_id;
        buffer.next_ligature_id +%= 1;
        if (buffer.next_ligature_id == 0) buffer.next_ligature_id = 1;
        buffer.glyphs.items[index].id = try layout.u16(value, 0);
        buffer.glyphs.items[index].cluster_utf8 = cluster;
        buffer.glyphs.items[index].indic_role = combined_role;
        buffer.glyphs.items[index].indic_mask = combined_mask;
        application.substituted(&buffer.glyphs.items[index]);
        buffer.glyphs.items[index].ligature_id = ligature_id;
        buffer.glyphs.items[index].ligature_component = component_count;
        var component: u16 = 1;
        var scan = index + 1;
        while (scan < positions[component_count - 1]) : (scan += 1) {
            if (component < component_count and scan == positions[component]) {
                component += 1;
            } else if (layout.ignored(font, buffer.glyphs.items[scan], lookup_value)) {
                buffer.glyphs.items[scan].ligature_id = ligature_id;
                buffer.glyphs.items[scan].ligature_component = component;
            }
        }
        const old_end = positions[component_count - 1] + 1;
        var remove = component_count;
        while (remove > 1) {
            remove -= 1;
            _ = buffer.glyphs.orderedRemove(positions[remove]);
        }
        if (next_index) |next_cursor| next_cursor.* = old_end - (component_count - 1);
        return true;
    }
    return false;
}

fn extension(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
    depth: u8,
    next_index: ?*usize,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1) return error.InvalidFont;
    const kind = try layout.u16(subtable, 2);
    if (kind == 7) return error.InvalidFont;
    const nested = try layout.offsetSlice(subtable, try layout.u32(subtable, 4), 2);
    return applySubtable(allocator, font, buffer, lookup_value, application, index, kind, nested, depth, next_index);
}

fn reverse(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1 or !application.applies(buffer.glyphs.items[index])) return false;
    const coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    var cursor: usize = 4;
    const backtrack_count = try layout.u16(subtable, cursor);
    cursor += 2;
    if (backtrack_count > maximum_context) return error.InvalidFont;
    var position = index;
    var item: usize = 0;
    while (item < backtrack_count) : (item += 1) {
        position = (try layout.previousIncluded(font, buffer, position, lookup_value)) orelse return false;
        if (try layout.coverageIndex(subtable, try layout.u16(subtable, cursor + item * 2), buffer.glyphs.items[position].id) == null) return false;
    }
    cursor += @as(usize, backtrack_count) * 2;
    const lookahead_count = try layout.u16(subtable, cursor);
    cursor += 2;
    if (lookahead_count > maximum_context) return error.InvalidFont;
    position = index + 1;
    item = 0;
    while (item < lookahead_count) : (item += 1) {
        position = (try layout.nextIncluded(font, buffer, position, lookup_value)) orelse return false;
        if (try layout.coverageIndex(subtable, try layout.u16(subtable, cursor + item * 2), buffer.glyphs.items[position].id) == null) return false;
        position += 1;
    }
    cursor += @as(usize, lookahead_count) * 2;
    const glyph_count = try layout.u16(subtable, cursor);
    cursor += 2;
    if (coverage >= glyph_count) return error.InvalidFont;
    buffer.glyphs.items[index].id = try layout.u16(subtable, cursor + @as(usize, coverage) * 2);
    application.substituted(&buffer.glyphs.items[index]);
    return true;
}

fn mergeIndicRole(left: layout.IndicRole, right: layout.IndicRole) layout.IndicRole {
    if (left == .base or right == .base) return .base;
    if (left == .reph or right == .reph) return .reph;
    if (left == .pre_base_consonant or right == .pre_base_consonant) return .pre_base_consonant;
    if (left == .post_base or right == .post_base) return .post_base;
    if (left == .below_base or right == .below_base) return .below_base;
    if (left == .pre_base or right == .pre_base) return .pre_base;
    if (left == .pre_base_mark or right == .pre_base_mark) return .pre_base_mark;
    if (left == .above_base or right == .above_base) return .above_base;
    if (left == .mark or right == .mark) return .mark;
    return .none;
}

fn context(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
    chained: bool,
    depth: u8,
    next_index: ?*usize,
) Error!bool {
    return if (chained)
        chainContext(allocator, font, buffer, lookup_value, application, index, subtable, depth, next_index)
    else
        simpleContext(allocator, font, buffer, lookup_value, application, index, subtable, depth, next_index);
}

fn simpleContext(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
    depth: u8,
    next_index: ?*usize,
) Error!bool {
    const format = try layout.u16(subtable, 0);
    var matched: [maximum_context]usize = undefined;
    matched[0] = index;
    switch (format) {
        1 => {
            if (try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) == null) return false;
            const coverage = (try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id)).?;
            if (coverage >= try layout.u16(subtable, 4)) return error.InvalidFont;
            const set_offset = try layout.u16(subtable, 6 + @as(usize, coverage) * 2);
            if (set_offset == 0) return false;
            const set = try layout.offsetSlice(subtable, set_offset, 2);
            const count = try layout.u16(set, 0);
            var rule_index: usize = 0;
            while (rule_index < count) : (rule_index += 1) {
                try buffer.chargeLookupWork(1);
                const rule = try layout.offsetSlice(set, try layout.u16(set, 2 + rule_index * 2), 4);
                const glyph_count = try layout.u16(rule, 0);
                const record_count = try layout.u16(rule, 2);
                if (glyph_count == 0 or glyph_count > maximum_context) return error.InvalidFont;
                if (!try matchGlyphSequence(font, buffer, lookup_value, index, rule[4..], glyph_count - 1, &matched)) continue;
                return applyRecords(allocator, font, buffer, application, matched[0..glyph_count], rule, 4 + @as(usize, glyph_count - 1) * 2, record_count, depth, next_index);
            }
        },
        2 => {
            if (try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) == null) return false;
            const class_def = try layout.u16(subtable, 4);
            const first_class = try layout.classValue(subtable, class_def, buffer.glyphs.items[index].id);
            if (first_class >= try layout.u16(subtable, 6)) return false;
            const set_offset = try layout.u16(subtable, 8 + @as(usize, first_class) * 2);
            if (set_offset == 0) return false;
            const set = try layout.offsetSlice(subtable, set_offset, 2);
            const count = try layout.u16(set, 0);
            var rule_index: usize = 0;
            while (rule_index < count) : (rule_index += 1) {
                try buffer.chargeLookupWork(1);
                const rule = try layout.offsetSlice(set, try layout.u16(set, 2 + rule_index * 2), 4);
                const glyph_count = try layout.u16(rule, 0);
                const record_count = try layout.u16(rule, 2);
                if (glyph_count == 0 or glyph_count > maximum_context) return error.InvalidFont;
                if (!try matchClassSequence(font, buffer, lookup_value, index, subtable, class_def, rule[4..], glyph_count - 1, &matched)) continue;
                return applyRecords(allocator, font, buffer, application, matched[0..glyph_count], rule, 4 + @as(usize, glyph_count - 1) * 2, record_count, depth, next_index);
            }
        },
        3 => {
            const glyph_count = try layout.u16(subtable, 2);
            const record_count = try layout.u16(subtable, 4);
            if (glyph_count == 0 or glyph_count > maximum_context) return error.InvalidFont;
            if (!try matchCoverageSequence(font, buffer, lookup_value, index, subtable, subtable[6..], glyph_count, &matched)) return false;
            return applyRecords(allocator, font, buffer, application, matched[0..glyph_count], subtable, 6 + @as(usize, glyph_count) * 2, record_count, depth, next_index);
        },
        else => return error.InvalidFont,
    }
    return false;
}

fn chainContext(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
    depth: u8,
    next_index: ?*usize,
) Error!bool {
    const format = try layout.u16(subtable, 0);
    var matched: [maximum_context]usize = undefined;
    matched[0] = index;
    switch (format) {
        1 => {
            if (try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) == null) return false;
            const coverage = (try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id)).?;
            if (coverage >= try layout.u16(subtable, 4)) return error.InvalidFont;
            const set_offset = try layout.u16(subtable, 6 + @as(usize, coverage) * 2);
            if (set_offset == 0) return false;
            const set = try layout.offsetSlice(subtable, set_offset, 2);
            const count = try layout.u16(set, 0);
            var rule_index: usize = 0;
            while (rule_index < count) : (rule_index += 1) {
                try buffer.chargeLookupWork(1);
                const rule = try layout.offsetSlice(set, try layout.u16(set, 2 + rule_index * 2), 2);
                const parsed = try parseChainRule(font, buffer, lookup_value, index, rule, .glyph, subtable, 0, 0, 0, &matched);
                if (parsed) |record| return applyRecords(allocator, font, buffer, application, matched[0..record.input_count], rule, record.record_offset, record.record_count, depth, next_index);
            }
        },
        2 => {
            if (try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) == null) return false;
            const backtrack_class = try layout.u16(subtable, 4);
            const input_class = try layout.u16(subtable, 6);
            const lookahead_class = try layout.u16(subtable, 8);
            const first_class = try layout.classValue(subtable, input_class, buffer.glyphs.items[index].id);
            if (first_class >= try layout.u16(subtable, 10)) return false;
            const set_offset = try layout.u16(subtable, 12 + @as(usize, first_class) * 2);
            if (set_offset == 0) return false;
            const set = try layout.offsetSlice(subtable, set_offset, 2);
            const count = try layout.u16(set, 0);
            var rule_index: usize = 0;
            while (rule_index < count) : (rule_index += 1) {
                try buffer.chargeLookupWork(1);
                const rule = try layout.offsetSlice(set, try layout.u16(set, 2 + rule_index * 2), 2);
                const parsed = try parseChainRule(font, buffer, lookup_value, index, rule, .class, subtable, backtrack_class, input_class, lookahead_class, &matched);
                if (parsed) |record| return applyRecords(allocator, font, buffer, application, matched[0..record.input_count], rule, record.record_offset, record.record_count, depth, next_index);
            }
        },
        3 => {
            const parsed = try parseChainCoverage(font, buffer, lookup_value, index, subtable, &matched) orelse return false;
            return applyRecords(allocator, font, buffer, application, matched[0..parsed.input_count], subtable, parsed.record_offset, parsed.record_count, depth, next_index);
        },
        else => return error.InvalidFont,
    }
    return false;
}

const MatchKind = enum { glyph, class };
const ParsedRecord = struct { input_count: usize, record_count: u16, record_offset: usize };

fn parseChainRule(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    index: usize,
    rule: []const u8,
    kind: MatchKind,
    class_base: []const u8,
    backtrack_class: u16,
    input_class: u16,
    lookahead_class: u16,
    matched: *[maximum_context]usize,
) Error!?ParsedRecord {
    var cursor: usize = 0;
    const backtrack_count = try layout.u16(rule, cursor);
    cursor += 2;
    if (backtrack_count > maximum_context) return error.InvalidFont;
    var position = index;
    var item: usize = 0;
    while (item < backtrack_count) : (item += 1) {
        position = (try layout.previousIncluded(font, buffer, position, lookup_value)) orelse return null;
        const expected = try layout.u16(rule, cursor + item * 2);
        const actual = if (kind == .glyph) buffer.glyphs.items[position].id else try layout.classValue(class_base, backtrack_class, buffer.glyphs.items[position].id);
        if (actual != expected) return null;
    }
    cursor += @as(usize, backtrack_count) * 2;
    const input_count = try layout.u16(rule, cursor);
    cursor += 2;
    if (input_count == 0 or input_count > maximum_context) return error.InvalidFont;
    matched[0] = index;
    position = index + 1;
    item = 1;
    while (item < input_count) : (item += 1) {
        position = (try layout.nextIncluded(font, buffer, position, lookup_value)) orelse return null;
        const expected = try layout.u16(rule, cursor + (item - 1) * 2);
        const actual = if (kind == .glyph) buffer.glyphs.items[position].id else try layout.classValue(class_base, input_class, buffer.glyphs.items[position].id);
        if (actual != expected) return null;
        matched[item] = position;
        position += 1;
    }
    cursor += @as(usize, input_count - 1) * 2;
    const lookahead_count = try layout.u16(rule, cursor);
    cursor += 2;
    item = 0;
    while (item < lookahead_count) : (item += 1) {
        position = (try layout.nextIncluded(font, buffer, position, lookup_value)) orelse return null;
        const expected = try layout.u16(rule, cursor + item * 2);
        const actual = if (kind == .glyph) buffer.glyphs.items[position].id else try layout.classValue(class_base, lookahead_class, buffer.glyphs.items[position].id);
        if (actual != expected) return null;
        position += 1;
    }
    cursor += @as(usize, lookahead_count) * 2;
    const record_count = try layout.u16(rule, cursor);
    return .{ .input_count = input_count, .record_count = record_count, .record_offset = cursor + 2 };
}

fn parseChainCoverage(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    index: usize,
    subtable: []const u8,
    matched: *[maximum_context]usize,
) Error!?ParsedRecord {
    var cursor: usize = 2;
    const backtrack_count = try layout.u16(subtable, cursor);
    cursor += 2;
    if (backtrack_count > maximum_context) return error.InvalidFont;
    var position = index;
    var item: usize = 0;
    while (item < backtrack_count) : (item += 1) {
        position = (try layout.previousIncluded(font, buffer, position, lookup_value)) orelse return null;
        if (try layout.coverageIndex(subtable, try layout.u16(subtable, cursor + item * 2), buffer.glyphs.items[position].id) == null) return null;
    }
    cursor += @as(usize, backtrack_count) * 2;
    const input_count = try layout.u16(subtable, cursor);
    cursor += 2;
    if (input_count == 0 or input_count > maximum_context) return error.InvalidFont;
    position = index;
    item = 0;
    while (item < input_count) : (item += 1) {
        position = if (item == 0) index else (try layout.nextIncluded(font, buffer, position + 1, lookup_value)) orelse return null;
        if (try layout.coverageIndex(subtable, try layout.u16(subtable, cursor + item * 2), buffer.glyphs.items[position].id) == null) return null;
        matched[item] = position;
    }
    cursor += @as(usize, input_count) * 2;
    const lookahead_count = try layout.u16(subtable, cursor);
    cursor += 2;
    position = matched[input_count - 1] + 1;
    item = 0;
    while (item < lookahead_count) : (item += 1) {
        position = (try layout.nextIncluded(font, buffer, position, lookup_value)) orelse return null;
        if (try layout.coverageIndex(subtable, try layout.u16(subtable, cursor + item * 2), buffer.glyphs.items[position].id) == null) return null;
        position += 1;
    }
    cursor += @as(usize, lookahead_count) * 2;
    const record_count = try layout.u16(subtable, cursor);
    return .{ .input_count = input_count, .record_count = record_count, .record_offset = cursor + 2 };
}

fn matchGlyphSequence(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    index: usize,
    expected: []const u8,
    count: usize,
    matched: *[maximum_context]usize,
) Error!bool {
    var position = index + 1;
    var item: usize = 0;
    while (item < count) : (item += 1) {
        position = (try layout.nextIncluded(font, buffer, position, lookup_value)) orelse return false;
        if (buffer.glyphs.items[position].id != try layout.u16(expected, item * 2)) return false;
        matched[item + 1] = position;
        position += 1;
    }
    return true;
}

fn matchClassSequence(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    index: usize,
    class_base: []const u8,
    class_offset: u16,
    expected: []const u8,
    count: usize,
    matched: *[maximum_context]usize,
) Error!bool {
    var position = index + 1;
    var item: usize = 0;
    while (item < count) : (item += 1) {
        position = (try layout.nextIncluded(font, buffer, position, lookup_value)) orelse return false;
        if (try layout.classValue(class_base, class_offset, buffer.glyphs.items[position].id) != try layout.u16(expected, item * 2)) return false;
        matched[item + 1] = position;
        position += 1;
    }
    return true;
}

fn matchCoverageSequence(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    index: usize,
    coverage_base: []const u8,
    offsets: []const u8,
    count: usize,
    matched: *[maximum_context]usize,
) Error!bool {
    var position = index;
    var item: usize = 0;
    while (item < count) : (item += 1) {
        if (item != 0) position = (try layout.nextIncluded(font, buffer, position + 1, lookup_value)) orelse return false;
        if (try layout.coverageIndex(coverage_base, try layout.u16(offsets, item * 2), buffer.glyphs.items[position].id) == null) return false;
        matched[item] = position;
    }
    return true;
}

fn applyRecords(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    application: layout.LookupApplication,
    matched: []const usize,
    record_base: []const u8,
    record_offset: usize,
    record_count: u16,
    depth: u8,
    next_index: ?*usize,
) Error!bool {
    if (record_offset + @as(usize, record_count) * 4 > record_base.len) return error.InvalidFont;
    for (matched) |position| {
        if (position >= buffer.glyphs.items.len or !application.applies(buffer.glyphs.items[position])) return false;
    }
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(allocator);
    try positions.appendSlice(allocator, matched);
    var applied = false;
    var record_index: usize = 0;
    while (record_index < record_count) : (record_index += 1) {
        const sequence_index = try layout.u16(record_base, record_offset + record_index * 4);
        const lookup_index = try layout.u16(record_base, record_offset + record_index * 4 + 2);
        if (sequence_index >= positions.items.len) return error.InvalidFont;
        const position = positions.items[sequence_index];
        if (position >= buffer.glyphs.items.len) continue;
        const nested = try layout.lookup(try font.table("GSUB".*), lookup_index);
        const previous_length = buffer.glyphs.items.len;
        const nested_applied = try applyLookupAt(allocator, font, buffer, nested, application, position, depth, null);
        applied = nested_applied or applied;
        if (!nested_applied or buffer.glyphs.items.len == previous_length) continue;
        if (buffer.glyphs.items.len > previous_length) {
            const added = buffer.glyphs.items.len - previous_length;
            if (positions.items.len > maximum_expanded_context -| added) return error.BudgetExceeded;
            for (positions.items[sequence_index + 1 ..]) |*candidate| if (candidate.* > position) {
                candidate.* = std.math.add(usize, candidate.*, added) catch return error.BudgetExceeded;
            };
            var inserted: usize = 0;
            while (inserted < added) : (inserted += 1) {
                try positions.insert(allocator, sequence_index + 1 + inserted, position + 1 + inserted);
            }
        } else {
            const removed = previous_length - buffer.glyphs.items.len;
            const removable = @min(removed, positions.items.len - sequence_index - 1);
            var removed_index: usize = 0;
            while (removed_index < removable) : (removed_index += 1) _ = positions.orderedRemove(sequence_index + 1);
            for (positions.items[sequence_index + 1 ..]) |*candidate| if (candidate.* > position) {
                candidate.* -|= removed;
            };
        }
    }
    if (applied) if (next_index) |value| {
        value.* = if (positions.items.len == 0)
            @min(buffer.glyphs.items.len, matched[0] + 1)
        else
            @min(buffer.glyphs.items.len, positions.items[positions.items.len - 1] + 1);
    };
    return applied;
}
