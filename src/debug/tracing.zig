const std = @import("std");
const clock = @import("../core/clock.zig");
const handles = @import("../core/handle.zig");

pub const Category = enum(u8) {
    application,
    event,
    state,
    composition,
    layout,
    input,
    text,
    accessibility,
    scene,
    resource,
    renderer,
    platform,
    task,
};

pub const Name = enum(u16) {
    app_run,
    frame,
    native_event,
    dispatch,
    update,
    effect,
    compose,
    reconcile,
    measure,
    arrange,
    prepare,
    hit_tree,
    semantic_tree,
    text_shape,
    text_raster,
    scene_build,
    render_encode,
    render_submit,
    present,
    texture_create,
    texture_upload,
    texture_retire,
    atlas_allocate,
    atlas_evict,
    device_lost,
    device_recover,
    window_create,
    window_close,
    task_enqueue,
    task_complete,
    custom,
};

pub const Phase = enum(u8) { instant, begin, end, counter };

pub const Arguments = extern struct {
    first: u64 = 0,
    second: u64 = 0,
    third: u64 = 0,
    fourth: u64 = 0,
};

pub const Event = extern struct {
    timestamp_ns: u64,
    sequence: u64,
    correlation: u64,
    thread: u64,
    arguments: Arguments,
    category: Category,
    name: Name,
    phase: Phase,
    flags: u8 = 0,
    reserved: u32 = 0,
};

pub const Snapshot = struct {
    events: []Event,
    losses: u64,
    first_sequence: u64,
    next_sequence: u64,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        self.* = undefined;
    }

    /// Writes Chrome Trace Event JSON without pulling a serialization package
    /// into the framework. Enum names are static and arguments are numeric.
    pub fn writeChromeTrace(self: *const Snapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll("{\"traceEvents\":[");
        for (self.events, 0..) |event, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.print(
                "{{\"name\":\"{s}\",\"cat\":\"{s}\",\"ph\":\"{c}\",\"ts\":{d},\"pid\":1,\"tid\":{d},\"id\":{d},\"args\":{{\"a\":{d},\"b\":{d},\"c\":{d},\"d\":{d}}}}}",
                .{
                    @tagName(event.name),
                    @tagName(event.category),
                    chromePhase(event.phase),
                    event.timestamp_ns / 1000,
                    event.thread,
                    event.correlation,
                    event.arguments.first,
                    event.arguments.second,
                    event.arguments.third,
                    event.arguments.fourth,
                },
            );
        }
        try writer.print("],\"displayTimeUnit\":\"ns\",\"metadata\":{{\"losses\":{d}}}}", .{self.losses});
    }
};

/// A bounded UI-thread journal. When full it overwrites the oldest event and
/// increments a loss counter; tracing can never make frame progress depend on
/// an unbounded allocation or a consumer keeping up.
pub const Recorder = struct {
    allocator: std.mem.Allocator,
    source: clock.Clock,
    events: []Event,
    start: usize = 0,
    count: usize = 0,
    next_sequence: u64 = 1,
    next_correlation: u64 = 1,
    losses: u64 = 0,
    enabled: bool = true,

    pub fn init(allocator: std.mem.Allocator, source: clock.Clock, capacity: usize) !Recorder {
        if (capacity == 0) return error.InvalidConfiguration;
        return .{ .allocator = allocator, .source = source, .events = try allocator.alloc(Event, capacity) };
    }

    pub fn deinit(self: *Recorder) void {
        self.allocator.free(self.events);
        self.* = undefined;
    }

    pub fn setEnabled(self: *Recorder, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn instant(self: *Recorder, category: Category, name: Name, arguments: Arguments) void {
        self.record(category, name, .instant, 0, arguments);
    }

    pub fn counter(self: *Recorder, category: Category, name: Name, arguments: Arguments) void {
        self.record(category, name, .counter, 0, arguments);
    }

    pub fn begin(self: *Recorder, category: Category, name: Name, arguments: Arguments) Span {
        const correlation = self.allocateCorrelation();
        self.record(category, name, .begin, correlation, arguments);
        return .{ .recorder = self, .category = category, .name = name, .correlation = correlation };
    }

    pub fn snapshot(self: *const Recorder, allocator: std.mem.Allocator) !Snapshot {
        const copy = try allocator.alloc(Event, self.count);
        for (0..self.count) |index| copy[index] = self.events[(self.start + index) % self.events.len];
        return .{
            .events = copy,
            .losses = self.losses,
            .first_sequence = if (copy.len == 0) self.next_sequence else copy[0].sequence,
            .next_sequence = self.next_sequence,
        };
    }

    pub fn clear(self: *Recorder) void {
        self.start = 0;
        self.count = 0;
        self.losses = 0;
    }

    fn allocateCorrelation(self: *Recorder) u64 {
        const value = self.next_correlation;
        self.next_correlation +%= 1;
        if (self.next_correlation == 0) self.next_correlation = 1;
        return value;
    }

    fn record(self: *Recorder, category: Category, name: Name, phase: Phase, correlation: u64, arguments: Arguments) void {
        if (!self.enabled) return;
        const event: Event = .{
            .timestamp_ns = self.source.now(),
            .sequence = self.next_sequence,
            .correlation = correlation,
            .thread = currentThreadId(),
            .arguments = arguments,
            .category = category,
            .name = name,
            .phase = phase,
        };
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        if (self.count < self.events.len) {
            self.events[(self.start + self.count) % self.events.len] = event;
            self.count += 1;
        } else {
            self.events[self.start] = event;
            self.start = (self.start + 1) % self.events.len;
            self.losses +|= 1;
        }
    }
};

pub const Span = struct {
    recorder: ?*Recorder,
    category: Category,
    name: Name,
    correlation: u64,
    closed: bool = false,

    pub fn end(self: *Span, arguments: Arguments) void {
        if (self.closed) return;
        self.closed = true;
        if (self.recorder) |recorder| recorder.record(self.category, self.name, .end, self.correlation, arguments);
    }

    pub fn deinit(self: *Span) void {
        self.end(.{});
    }
};

pub fn handleArgument(comptime T: type, value: T) u64 {
    if (@hasDecl(T, "encode")) return value.encode();
    if (@sizeOf(T) <= @sizeOf(u64)) {
        var result: u64 = 0;
        @memcpy(std.mem.asBytes(&result)[0..@sizeOf(T)], std.mem.asBytes(&value));
        return result;
    }
    return 0;
}

fn chromePhase(phase: Phase) u8 {
    return switch (phase) {
        .instant => 'i',
        .begin => 'B',
        .end => 'E',
        .counter => 'C',
    };
}

fn currentThreadId() u64 {
    const id = std.Thread.getCurrentId();
    return @intCast(id);
}

comptime {
    _ = handles.WindowId;
    std.debug.assert(@sizeOf(Event) == 80);
}
