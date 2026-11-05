const std = @import("std");
const ui = @import("zigui");
const retained_test_font = @embedFile("retained_test_font");

const native_benchmark = ui.config.compiled_platform == .macos and ui.config.compiled_renderer == .metal;

// Keep these values large enough to make retained work visible, but small
// enough that `zig build retained-bench -Doptimize=ReleaseFast` remains useful
// during local development and on CI hosts.
const panel_count: usize = 32;
const labels_per_panel: usize = 32;
const warmup_frames: usize = 16;
const measured_frames: usize = if (native_benchmark) 32 else 64;
const trial_count: usize = 3;
const sample_capacity: usize = measured_frames * trial_count;

const Scenario = enum {
    idle_requests,
    one_panel,
    text_change,
    all_panels,
    paint_animation,
    scroll,
    resize,
};

const scenarios = [_]Scenario{
    .idle_requests,
    .one_panel,
    .text_change,
    .all_panels,
    .paint_animation,
    .scroll,
    .resize,
};

const modes = [_]bool{ false, true };

const label_texts = [_][]const u8{
    "label 00", "label 01", "label 02", "label 03", "label 04", "label 05", "label 06", "label 07",
    "label 08", "label 09", "label 10", "label 11", "label 12", "label 13", "label 14", "label 15",
    "label 16", "label 17", "label 18", "label 19", "label 20", "label 21", "label 22", "label 23",
    "label 24", "label 25", "label 26", "label 27", "label 28", "label 29", "label 30", "label 31",
};

const wide_label_texts = [_][]const u8{
    "label 00 with variable width", "label 01 with variable width", "label 02 with variable width", "label 03 with variable width",
    "label 04 with variable width", "label 05 with variable width", "label 06 with variable width", "label 07 with variable width",
    "label 08 with variable width", "label 09 with variable width", "label 10 with variable width", "label 11 with variable width",
    "label 12 with variable width", "label 13 with variable width", "label 14 with variable width", "label 15 with variable width",
    "label 16 with variable width", "label 17 with variable width", "label 18 with variable width", "label 19 with variable width",
    "label 20 with variable width", "label 21 with variable width", "label 22 with variable width", "label 23 with variable width",
    "label 24 with variable width", "label 25 with variable width", "label 26 with variable width", "label 27 with variable width",
    "label 28 with variable width", "label 29 with variable width", "label 30 with variable width", "label 31 with variable width",
};

const Panel = struct {
    index: usize,
    generation: u64 = 0,
    layout_generation: u64 = 0,
    text_variant: bool = false,
    scroll_offset: f32 = 0,
    component: ui.core.handles.ComponentId = .invalid,

    pub fn build(self: *Panel, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const children = try ctx.allocator.alloc(ui.NodeSpec, labels_per_panel + 1);
        children[0] = .{
            .key = 1,
            .kind = .{ .text = "panel" },
            .style = .{ .text = .{
                .font_size = 12,
                .font_weight = .semibold,
                .color = ui.Color.rgba8(220, 227, 241, 255),
            } },
            .semantics = .{ .role = .heading, .label = "Panel" },
        };
        for (children[1..], 0..) |*child, label_index| {
            const color_shift: u8 = @intCast((self.generation +% @as(u64, @intCast(label_index * 7))) % 28);
            const label_text = if (self.text_variant) wide_label_texts[label_index] else label_texts[label_index];
            child.* = .{
                .key = 0x4c_4142_4500_0000 +% @as(u64, @intCast(label_index)),
                .kind = .{ .text = label_text },
                .style = .{
                    .layout = .{ .width = .{ .percent = 1 }, .height = .{ .points = 14 } },
                    .text = .{
                        .font_size = 10,
                        .color = ui.Color.rgba8(
                            @intCast(150 + color_shift),
                            @intCast(166 + (color_shift / 2)),
                            204,
                            255,
                        ),
                    },
                },
                .semantics = .{ .role = .static_text, .label = label_text },
            };
        }

        const panel_color = ui.Color.rgba8(
            @intCast(20 + ((self.index * 17 + @as(usize, @intCast(self.generation))) % 24)),
            @intCast(28 + ((self.index * 11 + @as(usize, @intCast(self.generation *% 3))) % 28)),
            @intCast(44 + ((self.index * 7 + @as(usize, @intCast(self.generation *% 5))) % 32)),
            255,
        );
        const panel_width: f32 = if (self.layout_generation % 2 == 0) 250 else 258;
        const panel_height: f32 = if (self.layout_generation % 2 == 0) 182 else 188;
        return .{
            .key = 0x5041_4e45_4c00_0000 +% @as(u64, @intCast(self.index)),
            .kind = .{ .scroll = .{
                .vertical = true,
                .offset_y = self.scroll_offset,
            } },
            .style = .{
                .layout = .{
                    .width = .{ .points = panel_width },
                    .height = .{ .points = panel_height },
                    .padding = .{ .top = .{ .points = 7 }, .right = .{ .points = 7 }, .bottom = .{ .points = 7 }, .left = .{ .points = 7 } },
                    .gap = .{ .height = 2 },
                    .overflow_y = .scroll,
                },
                .paint = .{
                    .background = .{ .solid = panel_color },
                    .border = .{ .widths = ui.Insets.all(1), .color = ui.Color.rgba8(59, 74, 103, 255) },
                    .radii = ui.CornerRadii.all(5),
                },
            },
            .semantics = .{ .role = .group, .label = "Independent panel" },
            .children = children,
        };
    }
};

