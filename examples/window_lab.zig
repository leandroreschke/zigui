const std = @import("std");
const ui = @import("zigui");

const Secondary = struct {
    owner: *Model,

    pub fn build(self: *Secondary, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const children = try ctx.allocator.alloc(ui.NodeSpec, 4);
        children[0] = .{
            .kind = .{ .text = "Managed secondary window" },
            .style = .{ .text = .{ .font_size = 25, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "Managed secondary window" },
        };
        children[1] = .{
            .kind = .{ .text = "Move, resize, minimize, maximize, and fullscreen are native platform commands behind one typed ZigUI contract." },
            .style = .{ .text = .{ .font_size = 14, .color = ui.Color.rgba8(190, 201, 220, 255) } },
        };
        children[2] = .{
            .kind = .{ .text = try ctx.allocator.dupe(u8, self.owner.status()) },
            .style = .{
                .layout = .{ .padding = .{
                    .top = .{ .points = 12 },
                    .right = .{ .points = 12 },
                    .bottom = .{ .points = 12 },
                    .left = .{ .points = 12 },
                } },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(29, 36, 50, 255) }, .radii = ui.CornerRadii.all(8) },
                .text = .{ .font_size = 13, .color = ui.Color.rgba8(128, 218, 180, 255) },
            },
            .semantics = .{ .role = .static_text, .label = try ctx.allocator.dupe(u8, self.owner.status()) },
        };
        children[3] = .{
            .kind = .{ .text = self.owner.display_summary },
            .style = .{ .text = .{ .font_size = 13, .color = ui.Color.rgba8(144, 160, 190, 255) } },
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 30 },
                        .right = .{ .points = 30 },
                        .bottom = .{ .points = 30 },
                        .left = .{ .points = 30 },
                    },
                    .gap = .{ .height = 18 },
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(17, 21, 30, 255) } },
            },
            .children = children,
        };
    }
};

