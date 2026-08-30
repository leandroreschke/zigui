const Error = @import("../core/error.zig").Error;

pub const Phase = enum {
    idle,
    draining,
    dispatching,
    updating,
    composing,
    measuring,
    arranging,
    preparing,
    building_scene,
    encoding,
    submitting,
    presenting,
    shutting_down,
    closed,
};

pub const State = struct {
    current: Phase = .idle,
    callback_depth: u32 = 0,
    /// User callbacks entered from renderer/native boundaries that must not
    /// mutate App-owned registries while those boundaries retain borrows.
    mutation_block_depth: u32 = 0,
    transaction_depth: u32 = 0,
    frame_callback_depth: u32 = 0,

    pub fn transition(self: *State, next: Phase) Error!void {
        if (!isAllowed(self.current, next)) return error.FramePhaseViolation;
        self.current = next;
    }

    pub fn enterCallback(self: *State) Error!CallbackGuard {
        if (self.callback_depth != 0) return error.CallbackReentrancy;
        self.callback_depth += 1;
        return .{ .state = self };
    }

    pub fn enterMutationBlockedCallback(self: *State) Error!MutationBlockedCallbackGuard {
        if (self.callback_depth != 0 or self.mutation_block_depth != 0)
            return error.CallbackReentrancy;
        self.callback_depth += 1;
        self.mutation_block_depth += 1;
        return .{ .state = self };
    }

    pub fn beginTransaction(self: *State) Error!TransactionGuard {
        if (self.current != .dispatching and self.current != .updating and self.current != .idle) {
            return error.FramePhaseViolation;
        }
        self.transaction_depth += 1;
        return .{ .state = self };
    }

    /// Marks the narrow component frame-hook interval. Frame hooks may poll
    /// renderer services and hand completed owned work to the task host, but
    /// ordinary retained build callbacks remain mutation-free.
    pub fn enterFrameCallback(self: *State) Error!FrameCallbackGuard {
        if (self.current != .composing or self.frame_callback_depth != 0)
            return error.FramePhaseViolation;
        self.frame_callback_depth += 1;
        return .{ .state = self };
    }

    pub const CallbackGuard = struct {
        state: *State,
        active: bool = true,

        pub fn deinit(self: *CallbackGuard) void {
            if (!self.active) return;
            self.active = false;
            self.state.callback_depth -= 1;
        }
    };

    pub const TransactionGuard = struct {
        state: *State,
        active: bool = true,

        pub fn deinit(self: *TransactionGuard) void {
            if (!self.active) return;
            self.active = false;
            self.state.transaction_depth -= 1;
        }
    };

    pub const MutationBlockedCallbackGuard = struct {
        state: *State,
        active: bool = true,

        pub fn deinit(self: *MutationBlockedCallbackGuard) void {
            if (!self.active) return;
            self.active = false;
            self.state.mutation_block_depth -= 1;
            self.state.callback_depth -= 1;
        }
    };

    pub const FrameCallbackGuard = struct {
        state: *State,
        active: bool = true,

        pub fn deinit(self: *FrameCallbackGuard) void {
            if (!self.active) return;
            self.active = false;
            self.state.frame_callback_depth -= 1;
        }
    };
};

fn isAllowed(current: Phase, next: Phase) bool {
    if (next == .shutting_down and current != .closed) return true;
    return switch (current) {
        .idle => next == .draining or next == .closed,
        .draining => next == .dispatching,
        .dispatching => next == .updating,
        .updating => next == .composing or next == .idle,
        .composing => next == .measuring,
        .measuring => next == .arranging,
        .arranging => next == .composing or next == .preparing,
        .preparing => next == .building_scene,
        .building_scene => next == .encoding,
        .encoding => next == .submitting,
        .submitting => next == .presenting,
        .presenting => next == .idle,
        .shutting_down => next == .closed,
        .closed => false,
    };
}
