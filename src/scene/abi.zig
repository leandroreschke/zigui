const std = @import("std");
const geometry = @import("../core/geometry.zig");

pub const OperationKind = enum(u32) {
    push_clip,
    pop_clip,
    push_layer,
    pop_layer,
    shadows,
    quads,
    paths,
    underlines,
    monochrome_sprites,
    color_sprites,
    external_surfaces,
    custom_passes,
    backdrop_effect,
};

pub const BlendMode = enum(u32) { normal, multiply, screen, overlay, plus_lighter };
pub const TextureFormat = enum(u32) { a8, rgba8, bgra8, rgba16_float };
pub const MaterialKind = enum(u32) { none, solid, linear_gradient, radial_gradient };
pub const PathCommand = enum(u32) { move_to, line_to, quadratic_to, close };
pub const FillRule = enum(u32) { non_zero, even_odd };

pub const Material = extern struct {
    kind: u32,
    stop_start: u32,
    stop_count: u32,
    reserved: u32 = 0,
    color: geometry.Color,
    start: geometry.Point,
    end: geometry.Point,
    /// Maps world coordinates into the gradient's coordinate system. Linear
    /// gradients normally use identity. Radial gradients encode their two
    /// circle centers in `start`/`end` and radii in `color.r`/`color.g`.
    gradient_transform: geometry.Affine2D = .identity,
};

pub const GradientStop = extern struct {
    offset: f32,
    reserved: [3]f32 = .{ 0, 0, 0 },
    color: geometry.Color,
};

pub const Operation = extern struct {
    kind: u32,
    start: u32,
    count: u32,
    clip: u32,
    layer: u32,
    material: u32,
    target: u32,
    reserved: u32 = 0,
};

pub const Clip = extern struct {
    bounds: geometry.Rect,
    radii: geometry.CornerRadii,
    parent: u32,
    layer: u32,
    reserved: [2]u32 = .{ 0, 0 },
};

pub const Layer = extern struct {
    opacity: f32,
    blend_mode: u32,
    parent: u32,
    reserved: u32 = 0,
    transform: geometry.Affine2D,
};

pub const Quad = extern struct {
    bounds: geometry.Rect,
    background: geometry.Color,
    border_color: geometry.Color,
    border_widths: geometry.Insets,
    radii: geometry.CornerRadii,
};

pub const Shadow = extern struct {
    bounds: geometry.Rect,
    color: geometry.Color,
    radii: geometry.CornerRadii,
    offset: geometry.Point,
    blur_radius: f32,
    spread: f32,
};

pub const BackdropEffect = extern struct {
    bounds: geometry.Rect,
    radii: geometry.CornerRadii = .{},
    blur_radius: f32 = 0,
    saturation: f32 = 1,
    opacity: f32 = 1,
};

pub const PathVertex = extern struct {
    position: geometry.Point,
    control: geometry.Point,
    kind: u32,
    reserved: u32 = 0,
};

pub const Path = extern struct {
    vertex_start: u32,
    vertex_count: u32,
    fill_rule: u32,
    reserved: u32 = 0,
    color: geometry.Color,
    bounds: geometry.Rect,
};

pub const Underline = extern struct {
    bounds: geometry.Rect,
    color: geometry.Color,
    thickness: f32,
    wave_amplitude: f32,
    wave_period: f32,
    reserved: f32 = 0,
};

pub const Sprite = extern struct {
    bounds: geometry.Rect,
    uv_bounds: geometry.Rect,
    color: geometry.Color,
    texture: u64,
    tile_generation: u32,
    format: u32,
    /// A progressively blurred contrast treatment along the bottom edge.
    effect: SpriteEffect = .none,
    effect_radius: f32 = 0,
    effect_height: f32 = 0,
    effect_reserved: u32 = 0,
};

pub const SpriteEffect = enum(u32) { none, light_text, dark_text, preview_blur };

pub const ExternalSurface = extern struct {
    bounds: geometry.Rect,
    uv_bounds: geometry.Rect,
    surface: u64,
    generation: u32,
    color_space: u32,
    opacity: f32,
    reserved: f32 = 0,
};

pub const CustomPass = extern struct {
    bounds: geometry.Rect,
    extension: u64,
    payload_start: u32,
    payload_length: u32,
    flags: u32 = 0,
    reserved: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Operation) == 32);
    std.debug.assert(@offsetOf(Operation, "start") == 4);
    std.debug.assert(@sizeOf(geometry.Color) == 16);
    std.debug.assert(@sizeOf(geometry.Rect) == 16);
    std.debug.assert(@sizeOf(geometry.Affine2D) == 24);
    std.debug.assert(@sizeOf(Material) == 72);
    std.debug.assert(@sizeOf(GradientStop) == 32);
    std.debug.assert(@offsetOf(GradientStop, "color") == 16);
    std.debug.assert(@sizeOf(PathVertex) == 24);
    std.debug.assert(@offsetOf(PathVertex, "kind") == 16);
    std.debug.assert(@sizeOf(BackdropEffect) == 44);
    std.debug.assert(@sizeOf(Sprite) == 80);
    std.debug.assert(@sizeOf(CustomPass) == 40);
}
