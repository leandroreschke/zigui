const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const metrics = @import("../core/metrics.zig");
const layout = @import("../layout/style.zig");
const dependency = @import("dependency.zig");

const ComponentRecord = struct {
    generation: u32 = 0,
    window: handles.WindowId = .invalid,
    dirty: layout.Dirty = .{},
    /// Work removed from `dirty` while a composition is being built. It is
    /// only discarded after the frame commits; a later render failure puts it
    /// back so a partially built retained tree can never acknowledge work it
    /// did not present.
    in_flight: layout.Dirty = noDirty(),
    registered: bool = false,
};

const WindowRecord = struct {
    generation: u32 = 0,
    version: u64 = 0,
    dirty: layout.Dirty = noDirty(),
    registered: bool = false,
};

fn noDirty() layout.Dirty {
    return .{
        .compose = false,
        .layout = false,
        .paint = false,
        .hit_test = false,
        .semantics = false,
        .resources = false,
    };
}

/// The work required to publish one frame. The dependency expansion is kept
/// in ZigUI so consumers can request a narrow invalidation without having to
/// know which retained-tree phases must follow it.
pub const PhasePlan = packed struct {
    compose: bool = false,
    layout: bool = false,
    prepare: bool = false,
    scene: bool = false,
    hit_test: bool = false,
    focus: bool = false,
    semantics: bool = false,
    resources: bool = false,
    submit: bool = false,

    pub fn fromDirty(dirty: layout.Dirty) PhasePlan {
        if (dirty.compose) return .{
            .compose = true,
            .layout = true,
            .prepare = true,
            .scene = true,
            .hit_test = true,
            .focus = true,
            .semantics = true,
            .resources = true,
            .submit = true,
        };

        var plan: PhasePlan = .{};
        plan.layout = dirty.layout;
        plan.prepare = dirty.layout or dirty.resources;
        plan.scene = dirty.layout or dirty.paint or dirty.resources;
        plan.hit_test = dirty.layout or dirty.hit_test;
        plan.focus = dirty.layout;
        plan.semantics = dirty.layout or dirty.semantics;
        plan.resources = dirty.resources;
        // Every acknowledged window invalidation must publish a frame, even
        // when only the hit or semantics snapshot changes and the committed
        // scene can be reused.
        plan.submit = dirty.any();
        return plan;
    }

    pub fn any(self: PhasePlan) bool {
        return self.submit;
    }

    /// Converts a plan back to the narrowest public invalidation that can
    /// reproduce it. This is used when presentation is rejected/occluded so
    /// retrying the frame does not silently escalate a paint-only animation
    /// into full composition work.
    pub fn toDirty(self: PhasePlan) layout.Dirty {
        if (self.compose) return .{};
        return .{
            .compose = false,
            .layout = self.layout,
            .paint = self.scene and !self.layout,
            .hit_test = self.hit_test and !self.layout,
            .semantics = self.semantics and !self.layout,
            .resources = self.resources,
        };
    }
};

