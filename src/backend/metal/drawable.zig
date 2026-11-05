const std = @import("std");
const objc = @import("../../platform/macos/objc.zig");
const Error = @import("../../core/error.zig").Error;

extern "c" fn dispatch_queue_create([*:0]const u8, objc.Id) objc.Id;
extern "c" fn dispatch_async_f(objc.Id, *anyopaque, *const fn (*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_sync_f(objc.Id, *anyopaque, *const fn (*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_release(objc.Id) void;

/// One outstanding drawable per window. Only nextDrawable runs off-thread;
/// AppKit, layer configuration, scene encoding and resource ownership stay on
/// the UI thread. The release/acquire handoff includes the worker's pool drain.
pub const Acquisition = struct {
    const State = enum(u8) { idle, pending, ready };
    layer: objc.Id,
    queue: objc.Id,
    state: std.atomic.Value(State) = .init(.idle),
    drawable: objc.Id = null,

    pub fn init(layer: objc.Id) Error!Acquisition {
        const queue = dispatch_queue_create("zigui.drawable", null) orelse return error.OutOfMemory;
        return .{ .layer = objc.retain(layer), .queue = queue };
    }

    pub fn pending(self: *const Acquisition) bool {
        return self.state.load(.acquire) == .pending;
    }

    pub fn start(self: *Acquisition) void {
        if (self.state.load(.acquire) != .idle) return;
        self.state.store(.pending, .release);
        dispatch_async_f(self.queue, self, acquire);
    }

    /// Transfers ownership when ready. Pending work returns null; a completed
    /// nil drawable preserves CAMetalLayer failure instead of retrying forever.
    pub fn take(self: *Acquisition) Error!objc.Id {
        if (self.state.load(.acquire) != .ready) return null;
        const result = self.drawable;
        self.drawable = null;
        self.state.store(.idle, .release);
        return result orelse error.SurfaceUnavailable;
    }

    pub fn deinit(self: *Acquisition) void {
        dispatch_sync_f(self.queue, self, barrier);
        objc.release(self.drawable);
        objc.release(self.layer);
        dispatch_release(self.queue);
    }

    fn barrier(_: *anyopaque) callconv(.c) void {}

    fn acquire(raw: *anyopaque) callconv(.c) void {
        const self: *Acquisition = @ptrCast(@alignCast(raw));
        var pool = objc.AutoreleasePool.init();
        self.drawable = objc.retain(objc.send(objc.Id, self.layer, "nextDrawable", .{}));
        pool.deinit();
        self.state.store(.ready, .release);
    }
};
