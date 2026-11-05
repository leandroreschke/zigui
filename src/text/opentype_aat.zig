const std = @import("std");
const Error = @import("../core/error.zig").Error;
const opentype = @import("opentype.zig");
const layout = @import("opentype_layout.zig");

const deleted_glyph: u16 = 0xffff;
const class_end_of_text: u16 = 0;
const class_out_of_bounds: u16 = 1;
const class_deleted_glyph: u16 = 2;
const maximum_chains = 4096;
const maximum_features = 65_536;
const maximum_subtables = 65_536;
const maximum_components = 256;

const coverage_vertical: u32 = 0x80000000;
const coverage_backwards: u32 = 0x40000000;
const coverage_all_directions: u32 = 0x20000000;
const coverage_logical: u32 = 0x10000000;
const coverage_reserved: u32 = 0x0fffff00;

pub fn apply(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    options: layout.Options,
) Error!void {
    const table = font.optionalTable("morx".*) orelse return;
    if (table.len < 8) return error.InvalidFont;
    const version = try readU16(table, 0);
    if ((version != 2 and version != 3) or try readU16(table, 2) != 0) return error.InvalidFont;
    const chain_count = try readU32(table, 4);
    if (chain_count > maximum_chains) return error.InvalidFont;
    const glyph_count = try font.glyphCount();

    var chain_cursor: usize = 8;
    var chain_index: usize = 0;
    while (chain_index < chain_count) : (chain_index += 1) {
        const chain_header = try boundedSlice(table, chain_cursor, 16);
        const chain_length: usize = try readU32(chain_header, 4);
        if (chain_length < 16 or chain_length & 3 != 0) return error.InvalidFont;
        const chain = try exactSlice(table, chain_cursor, chain_length);
        const feature_count = try readU32(chain, 8);
        const subtable_count = try readU32(chain, 12);
        if (feature_count > maximum_features or subtable_count > maximum_subtables) return error.InvalidFont;
        const feature_bytes = std.math.mul(usize, feature_count, 12) catch return error.InvalidFont;
        const subtable_start = std.math.add(usize, 16, feature_bytes) catch return error.InvalidFont;
        if (subtable_start > chain.len) return error.InvalidFont;
        const features = chain[16..subtable_start];
        const default_flags = try readU32(chain, 0);

        var subtable_cursor = subtable_start;
        var subtable_index: usize = 0;
        while (subtable_index < subtable_count) : (subtable_index += 1) {
            const header = try boundedSlice(chain, subtable_cursor, 12);
            const subtable_length: usize = try readU32(header, 0);
            if (subtable_length < 14) return error.InvalidFont;
            const subtable = try exactSlice(chain, subtable_cursor, subtable_length);
            const coverage = try readU32(subtable, 4);
            if (coverage & coverage_reserved != 0) return error.InvalidFont;
            const subfeature_flags = try readU32(subtable, 8);
            if (subfeature_flags != 0 and horizontalCoverage(coverage) and
                try anyGlyphEnables(features, default_flags, subfeature_flags, options, buffer.glyphs.items))
            {
                const reverse = if (coverage & coverage_logical != 0)
                    coverage & coverage_backwards != 0
                else
                    (coverage & coverage_backwards != 0) != (options.direction == .right_to_left);
                if (reverse) std.mem.reverse(layout.Glyph, buffer.glyphs.items);
                defer if (reverse) std.mem.reverse(layout.Glyph, buffer.glyphs.items);
                try applySubtable(
                    allocator,
                    font,
                    buffer,
                    subtable[12..],
                    @intCast(coverage & 0xff),
                    features,
                    default_flags,
                    subfeature_flags,
                    options,
                    glyph_count,
                );
                compactDeleted(buffer);
            }
            subtable_cursor = std.math.add(usize, subtable_cursor, subtable_length) catch return error.InvalidFont;
        }
        if (subtable_cursor > chain.len) return error.InvalidFont;
        if (version == 2 and subtable_cursor != chain.len) {
            for (chain[subtable_cursor..]) |byte| if (byte != 0) return error.InvalidFont;
        } else if (version == 3) {
            try validateCoverageArray(chain[subtable_cursor..], subtable_count, glyph_count);
        }
        chain_cursor = std.math.add(usize, chain_cursor, chain_length) catch return error.InvalidFont;
    }
    if (chain_cursor > table.len) return error.InvalidFont;
}

fn applySubtable(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    body: []const u8,
    kind: u8,
    features: []const u8,
    default_flags: u32,
    subfeature_flags: u32,
    options: layout.Options,
    glyph_count: u16,
) Error!void {
    return switch (kind) {
        0 => applyRearrangement(buffer, body, features, default_flags, subfeature_flags, options, glyph_count),
        1 => applyContextual(buffer, body, features, default_flags, subfeature_flags, options, glyph_count),
        2 => applyLigature(buffer, body, features, default_flags, subfeature_flags, options, glyph_count),
        4 => applyNoncontextual(buffer, body, features, default_flags, subfeature_flags, options, glyph_count),
        5 => applyInsertion(allocator, font, buffer, body, features, default_flags, subfeature_flags, options, glyph_count),
        else => error.InvalidFont,
    };
}

