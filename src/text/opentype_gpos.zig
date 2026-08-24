const std = @import("std");
const Error = @import("../core/error.zig").Error;
const opentype = @import("opentype.zig");
const layout = @import("opentype_layout.zig");

const maximum_context = 256;

const Adjustment = struct {
    x_placement: i32 = 0,
    y_placement: i32 = 0,
    x_advance: i32 = 0,
    y_advance: i32 = 0,
};

const Anchor = struct { x: i32, y: i32 };

pub fn apply(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    applications: []const layout.LookupApplication,
    direction: layout.Direction,
) Error!bool {
    var used_pair_kerning = false;
    const table = try font.table("GPOS".*);
    for (applications) |application| {
        const lookup_value = try layout.lookup(table, application.index);
        var index: usize = 0;
        while (index < buffer.glyphs.items.len) : (index += 1) {
            if (try applyLookupAt(allocator, font, buffer, lookup_value, application, direction, index, 0) and
                (std.mem.eql(u8, &application.tag, "kern") or std.mem.eql(u8, &application.tag, "vkrn")))
                used_pair_kerning = true;
        }
    }
    return used_pair_kerning;
}

fn applyLookupAt(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    direction: layout.Direction,
    index: usize,
    depth: u8,
) Error!bool {
    if (depth >= 32) return error.InvalidFont;
    if (index >= buffer.glyphs.items.len) return false;
    if (layout.ignored(font, buffer.glyphs.items[index], lookup_value) or !application.applies(buffer.glyphs.items[index])) return false;
    var subtable_index: usize = 0;
    while (subtable_index < lookup_value.subtable_count) : (subtable_index += 1) {
        const subtable = try lookup_value.subtable(subtable_index);
        if (try applySubtable(allocator, font, buffer, lookup_value, application, direction, index, lookup_value.kind, subtable, depth)) return true;
    }
    return false;
}

fn applySubtable(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    direction: layout.Direction,
    index: usize,
    kind: u16,
    subtable: []const u8,
    depth: u8,
) Error!bool {
    return switch (kind) {
        1 => single(font, buffer, application, index, subtable),
        2 => pair(font, buffer, lookup_value, application, index, subtable),
        3 => cursive(font, buffer, lookup_value, application, direction, index, subtable),
        4 => markToBase(font, buffer, lookup_value, application, index, subtable),
        5 => markToLigature(font, buffer, lookup_value, application, index, subtable),
        6 => markToMark(font, buffer, lookup_value, application, index, subtable),
        7 => context(allocator, font, buffer, lookup_value, application, direction, index, subtable, false, depth + 1),
        8 => context(allocator, font, buffer, lookup_value, application, direction, index, subtable, true, depth + 1),
        9 => extension(allocator, font, buffer, lookup_value, application, direction, index, subtable, depth + 1),
        else => error.InvalidFont,
    };
}

fn single(font: opentype.Font, buffer: *layout.Buffer, application: layout.LookupApplication, index: usize, subtable: []const u8) Error!bool {
    const format = try layout.u16(subtable, 0);
    const coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    if (!application.applies(buffer.glyphs.items[index])) return false;
    const value_format = try layout.u16(subtable, 4);
    var cursor: usize = 6;
    const adjustment = switch (format) {
        1 => try readValue(font, subtable, &cursor, value_format, subtable),
        2 => blk: {
            const count = try layout.u16(subtable, cursor);
            cursor += 2;
            if (coverage >= count) return error.InvalidFont;
            cursor += @as(usize, coverage) * valueSize(value_format);
            break :blk try readValue(font, subtable, &cursor, value_format, subtable);
        },
        else => return error.InvalidFont,
    };
    applyValue(&buffer.glyphs.items[index], adjustment);
    return true;
}

