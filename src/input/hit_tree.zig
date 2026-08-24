const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const compose_store = @import("../compose/store.zig");
const compose_style = @import("../compose/style.zig");

pub const Entry = struct {
    node: handles.NodeId,
    parent_entry: ?u32,
    world_bounds: geometry.Rect,
    local_bounds: geometry.Rect,
    world_transform: geometry.Affine2D,
    inverse_transform: geometry.Affine2D,
    clip: ?geometry.Rect,
    radii: geometry.CornerRadii,
    pointer_events: compose_style.PointerEvents,
    disabled: bool,
    depth: u32,
};

pub const Hit = struct {
    target: handles.NodeId,
    entry_index: u32,
};

const Buffers = struct {
    entries: std.ArrayList(Entry) = .empty,
    node_to_entry: std.AutoHashMap(u64, u32),

    fn init(allocator: std.mem.Allocator) Buffers {
        return .{ .node_to_entry = std.AutoHashMap(u64, u32).init(allocator) };
    }

    fn deinit(self: *Buffers, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.node_to_entry.deinit();
        self.* = undefined;
    }

    fn clear(self: *Buffers) void {
        self.entries.clearRetainingCapacity();
        self.node_to_entry.clearRetainingCapacity();
    }
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    committed: Buffers,
    staging: Buffers,
    generation: u64 = 0,
    prepared: bool = false,
    maximum_entries: usize,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return initWithLimit(allocator, 1_000_000);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, maximum_entries: usize) Tree {
        return .{
            .allocator = allocator,
            .committed = Buffers.init(allocator),
            .staging = Buffers.init(allocator),
            .maximum_entries = maximum_entries,
        };
    }

    pub fn deinit(self: *Tree) void {
        self.committed.deinit(self.allocator);
        self.staging.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn rebuild(self: *Tree, nodes: *const compose_store.Store, root: handles.NodeId) Error!void {
        try self.prepare(nodes, root);
        try self.commitPrepared();
    }

    /// Builds the next hit tree without changing the tree used by input.
    pub fn prepare(self: *Tree, nodes: *const compose_store.Store, root: handles.NodeId) Error!void {
        self.prepared = false;
        self.staging.clear();
        var portals: std.ArrayList(PortalCandidate) = .empty;
        defer portals.deinit(self.allocator);
        try self.appendSubtree(&self.staging, nodes, root, null, .identity, null, 0, true, false, &portals);
        try self.appendPortalContext(&self.staging, nodes, portals.items);
        self.prepared = true;
    }

    /// Atomically publishes a tree produced by `prepare`.
    pub fn commitPrepared(self: *Tree) Error!void {
        if (!self.prepared) return error.FramePhaseViolation;
        std.mem.swap(Buffers, &self.committed, &self.staging);
        self.prepared = false;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }

    pub fn discardPrepared(self: *Tree) void {
        self.prepared = false;
    }

    pub fn hit(self: *const Tree, point: geometry.Point) ?Hit {
        var index = self.committed.entries.items.len;
        while (index != 0) {
            index -= 1;
            const entry = self.committed.entries.items[index];
            if (entry.pointer_events == .none or entry.pointer_events == .children_only or entry.disabled) continue;
            if (entry.clip) |clip| if (!clip.contains(point)) continue;
            if (!entry.world_bounds.contains(point)) continue;
            const local_point = entry.inverse_transform.transformPoint(point);
            if (!roundedRectContains(entry.local_bounds, entry.radii, local_point)) continue;
            return .{ .target = entry.node, .entry_index = @intCast(index) };
        }
        return null;
    }

    pub fn path(self: *const Tree, target: handles.NodeId, allocator: std.mem.Allocator) std.mem.Allocator.Error![]handles.NodeId {
        const entry_index = self.committed.node_to_entry.get(target.encode()) orelse return allocator.alloc(handles.NodeId, 0);
        var count: usize = 0;
        var cursor: ?u32 = entry_index;
        while (cursor) |value| {
            count += 1;
            cursor = self.committed.entries.items[value].parent_entry;
        }
        const result = try allocator.alloc(handles.NodeId, count);
        cursor = entry_index;
        var write = count;
        while (cursor) |value| {
            write -= 1;
            result[write] = self.committed.entries.items[value].node;
            cursor = self.committed.entries.items[value].parent_entry;
        }
        return result;
    }

    pub fn visualEntry(self: *const Tree, node: handles.NodeId) ?Entry {
        const index = self.committed.node_to_entry.get(node.encode()) orelse return null;
        if (@as(usize, index) >= self.committed.entries.items.len) return null;
        return self.committed.entries.items[index];
    }

    fn appendSubtree(
        self: *Tree,
        buffers: *Buffers,
        nodes: *const compose_store.Store,
        id: handles.NodeId,
        parent_entry: ?u32,
        parent_transform: geometry.Affine2D,
        inherited_clip: ?geometry.Rect,
        depth: u32,
        ancestors_allow_children: bool,
        portal_root: bool,
        portals: *std.ArrayList(PortalCandidate),
    ) Error!void {
        const record = nodes.getConst(id) orelse return;
        const borrowed = record.borrowedStyle();
        if (borrowed.layout.display == .none or !ancestors_allow_children) return;
        if (borrowed.layout.portal.target != .none and !portal_root) {
            try portals.append(self.allocator, .{
                .id = id,
                .parent_entry = parent_entry,
                .depth = depth,
                .ancestors_allow_children = ancestors_allow_children,
                .order = borrowed.layout.portal.order,
                .sequence = portals.items.len,
            });
            return;
        }

        const local_transform = borrowed.paint.transform.around(record.layout.bounds.origin);
        const world_transform = geometry.Affine2D.mul(parent_transform, local_transform);
        const inverse = world_transform.inverse() orelse return;
        const world_bounds = world_transform.transformRectBounds(record.layout.bounds);
        var clip = inherited_clip;
        const clips_children = borrowed.layout.overflow_x == .hidden or borrowed.layout.overflow_x == .clip or borrowed.layout.overflow_x == .scroll or
            borrowed.layout.overflow_y == .hidden or borrowed.layout.overflow_y == .clip or borrowed.layout.overflow_y == .scroll or
            borrowed.interaction.clips_hit_testing;
        if (clips_children) {
            clip = if (clip) |existing| geometry.Rect.intersection(existing, world_bounds) else world_bounds;
            if (clip == null) return;
        }

        if (buffers.entries.items.len >= self.maximum_entries) return error.BudgetExceeded;
        const current_index: u32 = @intCast(buffers.entries.items.len);
        try buffers.entries.append(self.allocator, .{
            .node = id,
            .parent_entry = parent_entry,
            .world_bounds = world_bounds,
            .local_bounds = record.layout.bounds,
            .world_transform = world_transform,
            .inverse_transform = inverse,
            .clip = inherited_clip,
            .radii = borrowed.paint.radii,
            .pointer_events = borrowed.interaction.pointer_events,
            .disabled = borrowed.interaction.disabled,
            .depth = depth,
        });
        try buffers.node_to_entry.put(id.encode(), current_index);

        const allow_children = borrowed.interaction.pointer_events != .none and borrowed.interaction.pointer_events != .box_only;
        var child_transform = world_transform;
        switch (record.kind) {
            .scroll => |scroll| child_transform = geometry.Affine2D.mul(world_transform, geometry.Affine2D.translation(.{
                .x = -scroll.offset_x,
                .y = -scroll.offset_y,
            })),
            else => {},
        }
        for (record.children.items) |child| {
            try self.appendSubtree(buffers, nodes, child, current_index, child_transform, clip, depth + 1, allow_children, false, portals);
        }
    }

    fn appendPortalContext(
        self: *Tree,
        buffers: *Buffers,
        nodes: *const compose_store.Store,
        source: []PortalCandidate,
    ) Error!void {
        if (source.len == 0) return;
        const ordered = try self.allocator.dupe(PortalCandidate, source);
        defer self.allocator.free(ordered);
        std.mem.sort(PortalCandidate, ordered, {}, PortalCandidate.lessThan);
        for (ordered) |candidate| {
            var nested: std.ArrayList(PortalCandidate) = .empty;
            defer nested.deinit(self.allocator);
            try self.appendSubtree(
                buffers,
                nodes,
                candidate.id,
                candidate.parent_entry,
                .identity,
                null,
                candidate.depth,
                candidate.ancestors_allow_children,
                true,
                &nested,
            );
            try self.appendPortalContext(buffers, nodes, nested.items);
        }
    }
};

