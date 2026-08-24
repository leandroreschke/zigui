const std = @import("std");
const a11y = @import("../a11y/api.zig");
const core_config = @import("../core/config.zig");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const input = @import("../input/event.zig");
const action = @import("../input/action.zig");
const layout = @import("../layout/style.zig");
const custom = @import("custom.zig");
const node = @import("node.zig");
const style = @import("style.zig");
const text = @import("../text/api.zig");

const OwnedLayout = struct {
    value: layout.LayoutStyle,
    columns: []layout.GridTrack = &.{},
    rows: []layout.GridTrack = &.{},

    fn init(allocator: std.mem.Allocator, source: layout.LayoutStyle) std.mem.Allocator.Error!OwnedLayout {
        var result: OwnedLayout = .{ .value = source };
        errdefer result.deinit(allocator);
        if (source.grid_columns.len != 0) {
            result.columns = try allocator.dupe(layout.GridTrack, source.grid_columns);
            result.value.grid_columns = result.columns;
        }
        if (source.grid_rows.len != 0) {
            result.rows = try allocator.dupe(layout.GridTrack, source.grid_rows);
            result.value.grid_rows = result.rows;
        }
        return result;
    }

    fn deinit(self: *OwnedLayout, allocator: std.mem.Allocator) void {
        if (self.columns.len != 0) allocator.free(self.columns);
        if (self.rows.len != 0) allocator.free(self.rows);
        self.* = undefined;
    }
};

const OwnedTextStyle = struct {
    value: style.TextStyle,
    families: [][]const u8 = &.{},
    variations: []text.FontVariation = &.{},

    fn init(allocator: std.mem.Allocator, source: style.TextStyle) Error!OwnedTextStyle {
        var result: OwnedTextStyle = .{ .value = source };
        errdefer result.deinit(allocator);
        if (source.font_families.len != 0) {
            result.families = try allocator.alloc([]const u8, source.font_families.len);
            for (result.families) |*family| family.* = &.{};
            for (source.font_families, 0..) |family, index| {
                if (family.len == 0 or !validText(family, false)) return error.InvalidConfiguration;
                result.families[index] = try allocator.dupe(u8, family);
            }
            result.value.font_families = result.families;
        }
        if (source.font_variations.len != 0) {
            result.variations = try allocator.dupe(text.FontVariation, source.font_variations);
            result.value.font_variations = result.variations;
        }
        return result;
    }

    fn deinit(self: *OwnedTextStyle, allocator: std.mem.Allocator) void {
        for (self.families) |family| if (family.len != 0) allocator.free(@constCast(family));
        if (self.families.len != 0) allocator.free(self.families);
        if (self.variations.len != 0) allocator.free(self.variations);
        self.* = undefined;
    }
};

const OwnedStyle = struct {
    layout: OwnedLayout,
    paint: style.PaintStyle,
    text: OwnedTextStyle,
    interaction: style.InteractionStyle,

    fn init(allocator: std.mem.Allocator, source: style.Style) Error!OwnedStyle {
        try validateStyle(source);
        var owned_layout = try OwnedLayout.init(allocator, source.layout);
        errdefer owned_layout.deinit(allocator);
        return .{
            .layout = owned_layout,
            .paint = source.paint,
            .text = try OwnedTextStyle.init(allocator, source.text),
            .interaction = source.interaction,
        };
    }

    fn deinit(self: *OwnedStyle, allocator: std.mem.Allocator) void {
        self.layout.deinit(allocator);
        self.text.deinit(allocator);
        self.* = undefined;
    }

    fn borrowed(self: *const OwnedStyle) style.Style {
        return .{
            .layout = self.layout.value,
            .paint = self.paint,
            .text = self.text.value,
            .interaction = self.interaction,
        };
    }
};

const OwnedSemantics = struct {
    role: a11y.Role = .none,
    label: []u8 = &.{},
    description: []u8 = &.{},
    value: []u8 = &.{},
    actions: []a11y.Action = &.{},
    disabled: bool = false,
    checked: ?bool = null,
    expanded: ?bool = null,
    selected: bool = false,
    selection: ?a11y.Selection = null,
    range_min: ?f64 = null,
    range_max: ?f64 = null,
    range_value: ?f64 = null,
    multiline: bool = false,
    password: bool = false,

    fn init(allocator: std.mem.Allocator, source: node.Semantics) Error!OwnedSemantics {
        if (!validText(source.label, false) or !validText(source.description, false) or !validText(source.value, false))
            return error.InvalidConfiguration;
        if (source.selection) |selection| {
            if (selection.anchor > source.value.len or selection.focus > source.value.len or
                !utf8Boundary(source.value, selection.anchor) or !utf8Boundary(source.value, selection.focus))
                return error.InvalidConfiguration;
        }
        if (source.range_min) |value| if (!std.math.isFinite(value)) return error.InvalidConfiguration;
        if (source.range_max) |value| if (!std.math.isFinite(value)) return error.InvalidConfiguration;
        if (source.range_value) |value| if (!std.math.isFinite(value)) return error.InvalidConfiguration;
        if (source.range_min != null and source.range_max != null and source.range_min.? > source.range_max.?)
            return error.InvalidConfiguration;
        if (source.range_value) |range_value| {
            if (source.range_min) |minimum| if (range_value < minimum) return error.InvalidConfiguration;
            if (source.range_max) |maximum| if (range_value > maximum) return error.InvalidConfiguration;
        }
        var result: OwnedSemantics = .{
            .role = source.role,
            .disabled = source.disabled,
            .checked = source.checked,
            .expanded = source.expanded,
            .selected = source.selected,
            .selection = source.selection,
            .range_min = source.range_min,
            .range_max = source.range_max,
            .range_value = source.range_value,
            .multiline = source.multiline,
            .password = source.password,
        };
        errdefer result.deinit(allocator);
        result.label = try allocator.dupe(u8, source.label);
        result.description = try allocator.dupe(u8, source.description);
        result.value = try allocator.dupe(u8, source.value);
        result.actions = try allocator.dupe(a11y.Action, source.actions);
        return result;
    }

    fn deinit(self: *OwnedSemantics, allocator: std.mem.Allocator) void {
        if (self.label.len != 0) allocator.free(self.label);
        if (self.description.len != 0) allocator.free(self.description);
        if (self.value.len != 0) allocator.free(self.value);
        if (self.actions.len != 0) allocator.free(self.actions);
        self.* = undefined;
    }
};

