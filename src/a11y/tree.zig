const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const compose_store = @import("../compose/store.zig");
const custom = @import("../compose/custom.zig");
const visual = @import("../compose/visual.zig");
const api = @import("api.zig");

const Identity = struct {
    node: handles.NodeId,
    custom_key: ?u64 = null,
    seen_generation: u64,
    committed: bool = false,
};

const CustomKey = struct { owner: u64, local: u64 };

const Output = struct {
    node: api.Node,
    children: std.ArrayList(handles.SemanticId) = .empty,
    label: std.ArrayList(u8) = .empty,
    description: std.ArrayList(u8) = .empty,
    value: std.ArrayList(u8) = .empty,
    actions: std.ArrayList(api.Action) = .empty,

    fn init(allocator: std.mem.Allocator, source: api.Node) Error!Output {
        var result: Output = .{ .node = source };
        errdefer result.deinit(allocator);
        try result.replace(allocator, source);
        return result;
    }

    fn replace(self: *Output, allocator: std.mem.Allocator, source: api.Node) Error!void {
        try validateNode(source);
        try self.label.ensureTotalCapacity(allocator, source.label.len);
        try self.description.ensureTotalCapacity(allocator, source.description.len);
        try self.value.ensureTotalCapacity(allocator, source.value.len);
        try self.actions.ensureTotalCapacity(allocator, source.actions.len);
        self.label.items.len = source.label.len;
        self.description.items.len = source.description.len;
        self.value.items.len = source.value.len;
        self.actions.items.len = source.actions.len;
        @memcpy(self.label.items, source.label);
        @memcpy(self.description.items, source.description);
        @memcpy(self.value.items, source.value);
        @memcpy(self.actions.items, source.actions);
        self.children.clearRetainingCapacity();
        self.node = source;
        self.node.label = self.label.items;
        self.node.description = self.description.items;
        self.node.value = self.value.items;
        self.node.actions = self.actions.items;
        self.node.children = &.{};
    }

    fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        self.children.deinit(allocator);
        self.label.deinit(allocator);
        self.description.deinit(allocator);
        self.value.deinit(allocator);
        self.actions.deinit(allocator);
        self.* = undefined;
    }
};

const Assignment = struct {
    node: handles.NodeId,
    semantic: handles.SemanticId,
};

pub const Prepared = struct {
    owner: *Builder,
    nodes: *compose_store.Store,
    root: handles.SemanticId,
    stale: []handles.SemanticId,
    scratch: std.mem.Allocator,
    attempt_generation: u64,
    tree_generation: u64,
    active: bool = true,

    pub fn deinit(self: *Prepared) void {
        if (!self.active) return;
        self.active = false;
        self.scratch.free(self.stale);
    }
};

