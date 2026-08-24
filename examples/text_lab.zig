const std = @import("std");
const ui = @import("zigui");

const Model = struct {
    editor: ui.widgets.TextField,

    fn init(allocator: std.mem.Allocator) ui.Error!Model {
        var editor = try ui.widgets.TextField.init(allocator, "Latin + العربية + עברית\nदेवनागरी বাংলা ไทย\n日本語 한국어 中文\nEmoji: 👩🏽‍💻 🏳️‍🌈 🧑‍🚀");
        editor.label = "Multilingual editor";
        editor.multiline = true;
        editor.maximum_bytes = 4 * 1024 * 1024;
        editor.font_size = 17;
        return .{ .editor = editor };
    }

    fn deinit(self: *Model) void {
        self.editor.deinit();
        self.* = undefined;
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        var editor = try self.editor.build(ctx);
        editor.style.layout.height = .{ .points = 210 };
        const rows = try ctx.allocator.alloc(ui.NodeSpec, 9);
        rows[0] = .{
            .kind = .{ .text = "Unicode, shaping, and color fonts" },
            .style = .{ .text = .{ .font_size = 28, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "Unicode, shaping, and color fonts" },
        };
        rows[1] = .{
            .kind = .{ .text = "Ligatures: office affine ffi fl — kerning: AVATAR Typography" },
            .style = .{ .text = .{ .font_size = 20, .color = ui.Color.rgba8(222, 228, 241, 255) } },
        };
        rows[2] = .{
            .kind = .{ .text = "العَرَبِيَّةُ لغةٌ جميلة — مرحبًا بالعالم" },
            .style = .{ .text = .{ .font_size = 23, .direction = .right_to_left, .color = ui.Color.rgba8(117, 220, 184, 255) } },
        };
        rows[3] = .{
            .kind = .{ .text = "עברית בתוך English 123, with bidi punctuation!" },
            .style = .{ .text = .{ .font_size = 20, .direction = .auto, .color = ui.Color.rgba8(130, 183, 255, 255) } },
        };
        rows[4] = .{
            .kind = .{ .text = "नमस्ते दुनिया · বাংলা লিপি · สวัสดีชาวโลก" },
            .style = .{ .text = .{ .font_size = 21, .color = ui.Color.rgba8(255, 190, 105, 255) } },
        };
        rows[5] = .{
            .kind = .{ .text = "日本語の文字組み　한국어 조판　简体中文与繁體中文" },
            .style = .{ .text = .{ .font_size = 21, .color = ui.Color.rgba8(241, 153, 200, 255) } },
        };
        rows[6] = .{
            .kind = .{ .text = "Color and joined emoji: 😀 👩🏽‍💻 👨‍👩‍👧‍👦 🏳️‍🌈 ❤️‍🔥" },
            .style = .{ .text = .{ .font_size = 24, .color = ui.Color.white } },
        };
        rows[7] = ui.widgets.separator(.horizontal, &ui.widgets.Theme.dark);
        rows[8] = editor;
        return .{
            .kind = .{ .scroll = .{ .vertical = true } },
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 32 },
                        .right = .{ .points = 36 },
                        .bottom = .{ .points = 40 },
                        .left = .{ .points = 36 },
                    },
                    .gap = .{ .height = 18 },
                    .overflow_y = .scroll,
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(16, 19, 27, 255) } },
            },
            .children = rows,
        };
    }
};

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    var model = try Model.init(allocator);
    const app = try ui.App.create(allocator, .{ .application_name = "ZigUI Text Lab" });
    defer {
        app.destroy() catch {};
        model.deinit();
    }
    _ = try app.openWindow(.{
        .platform = .{ .title = "Text Lab", .size = .{ .width = 920, .height = 760 } },
        .clear_color = ui.Color.rgba8(16, 19, 27, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    try app.run();
}
