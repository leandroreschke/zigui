const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const compose_store = @import("../compose/store.zig");
const custom = @import("../compose/custom.zig");
const event = @import("event.zig");
const action = @import("action.zig");
const focus = @import("focus.zig");
const hit_tree = @import("hit_tree.zig");
const coordinator_mod = @import("../runtime/coordinator.zig");
const layout = @import("../layout/style.zig");

pub const Result = struct {
    handled: bool = false,
    default_prevented: bool = false,
    target: handles.NodeId = .invalid,
    focus_changed: bool = false,
    /// Multiple callbacks can invalidate different component boundaries
    /// during one synthesized transition; those requests must widen to the
    /// window rather than losing all but one component.
    window_dirty: bool = false,
    /// Explicit phase work requested by a handled custom element event.
    /// App applies this to the owning component after dispatch completes.
    narrow_dirty: ?layout.Dirty = null,
    narrow_component: ?handles.ComponentId = null,
};

pub const CapturedFocusEndpoint = struct {
    node: handles.NodeId,
    component: handles.ComponentId,
    handlers: []const event.Handler,
    custom_context: ?*anyopaque,
    custom_callback: ?*const fn (*anyopaque, *event.Dispatch, *const event.Event, *event.Context) Error!void,
    current_bounds: geometry.Rect,
    current_layout_bounds: geometry.Rect,
    current_content_bounds: geometry.Rect,
    current_scroll_extent: geometry.Size,
    local_to_world: geometry.Affine2D,
    world_to_local: geometry.Affine2D,
};

