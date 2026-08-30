const std = @import("std");
const Error = @import("../core/error.zig").Error;
const data = @import("unicode_data.zig");

pub const Class = data.BidiClass;

pub const Result = struct {
    levels: []u8,
    visual_to_logical: []usize,
    paragraph_level: u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.levels);
        allocator.free(self.visual_to_logical);
        self.* = undefined;
    }
};

const Override = enum { neutral, left, right };
const StackEntry = struct { level: u8, override: Override, isolate: bool };
const none = std.math.maxInt(usize);

const Run = struct {
    start: usize,
    end: usize,
    level: u8,
    next: usize = none,
    targeted: bool = false,
};

pub fn class(scalar: u21) Class {
    return data.properties(scalar).bidi;
}

pub fn resolve(allocator: std.mem.Allocator, scalars: []const u21, requested_rtl: ?bool) Error!Result {
    const paragraph_level: u8 = if (requested_rtl) |rtl| @intFromBool(rtl) else paragraphLevel(scalars);
    const levels = try allocator.alloc(u8, scalars.len);
    errdefer allocator.free(levels);
    const types = try allocator.alloc(Class, scalars.len);
    defer allocator.free(types);
    const original = try allocator.alloc(Class, scalars.len);
    defer allocator.free(original);
    const isolate_matches = try allocator.alloc(usize, scalars.len);
    defer allocator.free(isolate_matches);
    @memset(isolate_matches, none);
    for (scalars, 0..) |scalar, index| {
        const value = class(scalar);
        types[index] = value;
        original[index] = value;
        levels[index] = paragraph_level;
    }
    matchIsolates(original, isolate_matches);
    explicitLevels(scalars, original, types, levels, isolate_matches, paragraph_level);

    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(allocator);
    const run_for_index = try allocator.alloc(usize, scalars.len);
    defer allocator.free(run_for_index);
    try makeRuns(allocator, levels, types, isolate_matches, &runs, run_for_index);
    var sequence: std.ArrayList(usize) = .empty;
    defer sequence.deinit(allocator);
    for (runs.items, 0..) |run, run_index| {
        if (run.targeted) continue;
        sequence.clearRetainingCapacity();
        var current_run = run_index;
        var guard: usize = 0;
        while (current_run != none and guard <= runs.items.len) : (guard += 1) {
            const current = runs.items[current_run];
            var index = current.start;
            while (index < current.end) : (index += 1) if (types[index] != .bn) try sequence.append(allocator, index);
            current_run = current.next;
        }
        if (guard > runs.items.len) return error.InvalidLayout;
        if (sequence.items.len == 0) continue;
        const sos = directionForLevel(@max(paragraph_level, levels[sequence.items[0]]));
        const eos = directionForLevel(@max(paragraph_level, levels[sequence.items[sequence.items.len - 1]]));
        resolveWeak(types, sequence.items, sos, eos);
        resolveBrackets(scalars, types, levels, sequence.items, sos);
        resolveNeutrals(types, levels, sequence.items, sos, eos);
        resolveImplicit(types, levels, sequence.items);
    }
    resolveWhitespace(original, levels, paragraph_level);

    const order = try allocator.alloc(usize, scalars.len);
    errdefer allocator.free(order);
    for (order, 0..) |*value, index| value.* = index;
    reorder(order, levels);
    return .{ .levels = levels, .visual_to_logical = order, .paragraph_level = paragraph_level };
}

fn paragraphLevel(scalars: []const u21) u8 {
    var isolate_depth: usize = 0;
    for (scalars) |scalar| switch (class(scalar)) {
        .lri, .rli, .fsi => isolate_depth += 1,
        .pdi => isolate_depth -|= 1,
        .l => if (isolate_depth == 0) return 0,
        .r, .al => if (isolate_depth == 0) return 1,
        else => {},
    };
    return 0;
}

