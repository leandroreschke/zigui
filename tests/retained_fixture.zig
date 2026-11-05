const std = @import("std");
const ui = @import("zigui");

pub const Panel = struct {
    component: ui.core.handles.ComponentId = .invalid,
    value: u32 = 0,
    wide: bool = false,
    scroll: f32 = 0,
    reverse: bool = false,
    portal: bool = false,

    pub fn build(self: *Panel, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.component = ctx.component;
        const children = try ctx.allocator.alloc(ui.NodeSpec, 5);
        for (children, 0..) |*child, i| {
            const index = if (self.reverse) children.len - i - 1 else i;
            child.* = .{
                .key = index + 1,
                .kind = .{ .text = if (index == 0 and self.wide) "A longer line that wraps into another row" else if (self.value % 2 == 0) "Price 12" else "Price 34" },
                .style = .{
                    .layout = .{ .width = .{ .percent = 1 }, .min_height = .{ .points = 20 } },
                    .text = .{ .font_size = if (self.value % 3 == 0) 12 else 14, .color = ui.Color.rgba8(220, @intCast(120 + self.value % 100), 180, 255) },
                },
                .semantics = .{ .role = .static_text, .label = if (self.wide) "Long price" else "Price" },
            };
        }
        return .{
            .kind = .{ .scroll = .{ .offset_y = self.scroll } },
            .style = .{
                .layout = .{
                    .width = .{ .points = if (self.wide) 135 else 100 },
                    .height = .{ .points = 85 },
                    .flex_shrink = 0,
                    .overflow_y = .scroll,
                    .portal = if (self.portal) .{ .target = .viewport, .placement = .center } else .{},
                },
                .paint = .{
                    .background = .{ .solid = ui.Color.rgba8(30, 40, @intCast(50 + self.value % 120), 255) },
                    .opacity = if (self.value % 5 == 0) 0.7 else 1,
                    .radii = ui.CornerRadii.all(4),
                    .transform = .{ .tx = @floatFromInt(self.value % 4) },
                },
            },
            .children = children,
        };
    }
};

pub const Model = struct {
    component: ui.core.handles.ComponentId = .invalid,
    panels: [4]Panel = .{ .{}, .{}, .{}, .{} },
    slots: [4]ui.core.handles.ComponentId = @splat(.invalid),
    show_last: bool = true,
    reverse: bool = false,
    custom_value: u32 = 0,
    custom_paints: usize = 0,

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.component = ctx.component;
        const count: usize = if (self.show_last) 4 else 3;
        const children = try ctx.allocator.alloc(ui.NodeSpec, count + 1);
        for (children[0..count], 0..) |*child, i| {
            const index = if (self.reverse) count - i - 1 else i;
            child.* = try ctx.childComponent(&self.slots[index], ui.Component.Descriptor.from(Panel, &self.panels[index]));
            child.key = 100 + index;
        }
        children[count] = .{
            .key = 200,
            .kind = .{ .custom = ui.custom.Node.from(Model, self) },
            .style = .{ .layout = .{ .width = .{ .points = 25 }, .height = .{ .points = 25 }, .flex_shrink = 0 } },
        };
        return .{
            .style = .{
                .layout = .{ .width = .{ .percent = 1 }, .height = .{ .percent = 1 }, .direction = .row, .wrap = .wrap, .gap = .{ .width = 3, .height = 3 } },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(12, 16, 24, 255) } },
            },
            .children = children,
        };
    }

    pub fn paint(self: *Model, ctx: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        self.custom_paints += 1;
        try ctx.quad(.{
            .bounds = bounds,
            .background = ui.Color.rgba8(@intCast(self.custom_value % 255), 180, 80, 255),
            .border_color = .transparent,
            .border_widths = .{},
            .radii = .{},
        });
    }
};

pub fn drain(app: *ui.App) !void {
    var steps: usize = 0;
    while (try app.step(false)) : (steps += 1) {
        if (steps > 128) return error.DidNotSettle;
    }
}
