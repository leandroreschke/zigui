const std = @import("std");
const ui = @import("zigui");
const fixture = @import("retained_fixture.zig");
const testing = std.testing;

const Instance = struct {
    app: *ui.App,
    window: ui.core.handles.WindowId,
    harness: ui.HeadlessPlatform.Harness,
    model: fixture.Model = .{},

    fn init(self: *Instance, retain: bool, budget: usize) !void {
        self.model = .{};
        const config: ui.config.AppConfig = .{ .allow_multiple_apps_for_testing = true, .retain_frame_work = retain, .memory = .{ .retained_scene_bytes = budget } };
        const text = try ui.InTreeTextBackend.createInstance(testing.allocator, config.memory.loaded_font_bytes, config.memory.mapped_font_bytes, config.memory.font_instance_count, config.memory.font_catalog_count, config.memory.font_catalog_bytes);
        _ = try text.registerCopy(@embedFile("fixtures/Abel-Regular.ttf"), 0, .regular, .normal);
        self.harness = try ui.HeadlessPlatform.createWithMemory(testing.allocator, text.interface(), config.memory);
        self.app = try ui.App.createWithBundle(testing.allocator, config, self.harness.bundle);
        errdefer self.app.destroy() catch unreachable;
        self.window = try self.app.openWindow(.{ .platform = .{ .title = "Retained equivalence", .size = .{ .width = 420, .height = 220 } } }, ui.Component.Descriptor.from(fixture.Model, &self.model));
        try fixture.drain(self.app);
    }

    fn redraw(self: *Instance) !void {
        try self.app.invalidateComponent(self.model.component, .{});
        try fixture.drain(self.app);
    }
};

fn expectSame(a: *Instance, b: *Instance) !void {
    const wa = a.app.windows.get(a.window).?.*;
    const wb = b.app.windows.get(b.window).?.*;
    try testing.expectEqualDeep(wa.committedScene().view(), wb.committedScene().view());
    try testing.expectEqualDeep(wa.hits.committed.entries.items, wb.hits.committed.entries.items);
    try testing.expectEqualDeep(wa.semantic_tree.snapshot_nodes.items, wb.semantic_tree.snapshot_nodes.items);
    try testing.expectEqual(a.model.custom_paints, b.model.custom_paints);
    var na = a.app.nodes.inspectIterator();
    var nb = b.app.nodes.inspectIterator();
    while (na.next()) |node_a| {
        const node_b = nb.next() orelse return error.MissingRetainedNode;
        try testing.expectEqualDeep(node_a.id, node_b.id);
        try testing.expectEqualDeep(node_a.layout_result, node_b.layout_result);
    }
    try testing.expect(nb.next() == null);
}

test "retained frames match full frames through state, geometry, scroll, portals and remounts" {
    var full: Instance = undefined;
    try full.init(false, 16 * 1024 * 1024);
    defer full.app.destroy() catch unreachable;
    var retained: Instance = undefined;
    try retained.init(true, 16 * 1024 * 1024);
    defer retained.app.destroy() catch unreachable;
    try expectSame(&full, &retained);
    var rng = std.Random.DefaultPrng.init(0x7061696e745f6162);
    for (0..240) |frame| {
        const selected = rng.random().uintLessThan(usize, 3);
        const action = frame % 12;
        for ([_]*Instance{ &full, &retained }) |instance| {
            const panel = &instance.model.panels[selected];
            switch (action) {
                0 => panel.value +%= 1,
                1 => panel.wide = !panel.wide,
                2 => panel.scroll = @floatFromInt(frame % 30),
                3 => panel.reverse = !panel.reverse,
                4 => instance.model.reverse = !instance.model.reverse,
                5 => instance.model.show_last = !instance.model.show_last,
                6 => panel.portal = !panel.portal,
                7 => try instance.harness.post(instance.window, .{ .resized = .{ .width = 350 + @as(f32, @floatFromInt(frame % 100)), .height = 230 } }),
                8 => try instance.harness.post(instance.window, .{ .scale_changed = try ui.ScaleFactor.init(if (frame % 24 == 8) 2 else 1) }),
                9 => instance.model.custom_value +%= 17,
                else => {},
            }
            if (action <= 3 or action == 6) try instance.app.invalidateComponent(panel.component, .{});
            instance.redraw() catch |err| {
                std.debug.print("equivalence frame {d}, action {d}, retained={any}: {s}\n", .{ frame, action, instance.app.app_config.retain_frame_work, @errorName(err) });
                return err;
            };
        }
        try expectSame(&full, &retained);
    }
    try testing.expect(retained.app.coordinator.counters.retained_scene_hits > 0);
}

