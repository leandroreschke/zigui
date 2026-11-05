const std = @import("std");
const clock = @import("clock.zig");

pub const FramePhase = enum {
    drain,
    dispatch,
    update,
    compose,
    measure,
    arrange,
    prepare,
    scene,
    encode,
    submit,
    present,
};

pub const PhaseTimings = struct {
    drain_ns: u64 = 0,
    dispatch_ns: u64 = 0,
    update_ns: u64 = 0,
    compose_ns: u64 = 0,
    measure_ns: u64 = 0,
    arrange_ns: u64 = 0,
    prepare_ns: u64 = 0,
    scene_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_ns: u64 = 0,
    present_ns: u64 = 0,

    pub fn set(self: *PhaseTimings, phase: FramePhase, duration: u64) void {
        switch (phase) {
            .drain => self.drain_ns = duration,
            .dispatch => self.dispatch_ns = duration,
            .update => self.update_ns = duration,
            .compose => self.compose_ns = duration,
            .measure => self.measure_ns = duration,
            .arrange => self.arrange_ns = duration,
            .prepare => self.prepare_ns = duration,
            .scene => self.scene_ns = duration,
            .encode => self.encode_ns = duration,
            .submit => self.submit_ns = duration,
            .present => self.present_ns = duration,
        }
    }
};

/// Aggregated invocation counts for each frame phase. `PhaseTimings` remains
/// the low-cost last-sample view used by existing overlays; these counters
/// make a bounded run auditable without enabling the detailed trace journal.
pub const PhaseCounter = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
};

pub const PhaseCounts = struct {
    drain: PhaseCounter = .{},
    dispatch: PhaseCounter = .{},
    update: PhaseCounter = .{},
    compose: PhaseCounter = .{},
    measure: PhaseCounter = .{},
    arrange: PhaseCounter = .{},
    prepare: PhaseCounter = .{},
    scene: PhaseCounter = .{},
    encode: PhaseCounter = .{},
    submit: PhaseCounter = .{},
    present: PhaseCounter = .{},

    fn add(self: *PhaseCounts, phase: FramePhase, duration_ns: u64) void {
        var counter: *PhaseCounter = switch (phase) {
            .drain => &self.drain,
            .dispatch => &self.dispatch,
            .update => &self.update,
            .compose => &self.compose,
            .measure => &self.measure,
            .arrange => &self.arrange,
            .prepare => &self.prepare,
            .scene => &self.scene,
            .encode => &self.encode,
            .submit => &self.submit,
            .present => &self.present,
        };
        counter.count +|= 1;
        counter.total_ns +|= duration_ns;
    }
};

/// One committed presentation sample. The ring is deliberately fixed-size so
/// recording remains allocation-free on a 480 Hz display as well as at lower
/// rates. A sample may omit interval/input values when there is no preceding
/// timestamp or no input transaction associated with that frame.
pub const PresentationSample = struct {
    timestamp_ns: u64 = 0,
    interval_ns: u64 = 0,
    input_to_present_ns: u64 = 0,
    has_interval: bool = false,
    has_input_to_present: bool = false,
};

pub const PercentileSummary = struct {
    sample_count: u32 = 0,
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
};

