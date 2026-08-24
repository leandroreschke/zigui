const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const custom = @import("../compose/custom.zig");
const node = @import("../compose/node.zig");
const input = @import("../input/event.zig");
const a11y = @import("../a11y/api.zig");

pub const HeightIndex = struct {
    allocator: std.mem.Allocator,
    heights: []f32,
    tree: []f64,

    pub fn init(allocator: std.mem.Allocator, count: usize, estimated_height: f32) Error!HeightIndex {
        if (estimated_height < 0 or !std.math.isFinite(estimated_height)) return error.InvalidConfiguration;
        const tree_length = std.math.add(usize, count, 1) catch return error.BudgetExceeded;
        const heights = try allocator.alloc(f32, count);
        errdefer allocator.free(heights);
        const tree = try allocator.alloc(f64, tree_length);
        @memset(heights, estimated_height);
        @memset(tree, 0);
        var self: HeightIndex = .{ .allocator = allocator, .heights = heights, .tree = tree };
        for (heights, 0..) |height, index| self.add(index, height);
        return self;
    }

    pub fn deinit(self: *HeightIndex) void {
        self.allocator.free(self.heights);
        self.allocator.free(self.tree);
        self.* = undefined;
    }

    pub fn resize(self: *HeightIndex, count: usize, estimated_height: f32) Error!void {
        var replacement = try HeightIndex.init(self.allocator, count, estimated_height);
        errdefer replacement.deinit();
        const shared = @min(count, self.heights.len);
        var index: usize = 0;
        while (index < shared) : (index += 1) try replacement.set(index, self.heights[index]);
        self.deinit();
        self.* = replacement;
    }

    pub fn set(self: *HeightIndex, index: usize, height: f32) Error!void {
        if (index >= self.heights.len or height < 0 or !std.math.isFinite(height)) return error.InvalidConfiguration;
        const delta = height - self.heights[index];
        const next_total = self.total() + @as(f64, delta);
        if (!std.math.isFinite(next_total) or next_total < 0) return error.BudgetExceeded;
        self.heights[index] = height;
        self.add(index, delta);
    }

    pub fn total(self: *const HeightIndex) f64 {
        return self.prefix(self.heights.len);
    }

    pub fn offsetOf(self: *const HeightIndex, index: usize) f64 {
        return self.prefix(@min(index, self.heights.len));
    }

    pub fn indexAt(self: *const HeightIndex, offset: f64) usize {
        if (self.heights.len == 0 or std.math.isNan(offset) or offset <= 0) return 0;
        if (std.math.isPositiveInf(offset)) return self.heights.len - 1;
        var index: usize = 0;
        var accumulated: f64 = 0;
        var bit: usize = std.math.floorPowerOfTwo(usize, self.heights.len);
        while (bit != 0) : (bit >>= 1) {
            const next = index + bit;
            if (next <= self.heights.len and accumulated + self.tree[next] <= offset) {
                index = next;
                accumulated += self.tree[next];
            }
        }
        return @min(index, self.heights.len - 1);
    }

    fn prefix(self: *const HeightIndex, end: usize) f64 {
        var index = end;
        var result: f64 = 0;
        while (index != 0) {
            result += self.tree[index];
            index &= index - 1;
        }
        return result;
    }

    fn add(self: *HeightIndex, item_index: usize, delta: f32) void {
        var index = item_index + 1;
        while (index < self.tree.len) {
            self.tree[index] += delta;
            index += index & (~index +% 1);
        }
    }
};