test "scene cache exhaustion and zero budget preserve full frame output" {
    for ([_]usize{ 0, 512, 8192 }) |budget| {
        var full: Instance = undefined;
        try full.init(false, budget);
        defer full.app.destroy() catch unreachable;
        var retained: Instance = undefined;
        try retained.init(true, budget);
        defer retained.app.destroy() catch unreachable;
        for (0..5) |_| {
            try full.redraw();
            try retained.redraw();
            try expectSame(&full, &retained);
        }
        const window = retained.app.windows.get(retained.window).?.*;
        try testing.expect(window.retained_scene.budget.used <= budget);
    }
}

test "cached glyphs are rebuilt after atlas invalidation" {
    var retained: Instance = undefined;
    try retained.init(true, 16 * 1024 * 1024);
    defer retained.app.destroy() catch unreachable;
    for (0..3) |_| try retained.redraw();
    const hits = retained.app.coordinator.counters.retained_scene_hits;
    try testing.expect(hits > 0);
    if (retained.app.text) |*text| try text.deviceLost();
    try retained.redraw();
    // The retained scene must contain the newly allocated glyph identities.
    const window = retained.app.windows.get(retained.window).?.*;
    const snapshot = try testing.allocator.dupe(ui.scene_abi.Sprite, window.committedScene().monochrome_sprites.items);
    defer testing.allocator.free(snapshot);
    retained.app.app_config.retain_frame_work = false;
    try retained.redraw();
    try testing.expectEqualDeep(snapshot, window.committedScene().monochrome_sprites.items);
}

test "scene admission retries when other cache entries release capacity" {
    var instance: Instance = undefined;
    try instance.init(true, 16 * 1024 * 1024);
    defer instance.app.destroy() catch unreachable;
    const window = instance.app.windows.get(instance.window).?.*;
    var cache = @TypeOf(window.retained_scene).init(testing.allocator, 8192);
    defer cache.deinit();
    cache.beginFrame();
    const id: ui.core.handles.NodeId = .{ .index = 1, .generation = 1 };
    var counters: ui.core.metrics.Counters = .{};
    const entry = cache.lookup(id, .{ .revision = 1, .store_generation = 1, .layout_result = .{}, .scale = try ui.ScaleFactor.init(1), .device_generation = 1 }, &counters).?.entry;
    const key = entry.key;
    _ = cache.lookup(id, key, &counters);
    try testing.expect(cache.lookup(id, key, &counters).?.admit);
    const pressure = try cache.tracked.allocator().alloc(u8, 1024);
    cache.discard(entry);
    try testing.expect(!cache.lookup(id, key, &counters).?.admit);
    cache.tracked.allocator().free(pressure);
    try testing.expect(cache.lookup(id, key, &counters).?.admit);
}

test "paint-only glyph references stay bounded and advance atlas liveness" {
    for ([_]bool{ false, true }) |retain| {
        var instance: Instance = undefined;
        try instance.init(retain, 16 * 1024 * 1024);
        defer instance.app.destroy() catch unreachable;
        const glyph_count = instance.app.text.?.used_glyphs.items.len;
        try testing.expect(glyph_count > 0);
        var previous_frame = instance.app.text.?.frame;
        for (0..32) |_| {
            try instance.app.invalidateComponent(instance.model.component, .{
                .compose = false,
                .layout = false,
                .paint = true,
                .hit_test = false,
                .semantics = false,
                .resources = false,
            });
            try fixture.drain(instance.app);
            try testing.expectEqual(glyph_count, instance.app.text.?.used_glyphs.items.len);
            try testing.expect(instance.app.text.?.frame > previous_frame);
            previous_frame = instance.app.text.?.frame;
        }
    }
}
