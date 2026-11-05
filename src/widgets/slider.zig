const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const Slider = struct {
    value: *f64,
    minimum: f64 = 0,
    maximum: f64 = 1,
    step: f64 = 0.01,
    on_change: ?Callback = null,
    theme: *const Theme = &Theme.dark,
    disabled: bool = false,
    dragging: bool = false,
    dragging_pointer: ?u64 = null,

    pub fn build(self: *Slider, ctx: *component.BuildContext) Error!node.Spec {
        if (self.disabled) {
            self.dragging = false;
            self.dragging_pointer = null;
        }
        try self.validateConfiguration();
        const fraction_value = self.fraction();
        const effective_value = std.math.clamp(self.value.*, self.minimum, self.maximum);
        const track_children = try ctx.allocator.alloc(node.Spec, 3);
        track_children[0] = .{
            .kind = .container,
            .style = .{
                .layout = .{ .position = .absolute, .width = .{ .percent = @floatCast(fraction_value) }, .height = .{ .points = 4 }, .inset = .{ .top = .{ .points = 8 }, .left = .{ .points = 0 }, .right = .auto, .bottom = .auto } },
                .paint = .{ .background = .{ .solid = self.theme.accent }, .radii = geometry.CornerRadii.all(2) },
            },
        };
        track_children[1] = .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .position = .absolute,
                    .width = .{ .points = 16 },
                    .height = .{ .points = 16 },
                    .inset = .{ .left = .{ .percent = @floatCast(fraction_value) }, .top = .{ .points = 2 }, .right = .auto, .bottom = .auto },
                },
                .paint = .{
                    .background = .{ .solid = geometry.Color.white },
                    .border = .{ .widths = geometry.Insets.all(1), .color = self.theme.border },
                    .radii = geometry.CornerRadii.all(8),
                    .shadows = try @import("../compose/style.zig").Shadows.from(&.{.{ .color = geometry.Color.rgba(0, 0, 0, 0.25), .offset = .{ .y = 1 }, .blur_radius = 2 }}),
                },
            },
        };
        // A full-height containing box keeps absolute thumbs from being
        // constrained to the four-point track during layout measurement.
        track_children[2] = track_children[0];
        track_children[2].style.layout.width = .{ .percent = 1 };
        track_children[2].style.paint.background = .{ .solid = self.theme.surface_pressed };
        const background = track_children[2];
        track_children[2] = track_children[1];
        track_children[1] = track_children[0];
        track_children[0] = background;
        const handlers = try ctx.allocator.alloc(input.Handler, 1);
        handlers[0] = .{ .context = self, .callback = handle };
        const available_actions: []const a11y.Action = if (self.disabled) &.{} else &.{ .increment, .decrement, .set_value };
        const actions = try ctx.allocator.dupe(a11y.Action, available_actions);
        var value_buffer: [64]u8 = undefined;
        const value_text = std.fmt.bufPrint(&value_buffer, "{d}", .{effective_value}) catch "";
        const children = try ctx.allocator.alloc(node.Spec, 1);
        children[0] = .{
            .kind = .container,
            .style = .{
                .layout = .{ .width = .{ .percent = 1 }, .height = .{ .points = 20 } },
            },
            .children = track_children,
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{ .height = .{ .points = 20 }, .align_items = .center },
                .paint = .{ .opacity = if (self.disabled) self.theme.disabled_opacity else 1 },
                .interaction = .{ .focusable = true, .cursor = if (self.disabled) .not_allowed else .pointer, .disabled = self.disabled },
            },
            .handlers = handlers,
            .semantics = .{
                .role = .slider,
                .value = try ctx.allocator.dupe(u8, value_text),
                .range_min = self.minimum,
                .range_max = self.maximum,
                .range_value = effective_value,
                .actions = actions,
                .disabled = self.disabled,
            },
            .children = children,
        };
    }

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const self: *Slider = @ptrCast(@alignCast(context));
        if (self.disabled) {
            switch (event.*) {
                .pointer_up, .pointer_cancel => |pointer| if (self.dragging_pointer == pointer.pointer_id) {
                    self.dragging = false;
                    self.dragging_pointer = null;
                    dispatch.releasePointer();
                    dispatch.handled = true;
                },
                else => {},
            }
            return;
        }
        switch (event.*) {
            .pointer_down => |pointer| if (pointer.button == .primary) {
                self.dragging = true;
                self.dragging_pointer = pointer.pointer_id;
                dispatch.capturePointer(dispatch.current);
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
                try self.setFromPosition(pointer.position, ctx, dispatch);
            },
            .pointer_move => |pointer| if (self.dragging_pointer == pointer.pointer_id) {
                dispatch.handled = true;
                try self.setFromPosition(pointer.position, ctx, dispatch);
            },
            .pointer_up, .pointer_cancel => |pointer| if (self.dragging_pointer == pointer.pointer_id) {
                self.dragging = false;
                self.dragging_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
            },
            .key_down => |key| switch (key.key) {
                .arrow_left, .arrow_down => try self.adjust(-self.step, ctx, dispatch),
                .arrow_right, .arrow_up => try self.adjust(self.step, ctx, dispatch),
                .home => try self.set(self.minimum, ctx, dispatch),
                .end => try self.set(self.maximum, ctx, dispatch),
                else => {},
            },
            .accessibility => |request| switch (request.action) {
                .increment => try self.adjust(self.step, ctx, dispatch),
                .decrement => try self.adjust(-self.step, ctx, dispatch),
                .set_value => if (request.value) |value| {
                    const parsed = std.fmt.parseFloat(f64, value) catch return;
                    try self.set(parsed, ctx, dispatch);
                },
                else => {},
            },
            else => {},
        }
    }

    fn setFromPosition(self: *Slider, point: geometry.Point, ctx: *input.Context, dispatch: *input.Dispatch) Error!void {
        const local = ctx.localPoint(point);
        const fraction_value = std.math.clamp((local.x - ctx.current_layout_bounds.origin.x) / @max(ctx.current_layout_bounds.size.width, 0.0001), 0, 1);
        try self.set(self.minimum + fraction_value * (self.maximum - self.minimum), ctx, dispatch);
    }

    fn adjust(self: *Slider, delta: f64, ctx: *input.Context, dispatch: *input.Dispatch) Error!void {
        try self.set(self.value.* + delta, ctx, dispatch);
    }

    fn set(self: *Slider, raw: f64, ctx: *input.Context, dispatch: *input.Dispatch) Error!void {
        try self.validateConfiguration();
        if (!std.math.isFinite(raw)) return error.InvalidConfiguration;
        const stepped = if (self.step > 0) self.minimum + @round((raw - self.minimum) / self.step) * self.step else raw;
        const next = std.math.clamp(stepped, self.minimum, self.maximum);
        dispatch.handled = true;
        dispatch.preventDefault();
        if (next == self.value.*) return;
        self.value.* = next;
        try ctx.invalidate(.{});
        if (self.on_change) |callback| try callback.call(ctx);
    }

    fn validateConfiguration(self: *const Slider) Error!void {
        if (!std.math.isFinite(self.minimum) or !std.math.isFinite(self.maximum) or
            !std.math.isFinite(self.step) or !std.math.isFinite(self.value.*) or
            self.maximum < self.minimum or self.step < 0)
            return error.InvalidConfiguration;
    }

    fn fraction(self: *const Slider) f64 {
        if (self.maximum <= self.minimum) return 0;
        return std.math.clamp((self.value.* - self.minimum) / (self.maximum - self.minimum), 0, 1);
    }
};
