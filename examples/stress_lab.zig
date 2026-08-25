const std = @import("std");
const ui = @import("zigui");

const retained_wall_nodes = 2_048;

const StressCanvas = struct {
    owner: *Model,

    pub fn measure(_: *StressCanvas, _: *ui.custom.MeasureContext, constraints: ui.layout.Constraints) ui.Error!ui.Size {
        return constraints.constrain(.{ .width = 900, .height = 500 });
    }

    pub fn paint(self: *StressCanvas, ctx: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        const model = self.owner;
        try ctx.quad(.{
            .bounds = bounds,
            .background = ui.Color.rgba8(9, 13, 21, 255),
            .border_color = ui.Color.rgba8(48, 62, 86, 255),
            .border_widths = ui.Insets.all(1),
            .radii = ui.CornerRadii.all(12),
        });
        const content = bounds.inset(ui.Insets.all(12));
        const object_count = @max(@as(usize, 1), model.object_count);
        const columns: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(object_count)))))));
        const rows = (object_count + columns - 1) / columns;
        const column_width = content.size.width / @as(f32, @floatFromInt(columns));
        const row_height = content.size.height / @as(f32, @floatFromInt(rows));
        const diameter = @max(1, @min(column_width, row_height) - 0.55);
        try ctx.pushClip(bounds, ui.CornerRadii.all(12));
        for (0..object_count) |index| {
            const column = index % columns;
            const row = index / columns;
            const wave = @sin(model.phase + @as(f32, @floatFromInt(index % 97)) * 0.071) * @min(1.4, diameter * 0.24);
            const red: u8 = @intCast(55 + (index *% 29) % 190);
            const green: u8 = @intCast(62 + (index *% 47) % 184);
            const blue: u8 = @intCast(72 + (index *% 71) % 176);
            try ctx.quad(.{
                .bounds = ui.Rect.fromXYWH(
                    content.origin.x + @as(f32, @floatFromInt(column)) * column_width,
                    content.origin.y + @as(f32, @floatFromInt(row)) * row_height + wave,
                    diameter,
                    diameter,
                ),
                .background = ui.Color.rgba8(red, green, blue, 230),
                .border_color = if (index % 257 == 0) ui.Color.white else .transparent,
                .border_widths = ui.Insets.all(if (index % 257 == 0) 0.75 else 0),
                .radii = ui.CornerRadii.all(@min(2.5, diameter * 0.35)),
            });
        }
        try ctx.popClip();

        const runtime = try model.app.metricsSnapshot();
        const allocations = model.allocation_tracker.snapshot();
        const frame_ms = @as(f64, @floatFromInt(model.last_frame_ns)) / 1_000_000.0;
        const submit_ms = @as(f64, @floatFromInt(runtime.timings.submit_ns)) / 1_000_000.0;
        const scene_ms = @as(f64, @floatFromInt(runtime.timings.scene_ns)) / 1_000_000.0;
        const layout_ms = @as(f64, @floatFromInt(runtime.timings.measure_ns +| runtime.timings.arrange_ns)) / 1_000_000.0;
        var metrics_buffer: [512]u8 = undefined;
        const metrics_text = std.fmt.bufPrint(
            &metrics_buffer,
            "{d} animated quads · frame {d:.2} ms · layout {d:.2} ms · scene {d:.2} ms · submit {d:.2} ms\nframes {d} · primitives {d} · allocator live {d} KiB · peak {d} KiB · allocations {d}",
            .{
                object_count,
                frame_ms,
                layout_ms,
                scene_ms,
                submit_ms,
                runtime.frames_submitted,
                runtime.scene_primitives,
                allocations.live_bytes / 1024,
                allocations.peak_live_bytes / 1024,
                allocations.allocations,
            },
        ) catch return error.BudgetExceeded;
        const overlay = ui.Rect.fromXYWH(bounds.origin.x + 18, bounds.origin.y + 18, @max(1, @min(760, bounds.size.width - 36)), 64);
        try ctx.quad(.{
            .bounds = overlay,
            .background = ui.Color.rgba(0.025, 0.04, 0.075, 0.90),
            .border_color = ui.Color.rgba8(78, 101, 139, 255),
            .border_widths = ui.Insets.all(1),
            .radii = ui.CornerRadii.all(9),
        });
        if (ctx.text) |_| try ctx.paintText(metrics_text, .{
            .font_size = 12,
            .font_weight = .medium,
            .color = ui.Color.rgba8(223, 232, 248, 255),
        }, overlay.inset(ui.Insets.all(10)));
    }

    pub fn event(self: *StressCanvas, dispatch: *ui.input.Dispatch, event_value: *const ui.input.Event, ctx: *ui.input.Context) ui.Error!void {
        switch (event_value.*) {
            .pointer_down => |pointer| if (pointer.button == .primary) {
                dispatch.requestFocus(dispatch.current);
                dispatch.handled = true;
            },
            .key_down => |key| switch (key.key) {
                .space => {
                    self.owner.running = !self.owner.running;
                    self.owner.updateButtonLabels();
                    dispatch.handled = true;
                    dispatch.preventDefault();
                    try ctx.invalidate(.{});
                },
                .arrow_up => {
                    self.owner.object_count = @min(@as(usize, 100_000), self.owner.object_count *| 2);
                    dispatch.handled = true;
                    try ctx.invalidate(.{});
                },
                .arrow_down => {
                    self.owner.object_count = @max(@as(usize, 256), self.owner.object_count / 2);
                    dispatch.handled = true;
                    try ctx.invalidate(.{});
                },
                else => {},
            },
            else => {},
        }
    }
};

