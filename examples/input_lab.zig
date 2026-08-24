const std = @import("std");
const ui = @import("zigui");

const Model = struct {
    allocator: std.mem.Allocator,
    command_action: ui.core.handles.ActionId,
    enabled: bool = true,
    slider_value: f64 = 0.42,
    selected: usize = 0,
    dialog_open: bool = false,
    field: ui.widgets.TextField,
    select: ui.widgets.Select,
    toggle: ui.widgets.Toggle = undefined,
    slider: ui.widgets.Slider = undefined,
    open_button: ui.widgets.Button = undefined,
    close_button: ui.widgets.Button = undefined,
    tooltip: ui.widgets.Tooltip = .{ .content = .{}, .text = "Opens a modal portal (Command/Ctrl-K)" },
    dialog: ui.widgets.Dialog = undefined,

    fn init(allocator: std.mem.Allocator, command_action: ui.core.handles.ActionId) ui.Error!Model {
        var field = try ui.widgets.TextField.init(allocator, "ZigUI input");
        errdefer field.deinit();
        var select = try ui.widgets.Select.init(allocator, &.{ "macOS", "Windows", "Linux" }, undefined);
        errdefer select.deinit();
        var result: Model = .{
            .allocator = allocator,
            .command_action = command_action,
            .field = field,
            .select = select,
        };
        result.select.selected_index = &result.selected;
        result.select.label = "Target platform";
        result.field.label = "Editable text";
        result.field.placeholder = "Type with IME…";
        result.toggle = .{ .label = "Enable live controls", .value = &result.enabled, .kind = .switch_control };
        result.slider = .{ .value = &result.slider_value, .minimum = 0, .maximum = 100, .step = 1 };
        result.open_button = .{
            .label = "Open command dialog",
            .variant = .primary,
            .on_activate = ui.widgets.Callback.from(Model, &result, "openDialog"),
        };
        result.close_button = .{
            .label = "Close",
            .on_activate = ui.widgets.Callback.from(Model, &result, "closeDialog"),
        };
        result.dialog = .{ .open = &result.dialog_open, .title = "Portal, focus, and dismissal", .content = .{} };
        return result;
    }

    fn repairPointers(self: *Model) void {
        self.select.selected_index = &self.selected;
        self.toggle.value = &self.enabled;
        self.slider.value = &self.slider_value;
        self.open_button.on_activate = ui.widgets.Callback.from(Model, self, "openDialog");
        self.close_button.on_activate = ui.widgets.Callback.from(Model, self, "closeDialog");
        self.dialog.open = &self.dialog_open;
    }

    fn deinit(self: *Model) void {
        self.field.deinit();
        self.select.deinit();
        self.* = undefined;
    }

    pub fn openDialog(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        self.dialog_open = true;
        try ctx.invalidate(.{});
    }

    pub fn closeDialog(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        self.dialog_open = false;
        try ctx.invalidate(.{});
    }

    fn command(
        context: *anyopaque,
        dispatch: *ui.actions.Dispatch,
        _: ui.actions.ActionEvent,
        ctx: *ui.input.Context,
    ) ui.Error!void {
        const self: *Model = @ptrCast(@alignCast(context));
        self.dialog_open = true;
        dispatch.handled = true;
        try ctx.invalidate(.{});
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.field.disabled = !self.enabled;
        self.select.disabled = !self.enabled;
        self.slider.disabled = !self.enabled;
        const field_spec = try self.field.build(ctx);
        const select_spec = try self.select.build(ctx);
        const toggle_spec = try self.toggle.build(ctx);
        const slider_spec = try self.slider.build(ctx);
        self.tooltip.content = try self.open_button.build(ctx);
        const tooltip_spec = try self.tooltip.build(ctx);

        const dialog_text = try ctx.allocator.dupe(ui.NodeSpec, &.{ui.NodeSpec{
            .kind = .{ .text = "This panel is viewport-rooted, paints above clipped content, traps focus, and restores focus when it closes." },
            .style = .{ .text = .{ .font_size = 14, .color = ui.Color.rgba8(207, 214, 230, 255) } },
        }});
        self.dialog.content = .{ .kind = .container, .children = dialog_text };
        self.dialog.footer = try self.close_button.build(ctx);
        const dialog_spec = try self.dialog.build(ctx);

        var slider_buffer: [64]u8 = undefined;
        const slider_label = std.fmt.bufPrint(&slider_buffer, "Value: {d:.0}", .{self.slider_value}) catch return error.BudgetExceeded;
        const controls = try ctx.allocator.alloc(ui.NodeSpec, 8);
        controls[0] = .{
            .kind = .{ .text = "Input and overlay laboratory" },
            .style = .{ .text = .{ .font_size = 28, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "Input and overlay laboratory" },
        };
        controls[1] = field_spec;
        controls[2] = select_spec;
        controls[3] = toggle_spec;
        controls[4] = slider_spec;
        controls[5] = .{
            .kind = .{ .text = try ctx.allocator.dupe(u8, slider_label) },
            .style = .{ .text = .{ .font_size = 13, .color = ui.Color.rgba8(145, 157, 184, 255) } },
        };
        controls[6] = tooltip_spec;
        controls[7] = dialog_spec;
        const action_handlers = try ctx.allocator.dupe(ui.actions.Handler, &.{.{
            .action = self.command_action,
            .callback_context = self,
            .callback = command,
        }});
        return .{
            .kind = .{ .scroll = .{ .vertical = true } },
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 36 },
                        .right = .{ .points = 36 },
                        .bottom = .{ .points = 36 },
                        .left = .{ .points = 36 },
                    },
                    .gap = .{ .height = 18 },
                    .align_items = .stretch,
                    .overflow_y = .scroll,
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(18, 21, 29, 255) } },
            },
            .action_handlers = action_handlers,
            .children = controls,
        };
    }
};

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const app = try ui.App.create(allocator, .{ .application_name = "ZigUI Input Lab" });
    const command_action = try app.registerAction("input-lab.open-command-dialog");
    try app.bindAction(.{ .key = .{ .character = 'k' }, .modifiers = .{ .command = true } }, command_action, ui.actions.global_context, 10);
    try app.bindAction(.{ .key = .{ .character = 'k' }, .modifiers = .{ .control = true } }, command_action, ui.actions.global_context, 10);
    var model = try Model.init(allocator, command_action);
    model.repairPointers();
    defer {
        app.destroy() catch {};
        model.deinit();
    }
    _ = try app.openWindow(.{
        .platform = .{ .title = "Input Lab", .size = .{ .width = 760, .height = 680 } },
        .clear_color = ui.Color.rgba8(18, 21, 29, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    try app.run();
}