pub const Builder = struct {
    const IdentityPool = handles.SlotPool(Identity, handles.SemanticId);

    allocator: std.mem.Allocator,
    window: handles.WindowId,
    identities: IdentityPool,
    by_node: std.AutoHashMap(u64, handles.SemanticId),
    custom_by_key: std.AutoHashMap(CustomKey, handles.SemanticId),
    by_semantic: std.AutoHashMap(u64, handles.NodeId),
    output_indices: std.AutoHashMap(u64, u32),
    outputs: std.ArrayList(Output) = .empty,
    staging_outputs: std.ArrayList(Output) = .empty,
    snapshot_nodes: std.ArrayList(api.Node) = .empty,
    staging_snapshot_nodes: std.ArrayList(api.Node) = .empty,
    staging_assignments: std.ArrayList(Assignment) = .empty,
    generation: u64 = 0,
    attempt_generation: u64 = 0,
    prepared_attempt: u64 = 0,
    maximum_nodes: usize,
    maximum_bytes: usize,
    staging_bytes: usize = 0,
    staging_output_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, window: handles.WindowId) Builder {
        return initWithLimits(allocator, window, 250_000, 32 * 1024 * 1024);
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        window: handles.WindowId,
        maximum_nodes: usize,
        maximum_bytes: usize,
    ) Builder {
        return .{
            .allocator = allocator,
            .window = window,
            .identities = IdentityPool.init(allocator),
            .by_node = std.AutoHashMap(u64, handles.SemanticId).init(allocator),
            .custom_by_key = std.AutoHashMap(CustomKey, handles.SemanticId).init(allocator),
            .by_semantic = std.AutoHashMap(u64, handles.NodeId).init(allocator),
            .output_indices = std.AutoHashMap(u64, u32).init(allocator),
            .maximum_nodes = maximum_nodes,
            .maximum_bytes = maximum_bytes,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.clearOutputs(&self.outputs);
        self.clearOutputs(&self.staging_outputs);
        self.outputs.deinit(self.allocator);
        self.staging_outputs.deinit(self.allocator);
        self.snapshot_nodes.deinit(self.allocator);
        self.staging_snapshot_nodes.deinit(self.allocator);
        self.staging_assignments.deinit(self.allocator);
        self.identities.deinit();
        self.by_node.deinit();
        self.custom_by_key.deinit();
        self.by_semantic.deinit();
        self.output_indices.deinit();
        self.* = undefined;
    }

    pub fn build(
        self: *Builder,
        nodes: *compose_store.Store,
        root_node: handles.NodeId,
        focused: handles.NodeId,
        scratch: std.mem.Allocator,
    ) Error!api.Tree {
        var prepared = try self.prepare(nodes, root_node, focused, scratch);
        defer prepared.deinit();
        return try self.commitPrepared(&prepared);
    }

    /// Builds a semantic snapshot in staging storage. Stable semantic maps and
    /// node assignments remain committed to the currently presented frame.
    pub fn prepare(
        self: *Builder,
        nodes: *compose_store.Store,
        root_node: handles.NodeId,
        focused: handles.NodeId,
        scratch: std.mem.Allocator,
    ) Error!Prepared {
        self.prepared_attempt = 0;
        self.pruneUncommitted();
        self.staging_output_count = 0;
        self.staging_snapshot_nodes.clearRetainingCapacity();
        self.staging_assignments.clearRetainingCapacity();
        self.output_indices.clearRetainingCapacity();
        self.staging_bytes = 0;
        self.attempt_generation +%= 1;
        if (self.attempt_generation == 0) self.attempt_generation = 1;
        const attempt = self.attempt_generation;
        var tree_generation = self.generation +% 1;
        if (tree_generation == 0) tree_generation = 1;

        const root_id = try self.identityFor(root_node, attempt);
        const root_record = nodes.get(root_node) orelse return error.InvalidHandle;
        try self.appendAssignment(.{ .node = root_node, .semantic = root_id });
        const root_semantics = root_record.semantics;
        const root_transform = visual.localTransform(root_record);
        const root_bounds = root_transform.transformRectBounds(root_record.layout.bounds);
        const root_index: u32 = @intCast(self.staging_output_count);
        try self.appendOutput(.{
            .id = root_id,
            .role = if (root_semantics.role == .none) .window else root_semantics.role,
            .label = root_semantics.label,
            .description = root_semantics.description,
            .value = root_semantics.value,
            .bounds = root_bounds,
            .actions = root_semantics.actions,
            .disabled = root_semantics.disabled,
            .focused = focused.eql(root_node),
            .selected = root_semantics.selected,
            .checked = root_semantics.checked,
            .expanded = root_semantics.expanded,
            .selection = root_semantics.selection,
            .range_min = root_semantics.range_min,
            .range_max = root_semantics.range_max,
            .range_value = root_semantics.range_value,
            .multiline = root_semantics.multiline,
            .password = root_semantics.password,
        });
        try self.output_indices.put(root_id.encode(), root_index);
        const root_child_transform = visual.transformForChildren(root_record, root_transform);
        for (root_record.children.items) |child| try self.visit(nodes, child, root_id, root_index, focused, root_child_transform, attempt);
        try self.appendCustom(root_record, root_node, root_id, root_index, root_bounds, attempt);

        self.finishStagingOutputs();
        for (self.staging_outputs.items) |*output| {
            output.node.children = output.children.items;
            try self.staging_snapshot_nodes.append(self.allocator, output.node);
        }
        try self.validateStagingBudget();
        const stale = try self.collectStale(scratch, attempt);
        self.prepared_attempt = attempt;
        return .{
            .owner = self,
            .nodes = nodes,
            .root = root_id,
            .stale = stale,
            .scratch = scratch,
            .attempt_generation = attempt,
            .tree_generation = tree_generation,
        };
    }

    pub fn commitPrepared(self: *Builder, prepared: *Prepared) Error!api.Tree {
        if (!prepared.active or prepared.owner != self or self.prepared_attempt != prepared.attempt_generation)
            return error.FramePhaseViolation;
        for (self.staging_assignments.items) |assignment| {
            if (prepared.nodes.get(assignment.node)) |record| {
                record.semantic_id = assignment.semantic;
            }
        }
        var iterator = self.identities.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.seen_generation == prepared.attempt_generation) entry.value.committed = true;
        }
        self.prune(prepared.nodes, prepared.stale);
        std.mem.swap(std.ArrayList(Output), &self.outputs, &self.staging_outputs);
        std.mem.swap(std.ArrayList(api.Node), &self.snapshot_nodes, &self.staging_snapshot_nodes);
        self.staging_output_count = 0;
        self.staging_snapshot_nodes.clearRetainingCapacity();
        self.generation = prepared.tree_generation;
        self.prepared_attempt = 0;
        const root = prepared.root;
        prepared.deinit();
        return .{
            .window = self.window,
            .root = root,
            .nodes = self.snapshot_nodes.items,
            .generation = self.generation,
        };
    }

    pub fn discardPrepared(self: *Builder) void {
        self.prepared_attempt = 0;
    }

    pub fn semanticForNode(self: *const Builder, node: handles.NodeId) ?handles.SemanticId {
        const id = self.by_node.get(node.encode()) orelse return null;
        const identity = self.identities.getConst(id) orelse return null;
        return if (identity.committed) id else null;
    }

    pub fn nodeForSemantic(self: *const Builder, semantic: handles.SemanticId) ?handles.NodeId {
        const identity = self.identities.getConst(semantic) orelse return null;
        if (!identity.committed) return null;
        return self.by_semantic.get(semantic.encode());
    }

    fn visit(
        self: *Builder,
        nodes: *compose_store.Store,
        node_id: handles.NodeId,
        semantic_parent: handles.SemanticId,
        parent_output: u32,
        focused: handles.NodeId,
        parent_transform: geometry.Affine2D,
        attempt: u64,
    ) Error!void {
        const record = nodes.get(node_id) orelse return;
        const borrowed = record.borrowedStyle();
        if (borrowed.layout.display == .none) return;
        const visual_parent = if (borrowed.layout.portal.target != .none)
            geometry.Affine2D.identity
        else
            parent_transform;
        const world_transform = geometry.Affine2D.mul(visual_parent, visual.localTransform(record));
        const visual_bounds = world_transform.transformRectBounds(record.layout.bounds);
        const semantics = record.semantics;
        const included = semantics.role != .none or semantics.label.len != 0 or semantics.description.len != 0 or
            semantics.value.len != 0 or semantics.actions.len != 0 or borrowed.interaction.focusable;

        var next_parent = semantic_parent;
        var next_parent_output = parent_output;
        if (included) {
            const id = try self.identityFor(node_id, attempt);
            try self.appendAssignment(.{ .node = node_id, .semantic = id });
            next_parent = id;
            next_parent_output = @intCast(self.staging_output_count);
            try self.appendOutput(.{
                .id = id,
                .parent = semantic_parent,
                .role = if (semantics.role == .none) .group else semantics.role,
                .label = semantics.label,
                .description = semantics.description,
                .value = semantics.value,
                .bounds = visual_bounds,
                .actions = semantics.actions,
                .disabled = semantics.disabled or borrowed.interaction.disabled,
                .focused = focused.eql(node_id),
                .selected = semantics.selected,
                .checked = semantics.checked,
                .expanded = semantics.expanded,
                .selection = semantics.selection,
                .range_min = semantics.range_min,
                .range_max = semantics.range_max,
                .range_value = semantics.range_value,
                .multiline = semantics.multiline,
                .password = semantics.password,
            });
            try self.output_indices.put(id.encode(), next_parent_output);
            try self.appendChild(parent_output, id);
        } else {
            try self.appendAssignment(.{ .node = node_id, .semantic = .invalid });
        }

        const child_transform = visual.transformForChildren(record, world_transform);
        for (record.children.items) |child| try self.visit(nodes, child, next_parent, next_parent_output, focused, child_transform, attempt);
        try self.appendCustom(record, node_id, next_parent, next_parent_output, visual_bounds, attempt);
    }

    fn appendCustom(
        self: *Builder,
        record: *const compose_store.Record,
        owner_node: handles.NodeId,
        parent: handles.SemanticId,
        parent_output: u32,
        bounds: geometry.Rect,
        attempt: u64,
    ) Error!void {
        switch (record.kind) {
            .custom => |custom_node| if (custom_node.vtable.semantics) |callback| {
                var sink: CustomSink = .{
                    .builder = self,
                    .owner_node = owner_node,
                    .parent = parent,
                    .parent_output = parent_output,
                    .attempt = attempt,
                };
                var writer: custom.SemanticsWriter = .{ .context = &sink, .append_fn = CustomSink.append };
                try callback(custom_node.context, &writer, bounds);
                if (sink.failure) |failure| return failure;
            },
            else => {},
        }
    }

    fn identityFor(self: *Builder, node: handles.NodeId, attempt: u64) Error!handles.SemanticId {
        if (self.by_node.get(node.encode())) |id| {
            const identity = self.identities.get(id) orelse return error.InvalidHandle;
            identity.seen_generation = attempt;
            return id;
        }
        if (self.identities.live_count >= self.maximum_nodes +| self.maximum_nodes) return error.BudgetExceeded;
        const id = try self.identities.insert(.{ .node = node, .seen_generation = attempt });
        errdefer _ = self.identities.remove(id);
        try self.by_node.put(node.encode(), id);
        errdefer _ = self.by_node.remove(node.encode());
        try self.by_semantic.put(id.encode(), node);
        return id;
    }

    fn identityForCustom(self: *Builder, owner: handles.NodeId, local_key: u64, attempt: u64) Error!handles.SemanticId {
        const key: CustomKey = .{ .owner = owner.encode(), .local = local_key };
        if (self.custom_by_key.get(key)) |id| {
            const identity = self.identities.get(id) orelse return error.InvalidHandle;
            if (identity.seen_generation == attempt) return error.ResourceBusy;
            identity.seen_generation = attempt;
            return id;
        }
        if (self.identities.live_count >= self.maximum_nodes +| self.maximum_nodes) return error.BudgetExceeded;
        const id = try self.identities.insert(.{
            .node = owner,
            .custom_key = local_key,
            .seen_generation = attempt,
        });
        errdefer _ = self.identities.remove(id);
        try self.custom_by_key.put(key, id);
        errdefer _ = self.custom_by_key.remove(key);
        try self.by_semantic.put(id.encode(), owner);
        return id;
    }

    fn collectStale(self: *Builder, scratch: std.mem.Allocator, attempt: u64) std.mem.Allocator.Error![]handles.SemanticId {
        var stale: std.ArrayList(handles.SemanticId) = .empty;
        errdefer stale.deinit(scratch);
        var iterator = self.identities.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.seen_generation != attempt) try stale.append(scratch, entry.id);
        }
        return stale.toOwnedSlice(scratch);
    }

    fn prune(self: *Builder, nodes: *compose_store.Store, stale: []const handles.SemanticId) void {
        for (stale) |id| {
            const identity = self.identities.remove(id) orelse continue;
            if (identity.custom_key) |local_key| {
                _ = self.custom_by_key.remove(.{ .owner = identity.node.encode(), .local = local_key });
            } else {
                _ = self.by_node.remove(identity.node.encode());
                if (nodes.get(identity.node)) |record| {
                    if (record.semantic_id.eql(id)) record.semantic_id = .invalid;
                }
            }
            _ = self.by_semantic.remove(id.encode());
        }
    }

    fn pruneUncommitted(self: *Builder) void {
        var iterator = self.identities.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.committed) continue;
            const identity = self.identities.remove(entry.id) orelse continue;
            if (identity.custom_key) |local_key| {
                _ = self.custom_by_key.remove(.{ .owner = identity.node.encode(), .local = local_key });
            } else {
                _ = self.by_node.remove(identity.node.encode());
            }
            _ = self.by_semantic.remove(entry.id.encode());
        }
    }

    fn appendOutput(self: *Builder, source: api.Node) Error!void {
        if (self.staging_output_count >= self.maximum_nodes) return error.BudgetExceeded;
        var bytes = std.math.add(usize, @sizeOf(Output), @sizeOf(api.Node)) catch return error.BudgetExceeded;
        inline for (.{ source.label.len, source.description.len, source.value.len }) |length|
            bytes = std.math.add(usize, bytes, length) catch return error.BudgetExceeded;
        bytes = std.math.add(
            usize,
            bytes,
            std.math.mul(usize, source.actions.len, @sizeOf(api.Action)) catch return error.BudgetExceeded,
        ) catch return error.BudgetExceeded;
        try self.reserveStagingBytes(bytes);
        errdefer self.staging_bytes -= bytes;
        if (self.staging_output_count < self.staging_outputs.items.len) {
            try self.staging_outputs.items[self.staging_output_count].replace(self.allocator, source);
        } else {
            var output = try Output.init(self.allocator, source);
            errdefer output.deinit(self.allocator);
            try self.staging_outputs.append(self.allocator, output);
        }
        self.staging_output_count += 1;
    }

    fn appendAssignment(self: *Builder, assignment: Assignment) Error!void {
        try self.reserveStagingBytes(@sizeOf(Assignment));
        errdefer self.staging_bytes -= @sizeOf(Assignment);
        try self.staging_assignments.append(self.allocator, assignment);
    }

    fn appendChild(self: *Builder, parent_output: u32, child: handles.SemanticId) Error!void {
        if (parent_output >= self.staging_output_count) return error.InvalidHandle;
        try self.reserveStagingBytes(@sizeOf(handles.SemanticId));
        errdefer self.staging_bytes -= @sizeOf(handles.SemanticId);
        try self.staging_outputs.items[parent_output].children.append(self.allocator, child);
    }

    fn reserveStagingBytes(self: *Builder, amount: usize) Error!void {
        if (amount > self.maximum_bytes -| self.staging_bytes) return error.BudgetExceeded;
        self.staging_bytes += amount;
    }

    fn validateStagingBudget(self: *const Builder) Error!void {
        var bytes = std.math.mul(usize, self.staging_output_count, @sizeOf(Output) + @sizeOf(api.Node)) catch return error.BudgetExceeded;
        bytes = std.math.add(
            usize,
            bytes,
            std.math.mul(usize, self.staging_assignments.items.len, @sizeOf(Assignment)) catch return error.BudgetExceeded,
        ) catch return error.BudgetExceeded;
        for (self.staging_outputs.items[0..self.staging_output_count]) |output| {
            inline for (.{ output.label.items.len, output.description.items.len, output.value.items.len }) |length|
                bytes = std.math.add(usize, bytes, length) catch return error.BudgetExceeded;
            bytes = std.math.add(
                usize,
                bytes,
                std.math.mul(usize, output.actions.items.len, @sizeOf(api.Action)) catch return error.BudgetExceeded,
            ) catch return error.BudgetExceeded;
            bytes = std.math.add(
                usize,
                bytes,
                std.math.mul(usize, output.children.items.len, @sizeOf(handles.SemanticId)) catch return error.BudgetExceeded,
            ) catch return error.BudgetExceeded;
        }
        if (bytes > self.maximum_bytes or bytes != self.staging_bytes) return error.BudgetExceeded;
    }

    fn finishStagingOutputs(self: *Builder) void {
        for (self.staging_outputs.items[self.staging_output_count..]) |*output| output.deinit(self.allocator);
        self.staging_outputs.items.len = self.staging_output_count;
    }

    fn clearOutputs(self: *Builder, outputs: *std.ArrayList(Output)) void {
        for (outputs.items) |*output| output.deinit(self.allocator);
        outputs.clearRetainingCapacity();
    }

    const CustomSink = struct {
        builder: *Builder,
        owner_node: handles.NodeId,
        parent: handles.SemanticId,
        parent_output: u32,
        attempt: u64,
        failure: ?Error = null,

        fn append(context: *anyopaque, local_key: u64, source: api.Node) Error!handles.SemanticId {
            const self: *CustomSink = @ptrCast(@alignCast(context));
            if (self.failure) |failure| return failure;
            return self.appendValue(local_key, source) catch |err| {
                self.failure = err;
                return err;
            };
        }

        fn appendValue(self: *CustomSink, local_key: u64, source: api.Node) Error!handles.SemanticId {
            var value = source;
            value.id = try self.builder.identityForCustom(self.owner_node, local_key, self.attempt);
            if (!value.parent.isValid()) value.parent = self.parent;
            const parent_output = self.builder.output_indices.get(value.parent.encode()) orelse return error.InvalidHandle;
            const output_index: u32 = @intCast(self.builder.staging_output_count);
            try self.builder.appendOutput(value);
            try self.builder.output_indices.put(value.id.encode(), output_index);
            try self.builder.appendChild(parent_output, value.id);
            return value.id;
        }
    };
};

