const std = @import("std");
const ui = @import("zigui");

const Probe = struct {
    text_calls: usize = 0,
    baseline: ?f32 = null,

    fn text(
        raw: *anyopaque,
        value: []const u8,
        _: ui.style.TextStyle,
        constraints: ui.layout.Constraints,
    ) ui.Error!ui.layout_engine.TextMeasure {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.text_calls += 1;
        return .{ .baseline = self.baseline, .size = constraints.constrain(.{
            .width = @as(f32, @floatFromInt(value.len * 8)),
            .height = 12,
        }) };
    }

    fn customMeasure(
        _: *anyopaque,
        _: []const u8,
        _: ui.style.TextStyle,
        _: ui.layout.Constraints,
    ) ui.Error!ui.Size {
        return .zero;
    }
};

test "retained measure preserves the final baseline of a centered row" {
    var store = ui.NodeStore.initWithLimits(std.testing.allocator, .{ .retain_frame_work = true });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var probe: Probe = .{ .baseline = 8 };
    var engine = try makeEngine(arena.allocator(), &probe);
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row, .align_items = .baseline, .align_content = .center } },
        .children = &.{.{ .kind = .{ .text = "hi" } }},
    }, 1, arena.allocator());
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const first = store.getConst(root).?.layout;
    try std.testing.expectEqual(@as(?f32, 52), first.baseline);
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    try std.testing.expectEqualDeep(first, store.getConst(root).?.layout);
}

fn makeEngine(scratch: std.mem.Allocator, probe: *Probe) !ui.LayoutEngine {
    return .{
        .scratch = scratch,
        .scale_factor = try ui.ScaleFactor.init(1),
        .retain_frame_work = true,
        .measures = .{
            .context = probe,
            .text_fn = Probe.text,
            .custom_measure_fn = Probe.customMeasure,
        },
    };
}

test "retained layout reuses a stable subtree and follows reconciliation revisions" {
    var store = ui.NodeStore.initWithLimits(std.testing.allocator, .{ .retain_frame_work = true });
    defer store.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var probe = Probe{};
    var engine = try makeEngine(scratch, &probe);
    const first_spec = ui.NodeSpec{ .children = &.{.{ .kind = .{ .text = "hello" } }} };
    const root = try store.reconcile(null, .invalid, .invalid, first_spec, 1, scratch);
    try engine.layout(&store, root, .{ .width = 100, .height = 40 });
    const first_calls = probe.text_calls;
    try std.testing.expect(first_calls > 0);

    try engine.layout(&store, root, .{ .width = 100, .height = 40 });
    try std.testing.expectEqual(first_calls, probe.text_calls);

    const second_spec = ui.NodeSpec{ .children = &.{.{ .kind = .{ .text = "hello, retained" } }} };
    _ = try store.reconcile(root, .invalid, .invalid, second_spec, 1, scratch);
    try engine.layout(&store, root, .{ .width = 100, .height = 40 });
    try std.testing.expect(probe.text_calls > first_calls);
}

test "retained measure cache keeps alternating constraints and clears on revision" {
    var store = ui.NodeStore.initWithLimits(std.testing.allocator, .{ .retain_frame_work = true });
    defer store.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var probe = Probe{};
    var engine = try makeEngine(scratch, &probe);
    const initial = ui.NodeSpec{ .children = &.{.{ .key = 7, .kind = .{ .text = "cached text" } }} };
    const root = try store.reconcile(null, .invalid, .invalid, initial, 1, scratch);
    const child = store.getConst(root).?.children.items[0];
    const constraints = [_]ui.layout.Constraints{
        .{ .maximum = .{ .width = 40, .height = 40 } },
        .{ .maximum = .{ .width = 80, .height = 40 } },
        .{ .maximum = .{ .width = 120, .height = 40 } },
        .{ .maximum = .{ .width = 160, .height = 40 } },
    };
    for (constraints) |value| _ = try engine.measureNode(&store, child, value);
    const populated_calls = probe.text_calls;
    try std.testing.expectEqual(@as(usize, constraints.len), populated_calls);

    for (0..8) |_| {
        _ = try engine.measureNode(&store, child, constraints[0]);
        _ = try engine.measureNode(&store, child, constraints[1]);
    }
    try std.testing.expectEqual(populated_calls, probe.text_calls);

    const updated = ui.NodeSpec{ .children = &.{.{ .key = 7, .kind = .{ .text = "revised text" } }} };
    _ = try store.reconcile(root, .invalid, .invalid, updated, 1, scratch);
    const before_revision_calls = probe.text_calls;
    for (constraints) |value| _ = try engine.measureNode(&store, child, value);
    try std.testing.expectEqual(before_revision_calls + constraints.len, probe.text_calls);
    for (constraints) |value| _ = try engine.measureNode(&store, child, value);
    try std.testing.expectEqual(before_revision_calls + constraints.len, probe.text_calls);
}