pub const Router = struct {
    pub const Limits = struct {
        maximum_pointer_captures: usize = 256,
        maximum_contexts: usize = 256,
        maximum_hover_depth: usize = 512,
        maximum_event_payload_bytes: usize = 16 * 1024 * 1024,
        maximum_file_drop_paths: usize = 4_096,
    };

    allocator: std.mem.Allocator,
    window: handles.WindowId,
    root: handles.NodeId,
    hits: *hit_tree.Tree,
    focus_manager: *focus.Manager,
    actions: *action.Registry,
    pointer_capture: std.AutoHashMap(u64, handles.NodeId),
    hover_path: std.ArrayList(handles.NodeId) = .empty,
    active_contexts: std.ArrayList(action.Context) = .empty,
    native_text_input: ?event.NativeTextInput = null,
    native_clipboard: ?event.NativeClipboard = null,
    limits: Limits,

    pub fn init(
        allocator: std.mem.Allocator,
        window: handles.WindowId,
        root: handles.NodeId,
        hits: *hit_tree.Tree,
        focus_manager: *focus.Manager,
        actions: *action.Registry,
    ) Router {
        return initWithLimits(allocator, window, root, hits, focus_manager, actions, .{});
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        window: handles.WindowId,
        root: handles.NodeId,
        hits: *hit_tree.Tree,
        focus_manager: *focus.Manager,
        actions: *action.Registry,
        limits: Limits,
    ) Router {
        return .{
            .allocator = allocator,
            .window = window,
            .root = root,
            .hits = hits,
            .focus_manager = focus_manager,
            .actions = actions,
            .pointer_capture = std.AutoHashMap(u64, handles.NodeId).init(allocator),
            .limits = limits,
        };
    }

    pub fn deinit(self: *Router) void {
        self.pointer_capture.deinit();
        self.hover_path.deinit(self.allocator);
        self.active_contexts.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setContexts(self: *Router, contexts: []const action.Context) Error!void {
        if (contexts.len > self.limits.maximum_contexts) return error.BudgetExceeded;
        try self.active_contexts.ensureTotalCapacity(self.allocator, contexts.len);
        self.active_contexts.clearRetainingCapacity();
        self.active_contexts.appendSliceAssumeCapacity(contexts);
    }

    pub fn setNativeTextInput(self: *Router, bridge: ?event.NativeTextInput) void {
        self.native_text_input = bridge;
    }

    pub fn setNativeClipboard(self: *Router, bridge: ?event.NativeClipboard) void {
        self.native_clipboard = bridge;
    }

    pub fn dispatch(
        self: *Router,
        nodes: *const compose_store.Store,
        coordinator: *coordinator_mod.Coordinator,
        value: *const event.Event,
        scratch: std.mem.Allocator,
    ) Error!Result {
        return self.dispatchInternal(nodes, coordinator, value, null, scratch);
    }

    pub fn dispatchTo(
        self: *Router,
        nodes: *const compose_store.Store,
        coordinator: *coordinator_mod.Coordinator,
        target: handles.NodeId,
        value: *const event.Event,
        scratch: std.mem.Allocator,
    ) Error!Result {
        return self.dispatchInternal(nodes, coordinator, value, target, scratch);
    }

    fn dispatchInternal(
        self: *Router,
        nodes: *const compose_store.Store,
        coordinator: *coordinator_mod.Coordinator,
        value: *const event.Event,
        forced_target: ?handles.NodeId,
        scratch: std.mem.Allocator,
    ) Error!Result {
        const focus_before = self.focus_manager.focused;
        try event.validate(value, .{
            .maximum_payload_bytes = self.limits.maximum_event_payload_bytes,
            .maximum_file_paths = self.limits.maximum_file_drop_paths,
        });
        if (pointerId(value)) |pointer_id| {
            if (!self.pointer_capture.contains(pointer_id) and self.pointer_capture.count() < self.limits.maximum_pointer_captures)
                try self.pointer_capture.ensureUnusedCapacity(1);
        }
        const target = forced_target orelse self.resolveTarget(nodes, value);
        var result: Result = .{ .target = target };
        if (forced_target == null) try self.updateHover(nodes, coordinator, value, scratch, &result);
        if (!target.isValid()) return result;

        switch (value.*) {
            .key_down => |key| if (!key.composing) {
                if (self.actions.resolveWithTextInput(key, self.active_contexts.items, self.textInputFocused(nodes))) |action_id| {
                    result.handled = try self.dispatchAction(nodes, coordinator, target, .{
                        .id = action_id,
                        .source = .keyboard,
                        .key_event = key,
                    });
                    if (result.handled) return result;
                }
            },
            else => {},
        }

        const path = try self.pathFor(nodes, target, scratch);
        var state: event.Dispatch = .{
            .window = self.window,
            .target = target,
            .current = target,
            .phase = .capture,
        };
        switch (value.*) {
            .accessibility => |accessibility_event| {
                if (accessibility_event.action == .focus) state.requested_focus = target;
            },
            else => {},
        }
        if (path.len > 1) {
            for (path[0 .. path.len - 1]) |node_id| {
                state.current = node_id;
                state.phase = .capture;
                try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, node_id, &state, value, .capture, &state.requested_autofocus_after_reconcile);
                if (state.propagation_stopped) break;
            }
        }
        if (!state.propagation_stopped) {
            state.current = target;
            state.phase = .target;
            try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, target, &state, value, .capture, &state.requested_autofocus_after_reconcile);
            if (!state.propagation_stopped) try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, target, &state, value, .target, &state.requested_autofocus_after_reconcile);
            if (!state.propagation_stopped) try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, target, &state, value, .bubble, &state.requested_autofocus_after_reconcile);
            if (!state.propagation_stopped) try callCustom(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, target, &state, value, &state.requested_autofocus_after_reconcile);
        }
        if (!state.propagation_stopped and path.len > 1) {
            var index = path.len - 1;
            while (index != 0) {
                index -= 1;
                state.current = path[index];
                state.phase = .bubble;
                try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, path[index], &state, value, .bubble, &state.requested_autofocus_after_reconcile);
                if (state.propagation_stopped) break;
            }
        }

        if (pointerId(value)) |pointer_id| {
            if (state.release_pointer_capture) {
                _ = self.pointer_capture.remove(pointer_id);
            } else if (state.pointer_capture) |capture| {
                if (nodes.getConst(capture) != null) {
                    if (!self.pointer_capture.contains(pointer_id) and self.pointer_capture.count() >= self.limits.maximum_pointer_captures)
                        return error.BudgetExceeded;
                    try self.pointer_capture.put(pointer_id, capture);
                }
            }
            switch (value.*) {
                .pointer_up, .pointer_cancel => _ = self.pointer_capture.remove(pointer_id),
                else => {},
            }
        }
        if (state.requested_focus) |requested| {
            const previous = self.focus_manager.focused;
            if (self.focus_manager.request(nodes, requested)) result.focus_changed = !previous.eql(self.focus_manager.focused);
        } else if (state.requested_autofocus_after_reconcile) {
            self.focus_manager.requestAutofocusAfterReconcile();
        }
        switch (value.*) {
            .key_down => |key| if (!state.default_prevented and std.meta.eql(key.key, event.Key.tab)) {
                const previous = self.focus_manager.focused;
                _ = self.focus_manager.move(nodes, if (key.modifiers.shift) .backward else .forward);
                result.focus_changed = result.focus_changed or !previous.eql(self.focus_manager.focused);
            },
            else => {},
        }
        result.handled = result.handled or state.handled;
        result.default_prevented = state.default_prevented;
        mergeRequestedDirty(nodes, target, &state, &result);
        if (!focus_before.eql(self.focus_manager.focused)) {
            try self.sendFocusTransition(nodes, coordinator, focus_before, self.focus_manager.focused, &result);
            result.focus_changed = true;
        }
        return result;
    }

    pub fn dispatchAction(
        self: *Router,
        nodes: *const compose_store.Store,
        coordinator: *coordinator_mod.Coordinator,
        target: handles.NodeId,
        action_event: action.ActionEvent,
    ) Error!bool {
        if (!self.actions.contains(action_event.id)) return false;
        var current = target;
        var dispatch_state: action.Dispatch = .{
            .window = self.window,
            .target = target,
            .current = target,
        };
        while (current.isValid()) {
            const record = nodes.getConst(current) orelse break;
            dispatch_state.current = current;
            var context = makeContext(
                nodes,
                self.hits,
                coordinator,
                self.window,
                self.native_text_input,
                self.native_clipboard,
                current,
                &dispatch_state.requested_autofocus_after_reconcile,
            ) orelse break;
            for (record.action_handlers) |handler| {
                if (!handler.action.eql(action_event.id) or action.contextSpecificity(handler.context, self.active_contexts.items) == null) continue;
                try handler.callback(handler.callback_context, &dispatch_state, action_event, &context);
                if (dispatch_state.propagation_stopped) break;
            }
            if (dispatch_state.propagation_stopped) break;
            current = record.parent;
        }
        if (dispatch_state.requested_autofocus_after_reconcile)
            self.focus_manager.requestAutofocusAfterReconcile();
        return dispatch_state.handled;
    }

    /// Copies the callback descriptors and geometry needed to deliver a later
    /// focus-out. Reconciliation may remove the focused retained node before
    /// the new focus set is committed, while callback contexts remain owned by
    /// their component models.
    pub fn captureFocusEndpoint(
        self: *Router,
        nodes: *const compose_store.Store,
        node_id: handles.NodeId,
        scratch: std.mem.Allocator,
    ) Error!?CapturedFocusEndpoint {
        if (!node_id.isValid()) return null;
        const record = nodes.getConst(node_id) orelse return null;
        const handlers = try scratch.dupe(event.Handler, record.handlers);
        const visual = self.hits.visualEntry(node_id);
        var custom_context: ?*anyopaque = null;
        var custom_callback: ?*const fn (*anyopaque, *event.Dispatch, *const event.Event, *event.Context) Error!void = null;
        switch (record.kind) {
            .custom => |custom_node| if (custom_node.vtable.event) |callback| {
                custom_context = custom_node.context;
                custom_callback = callback;
            },
            else => {},
        }
        return .{
            .node = node_id,
            .component = record.component,
            .handlers = handlers,
            .custom_context = custom_context,
            .custom_callback = custom_callback,
            .current_bounds = if (visual) |entry| entry.world_bounds else record.layout.bounds,
            .current_layout_bounds = record.layout.bounds,
            .current_content_bounds = record.layout.content_bounds,
            .current_scroll_extent = record.layout.scroll_extent,
            .local_to_world = if (visual) |entry| entry.world_transform else .identity,
            .world_to_local = if (visual) |entry| entry.inverse_transform else .identity,
        };
    }

    pub fn dispatchCommittedFocusTransition(
        self: *Router,
        nodes: *const compose_store.Store,
        coordinator: *coordinator_mod.Coordinator,
        previous: ?CapturedFocusEndpoint,
        next: handles.NodeId,
    ) Error!void {
        if (self.native_text_input) |bridge| try bridge.setActive(self.window, false);
        if (previous) |endpoint| try self.callCapturedFocusOut(coordinator, endpoint);
        if (next.isValid()) {
            const value: event.Event = .focus_in;
            var state: event.Dispatch = .{ .window = self.window, .target = next, .current = next, .phase = .target };
            try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, next, &state, &value, .bubble, null);
            try callCustom(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, next, &state, &value, null);
        }
    }

    fn callCapturedFocusOut(
        self: *Router,
        coordinator: *coordinator_mod.Coordinator,
        endpoint: CapturedFocusEndpoint,
    ) Error!void {
        const value: event.Event = .focus_out;
        var state: event.Dispatch = .{
            .window = self.window,
            .target = endpoint.node,
            .current = endpoint.node,
            .phase = .target,
        };
        var context: event.Context = .{
            .coordinator = coordinator,
            .component = endpoint.component,
            .window = self.window,
            .current_bounds = endpoint.current_bounds,
            .current_layout_bounds = endpoint.current_layout_bounds,
            .current_content_bounds = endpoint.current_content_bounds,
            .current_scroll_extent = endpoint.current_scroll_extent,
            .local_to_world = endpoint.local_to_world,
            .world_to_local = endpoint.world_to_local,
            .native_text_input = self.native_text_input,
            .native_clipboard = self.native_clipboard,
        };
        for (endpoint.handlers) |handler| {
            if (handler.phase != .bubble) continue;
            try handler.callback(handler.context, &state, &value, &context);
            if (state.propagation_stopped) return;
        }
        if (!state.propagation_stopped) if (endpoint.custom_callback) |callback|
            try callback(endpoint.custom_context.?, &state, &value, &context);
    }

    fn updateHover(
        self: *Router,
        nodes: *const compose_store.Store,
        coordinator: *coordinator_mod.Coordinator,
        value: *const event.Event,
        scratch: std.mem.Allocator,
        result: *Result,
    ) Error!void {
        const pointer = switch (value.*) {
            .pointer_down, .pointer_up, .pointer_move, .pointer_enter, .pointer_leave, .pointer_cancel => |pointer_value| pointer_value,
            else => return,
        };
        const tracks_position = switch (value.*) {
            .pointer_leave, .pointer_cancel => false,
            else => true,
        };
        var next_path: []handles.NodeId = &.{};
        if (tracks_position) {
            if (self.hits.hit(pointer.position)) |hit| next_path = try self.hits.path(hit.target, scratch);
        }
        if (next_path.len > self.limits.maximum_hover_depth) return error.BudgetExceeded;
        try self.hover_path.ensureTotalCapacity(self.allocator, next_path.len);
        var common: usize = 0;
        while (common < self.hover_path.items.len and common < next_path.len and self.hover_path.items[common].eql(next_path[common])) common += 1;

        var leave_index = self.hover_path.items.len;
        while (leave_index > common) {
            leave_index -= 1;
            const node_id = self.hover_path.items[leave_index];
            const synthetic: event.Event = .{ .pointer_leave = pointer };
            var dispatch_state: event.Dispatch = .{
                .window = self.window,
                .target = node_id,
                .current = node_id,
                .phase = .target,
            };
            try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, node_id, &dispatch_state, &synthetic, .bubble, null);
            try callCustom(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, node_id, &dispatch_state, &synthetic, null);
            mergeRequestedDirty(nodes, node_id, &dispatch_state, result);
        }
        var enter_index = common;
        while (enter_index < next_path.len) : (enter_index += 1) {
            const node_id = next_path[enter_index];
            const synthetic: event.Event = .{ .pointer_enter = pointer };
            var dispatch_state: event.Dispatch = .{
                .window = self.window,
                .target = node_id,
                .current = node_id,
                .phase = .target,
            };
            try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, node_id, &dispatch_state, &synthetic, .bubble, null);
            try callCustom(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, node_id, &dispatch_state, &synthetic, null);
            mergeRequestedDirty(nodes, node_id, &dispatch_state, result);
        }
        self.hover_path.clearRetainingCapacity();
        self.hover_path.appendSliceAssumeCapacity(next_path);
    }

    fn sendFocusTransition(
        self: *Router,
        nodes: *const compose_store.Store,
        coordinator: *coordinator_mod.Coordinator,
        previous: handles.NodeId,
        next: handles.NodeId,
        result: *Result,
    ) Error!void {
        if (!previous.eql(next)) if (self.native_text_input) |bridge|
            try bridge.setActive(self.window, false);
        if (previous.isValid()) {
            const value: event.Event = .focus_out;
            var state: event.Dispatch = .{ .window = self.window, .target = previous, .current = previous, .phase = .target };
            try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, previous, &state, &value, .bubble, null);
            try callCustom(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, previous, &state, &value, null);
            mergeRequestedDirty(nodes, previous, &state, result);
        }
        if (next.isValid()) {
            const value: event.Event = .focus_in;
            var state: event.Dispatch = .{ .window = self.window, .target = next, .current = next, .phase = .target };
            try callHandlers(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, next, &state, &value, .bubble, null);
            try callCustom(nodes, self.hits, coordinator, self.window, self.native_text_input, self.native_clipboard, next, &state, &value, null);
            mergeRequestedDirty(nodes, next, &state, result);
        }
    }

    fn resolveTarget(self: *Router, nodes: *const compose_store.Store, value: *const event.Event) handles.NodeId {
        if (pointerId(value)) |id| {
            if (self.pointer_capture.get(id)) |captured| {
                if (nodes.getConst(captured) != null) return captured;
                _ = self.pointer_capture.remove(id);
            }
        }
        if (eventPoint(value)) |point| return if (self.hits.hit(point)) |hit| hit.target else self.root;
        if (self.focus_manager.focused.isValid() and nodes.getConst(self.focus_manager.focused) != null) return self.focus_manager.focused;
        return self.root;
    }

    fn pathFor(self: *Router, nodes: *const compose_store.Store, target: handles.NodeId, scratch: std.mem.Allocator) std.mem.Allocator.Error![]handles.NodeId {
        _ = nodes;
        const path = try self.hits.path(target, scratch);
        if (path.len != 0) return path;
        const fallback = try scratch.alloc(handles.NodeId, 1);
        fallback[0] = target;
        return fallback;
    }

    fn textInputFocused(self: *const Router, nodes: *const compose_store.Store) bool {
        const focused = self.focus_manager.focused;
        const record = nodes.getConst(focused) orelse return false;
        return record.semantics.role == .text_field or record.semantics.role == .search_field;
    }
};

