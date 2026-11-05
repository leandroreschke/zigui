const std = @import("std");
const ui = @import("zigui");

const Scene = ui.scene.Scene;
const Builder = ui.scene.Builder;
const Limits = ui.scene.Limits;
const abi = ui.scene_abi;
const geometry = ui.core.geometry;
const handles = ui.core.handles;

fn quad(bounds: geometry.Rect) abi.Quad {
    return .{
        .bounds = bounds,
        .background = .{ .r = 0.15, .g = 0.25, .b = 0.35, .a = 1 },
        .border_color = .{ .r = 0.8, .g = 0.7, .b = 0.1, .a = 1 },
        .border_widths = .all(1),
        .radii = .all(2),
    };
}

fn buildBody(builder: *Builder) !void {
    const no_material = geometry.Rect.fromXYWH(1, 2, 10, 11);
    try builder.quad(quad(no_material), null);

    _ = try builder.pushClip(geometry.Rect.fromXYWH(0, 0, 100, 100), .all(4));
    _ = try builder.pushLayer(0.75, .multiply, .{ .tx = 3, .ty = 4 });

    const stops = [_]abi.GradientStop{
        .{ .offset = 0, .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } },
        .{ .offset = 1, .color = .{ .r = 0, .g = 0, .b = 1, .a = 1 } },
    };
    const material = try builder.linearGradientMaterial(.{ .x = 0, .y = 0 }, .{ .x = 30, .y = 20 }, &stops);
    try builder.quad(quad(geometry.Rect.fromXYWH(4, 5, 20, 21)), material);
    try builder.shadow(.{
        .bounds = geometry.Rect.fromXYWH(2, 3, 8, 9),
        .color = .{ .r = 0, .g = 0, .b = 0, .a = 0.4 },
        .radii = .all(1),
        .offset = .{ .x = 2, .y = 3 },
        .blur_radius = 4,
        .spread = 1,
    });
    try builder.path(.{
        .vertex_start = 0,
        .vertex_count = 0,
        .fill_rule = @backingInt(abi.FillRule.non_zero),
        .color = .{ .r = 0.2, .g = 0.8, .b = 0.3, .a = 1 },
        .bounds = geometry.Rect.fromXYWH(0, 0, 12, 12),
    }, &[_]abi.PathVertex{
        .{ .position = .{ .x = 0, .y = 0 }, .control = .{}, .kind = @backingInt(abi.PathCommand.move_to) },
        .{ .position = .{ .x = 12, .y = 12 }, .control = .{}, .kind = @backingInt(abi.PathCommand.line_to) },
    }, material);
    try builder.underline(.{
        .bounds = geometry.Rect.fromXYWH(0, 20, 30, 2),
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .thickness = 1,
        .wave_amplitude = 0,
        .wave_period = 0,
    });
    try builder.backdropEffect(.{
        .bounds = geometry.Rect.fromXYWH(0, 0, 30, 30),
        .radii = .all(2),
        .blur_radius = 2,
        .saturation = 1.2,
        .opacity = 0.8,
    });
    try builder.monochromeSprite(.{
        .bounds = geometry.Rect.fromXYWH(0, 0, 10, 10),
        .uv_bounds = geometry.Rect.fromXYWH(0, 0, 1, 1),
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .texture = handles.TextureId.init(3, 1).encode(),
        .tile_generation = 1,
        .format = @backingInt(abi.TextureFormat.a8),
    });
    try builder.colorSprite(.{
        .bounds = geometry.Rect.fromXYWH(10, 0, 10, 10),
        .uv_bounds = geometry.Rect.fromXYWH(0, 0, 1, 1),
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .texture = handles.TextureId.init(4, 1).encode(),
        .tile_generation = 1,
        .format = @backingInt(abi.TextureFormat.rgba8),
    });
    try builder.externalSurface(.{
        .bounds = geometry.Rect.fromXYWH(0, 0, 10, 10),
        .uv_bounds = geometry.Rect.fromXYWH(0, 0, 1, 1),
        .surface = handles.SurfaceId.init(5, 1).encode(),
        .generation = 1,
        .color_space = @backingInt(ui.render.ColorSpace.srgb),
        .opacity = 1,
    });
    try builder.customPass(handles.RenderExtensionId.init(6, 1), geometry.Rect.fromXYWH(0, 0, 8, 8), "cache", 7);
    try builder.nativeMediaWithVisibility(handles.NativeMediaId.init(7, 1), geometry.Rect.fromXYWH(1, 1, 8, 8), false);

    try builder.popLayer();
    try builder.popClip();
}

