const std = @import("std");
const ui = @import("zigui");

const SpatialCanvas = struct {
    pan: ui.Point = .{ .x = 28, .y = 28 },
    zoom: f32 = 1,
    dragging: bool = false,
    previous: ui.Point = .{},
    visible_objects: usize = 0,

    pub fn measure(_: *SpatialCanvas, _: *ui.custom.MeasureContext, constraints: ui.layout.Constraints) ui.Error!ui.Size {
        return constraints.constrain(constraints.maximum);
    }

    pub fn paint(self: *SpatialCanvas, ctx: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        try ctx.quad(.{
            .bounds = bounds,
            .background = ui.Color.rgba8(11, 15, 23, 255),
            .border_color = ui.Color.rgba8(48, 59, 78, 255),
            .border_widths = ui.Insets.all(1),
            .radii = ui.CornerRadii.all(10),
        });

        const cell: f32 = 72;
        const world_left = (bounds.minX() - bounds.minX() - self.pan.x) / self.zoom;
        const world_top = (bounds.minY() - bounds.minY() - self.pan.y) / self.zoom;
        const world_right = (bounds.size.width - self.pan.x) / self.zoom;
        const world_bottom = (bounds.size.height - self.pan.y) / self.zoom;
        const first_column: usize = @intFromFloat(std.math.clamp(@floor(world_left / cell), 0, 99));
        const first_row: usize = @intFromFloat(std.math.clamp(@floor(world_top / cell), 0, 99));
        const last_column: usize = @intFromFloat(std.math.clamp(@ceil(world_right / cell), 0, 99));
        const last_row: usize = @intFromFloat(std.math.clamp(@ceil(world_bottom / cell), 0, 99));

        try ctx.pushClip(bounds, ui.CornerRadii.all(10));
        var painted: usize = 0;
        var row = first_row;
        while (row <= last_row) : (row += 1) {
            var column = first_column;
            while (column <= last_column) : (column += 1) {
                const index = row * 100 + column;
                const x = bounds.origin.x + self.pan.x + @as(f32, @floatFromInt(column)) * cell * self.zoom;
                const y = bounds.origin.y + self.pan.y + @as(f32, @floatFromInt(row)) * cell * self.zoom;
                const size = @max(4, 13 * self.zoom);
                const red: u8 = @intCast(65 + (index * 29) % 150);
                const green: u8 = @intCast(80 + (index * 47) % 135);
                const blue: u8 = @intCast(100 + (index * 17) % 120);
                try ctx.quad(.{
                    .bounds = ui.Rect.fromXYWH(x, y, size, size),
                    .background = ui.Color.rgba8(red, green, blue, 255),
                    .border_color = ui.Color.rgba(1, 1, 1, 0.22),
                    .border_widths = ui.Insets.all(1),
                    .radii = ui.CornerRadii.all(size / 2),
                });
                painted += 1;
            }
        }
        try ctx.popClip();
        self.visible_objects = painted;

        if (ctx.text) |_| {
            var buffer: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&buffer, "{d} / 10,000 objects · {d:.0}%", .{ painted, self.zoom * 100 }) catch return error.BudgetExceeded;
            try ctx.paintText(label, .{
                .font_size = 13,
                .font_weight = .semibold,
                .color = ui.Color.rgba8(218, 226, 242, 255),
            }, bounds.inset(ui.Insets.all(14)));
        }
    }

    pub fn event(self: *SpatialCanvas, dispatch: *ui.input.Dispatch, event_value: *const ui.input.Event, ctx: *ui.input.Context) ui.Error!void {
        switch (event_value.*) {
            .pointer_down => |pointer| if (pointer.button == .primary) {
                self.dragging = true;
                self.previous = ctx.localPoint(pointer.position);
                dispatch.capturePointer(dispatch.current);
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
            },
            .pointer_move => |pointer| if (self.dragging) {
                const local = ctx.localPoint(pointer.position);
                self.pan = self.pan.add(local.sub(self.previous));
                self.previous = local;
                dispatch.handled = true;
                try ctx.invalidate(.{ .compose = false, .layout = false, .resources = false, .semantics = false });
            },
            .pointer_up, .pointer_cancel => if (self.dragging) {
                self.dragging = false;
                dispatch.releasePointer();
                dispatch.handled = true;
            },
            .scroll => |scroll| {
                if (scroll.modifiers.command or scroll.modifiers.control) {
                    const previous_zoom = self.zoom;
                    self.zoom = std.math.clamp(self.zoom * @exp(-scroll.delta.y * 0.0025), 0.2, 4);
                    const local = ctx.localPoint(scroll.position);
                    const anchor = local.sub(ctx.current_layout_bounds.origin);
                    const offset = anchor.sub(self.pan);
                    const ratio = self.zoom / previous_zoom;
                    self.pan = anchor.sub(.{ .x = offset.x * ratio, .y = offset.y * ratio });
                } else {
                    self.pan = self.pan.sub(scroll.delta);
                }
                dispatch.handled = true;
                dispatch.preventDefault();
                try ctx.invalidate(.{ .compose = false, .layout = false, .resources = false, .semantics = false });
            },
            .key_down => |key| switch (key.key) {
                .home => {
                    self.pan = .{ .x = 28, .y = 28 };
                    self.zoom = 1;
                    dispatch.handled = true;
                    try ctx.invalidate(.{ .compose = false, .layout = false, .resources = false, .semantics = false });
                },
                else => {},
            },
            else => {},
        }
    }
};