fn matchIsolates(types: []const Class, matches: []usize) void {
    var stack: [126]usize = undefined;
    var depth: usize = 0;
    for (types, 0..) |value, index| switch (value) {
        .lri, .rli, .fsi => if (depth < stack.len) {
            stack[depth] = index;
            depth += 1;
        },
        .pdi => if (depth != 0) {
            depth -= 1;
            matches[stack[depth]] = index;
            matches[index] = stack[depth];
        },
        else => {},
    };
}

fn explicitLevels(
    scalars: []const u21,
    original: []const Class,
    types: []Class,
    levels: []u8,
    matches: []const usize,
    paragraph_level: u8,
) void {
    var stack: [126]StackEntry = undefined;
    stack[0] = .{ .level = paragraph_level, .override = .neutral, .isolate = false };
    var depth: usize = 1;
    var overflow_isolates: usize = 0;
    var overflow_embeddings: usize = 0;
    var valid_isolates: usize = 0;

    for (original, 0..) |value, index| {
        var current = stack[depth - 1];
        levels[index] = current.level;
        switch (value) {
            .rle, .lre, .rlo, .lro => {
                types[index] = .bn;
                if (overflow_isolates != 0) continue;
                const next = if (value == .rle or value == .rlo) nextOdd(current.level) else nextEven(current.level);
                if (next != null and overflow_embeddings == 0 and depth < stack.len) {
                    stack[depth] = .{
                        .level = next.?,
                        .override = if (value == .rlo) .right else if (value == .lro) .left else .neutral,
                        .isolate = false,
                    };
                    depth += 1;
                } else overflow_embeddings += 1;
            },
            .pdf => {
                types[index] = .bn;
                if (overflow_isolates != 0) continue;
                if (overflow_embeddings != 0) {
                    overflow_embeddings -= 1;
                } else if (depth > 1 and !stack[depth - 1].isolate) {
                    depth -= 1;
                }
            },
            .lri, .rli, .fsi => {
                if (current.override == .left) types[index] = .l else if (current.override == .right) types[index] = .r;
                const isolate_class: Class = if (value == .fsi) firstStrongInIsolate(scalars, index, matches[index]) else value;
                const next = if (isolate_class == .rli) nextOdd(current.level) else nextEven(current.level);
                if (next != null and overflow_isolates == 0 and overflow_embeddings == 0 and depth < stack.len) {
                    stack[depth] = .{ .level = next.?, .override = .neutral, .isolate = true };
                    depth += 1;
                    valid_isolates += 1;
                } else overflow_isolates += 1;
            },
            .pdi => {
                if (overflow_isolates != 0) {
                    overflow_isolates -= 1;
                    continue;
                }
                if (valid_isolates == 0) continue;
                overflow_embeddings = 0;
                while (depth > 1 and !stack[depth - 1].isolate) depth -= 1;
                if (depth > 1) depth -= 1;
                valid_isolates -= 1;
                current = stack[depth - 1];
                levels[index] = current.level;
                if (current.override == .left) types[index] = .l else if (current.override == .right) types[index] = .r;
            },
            .b => {
                depth = 1;
                overflow_isolates = 0;
                overflow_embeddings = 0;
                valid_isolates = 0;
            },
            else => if (current.override == .left) {
                types[index] = .l;
            } else if (current.override == .right) {
                types[index] = .r;
            },
        }
    }
}

fn firstStrongInIsolate(scalars: []const u21, start: usize, matching_pdi: usize) Class {
    const limit = if (matching_pdi == none) scalars.len else matching_pdi;
    var depth: usize = 0;
    var index = start + 1;
    while (index < limit) : (index += 1) switch (class(scalars[index])) {
        .lri, .rli, .fsi => depth += 1,
        .pdi => depth -|= 1,
        .l => if (depth == 0) return .lri,
        .r, .al => if (depth == 0) return .rli,
        else => {},
    };
    return .lri;
}

fn nextOdd(level: u8) ?u8 {
    const result = (level + 1) | 1;
    return if (result <= 125) result else null;
}

fn nextEven(level: u8) ?u8 {
    const result = (level + 2) & ~@as(u8, 1);
    return if (result <= 125) result else null;
}

