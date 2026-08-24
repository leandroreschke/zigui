const Error = @import("../core/error.zig").Error;
const std = @import("std");
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const custom = @import("../compose/custom.zig");
const image_fit = @import("../compose/image_fit.zig");
const node = @import("../compose/node.zig");
const layout = @import("../layout/style.zig");
const scene_abi = @import("../scene/abi.zig");
const render = @import("../render/api.zig");
const api = @import("api.zig");

pub const View = struct {
    visual: api.Visual,
    fit: node.Image.Fit = .contain,
    opacity: f32 = 1,
    label: []const u8 = "",

    pub fn build(self: *View, _: *component.BuildContext) Error!node.Spec {
        try self.validate();
        return .{
            .kind = .{ .custom = custom.Node.from(View, self) },
            .semantics = .{ .role = .image, .label = self.label },
        };
    }

    pub fn measure(self: *View, _: *custom.MeasureContext, constraints: layout.Constraints) Error!geometry.Size {
        try self.validate();
        const natural: geometry.Size = .{ .width = @floatFromInt(self.visual.width()), .height = @floatFromInt(self.visual.height()) };
        return constraints.constrain(natural);
    }

    pub fn paint(self: *View, ctx: *custom.PaintContext, bounds: geometry.Rect) Error!void {
        try self.validate();
        const placement = image_fit.place(bounds, self.visual.width(), self.visual.height(), self.fit);
        switch (self.visual) {
            .texture => |texture| try ctx.emit(.{ .color_sprite = .{
                .bounds = placement.bounds,
                .uv_bounds = placement.uv_bounds,
                .color = geometry.Color.rgba(1, 1, 1, self.opacity),
                .texture = texture.id.encode(),
                .tile_generation = texture.id.generation,
                .format = @backingInt(textureFormat(texture.format)),
            } }),
            .surface => |surface| try ctx.emit(.{ .external_surface = .{
                .bounds = placement.bounds,
                .uv_bounds = placement.uv_bounds,
                .surface = surface.id.encode(),
                .generation = surface.id.generation,
                .color_space = @backingInt(surface.color_space),
                .opacity = self.opacity,
            } }),
        }
    }

    fn validate(self: *const View) Error!void {
        try api.validateVisual(self.visual);
        if (!std.math.isFinite(self.opacity) or self.opacity < 0 or self.opacity > 1)
            return error.InvalidConfiguration;
    }
};

fn textureFormat(format: render.PixelFormat) scene_abi.TextureFormat {
    return switch (format) {
        .a8 => .a8,
        .rgba8, .rgba8_srgb => .rgba8,
        .bgra8, .bgra8_srgb => .bgra8,
        .rgba16_float => .rgba16_float,
    };
}