const AnimationMark = struct {
    tick: *const u64,

    pub fn measure(_: *AnimationMark, _: *ui.custom.MeasureContext, constraints: ui.layout.Constraints) ui.Error!ui.Size {
        return constraints.constrain(.{});
    }

    pub fn paint(self: *AnimationMark, ctx: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        if (bounds.isEmpty()) return;
        const phase = self.tick.* % 240;
        const x = @min(@as(f32, @floatFromInt(phase)), @max(0, bounds.size.width - 8));
        const y = @min(@as(f32, @floatFromInt((self.tick.* / 3) % 120)), @max(0, bounds.size.height - 8));
        try ctx.quad(.{
            .bounds = ui.Rect.fromXYWH(bounds.origin.x + x, bounds.origin.y + y, 8, 8),
            .background = ui.Color.rgba8(245, 188, 83, 255),
            .border_color = ui.Color.transparent,
            .border_widths = .{},
            .radii = ui.CornerRadii.all(2),
        });
    }
};

const Model = struct {
    component: ui.core.handles.ComponentId = .invalid,
    panels: [panel_count]Panel = undefined,
    animation_tick: u64 = 0,
    animation_enabled: bool = false,
    animation_mark: AnimationMark = undefined,

    fn init() Model {
        var result: Model = .{};
        for (&result.panels, 0..) |*panel, index| panel.* = .{ .index = index };
        return result;
    }

    fn repairPointers(self: *Model) void {
        self.animation_mark = .{ .tick = &self.animation_tick };
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.component = ctx.component;
        const children = try ctx.allocator.alloc(ui.NodeSpec, panel_count + 1);
        for (children[0..panel_count], 0..) |*child, index| {
            child.* = try ctx.childComponent(
                &self.panels[index].component,
                ui.Component.Descriptor.from(Panel, &self.panels[index]),
            );
            child.key = 0x434f_4d50_0000_0000 +% @as(u64, @intCast(index));
        }
        children[panel_count] = .{
            .key = 0x414e_494d_4154_4500,
            .kind = .{ .custom = ui.custom.Node.from(AnimationMark, &self.animation_mark) },
            .style = .{
                .layout = .{
                    .position = .absolute,
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .inset = .{ .top = .{ .points = 0 }, .right = .{ .points = 0 }, .bottom = .{ .points = 0 }, .left = .{ .points = 0 } },
                },
                .interaction = .{ .pointer_events = .none },
            },
        };
        return .{
            .key = 0x524f_4f54_0000_0000,
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 12 },
                        .right = .{ .points = 12 },
                        .bottom = .{ .points = 12 },
                        .left = .{ .points = 12 },
                    },
                    .gap = .{ .width = 8, .height = 8 },
                    .direction = .row,
                    .wrap = .wrap,
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(11, 15, 24, 255) } },
            },
            .children = children,
        };
    }

    pub fn frame(self: *Model, _: u64) ui.Error!ui.Component.FrameUpdate {
        if (!self.animation_enabled) return .{};
        self.animation_tick +%= 1;
        return .{
            .dirty = .{
                .compose = false,
                .layout = false,
                .paint = true,
                .hit_test = false,
                .semantics = false,
                .resources = false,
            },
            .request_next_frame = true,
        };
    }

    fn bumpPanel(self: *Model, index: usize) void {
        self.panels[index].generation +%= 1;
    }

    fn bumpPanelText(self: *Model, index: usize) void {
        self.panels[index].text_variant = !self.panels[index].text_variant;
        self.bumpPanel(index);
    }

    fn bumpAll(self: *Model) void {
        for (&self.panels) |*panel| panel.generation +%= 1;
    }

    fn bumpAllLayout(self: *Model) void {
        for (&self.panels) |*panel| panel.layout_generation +%= 1;
    }
};