fn makeRuns(
    allocator: std.mem.Allocator,
    levels: []const u8,
    types: []const Class,
    matches: []const usize,
    output: *std.ArrayList(Run),
    run_for_index: []usize,
) Error!void {
    if (levels.len == 0) return;
    var start: usize = 0;
    while (start < levels.len) {
        var end = start + 1;
        while (end < levels.len and levels[end] == levels[start]) end += 1;
        const run_index = output.items.len;
        try output.append(allocator, .{ .start = start, .end = end, .level = levels[start] });
        @memset(run_for_index[start..end], run_index);
        start = end;
    }
    for (output.items, 0..) |*run, run_index| {
        var index = run.end;
        while (index > run.start) {
            index -= 1;
            if (types[index] == .bn) continue;
            if (isIsolateInitiator(types[index]) and matches[index] != none) {
                const target = run_for_index[matches[index]];
                if (target != run_index) {
                    run.next = target;
                    output.items[target].targeted = true;
                }
            }
            break;
        }
    }
}

fn resolveWeak(types: []Class, sequence: []const usize, sos: Class, eos: Class) void {
    var previous = sos;
    for (sequence) |logical| {
        if (types[logical] == .nsm) types[logical] = previous;
        previous = if (isIsolateInitiator(types[logical]) or types[logical] == .pdi) .on else types[logical];
    }
    var preceding_strong = sos;
    for (sequence) |logical| {
        if (types[logical] == .en and preceding_strong == .al) types[logical] = .an;
        if (types[logical] == .l or types[logical] == .r or types[logical] == .al)
            preceding_strong = types[logical];
    }
    for (sequence) |logical| {
        if (types[logical] == .al) types[logical] = .r;
    }

    var position: usize = 1;
    while (position + 1 < sequence.len) : (position += 1) {
        const logical = sequence[position];
        const before = types[sequence[position - 1]];
        const after = types[sequence[position + 1]];
        if (types[logical] == .es and before == .en and after == .en) types[logical] = .en;
        if (types[logical] == .cs and before == after and (before == .en or before == .an)) types[logical] = before;
    }
    position = 0;
    while (position < sequence.len) {
        if (types[sequence[position]] != .et) {
            position += 1;
            continue;
        }
        const start = position;
        while (position < sequence.len and types[sequence[position]] == .et) position += 1;
        const before = if (start == 0) sos else types[sequence[start - 1]];
        const after = if (position == sequence.len) eos else types[sequence[position]];
        if (before == .en or after == .en) {
            for (sequence[start..position]) |logical| types[logical] = .en;
        }
    }
    for (sequence) |logical| {
        if (types[logical] == .es or types[logical] == .et or types[logical] == .cs) types[logical] = .on;
    }
    preceding_strong = sos;
    for (sequence) |logical| {
        if (types[logical] == .en and preceding_strong == .l) types[logical] = .l;
        if (types[logical] == .l or types[logical] == .r) preceding_strong = types[logical];
    }
}

const OpenBracket = struct { sequence_position: usize, scalar: u21, pair: u21 };

fn resolveBrackets(scalars: []const u21, types: []Class, levels: []const u8, sequence: []const usize, sos: Class) void {
    var stack: [63]OpenBracket = undefined;
    var depth: usize = 0;
    for (sequence, 0..) |logical, position| {
        const bracket = data.bracket(scalars[logical]) orelse continue;
        if (bracket.opening) {
            if (depth < stack.len) {
                stack[depth] = .{ .sequence_position = position, .scalar = scalars[logical], .pair = bracket.pair };
                depth += 1;
            }
            continue;
        }
        var match: ?usize = null;
        var scan = depth;
        while (scan > 0) {
            scan -= 1;
            if (stack[scan].scalar == bracket.pair or stack[scan].pair == scalars[logical]) {
                match = scan;
                break;
            }
        }
        const match_index = match orelse continue;
        const open = stack[match_index];
        depth = match_index;
        const embedding = directionForLevel(levels[sequence[open.sequence_position]]);
        const opposite: Class = if (embedding == .l) .r else .l;
        var found_embedding = false;
        var found_opposite = false;
        for (sequence[open.sequence_position + 1 .. position]) |inside| {
            const strong = strongForNeutral(types[inside]);
            if (strong == embedding) found_embedding = true;
            if (strong == opposite) found_opposite = true;
        }
        var resolved: ?Class = null;
        if (found_embedding) {
            resolved = embedding;
        } else if (found_opposite) {
            var preceding = sos;
            var before = open.sequence_position;
            while (before > 0) {
                before -= 1;
                const strong = strongForNeutral(types[sequence[before]]);
                if (strong == .l or strong == .r) {
                    preceding = strong;
                    break;
                }
            }
            resolved = if (preceding == opposite) opposite else embedding;
        }
        if (resolved) |value| {
            types[sequence[open.sequence_position]] = value;
            types[logical] = value;
        }
    }
}

