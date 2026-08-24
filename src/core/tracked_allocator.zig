const std = @import("std");
const memory = @import("memory.zig");
const metrics = @import("metrics.zig");
const Mutex = @import("mutex.zig").Mutex;

pub const TrackedAllocator = struct {
    backing: std.mem.Allocator,
    counters: *metrics.Counters,
    budget: ?*memory.Budget = null,
    mutex: Mutex = .{},

    pub fn init(
        backing: std.mem.Allocator,
        counters: *metrics.Counters,
        budget: ?*memory.Budget,
    ) TrackedAllocator {
        return .{ .backing = backing, .counters = counters, .budget = budget };
    }

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Returns a coherent counter sample even when the wrapped allocator is
    /// used by application worker threads.
    pub fn snapshot(self: *TrackedAllocator) metrics.Counters {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.counters.*;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn reserve(self: *TrackedAllocator, amount: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.budget) |budget| budget.reserve(amount) catch return false;
        return true;
    }

    fn unreserve(self: *TrackedAllocator, amount: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.budget) |budget| budget.release(amount);
    }

    fn recordRelease(self: *TrackedAllocator, amount: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.budget) |budget| budget.release(amount);
        self.counters.live_bytes -|= amount;
    }

    fn recordAllocation(self: *TrackedAllocator, amount: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.counters.allocations +|= 1;
        self.counters.allocated_bytes +|= amount;
        self.counters.live_bytes +|= amount;
        self.counters.peak_live_bytes = @max(self.counters.peak_live_bytes, self.counters.live_bytes);
    }

    fn allocate(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(context));
        if (!self.reserve(len)) return null;
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse {
            self.unreserve(len);
            return null;
        };
        self.recordAllocation(len);
        return result;
    }

    fn resize(
        context: *anyopaque,
        allocation: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(context));
        const growing = new_len > allocation.len;
        const difference = if (growing) new_len - allocation.len else allocation.len - new_len;
        if (growing and !self.reserve(difference)) return false;
        if (!self.backing.rawResize(allocation, alignment, new_len, ret_addr)) {
            if (growing) self.unreserve(difference);
            return false;
        }
        if (growing) {
            self.recordAllocation(difference);
        } else {
            self.recordRelease(difference);
        }
        return true;
    }

    fn remap(
        context: *anyopaque,
        allocation: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(context));
        const growing = new_len > allocation.len;
        const difference = if (growing) new_len - allocation.len else allocation.len - new_len;
        if (growing and !self.reserve(difference)) return null;
        const result = self.backing.rawRemap(allocation, alignment, new_len, ret_addr) orelse {
            if (growing) self.unreserve(difference);
            return null;
        };
        if (growing) {
            self.recordAllocation(difference);
        } else {
            self.recordRelease(difference);
        }
        return result;
    }

    fn free(
        context: *anyopaque,
        allocation: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(allocation, alignment, ret_addr);
        self.recordRelease(allocation.len);
    }
};