/// Bounded presentation evidence owned by the UI thread's `Counters`.
///
/// `refresh_millihertz` is a platform-reported display rate, not a scheduler
/// setting. A zero value means the provider did not report a rate, in which
/// case deadline accounting is intentionally disabled while timestamps and
/// percentiles remain valid. Percentiles use the nearest-rank definition over
/// the retained ring samples and are recomputed with fixed stack storage when
/// a presentation is recorded; no allocator or background thread is used.
pub const PresentationStats = struct {
    pub const sample_capacity: usize = 256;

    samples: [sample_capacity]PresentationSample = @splat(.{}),
    sample_count: usize = 0,
    next_sample: usize = 0,
    presented_count: u64 = 0,
    dropped_count: u64 = 0,
    latest_timestamp_ns: ?u64 = null,
    refresh_millihertz: u32 = 0,
    missed_deadline_count: u64 = 0,
    current_missed_deadline_streak: u64 = 0,
    maximum_missed_deadline_streak: u64 = 0,
    interval: PercentileSummary = .{},
    input_to_present: PercentileSummary = .{},

    /// Records a frame for which the renderer reported a successful present.
    /// This method must be called at the UI presentation boundary, after the
    /// renderer submit/present call has returned successfully.
    pub fn recordPresented(
        self: *PresentationStats,
        timestamp_ns: u64,
        refresh_millihertz: u32,
        input_to_present_ns: ?u64,
    ) void {
        // A zero report is meaningful: it explicitly disables deadline
        // classification when the provider cannot resolve the current rate.
        self.refresh_millihertz = refresh_millihertz;

        const previous_timestamp = self.latest_timestamp_ns;
        const has_interval = if (previous_timestamp) |previous| timestamp_ns > previous else false;
        const interval_ns = if (has_interval) timestamp_ns - previous_timestamp.? else 0;
        const sample: PresentationSample = .{
            .timestamp_ns = timestamp_ns,
            .interval_ns = interval_ns,
            .input_to_present_ns = input_to_present_ns orelse 0,
            .has_interval = has_interval,
            .has_input_to_present = input_to_present_ns != null,
        };
        self.samples[self.next_sample] = sample;
        self.next_sample = (self.next_sample + 1) % sample_capacity;
        if (self.sample_count < sample_capacity) self.sample_count += 1;
        self.presented_count +|= 1;
        self.latest_timestamp_ns = timestamp_ns;

        if (has_interval) {
            if (deadlinePeriodNs(self.refresh_millihertz)) |deadline| {
                if (interval_ns > deadline) {
                    self.missed_deadline_count +|= 1;
                    self.current_missed_deadline_streak +|= 1;
                    self.maximum_missed_deadline_streak = @max(
                        self.maximum_missed_deadline_streak,
                        self.current_missed_deadline_streak,
                    );
                } else {
                    self.current_missed_deadline_streak = 0;
                }
            } else {
                self.current_missed_deadline_streak = 0;
            }
        } else if (previous_timestamp != null) {
            // Equal or backwards timestamps are a clock discontinuity, not a
            // missed display deadline. Keep the new sample for diagnostics,
            // but do not bridge a false streak across the discontinuity.
            self.current_missed_deadline_streak = 0;
        }

        self.recomputePercentiles();
    }

    /// Records a submitted frame that the renderer/compositor did not report
    /// as presented (for example an occluded surface). It has no timestamp and
    /// therefore cannot fabricate an interval sample.
    pub fn recordDropped(self: *PresentationStats) void {
        self.dropped_count +|= 1;
    }

    pub fn reset(self: *PresentationStats) void {
        self.* = .{};
    }

    fn recomputePercentiles(self: *PresentationStats) void {
        var intervals: [sample_capacity]u64 = undefined;
        var inputs: [sample_capacity]u64 = undefined;
        var interval_count: usize = 0;
        var input_count: usize = 0;
        for (self.samples[0..self.sample_count]) |sample| {
            if (sample.has_interval) {
                intervals[interval_count] = sample.interval_ns;
                interval_count += 1;
            }
            if (sample.has_input_to_present) {
                inputs[input_count] = sample.input_to_present_ns;
                input_count += 1;
            }
        }
        // Once the ring wraps, the oldest element may be at `next_sample`, so
        // the physical prefix is not the complete retained set. The values
        // above are still correct only before wrap; scan the ring in logical
        // order for the wrapped case.
        if (self.sample_count == sample_capacity and self.next_sample != 0) {
            interval_count = 0;
            input_count = 0;
            var offset: usize = 0;
            while (offset < sample_capacity) : (offset += 1) {
                const sample = self.samples[(self.next_sample + offset) % sample_capacity];
                if (sample.has_interval) {
                    intervals[interval_count] = sample.interval_ns;
                    interval_count += 1;
                }
                if (sample.has_input_to_present) {
                    inputs[input_count] = sample.input_to_present_ns;
                    input_count += 1;
                }
            }
        }
        sortAscending(intervals[0..interval_count]);
        sortAscending(inputs[0..input_count]);
        self.interval = percentileSummary(intervals[0..interval_count]);
        self.input_to_present = percentileSummary(inputs[0..input_count]);
    }
};

fn sortAscending(values: []u64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var cursor = index;
        while (cursor > 0 and values[cursor - 1] > value) : (cursor -= 1) values[cursor] = values[cursor - 1];
        values[cursor] = value;
    }
}

