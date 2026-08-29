const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const custom = @import("../compose/custom.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const Theme = @import("theme.zig").Theme;
const virtual_list = @import("virtual_list.zig");

/// A vertical scrollbar bound to a generic `VirtualList`.
///
/// The list and scrollbar are intentionally bound by pointer rather than by a
/// copied offset. Pointer, keyboard, and accessibility input therefore all
/// update the list's retained scroll state and visible-range notification in
/// the same serialized input turn.
pub fn VerticalScrollbar(comptime ItemContext: type) type {
    const List = virtual_list.VirtualList(ItemContext);

    return struct {
        const Self = @This();

        pub const Geometry = struct {
            track: geometry.Rect,
            thumb: geometry.Rect,
            metrics: virtual_list.ScrollMetrics,
        };

        list: *List,
        theme: *const Theme = &Theme.dark,
        label: []const u8 = "Vertical scrollbar",
        width: f32 = 12,
        horizontal_inset: f32 = 2,
        vertical_inset: f32 = 2,
        minimum_thumb_length: f32 = 24,
        disabled: bool = false,
        hovered: bool = false,
        focused: bool = false,
        pressed: bool = false,
        pressed_pointer: ?u64 = null,
        drag_grab_offset: f32 = 0,

        pub fn build(self: *Self, ctx: *component.BuildContext) Error!node.Spec {
            const metrics = try self.list.scrollMetrics();
            try self.validateConfiguration();
            const scrollable = metrics.maximum_offset > 0;
            const actions: []const a11y.Action = if (self.disabled or !scrollable)
                &.{}
            else
                &.{ .scroll_up, .scroll_down, .increment, .decrement, .set_value };
            const owned_actions = try ctx.allocator.dupe(a11y.Action, actions);
            const value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{metrics.offset});
            return .{
                .kind = .{ .custom = custom.Node.from(Self, self) },
                .style = .{
                    .layout = .{
                        .width = .{ .points = self.width },
                        .height = .{ .percent = 1 },
                    },
                    .paint = .{ .opacity = if (self.disabled) self.theme.disabled_opacity else 1 },
                    .interaction = .{
                        .focusable = !self.disabled and scrollable,
                        .cursor = if (self.disabled) .not_allowed else .pointer,
                        .disabled = self.disabled,
                    },
                },
                .semantics = .{
                    // ZigUI's cross-platform public role set does not yet
                    // expose a distinct scrollbar role. A ranged slider is
                    // the existing native-compatible role for this control.
                    .role = .slider,
                    .label = self.label,
                    .value = value,
                    .actions = owned_actions,
                    .range_min = 0,
                    .range_max = metrics.maximum_offset,
                    .range_value = metrics.offset,
                    .disabled = self.disabled or !scrollable,
                },
            };
        }

        pub fn arrange(self: *Self, _: *custom.ArrangeContext, bounds: geometry.Rect) Error!void {
            _ = try self.geometryFor(bounds);
        }

        pub fn paint(self: *Self, ctx: *custom.PaintContext, bounds: geometry.Rect) Error!void {
            const scrollbar = try self.geometryFor(bounds);
            if (scrollbar.metrics.maximum_offset == 0 or scrollbar.track.isEmpty()) return;

            try ctx.quad(.{
                .bounds = scrollbar.track,
                .background = geometry.Color.rgba(1, 1, 1, 0.08),
                .border_color = geometry.Color.transparent,
                .border_widths = .{},
                .radii = geometry.CornerRadii.all(@min(scrollbar.track.size.width, scrollbar.track.size.height) / 2),
            });
            try ctx.quad(.{
                .bounds = scrollbar.thumb,
                .background = if (self.pressed)
                    self.theme.accent_pressed
                else if (self.hovered)
                    self.theme.accent_hovered
                else
                    self.theme.muted_text,
                .border_color = if (self.focused) self.theme.focus_ring else geometry.Color.transparent,
                .border_widths = geometry.Insets.all(if (self.focused) 1 else 0),
                .radii = geometry.CornerRadii.all(@min(scrollbar.thumb.size.width, scrollbar.thumb.size.height) / 2),
            });
        }

        pub fn event(self: *Self, dispatch: *input.Dispatch, event_value: *const input.Event, ctx: *input.Context) Error!void {
            if (self.disabled) {
                switch (event_value.*) {
                    .pointer_up, .pointer_cancel => |pointer| if (self.pressed_pointer == pointer.pointer_id) {
                        self.resetPress(dispatch);
                    },
                    else => {},
                }
                return;
            }

            switch (event_value.*) {
                .pointer_enter => {
                    self.hovered = true;
                    try self.invalidateVisual(ctx);
                },
                .pointer_leave => {
                    self.hovered = false;
                    try self.invalidateVisual(ctx);
                },
                .focus_in => {
                    self.focused = true;
                    try self.invalidateVisual(ctx);
                },
                .focus_out => {
                    self.focused = false;
                    try self.invalidateVisual(ctx);
                },
                .pointer_down => |pointer| if (pointer.button == .primary) {
                    const scrollbar = try self.geometryFor(ctx.current_layout_bounds);
                    if (scrollbar.metrics.maximum_offset == 0) return;
                    const local = ctx.localPoint(pointer.position);
                    self.pressed = true;
                    self.pressed_pointer = pointer.pointer_id;
                    self.drag_grab_offset = if (scrollbar.thumb.contains(local))
                        local.y - scrollbar.thumb.origin.y
                    else
                        scrollbar.thumb.size.height / 2;
                    dispatch.capturePointer(dispatch.current);
                    dispatch.requestFocus(dispatch.current);
                    dispatch.handled = true;
                    dispatch.preventDefault();
                    try self.setFromLocalY(local.y, scrollbar, ctx, dispatch);
                    try self.invalidateVisual(ctx);
                },
                .pointer_move => |pointer| if (self.pressed_pointer == pointer.pointer_id) {
                    const scrollbar = try self.geometryFor(ctx.current_layout_bounds);
                    const local = ctx.localPoint(pointer.position);
                    dispatch.handled = true;
                    dispatch.preventDefault();
                    try self.setFromLocalY(local.y, scrollbar, ctx, dispatch);
                },
                .pointer_up => |pointer| if (pointer.button == .primary and self.pressed_pointer == pointer.pointer_id) {
                    self.resetPress(dispatch);
                    try self.invalidateVisual(ctx);
                },
                .pointer_cancel => |pointer| if (self.pressed_pointer == pointer.pointer_id) {
                    self.hovered = false;
                    self.resetPress(dispatch);
                    try self.invalidateVisual(ctx);
                },
                .key_down => |key| switch (key.key) {
                    .arrow_up => try self.adjust(-self.keyboardStep(ctx), ctx, dispatch),
                    .arrow_down => try self.adjust(self.keyboardStep(ctx), ctx, dispatch),
                    .page_up => try self.adjust(-self.pageStep(ctx), ctx, dispatch),
                    .page_down => try self.adjust(self.pageStep(ctx), ctx, dispatch),
                    .home => try self.setOffset(0, ctx, dispatch),
                    .end => {
                        const metrics = try self.list.scrollMetricsForViewport(self.viewportHeight(ctx));
                        try self.setOffset(metrics.maximum_offset, ctx, dispatch);
                    },
                    else => {},
                },
                .accessibility => |request| switch (request.action) {
                    .scroll_up, .decrement => try self.adjust(-self.pageStep(ctx), ctx, dispatch),
                    .scroll_down, .increment => try self.adjust(self.pageStep(ctx), ctx, dispatch),
                    .set_value => if (request.value) |value| {
                        const parsed = std.fmt.parseFloat(f64, value) catch return;
                        try self.setOffset(parsed, ctx, dispatch);
                    },
                    else => {},
                },
                else => {},
            }
        }

        fn geometryFor(self: *const Self, bounds: geometry.Rect) Error!Geometry {
            try self.validateConfiguration();
            if (!finiteRect(bounds)) return error.InvalidLayout;
            const viewport_height = if (self.list.viewport_height > 0)
                self.list.viewport_height
            else
                bounds.size.height;
            const metrics = try self.list.scrollMetricsForViewport(viewport_height);
            const track = geometry.Rect.fromXYWH(
                bounds.origin.x + self.horizontal_inset,
                bounds.origin.y + self.vertical_inset,
                @max(0, bounds.size.width - self.horizontal_inset * 2),
                @max(0, bounds.size.height - self.vertical_inset * 2),
            );
            if (track.isEmpty() or metrics.maximum_offset == 0) return .{ .track = track, .thumb = track, .metrics = metrics };

            const visible_fraction = std.math.clamp(metrics.viewport_extent / metrics.content_extent, 0, 1);
            const thumb_height = @min(track.size.height, @max(self.minimum_thumb_length, track.size.height * @as(f32, @floatCast(visible_fraction))));
            const travel = @max(0, track.size.height - thumb_height);
            const position_fraction = @as(f32, @floatCast(metrics.offset / metrics.maximum_offset));
            return .{
                .track = track,
                .thumb = geometry.Rect.fromXYWH(
                    bounds.origin.x + self.horizontal_inset,
                    track.origin.y + travel * std.math.clamp(position_fraction, 0, 1),
                    track.size.width,
                    thumb_height,
                ),
                .metrics = metrics,
            };
        }

        fn setFromLocalY(self: *Self, local_y: f32, scrollbar: Geometry, ctx: *input.Context, dispatch: *input.Dispatch) Error!void {
            const thumb_top = local_y - self.drag_grab_offset;
            const travel = @max(0, scrollbar.track.size.height - scrollbar.thumb.size.height);
            const fraction = if (travel == 0) 0 else std.math.clamp((thumb_top - scrollbar.track.origin.y) / travel, 0, 1);
            try self.setOffset(scrollbar.metrics.maximum_offset * @as(f64, @floatCast(fraction)), ctx, dispatch);
        }

        fn adjust(self: *Self, delta: f64, ctx: *input.Context, dispatch: *input.Dispatch) Error!void {
            const metrics = try self.list.scrollMetricsForViewport(self.viewportHeight(ctx));
            try self.setOffset(metrics.offset + delta, ctx, dispatch);
        }

        fn setOffset(self: *Self, offset: f64, ctx: *input.Context, dispatch: *input.Dispatch) Error!void {
            const changed = try self.list.setScrollOffsetForViewport(offset, self.viewportHeight(ctx));
            dispatch.handled = true;
            dispatch.preventDefault();
            if (changed) try ctx.invalidate(.{ .layout = false, .resources = false });
        }

        fn viewportHeight(self: *const Self, ctx: *const input.Context) f32 {
            return if (self.list.viewport_height > 0) self.list.viewport_height else ctx.current_layout_bounds.size.height;
        }

        fn keyboardStep(self: *const Self, ctx: *const input.Context) f64 {
            _ = self;
            return @max(@as(f64, 1), @as(f64, @floatCast(@max(@as(f32, 1), viewportHeightFromContext(ctx) * 0.1))));
        }

        fn pageStep(self: *const Self, ctx: *const input.Context) f64 {
            _ = self;
            return @as(f64, @floatCast(@max(@as(f32, 1), viewportHeightFromContext(ctx) * 0.8)));
        }

        fn invalidateVisual(_: *Self, ctx: *input.Context) Error!void {
            try ctx.invalidate(.{ .compose = false, .layout = false, .resources = false, .semantics = false });
        }

        fn resetPress(self: *Self, dispatch: *input.Dispatch) void {
            self.pressed = false;
            self.pressed_pointer = null;
            self.drag_grab_offset = 0;
            dispatch.releasePointer();
            dispatch.handled = true;
            dispatch.preventDefault();
        }

        fn validateConfiguration(self: *const Self) Error!void {
            if (!std.math.isFinite(self.width) or !std.math.isFinite(self.horizontal_inset) or
                !std.math.isFinite(self.vertical_inset) or !std.math.isFinite(self.minimum_thumb_length) or
                self.width <= 0 or self.horizontal_inset < 0 or self.vertical_inset < 0 or
                self.minimum_thumb_length <= 0 or self.horizontal_inset * 2 > self.width)
                return error.InvalidConfiguration;
        }
    };
}