const OwnedKind = union(enum) {
    container,
    spacer,
    text: []u8,
    image: node.Image,
    scroll: node.Scroll,
    component: handles.ComponentId,
    custom: custom.Node,

    fn init(allocator: std.mem.Allocator, source: node.Kind) Error!OwnedKind {
        return switch (source) {
            .container => .container,
            .spacer => .spacer,
            .text => |value| blk: {
                if (!validText(value, true)) return error.InvalidUtf8;
                break :blk .{ .text = try allocator.dupe(u8, value) };
            },
            .image => |value| blk: {
                if (!value.texture.isValid() or value.source_width == 0 or value.source_height == 0)
                    return error.InvalidConfiguration;
                break :blk .{ .image = value };
            },
            .scroll => |value| blk: {
                if (!std.math.isFinite(value.offset_x) or !std.math.isFinite(value.offset_y) or
                    value.offset_x < 0 or value.offset_y < 0)
                    return error.InvalidConfiguration;
                break :blk .{ .scroll = value };
            },
            .component => |value| blk: {
                if (!value.isValid()) return error.InvalidHandle;
                break :blk .{ .component = value };
            },
            .custom => |value| .{ .custom = value },
        };
    }

    fn deinit(self: *OwnedKind, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |value| allocator.free(value),
            else => {},
        }
        self.* = undefined;
    }
};

pub const Record = struct {
    parent: handles.NodeId,
    component: handles.ComponentId,
    key: node.Key,
    kind: OwnedKind,
    style: OwnedStyle,
    handlers: []input.Handler,
    action_handlers: []action.Handler,
    semantics: OwnedSemantics,
    children: std.ArrayList(handles.NodeId) = .empty,
    layout: layout.LayoutResult = .{},
    dirty: layout.Dirty = .{},
    semantic_id: handles.SemanticId = .invalid,
    paint_generation: u64 = 1,
    owned_bytes: usize = 0,
    children_bytes: usize = 0,

    pub fn borrowedStyle(self: *const Record) style.Style {
        return self.style.borrowed();
    }

    pub fn kindTag(self: *const Record) std.meta.Tag(OwnedKind) {
        return std.meta.activeTag(self.kind);
    }
};

