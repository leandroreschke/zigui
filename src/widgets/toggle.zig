const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const Kind = enum { checkbox, switch_control };

pub const Toggle = struct {
    label: []const u8,
    value: *bool,
    on_change: ?Callback = null,
    theme: *const Theme = &Theme.dark,
    kind: Kind = .checkbox,
    disabled: bool = false,
    hovered: bool = false,
    pressed_pointer: ?u64 = null,

    pub fn build(self: *Toggle, ctx: *component.BuildContext) Error!node.Spec {
        if (self.disabled) {
            self.hovered = false;
            self.pressed_pointer = null;
        }
        const children = try ctx.allocator.alloc(node.Spec, 2);
        children[0] = if (self.kind == .checkbox) try self.checkbox(ctx) else try self.switchControl(ctx);
        children[1] = .{
            .kind = .{ .text = self.label },
            .style = .{ .text = .{ .font_size = self.theme.font_size, .color = self.theme.text } },
        };
        const handlers = try ctx.allocator.alloc(input.Handler, 1);
        handlers[0] = .{ .context = self, .callback = handle };
        const available_actions: []const a11y.Action = if (self.disabled) &.{} else &.{.activate};
        const actions = try ctx.allocator.dupe(a11y.Action, available_actions);
        return .{
            .kind = .container,
            .style = .{
                .layout = .{ .direction = .row, .gap = .{ .width = 8 }, .align_items = .center },
                .paint = .{ .opacity = if (self.disabled) self.theme.disabled_opacity else 1 },
                .interaction = .{ .focusable = true, .cursor = if (self.disabled) .not_allowed else .pointer, .disabled = self.disabled },
            },
            .handlers = handlers,
            .semantics = .{
                .role = if (self.kind == .checkbox) .checkbox else .switch_control,
                .label = self.label,
                .checked = self.value.*,
                .disabled = self.disabled,
                .actions = actions,
            },
            .children = children,
        };
    }

    fn checkbox(self: *Toggle, ctx: *component.BuildContext) Error!node.Spec {
        const mark = try ctx.allocator.alloc(node.Spec, 1);
        mark[0] = .{
            .kind = .{ .text = if (self.value.*) "✓" else "" },
            .style = .{ .text = .{ .font_size = 13, .color = geometry.Color.white } },
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{ .width = .{ .points = 18 }, .height = .{ .points = 18 }, .align_items = .center, .justify_content = .center },
                .paint = .{
                    .background = .{ .solid = if (self.value.*) self.theme.accent else if (self.hovered) self.theme.surface_hovered else self.theme.surface },
                    .border = .{ .widths = geometry.Insets.all(1), .color = if (self.value.*) self.theme.accent else self.theme.border },
                    .radii = geometry.CornerRadii.all(4),
                },
            },
            .children = mark,
        };
    }

    fn switchControl(self: *Toggle, ctx: *component.BuildContext) Error!node.Spec {
        const knob = try ctx.allocator.alloc(node.Spec, 1);
        knob[0] = .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .position = .absolute,
                    .width = .{ .points = 16 },
                    .height = .{ .points = 16 },
                    .inset = .{
                        .left = .{ .points = if (self.value.*) 18 else 2 },
                        .top = .{ .points = 2 },
                        .right = .auto,
                        .bottom = .auto,
                    },
                },
                .paint = .{ .background = .{ .solid = geometry.Color.white }, .radii = geometry.CornerRadii.all(8) },
            },
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{ .width = .{ .points = 36 }, .height = .{ .points = 20 } },
                .paint = .{
                    .background = .{ .solid = if (self.value.*) self.theme.accent else self.theme.surface_pressed },
                    .radii = geometry.CornerRadii.all(10),
                },
            },
            .children = knob,
        };
    }

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const self: *Toggle = @ptrCast(@alignCast(context));
        if (self.disabled) {
            switch (event.*) {
                .pointer_up, .pointer_cancel => |pointer| if (self.pressed_pointer == pointer.pointer_id) {
                    self.pressed_pointer = null;
                    dispatch.releasePointer();
                    dispatch.handled = true;
                },
                else => {},
            }
            return;
        }
        switch (event.*) {
            .pointer_enter => {
                self.hovered = true;
                try ctx.invalidate(.{});
            },
            .pointer_leave => {
                self.hovered = false;
                try ctx.invalidate(.{});
            },
            .pointer_down => |pointer| if (pointer.button == .primary) {
                self.pressed_pointer = pointer.pointer_id;
                dispatch.capturePointer(dispatch.current);
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
            },
            .pointer_up => |pointer| if (pointer.button == .primary and self.pressed_pointer == pointer.pointer_id) {
                self.pressed_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
                if (ctx.contains(pointer.position)) try self.toggle(dispatch, ctx);
            },
            .pointer_cancel => |pointer| if (self.pressed_pointer == pointer.pointer_id) {
                self.pressed_pointer = null;
                self.hovered = false;
                dispatch.releasePointer();
                dispatch.handled = true;
                try ctx.invalidate(.{});
            },
            .key_down => |key| if (!key.repeat and (key.key == .space or key.key == .enter)) try self.toggle(dispatch, ctx),
            .accessibility => |request| if (request.action == .activate) try self.toggle(dispatch, ctx),
            else => {},
        }
    }

    fn toggle(self: *Toggle, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        self.value.* = !self.value.*;
        dispatch.handled = true;
        dispatch.preventDefault();
        try ctx.invalidate(.{});
        if (self.on_change) |callback| try callback.call(ctx);
    }
};
