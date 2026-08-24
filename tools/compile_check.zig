const std = @import("std");
const ui = @import("zigui");

const Model = struct {
    pub fn build(_: *Model, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        return .{};
    }
};

/// Build-only consumer root. Real calls force the selected platform factory,
/// window vtables, renderer, App lifecycle, and public component contract
/// through semantic analysis without executing the resulting artifact.
pub fn main() !void {
    _ = ui.App.create;
    _ = ui.App.openWindow;
    _ = ui.LayoutEngine.layout;
    _ = ui.InputRouter.dispatch;
    _ = ui.custom.Node;
    _ = ui.widgets.TextField.build;
    _ = ui.widgets.ScrollView.build;
    _ = ui.render.Renderer.submit;
    _ = ui.scene.Builder.finish;
    _ = ui.platform.Bundle.deinit;

    var model: Model = .{};
    const app = try ui.App.create(std.heap.page_allocator, .{ .application_name = "ZigUI compile check" });
    defer app.destroy() catch {};
    _ = try app.openWindow(.{ .platform = .{ .title = "ZigUI compile check" } }, ui.Component.Descriptor.from(Model, &model));
}
