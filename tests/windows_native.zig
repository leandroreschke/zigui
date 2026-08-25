const std = @import("std");
const testing = std.testing;
const ui = @import("zigui");

const Model = struct {
    pub fn build(_: *Model, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        return .{
            .kind = .{ .text = "Native Windows validation" },
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 16 },
                        .right = .{ .points = 16 },
                        .bottom = .{ .points = 16 },
                        .left = .{ .points = 16 },
                    },
                },
                .text = .{ .font_size = 18, .color = ui.Color.white },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(20, 23, 31, 255) } },
            },
            .semantics = .{ .role = .static_text, .label = "Native Windows validation" },
        };
    }
};

test "real Win32 D3D11 window presents and closes cleanly" {
    var model: Model = .{};
    const app = try ui.App.create(testing.allocator, .{ .application_name = "ZigUI Windows native test" });
    defer app.destroy() catch unreachable;
    const window = try app.openWindow(.{
        .platform = .{ .title = "ZigUI Windows native test", .size = .{ .width = 320, .height = 200 } },
        .clear_color = ui.Color.rgba8(20, 23, 31, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    const secondary = try app.openWindow(.{
        .platform = .{
            .title = "ZigUI Windows secondary test",
            .size = .{ .width = 280, .height = 180 },
            .position = .{ .x = 80, .y = 80 },
        },
        .clear_color = ui.Color.rgba8(20, 23, 31, 255),
    }, ui.Component.Descriptor.from(Model, &model));

    var attempts: usize = 0;
    while ((try app.metricsSnapshot()).frames_submitted < 2 and attempts < 256) : (attempts += 1) {
        _ = try app.step(false);
        std.Thread.yield() catch {};
    }
    try testing.expect((try app.metricsSnapshot()).frames_submitted >= 2);

    var displays = try app.displays(testing.allocator);
    defer displays.deinit();
    try testing.expect(displays.values.len > 0);
    try testing.expect(displays.values[0].scale_factor.value > 0);

    try app.writeClipboardText("ZigUI native clipboard validation");
    const clipboard = (try app.readClipboardText(testing.allocator)).?;
    defer testing.allocator.free(clipboard);
    try testing.expectEqualStrings("ZigUI native clipboard validation", clipboard);

    try app.setWindowTitle(secondary, "ZigUI Windows secondary revised");
    try app.moveWindow(secondary, .{ .x = 120, .y = 120 });
    try app.resizeWindow(secondary, .{ .width = 360, .height = 240 });
    try app.setWindowMode(secondary, .minimized);
    try app.setWindowMode(secondary, .normal);
    try app.setWindowVisible(secondary, false);
    try app.setWindowVisible(secondary, true);
    try app.closeWindow(secondary);
    try testing.expect(!(try app.hasWindow(secondary)));

    try app.closeWindow(window);
    try testing.expect(!(try app.step(false)));
}
