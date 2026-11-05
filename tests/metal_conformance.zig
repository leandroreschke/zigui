const std = @import("std");
const ui = @import("zigui");
const metal = ui.internal_backend_test.metal_renderer;
const handles = ui.core.handles;

test "Metal focus borders preserve transparent and translucent button interiors" {
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

    for ([_]f32{ 0, 0.5, 1 }) |fill_alpha| {
        var scene = ui.scene.Scene.init(std.testing.allocator);
        defer scene.deinit();
        var builder = ui.scene.Builder.init(&scene, .{});
        defer builder.deinit();
        try builder.quad(.{
            .bounds = ui.Rect.fromXYWH(0, 0, 24, 24),
            .background = ui.Color.rgba(0, 0, 1, fill_alpha),
            .border_color = ui.Color.rgba(1, 0, 0, 1),
            .border_widths = ui.Insets.all(1.5),
            .radii = ui.CornerRadii.all(6),
        }, null);
        try builder.finish();

        var readback = (try renderer.renderOffscreen(.{
            .width = 24,
            .height = 24,
            .scale_factor = try ui.ScaleFactor.init(1),
            .format = .rgba8,
        }, scene.view(), std.testing.allocator)).?;
        defer readback.deinit(std.testing.allocator);
        const center = 12 * readback.stride + 12 * 4;
        try std.testing.expectEqual(@as(u8, 0), readback.pixels[center]);
        try std.testing.expectEqual(@as(u8, 0), readback.pixels[center + 1]);
        try std.testing.expectApproxEqAbs(fill_alpha * 255, @as(f32, @floatFromInt(readback.pixels[center + 2])), 1);
        try std.testing.expectApproxEqAbs(fill_alpha * 255, @as(f32, @floatFromInt(readback.pixels[center + 3])), 1);
        const border = 12 * readback.stride;
        try std.testing.expect(readback.pixels[border] > 220);
        try std.testing.expectEqual(@as(u8, 0), readback.pixels[border + 1]);
        try std.testing.expectEqual(@as(u8, 0), readback.pixels[border + 2]);
        try std.testing.expect(readback.pixels[border + 3] > 220);
        const inner_edge = border + 4;
        try std.testing.expectApproxEqAbs(@as(f32, 127.5), @as(f32, @floatFromInt(readback.pixels[inner_edge])), 1);
        try std.testing.expectApproxEqAbs(fill_alpha * 127.5, @as(f32, @floatFromInt(readback.pixels[inner_edge + 2])), 1);
        try std.testing.expectApproxEqAbs(127.5 + fill_alpha * 127.5, @as(f32, @floatFromInt(readback.pixels[inner_edge + 3])), 1);
        try std.testing.expectEqual(@as(u8, 0), readback.pixels[3]);
    }
}

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