const Model = struct {
    app: *ui.App,
    allocation_tracker: *ui.core.TrackedAllocator,
    component: ui.core.handles.ComponentId = .invalid,
    window: ui.core.handles.WindowId = .invalid,
    canvas: StressCanvas = undefined,
    object_count: usize = 10_000,
    phase: f32 = 0,
    last_frame_ns: u64 = 0,
    running: bool = true,
    recompose_every_frame: bool = false,
    run_button: ui.widgets.Button = undefined,
    low_button: ui.widgets.Button = undefined,
    medium_button: ui.widgets.Button = undefined,
    high_button: ui.widgets.Button = undefined,
    rebuild_button: ui.widgets.Button = undefined,

    fn init(app: *ui.App, allocation_tracker: *ui.core.TrackedAllocator) Model {
        return .{ .app = app, .allocation_tracker = allocation_tracker };
    }

    fn repairPointers(self: *Model) void {
        self.canvas = .{ .owner = self };
        self.run_button = .{
            .label = if (self.running) "Pause" else "Resume",
            .on_activate = ui.widgets.Callback.from(Model, self, "toggleRunning"),
            .variant = .primary,
        };
        self.low_button = .{ .label = "1,000", .on_activate = ui.widgets.Callback.from(Model, self, "setLow") };
        self.medium_button = .{ .label = "10,000", .on_activate = ui.widgets.Callback.from(Model, self, "setMedium") };
        self.high_button = .{ .label = "40,000", .on_activate = ui.widgets.Callback.from(Model, self, "setHigh") };
        self.rebuild_button = .{
            .label = if (self.recompose_every_frame) "Rebuild: on" else "Rebuild: off",
            .on_activate = ui.widgets.Callback.from(Model, self, "toggleRebuild"),
            .variant = if (self.recompose_every_frame) .destructive else .normal,
        };
    }

    fn updateButtonLabels(self: *Model) void {
        self.run_button.label = if (self.running) "Pause" else "Resume";
        self.rebuild_button.label = if (self.recompose_every_frame) "Rebuild: on" else "Rebuild: off";
        self.rebuild_button.variant = if (self.recompose_every_frame) .destructive else .normal;
    }

    pub fn toggleRunning(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        self.running = !self.running;
        self.updateButtonLabels();
        try ctx.invalidate(.{});
    }

    pub fn setLow(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.setCount(1_000, ctx);
    }
    pub fn setMedium(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.setCount(10_000, ctx);
    }
    pub fn setHigh(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        try self.setCount(40_000, ctx);
    }

    fn setCount(self: *Model, count: usize, ctx: *ui.input.Context) ui.Error!void {
        self.object_count = count;
        try ctx.invalidate(.{});
    }

    pub fn toggleRebuild(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        self.recompose_every_frame = !self.recompose_every_frame;
        self.updateButtonLabels();
        try ctx.invalidate(.{});
    }

    fn advance(self: *Model, now_ns: u64, previous_ns: *u64) void {
        var elapsed = now_ns -| previous_ns.*;
        previous_ns.* = now_ns;
        if (elapsed == 0 or elapsed > 100 * std.time.ns_per_ms) elapsed = 16_666_667;
        self.last_frame_ns = elapsed;
        self.phase += @as(f32, @floatFromInt(elapsed)) / @as(f32, std.time.ns_per_s) * 2.15;
        if (self.phase > std.math.tau) self.phase -= std.math.tau;
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.component = ctx.component;
        const wall = try ctx.allocator.alloc(ui.NodeSpec, retained_wall_nodes);
        const phase_color: usize = @intFromFloat((@sin(self.phase) * 0.5 + 0.5) * 127);
        for (wall, 0..) |*spec, index| {
            const animated = if (self.recompose_every_frame) phase_color else 0;
            spec.* = .{
                .key = 0x5354_5245_5353_0000 +% @as(u64, @intCast(index)),
                .kind = .spacer,
                .style = .{
                    .layout = .{ .width = .{ .points = 7 }, .height = .{ .points = 7 } },
                    .paint = .{ .background = .{ .solid = ui.Color.rgba8(
                        @intCast(45 + (index *% 31 + animated) % 180),
                        @intCast(55 + (index *% 47 + animated) % 170),
                        @intCast(75 + (index *% 67 + animated) % 160),
                        255,
                    ) } },
                },
            };
        }

        const buttons = try ctx.allocator.alloc(ui.NodeSpec, 5);
        buttons[0] = try self.run_button.build(ctx);
        buttons[1] = try self.low_button.build(ctx);
        buttons[2] = try self.medium_button.build(ctx);
        buttons[3] = try self.high_button.build(ctx);
        buttons[4] = try self.rebuild_button.build(ctx);
        const children = try ctx.allocator.alloc(ui.NodeSpec, 5);
        children[0] = .{
            .kind = .{ .text = "Retained-tree and GPU batch stress lab" },
            .style = .{ .text = .{ .font_size = 25, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "Retained-tree and GPU batch stress lab" },
        };
        children[1] = .{
            .kind = .{ .text = "Paint-only animation reuses 2,048 retained nodes. Rebuild mode deliberately recomposes that subtree every frame. Space pauses; Up and Down change GPU load." },
            .style = .{ .text = .{ .font_size = 13, .color = ui.Color.rgba8(165, 181, 210, 255) } },
        };
        children[2] = .{
            .kind = .container,
            .style = .{ .layout = .{ .direction = .row, .wrap = .wrap, .gap = .{ .width = 8, .height = 8 } } },
            .children = buttons,
        };
        children[3] = .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .direction = .row,
                    .wrap = .wrap,
                    .height = .{ .points = 72 },
                    .gap = .{ .width = 1, .height = 1 },
                    .overflow_x = .clip,
                    .overflow_y = .clip,
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(15, 21, 32, 255) } },
            },
            .semantics = .{ .role = .group, .label = "Two thousand forty-eight retained layout nodes" },
            .children = wall,
        };
        children[4] = .{
            .kind = .{ .custom = ui.custom.Node.from(StressCanvas, &self.canvas) },
            .style = .{
                .layout = .{ .width = .{ .percent = 1 }, .min_height = .{ .points = 320 }, .flex_grow = 1 },
                .interaction = .{ .focusable = true, .cursor = .crosshair },
            },
            .semantics = .{ .role = .canvas, .label = "Animated GPU quad stress surface" },
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 20 },
                        .right = .{ .points = 20 },
                        .bottom = .{ .points = 20 },
                        .left = .{ .points = 20 },
                    },
                    .gap = .{ .height = 12 },
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(12, 16, 24, 255) } },
            },
            .children = children,
        };
    }
};

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    var allocation_metrics: ui.core.metrics.Counters = .{};
    var tracked = ui.core.TrackedAllocator.init(general.allocator(), &allocation_metrics, null);
    const allocator = tracked.allocator();
    const app = try ui.App.create(allocator, .{
        .application_name = "ZigUI Stress Lab",
        // The proof deliberately combines a 2,048-node retained wall with
        // 10,000 paint-only quads in one frame. Keep that workload bounded,
        // but give its per-window scratch arena an explicit stress budget.
        .memory = .{ .frame_arena_bytes = 32 * 1024 * 1024 },
    });
    var model = Model.init(app, &tracked);
    model.repairPointers();
    defer app.destroy() catch {};
    const window = try app.openWindow(.{
        .platform = .{ .title = "Stress Lab", .size = .{ .width = 1200, .height = 820 } },
        .clear_color = ui.Color.rgba8(12, 16, 24, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    model.window = window;
    var previous_frame_count: u64 = 0;
    var previous_frame_time = try app.clockNow();
    while (try app.hasWindow(window)) {
        _ = try app.step(true);
        if (!try app.hasWindow(window)) break;
        const snapshot = try app.metricsSnapshot();
        if (snapshot.frames_submitted == previous_frame_count) continue;
        previous_frame_count = snapshot.frames_submitted;
        if (!model.running) continue;
        model.advance(try app.clockNow(), &previous_frame_time);
        if (model.recompose_every_frame and model.component.isValid())
            try app.invalidateComponent(model.component, .{})
        else
            try app.invalidateWindow(window);
    }
}
