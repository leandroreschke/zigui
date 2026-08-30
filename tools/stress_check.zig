const std = @import("std");
const builtin = @import("builtin");
const ui = @import("zigui");

const measured_frames: u64 = 10_000;
const warmup_frames: u64 = 64;
const retained_children: usize = 256;

const MachTimeValue = extern struct { seconds: i32, microseconds: i32 };
const MachTaskBasicInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    resident_size_max: u64,
    user_time: MachTimeValue,
    system_time: MachTimeValue,
    policy: i32,
    suspend_count: i32,
};
extern "c" var mach_task_self_: u32;
extern "c" fn task_info(target: u32, flavor: u32, info: *MachTaskBasicInfo, count: *u32) i32;

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

pub fn main(init: std.process.Init) !void {
    var debug = std.heap.DebugAllocator(.{}){};
    runStress(debug.allocator(), init.io) catch |err| {
        _ = debug.deinit();
        return err;
    };
    if (debug.deinit() != .ok) return error.LeakDetected;
}

fn runStress(backing: std.mem.Allocator, io: std.Io) !void {
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
    var frame_times_ns: [measured_frames]u64 = undefined;
    const resident_before = residentBytes();
    var resident_min = resident_before;
    var resident_max = resident_before;
    const total_started = std.Io.Clock.awake.now(io);
    var frame_index: u64 = 0;
    while (frame_index < measured_frames) : (frame_index += 1) {
        const frame_started = std.Io.Clock.awake.now(io);
        if (frame_index % 2 == 0) {
            model.generation +%= 1;
            try app.invalidateComponent(model.component, .{});
        } else {
            try app.invalidateWindow(window);
        }
        try expectOneFrame(app);
        const frame_elapsed = frame_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        frame_times_ns[@intCast(frame_index)] = @intCast(@max(0, frame_elapsed));
        if (frame_index % 64 == 0) if (residentBytes()) |current| {
            resident_min = @min(resident_min orelse current, current);
            resident_max = @max(resident_max orelse current, current);
        };
    }
    const total_elapsed = total_started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
    const total_elapsed_ns: u64 = @intCast(@max(0, total_elapsed));
    try drain(app);

    const runtime_after = try app.metricsSnapshot();
    const allocator_after = tracked.snapshot();
    const resident_after = residentBytes();
    if (resident_after) |current| {
        resident_min = @min(resident_min orelse current, current);
        resident_max = @max(resident_max orelse current, current);
    }
    const peak_resident_bytes = peakResidentBytes();
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
    if (resident_before != null and resident_after != null) {
        const maximum_endpoint_growth = 4 * 1024 * 1024;
        const maximum_sampled_growth = 8 * 1024 * 1024;
        std.debug.print(
            "stress RSS gate: {d}->{d} bytes, sampled range {d}..{d}\n",
            .{ resident_before.?, resident_after.?, resident_min.?, resident_max.? },
        );
        if (resident_after.? > resident_before.? +| maximum_endpoint_growth or
            resident_max.? > resident_before.? +| maximum_sampled_growth)
            return error.ResidentMemoryGrowth;
    }

    const stable_live_bytes = allocator_after.live_bytes;
    const peak_live_bytes = allocator_after.peak_live_bytes;
    const total_primitives = runtime_after.scene_primitives -| runtime_before.scene_primitives;
    std.mem.sort(u64, &frame_times_ns, {}, std.sort.asc(u64));
    const p50_ns = nearestRank(&frame_times_ns, 50);
    const p95_ns = nearestRank(&frame_times_ns, 95);
    const p99_ns = nearestRank(&frame_times_ns, 99);
    try app.destroy();
    app_owned = false;
    const allocator_final = tracked.snapshot();
    if (allocator_final.live_bytes != 0) return error.LiveBytesAfterTeardown;

    std.debug.print(
        "stress: {d} frames, {d} primitives, {d} stable live bytes, {d} peak tracked bytes, zero post-warm-up allocations; headless CPU frame p50/p95/p99 {d}/{d}/{d} us, total {d} ms",
        .{
            measured_frames,
            total_primitives,
            stable_live_bytes,
            peak_live_bytes,
            p50_ns / std.time.ns_per_us,
            p95_ns / std.time.ns_per_us,
            p99_ns / std.time.ns_per_us,
            total_elapsed_ns / std.time.ns_per_ms,
        },
    );
    if (peak_resident_bytes) |bytes| std.debug.print(", process peak RSS {d} bytes", .{bytes});
    if (resident_before != null and resident_after != null) std.debug.print(
        ", sampled RSS {d}->{d} bytes (range {d}..{d})",
        .{ resident_before.?, resident_after.?, resident_min.?, resident_max.? },
    );
    std.debug.print("\n", .{});
}

fn nearestRank(sorted: []const u64, percentile: usize) u64 {
    std.debug.assert(sorted.len != 0 and percentile >= 1 and percentile <= 100);
    const rank = (sorted.len * percentile + 99) / 100;
    return sorted[rank - 1];
}

fn peakResidentBytes() ?u64 {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi or builtin.os.tag == .emscripten)
        return null;
    const usage = std.posix.getrusage(std.c.rusage.SELF);
    if (usage.maxrss <= 0) return null;
    // Darwin reports bytes while Linux and the BSDs report KiB.
    return switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => @intCast(usage.maxrss),
        else => std.math.mul(u64, @intCast(usage.maxrss), 1024) catch null,
    };
}

fn residentBytes() ?u64 {
    if (comptime builtin.os.tag != .macos) return null;
    var info: MachTaskBasicInfo = undefined;
    var count: u32 = @sizeOf(MachTaskBasicInfo) / @sizeOf(u32);
    if (task_info(mach_task_self_, 20, &info, &count) != 0) return null;
    return info.resident_size;
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