fn mergeRequestedDirty(
    nodes: *const compose_store.Store,
    node_id: handles.NodeId,
    state: *const event.Dispatch,
    result: *Result,
) void {
    const dirty = state.requested_dirty orelse return;
    const component = if (nodes.getConst(node_id)) |record| record.component else return;
    result.handled = true;
    if (result.window_dirty) return;
    if (result.narrow_component) |existing_component| {
        if (!existing_component.eql(component)) {
            result.window_dirty = true;
            result.narrow_component = null;
            result.narrow_dirty = null;
            return;
        }
        if (result.narrow_dirty) |*existing_dirty| existing_dirty.merge(dirty);
        return;
    }
    if (result.narrow_dirty == null) {
        result.narrow_component = component;
        result.narrow_dirty = dirty;
    }
}

fn callHandlers(
    nodes: *const compose_store.Store,
    hits: *const hit_tree.Tree,
    coordinator: *coordinator_mod.Coordinator,
    window: handles.WindowId,
    native_text_input: ?event.NativeTextInput,
    native_clipboard: ?event.NativeClipboard,
    node_id: handles.NodeId,
    state: *event.Dispatch,
    value: *const event.Event,
    phase: event.Phase,
    autofocus_request: ?*bool,
) Error!void {
    const record = nodes.getConst(node_id) orelse return;
    var context = makeContext(nodes, hits, coordinator, window, native_text_input, native_clipboard, node_id, autofocus_request) orelse return;
    for (record.handlers) |handler| {
        if (handler.phase != phase) continue;
        try handler.callback(handler.context, state, value, &context);
        if (state.propagation_stopped) return;
    }
}