const Machine = struct {
    body: []const u8,
    class_count: u32,
    class_offset: usize,
    state_offset: usize,
    entry_offset: usize,
    glyph_count: u16,

    fn init(body: []const u8, glyph_count: u16, minimum_header: usize) Error!Machine {
        if (body.len < minimum_header) return error.InvalidFont;
        const class_count = try readU32(body, 0);
        if (class_count < 4 or class_count > std.math.maxInt(u16)) return error.InvalidFont;
        const class_offset: usize = try readU32(body, 4);
        const state_offset: usize = try readU32(body, 8);
        const entry_offset: usize = try readU32(body, 12);
        _ = try boundedSlice(body, class_offset, 2);
        _ = try boundedSlice(body, state_offset, 2);
        _ = try boundedSlice(body, entry_offset, 4);
        return .{
            .body = body,
            .class_count = class_count,
            .class_offset = class_offset,
            .state_offset = state_offset,
            .entry_offset = entry_offset,
            .glyph_count = glyph_count,
        };
    }

    fn glyphClass(self: Machine, glyph: u16) Error!u16 {
        if (glyph == deleted_glyph) return class_deleted_glyph;
        const value = (try lookupU16(self.body[self.class_offset..], glyph, self.glyph_count)) orelse class_out_of_bounds;
        if (value >= self.class_count) return error.InvalidFont;
        return @intCast(value);
    }

    fn entry(self: Machine, state: u16, glyph_class: u16, entry_size: usize) Error![]const u8 {
        if (glyph_class >= self.class_count) return error.InvalidFont;
        const row = std.math.mul(usize, state, self.class_count) catch return error.InvalidFont;
        const cell = std.math.add(usize, row, glyph_class) catch return error.InvalidFont;
        const cell_bytes = std.math.mul(usize, cell, 2) catch return error.InvalidFont;
        const entry_index = try readU16(self.body, std.math.add(usize, self.state_offset, cell_bytes) catch return error.InvalidFont);
        const entry_bytes = std.math.mul(usize, entry_index, entry_size) catch return error.InvalidFont;
        return boundedSlice(self.body, std.math.add(usize, self.entry_offset, entry_bytes) catch return error.InvalidFont, entry_size);
    }
};

fn transitionBudget(glyph_length: usize) Error!usize {
    const scaled = std.math.mul(usize, glyph_length, 64) catch return error.BudgetExceeded;
    return std.math.add(usize, scaled, 4096) catch return error.BudgetExceeded;
}

fn glyphEnabled(
    features: []const u8,
    default_flags: u32,
    subfeature_flags: u32,
    options: layout.Options,
    glyph: layout.Glyph,
) Error!bool {
    return (try flagsForCluster(features, default_flags, options, glyph.cluster_utf8)) & subfeature_flags != 0;
}

fn anyGlyphEnables(
    features: []const u8,
    default_flags: u32,
    subfeature_flags: u32,
    options: layout.Options,
    glyphs: []const layout.Glyph,
) Error!bool {
    if (glyphs.len == 0) return default_flags & subfeature_flags != 0;
    for (glyphs) |glyph| if (try glyphEnabled(features, default_flags, subfeature_flags, options, glyph)) return true;
    return false;
}

fn horizontalCoverage(coverage: u32) bool {
    return coverage & coverage_all_directions != 0 or coverage & coverage_vertical == 0;
}

fn validateCoverageArray(bytes: []const u8, subtable_count: usize, glyph_count: u16) Error!void {
    const offsets_size = std.math.mul(usize, subtable_count, 4) catch return error.InvalidFont;
    if (offsets_size > bytes.len) return error.InvalidFont;
    const coverage_bytes = (@as(usize, glyph_count) + 7) / 8;
    var index: usize = 0;
    while (index < subtable_count) : (index += 1) {
        const offset = try readU32(bytes, index * 4);
        if (offset == 0 or offset == 0xffffffff) continue;
        _ = try boundedSlice(bytes, offset, coverage_bytes);
    }
}

fn compactDeleted(buffer: *layout.Buffer) void {
    var write: usize = 0;
    for (buffer.glyphs.items) |glyph| {
        if (glyph.id == deleted_glyph) continue;
        buffer.glyphs.items[write] = glyph;
        write += 1;
    }
    buffer.glyphs.items.len = write;
}

fn applyNoncontextual(
    buffer: *layout.Buffer,
    body: []const u8,
    features: []const u8,
    default_flags: u32,
    subfeature_flags: u32,
    options: layout.Options,
    glyph_count: u16,
) Error!void {
    for (buffer.glyphs.items) |*glyph| {
        if (glyph.id == deleted_glyph or !try glyphEnabled(features, default_flags, subfeature_flags, options, glyph.*)) continue;
        const replacement = (try lookupU16(body, glyph.id, glyph_count)) orelse continue;
        if (replacement == 0) continue;
        // AAT uses 0xffff to delete a glyph; apply() compacts these after the subtable.
        if (replacement != deleted_glyph and replacement >= glyph_count) return error.InvalidFont;
        glyph.id = @intCast(replacement);
    }
}

fn applyRearrangement(
    buffer: *layout.Buffer,
    body: []const u8,
    features: []const u8,
    default_flags: u32,
    subfeature_flags: u32,
    options: layout.Options,
    glyph_count: u16,
) Error!void {
    const machine = try Machine.init(body, glyph_count, 16);
    var state: u16 = 0;
    var index: usize = 0;
    var first: usize = 0;
    var last: usize = 0;
    var operations: usize = 0;
    const budget = try transitionBudget(buffer.glyphs.items.len);
    while (true) {
        if (operations == budget) return error.InvalidFont;
        operations += 1;
        if (index < buffer.glyphs.items.len and !try glyphEnabled(features, default_flags, subfeature_flags, options, buffer.glyphs.items[index])) {
            state = 0;
            index += 1;
            continue;
        }
        const glyph_class = if (index < buffer.glyphs.items.len) try machine.glyphClass(buffer.glyphs.items[index].id) else class_end_of_text;
        const entry = try machine.entry(state, glyph_class, 4);
        const next_state = try readU16(entry, 0);
        const flags = try readU16(entry, 2);
        if (flags & 0x1ff0 != 0) return error.InvalidFont;
        if (flags & 0x8000 != 0) first = index;
        if (flags & 0x2000 != 0) last = @min(index + 1, buffer.glyphs.items.len);
        if (flags & 0x000f != 0 and first < last) try rearrange(buffer.glyphs.items[first..last], @intCast(flags & 0x000f));
        state = next_state;
        if (index == buffer.glyphs.items.len) break;
        if (flags & 0x4000 == 0) index += 1;
    }
}