test "drawable acquisition stays off-thread and bounds pending work" {
    const objc = ui.internal_backend_test.metal_objc;
    const Acquisition = ui.internal_backend_test.metal_drawable.Acquisition;
    const Error = ui.Error;
    const Gate = struct {
        extern "c" fn dispatch_release(objc.Id) void;
        extern "c" fn dispatch_semaphore_create(isize) objc.Id;
        extern "c" fn dispatch_semaphore_wait(objc.Id, u64) isize;
        extern "c" fn dispatch_semaphore_signal(objc.Id) isize;
        extern "c" fn usleep(c_uint) c_int;
        var semaphore: objc.Id = null;
        var calls = std.atomic.Value(usize).init(0);
        var on_main = std.atomic.Value(bool).init(false);
        var fail = std.atomic.Value(bool).init(false);
        fn next(_: objc.Id, _: objc.Sel) callconv(.c) objc.Id {
            _ = calls.fetchAdd(1, .monotonic);
            on_main.store(objc.send(bool, objc.class("NSThread"), "isMainThread", .{}), .monotonic);
            _ = dispatch_semaphore_wait(semaphore, std.math.maxInt(u64));
            if (fail.load(.monotonic)) return null;
            return objc.autorelease(objc.send(objc.Id, objc.class("NSObject"), "new", .{}));
        }
        fn awaitResult(value: *Acquisition) Error!objc.Id {
            for (0..2000) |_| {
                if (!value.pending()) return value.take();
                _ = usleep(1000);
            }
            return error.PlatformFailure;
        }
    };
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const cls = objc.objc_allocateClassPair(objc.class("NSObject"), "ZigUIDrawableAcquisitionTest", 0);
    try std.testing.expect(cls != null);
    try std.testing.expect(objc.class_addMethod(cls, objc.selector("nextDrawable"), @ptrCast(&Gate.next), "@@:"));
    objc.objc_registerClassPair(cls);
    const layer = objc.send(objc.Id, cls, "new", .{});
    defer objc.release(layer);
    Gate.semaphore = Gate.dispatch_semaphore_create(0);
    defer Gate.dispatch_release(Gate.semaphore);
    var value = try Acquisition.init(layer);
    defer value.deinit();
    // Always unblock the worker before joining, including assertion failures.
    defer _ = Gate.dispatch_semaphore_signal(Gate.semaphore);
    value.start();
    for (0..32) |_| {
        value.start();
        try std.testing.expect(value.pending());
        try std.testing.expect((try value.take()) == null);
    }
    _ = Gate.dispatch_semaphore_signal(Gate.semaphore);
    const drawable = try Gate.awaitResult(&value);
    try std.testing.expect(drawable != null);
    objc.release(drawable);
    try std.testing.expectEqual(@as(usize, 1), Gate.calls.load(.monotonic));
    try std.testing.expect(!Gate.on_main.load(.monotonic));
    Gate.fail.store(true, .monotonic);
    value.start();
    _ = Gate.dispatch_semaphore_signal(Gate.semaphore);
    try std.testing.expectError(error.SurfaceUnavailable, Gate.awaitResult(&value));
    try std.testing.expectEqual(@as(usize, 2), Gate.calls.load(.monotonic));
}

test "progressive sprite blurs neighboring pixels" {
    const a = std.testing.allocator;
    const provider = struct {
        fn layer(_: *anyopaque, _: ui.core.handles.WindowId) ?*anyopaque {
            return null;
        }
    };
    var context: u8 = 0;
    const renderer = try ui.internal_backend_test.metal_renderer.Renderer.create(a, .{ .context = &context, .layer_fn = provider.layer }, .{}, .{});
    defer renderer.deinit();
    const texture = ui.core.handles.TextureId.init(41, 1);
    try renderer.createTexture(texture, .{ .width = 16, .height = 16, .format = .rgba8 });
    defer renderer.destroyTexture(texture, 0) catch {};
    var bytes: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        const n: u8 = if (x % 2 == 0) 0 else 255;
        const off = (y * 16 + x) * 4;
        @memcpy(bytes[off..][0..4], &[_]u8{ n, n, n, 255 });
    };
    try renderer.writeTexture(texture, .{ .width = 16, .height = 16 }, &bytes, 64);
    var results: [2]u8 = undefined;
    for ([_]f32{ 0, 5 }, 0..) |radius, index| {
        var scene = ui.scene.Scene.init(a);
        defer scene.deinit();
        var b = ui.scene.Builder.init(&scene, .{});
        defer b.deinit();
        const sprite: ui.scene_abi.Sprite = .{ .bounds = ui.Rect.fromXYWH(0, 0, 16, 16), .uv_bounds = ui.Rect.fromXYWH(0, 0, 1, 1), .color = .white, .texture = texture.encode(), .tile_generation = texture.generation, .format = @backingInt(ui.scene_abi.TextureFormat.rgba8) };
        try b.colorSprite(sprite);
        var filter = sprite;
        filter.effect = .light_text;
        filter.effect_radius = radius;
        filter.effect_height = 16;
        try b.colorSprite(filter);
        try b.finish();
        var image = (try renderer.renderOffscreen(.{ .width = 16, .height = 16, .scale_factor = try ui.ScaleFactor.init(1), .format = .rgba8 }, scene.view(), a)).?;
        defer image.deinit(a);
        results[index] = image.pixels[15 * image.stride + 8 * 4];
    }
    try std.testing.expect(results[1] > results[0] + 20);
}