const FrameRecord = struct {
    elapsed_ns: u64,
    cpu_ns: u64,
    allocated_bytes: u64,
    allocation_count: u64,
    live_bytes: u64,
    scene_operations: u64,
    scene_primitives: u64,
};

const ScenarioStats = struct {
    frames: [sample_capacity]FrameRecord = undefined,
    sample_count: usize = 0,
    submitted: u64 = 0,
    built: u64 = 0,
    presented: u64 = 0,
    retained_hits: u64 = 0,
    retained_misses: u64 = 0,
    retained_budget_skips: u64 = 0,
    idle_submitted: u64 = 0,
    idle_step_ns: [sample_capacity]u64 = undefined,
    idle_sample_count: usize = 0,
    peak_live_bytes: u64 = 0,
    start_live_bytes: ?u64 = null,
    end_live_bytes: ?u64 = null,

    fn appendFrame(
        self: *ScenarioStats,
        elapsed_ns: u64,
        cpu_ns: u64,
        before: ui.core.metrics.Counters,
        after: ui.core.metrics.Counters,
        allocator_before: ui.core.metrics.Counters,
        allocator_after: ui.core.metrics.Counters,
    ) !void {
        if (self.sample_count >= self.frames.len) return error.BenchmarkSampleOverflow;
        self.frames[self.sample_count] = .{
            .elapsed_ns = elapsed_ns,
            .cpu_ns = cpu_ns,
            .allocated_bytes = allocator_after.allocated_bytes -| allocator_before.allocated_bytes,
            .allocation_count = allocator_after.allocations -| allocator_before.allocations,
            .live_bytes = allocator_after.live_bytes,
            .scene_operations = after.scene_operations -| before.scene_operations,
            .scene_primitives = after.scene_primitives -| before.scene_primitives,
        };
        self.sample_count += 1;
        self.submitted +|= after.frames_submitted -| before.frames_submitted;
        self.built +|= after.frames_built -| before.frames_built;
        self.presented +|= after.frames_presented -| before.frames_presented;
        self.retained_hits +|= after.retained_scene_hits -| before.retained_scene_hits;
        self.retained_misses +|= after.retained_scene_misses -| before.retained_scene_misses;
        self.retained_budget_skips +|= after.retained_scene_budget_skips -| before.retained_scene_budget_skips;
        self.peak_live_bytes = @max(self.peak_live_bytes, allocator_after.peak_live_bytes);
        if (self.start_live_bytes == null) self.start_live_bytes = allocator_before.live_bytes;
        self.end_live_bytes = allocator_after.live_bytes;
    }

    fn appendIdle(self: *ScenarioStats, elapsed_ns: u64, submitted: u64) !void {
        if (self.idle_sample_count >= self.idle_step_ns.len) return error.BenchmarkSampleOverflow;
        self.idle_step_ns[self.idle_sample_count] = elapsed_ns;
        self.idle_sample_count += 1;
        self.idle_submitted +|= submitted;
    }
};

