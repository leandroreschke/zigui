const Error = @import("../core/error.zig").Error;
const std = @import("std");
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const Dialog = struct {
    open: *bool,
    title: []const u8,
    content: node.Spec,
    footer: ?node.Spec = null,
    on_close: ?Callback = null,
    theme: *const Theme = &Theme.dark,
    width: f32 = 480,
    dismiss_on_escape: bool = true,
    dismiss_on_backdrop: bool = true,
    backdrop: HandlerTarget = .{ .kind = .backdrop },
    panel: HandlerTarget = .{ .kind = .panel },

    const HandlerTarget = struct {
        owner: *Dialog = undefined,
        kind: Kind,
        pressed_pointer: ?u64 = null,
        const Kind = enum { backdrop, panel };
    };

    pub fn build(self: *Dialog, ctx: *component.BuildContext) Error!node.Spec {
        if (!std.math.isFinite(self.width) or self.width <= 0 or self.width > 1_000_000)
            return error.InvalidConfiguration;
        if (!self.open.*) {
            self.backdrop.pressed_pointer = null;
            self.panel.pressed_pointer = null;
            return .{ .kind = .spacer, .style = .{ .layout = .{ .display = .none } } };
        }
        self.backdrop.owner = self;
        self.panel.owner = self;
        const backdrop_handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = &self.backdrop, .callback = handle }});
        const panel_handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = &self.panel, .callback = handle }});
        const panel_actions = try ctx.allocator.dupe(a11y.Action, &.{.focus});
        const panel_children = try ctx.allocator.alloc(node.Spec, 2 + @as(usize, @intFromBool(self.footer != null)));
        panel_children[0] = .{
            .kind = .{ .text = self.title },
            .style = .{ .text = .{ .font_size = self.theme.font_size + 4, .font_weight = .semibold, .color = self.theme.text } },
            .semantics = .{ .role = .heading, .label = self.title },
        };
        panel_children[1] = self.content;
        if (self.footer) |footer| panel_children[2] = footer;
        const overlay_children = try ctx.allocator.alloc(node.Spec, 2);
        overlay_children[0] = .{
            .kind = .container,
            .style = .{
                .layout = .{ .position = .absolute, .width = .{ .percent = 1 }, .height = .{ .percent = 1 } },
                .paint = .{ .background = .{ .solid = geometry.Color.rgba(0, 0, 0, 0.58) } },
                .interaction = .{ .cursor = .default },
            },
            .handlers = backdrop_handlers,
        };
        overlay_children[1] = .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .width = .{ .points = self.width },
                    .max_width = .{ .percent = 0.92 },
                    .max_height = .{ .percent = 0.9 },
                    .direction = .column,
                    .gap = .{ .height = self.theme.spacing * 2 },
                    .padding = .{ .left = .{ .points = 20 }, .right = .{ .points = 20 }, .top = .{ .points = 18 }, .bottom = .{ .points = 18 } },
                    .overflow_y = .scroll,
                },
                .paint = .{
                    .background = .{ .solid = self.theme.surface },
                    .border = .{ .widths = geometry.Insets.all(1), .color = self.theme.border },
                    .radii = geometry.CornerRadii.all(self.theme.radius + 2),
                    .shadows = try @import("../compose/style.zig").Shadows.from(&.{.{ .color = geometry.Color.rgba(0, 0, 0, 0.5), .offset = .{ .y = 10 }, .blur_radius = 32 }}),
                },
                .interaction = .{ .focusable = true, .focus_scope = true, .trap_focus = true, .autofocus = true },
            },
            .handlers = panel_handlers,
            .semantics = .{ .role = .dialog, .label = self.title, .actions = panel_actions },
            .children = panel_children,
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .position = .absolute,
                    .portal = .{
                        .target = .viewport,
                        .placement = .fill,
                        .viewport_margin = 0,
                        .order = @import("../layout/style.zig").PortalStyle.Order.modal,
                    },
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .align_items = .center,
                    .justify_content = .center,
                },
            },
            .children = overlay_children,
        };
    }

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const target: *HandlerTarget = @ptrCast(@alignCast(context));
        const self = target.owner;
        switch (event.*) {
            .pointer_down => |pointer| if (target.kind == .backdrop and pointer.button == .primary) {
                target.pressed_pointer = pointer.pointer_id;
                dispatch.handled = true;
                dispatch.capturePointer(dispatch.current);
            },
            .pointer_up => |pointer| if (target.kind == .backdrop and pointer.button == .primary and target.pressed_pointer == pointer.pointer_id) {
                target.pressed_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
                if (self.dismiss_on_backdrop and ctx.contains(pointer.position)) try self.close(ctx);
            },
            .pointer_cancel => |pointer| if (target.kind == .backdrop and target.pressed_pointer == pointer.pointer_id) {
                target.pressed_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
            },
            .key_down => |key| if (self.dismiss_on_escape and key.key == .escape and !key.repeat) {
                dispatch.handled = true;
                dispatch.preventDefault();
                try self.close(ctx);
            },
            .accessibility => |request| if (request.action == .focus) {
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
            },
            else => {},
        }
    }

    fn close(self: *Dialog, ctx: *input.Context) Error!void {
        if (!self.open.*) return;
        self.backdrop.pressed_pointer = null;
        self.panel.pressed_pointer = null;
        self.open.* = false;
        try ctx.invalidate(.{});
        if (self.on_close) |callback| try callback.call(ctx);
    }
};