test "preview blur preserves color and covers the whole image" {
    const a = std.testing.allocator;
    const provider = struct {
        fn layer(_: *anyopaque, _: ui.core.handles.WindowId) ?*anyopaque {
            return null;
        }
    };
    var context: u8 = 0;
    const renderer = try ui.internal_backend_test.metal_renderer.Renderer.create(a, .{ .context = &context, .layer_fn = provider.layer }, .{}, .{});
    defer renderer.deinit();
    const texture = ui.core.handles.TextureId.init(43, 1);
    try renderer.createTexture(texture, .{ .width = 16, .height = 16, .format = .rgba8 });
    defer renderer.destroyTexture(texture, 0) catch {};
    var bytes: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        const n: u8 = if (x % 2 == 0) 0 else 200;
        const off = (y * 16 + x) * 4;
        @memcpy(bytes[off..][0..4], &[_]u8{ n, n, n, 255 });
    };
    try renderer.writeTexture(texture, .{ .width = 16, .height = 16 }, &bytes, 64);
    var scene = ui.scene.Scene.init(a);
    defer scene.deinit();
    var b = ui.scene.Builder.init(&scene, .{});
    defer b.deinit();
    try b.colorSprite(.{ .bounds = ui.Rect.fromXYWH(0, 0, 16, 16), .uv_bounds = ui.Rect.fromXYWH(0, 0, 1, 1), .color = .white, .texture = texture.encode(), .tile_generation = texture.generation, .format = @backingInt(ui.scene_abi.TextureFormat.rgba8), .effect = .preview_blur, .effect_radius = 5, .effect_height = 1 });
    try b.finish();
    var image = (try renderer.renderOffscreen(.{ .width = 16, .height = 16, .scale_factor = try ui.ScaleFactor.init(1), .format = .rgba8 }, scene.view(), a)).?;
    defer image.deinit(a);
    const top = image.pixels[1 * image.stride + 8 * 4];
    const bottom = image.pixels[14 * image.stride + 8 * 4];
    try std.testing.expect(top > 20 and top < 160);
    try std.testing.expectEqual(top, bottom);
    try std.testing.expectEqual(@as(u8, 255), image.pixels[1 * image.stride + 8 * 4 + 3]);
}

test "progressive sprite adapts to light and dark text" {
    const a = std.testing.allocator;
    const provider = struct {
        fn layer(_: *anyopaque, _: ui.core.handles.WindowId) ?*anyopaque {
            return null;
        }
    };
    var context: u8 = 0;
    const renderer = try ui.internal_backend_test.metal_renderer.Renderer.create(a, .{ .context = &context, .layer_fn = provider.layer }, .{}, .{});
    defer renderer.deinit();
    const texture = ui.core.handles.TextureId.init(42, 1);
    try renderer.createTexture(texture, .{ .width = 1, .height = 1, .format = .rgba8 });
    defer renderer.destroyTexture(texture, 0) catch {};
    for ([_]ui.scene_abi.SpriteEffect{ .light_text, .dark_text }) |effect| {
        const n: u8 = if (effect == .light_text) 255 else 0;
        try renderer.writeTexture(texture, .{ .width = 1, .height = 1 }, &[_]u8{ n, n, n, 255 }, 4);
        var scene = ui.scene.Scene.init(a);
        defer scene.deinit();
        var b = ui.scene.Builder.init(&scene, .{});
        defer b.deinit();
        const sprite: ui.scene_abi.Sprite = .{ .bounds = ui.Rect.fromXYWH(0, 0, 16, 16), .uv_bounds = ui.Rect.fromXYWH(0, 0, 1, 1), .color = .white, .texture = texture.encode(), .tile_generation = texture.generation, .format = @backingInt(ui.scene_abi.TextureFormat.rgba8) };
        try b.colorSprite(sprite);
        var overlay = sprite;
        overlay.effect = effect;
        overlay.effect_radius = 5;
        overlay.effect_height = 12;
        try b.colorSprite(overlay);
        try b.finish();
        var image = (try renderer.renderOffscreen(.{ .width = 16, .height = 16, .scale_factor = try ui.ScaleFactor.init(1), .format = .rgba8 }, scene.view(), a)).?;
        defer image.deinit(a);
        const top = image.pixels[2 * image.stride + 8 * 4];
        const bottom = image.pixels[15 * image.stride + 8 * 4];
        if (effect == .light_text) {
            try std.testing.expect(top > 240);
            try std.testing.expect(bottom < 100);
        } else {
            try std.testing.expect(top < 10);
            try std.testing.expect(bottom > 150);
        }
    }
}