const ResultTable = [scenarios.len][modes.len]ScenarioStats;

pub fn main(init: std.process.Init) !void {
    var debug = std.heap.DebugAllocator(.{}){};
    runBenchmark(debug.allocator(), init.io) catch |err| {
        _ = debug.deinit();
        return err;
    };
    if (debug.deinit() != .ok) return error.LeakDetected;
}

fn runBenchmark(backing: std.mem.Allocator, io: std.Io) !void {
    var results: ResultTable = undefined;
    for (&results) |*scenario_results| {
        for (scenario_results) |*mode_result| mode_result.* = .{};
    }

    std.debug.print(
        "retained benchmark: {d} panels x {d} labels, {d} warmup, {d} measured, {d} alternating trials\n",
        .{ panel_count, labels_per_panel, warmup_frames, measured_frames, trial_count },
    );

    var trial: usize = 0;
    while (trial < trial_count) : (trial += 1) {
        const first_mode: usize = trial % modes.len;
        try runMode(backing, io, modes[first_mode], &results, trial);
        try runMode(backing, io, modes[first_mode ^ 1], &results, trial);
        if (native_benchmark) {
            std.debug.print("native comparison after trial {d}:\n", .{trial + 1});
            for (scenarios, 0..) |scenario, index|
                printComparison(scenario, &results[index][0], &results[index][1]);
        }
    }

    for (scenarios, 0..) |scenario, scenario_index| {
        const baseline = &results[scenario_index][0];
        const retained = &results[scenario_index][1];
        printComparison(scenario, baseline, retained);
        if (scenario == .idle_requests) {
            if (baseline.idle_submitted != 0 or retained.idle_submitted != 0)
                return error.IdleRequestRenderedFrame;
        } else if (baseline.submitted != measured_frames * trial_count or
            retained.submitted != measured_frames * trial_count or
            baseline.built != baseline.submitted or retained.built != retained.submitted or
            baseline.presented != baseline.submitted or retained.presented != retained.submitted)
        {
            return error.UnexpectedFrameCount;
        }
        if (scenario == .one_panel or scenario == .text_change or scenario == .paint_animation or scenario == .scroll) {
            if (retained.retained_hits == 0) return error.RetentionCacheNotUsed;
        }
    }
}

fn runMode(
    backing: std.mem.Allocator,
    io: std.Io,
    retain_frame_work: bool,
    results: *ResultTable,
    trial: usize,
) !void {
    var allocation_counters: ui.core.metrics.Counters = .{};
    var tracked = ui.core.TrackedAllocator.init(backing, &allocation_counters, null);
    const allocator = tracked.allocator();
    const app_config: ui.config.AppConfig = .{
        .application_name = "ZigUI retained rendering benchmark",
        .allow_multiple_apps_for_testing = !native_benchmark,
        .retain_frame_work = retain_frame_work,
    };
    const app = try createBenchmarkApp(allocator, app_config);
    var app_owned = true;
    errdefer if (app_owned) app.destroy() catch {};

    var model = Model.init();
    model.repairPointers();
    const window = try app.openWindow(.{
        .platform = .{
            .title = "ZigUI retained rendering benchmark",
            .size = .{ .width = 1100, .height = 800 },
        },
        .clear_color = ui.Color.rgba8(11, 15, 24, 255),
    }, ui.Component.Descriptor.fromWithFrame(Model, &model));
    try drain(app);
    // A native window may not receive its first display callback during a
    // nonblocking event drain, especially after reopening the application.
    if (!model.panels[0].component.isValid()) try expectOneFrame(app, io);
    if (!model.panels[0].component.isValid()) return error.ComponentWasNotBuilt;

    var warmup: usize = 0;
    while (warmup < warmup_frames) : (warmup += 1) {
        model.bumpAll();
        for (model.panels) |panel| try app.invalidateComponent(panel.component, .{});
        expectOneFrame(app, io) catch |err| {
            std.debug.print("warmup {d}, retained={any}: {s}\n", .{ warmup, retain_frame_work, @errorName(err) });
            return err;
        };
    }
    try drain(app);

    for (scenarios, 0..) |scenario, scenario_index| {
        if (native_benchmark) std.debug.print("  trial {d}, retained={any}, {s}\n", .{ trial + 1, retain_frame_work, @tagName(scenario) });
        model.animation_enabled = scenario == .paint_animation;
        if (scenario == .paint_animation) {
            try app.invalidateComponent(model.component, .{
                .compose = false,
                .layout = false,
                .paint = true,
                .hit_test = false,
                .semantics = false,
                .resources = false,
            });
        }
        try runScenario(app, io, window, &model, scenario, &results[scenario_index][if (retain_frame_work) 1 else 0], &tracked);
        model.animation_enabled = false;
        try drain(app);
    }

    try app.destroy();
    app_owned = false;
    if (tracked.snapshot().live_bytes != 0) return error.LiveBytesAfterTeardown;
}

