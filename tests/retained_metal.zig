const std = @import("std");
const ui = @import("zigui");
const fixture = @import("retained_fixture.zig");

fn draw(app: *ui.App, id: ui.core.handles.WindowId) !void {
    const before = app.coordinator.counters.frames_presented;
    try app.invalidateWindow(id);
    var attempts: usize = 0;
    while (app.coordinator.counters.frames_presented == before) : (attempts += 1) {
        if (attempts > 256) return error.FrameDidNotPresent;
        _ = try app.step(true);
    }
}

fn capture(app: *ui.App, id: ui.core.handles.WindowId) !ui.render.Readback {
    const window = app.windows.get(id).?.*;
    return (try app.renderOffscreen(.{
        .width = try window.drawableWidth(),
        .height = try window.drawableHeight(),
        .scale_factor = window.scale_factor,
        .format = .rgba8_srgb,
    }, window.committedScene().view(), std.testing.allocator)) orelse error.ReadbackUnavailable;
}

test "Metal pixels match with retained layout and component scenes enabled" {
    const app = try ui.App.create(std.testing.allocator, .{ .application_name = "ZigUI retained frame equivalence" });
    defer app.destroy() catch unreachable;
    var model: fixture.Model = .{};
    const window = try app.openWindow(.{ .platform = .{ .title = "Retained frame verification", .size = .{ .width = 420, .height = 220 } } }, ui.Component.Descriptor.from(fixture.Model, &model));
    for (0..6) |iteration| {
        model.panels[0].value = @intCast(iteration);
        model.panels[1].wide = iteration % 2 != 0;
        model.panels[2].scroll = @floatFromInt(iteration * 4);
        model.panels[3].portal = iteration == 4;
        model.custom_value = @intCast(iteration * 20);
        app.app_config.retain_frame_work = false;
        try draw(app, window);
        var full = try capture(app, window);
        defer full.deinit(std.testing.allocator);
        app.app_config.retain_frame_work = true;
        for (0..4) |_| try draw(app, window);
        var retained = try capture(app, window);
        defer retained.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(full.pixels, retained.pixels);
    }
    try std.testing.expect(app.coordinator.counters.retained_scene_hits > 0);
}