fn pair(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
) Error!bool {
    const format = try layout.u16(subtable, 0);
    if (try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) == null or !application.applies(buffer.glyphs.items[index])) return false;
    const second_index = layout.nextIncluded(font, buffer, index + 1, lookup_value) orelse return false;
    if (!application.applies(buffer.glyphs.items[second_index])) return false;
    const value_format1 = try layout.u16(subtable, 4);
    const value_format2 = try layout.u16(subtable, 6);
    if (value_format1 & 0xff00 != 0 or value_format2 & 0xff00 != 0) return error.InvalidFont;
    var first_adjustment: Adjustment = .{};
    var second_adjustment: Adjustment = .{};
    switch (format) {
        1 => {
            const coverage = (try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id)).?;
            const pair_set_count = try layout.u16(subtable, 8);
            if (coverage >= pair_set_count) return error.InvalidFont;
            const set = try layout.offsetSlice(subtable, try layout.u16(subtable, 10 + @as(usize, coverage) * 2), 2);
            const pair_count = try layout.u16(set, 0);
            const record_size = 2 + valueSize(value_format1) + valueSize(value_format2);
            var low: usize = 0;
            var high: usize = pair_count;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (try layout.u16(set, 2 + middle * record_size) < buffer.glyphs.items[second_index].id) low = middle + 1 else high = middle;
            }
            if (low >= pair_count or try layout.u16(set, 2 + low * record_size) != buffer.glyphs.items[second_index].id) return false;
            var cursor = 2 + low * record_size + 2;
            // ValueRecord device/variation offsets are relative to the
            // immediate parent. For PairPos format 1 that parent is PairSet,
            // not the enclosing PairPos subtable.
            first_adjustment = try readValue(font, set, &cursor, value_format1, set);
            second_adjustment = try readValue(font, set, &cursor, value_format2, set);
        },
        2 => {
            const class1 = try layout.classValue(subtable, try layout.u16(subtable, 8), buffer.glyphs.items[index].id);
            const class2 = try layout.classValue(subtable, try layout.u16(subtable, 10), buffer.glyphs.items[second_index].id);
            const class1_count = try layout.u16(subtable, 12);
            const class2_count = try layout.u16(subtable, 14);
            if (class1 >= class1_count or class2 >= class2_count) return error.InvalidFont;
            const record_size = valueSize(value_format1) + valueSize(value_format2);
            var cursor = 16 + (@as(usize, class1) * class2_count + class2) * record_size;
            first_adjustment = try readValue(font, subtable, &cursor, value_format1, subtable);
            second_adjustment = try readValue(font, subtable, &cursor, value_format2, subtable);
        },
        else => return error.InvalidFont,
    }
    applyValue(&buffer.glyphs.items[index], first_adjustment);
    applyValue(&buffer.glyphs.items[second_index], second_adjustment);
    return true;
}

fn cursive(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    direction: layout.Direction,
    index: usize,
    subtable: []const u8,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1 or !application.applies(buffer.glyphs.items[index])) return false;
    const current_coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    const previous_index = layout.previousIncluded(font, buffer, index, lookup_value) orelse return false;
    if (!application.applies(buffer.glyphs.items[previous_index])) return false;
    const previous_coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[previous_index].id) orelse return false;
    const count = try layout.u16(subtable, 4);
    if (current_coverage >= count or previous_coverage >= count) return error.InvalidFont;
    const previous_exit_offset = try layout.u16(subtable, 6 + @as(usize, previous_coverage) * 4 + 2);
    const current_entry_offset = try layout.u16(subtable, 6 + @as(usize, current_coverage) * 4);
    if (previous_exit_offset == 0 or current_entry_offset == 0) return false;
    const exit_anchor = try anchor(font, subtable, previous_exit_offset);
    const entry_anchor = try anchor(font, subtable, current_entry_offset);
    const distance = penDistance(buffer.glyphs.items, previous_index, index);
    if (direction == .left_to_right) {
        buffer.glyphs.items[index].offset_x += buffer.glyphs.items[previous_index].offset_x + exit_anchor.x - entry_anchor.x - distance;
        buffer.glyphs.items[index].offset_y += buffer.glyphs.items[previous_index].offset_y + exit_anchor.y - entry_anchor.y;
    } else {
        buffer.glyphs.items[previous_index].offset_x += buffer.glyphs.items[index].offset_x + entry_anchor.x - exit_anchor.x + distance;
        buffer.glyphs.items[previous_index].offset_y += buffer.glyphs.items[index].offset_y + entry_anchor.y - exit_anchor.y;
    }
    return true;
}

