const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const custom = @import("../compose/custom.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const layout = @import("../layout/style.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const Orientation = enum { horizontal, vertical };

pub const SplitPane = struct {
    first: node.Spec,
    second: node.Spec,
    fraction: *f32,
    orientation: Orientation = .horizontal,
    minimum_first: f32 = 80,
    minimum_second: f32 = 80,
    divider_size: f32 = 6,
    on_change: ?Callback = null,
    theme: *const Theme = &Theme.dark,
    dragging: bool = false,
    dragging_pointer: ?u64 = null,
    bounds: geometry.Rect = .{},

    pub fn build(self: *SplitPane, ctx: *component.BuildContext) Error!node.Spec {
        try self.validateConfiguration();
        const effective_fraction = self.clampFraction(self.fraction.*);
        const children = try ctx.allocator.alloc(node.Spec, 3);
        children[0] = self.first;
        // A zero basis with complementary grow factors divides the space left
        // after the fixed divider. A percentage basis would divide the full
        // container and overflow at fraction == 1.
        children[0].style.layout.flex_basis = .{ .points = 0 };
        children[0].style.layout.flex_grow = effective_fraction;
        children[0].style.layout.flex_shrink = 0;
        children[0].style.layout.min_width = if (self.orientation == .horizontal) .{ .points = self.minimum_first } else children[0].style.layout.min_width;
        children[0].style.layout.min_height = if (self.orientation == .vertical) .{ .points = self.minimum_first } else children[0].style.layout.min_height;
        const handlers = try ctx.allocator.dupe(input.Handler, &.{.{ .context = self, .callback = handle }});
        const actions = try ctx.allocator.dupe(a11y.Action, &.{ .increment, .decrement, .set_value });
        children[1] = .{
            .kind = .container,
            .style = .{
                .layout = if (self.orientation == .horizontal)
                    .{ .width = .{ .points = self.divider_size }, .height = .{ .percent = 1 }, .flex_shrink = 0 }
                else
                    .{ .height = .{ .points = self.divider_size }, .width = .{ .percent = 1 }, .flex_shrink = 0 },
                .paint = .{ .background = .{ .solid = if (self.dragging) self.theme.accent else self.theme.border } },
                .interaction = .{
                    .focusable = true,
                    .cursor = if (self.orientation == .horizontal) .resize_horizontal else .resize_vertical,
                },
            },
            .handlers = handlers,
            .semantics = .{
                .role = .separator,
                .range_min = 0,
                .range_max = 1,
                .range_value = effective_fraction,
                .actions = actions,
            },
        };
        children[2] = self.second;
        children[2].style.layout.flex_basis = .{ .points = 0 };
        children[2].style.layout.flex_grow = 1 - effective_fraction;
        children[2].style.layout.flex_shrink = 0;
        children[2].style.layout.min_width = if (self.orientation == .horizontal) .{ .points = self.minimum_second } else children[2].style.layout.min_width;
        children[2].style.layout.min_height = if (self.orientation == .vertical) .{ .points = self.minimum_second } else children[2].style.layout.min_height;
        return .{
            .kind = .{ .custom = custom.Node.from(SplitPane, self) },
            .style = .{ .layout = .{
                .direction = if (self.orientation == .horizontal) .row else .column,
                .width = .{ .percent = 1 },
                .height = .{ .percent = 1 },
            } },
            .children = children,
        };
    }

    pub fn measure(self: *SplitPane, _: *custom.MeasureContext, constraints: layout.Constraints) Error!geometry.Size {
        try self.validateConfiguration();
        const main_minimum = self.minimum_first + self.divider_size + self.minimum_second;
        const preferred = if (self.orientation == .horizontal)
            geometry.Size{
                .width = if (std.math.isFinite(constraints.maximum.width)) constraints.maximum.width else main_minimum,
                .height = if (std.math.isFinite(constraints.maximum.height)) constraints.maximum.height else constraints.minimum.height,
            }
        else
            geometry.Size{
                .width = if (std.math.isFinite(constraints.maximum.width)) constraints.maximum.width else constraints.minimum.width,
                .height = if (std.math.isFinite(constraints.maximum.height)) constraints.maximum.height else main_minimum,
            };
        return constraints.constrain(preferred);
    }

    pub fn arrange(self: *SplitPane, _: *custom.ArrangeContext, bounds: geometry.Rect) Error!void {
        self.bounds = bounds;
    }
    pub fn paint(_: *SplitPane, _: *custom.PaintContext, _: geometry.Rect) Error!void {}

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const self: *SplitPane = @ptrCast(@alignCast(context));
        switch (event.*) {
            .pointer_down => |pointer| if (pointer.button == .primary) {
                self.dragging = true;
                self.dragging_pointer = pointer.pointer_id;
                dispatch.capturePointer(dispatch.current);
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
                try self.update(pointer.position, dispatch, ctx);
            },
            .pointer_move => |pointer| if (self.dragging_pointer == pointer.pointer_id) try self.update(pointer.position, dispatch, ctx),
            .pointer_up, .pointer_cancel => |pointer| if (self.dragging_pointer == pointer.pointer_id) {
                self.dragging = false;
                self.dragging_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
                try ctx.invalidate(.{});
            },
            .key_down => |key| switch (key.key) {
                .arrow_left => if (self.orientation == .horizontal) try self.adjust(-0.02, dispatch, ctx),
                .arrow_right => if (self.orientation == .horizontal) try self.adjust(0.02, dispatch, ctx),
                .arrow_up => if (self.orientation == .vertical) try self.adjust(-0.02, dispatch, ctx),
                .arrow_down => if (self.orientation == .vertical) try self.adjust(0.02, dispatch, ctx),
                .home => try self.setFraction(0, dispatch, ctx),
                .end => try self.setFraction(1, dispatch, ctx),
                else => {},
            },
            .accessibility => |request| switch (request.action) {
                .increment => try self.adjust(0.05, dispatch, ctx),
                .decrement => try self.adjust(-0.05, dispatch, ctx),
                .set_value => if (request.value) |value| try self.setFraction(std.fmt.parseFloat(f32, value) catch return, dispatch, ctx),
                else => {},
            },
            else => {},
        }
    }

    fn update(self: *SplitPane, point: geometry.Point, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        const extent = if (self.orientation == .horizontal) self.bounds.size.width else self.bounds.size.height;
        if (extent <= self.divider_size) return;
        const available = extent - self.divider_size;
        const local = ctx.localPoint(point);
        const position = if (self.orientation == .horizontal) local.x - self.bounds.origin.x else local.y - self.bounds.origin.y;
        try self.setFraction((position - self.divider_size / 2) / available, dispatch, ctx);
    }

    fn adjust(self: *SplitPane, delta: f32, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        try self.setFraction(self.fraction.* + delta, dispatch, ctx);
    }

    fn setFraction(self: *SplitPane, value: f32, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        try self.validateConfiguration();
        if (!std.math.isFinite(value)) return error.InvalidConfiguration;
        const next = self.clampFraction(value);
        dispatch.handled = true;
        dispatch.preventDefault();
        if (next == self.fraction.*) return;
        self.fraction.* = next;
        try ctx.invalidate(.{});
        if (self.on_change) |callback| try callback.call(ctx);
    }

    fn validateConfiguration(self: *const SplitPane) Error!void {
        if (!std.math.isFinite(self.fraction.*) or !std.math.isFinite(self.minimum_first) or
            !std.math.isFinite(self.minimum_second) or !std.math.isFinite(self.divider_size) or
            self.minimum_first < 0 or self.minimum_second < 0 or self.divider_size <= 0 or
            !std.math.isFinite(self.minimum_first + self.divider_size + self.minimum_second))
            return error.InvalidConfiguration;
    }

    fn clampFraction(self: *const SplitPane, value: f32) f32 {
        const extent = if (self.orientation == .horizontal) self.bounds.size.width else self.bounds.size.height;
        if (!std.math.isFinite(extent) or extent <= self.divider_size)
            return std.math.clamp(value, 0, 1);
        const available = extent - self.divider_size;
        const minimum = self.minimum_first / available;
        const maximum = 1 - self.minimum_second / available;
        if (minimum <= maximum) return std.math.clamp(value, minimum, maximum);
        const total_minimum = self.minimum_first + self.minimum_second;
        return if (total_minimum > 0) self.minimum_first / total_minimum else 0.5;
    }
};
