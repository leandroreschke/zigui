const std = @import("std");
const Error = @import("../../../core/error.zig").Error;
const input = @import("../../../input/event.zig");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");

pub const Decoded = struct {
    event: input.KeyEvent,
    scalar: ?u21 = null,
    dead_mark: ?u21 = null,
};

pub const Map = struct {
    allocator: std.mem.Allocator,
    minimum: u8,
    maximum: u8,
    symbols_per_key: u8,
    symbols: []u32,
    modifiers_per_slot: u8,
    modifier_keycodes: []u8,

    pub fn load(allocator: std.mem.Allocator, client: *client_mod.Client, writer: *wire.Writer) Error!Map {
        const minimum = client.setup.minimum_keycode;
        const maximum = client.setup.maximum_keycode;
        if (maximum < minimum) return error.PlatformFailure;
        const count_u16 = @as(u16, maximum) - minimum + 1;
        if (count_u16 > std.math.maxInt(u8)) return error.PlatformFailure;
        var mapping_reply = try protocol.getKeyboardMapping(client, writer, minimum, @intCast(count_u16));
        defer mapping_reply.deinit();
        if (mapping_reply.bytes.len < 32) return error.PlatformFailure;
        const symbols_per_key = mapping_reply.bytes[1];
        if (symbols_per_key == 0) return error.PlatformFailure;
        const symbol_count = std.math.mul(usize, count_u16, symbols_per_key) catch return error.BudgetExceeded;
        const symbol_bytes = std.math.mul(usize, symbol_count, 4) catch return error.BudgetExceeded;
        const required = std.math.add(usize, 32, symbol_bytes) catch return error.BudgetExceeded;
        if (required > mapping_reply.bytes.len) return error.PlatformFailure;
        const symbols = try allocator.alloc(u32, symbol_count);
        errdefer allocator.free(symbols);
        for (symbols, 0..) |*symbol, index| symbol.* = try wire.readU32(mapping_reply.bytes, 32 + index * 4);

        var modifier_reply = try protocol.getModifierMapping(client, writer);
        defer modifier_reply.deinit();
        if (modifier_reply.bytes.len < 32) return error.PlatformFailure;
        const modifiers_per_slot = modifier_reply.bytes[1];
        const modifier_count = @as(usize, modifiers_per_slot) * 8;
        if (32 + modifier_count > modifier_reply.bytes.len) return error.PlatformFailure;
        return .{
            .allocator = allocator,
            .minimum = minimum,
            .maximum = maximum,
            .symbols_per_key = symbols_per_key,
            .symbols = symbols,
            .modifiers_per_slot = modifiers_per_slot,
            .modifier_keycodes = try allocator.dupe(u8, modifier_reply.bytes[32..][0..modifier_count]),
        };
    }

    pub fn reload(self: *Map, client: *client_mod.Client, writer: *wire.Writer) Error!void {
        const replacement = try Map.load(self.allocator, client, writer);
        self.deinit();
        self.* = replacement;
    }

    pub fn decode(self: *const Map, keycode: u8, state: u16, repeat: bool, timestamp_ns: u64) Decoded {
        const modifiers = decodeModifiers(state);
        const symbol = self.symbolFor(keycode, modifiers);
        const scalar = keysymScalar(symbol);
        return .{
            .event = .{
                .key = semanticKey(symbol, scalar),
                .physical_code = keycode,
                .location = keyLocation(symbol),
                .modifiers = modifiers,
                .repeat = repeat,
                .composing = deadMark(symbol) != null,
                .timestamp_ns = timestamp_ns,
            },
            .scalar = scalar,
            .dead_mark = deadMark(symbol),
        };
    }

    pub fn deinit(self: *Map) void {
        self.allocator.free(self.symbols);
        self.allocator.free(self.modifier_keycodes);
        self.* = undefined;
    }

    fn symbolFor(self: *const Map, keycode: u8, modifiers: input.Modifiers) u32 {
        if (keycode < self.minimum or keycode > self.maximum) return 0;
        const base = @as(usize, keycode - self.minimum) * self.symbols_per_key;
        const group: usize = 0;
        const unshifted_index: usize = @min(group * 2, @as(usize, self.symbols_per_key) - 1);
        const shifted_index: usize = @min(unshifted_index + 1, @as(usize, self.symbols_per_key) - 1);
        const unshifted = self.symbols[base + unshifted_index];
        var shifted = self.symbols[base + shifted_index];
        if (shifted == 0) shifted = unshifted;
        const lower_scalar = keysymScalar(unshifted);
        const upper_scalar = keysymScalar(shifted);
        const alphabetic = if (lower_scalar) |lower| if (upper_scalar) |upper|
            lower != upper and isAlphabeticPair(lower, upper)
        else
            false else false;
        const use_shifted = if (alphabetic) modifiers.shift != modifiers.caps_lock else modifiers.shift;
        return if (use_shifted) shifted else unshifted;
    }
};