fn expectSceneEqual(a: *const Scene, b: *const Scene) !void {
    try std.testing.expectEqualSlices(abi.Operation, a.operations.items, b.operations.items);
    try std.testing.expectEqualSlices(abi.Material, a.materials.items, b.materials.items);
    try std.testing.expectEqualSlices(abi.GradientStop, a.gradient_stops.items, b.gradient_stops.items);
    try std.testing.expectEqualSlices(abi.Clip, a.clips.items, b.clips.items);
    try std.testing.expectEqualSlices(abi.Layer, a.layers.items, b.layers.items);
    try std.testing.expectEqualSlices(abi.Shadow, a.shadows.items, b.shadows.items);
    try std.testing.expectEqualSlices(abi.Quad, a.quads.items, b.quads.items);
    try std.testing.expectEqualSlices(abi.Path, a.paths.items, b.paths.items);
    try std.testing.expectEqualSlices(abi.PathVertex, a.path_vertices.items, b.path_vertices.items);
    try std.testing.expectEqualSlices(abi.Underline, a.underlines.items, b.underlines.items);
    try std.testing.expectEqualSlices(abi.Sprite, a.monochrome_sprites.items, b.monochrome_sprites.items);
    try std.testing.expectEqualSlices(abi.Sprite, a.color_sprites.items, b.color_sprites.items);
    try std.testing.expectEqualSlices(abi.ExternalSurface, a.external_surfaces.items, b.external_surfaces.items);
    try std.testing.expectEqualSlices(abi.CustomPass, a.custom_passes.items, b.custom_passes.items);
    try std.testing.expectEqualSlices(u8, a.custom_payload.items, b.custom_payload.items);
    try std.testing.expectEqualSlices(abi.BackdropEffect, a.backdrop_effects.items, b.backdrop_effects.items);
    try std.testing.expectEqualDeep(a.native_media_placements.items, b.native_media_placements.items);
}

test "retained scene replay matches ordinary building under inherited stacks" {
    var source = Scene.init(std.testing.allocator);
    defer source.deinit();
    var source_builder = Builder.init(&source, .{});
    defer source_builder.deinit();
    try buildBody(&source_builder);
    try source_builder.finish();

    var replayed = Scene.init(std.testing.allocator);
    defer replayed.deinit();
    var replay_builder = Builder.init(&replayed, .{});
    defer replay_builder.deinit();
    _ = try replay_builder.solidMaterial(.{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 });
    _ = try replay_builder.pushClip(geometry.Rect.fromXYWH(0, 0, 200, 200), .{});
    _ = try replay_builder.pushLayer(0.9, .screen, .identity);
    try replay_builder.quad(quad(geometry.Rect.fromXYWH(50, 50, 4, 4)), null);
    try replay_builder.appendRetained(&source);
    try replay_builder.popLayer();
    try replay_builder.popClip();
    try replay_builder.finish();

    var expected = Scene.init(std.testing.allocator);
    defer expected.deinit();
    var expected_builder = Builder.init(&expected, .{});
    defer expected_builder.deinit();
    _ = try expected_builder.solidMaterial(.{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 });
    _ = try expected_builder.pushClip(geometry.Rect.fromXYWH(0, 0, 200, 200), .{});
    _ = try expected_builder.pushLayer(0.9, .screen, .identity);
    try expected_builder.quad(quad(geometry.Rect.fromXYWH(50, 50, 4, 4)), null);
    try buildBody(&expected_builder);
    try expected_builder.popLayer();
    try expected_builder.popClip();
    try expected_builder.finish();

    try expectSceneEqual(&replayed, &expected);
}

test "retained scene replay rejects budget overflow without mutating destination" {
    var source = Scene.init(std.testing.allocator);
    defer source.deinit();
    var source_builder = Builder.init(&source, .{});
    defer source_builder.deinit();
    try source_builder.quad(quad(geometry.Rect.fromXYWH(0, 0, 4, 4)), null);
    try source_builder.finish();

    var destination = Scene.init(std.testing.allocator);
    defer destination.deinit();
    var builder = Builder.init(&destination, Limits{ .primitives = 1 });
    defer builder.deinit();
    try builder.quad(quad(geometry.Rect.fromXYWH(0, 0, 4, 4)), null);
    const operations_before = destination.operations.items.len;
    const quads_before = destination.quads.items.len;
    try std.testing.expectError(error.BudgetExceeded, builder.appendRetained(&source));
    try std.testing.expectEqual(operations_before, destination.operations.items.len);
    try std.testing.expectEqual(quads_before, destination.quads.items.len);
}

test "retained scene replay counts an operation merge against the operation budget" {
    var source = Scene.init(std.testing.allocator);
    defer source.deinit();
    var source_builder = Builder.init(&source, .{});
    defer source_builder.deinit();
    try source_builder.quad(quad(geometry.Rect.fromXYWH(4, 0, 4, 4)), null);
    try source_builder.finish();

    var destination = Scene.init(std.testing.allocator);
    defer destination.deinit();
    var builder = Builder.init(&destination, Limits{ .operations = 1, .primitives = 2 });
    defer builder.deinit();
    try builder.quad(quad(geometry.Rect.fromXYWH(0, 0, 4, 4)), null);
    try builder.appendRetained(&source);
    try builder.finish();
    try std.testing.expectEqual(@as(usize, 1), destination.operations.items.len);
    try std.testing.expectEqual(@as(u32, 2), destination.operations.items[0].count);
}

test "retained scene replay rejects malformed source before mutation" {
    var source = Scene.init(std.testing.allocator);
    defer source.deinit();
    var source_builder = Builder.init(&source, .{});
    defer source_builder.deinit();
    try source_builder.quad(quad(geometry.Rect.fromXYWH(0, 0, 4, 4)), null);
    try source_builder.finish();
    source.operations.items[0].target = 1;

    var destination = Scene.init(std.testing.allocator);
    defer destination.deinit();
    var builder = Builder.init(&destination, .{});
    defer builder.deinit();
    try std.testing.expectError(error.InvalidScene, builder.appendRetained(&source));
    try std.testing.expectEqual(@as(usize, 0), destination.operations.items.len);
}
