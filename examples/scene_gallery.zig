const std = @import("std");
const ui = @import("zigui");

const Gallery = struct {
    pub fn paint(_: *Gallery, ctx: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        const inset = bounds.inset(ui.Insets.all(28));
        const gap: f32 = 18;
        const card_width = @max(80, (inset.size.width - gap * 2) / 3);
        const card_height = @max(120, inset.size.height - 56);
        const radii = ui.CornerRadii.all(18);

        const first = ui.Rect.fromXYWH(inset.origin.x, inset.origin.y + 28, card_width, card_height);
        try ctx.emit(.{ .shadow = .{
            .bounds = first,
            .color = ui.Color.rgba(0, 0, 0, 0.45),
            .radii = radii,
            .offset = .{ .y = 12 },
            .blur_radius = 30,
            .spread = -3,
        } });
        const stops = [_]ui.scene_abi.GradientStop{
            .{ .offset = 0, .color = ui.Color.rgba8(83, 76, 255, 255) },
            .{ .offset = 0.52, .color = ui.Color.rgba8(157, 74, 255, 255) },
            .{ .offset = 1, .color = ui.Color.rgba8(255, 83, 153, 255) },
        };
        try ctx.gradientQuad(.{
            .bounds = first,
            .background = .transparent,
            .border_color = ui.Color.rgba(1, 1, 1, 0.22),
            .border_widths = ui.Insets.all(1),
            .radii = radii,
        }, first.origin, .{ .x = first.maxX(), .y = first.maxY() }, &stops);

        const second = ui.Rect.fromXYWH(first.maxX() + gap, first.origin.y, card_width, card_height);
        try ctx.pushClip(second, radii);
        try ctx.quad(.{
            .bounds = second,
            .background = ui.Color.rgba8(27, 34, 49, 255),
            .border_color = ui.Color.rgba8(77, 88, 112, 255),
            .border_widths = ui.Insets.all(1),
            .radii = radii,
        });
        var stripe: usize = 0;
        while (stripe < 9) : (stripe += 1) {
            const x = second.origin.x - 80 + @as(f32, @floatFromInt(stripe)) * 38;
            try ctx.pushLayer(0.72, .screen, (ui.Affine2D{
                .m11 = 0.78,
                .m12 = 0.62,
                .m21 = -0.62,
                .m22 = 0.78,
                .tx = 0,
                .ty = 0,
            }).around(.{ .x = x, .y = second.origin.y }));
            try ctx.quad(.{
                .bounds = ui.Rect.fromXYWH(x, second.origin.y - 120, 18, second.size.height + 240),
                .background = if (stripe % 2 == 0) ui.Color.rgba8(53, 211, 153, 255) else ui.Color.rgba8(69, 150, 255, 255),
                .border_color = .transparent,
                .border_widths = .{},
                .radii = .{},
            });
            try ctx.popLayer();
        }
        try ctx.popClip();

        const third = ui.Rect.fromXYWH(second.maxX() + gap, first.origin.y, card_width, card_height);
        try ctx.quad(.{
            .bounds = third,
            .background = ui.Color.rgba8(249, 245, 236, 255),
            .border_color = ui.Color.rgba8(220, 209, 187, 255),
            .border_widths = ui.Insets.all(1),
            .radii = radii,
        });
        const center: ui.Point = .{ .x = third.origin.x + third.size.width / 2, .y = third.origin.y + third.size.height / 2 };
        const outer = @min(third.size.width, third.size.height) * 0.31;
        const inner = outer * 0.43;
        var vertices: [12]ui.scene_abi.PathVertex = undefined;
        for (0..10) |index| {
            const radius = if (index % 2 == 0) outer else inner;
            const angle = -std.math.pi / 2.0 + @as(f32, @floatFromInt(index)) * std.math.pi / 5.0;
            vertices[index] = .{
                .position = .{ .x = center.x + @cos(angle) * radius, .y = center.y + @sin(angle) * radius },
                .control = .{},
                .kind = @backingInt(if (index == 0) ui.scene_abi.PathCommand.move_to else ui.scene_abi.PathCommand.line_to),
            };
        }
        vertices[10] = .{ .position = vertices[0].position, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.close) };
        vertices[11] = vertices[10];
        try ctx.path(.{
            .vertex_start = 0,
            .vertex_count = 0,
            .fill_rule = @backingInt(ui.scene_abi.FillRule.non_zero),
            .color = ui.Color.rgba8(237, 93, 66, 255),
            .bounds = third,
        }, vertices[0..11]);

        if (ctx.text) |_| {
            try ctx.paintText("Gradient", .{ .font_size = 18, .font_weight = .semibold, .color = ui.Color.white }, first.inset(ui.Insets.all(18)));
            try ctx.paintText("Clip + layers", .{ .font_size = 18, .font_weight = .semibold, .color = ui.Color.white }, second.inset(ui.Insets.all(18)));
            try ctx.paintText("Vector path", .{ .font_size = 18, .font_weight = .semibold, .color = ui.Color.rgba8(52, 45, 38, 255) }, third.inset(ui.Insets.all(18)));
        }
    }
};

const Model = struct {
    gallery: Gallery = .{},

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        _ = ctx;
        return .{
            .kind = .{ .custom = ui.custom.Node.from(Gallery, &self.gallery) },
            .style = .{
                .layout = .{ .width = .{ .percent = 1 }, .height = .{ .percent = 1 } },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(14, 17, 24, 255) } },
            },
            .semantics = .{ .role = .canvas, .label = "ZigUI scene primitive gallery" },
        };
    }
};

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    var model: Model = .{};
    const app = try ui.App.create(allocator, .{ .application_name = "ZigUI Scene Gallery" });
    defer app.destroy() catch {};
    _ = try app.openWindow(.{
        .platform = .{ .title = "Scene Gallery", .size = .{ .width = 1080, .height = 620 } },
        .clear_color = ui.Color.rgba8(14, 17, 24, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    try app.run();
}