fn rearrange(glyphs: []layout.Glyph, verb: u4) Error!void {
    const map = [_]u8{ 0x00, 0x10, 0x01, 0x11, 0x20, 0x30, 0x02, 0x03, 0x12, 0x13, 0x21, 0x31, 0x22, 0x32, 0x23, 0x33 };
    const value = map[verb];
    const left_count: usize = @min(2, value >> 4);
    const right_count: usize = @min(2, value & 0x0f);
    if (glyphs.len < left_count + right_count or glyphs.len > maximum_components) return error.InvalidFont;
    var saved: [4]layout.Glyph = undefined;
    @memcpy(saved[0..left_count], glyphs[0..left_count]);
    @memcpy(saved[2..][0..right_count], glyphs[glyphs.len - right_count ..]);
    const middle_count = glyphs.len - left_count - right_count;
    if (right_count > left_count) {
        std.mem.copyBackwards(layout.Glyph, glyphs[right_count..][0..middle_count], glyphs[left_count..][0..middle_count]);
    } else if (right_count < left_count) {
        std.mem.copyForwards(layout.Glyph, glyphs[right_count..][0..middle_count], glyphs[left_count..][0..middle_count]);
    }
    @memcpy(glyphs[0..right_count], saved[2..][0..right_count]);
    @memcpy(glyphs[glyphs.len - left_count ..], saved[0..left_count]);
    if (value >> 4 == 3) std.mem.reverse(layout.Glyph, glyphs[glyphs.len - left_count ..]);
    if (value & 0x0f == 3) std.mem.reverse(layout.Glyph, glyphs[0..right_count]);
    var cluster: u32 = std.math.maxInt(u32);
    for (glyphs) |glyph| cluster = @min(cluster, glyph.cluster_utf8);
    for (glyphs) |*glyph| glyph.cluster_utf8 = cluster;
}

fn applyContextual(
    buffer: *layout.Buffer,
    body: []const u8,
    features: []const u8,
    default_flags: u32,
    subfeature_flags: u32,
    options: layout.Options,
    glyph_count: u16,
) Error!void {
    const machine = try Machine.init(body, glyph_count, 20);
    const substitutions_offset: usize = try readU32(body, 16);
    _ = try boundedSlice(body, substitutions_offset, 4);
    var state: u16 = 0;
    var index: usize = 0;
    var mark: usize = 0;
    var mark_set = false;
    var operations: usize = 0;
    const budget = try transitionBudget(buffer.glyphs.items.len);
    while (true) {
        if (operations == budget) return error.InvalidFont;
        operations += 1;
        if (index < buffer.glyphs.items.len and !try glyphEnabled(features, default_flags, subfeature_flags, options, buffer.glyphs.items[index])) {
            state = 0;
            index += 1;
            continue;
        }
        const glyph_class = if (index < buffer.glyphs.items.len) try machine.glyphClass(buffer.glyphs.items[index].id) else class_end_of_text;
        const entry = try machine.entry(state, glyph_class, 8);
        const next_state = try readU16(entry, 0);
        const flags = try readU16(entry, 2);
        if (flags & 0x3fff != 0) return error.InvalidFont;
        if (!(index == buffer.glyphs.items.len and !mark_set) and buffer.glyphs.items.len != 0) {
            const marked_lookup = try readU16(entry, 4);
            if (marked_lookup != 0xffff) {
                if (mark >= buffer.glyphs.items.len) return error.InvalidFont;
                try contextualSubstitute(body, substitutions_offset, marked_lookup, &buffer.glyphs.items[mark], glyph_count);
            }
            const current_lookup = try readU16(entry, 6);
            if (current_lookup != 0xffff) {
                const current = @min(index, buffer.glyphs.items.len - 1);
                try contextualSubstitute(body, substitutions_offset, current_lookup, &buffer.glyphs.items[current], glyph_count);
            }
        }
        if (flags & 0x8000 != 0 and index < buffer.glyphs.items.len) {
            mark_set = true;
            mark = index;
        }
        state = next_state;
        if (index == buffer.glyphs.items.len) break;
        if (flags & 0x4000 == 0) index += 1;
    }
}

fn contextualSubstitute(
    body: []const u8,
    substitutions_offset: usize,
    lookup_index: u16,
    glyph: *layout.Glyph,
    glyph_count: u16,
) Error!void {
    const offset_position = std.math.add(usize, substitutions_offset, @as(usize, lookup_index) * 4) catch return error.InvalidFont;
    const lookup_offset: usize = try readU32(body, offset_position);
    const lookup_start = std.math.add(usize, substitutions_offset, lookup_offset) catch return error.InvalidFont;
    const lookup_table = try boundedSlice(body, lookup_start, 2);
    const replacement = (try lookupU16(lookup_table, glyph.id, glyph_count)) orelse return;
    if (replacement == 0) return;
    if (replacement >= glyph_count) return error.InvalidFont;
    glyph.id = @intCast(replacement);
}