test "retained reconciliation rollback restores revisions eligibility and layout" {
    var store = ui.NodeStore.initWithLimits(std.testing.allocator, .{ .retain_frame_work = true });
    defer store.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    var probe = Probe{};
    var engine = try makeEngine(scratch, &probe);
    const initial_children = [_]ui.NodeSpec{
        .{ .key = 10, .kind = .{ .text = "before" } },
        .{ .key = 20, .kind = .{ .text = "sibling" } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &initial_children }, 1, scratch);
    try engine.layout(&store, root, .{ .width = 160, .height = 40 });
    const first_calls = probe.text_calls;

    const initial_root = store.getConst(root).?;
    const first_child = initial_root.children.items[0];
    const second_child = initial_root.children.items[1];
    const root_revision = initial_root.revision;
    const root_subtree_revision = initial_root.subtree_revision;
    const root_retention_safe = initial_root.retention_safe;
    const first_revision = store.getConst(first_child).?.revision;
    const first_subtree_revision = store.getConst(first_child).?.subtree_revision;
    const first_retention_safe = store.getConst(first_child).?.retention_safe;
    const root_layout = initial_root.layout;
    const first_layout = store.getConst(first_child).?.layout;
    const second_layout = store.getConst(second_child).?.layout;

    // The first child mutates the retained tree before the duplicate key
    // makes reconciliation fail. Rollback must restore the old transaction
    // state, including the eligibility bit that the portal style invalidates.
    const failing_children = [_]ui.NodeSpec{
        .{
            .key = 10,
            .kind = .{ .text = "changed" },
            .style = .{ .layout = .{ .portal = .{ .target = .anchor } } },
        },
        .{ .key = 10, .kind = .{ .text = "duplicate" } },
    };
    try std.testing.expectError(
        error.InvalidConfiguration,
        store.reconcile(
            root,
            .invalid,
            .invalid,
            .{
                .style = .{ .layout = .{ .width = .{ .points = 120 } } },
                .children = &failing_children,
            },
            1,
            scratch,
        ),
    );

    const rolled_back_root = store.getConst(root).?;
    try std.testing.expectEqual(root_revision, rolled_back_root.revision);
    try std.testing.expectEqual(root_subtree_revision, rolled_back_root.subtree_revision);
    try std.testing.expectEqual(root_retention_safe, rolled_back_root.retention_safe);
    const rolled_back_first = store.getConst(first_child).?;
    try std.testing.expectEqual(first_revision, rolled_back_first.revision);
    try std.testing.expectEqual(first_subtree_revision, rolled_back_first.subtree_revision);
    try std.testing.expectEqual(first_retention_safe, rolled_back_first.retention_safe);
    try std.testing.expectEqual(root_layout, rolled_back_root.layout);
    try std.testing.expectEqual(first_layout, rolled_back_first.layout);
    try std.testing.expectEqual(second_layout, store.getConst(second_child).?.layout);

    try engine.layout(&store, root, .{ .width = 160, .height = 40 });
    try std.testing.expectEqual(first_calls, probe.text_calls);
    try std.testing.expectEqual(root_layout, store.getConst(root).?.layout);
    try std.testing.expectEqual(first_layout, store.getConst(first_child).?.layout);
    try std.testing.expectEqual(second_layout, store.getConst(second_child).?.layout);
}

test "retained subtree revision advances once for multiple changed descendants" {
    var store = ui.NodeStore.initWithLimits(std.testing.allocator, .{ .retain_frame_work = true });
    defer store.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();

    const initial_children = [_]ui.NodeSpec{
        .{ .key = 1, .kind = .{ .text = "first" } },
        .{ .key = 2, .kind = .{ .text = "second" } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &initial_children }, 1, scratch);
    const initial_root = store.getConst(root).?;
    const first_child = initial_root.children.items[0];
    const second_child = initial_root.children.items[1];
    const root_revision = initial_root.revision;
    const root_subtree_revision = initial_root.subtree_revision;
    const first_revision = store.getConst(first_child).?.revision;
    const second_revision = store.getConst(second_child).?.revision;

    const changed_children = [_]ui.NodeSpec{
        .{ .key = 1, .kind = .{ .text = "first changed" } },
        .{ .key = 2, .kind = .{ .text = "second changed" } },
    };
    _ = try store.reconcile(root, .invalid, .invalid, .{ .children = &changed_children }, 1, scratch);

    try std.testing.expectEqual(root_revision, store.getConst(root).?.revision);
    try std.testing.expectEqual(root_subtree_revision + 1, store.getConst(root).?.subtree_revision);
    try std.testing.expectEqual(first_revision + 1, store.getConst(first_child).?.revision);
    try std.testing.expectEqual(second_revision + 1, store.getConst(second_child).?.revision);
}

test "portal descendants disable retained subtree layout" {
    var store = ui.NodeStore.initWithLimits(std.testing.allocator, .{ .retain_frame_work = true });
    defer store.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    const portal_spec = ui.NodeSpec{
        .style = .{ .layout = .{ .portal = .{ .target = .anchor } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &.{portal_spec} }, 1, scratch_arena.allocator());
    try std.testing.expect(!store.getConst(root).?.retention_safe);
}

test "explicit retained work invalidation covers mutable NodeStore access" {
    var store = ui.NodeStore.initWithLimits(std.testing.allocator, .{ .retain_frame_work = true });
    defer store.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    var probe = Probe{};
    var engine = try makeEngine(scratch, &probe);
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &.{.{ .kind = .{ .text = "hello" } }} }, 1, scratch);
    try engine.layout(&store, root, .{ .width = 100, .height = 40 });
    const first_calls = probe.text_calls;
    store.get(root).?.style.layout.value.width = .{ .points = 80 };
    store.invalidateRetainedWork();
    try engine.layout(&store, root, .{ .width = 100, .height = 40 });
    try std.testing.expect(probe.text_calls > first_calls);
}

test "explicit invalidation rebuilds retention eligibility after direct portal mutation" {
    var store = ui.NodeStore.initWithLimits(std.testing.allocator, .{ .retain_frame_work = true });
    defer store.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    const scratch = scratch_arena.allocator();
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &.{.{}} }, 1, scratch);
    const child = store.getConst(root).?.children.items[0];
    try std.testing.expect(store.getConst(root).?.retention_safe);
    store.get(child).?.style.layout.value.portal.target = .anchor;
    store.invalidateRetainedWork();
    try std.testing.expect(!store.getConst(root).?.retention_safe);
}