fn markToBase(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1 or !application.applies(buffer.glyphs.items[index])) return false;
    const mark_index = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    var base_index = layout.previousIncluded(font, buffer, index, lookup_value) orelse return false;
    while (base_index > 0 and try layout.coverageIndex(subtable, try layout.u16(subtable, 4), buffer.glyphs.items[base_index].id) == null)
        base_index = layout.previousIncluded(font, buffer, base_index, lookup_value) orelse return false;
    const base_coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 4), buffer.glyphs.items[base_index].id) orelse return false;
    return attachMark(font, buffer, index, base_index, subtable, try layout.u16(subtable, 8), mark_index, try layout.u16(subtable, 10), base_coverage, try layout.u16(subtable, 6));
}

fn markToLigature(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1 or !application.applies(buffer.glyphs.items[index])) return false;
    const mark_index = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    var ligature_index = layout.previousIncluded(font, buffer, index, lookup_value) orelse return false;
    while (ligature_index > 0 and try layout.coverageIndex(subtable, try layout.u16(subtable, 4), buffer.glyphs.items[ligature_index].id) == null)
        ligature_index = layout.previousIncluded(font, buffer, ligature_index, lookup_value) orelse return false;
    const ligature_coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 4), buffer.glyphs.items[ligature_index].id) orelse return false;
    const ligature_array = try layout.offsetSlice(subtable, try layout.u16(subtable, 10), 2);
    if (ligature_coverage >= try layout.u16(ligature_array, 0)) return error.InvalidFont;
    const attach = try layout.offsetSlice(ligature_array, try layout.u16(ligature_array, 2 + @as(usize, ligature_coverage) * 2), 2);
    const component_count = try layout.u16(attach, 0);
    if (component_count == 0) return false;
    const component: u16 = @min(if (buffer.glyphs.items[index].ligature_id == buffer.glyphs.items[ligature_index].ligature_id and buffer.glyphs.items[index].ligature_component != 0) buffer.glyphs.items[index].ligature_component - 1 else component_count - 1, component_count - 1);
    return attachMark(font, buffer, index, ligature_index, subtable, try layout.u16(subtable, 8), mark_index, attach, component, try layout.u16(subtable, 6));
}

fn markToMark(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    index: usize,
    subtable: []const u8,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1 or !application.applies(buffer.glyphs.items[index])) return false;
    const mark1_index = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    const mark2_position = layout.previousIncluded(font, buffer, index, lookup_value) orelse return false;
    const mark2_index = try layout.coverageIndex(subtable, try layout.u16(subtable, 4), buffer.glyphs.items[mark2_position].id) orelse return false;
    return attachMark(font, buffer, index, mark2_position, subtable, try layout.u16(subtable, 8), mark1_index, try layout.u16(subtable, 10), mark2_index, try layout.u16(subtable, 6));
}

