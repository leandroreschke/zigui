const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const Radio = struct {
    label: []const u8,
    selected_index: *usize,
    index: usize,
    on_change: ?Callback = null,
    theme: *const Theme = &Theme.dark,
    disabled: bool = false,
    hovered: bool = false,
    pressed_pointer: ?u64 = null,

    pub fn build(self: *Radio, ctx: *component.BuildContext) Error!node.Spec {
        if (self.disabled) {
            self.hovered = false;
            self.pressed_pointer = null;
        }
        const selected = self.selected_index.* == self.index;
        const dot_children = try ctx.allocator.alloc(node.Spec, @intFromBool(selected));
        if (selected) dot_children[0] = .{
            .kind = .container,
            .style = .{
                .layout = .{ .width = .{ .points = 8 }, .height = .{ .points = 8 } },
                .paint = .{ .background = .{ .solid = self.theme.accent }, .radii = geometry.CornerRadii.all(4) },
            },
        };
        const children = try ctx.allocator.alloc(node.Spec, 2);
        children[0] = .{
            .kind = .container,
            .style = .{
                .layout = .{ .width = .{ .points = 18 }, .height = .{ .points = 18 }, .align_items = .center, .justify_content = .center },
                .paint = .{
                    .background = .{ .solid = if (self.hovered) self.theme.surface_hovered else self.theme.surface },
                    .border = .{ .widths = geometry.Insets.all(1), .color = if (selected) self.theme.accent else self.theme.border },
                    .radii = geometry.CornerRadii.all(9),
                },
            },
            .children = dot_children,
        };
        children[1] = .{ .kind = .{ .text = self.label }, .style = .{ .text = .{ .font_families = self.theme.font_families, .font_size = self.theme.font_size, .color = self.theme.text } } };
        const handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = self, .callback = handle }});
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
            .semantics = .{ .role = .radio, .label = self.label, .checked = selected, .disabled = self.disabled, .actions = actions },
            .children = children,
        };
    }

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const self: *Radio = @ptrCast(@alignCast(context));
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
                if (ctx.contains(pointer.position)) try self.select(dispatch, ctx);
            },
            .pointer_cancel => |pointer| if (self.pressed_pointer == pointer.pointer_id) {
                self.pressed_pointer = null;
                self.hovered = false;
                dispatch.releasePointer();
                dispatch.handled = true;
                try ctx.invalidate(.{});
            },
            .key_down => |key| if (!key.repeat and (key.key == .space or key.key == .enter)) try self.select(dispatch, ctx),
            .accessibility => |request| if (request.action == .activate) try self.select(dispatch, ctx),
            else => {},
        }
    }

    fn select(self: *Radio, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        dispatch.handled = true;
        dispatch.preventDefault();
        if (self.selected_index.* == self.index) return;
        self.selected_index.* = self.index;
        try ctx.invalidate(.{});
        if (self.on_change) |callback| try callback.call(ctx);
    }
};
