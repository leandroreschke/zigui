const std = @import("std");
const ui = @import("zigui");
const metal = ui.internal_backend_test.metal_renderer;
const handles = ui.core.handles;

test "Metal renderer applies retained backdrop effects to offscreen targets" {
    const TestProvider = struct {
        fn layer(_: *anyopaque, _: handles.WindowId) ?*anyopaque {
            return null;
        }
    };
    var provider_context: u8 = 0;
    const renderer = metal.Renderer.create(std.testing.allocator, .{
        .context = &provider_context,
        .layer_fn = TestProvider.layer,
    }, .{}, .{}) catch |err| switch (err) {
        error.NoGpuDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(std.testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 8),
        .background = ui.Color.rgba(1, 0, 0, 1),
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(4, 0, 4, 8),
        .background = ui.Color.rgba(0, 0, 1, 1),
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.backdropEffect(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 8, 8),
        .radii = .{},
        .blur_radius = 2,
        .saturation = 1,
    });
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 8,
        .height = 8,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), std.testing.allocator)).?;
    defer readback.deinit(std.testing.allocator);
    const offset = 4 * readback.stride + 3 * 4;
    try std.testing.expect(readback.pixels[offset] > 0);
    try std.testing.expect(readback.pixels[offset + 2] > 0);
}

test "Metal renderer paints content translated into a parent scroll clip" {
    const TestProvider = struct {
        fn layer(_: *anyopaque, _: handles.WindowId) ?*anyopaque {
            return null;
        }
    };
    var provider_context: u8 = 0;
    const renderer = metal.Renderer.create(std.testing.allocator, .{
        .context = &provider_context,
        .layer_fn = TestProvider.layer,
    }, .{}, .{}) catch |err| switch (err) {
        error.NoGpuDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(std.testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    _ = try builder.pushClip(ui.Rect.fromXYWH(0, 0, 10, 10), .{});
    _ = try builder.pushLayer(1, .normal, ui.Affine2D.translation(.{ .x = 0, .y = -100 }));
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 100, 10, 10),
        .background = ui.Color.rgba(1, 0, 0, 1),
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.popLayer();
    try builder.popClip();
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 10,
        .height = 10,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), std.testing.allocator)).?;
    defer readback.deinit(std.testing.allocator);
    const offset = 5 * readback.stride + 5 * 4;
    try std.testing.expect(readback.pixels[offset] > 240);
    try std.testing.expect(readback.pixels[offset + 3] > 240);
}

test "Metal asynchronous offscreen readback retains scene until completion" {
    const TestProvider = struct {
        fn layer(_: *anyopaque, _: handles.WindowId) ?*anyopaque {
            return null;
        }
    };
    var provider_context: u8 = 0;
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    const renderer = metal.Renderer.create(std.testing.allocator, .{
        .context = &provider_context,
        .layer_fn = TestProvider.layer,
    }, .{}, memory) catch |err| switch (err) {
        error.NoGpuDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    try std.testing.expect(renderer.capabilities().offscreen_async_readback);

    var scene = ui.scene.Scene.init(std.testing.allocator);
    const id = blk: {
        var builder = ui.scene.Builder.init(&scene, .{});
        defer builder.deinit();
        try builder.quad(.{
            .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
            .background = ui.Color.rgba(0, 1, 0, 1),
            .border_color = .transparent,
            .border_widths = .{},
            .radii = .{},
        }, null);
        try builder.finish();
        break :blk try renderer.beginOffscreen(.{
            .width = 4,
            .height = 4,
            .scale_factor = try ui.ScaleFactor.init(1),
            .format = .rgba8_srgb,
        }, scene.view());
    };
    scene.deinit();

    var result = try renderer.pollOffscreen(id, std.testing.allocator);
    const started = std.Io.Clock.awake.now(std.testing.io);
    while (result == .pending and
        started.durationTo(std.Io.Clock.awake.now(std.testing.io)).nanoseconds < 2 * std.time.ns_per_s)
    {
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        result = try renderer.pollOffscreen(id, std.testing.allocator);
    }
    switch (result) {
        .ready => |readback| {
            var owned = readback;
            defer owned.deinit(std.testing.allocator);
            const offset = 2 * owned.stride + 2 * 4;
            try std.testing.expect(owned.pixels[offset + 1] > 240);
            try std.testing.expect(owned.pixels[offset + 3] > 240);
        },
        .pending => return error.TestExpectedEqual,
        .failed => |err| return err,
        .cancelled => return error.TestExpectedEqual,
    }
    try std.testing.expectError(error.InvalidHandle, renderer.pollOffscreen(id, std.testing.allocator));
}

test "Metal asynchronous requests do not consume presentation frame slots" {
    const TestProvider = struct {
        fn layer(_: *anyopaque, _: handles.WindowId) ?*anyopaque {
            return null;
        }
    };
    var provider_context: u8 = 0;
    var policy: ui.config.GpuPolicy = .{};
    policy.frames_in_flight = 1;
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 3;
    const renderer = metal.Renderer.create(std.testing.allocator, .{
        .context = &provider_context,
        .layer_fn = TestProvider.layer,
    }, policy, memory) catch |err| switch (err) {
        error.NoGpuDevice => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();

    const empty_scene: ui.render.SceneView = .{
        .operations = &.{},
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = &.{},
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    };
    const target: ui.render.OffscreenTarget = .{
        .width = 2,
        .height = 2,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    };
    _ = try renderer.beginOffscreen(target, empty_scene);
    _ = try renderer.beginOffscreen(target, empty_scene);
    _ = try renderer.beginOffscreen(target, empty_scene);

    // A pending async request must not occupy the presentation ring. The
    // provider intentionally has no layer, so reaching this check proves the
    // presentation slot remained available without needing a native window.
    try std.testing.expectError(error.SurfaceUnavailable, renderer.beginFrame(.{
        .window = handles.WindowId.init(1, 1),
        .logical_size = .{ .width = 2, .height = 2 },
        .drawable_width = 2,
        .drawable_height = 2,
        .scale_factor = try ui.ScaleFactor.init(1),
        .clear_color = .transparent,
    }));
}
