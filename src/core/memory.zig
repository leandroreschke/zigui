const std = @import("std");

pub const Budget = struct {
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    denied: u64 = 0,

    pub fn reserve(self: *Budget, amount: usize) error{BudgetExceeded}!void {
        if (amount > self.limit -| self.used) {
            self.denied +|= 1;
            return error.BudgetExceeded;
        }
        self.used += amount;
        self.peak = @max(self.peak, self.used);
    }

    pub fn release(self: *Budget, amount: usize) void {
        std.debug.assert(amount <= self.used);
        self.used -= amount;
    }

    pub fn remaining(self: Budget) usize {
        return self.limit -| self.used;
    }
};

pub const FrameArena = struct {
    owner_allocator: std.mem.Allocator,
    state: *State,
    retained_limit: usize,
    generation: u64 = 1,
    scope_depth: u32 = 0,
    reset_requested: bool = false,

    pub fn init(backing_allocator: std.mem.Allocator, capacity_bytes: usize) std.mem.Allocator.Error!FrameArena {
        const state = try backing_allocator.create(State);
        state.limited = .{ .backing = backing_allocator, .limit = capacity_bytes };
        state.arena = std.heap.ArenaAllocator.init(state.limited.allocator());
        return .{
            .owner_allocator = backing_allocator,
            .state = state,
            // A frame arena retains its bounded high-water mark so stable UI
            // workloads stop touching the backing heap after warm-up. The
            // configured capacity remains the hard per-window upper bound.
            .retained_limit = capacity_bytes,
        };
    }

    pub fn deinit(self: *FrameArena) void {
        std.debug.assert(self.scope_depth == 0);
        self.state.arena.deinit();
        const allocator = self.owner_allocator;
        allocator.destroy(self.state);
        self.* = undefined;
    }

    pub fn enter(self: *FrameArena) Scope {
        self.scope_depth += 1;
        return .{ .owner = self, .generation = self.generation };
    }

    pub fn requestReset(self: *FrameArena) void {
        self.reset_requested = true;
        if (self.scope_depth == 0) self.performReset();
    }

    pub fn resetNow(self: *FrameArena) error{FrameActive}!void {
        if (self.scope_depth != 0) return error.FrameActive;
        self.reset_requested = true;
        self.performReset();
    }

    pub fn capacity(self: *const FrameArena) usize {
        return self.state.arena.queryCapacity();
    }

    pub fn limit(self: *const FrameArena) usize {
        return self.state.limited.limit;
    }

    fn performReset(self: *FrameArena) void {
        _ = self.state.arena.reset(.{ .retain_with_limit = self.retained_limit });
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.reset_requested = false;
    }

    pub const Scope = struct {
        owner: *FrameArena,
        generation: u64,
        active: bool = true,

        pub fn allocator(self: *const Scope) std.mem.Allocator {
            std.debug.assert(self.active);
            std.debug.assert(self.owner.generation == self.generation);
            return self.owner.state.arena.allocator();
        }

        pub fn deinit(self: *Scope) void {
            std.debug.assert(self.active);
            std.debug.assert(self.owner.generation == self.generation);
            self.active = false;
            self.owner.scope_depth -= 1;
            if (self.owner.scope_depth == 0 and self.owner.reset_requested) {
                self.owner.performReset();
            }
        }
    };

    const State = struct {
        limited: LimitedAllocator,
        arena: std.heap.ArenaAllocator,
    };
};

/// UI-thread-only allocator used underneath a frame arena. Arena chunks are
/// acquired lazily, but their aggregate requested bytes can never exceed the
/// configured frame budget.
const LimitedAllocator = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: usize = 0,

    fn allocator(self: *LimitedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn reserve(self: *LimitedAllocator, amount: usize) bool {
        if (amount > self.limit -| self.used) return false;
        self.used += amount;
        return true;
    }

    fn allocate(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *LimitedAllocator = @ptrCast(@alignCast(context));
        if (!self.reserve(len)) return null;
        return self.backing.rawAlloc(len, alignment, return_address) orelse {
            self.used -= len;
            return null;
        };
    }

    fn resize(
        context: *anyopaque,
        allocation: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *LimitedAllocator = @ptrCast(@alignCast(context));
        const growing = new_len > allocation.len;
        const difference = if (growing) new_len - allocation.len else allocation.len - new_len;
        if (growing and !self.reserve(difference)) return false;
        if (!self.backing.rawResize(allocation, alignment, new_len, return_address)) {
            if (growing) self.used -= difference;
            return false;
        }
        if (!growing) self.used -= difference;
        return true;
    }

    fn remap(
        context: *anyopaque,
        allocation: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LimitedAllocator = @ptrCast(@alignCast(context));
        const growing = new_len > allocation.len;
        const difference = if (growing) new_len - allocation.len else allocation.len - new_len;
        if (growing and !self.reserve(difference)) return null;
        const result = self.backing.rawRemap(allocation, alignment, new_len, return_address) orelse {
            if (growing) self.used -= difference;
            return null;
        };
        if (!growing) self.used -= difference;
        return result;
    }

    fn free(context: *anyopaque, allocation: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *LimitedAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(allocation, alignment, return_address);
        std.debug.assert(allocation.len <= self.used);
        self.used -= allocation.len;
    }
};