fn runScenario(
    app: *ui.App,
    io: std.Io,
    window: ui.core.handles.WindowId,
    model: *Model,
    scenario: Scenario,
    stats: *ScenarioStats,
    tracked: *ui.core.TrackedAllocator,
) !void {
    const scenario_before = try app.metricsSnapshot();
    const allocator_before = tracked.snapshot();
    var frame_index: usize = 0;
    while (frame_index < measured_frames) : (frame_index += 1) {
        if (scenario == .idle_requests) {
            const started = std.Io.Clock.awake.now(io);
            try app.requestFrame(window);
            const before = try app.metricsSnapshot();
            var steps: usize = 0;
            while (app.windows.get(window).?.*.pending_frame) : (steps += 1) {
                if (steps >= 5000) return error.IdleFrameCallbackTimedOut;
                const progressed = try app.step(false);
                if ((try app.metricsSnapshot()).frames_submitted != before.frames_submitted) break;
                if (!progressed and native_benchmark) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
            const elapsed = started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
            const after = try app.metricsSnapshot();
            try stats.appendIdle(@intCast(@max(0, elapsed)), after.frames_submitted -| before.frames_submitted);
            continue;
        }

        switch (scenario) {
            .one_panel => {
                const index = frame_index % panel_count;
                model.bumpPanel(index);
                try app.invalidateComponent(model.panels[index].component, .{});
            },
            .text_change => {
                const index = frame_index % panel_count;
                model.bumpPanelText(index);
                try app.invalidateComponent(model.panels[index].component, .{});
            },
            .all_panels => {
                model.bumpAll();
                model.bumpAllLayout();
                for (model.panels) |panel| try app.invalidateComponent(panel.component, .{});
            },
            .paint_animation => {},
            .scroll => {
                model.panels[0].scroll_offset = @floatFromInt((frame_index * 5) % 240);
                try app.invalidateComponent(model.panels[0].component, .{});
            },
            .resize => {
                const width: f32 = if (frame_index % 2 == 0) 980 else 1100;
                const height: f32 = if (frame_index % 2 == 0) 720 else 800;
                try app.resizeWindow(window, .{ .width = width, .height = height });
            },
            .idle_requests => unreachable,
        }

        const runtime_before = try app.metricsSnapshot();
        const tracked_before = tracked.snapshot();
        const started = std.Io.Clock.awake.now(io);
        expectOneFrame(app, io) catch |err| {
            std.debug.print("scenario {s}, frame {d}, retained={any}: {s}\n", .{ @tagName(scenario), frame_index, app.app_config.retain_frame_work, @errorName(err) });
            return err;
        };
        const elapsed = started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        const runtime_after = try app.metricsSnapshot();
        const tracked_after = tracked.snapshot();
        try stats.appendFrame(
            @intCast(@max(0, elapsed)),
            phaseCpuNs(runtime_before, runtime_after),
            runtime_before,
            runtime_after,
            tracked_before,
            tracked_after,
        );
    }

    const scenario_after = try app.metricsSnapshot();
    const allocator_after = tracked.snapshot();
    if (scenario == .idle_requests) {
        if (scenario_after.frames_submitted != scenario_before.frames_submitted or
            allocator_after.live_bytes != allocator_before.live_bytes)
            return error.IdleRequestChangedState;
    }
}

fn createBenchmarkApp(allocator: std.mem.Allocator, app_config: ui.config.AppConfig) !*ui.App {
    if (native_benchmark) return ui.App.create(allocator, app_config);

    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        allocator,
        app_config.memory.loaded_font_bytes,
        app_config.memory.mapped_font_bytes,
        app_config.memory.font_instance_count,
        app_config.memory.font_catalog_count,
        app_config.memory.font_catalog_bytes,
    );
    var text_backend_owned = true;
    errdefer if (text_backend_owned) text_backend_instance.interface().deinit();
    _ = try text_backend_instance.registerCopy(retained_test_font, 0, .regular, .normal);
    var harness = try ui.HeadlessPlatform.createWithMemory(allocator, text_backend_instance.interface(), app_config.memory);
    const bundle = harness.bundle;
    harness.bundle = undefined;
    text_backend_owned = false;
    return ui.App.createWithBundle(allocator, app_config, bundle);
}

