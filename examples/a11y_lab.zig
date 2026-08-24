const std = @import("std");
const ui = @import("zigui");

const chart_labels = [_][]const u8{ "Build", "Layout", "Paint", "GPU", "Present" };
const chart_actions = [_]ui.accessibility.Action{ .increment, .decrement, .set_value };

const AccessibleChart = struct {
    values: [5]f64 = .{ 42, 68, 54, 88, 73 },
    semantic_ids: [5]ui.core.handles.SemanticId = @splat(.invalid),
    value_buffers: [5][32]u8 = @splat(@splat(0)),
    value_lengths: [5]usize = @splat(0),
    selected: usize = 0,

    pub fn measure(_: *AccessibleChart, _: *ui.custom.MeasureContext, constraints: ui.layout.Constraints) ui.Error!ui.Size {
        return constraints.constrain(.{ .width = 560, .height = 250 });
    }

    pub fn paint(self: *AccessibleChart, ctx: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        try ctx.quad(.{
            .bounds = bounds,
            .background = ui.Color.rgba8(20, 26, 38, 255),
            .border_color = ui.Color.rgba8(58, 70, 94, 255),
            .border_widths = ui.Insets.all(1),
            .radii = ui.CornerRadii.all(12),
        });
        const inner = bounds.inset(ui.Insets.symmetric(20, 24));
        const slot = inner.size.width / chart_labels.len;
        for (self.values, 0..) |value, index| {
            const height = inner.size.height * @as(f32, @floatCast(value / 100));
            const bar = ui.Rect.fromXYWH(
                inner.origin.x + @as(f32, @floatFromInt(index)) * slot + slot * 0.2,
                inner.maxY() - height,
                slot * 0.6,
                height,
            );
            try ctx.quad(.{
                .bounds = bar,
                .background = if (index == self.selected) ui.Color.rgba8(112, 103, 255, 255) else ui.Color.rgba8(67, 177, 219, 255),
                .border_color = if (index == self.selected) ui.Color.white else ui.Color.transparent,
                .border_widths = ui.Insets.all(if (index == self.selected) 2 else 0),
                .radii = .{ .top_left = 7, .top_right = 7 },
            });
            if (ctx.text) |_| try ctx.paintText(chart_labels[index], .{
                .font_size = 12,
                .color = ui.Color.rgba8(202, 212, 232, 255),
            }, ui.Rect.fromXYWH(inner.origin.x + @as(f32, @floatFromInt(index)) * slot, inner.maxY() + 5, slot, 20));
        }
    }

    pub fn semantics(self: *AccessibleChart, writer: *ui.custom.SemanticsWriter, bounds: ui.Rect) ui.Error!void {
        const inner = bounds.inset(ui.Insets.symmetric(20, 24));
        const slot = inner.size.width / chart_labels.len;
        for (self.values, 0..) |value, index| {
            const text = std.fmt.bufPrint(&self.value_buffers[index], "{d:.0}%", .{value}) catch "";
            self.value_lengths[index] = text.len;
            self.semantic_ids[index] = try writer.append(index + 1, .{
                .role = .slider,
                .label = chart_labels[index],
                .description = "Pipeline timing contribution",
                .value = self.value_buffers[index][0..self.value_lengths[index]],
                .bounds = ui.Rect.fromXYWH(
                    inner.origin.x + @as(f32, @floatFromInt(index)) * slot,
                    inner.origin.y,
                    slot,
                    inner.size.height,
                ),
                .actions = &chart_actions,
                .range_min = 0,
                .range_max = 100,
                .range_value = value,
                .selected = index == self.selected,
            });
        }
    }

    pub fn event(self: *AccessibleChart, dispatch: *ui.input.Dispatch, event_value: *const ui.input.Event, ctx: *ui.input.Context) ui.Error!void {
        switch (event_value.*) {
            .pointer_down => |pointer| if (pointer.button == .primary and ctx.contains(pointer.position)) {
                const local = ctx.localPoint(pointer.position);
                const fraction = std.math.clamp(
                    (local.x - ctx.current_layout_bounds.origin.x) / @max(ctx.current_layout_bounds.size.width, 1),
                    0,
                    0.99999,
                );
                self.selected = @min(chart_labels.len - 1, @as(usize, @intFromFloat(fraction * chart_labels.len)));
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
                try ctx.invalidate(.{ .layout = false, .resources = false });
            },
            .key_down => |key| switch (key.key) {
                .arrow_left => try self.selectOffset(-1, dispatch, ctx),
                .arrow_right => try self.selectOffset(1, dispatch, ctx),
                .arrow_up => try self.adjust(self.selected, 5, dispatch, ctx),
                .arrow_down => try self.adjust(self.selected, -5, dispatch, ctx),
                else => {},
            },
            .accessibility => |request| {
                const index = self.semanticIndex(request.target) orelse return;
                self.selected = index;
                switch (request.action) {
                    .increment => try self.adjust(index, 5, dispatch, ctx),
                    .decrement => try self.adjust(index, -5, dispatch, ctx),
                    .set_value => if (request.value) |text| try self.set(index, std.fmt.parseFloat(f64, text) catch return, dispatch, ctx),
                    else => {},
                }
            },
            else => {},
        }
    }

    fn semanticIndex(self: *const AccessibleChart, target: ui.core.handles.SemanticId) ?usize {
        for (self.semantic_ids, 0..) |id, index| if (id.eql(target)) return index;
        return null;
    }

    fn selectOffset(self: *AccessibleChart, offset: i32, dispatch: *ui.input.Dispatch, ctx: *ui.input.Context) ui.Error!void {
        const current: i32 = @intCast(self.selected);
        self.selected = @intCast(std.math.clamp(current + offset, 0, @as(i32, chart_labels.len - 1)));
        dispatch.handled = true;
        dispatch.preventDefault();
        try ctx.invalidate(.{ .layout = false, .resources = false });
    }

    fn adjust(self: *AccessibleChart, index: usize, delta: f64, dispatch: *ui.input.Dispatch, ctx: *ui.input.Context) ui.Error!void {
        try self.set(index, self.values[index] + delta, dispatch, ctx);
    }

    fn set(self: *AccessibleChart, index: usize, value: f64, dispatch: *ui.input.Dispatch, ctx: *ui.input.Context) ui.Error!void {
        self.values[index] = std.math.clamp(value, 0, 100);
        dispatch.handled = true;
        dispatch.preventDefault();
        try ctx.invalidate(.{ .layout = false, .resources = false });
    }
};

