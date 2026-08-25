const std = @import("std");
const ui = @import("zigui");

const testing = std.testing;
const handles = ui.core.handles;

test "generational handles reject stale identities and reuse slots" {
    const Pool = handles.SlotPool(u32, handles.NodeId);
    var pool = Pool.init(testing.allocator);
    defer pool.deinit();

    const first = try pool.insert(41);
    try testing.expect(first.isValid());
    try testing.expectEqual(@as(u32, 41), pool.get(first).?.*);
    try testing.expectEqual(@as(u32, 41), pool.remove(first).?);
    try testing.expect(!pool.contains(first));

    const second = try pool.insert(73);
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);
    try testing.expect(pool.get(first) == null);
    try testing.expectEqual(@as(u32, 73), pool.get(second).?.*);
}

test "state writes advance versions and destroyed state stays invalid" {
    var store = ui.runtime_state.Store.init(testing.allocator);
    defer store.deinit();

    const owner = handles.ComponentId.init(4, 1);
    const value = try store.create(u32, owner, 8);
    try testing.expectEqual(@as(u64, 1), try store.version(value.id));
    try testing.expectEqual(@as(u32, 8), (try store.read(u32, value, null)).*);

    var write = try store.beginWrite(u32, value);
    write.value().* = 13;
    write.deinit();
    try testing.expectEqual(@as(u64, 2), try store.version(value.id));
    try testing.expectEqual(@as(u32, 13), (try store.read(u32, value, null)).*);

    try store.destroy(u32, value);
    try testing.expectError(error.InvalidHandle, store.version(value.id));
    try testing.expectError(error.InvalidHandle, store.read(u32, value, null));
}

test "state dependencies invalidate only recorded retained components" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component = handles.ComponentId.init(2, 1);
    const window = handles.WindowId.init(3, 1);
    try coordinator.invalidations.register(component, window);
    _ = coordinator.invalidations.consumeComponent(component);
    _ = coordinator.invalidations.consumeWindow(window);

    const state = try coordinator.states.create(u32, component, 5);
    var dependencies = try coordinator.beginComponentDependencies(component, testing.allocator);
    defer dependencies.deinit();
    _ = try coordinator.states.read(u32, state, dependencies.sink());
    try dependencies.finish();

    var write = try coordinator.states.beginWrite(u32, state);
    write.value().* = 6;
    write.deinit();
    var update = try coordinator.beginUpdate();
    try update.deinit();
    try testing.expect(coordinator.invalidations.isWindowDirty(window));
    try testing.expect(coordinator.invalidations.consumeComponent(component).?.compose);
}

const WindowCompositionProbe = struct {
    builds: usize = 0,

    pub fn build(self: *WindowCompositionProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.builds +|= 1;
        return .{ .kind = .spacer };
    }
};

const LargeInitialTree = struct {
    pub fn build(_: *LargeInitialTree, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const children = try ctx.allocator.alloc(ui.NodeSpec, 2_048);
        for (children) |*child| child.* = .{ .kind = .spacer };
        return .{ .children = children };
    }
};

test "initial reconciliation keeps compact undo entries within the default frame arena" {
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "large initial reconciliation test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;

    var model: LargeInitialTree = .{};
    _ = try app.openWindow(.{ .platform = .{ .title = "large tree" } }, ui.Component.Descriptor.from(LargeInitialTree, &model));
    while (try app.step(false)) {}
    try testing.expectEqual(@as(u64, 1), (try app.metricsSnapshot()).frames_submitted);
}

test "whole-window invalidation rebuilds only that window's components" {
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "window composition invalidation test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;

    var first: WindowCompositionProbe = .{};
    var second: WindowCompositionProbe = .{};
    _ = try app.openWindow(.{ .platform = .{ .title = "first" } }, ui.Component.Descriptor.from(WindowCompositionProbe, &first));
    const second_window = try app.openWindow(.{ .platform = .{ .title = "second" } }, ui.Component.Descriptor.from(WindowCompositionProbe, &second));
    while (try app.step(false)) {}

    const first_builds = first.builds;
    const second_builds = second.builds;
    try app.invalidateWindow(second_window);
    while (try app.step(false)) {}

    try testing.expectEqual(first_builds, first.builds);
    try testing.expectEqual(second_builds + 1, second.builds);
}

test "a frame token cannot consume invalidation raised during that frame" {
    var counters: ui.core.metrics.Counters = .{};
    var tracker = ui.runtime_invalidation.Tracker.init(testing.allocator, &counters);
    defer tracker.deinit();
    const component = handles.ComponentId.init(2, 1);
    const window = handles.WindowId.init(3, 1);
    try tracker.register(component, window);
    const token = tracker.windowToken(window).?;
    try testing.expect(!tracker.markWindow(window));
    try testing.expect(!tracker.consumeWindowToken(window, token));
    try testing.expect(tracker.isWindowDirty(window));
    const latest = tracker.windowToken(window).?;
    try testing.expect(tracker.consumeWindowToken(window, latest));
    try testing.expect(!tracker.isWindowDirty(window));
}

test "bounded queues preserve order, capacity, and shutdown" {
    try testing.expectError(error.InvalidConfiguration, ui.runtime_queue.BoundedQueue(u8).init(testing.allocator, 0));

    var queue = try ui.runtime_queue.BoundedQueue(u8).init(testing.allocator, 2);
    defer queue.deinit();

    try queue.tryPush(1);
    try queue.tryPush(2);
    try testing.expectError(error.QueueFull, queue.tryPush(3));
    try testing.expectEqual(@as(?u8, 1), queue.pop());
    try queue.tryPush(3);
    try testing.expectEqual(@as(?u8, 2), queue.pop());
    try testing.expectEqual(@as(?u8, 3), queue.pop());
    try testing.expectEqual(@as(?u8, null), queue.pop());
    queue.close();
    try testing.expectError(error.Shutdown, queue.tryPush(4));
}

test "task completions apply and release exactly once across terminal states" {
    var registry = ui.runtime_task.Registry.init(testing.allocator);
    defer registry.deinit();
    const component = handles.ComponentId.init(4, 1);
    const window = handles.WindowId.init(8, 1);

    var applied_probe: CompletionProbe = .{};
    const active = try registry.create(component, window);
    const applied = registry.finish(applied_probe.completion(active.id));
    switch (applied) {
        .applied => |owner| try testing.expect(owner.eql(window)),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 1), applied_probe.applied);
    try testing.expectEqual(@as(u32, 1), applied_probe.dropped);
    try testing.expect(!registry.contains(active.id));

    var cancelled_probe: CompletionProbe = .{};
    const cancelled = try registry.create(component, window);
    registry.cancel(cancelled.id);
    switch (registry.finish(cancelled_probe.completion(cancelled.id))) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 0), cancelled_probe.applied);
    try testing.expectEqual(@as(u32, 1), cancelled_probe.dropped);

    var stale_probe: CompletionProbe = .{};
    switch (registry.finish(stale_probe.completion(handles.TaskId.init(99, 7)))) {
        .stale => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 0), stale_probe.applied);
    try testing.expectEqual(@as(u32, 1), stale_probe.dropped);
}

test "affine transforms invert and pixel snapping is scale aware" {
    const transform = ui.Affine2D.mul(
        ui.Affine2D.translation(.{ .x = 7, .y = -3 }),
        ui.Affine2D.scale(2, 4),
    );
    const point: ui.Point = .{ .x = 5, .y = 6 };
    const world = transform.transformPoint(point);
    const restored = transform.inverse().?.transformPoint(world);
    try testing.expectApproxEqAbs(point.x, restored.x, 0.0001);
    try testing.expectApproxEqAbs(point.y, restored.y, 0.0001);

    const scale = try ui.ScaleFactor.init(2);
    try testing.expectApproxEqAbs(@as(f32, 1.5), ui.core.geometry.snap(1.37, scale, .nearest), 0.0001);
    try testing.expect(ui.Affine2D.scale(0, 1).inverse() == null);
}

test "memory budgets and tracked allocations account live bytes" {
    var counters: ui.core.metrics.Counters = .{};
    var budget: ui.core.memory.Budget = .{ .limit = 128 };
    var tracked = ui.core.TrackedAllocator.init(testing.allocator, &counters, &budget);
    const allocator = tracked.allocator();

    const bytes = try allocator.alloc(u8, 32);
    try testing.expectEqual(@as(usize, 32), budget.used);
    try testing.expectEqual(@as(u64, 32), tracked.snapshot().live_bytes);
    allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), budget.used);
    try testing.expectEqual(@as(u64, 0), tracked.snapshot().live_bytes);
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 129));
    try testing.expectEqual(@as(u64, 1), budget.denied);
}

test "frame arenas defer requested resets until scopes close" {
    var frame = try ui.core.memory.FrameArena.init(testing.allocator, 4096);
    defer frame.deinit();
    const original_generation = frame.generation;

    var scope = frame.enter();
    const allocation = try scope.allocator().alloc(u8, 64);
    @memset(allocation, 0xaa);
    try testing.expectError(error.OutOfMemory, scope.allocator().alloc(u8, 4097));
    try testing.expectEqual(@as(usize, 4096), frame.limit());
    frame.requestReset();
    try testing.expectEqual(original_generation, frame.generation);
    scope.deinit();
    try testing.expect(frame.generation != original_generation);
}

test "Unicode normalization, graphemes, bidi, and line breaks share generated data" {
    const decomposed = "e\xcc\x81";
    const normalized = try ui.unicode.normalize(testing.allocator, decomposed, .nfc);
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings("\xc3\xa9", normalized);
    try testing.expect(try ui.unicode.isNormalized(testing.allocator, normalized, .nfc));

    const family = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7";
    var graphemes: ui.unicode.GraphemeIterator = .{ .bytes = family };
    try testing.expectEqualStrings(family, (try graphemes.next()).?);
    try testing.expect((try graphemes.next()) == null);

    const scalars = [_]u21{ 'a', 0x05d0, 0x05d1 };
    var bidi = try ui.unicode.resolveBidi(testing.allocator, &scalars, null);
    defer bidi.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, scalars.len), bidi.visual_to_logical.len);

    var breaks = try ui.unicode.analyzeLineBreaks(testing.allocator, "hello world");
    defer breaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, "hello world".len + 1), breaks.boundaries.len);
}

test "QOI decoding and orientation are deterministic and bounded" {
    const qoi = [_]u8{
        'q',  'o',  'i',  'f',
        0,    0,    0,    1,
        0,    0,    0,    1,
        4,    0,    0xff, 0x12,
        0x34, 0x56, 0x78, 0,
        0,    0,    0,    0,
        0,    0,    1,
    };
    var decoded = try ui.image.decode(testing.allocator, &qoi, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), decoded.width);
    try testing.expectEqual(@as(u32, 1), decoded.height);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, decoded.pixels);

    try testing.expectError(error.BudgetExceeded, ui.image.decode(testing.allocator, &qoi, .{ .maximum_compressed_bytes = 8 }));
}

test "font and image readers reject truncated and hostile offsets" {
    try testing.expectError(error.InvalidFont, ui.opentype.Font.init(&.{}, 0));
    try testing.expectError(error.InvalidFont, ui.opentype.Font.init(&.{
        0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    }, 0));
    try testing.expectError(error.InvalidFont, ui.opentype.Font.faceCount(&.{
        't', 't', 'c', 'f', 0, 1, 0, 0, 0, 0, 0x10, 1,
    }));
    try testing.expectError(error.InvalidFont, ui.opentype.readU16(&.{ 0, 1 }, std.math.maxInt(usize)));
    try testing.expectError(error.InvalidFont, ui.opentype.readU32(&.{ 0, 1, 2, 3 }, std.math.maxInt(usize)));

    const malformed = [_][]const u8{
        &.{ 137, 80, 78, 71, 13, 10, 26, 10 },
        &.{ 0xff, 0xd8, 0xff, 0xd9 },
        "GIF89a",
        "BM",
        "qoif",
    };
    for (malformed) |source| {
        if (ui.image.decode(testing.allocator, source, .{})) |decoded_value| {
            var decoded = decoded_value;
            decoded.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "scene validation preserves operation ordering and bounds nesting depth" {
    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();

    const material = try builder.solidMaterial(ui.Color.rgba(1, 0, 0, 1));
    _ = try builder.pushLayer(0.75, .normal, ui.Affine2D.translation(.{ .x = 2, .y = 3 }));
    _ = try builder.pushClip(ui.Rect.fromXYWH(0, 0, 20, 20), ui.CornerRadii.all(4));
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 20, 20),
        .background = .transparent,
        .border_color = .transparent,
        .border_widths = .{},
        .radii = ui.CornerRadii.all(4),
    }, material);
    try builder.popClip();
    try builder.popLayer();
    try builder.finish();
    try testing.expectEqual(@as(usize, 5), scene.operations.items.len);

    var too_deep_scene = ui.scene.Scene.init(testing.allocator);
    defer too_deep_scene.deinit();
    var too_deep = ui.scene.Builder.init(&too_deep_scene, .{});
    defer too_deep.deinit();
    var depth: usize = 0;
    while (depth < 63) : (depth += 1)
        _ = try too_deep.pushClip(ui.Rect.fromXYWH(0, 0, 10, 10), .{});
    try testing.expectError(error.InvalidScene, too_deep.pushClip(ui.Rect.fromXYWH(0, 0, 10, 10), .{}));
    while (depth != 0) {
        depth -= 1;
        try too_deep.popClip();
    }
    try too_deep.finish();
}

