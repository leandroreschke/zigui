pub const Timestamp = u64;
pub const Duration = u64;

pub const Clock = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) Timestamp,

    pub fn now(self: Clock) Timestamp {
        return self.now_fn(self.context);
    }
};

pub const ManualClock = struct {
    current: Timestamp = 0,

    pub fn clock(self: *ManualClock) Clock {
        return .{ .context = self, .now_fn = nowOpaque };
    }

    pub fn advance(self: *ManualClock, duration: Duration) void {
        self.current +|= duration;
    }

    pub fn set(self: *ManualClock, timestamp: Timestamp) void {
        self.current = timestamp;
    }

    fn nowOpaque(context: *anyopaque) Timestamp {
        const self: *ManualClock = @ptrCast(@alignCast(context));
        return self.current;
    }
};

pub fn milliseconds(value: u64) Duration {
    return value * 1_000_000;
}

pub fn seconds(value: u64) Duration {
    return value * 1_000_000_000;
}
