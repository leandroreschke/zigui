const std = @import("std");
const ui = @import("zigui");

const measured_frames: u64 = 10_000;
const warmup_frames: u64 = 64;
const retained_children: usize = 256;

const Model = struct {
    component: ui.core.handles.ComponentId = .invalid,
    generation: u64 = 0,

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.component = ctx.component;
        const children = try ctx.allocator.alloc(ui.NodeSpec, retained_children + 1);
        children[0] = .{
            .key = 1,
            .kind = .spacer,
            .style = .{
                .layout = .{ .width = .{ .percent = 1 }, .height = .{ .points = 24 } },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(42, 53, 77, 255) } },
            },
            .semantics = .{ .role = .heading, .label = "ZigUI deterministic frame stress" },
        };
        for (children[1..], 0..) |*child, index| {
            const pulse: usize = @intCast((self.generation +% @as(u64, @intCast(index))) % 96);
            child.* = .{
                .key = 0x5354_5245_5353_0000 +% @as(u64, @intCast(index)),
                .kind = .spacer,
                .style = .{
                    .layout = .{
                        .width = .{ .points = 12 },
                        .height = .{ .points = 12 },
                    },
                    .paint = .{ .background = .{ .solid = ui.Color.rgba8(
                        @intCast(64 + (index *% 29 + pulse) % 176),
                        @intCast(72 + (index *% 43 + pulse) % 168),
                        @intCast(88 + (index *% 61 + pulse) % 152),
                        255,
                    ) } },
                },
            };
        }
        return .{
            .kind = .container,
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
                    .gap = .{ .width = 2, .height = 2 },
                    .direction = .row,
                    .wrap = .wrap,
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(12, 16, 24, 255) } },
            },
            .children = children,
        };
    }
};

pub fn main() !void {
    var debug = std.heap.DebugAllocator(.{}){};
    runStress(debug.allocator()) catch |err| {
        _ = debug.deinit();
        return err;
    };
    if (debug.deinit() != .ok) return error.LeakDetected;
}

fn runStress(backing: std.mem.Allocator) !void {
    var allocation_counters: ui.core.metrics.Counters = .{};
    var tracked = ui.core.TrackedAllocator.init(backing, &allocation_counters, null);
    const allocator = tracked.allocator();

    const app = try ui.App.create(allocator, .{
        .application_name = "ZigUI deterministic stress check",
        .allow_multiple_apps_for_testing = true,
    });
    var app_owned = true;
    errdefer if (app_owned) app.destroy() catch {};

    var model: Model = .{};
    const window = try app.openWindow(.{
        .platform = .{
            .title = "ZigUI stress check",
            .size = .{ .width = 800, .height = 600 },
        },
        .clear_color = ui.Color.rgba8(12, 16, 24, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    try drain(app);
    if (!model.component.isValid()) return error.ComponentWasNotBuilt;

    var warmup: u64 = 0;
    while (warmup < warmup_frames) : (warmup += 1) {
        model.generation +%= 1;
        try app.invalidateComponent(model.component, .{});
        try expectOneFrame(app);
    }

    const runtime_before = try app.metricsSnapshot();
    const allocator_before = tracked.snapshot();
    var frame_index: u64 = 0;
    while (frame_index < measured_frames) : (frame_index += 1) {
        if (frame_index % 2 == 0) {
            model.generation +%= 1;
            try app.invalidateComponent(model.component, .{});
        } else {
            try app.invalidateWindow(window);
        }
        try expectOneFrame(app);
    }
    try drain(app);

    const runtime_after = try app.metricsSnapshot();
    const allocator_after = tracked.snapshot();
    std.debug.print(
        "stress sample: live {d}->{d}, peak {d}, allocations {d}->{d}, allocated {d}->{d}\n",
        .{
            allocator_before.live_bytes,
            allocator_after.live_bytes,
            allocator_after.peak_live_bytes,
            allocator_before.allocations,
            allocator_after.allocations,
            allocator_before.allocated_bytes,
            allocator_after.allocated_bytes,
        },
    );
    if (runtime_after.frames_built -| runtime_before.frames_built != measured_frames or
        runtime_after.frames_submitted -| runtime_before.frames_submitted != measured_frames or
        runtime_after.frames_presented -| runtime_before.frames_presented != measured_frames)
        return error.UnexpectedFrameCount;
    if (allocator_after.live_bytes != allocator_before.live_bytes)
        return error.LiveHeapGrowth;
    if (allocator_after.allocations != allocator_before.allocations or
        allocator_after.allocated_bytes != allocator_before.allocated_bytes)
        return error.FrameHeapAllocation;

    const stable_live_bytes = allocator_after.live_bytes;
    const peak_live_bytes = allocator_after.peak_live_bytes;
    const total_primitives = runtime_after.scene_primitives -| runtime_before.scene_primitives;
    try app.destroy();
    app_owned = false;
    const allocator_final = tracked.snapshot();
    if (allocator_final.live_bytes != 0) return error.LiveBytesAfterTeardown;

    std.debug.print(
        "stress: {d} frames, {d} primitives, {d} stable live bytes, {d} peak bytes, zero post-warm-up allocations\n",
        .{ measured_frames, total_primitives, stable_live_bytes, peak_live_bytes },
    );
}

fn expectOneFrame(app: *ui.App) !void {
    const before = (try app.metricsSnapshot()).frames_submitted;
    var steps: usize = 0;
    while ((try app.metricsSnapshot()).frames_submitted == before) {
        if (steps >= 8 or !try app.step(false)) return error.FrameDidNotAdvance;
        steps += 1;
    }
    const after = (try app.metricsSnapshot()).frames_submitted;
    if (after != before + 1) return error.ExtraFrameSubmitted;
}

fn drain(app: *ui.App) !void {
    var steps: usize = 0;
    while (try app.step(false)) {
        steps += 1;
        if (steps > 64) return error.EventQueueDidNotDrain;
    }
}
