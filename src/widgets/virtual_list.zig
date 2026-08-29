const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const custom = @import("../compose/custom.zig");
const node = @import("../compose/node.zig");
const layout = @import("../layout/style.zig");
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

pub const ScrollMetrics = struct {
    content_extent: f64,
    viewport_extent: f64,
    offset: f64,
    maximum_offset: f64,
};

fn scrollContentLayout(total: f64) layout.LayoutStyle {
    return .{
        .width = .{ .percent = 1 },
        .height = .{ .points = @floatCast(total) },
        .flex_shrink = 0,
    };
}

pub fn VirtualList(comptime ItemContext: type) type {
    return struct {
        const Self = @This();

        /// Called after an input-driven scroll changes the retained visible
        /// range. The callback runs on ZigUI's serialized event/update
        /// thread, so an application may schedule work for newly visible
        /// items without mutating state during composition.
        pub const VisibleRangeCallback = *const fn (*anyopaque, usize, usize) void;

        /// Provides the stable identity for an item at `index`. The callback
        /// runs only for wrapper nodes that this build retains. Returned keys
        /// must be non-zero, must not use the list's reserved overlay key, and
        /// must be unique within that retained range.
        pub const ItemKeyCallback = *const fn (*anyopaque, usize) Error!u64;

        item_context: *ItemContext,
        build_item: *const fn (*ItemContext, usize, *component.BuildContext) Error!node.Spec,
        heights: *HeightIndex,
        scroll_offset: f64 = 0,
        viewport_height: f32 = 0,
        overscan_pixels: f32 = 400,
        maximum_visible_items: usize = 4_096,
        visible_range_context: ?*anyopaque = null,
        visible_range_callback: ?VisibleRangeCallback = null,
        item_key_context: ?*anyopaque = null,
        item_key_callback: ?ItemKeyCallback = null,
        last_notified_visible_start: usize = std.math.maxInt(usize),
        last_notified_visible_end: usize = std.math.maxInt(usize),

        pub fn build(self: *Self, ctx: *component.BuildContext) Error!node.Spec {
            const metrics = try self.scrollMetrics();
            const count = self.heights.heights.len;
            const total = metrics.content_extent;
            const viewport_height = metrics.viewport_extent;
            const overscan_pixels: f64 = @floatCast(self.overscan_pixels);
            const effective_offset = metrics.offset;
            const overscan_start = @max(0, effective_offset - overscan_pixels);
            const overscan_end = @min(total, effective_offset + viewport_height + overscan_pixels);
            const start = if (count == 0) 0 else self.heights.indexAt(overscan_start);
            const end = if (count == 0) 0 else @min(count, self.heights.indexAt(overscan_end) + 2);
            const visible = end - start;
            if (visible > self.maximum_visible_items) return error.BudgetExceeded;

            // Validate all identities before building any item content. This
            // keeps a malformed key set from reaching reconciliation and
            // ensures a failed build cannot partially alter retained state.
            var item_keys: ?[]u64 = null;
            defer if (item_keys) |keys| ctx.allocator.free(keys);
            if (self.item_key_callback) |callback| {
                const key_context = self.item_key_context orelse return error.InvalidConfiguration;
                const keys = try ctx.allocator.alloc(u64, visible);
                item_keys = keys;
                for (keys, 0..) |*key_slot, key_index| {
                    const item_index = start + key_index;
                    const key = try callback(key_context, item_index);
                    if (!isValidItemKey(key)) return error.InvalidConfiguration;
                    for (keys[0..key_index]) |previous| {
                        if (previous == key) return error.InvalidConfiguration;
                    }
                    key_slot.* = key;
                }
            }
            const items = try ctx.allocator.alloc(node.Spec, visible);
            var item_index = start;
            while (item_index < end) : (item_index += 1) {
                const content = try self.build_item(self.item_context, item_index, ctx);
                const child = try ctx.allocator.dupe(node.Spec, &.{content});
                items[item_index - start] = .{
                    .key = if (item_keys) |keys| keys[item_index - start] else @intCast(item_index + 1),
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
                .style = .{ .layout = scrollContentLayout(self.heights.total()) },
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

        pub fn scrollMetrics(self: *const Self) Error!ScrollMetrics {
            return self.scrollMetricsForViewport(self.viewport_height);
        }

        pub fn scrollMetricsForViewport(self: *const Self, viewport_height: f32) Error!ScrollMetrics {
            try self.validateConfiguration();
            if (!std.math.isFinite(viewport_height) or viewport_height < 0) return error.InvalidLayout;
            const content_extent = self.heights.total();
            if (!std.math.isFinite(content_extent) or content_extent > 3.402823466e+38) return error.BudgetExceeded;
            const viewport_extent: f64 = @floatCast(viewport_height);
            const maximum_offset = @max(0, content_extent - viewport_extent);
            return .{
                .content_extent = content_extent,
                .viewport_extent = viewport_extent,
                .offset = std.math.clamp(self.scroll_offset, 0, maximum_offset),
                .maximum_offset = maximum_offset,
            };
        }

        pub fn setScrollOffset(self: *Self, offset: f64) Error!bool {
            return self.setScrollOffsetForViewport(offset, self.viewport_height);
        }

        pub fn setScrollOffsetForViewport(self: *Self, offset: f64, viewport_height: f32) Error!bool {
            if (!std.math.isFinite(offset)) return error.InvalidConfiguration;
            const metrics = try self.scrollMetricsForViewport(viewport_height);
            const next = std.math.clamp(offset, 0, metrics.maximum_offset);
            if (next == self.scroll_offset) return false;
            self.scroll_offset = next;
            self.notifyVisibleRange();
            return true;
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
                    self.notifyVisibleRange();
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
                            self.notifyVisibleRange();
                            try ctx.invalidate(.{ .layout = false, .resources = false });
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }

        pub fn notifyVisibleRange(self: *Self) void {
            const callback = self.visible_range_callback orelse return;
            const context = self.visible_range_context orelse return;
            const count = self.heights.heights.len;
            if (count == 0) {
                if (self.last_notified_visible_start == 0 and self.last_notified_visible_end == 0) return;
                self.last_notified_visible_start = 0;
                self.last_notified_visible_end = 0;
                callback(context, 0, 0);
                return;
            }
            const viewport_height: f64 = @floatCast(@max(self.viewport_height, 0));
            const start = self.heights.indexAt(self.scroll_offset);
            const end_offset = self.scroll_offset + viewport_height;
            const end = @min(count, self.heights.indexAt(end_offset) + 1);
            const visible_end = @max(start, end);
            if (self.last_notified_visible_start == start and self.last_notified_visible_end == visible_end) return;
            self.last_notified_visible_start = start;
            self.last_notified_visible_end = visible_end;
            callback(context, start, visible_end);
        }

        fn validateConfiguration(self: *const Self) Error!void {
            if (!std.math.isFinite(self.scroll_offset) or !std.math.isFinite(self.viewport_height) or
                !std.math.isFinite(self.overscan_pixels) or self.scroll_offset < 0 or
                self.viewport_height < 0 or self.overscan_pixels < 0 or self.maximum_visible_items == 0)
                return error.InvalidConfiguration;
            if ((self.item_key_callback == null) != (self.item_key_context == null)) return error.InvalidConfiguration;
        }
    };
}

fn isValidItemKey(key: u64) bool {
    // Zero is not a meaningful caller identity, and maxInt(u64) belongs to
    // the list's non-interactive overlay sibling.
    return key != 0 and key != std.math.maxInt(u64);
}

test "virtual list reports changed visible ranges after scrolling" {
    const ItemContext = struct {};
    const List = VirtualList(ItemContext);
    const Capture = struct {
        calls: usize = 0,
        start: usize = 0,
        end: usize = 0,

        fn record(raw: *anyopaque, start: usize, end: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.start = start;
            self.end = end;
        }
    };

    var heights = try HeightIndex.init(std.testing.allocator, 3, 10);
    defer heights.deinit();
    var item_context = ItemContext{};
    var capture = Capture{};
    var list = List{
        .item_context = &item_context,
        .build_item = undefined,
        .heights = &heights,
        .viewport_height = 10,
        .visible_range_context = &capture,
        .visible_range_callback = Capture.record,
    };

    list.notifyVisibleRange();
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), capture.start);
    try std.testing.expectEqual(@as(usize, 2), capture.end);

    list.notifyVisibleRange();
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    list.scroll_offset = 10;
    list.notifyVisibleRange();
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(usize, 1), capture.start);
    try std.testing.expectEqual(@as(usize, 3), capture.end);
}