fn applyLigature(
    buffer: *layout.Buffer,
    body: []const u8,
    features: []const u8,
    default_flags: u32,
    subfeature_flags: u32,
    options: layout.Options,
    glyph_count: u16,
) Error!void {
    const machine = try Machine.init(body, glyph_count, 28);
    const action_offset: usize = try readU32(body, 16);
    const component_offset: usize = try readU32(body, 20);
    const ligature_offset: usize = try readU32(body, 24);
    _ = try boundedSlice(body, action_offset, 4);
    _ = try boundedSlice(body, component_offset, 2);
    _ = try boundedSlice(body, ligature_offset, 2);

    var state: u16 = 0;
    var index: usize = 0;
    var component_positions: [maximum_components]usize = undefined;
    var component_length: usize = 0;
    var operations: usize = 0;
    const budget = try transitionBudget(buffer.glyphs.items.len);
    while (true) {
        if (operations == budget) return error.InvalidFont;
        operations += 1;
        if (index < buffer.glyphs.items.len and !try glyphEnabled(features, default_flags, subfeature_flags, options, buffer.glyphs.items[index])) {
            state = 0;
            component_length = 0;
            index += 1;
            continue;
        }
        const glyph_class = if (index < buffer.glyphs.items.len) try machine.glyphClass(buffer.glyphs.items[index].id) else class_end_of_text;
        const entry = try machine.entry(state, glyph_class, 6);
        const next_state = try readU16(entry, 0);
        const flags = try readU16(entry, 2);
        if (flags & 0x1fff != 0) return error.InvalidFont;
        if (flags & 0x8000 != 0 and index < buffer.glyphs.items.len) {
            if (component_length != 0 and component_positions[component_length - 1] == index) component_length -= 1;
            if (component_length == component_positions.len) return error.InvalidFont;
            component_positions[component_length] = index;
            component_length += 1;
        }
        if (flags & 0x2000 != 0 and component_length != 0 and index < buffer.glyphs.items.len) {
            try performLigatureActions(
                buffer,
                body,
                action_offset,
                component_offset,
                ligature_offset,
                try readU16(entry, 4),
                &component_positions,
                &component_length,
                glyph_count,
            );
        }
        state = next_state;
        if (index == buffer.glyphs.items.len) break;
        if (flags & 0x4000 == 0) index += 1;
    }
}

fn performLigatureActions(
    buffer: *layout.Buffer,
    body: []const u8,
    action_offset: usize,
    component_offset: usize,
    ligature_offset: usize,
    first_action: u16,
    component_positions: *[maximum_components]usize,
    component_length: *usize,
    glyph_count: u16,
) Error!void {
    var cursor = component_length.*;
    var action_index: usize = first_action;
    var ligature_index: usize = 0;
    const original_component_count = component_length.*;
    var cluster: u32 = std.math.maxInt(u32);
    for (component_positions[0..component_length.*]) |position| {
        if (position >= buffer.glyphs.items.len) return error.InvalidFont;
        cluster = @min(cluster, buffer.glyphs.items[position].cluster_utf8);
    }
    var action_count: usize = 0;
    while (true) {
        if (action_count == maximum_components or cursor == 0) return error.InvalidFont;
        action_count += 1;
        cursor -= 1;
        const position = component_positions[cursor];
        const action_position = std.math.add(usize, action_offset, std.math.mul(usize, action_index, 4) catch return error.InvalidFont) catch return error.InvalidFont;
        const action = try readU32(body, action_position);
        const raw_offset = action & 0x3fffffff;
        const sign_extended: u32 = if (raw_offset & 0x20000000 != 0) raw_offset | 0xc0000000 else raw_offset;
        const signed_offset: i32 = @bitCast(sign_extended);
        const component_index_signed = @as(i64, buffer.glyphs.items[position].id) + signed_offset;
        if (component_index_signed < 0 or component_index_signed > std.math.maxInt(usize)) return error.InvalidFont;
        const component_position = std.math.add(usize, component_offset, std.math.mul(usize, @intCast(component_index_signed), 2) catch return error.InvalidFont) catch return error.InvalidFont;
        ligature_index = std.math.add(usize, ligature_index, try readU16(body, component_position)) catch return error.InvalidFont;
        if (action & 0xc0000000 != 0) {
            const ligature_position = std.math.add(usize, ligature_offset, std.math.mul(usize, ligature_index, 2) catch return error.InvalidFont) catch return error.InvalidFont;
            const replacement = try readU16(body, ligature_position);
            if (replacement >= glyph_count) return error.InvalidFont;
            buffer.glyphs.items[position].id = replacement;
            buffer.glyphs.items[position].cluster_utf8 = cluster;
            const ligature_id = nextLigatureId(buffer);
            buffer.glyphs.items[position].ligature_id = ligature_id;
            buffer.glyphs.items[position].ligature_component = @intCast(@min(original_component_count, std.math.maxInt(u16)));
            while (component_length.* - 1 > cursor) {
                component_length.* -= 1;
                const deleted_position = component_positions[component_length.*];
                buffer.glyphs.items[deleted_position].id = deleted_glyph;
                buffer.glyphs.items[deleted_position].ligature_id = ligature_id;
            }
        }
        action_index = std.math.add(usize, action_index, 1) catch return error.InvalidFont;
        if (action & 0x80000000 != 0) break;
    }
}

fn nextLigatureId(buffer: *layout.Buffer) u32 {
    const result = buffer.next_ligature_id;
    buffer.next_ligature_id +%= 1;
    if (buffer.next_ligature_id == 0) buffer.next_ligature_id = 1;
    return result;
}

