const std = @import("std");
const a11y = @import("../a11y/api.zig");
const handles = @import("../core/handle.zig");
const input = @import("../input/event.zig");
const action = @import("../input/action.zig");
const custom = @import("custom.zig");
const style = @import("style.zig");

pub const Key = u64;

pub const Image = struct {
    texture: handles.TextureId,
    source_width: u32,
    source_height: u32,
    fit: Fit = .contain,

    pub const Fit = enum { fill, contain, cover, none, scale_down };
};

pub const Scroll = struct {
    horizontal: bool = false,
    vertical: bool = true,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub const Kind = union(enum) {
    container,
    spacer,
    text: []const u8,
    image: Image,
    scroll: Scroll,
    component: handles.ComponentId,
    custom: custom.Node,
};

pub const Semantics = struct {
    role: a11y.Role = .none,
    label: []const u8 = "",
    description: []const u8 = "",
    value: []const u8 = "",
    actions: []const a11y.Action = &.{},
    disabled: bool = false,
    checked: ?bool = null,
    expanded: ?bool = null,
    selected: bool = false,
    selection: ?a11y.Selection = null,
    range_min: ?f64 = null,
    range_max: ?f64 = null,
    range_value: ?f64 = null,
    multiline: bool = false,
    password: bool = false,
};

pub const Spec = struct {
    key: ?Key = null,
    kind: Kind = .container,
    style: style.Style = .{},
    handlers: []const input.Handler = &.{},
    action_handlers: []const action.Handler = &.{},
    semantics: Semantics = .{},
    children: []const Spec = &.{},

    pub fn withKey(self: Spec, key: Key) Spec {
        var copy = self;
        copy.key = key;
        return copy;
    }
};

pub fn automaticKey(parent_seed: u64, index: usize, kind: Kind) Key {
    const tag: u64 = @backingInt(std.meta.activeTag(kind));
    var value = parent_seed ^ (tag *% 0x9e3779b97f4a7c15);
    value ^= @as(u64, @intCast(index)) +% 0x517cc1b727220a95 +% (value << 6) +% (value >> 2);
    return value;
}