pub fn decodeModifiers(state: u16) input.Modifiers {
    return .{
        .shift = state & (1 << 0) != 0,
        .caps_lock = state & (1 << 1) != 0,
        .control = state & (1 << 2) != 0,
        .alt = state & (1 << 3) != 0,
        .num_lock = state & (1 << 4) != 0,
        .command = state & (1 << 6) != 0,
    };
}

fn semanticKey(symbol: u32, scalar: ?u21) input.Key {
    return switch (symbol) {
        0xff08 => .backspace,
        0xff09, 0xff89 => .tab,
        0xff0d, 0xff8d => .enter,
        0xff1b => .escape,
        0xff50, 0xff95 => .home,
        0xff51, 0xff96 => .arrow_left,
        0xff52, 0xff97 => .arrow_up,
        0xff53, 0xff98 => .arrow_right,
        0xff54, 0xff99 => .arrow_down,
        0xff55, 0xff9a => .page_up,
        0xff56, 0xff9b => .page_down,
        0xff57, 0xff9c => .end,
        0xff63, 0xff9e => .insert,
        0xffff, 0xff9f => .delete,
        0x20, 0xff80 => .space,
        0xffbe...0xffe0 => .{ .function = @intCast(symbol - 0xffbd) },
        else => if (scalar) |value| .{ .character = value } else .{ .native = symbol },
    };
}

fn keyLocation(symbol: u32) input.KeyLocation {
    return switch (symbol) {
        0xffe1, 0xffe3, 0xffe7, 0xffe9 => .left,
        0xffe2, 0xffe4, 0xffe8, 0xffea => .right,
        0xff80...0xffbd => .numpad,
        else => .standard,
    };
}

pub fn keysymScalar(symbol: u32) ?u21 {
    if (symbol >= 0x20 and symbol <= 0x7e) return @intCast(symbol);
    if (symbol >= 0xa0 and symbol <= 0xff) return @intCast(symbol);
    if (symbol & 0xff000000 == 0x01000000) {
        const value = symbol & 0x00ffffff;
        if (value <= 0x10ffff and !(value >= 0xd800 and value <= 0xdfff)) return @intCast(value);
    }
    return switch (symbol) {
        0x01a1 => 0x0104,
        0x01a2 => 0x02d8,
        0x01a3 => 0x0141,
        0x01a5 => 0x013d,
        0x01a6 => 0x015a,
        0x01a9 => 0x0160,
        0x01aa => 0x015e,
        0x01ab => 0x0164,
        0x01ac => 0x0179,
        0x01ae => 0x017d,
        0x01af => 0x017b,
        0x01b1 => 0x0105,
        0x01b2 => 0x02db,
        0x01b3 => 0x0142,
        0x01b5 => 0x013e,
        0x01b6 => 0x015b,
        0x01b7 => 0x02c7,
        0x01b9 => 0x0161,
        0x01ba => 0x015f,
        0x01bb => 0x0165,
        0x01bc => 0x017a,
        0x01bd => 0x02dd,
        0x01be => 0x017e,
        0x01bf => 0x017c,
        0x06a1...0x06ff => cyrillicLegacy(symbol),
        0x07a1...0x07f9 => greekLegacy(symbol),
        else => null,
    };
}

pub fn deadMark(symbol: u32) ?u21 {
    return switch (symbol) {
        0xfe50 => 0x0300,
        0xfe51 => 0x0301,
        0xfe52 => 0x0302,
        0xfe53 => 0x0303,
        0xfe54 => 0x0304,
        0xfe55 => 0x0306,
        0xfe56 => 0x0307,
        0xfe57 => 0x0308,
        0xfe58 => 0x030a,
        0xfe59 => 0x030b,
        0xfe5a => 0x030c,
        0xfe5b => 0x0327,
        0xfe5c => 0x0328,
        0xfe5d => 0x0345,
        0xfe5e => 0x3099,
        0xfe5f => 0x309a,
        else => null,
    };
}