pub fn VirtualList(comptime ItemContext: type) type {
    return struct {
        const Self = @This();

        item_context: *ItemContext,
        build_item: *const fn (*ItemContext, usize, *component.BuildContext) Error!node.Spec,
        heights: *HeightIndex,
        scroll_offset: f64 = 0,
        viewport_height: f32 = 0,
        overscan_pixels: f32 = 400,
        maximum_visible_items: usize = 4_096,

        pub fn build(self: *Self, ctx: *component.BuildContext) Error!node.Spec {
            try self.validateConfiguration();
            const count = self.heights.heights.len;
            const total = self.heights.total();
            if (!std.math.isFinite(total) or total > 3.402823466e+38) return error.BudgetExceeded;
            const viewport_height: f64 = @floatCast(self.viewport_height);
            const overscan_pixels: f64 = @floatCast(self.overscan_pixels);
            const maximum_offset = @max(0, total - viewport_height);
            const effective_offset = std.math.clamp(self.scroll_offset, 0, maximum_offset);
            const overscan_start = @max(0, effective_offset - overscan_pixels);
            const overscan_end = @min(total, effective_offset + viewport_height + overscan_pixels);
            const start = if (count == 0) 0 else self.heights.indexAt(overscan_start);
            const end = if (count == 0) 0 else @min(count, self.heights.indexAt(overscan_end) + 2);
            const visible = end - start;
            if (visible > self.maximum_visible_items) return error.BudgetExceeded;
            const items = try ctx.allocator.alloc(node.Spec, visible);
            var item_index = start;
            while (item_index < end) : (item_index += 1) {
                const content = try self.build_item(self.item_context, item_index, ctx);
                const child = try ctx.allocator.dupe(node.Spec, &.{content});
                items[item_index - start] = .{
                    .key = @intCast(item_index + 1),
                    .kind = .container,
                    .style = .{ .layout = .{
                        .position = .absolute,
                        .width = .{ .percent = 1 },
                        .height = .{ .points = self.heights.heights[item_index] },
                        .inset = .{
                            .top = .{ .points = @floatCast(self.heights.offsetOf(item_index)) },
                            .left = .{ .points = 0 },
                            .right = .auto,
                            .bottom = .auto,
                        },
                    } },
                    .children = child,
                };
            }
            const content = try ctx.allocator.alloc(node.Spec, 2);
            content[0] = .{
                .kind = .container,
                .style = .{ .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .points = @floatCast(self.heights.total()) },
                } },
                .semantics = .{ .role = .list },
                .children = items,
            };
            content[1] = .{
                .key = std.math.maxInt(u64),
                .kind = .{ .custom = custom.Node.from(Self, self) },
                .style = .{
                    .layout = .{
                        .position = .absolute,
                        .width = .{ .percent = 1 },
                        .height = .{ .percent = 1 },
                        .inset = .{ .top = .{ .points = 0 }, .right = .{ .points = 0 }, .bottom = .{ .points = 0 }, .left = .{ .points = 0 } },
                    },
                    .interaction = .{ .pointer_events = .none },
                },
            };
            const handlers = try ctx.allocator.alloc(input.Handler, 1);
            handlers[0] = .{ .context = self, .callback = handle };
            const actions = try ctx.allocator.dupe(a11y.Action, &.{ .scroll_up, .scroll_down });
            return .{
                .kind = .{ .scroll = .{ .vertical = true, .horizontal = false, .offset_y = @floatCast(effective_offset) } },
                .style = .{ .layout = .{ .width = .{ .percent = 1 }, .height = .{ .percent = 1 }, .overflow_y = .scroll, .overflow_x = .hidden } },
                .handlers = handlers,
                .semantics = .{ .role = .scroll_view, .actions = actions },
                .children = content,
            };
        }

        pub fn reveal(self: *Self, index: usize) void {
            if (index >= self.heights.heights.len) return;
            const start = self.heights.offsetOf(index);
            const item_height: f64 = @floatCast(self.heights.heights[index]);
            const viewport_height: f64 = @floatCast(self.viewport_height);
            const end = start + item_height;
            if (start < self.scroll_offset) self.scroll_offset = start;
            if (end > self.scroll_offset + viewport_height) self.scroll_offset = @max(0, end - viewport_height);
        }

        pub fn arrange(self: *Self, ctx: *custom.ArrangeContext, bounds: geometry.Rect) Error!void {
            const height = if (ctx.containing_content_bounds.size.height > 0)
                ctx.containing_content_bounds.size.height
            else
                bounds.size.height;
            if (!std.math.isFinite(height) or height < 0) return error.InvalidLayout;
            const maximum = @max(0, self.heights.total() - @as(f64, @floatCast(height)));
            const offset = std.math.clamp(self.scroll_offset, 0, maximum);
            if (@abs(self.viewport_height - height) <= 0.25 and offset == self.scroll_offset) return;
            self.viewport_height = height;
            self.scroll_offset = offset;
            _ = ctx.requestRecompose();
        }

        pub fn paint(_: *Self, _: *custom.PaintContext, _: geometry.Rect) Error!void {}

        fn handle(context: *anyopaque, dispatch: *input.Dispatch, event: *const input.Event, ctx: *input.Context) Error!void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.viewport_height = ctx.current_content_bounds.size.height;
            switch (event.*) {
                .scroll => |scroll| {
                    const viewport_height: f64 = @floatCast(self.viewport_height);
                    const delta: f64 = @floatCast(scroll.delta.y);
                    const maximum = @max(0, self.heights.total() - viewport_height);
                    const next = std.math.clamp(self.scroll_offset + delta, 0, maximum);
                    if (next == self.scroll_offset) return;
                    self.scroll_offset = next;
                    dispatch.handled = true;
                    dispatch.preventDefault();
                    try ctx.invalidate(.{ .layout = false, .resources = false });
                },
                .accessibility => |request| switch (request.action) {
                    .scroll_up, .scroll_down => {
                        const viewport_height: f64 = @floatCast(self.viewport_height);
                        const maximum = @max(0, self.heights.total() - viewport_height);
                        const direction: f64 = if (request.action == .scroll_up) -1.0 else 1.0;
                        const delta = viewport_height * 0.8 * direction;
                        const next = std.math.clamp(self.scroll_offset + delta, 0, maximum);
                        dispatch.handled = true;
                        dispatch.preventDefault();
                        if (next != self.scroll_offset) {
                            self.scroll_offset = next;
                            try ctx.invalidate(.{ .layout = false, .resources = false });
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }

        fn validateConfiguration(self: *const Self) Error!void {
            if (!std.math.isFinite(self.scroll_offset) or !std.math.isFinite(self.viewport_height) or
                !std.math.isFinite(self.overscan_pixels) or self.scroll_offset < 0 or
                self.viewport_height < 0 or self.overscan_pixels < 0 or self.maximum_visible_items == 0)
                return error.InvalidConfiguration;
        }
    };
}