fn phaseCpuNs(before: ui.core.metrics.Counters, after: ui.core.metrics.Counters) u64 {
    var total: u64 = 0;
    inline for (.{
        .drain,
        .dispatch,
        .update,
        .compose,
        .measure,
        .arrange,
        .prepare,
        .scene,
        .encode,
        .submit,
    }) |phase| {
        const before_count = @field(before.phase_counts, @tagName(phase));
        const after_count = @field(after.phase_counts, @tagName(phase));
        total +|= after_count.total_ns -| before_count.total_ns;
    }
    return total;
}

fn expectOneFrame(app: *ui.App, io: std.Io) !void {
    const before = (try app.metricsSnapshot()).frames_submitted;
    var steps: usize = 0;
    while ((try app.metricsSnapshot()).frames_submitted == before) {
        if (steps >= (if (native_benchmark) @as(usize, 5000) else 32)) return error.FrameDidNotAdvance;
        const progressed = try app.step(false);
        if (!progressed) {
            if (!native_benchmark) return error.FrameDidNotAdvance;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        steps += 1;
    }
    const after = (try app.metricsSnapshot()).frames_submitted;
    if (after != before + 1) return error.ExtraFrameSubmitted;
}

fn drain(app: *ui.App) !void {
    var steps: usize = 0;
    while (try app.step(false)) {
        steps += 1;
        if (steps > 128) return error.EventQueueDidNotDrain;
    }
}

fn printComparison(scenario: Scenario, baseline: *const ScenarioStats, retained: *const ScenarioStats) void {
    if (scenario == .idle_requests) {
        std.debug.print(
            "  {s}: idle step p50/p95 {d}/{d} us, submitted {d}/{d}\n",
            .{
                @tagName(scenario),
                percentile(baseline.idle_step_ns[0..], baseline.idle_sample_count, 50) / std.time.ns_per_us,
                percentile(baseline.idle_step_ns[0..], baseline.idle_sample_count, 95) / std.time.ns_per_us,
                baseline.idle_submitted,
                retained.idle_submitted,
            },
        );
        return;
    }

    const baseline_p50 = percentileFrameTime(baseline, 50);
    const retained_p50 = percentileFrameTime(retained, 50);
    const baseline_p95 = percentileFrameTime(baseline, 95);
    const retained_p95 = percentileFrameTime(retained, 95);
    const baseline_cpu_p50 = percentileCpuTime(baseline, 50);
    const retained_cpu_p50 = percentileCpuTime(retained, 50);
    const baseline_cpu_p95 = percentileCpuTime(baseline, 95);
    const retained_cpu_p95 = percentileCpuTime(retained, 95);
    const baseline_alloc = sumAllocatedBytes(baseline);
    const retained_alloc = sumAllocatedBytes(retained);
    const baseline_allocation_count = sumAllocationCount(baseline);
    const retained_allocation_count = sumAllocationCount(retained);
    const baseline_scene = sumSceneOperations(baseline);
    const retained_scene = sumSceneOperations(retained);
    std.debug.print(
        "  {s}: phase-cpu p50/p95 {d}/{d} -> {d}/{d} us ({d:.2}x/{d:.2}x), " ++
            "wall p50/p95 {d}/{d} -> {d}/{d} us ({d:.2}x/{d:.2}x), " ++
            "scene ops {d} -> {d}, cache hits/misses/skips {d}/{d}/{d}, alloc calls/bytes {d}/{d} -> {d}/{d}, " ++
            "live {d} -> {d}, peak {d}/{d}, frames {d}/{d}\n",
        .{
            @tagName(scenario),
            baseline_cpu_p50 / std.time.ns_per_us,
            baseline_cpu_p95 / std.time.ns_per_us,
            retained_cpu_p50 / std.time.ns_per_us,
            retained_cpu_p95 / std.time.ns_per_us,
            ratio(baseline_cpu_p50, retained_cpu_p50),
            ratio(baseline_cpu_p95, retained_cpu_p95),
            baseline_p50 / std.time.ns_per_us,
            baseline_p95 / std.time.ns_per_us,
            retained_p50 / std.time.ns_per_us,
            retained_p95 / std.time.ns_per_us,
            ratio(baseline_p50, retained_p50),
            ratio(baseline_p95, retained_p95),
            baseline_scene,
            retained_scene,
            retained.retained_hits,
            retained.retained_misses,
            retained.retained_budget_skips,
            baseline_allocation_count,
            baseline_alloc,
            retained_allocation_count,
            retained_alloc,
            baseline.end_live_bytes orelse 0,
            retained.end_live_bytes orelse 0,
            baseline.peak_live_bytes,
            retained.peak_live_bytes,
            baseline.submitted,
            retained.submitted,
        },
    );
}

fn percentileFrameTime(stats: *const ScenarioStats, percentile_value: usize) u64 {
    var values: [sample_capacity]u64 = undefined;
    for (stats.frames[0..stats.sample_count], 0..) |frame, index| values[index] = frame.elapsed_ns;
    return percentile(values[0..], stats.sample_count, percentile_value);
}

fn percentileCpuTime(stats: *const ScenarioStats, percentile_value: usize) u64 {
    var values: [sample_capacity]u64 = undefined;
    for (stats.frames[0..stats.sample_count], 0..) |frame, index| values[index] = frame.cpu_ns;
    return percentile(values[0..], stats.sample_count, percentile_value);
}

fn percentile(values: []const u64, count: usize, percentile_value: usize) u64 {
    if (count == 0) return 0;
    var sorted: [sample_capacity]u64 = undefined;
    @memcpy(sorted[0..count], values[0..count]);
    std.mem.sort(u64, sorted[0..count], {}, std.sort.asc(u64));
    const rank = (count * percentile_value + 99) / 100;
    return sorted[@max(@as(usize, 1), rank) - 1];
}

fn sumAllocatedBytes(stats: *const ScenarioStats) u64 {
    var total: u64 = 0;
    for (stats.frames[0..stats.sample_count]) |frame| total +|= frame.allocated_bytes;
    return total;
}

fn sumAllocationCount(stats: *const ScenarioStats) u64 {
    var total: u64 = 0;
    for (stats.frames[0..stats.sample_count]) |frame| total +|= frame.allocation_count;
    return total;
}

fn sumSceneOperations(stats: *const ScenarioStats) u64 {
    var total: u64 = 0;
    for (stats.frames[0..stats.sample_count]) |frame| total +|= frame.scene_operations;
    return total;
}

fn ratio(baseline: u64, retained: u64) f64 {
    if (baseline == 0) return 0;
    return @as(f64, @floatFromInt(retained)) / @as(f64, @floatFromInt(baseline));
}