const PortalCandidate = struct {
    id: handles.NodeId,
    parent_entry: ?u32,
    depth: u32,
    ancestors_allow_children: bool,
    order: i32,
    sequence: usize,

    fn lessThan(_: void, left: PortalCandidate, right: PortalCandidate) bool {
        if (left.order != right.order) return left.order < right.order;
        return left.sequence < right.sequence;
    }
};

fn roundedRectContains(rect: geometry.Rect, radii: geometry.CornerRadii, point: geometry.Point) bool {
    if (!rect.contains(point)) return false;
    const maximum_radius = @max(0, @min(rect.size.width, rect.size.height) / 2);
    const top_left = @min(radii.top_left, maximum_radius);
    const top_right = @min(radii.top_right, maximum_radius);
    const bottom_right = @min(radii.bottom_right, maximum_radius);
    const bottom_left = @min(radii.bottom_left, maximum_radius);
    if (point.x < rect.minX() + top_left and point.y < rect.minY() + top_left)
        return inCircle(point, .{ .x = rect.minX() + top_left, .y = rect.minY() + top_left }, top_left);
    if (point.x > rect.maxX() - top_right and point.y < rect.minY() + top_right)
        return inCircle(point, .{ .x = rect.maxX() - top_right, .y = rect.minY() + top_right }, top_right);
    if (point.x > rect.maxX() - bottom_right and point.y > rect.maxY() - bottom_right)
        return inCircle(point, .{ .x = rect.maxX() - bottom_right, .y = rect.maxY() - bottom_right }, bottom_right);
    if (point.x < rect.minX() + bottom_left and point.y > rect.maxY() - bottom_left)
        return inCircle(point, .{ .x = rect.minX() + bottom_left, .y = rect.maxY() - bottom_left }, bottom_left);
    return true;
}

fn inCircle(point: geometry.Point, center: geometry.Point, radius: f32) bool {
    if (radius <= 0) return true;
    const x = point.x - center.x;
    const y = point.y - center.y;
    return x * x + y * y <= radius * radius;
}
