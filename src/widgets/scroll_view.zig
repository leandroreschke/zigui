const std = @import("std");
const Error = @import("../core/error.zig").Error;
const component = @import("../compose/component.zig");
const custom = @import("../compose/custom.zig");
const node = @import("../compose/node.zig");
const geometry = @import("../core/geometry.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");
const compose_style = @import("../compose/style.zig");

pub const ScrollView = struct {
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    horizontal: bool = false,
    vertical: bool = true,
    content: node.Spec,
    style: compose_style.Style = .{},

    pub fn build(self: *ScrollView, ctx: *component.BuildContext) Error!node.Spec {
        if (!std.math.isFinite(self.offset_x) or !std.math.isFinite(self.offset_y) or self.offset_x < 0 or self.offset_y < 0)
            return error.InvalidConfiguration;
        const handlers = try ctx.allocator.alloc(input.Handler, 1);
        handlers[0] = .{ .context = self, .callback = handle };
        const children = try ctx.allocator.alloc(node.Spec, 2);
        children[0] = self.content;
        children[1] = .{
            .key = std.math.maxInt(u64),
            .kind = .{ .custom = custom.Node.from(ScrollView, self) },
            .style = .{
                .layout = .{
                    .position = .absolute,
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .inset = .{
                        .top = .{ .points = 0 },
                        .right = .{ .points = 0 },
                        .bottom = .{ .points = 0 },
                        .left = .{ .points = 0 },
                    },
                },
                .interaction = .{ .pointer_events = .none },
            },
        };
        var action_buffer: [4]a11y.Action = undefined;
        var action_count: usize = 0;
        if (self.vertical) {
            action_buffer[action_count] = .scroll_up;
            action_buffer[action_count + 1] = .scroll_down;
            action_count += 2;
        }
        if (self.horizontal) {
            action_buffer[action_count] = .scroll_left;
            action_buffer[action_count + 1] = .scroll_right;
            action_count += 2;
        }
        const actions = try ctx.allocator.dupe(a11y.Action, action_buffer[0..action_count]);
        var node_style = self.style;
        node_style.layout.overflow_x = if (self.horizontal) .scroll else .hidden;
        node_style.layout.overflow_y = if (self.vertical) .scroll else .hidden;
        return .{
            .kind = .{ .scroll = .{
                .horizontal = self.horizontal,
                .vertical = self.vertical,
                .offset_x = if (self.horizontal) self.offset_x else 0,
                .offset_y = if (self.vertical) self.offset_y else 0,
            } },
            .style = node_style,
            .handlers = handlers,
            .semantics = .{ .role = .scroll_view, .actions = actions },
            .children = children,
        };
    }

    pub fn arrange(self: *ScrollView, ctx: *custom.ArrangeContext, _: geometry.Rect) Error!void {
        const viewport = ctx.containing_content_bounds.size;
        const extent = ctx.containing_scroll_extent;
        if (!finiteNonNegativeSize(viewport) or !finiteNonNegativeSize(extent)) return error.InvalidLayout;
        const next_x = if (self.horizontal) clampOffset(self.offset_x, extent.width, viewport.width) else 0;
        const next_y = if (self.vertical) clampOffset(self.offset_y, extent.height, viewport.height) else 0;
        if (next_x == self.offset_x and next_y == self.offset_y) return;
        self.offset_x = next_x;
        self.offset_y = next_y;
        _ = ctx.requestRecompose();
    }

    pub fn paint(_: *ScrollView, _: *custom.PaintContext, _: geometry.Rect) Error!void {}

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
        const self: *ScrollView = @ptrCast(@alignCast(context));
        switch (event.*) {
            .scroll => |scroll| {
                const previous_x = self.offset_x;
                const previous_y = self.offset_y;
                self.clampOffsets(ctx);
                if (self.horizontal) self.offset_x = clampOffset(self.offset_x + scroll.delta.x, ctx.current_scroll_extent.width, ctx.current_content_bounds.size.width);
                if (self.vertical) self.offset_y = clampOffset(self.offset_y + scroll.delta.y, ctx.current_scroll_extent.height, ctx.current_content_bounds.size.height);
                if (self.offset_x == previous_x and self.offset_y == previous_y) return;
                dispatch.handled = true;
                dispatch.preventDefault();
                try ctx.invalidate(.{ .layout = false, .resources = false, .semantics = false });
            },
            .accessibility => |request| {
                const previous_x = self.offset_x;
                const previous_y = self.offset_y;
                self.clampOffsets(ctx);
                switch (request.action) {
                    .scroll_up => {
                        if (!self.vertical) return;
                        self.offset_y = clampOffset(self.offset_y - ctx.current_content_bounds.size.height * 0.8, ctx.current_scroll_extent.height, ctx.current_content_bounds.size.height);
                    },
                    .scroll_down => {
                        if (!self.vertical) return;
                        self.offset_y = clampOffset(self.offset_y + ctx.current_content_bounds.size.height * 0.8, ctx.current_scroll_extent.height, ctx.current_content_bounds.size.height);
                    },
                    .scroll_left => {
                        if (!self.horizontal) return;
                        self.offset_x = clampOffset(self.offset_x - ctx.current_content_bounds.size.width * 0.8, ctx.current_scroll_extent.width, ctx.current_content_bounds.size.width);
                    },
                    .scroll_right => {
                        if (!self.horizontal) return;
                        self.offset_x = clampOffset(self.offset_x + ctx.current_content_bounds.size.width * 0.8, ctx.current_scroll_extent.width, ctx.current_content_bounds.size.width);
                    },
                    else => return,
                }
                dispatch.handled = true;
                dispatch.preventDefault();
                if (self.offset_x != previous_x or self.offset_y != previous_y)
                    try ctx.invalidate(.{ .layout = false, .resources = false, .semantics = false });
            },
            else => {},
        }
    }

    fn clampOffsets(self: *ScrollView, ctx: *const input.Context) void {
        self.offset_x = if (self.horizontal) clampOffset(self.offset_x, ctx.current_scroll_extent.width, ctx.current_content_bounds.size.width) else 0;
        self.offset_y = if (self.vertical) clampOffset(self.offset_y, ctx.current_scroll_extent.height, ctx.current_content_bounds.size.height) else 0;
    }
};

fn clampOffset(value: f32, extent: f32, viewport: f32) f32 {
    return std.math.clamp(value, 0, @max(0, extent - viewport));
}

fn finiteNonNegativeSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and
        value.width >= 0 and value.height >= 0;
}