/// Allocation is confined to component/window registration. All hot-path
/// invalidation operations are infallible and allocation-free, including the
/// state-change callback invoked when a WriteGuard commits.
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    components: std.ArrayList(ComponentRecord) = .empty,
    windows: std.ArrayList(WindowRecord) = .empty,
    counters: *metrics.Counters,
    maximum_components: usize,
    maximum_windows: usize,

    pub fn init(allocator: std.mem.Allocator, counters: *metrics.Counters) Tracker {
        return initWithLimits(allocator, counters, 131_072, 256);
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        counters: *metrics.Counters,
        maximum_components: usize,
        maximum_windows: usize,
    ) Tracker {
        return .{
            .allocator = allocator,
            .counters = counters,
            .maximum_components = maximum_components,
            .maximum_windows = maximum_windows,
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.components.deinit(self.allocator);
        self.windows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(
        self: *Tracker,
        component: handles.ComponentId,
        window: handles.WindowId,
    ) Error!void {
        if (!component.isValid() or !window.isValid() or component.index >= self.maximum_components or
            window.index >= self.maximum_windows)
            return error.InvalidHandle;
        while (self.components.items.len <= component.index) {
            try self.components.append(self.allocator, .{});
        }
        try self.ensureWindow(window);
        self.components.items[component.index] = .{
            .generation = component.generation,
            .window = window,
            .dirty = .{},
            .in_flight = noDirty(),
            .registered = true,
        };
        _ = self.markWindow(window);
    }

    pub fn unregister(self: *Tracker, component: handles.ComponentId) void {
        if (component.index >= self.components.items.len) return;
        const record = &self.components.items[component.index];
        if (record.generation != component.generation) return;
        record.* = .{};
    }

    pub fn unregisterWindow(self: *Tracker, window: handles.WindowId) void {
        if (window.index >= self.windows.items.len) return;
        const record = &self.windows.items[window.index];
        if (record.generation != window.generation) return;
        record.* = .{};
    }

    pub fn markComponent(
        self: *Tracker,
        component: handles.ComponentId,
        dirty: layout.Dirty,
    ) bool {
        if (component.index >= self.components.items.len) return false;
        const record = &self.components.items[component.index];
        if (!record.registered or record.generation != component.generation) return false;
        _ = dirty;
        // Ordinary component invalidation is intentionally conservative.
        // Existing component builders may derive retained children, layout,
        // hit targets, or semantics from a value even when a caller labels it
        // `paint`; only the display-frame hook path below is authorized to
        // publish a paint-only component update.
        const effective_dirty: layout.Dirty = .{};
        const was_dirty = record.dirty.any();
        record.dirty.merge(effective_dirty);
        self.counters.invalidations +|= 1;
        if (was_dirty) self.counters.coalesced_invalidations +|= 1;
        _ = self.markWindowDirty(record.window, effective_dirty);
        return !was_dirty;
    }

    /// Applies an explicit invalidation raised by a handled custom-element
    /// event. Unlike ordinary component invalidation, this preserves the
    /// caller's phase mask; `PhasePlan.fromDirty` expands only the dependent
    /// work needed to publish the requested change.
    pub fn markComponentNarrow(
        self: *Tracker,
        component: handles.ComponentId,
        dirty: layout.Dirty,
    ) bool {
        if (component.index >= self.components.items.len) return false;
        const record = &self.components.items[component.index];
        if (!record.registered or record.generation != component.generation or !dirty.any()) return false;
        const was_dirty = record.dirty.any();
        record.dirty.merge(dirty);
        self.counters.invalidations +|= 1;
        if (was_dirty) self.counters.coalesced_invalidations +|= 1;
        _ = self.markWindowDirty(record.window, dirty);
        return !was_dirty;
    }

    /// Marks component work that will be consumed by the frame already in
    /// progress. Unlike an external invalidation, this does not advance the
    /// window token and therefore does not schedule a redundant settling
    /// frame after a display-driven hook reaches its final state.
    pub fn markComponentDuringFrame(
        self: *Tracker,
        component: handles.ComponentId,
        dirty: layout.Dirty,
    ) bool {
        if (component.index >= self.components.items.len) return false;
        const record = &self.components.items[component.index];
        if (!record.registered or record.generation != component.generation) return false;
        const was_dirty = record.dirty.any();
        record.dirty.merge(dirty);
        self.counters.invalidations +|= 1;
        if (was_dirty) self.counters.coalesced_invalidations +|= 1;
        _ = self.markWindowDuringFrame(record.window, dirty);
        return !was_dirty;
    }

    pub fn markState(
        self: *Tracker,
        graph: *const dependency.Graph,
        state: handles.StateId,
        dirty: layout.Dirty,
    ) usize {
        var count: usize = 0;
        for (graph.dependents(state)) |component| {
            if (self.markComponent(component, dirty)) count += 1;
        }
        return count;
    }

    pub fn markWindow(self: *Tracker, window: handles.WindowId) bool {
        return self.markWindowDirty(window, .{});
    }

    /// Marks a window with only the work that changed. A zero-valued
    /// `layout.Dirty` is intentionally not a no-op here: its defaults mean a
    /// conservative full invalidation, matching the pre-phase-gating API.
    pub fn markWindowDirty(self: *Tracker, window: handles.WindowId, dirty: layout.Dirty) bool {
        if (window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation) return false;
        const was_dirty = record.dirty.any();
        record.dirty.merge(dirty);
        record.version +%= 1;
        if (record.version == 0) record.version = 1;
        return !was_dirty;
    }

    /// Merges work raised by a display-driven frame hook without advancing the
    /// frame token captured before the hook ran. The current frame observes
    /// the merged plan; no redundant acknowledgement frame is created.
    pub fn markWindowDuringFrame(self: *Tracker, window: handles.WindowId, dirty: layout.Dirty) bool {
        if (window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation) return false;
        const was_dirty = record.dirty.any();
        record.dirty.merge(dirty);
        return !was_dirty;
    }

    pub fn windowDirty(self: *const Tracker, window: handles.WindowId) ?layout.Dirty {
        if (window.index >= self.windows.items.len) return null;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation or !record.dirty.any()) return null;
        return record.dirty;
    }

    /// Begins a component composition transaction. New invalidations raised
    /// while the build executes remain in `dirty` and are therefore preserved
    /// independently from the work currently being attempted.
    pub fn beginComponent(self: *Tracker, component: handles.ComponentId) ?layout.Dirty {
        if (component.index >= self.components.items.len) return null;
        const record = &self.components.items[component.index];
        if (!record.registered or record.generation != component.generation or
            !record.dirty.any()) return null;
        const dirty = record.dirty;
        record.dirty = noDirty();
        record.in_flight.merge(dirty);
        return dirty;
    }

    /// Completes all component compositions for one window. On failure, the
    /// in-flight masks are merged back into the pending masks. This method is
    /// deliberately window-scoped so App can install one defer at the start
    /// of renderWindow and cover errors from every later phase.
    pub fn finishWindowComposition(self: *Tracker, window: handles.WindowId, committed: bool) void {
        for (self.components.items) |*record| {
            if (!record.registered or !record.window.eql(window) or !record.in_flight.any()) continue;
            if (!committed) record.dirty.merge(record.in_flight);
            record.in_flight = noDirty();
        }
    }

    pub fn consumeComponent(self: *Tracker, component: handles.ComponentId) ?layout.Dirty {
        if (component.index >= self.components.items.len) return null;
        const record = &self.components.items[component.index];
        if (!record.registered or record.generation != component.generation) return null;
        const dirty = record.dirty;
        record.dirty = noDirty();
        return dirty;
    }

    pub fn isWindowDirty(self: *const Tracker, window: handles.WindowId) bool {
        if (window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        return record.registered and record.generation == window.generation and record.dirty.any();
    }

    pub fn consumeWindow(self: *Tracker, window: handles.WindowId) bool {
        if (window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation) return false;
        const was_dirty = record.dirty.any();
        record.dirty = noDirty();
        return was_dirty;
    }

    /// Captures the exact dirty generation a frame is about to process. Every
    /// mark advances the version even when the window was already dirty, so a
    /// callback or retained hook that invalidates during the frame cannot have
    /// its work accidentally acknowledged by that older frame.
    pub fn windowToken(self: *const Tracker, window: handles.WindowId) ?u64 {
        if (window.index >= self.windows.items.len) return null;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation or !record.dirty.any())
            return null;
        return record.version;
    }

    pub fn consumeWindowToken(self: *Tracker, window: handles.WindowId, token: u64) bool {
        if (token == 0 or window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation or
            !record.dirty.any() or record.version != token)
            return false;
        record.dirty = noDirty();
        return true;
    }

    fn ensureWindow(self: *Tracker, window: handles.WindowId) Error!void {
        if (!window.isValid() or window.index >= self.maximum_windows) return error.InvalidHandle;
        while (self.windows.items.len <= window.index) {
            try self.windows.append(self.allocator, .{});
        }
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation) {
            record.* = .{ .generation = window.generation, .registered = true };
        }
    }
};