pub const Store = struct {
    const Pool = handles.SlotPool(Record, handles.NodeId);

    pub const Limits = struct {
        maximum_nodes: usize = 1_000_000,
        maximum_depth: usize = core_config.maximum_retained_tree_depth,
        maximum_bytes: usize = 256 * 1024 * 1024,
    };

    const FieldUndo = struct {
        id: handles.NodeId,
        parent: handles.NodeId,
        component: handles.ComponentId,
        paint_generation: u64,
        kind: ?OwnedKind = null,
        layout: ?OwnedLayout = null,
        paint: ?style.PaintStyle = null,
        text_style: ?OwnedTextStyle = null,
        interaction: ?style.InteractionStyle = null,
        semantics: ?OwnedSemantics = null,
        handlers: ?[]input.Handler = null,
        action_handlers: ?[]action.Handler = null,
        old_record_bytes: usize,
        old_allocation_bytes: usize,
        new_allocation_bytes: usize,
    };

    const ChildrenUndo = struct {
        id: handles.NodeId,
        children: std.ArrayList(handles.NodeId),
        stale: []const handles.NodeId,
        old_bytes: usize,
        new_bytes: usize,
    };

    const Undo = union(enum) {
        created: handles.NodeId,
        retired: handles.NodeId,
        fields: FieldUndo,
        children: ChildrenUndo,
    };

    const ReconcileTransaction = struct {
        scratch: std.mem.Allocator,
        undo: std.ArrayList(Undo) = .empty,

        fn init(scratch: std.mem.Allocator) ReconcileTransaction {
            return .{ .scratch = scratch };
        }

        fn deinit(self: *ReconcileTransaction) void {
            self.undo.deinit(self.scratch);
            self.* = undefined;
        }

        fn record(self: *ReconcileTransaction, undo: Undo) std.mem.Allocator.Error!void {
            try self.undo.append(self.scratch, undo);
        }

        fn rollback(self: *ReconcileTransaction, store: *Store) void {
            var index = self.undo.items.len;
            while (index != 0) {
                index -= 1;
                switch (self.undo.items[index]) {
                    .created => |id| store.destroyTree(id),
                    .retired => {},
                    .fields => |fields| rollbackFields(store, fields),
                    .children => |children| {
                        var old_children = children.children;
                        if (store.get(children.id)) |node_record| {
                            node_record.children.deinit(store.allocator);
                            store.releaseOwned(children.new_bytes);
                            node_record.children = old_children;
                            node_record.children_bytes = children.old_bytes;
                        } else {
                            old_children.deinit(store.allocator);
                            store.releaseOwned(children.old_bytes);
                        }
                    },
                }
            }
            self.undo.clearRetainingCapacity();
        }

        fn commit(self: *ReconcileTransaction, store: *Store) void {
            for (self.undo.items) |undo| switch (undo) {
                .created => {},
                .retired => |id| store.destroyTree(id),
                .fields => |fields| {
                    deinitOldFields(store.allocator, fields);
                    store.releaseOwned(fields.old_allocation_bytes);
                },
                .children => |children| {
                    var old_children = children.children;
                    old_children.deinit(store.allocator);
                    store.releaseOwned(children.old_bytes);
                    for (children.stale) |id| store.destroyTree(id);
                },
            };
            self.undo.clearRetainingCapacity();
        }
    };

    allocator: std.mem.Allocator,
    pool: Pool,
    limits: Limits,
    retained_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return initWithLimits(allocator, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) Store {
        return .{ .allocator = allocator, .pool = Pool.init(allocator), .limits = limits };
    }

    pub fn deinit(self: *Store) void {
        var iterator = self.pool.iterator();
        while (iterator.next()) |entry| deinitRecord(self.allocator, entry.value);
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn get(self: *Store, id: handles.NodeId) ?*Record {
        return self.pool.get(id);
    }

    pub fn getConst(self: *const Store, id: handles.NodeId) ?*const Record {
        return self.pool.getConst(id);
    }

    pub fn retainedBytes(self: *const Store) usize {
        return self.retained_bytes;
    }

    pub const InspectView = struct {
        id: handles.NodeId,
        parent: handles.NodeId,
        component: handles.ComponentId,
        key: node.Key,
        kind: []const u8,
        style: style.Style,
        layout_result: layout.LayoutResult,
        children: []const handles.NodeId,
        semantic_id: handles.SemanticId,
        semantic_role: a11y.Role,
        semantic_label: []const u8,
        semantic_value: []const u8,
        dirty: layout.Dirty,
        paint_generation: u64,
    };

    pub const InspectIterator = struct {
        inner: Pool.Iterator,

        pub fn next(self: *InspectIterator) ?InspectView {
            const entry = self.inner.next() orelse return null;
            const record = entry.value;
            return .{
                .id = entry.id,
                .parent = record.parent,
                .component = record.component,
                .key = record.key,
                .kind = @tagName(record.kindTag()),
                .style = record.borrowedStyle(),
                .layout_result = record.layout,
                .children = record.children.items,
                .semantic_id = record.semantic_id,
                .semantic_role = record.semantics.role,
                .semantic_label = record.semantics.label,
                .semantic_value = record.semantics.value,
                .dirty = record.dirty,
                .paint_generation = record.paint_generation,
            };
        }
    };

    pub fn inspectIterator(self: *Store) InspectIterator {
        return .{ .inner = self.pool.iterator() };
    }

    /// Verifies the complete retained ownership tree before any recursive
    /// layout, painting, hit-testing, or accessibility walk consumes it.
    /// Validation is iterative so malformed low-level NodeStore mutations
    /// cannot turn into an unbounded call stack.
    pub fn validateTree(self: *const Store, root: handles.NodeId, scratch: std.mem.Allocator) Error!void {
        const Pending = struct {
            id: handles.NodeId,
            expected_parent: handles.NodeId,
            depth: usize,
        };

        var pending: std.ArrayList(Pending) = .empty;
        defer pending.deinit(scratch);
        var visited = std.AutoHashMap(u64, void).init(scratch);
        defer visited.deinit();
        try pending.append(scratch, .{
            .id = root,
            .expected_parent = .invalid,
            .depth = 0,
        });

        while (pending.items.len != 0) {
            const item = pending.items[pending.items.len - 1];
            pending.items.len -= 1;
            if (!item.id.isValid()) return error.InvalidHandle;
            if (item.depth >= self.limits.maximum_depth) return error.BudgetExceeded;
            if (visited.count() >= self.limits.maximum_nodes) return error.BudgetExceeded;
            if ((try visited.getOrPut(item.id.encode())).found_existing) return error.InvalidConfiguration;

            const record = self.getConst(item.id) orelse return error.InvalidHandle;
            if (!record.parent.eql(item.expected_parent)) return error.InvalidConfiguration;
            if (record.kindTag() == .component and record.children.items.len > 1)
                return error.InvalidConfiguration;

            try pending.ensureUnusedCapacity(scratch, record.children.items.len);
            for (record.children.items) |child| pending.appendAssumeCapacity(.{
                .id = child,
                .expected_parent = item.id,
                .depth = item.depth + 1,
            });
        }
    }

    pub fn createAnchor(self: *Store, seed: u64) Error!handles.NodeId {
        return self.createRecord(.invalid, .invalid, .{
            .key = seed,
            .kind = .container,
        }, seed);
    }

    pub fn reconcile(
        self: *Store,
        existing: ?handles.NodeId,
        parent: handles.NodeId,
        component: handles.ComponentId,
        spec: node.Spec,
        key: node.Key,
        scratch: std.mem.Allocator,
    ) Error!handles.NodeId {
        var transaction = ReconcileTransaction.init(scratch);
        defer transaction.deinit();
        const starting_depth = try self.childDepth(parent);
        const result = self.reconcileInner(existing, parent, component, spec, key, starting_depth, &transaction) catch |err| {
            transaction.rollback(self);
            return err;
        };
        transaction.commit(self);
        return result;
    }

    fn reconcileInner(
        self: *Store,
        existing: ?handles.NodeId,
        parent: handles.NodeId,
        component: handles.ComponentId,
        spec: node.Spec,
        key: node.Key,
        depth: usize,
        transaction: *ReconcileTransaction,
    ) Error!handles.NodeId {
        if (depth >= self.limits.maximum_depth) return error.BudgetExceeded;
        var id = existing orelse handles.NodeId.invalid;
        if (id.isValid()) {
            if (self.getConst(id)) |record| {
                if (record.key != key or @backingInt(record.kindTag()) != @backingInt(std.meta.activeTag(spec.kind))) {
                    try transaction.record(.{ .retired = id });
                    id = handles.NodeId.invalid;
                }
            } else {
                id = handles.NodeId.invalid;
            }
        }

        if (!id.isValid()) {
            const created = try self.createRecord(parent, component, spec, key);
            transaction.record(.{ .created = created }) catch |err| {
                self.destroyTree(created);
                return err;
            };
            id = created;
        } else {
            try self.updateRecord(id, parent, component, spec, transaction);
        }

        const current = self.get(id) orelse return error.InvalidHandle;
        if (std.meta.activeTag(current.kind) == .component) {
            if (spec.children.len != 0) return error.InvalidConfiguration;
            return id;
        }

        const old_children = try transaction.scratch.dupe(handles.NodeId, current.children.items);
        var old_by_key = std.AutoHashMap(node.Key, handles.NodeId).init(transaction.scratch);
        defer old_by_key.deinit();
        for (old_children) |candidate| {
            const candidate_record = self.getConst(candidate) orelse continue;
            const result = try old_by_key.getOrPut(candidate_record.key);
            if (result.found_existing) return error.InvalidConfiguration;
            result.value_ptr.* = candidate;
        }
        const next_children = try transaction.scratch.alloc(handles.NodeId, spec.children.len);
        var next_keys = std.AutoHashMap(node.Key, void).init(transaction.scratch);
        defer next_keys.deinit();

        for (spec.children, 0..) |child_spec, index| {
            const child_key = child_spec.key orelse node.automaticKey(key, index, child_spec.kind);
            if ((try next_keys.getOrPut(child_key)).found_existing) return error.InvalidConfiguration;
            const match = if (old_by_key.fetchRemove(child_key)) |entry| entry.value else null;
            const child = try self.reconcileInner(match, id, component, child_spec, child_key, depth + 1, transaction);
            next_children[index] = child;
        }

        const refreshed = self.get(id) orelse return error.InvalidHandle;
        if (sameHandles(refreshed.children.items, next_children) and old_by_key.count() == 0) return id;

        const stale = try transaction.scratch.alloc(handles.NodeId, old_by_key.count());
        var stale_index: usize = 0;
        var stale_iterator = old_by_key.valueIterator();
        while (stale_iterator.next()) |child| {
            stale[stale_index] = child.*;
            stale_index += 1;
        }

        const replacement_bytes = try sliceBytes(handles.NodeId, next_children.len);
        try self.ensureOwned(replacement_bytes);
        const replacement_items = try self.allocator.dupe(handles.NodeId, next_children);
        var replacement: std.ArrayList(handles.NodeId) = .{
            .items = replacement_items,
            .capacity = replacement_items.len,
        };
        transaction.record(.{ .children = .{
            .id = id,
            .children = refreshed.children,
            .stale = stale,
            .old_bytes = refreshed.children_bytes,
            .new_bytes = replacement_bytes,
        } }) catch |err| {
            replacement.deinit(self.allocator);
            return err;
        };
        refreshed.children = replacement;
        refreshed.children_bytes = replacement_bytes;
        self.retained_bytes += replacement_bytes;
        return id;
    }

    pub fn setSingleChild(self: *Store, parent: handles.NodeId, child: handles.NodeId) Error!void {
        const record = self.get(parent) orelse return error.InvalidHandle;
        const child_record = self.getConst(child) orelse return error.InvalidHandle;
        if (!child_record.parent.eql(parent)) return error.InvalidConfiguration;
        if (record.children.capacity == 0) {
            const replacement_bytes = try sliceBytes(handles.NodeId, 1);
            try self.ensureOwned(replacement_bytes);
            const storage = try self.allocator.alloc(handles.NodeId, 1);
            storage[0] = child;
            record.children = .{ .items = storage, .capacity = storage.len };
            record.children_bytes = replacement_bytes;
            self.retained_bytes += replacement_bytes;
            return;
        }
        for (record.children.items) |old| {
            if (!old.eql(child)) self.destroyTree(old);
        }
        record.children.clearRetainingCapacity();
        record.children.appendAssumeCapacity(child);
    }

    /// Reserves retained child storage before reconciliation begins so the
    /// final root attachment cannot strand a newly-created subtree on OOM.
    pub fn reserveChildren(self: *Store, parent: handles.NodeId, count: usize) Error!void {
        const record = self.get(parent) orelse return error.InvalidHandle;
        if (count <= record.children.capacity) return;
        if (count > self.limits.maximum_nodes) return error.BudgetExceeded;
        const replacement_bytes = try sliceBytes(handles.NodeId, count);
        try self.ensureOwned(replacement_bytes);
        const storage = try self.allocator.alloc(handles.NodeId, count);
        @memcpy(storage[0..record.children.items.len], record.children.items);
        var old = record.children;
        const old_bytes = record.children_bytes;
        record.children = .{ .items = storage[0..old.items.len], .capacity = storage.len };
        record.children_bytes = replacement_bytes;
        self.retained_bytes += replacement_bytes;
        old.deinit(self.allocator);
        self.releaseOwned(old_bytes);
    }

    pub fn destroyTree(self: *Store, root: handles.NodeId) void {
        const record = self.pool.remove(root) orelse return;
        for (record.children.items) |child| self.destroyTree(child);
        var owned = record;
        self.releaseOwned(owned.owned_bytes);
        self.releaseOwned(owned.children_bytes);
        deinitRecord(self.allocator, &owned);
    }

    fn createRecord(
        self: *Store,
        parent: handles.NodeId,
        component: handles.ComponentId,
        spec: node.Spec,
        key: node.Key,
    ) Error!handles.NodeId {
        if (self.pool.live_count >= self.limits.maximum_nodes) return error.BudgetExceeded;
        const record_bytes = try specOwnedBytes(spec);
        try self.ensureOwned(record_bytes);
        var owned_kind = try OwnedKind.init(self.allocator, spec.kind);
        errdefer owned_kind.deinit(self.allocator);
        var owned_style = try OwnedStyle.init(self.allocator, spec.style);
        errdefer owned_style.deinit(self.allocator);
        var semantics = try OwnedSemantics.init(self.allocator, spec.semantics);
        errdefer semantics.deinit(self.allocator);
        const handlers = try self.allocator.dupe(input.Handler, spec.handlers);
        errdefer self.allocator.free(handlers);
        const action_handlers = try self.allocator.dupe(action.Handler, spec.action_handlers);
        errdefer self.allocator.free(action_handlers);
        const id = try self.pool.insert(.{
            .parent = parent,
            .component = component,
            .key = key,
            .kind = owned_kind,
            .style = owned_style,
            .handlers = handlers,
            .action_handlers = action_handlers,
            .semantics = semantics,
            .owned_bytes = record_bytes,
        });
        self.retained_bytes += record_bytes;
        return id;
    }

    fn childDepth(self: *const Store, parent: handles.NodeId) Error!usize {
        var depth: usize = 0;
        var cursor = parent;
        while (cursor.isValid()) {
            if (depth >= self.limits.maximum_depth) return error.BudgetExceeded;
            const record = self.getConst(cursor) orelse return error.InvalidHandle;
            cursor = record.parent;
            depth += 1;
        }
        return depth;
    }

    fn updateRecord(
        self: *Store,
        id: handles.NodeId,
        parent: handles.NodeId,
        component: handles.ComponentId,
        spec: node.Spec,
        transaction: *ReconcileTransaction,
    ) Error!void {
        const record = self.get(id) orelse return error.InvalidHandle;
        const kind_changed = !kindEqual(record.kind, spec.kind);
        const current_style = record.style.borrowed();
        const layout_changed = !layoutEqual(current_style.layout, spec.style.layout);
        const paint_changed = !paintEqual(current_style.paint, spec.style.paint);
        const text_style_changed = !textStyleEqual(current_style.text, spec.style.text);
        const interaction_changed = !std.meta.eql(current_style.interaction, spec.style.interaction);
        const style_changed = layout_changed or paint_changed or text_style_changed or interaction_changed;
        const semantics_changed = !semanticsEqual(record.semantics, spec.semantics);
        const handlers_changed = !sliceMetaEqual(input.Handler, record.handlers, spec.handlers);
        const action_handlers_changed = !sliceMetaEqual(action.Handler, record.action_handlers, spec.action_handlers);
        if (style_changed) try validateStyle(spec.style);

        var old_allocation_bytes: usize = 0;
        var new_allocation_bytes: usize = 0;
        if (kind_changed) {
            old_allocation_bytes = try addBytes(old_allocation_bytes, try ownedKindBytes(record.kind));
            new_allocation_bytes = try addBytes(new_allocation_bytes, try kindBytes(spec.kind));
        }
        if (layout_changed) {
            old_allocation_bytes = try addBytes(old_allocation_bytes, try ownedLayoutBytes(&record.style.layout));
            new_allocation_bytes = try addBytes(new_allocation_bytes, try layoutBytes(spec.style.layout));
        }
        if (text_style_changed) {
            old_allocation_bytes = try addBytes(old_allocation_bytes, try ownedTextStyleBytes(&record.style.text));
            new_allocation_bytes = try addBytes(new_allocation_bytes, try textStyleBytes(spec.style.text));
        }
        if (semantics_changed) {
            old_allocation_bytes = try addBytes(old_allocation_bytes, try ownedSemanticsBytes(&record.semantics));
            new_allocation_bytes = try addBytes(new_allocation_bytes, try semanticsBytes(spec.semantics));
        }
        if (handlers_changed) {
            old_allocation_bytes = try addBytes(old_allocation_bytes, try sliceBytes(input.Handler, record.handlers.len));
            new_allocation_bytes = try addBytes(new_allocation_bytes, try sliceBytes(input.Handler, spec.handlers.len));
        }
        if (action_handlers_changed) {
            old_allocation_bytes = try addBytes(old_allocation_bytes, try sliceBytes(action.Handler, record.action_handlers.len));
            new_allocation_bytes = try addBytes(new_allocation_bytes, try sliceBytes(action.Handler, spec.action_handlers.len));
        }
        try self.ensureOwned(new_allocation_bytes);
        const new_record_bytes = try addBytes(
            record.owned_bytes - old_allocation_bytes,
            new_allocation_bytes,
        );

        var next_kind: ?OwnedKind = null;
        errdefer if (next_kind) |*value| value.deinit(self.allocator);
        var next_layout: ?OwnedLayout = null;
        errdefer if (next_layout) |*value| value.deinit(self.allocator);
        var next_text_style: ?OwnedTextStyle = null;
        errdefer if (next_text_style) |*value| value.deinit(self.allocator);
        var next_semantics: ?OwnedSemantics = null;
        errdefer if (next_semantics) |*value| value.deinit(self.allocator);
        var next_handlers: ?[]input.Handler = null;
        errdefer if (next_handlers) |value| self.allocator.free(value);
        var next_action_handlers: ?[]action.Handler = null;
        errdefer if (next_action_handlers) |value| self.allocator.free(value);

        if (kind_changed) next_kind = try OwnedKind.init(self.allocator, spec.kind);
        if (layout_changed) next_layout = try OwnedLayout.init(self.allocator, spec.style.layout);
        if (text_style_changed) next_text_style = try OwnedTextStyle.init(self.allocator, spec.style.text);
        if (semantics_changed) next_semantics = try OwnedSemantics.init(self.allocator, spec.semantics);
        if (handlers_changed) next_handlers = try self.allocator.dupe(input.Handler, spec.handlers);
        if (action_handlers_changed) next_action_handlers = try self.allocator.dupe(action.Handler, spec.action_handlers);

        if (!kind_changed and !style_changed and !semantics_changed and !handlers_changed and
            !action_handlers_changed and record.parent.eql(parent) and record.component.eql(component)) return;

        try transaction.record(.{ .fields = .{
            .id = id,
            .parent = record.parent,
            .component = record.component,
            .paint_generation = record.paint_generation,
            .kind = if (kind_changed) record.kind else null,
            .layout = if (layout_changed) record.style.layout else null,
            .paint = if (paint_changed) record.style.paint else null,
            .text_style = if (text_style_changed) record.style.text else null,
            .interaction = if (interaction_changed) record.style.interaction else null,
            .semantics = if (semantics_changed) record.semantics else null,
            .handlers = if (handlers_changed) record.handlers else null,
            .action_handlers = if (action_handlers_changed) record.action_handlers else null,
            .old_record_bytes = record.owned_bytes,
            .old_allocation_bytes = old_allocation_bytes,
            .new_allocation_bytes = new_allocation_bytes,
        } });

        if (next_kind) |value| {
            record.kind = value;
            next_kind = null;
        }
        if (next_layout) |value| {
            record.style.layout = value;
            next_layout = null;
        }
        if (paint_changed) record.style.paint = spec.style.paint;
        if (next_text_style) |value| {
            record.style.text = value;
            next_text_style = null;
        }
        if (interaction_changed) record.style.interaction = spec.style.interaction;
        if (next_semantics) |value| {
            record.semantics = value;
            next_semantics = null;
        }
        if (next_handlers) |value| {
            record.handlers = value;
            next_handlers = null;
        }
        if (next_action_handlers) |value| {
            record.action_handlers = value;
            next_action_handlers = null;
        }
        record.parent = parent;
        record.component = component;
        record.owned_bytes = new_record_bytes;
        self.retained_bytes += new_allocation_bytes;
        if (kind_changed or style_changed) {
            record.paint_generation +%= 1;
            if (record.paint_generation == 0) record.paint_generation = 1;
        }
    }

    fn ensureOwned(self: *const Store, amount: usize) Error!void {
        if (amount > self.limits.maximum_bytes -| self.retained_bytes) return error.BudgetExceeded;
    }

    fn releaseOwned(self: *Store, amount: usize) void {
        self.retained_bytes -= amount;
    }
};

fn rollbackFields(store: *Store, fields: Store.FieldUndo) void {
    const record = store.get(fields.id) orelse {
        deinitOldFields(store.allocator, fields);
        store.releaseOwned(fields.old_allocation_bytes);
        return;
    };
    if (fields.kind) |value| {
        record.kind.deinit(store.allocator);
        record.kind = value;
    }
    if (fields.layout) |value| {
        record.style.layout.deinit(store.allocator);
        record.style.layout = value;
    }
    if (fields.paint) |value| record.style.paint = value;
    if (fields.text_style) |value| {
        record.style.text.deinit(store.allocator);
        record.style.text = value;
    }
    if (fields.interaction) |value| record.style.interaction = value;
    if (fields.semantics) |value| {
        record.semantics.deinit(store.allocator);
        record.semantics = value;
    }
    if (fields.handlers) |value| {
        store.allocator.free(record.handlers);
        record.handlers = value;
    }
    if (fields.action_handlers) |value| {
        store.allocator.free(record.action_handlers);
        record.action_handlers = value;
    }
    store.releaseOwned(fields.new_allocation_bytes);
    record.owned_bytes = fields.old_record_bytes;
    record.parent = fields.parent;
    record.component = fields.component;
    record.paint_generation = fields.paint_generation;
}

fn deinitOldFields(allocator: std.mem.Allocator, fields: Store.FieldUndo) void {
    if (fields.kind) |value| {
        var old = value;
        old.deinit(allocator);
    }
    if (fields.layout) |value| {
        var old = value;
        old.deinit(allocator);
    }
    if (fields.text_style) |value| {
        var old = value;
        old.deinit(allocator);
    }
    if (fields.semantics) |value| {
        var old = value;
        old.deinit(allocator);
    }
    if (fields.handlers) |value| allocator.free(value);
    if (fields.action_handlers) |value| allocator.free(value);
}

fn specOwnedBytes(spec: node.Spec) Error!usize {
    var total = try kindBytes(spec.kind);
    total = try addBytes(total, try styleBytes(spec.style));
    total = try addBytes(total, try semanticsBytes(spec.semantics));
    total = try addBytes(total, try sliceBytes(input.Handler, spec.handlers.len));
    total = try addBytes(total, try sliceBytes(action.Handler, spec.action_handlers.len));
    return total;
}

fn kindBytes(value: node.Kind) Error!usize {
    return switch (value) {
        .text => |bytes| bytes.len,
        else => 0,
    };
}

fn ownedKindBytes(value: OwnedKind) Error!usize {
    return switch (value) {
        .text => |bytes| bytes.len,
        else => 0,
    };
}

fn styleBytes(value: style.Style) Error!usize {
    return addBytes(try layoutBytes(value.layout), try textStyleBytes(value.text));
}

fn ownedStyleBytes(value: *const OwnedStyle) Error!usize {
    return addBytes(try ownedLayoutBytes(&value.layout), try ownedTextStyleBytes(&value.text));
}

fn layoutBytes(value: layout.LayoutStyle) Error!usize {
    return addBytes(
        try sliceBytes(layout.GridTrack, value.grid_columns.len),
        try sliceBytes(layout.GridTrack, value.grid_rows.len),
    );
}

fn ownedLayoutBytes(value: *const OwnedLayout) Error!usize {
    return addBytes(
        try sliceBytes(layout.GridTrack, value.columns.len),
        try sliceBytes(layout.GridTrack, value.rows.len),
    );
}

fn textStyleBytes(value: style.TextStyle) Error!usize {
    var total = try sliceBytes([]const u8, value.font_families.len);
    for (value.font_families) |family| total = try addBytes(total, family.len);
    total = try addBytes(total, try sliceBytes(text.FontVariation, value.font_variations.len));
    return total;
}

fn ownedTextStyleBytes(value: *const OwnedTextStyle) Error!usize {
    var total = try sliceBytes([]const u8, value.families.len);
    for (value.families) |family| total = try addBytes(total, family.len);
    total = try addBytes(total, try sliceBytes(text.FontVariation, value.variations.len));
    return total;
}

fn semanticsBytes(value: node.Semantics) Error!usize {
    var total = try addBytes(value.label.len, value.description.len);
    total = try addBytes(total, value.value.len);
    total = try addBytes(total, try sliceBytes(a11y.Action, value.actions.len));
    return total;
}

fn ownedSemanticsBytes(value: *const OwnedSemantics) Error!usize {
    var total = try addBytes(value.label.len, value.description.len);
    total = try addBytes(total, value.value.len);
    total = try addBytes(total, try sliceBytes(a11y.Action, value.actions.len));
    return total;
}

fn sliceBytes(comptime T: type, count: usize) Error!usize {
    return std.math.mul(usize, @sizeOf(T), count) catch error.BudgetExceeded;
}

fn addBytes(total: usize, amount: usize) Error!usize {
    return std.math.add(usize, total, amount) catch error.BudgetExceeded;
}

fn sameHandles(a: []const handles.NodeId, b: []const handles.NodeId) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!left.eql(right)) return false;
    return true;
}