test "scene builder leaves no partial primitive when allocation fails" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var scene = ui.scene.Scene.init(failing.allocator());
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try testing.expectError(error.OutOfMemory, builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .background = ui.Color.white,
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null));
    try testing.expectEqual(@as(usize, 0), scene.operations.items.len);
    try testing.expectEqual(@as(usize, 0), scene.quads.items.len);
}

test "null renderer respects affine rounded clips and produces readback" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();

    _ = try builder.pushLayer(1, .normal, ui.Affine2D.translation(.{ .x = 2, .y = 2 }));
    _ = try builder.pushClip(ui.Rect.fromXYWH(0, 0, 8, 8), ui.CornerRadii.all(3));
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 8, 8),
        .background = ui.Color.rgba(1, 0, 0, 1),
        .border_color = ui.Color.rgba(0, 0, 1, 1),
        .border_widths = ui.Insets.all(1),
        .radii = ui.CornerRadii.all(3),
    }, null);
    try builder.popClip();
    try builder.popLayer();
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 12,
        .height = 12,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);

    try testing.expect(pixel(readback, 6, 6)[0] > 240);
    try testing.expectEqual(@as(u8, 0), pixel(readback, 0, 0)[3]);
    try testing.expect(pixel(readback, 2, 2)[3] < 128);
}

test "null renderer samples scaled textures bilinearly" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    const texture = handles.TextureId.init(9, 1);
    try renderer.createTexture(texture, .{ .width = 2, .height = 2, .format = .rgba8 });
    defer renderer.destroyTexture(texture, 0) catch {};
    const texels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    try renderer.writeTexture(texture, .{ .width = 2, .height = 2 }, &texels, 8);

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.colorSprite(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .uv_bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
        .color = .white,
        .texture = texture.encode(),
        .tile_generation = texture.generation,
        .format = @backingInt(ui.scene_abi.TextureFormat.rgba8),
    });
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 4,
        .height = 4,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    const center = pixel(readback, 1, 1);
    try testing.expect(center[0] > 20 and center[1] > 20 and center[2] > 20);
    try testing.expectEqual(@as(u8, 255), center[3]);
}

test "resource retirement obeys submission epochs and memory budgets" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var resources = ui.resources.Manager.init(testing.allocator, 256, 256);
    defer resources.deinit();

    var pixels: [64]u8 = undefined;
    @memset(&pixels, 0x7f);
    const texture = try resources.createTexture(.{ .width = 4, .height = 4, .format = .rgba8 }, &pixels, true);
    try resources.realize(renderer, texture);
    try resources.markUsed(texture, 5);
    try testing.expectEqual(@as(usize, 64), resources.stats().gpu_reserved);
    try resources.destroyTextureOnRenderer(renderer, texture);
    resources.collect(4);
    try testing.expectEqual(@as(usize, 1), resources.stats().retired_textures);
    resources.collect(5);
    try testing.expectEqual(@as(usize, 0), resources.stats().retired_textures);
    try testing.expectEqual(@as(usize, 0), resources.stats().gpu_reserved);

    try testing.expectError(error.BudgetExceeded, resources.createTexture(.{ .width = 9, .height = 9, .format = .rgba8 }, null, false));
}

test "atlas tiles cannot be reused before their completed submission" {
    var resources = ui.resources.Manager.init(testing.allocator, 1024, 0);
    defer resources.deinit();
    var atlas = try ui.atlas.Atlas.init(testing.allocator, &resources, 4, 1, .a8);
    defer atlas.deinit();

    const first = try atlas.allocate(4, 4, 1, 0);
    try atlas.markUsed(first, 1, 3);
    try atlas.release(first);
    try testing.expectError(error.AtlasFull, atlas.allocate(4, 4, 2, 2));
    const second = try atlas.allocate(4, 4, 2, 3);
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);

    resources.deviceLost();
    try atlas.deviceLost();
    try testing.expect(atlas.get(second) == null);
}

test "atlas tiles selected by a scene cannot be evicted later in that frame" {
    var resources = ui.resources.Manager.init(testing.allocator, 1024, 0);
    defer resources.deinit();
    var atlas = try ui.atlas.Atlas.init(testing.allocator, &resources, 4, 1, .a8);
    defer atlas.deinit();

    const first = try atlas.allocate(4, 4, 7, 0);
    try atlas.touch(first, 7);
    try testing.expectError(error.AtlasFull, atlas.allocate(4, 4, 7, 0));
    const next_frame = try atlas.allocate(4, 4, 8, 0);
    try testing.expectEqual(first.index, next_frame.index);
    try testing.expect(first.generation != next_frame.generation);
}

test "retained reconciliation preserves keyed node identity across reorder" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const first_children = [_]ui.NodeSpec{
        (ui.NodeSpec{ .kind = .{ .text = "first" } }).withKey(11),
        (ui.NodeSpec{ .kind = .{ .text = "second" } }).withKey(22),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &first_children }, 1, scratch.allocator());
    const original = store.get(root).?.children.items;
    const first_id = original[0];
    const second_id = original[1];

    const reordered = [_]ui.NodeSpec{
        (ui.NodeSpec{ .kind = .{ .text = "second changed" } }).withKey(22),
        (ui.NodeSpec{ .kind = .{ .text = "first changed" } }).withKey(11),
    };
    const same_root = try store.reconcile(root, .invalid, .invalid, .{ .children = &reordered }, 1, scratch.allocator());
    try testing.expect(root.eql(same_root));
    const children = store.get(root).?.children.items;
    try testing.expect(children[0].eql(second_id));
    try testing.expect(children[1].eql(first_id));
}

test "retained reconciliation has a strong allocation-failure guarantee" {
    try checkReconcileAllocationFailures(testing.allocator);
}

test "SVG document ownership transfers exactly once across allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, svgManagerAllocationProbe, .{});
}

test "component children have explicit ownership mount and recursive destruction" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    var nodes = ui.NodeStore.init(testing.allocator);
    defer nodes.deinit();
    var components = ui.Component.Store.init(testing.allocator);
    defer components.deinit();

    var parent_probe: ComponentProbe = .{};
    var child_probe: ComponentProbe = .{};
    const window = handles.WindowId.init(1, 1);
    const parent = try components.create(parent_probe.descriptor(), window);
    const anchor = try nodes.createAnchor(1);
    try components.attach(parent, anchor);
    _ = try components.markRegistered(parent);
    try coordinator.invalidations.register(parent, window);

    const child = try components.createChild(child_probe.descriptor(), window, parent);
    try testing.expect(components.isChildOf(child, parent));
    try testing.expect(try components.mount(child, anchor, parent));
    _ = try components.markRegistered(child);
    try coordinator.invalidations.register(child, window);

    components.destroy(parent, &nodes, &coordinator);
    try testing.expect(!components.contains(parent));
    try testing.expect(!components.contains(child));
    try testing.expectEqual(@as(u32, 1), parent_probe.dropped);
    try testing.expectEqual(@as(u32, 1), child_probe.dropped);
}

test "input handler failures propagate through retained dispatch" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    var nodes = ui.NodeStore.init(testing.allocator);
    defer nodes.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var handler_context: u8 = 0;
    const handlers = [_]ui.input.Handler{.{
        .context = &handler_context,
        .callback = failingHandler,
        .phase = .target,
    }};
    const root = try nodes.reconcile(null, .invalid, .invalid, .{ .handlers = &handlers }, 1, scratch.allocator());
    var hits = ui.hit_testing.Tree.init(testing.allocator);
    defer hits.deinit();
    var focus_manager = ui.focus.Manager.init(testing.allocator);
    defer focus_manager.deinit();
    var actions = ui.actions.Registry.init(testing.allocator);
    defer actions.deinit();
    var router = ui.InputRouter.init(testing.allocator, handles.WindowId.init(1, 1), root, &hits, &focus_manager, &actions);
    defer router.deinit();
    const value: ui.input.Event = .focus_in;
    try testing.expectError(error.BudgetExceeded, router.dispatchTo(&nodes, &coordinator, root, &value, scratch.allocator()));
}

test "application path budgets reject unbounded tessellation work" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.path_edge_count = 16;
    memory.path_work_units = 1;
    const renderer = try ui.NullRenderer.createWithMemory(testing.allocator, memory);
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    const vertices = [_]ui.scene_abi.PathVertex{
        .{ .position = .{ .x = 1, .y = 1 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.move_to) },
        .{ .position = .{ .x = 7, .y = 1 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.line_to) },
        .{ .position = .{ .x = 7, .y = 7 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.line_to) },
        .{ .position = .{ .x = 1, .y = 7 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.line_to) },
        .{ .position = .{ .x = 1, .y = 1 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.close) },
    };
    try builder.path(.{
        .vertex_start = 0,
        .vertex_count = 0,
        .fill_rule = @backingInt(ui.scene_abi.FillRule.non_zero),
        .color = ui.Color.white,
        .bounds = ui.Rect.fromXYWH(1, 1, 6, 6),
    }, &vertices, null);
    try builder.finish();
    try testing.expectError(error.BudgetExceeded, renderer.renderOffscreen(.{
        .width = 8,
        .height = 8,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator));
}

test "application configuration validates every path work boundary" {
    var missing_edges: ui.config.AppConfig = .{};
    missing_edges.memory.path_edge_count = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(missing_edges));
    var missing_work: ui.config.AppConfig = .{};
    missing_work.memory.path_work_units = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(missing_work));
}

test "layout, hit testing, focus, and accessibility share retained identities" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        (ui.NodeSpec{
            .kind = .spacer,
            .style = .{
                .layout = .{ .width = .{ .points = 40 }, .height = .{ .points = 30 } },
                .paint = .{ .radii = ui.CornerRadii.all(8) },
                .interaction = .{ .focusable = true, .tab_index = 2 },
            },
            .semantics = .{ .role = .button, .label = "later" },
        }).withKey(11),
        (ui.NodeSpec{
            .kind = .spacer,
            .style = .{
                .layout = .{ .width = .{ .points = 60 }, .height = .{ .points = 30 } },
                .interaction = .{ .focusable = true, .tab_index = 1 },
            },
            .semantics = .{ .role = .button, .label = "first" },
        }).withKey(22),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row, .gap = .{ .width = 5 } } },
        .children = &children,
    }, 1, scratch.allocator());

    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 120, .height = 40 });
    const retained_children = store.get(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 0), store.get(retained_children[0]).?.layout.bounds.origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 45), store.get(retained_children[1]).?.layout.bounds.origin.x, 0.001);

    var hit_tree = ui.hit_testing.Tree.init(testing.allocator);
    defer hit_tree.deinit();
    try hit_tree.rebuild(&store, root);
    try testing.expect(hit_tree.hit(.{ .x = 50, .y = 10 }).?.target.eql(retained_children[1]));

    var focus = ui.focus.Manager.init(testing.allocator);
    defer focus.deinit();
    try focus.rebuild(&store, root);
    try testing.expect(focus.move(&store, .forward).?.eql(retained_children[1]));
    try testing.expect(focus.move(&store, .forward).?.eql(retained_children[0]));

    var accessibility = ui.AccessibilityTree.init(testing.allocator, handles.WindowId.init(1, 1));
    defer accessibility.deinit();
    const first_tree = try accessibility.build(&store, root, retained_children[1], scratch.allocator());
    const semantic = accessibility.semanticForNode(retained_children[1]).?;
    try testing.expect(first_tree.nodes.len >= 3);
    const second_tree = try accessibility.build(&store, root, retained_children[1], scratch.allocator());
    try testing.expectEqual(first_tree.root.encode(), second_tree.root.encode());
    try testing.expectEqual(semantic.encode(), accessibility.semanticForNode(retained_children[1]).?.encode());
    try testing.expect(accessibility.nodeForSemantic(semantic).?.eql(retained_children[1]));
}

