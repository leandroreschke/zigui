const std = @import("std");
const input = @import("../../../input/event.zig");

pub const State = struct {
    modifiers: input.Modifiers = .{},
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,
    repeat_rate: i32 = 25,
    repeat_delay_ms: i32 = 600,
    pressed: std.StaticBitSet(768) = .empty,

    /// Core XKB real modifiers occupy these stable indices. The complete
    /// in-tree keymap interpreter may override them after parsing a keymap.
    shift_index: u5 = 0,
    lock_index: u5 = 1,
    control_index: u5 = 2,
    alt_index: u5 = 3,
    num_index: u5 = 4,
    command_index: u5 = 6,

    pub fn updateModifiers(self: *State, depressed: u32, latched: u32, locked: u32, group: u32) void {
        self.depressed = depressed;
        self.latched = latched;
        self.locked = locked;
        self.group = group;
        const active = depressed | latched | locked;
        self.modifiers = .{
            .shift = active & bit(self.shift_index) != 0,
            .control = active & bit(self.control_index) != 0,
            .alt = active & bit(self.alt_index) != 0,
            .command = active & bit(self.command_index) != 0,
            .caps_lock = locked & bit(self.lock_index) != 0,
            .num_lock = locked & bit(self.num_index) != 0,
        };
    }

    pub fn keyEvent(self: *State, code: u32, pressed: bool, repeated: bool, timestamp_ns: u64) input.KeyEvent {
        if (code < 768) self.pressed.setValue(@intCast(code), pressed);
        return .{
            .key = mapKey(code, self.modifiers),
            .physical_code = code,
            .location = location(code),
            .modifiers = self.modifiers,
            .repeat = repeated,
            .timestamp_ns = timestamp_ns,
        };
    }
};

fn bit(index: u5) u32 {
    return @as(u32, 1) << index;
}

fn mapKey(code: u32, modifiers: input.Modifiers) input.Key {
    return switch (code) {
        1 => .escape,
        14 => .backspace,
        15 => .tab,
        28, 96 => .enter,
        57 => .space,
        102, 71 => .home,
        107, 79 => .end,
        104, 73 => .page_up,
        109, 81 => .page_down,
        105, 75 => .arrow_left,
        106, 77 => .arrow_right,
        103, 72 => .arrow_up,
        108, 80 => .arrow_down,
        110, 82 => .insert,
        111, 83 => .delete,
        59...68 => .{ .function = @intCast(code - 58) },
        87 => .{ .function = 11 },
        88 => .{ .function = 12 },
        else => if (usScalar(code, modifiers)) |scalar| .{ .character = scalar } else .{ .native = code },
    };
}

fn usScalar(code: u32, modifiers: input.Modifiers) ?u21 {
    const shifted = modifiers.shift;
    const uppercase = modifiers.shift != modifiers.caps_lock;
    if (letter(code)) |value| return if (uppercase) std.ascii.toUpper(value) else value;
    return switch (code) {
        2 => if (shifted) '!' else '1',
        3 => if (shifted) '@' else '2',
        4 => if (shifted) '#' else '3',
        5 => if (shifted) '$' else '4',
        6 => if (shifted) '%' else '5',
        7 => if (shifted) '^' else '6',
        8 => if (shifted) '&' else '7',
        9 => if (shifted) '*' else '8',
        10 => if (shifted) '(' else '9',
        11 => if (shifted) ')' else '0',
        12 => if (shifted) '_' else '-',
        13 => if (shifted) '+' else '=',
        26 => if (shifted) '{' else '[',
        27 => if (shifted) '}' else ']',
        39 => if (shifted) ':' else ';',
        40 => if (shifted) '"' else '\'',
        41 => if (shifted) '~' else '`',
        43 => if (shifted) '|' else '\\',
        51 => if (shifted) '<' else ',',
        52 => if (shifted) '>' else '.',
        53 => if (shifted) '?' else '/',
        else => null,
    };
}

fn letter(code: u32) ?u8 {
    return switch (code) {
        16 => 'q',
        17 => 'w',
        18 => 'e',
        19 => 'r',
        20 => 't',
        21 => 'y',
        22 => 'u',
        23 => 'i',
        24 => 'o',
        25 => 'p',
        30 => 'a',
        31 => 's',
        32 => 'd',
        33 => 'f',
        34 => 'g',
        35 => 'h',
        36 => 'j',
        37 => 'k',
        38 => 'l',
        44 => 'z',
        45 => 'x',
        46 => 'c',
        47 => 'v',
        48 => 'b',
        49 => 'n',
        50 => 'm',
        else => null,
    };
}

fn location(code: u32) input.KeyLocation {
    return switch (code) {
        29, 42, 56, 125 => .left,
        54, 97, 100, 126 => .right,
        55, 71...83, 96, 98 => .numpad,
        else => .standard,
    };
}
