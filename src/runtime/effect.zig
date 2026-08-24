const std = @import("std");
const Error = @import("../core/error.zig").Error;

pub const Deferred = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque) void,
    drop_fn: *const fn (*anyopaque) void,

    /// Executes the effect without consuming its context. The queue invokes
    /// `drop_fn` exactly once after a successful run or during shutdown when
    /// an unread effect is abandoned.
    pub fn run(self: Deferred) void {
        self.run_fn(self.context);
    }

    pub fn drop(self: Deferred) void {
        self.drop_fn(self.context);
    }
};

pub const Effect = union(enum) {
    deferred: Deferred,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    effects: std.ArrayList(Effect) = .empty,
    read_index: usize = 0,
    maximum_effects: usize,

    pub fn init(allocator: std.mem.Allocator) Queue {
        return initWithLimit(allocator, 65_536);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, maximum_effects: usize) Queue {
        return .{ .allocator = allocator, .maximum_effects = maximum_effects };
    }

    pub fn deinit(self: *Queue) void {
        for (self.effects.items[self.read_index..]) |effect| {
            if (effect == .deferred) effect.deferred.drop();
        }
        self.effects.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *Queue, effect: Effect) Error!void {
        // Count the whole current drain, not only its unread tail. An effect
        // may enqueue another effect while running; bounding only `pending`
        // would let a self-rescheduling chain grow the backing list forever.
        if (self.effects.items.len >= self.maximum_effects) return error.BudgetExceeded;
        try self.effects.append(self.allocator, effect);
    }

    pub fn next(self: *Queue) ?Effect {
        if (self.read_index >= self.effects.items.len) return null;
        const effect = self.effects.items[self.read_index];
        self.read_index += 1;
        return effect;
    }

    pub fn reset(self: *Queue) Error!void {
        if (self.read_index != self.effects.items.len) return error.FramePhaseViolation;
        self.effects.clearRetainingCapacity();
        self.read_index = 0;
    }

    pub fn pending(self: *const Queue) usize {
        return self.effects.items.len - self.read_index;
    }
};