fn kindEqual(owned: OwnedKind, source: node.Kind) bool {
    if (@backingInt(std.meta.activeTag(owned)) != @backingInt(std.meta.activeTag(source))) return false;
    return switch (owned) {
        .container, .spacer => true,
        .text => |value| std.mem.eql(u8, value, source.text),
        .image => |value| std.meta.eql(value, source.image),
        .scroll => |value| std.meta.eql(value, source.scroll),
        .component => |value| value.eql(source.component),
        .custom => |value| value.context == source.custom.context and value.vtable == source.custom.vtable and value.type_token == source.custom.type_token,
    };
}

fn styleEqual(a: style.Style, b: style.Style) bool {
    return layoutEqual(a.layout, b.layout) and paintEqual(a.paint, b.paint) and
        textStyleEqual(a.text, b.text) and std.meta.eql(a.interaction, b.interaction);
}

fn layoutEqual(a: layout.LayoutStyle, b: layout.LayoutStyle) bool {
    if (!sliceMetaEqual(layout.GridTrack, a.grid_columns, b.grid_columns) or !sliceMetaEqual(layout.GridTrack, a.grid_rows, b.grid_rows)) return false;
    var left = a;
    var right = b;
    left.grid_columns = &.{};
    left.grid_rows = &.{};
    right.grid_columns = &.{};
    right.grid_rows = &.{};
    return std.meta.eql(left, right);
}

