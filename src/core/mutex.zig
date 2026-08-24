const std = @import("std");

/// Small standard-library-only mutex for framework critical sections.
/// Zig 0.17's blocking mutex is IO-context-bound; ZigUI's allocator counters
/// and bounded message rings cannot require an application IO runtime. Their
/// critical sections are short, so a bounded backoff over the atomic mutex is
/// the appropriate runtime-independent contract.
pub const Mutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *Mutex) void {
        var spins: usize = 1;
        while (!self.inner.tryLock()) {
            for (0..spins) |_| std.atomic.spinLoopHint();
            spins = @min(spins * 2, 256);
            if (spins == 256) std.Thread.yield() catch {};
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};