test "flex redistribution honors constrained children without leaving free space" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 50 },
            .height = .{ .points = 20 },
            .max_width = .{ .points = 60 },
            .flex_grow = 1,
        } } },
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 50 },
            .height = .{ .points = 20 },
            .flex_grow = 1,
        } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 300, .height = 40 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 60), store.getConst(retained[0]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 240), store.getConst(retained[1]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 300), store.getConst(retained[1]).?.layout.bounds.maxX(), 0.001);
}

test "flex shrink redistributes overflow after a child reaches its minimum" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 100 },
            .height = .{ .points = 20 },
            .min_width = .{ .points = 90 },
        } } },
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 100 },
            .height = .{ .points = 20 },
        } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 40 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 90), store.getConst(retained[0]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), store.getConst(retained[1]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100), store.getConst(retained[1]).?.layout.bounds.maxX(), 0.001);
}

test "scrolling flex containers preserve overflowing main-axis content" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        .{ .kind = .spacer, .style = .{ .layout = .{ .height = .{ .points = 80 } } } },
        .{ .kind = .spacer, .style = .{ .layout = .{ .height = .{ .points = 80 } } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .kind = .{ .scroll = .{ .vertical = true } },
        .style = .{ .layout = .{ .direction = .column, .overflow_y = .scroll } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 80), store.getConst(retained[0]).?.layout.bounds.size.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80), store.getConst(retained[1]).?.layout.bounds.size.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80), store.getConst(retained[1]).?.layout.bounds.origin.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 160), store.getConst(root).?.layout.scroll_extent.height, 0.001);
}

test "flex remeasures wrapped content at its allocated main size" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        .{ .kind = .{ .text = "abcdefghijklmnopqrst" } },
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 50 },
            .height = .{ .points = 10 },
            .flex_shrink = 0,
        } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row, .align_items = .start } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = wrappingTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const retained = store.getConst(root).?.children.items;
    const text = store.getConst(retained[0]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 50), text.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), text.size.height, 0.001);
}

test "text baselines clamp when exact constraints clip line height" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const root = try store.reconcile(null, .invalid, .invalid, .{
        .kind = .{ .text = "clipped" },
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = clippedTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };

    try engine.layout(&store, root, .{ .width = 32, .height = 6 });
    const record = store.getConst(root).?;
    try testing.expectApproxEqAbs(@as(f32, 6), record.layout.bounds.size.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 6), record.layout.baseline.?, 0.001);
}

test "fractional grid tracks redistribute around intrinsic minimums" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const tracks = [_]ui.layout.GridTrack{
        .{ .minmax = .{ .min = .{ .points = 80 }, .max = .{ .fraction = 1 } } },
        .{ .fraction = 1 },
    };
    const children = [_]ui.NodeSpec{
        .{ .kind = .spacer },
        .{ .kind = .spacer },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid, .grid_columns = &tracks } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 120, .height = 20 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 80), store.getConst(retained[0]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), store.getConst(retained[1]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 120), store.getConst(retained[1]).?.layout.bounds.maxX(), 0.001);
}

test "grid rows measure wrapped content at the resolved column width" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const tracks = [_]ui.layout.GridTrack{ .{ .points = 50 }, .{ .points = 50 } };
    const children = [_]ui.NodeSpec{.{ .kind = .{ .text = "abcdefghijklmnopqrst" } }};
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid, .grid_columns = &tracks, .align_items = .start } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = wrappingTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const child = store.getConst(store.getConst(root).?.children.items[0]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 50), child.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), child.size.height, 0.001);
}

test "grid baseline alignment contributes the full ascent and descent" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const tracks = [_]ui.layout.GridTrack{ .{ .points = 50 }, .{ .points = 50 } };
    const children = [_]ui.NodeSpec{
        .{ .kind = .{ .text = "high" } },
        .{ .kind = .{ .text = "low" } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid, .grid_columns = &tracks, .align_items = .baseline } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = variableBaselineTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 30 });
    const retained = store.getConst(root).?.children.items;
    const high = store.getConst(retained[0]).?.layout.bounds;
    const low = store.getConst(retained[1]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 0), high.origin.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), low.origin.y, 0.001);
    try testing.expectApproxEqAbs(high.origin.y + 8, low.origin.y + 3, 0.001);
}

test "absolute layout applies margins and derives an auto aspect axis" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{.{
        .kind = .spacer,
        .style = .{ .layout = .{
            .position = .absolute,
            .aspect_ratio = 2,
            .margin = .{
                .top = .{ .points = 3 },
                .right = .{ .points = 5 },
                .bottom = .{ .points = 3 },
                .left = .{ .points = 5 },
            },
            .inset = .{
                .top = .{ .points = 4 },
                .right = .{ .points = 10 },
                .bottom = .auto,
                .left = .{ .points = 10 },
            },
        } },
    }};
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const child = store.getConst(store.getConst(root).?.children.items[0]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 15), child.origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 7), child.origin.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 70), child.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 35), child.size.height, 0.001);
}

test "custom measurement cannot publish non-finite layout geometry" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var probe: InvalidMeasureProbe = .{};
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .kind = .{ .custom = ui.custom.Node.from(InvalidMeasureProbe, &probe) },
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try testing.expectError(error.InvalidLayout, engine.layout(&store, root, .{ .width = 100, .height = 100 }));
}

test "headless platform deterministically exposes windows displays clipboard and events" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();

    const window = handles.WindowId.init(3, 1);
    const native = try harness.bundle.windows.create(window, .{
        .title = "Conformance",
        .size = .{ .width = 640, .height = 480 },
    });
    try testing.expectEqual(ui.platform.NativeHandle.Kind.headless, native.kind);
    try testing.expect(harness.bundle.windows.nativeHandle(window) != null);

    var displays = try harness.bundle.displays.list(testing.allocator);
    defer displays.deinit();
    try testing.expectEqual(@as(usize, 1), displays.values.len);
    try testing.expect(displays.values[0].primary);

    try harness.bundle.clipboard.?.writeText("clipboard");
    const clipboard = (try harness.bundle.clipboard.?.readText(testing.allocator)).?;
    defer testing.allocator.free(clipboard);
    try testing.expectEqualStrings("clipboard", clipboard);

    var events: EventCollector = .{};
    const sink: ui.platform.EventSink = .{ .context = &events, .callback = EventCollector.receive };
    while (try harness.bundle.event_loop.step(sink, false)) {}
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqual(@as(EventCollector.Tag, .created), events.tags[0]);
    try testing.expectEqual(@as(EventCollector.Tag, .configured), events.tags[1]);
    try testing.expectEqual(@as(EventCollector.Tag, .frame_requested), events.tags[2]);

    try harness.bundle.windows.command(window, .{ .resize = .{ .width = 800, .height = 600 } });
    try harness.bundle.windows.requestFrame(window);
    while (try harness.bundle.event_loop.step(sink, false)) {}
    try testing.expectEqual(@as(usize, 6), events.len);
    harness.bundle.windows.destroy(window);
    while (try harness.bundle.event_loop.step(sink, false)) {}
    try testing.expectEqual(@as(EventCollector.Tag, .closed), events.tags[events.len - 1]);
}

test "coordinator binding is single owner and returns a typed error" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    try testing.expectError(error.ResourceBusy, coordinator.bind());
}

test "effects execute and release exactly once or release unread on shutdown" {
    var executed: EffectProbe = .{};
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    try coordinator.deferEffect(executed.deferred());
    try coordinator.flushEffects();
    try testing.expectEqual(@as(usize, 1), executed.runs);
    try testing.expectEqual(@as(usize, 1), executed.drops);
    try coordinator.deinit();

    var unread: EffectProbe = .{};
    var queue = ui.runtime_effect.Queue.initWithLimit(testing.allocator, 2);
    try queue.push(.{ .deferred = unread.deferred() });
    try testing.expectError(error.FramePhaseViolation, queue.reset());
    queue.deinit();
    try testing.expectEqual(@as(usize, 0), unread.runs);
    try testing.expectEqual(@as(usize, 1), unread.drops);
}

test "dependency replacements use exact one-shot prepared tokens" {
    const component = handles.ComponentId.init(1, 1);
    const state_a = handles.StateId.init(2, 1);
    const state_b = handles.StateId.init(3, 1);
    var graph = ui.runtime_dependency.Graph.initWithLimits(testing.allocator, 8, 8, 2);
    defer graph.deinit();

    const initial = try graph.prepareComponent(component, &.{state_a});
    try graph.commitPrepared(initial);
    try testing.expectEqual(@as(usize, 1), graph.dependents(state_a).len);

    const stale = try graph.prepareComponent(component, &.{state_b});
    const current = try graph.prepareComponent(component, &.{state_a});
    try testing.expectError(error.FramePhaseViolation, graph.commitPrepared(stale));

    var other = ui.runtime_dependency.Graph.initWithLimits(testing.allocator, 8, 8, 2);
    defer other.deinit();
    try testing.expectError(error.FramePhaseViolation, other.commitPrepared(current));
    try graph.commitPrepared(current);
    try testing.expectEqual(@as(usize, 0), graph.dependents(state_b).len);
    try testing.expectEqual(@as(usize, 1), graph.dependents(state_a).len);
    try testing.expectError(error.InvalidConfiguration, graph.prepareComponent(component, &.{ state_a, state_a }));
    try testing.expectEqual(@as(usize, 1), graph.dependents(state_a).len);
}

test "dependency edge budget failure preserves the committed graph" {
    const component = handles.ComponentId.init(1, 1);
    const state_a = handles.StateId.init(2, 1);
    const state_b = handles.StateId.init(3, 1);
    var graph = ui.runtime_dependency.Graph.initWithLimits(testing.allocator, 8, 8, 1);
    defer graph.deinit();
    const prepared = try graph.prepareComponent(component, &.{state_a});
    try graph.commitPrepared(prepared);
    try testing.expectError(error.BudgetExceeded, graph.prepareComponent(component, &.{ state_a, state_b }));
    try testing.expectEqual(@as(usize, 1), graph.dependents(state_a).len);
    try testing.expectEqual(@as(usize, 0), graph.dependents(state_b).len);
}

test "destroying state removes dependency edges and invalidates its owner path" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component = handles.ComponentId.init(4, 1);
    const window = handles.WindowId.init(5, 1);
    try coordinator.invalidations.register(component, window);
    _ = coordinator.invalidations.consumeComponent(component);
    _ = coordinator.invalidations.consumeWindow(window);

    const value = try coordinator.states.create(u32, component, 9);
    var recorder = try coordinator.beginComponentDependencies(component, testing.allocator);
    defer recorder.deinit();
    _ = try coordinator.states.read(u32, value, recorder.sink());
    try recorder.finish();
    try testing.expectEqual(@as(usize, 1), coordinator.dependencies.dependents(value.id).len);

    try coordinator.states.destroy(u32, value);
    try testing.expectEqual(@as(usize, 0), coordinator.dependencies.dependents(value.id).len);
    try testing.expect(coordinator.invalidations.isWindowDirty(window));
    try testing.expect(coordinator.invalidations.consumeComponent(component) != null);
}

test "focus and hit-tree publication rejects stale or missing prepares" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const children = [_]ui.NodeSpec{.{
        .style = .{ .interaction = .{ .focusable = true } },
    }};
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());

    var manager = ui.focus.Manager.init(testing.allocator);
    defer manager.deinit();
    const stale = try manager.prepare(&store, root);
    const current = try manager.prepare(&store, root);
    try testing.expectError(error.FramePhaseViolation, manager.commitPrepared(stale));
    var other = ui.focus.Manager.init(testing.allocator);
    defer other.deinit();
    try testing.expectError(error.FramePhaseViolation, other.commitPrepared(current));
    try manager.commitPrepared(current);

    var hits = ui.hit_testing.Tree.init(testing.allocator);
    defer hits.deinit();
    try testing.expectError(error.FramePhaseViolation, hits.commitPrepared());
}

test "focus removal hands control to a newly mounted autofocus target" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var manager = ui.focus.Manager.init(testing.allocator);
    defer manager.deinit();

    const initial_children = [_]ui.NodeSpec{(ui.NodeSpec{
        .style = .{ .interaction = .{ .focusable = true } },
    }).withKey(1)};
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &initial_children }, 1, scratch.allocator());
    const initial_focus = store.getConst(root).?.children.items[0];
    try manager.rebuild(&store, root);
    try testing.expect(manager.request(&store, initial_focus));

    const replacement_children = [_]ui.NodeSpec{(ui.NodeSpec{
        .style = .{ .interaction = .{ .focusable = true, .autofocus = true } },
    }).withKey(2)};
    _ = try store.reconcile(root, .invalid, .invalid, .{ .children = &replacement_children }, 1, scratch.allocator());
    const replacement_focus = store.getConst(root).?.children.items[0];
    try manager.rebuild(&store, root);
    try testing.expect(manager.focused.eql(replacement_focus));
    try testing.expect(!manager.focused.eql(initial_focus));
}

