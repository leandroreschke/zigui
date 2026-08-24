const std = @import("std");
const Error = @import("../core/error.zig").Error;
const data = @import("unicode_data.zig");

pub const Form = enum { nfd, nfc, nfkd, nfkc };

const hangul_s_base = 0xac00;
const hangul_l_base = 0x1100;
const hangul_v_base = 0x1161;
const hangul_t_base = 0x11a7;
const hangul_l_count = 19;
const hangul_v_count = 21;
const hangul_t_count = 28;
const hangul_n_count = hangul_v_count * hangul_t_count;
const hangul_s_count = hangul_l_count * hangul_n_count;

pub fn normalize(allocator: std.mem.Allocator, input: []const u8, form: Form) Error![]u8 {
    var scalars: std.ArrayList(u21) = .empty;
    defer scalars.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        const length = std.unicode.utf8ByteSequenceLength(input[index]) catch return error.InvalidUtf8;
        if (index + length > input.len) return error.InvalidUtf8;
        const scalar = std.unicode.utf8Decode(input[index..][0..length]) catch return error.InvalidUtf8;
        try decomposeRecursive(allocator, &scalars, scalar, form == .nfkd or form == .nfkc, 0);
        index += length;
    }
    canonicalOrder(scalars.items);
    if (form == .nfc or form == .nfkc) compose(scalars.items, &scalars.items.len);

    var byte_count: usize = 0;
    for (scalars.items) |scalar| byte_count = std.math.add(usize, byte_count, std.unicode.utf8CodepointSequenceLength(scalar) catch return error.InvalidUtf8) catch return error.BudgetExceeded;
    const output = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(output);
    var cursor: usize = 0;
    for (scalars.items) |scalar| cursor += std.unicode.utf8Encode(scalar, output[cursor..]) catch return error.InvalidUtf8;
    return output;
}

pub fn isNormalized(allocator: std.mem.Allocator, input: []const u8, form: Form) Error!bool {
    const normalized = try normalize(allocator, input, form);
    defer allocator.free(normalized);
    return std.mem.eql(u8, input, normalized);
}

fn decomposeRecursive(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u21),
    scalar: u21,
    compatibility: bool,
    depth: u8,
) Error!void {
    if (depth == 64) return error.InvalidUtf8;
    if (try decomposeHangul(allocator, output, scalar)) return;
    if (data.decomposition(scalar, compatibility)) |mapping| {
        for (mapping) |mapped| try decomposeRecursive(allocator, output, mapped, compatibility, depth + 1);
        return;
    }
    try output.append(allocator, scalar);
}

fn decomposeHangul(allocator: std.mem.Allocator, output: *std.ArrayList(u21), scalar: u21) Error!bool {
    if (scalar < hangul_s_base or scalar >= hangul_s_base + hangul_s_count) return false;
    const s_index = scalar - hangul_s_base;
    try output.ensureUnusedCapacity(allocator, 3);
    output.appendAssumeCapacity(@intCast(hangul_l_base + s_index / hangul_n_count));
    output.appendAssumeCapacity(@intCast(hangul_v_base + (s_index % hangul_n_count) / hangul_t_count));
    const t_index = s_index % hangul_t_count;
    if (t_index != 0) output.appendAssumeCapacity(@intCast(hangul_t_base + t_index));
    return true;
}

fn canonicalOrder(values: []u21) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const combining = data.properties(values[index]).combining;
        if (combining == 0) continue;
        const value = values[index];
        var destination = index;
        while (destination > 0) {
            const previous_combining = data.properties(values[destination - 1]).combining;
            if (previous_combining == 0 or previous_combining <= combining) break;
            values[destination] = values[destination - 1];
            destination -= 1;
        }
        values[destination] = value;
    }
}

fn compose(values: []u21, length: *usize) void {
    if (length.* == 0) return;
    var output: usize = 1;
    var starter_index: usize = 0;
    var starter = values[0];
    var last_combining: u8 = 0;
    var input: usize = 1;
    while (input < length.*) : (input += 1) {
        const current = values[input];
        const combining = data.properties(current).combining;
        const combined = composeHangul(starter, current) orelse data.compose(starter, current);
        if (combined != null and (last_combining < combining or last_combining == 0)) {
            starter = combined.?;
            values[starter_index] = starter;
            continue;
        }
        if (combining == 0) {
            starter_index = output;
            starter = current;
        }
        last_combining = combining;
        values[output] = current;
        output += 1;
    }
    length.* = output;
}

fn composeHangul(first: u21, second: u21) ?u21 {
    if (first >= hangul_l_base and first < hangul_l_base + hangul_l_count and
        second >= hangul_v_base and second < hangul_v_base + hangul_v_count)
    {
        const l_index = first - hangul_l_base;
        const v_index = second - hangul_v_base;
        return @intCast(hangul_s_base + (l_index * hangul_v_count + v_index) * hangul_t_count);
    }
    if (first >= hangul_s_base and first < hangul_s_base + hangul_s_count and
        (first - hangul_s_base) % hangul_t_count == 0 and
        second > hangul_t_base and second < hangul_t_base + hangul_t_count)
    {
        return @intCast(first + second - hangul_t_base);
    }
    return null;
}
