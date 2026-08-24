const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const compose_store = @import("../compose/store.zig");

const Candidate = struct {
    node: handles.NodeId,
    tab_index: i32,
    document_order: u32,
};

pub const Direction = enum { forward, backward };

pub const Prepared = struct {
    owner: *Manager,
    focused: handles.NodeId,
    manual_scope: handles.NodeId,
    declarative_scope: handles.NodeId,
    restore_focus: handles.NodeId,
    autofocus: handles.NodeId,
    consume_pending_autofocus: bool,
    generation: u64,
    attempt: u64,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    candidates: std.ArrayList(Candidate) = .empty,
    staging_candidates: std.ArrayList(Candidate) = .empty,
    focused: handles.NodeId = .invalid,
    manual_scope: handles.NodeId = .invalid,
    declarative_scope: handles.NodeId = .invalid,
    restore_focus: handles.NodeId = .invalid,
    autofocus: handles.NodeId = .invalid,
    pending_autofocus: bool = false,
    generation: u64 = 0,
    attempt_generation: u64 = 0,
    prepared_attempt: u64 = 0,
    prepared: bool = false,
    maximum_candidates: usize,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return initWithLimit(allocator, 1_000_000);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, maximum_candidates: usize) Manager {
        return .{ .allocator = allocator, .maximum_candidates = maximum_candidates };
    }

    pub fn deinit(self: *Manager) void {
        self.candidates.deinit(self.allocator);
        self.staging_candidates.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn rebuild(self: *Manager, nodes: *const compose_store.Store, root: handles.NodeId) Error!void {
        const prepared = try self.prepare(nodes, root);
        try self.commitPrepared(prepared);
    }

    /// Computes the next candidate list and focus-scope state without changing
    /// the focus manager currently used by input dispatch.
    pub fn prepare(self: *Manager, nodes: *const compose_store.Store, root: handles.NodeId) Error!Prepared {
        self.prepared = false;
        self.prepared_attempt = 0;
        self.staging_candidates.clearRetainingCapacity();
        const previous_declarative = self.declarative_scope;
        var next_declarative = handles.NodeId.invalid;
        var next_autofocus = handles.NodeId.invalid;
        var order: u32 = 0;
        try self.collect(nodes, root, &order, &next_declarative, &next_autofocus, &self.staging_candidates);
        std.mem.sort(Candidate, self.staging_candidates.items, {}, lessThan);
        var next_focused = self.focused;
        var next_restore = self.restore_focus;
        const next_manual = if (self.manual_scope.isValid() and nodes.getConst(self.manual_scope) != null)
            self.manual_scope
        else
            handles.NodeId.invalid;
        if (next_manual.isValid()) {
            if (!next_focused.isValid() or !isDescendant(nodes, next_focused, next_manual))
                next_focused = if (next_autofocus.isValid() and isDescendant(nodes, next_autofocus, next_manual))
                    next_autofocus
                else
                    firstInScope(self.staging_candidates.items, nodes, next_manual) orelse .invalid;
        } else if (!previous_declarative.eql(next_declarative)) {
            if (next_declarative.isValid()) {
                if (!previous_declarative.isValid()) next_restore = next_focused;
                if (!next_focused.isValid() or !isDescendant(nodes, next_focused, next_declarative))
                    next_focused = if (next_autofocus.isValid()) next_autofocus else firstInScope(self.staging_candidates.items, nodes, next_declarative) orelse .invalid;
            } else if (next_restore.isValid()) {
                if (nodes.getConst(next_restore) != null) next_focused = next_restore;
                next_restore = .invalid;
            }
        }
        const effective_scope = if (next_manual.isValid()) next_manual else next_declarative;
        if (next_focused.isValid()) {
            if (!programmaticallyFocusable(nodes, next_focused, effective_scope))
                next_focused = .invalid;
        }
        const consume_pending_autofocus = self.pending_autofocus;
        if (consume_pending_autofocus and next_autofocus.isValid() and
            (!effective_scope.isValid() or isDescendant(nodes, next_autofocus, effective_scope)))
            next_focused = next_autofocus;
        // Validate the previously focused identity before considering
        // autofocus. A removed focused node must not suppress a newly mounted
        // autofocus target merely because it was valid at the start of the
        // transaction.
        if (!next_focused.isValid() and next_autofocus.isValid() and !self.autofocus.eql(next_autofocus) and
            (!effective_scope.isValid() or isDescendant(nodes, next_autofocus, effective_scope)))
            next_focused = next_autofocus;
        if (!next_focused.isValid() and effective_scope.isValid())
            next_focused = if (next_autofocus.isValid() and isDescendant(nodes, next_autofocus, effective_scope))
                next_autofocus
            else
                firstInScope(self.staging_candidates.items, nodes, effective_scope) orelse .invalid;
        var next_generation = self.generation +% 1;
        if (next_generation == 0) next_generation = 1;
        self.attempt_generation +%= 1;
        if (self.attempt_generation == 0) self.attempt_generation = 1;
        const attempt = self.attempt_generation;
        self.prepared = true;
        self.prepared_attempt = attempt;
        return .{
            .owner = self,
            .focused = next_focused,
            .manual_scope = next_manual,
            .declarative_scope = next_declarative,
            .restore_focus = next_restore,
            .autofocus = next_autofocus,
            .consume_pending_autofocus = consume_pending_autofocus,
            .generation = next_generation,
            .attempt = attempt,
        };
    }

    pub fn commitPrepared(self: *Manager, prepared: Prepared) Error!void {
        if (!self.prepared or prepared.owner != self or prepared.attempt != self.prepared_attempt)
            return error.FramePhaseViolation;
        std.mem.swap(std.ArrayList(Candidate), &self.candidates, &self.staging_candidates);
        self.focused = prepared.focused;
        self.manual_scope = prepared.manual_scope;
        self.declarative_scope = prepared.declarative_scope;
        self.restore_focus = prepared.restore_focus;
        self.autofocus = prepared.autofocus;
        if (prepared.consume_pending_autofocus) self.pending_autofocus = false;
        self.generation = prepared.generation;
        self.prepared = false;
        self.prepared_attempt = 0;
    }

    pub fn discardPrepared(self: *Manager) void {
        self.prepared = false;
        self.prepared_attempt = 0;
    }

    pub fn request(self: *Manager, nodes: *const compose_store.Store, node: handles.NodeId) bool {
        const record = nodes.getConst(node) orelse return false;
        const interaction = record.borrowedStyle().interaction;
        if (!interaction.focusable or interaction.disabled) return false;
        const scope = self.effectiveScope();
        if (!programmaticallyFocusable(nodes, node, scope)) return false;
        self.focused = node;
        self.pending_autofocus = false;
        return true;
    }

    pub fn clear(self: *Manager) void {
        self.focused = .invalid;
        self.pending_autofocus = false;
    }

    pub fn requestAutofocusAfterReconcile(self: *Manager) void {
        self.pending_autofocus = true;
    }

    pub fn setScope(self: *Manager, nodes: *const compose_store.Store, scope: ?handles.NodeId) bool {
        if (scope) |value| {
            if (nodes.getConst(value) == null) return false;
            self.manual_scope = value;
            if (self.focused.isValid() and !isDescendant(nodes, self.focused, value)) self.focused = .invalid;
        } else {
            self.manual_scope = .invalid;
        }
        return true;
    }

    pub fn move(self: *Manager, nodes: *const compose_store.Store, direction: Direction) ?handles.NodeId {
        self.pending_autofocus = false;
        const scope = self.effectiveScope();
        var eligible_count: usize = 0;
        for (self.candidates.items) |candidate| {
            if (!scope.isValid() or isDescendant(nodes, candidate.node, scope)) eligible_count += 1;
        }
        if (eligible_count == 0) {
            self.focused = .invalid;
            return null;
        }

        var current_index: ?usize = null;
        var eligible_index: usize = 0;
        for (self.candidates.items) |candidate| {
            if (scope.isValid() and !isDescendant(nodes, candidate.node, scope)) continue;
            if (candidate.node.eql(self.focused)) current_index = eligible_index;
            eligible_index += 1;
        }
        const next_index = switch (direction) {
            .forward => if (current_index) |index| (index + 1) % eligible_count else 0,
            .backward => if (current_index) |index| if (index == 0) eligible_count - 1 else index - 1 else eligible_count - 1,
        };
        eligible_index = 0;
        for (self.candidates.items) |candidate| {
            if (scope.isValid() and !isDescendant(nodes, candidate.node, scope)) continue;
            if (eligible_index == next_index) {
                self.focused = candidate.node;
                return candidate.node;
            }
            eligible_index += 1;
        }
        return null;
    }

    fn collect(
        self: *Manager,
        nodes: *const compose_store.Store,
        id: handles.NodeId,
        order: *u32,
        declarative_scope: *handles.NodeId,
        autofocus: *handles.NodeId,
        output: *std.ArrayList(Candidate),
    ) Error!void {
        const record = nodes.getConst(id) orelse return;
        const style = record.borrowedStyle();
        if (style.layout.display == .none) return;
        if (style.interaction.focus_scope and style.interaction.trap_focus) declarative_scope.* = id;
        if (!autofocus.*.isValid() and style.interaction.autofocus and style.interaction.focusable and
            !style.interaction.disabled) autofocus.* = id;
        if (style.interaction.focusable and !style.interaction.disabled and style.interaction.tab_index >= 0) {
            if (output.items.len >= self.maximum_candidates) return error.BudgetExceeded;
            try output.append(self.allocator, .{
                .node = id,
                .tab_index = style.interaction.tab_index,
                .document_order = order.*,
            });
        }
        order.* +|= 1;
        for (record.children.items) |child| try self.collect(nodes, child, order, declarative_scope, autofocus, output);
    }

    fn effectiveScope(self: *const Manager) handles.NodeId {
        return if (self.manual_scope.isValid()) self.manual_scope else self.declarative_scope;
    }
};