test "virtual list content keeps its full extent inside the viewport" {
    const style = scrollContentLayout(110);
    try std.testing.expectEqual(@as(f32, 0), style.flex_shrink);
    try std.testing.expectEqual(@as(f32, 110), style.height.points);
}

test "virtual list stable item keys preserve identity across reorder and removal" {
    const ItemContext = struct {};
    const KeySource = struct {
        keys: []const u64,

        fn itemKey(raw: *anyopaque, index: usize) Error!u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.keys[index];
        }
    };
    const List = VirtualList(ItemContext);
    const buildItem = struct {
        fn build(_: *ItemContext, _: usize, _: *component.BuildContext) Error!node.Spec {
            return .{ .kind = .container };
        }
    }.build;

    var heights = try HeightIndex.init(std.testing.allocator, 3, 10);
    defer heights.deinit();
    var item_context = ItemContext{};
    var keys = KeySource{ .keys = &.{ 101, 202, 303 } };
    var list = List{
        .item_context = &item_context,
        .build_item = buildItem,
        .heights = &heights,
        .viewport_height = 10,
        .overscan_pixels = 0,
        .item_key_context = &keys,
        .item_key_callback = KeySource.itemKey,
    };

    var build_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer build_arena.deinit();
    var build_context: component.BuildContext = undefined;
    build_context.allocator = build_arena.allocator();
    var nodes = @import("../compose/store.zig").Store.init(std.testing.allocator);
    defer nodes.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();

    const first = try list.build(&build_context);
    const root = try nodes.reconcile(null, .invalid, .invalid, first, 1, scratch.allocator());
    const first_content = nodes.get(root).?.children.items[0];
    const first_items = nodes.get(first_content).?.children.items;
    const first_101 = first_items[0];
    const first_202 = first_items[1];
    const first_303 = first_items[2];
    try std.testing.expectEqual(@as(u64, 101), nodes.getConst(first_101).?.key);
    try std.testing.expectEqual(@as(u64, 202), nodes.getConst(first_202).?.key);
    try std.testing.expectEqual(@as(u64, 303), nodes.getConst(first_303).?.key);

    var reordered_keys = [_]u64{ 303, 101 };
    keys.keys = &reordered_keys;
    try heights.resize(2, 10);
    const second = try list.build(&build_context);
    _ = try nodes.reconcile(root, .invalid, .invalid, second, 1, scratch.allocator());
    const second_content = nodes.get(root).?.children.items[0];
    const second_items = nodes.get(second_content).?.children.items;
    try std.testing.expectEqual(@as(usize, 2), second_items.len);
    try std.testing.expect(second_items[0].eql(first_303));
    try std.testing.expect(second_items[1].eql(first_101));
    try std.testing.expect(!second_items[0].eql(first_202));
}