fn applyInsertion(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    body: []const u8,
    features: []const u8,
    default_flags: u32,
    subfeature_flags: u32,
    options: layout.Options,
    glyph_count: u16,
) Error!void {
    const machine = try Machine.init(body, glyph_count, 20);
    const insertion_offset: usize = try readU32(body, 16);
    _ = try boundedSlice(body, insertion_offset, 2);
    var state: u16 = 0;
    var index: usize = 0;
    var mark: usize = 0;
    var mark_set = false;
    var operations: usize = 0;
    const initial_budget = try transitionBudget(buffer.glyphs.items.len);
    const insertion_budget = std.math.mul(usize, initial_budget, 32) catch return error.BudgetExceeded;
    while (true) {
        if (operations == insertion_budget) return error.InvalidFont;
        operations += 1;
        if (index < buffer.glyphs.items.len and !try glyphEnabled(features, default_flags, subfeature_flags, options, buffer.glyphs.items[index])) {
            state = 0;
            index += 1;
            continue;
        }
        const at_end = index == buffer.glyphs.items.len;
        const glyph_class = if (!at_end) try machine.glyphClass(buffer.glyphs.items[index].id) else class_end_of_text;
        const entry = try machine.entry(state, glyph_class, 8);
        const next_state = try readU16(entry, 0);
        const flags = try readU16(entry, 2);
        const current_insert_index = try readU16(entry, 4);
        const marked_insert_index = try readU16(entry, 6);
        const marked_count: usize = flags & 0x001f;
        const current_count: usize = (flags & 0x03e0) >> 5;
        var current_position = index;

        if (marked_insert_index != 0xffff) {
            if (!mark_set or mark >= buffer.glyphs.items.len) return error.InvalidFont;
            const before = flags & 0x0400 != 0;
            const cluster_source = if (flags & 0x1000 != 0 or at_end)
                buffer.glyphs.items[mark].cluster_utf8
            else
                buffer.glyphs.items[current_position].cluster_utf8;
            const insertion_position = mark + @intFromBool(!before);
            try insertActionGlyphs(allocator, font, buffer, body, insertion_offset, marked_insert_index, marked_count, insertion_position, cluster_source, glyph_count);
            if (insertion_position <= current_position) current_position += marked_count;
            if (before) mark += marked_count;
        } else if (marked_count != 0) return error.InvalidFont;

        if (flags & 0x8000 != 0 and !at_end) {
            mark_set = true;
            mark = current_position;
        }

        var inserted_after_current = false;
        if (current_insert_index != 0xffff) {
            if (at_end) return error.InvalidFont;
            const before = flags & 0x0800 != 0;
            const cluster_source = buffer.glyphs.items[current_position].cluster_utf8;
            const insertion_position = current_position + @intFromBool(!before);
            try insertActionGlyphs(allocator, font, buffer, body, insertion_offset, current_insert_index, current_count, insertion_position, cluster_source, glyph_count);
            if (before) current_position += current_count else inserted_after_current = current_count != 0;
            if (mark_set and insertion_position <= mark) mark += current_count;
        } else if (current_count != 0) return error.InvalidFont;

        state = next_state;
        if (at_end) break;
        if (flags & 0x4000 != 0) {
            index = if (inserted_after_current) current_position + 1 else current_position;
        } else {
            index = std.math.add(usize, current_position, 1 + @as(usize, if (inserted_after_current) current_count else 0)) catch return error.BudgetExceeded;
        }
    }
}

fn insertActionGlyphs(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    buffer: *layout.Buffer,
    body: []const u8,
    insertion_offset: usize,
    first: u16,
    count: usize,
    position: usize,
    cluster: u32,
    glyph_count: u16,
) Error!void {
    if (count == 0) return;
    if (position > buffer.glyphs.items.len) return error.InvalidFont;
    if (buffer.glyphs.items.len > layout.maximum_buffer_glyphs -| count) return error.BudgetExceeded;
    const action_start = std.math.add(usize, insertion_offset, std.math.mul(usize, first, 2) catch return error.InvalidFont) catch return error.InvalidFont;
    _ = try boundedSlice(body, action_start, std.math.mul(usize, count, 2) catch return error.InvalidFont);
    var action_index: usize = 0;
    while (action_index < count) : (action_index += 1) {
        const glyph_id = try readU16(body, action_start + action_index * 2);
        if (glyph_id >= glyph_count) return error.InvalidFont;
        var glyph: layout.Glyph = .{
            .id = glyph_id,
            .cluster_utf8 = cluster,
            .scalar = 0,
        };
        const metric = try font.horizontalMetric(allocator, glyph_id);
        glyph.advance_x = metric.advance;
        try buffer.glyphs.insert(allocator, position + action_index, glyph);
    }
}

fn lookupU16(table: []const u8, glyph: u16, glyph_count: u16) Error!?u32 {
    const format = try readU16(table, 0);
    return switch (format) {
        0 => lookupFormat0(table, glyph, glyph_count),
        2 => lookupFormat2(table, glyph),
        4 => lookupFormat4(table, glyph),
        6 => lookupFormat6(table, glyph),
        8 => lookupFormat8(table, glyph),
        10 => lookupFormat10(table, glyph),
        else => error.InvalidFont,
    };
}

fn lookupFormat0(table: []const u8, glyph: u16, glyph_count: u16) Error!?u32 {
    const required = std.math.add(usize, 2, std.math.mul(usize, glyph_count, 2) catch return error.InvalidFont) catch return error.InvalidFont;
    if (required > table.len) return error.InvalidFont;
    return try readU16(table, 2 + @as(usize, glyph) * 2);
}

const SearchHeader = struct { unit_size: usize, unit_count: usize };

fn searchHeader(table: []const u8, minimum_unit: usize) Error!SearchHeader {
    if (table.len < 12) return error.InvalidFont;
    const unit_size = try readU16(table, 2);
    const unit_count = try readU16(table, 4);
    if (unit_size < minimum_unit) return error.InvalidFont;
    const units_size = std.math.mul(usize, unit_size, unit_count) catch return error.InvalidFont;
    if (12 + units_size > table.len) return error.InvalidFont;
    return .{ .unit_size = unit_size, .unit_count = unit_count };
}

fn lookupFormat2(table: []const u8, glyph: u16) Error!?u32 {
    const header = try searchHeader(table, 6);
    var index: usize = 0;
    while (index < header.unit_count) : (index += 1) {
        const record = 12 + index * header.unit_size;
        const last = try readU16(table, record);
        const first = try readU16(table, record + 2);
        if (first > last) return error.InvalidFont;
        if (glyph >= first and glyph <= last) return try readU16(table, record + 4);
    }
    return null;
}