fn callCustom(
    nodes: *const compose_store.Store,
    hits: *const hit_tree.Tree,
    coordinator: *coordinator_mod.Coordinator,
    window: handles.WindowId,
    native_text_input: ?event.NativeTextInput,
    native_clipboard: ?event.NativeClipboard,
    node_id: handles.NodeId,
    state: *event.Dispatch,
    value: *const event.Event,
    autofocus_request: ?*bool,
) Error!void {
    const record = nodes.getConst(node_id) orelse return;
    var context = makeContext(nodes, hits, coordinator, window, native_text_input, native_clipboard, node_id, autofocus_request) orelse return;
    context.custom_event_dirty = &state.requested_dirty;
    switch (record.kind) {
        .custom => |custom_node| if (custom_node.vtable.event) |callback| try callback(custom_node.context, state, value, &context),
        else => {},
    }
}

fn makeContext(
    nodes: *const compose_store.Store,
    hits: *const hit_tree.Tree,
    coordinator: *coordinator_mod.Coordinator,
    window: handles.WindowId,
    native_text_input: ?event.NativeTextInput,
    native_clipboard: ?event.NativeClipboard,
    node_id: handles.NodeId,
    autofocus_request: ?*bool,
) ?event.Context {
    const record = nodes.getConst(node_id) orelse return null;
    const visual = hits.visualEntry(node_id);
    return .{
        .coordinator = coordinator,
        .component = record.component,
        .window = window,
        .current_bounds = if (visual) |entry| entry.world_bounds else record.layout.bounds,
        .current_layout_bounds = record.layout.bounds,
        .current_content_bounds = record.layout.content_bounds,
        .current_scroll_extent = record.layout.scroll_extent,
        .local_to_world = if (visual) |entry| entry.world_transform else .identity,
        .world_to_local = if (visual) |entry| entry.inverse_transform else .identity,
        .native_text_input = native_text_input,
        .native_clipboard = native_clipboard,
        .autofocus_request = autofocus_request,
    };
}

fn pointerId(value: *const event.Event) ?u64 {
    return switch (value.*) {
        .pointer_down, .pointer_up, .pointer_move, .pointer_enter, .pointer_leave, .pointer_cancel => |pointer| pointer.pointer_id,
        else => null,
    };
}

fn eventPoint(value: *const event.Event) ?@import("../core/geometry.zig").Point {
    return switch (value.*) {
        .pointer_down, .pointer_up, .pointer_move, .pointer_enter, .pointer_leave, .pointer_cancel => |pointer| pointer.position,
        .scroll => |scroll| scroll.position,
        .file_drop_entered, .file_drop_updated, .file_drop_performed => |drop| drop.position,
        else => null,
    };
}

comptime {
    _ = custom;
}
