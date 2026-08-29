const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const appearance = @import("../core/appearance.zig");
const node = @import("node.zig");
const store = @import("store.zig");
const runtime = @import("../runtime/coordinator.zig");
const state = @import("../runtime/state.zig");

pub const BuildContext = struct {
    allocator: std.mem.Allocator,
    /// Resolved system appearance for the window being composed. ZigUI does
    /// not prescribe a product palette; consumers map this value themselves.
    appearance: appearance.Appearance = .system,
    coordinator: *runtime.Coordinator,
    components: *Store,
    component: handles.ComponentId,
    window: handles.WindowId,
    dependencies: runtime.Coordinator.DependencyRecorder,

    pub fn readState(self: *BuildContext, comptime T: type, handle: state.Handle(T)) Error!*const T {
        var recorder = &self.dependencies;
        return self.coordinator.states.read(T, handle, recorder.sink());
    }

    pub fn createState(self: *BuildContext, comptime T: type, initial: T) Error!state.Handle(T) {
        return self.coordinator.states.create(T, self.component, initial);
    }

    pub fn beginStateWrite(self: *BuildContext, comptime T: type, handle: state.Handle(T)) Error!state.WriteGuard(T) {
        return self.coordinator.states.beginWrite(T, handle);
    }

    /// Creates a retained child component once and returns a component node on
    /// every subsequent build. `slot` belongs to the parent model and must be
    /// initialized to `.invalid`. The child is owned by this component, is
    /// suspended while absent from the retained tree, and is destroyed with
    /// its parent.
    pub fn childComponent(
        self: *BuildContext,
        slot: *handles.ComponentId,
        descriptor: Descriptor,
    ) Error!node.Spec {
        if (!slot.isValid() or !self.components.contains(slot.*)) {
            slot.* = try self.components.createChild(descriptor, self.window, self.component);
        } else if (!self.components.isChildOf(slot.*, self.component)) {
            return error.InvalidHandle;
        }
        return .{ .kind = .{ .component = slot.* } };
    }
};

pub const Descriptor = struct {
    context: *anyopaque,
    build_fn: *const fn (*anyopaque, *BuildContext) Error!node.Spec,
    frame_fn: ?*const fn (*anyopaque, u64) Error!FrameUpdate = null,
    drop_fn: ?*const fn (*anyopaque) void = null,

    pub fn from(comptime T: type, value: *T) Descriptor {
        return .{
            .context = value,
            .build_fn = struct {
                fn build(context: *anyopaque, ctx: *BuildContext) Error!node.Spec {
                    const self: *T = @ptrCast(@alignCast(context));
                    return self.build(ctx);
                }
            }.build,
        };
    }

    /// Creates a component with an explicit display-driven frame hook. The
    /// hook runs before composition on frames already requested for its
    /// window, and may request another native display frame. Application
    /// easing and semantic state remain consumer-owned.
    pub fn fromWithFrame(comptime T: type, value: *T) Descriptor {
        if (!@hasDecl(T, "frame")) @compileError(@typeName(T) ++ " must declare frame");
        var descriptor = from(T, value);
        descriptor.frame_fn = struct {
            fn frame(context: *anyopaque, now_ns: u64) Error!FrameUpdate {
                const self: *T = @ptrCast(@alignCast(context));
                return self.frame(now_ns);
            }
        }.frame;
        return descriptor;
    }
};

/// Result of one display-driven component frame hook.
pub const FrameUpdate = struct {
    dirty: ?@import("../layout/style.zig").Dirty = null,
    request_next_frame: bool = false,
};

const Entry = struct {
    descriptor: Descriptor,
    window: handles.WindowId,
    parent: handles.ComponentId = .invalid,
    children: std.ArrayList(handles.ComponentId) = .empty,
    anchor: handles.NodeId = .invalid,
    root: handles.NodeId = .invalid,
    version: u64 = 1,
    registered: bool = false,
    seen_in_mount_pass: bool = false,
};