fn viewportHeightFromContext(ctx: *const input.Context) f32 {
    return @max(0, ctx.current_layout_bounds.size.height);
}

fn finiteRect(value: geometry.Rect) bool {
    return std.math.isFinite(value.origin.x) and std.math.isFinite(value.origin.y) and
        std.math.isFinite(value.size.width) and std.math.isFinite(value.size.height) and
        value.size.width >= 0 and value.size.height >= 0;
}

test "vertical scrollbar rejects malformed configuration and layout" {
    const ItemContext = struct {};
    const List = virtual_list.VirtualList(ItemContext);
    var heights = try virtual_list.HeightIndex.init(std.testing.allocator, 4, 10);
    defer heights.deinit();
    var item_context = ItemContext{};
    var list = List{ .item_context = &item_context, .build_item = undefined, .heights = &heights, .viewport_height = 20 };
    var scrollbar = VerticalScrollbar(ItemContext){ .list = &list };

    try std.testing.expectError(error.InvalidLayout, scrollbar.geometryFor(geometry.Rect.fromXYWH(0, 0, 12, -1)));
    scrollbar.minimum_thumb_length = std.math.nan(f32);
    try std.testing.expectError(error.InvalidConfiguration, scrollbar.geometryFor(geometry.Rect.fromXYWH(0, 0, 12, 100)));
    scrollbar.minimum_thumb_length = 24;
    list.scroll_offset = std.math.nan(f64);
    try std.testing.expectError(error.InvalidConfiguration, scrollbar.geometryFor(geometry.Rect.fromXYWH(0, 0, 12, 100)));
}