fn attachMark(
    font: opentype.Font,
    buffer: *layout.Buffer,
    mark_position: usize,
    base_position: usize,
    parent: []const u8,
    mark_array_offset: u16,
    mark_index: u16,
    base_source: anytype,
    base_index: u16,
    class_count: u16,
) Error!bool {
    const mark_array = try layout.offsetSlice(parent, mark_array_offset, 2);
    if (mark_index >= try layout.u16(mark_array, 0)) return error.InvalidFont;
    const mark_record = 2 + @as(usize, mark_index) * 4;
    const mark_class = try layout.u16(mark_array, mark_record);
    if (mark_class >= class_count) return error.InvalidFont;
    const mark_anchor = try anchor(font, mark_array, try layout.u16(mark_array, mark_record + 2));

    const base_array: []const u8 = if (comptime @TypeOf(base_source) == u16) try layout.offsetSlice(parent, base_source, 2) else base_source;
    const base_anchor_offset = 2 + (@as(usize, base_index) * class_count + mark_class) * 2;
    const offset = try layout.u16(base_array, base_anchor_offset);
    if (offset == 0) return false;
    const base_anchor = try anchor(font, base_array, offset);
    buffer.glyphs.items[mark_position].offset_x += buffer.glyphs.items[base_position].offset_x + base_anchor.x - mark_anchor.x - penDistance(buffer.glyphs.items, base_position, mark_position);
    buffer.glyphs.items[mark_position].offset_y += buffer.glyphs.items[base_position].offset_y + base_anchor.y - mark_anchor.y;
    buffer.glyphs.items[mark_position].advance_x = 0;
    buffer.glyphs.items[mark_position].advance_y = 0;
    return true;
}

fn extension(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    direction: layout.Direction,
    index: usize,
    subtable: []const u8,
    depth: u8,
) Error!bool {
    if (try layout.u16(subtable, 0) != 1) return error.InvalidFont;
    const kind = try layout.u16(subtable, 2);
    if (kind == 9) return error.InvalidFont;
    return applySubtable(allocator, font, buffer, lookup_value, application, direction, index, kind, try layout.offsetSlice(subtable, try layout.u32(subtable, 4), 2), depth);
}

fn context(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    direction: layout.Direction,
    index: usize,
    subtable: []const u8,
    chained: bool,
    depth: u8,
) Error!bool {
    const format = try layout.u16(subtable, 0);
    if (format != 3) return contextClassOrGlyph(allocator, font, buffer, lookup_value, application, direction, index, subtable, chained, depth);
    var matched: [maximum_context]usize = undefined;
    var cursor: usize = 2;
    if (chained) {
        const backtrack_count = try layout.u16(subtable, cursor);
        cursor += 2;
        if (backtrack_count > maximum_context) return error.InvalidFont;
        var position = index;
        var item: usize = 0;
        while (item < backtrack_count) : (item += 1) {
            position = layout.previousIncluded(font, buffer, position, lookup_value) orelse return false;
            if (try layout.coverageIndex(subtable, try layout.u16(subtable, cursor + item * 2), buffer.glyphs.items[position].id) == null) return false;
        }
        cursor += @as(usize, backtrack_count) * 2;
    }
    const input_count = try layout.u16(subtable, cursor);
    cursor += 2;
    if (input_count == 0 or input_count > maximum_context) return error.InvalidFont;
    var position = index;
    var item: usize = 0;
    while (item < input_count) : (item += 1) {
        if (item != 0) position = layout.nextIncluded(font, buffer, position + 1, lookup_value) orelse return false;
        if (try layout.coverageIndex(subtable, try layout.u16(subtable, cursor + item * 2), buffer.glyphs.items[position].id) == null) return false;
        matched[item] = position;
    }
    cursor += @as(usize, input_count) * 2;
    if (chained) {
        const lookahead_count = try layout.u16(subtable, cursor);
        cursor += 2;
        if (lookahead_count > maximum_context) return error.InvalidFont;
        position = matched[input_count - 1] + 1;
        item = 0;
        while (item < lookahead_count) : (item += 1) {
            position = layout.nextIncluded(font, buffer, position, lookup_value) orelse return false;
            if (try layout.coverageIndex(subtable, try layout.u16(subtable, cursor + item * 2), buffer.glyphs.items[position].id) == null) return false;
            position += 1;
        }
        cursor += @as(usize, lookahead_count) * 2;
    }
    const record_count = try layout.u16(subtable, cursor);
    return applyRecords(allocator, font, buffer, application, direction, matched[0..input_count], subtable, cursor + 2, record_count, depth);
}