pub const Store = struct {
    const Pool = handles.SlotPool(Entry, handles.ComponentId);

    allocator: std.mem.Allocator,
    pool: Pool,
    frame_components: std.ArrayList(handles.ComponentId) = .empty,
    maximum_components: usize,

    pub fn init(allocator: std.mem.Allocator) Store {
        return initWithLimit(allocator, 131_072);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, maximum_components: usize) Store {
        return .{
            .allocator = allocator,
            .pool = Pool.init(allocator),
            .maximum_components = maximum_components,
        };
    }

    pub fn deinit(self: *Store) void {
        var component_iterator = self.pool.iterator();
        while (component_iterator.next()) |entry| {
            if (entry.value.descriptor.drop_fn) |drop| drop(entry.value.descriptor.context);
            entry.value.children.deinit(self.allocator);
        }
        self.frame_components.deinit(self.allocator);
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn create(
        self: *Store,
        descriptor: Descriptor,
        window: handles.WindowId,
    ) Error!handles.ComponentId {
        if (self.pool.live_count >= self.maximum_components) return error.BudgetExceeded;
        if (descriptor.frame_fn != null) try self.frame_components.ensureUnusedCapacity(self.allocator, 1);
        const id = try self.pool.insert(.{ .descriptor = descriptor, .window = window });
        if (descriptor.frame_fn != null) self.frame_components.appendAssumeCapacity(id);
        return id;
    }

    pub fn createChild(
        self: *Store,
        descriptor: Descriptor,
        window: handles.WindowId,
        parent: handles.ComponentId,
    ) Error!handles.ComponentId {
        if (self.pool.live_count >= self.maximum_components) return error.BudgetExceeded;
        const parent_entry = self.pool.get(parent) orelse return error.InvalidHandle;
        if (!parent_entry.window.eql(window)) return error.InvalidHandle;
        try parent_entry.children.ensureUnusedCapacity(self.allocator, 1);
        if (descriptor.frame_fn != null) try self.frame_components.ensureUnusedCapacity(self.allocator, 1);
        const id = try self.pool.insert(.{
            .descriptor = descriptor,
            .window = window,
            .parent = parent,
        });
        const refreshed_parent = self.pool.get(parent) orelse return error.InvalidHandle;
        refreshed_parent.children.appendAssumeCapacity(id);
        if (descriptor.frame_fn != null) self.frame_components.appendAssumeCapacity(id);
        return id;
    }

    pub fn contains(self: *const Store, id: handles.ComponentId) bool {
        return self.pool.contains(id);
    }

    pub fn isChildOf(self: *const Store, id: handles.ComponentId, parent: handles.ComponentId) bool {
        const entry = self.pool.getConst(id) orelse return false;
        return entry.parent.eql(parent);
    }

    pub fn destroy(
        self: *Store,
        id: handles.ComponentId,
        nodes: *store.Store,
        coordinator: *runtime.Coordinator,
    ) void {
        var entry = self.pool.remove(id) orelse return;
        removeComponent(&self.frame_components, id);
        if (entry.parent.isValid()) if (self.pool.get(entry.parent)) |parent| {
            removeComponent(&parent.children, id);
        };
        for (entry.children.items) |child| self.destroy(child, nodes, coordinator);
        entry.children.deinit(self.allocator);
        coordinator.dependencies.removeComponent(id);
        coordinator.invalidations.unregister(id);
        coordinator.tasks.cancelComponent(id);
        coordinator.states.destroyOwner(id);
        if (entry.root.isValid()) nodes.destroyTree(entry.root);
        if (entry.descriptor.drop_fn) |drop| drop(entry.descriptor.context);
    }

    pub fn attach(self: *Store, id: handles.ComponentId, anchor: handles.NodeId) Error!void {
        const entry = self.pool.get(id) orelse return error.InvalidHandle;
        entry.anchor = anchor;
        entry.seen_in_mount_pass = true;
    }

    pub fn mount(
        self: *Store,
        id: handles.ComponentId,
        anchor: handles.NodeId,
        owner: handles.ComponentId,
    ) Error!bool {
        const entry = self.pool.get(id) orelse return error.InvalidHandle;
        if (!entry.parent.eql(owner)) return error.InvalidHandle;
        entry.anchor = anchor;
        entry.seen_in_mount_pass = true;
        return !entry.registered;
    }

    pub fn beginMountPass(self: *Store, window: handles.WindowId, root_id: handles.ComponentId) void {
        var component_iterator = self.pool.iterator();
        while (component_iterator.next()) |entry| {
            if (!entry.value.window.eql(window)) continue;
            entry.value.seen_in_mount_pass = entry.id.eql(root_id);
        }
    }

    pub fn finishMountPass(
        self: *Store,
        window: handles.WindowId,
        root_id: handles.ComponentId,
        coordinator: *runtime.Coordinator,
    ) void {
        var component_iterator = self.pool.iterator();
        while (component_iterator.next()) |entry| {
            if (!entry.value.window.eql(window) or entry.id.eql(root_id) or
                entry.value.seen_in_mount_pass or !entry.value.registered) continue;
            entry.value.registered = false;
            entry.value.anchor = .invalid;
            entry.value.root = .invalid;
            coordinator.dependencies.removeComponent(entry.id);
            coordinator.invalidations.unregister(entry.id);
            coordinator.tasks.cancelComponent(entry.id);
        }
    }

    pub fn markRegistered(self: *Store, id: handles.ComponentId) Error!bool {
        const entry = self.pool.get(id) orelse return error.InvalidHandle;
        const was_registered = entry.registered;
        entry.registered = true;
        return !was_registered;
    }

    pub fn isRegistered(self: *const Store, id: handles.ComponentId) bool {
        const entry = self.pool.getConst(id) orelse return false;
        return entry.registered;
    }

    pub fn root(self: *const Store, id: handles.ComponentId) ?handles.NodeId {
        const entry = self.pool.getConst(id) orelse return null;
        return if (entry.root.isValid()) entry.root else null;
    }

    pub const EntryView = struct {
        id: handles.ComponentId,
        window: handles.WindowId,
        anchor: handles.NodeId,
        root: handles.NodeId,
        registered: bool,
    };

    pub const Iterator = struct {
        inner: Pool.Iterator,

        pub fn next(self: *Iterator) ?EntryView {
            const entry = self.inner.next() orelse return null;
            return .{
                .id = entry.id,
                .window = entry.value.window,
                .anchor = entry.value.anchor,
                .root = entry.value.root,
                .registered = entry.value.registered,
            };
        }
    };

    pub fn iterator(self: *Store) Iterator {
        return .{ .inner = self.pool.iterator() };
    }

    /// Advances only explicitly registered frame-driven components in the
    /// target window. The compact registry avoids scanning ordinary retained
    /// components on every display frame.
    pub fn updateFrame(
        self: *Store,
        window: handles.WindowId,
        now_ns: u64,
        coordinator: *runtime.Coordinator,
    ) Error!bool {
        var request_next = false;
        for (self.frame_components.items) |id| {
            const entry = self.pool.get(id) orelse continue;
            if (!entry.registered or !entry.window.eql(window)) continue;
            const callback = entry.descriptor.frame_fn orelse continue;
            var frame_guard = try coordinator.phase_state.enterFrameCallback();
            defer frame_guard.deinit();
            const update = try callback(entry.descriptor.context, now_ns);
            if (update.dirty) |dirty| {
                if (dirty.any()) _ = coordinator.invalidations.markComponentDuringFrame(id, dirty);
            }
            request_next = request_next or update.request_next_frame;
        }
        return request_next;
    }

    pub fn build(
        self: *Store,
        id: handles.ComponentId,
        nodes: *store.Store,
        coordinator: *runtime.Coordinator,
        scratch: std.mem.Allocator,
    ) Error!handles.NodeId {
        return self.buildWithAppearance(id, nodes, coordinator, scratch, .system);
    }

    pub fn buildWithAppearance(
        self: *Store,
        id: handles.ComponentId,
        nodes: *store.Store,
        coordinator: *runtime.Coordinator,
        scratch: std.mem.Allocator,
        appearance_value: appearance.Appearance,
    ) Error!handles.NodeId {
        const initial = self.pool.getConst(id) orelse return error.InvalidHandle;
        if (!initial.anchor.isValid()) return error.InvalidHandle;
        try nodes.reserveChildren(initial.anchor, 1);
        const descriptor = initial.descriptor;
        const window = initial.window;
        var context: BuildContext = .{
            .allocator = scratch,
            .appearance = appearance_value,
            .coordinator = coordinator,
            .components = self,
            .component = id,
            .window = window,
            .dependencies = try coordinator.beginComponentDependencies(id, scratch),
        };
        defer context.dependencies.deinit();
        const spec = try descriptor.build_fn(descriptor.context, &context);
        try context.dependencies.prepare();
        const entry = self.pool.get(id) orelse return error.InvalidHandle;
        const key = spec.key orelse node.automaticKey(id.encode(), 0, spec.kind);
        const existing = if (entry.root.isValid()) entry.root else null;
        const root_node = try nodes.reconcile(existing, entry.anchor, id, spec, key, scratch);
        try nodes.setSingleChild(entry.anchor, root_node);
        try context.dependencies.commit();
        entry.root = root_node;
        entry.version +%= 1;
        if (entry.version == 0) entry.version = 1;
        return root_node;
    }

    pub fn getWindow(self: *const Store, id: handles.ComponentId) ?handles.WindowId {
        const entry = self.pool.getConst(id) orelse return null;
        return entry.window;
    }
};

fn removeComponent(list: *std.ArrayList(handles.ComponentId), target: handles.ComponentId) void {
    for (list.items, 0..) |id, index| {
        if (!id.eql(target)) continue;
        _ = list.swapRemove(index);
        return;
    }
}
