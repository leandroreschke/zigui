const geometry = @import("../core/geometry.zig");

pub const Theme = struct {
    background: geometry.Color = geometry.Color.rgba8(24, 24, 27, 255),
    surface: geometry.Color = geometry.Color.rgba8(39, 39, 42, 255),
    surface_hovered: geometry.Color = geometry.Color.rgba8(52, 52, 56, 255),
    surface_pressed: geometry.Color = geometry.Color.rgba8(63, 63, 70, 255),
    border: geometry.Color = geometry.Color.rgba8(82, 82, 91, 255),
    text: geometry.Color = geometry.Color.rgba8(250, 250, 250, 255),
    muted_text: geometry.Color = geometry.Color.rgba8(161, 161, 170, 255),
    accent: geometry.Color = geometry.Color.rgba8(59, 130, 246, 255),
    accent_hovered: geometry.Color = geometry.Color.rgba8(96, 165, 250, 255),
    accent_pressed: geometry.Color = geometry.Color.rgba8(37, 99, 235, 255),
    focus_ring: geometry.Color = geometry.Color.rgba8(59, 130, 246, 255),
    destructive: geometry.Color = geometry.Color.rgba8(239, 68, 68, 255),
    disabled_opacity: f32 = 0.48,
    control_height: f32 = 32,
    compact_control_height: f32 = 26,
    radius: f32 = 6,
    spacing: f32 = 8,
    font_families: []const []const u8 = &.{"system-ui"},
    font_size: f32 = 14,
    focus_ring_width: f32 = 2,

    pub const dark: Theme = .{};

    pub const light: Theme = .{
        .background = geometry.Color.rgba8(250, 250, 250, 255),
        .surface = geometry.Color.rgba8(244, 244, 245, 255),
        .surface_hovered = geometry.Color.rgba8(228, 228, 231, 255),
        .surface_pressed = geometry.Color.rgba8(212, 212, 216, 255),
        .border = geometry.Color.rgba8(161, 161, 170, 255),
        .text = geometry.Color.rgba8(24, 24, 27, 255),
        .muted_text = geometry.Color.rgba8(82, 82, 91, 255),
    };
};
