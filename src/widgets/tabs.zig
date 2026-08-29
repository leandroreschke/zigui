const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const Tabs = struct {
    allocator: std.mem.Allocator,
    labels: []const []const u8,
    selected_index: *usize,
    panels: []const node.Spec = &.{},
    on_change: ?Callback = null,
    theme: *const Theme = &Theme.dark,
    disabled: ?[]const bool = null,
    maximum_items: usize = 4_096,
    slots: std.ArrayList(*Slot) = .empty,

    const Slot = struct {
        owner: *Tabs = undefined,
        index: usize = 0,
        pressed_pointer: ?u64 = null,
    };

    pub fn init(allocator: std.mem.Allocator, labels: []const []const u8, selected_index: *usize) Error!Tabs {
        var self: Tabs = .{ .allocator = allocator, .labels = labels, .selected_index = selected_index };
        try self.ensureSlots(labels.len);
        return self;
    }

    pub fn deinit(self: *Tabs) void {
        for (self.slots.items) |slot| self.allocator.destroy(slot);
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn build(self: *Tabs, ctx: *component.BuildContext) Error!node.Spec {
        try self.ensureSlots(self.labels.len);
        const effective_selected = self.effectiveSelected();
        const tab_nodes = try ctx.allocator.alloc(node.Spec, self.labels.len);
        for (self.labels, 0..) |label, index| {
            const slot = self.slots.items[index];
            slot.owner = self;
            slot.index = index;
            const selected = effective_selected != null and effective_selected.? == index;
            const disabled = self.isDisabled(index);
            if (disabled) slot.pressed_pointer = null;
            const handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = slot, .callback = handle }});
            const available_actions: []const a11y.Action = if (disabled) &.{} else &.{.activate};
            const actions = try ctx.allocator.dupe(a11y.Action, available_actions);
            const label_children = try ctx.allocator.dupe(node.Spec, &.{node.Spec{
                .kind = .{ .text = label },
                .style = .{ .text = .{ .font_families = self.theme.font_families, .font_size = self.theme.font_size, .color = if (selected) self.theme.text else self.theme.muted_text } },
            }});
            tab_nodes[index] = .{
                .key = @intCast(index + 1),
                .kind = .container,
                .style = .{
                    .layout = .{
                        .height = .{ .points = self.theme.control_height },
                        .padding = .{ .left = .{ .points = 12 }, .right = .{ .points = 12 }, .top = .{ .points = 6 }, .bottom = .{ .points = 6 } },
                        .align_items = .center,
                        .justify_content = .center,
                    },
                    .paint = .{
                        .background = .{ .solid = if (selected) self.theme.surface_pressed else .transparent },
                        .border = .{ .widths = .{ .bottom = if (selected) 2 else 0 }, .color = self.theme.accent },
                        .radii = geometry.CornerRadii.all(self.theme.radius),
                        .opacity = if (disabled) self.theme.disabled_opacity else 1,
                    },
                    // Tabs use roving focus: only the selected tab participates
                    // in sequential focus navigation. Selecting another tab
                    // removes the old candidate during reconciliation and the
                    // new autofocus identity receives focus atomically.
                    .interaction = .{
                        .focusable = true,
                        .tab_index = if (selected) 0 else -1,
                        .autofocus = selected,
                        .cursor = if (disabled) .not_allowed else .pointer,
                        .disabled = disabled,
                    },
                },
                .handlers = handlers,
                .semantics = .{ .role = .tab, .label = label, .selected = selected, .disabled = disabled, .actions = actions },
                .children = label_children,
            };
        }
        const panel_index = effective_selected orelse self.panels.len;
        const root_children = try ctx.allocator.alloc(node.Spec, 1 + @as(usize, @intFromBool(panel_index < self.panels.len)));
        root_children[0] = .{
            .kind = .container,
            .style = .{ .layout = .{ .direction = .row, .gap = .{ .width = 2 }, .align_items = .center } },
            .semantics = .{ .role = .tab_list },
            .children = tab_nodes,
        };
        if (root_children.len == 2) {
            var panel = self.panels[panel_index];
            panel.semantics.role = .tab_panel;
            root_children[1] = panel;
        }
        return .{
            .kind = .container,
            .style = .{ .layout = .{ .direction = .column, .gap = .{ .height = self.theme.spacing } } },
            .children = root_children,
        };
    }

    fn ensureSlots(self: *Tabs, count: usize) Error!void {
        if (count > self.maximum_items) return error.BudgetExceeded;
        if (count < self.slots.items.len) {
            for (self.slots.items[count..]) |slot| slot.pressed_pointer = null;
        }
        const original_len = self.slots.items.len;
        errdefer while (self.slots.items.len > original_len) self.allocator.destroy(self.slots.pop().?);
        while (self.slots.items.len < count) {
            const slot = try self.allocator.create(Slot);
            slot.* = .{};
            self.slots.append(self.allocator, slot) catch |err| {
                self.allocator.destroy(slot);
                return err;
            };
        }
    }

    fn effectiveSelected(self: *const Tabs) ?usize {
        if (self.selected_index.* < self.labels.len and !self.isDisabled(self.selected_index.*))
            return self.selected_index.*;
        return self.firstEnabled();
    }

    fn isDisabled(self: *const Tabs, index: usize) bool {
        return if (self.disabled) |disabled| index < disabled.len and disabled[index] else false;
    }

    fn firstEnabled(self: *const Tabs) ?usize {
        for (self.labels, 0..) |_, index| if (!self.isDisabled(index)) return index;
        return null;
    }

    fn nextEnabled(self: *const Tabs, start: usize, direction: i8) ?usize {
        if (self.labels.len == 0) return null;
        var index = start;
        var visited: usize = 0;
        while (visited < self.labels.len) : (visited += 1) {
            index = if (direction > 0) (index + 1) % self.labels.len else if (index == 0) self.labels.len - 1 else index - 1;
            if (!self.isDisabled(index)) return index;
        }
        return null;
    }

    fn select(self: *Tabs, index: usize, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        if (index >= self.labels.len or self.isDisabled(index)) return;
        const changed = self.selected_index.* != index;
        self.selected_index.* = index;
        dispatch.handled = true;
        dispatch.preventDefault();
        if (changed) {
            dispatch.requestAutofocusAfterReconcile();
            try ctx.invalidate(.{});
            if (self.on_change) |callback| try callback.call(ctx);
        } else dispatch.requestFocus(dispatch.current);
    }

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const slot: *Slot = @ptrCast(@alignCast(context));
        const self = slot.owner;
        if (self.isDisabled(slot.index)) {
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
                if (ctx.contains(pointer.position)) try self.select(slot.index, dispatch, ctx);
            },
            .pointer_cancel => |pointer| if (slot.pressed_pointer == pointer.pointer_id) {
                slot.pressed_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
            },
            .key_down => |key| if (!key.repeat) switch (key.key) {
                .enter, .space => try self.select(slot.index, dispatch, ctx),
                .arrow_left, .arrow_up => if (self.nextEnabled(slot.index, -1)) |index| try self.select(index, dispatch, ctx),
                .arrow_right, .arrow_down => if (self.nextEnabled(slot.index, 1)) |index| try self.select(index, dispatch, ctx),
                .home => if (self.firstEnabled()) |index| try self.select(index, dispatch, ctx),
                .end => {
                    var index = self.labels.len;
                    while (index > 0) {
                        index -= 1;
                        if (!self.isDisabled(index)) {
                            try self.select(index, dispatch, ctx);
                            break;
                        }
                    }
                },
                else => {},
            },
            .accessibility => |request| if (request.action == .activate) try self.select(slot.index, dispatch, ctx),
            else => {},
        }
    }
};