test "vertical scrollbar keeps thumb bounded and proportional" {
    const ItemContext = struct {};
    const List = virtual_list.VirtualList(ItemContext);
    var heights = try virtual_list.HeightIndex.init(std.testing.allocator, 100, 10);
    defer heights.deinit();
    var item_context = ItemContext{};
    var list = List{ .item_context = &item_context, .build_item = undefined, .heights = &heights, .viewport_height = 100, .scroll_offset = 450 };
    const Scrollbar = VerticalScrollbar(ItemContext);
    var scrollbar = Scrollbar{ .list = &list };
    const result = try scrollbar.geometryFor(geometry.Rect.fromXYWH(0, 0, 12, 100));

    try std.testing.expectEqual(@as(f32, 96), result.track.size.height);
    try std.testing.expectEqual(@as(f32, 24), result.thumb.size.height);
    try std.testing.expect(result.thumb.minY() >= result.track.minY());
    try std.testing.expect(result.thumb.maxY() <= result.track.maxY());
    try std.testing.expectApproxEqAbs(@as(f32, 38), result.thumb.minY(), 0.001);
}

test "vertical scrollbar pointer drag and keyboard update the bound list" {
    const ItemContext = struct {};
    const List = virtual_list.VirtualList(ItemContext);
    var heights = try virtual_list.HeightIndex.init(std.testing.allocator, 20, 10);
    defer heights.deinit();
    var item_context = ItemContext{};
    var list = List{ .item_context = &item_context, .build_item = undefined, .heights = &heights, .viewport_height = 100 };
    const Scrollbar = VerticalScrollbar(ItemContext);
    var scrollbar = Scrollbar{ .list = &list };
    var coordinator = @import("../runtime/coordinator.zig").Coordinator.init(std.testing.allocator);
    defer coordinator.deinit() catch {};
    var ctx: input.Context = .{
        .coordinator = &coordinator,
        .component = .invalid,
        .window = .invalid,
        .current_bounds = geometry.Rect.fromXYWH(0, 0, 12, 100),
        .current_layout_bounds = geometry.Rect.fromXYWH(0, 0, 12, 100),
        .current_content_bounds = geometry.Rect.fromXYWH(0, 0, 12, 100),
    };
    var dispatch: input.Dispatch = .{ .window = .invalid, .target = .invalid, .current = .invalid, .phase = .target };
    const enter: input.Event = .{ .pointer_enter = .{ .pointer_id = 7, .position = .{ .x = 6, .y = 50 } } };
    try scrollbar.event(&dispatch, &enter, &ctx);
    try std.testing.expect(scrollbar.hovered);
    try scrollbar.event(&dispatch, &.{ .focus_in = {} }, &ctx);
    try std.testing.expect(scrollbar.focused);
    const down: input.Event = .{ .pointer_down = .{ .pointer_id = 7, .position = .{ .x = 6, .y = 50 }, .button = .primary } };
    try scrollbar.event(&dispatch, &down, &ctx);
    try std.testing.expect(scrollbar.pressed);
    try std.testing.expect(list.scroll_offset > 0);
    const move: input.Event = .{ .pointer_move = .{ .pointer_id = 7, .position = .{ .x = 6, .y = 90 } } };
    try scrollbar.event(&dispatch, &move, &ctx);
    try std.testing.expect(list.scroll_offset > 0);
    const up: input.Event = .{ .pointer_up = .{ .pointer_id = 7, .position = .{ .x = 6, .y = 90 }, .button = .primary } };
    try scrollbar.event(&dispatch, &up, &ctx);
    try std.testing.expect(!scrollbar.pressed);
    try scrollbar.event(&dispatch, &.{ .focus_out = {} }, &ctx);
    try scrollbar.event(&dispatch, &.{ .pointer_leave = .{ .pointer_id = 7, .position = .{ .x = 20, .y = 90 } } }, &ctx);
    try std.testing.expect(!scrollbar.focused);
    try std.testing.expect(!scrollbar.hovered);
    const key: input.Event = .{ .key_down = .{ .key = .page_down, .physical_code = 0 } };
    try scrollbar.event(&dispatch, &key, &ctx);
    try std.testing.expect(list.scroll_offset > 0);
    const a11y_event: input.Event = .{ .accessibility = .{ .target = .{ .index = 1, .generation = 1 }, .action = .scroll_up } };
    try scrollbar.event(&dispatch, &a11y_event, &ctx);
    try std.testing.expect(list.scroll_offset >= 0);
}

test "vertical scrollbar build publishes focusable ranged actions" {
    const ItemContext = struct {};
    const List = virtual_list.VirtualList(ItemContext);
    var heights = try virtual_list.HeightIndex.init(std.testing.allocator, 10, 10);
    defer heights.deinit();
    var item_context = ItemContext{};
    var list = List{ .item_context = &item_context, .build_item = undefined, .heights = &heights, .viewport_height = 20 };
    var scrollbar = VerticalScrollbar(ItemContext){ .list = &list };
    var build_context: component.BuildContext = .{
        .allocator = std.testing.allocator,
        .appearance = .system,
        .coordinator = undefined,
        .components = undefined,
        .component = .invalid,
        .window = .invalid,
        .dependencies = undefined,
    };
    const spec = try scrollbar.build(&build_context);
    try std.testing.expect(spec.style.interaction.focusable);
    try std.testing.expectEqual(a11y.Role.slider, spec.semantics.role);
    try std.testing.expectEqual(@as(usize, 5), spec.semantics.actions.len);
    try std.testing.expectEqual(@as(f64, 80), spec.semantics.range_max.?);
}