test "accessibility snapshots own committed text across retained mutations and failed prepares" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .semantics = .{ .role = .button, .label = "before" },
    }, 1, scratch.allocator());
    var builder = ui.AccessibilityTree.initWithLimits(
        testing.allocator,
        handles.WindowId.init(1, 1),
        32,
        4096,
    );
    defer builder.deinit();
    const committed = try builder.build(&store, root, root, scratch.allocator());
    try testing.expectEqualStrings("before", committed.nodes[0].label);

    var oversized: [8192]u8 = undefined;
    @memset(&oversized, 'x');
    _ = try store.reconcile(root, .invalid, .invalid, .{
        .semantics = .{ .role = .button, .label = &oversized },
    }, 1, scratch.allocator());
    try testing.expectEqualStrings("before", committed.nodes[0].label);
    try testing.expectError(error.BudgetExceeded, builder.prepare(&store, root, root, scratch.allocator()));
    try testing.expectEqualStrings("before", committed.nodes[0].label);
}

test "accessibility prepared snapshots are owner-bound and one-shot" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .semantics = .{ .role = .button, .label = "owned" },
    }, 1, scratch.allocator());
    var first = ui.AccessibilityTree.init(testing.allocator, handles.WindowId.init(1, 1));
    defer first.deinit();
    var second = ui.AccessibilityTree.init(testing.allocator, handles.WindowId.init(2, 1));
    defer second.deinit();
    var prepared = try first.prepare(&store, root, root, scratch.allocator());
    defer prepared.deinit();
    try testing.expectError(error.FramePhaseViolation, second.commitPrepared(&prepared));
    _ = try first.commitPrepared(&prepared);
    try testing.expectError(error.FramePhaseViolation, first.commitPrepared(&prepared));
}

test "retained updates reject invalid payloads without changing committed records" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{ .kind = .{ .text = "safe" } }, 1, scratch.allocator());
    const initial_bytes = store.retainedBytes();
    const initial_generation = store.getConst(root).?.paint_generation;
    const invalid_utf8 = [_]u8{0xff};
    try testing.expectError(error.InvalidUtf8, store.reconcile(root, .invalid, .invalid, .{
        .kind = .{ .text = &invalid_utf8 },
    }, 1, scratch.allocator()));
    try testing.expectEqual(initial_bytes, store.retainedBytes());
    try testing.expectEqual(initial_generation, store.getConst(root).?.paint_generation);

    const nan: f32 = @bitCast(@as(u32, 0x7fc00000));
    try testing.expectError(error.InvalidConfiguration, store.reconcile(root, .invalid, .invalid, .{
        .kind = .{ .text = "safe" },
        .style = .{ .paint = .{ .opacity = nan } },
    }, 1, scratch.allocator()));
    try testing.expectEqual(initial_bytes, store.retainedBytes());
    try testing.expectEqual(initial_generation, store.getConst(root).?.paint_generation);
}

test "retained byte budget rejects replacement and preserves old ownership" {
    var store = ui.NodeStore.initWithLimits(testing.allocator, .{
        .maximum_nodes = 16,
        .maximum_depth = 16,
        .maximum_bytes = 1024,
    });
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .semantics = .{ .label = "old" },
    }, 1, scratch.allocator());
    const initial_bytes = store.retainedBytes();
    var oversized: [2048]u8 = undefined;
    @memset(&oversized, 'b');
    try testing.expectError(error.BudgetExceeded, store.reconcile(root, .invalid, .invalid, .{
        .semantics = .{ .label = &oversized },
    }, 1, scratch.allocator()));
    try testing.expectEqual(initial_bytes, store.retainedBytes());
    var iterator = store.inspectIterator();
    try testing.expectEqualStrings("old", iterator.next().?.semantic_label);
}

test "retained tree validation detects duplicates parent mismatch cycles and depth" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const children = [_]ui.NodeSpec{ .{}, .{} };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());
    const first_child = store.getConst(root).?.children.items[0];
    const second_child = store.getConst(root).?.children.items[1];

    store.get(root).?.children.items[1] = first_child;
    try testing.expectError(error.InvalidConfiguration, store.validateTree(root, scratch.allocator()));
    store.get(root).?.children.items[1] = second_child;

    store.get(first_child).?.parent = .invalid;
    try testing.expectError(error.InvalidConfiguration, store.validateTree(root, scratch.allocator()));
    store.get(first_child).?.parent = root;

    try store.reserveChildren(first_child, 1);
    store.get(first_child).?.children.appendAssumeCapacity(root);
    try testing.expectError(error.InvalidConfiguration, store.validateTree(root, scratch.allocator()));
    store.get(first_child).?.children.clearRetainingCapacity();
    try store.validateTree(root, scratch.allocator());

    var shallow = ui.NodeStore.initWithLimits(testing.allocator, .{
        .maximum_nodes = 16,
        .maximum_depth = 3,
        .maximum_bytes = 4096,
    });
    defer shallow.deinit();
    const level_three_children = [_]ui.NodeSpec{.{}};
    const level_two_children = [_]ui.NodeSpec{.{ .children = &level_three_children }};
    const level_one_children = [_]ui.NodeSpec{.{ .children = &level_two_children }};
    try testing.expectError(error.BudgetExceeded, shallow.reconcile(null, .invalid, .invalid, .{
        .children = &level_one_children,
    }, 1, scratch.allocator()));
    try testing.expectEqual(@as(usize, 0), shallow.retainedBytes());
}

test "configuration validates retained platform clipboard menu and action budgets" {
    var config_value: ui.config.AppConfig = .{};
    config_value.memory.retained_tree_depth = 513;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.platform_event_payload_bytes = config_value.memory.platform_event_queue_bytes + 1;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.platform_text_bytes = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.platform_retained_text_bytes = config_value.memory.platform_text_bytes - 1;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.clipboard_retained_bytes = config_value.memory.clipboard_bytes - 1;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.menu_depth = 129;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.action_name_bytes = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.layout_grid_cell_count = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.font_catalog_count = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.font_catalog_bytes = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.font_instance_count = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));
}

test "action registry owns names within an aggregate byte budget" {
    var registry = ui.actions.Registry.initWithBudgets(testing.allocator, 4, 4, 5);
    defer registry.deinit();
    const first = try registry.register("abc");
    try testing.expect((try registry.register("abc")).eql(first));
    try testing.expectEqual(@as(usize, 3), registry.registeredNameBytes());
    _ = try registry.register("de");
    try testing.expectEqual(@as(usize, 5), registry.registeredNameBytes());
    try testing.expectError(error.InvalidConfiguration, registry.register("longer"));
    try testing.expectError(error.BudgetExceeded, registry.register("f"));
    try testing.expectEqual(@as(usize, 5), registry.registeredNameBytes());
}

test "menu validation rejects invalid trees before invoking native code" {
    var probe: MenuProbe = .{};
    const menus: ui.platform.Menus = .{
        .context = &probe,
        .set_application_menu_fn = MenuProbe.set,
        .show_context_menu_fn = MenuProbe.show,
        .limits = .{ .maximum_items = 2, .maximum_depth = 2, .maximum_text_bytes = 8 },
    };
    const action_id = handles.ActionId.init(1, 1);
    const valid = [_]ui.platform.MenuItem{.{ .action = .{ .label = "Open", .action = action_id } }};
    try menus.setApplicationMenu(&valid);
    try testing.expectEqual(@as(usize, 1), probe.set_calls);

    const too_many = [_]ui.platform.MenuItem{ .separator, .separator, .separator };
    try testing.expectError(error.BudgetExceeded, menus.setApplicationMenu(&too_many));
    const invalid_text = [_]u8{0xff};
    const invalid = [_]ui.platform.MenuItem{.{ .action = .{ .label = &invalid_text, .action = action_id } }};
    try testing.expectError(error.InvalidUtf8, menus.setApplicationMenu(&invalid));
    const leaf = [_]ui.platform.MenuItem{.separator};
    const middle = [_]ui.platform.MenuItem{.{ .submenu = .{ .label = "M", .items = &leaf } }};
    const deep = [_]ui.platform.MenuItem{.{ .submenu = .{ .label = "D", .items = &middle } }};
    try testing.expectError(error.BudgetExceeded, menus.setApplicationMenu(&deep));
    try testing.expectEqual(@as(usize, 1), probe.set_calls);
}

test "headless queued payloads are deep copied and aggregate bounded" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    const window = handles.WindowId.init(9, 1);
    var collector: PayloadCollector = .{};
    const sink: ui.platform.EventSink = .{ .context = &collector, .callback = PayloadCollector.receive };

    var ime_bytes = [_]u8{ 'i', 'm', 'e' };
    try harness.post(window, .{ .input = .{ .ime = .{ .commit_text = .{
        .text = &ime_bytes,
        .replacement_utf8 = null,
    } } } });
    var path_bytes = [_]u8{ '/', 't', 'm', 'p', '/', 'a' };
    var paths = [_][]const u8{&path_bytes};
    try harness.post(window, .{ .input = .{ .file_drop_performed = .{
        .paths = &paths,
        .position = .{ .x = 3, .y = 4 },
    } } });
    var accessibility_bytes = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    try harness.post(window, .{ .accessibility_action = .{
        .window = window,
        .target = handles.SemanticId.init(2, 1),
        .action = .set_value,
        .value = &accessibility_bytes,
    } });
    ime_bytes[0] = 'x';
    path_bytes[5] = 'z';
    accessibility_bytes[0] = 'x';
    while (try harness.bundle.event_loop.step(sink, false)) {}
    try testing.expect(collector.ime_owned);
    try testing.expect(collector.path_owned);
    try testing.expect(collector.accessibility_owned);

    var constrained_memory: ui.config.MemoryBudgets = .{};
    constrained_memory.platform_event_payload_bytes = 8;
    constrained_memory.platform_event_queue_bytes = 10;
    var constrained = try ui.HeadlessPlatform.createWithMemory(testing.allocator, null, constrained_memory);
    defer constrained.bundle.deinit();
    defer constrained.bundle.renderer.deinit();
    var six = [_]u8{ '1', '2', '3', '4', '5', '6' };
    const queued: ui.platform.WindowEvent = .{ .input = .{ .ime = .{ .commit_text = .{
        .text = &six,
        .replacement_utf8 = null,
    } } } };
    try constrained.post(window, queued);
    try testing.expectError(error.BudgetExceeded, constrained.post(window, queued));
}

test "headless window creation reserves its entire initial event transaction" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.platform_event_count = 1;
    var harness = try ui.HeadlessPlatform.createWithMemory(testing.allocator, null, memory);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    const window = handles.WindowId.init(7, 1);
    try testing.expectError(error.BudgetExceeded, harness.bundle.windows.create(window, .{
        .title = "bounded",
        .visible = false,
    }));
    try testing.expect(harness.bundle.windows.nativeHandle(window) == null);
}

test "scene primitive budget spans every typed primitive stream" {
    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{ .primitives = 1 });
    defer builder.deinit();
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
        .background = ui.Color.white,
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try testing.expectError(error.BudgetExceeded, builder.underline(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
        .color = ui.Color.white,
        .thickness = 1,
        .wave_amplitude = 0,
        .wave_period = 1,
    }));
    try testing.expectEqual(@as(usize, 1), scene.quads.items.len);
    try testing.expectEqual(@as(usize, 0), scene.underlines.items.len);
}

test "platform event validation rejects malformed native lifecycle data" {
    const valid: ui.platform.WindowEvent = .{ .configured = .{
        .logical_size = .{ .width = 640, .height = 480 },
        .scale_factor = try ui.ScaleFactor.init(2),
    } };
    try ui.platform.validateWindowEvent(&valid);

    const nan: f32 = @bitCast(@as(u32, 0x7fc00000));
    const invalid_size: ui.platform.WindowEvent = .{ .resized = .{ .width = nan, .height = 10 } };
    try testing.expectError(error.InvalidConfiguration, ui.platform.validateWindowEvent(&invalid_size));
    const invalid_handle: ui.platform.WindowEvent = .{ .created = .{ .kind = .none, .value = 0 } };
    try testing.expectError(error.PlatformFailure, ui.platform.validateWindowEvent(&invalid_handle));
}