fn lookupFormat4(table: []const u8, glyph: u16) Error!?u32 {
    const header = try searchHeader(table, 6);
    var index: usize = 0;
    while (index < header.unit_count) : (index += 1) {
        const record = 12 + index * header.unit_size;
        const last = try readU16(table, record);
        const first = try readU16(table, record + 2);
        if (first > last) return error.InvalidFont;
        if (glyph < first or glyph > last) continue;
        const values_offset: usize = try readU16(table, record + 4);
        const delta = std.math.mul(usize, glyph - first, 2) catch return error.InvalidFont;
        return try readU16(table, std.math.add(usize, values_offset, delta) catch return error.InvalidFont);
    }
    return null;
}

fn lookupFormat6(table: []const u8, glyph: u16) Error!?u32 {
    const header = try searchHeader(table, 4);
    var index: usize = 0;
    while (index < header.unit_count) : (index += 1) {
        const record = 12 + index * header.unit_size;
        const candidate = try readU16(table, record);
        if (candidate == glyph) return try readU16(table, record + 2);
    }
    return null;
}

fn lookupFormat8(table: []const u8, glyph: u16) Error!?u32 {
    if (table.len < 6) return error.InvalidFont;
    const first = try readU16(table, 2);
    const count = try readU16(table, 4);
    if (glyph < first or glyph - first >= count) return null;
    return try readU16(table, 6 + @as(usize, glyph - first) * 2);
}

fn lookupFormat10(table: []const u8, glyph: u16) Error!?u32 {
    if (table.len < 8) return error.InvalidFont;
    const value_size = try readU16(table, 2);
    if (value_size != 1 and value_size != 2 and value_size != 4) return error.InvalidFont;
    const first = try readU16(table, 4);
    const count = try readU16(table, 6);
    if (glyph < first or glyph - first >= count) return null;
    const value_offset = std.math.add(usize, 8, std.math.mul(usize, glyph - first, value_size) catch return error.InvalidFont) catch return error.InvalidFont;
    return switch (value_size) {
        1 => (try boundedSlice(table, value_offset, 1))[0],
        2 => try readU16(table, value_offset),
        4 => try readU32(table, value_offset),
        else => unreachable,
    };
}

const FeatureMapping = struct { feature_type: u16, enable: u16, disable: u16 };

fn flagsForCluster(features: []const u8, default_flags: u32, options: layout.Options, cluster: u32) Error!u32 {
    var result = default_flags;
    var record: usize = 0;
    while (record < features.len) : (record += 12) {
        const feature_type = try readU16(features, record);
        const feature_setting = try readU16(features, record + 2);
        var requested = false;
        for (options.features) |feature| {
            if (cluster < feature.start_utf8 or cluster >= feature.end_utf8) continue;
            const mapping = featureMapping(feature.tag, feature.value) orelse continue;
            if (mapping.feature_type == feature_type and
                (if (feature.value == 0) mapping.disable else mapping.enable) == feature_setting)
            {
                requested = true;
                break;
            }
        }
        if (!requested) continue;
        result &= try readU32(features, record + 8);
        result |= try readU32(features, record + 4);
    }
    return result;
}