test "virtual list stable item keys reject invalid and duplicate visible keys" {
    const ItemContext = struct {};
    const KeySource = struct {
        key: u64,

        fn itemKey(raw: *anyopaque, _: usize) Error!u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.key;
        }
    };
    const List = VirtualList(ItemContext);
    const buildItem = struct {
        fn build(_: *ItemContext, _: usize, _: *component.BuildContext) Error!node.Spec {
            return .{ .kind = .container };
        }
    }.build;

    var heights = try HeightIndex.init(std.testing.allocator, 2, 10);
    defer heights.deinit();
    var item_context = ItemContext{};
    var keys = KeySource{ .key = 0 };
    var list = List{
        .item_context = &item_context,
        .build_item = buildItem,
        .heights = &heights,
        .viewport_height = 10,
        .overscan_pixels = 0,
        .item_key_context = &keys,
        .item_key_callback = KeySource.itemKey,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context: component.BuildContext = undefined;
    context.allocator = arena.allocator();
    try std.testing.expectError(error.InvalidConfiguration, list.build(&context));
    keys.key = std.math.maxInt(u64);
    try std.testing.expectError(error.InvalidConfiguration, list.build(&context));
    keys.key = 44;
    try std.testing.expectError(error.InvalidConfiguration, list.build(&context));
}

test "virtual list defaults to index keys and enforces visible item budget" {
    const ItemContext = struct {};
    const List = VirtualList(ItemContext);
    const buildItem = struct {
        fn build(_: *ItemContext, _: usize, _: *component.BuildContext) Error!node.Spec {
            return .{ .kind = .container };
        }
    }.build;

    var heights = try HeightIndex.init(std.testing.allocator, 3, 10);
    defer heights.deinit();
    var item_context = ItemContext{};
    var list = List{ .item_context = &item_context, .build_item = buildItem, .heights = &heights, .viewport_height = 10, .overscan_pixels = 0 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context: component.BuildContext = undefined;
    context.allocator = arena.allocator();
    const spec = try list.build(&context);
    try std.testing.expectEqual(@as(?u64, 1), spec.children[0].children[0].key);
    try std.testing.expectEqual(@as(?u64, 2), spec.children[0].children[1].key);
    try std.testing.expectEqual(@as(?u64, 3), spec.children[0].children[2].key);
    list.maximum_visible_items = 2;
    try std.testing.expectError(error.BudgetExceeded, list.build(&context));
}