test "headless asynchronous failures remain sticky until teardown" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    harness.injectFailure(error.DeviceLost);
    var events: EventCollector = .{};
    const sink: ui.platform.EventSink = .{ .context = &events, .callback = EventCollector.receive };
    try testing.expectError(error.DeviceLost, harness.bundle.event_loop.step(sink, false));
    try testing.expectError(error.DeviceLost, harness.bundle.event_loop.step(sink, false));
    try testing.expectError(error.DeviceLost, harness.bundle.event_loop.run(sink));
}

test "grid auto placement avoids later explicit cells and respects spans" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const tracks = [_]ui.layout.GridTrack{ .{ .points = 50 }, .{ .points = 50 } };
    const children = [_]ui.NodeSpec{
        (ui.NodeSpec{ .kind = .spacer, .style = .{ .layout = .{ .width = .{ .points = 10 }, .height = .{ .points = 10 } } } }).withKey(1),
        (ui.NodeSpec{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 10 },
            .height = .{ .points = 10 },
            .grid_column = 1,
            .grid_row = 1,
        } } }).withKey(2),
        (ui.NodeSpec{ .kind = .spacer, .style = .{ .layout = .{
            .height = .{ .points = 10 },
            .grid_column_span = 2,
        } } }).withKey(3),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid, .grid_columns = &tracks } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 80 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 50), store.getConst(retained[0]).?.layout.bounds.origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), store.getConst(retained[1]).?.layout.bounds.origin.x, 0.001);
    try testing.expect(store.getConst(retained[2]).?.layout.bounds.origin.y > 0);
    try testing.expectApproxEqAbs(@as(f32, 100), store.getConst(retained[2]).?.layout.bounds.size.width, 0.001);
}

test "grid sparse placement is refused by the configured cell budget" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const children = [_]ui.NodeSpec{.{
        .kind = .spacer,
        .style = .{ .layout = .{ .grid_row = 4 } },
    }};
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .maximum_grid_cells = 3,
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try testing.expectError(error.BudgetExceeded, engine.layout(&store, root, .{ .width = 100, .height = 100 }));
}

test "arrange feedback stabilizes inside one submitted frame" {
    var model: LayoutFeedbackProbe = .{ .stop_after = 3 };
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "layout feedback test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;
    _ = try app.openWindow(.{ .platform = .{ .title = "feedback" } }, ui.Component.Descriptor.from(LayoutFeedbackProbe, &model));
    while (try app.step(false)) {}
    try testing.expectEqual(@as(usize, 3), model.arrange_count);
    try testing.expectEqual(@as(u64, 1), (try app.metricsSnapshot()).frames_submitted);
}

test "unbounded arrange feedback terminates with a sticky typed failure" {
    var model: LayoutFeedbackProbe = .{ .stop_after = std.math.maxInt(usize) };
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "layout feedback budget test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;
    _ = try app.openWindow(.{ .platform = .{ .title = "feedback budget" } }, ui.Component.Descriptor.from(LayoutFeedbackProbe, &model));
    var observed = false;
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        _ = app.step(false) catch |err| {
            try testing.expectEqual(error.BudgetExceeded, err);
            observed = true;
            break;
        };
    }
    try testing.expect(observed);
    try testing.expectError(error.BudgetExceeded, app.step(false));
}

test "text field clipboard editing history and IME are bounded and reversible" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component_id = handles.ComponentId.init(1, 1);
    const window_id = handles.WindowId.init(1, 1);
    const node_id = handles.NodeId.init(1, 1);
    try coordinator.invalidations.register(component_id, window_id);
    var clipboard: ClipboardProbe = .{};
    defer clipboard.deinit();
    var text_input: TextInputProbe = .{};
    var context: ui.input.Context = .{
        .coordinator = &coordinator,
        .component = component_id,
        .window = window_id,
        .current_layout_bounds = ui.Rect.fromXYWH(0, 0, 200, 30),
        .native_clipboard = clipboard.bridge(),
        .native_text_input = text_input.bridge(),
    };
    var dispatch: ui.input.Dispatch = .{
        .window = window_id,
        .target = node_id,
        .current = node_id,
        .phase = .target,
    };
    var field = try ui.widgets.TextField.init(testing.allocator, "hello");
    defer field.deinit();
    field.selection = .{ .start = 1, .end = 4 };

    try sendShortcut(&field, &dispatch, &context, 'x', false);
    try testing.expectEqualStrings("ho", field.value());
    try testing.expectEqualStrings("ell", clipboard.value());
    try sendShortcut(&field, &dispatch, &context, 'z', false);
    try testing.expectEqualStrings("hello", field.value());
    try sendShortcut(&field, &dispatch, &context, 'z', true);
    try testing.expectEqualStrings("ho", field.value());
    try sendShortcut(&field, &dispatch, &context, 'v', false);
    try testing.expectEqualStrings("hello", field.value());

    field.selection = .{ .start = field.value().len, .end = field.value().len };
    const marked: ui.input.Event = .{ .ime = .{ .set_marked_text = .{
        .text = "世",
        .selected_utf8 = .{ .start = 3, .end = 3 },
        .replacement_utf8 = null,
    } } };
    try field.event(&dispatch, &marked, &context);
    const cancel: ui.input.Event = .{ .ime = .cancel_composition };
    try field.event(&dispatch, &cancel, &context);
    try testing.expectEqualStrings("hello", field.value());
    try field.event(&dispatch, &marked, &context);
    const unmark: ui.input.Event = .{ .ime = .unmark_text };
    try field.event(&dispatch, &unmark, &context);
    try testing.expectEqualStrings("hello世", field.value());

    field.selection = .{ .start = field.value().len, .end = 0 };
    try sendShortcut(&field, &dispatch, &context, 'c', false);
    try testing.expectEqual(@as(usize, 0), text_input.selection.start);
    try testing.expectEqual(field.value().len, text_input.selection.end);

    field.clearHistory();
    field.maximum_history_entries = 0;
    field.selection = .{ .start = field.value().len, .end = field.value().len };
    const history_free_commit: ui.input.Event = .{ .ime = .{ .commit_text = .{
        .text = "!",
        .replacement_utf8 = null,
    } } };
    try field.event(&dispatch, &history_free_commit, &context);
    try testing.expectEqualStrings("hello世!", field.value());
}

test "text field setValue preserves committed text across allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, textFieldSetValueAllocationProbe, .{});
}

test "disabled standard controls expose no invokable accessibility actions" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var context: ui.Component.BuildContext = undefined;
    context.allocator = scratch.allocator();
    var callback_probe: usize = 0;
    const callback: ui.widgets.Callback = .{ .context = &callback_probe, .callback = noopWidgetCallback };

    var button: ui.widgets.Button = .{ .label = "button", .on_activate = callback, .disabled = true };
    const button_spec = try button.build(&context);
    try testing.expectEqual(@as(usize, 0), button_spec.semantics.actions.len);
    try testing.expectEqual(ui.text.WrapMode.none, button_spec.children[0].style.text.wrap);
    try testing.expectEqual(@as(?u32, 1), button_spec.children[0].style.text.maximum_lines);

    var checked = false;
    var toggle: ui.widgets.Toggle = .{ .label = "toggle", .value = &checked, .disabled = true };
    try testing.expectEqual(@as(usize, 0), (try toggle.build(&context)).semantics.actions.len);

    var selected: usize = 0;
    var radio: ui.widgets.Radio = .{ .label = "radio", .selected_index = &selected, .index = 0, .disabled = true };
    try testing.expectEqual(@as(usize, 0), (try radio.build(&context)).semantics.actions.len);

    const labels = [_][]const u8{ "one", "two" };
    const disabled_tabs = [_]bool{ true, true };
    var tabs = try ui.widgets.Tabs.init(testing.allocator, &labels, &selected);
    defer tabs.deinit();
    tabs.disabled = &disabled_tabs;
    const tabs_spec = try tabs.build(&context);
    for (tabs_spec.children[0].children) |tab| try testing.expectEqual(@as(usize, 0), tab.semantics.actions.len);

    var select = try ui.widgets.Select.init(testing.allocator, &labels, &selected);
    defer select.deinit();
    select.disabled = true;
    try testing.expectEqual(@as(usize, 0), (try select.build(&context)).semantics.actions.len);

    var slider_value: f64 = 0.5;
    var slider: ui.widgets.Slider = .{ .value = &slider_value, .disabled = true };
    try testing.expectEqual(@as(usize, 0), (try slider.build(&context)).semantics.actions.len);

    var field = try ui.widgets.TextField.init(testing.allocator, "text");
    defer field.deinit();
    field.disabled = true;
    try testing.expectEqual(@as(usize, 0), (try field.build(&context)).semantics.actions.len);
    field.disabled = false;
    field.password = true;
    field.selection = .{ .start = 1, .end = 4 };
    const password_spec = try field.build(&context);
    try testing.expect(password_spec.semantics.selection == null);
    try testing.expectEqualStrings("", password_spec.semantics.value);
}

test "text field keeps the caret visible and marks active IME text" {
    var field = try ui.widgets.TextField.init(testing.allocator, "abcdefghijklmnopqrstuvwxyz");
    defer field.deinit();
    field.focused = true;

    var probe: TextGeometryProbe = .{};
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const scale = try ui.ScaleFactor.init(2);
    var measure_context: ui.custom.MeasureContext = .{
        .allocator = scratch.allocator(),
        .scale_factor = scale,
        .text = probe.services(),
    };
    _ = try field.measure(&measure_context, .{ .maximum = .{ .width = 62, .height = 28 } });
    var paint_context: ui.custom.PaintContext = .{
        .scene_context = &probe,
        .emit_fn = TextGeometryProbe.emit,
        .scratch = scratch.allocator(),
        .scale_factor = scale,
        .text = probe.services(),
    };
    try field.paint(&paint_context, ui.Rect.fromXYWH(0, 0, 80, 40));
    try testing.expect(field.scroll_offset.x > 0);

    field.selection = .{ .start = 5, .end = 5 };
    try field.marked_text.appendSlice(testing.allocator, "世");
    field.marked_selection = .{ .start = 3, .end = 3 };
    field.composition_active = true;
    field.reveal_caret = true;
    try field.paint(&paint_context, ui.Rect.fromXYWH(0, 0, 80, 40));
    try testing.expect(probe.underlines != 0);
}

test "accessibility tree validation rejects duplicate identities and malformed values" {
    const window = handles.WindowId.init(1, 1);
    const root_id = handles.SemanticId.init(1, 1);
    const child_id = handles.SemanticId.init(2, 1);
    const children = [_]handles.SemanticId{child_id};
    const valid_nodes = [_]ui.accessibility.Node{
        .{ .id = root_id, .role = .window, .children = &children },
        .{ .id = child_id, .parent = root_id, .role = .button, .label = "valid" },
    };
    const valid: ui.accessibility.Tree = .{ .window = window, .root = root_id, .nodes = &valid_nodes, .generation = 1 };
    try ui.accessibility.validateTree(testing.allocator, &valid, .{ .maximum_nodes = 4, .maximum_bytes = 4096 });

    const duplicate_nodes = [_]ui.accessibility.Node{
        .{ .id = root_id, .role = .window, .children = &children },
        .{ .id = root_id, .parent = root_id, .role = .button },
    };
    const duplicate: ui.accessibility.Tree = .{ .window = window, .root = root_id, .nodes = &duplicate_nodes, .generation = 1 };
    try testing.expectError(error.InvalidLayout, ui.accessibility.validateTree(testing.allocator, &duplicate, .{ .maximum_nodes = 4, .maximum_bytes = 4096 }));

    const invalid_text = [_]u8{0xff};
    const malformed_nodes = [_]ui.accessibility.Node{.{ .id = root_id, .role = .window, .label = &invalid_text }};
    const malformed: ui.accessibility.Tree = .{ .window = window, .root = root_id, .nodes = &malformed_nodes, .generation = 1 };
    try testing.expectError(error.InvalidUtf8, ui.accessibility.validateTree(testing.allocator, &malformed, .{ .maximum_nodes = 4, .maximum_bytes = 4096 }));
}