const Model = struct {
    allocator: std.mem.Allocator,
    app: *ui.App,
    main_window: ui.core.handles.WindowId = .invalid,
    secondary_window: ui.core.handles.WindowId = .invalid,
    display_summary: []u8,
    status_buffer: [320]u8 = @splat(0),
    status_length: usize = 0,
    title_revision: usize = 1,
    secondary: Secondary = undefined,
    title_button: ui.widgets.Button = undefined,
    move_button: ui.widgets.Button = undefined,
    resize_button: ui.widgets.Button = undefined,
    minimize_button: ui.widgets.Button = undefined,
    maximize_button: ui.widgets.Button = undefined,
    fullscreen_button: ui.widgets.Button = undefined,
    restore_button: ui.widgets.Button = undefined,
    hide_button: ui.widgets.Button = undefined,
    show_button: ui.widgets.Button = undefined,
    copy_button: ui.widgets.Button = undefined,
    paste_button: ui.widgets.Button = undefined,
    open_button: ui.widgets.Button = undefined,
    save_button: ui.widgets.Button = undefined,

    fn init(allocator: std.mem.Allocator, app: *ui.App) ui.Error!Model {
        var displays = try app.displays(allocator);
        defer displays.deinit();
        var summary: std.ArrayList(u8) = .empty;
        errdefer summary.deinit(allocator);
        try summary.print(allocator, "{d} display{s}: ", .{ displays.values.len, if (displays.values.len == 1) "" else "s" });
        for (displays.values, 0..) |display, index| {
            if (index != 0) try summary.appendSlice(allocator, " · ");
            try summary.print(allocator, "{s} {d:.0}×{d:.0} @{d:.2}x", .{
                display.name,
                display.bounds.size.width,
                display.bounds.size.height,
                display.scale_factor.value,
            });
        }
        var result: Model = .{
            .allocator = allocator,
            .app = app,
            .display_summary = try summary.toOwnedSlice(allocator),
        };
        result.setStatus("Both windows are active and independently retained.");
        result.repairPointers();
        return result;
    }

    fn repairPointers(self: *Model) void {
        self.secondary = .{ .owner = self };
        self.title_button = self.button("Change title", "changeTitle");
        self.move_button = self.button("Move", "moveSecondary");
        self.resize_button = self.button("Resize", "resizeSecondary");
        self.minimize_button = self.button("Minimize", "minimizeSecondary");
        self.maximize_button = self.button("Maximize", "maximizeSecondary");
        self.fullscreen_button = self.button("Fullscreen", "fullscreenSecondary");
        self.restore_button = self.button("Restore", "restoreSecondary");
        self.hide_button = self.button("Hide", "hideSecondary");
        self.show_button = self.button("Show", "showSecondary");
        self.copy_button = self.button("Copy status", "copyStatus");
        self.paste_button = self.button("Read clipboard", "readClipboard");
        self.open_button = self.button("Open files…", "openFiles");
        self.save_button = self.button("Save file…", "saveFile");
    }

    fn deinit(self: *Model) void {
        self.allocator.free(self.display_summary);
        self.* = undefined;
    }

    fn button(self: *Model, comptime label: []const u8, comptime method: []const u8) ui.widgets.Button {
        return .{ .label = label, .on_activate = ui.widgets.Callback.from(Model, self, method) };
    }

    fn status(self: *const Model) []const u8 {
        return self.status_buffer[0..self.status_length];
    }

    fn setStatus(self: *Model, value: []const u8) void {
        const length = @min(value.len, self.status_buffer.len);
        @memcpy(self.status_buffer[0..length], value[0..length]);
        self.status_length = length;
    }

    fn record(self: *Model, comptime success: []const u8, result: ui.Error!void, ctx: *ui.input.Context) ui.Error!void {
        result catch |err| {
            var buffer: [240]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buffer, "{s} is unavailable: {s}", .{ success, @errorName(err) }) catch "Window command failed");
            try self.invalidateBoth(ctx);
            return;
        };
        self.setStatus(success);
        try self.invalidateBoth(ctx);
    }

    fn invalidateBoth(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try ctx.invalidate(.{});
        if (self.secondary_window.isValid()) try self.app.invalidateWindow(self.secondary_window);
    }

    pub fn changeTitle(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        var buffer: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&buffer, "Secondary window · revision {d}", .{self.title_revision}) catch return;
        self.title_revision +|= 1;
        try self.record("Changed the native window title", self.app.setWindowTitle(self.secondary_window, title), ctx);
    }

    pub fn moveSecondary(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Moved the secondary window", self.app.moveWindow(self.secondary_window, .{ .x = 96, .y = 96 }), ctx);
    }

    pub fn resizeSecondary(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Resized content to 720 × 460 logical pixels", self.app.resizeWindow(self.secondary_window, .{ .width = 720, .height = 460 }), ctx);
    }

    pub fn minimizeSecondary(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Minimized the secondary window", self.app.setWindowMode(self.secondary_window, .minimized), ctx);
    }

    pub fn maximizeSecondary(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Maximized the secondary window", self.app.setWindowMode(self.secondary_window, .maximized), ctx);
    }

    pub fn fullscreenSecondary(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Entered native fullscreen", self.app.setWindowMode(self.secondary_window, .fullscreen), ctx);
    }

    pub fn restoreSecondary(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Restored normal window mode", self.app.setWindowMode(self.secondary_window, .normal), ctx);
    }

    pub fn hideSecondary(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Hid the secondary window", self.app.setWindowVisible(self.secondary_window, false), ctx);
    }

    pub fn showSecondary(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Showed the secondary window", self.app.setWindowVisible(self.secondary_window, true), ctx);
    }

    pub fn copyStatus(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.record("Copied the status through the native clipboard", self.app.writeClipboardText(self.status()), ctx);
    }

    pub fn readClipboard(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        const value = self.app.readClipboardText(self.allocator) catch |err| {
            try self.record("Read clipboard", err, ctx);
            return;
        };
        if (value) |text| {
            defer self.allocator.free(text);
            var buffer: [240]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buffer, "Clipboard: {s}", .{text[0..@min(text.len, 180)]}) catch "Clipboard text received");
        } else self.setStatus("Clipboard contains no text");
        try self.invalidateBoth(ctx);
    }

    pub fn openFiles(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        var paths = self.app.openFiles(self.main_window, true, self.allocator) catch |err| {
            try self.record("Open files", err, ctx);
            return;
        };
        defer paths.deinit();
        var buffer: [240]u8 = undefined;
        self.setStatus(std.fmt.bufPrint(&buffer, "Native open dialog returned {d} path{s}", .{ paths.values.len, if (paths.values.len == 1) "" else "s" }) catch "Open dialog completed");
        try self.invalidateBoth(ctx);
    }

    pub fn saveFile(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        var result = self.app.saveFile(self.main_window, "zigui-document.txt", self.allocator) catch |err| {
            try self.record("Save file", err, ctx);
            return;
        };
        if (result) |*path| {
            defer path.deinit();
            var buffer: [240]u8 = undefined;
            self.setStatus(std.fmt.bufPrint(&buffer, "Native save dialog selected: {s}", .{path.value[0..@min(path.value.len, 170)]}) catch "Save location selected");
        } else self.setStatus("Native save dialog was cancelled");
        try self.invalidateBoth(ctx);
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const buttons = [_]*ui.widgets.Button{
            &self.title_button,    &self.move_button,     &self.resize_button,
            &self.minimize_button, &self.maximize_button, &self.fullscreen_button,
            &self.restore_button,  &self.hide_button,     &self.show_button,
            &self.copy_button,     &self.paste_button,    &self.open_button,
            &self.save_button,
        };
        const controls = try ctx.allocator.alloc(ui.NodeSpec, buttons.len);
        for (buttons, 0..) |button_value, index| controls[index] = try button_value.build(ctx);
        const children = try ctx.allocator.alloc(ui.NodeSpec, 4);
        children[0] = .{
            .kind = .{ .text = "Native window and desktop laboratory" },
            .style = .{ .text = .{ .font_size = 27, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "Native window and desktop laboratory" },
        };
        children[1] = .{
            .kind = .{ .text = self.display_summary },
            .style = .{ .text = .{ .font_size = 13, .color = ui.Color.rgba8(143, 163, 199, 255) } },
        };
        children[2] = .{
            .kind = .container,
            .style = .{ .layout = .{ .direction = .row, .wrap = .wrap, .gap = .{ .width = 9, .height = 9 } } },
            .children = controls,
        };
        children[3] = .{
            .kind = .{ .text = try ctx.allocator.dupe(u8, self.status()) },
            .style = .{
                .layout = .{ .padding = .{
                    .top = .{ .points = 14 },
                    .right = .{ .points = 14 },
                    .bottom = .{ .points = 14 },
                    .left = .{ .points = 14 },
                } },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(27, 34, 48, 255) }, .radii = ui.CornerRadii.all(8) },
                .text = .{ .font_size = 13, .color = ui.Color.rgba8(126, 221, 181, 255) },
            },
            .semantics = .{ .role = .static_text, .label = try ctx.allocator.dupe(u8, self.status()) },
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 30 },
                        .right = .{ .points = 30 },
                        .bottom = .{ .points = 30 },
                        .left = .{ .points = 30 },
                    },
                    .gap = .{ .height = 18 },
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(14, 18, 26, 255) } },
            },
            .children = children,
        };
    }
};

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const app = try ui.App.create(allocator, .{ .application_name = "ZigUI Window Lab" });
    var model = try Model.init(allocator, app);
    model.repairPointers();
    defer {
        app.destroy() catch {};
        model.deinit();
    }
    model.main_window = try app.openWindow(.{
        .platform = .{ .title = "Window Lab controls", .size = .{ .width = 900, .height = 620 }, .position = .{ .x = 52, .y = 52 } },
        .clear_color = ui.Color.rgba8(14, 18, 26, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    model.secondary_window = try app.openWindow(.{
        .platform = .{ .title = "Managed secondary window", .size = .{ .width = 620, .height = 420 }, .position = .{ .x = 990, .y = 92 } },
        .clear_color = ui.Color.rgba8(17, 21, 30, 255),
    }, ui.Component.Descriptor.from(Secondary, &model.secondary));
    try app.run();
}