fn contextClassOrGlyph(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    application: layout.LookupApplication,
    direction: layout.Direction,
    index: usize,
    subtable: []const u8,
    chained: bool,
    depth: u8,
) Error!bool {
    const format = try layout.u16(subtable, 0);
    if (format != 1 and format != 2) return error.InvalidFont;
    const coverage = try layout.coverageIndex(subtable, try layout.u16(subtable, 2), buffer.glyphs.items[index].id) orelse return false;
    var matched: [maximum_context]usize = undefined;
    matched[0] = index;
    if (!chained) {
        const class_def: u16 = if (format == 2) try layout.u16(subtable, 4) else 0;
        const selector = if (format == 1) coverage else try layout.classValue(subtable, class_def, buffer.glyphs.items[index].id);
        const set_count = try layout.u16(subtable, if (format == 1) 4 else 6);
        if (selector >= set_count) return false;
        const set_offset = try layout.u16(subtable, (if (format == 1) @as(usize, 6) else 8) + @as(usize, selector) * 2);
        if (set_offset == 0) return false;
        const set = try layout.offsetSlice(subtable, set_offset, 2);
        const rule_count = try layout.u16(set, 0);
        var rule_index: usize = 0;
        while (rule_index < rule_count) : (rule_index += 1) {
            const rule = try layout.offsetSlice(set, try layout.u16(set, 2 + rule_index * 2), 4);
            const glyph_count = try layout.u16(rule, 0);
            const record_count = try layout.u16(rule, 2);
            if (glyph_count == 0 or glyph_count > maximum_context) return error.InvalidFont;
            if (!try matchInput(font, buffer, lookup_value, index, rule[4..], glyph_count - 1, format == 2, subtable, class_def, &matched)) continue;
            return applyRecords(allocator, font, buffer, application, direction, matched[0..glyph_count], rule, 4 + @as(usize, glyph_count - 1) * 2, record_count, depth);
        }
        return false;
    }

    const backtrack_class: u16 = if (format == 2) try layout.u16(subtable, 4) else 0;
    const input_class: u16 = if (format == 2) try layout.u16(subtable, 6) else 0;
    const lookahead_class: u16 = if (format == 2) try layout.u16(subtable, 8) else 0;
    const selector = if (format == 1) coverage else try layout.classValue(subtable, input_class, buffer.glyphs.items[index].id);
    const set_count = try layout.u16(subtable, if (format == 1) 4 else 10);
    if (selector >= set_count) return false;
    const set_offset = try layout.u16(subtable, (if (format == 1) @as(usize, 6) else 12) + @as(usize, selector) * 2);
    if (set_offset == 0) return false;
    const set = try layout.offsetSlice(subtable, set_offset, 2);
    const rule_count = try layout.u16(set, 0);
    var rule_index: usize = 0;
    while (rule_index < rule_count) : (rule_index += 1) {
        const rule = try layout.offsetSlice(set, try layout.u16(set, 2 + rule_index * 2), 2);
        const parsed = try matchChainRule(font, buffer, lookup_value, index, rule, format == 2, subtable, backtrack_class, input_class, lookahead_class, &matched) orelse continue;
        return applyRecords(allocator, font, buffer, application, direction, matched[0..parsed.input_count], rule, parsed.record_offset, parsed.record_count, depth);
    }
    return false;
}

const ParsedContext = struct { input_count: usize, record_count: u16, record_offset: usize };