fn validateNode(node: api.Node) Error!void {
    if (node.children.len != 0 or !validText(node.label) or !validText(node.description) or !validText(node.value))
        return error.InvalidConfiguration;
    if (!finiteRect(node.bounds)) return error.InvalidConfiguration;
    if (node.selection) |selection| {
        if (selection.anchor > node.value.len or selection.focus > node.value.len or
            !utf8Boundary(node.value, selection.anchor) or !utf8Boundary(node.value, selection.focus))
            return error.InvalidConfiguration;
    }
    if (node.range_min) |value| if (!std.math.isFinite(value)) return error.InvalidConfiguration;
    if (node.range_max) |value| if (!std.math.isFinite(value)) return error.InvalidConfiguration;
    if (node.range_value) |value| if (!std.math.isFinite(value)) return error.InvalidConfiguration;
    if (node.range_min != null and node.range_max != null and node.range_min.? > node.range_max.?)
        return error.InvalidConfiguration;
    if (node.range_value) |range_value| {
        if (node.range_min) |minimum| if (range_value < minimum) return error.InvalidConfiguration;
        if (node.range_max) |maximum| if (range_value > maximum) return error.InvalidConfiguration;
    }
}

fn validText(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn utf8Boundary(value: []const u8, index: usize) bool {
    return index == value.len or (index < value.len and value[index] & 0xc0 != 0x80);
}

fn finiteRect(value: geometry.Rect) bool {
    return std.math.isFinite(value.origin.x) and std.math.isFinite(value.origin.y) and
        std.math.isFinite(value.size.width) and std.math.isFinite(value.size.height) and
        value.size.width >= 0 and value.size.height >= 0;
}