fn resolveNeutrals(types: []Class, levels: []const u8, sequence: []const usize, sos: Class, eos: Class) void {
    var position: usize = 0;
    while (position < sequence.len) {
        if (!isNeutral(types[sequence[position]])) {
            position += 1;
            continue;
        }
        const start = position;
        while (position < sequence.len and isNeutral(types[sequence[position]])) position += 1;
        const before = if (start == 0) sos else strongForNeutral(types[sequence[start - 1]]);
        const after = if (position == sequence.len) eos else strongForNeutral(types[sequence[position]]);
        const resolved = if (before == after) before else directionForLevel(levels[sequence[start]]);
        for (sequence[start..position]) |logical| types[logical] = resolved;
    }
}

fn resolveImplicit(types: []const Class, levels: []u8, sequence: []const usize) void {
    for (sequence) |logical| {
        if (levels[logical] & 1 == 0) {
            if (types[logical] == .r) levels[logical] += 1 else if (types[logical] == .an or types[logical] == .en) levels[logical] += 2;
        } else if (types[logical] == .l or types[logical] == .an or types[logical] == .en) {
            levels[logical] += 1;
        }
    }
}

fn resolveWhitespace(original: []const Class, levels: []u8, paragraph_level: u8) void {
    for (original, 0..) |value, index| if (value == .b or value == .s) {
        levels[index] = paragraph_level;
        var before = index;
        while (before > 0) {
            before -= 1;
            if (!resetByL1(original[before])) break;
            levels[before] = paragraph_level;
        }
    };
    var end = original.len;
    while (end > 0) {
        if (!resetByL1(original[end - 1])) break;
        end -= 1;
        levels[end] = paragraph_level;
    }
}

fn resetByL1(value: Class) bool {
    return value == .ws or value == .bn or value == .lre or value == .rle or value == .lro or value == .rlo or value == .pdf or isIsolateInitiator(value) or value == .pdi;
}

fn reorder(order: []usize, levels: []const u8) void {
    var maximum: u8 = 0;
    var minimum_odd: u8 = 126;
    for (levels) |level| {
        maximum = @max(maximum, level);
        if (level & 1 == 1) minimum_odd = @min(minimum_odd, level);
    }
    if (minimum_odd == 126) return;
    var level = maximum;
    while (true) {
        var index: usize = 0;
        while (index < order.len) {
            while (index < order.len and levels[order[index]] < level) index += 1;
            const start = index;
            while (index < order.len and levels[order[index]] >= level) index += 1;
            if (index > start) std.mem.reverse(usize, order[start..index]);
        }
        if (level == minimum_odd) break;
        level -= 1;
    }
}

fn directionForLevel(level: u8) Class {
    return if (level & 1 == 0) .l else .r;
}

fn isIsolateInitiator(value: Class) bool {
    return value == .lri or value == .rli or value == .fsi;
}

fn isNeutral(value: Class) bool {
    return value == .b or value == .s or value == .ws or value == .on or isIsolateInitiator(value) or value == .pdi;
}

fn strongForNeutral(value: Class) Class {
    return switch (value) {
        .an, .en, .r => .r,
        .l => .l,
        else => value,
    };
}
