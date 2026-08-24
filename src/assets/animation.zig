const std = @import("std");
const Error = @import("../core/error.zig").Error;
const api = @import("animation_api.zig");
const gif = @import("gif.zig");
const image = @import("image.zig");
const png = @import("png.zig");

pub const Frame = api.Frame;
pub const Looping = api.Looping;

pub const Decoder = union(enum) {
    gif: gif.Decoder,
    apng: png.AnimationDecoder,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!Decoder {
        if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a")))
            return .{ .gif = try gif.Decoder.init(allocator, bytes, limits) };
        if (png.isAnimated(bytes)) return .{ .apng = try png.AnimationDecoder.init(allocator, bytes, limits) };
        return error.InvalidImage;
    }

    pub fn deinit(self: *Decoder) void {
        switch (self.*) {
            .gif => |*value| value.deinit(),
            .apng => |*value| value.deinit(),
        }
        self.* = undefined;
    }

    pub fn reset(self: *Decoder) void {
        switch (self.*) {
            .gif => |*value| value.reset(),
            .apng => |*value| value.reset(),
        }
    }

    pub fn next(self: *Decoder) Error!?Frame {
        return switch (self.*) {
            .gif => |*value| try value.next(),
            .apng => |*value| try value.next(),
        };
    }

    pub fn looping(self: *const Decoder) Looping {
        return switch (self.*) {
            .gif => |value| value.looping,
            .apng => |value| value.looping,
        };
    }
};

pub const State = enum { playing, paused, finished };

/// Clock-driven sequential player with bounded catch-up work. It owns the
/// encoded source and keeps only the decoder's current compositing canvases.
pub const Player = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    decoder: Decoder,
    current: ?Frame = null,
    state: State = .playing,
    deadline_ns: u64 = 0,
    remaining_repetitions: u32 = 0,
    initialized_loop_count: bool = false,
    maximum_catch_up_frames: usize = 4096,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, limits: image.Limits, now_ns: u64) Error!Player {
        if (source.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
        const owned = try allocator.dupe(u8, source);
        errdefer allocator.free(owned);
        var decoder = try Decoder.init(allocator, owned, limits);
        errdefer decoder.deinit();
        var result: Player = .{
            .allocator = allocator,
            .source = owned,
            .decoder = decoder,
        };
        const first = (try result.decoder.next()) orelse return error.InvalidImage;
        result.current = first;
        result.deadline_ns = now_ns +| first.duration_ns;
        result.refreshLoopCount();
        return result;
    }

    pub fn deinit(self: *Player) void {
        self.decoder.deinit();
        self.allocator.free(self.source);
        self.* = undefined;
    }

    pub fn frame(self: *const Player) ?Frame {
        return self.current;
    }

    pub fn isPlaying(self: *const Player) bool {
        return self.state == .playing;
    }

    pub fn play(self: *Player, now_ns: u64) Error!void {
        if (self.state == .playing) return;
        if (self.state == .finished) return self.restart(now_ns);
        self.state = .playing;
        if (self.current) |frame_value| self.deadline_ns = now_ns +| frame_value.duration_ns;
    }

    pub fn pause(self: *Player) void {
        if (self.state == .playing) self.state = .paused;
    }

    pub fn restart(self: *Player, now_ns: u64) Error!void {
        self.decoder.reset();
        const first = (try self.decoder.next()) orelse return error.InvalidImage;
        self.current = first;
        self.state = .playing;
        self.deadline_ns = now_ns +| first.duration_ns;
        self.initialized_loop_count = false;
        self.refreshLoopCount();
    }

    /// Advances to the frame appropriate for `now_ns`. Returns true only when
    /// the visible canvas changed. Decode work is bounded even after a long
    /// suspension; excess elapsed time is rebased instead of monopolizing the
    /// UI thread.
    pub fn advance(self: *Player, now_ns: u64) Error!bool {
        if (self.state != .playing or self.current == null or now_ns < self.deadline_ns) return false;
        var changed = false;
        var decoded: usize = 0;
        while (now_ns >= self.deadline_ns and self.state == .playing) {
            if (decoded >= self.maximum_catch_up_frames) {
                const current = self.current.?;
                self.deadline_ns = now_ns +| current.duration_ns;
                break;
            }
            if (try self.decoder.next()) |next_frame| {
                self.current = next_frame;
                self.deadline_ns +|= next_frame.duration_ns;
                changed = true;
                decoded += 1;
                continue;
            }
            if (!self.beginNextLoop()) {
                self.state = .finished;
                break;
            }
            self.decoder.reset();
            const first = (try self.decoder.next()) orelse return error.InvalidImage;
            self.current = first;
            self.deadline_ns +|= first.duration_ns;
            changed = true;
            decoded += 1;
        }
        return changed;
    }

    fn refreshLoopCount(self: *Player) void {
        switch (self.decoder.looping()) {
            .once, .infinite => self.remaining_repetitions = 0,
            .repetitions => |count| self.remaining_repetitions = count,
        }
        self.initialized_loop_count = true;
    }

    fn beginNextLoop(self: *Player) bool {
        if (!self.initialized_loop_count) self.refreshLoopCount();
        return switch (self.decoder.looping()) {
            .infinite => true,
            .once => false,
            .repetitions => if (self.remaining_repetitions == 0) false else blk: {
                self.remaining_repetitions -= 1;
                break :blk true;
            },
        };
    }
};