fn paintEqual(a: style.PaintStyle, b: style.PaintStyle) bool {
    if (!brushEqual(a.background, b.background) or !std.meta.eql(a.border, b.border) or
        !std.meta.eql(a.radii, b.radii) or a.opacity != b.opacity or !std.meta.eql(a.transform, b.transform) or
        a.shadows.count != b.shadows.count) return false;
    return sliceMetaEqual(style.ShadowStyle, a.shadows.values[0..a.shadows.count], b.shadows.values[0..b.shadows.count]);
}

fn brushEqual(a: style.Brush, b: style.Brush) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none => true,
        .solid => |color| std.meta.eql(color, b.solid),
        .linear_gradient => |gradient| blk: {
            const other = b.linear_gradient;
            if (gradient.angle_radians != other.angle_radians or gradient.stop_count != other.stop_count) break :blk false;
            break :blk sliceMetaEqual(style.GradientStop, gradient.stops[0..gradient.stop_count], other.stops[0..other.stop_count]);
        },
    };
}

fn textStyleEqual(a: style.TextStyle, b: style.TextStyle) bool {
    if (a.font_families.len != b.font_families.len) return false;
    for (a.font_families, b.font_families) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    if (!sliceMetaEqual(text.FontVariation, a.font_variations, b.font_variations)) return false;
    var left = a;
    var right = b;
    left.font_families = &.{};
    right.font_families = &.{};
    left.font_variations = &.{};
    right.font_variations = &.{};
    return std.meta.eql(left, right);
}

