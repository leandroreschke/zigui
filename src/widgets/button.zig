const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const Variant = enum { normal, primary, destructive, quiet };

pub const Button = struct {
    label: []const u8,
    on_activate: Callback,
    theme: *const Theme = &Theme.dark,
    variant: Variant = .normal,
    disabled: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    pressed_pointer: ?u64 = null,

    pub fn build(self: *Button, ctx: *component.BuildContext) Error!node.Spec {
        if (self.disabled) {
            self.hovered = false;
            self.pressed = false;
            self.focused = false;
            self.pressed_pointer = null;
        }
        const children = try ctx.allocator.alloc(node.Spec, 1);
        children[0] = .{
            .kind = .{ .text = self.label },
            .style = .{ .text = .{
                .font_families = self.theme.font_families,
                .font_size = self.theme.font_size,
                .color = self.theme.text,
                .wrap = .none,
                .maximum_lines = 1,
            } },
        };
        const handlers = try ctx.allocator.alloc(input.Handler, 1);
        handlers[0] = .{ .context = self, .callback = handle };
        const available_actions: []const a11y.Action = if (self.disabled) &.{} else &.{.activate};
        const actions = try ctx.allocator.dupe(a11y.Action, available_actions);
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .direction = .row,
                    .height = .{ .points = self.theme.control_height },
                    .padding = .{
                        .left = .{ .points = 12 },
                        .right = .{ .points = 12 },
                        .top = .{ .points = 6 },
                        .bottom = .{ .points = 6 },
                    },
                    .align_items = .center,
                    .justify_content = .center,
                },
                .paint = .{
                    .background = .{ .solid = self.background() },
                    .border = .{
                        .widths = geometry.Insets.all(if (self.focused) self.theme.focus_ring_width else if (self.variant == .quiet) 0 else 1),
                        .color = if (self.focused) self.theme.focus_ring else self.theme.border,
                    },
                    .radii = geometry.CornerRadii.all(self.theme.radius),
                    .opacity = if (self.disabled) self.theme.disabled_opacity else 1,
                },
                .interaction = .{ .cursor = if (self.disabled) .not_allowed else .pointer, .focusable = !self.disabled, .disabled = self.disabled },
            },
            .handlers = handlers,
            .semantics = .{
                .role = .button,
                .label = self.label,
                .actions = actions,
                .disabled = self.disabled,
            },
            .children = children,
        };
    }

    fn background(self: *const Button) geometry.Color {
        if (self.variant == .quiet and !self.hovered and !self.pressed) return .transparent;
        if (self.variant == .primary) return if (self.pressed) self.theme.accent_pressed else if (self.hovered) self.theme.accent_hovered else self.theme.accent;
        if (self.variant == .destructive) return self.theme.destructive;
        return if (self.pressed) self.theme.surface_pressed else if (self.hovered) self.theme.surface_hovered else self.theme.surface;
    }

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, value: *const input.Event, event_context: *input.Context) Error!void {
        const self: *Button = @ptrCast(@alignCast(context));
        if (self.disabled) {
            switch (value.*) {
                .pointer_up, .pointer_cancel => |pointer| if (self.pressed_pointer == pointer.pointer_id) {
                    self.pressed = false;
                    self.pressed_pointer = null;
                    dispatch.releasePointer();
                    dispatch.handled = true;
                },
                else => {},
            }
            return;
        }
        switch (value.*) {
            .focus_in => {
                self.focused = true;
                try event_context.invalidate(.{});
            },
            .focus_out => {
                self.focused = false;
                self.pressed = false;
                self.pressed_pointer = null;
                try event_context.invalidate(.{});
            },
            .pointer_enter => {
                self.hovered = true;
                try event_context.invalidate(.{});
            },
            .pointer_leave => {
                self.hovered = false;
                try event_context.invalidate(.{});
            },
            .pointer_down => |pointer| if (pointer.button == .primary) {
                self.pressed = true;
                self.pressed_pointer = pointer.pointer_id;
                dispatch.capturePointer(dispatch.current);
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
                try event_context.invalidate(.{});
            },
            .pointer_up => |pointer| if (pointer.button == .primary and self.pressed_pointer == pointer.pointer_id) {
                self.pressed = false;
                self.pressed_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
                if (event_context.contains(pointer.position)) try self.on_activate.call(event_context);
                try event_context.invalidate(.{});
            },
            .pointer_cancel => |pointer| if (self.pressed_pointer == pointer.pointer_id) {
                self.hovered = false;
                self.pressed = false;
                self.pressed_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
                try event_context.invalidate(.{});
            },
            .key_down => |key| if (!key.repeat and (key.key == .enter or key.key == .space)) {
                dispatch.handled = true;
                dispatch.preventDefault();
                try self.on_activate.call(event_context);
            },
            .accessibility => |request| if (request.action == .activate) {
                dispatch.handled = true;
                try self.on_activate.call(event_context);
            },
            else => {},
        }
    }
};