fn matchInput(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    index: usize,
    expected: []const u8,
    count: usize,
    classes: bool,
    class_base: []const u8,
    class_offset: u16,
    matched: *[maximum_context]usize,
) Error!bool {
    var position = index + 1;
    var item: usize = 0;
    while (item < count) : (item += 1) {
        position = layout.nextIncluded(font, buffer, position, lookup_value) orelse return false;
        const actual = if (classes) try layout.classValue(class_base, class_offset, buffer.glyphs.items[position].id) else buffer.glyphs.items[position].id;
        if (actual != try layout.u16(expected, item * 2)) return false;
        matched[item + 1] = position;
        position += 1;
    }
    return true;
}

fn matchChainRule(
    font: opentype.Font,
    buffer: *layout.Buffer,
    lookup_value: layout.Lookup,
    index: usize,
    rule: []const u8,
    classes: bool,
    class_base: []const u8,
    backtrack_class: u16,
    input_class: u16,
    lookahead_class: u16,
    matched: *[maximum_context]usize,
) Error!?ParsedContext {
    var cursor: usize = 0;
    const backtrack_count = try layout.u16(rule, cursor);
    cursor += 2;
    if (backtrack_count > maximum_context) return error.InvalidFont;
    var position = index;
    var item: usize = 0;
    while (item < backtrack_count) : (item += 1) {
        position = layout.previousIncluded(font, buffer, position, lookup_value) orelse return null;
        const actual = if (classes) try layout.classValue(class_base, backtrack_class, buffer.glyphs.items[position].id) else buffer.glyphs.items[position].id;
        if (actual != try layout.u16(rule, cursor + item * 2)) return null;
    }
    cursor += @as(usize, backtrack_count) * 2;
    const input_count = try layout.u16(rule, cursor);
    cursor += 2;
    if (input_count == 0 or input_count > maximum_context) return error.InvalidFont;
    matched[0] = index;
    position = index + 1;
    item = 1;
    while (item < input_count) : (item += 1) {
        position = layout.nextIncluded(font, buffer, position, lookup_value) orelse return null;
        const actual = if (classes) try layout.classValue(class_base, input_class, buffer.glyphs.items[position].id) else buffer.glyphs.items[position].id;
        if (actual != try layout.u16(rule, cursor + (item - 1) * 2)) return null;
        matched[item] = position;
        position += 1;
    }
    cursor += @as(usize, input_count - 1) * 2;
    const lookahead_count = try layout.u16(rule, cursor);
    cursor += 2;
    if (lookahead_count > maximum_context) return error.InvalidFont;
    item = 0;
    while (item < lookahead_count) : (item += 1) {
        position = layout.nextIncluded(font, buffer, position, lookup_value) orelse return null;
        const actual = if (classes) try layout.classValue(class_base, lookahead_class, buffer.glyphs.items[position].id) else buffer.glyphs.items[position].id;
        if (actual != try layout.u16(rule, cursor + item * 2)) return null;
        position += 1;
    }
    cursor += @as(usize, lookahead_count) * 2;
    const record_count = try layout.u16(rule, cursor);
    return .{ .input_count = input_count, .record_count = record_count, .record_offset = cursor + 2 };
}

fn applyRecords(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    application: layout.LookupApplication,
    direction: layout.Direction,
    matched: []const usize,
    record_base: []const u8,
    record_offset: usize,
    record_count: u16,
    depth: u8,
) Error!bool {
    if (record_offset + @as(usize, record_count) * 4 > record_base.len) return error.InvalidFont;
    for (matched) |position| {
        if (position >= buffer.glyphs.items.len or !application.applies(buffer.glyphs.items[position])) return false;
    }
    var applied = false;
    var item: usize = 0;
    while (item < record_count) : (item += 1) {
        const sequence_index = try layout.u16(record_base, record_offset + item * 4);
        const lookup_index = try layout.u16(record_base, record_offset + item * 4 + 2);
        if (sequence_index >= matched.len) return error.InvalidFont;
        const nested = try layout.lookup(try font.table("GPOS".*), lookup_index);
        applied = try applyLookupAt(allocator, font, buffer, nested, application, direction, matched[sequence_index], depth) or applied;
    }
    return applied;
}