test "App task contexts have one terminal owner across rejection completion and shutdown" {
    var owner: TaskOwnerProbe = .{};
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "task ownership test",
        .allow_multiple_apps_for_testing = true,
    });
    _ = try app.openWindow(.{ .platform = .{ .title = "tasks" } }, ui.Component.Descriptor.from(TaskOwnerProbe, &owner));
    while (try app.step(false)) {}
    try testing.expect(owner.component.isValid());

    var counts: TaskContextCounts = .{};
    const missing = try TaskContext.create(&counts);
    try testing.expectError(error.MissingCapability, app.spawnTask(owner.component, missing, TaskContext.run, TaskContext.apply, TaskContext.drop));
    try testing.expectEqual(@as(usize, 1), counts.drops);

    var host_probe: TaskHostProbe = .{};
    try app.installTaskHost(host_probe.host());
    host_probe.mode = .reject;
    const rejected = try TaskContext.create(&counts);
    try testing.expectError(error.QueueFull, app.spawnTask(owner.component, rejected, TaskContext.run, TaskContext.apply, TaskContext.drop));
    try testing.expectEqual(@as(usize, 2), counts.drops);

    host_probe.mode = .complete;
    const completed = try TaskContext.create(&counts);
    _ = try app.spawnTask(owner.component, completed, TaskContext.run, TaskContext.apply, TaskContext.drop);
    try testing.expectEqual(@as(usize, 1), try app.drainTaskCompletions());
    try testing.expectEqual(@as(usize, 1), counts.runs);
    try testing.expectEqual(@as(usize, 1), counts.applies);
    try testing.expectEqual(@as(usize, 3), counts.drops);

    host_probe.mode = .hold;
    const held = try TaskContext.create(&counts);
    _ = try app.spawnTask(owner.component, held, TaskContext.run, TaskContext.apply, TaskContext.drop);
    try app.destroy();
    try testing.expectEqual(@as(usize, 4), counts.drops);
    try testing.expectEqual(@as(usize, 1), host_probe.shutdowns);
}

test "scroll view reconciles stale model offsets during frame stabilization" {
    var model = ScrollSyncProbe.init();
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "scroll synchronization test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;
    _ = try app.openWindow(.{ .platform = .{
        .title = "scroll",
        .size = .{ .width = 200, .height = 120 },
    } }, ui.Component.Descriptor.from(ScrollSyncProbe, &model));
    while (try app.step(false)) {}
    try testing.expectEqual(@as(f32, 0), model.scroll.offset_y);
    try testing.expectEqual(@as(u64, 1), (try app.metricsSnapshot()).frames_submitted);
}

test "programmatic focus includes negative tab index without adding it to traversal" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const children = [_]ui.NodeSpec{
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = -1 } } }).withKey(1),
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = 0 } } }).withKey(2),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());
    const retained = store.getConst(root).?.children.items;

    var manager = ui.focus.Manager.init(testing.allocator);
    defer manager.deinit();
    try manager.rebuild(&store, root);
    try testing.expect(manager.request(&store, retained[0]));
    try manager.rebuild(&store, root);
    try testing.expect(manager.focused.eql(retained[0]));
    try testing.expect(manager.move(&store, .forward).?.eql(retained[1]));
    try testing.expect(manager.move(&store, .backward).?.eql(retained[1]));
}

test "roving focus transfers to the newly committed autofocus identity" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const initial = [_]ui.NodeSpec{
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = 0, .autofocus = true } } }).withKey(1),
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = -1 } } }).withKey(2),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &initial }, 1, scratch.allocator());
    const first = store.getConst(root).?.children.items[0];
    const second = store.getConst(root).?.children.items[1];
    var manager = ui.focus.Manager.init(testing.allocator);
    defer manager.deinit();
    try manager.rebuild(&store, root);
    try testing.expect(manager.focused.eql(first));

    manager.requestAutofocusAfterReconcile();
    const replacement = [_]ui.NodeSpec{
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = -1 } } }).withKey(1),
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = 0, .autofocus = true } } }).withKey(2),
    };
    _ = try store.reconcile(root, .invalid, .invalid, .{ .children = &replacement }, 1, scratch.allocator());
    try manager.rebuild(&store, root);
    try testing.expect(manager.focused.eql(second));
}

test "tabs request atomic roving focus when keyboard selection changes" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component_id = handles.ComponentId.init(1, 1);
    const window_id = handles.WindowId.init(1, 1);
    const node_id = handles.NodeId.init(1, 1);
    try coordinator.invalidations.register(component_id, window_id);
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var build_context: ui.Component.BuildContext = undefined;
    build_context.allocator = scratch.allocator();
    const labels = [_][]const u8{ "one", "two", "three" };
    var selected: usize = 0;
    var tabs = try ui.widgets.Tabs.init(testing.allocator, &labels, &selected);
    defer tabs.deinit();
    const spec = try tabs.build(&build_context);
    const first_tab = spec.children[0].children[0];
    var dispatch: ui.input.Dispatch = .{
        .window = window_id,
        .target = node_id,
        .current = node_id,
        .phase = .target,
    };
    var event_context: ui.input.Context = .{
        .coordinator = &coordinator,
        .component = component_id,
        .window = window_id,
    };
    const key: ui.input.Event = .{ .key_down = .{ .key = .arrow_right, .physical_code = 0 } };
    try first_tab.handlers[0].callback(first_tab.handlers[0].context, &dispatch, &key, &event_context);
    try testing.expectEqual(@as(usize, 1), selected);
    try testing.expect(dispatch.requested_autofocus_after_reconcile);
    try testing.expect(dispatch.requested_focus == null);
}

test "split pane clamps its ratio from committed geometry" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var context: ui.Component.BuildContext = undefined;
    context.allocator = scratch.allocator();
    var fraction: f32 = 0;
    var pane: ui.widgets.SplitPane = .{
        .first = .{},
        .second = .{},
        .fraction = &fraction,
        .minimum_first = 100,
        .minimum_second = 50,
        .divider_size = 10,
    };
    var arrange_context: ui.custom.ArrangeContext = .{
        .allocator = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
    };
    try pane.arrange(&arrange_context, ui.Rect.fromXYWH(0, 0, 300, 100));
    const spacious = try pane.build(&context);
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 290.0), spacious.children[0].style.layout.flex_grow, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 190.0 / 290.0), spacious.children[2].style.layout.flex_grow, 0.0001);

    try pane.arrange(&arrange_context, ui.Rect.fromXYWH(0, 0, 120, 100));
    const constrained = try pane.build(&context);
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), constrained.children[0].style.layout.flex_grow, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), constrained.children[2].style.layout.flex_grow, 0.0001);

    pane.minimum_first = 3.0e38;
    pane.minimum_second = 3.0e38;
    try testing.expectError(error.InvalidConfiguration, pane.build(&context));
}

test "text backend wrappers reject malformed provider output and free it" {
    var probe: MalformedTextBackend = .{};
    const backend = probe.backend();
    const font = handles.FontId.init(1, 1);
    try testing.expectError(error.PlatformFailure, backend.resolveFont(.{ .families = &.{"Test"} }));
    try testing.expectError(error.PlatformFailure, backend.metrics(font, 14));
    try testing.expectError(error.PlatformFailure, backend.shape(.{ .text = "abc", .font = font, .size = 14 }, testing.allocator));
    try testing.expectError(error.PlatformFailure, backend.rasterize(.{
        .font = font,
        .glyph_id = 1,
        .size = 14,
        .scale_factor = 1,
    }, testing.allocator));
    backend.deinit();
    try testing.expectEqual(@as(usize, 1), probe.deinits);
}

test "custom text selection providers cannot overwrite caller rectangles" {
    var context: u8 = 0;
    const services: ui.custom.TextServices = .{
        .context = &context,
        .measure_fn = TextGeometryProbe.measure,
        .selection_rects_fn = mutatingSelectionRects,
    };
    var output: std.ArrayList(ui.Rect) = .empty;
    defer output.deinit(testing.allocator);
    try output.append(testing.allocator, ui.Rect.fromXYWH(99, 99, 1, 1));
    try services.selectionRects("ab", .{}, 100, 0, 1, &output, testing.allocator);
    try testing.expectEqual(@as(usize, 2), output.items.len);
    try testing.expectApproxEqAbs(@as(f32, 99), output.items[0].origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), output.items[1].origin.x, 0.001);
}

test "media source validation releases rejected frames and Y4M obeys decoded budget" {
    var probe: MalformedMediaSource = .{};
    const source = probe.source();
    try testing.expectError(error.InvalidMedia, source.poll(0));
    try testing.expectEqual(@as(usize, 1), probe.releases);
    source.deinit();
    try testing.expectEqual(@as(usize, 1), probe.deinits);

    const encoded = "YUV4MPEG2 W100 H100 F30:1 Ip C420\nFRAME\n";
    try testing.expectError(error.BudgetExceeded, ui.media.Y4mSource.create(
        testing.allocator,
        encoded,
        4,
        encoded.len,
        100,
    ));

    var build_context: ui.Component.BuildContext = undefined;
    var invalid_view: ui.media.View = .{
        .visual = .{ .texture = .{ .id = .invalid, .width = 1, .height = 1, .format = .rgba8 } },
    };
    try testing.expectError(error.InvalidHandle, invalid_view.build(&build_context));
}

test "SVG path arithmetic cannot retain non-finite geometry" {
    const source =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
        \\  <path d="M 3e38 0 l 3e38 0"/>
        \\</svg>
    ;
    try testing.expectError(error.InvalidSvg, ui.svg.Document.parse(testing.allocator, source, .{}));
}

test "accessibility validation enforces its iterative depth limit" {
    const window = handles.WindowId.init(1, 1);
    const root = handles.SemanticId.init(1, 1);
    const middle = handles.SemanticId.init(2, 1);
    const leaf = handles.SemanticId.init(3, 1);
    const root_children = [_]handles.SemanticId{middle};
    const middle_children = [_]handles.SemanticId{leaf};
    const nodes = [_]ui.accessibility.Node{
        .{ .id = root, .role = .window, .children = &root_children },
        .{ .id = middle, .parent = root, .role = .group, .children = &middle_children },
        .{ .id = leaf, .parent = middle, .role = .button },
    };
    const tree: ui.accessibility.Tree = .{ .window = window, .root = root, .nodes = &nodes, .generation = 1 };
    try testing.expectError(error.BudgetExceeded, ui.accessibility.validateTree(testing.allocator, &tree, .{
        .maximum_nodes = nodes.len,
        .maximum_bytes = 4096,
        .maximum_depth = 2,
    }));
}

test "render extension registry owns labels and bounds retired entries" {
    var probe: RenderExtensionProbe = .{};
    var registry = ui.render_extension.Registry.initWithLimit(testing.allocator, 1);
    defer registry.deinit();
    const label = try testing.allocator.dupe(u8, "mutable");
    const first = try registry.register(probe.descriptor(label));
    @memset(label, 'x');
    testing.allocator.free(label);
    try registry.destroy(first, 10);
    try testing.expectError(error.BudgetExceeded, registry.register(probe.descriptor("second")));
    registry.collect(9);
    try testing.expectEqual(@as(usize, 0), probe.deinits);
    registry.collect(10);
    try testing.expectEqual(@as(usize, 1), probe.deinits);
    _ = try registry.register(probe.descriptor("second"));
}

