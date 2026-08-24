const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const metrics = @import("../core/metrics.zig");
const layout = @import("../layout/style.zig");
const dependency = @import("dependency.zig");
const effect = @import("effect.zig");
const invalidation = @import("invalidation.zig");
const phase = @import("phase.zig");
const state = @import("state.zig");
const task = @import("task.zig");
const ThreadAffinity = @import("thread_affinity.zig").ThreadAffinity;

pub const Coordinator = struct {
    pub const Limits = struct {
        maximum_states: usize = 1_000_000,
        maximum_components: usize = 131_072,
        maximum_windows: usize = 256,
        maximum_dependency_edges: usize = 4_194_304,
        maximum_effects: usize = 65_536,
        maximum_tasks: usize = 4_096,
    };

    allocator: std.mem.Allocator,
    affinity: ThreadAffinity,
    phase_state: phase.State = .{},
    counters: metrics.Counters = .{},
    states: state.Store,
    dependencies: dependency.Graph,
    effects: effect.Queue,
    invalidations: invalidation.Tracker,
    tasks: task.Registry,
    bound: bool = false,

    pub fn init(allocator: std.mem.Allocator) Coordinator {
        return initWithLimits(allocator, .{});
    }

    pub fn initWithStateLimit(allocator: std.mem.Allocator, maximum_states: usize) Coordinator {
        return initWithLimits(allocator, .{ .maximum_states = maximum_states });
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) Coordinator {
        return .{
            .allocator = allocator,
            .affinity = ThreadAffinity.capture(),
            .states = state.Store.initWithLimit(allocator, limits.maximum_states),
            .dependencies = dependency.Graph.initWithLimits(
                allocator,
                limits.maximum_states,
                limits.maximum_components,
                limits.maximum_dependency_edges,
            ),
            .effects = effect.Queue.initWithLimit(allocator, limits.maximum_effects),
            .invalidations = invalidation.Tracker.initWithLimits(
                allocator,
                undefined,
                limits.maximum_components,
                limits.maximum_windows,
            ),
            .tasks = task.Registry.initWithLimit(allocator, limits.maximum_tasks),
        };
    }

    pub fn bind(self: *Coordinator) Error!void {
        if (self.bound) return error.ResourceBusy;
        self.invalidations.counters = &self.counters;
        self.states.setChangeSink(.{ .context = self, .changed_fn = stateChanged });
        self.states.setLifecycleSink(.{ .context = self, .destroyed_fn = stateDestroyed });
        self.bound = true;
    }

    pub fn deinit(self: *Coordinator) Error!void {
        try self.affinity.assertCurrent();
        self.tasks.deinit();
        self.invalidations.deinit();
        self.effects.deinit();
        self.dependencies.deinit();
        self.states.deinit();
        self.* = undefined;
    }

    pub fn beginUpdate(self: *Coordinator) Error!Update {
        try self.affinity.assertCurrent();
        const previous = self.phase_state.current;
        if (previous == .idle) try self.phase_state.transition(.draining);
        if (self.phase_state.current == .draining) try self.phase_state.transition(.dispatching);
        if (self.phase_state.current == .dispatching) try self.phase_state.transition(.updating);
        const transaction = try self.phase_state.beginTransaction();
        return .{ .coordinator = self, .transaction = transaction, .previous = previous };
    }

    pub fn beginComponentDependencies(
        self: *Coordinator,
        component: handles.ComponentId,
        scratch: std.mem.Allocator,
    ) Error!DependencyRecorder {
        try self.affinity.assertCurrent();
        return .{
            .coordinator = self,
            .component = component,
            .scratch = scratch,
            .seen = std.AutoHashMap(u64, void).init(scratch),
        };
    }

    pub fn deferEffect(self: *Coordinator, deferred: effect.Deferred) Error!void {
        try self.effects.push(.{ .deferred = deferred });
    }

    pub fn invalidateComponent(
        self: *Coordinator,
        component: handles.ComponentId,
        dirty: layout.Dirty,
    ) Error!void {
        try self.affinity.assertCurrent();
        _ = self.invalidations.markComponent(component, dirty);
    }

    pub fn flushEffects(self: *Coordinator) Error!void {
        try self.affinity.assertCurrent();
        while (self.effects.next()) |queued| {
            switch (queued) {
                .deferred => |deferred| {
                    deferred.run();
                    deferred.drop();
                },
            }
        }
        try self.effects.reset();
    }

    pub const Update = struct {
        coordinator: *Coordinator,
        transaction: phase.State.TransactionGuard,
        previous: phase.Phase,
        active: bool = true,

        pub fn deinit(self: *Update) Error!void {
            if (!self.active) return;
            self.active = false;
            self.transaction.deinit();
            if (self.coordinator.phase_state.transaction_depth == 0 and
                self.coordinator.phase_state.callback_depth == 0)
                try self.coordinator.flushEffects();
            if (self.previous == .idle) {
                self.coordinator.phase_state.current = .idle;
            }
        }
    };

    pub const DependencyRecorder = struct {
        coordinator: *Coordinator,
        component: handles.ComponentId,
        scratch: std.mem.Allocator,
        states: std.ArrayList(handles.StateId) = .empty,
        seen: std.AutoHashMap(u64, void),
        failure: ?Error = null,
        prepared: ?dependency.Prepared = null,

        pub fn deinit(self: *DependencyRecorder) void {
            if (self.prepared) |prepared| self.coordinator.dependencies.discardPrepared(prepared);
            self.states.deinit(self.scratch);
            self.seen.deinit();
            self.* = undefined;
        }

        pub fn sink(self: *DependencyRecorder) state.DependencySink {
            return .{ .context = self, .record_fn = record };
        }

        fn record(context: *anyopaque, id: handles.StateId, version: u64) void {
            _ = version;
            const self: *DependencyRecorder = @ptrCast(@alignCast(context));
            if (self.failure != null) return;
            const seen = self.seen.getOrPut(id.encode()) catch |err| {
                self.failure = err;
                self.coordinator.counters.dropped_events +|= 1;
                return;
            };
            if (seen.found_existing) return;
            self.states.append(self.scratch, id) catch |err| {
                self.failure = err;
                self.coordinator.counters.dropped_events +|= 1;
            };
        }

        pub fn prepare(self: *DependencyRecorder) Error!void {
            if (self.failure) |failure| return failure;
            if (self.prepared != null) return error.FramePhaseViolation;
            self.prepared = try self.coordinator.dependencies.prepareComponent(self.component, self.states.items);
        }

        pub fn commit(self: *DependencyRecorder) Error!void {
            const prepared = self.prepared orelse return error.FramePhaseViolation;
            try self.coordinator.dependencies.commitPrepared(prepared);
            self.prepared = null;
        }

        pub fn finish(self: *DependencyRecorder) Error!void {
            try self.prepare();
            try self.commit();
        }
    };

    fn stateChanged(context: *anyopaque, id: handles.StateId, version: u64) void {
        _ = version;
        const self: *Coordinator = @ptrCast(@alignCast(context));
        _ = self.invalidations.markState(&self.dependencies, id, .{});
    }

    fn stateDestroyed(context: *anyopaque, id: handles.StateId) void {
        const self: *Coordinator = @ptrCast(@alignCast(context));
        _ = self.invalidations.markState(&self.dependencies, id, .{});
        self.dependencies.removeState(id);
    }
};