fn semanticsEqual(a: OwnedSemantics, b: node.Semantics) bool {
    return a.role == b.role and std.mem.eql(u8, a.label, b.label) and
        std.mem.eql(u8, a.description, b.description) and std.mem.eql(u8, a.value, b.value) and
        std.mem.eql(a11y.Action, a.actions, b.actions) and a.disabled == b.disabled and a.checked == b.checked and
        a.expanded == b.expanded and a.selected == b.selected and std.meta.eql(a.selection, b.selection) and
        a.range_min == b.range_min and a.range_max == b.range_max and a.range_value == b.range_value and
        a.multiline == b.multiline and a.password == b.password;
}

fn sliceMetaEqual(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

fn deinitRecord(allocator: std.mem.Allocator, record: *Record) void {
    record.kind.deinit(allocator);
    record.style.deinit(allocator);
    record.semantics.deinit(allocator);
    allocator.free(record.handlers);
    allocator.free(record.action_handlers);
    record.children.deinit(allocator);
}

fn validateStyle(value: style.Style) Error!void {
    const box = value.layout;
    if (!validBoxLength(box.width, true) or !validBoxLength(box.height, true) or
        !validBoxLength(box.min_width, true) or !validBoxLength(box.min_height, true) or
        !validBoxLength(box.max_width, true) or !validBoxLength(box.max_height, true) or
        !validBoxLength(box.flex_basis, true) or !validBoxEdges(box.margin, false) or
        !validBoxEdges(box.padding, true) or !validBoxEdges(box.inset, false) or
        !validNonNegativeSize(box.gap) or !std.math.isFinite(box.flex_grow) or box.flex_grow < 0 or
        !std.math.isFinite(box.flex_shrink) or box.flex_shrink < 0 or
        !std.math.isFinite(box.portal.gap) or !std.math.isFinite(box.portal.viewport_margin) or
        box.portal.viewport_margin < 0 or box.grid_column_span == 0 or box.grid_row_span == 0)
        return error.InvalidLayout;
    if (box.aspect_ratio) |ratio| if (!std.math.isFinite(ratio) or ratio <= 0) return error.InvalidLayout;
    for (box.grid_columns) |track| if (!validGridTrack(track)) return error.InvalidLayout;
    for (box.grid_rows) |track| if (!validGridTrack(track)) return error.InvalidLayout;

    const paint = value.paint;
    if (!validBrush(paint.background) or !validInsets(paint.border.widths, true) or
        !validColor(paint.border.color) or !validRadii(paint.radii) or
        !std.math.isFinite(paint.opacity) or paint.opacity < 0 or paint.opacity > 1 or
        !validTransform(paint.transform) or paint.shadows.count > paint.shadows.values.len)
        return error.InvalidConfiguration;
    for (paint.shadows.values[0..paint.shadows.count]) |shadow| {
        if (!validColor(shadow.color) or !validPoint(shadow.offset) or
            !std.math.isFinite(shadow.blur_radius) or shadow.blur_radius < 0 or !std.math.isFinite(shadow.spread))
            return error.InvalidConfiguration;
    }

    const text_style = value.text;
    if (text_style.font_families.len > 64 or text_style.font_variations.len > 64)
        return error.BudgetExceeded;
    if (text_style.font_stretch == 0 or text_style.font_stretch > 1000 or
        !std.math.isFinite(text_style.font_size) or text_style.font_size <= 0 or text_style.font_size > 1_000_000 or
        !std.math.isFinite(text_style.letter_spacing) or @abs(text_style.letter_spacing) > 1_000_000 or
        !validColor(text_style.color))
        return error.InvalidConfiguration;
    if (text_style.line_height) |line_height| if (!std.math.isFinite(line_height) or
        line_height <= 0 or line_height > 1_000_000)
        return error.InvalidConfiguration;
    if (text_style.maximum_lines) |maximum_lines| if (maximum_lines == 0) return error.InvalidConfiguration;
    var family_bytes: usize = 0;
    for (text_style.font_families) |family| {
        if (family.len == 0 or !validText(family, false)) return error.InvalidConfiguration;
        family_bytes = std.math.add(usize, family_bytes, family.len) catch return error.BudgetExceeded;
        if (family_bytes > 4096) return error.BudgetExceeded;
    }
    for (text_style.font_variations) |variation| if (!std.math.isFinite(variation.value))
        return error.InvalidConfiguration;

    const interaction = value.interaction;
    if ((interaction.trap_focus and !interaction.focus_scope) or (interaction.autofocus and !interaction.focusable))
        return error.InvalidConfiguration;
}

fn validLength(value: layout.Length, nonnegative: bool) bool {
    return switch (value) {
        .auto => true,
        .points, .percent => |amount| std.math.isFinite(amount) and (!nonnegative or amount >= 0),
        .fraction => |amount| std.math.isFinite(amount) and amount >= 0,
    };
}

fn validBoxLength(value: layout.Length, nonnegative: bool) bool {
    return switch (value) {
        .fraction => false,
        else => validLength(value, nonnegative),
    };
}

fn validBoxEdges(value: layout.LengthEdges, nonnegative: bool) bool {
    return validBoxLength(value.top, nonnegative) and validBoxLength(value.right, nonnegative) and
        validBoxLength(value.bottom, nonnegative) and validBoxLength(value.left, nonnegative);
}

fn validGridTrack(value: layout.GridTrack) bool {
    return switch (value) {
        .auto => true,
        .points, .percent, .fraction => |amount| std.math.isFinite(amount) and amount >= 0,
        .minmax => |range| validBoxLength(range.min, true) and validLength(range.max, true),
    };
}

fn validBrush(value: style.Brush) bool {
    return switch (value) {
        .none => true,
        .solid => |color| validColor(color),
        .linear_gradient => |gradient| blk: {
            if (!std.math.isFinite(gradient.angle_radians) or gradient.stop_count > gradient.stops.len) break :blk false;
            var previous: f32 = 0;
            for (gradient.stops[0..gradient.stop_count], 0..) |stop, index| {
                if (!std.math.isFinite(stop.offset) or stop.offset < 0 or stop.offset > 1 or
                    !validColor(stop.color) or (index != 0 and stop.offset < previous))
                    break :blk false;
                previous = stop.offset;
            }
            break :blk true;
        },
    };
}

fn validColor(value: geometry.Color) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and std.math.isFinite(value.b) and
        std.math.isFinite(value.a) and value.a >= 0 and value.a <= 1;
}

fn validPoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}

fn validNonNegativeSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and value.width >= 0 and value.height >= 0;
}

fn validInsets(value: geometry.Insets, nonnegative: bool) bool {
    inline for (.{ value.top, value.right, value.bottom, value.left }) |amount|
        if (!std.math.isFinite(amount) or (nonnegative and amount < 0)) return false;
    return true;
}

fn validRadii(value: geometry.CornerRadii) bool {
    inline for (.{ value.top_left, value.top_right, value.bottom_right, value.bottom_left }) |radius|
        if (!std.math.isFinite(radius) or radius < 0) return false;
    return true;
}

fn validTransform(value: geometry.Affine2D) bool {
    inline for (.{ value.m11, value.m12, value.m21, value.m22, value.tx, value.ty }) |amount|
        if (!std.math.isFinite(amount)) return false;
    return true;
}

fn validText(value: []const u8, allow_nul: bool) bool {
    return std.unicode.utf8ValidateSlice(value) and (allow_nul or std.mem.indexOfScalar(u8, value, 0) == null);
}

fn utf8Boundary(value: []const u8, index: usize) bool {
    return index == value.len or (index < value.len and value[index] & 0xc0 != 0x80);
}