pub fn compose(base: u21, mark: u21) ?u21 {
    return switch (mark) {
        0x0300 => switch (base) {
            'A' => 0x00c0,
            'E' => 0x00c8,
            'I' => 0x00cc,
            'O' => 0x00d2,
            'U' => 0x00d9,
            'a' => 0x00e0,
            'e' => 0x00e8,
            'i' => 0x00ec,
            'o' => 0x00f2,
            'u' => 0x00f9,
            else => null,
        },
        0x0301 => switch (base) {
            'A' => 0x00c1,
            'E' => 0x00c9,
            'I' => 0x00cd,
            'O' => 0x00d3,
            'U' => 0x00da,
            'Y' => 0x00dd,
            'a' => 0x00e1,
            'e' => 0x00e9,
            'i' => 0x00ed,
            'o' => 0x00f3,
            'u' => 0x00fa,
            'y' => 0x00fd,
            else => null,
        },
        0x0302 => switch (base) {
            'A' => 0x00c2,
            'E' => 0x00ca,
            'I' => 0x00ce,
            'O' => 0x00d4,
            'U' => 0x00db,
            'a' => 0x00e2,
            'e' => 0x00ea,
            'i' => 0x00ee,
            'o' => 0x00f4,
            'u' => 0x00fb,
            else => null,
        },
        0x0303 => switch (base) {
            'A' => 0x00c3,
            'N' => 0x00d1,
            'O' => 0x00d5,
            'a' => 0x00e3,
            'n' => 0x00f1,
            'o' => 0x00f5,
            else => null,
        },
        0x0308 => switch (base) {
            'A' => 0x00c4,
            'E' => 0x00cb,
            'I' => 0x00cf,
            'O' => 0x00d6,
            'U' => 0x00dc,
            'Y' => 0x0178,
            'a' => 0x00e4,
            'e' => 0x00eb,
            'i' => 0x00ef,
            'o' => 0x00f6,
            'u' => 0x00fc,
            'y' => 0x00ff,
            else => null,
        },
        0x030a => switch (base) {
            'A' => 0x00c5,
            'a' => 0x00e5,
            else => null,
        },
        0x0327 => switch (base) {
            'C' => 0x00c7,
            'c' => 0x00e7,
            else => null,
        },
        else => null,
    };
}

fn isAlphabeticPair(lower: u21, upper: u21) bool {
    if (lower >= 'a' and lower <= 'z' and upper == lower - 32) return true;
    return lower != upper;
}

fn cyrillicLegacy(symbol: u32) ?u21 {
    const table = [_]u21{
        0x0452, 0x0453, 0x0451, 0x0454, 0x0455, 0x0456, 0x0457, 0x0458,
        0x0459, 0x045a, 0x045b, 0x045c, 0x0491, 0x045e, 0x045f, 0x2116,
    };
    if (symbol >= 0x06a1 and symbol <= 0x06b0) return table[symbol - 0x06a1];
    if (symbol >= 0x06c0 and symbol <= 0x06df) return @intCast(0x044e - (symbol - 0x06c0));
    if (symbol >= 0x06e0 and symbol <= 0x06ff) return @intCast(0x042e - (symbol - 0x06e0));
    return null;
}

fn greekLegacy(symbol: u32) ?u21 {
    if (symbol >= 0x07c1 and symbol <= 0x07d9) return @intCast(0x0391 + symbol - 0x07c1);
    if (symbol >= 0x07e1 and symbol <= 0x07f9) return @intCast(0x03b1 + symbol - 0x07e1);
    return switch (symbol) {
        0x07a1 => 0x0386,
        0x07a2 => 0x0388,
        0x07a3 => 0x0389,
        0x07a4 => 0x038a,
        0x07a5 => 0x03aa,
        0x07a7 => 0x038c,
        0x07a8 => 0x038e,
        0x07a9 => 0x03ab,
        0x07ab => 0x038f,
        0x07b1 => 0x03ac,
        0x07b2 => 0x03ad,
        0x07b3 => 0x03ae,
        0x07b4 => 0x03af,
        0x07b5 => 0x03ca,
        0x07b6 => 0x0390,
        0x07b7 => 0x03cc,
        0x07b8 => 0x03cd,
        0x07b9 => 0x03cb,
        0x07ba => 0x03b0,
        0x07bb => 0x03ce,
        else => null,
    };
}