const Model = struct {
    heights: ui.widgets.HeightIndex,
    list: ui.widgets.VirtualList(Model) = undefined,
    canvas: SpatialCanvas = .{},
    split_fraction: f32 = 0.36,
    split: ui.widgets.SplitPane = undefined,

    fn init(allocator: std.mem.Allocator) ui.Error!Model {
        var result: Model = .{ .heights = try ui.widgets.HeightIndex.init(allocator, 10_000, 38) };
        result.repairPointers();
        return result;
    }

    fn repairPointers(self: *Model) void {
        self.list = .{
            .item_context = self,
            .build_item = buildItem,
            .heights = &self.heights,
            .overscan_pixels = 520,
        };
        self.split = .{
            .first = .{},
            .second = .{},
            .fraction = &self.split_fraction,
            .orientation = .horizontal,
            .minimum_first = 220,
            .minimum_second = 320,
        };
    }

    fn deinit(self: *Model) void {
        self.heights.deinit();
        self.* = undefined;
    }

    fn buildItem(_: *Model, index: usize, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        var buffer: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "Row {d:0>5} · stable key {x:0>6}", .{ index, index *% 0x9e37 }) catch return error.BudgetExceeded;
        const children = try ctx.allocator.dupe(ui.NodeSpec, &.{ui.NodeSpec{
            .kind = .{ .text = try ctx.allocator.dupe(u8, label) },
            .style = .{ .text = .{
                .font_size = 13,
                .color = if (index % 2 == 0) ui.Color.rgba8(213, 221, 238, 255) else ui.Color.rgba8(157, 174, 204, 255),
            } },
        }});
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{ .left = .{ .points = 14 }, .right = .{ .points = 14 } },
                    .justify_content = .center,
                },
                .paint = .{ .background = .{ .solid = if (index % 2 == 0) ui.Color.rgba8(22, 27, 38, 255) else ui.Color.rgba8(18, 23, 33, 255) } },
            },
            .semantics = .{ .role = .list_item, .label = try ctx.allocator.dupe(u8, label) },
            .children = children,
        };
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        var list_spec = try self.list.build(ctx);
        list_spec.style.paint.background = .{ .solid = ui.Color.rgba8(18, 23, 33, 255) };
        const canvas_spec: ui.NodeSpec = .{
            .kind = .{ .custom = ui.custom.Node.from(SpatialCanvas, &self.canvas) },
            .style = .{
                .layout = .{ .width = .{ .percent = 1 }, .height = .{ .percent = 1 } },
                .interaction = .{ .focusable = true, .cursor = if (self.canvas.dragging) .grabbing else .grab },
            },
            .semantics = .{ .role = .canvas, .label = "Virtualized 10,000 object spatial canvas" },
        };
        self.split.first = list_spec;
        self.split.second = canvas_spec;
        const split_spec = try self.split.build(ctx);
        const children = try ctx.allocator.alloc(ui.NodeSpec, 2);
        children[0] = .{
            .kind = .{ .text = "Visibility-proportional list and canvas" },
            .style = .{ .text = .{ .font_size = 24, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "Visibility-proportional list and canvas" },
        };
        children[1] = split_spec;
        children[1].style.layout.flex_grow = 1;
        children[1].style.layout.min_height = .{ .points = 0 };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 22 },
                        .right = .{ .points = 22 },
                        .bottom = .{ .points = 22 },
                        .left = .{ .points = 22 },
                    },
                    .gap = .{ .height = 16 },
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(13, 17, 25, 255) } },
            },
            .children = children,
        };
    }
};

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    var model = try Model.init(allocator);
    model.repairPointers();
    const app = try ui.App.create(allocator, .{ .application_name = "ZigUI List + Canvas Lab" });
    defer {
        app.destroy() catch {};
        model.deinit();
    }
    _ = try app.openWindow(.{
        .platform = .{ .title = "List + Canvas Lab", .size = .{ .width = 1180, .height = 760 } },
        .clear_color = ui.Color.rgba8(13, 17, 25, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    try app.run();
}
