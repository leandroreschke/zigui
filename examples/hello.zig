const std = @import("std");
const ui = @import("zigui");

const Model = struct {
    clicks: usize = 0,
    enabled: bool = true,
    button: ui.widgets.Button = undefined,
    toggle: ui.widgets.Toggle = undefined,

    fn init(self: *Model) void {
        self.button = .{
            .label = "Count",
            .variant = .primary,
            .on_activate = ui.widgets.Callback.from(Model, self, "count"),
        };
        self.toggle = .{
            .label = "GPU-driven interface",
            .value = &self.enabled,
            .kind = .switch_control,
        };
    }

    pub fn count(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        self.clicks +|= 1;
        try ctx.invalidate(.{});
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        var count_buffer: [96]u8 = undefined;
        const count_label = std.fmt.bufPrint(&count_buffer, "Activated {d} time{s}", .{
            self.clicks,
            if (self.clicks == 1) "" else "s",
        }) catch return error.BudgetExceeded;
        const children = try ctx.allocator.alloc(ui.NodeSpec, 5);
        children[0] = .{
            .kind = .{ .text = "Hello from ZigUI" },
            .style = .{ .text = .{ .font_size = 30, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "Hello from ZigUI" },
        };
        children[1] = .{
            .kind = .{ .text = "A retained, GPU-rendered desktop UI with no third-party dependencies." },
            .style = .{ .text = .{ .font_size = 15, .color = ui.Color.rgba8(180, 188, 205, 255) } },
        };
        children[2] = try self.toggle.build(ctx);
        children[3] = try self.button.build(ctx);
        children[4] = .{
            .kind = .{ .text = try ctx.allocator.dupe(u8, count_label) },
            .style = .{ .text = .{ .font_size = 13, .color = ui.Color.rgba8(139, 151, 176, 255) } },
            .semantics = .{ .role = .static_text, .label = try ctx.allocator.dupe(u8, count_label) },
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 44 },
                        .right = .{ .points = 44 },
                        .bottom = .{ .points = 44 },
                        .left = .{ .points = 44 },
                    },
                    .gap = .{ .height = 18 },
                    .align_items = .start,
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(20, 23, 31, 255) } },
            },
            .children = children,
        };
    }
};

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    const allocator = general.allocator();

    var model: Model = .{};
    model.init();
    const app = try ui.App.create(allocator, .{ .application_name = "ZigUI Hello" });
    defer app.destroy() catch {};
    _ = try app.openWindow(.{
        .platform = .{ .title = "ZigUI Hello", .size = .{ .width = 640, .height = 420 } },
        .clear_color = ui.Color.rgba8(20, 23, 31, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    try app.run();
}
