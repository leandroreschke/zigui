const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const Select = struct {
    allocator: std.mem.Allocator,
    options: []const []const u8,
    selected_index: *usize,
    placeholder: []const u8 = "Select",
    label: []const u8 = "",
    on_change: ?Callback = null,
    theme: *const Theme = &Theme.dark,
    disabled: bool = false,
    open: bool = false,
    maximum_options: usize = 4_096,
    slots: std.ArrayList(*Slot) = .empty,
    button_slot: Slot = .{ .kind = .button },
    backdrop_slot: Slot = .{ .kind = .backdrop },

    const Slot = struct {
        owner: *Select = undefined,
        kind: Kind,
        index: usize = 0,
        pressed_pointer: ?u64 = null,
        const Kind = enum { button, backdrop, option };
    };

    pub fn init(allocator: std.mem.Allocator, options: []const []const u8, selected_index: *usize) Error!Select {
        var self: Select = .{ .allocator = allocator, .options = options, .selected_index = selected_index };
        try self.ensureSlots();
        return self;
    }

    pub fn deinit(self: *Select) void {
        for (self.slots.items) |slot| self.allocator.destroy(slot);
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn build(self: *Select, ctx: *component.BuildContext) Error!node.Spec {
        try self.ensureSlots();
        if (self.disabled) {
            self.open = false;
            self.clearPresses();
        }
        self.button_slot.owner = self;
        self.backdrop_slot.owner = self;
        const selected_valid = self.selected_index.* < self.options.len;
        const selected_label = if (selected_valid) self.options[self.selected_index.*] else self.placeholder;
        const button_children = try ctx.allocator.alloc(node.Spec, 2 + 2 * @as(usize, @intFromBool(self.open)));
        button_children[0] = .{
            .kind = .{ .text = selected_label },
            .style = .{ .layout = .{ .flex_grow = 1 }, .text = .{ .font_size = self.theme.font_size, .color = if (selected_valid) self.theme.text else self.theme.muted_text } },
        };
        button_children[1] = .{
            .kind = .{ .text = if (self.open) "▴" else "▾" },
            .style = .{ .text = .{ .font_size = 12, .color = self.theme.muted_text } },
        };
        if (self.open) {
            button_children[2] = try self.dismissSurface(ctx);
            button_children[3] = try self.menu(ctx);
        }
        const button_handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = &self.button_slot, .callback = handle }});
        const available_actions: []const a11y.Action = if (self.disabled) &.{} else &.{ .activate, .show_menu };
        const button_actions = try ctx.allocator.dupe(a11y.Action, available_actions);
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .direction = .row,
                    .height = .{ .points = self.theme.control_height },
                    .min_width = .{ .points = 140 },
                    .gap = .{ .width = 10 },
                    .padding = .{ .left = .{ .points = 10 }, .right = .{ .points = 10 }, .top = .{ .points = 6 }, .bottom = .{ .points = 6 } },
                    .align_items = .center,
                },
                .paint = .{
                    .background = .{ .solid = self.theme.surface },
                    .border = .{ .widths = geometry.Insets.all(if (self.open) self.theme.focus_ring_width else 1), .color = if (self.open) self.theme.accent else self.theme.border },
                    .radii = geometry.CornerRadii.all(self.theme.radius),
                    .opacity = if (self.disabled) self.theme.disabled_opacity else 1,
                },
                .interaction = .{ .focusable = true, .cursor = if (self.disabled) .not_allowed else .pointer, .disabled = self.disabled },
            },
            .handlers = button_handlers,
            .semantics = .{
                .role = .button,
                .label = self.label,
                .value = selected_label,
                .expanded = self.open,
                .disabled = self.disabled,
                .actions = button_actions,
            },
            .children = button_children,
        };
    }

    fn dismissSurface(self: *Select, ctx: *component.BuildContext) Error!node.Spec {
        const handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = &self.backdrop_slot, .callback = handle }});
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .position = .absolute,
                    .portal = .{
                        .target = .viewport,
                        .placement = .fill,
                        .viewport_margin = 0,
                        .order = @import("../layout/style.zig").PortalStyle.Order.popover,
                    },
                },
                .interaction = .{ .cursor = .default },
            },
            .handlers = handlers,
        };
    }

    fn menu(self: *Select, ctx: *component.BuildContext) Error!node.Spec {
        const options = try ctx.allocator.alloc(node.Spec, self.options.len);
        for (self.options, 0..) |label, index| {
            const slot = self.slots.items[index];
            slot.owner = self;
            slot.kind = .option;
            slot.index = index;
            const selected = self.selected_index.* == index;
            const handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = slot, .callback = handle }});
            const actions = try ctx.allocator.dupe(a11y.Action, &.{.activate});
            const option_children = try ctx.allocator.alloc(node.Spec, 2);
            option_children[0] = .{ .kind = .{ .text = if (selected) "✓" else "" }, .style = .{ .layout = .{ .width = .{ .points = 16 } }, .text = .{ .font_size = 13, .color = self.theme.accent } } };
            option_children[1] = .{ .kind = .{ .text = label }, .style = .{ .text = .{ .font_size = self.theme.font_size, .color = self.theme.text } } };
            options[index] = .{
                .key = @intCast(index + 1),
                .kind = .container,
                .style = .{
                    .layout = .{
                        .direction = .row,
                        .gap = .{ .width = 6 },
                        .height = .{ .points = self.theme.control_height },
                        .padding = .{ .left = .{ .points = 8 }, .right = .{ .points = 8 }, .top = .{ .points = 5 }, .bottom = .{ .points = 5 } },
                        .align_items = .center,
                    },
                    .paint = .{ .background = .{ .solid = if (selected) self.theme.surface_pressed else .transparent } },
                    .interaction = .{ .focusable = true, .cursor = .pointer },
                },
                .handlers = handlers,
                .semantics = .{ .role = .menu_item_radio, .label = label, .checked = selected, .selected = selected, .actions = actions },
                .children = option_children,
            };
        }
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .position = .absolute,
                    .portal = .{
                        .target = .anchor,
                        .placement = .below,
                        .alignment = .start,
                        .anchor_width = .minimum,
                        .gap = 4,
                        .order = @import("../layout/style.zig").PortalStyle.Order.popover + 1,
                    },
                    .min_width = .{ .points = 140 },
                    .direction = .column,
                    .padding = .{ .top = .{ .points = 4 }, .bottom = .{ .points = 4 }, .left = .{ .points = 4 }, .right = .{ .points = 4 } },
                },
                .paint = .{
                    .background = .{ .solid = self.theme.surface },
                    .border = .{ .widths = geometry.Insets.all(1), .color = self.theme.border },
                    .radii = geometry.CornerRadii.all(self.theme.radius),
                    .shadows = try @import("../compose/style.zig").Shadows.from(&.{.{ .color = geometry.Color.rgba(0, 0, 0, 0.35), .offset = .{ .y = 4 }, .blur_radius = 12 }}),
                },
            },
            .semantics = .{ .role = .menu },
            .children = options,
        };
    }

    fn ensureSlots(self: *Select) Error!void {
        if (self.options.len > self.maximum_options) return error.BudgetExceeded;
        if (self.options.len < self.slots.items.len) {
            for (self.slots.items[self.options.len..]) |slot| slot.pressed_pointer = null;
        }
        const original_len = self.slots.items.len;
        errdefer while (self.slots.items.len > original_len) self.allocator.destroy(self.slots.pop().?);
        while (self.slots.items.len < self.options.len) {
            const slot = try self.allocator.create(Slot);
            slot.* = .{ .kind = .option };
            self.slots.append(self.allocator, slot) catch |err| {
                self.allocator.destroy(slot);
                return err;
            };
        }
    }

    fn clearPresses(self: *Select) void {
        self.button_slot.pressed_pointer = null;
        self.backdrop_slot.pressed_pointer = null;
        for (self.slots.items) |slot| slot.pressed_pointer = null;
    }

    fn move(self: *Select, delta: i8, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        if (self.options.len == 0) return;
        const next = if (self.selected_index.* >= self.options.len)
            if (delta > 0) 0 else self.options.len - 1
        else if (delta > 0)
            (self.selected_index.* + 1) % self.options.len
        else if (self.selected_index.* == 0)
            self.options.len - 1
        else
            self.selected_index.* - 1;
        try self.choose(next, dispatch, ctx, false);
    }

    fn choose(self: *Select, index: usize, dispatch: *input.Dispatch, ctx: *input.Context, close: bool) Error!void {
        if (index >= self.options.len) return;
        const changed = self.selected_index.* != index;
        self.selected_index.* = index;
        if (close) self.open = false;
        dispatch.handled = true;
        dispatch.preventDefault();
        try ctx.invalidate(.{});
        if (changed) if (self.on_change) |callback| try callback.call(ctx);
    }

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const slot: *Slot = @ptrCast(@alignCast(context));
        const self = slot.owner;
        if (self.disabled) {
            switch (event.*) {
                .pointer_up, .pointer_cancel => |pointer| if (slot.pressed_pointer == pointer.pointer_id) {
                    slot.pressed_pointer = null;
                    dispatch.releasePointer();
                    dispatch.handled = true;
                },
                else => {},
            }
            return;
        }
        if (slot.kind == .backdrop) {
            switch (event.*) {
                .pointer_down => |pointer| if (pointer.button == .primary) {
                    slot.pressed_pointer = pointer.pointer_id;
                    dispatch.capturePointer(dispatch.current);
                    dispatch.handled = true;
                },
                .pointer_up => |pointer| if (pointer.button == .primary and slot.pressed_pointer == pointer.pointer_id) {
                    slot.pressed_pointer = null;
                    dispatch.releasePointer();
                    self.open = false;
                    dispatch.handled = true;
                    try ctx.invalidate(.{});
                },
                .pointer_cancel => |pointer| if (slot.pressed_pointer == pointer.pointer_id) {
                    slot.pressed_pointer = null;
                    dispatch.releasePointer();
                    dispatch.handled = true;
                },
                else => {},
            }
            return;
        }
        if (slot.kind == .option) {
            switch (event.*) {
                .pointer_down => |pointer| if (pointer.button == .primary) {
                    slot.pressed_pointer = pointer.pointer_id;
                    dispatch.capturePointer(dispatch.current);
                    dispatch.requestFocus(dispatch.current);
                    dispatch.handled = true;
                },
                .pointer_up => |pointer| if (pointer.button == .primary and slot.pressed_pointer == pointer.pointer_id) {
                    slot.pressed_pointer = null;
                    dispatch.releasePointer();
                    dispatch.handled = true;
                    if (ctx.contains(pointer.position)) try self.choose(slot.index, dispatch, ctx, true);
                },
                .pointer_cancel => |pointer| if (slot.pressed_pointer == pointer.pointer_id) {
                    slot.pressed_pointer = null;
                    dispatch.releasePointer();
                    dispatch.handled = true;
                },
                .key_down => |key| if (!key.repeat and (key.key == .enter or key.key == .space)) try self.choose(slot.index, dispatch, ctx, true),
                .accessibility => |request| if (request.action == .activate) try self.choose(slot.index, dispatch, ctx, true),
                else => {},
            }
            return;
        }
        if (dispatch.handled) {
            if (!self.open) dispatch.requestFocus(dispatch.current);
            return;
        }
        switch (event.*) {
            .pointer_down => |pointer| if (pointer.button == .primary) {
                slot.pressed_pointer = pointer.pointer_id;
                dispatch.capturePointer(dispatch.current);
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
            },
            .pointer_up => |pointer| if (pointer.button == .primary and slot.pressed_pointer == pointer.pointer_id) {
                slot.pressed_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
                if (ctx.contains(pointer.position)) {
                    self.open = !self.open;
                    try ctx.invalidate(.{});
                }
            },
            .pointer_cancel => |pointer| if (slot.pressed_pointer == pointer.pointer_id) {
                slot.pressed_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
            },
            .key_down => |key| if (!key.repeat) switch (key.key) {
                .enter, .space => {
                    self.open = !self.open;
                    dispatch.handled = true;
                    dispatch.preventDefault();
                    try ctx.invalidate(.{});
                },
                .escape => if (self.open) {
                    self.open = false;
                    dispatch.requestFocus(dispatch.current);
                    dispatch.handled = true;
                    dispatch.preventDefault();
                    try ctx.invalidate(.{});
                },
                .arrow_down => try self.move(1, dispatch, ctx),
                .arrow_up => try self.move(-1, dispatch, ctx),
                .home => try self.choose(0, dispatch, ctx, false),
                .end => if (self.options.len != 0) try self.choose(self.options.len - 1, dispatch, ctx, false),
                else => {},
            },
            .accessibility => |request| if (request.action == .activate or request.action == .show_menu) {
                self.open = true;
                dispatch.handled = true;
                try ctx.invalidate(.{});
            },
            else => {},
        }
    }
};
