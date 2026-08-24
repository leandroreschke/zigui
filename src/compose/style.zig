const geometry = @import("../core/geometry.zig");
const Error = @import("../core/error.zig").Error;
const layout = @import("../layout/style.zig");
const text = @import("../text/api.zig");

pub const Cursor = enum {
    default,
    pointer,
    text,
    crosshair,
    grab,
    grabbing,
    resize_horizontal,
    resize_vertical,
    resize_diagonal_nw_se,
    resize_diagonal_ne_sw,
    not_allowed,
    hidden,
};

pub const PointerEvents = enum { auto, none, box_only, children_only };

pub const GradientStop = extern struct {
    offset: f32,
    color: geometry.Color,
};

pub const LinearGradient = struct {
    angle_radians: f32 = 0,
    stops: [8]GradientStop = undefined,
    stop_count: u8 = 0,

    pub fn from(stops: []const GradientStop, angle_radians: f32) Error!LinearGradient {
        var result: LinearGradient = .{ .angle_radians = angle_radians };
        if (stops.len > result.stops.len) return error.BudgetExceeded;
        result.stop_count = @intCast(stops.len);
        @memcpy(result.stops[0..result.stop_count], stops[0..result.stop_count]);
        return result;
    }
};

pub const Brush = union(enum) {
    none,
    solid: geometry.Color,
    linear_gradient: LinearGradient,
};

pub const BorderStyle = struct {
    widths: geometry.Insets = .{},
    color: geometry.Color = .transparent,
};

pub const ShadowStyle = struct {
    color: geometry.Color = .transparent,
    offset: geometry.Point = .{},
    blur_radius: f32 = 0,
    spread: f32 = 0,
};

pub const Shadows = struct {
    values: [4]ShadowStyle = undefined,
    count: u8 = 0,

    pub fn from(values: []const ShadowStyle) Error!Shadows {
        var result: Shadows = .{};
        if (values.len > result.values.len) return error.BudgetExceeded;
        result.count = @intCast(values.len);
        @memcpy(result.values[0..result.count], values[0..result.count]);
        return result;
    }
};

pub const PaintStyle = struct {
    background: Brush = .none,
    border: BorderStyle = .{},
    radii: geometry.CornerRadii = .{},
    shadows: Shadows = .{},
    opacity: f32 = 1,
    transform: geometry.Affine2D = .identity,
};

pub const TextStyle = struct {
    font_families: []const []const u8 = &.{"system-ui"},
    font_weight: text.FontWeight = .regular,
    font_style: text.FontStyle = .normal,
    /// Percentage of the font's normal width. Variable fonts map this to the
    /// `wdth` axis; static faces use it during family matching.
    font_stretch: u16 = 100,
    /// Explicit OpenType user-space axis values. The store owns a copy, so a
    /// caller may construct this slice in frame scratch memory.
    font_variations: []const text.FontVariation = &.{},
    font_size: f32 = 14,
    line_height: ?f32 = null,
    letter_spacing: f32 = 0,
    color: geometry.Color = .white,
    direction: text.TextDirection = .auto,
    wrap: text.WrapMode = .word,
    maximum_lines: ?u32 = null,
};

pub const InteractionStyle = struct {
    cursor: Cursor = .default,
    pointer_events: PointerEvents = .auto,
    focusable: bool = false,
    tab_index: i32 = 0,
    disabled: bool = false,
    /// Clips descendants for hit testing even when visual overflow is visible.
    /// Ordinary overflow follows the layout overflow policy automatically.
    clips_hit_testing: bool = false,
    /// Declares a focus boundary. `trap_focus` confines tab navigation to the
    /// deepest active boundary and restores the previous focus when removed.
    focus_scope: bool = false,
    trap_focus: bool = false,
    autofocus: bool = false,
};

pub const Style = struct {
    layout: layout.LayoutStyle = .{},
    paint: PaintStyle = .{},
    text: TextStyle = .{},
    interaction: InteractionStyle = .{},
};