fn readValue(font: opentype.Font, bytes: []const u8, cursor: *usize, format: u16, device_base: []const u8) Error!Adjustment {
    if (format & 0xff00 != 0) return error.InvalidFont;
    var result: Adjustment = .{};
    if (format & 0x0001 != 0) {
        result.x_placement = try layout.i16(bytes, cursor.*);
        cursor.* += 2;
    }
    if (format & 0x0002 != 0) {
        result.y_placement = try layout.i16(bytes, cursor.*);
        cursor.* += 2;
    }
    if (format & 0x0004 != 0) {
        result.x_advance = try layout.i16(bytes, cursor.*);
        cursor.* += 2;
    }
    if (format & 0x0008 != 0) {
        result.y_advance = try layout.i16(bytes, cursor.*);
        cursor.* += 2;
    }
    const x_placement_device = if (format & 0x0010 != 0) blk: {
        const value = try layout.u16(bytes, cursor.*);
        cursor.* += 2;
        break :blk value;
    } else 0;
    const y_placement_device = if (format & 0x0020 != 0) blk: {
        const value = try layout.u16(bytes, cursor.*);
        cursor.* += 2;
        break :blk value;
    } else 0;
    const x_advance_device = if (format & 0x0040 != 0) blk: {
        const value = try layout.u16(bytes, cursor.*);
        cursor.* += 2;
        break :blk value;
    } else 0;
    const y_advance_device = if (format & 0x0080 != 0) blk: {
        const value = try layout.u16(bytes, cursor.*);
        cursor.* += 2;
        break :blk value;
    } else 0;
    if (cursor.* > bytes.len) return error.InvalidFont;
    result.x_placement += try variationAdjustment(font, device_base, x_placement_device);
    result.y_placement += try variationAdjustment(font, device_base, y_placement_device);
    result.x_advance += try variationAdjustment(font, device_base, x_advance_device);
    result.y_advance += try variationAdjustment(font, device_base, y_advance_device);
    return result;
}

fn valueSize(format: u16) usize {
    return @popCount(format & 0x00ff) * 2;
}

fn applyValue(glyph: *layout.Glyph, value: Adjustment) void {
    glyph.offset_x += value.x_placement;
    glyph.offset_y += value.y_placement;
    glyph.advance_x += value.x_advance;
    glyph.advance_y += value.y_advance;
}

fn anchor(font: opentype.Font, base: []const u8, offset: usize) Error!Anchor {
    if (offset == 0) return error.InvalidFont;
    const value = try layout.offsetSlice(base, offset, 6);
    const format = try layout.u16(value, 0);
    if (format < 1 or format > 3) return error.InvalidFont;
    var result: Anchor = .{ .x = try layout.i16(value, 2), .y = try layout.i16(value, 4) };
    if (format == 3) {
        result.x += try variationAdjustment(font, value, try layout.u16(value, 6));
        result.y += try variationAdjustment(font, value, try layout.u16(value, 8));
    }
    return result;
}