fn featureMapping(tag: [4]u8, value: u32) ?FeatureMapping {
    if (std.mem.eql(u8, &tag, "aalt")) return if (value <= std.math.maxInt(u16)) .{
        .feature_type = 17,
        .enable = @intCast(value),
        .disable = 0,
    } else null;
    if (tag[0] == 's' and tag[1] == 's' and tag[2] >= '0' and tag[2] <= '2' and tag[3] >= '0' and tag[3] <= '9') {
        const number = @as(u16, tag[2] - '0') * 10 + (tag[3] - '0');
        if (number >= 1 and number <= 20) return .{ .feature_type = 35, .enable = number * 2, .disable = number * 2 + 1 };
    }
    const mappings = [_]struct { tag: [4]u8, mapping: FeatureMapping }{
        .{ .tag = "afrc".*, .mapping = .{ .feature_type = 11, .enable = 1, .disable = 0 } },
        .{ .tag = "c2pc".*, .mapping = .{ .feature_type = 38, .enable = 2, .disable = 0 } },
        .{ .tag = "c2sc".*, .mapping = .{ .feature_type = 38, .enable = 1, .disable = 0 } },
        .{ .tag = "calt".*, .mapping = .{ .feature_type = 36, .enable = 0, .disable = 1 } },
        .{ .tag = "case".*, .mapping = .{ .feature_type = 33, .enable = 0, .disable = 1 } },
        .{ .tag = "clig".*, .mapping = .{ .feature_type = 1, .enable = 18, .disable = 19 } },
        .{ .tag = "cswh".*, .mapping = .{ .feature_type = 36, .enable = 4, .disable = 5 } },
        .{ .tag = "dlig".*, .mapping = .{ .feature_type = 1, .enable = 4, .disable = 5 } },
        .{ .tag = "expt".*, .mapping = .{ .feature_type = 20, .enable = 10, .disable = 16 } },
        .{ .tag = "frac".*, .mapping = .{ .feature_type = 11, .enable = 2, .disable = 0 } },
        .{ .tag = "fwid".*, .mapping = .{ .feature_type = 22, .enable = 1, .disable = 7 } },
        .{ .tag = "halt".*, .mapping = .{ .feature_type = 22, .enable = 6, .disable = 7 } },
        .{ .tag = "hkna".*, .mapping = .{ .feature_type = 34, .enable = 0, .disable = 1 } },
        .{ .tag = "hlig".*, .mapping = .{ .feature_type = 1, .enable = 20, .disable = 21 } },
        .{ .tag = "hojo".*, .mapping = .{ .feature_type = 20, .enable = 12, .disable = 16 } },
        .{ .tag = "hwid".*, .mapping = .{ .feature_type = 22, .enable = 2, .disable = 7 } },
        .{ .tag = "ital".*, .mapping = .{ .feature_type = 32, .enable = 2, .disable = 3 } },
        .{ .tag = "jp04".*, .mapping = .{ .feature_type = 20, .enable = 11, .disable = 16 } },
        .{ .tag = "jp78".*, .mapping = .{ .feature_type = 20, .enable = 2, .disable = 16 } },
        .{ .tag = "jp83".*, .mapping = .{ .feature_type = 20, .enable = 3, .disable = 16 } },
        .{ .tag = "jp90".*, .mapping = .{ .feature_type = 20, .enable = 4, .disable = 16 } },
        .{ .tag = "liga".*, .mapping = .{ .feature_type = 1, .enable = 2, .disable = 3 } },
        .{ .tag = "lnum".*, .mapping = .{ .feature_type = 21, .enable = 1, .disable = 2 } },
        .{ .tag = "nlck".*, .mapping = .{ .feature_type = 20, .enable = 13, .disable = 16 } },
        .{ .tag = "onum".*, .mapping = .{ .feature_type = 21, .enable = 0, .disable = 2 } },
        .{ .tag = "ordn".*, .mapping = .{ .feature_type = 10, .enable = 3, .disable = 0 } },
        .{ .tag = "palt".*, .mapping = .{ .feature_type = 22, .enable = 5, .disable = 7 } },
        .{ .tag = "pcap".*, .mapping = .{ .feature_type = 37, .enable = 2, .disable = 0 } },
        .{ .tag = "pkna".*, .mapping = .{ .feature_type = 22, .enable = 0, .disable = 7 } },
        .{ .tag = "pnum".*, .mapping = .{ .feature_type = 6, .enable = 1, .disable = 4 } },
        .{ .tag = "pwid".*, .mapping = .{ .feature_type = 22, .enable = 0, .disable = 7 } },
        .{ .tag = "qwid".*, .mapping = .{ .feature_type = 22, .enable = 4, .disable = 7 } },
        .{ .tag = "rlig".*, .mapping = .{ .feature_type = 1, .enable = 0, .disable = 1 } },
        .{ .tag = "ruby".*, .mapping = .{ .feature_type = 28, .enable = 2, .disable = 3 } },
        .{ .tag = "sinf".*, .mapping = .{ .feature_type = 10, .enable = 4, .disable = 0 } },
        .{ .tag = "smcp".*, .mapping = .{ .feature_type = 37, .enable = 1, .disable = 0 } },
        .{ .tag = "smpl".*, .mapping = .{ .feature_type = 20, .enable = 1, .disable = 16 } },
        .{ .tag = "subs".*, .mapping = .{ .feature_type = 10, .enable = 2, .disable = 0 } },
        .{ .tag = "sups".*, .mapping = .{ .feature_type = 10, .enable = 1, .disable = 0 } },
        .{ .tag = "swsh".*, .mapping = .{ .feature_type = 36, .enable = 2, .disable = 3 } },
        .{ .tag = "titl".*, .mapping = .{ .feature_type = 19, .enable = 4, .disable = 0 } },
        .{ .tag = "tnam".*, .mapping = .{ .feature_type = 20, .enable = 14, .disable = 16 } },
        .{ .tag = "tnum".*, .mapping = .{ .feature_type = 6, .enable = 0, .disable = 4 } },
        .{ .tag = "trad".*, .mapping = .{ .feature_type = 20, .enable = 0, .disable = 16 } },
        .{ .tag = "twid".*, .mapping = .{ .feature_type = 22, .enable = 3, .disable = 7 } },
        .{ .tag = "valt".*, .mapping = .{ .feature_type = 22, .enable = 5, .disable = 7 } },
        .{ .tag = "vert".*, .mapping = .{ .feature_type = 4, .enable = 0, .disable = 1 } },
        .{ .tag = "vhal".*, .mapping = .{ .feature_type = 22, .enable = 6, .disable = 7 } },
        .{ .tag = "vkna".*, .mapping = .{ .feature_type = 34, .enable = 2, .disable = 3 } },
        .{ .tag = "vpal".*, .mapping = .{ .feature_type = 22, .enable = 5, .disable = 7 } },
        .{ .tag = "vrt2".*, .mapping = .{ .feature_type = 4, .enable = 0, .disable = 1 } },
        .{ .tag = "zero".*, .mapping = .{ .feature_type = 14, .enable = 4, .disable = 5 } },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, &tag, &mapping.tag)) return mapping.mapping;
    return null;
}

fn exactSlice(bytes: []const u8, offset: usize, length: usize) Error![]const u8 {
    if (offset > bytes.len or length > bytes.len - offset) return error.InvalidFont;
    return bytes[offset..][0..length];
}

fn boundedSlice(bytes: []const u8, offset: usize, minimum: usize) Error![]const u8 {
    if (offset > bytes.len or minimum > bytes.len - offset) return error.InvalidFont;
    return bytes[offset..];
}

fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or 2 > bytes.len - offset) return error.InvalidFont;
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or 4 > bytes.len - offset) return error.InvalidFont;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

test "AAT lookup formats map bounded glyph ranges" {
    const testing = std.testing;

    const format0 = [_]u8{ 0, 0, 0, 5, 0, 7, 0, 9 };
    try testing.expectEqual(@as(?u32, 7), try lookupU16(&format0, 1, 3));

    var format2: [24]u8 = @splat(0);
    writeU16(&format2, 0, 2);
    writeU16(&format2, 2, 6);
    writeU16(&format2, 4, 2);
    writeU16(&format2, 12, 12);
    writeU16(&format2, 14, 10);
    writeU16(&format2, 16, 40);
    writeU16(&format2, 18, 22);
    writeU16(&format2, 20, 20);
    writeU16(&format2, 22, 50);
    try testing.expectEqual(@as(?u32, 40), try lookupU16(&format2, 11, 64));
    try testing.expectEqual(@as(?u32, 50), try lookupU16(&format2, 21, 64));

    var format4: [26]u8 = @splat(0);
    writeU16(&format4, 0, 4);
    writeU16(&format4, 2, 6);
    writeU16(&format4, 4, 1);
    writeU16(&format4, 12, 31);
    writeU16(&format4, 14, 30);
    writeU16(&format4, 16, 22);
    writeU16(&format4, 22, 70);
    writeU16(&format4, 24, 71);
    try testing.expectEqual(@as(?u32, 71), try lookupU16(&format4, 31, 64));

    const format8 = [_]u8{ 0, 8, 0, 40, 0, 2, 0, 80, 0, 81 };
    try testing.expectEqual(@as(?u32, 80), try lookupU16(&format8, 40, 64));
    try testing.expectEqual(@as(?u32, null), try lookupU16(&format8, 39, 64));

    const format10 = [_]u8{ 0, 10, 0, 1, 0, 50, 0, 3, 4, 5, 6 };
    try testing.expectEqual(@as(?u32, 6), try lookupU16(&format10, 52, 64));
}