fn percentileSummary(values: []const u64) PercentileSummary {
    if (values.len == 0) return .{};
    return .{
        .sample_count = @intCast(values.len),
        .p50_ns = values[nearestRankIndex(values.len, 50)],
        .p95_ns = values[nearestRankIndex(values.len, 95)],
        .p99_ns = values[nearestRankIndex(values.len, 99)],
    };
}

fn nearestRankIndex(count: usize, percentile: usize) usize {
    std.debug.assert(count > 0);
    const rank = (count * percentile + 99) / 100;
    return @max(@as(usize, 1), rank) - 1;
}

fn deadlinePeriodNs(refresh_millihertz: u32) ?u64 {
    if (refresh_millihertz == 0) return null;
    // millihertz -> nanoseconds, rounded up so an exact period is not marked
    // late solely because one display period is fractional in nanoseconds.
    const numerator: u64 = 1_000_000_000_000;
    return (numerator + refresh_millihertz - 1) / refresh_millihertz;
}

pub const Counters = struct {
    frames_built: u64 = 0,
    frames_submitted: u64 = 0,
    frames_presented: u64 = 0,
    invalidations: u64 = 0,
    coalesced_invalidations: u64 = 0,
    native_events: u64 = 0,
    worker_messages: u64 = 0,
    dropped_events: u64 = 0,
    allocations: u64 = 0,
    allocated_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
    scene_operations: u64 = 0,
    scene_primitives: u64 = 0,
    upload_bytes: u64 = 0,
    gpu_resources_created: u64 = 0,
    atlas_evictions: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    retained_scene_hits: u64 = 0,
    retained_scene_misses: u64 = 0,
    retained_scene_budget_skips: u64 = 0,
    stale_results: u64 = 0,
    device_recoveries: u64 = 0,
    journal_losses: u64 = 0,
    input_to_present_ns: u64 = 0,
    phase_counts: PhaseCounts = .{},
    presentation: PresentationStats = .{},
    timings: PhaseTimings = .{},

    pub fn recordPresented(
        self: *Counters,
        timestamp_ns: u64,
        refresh_millihertz: u32,
        input_to_present_ns: ?u64,
    ) void {
        self.presentation.recordPresented(timestamp_ns, refresh_millihertz, input_to_present_ns);
        if (input_to_present_ns) |latency| self.input_to_present_ns = latency;
    }

    pub fn recordDroppedFrame(self: *Counters) void {
        self.presentation.recordDropped();
    }

    pub fn resetPresentation(self: *Counters) void {
        self.presentation.reset();
        self.input_to_present_ns = 0;
    }
};

pub const PhaseTimer = struct {
    counters: *Counters,
    source: clock.Clock,
    phase: FramePhase,
    started: clock.Timestamp,
    ended: bool = false,

    pub fn begin(counters: *Counters, source: clock.Clock, phase: FramePhase) PhaseTimer {
        return .{
            .counters = counters,
            .source = source,
            .phase = phase,
            .started = source.now(),
        };
    }

    pub fn end(self: *PhaseTimer) void {
        if (self.ended) return;
        self.ended = true;
        const duration = self.source.now() -| self.started;
        self.counters.timings.set(self.phase, duration);
        self.counters.phase_counts.add(self.phase, duration);
    }
};

test "presentation deadlines cover common reported refresh rates" {
    const refresh_rates = [_]u32{ 60_000, 120_000, 240_000, 480_000 };
    for (refresh_rates) |refresh| {
        var stats: PresentationStats = .{};
        const period = deadlinePeriodNs(refresh).?;
        stats.recordPresented(0, refresh, null);
        stats.recordPresented(period, refresh, 2_000_000);
        stats.recordPresented(period * 2, refresh, 3_000_000);

        try std.testing.expectEqual(@as(u64, 3), stats.presented_count);
        try std.testing.expectEqual(@as(u64, 0), stats.dropped_count);
        try std.testing.expectEqual(@as(u32, 2), stats.interval.sample_count);
        try std.testing.expectEqual(period, stats.interval.p50_ns);
        try std.testing.expectEqual(period, stats.interval.p95_ns);
        try std.testing.expectEqual(@as(u32, 2), stats.input_to_present.sample_count);
        try std.testing.expectEqual(@as(u64, 2_000_000), stats.input_to_present.p50_ns);
        try std.testing.expectEqual(@as(u64, 3_000_000), stats.input_to_present.p95_ns);
        try std.testing.expectEqual(@as(u64, 0), stats.missed_deadline_count);
        try std.testing.expectEqual(@as(u64, 0), stats.maximum_missed_deadline_streak);
    }
}

