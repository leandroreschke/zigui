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
    registered: bool = false,
};

const WindowRecord = struct {
    generation: u32 = 0,
    version: u64 = 0,
    dirty: bool = false,
    registered: bool = false,
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
        const was_dirty = record.dirty.any();
        record.dirty.merge(dirty);
        self.counters.invalidations +|= 1;
        if (was_dirty) self.counters.coalesced_invalidations +|= 1;
        _ = self.markWindow(record.window);
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
        if (window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation) return false;
        const was_dirty = record.dirty;
        record.dirty = true;
        record.version +%= 1;
        if (record.version == 0) record.version = 1;
        return !was_dirty;
    }

    pub fn consumeComponent(self: *Tracker, component: handles.ComponentId) ?layout.Dirty {
        if (component.index >= self.components.items.len) return null;
        const record = &self.components.items[component.index];
        if (!record.registered or record.generation != component.generation) return null;
        const dirty = record.dirty;
        record.dirty = .{
            .compose = false,
            .layout = false,
            .paint = false,
            .hit_test = false,
            .semantics = false,
            .resources = false,
        };
        return dirty;
    }

    pub fn isWindowDirty(self: *const Tracker, window: handles.WindowId) bool {
        if (window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        return record.registered and record.generation == window.generation and record.dirty;
    }

    pub fn consumeWindow(self: *Tracker, window: handles.WindowId) bool {
        if (window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation) return false;
        const was_dirty = record.dirty;
        record.dirty = false;
        return was_dirty;
    }

    /// Captures the exact dirty generation a frame is about to process. Every
    /// mark advances the version even when the window was already dirty, so a
    /// callback or retained hook that invalidates during the frame cannot have
    /// its work accidentally acknowledged by that older frame.
    pub fn windowToken(self: *const Tracker, window: handles.WindowId) ?u64 {
        if (window.index >= self.windows.items.len) return null;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation or !record.dirty)
            return null;
        return record.version;
    }

    pub fn consumeWindowToken(self: *Tracker, window: handles.WindowId, token: u64) bool {
        if (token == 0 or window.index >= self.windows.items.len) return false;
        const record = &self.windows.items[window.index];
        if (!record.registered or record.generation != window.generation or
            !record.dirty or record.version != token)
            return false;
        record.dirty = false;
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
