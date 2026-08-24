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
    stale_results: u64 = 0,
    device_recoveries: u64 = 0,
    journal_losses: u64 = 0,
    input_to_present_ns: u64 = 0,
    timings: PhaseTimings = .{},
};

pub const PhaseTimer = struct {
    counters: *Counters,
    source: clock.Clock,
    phase: FramePhase,
    started: clock.Timestamp,

    pub fn begin(counters: *Counters, source: clock.Clock, phase: FramePhase) PhaseTimer {
        return .{
            .counters = counters,
            .source = source,
            .phase = phase,
            .started = source.now(),
        };
    }

    pub fn end(self: *PhaseTimer) void {
        self.counters.timings.set(self.phase, self.source.now() -| self.started);
    }
};