const Model = struct {
    chart: AccessibleChart = .{},
    enabled: bool = true,
    selected_radio: usize = 0,
    slider_value: f64 = 70,
    field: ui.widgets.TextField,
    toggle: ui.widgets.Toggle = undefined,
    slider: ui.widgets.Slider = undefined,
    radios: [3]ui.widgets.Radio = undefined,

    fn init(allocator: std.mem.Allocator) ui.Error!Model {
        var field = try ui.widgets.TextField.init(allocator, "Screen readers receive selection and editable text geometry.");
        field.label = "Accessible editor";
        var result: Model = .{ .field = field };
        result.repairPointers();
        return result;
    }

    fn repairPointers(self: *Model) void {
        self.toggle = .{ .label = "Enable pipeline", .value = &self.enabled, .kind = .checkbox };
        self.slider = .{ .value = &self.slider_value, .minimum = 0, .maximum = 100, .step = 5 };
        self.radios = .{
            .{ .label = "Balanced", .selected_index = &self.selected_radio, .index = 0 },
            .{ .label = "Latency", .selected_index = &self.selected_radio, .index = 1 },
            .{ .label = "Efficiency", .selected_index = &self.selected_radio, .index = 2 },
        };
    }

    fn deinit(self: *Model) void {
        self.field.deinit();
        self.* = undefined;
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const controls = try ctx.allocator.alloc(ui.NodeSpec, 7);
        controls[0] = .{
            .kind = .{ .text = "Accessibility semantics laboratory" },
            .style = .{ .text = .{ .font_size = 27, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "Accessibility semantics laboratory" },
        };
        controls[1] = .{
            .kind = .{ .text = "Navigate with Tab and arrow keys, or inspect with VoiceOver, UI Automation, or AT-SPI." },
            .style = .{ .text = .{ .font_size = 14, .color = ui.Color.rgba8(175, 189, 215, 255) } },
        };
        controls[2] = try self.toggle.build(ctx);
        const radio_specs = try ctx.allocator.alloc(ui.NodeSpec, self.radios.len);
        for (&self.radios, 0..) |*radio, index| radio_specs[index] = try radio.build(ctx);
        controls[3] = .{
            .kind = .container,
            .style = .{ .layout = .{ .direction = .row, .gap = .{ .width = 14 } } },
            .semantics = .{ .role = .group, .label = "Performance preference" },
            .children = radio_specs,
        };
        controls[4] = try self.slider.build(ctx);
        controls[4].semantics.label = "Performance target";
        controls[5] = try self.field.build(ctx);
        controls[6] = .{
            .kind = .{ .custom = ui.custom.Node.from(AccessibleChart, &self.chart) },
            .style = .{
                .layout = .{ .width = .{ .percent = 1 }, .height = .{ .points = 250 } },
                .interaction = .{ .focusable = true, .cursor = .pointer },
            },
            .semantics = .{
                .role = .canvas,
                .label = "Frame pipeline chart",
                .description = "Five individually adjustable accessible bars",
            },
        };
        return .{
            .kind = .{ .scroll = .{ .vertical = true } },
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 30 },
                        .right = .{ .points = 34 },
                        .bottom = .{ .points = 40 },
                        .left = .{ .points = 34 },
                    },
                    .gap = .{ .height = 17 },
                    .overflow_y = .scroll,
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(13, 17, 25, 255) } },
            },
            .children = controls,
        };
    }
};

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    var model = try Model.init(allocator);
    model.repairPointers();
    const app = try ui.App.create(allocator, .{ .application_name = "ZigUI Accessibility Lab" });
    defer {
        app.destroy() catch {};
        model.deinit();
    }
    _ = try app.openWindow(.{
        .platform = .{ .title = "Accessibility Lab", .size = .{ .width = 820, .height = 780 } },
        .clear_color = ui.Color.rgba8(13, 17, 25, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    try app.run();
}
