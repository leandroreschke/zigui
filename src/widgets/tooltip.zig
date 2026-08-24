const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const Theme = @import("theme.zig").Theme;

pub const Placement = enum { top, bottom, left, right };

pub const Tooltip = struct {
    content: node.Spec,
    text: []const u8,
    theme: *const Theme = &Theme.dark,
    placement: Placement = .top,
    visible: bool = false,
    disabled: bool = false,

    pub fn build(self: *Tooltip, ctx: *component.BuildContext) Error!node.Spec {
        if (self.disabled) self.visible = false;
        const children = try ctx.allocator.alloc(node.Spec, 1 + @as(usize, @intFromBool(self.visible and !self.disabled)));
        children[0] = self.content;
        if (children.len == 2) {
            const text_children = try ctx.allocator.dupe(node.Spec, &.{node.Spec{
                .kind = .{ .text = self.text },
                .style = .{ .text = .{ .font_size = self.theme.font_size - 1, .color = self.theme.text, .wrap = .none } },
            }});
            children[1] = .{
                .kind = .container,
                .style = .{
                    .layout = .{
                        .position = .absolute,
                        .portal = .{
                            .target = .anchor,
                            .placement = portalPlacement(self.placement),
                            .alignment = .center,
                            .gap = 6,
                            .viewport_margin = 6,
                            .order = @import("../layout/style.zig").PortalStyle.Order.tooltip,
                        },
                        .max_width = .{ .points = 320 },
                        .padding = .{ .left = .{ .points = 8 }, .right = .{ .points = 8 }, .top = .{ .points = 5 }, .bottom = .{ .points = 5 } },
                    },
                    .paint = .{
                        .background = .{ .solid = self.theme.surface_pressed },
                        .border = .{ .widths = geometry.Insets.all(1), .color = self.theme.border },
                        .radii = geometry.CornerRadii.all(self.theme.radius),
                        .shadows = try @import("../compose/style.zig").Shadows.from(&.{.{ .color = geometry.Color.rgba(0, 0, 0, 0.3), .offset = .{ .y = 2 }, .blur_radius = 8 }}),
                    },
                    .interaction = .{ .pointer_events = .none },
                },
                .semantics = .{ .role = .tooltip, .label = self.text },
                .children = text_children,
            };
        }
        const handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = self, .callback = handle }});
        return .{
            .kind = .container,
            .style = .{ .layout = .{ .position = .relative } },
            .handlers = handlers,
            .children = children,
        };
    }

    fn handle(context: *anyopaque, _: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const self: *Tooltip = @ptrCast(@alignCast(context));
        if (self.disabled) return;
        switch (event.*) {
            .pointer_enter, .focus_in => if (!self.visible) {
                self.visible = true;
                try ctx.invalidate(.{});
            },
            .pointer_leave, .pointer_cancel, .focus_out => if (self.visible) {
                self.visible = false;
                try ctx.invalidate(.{});
            },
            else => {},
        }
    }
};

fn portalPlacement(placement: Placement) @import("../layout/style.zig").PortalPlacement {
    return switch (placement) {
        .top => .above,
        .bottom => .below,
        .left => .left,
        .right => .right,
    };
}