fn firstInScope(candidates: []const Candidate, nodes: *const compose_store.Store, scope: handles.NodeId) ?handles.NodeId {
    for (candidates) |candidate| if (isDescendant(nodes, candidate.node, scope)) return candidate.node;
    return null;
}

fn lessThan(_: void, left: Candidate, right: Candidate) bool {
    const left_group: u1 = if (left.tab_index > 0) 0 else 1;
    const right_group: u1 = if (right.tab_index > 0) 0 else 1;
    if (left_group != right_group) return left_group < right_group;
    if (left_group == 0 and left.tab_index != right.tab_index) return left.tab_index < right.tab_index;
    return left.document_order < right.document_order;
}

fn isDescendant(nodes: *const compose_store.Store, candidate: handles.NodeId, ancestor: handles.NodeId) bool {
    var current = candidate;
    while (current.isValid()) {
        if (current.eql(ancestor)) return true;
        const record = nodes.getConst(current) orelse return false;
        current = record.parent;
    }
    return false;
}

fn programmaticallyFocusable(
    nodes: *const compose_store.Store,
    candidate: handles.NodeId,
    scope: handles.NodeId,
) bool {
    const candidate_record = nodes.getConst(candidate) orelse return false;
    const interaction = candidate_record.borrowedStyle().interaction;
    if (!interaction.focusable or interaction.disabled) return false;
    if (scope.isValid() and !isDescendant(nodes, candidate, scope)) return false;
    var current = candidate;
    while (current.isValid()) {
        const record = nodes.getConst(current) orelse return false;
        if (record.borrowedStyle().layout.display == .none) return false;
        current = record.parent;
    }
    return true;
}