test "presentation metrics record dropped frames and deadline streaks" {
    var stats: PresentationStats = .{};
    const period = deadlinePeriodNs(60_000).?;
    stats.recordPresented(0, 60_000, null);
    stats.recordDropped();
    stats.recordPresented(period * 2, 60_000, null);

    try std.testing.expectEqual(@as(u64, 1), stats.dropped_count);
    try std.testing.expectEqual(@as(u64, 1), stats.missed_deadline_count);
    try std.testing.expectEqual(@as(u64, 1), stats.current_missed_deadline_streak);
    try std.testing.expectEqual(@as(u64, 1), stats.maximum_missed_deadline_streak);

    // A normal interval closes the streak without fabricating a missed frame.
    stats.recordPresented(period * 3, 60_000, null);
    try std.testing.expectEqual(@as(u64, 0), stats.current_missed_deadline_streak);
    try std.testing.expectEqual(@as(u64, 1), stats.missed_deadline_count);
}

test "presentation ring wraps without allocations or stale percentile values" {
    var stats: PresentationStats = .{};
    const period = deadlinePeriodNs(120_000).?;
    var index: usize = 0;
    while (index < PresentationStats.sample_capacity + 23) : (index += 1) {
        stats.recordPresented(@as(u64, index) * period, 120_000, @as(u64, index) * 1000);
    }

    try std.testing.expectEqual(PresentationStats.sample_capacity, stats.sample_count);
    try std.testing.expectEqual(@as(u32, PresentationStats.sample_capacity), stats.interval.sample_count);
    try std.testing.expectEqual(@as(u32, PresentationStats.sample_capacity), stats.input_to_present.sample_count);
    try std.testing.expectEqual(period, stats.interval.p50_ns);
    try std.testing.expectEqual(period, stats.interval.p95_ns);
    try std.testing.expectEqual(period, stats.interval.p99_ns);
    try std.testing.expectEqual(
        @as(u64, PresentationStats.sample_capacity + 22) * period,
        stats.latest_timestamp_ns.?,
    );
    try std.testing.expectEqual(
        @as(u64, PresentationStats.sample_capacity + 20) * 1000,
        stats.input_to_present.p99_ns,
    );
}

test "presentation metrics reset cleanly and idle snapshots stay unchanged" {
    var counters: Counters = .{};
    counters.recordPresented(10, 60_000, 4);
    counters.recordDroppedFrame();
    const before_idle = counters;
    // An idle event-loop interval does not call a recorder and therefore does
    // not manufacture a submission or a presentation sample.
    try std.testing.expectEqual(before_idle.frames_submitted, counters.frames_submitted);
    try std.testing.expectEqual(before_idle.presentation.presented_count, counters.presentation.presented_count);
    try std.testing.expectEqual(before_idle.presentation.dropped_count, counters.presentation.dropped_count);

    counters.resetPresentation();
    try std.testing.expectEqual(@as(u64, 0), counters.input_to_present_ns);
    try std.testing.expectEqual(@as(u64, 0), counters.presentation.presented_count);
    try std.testing.expectEqual(@as(u64, 0), counters.presentation.dropped_count);
    try std.testing.expectEqual(@as(u32, 0), counters.presentation.interval.sample_count);
}

test "phase timers count each completed phase exactly once" {
    var manual = clock.ManualClock{};
    var counters: Counters = .{};
    var timer = PhaseTimer.begin(&counters, manual.clock(), .scene);
    manual.advance(clock.milliseconds(2));
    timer.end();
    timer.end();

    try std.testing.expectEqual(@as(u64, 1), counters.phase_counts.scene.count);
    try std.testing.expectEqual(clock.milliseconds(2), counters.phase_counts.scene.total_ns);
    try std.testing.expectEqual(clock.milliseconds(2), counters.timings.scene_ns);
}
