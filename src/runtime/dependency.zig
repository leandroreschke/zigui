const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");

const StateEdges = struct {
    generation: u32 = 0,
    consumers: std.ArrayList(handles.ComponentId) = .empty,
};

const ComponentEdges = struct {
    generation: u32 = 0,
    states: std.ArrayList(handles.StateId) = .empty,
};

pub const Prepared = struct {
    owner: *Graph,
    component: handles.ComponentId,
    attempt: u64,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(StateEdges) = .empty,
    components: std.ArrayList(ComponentEdges) = .empty,
    maximum_states: usize,
    maximum_components: usize,
    maximum_edges: usize,
    edge_count: usize = 0,
    prepared_states: std.ArrayList(handles.StateId) = .empty,
    prepared_component: handles.ComponentId = .invalid,
    attempt_generation: u64 = 0,
    prepared_attempt: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Graph {
        return initWithLimits(allocator, 1_000_000, 131_072, 4_194_304);
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        maximum_states: usize,
        maximum_components: usize,
        maximum_edges: usize,
    ) Graph {
        return .{
            .allocator = allocator,
            .maximum_states = maximum_states,
            .maximum_components = maximum_components,
            .maximum_edges = maximum_edges,
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.states.items) |*edges| edges.consumers.deinit(self.allocator);
        for (self.components.items) |*edges| edges.states.deinit(self.allocator);
        self.prepared_states.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.components.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reserves every allocation required to replace one component's edges.
    /// The currently committed graph is not changed until `commitPrepared`.
    pub fn prepareComponent(
        self: *Graph,
        component: handles.ComponentId,
        next_states: []const handles.StateId,
    ) Error!Prepared {
        self.prepared_attempt = 0;
        self.prepared_component = .invalid;
        self.prepared_states.clearRetainingCapacity();
        var unique = std.AutoHashMap(u64, void).init(self.allocator);
        defer unique.deinit();
        for (next_states) |state| {
            if ((try unique.getOrPut(state.encode())).found_existing) return error.InvalidConfiguration;
        }
        const component_edges = try self.ensureComponent(component);
        const retained_edges = self.edge_count -| component_edges.states.items.len;
        if (next_states.len > self.maximum_edges -| retained_edges) return error.BudgetExceeded;
        try self.prepared_states.ensureTotalCapacity(self.allocator, next_states.len);
        try component_edges.states.ensureTotalCapacity(self.allocator, next_states.len);
        for (next_states) |state| _ = try self.ensureState(state);
        for (next_states) |state| {
            const state_edges = &self.states.items[state.index];
            if (!containsComponent(state_edges.consumers.items, component))
                try state_edges.consumers.ensureUnusedCapacity(self.allocator, 1);
        }
        self.prepared_states.appendSliceAssumeCapacity(next_states);
        self.attempt_generation +%= 1;
        if (self.attempt_generation == 0) self.attempt_generation = 1;
        self.prepared_attempt = self.attempt_generation;
        self.prepared_component = component;
        return .{ .owner = self, .component = component, .attempt = self.prepared_attempt };
    }

    /// Commits the exact replacement copied by `prepareComponent`.
    /// This function is allocation-free and therefore cannot expose a partial
    /// dependency graph to state invalidation.
    pub fn commitPrepared(self: *Graph, prepared: Prepared) Error!void {
        if (prepared.owner != self or prepared.attempt != self.prepared_attempt or
            !prepared.component.eql(self.prepared_component))
            return error.FramePhaseViolation;
        const component = self.prepared_component;
        const next_states = self.prepared_states.items;
        if (component.index >= self.components.items.len) return error.FramePhaseViolation;
        const component_edges = &self.components.items[component.index];
        if (component_edges.generation != component.generation or component_edges.states.capacity < next_states.len)
            return error.FramePhaseViolation;
        for (next_states) |state| {
            if (state.index >= self.states.items.len or self.states.items[state.index].generation != state.generation)
                return error.FramePhaseViolation;
            const state_edges = &self.states.items[state.index];
            if (!containsComponent(state_edges.consumers.items, component) and
                state_edges.consumers.items.len >= state_edges.consumers.capacity)
                return error.FramePhaseViolation;
        }
        const retained_edges = self.edge_count -| component_edges.states.items.len;
        if (next_states.len > self.maximum_edges -| retained_edges) return error.BudgetExceeded;
        for (component_edges.states.items) |state| {
            if (state.index >= self.states.items.len) continue;
            const state_edges = &self.states.items[state.index];
            if (state_edges.generation != state.generation) continue;
            removeComponentFrom(&state_edges.consumers, component);
        }
        component_edges.states.clearRetainingCapacity();
        component_edges.states.appendSliceAssumeCapacity(next_states);
        self.edge_count = retained_edges + next_states.len;
        for (next_states) |state| {
            const state_edges = &self.states.items[state.index];
            if (!containsComponent(state_edges.consumers.items, component))
                state_edges.consumers.appendAssumeCapacity(component);
        }
        self.prepared_attempt = 0;
        self.prepared_component = .invalid;
        self.prepared_states.clearRetainingCapacity();
    }

    pub fn discardPrepared(self: *Graph, prepared: Prepared) void {
        if (prepared.owner != self or prepared.attempt != self.prepared_attempt or
            !prepared.component.eql(self.prepared_component)) return;
        self.prepared_attempt = 0;
        self.prepared_component = .invalid;
        self.prepared_states.clearRetainingCapacity();
    }

    pub fn dependents(self: *const Graph, state: handles.StateId) []const handles.ComponentId {
        if (state.index >= self.states.items.len) return &.{};
        const edges = &self.states.items[state.index];
        if (edges.generation != state.generation) return &.{};
        return edges.consumers.items;
    }

    pub fn removeComponent(self: *Graph, component: handles.ComponentId) void {
        if (self.prepared_component.eql(component)) {
            self.prepared_attempt = 0;
            self.prepared_component = .invalid;
            self.prepared_states.clearRetainingCapacity();
        }
        if (component.index >= self.components.items.len) return;
        const component_edges = &self.components.items[component.index];
        if (component_edges.generation != component.generation) return;
        for (component_edges.states.items) |state| {
            if (state.index >= self.states.items.len) continue;
            const state_edges = &self.states.items[state.index];
            if (state_edges.generation != state.generation) continue;
            removeComponentFrom(&state_edges.consumers, component);
        }
        self.edge_count -|= component_edges.states.items.len;
        component_edges.states.clearRetainingCapacity();
        component_edges.generation = 0;
    }

    pub fn removeState(self: *Graph, state: handles.StateId) void {
        if (self.prepared_attempt != 0) {
            for (self.prepared_states.items) |prepared_state| {
                if (!prepared_state.eql(state)) continue;
                self.prepared_attempt = 0;
                self.prepared_component = .invalid;
                self.prepared_states.clearRetainingCapacity();
                break;
            }
        }
        if (state.index >= self.states.items.len) return;
        const state_edges = &self.states.items[state.index];
        if (state_edges.generation != state.generation) return;
        for (state_edges.consumers.items) |component| {
            if (component.index >= self.components.items.len) continue;
            const component_edges = &self.components.items[component.index];
            if (component_edges.generation != component.generation) continue;
            if (removeStateFrom(&component_edges.states, state)) self.edge_count -|= 1;
        }
        state_edges.consumers.clearRetainingCapacity();
        state_edges.generation = 0;
    }

    fn ensureState(self: *Graph, state: handles.StateId) Error!*StateEdges {
        if (!state.isValid() or state.index >= self.maximum_states) return error.InvalidHandle;
        while (self.states.items.len <= state.index) {
            try self.states.append(self.allocator, .{});
        }
        const edges = &self.states.items[state.index];
        if (edges.generation != state.generation) {
            if (edges.generation != 0) {
                const old_state = handles.StateId.init(state.index, edges.generation);
                for (edges.consumers.items) |component| {
                    if (component.index >= self.components.items.len) continue;
                    const component_edges = &self.components.items[component.index];
                    if (component_edges.generation != component.generation) continue;
                    if (removeStateFrom(&component_edges.states, old_state)) self.edge_count -|= 1;
                }
            }
            edges.consumers.clearRetainingCapacity();
            edges.generation = state.generation;
        }
        return edges;
    }

    fn ensureComponent(self: *Graph, component: handles.ComponentId) Error!*ComponentEdges {
        if (!component.isValid() or component.index >= self.maximum_components) return error.InvalidHandle;
        while (self.components.items.len <= component.index) {
            try self.components.append(self.allocator, .{});
        }
        const edges = &self.components.items[component.index];
        if (edges.generation != component.generation) {
            if (edges.generation != 0) {
                const old_component = handles.ComponentId.init(component.index, edges.generation);
                for (edges.states.items) |state| {
                    if (state.index >= self.states.items.len) continue;
                    const state_edges = &self.states.items[state.index];
                    if (state_edges.generation == state.generation)
                        removeComponentFrom(&state_edges.consumers, old_component);
                }
                self.edge_count -|= edges.states.items.len;
            }
            edges.states.clearRetainingCapacity();
            edges.generation = component.generation;
        }
        return edges;
    }
};

fn containsComponent(components: []const handles.ComponentId, target: handles.ComponentId) bool {
    for (components) |component| if (component.eql(target)) return true;
    return false;
}

fn removeComponentFrom(list: *std.ArrayList(handles.ComponentId), target: handles.ComponentId) void {
    for (list.items, 0..) |component, index| {
        if (!component.eql(target)) continue;
        _ = list.swapRemove(index);
        return;
    }
}

fn removeStateFrom(list: *std.ArrayList(handles.StateId), target: handles.StateId) bool {
    for (list.items, 0..) |state, index| {
        if (!state.eql(target)) continue;
        _ = list.swapRemove(index);
        return true;
    }
    return false;
}