test "AAT noncontextual deletion preserves surrounding glyphs and clusters" {
    const testing = std.testing;
    const options: layout.Options = .{ .script = "latn".*, .direction = .left_to_right };
    // Format 8: glyph 20 is substituted, 21 deleted, and 22 retained.
    const body = [_]u8{ 0, 8, 0, 20, 0, 3, 0, 30, 0xff, 0xff, 0, 22 };
    var buffer: layout.Buffer = .{};
    defer buffer.deinit(testing.allocator);
    try buffer.glyphs.appendSlice(testing.allocator, &.{
        .{ .id = 20, .cluster_utf8 = 0, .scalar = 'a' },
        .{ .id = 21, .cluster_utf8 = 1, .scalar = 0x200d },
        .{ .id = 22, .cluster_utf8 = 4, .scalar = 'b' },
    });
    try applyNoncontextual(&buffer, &body, &.{}, 1, 1, options, 64);
    compactDeleted(&buffer);
    try testing.expectEqual(@as(usize, 2), buffer.glyphs.items.len);
    try testing.expectEqual(@as(u16, 30), buffer.glyphs.items[0].id);
    try testing.expectEqual(@as(u32, 0), buffer.glyphs.items[0].cluster_utf8);
    try testing.expectEqual(@as(u16, 22), buffer.glyphs.items[1].id);
    try testing.expectEqual(@as(u32, 4), buffer.glyphs.items[1].cluster_utf8);

    buffer.glyphs.clearRetainingCapacity();
    try buffer.glyphs.append(testing.allocator, .{ .id = 21, .cluster_utf8 = 0, .scalar = 0x200d });
    try applyNoncontextual(&buffer, &body, &.{}, 1, 1, options, 64);
    compactDeleted(&buffer);
    try testing.expectEqual(@as(usize, 0), buffer.glyphs.items.len);
}

test "AAT noncontextual substitution still rejects invalid glyph indices" {
    const testing = std.testing;
    const body = [_]u8{ 0, 8, 0, 20, 0, 1, 0, 64 };
    var buffer: layout.Buffer = .{};
    defer buffer.deinit(testing.allocator);
    try buffer.glyphs.append(testing.allocator, .{ .id = 20, .cluster_utf8 = 0, .scalar = 'a' });
    try testing.expectError(error.InvalidFont, applyNoncontextual(&buffer, &body, &.{}, 1, 1, .{ .script = "latn".*, .direction = .left_to_right }, 64));
}

test "AAT ligature state machine joins three components" {
    const testing = std.testing;
    var body: [136]u8 = @splat(0);
    writeU32(&body, 0, 7);
    writeU32(&body, 4, 28);
    writeU32(&body, 8, 40);
    writeU32(&body, 12, 96);
    writeU32(&body, 16, 120);
    writeU32(&body, 20, 132);
    writeU32(&body, 24, 134);
    writeU16(&body, 28, 8);
    writeU16(&body, 30, 20);
    writeU16(&body, 32, 3);
    writeU16(&body, 34, 4);
    writeU16(&body, 36, 5);
    writeU16(&body, 38, 6);
    const rows = [_][7]u16{
        .{ 0, 0, 0, 0, 1, 0, 0 },
        .{ 0, 0, 0, 0, 1, 0, 0 },
        .{ 0, 0, 0, 0, 1, 2, 0 },
        .{ 0, 0, 0, 0, 1, 2, 3 },
    };
    for (rows, 0..) |row, row_index| for (row, 0..) |entry, class_index|
        writeU16(&body, 40 + (row_index * 7 + class_index) * 2, entry);
    writeU16(&body, 96, 0);
    writeU16(&body, 102, 2);
    writeU16(&body, 104, 0x8000);
    writeU16(&body, 108, 3);
    writeU16(&body, 110, 0x8000);
    writeU16(&body, 114, 0);
    writeU16(&body, 116, 0xa000);
    writeU32(&body, 120, 0x3fffffea);
    writeU32(&body, 124, 0x3fffffeb);
    writeU32(&body, 128, 0xbfffffec);
    writeU16(&body, 132, 0);
    writeU16(&body, 134, 30);

    var buffer: layout.Buffer = .{};
    defer buffer.deinit(testing.allocator);
    try buffer.glyphs.append(testing.allocator, .{ .id = 20, .cluster_utf8 = 0, .scalar = 'a' });
    try buffer.glyphs.append(testing.allocator, .{ .id = 21, .cluster_utf8 = 1, .scalar = 'b' });
    try buffer.glyphs.append(testing.allocator, .{ .id = 22, .cluster_utf8 = 2, .scalar = 'c' });
    try applyLigature(&buffer, &body, &.{}, 1, 1, .{ .script = "latn".*, .direction = .left_to_right }, 64);
    compactDeleted(&buffer);
    try testing.expectEqual(@as(usize, 1), buffer.glyphs.items.len);
    try testing.expectEqual(@as(u16, 30), buffer.glyphs.items[0].id);
    try testing.expectEqual(@as(u32, 0), buffer.glyphs.items[0].cluster_utf8);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .big);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
}