test "null renderer executes custom passes with payload flags and device recovery" {
    var probe: RenderExtensionProbe = .{};
    const renderer = try ui.NullRenderer.create(testing.allocator);
    var renderer_owned = true;
    defer if (renderer_owned) renderer.deinit();
    const extension = try renderer.registerExtension(probe.descriptor("integrated custom pass"));

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.customPass(extension, ui.Rect.fromXYWH(2, 3, 7, 5), "pass-payload", 0xa55a_1734);
    try builder.finish();

    var first = (try renderer.renderOffscreen(.{
        .width = 16,
        .height = 12,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    first.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), probe.prepares);
    try testing.expectEqual(@as(usize, 1), probe.encodes);
    try testing.expectEqual(ui.render_extension.Backend.null, probe.last_device);
    try testing.expectEqual(ui.render_extension.Backend.null, probe.last_pass);
    try testing.expectEqual(@as(usize, "pass-payload".len), probe.payload_length);
    try testing.expectEqual(@as(u8, 'p'), probe.payload_first);
    try testing.expectEqual(@as(u32, 0xa55a_1734), probe.flags);
    try testing.expectEqual(ui.Rect.fromXYWH(2, 3, 7, 5), probe.geometry.bounds);

    try renderer.recover(.{});
    try testing.expectEqual(@as(usize, 1), probe.device_losses);
    var second = (try renderer.renderOffscreen(.{
        .width = 16,
        .height = 12,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    second.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), probe.prepares);
    try testing.expectEqual(@as(usize, 2), probe.encodes);

    renderer.deinit();
    renderer_owned = false;
    try testing.expectEqual(@as(usize, 1), probe.deinits);
}

fn pixel(readback: ui.render.Readback, x: usize, y: usize) []const u8 {
    const offset = y * readback.stride + x * 4;
    return readback.pixels[offset..][0..4];
}

const LayoutFeedbackProbe = struct {
    arrange_count: usize = 0,
    stop_after: usize,

    pub fn build(self: *LayoutFeedbackProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        return .{ .kind = .{ .custom = ui.custom.Node.from(LayoutFeedbackProbe, self) } };
    }

    pub fn arrange(self: *LayoutFeedbackProbe, context: *ui.custom.ArrangeContext, _: ui.Rect) ui.Error!void {
        self.arrange_count += 1;
        if (self.arrange_count < self.stop_after) _ = context.requestRecompose();
    }

    pub fn paint(_: *LayoutFeedbackProbe, _: *ui.custom.PaintContext, _: ui.Rect) ui.Error!void {}
};

const TaskOwnerProbe = struct {
    component: handles.ComponentId = .invalid,

    pub fn build(self: *TaskOwnerProbe, context: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.component = context.component;
        return .{};
    }
};

const TaskContextCounts = struct {
    runs: usize = 0,
    applies: usize = 0,
    drops: usize = 0,
};

const TaskContext = struct {
    counts: *TaskContextCounts,

    fn create(counts: *TaskContextCounts) !*TaskContext {
        const self = try testing.allocator.create(TaskContext);
        self.* = .{ .counts = counts };
        return self;
    }

    fn run(context: *anyopaque, _: *ui.runtime_task.CancellationToken) void {
        const self: *TaskContext = @ptrCast(@alignCast(context));
        self.counts.runs += 1;
    }

    fn apply(context: *anyopaque) void {
        const self: *TaskContext = @ptrCast(@alignCast(context));
        self.counts.applies += 1;
    }

    fn drop(context: *anyopaque) void {
        const self: *TaskContext = @ptrCast(@alignCast(context));
        self.counts.drops += 1;
        testing.allocator.destroy(self);
    }
};

const TaskHostProbe = struct {
    const Mode = enum { reject, complete, hold };

    mode: Mode = .reject,
    sink: ?ui.runtime_task.CompletionSink = null,
    held: ?ui.runtime_task.Work = null,
    shutdowns: usize = 0,

    fn host(self: *TaskHostProbe) ui.runtime_task.Host {
        return .{
            .context = self,
            .start_fn = start,
            .spawn_fn = spawn,
            .shutdown_fn = shutdown,
        };
    }

    fn start(context: *anyopaque, sink: ui.runtime_task.CompletionSink) ui.Error!void {
        const self: *TaskHostProbe = @ptrCast(@alignCast(context));
        self.sink = sink;
    }

    fn spawn(context: *anyopaque, work: ui.runtime_task.Work) ui.Error!void {
        const self: *TaskHostProbe = @ptrCast(@alignCast(context));
        switch (self.mode) {
            .reject => return error.QueueFull,
            .complete => work.run(self.sink.?),
            .hold => {
                if (self.held != null) return error.QueueFull;
                self.held = work;
            },
        }
    }

    fn shutdown(context: *anyopaque) void {
        const self: *TaskHostProbe = @ptrCast(@alignCast(context));
        if (self.held) |work| work.drop();
        self.held = null;
        self.sink = null;
        self.shutdowns += 1;
    }
};

const ScrollSyncProbe = struct {
    scroll: ui.widgets.ScrollView,

    fn init() ScrollSyncProbe {
        return .{ .scroll = .{
            .offset_y = 500,
            .content = .{},
            .style = .{ .layout = .{
                .width = .{ .percent = 1 },
                .height = .{ .percent = 1 },
            } },
        } };
    }

    pub fn build(self: *ScrollSyncProbe, context: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.scroll.content = .{
            .kind = .spacer,
            .style = .{ .layout = .{
                .width = .{ .percent = 1 },
                .height = .{ .points = 20 },
            } },
        };
        return self.scroll.build(context);
    }
};

const MalformedTextBackend = struct {
    deinits: usize = 0,

    fn backend(self: *MalformedTextBackend) ui.text.Backend {
        return .{
            .context = self,
            .resolve_font_fn = resolveFont,
            .metrics_fn = metrics,
            .shape_fn = shape,
            .color_glyph_fn = colorGlyph,
            .rasterize_fn = rasterize,
            .deinit_fn = deinit,
        };
    }

    fn resolveFont(_: *anyopaque, _: ui.text.FontDescriptor) ui.Error!handles.FontId {
        return .invalid;
    }

    fn metrics(_: *anyopaque, _: handles.FontId, _: f32) ui.Error!ui.text.FontMetrics {
        return .{
            .ascent = @bitCast(@as(u32, 0x7fc00000)),
            .descent = 0,
            .leading = 0,
            .x_height = 0,
            .cap_height = 0,
            .underline_position = 0,
            .underline_thickness = 1,
        };
    }

    fn shape(_: *anyopaque, request: ui.text.ShapeRequest, allocator: std.mem.Allocator) ui.Error!ui.text.ShapedRun {
        const glyphs = try allocator.alloc(ui.text.Glyph, 1);
        errdefer allocator.free(glyphs);
        const fonts = try allocator.alloc(handles.FontId, 1);
        fonts[0] = request.font;
        glyphs[0] = .{
            .glyph_id = 1,
            .cluster_utf8 = 0,
            .advance_x = 1,
            .advance_y = 0,
            .offset_x = 0,
            .offset_y = 0,
            .font_index = 0,
        };
        return .{
            .text_utf8 = request.text,
            .glyphs = glyphs,
            .fonts = fonts,
            .direction = if (request.direction == .auto) .left_to_right else request.direction,
            .width = @bitCast(@as(u32, 0x7fc00000)),
            .metrics = .{
                .ascent = 10,
                .descent = 2,
                .leading = 0,
                .x_height = 5,
                .cap_height = 7,
                .underline_position = 1,
                .underline_thickness = 1,
            },
        };
    }

    fn colorGlyph(_: *anyopaque, _: handles.FontId, _: u32) ui.text.ColorGlyphKind {
        return .none;
    }

    fn rasterize(_: *anyopaque, _: ui.text.RasterRequest, allocator: std.mem.Allocator) ui.Error!ui.text.RasterizedGlyph {
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0);
        return .{
            .size = .{ .width = 2, .height = 2 },
            .origin = .{},
            .stride = 1,
            .pixels = pixels,
            .mode = .grayscale,
        };
    }

    fn deinit(context: *anyopaque) void {
        const self: *MalformedTextBackend = @ptrCast(@alignCast(context));
        self.deinits += 1;
    }
};

const MalformedMediaSource = struct {
    pixels: [4]u8 = @splat(0),
    releases: usize = 0,
    deinits: usize = 0,

    fn source(self: *MalformedMediaSource) ui.media.api.Source {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: ui.media.api.Source.VTable = .{
        .info = info,
        .poll = poll,
        .seek = seek,
        .deinit = deinit,
    };

    fn cast(context: *anyopaque) *MalformedMediaSource {
        return @ptrCast(@alignCast(context));
    }

    fn info(_: *anyopaque) ui.media.api.Info {
        return .{ .width = 2, .height = 2 };
    }

    fn poll(context: *anyopaque, _: ui.media.api.Timestamp) ui.Error!ui.media.api.Poll {
        const self = cast(context);
        return .{ .frame = .{
            .presentation_time_ns = 0,
            .duration_ns = 1,
            .content = .{ .cpu = .{
                .width = 2,
                .height = 2,
                .stride = 1,
                .format = .rgba8,
                .pixels = &self.pixels,
            } },
            .release_context = self,
            .release_fn = release,
        } };
    }

    fn seek(_: *anyopaque, _: ui.media.api.Timestamp) ui.Error!void {}

    fn release(context: *anyopaque) void {
        cast(context).releases += 1;
    }

    fn deinit(context: *anyopaque) void {
        cast(context).deinits += 1;
    }
};

const RenderExtensionProbe = struct {
    deinits: usize = 0,
    prepares: usize = 0,
    encodes: usize = 0,
    device_losses: usize = 0,
    last_device: ui.render_extension.Backend = .null,
    last_pass: ui.render_extension.Backend = .null,
    payload_length: usize = 0,
    payload_first: u8 = 0,
    flags: u32 = 0,
    geometry: ui.render_extension.Geometry = undefined,

    fn descriptor(self: *RenderExtensionProbe, label: []const u8) ui.render_extension.Descriptor {
        return .{ .context = self, .vtable = &vtable, .label = label };
    }

    const vtable: ui.render_extension.Descriptor.VTable = .{
        .prepare = prepare,
        .encode = encode,
        .device_lost = deviceLost,
        .deinit = deinit,
    };

    fn prepare(context: *anyopaque, device: ui.render_extension.Device, _: ui.render_extension.DeviceGeneration) ui.Error!void {
        const self: *RenderExtensionProbe = @ptrCast(@alignCast(context));
        self.prepares += 1;
        self.last_device = std.meta.activeTag(device);
    }
    fn encode(context: *anyopaque, pass: ui.render_extension.Pass, payload: []const u8, flags: u32) ui.Error!void {
        const self: *RenderExtensionProbe = @ptrCast(@alignCast(context));
        self.encodes += 1;
        self.last_pass = std.meta.activeTag(pass);
        self.payload_length = payload.len;
        self.payload_first = if (payload.len == 0) 0 else payload[0];
        self.flags = flags;
        self.geometry = pass.geometry().*;
    }
    fn deviceLost(context: *anyopaque, _: ui.render_extension.DeviceGeneration) void {
        const self: *RenderExtensionProbe = @ptrCast(@alignCast(context));
        self.device_losses += 1;
    }
    fn deinit(context: *anyopaque) void {
        const self: *RenderExtensionProbe = @ptrCast(@alignCast(context));
        self.deinits += 1;
    }
};

fn noopWidgetCallback(context: *anyopaque, _: *ui.input.Context) ui.Error!void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

fn mutatingSelectionRects(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    _: f32,
    _: usize,
    _: usize,
    output: *std.ArrayList(ui.Rect),
    allocator: std.mem.Allocator,
) ui.Error!void {
    output.clearRetainingCapacity();
    try output.append(allocator, ui.Rect.fromXYWH(0, 0, 8, 18));
}

const TextGeometryProbe = struct {
    underlines: usize = 0,

    fn services(self: *TextGeometryProbe) ui.custom.TextServices {
        return .{
            .context = self,
            .measure_fn = measure,
            .paint_fn = paint,
            .hit_test_fn = hitTest,
            .caret_rect_fn = caretRect,
            .selection_rects_fn = selectionRects,
        };
    }

    fn measure(
        _: *anyopaque,
        value: []const u8,
        style: ui.style.TextStyle,
        constraints: ui.layout.Constraints,
    ) ui.Error!ui.Size {
        const natural_width = @as(f32, @floatFromInt(value.len)) * 8;
        const width = if (style.wrap == .none or !std.math.isFinite(constraints.maximum.width))
            natural_width
        else
            @min(natural_width, constraints.maximum.width);
        const lines = if (style.wrap == .none or width <= 0)
            1
        else
            @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(natural_width / width))));
        return constraints.constrain(.{ .width = width, .height = @as(f32, @floatFromInt(lines)) * 18 });
    }

    fn paint(_: *anyopaque, _: *anyopaque, _: []const u8, _: ui.style.TextStyle, _: ui.Rect) ui.Error!void {}

    fn hitTest(
        _: *anyopaque,
        value: []const u8,
        _: ui.style.TextStyle,
        _: f32,
        point: ui.Point,
    ) ui.Error!ui.text.Hit {
        const offset: usize = @intFromFloat(@max(0, @round(point.x / 8)));
        return .{ .utf8_offset = @min(offset, value.len) };
    }

    fn caretRect(
        _: *anyopaque,
        value: []const u8,
        _: ui.style.TextStyle,
        _: f32,
        utf8_offset: usize,
        _: ui.text.CaretAffinity,
    ) ui.Error!ui.Rect {
        return ui.Rect.fromXYWH(@as(f32, @floatFromInt(@min(utf8_offset, value.len))) * 8, 0, 1, 18);
    }

    fn selectionRects(
        _: *anyopaque,
        _: []const u8,
        _: ui.style.TextStyle,
        _: f32,
        start: usize,
        end: usize,
        output: *std.ArrayList(ui.Rect),
        allocator: std.mem.Allocator,
    ) ui.Error!void {
        if (start == end) return;
        const left = @min(start, end);
        const right = @max(start, end);
        try output.append(allocator, ui.Rect.fromXYWH(
            @as(f32, @floatFromInt(left)) * 8,
            0,
            @as(f32, @floatFromInt(right - left)) * 8,
            18,
        ));
    }

    fn emit(context: *anyopaque, command: ui.custom.PaintCommand) ui.Error!void {
        const self: *TextGeometryProbe = @ptrCast(@alignCast(context));
        switch (command) {
            .underline => self.underlines += 1,
            else => {},
        }
    }
};