fn variationAdjustment(font: opentype.Font, base: []const u8, offset: u16) Error!i32 {
    if (offset == 0) return 0;
    const device = try layout.offsetSlice(base, offset, 6);
    const format = try layout.u16(device, 4);
    if (format == 0x8000)
        return @intFromFloat(@round(try font.layoutVariationDelta(try layout.u16(device, 0), try layout.u16(device, 2))));
    if (format < 1 or format > 3) return error.InvalidFont;
    const first_ppem = try layout.u16(device, 0);
    const last_ppem = try layout.u16(device, 2);
    if (first_ppem > last_ppem) return error.InvalidFont;
    const ppem = font.pixels_per_em orelse return 0;
    if (ppem < first_ppem or ppem > last_ppem) return 0;
    const bits: u5 = switch (format) {
        1 => 2,
        2 => 4,
        3 => 8,
        else => unreachable,
    };
    const bits_usize: usize = bits;
    const values_per_word: usize = 16 / bits_usize;
    const value_index: usize = @as(usize, ppem - first_ppem);
    const word = try layout.u16(device, 6 + value_index / values_per_word * 2);
    const shift: u4 = @intCast(16 - bits_usize - (value_index % values_per_word) * bits_usize);
    const mask: u16 = (@as(u16, 1) << @as(u4, @intCast(bits))) - 1;
    const raw = (word >> shift) & mask;
    const sign = @as(u16, 1) << @as(u4, @intCast(bits - 1));
    const delta: i16 = if (raw & sign == 0)
        @intCast(raw)
    else
        @as(i16, @intCast(raw)) - @as(i16, 1) * (@as(i16, 1) << @as(u4, @intCast(bits)));
    const units = try font.unitsPerEm();
    return @intFromFloat(@round(
        @as(f64, @floatFromInt(delta)) * @as(f64, @floatFromInt(units)) /
            @as(f64, @floatFromInt(ppem)),
    ));
}

fn penDistance(glyphs: []const layout.Glyph, start: usize, end: usize) i64 {
    var distance: i64 = 0;
    var index = start;
    while (index < end) : (index += 1) distance += glyphs[index].advance_x;
    return distance;
}

test "PairPos format 1 resolves device offsets from PairSet" {
    const testing = std.testing;

    var font_bytes: [82]u8 = @splat(0);
    std.mem.writeInt(u32, font_bytes[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, font_bytes[4..6], 1, .big);
    @memcpy(font_bytes[12..16], "head");
    std.mem.writeInt(u32, font_bytes[20..24], 28, .big);
    std.mem.writeInt(u32, font_bytes[24..28], 54, .big);
    std.mem.writeInt(u16, font_bytes[46..48], 1000, .big);
    const font: opentype.Font = .{ .bytes = &font_bytes, .pixels_per_em = 16 };

    var subtable: [36]u8 = @splat(0);
    std.mem.writeInt(u16, subtable[0..2], 1, .big);
    std.mem.writeInt(u16, subtable[2..4], 12, .big);
    std.mem.writeInt(u16, subtable[4..6], 0x0044, .big);
    std.mem.writeInt(u16, subtable[8..10], 1, .big);
    std.mem.writeInt(u16, subtable[10..12], 18, .big);
    std.mem.writeInt(u16, subtable[12..14], 1, .big);
    std.mem.writeInt(u16, subtable[14..16], 1, .big);
    std.mem.writeInt(u16, subtable[16..18], 10, .big);
    std.mem.writeInt(u16, subtable[18..20], 1, .big);
    std.mem.writeInt(u16, subtable[20..22], 20, .big);
    std.mem.writeInt(u16, subtable[24..26], 10, .big);
    std.mem.writeInt(u16, subtable[28..30], 16, .big);
    std.mem.writeInt(u16, subtable[30..32], 16, .big);
    std.mem.writeInt(u16, subtable[32..34], 3, .big);
    std.mem.writeInt(u16, subtable[34..36], 0x0100, .big);

    var buffer: layout.Buffer = .{};
    defer buffer.deinit(testing.allocator);
    try buffer.glyphs.append(testing.allocator, .{ .id = 10, .cluster_utf8 = 0, .scalar = 'A' });
    try buffer.glyphs.append(testing.allocator, .{ .id = 20, .cluster_utf8 = 1, .scalar = 'V' });
    const applied = try pair(
        font,
        &buffer,
        .{
            .table = &.{},
            .kind = 2,
            .flags = 0,
            .subtables = &.{},
            .subtable_count = 1,
            .mark_filtering_set = null,
        },
        .{ .index = 0, .tag = "kern".*, .value = 1, .start_utf8 = 0, .end_utf8 = 2 },
        0,
        &subtable,
    );
    try testing.expect(applied);
    try testing.expectEqual(@as(i64, 63), buffer.glyphs.items[0].advance_x);
}