const InvalidMeasureProbe = struct {
    pub fn measure(_: *InvalidMeasureProbe, _: *ui.custom.MeasureContext, _: ui.layout.Constraints) ui.Error!ui.Size {
        return .{ .width = @bitCast(@as(u32, 0x7fc00000)), .height = 10 };
    }

    pub fn paint(_: *InvalidMeasureProbe, _: *ui.custom.PaintContext, _: ui.Rect) ui.Error!void {}
};

const ClipboardProbe = struct {
    text: ?[]u8 = null,

    fn deinit(self: *ClipboardProbe) void {
        if (self.text) |owned_text| testing.allocator.free(owned_text);
        self.* = undefined;
    }

    fn value(self: *const ClipboardProbe) []const u8 {
        return self.text orelse "";
    }

    fn bridge(self: *ClipboardProbe) ui.input.NativeClipboard {
        return .{
            .context = self,
            .read_text_fn = read,
            .write_text_fn = write,
            .maximum_bytes = 1024,
        };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator) ui.Error!?[]u8 {
        const self: *ClipboardProbe = @ptrCast(@alignCast(context));
        const value_text = self.text orelse return null;
        return try allocator.dupe(u8, value_text);
    }

    fn write(context: *anyopaque, value_text: []const u8) ui.Error!void {
        const self: *ClipboardProbe = @ptrCast(@alignCast(context));
        const replacement = try testing.allocator.dupe(u8, value_text);
        if (self.text) |previous| testing.allocator.free(previous);
        self.text = replacement;
    }
};

const TextInputProbe = struct {
    active: bool = false,
    selection: ui.input.TextRange = .{ .start = 0, .end = 0 },

    fn bridge(self: *TextInputProbe) ui.input.NativeTextInput {
        return .{
            .context = self,
            .set_active_fn = setActive,
            .set_candidate_rect_fn = setCandidateRect,
            .set_surrounding_text_fn = setSurroundingText,
            .maximum_surrounding_text_bytes = 1024,
        };
    }

    fn setActive(context: *anyopaque, _: handles.WindowId, active: bool) ui.Error!void {
        const self: *TextInputProbe = @ptrCast(@alignCast(context));
        self.active = active;
    }

    fn setCandidateRect(_: *anyopaque, _: handles.WindowId, _: ui.Rect) ui.Error!void {}

    fn setSurroundingText(
        context: *anyopaque,
        _: handles.WindowId,
        _: []const u8,
        selection: ui.input.TextRange,
    ) ui.Error!void {
        const self: *TextInputProbe = @ptrCast(@alignCast(context));
        self.selection = selection;
    }
};

fn sendShortcut(
    field: *ui.widgets.TextField,
    dispatch: *ui.input.Dispatch,
    context: *ui.input.Context,
    scalar: u21,
    shift: bool,
) ui.Error!void {
    const value: ui.input.Event = .{ .key_down = .{
        .key = .{ .character = scalar },
        .physical_code = 0,
        .modifiers = .{ .command = true, .shift = shift },
    } };
    try field.event(dispatch, &value, context);
}

fn textFieldSetValueAllocationProbe(allocator: std.mem.Allocator) !void {
    var field = try ui.widgets.TextField.init(allocator, "committed");
    defer field.deinit();
    field.setValue("replacement value") catch |err| {
        if (err == error.OutOfMemory) try testing.expectEqualStrings("committed", field.value());
        return err;
    };
    try testing.expectEqualStrings("replacement value", field.value());
}

fn emptyTextMeasure(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    _: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    return .{ .size = .zero };
}

fn wrappingTextMeasure(
    _: *anyopaque,
    value: []const u8,
    _: ui.style.TextStyle,
    constraints: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    const natural_width = @as(f32, @floatFromInt(value.len)) * 10;
    const width = @min(natural_width, constraints.maximum.width);
    const lines = @max(@as(f32, 1), @ceil(natural_width / @max(width, 1)));
    return .{
        .size = constraints.constrain(.{ .width = width, .height = lines * 10 }),
        .baseline = 8,
    };
}

fn clippedTextMeasure(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    constraints: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    return .{
        .size = constraints.constrain(.{ .width = 32, .height = 30 }),
        .baseline = 24,
    };
}

fn variableBaselineTextMeasure(
    _: *anyopaque,
    value: []const u8,
    _: ui.style.TextStyle,
    constraints: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    return .{
        .size = constraints.constrain(.{ .width = 20, .height = 10 }),
        .baseline = if (std.mem.eql(u8, value, "high")) 8 else 3,
    };
}

fn emptyCustomMeasure(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    _: ui.layout.Constraints,
) ui.Error!ui.Size {
    return .zero;
}

const EventCollector = struct {
    const Tag = std.meta.Tag(ui.platform.WindowEvent);
    tags: [32]Tag = undefined,
    len: usize = 0,

    fn receive(context: *anyopaque, _: handles.WindowId, event: *const ui.platform.WindowEvent) void {
        const self: *EventCollector = @ptrCast(@alignCast(context));
        if (self.len == self.tags.len) return;
        self.tags[self.len] = std.meta.activeTag(event.*);
        self.len += 1;
    }
};

const EffectProbe = struct {
    runs: usize = 0,
    drops: usize = 0,

    fn deferred(self: *EffectProbe) ui.runtime_effect.Deferred {
        return .{ .context = self, .run_fn = run, .drop_fn = drop };
    }

    fn run(context: *anyopaque) void {
        const self: *EffectProbe = @ptrCast(@alignCast(context));
        self.runs += 1;
    }

    fn drop(context: *anyopaque) void {
        const self: *EffectProbe = @ptrCast(@alignCast(context));
        self.drops += 1;
    }
};

const MenuProbe = struct {
    set_calls: usize = 0,
    show_calls: usize = 0,

    fn set(context: *anyopaque, _: []const ui.platform.MenuItem) ui.Error!void {
        const self: *MenuProbe = @ptrCast(@alignCast(context));
        self.set_calls += 1;
    }

    fn show(
        context: *anyopaque,
        _: handles.WindowId,
        _: ui.Point,
        _: []const ui.platform.MenuItem,
    ) ui.Error!void {
        const self: *MenuProbe = @ptrCast(@alignCast(context));
        self.show_calls += 1;
    }
};

const PayloadCollector = struct {
    ime_owned: bool = false,
    path_owned: bool = false,
    accessibility_owned: bool = false,

    fn receive(context: *anyopaque, _: handles.WindowId, event: *const ui.platform.WindowEvent) void {
        const self: *PayloadCollector = @ptrCast(@alignCast(context));
        switch (event.*) {
            .input => |input_event| switch (input_event) {
                .ime => |ime| switch (ime) {
                    .commit_text => |commit| self.ime_owned = std.mem.eql(u8, commit.text, "ime"),
                    else => {},
                },
                .file_drop_performed => |drop| {
                    self.path_owned = drop.paths.len == 1 and std.mem.eql(u8, drop.paths[0], "/tmp/a");
                },
                else => {},
            },
            .accessibility_action => |request| {
                self.accessibility_owned = if (request.value) |value|
                    std.mem.eql(u8, value, "value")
                else
                    false;
            },
            else => {},
        }
    }
};

const CompletionProbe = struct {
    applied: u32 = 0,
    dropped: u32 = 0,

    fn completion(self: *CompletionProbe, task: handles.TaskId) ui.runtime_task.Completion {
        return .{
            .task = task,
            .context = self,
            .apply_fn = apply,
            .drop_fn = drop,
        };
    }

    fn apply(context: *anyopaque) void {
        const self: *CompletionProbe = @ptrCast(@alignCast(context));
        self.applied += 1;
    }

    fn drop(context: *anyopaque) void {
        const self: *CompletionProbe = @ptrCast(@alignCast(context));
        self.dropped += 1;
    }
};

const ComponentProbe = struct {
    dropped: u32 = 0,

    fn descriptor(self: *ComponentProbe) ui.Component.Descriptor {
        return .{ .context = self, .build_fn = build, .drop_fn = drop };
    }

    fn build(_: *anyopaque, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        return .{};
    }

    fn drop(context: *anyopaque) void {
        const self: *ComponentProbe = @ptrCast(@alignCast(context));
        self.dropped += 1;
    }
};

fn failingHandler(
    _: *anyopaque,
    _: *ui.input.Dispatch,
    _: *const ui.input.Event,
    _: *ui.input.Context,
) ui.Error!void {
    return error.BudgetExceeded;
}

fn checkReconcileAllocationFailures(allocator: std.mem.Allocator) !void {
    // Force every resize through the allocate-copy-free path so the number of
    // independently fail-able allocation points does not depend on whether a
    // backing allocator can grow one particular block in place.
    var baseline = testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    try reconcileAllocationProbe(baseline.allocator());
    const required = baseline.alloc_index;
    for (0..required) |fail_index| {
        var failing = testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        reconcileAllocationProbe(failing.allocator()) catch |err| switch (err) {
            error.OutOfMemory => {
                if (failing.allocated_bytes != failing.freed_bytes) return error.MemoryLeakDetected;
                continue;
            },
            else => return err,
        };
        if (failing.has_induced_failure) return error.SwallowedOutOfMemoryError;
        return error.NondeterministicMemoryUsage;
    }
}

fn reconcileAllocationProbe(allocator: std.mem.Allocator) !void {
    var store = ui.NodeStore.init(allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const original_children = [_]ui.NodeSpec{
        (ui.NodeSpec{
            .kind = .{ .text = "first" },
            .style = .{ .layout = .{ .width = .{ .points = 10 } } },
            .semantics = .{ .label = "first-original" },
        }).withKey(11),
        (ui.NodeSpec{
            .kind = .{ .text = "second" },
            .style = .{ .layout = .{ .width = .{ .points = 12 } } },
            .semantics = .{ .label = "second-original" },
        }).withKey(22),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &original_children }, 1, scratch.allocator());
    const initial_retained_bytes = store.retainedBytes();
    const initial = store.getConst(root).?;
    const original_ids = [2]handles.NodeId{ initial.children.items[0], initial.children.items[1] };
    _ = scratch.reset(.free_all);

    const replacement_children = [_]ui.NodeSpec{
        (ui.NodeSpec{
            .kind = .spacer,
            .style = .{ .layout = .{ .width = .{ .points = 20 } } },
            .semantics = .{ .label = "first-replaced" },
        }).withKey(11),
        (ui.NodeSpec{
            .kind = .{ .text = "second-updated" },
            .style = .{ .layout = .{ .width = .{ .points = 24 } } },
            .semantics = .{ .label = "second-updated" },
        }).withKey(22),
        (ui.NodeSpec{
            .kind = .{ .text = "third" },
            .style = .{ .layout = .{ .width = .{ .points = 30 } } },
            .semantics = .{ .label = "third-new" },
        }).withKey(33),
    };
    const reconciled = store.reconcile(root, .invalid, .invalid, .{ .children = &replacement_children }, 1, scratch.allocator()) catch |err| {
        if (err != error.OutOfMemory) return err;
        const committed = store.getConst(root) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 2), committed.children.items.len);
        try testing.expect(committed.children.items[0].eql(original_ids[0]));
        try testing.expect(committed.children.items[1].eql(original_ids[1]));
        try testing.expect(std.meta.eql(ui.layout.Length{ .points = 10 }, store.getConst(original_ids[0]).?.borrowedStyle().layout.width));
        try testing.expect(std.meta.eql(ui.layout.Length{ .points = 12 }, store.getConst(original_ids[1]).?.borrowedStyle().layout.width));
        var live: usize = 0;
        var iterator = store.inspectIterator();
        while (iterator.next()) |_| live += 1;
        try testing.expectEqual(@as(usize, 3), live);
        try testing.expectEqual(initial_retained_bytes, store.retainedBytes());
        return err;
    };
    try testing.expect(reconciled.eql(root));
    const committed = store.getConst(root).?;
    try testing.expectEqual(@as(usize, 3), committed.children.items.len);
    try testing.expect(!committed.children.items[0].eql(original_ids[0]));
    try testing.expect(committed.children.items[1].eql(original_ids[1]));
    try testing.expect(store.retainedBytes() >= initial_retained_bytes);
}

fn svgManagerAllocationProbe(allocator: std.mem.Allocator) !void {
    var manager = ui.SvgManager.init(allocator, .{}, 1024 * 1024, 8);
    defer manager.deinit();
    const source =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
        \\  <rect width="8" height="8" fill="#336699"/>
        \\</svg>
    ;
    const id = try manager.load(source);
    try manager.release(id);
}
