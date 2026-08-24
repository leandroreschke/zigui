const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const api = @import("../../a11y/api.zig");
const win = @import("abi.zig");
const uia = @import("uia_abi.zig");
const uia_text = @import("uia_text.zig");

pub const ActionSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, api.ActionRequest) void,

    fn emit(self: ActionSink, request: api.ActionRequest) void {
        self.emit_fn(self.context, request);
    }
};

pub const Host = struct {
    context: *anyopaque,
    window_fn: *const fn (*anyopaque, handles.WindowId) win.HWND,
    detach_fn: *const fn (*anyopaque, *Adapter) void,

    fn window(self: Host, id: handles.WindowId) win.HWND {
        return self.window_fn(self.context, id);
    }

    fn detach(self: Host, adapter: *Adapter) void {
        self.detach_fn(self.context, adapter);
    }
};

const PreparedNode = struct {
    source: api.Node,
    label: []u16,
    description: []u16,
    value: []u16,
    children: []*Provider,
    action_mask: u32,
    selection: ?uia_text.Selection,
    moved: bool = false,

    fn init(allocator: std.mem.Allocator, source: api.Node) Error!PreparedNode {
        const label = try std.unicode.utf8ToUtf16LeAlloc(allocator, source.label);
        errdefer allocator.free(label);
        const description = try std.unicode.utf8ToUtf16LeAlloc(allocator, source.description);
        errdefer allocator.free(description);
        const value = try std.unicode.utf8ToUtf16LeAlloc(allocator, source.value);
        errdefer allocator.free(value);
        return .{
            .source = source,
            .label = label,
            .description = description,
            .value = value,
            .children = try allocator.alloc(*Provider, source.children.len),
            .action_mask = actionMask(source.actions),
            .selection = textSelection(source.value, source.selection),
        };
    }

    fn deinit(self: *PreparedNode, allocator: std.mem.Allocator) void {
        if (!self.moved) {
            allocator.free(self.label);
            allocator.free(self.description);
            allocator.free(self.value);
            allocator.free(self.children);
        }
        self.* = undefined;
    }
};

const WindowState = struct {
    root: ?*Provider = null,
    providers: std.AutoHashMap(u64, *Provider),
    generation: u64 = 0,
    tree_hash: u64 = 0,

    fn init(allocator: std.mem.Allocator) WindowState {
        return .{ .providers = std.AutoHashMap(u64, *Provider).init(allocator) };
    }

    fn deinit(self: *WindowState) void {
        var iterator = self.providers.iterator();
        while (iterator.next()) |entry| {
            const provider = entry.value_ptr.*;
            provider.detach();
            _ = uia.UiaDisconnectProvider(&provider.simple);
            _ = provider.releaseReference();
        }
        self.providers.deinit();
        self.* = undefined;
    }
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    sink: ActionSink,
    host: Host,
    windows: std.AutoHashMap(u64, WindowState),
    maximum_windows: usize,
    maximum_nodes_per_window: usize,
    maximum_tree_bytes: usize,
    updating: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        sink: ActionSink,
        host: Host,
        maximum_windows: usize,
        maximum_nodes_per_window: usize,
        maximum_tree_bytes: usize,
    ) Error!api.Adapter {
        if (maximum_windows == 0 or maximum_nodes_per_window == 0 or maximum_tree_bytes == 0)
            return error.InvalidConfiguration;
        const self = try allocator.create(Adapter);
        self.* = .{
            .allocator = allocator,
            .sink = sink,
            .host = host,
            .windows = std.AutoHashMap(u64, WindowState).init(allocator),
            .maximum_windows = maximum_windows,
            .maximum_nodes_per_window = maximum_nodes_per_window,
            .maximum_tree_bytes = maximum_tree_bytes,
        };
        return .{ .context = self, .update_fn = updateOpaque, .focus_fn = focusOpaque, .remove_window_fn = removeWindowOpaque, .deinit_fn = deinitOpaque };
    }

    pub fn fromApi(adapter: api.Adapter) *Adapter {
        return @ptrCast(@alignCast(adapter.context));
    }

    pub fn handleGetObject(
        self: *Adapter,
        window: handles.WindowId,
        hwnd: win.HWND,
        wparam: win.WPARAM,
        lparam: win.LPARAM,
    ) ?win.LRESULT {
        if (lparam != uia.root_object_id) return null;
        const state = self.windows.getPtr(window.encode()) orelse return null;
        const root = state.root orelse return null;
        return uia.UiaReturnRawElementProvider(hwnd, wparam, lparam, &root.simple);
    }

    fn update(self: *Adapter, tree: *const api.Tree) Error!void {
        if (self.updating) return error.CallbackReentrancy;
        self.updating = true;
        defer self.updating = false;
        try api.validateTree(self.allocator, tree, .{
            .maximum_nodes = self.maximum_nodes_per_window,
            .maximum_bytes = self.maximum_tree_bytes,
        });
        if (!self.windows.contains(tree.window.encode()) and self.windows.count() >= self.maximum_windows)
            return error.BudgetExceeded;
        const state_result = try self.windows.getOrPut(tree.window.encode());
        if (!state_result.found_existing) state_result.value_ptr.* = WindowState.init(self.allocator);
        const state_is_new = !state_result.found_existing;
        errdefer if (state_is_new) {
            const removed = self.windows.fetchRemove(tree.window.encode()) orelse unreachable;
            var state = removed.value;
            state.deinit();
        };
        const state = state_result.value_ptr;
        if (!api.generationFollows(tree.generation, state.generation))
            return error.InvalidLayout;

        const prepared = try self.allocator.alloc(PreparedNode, tree.nodes.len);
        defer self.allocator.free(prepared);
        var prepared_count: usize = 0;
        defer {
            for (prepared[0..prepared_count]) |*node| node.deinit(self.allocator);
        }
        for (tree.nodes, 0..) |node, index| {
            prepared[index] = try PreparedNode.init(self.allocator, node);
            prepared_count += 1;
        }
        var active = std.AutoHashMap(u64, void).init(self.allocator);
        defer active.deinit();
        try active.ensureTotalCapacity(@intCast(tree.nodes.len));
        var missing_count: usize = 0;
        for (prepared) |item| {
            if (!active.contains(item.source.id.encode())) active.putAssumeCapacity(item.source.id.encode(), {});
            if (!state.providers.contains(item.source.id.encode())) missing_count += 1;
        }
        if (active.count() != tree.nodes.len or !active.contains(tree.root.encode())) return error.InvalidHandle;

        var created: std.ArrayList(u64) = .empty;
        defer created.deinit(self.allocator);
        try created.ensureTotalCapacity(self.allocator, missing_count);
        const maximum_retained = self.maximum_nodes_per_window +| self.maximum_nodes_per_window;
        if (missing_count > maximum_retained -| state.providers.count())
            return error.BudgetExceeded;
        try state.providers.ensureUnusedCapacity(@intCast(missing_count));
        errdefer {
            for (created.items) |encoded| {
                const removed = state.providers.fetchRemove(encoded) orelse continue;
                removed.value.detach();
                _ = removed.value.releaseReference();
            }
        }
        for (prepared) |item| {
            if (state.providers.contains(item.source.id.encode())) continue;
            const provider = try Provider.create(self, tree.window, item.source.id);
            state.providers.putAssumeCapacity(item.source.id.encode(), provider);
            created.appendAssumeCapacity(item.source.id.encode());
        }
        for (prepared) |*item| {
            for (item.source.children, 0..) |child, index| {
                item.children[index] = state.providers.get(child.encode()) orelse return error.InvalidHandle;
            }
        }

        const next_root = state.providers.get(tree.root.encode()) orelse return error.InvalidHandle;
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        try stale.ensureTotalCapacity(self.allocator, state.providers.count() - active.count());
        var stale_iterator = state.providers.iterator();
        while (stale_iterator.next()) |entry| {
            if (!active.contains(entry.key_ptr.*)) stale.appendAssumeCapacity(entry.key_ptr.*);
        }

        var next_hash = std.hash.Wyhash.init(0x77696e5f7569615f);
        const previous_tree_hash = state.tree_hash;
        const previous_generation = state.generation;
        state.generation = tree.generation;
        for (prepared) |*item| {
            const provider = state.providers.get(item.source.id.encode()) orelse return error.InvalidHandle;
            const parent = if (item.source.parent.isValid()) state.providers.get(item.source.parent.encode()) else null;
            next_hash.update(std.mem.asBytes(&item.source.id));
            next_hash.update(std.mem.asBytes(&item.source.parent));
            for (item.source.children) |child| next_hash.update(std.mem.asBytes(&child));

            const had_content = provider.content_initialized;
            const previous_focus = provider.focused;
            const previous_role = provider.role;
            const previous_disabled = provider.disabled;
            const previous_hidden = provider.hidden;
            const previous_selected = provider.selected;
            const previous_checked = provider.checked;
            const previous_expanded = provider.expanded;
            const previous_range_min = provider.range_min;
            const previous_range_max = provider.range_max;
            const previous_range_value = provider.range_value_number;
            const previous_read_only = !provider.supports(.set_value);
            const text_changed = had_content and !std.mem.eql(u16, providerTextContent(provider), preparedTextContent(item));
            const selection_changed = had_content and !sameSelection(provider.selection, item.selection);
            const old_label = if (had_content and !std.mem.eql(u16, provider.label, item.label)) uia.stringVariant(provider.label) else null;
            const old_description = if (had_content and !std.mem.eql(u16, provider.description, item.description)) uia.stringVariant(provider.description) else null;
            const old_value = if (had_content and !std.mem.eql(u16, provider.value, item.value)) uia.stringVariant(provider.value) else null;
            provider.take(item, parent, next_root, tree.generation);
            if (previous_generation != 0 and had_content) {
                raiseStringProperty(provider, uia.property_name, old_label, provider.label);
                raiseStringProperty(provider, uia.property_help_text, old_description, provider.description);
                raiseStringProperty(provider, uia.property_value_value, old_value, provider.value);
                if (previous_role != provider.role) raiseProperty(provider, uia.property_control_type, uia.intVariant(controlType(previous_role)), uia.intVariant(controlType(provider.role)));
                if (previous_disabled != provider.disabled) raiseProperty(provider, uia.property_is_enabled, uia.boolVariant(!previous_disabled), uia.boolVariant(!provider.disabled));
                if (previous_hidden != provider.hidden) {
                    raiseProperty(provider, uia.property_is_offscreen, uia.boolVariant(previous_hidden), uia.boolVariant(provider.hidden));
                    raiseProperty(provider, uia.property_is_control_element, uia.boolVariant(!previous_hidden), uia.boolVariant(!provider.hidden));
                    raiseProperty(provider, uia.property_is_content_element, uia.boolVariant(!previous_hidden), uia.boolVariant(!provider.hidden));
                }
                if (previous_focus != provider.focused) raiseProperty(provider, uia.property_has_keyboard_focus, uia.boolVariant(previous_focus), uia.boolVariant(provider.focused));
                if (previous_selected != provider.selected) raiseProperty(provider, uia.property_selection_item_selected, uia.boolVariant(previous_selected), uia.boolVariant(provider.selected));
                if (!std.meta.eql(previous_checked, provider.checked)) raiseProperty(provider, uia.property_toggle_state, uia.intVariant(toggleValue(previous_checked)), uia.intVariant(toggleValue(provider.checked)));
                if (!std.meta.eql(previous_expanded, provider.expanded)) raiseProperty(provider, uia.property_expand_state, uia.intVariant(expandValue(previous_expanded)), uia.intVariant(expandValue(provider.expanded)));
                if (!std.meta.eql(previous_range_min, provider.range_min)) raiseProperty(provider, uia.property_range_minimum, uia.doubleVariant(previous_range_min orelse 0), uia.doubleVariant(provider.range_min orelse 0));
                if (!std.meta.eql(previous_range_max, provider.range_max)) raiseProperty(provider, uia.property_range_maximum, uia.doubleVariant(previous_range_max orelse 100), uia.doubleVariant(provider.range_max orelse 100));
                if (!std.meta.eql(previous_range_value, provider.range_value_number)) raiseProperty(provider, uia.property_range_value, uia.doubleVariant(previous_range_value orelse 0), uia.doubleVariant(provider.range_value_number orelse 0));
                const next_read_only = !provider.supports(.set_value);
                if (previous_read_only != next_read_only) {
                    raiseProperty(provider, uia.property_value_is_read_only, uia.boolVariant(previous_read_only), uia.boolVariant(next_read_only));
                    raiseProperty(provider, uia.property_range_is_read_only, uia.boolVariant(previous_read_only), uia.boolVariant(next_read_only));
                }
                if (text_changed) _ = uia.UiaRaiseAutomationEvent(&provider.simple, uia.text_changed_event);
                if (selection_changed) _ = uia.UiaRaiseAutomationEvent(&provider.simple, uia.text_selection_changed_event);
                if (!previous_focus and provider.focused) _ = uia.UiaRaiseAutomationEvent(&provider.simple, uia.automation_focus_changed_event);
            } else {
                discardVariant(old_label);
                discardVariant(old_description);
                discardVariant(old_value);
            }
        }
        state.root = next_root;
        state.tree_hash = next_hash.final();

        for (stale.items) |encoded| {
            const removed = state.providers.fetchRemove(encoded) orelse continue;
            removed.value.detach();
            _ = uia.UiaDisconnectProvider(&removed.value.simple);
            _ = removed.value.releaseReference();
        }
        if (previous_tree_hash != 0 and previous_tree_hash != state.tree_hash) {
            const root = state.root orelse return;
            _ = uia.UiaRaiseStructureChangedEvent(&root.simple, uia.structure_children_invalidated, null, 0);
        }
    }

    fn focus(self: *Adapter, id: handles.SemanticId) Error!void {
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| {
            const provider = entry.value_ptr.providers.get(id.encode()) orelse continue;
            _ = uia.UiaRaiseAutomationEvent(&provider.simple, uia.automation_focus_changed_event);
            return;
        }
        return error.InvalidHandle;
    }

    fn removeWindow(self: *Adapter, id: handles.WindowId) void {
        const removed = self.windows.fetchRemove(id.encode()) orelse return;
        var state = removed.value;
        state.deinit();
    }

    fn emit(self: *Adapter, provider: *Provider, action: api.Action, value: ?[]const u8, selection: ?api.Selection) win.HRESULT {
        if (provider.adapter == null) return uia.element_not_available;
        if (provider.disabled) return uia.element_not_enabled;
        if (!provider.supports(action)) return uia.not_supported;
        self.sink.emit(.{
            .window = provider.window,
            .target = provider.semantic,
            .action = action,
            .value = value,
            .selection = selection,
        });
        return win.S_OK;
    }

    fn providerFromPoint(self: *Adapter, window: handles.WindowId, x: f64, y: f64) ?*Provider {
        const state = self.windows.getPtr(window.encode()) orelse return null;
        const root = state.root orelse return null;
        return deepestAt(self, root, x, y);
    }

    fn focusedProvider(self: *Adapter, window: handles.WindowId) ?*Provider {
        const state = self.windows.getPtr(window.encode()) orelse return null;
        var iterator = state.providers.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.*.focused) return entry.value_ptr.*;
        return state.root;
    }

    fn screenRect(self: *Adapter, provider: *const Provider) uia.Rect {
        const hwnd = self.host.window(provider.window) orelse return .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        var origin: win.POINT = .{};
        _ = win.ClientToScreen(hwnd, &origin);
        const dpi = win.GetDpiForWindow(hwnd);
        const scale: f64 = if (dpi == 0) 1 else @as(f64, @floatFromInt(dpi)) / 96;
        return .{
            .left = @as(f64, @floatCast(provider.bounds.origin.x)) * scale + @as(f64, @floatFromInt(origin.x)),
            .top = @as(f64, @floatCast(provider.bounds.origin.y)) * scale + @as(f64, @floatFromInt(origin.y)),
            .width = @as(f64, @floatCast(provider.bounds.size.width)) * scale,
            .height = @as(f64, @floatCast(provider.bounds.size.height)) * scale,
        };
    }

    fn deinit(self: *Adapter) void {
        self.host.detach(self);
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit();
        self.windows.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

const Provider = struct {
    simple: uia.Object = .{ .vtable = &simple_vtable },
    fragment: uia.Object = .{ .vtable = &fragment_vtable },
    fragment_root: uia.Object = .{ .vtable = &fragment_root_vtable },
    invoke: uia.Object = .{ .vtable = &invoke_vtable },
    toggle: uia.Object = .{ .vtable = &toggle_vtable },
    range_value: uia.Object = .{ .vtable = &range_value_vtable },
    value_provider: uia.Object = .{ .vtable = &value_vtable },
    selection_item: uia.Object = .{ .vtable = &selection_item_vtable },
    expand_collapse: uia.Object = .{ .vtable = &expand_collapse_vtable },
    text_provider: uia_text.Provider = undefined,
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    allocator: std.mem.Allocator,
    adapter: ?*Adapter,
    window: handles.WindowId,
    semantic: handles.SemanticId,
    automation_id: []u16,
    parent: ?*Provider = null,
    root: ?*Provider = null,
    children: []*Provider = &.{},
    label: []u16 = &.{},
    description: []u16 = &.{},
    value: []u16 = &.{},
    bounds: geometry.Rect = .{},
    role: api.Role = .none,
    actions: u32 = 0,
    selection: ?api.Selection = null,
    range_min: ?f64 = null,
    range_max: ?f64 = null,
    range_value_number: ?f64 = null,
    disabled: bool = false,
    hidden: bool = false,
    focused: bool = false,
    selected: bool = false,
    checked: ?bool = null,
    expanded: ?bool = null,
    multiline: bool = false,
    password: bool = false,
    seen_generation: u64 = 0,
    content_initialized: bool = false,

    fn create(adapter: *Adapter, window: handles.WindowId, semantic: handles.SemanticId) Error!*Provider {
        const self = try adapter.allocator.create(Provider);
        errdefer adapter.allocator.destroy(self);
        const identity = try std.fmt.allocPrint(adapter.allocator, "zigui-{d}-{d}-{d}-{d}", .{
            window.index,
            window.generation,
            semantic.index,
            semantic.generation,
        });
        defer adapter.allocator.free(identity);
        self.* = .{
            .allocator = adapter.allocator,
            .adapter = adapter,
            .window = window,
            .semantic = semantic,
            .automation_id = try std.unicode.utf8ToUtf16LeAlloc(adapter.allocator, identity),
        };
        self.text_provider = uia_text.Provider.init(.{
            .allocator = adapter.allocator,
            .context = self,
            .query_fn = textQuery,
            .retain_fn = textRetain,
            .release_fn = textRelease,
            .available_fn = textAvailable,
            .value_fn = textValue,
            .selection_fn = textCurrentSelection,
            .bounds_fn = textBounds,
            .enclosing_fn = textEnclosing,
            .select_fn = textSelect,
            .read_only_fn = textReadOnly,
            .hidden_fn = textHidden,
            .multiline_fn = textMultiline,
            .selectable_fn = textSelectable,
        });
        return self;
    }

    fn take(self: *Provider, prepared: *PreparedNode, parent: ?*Provider, root: *Provider, generation: u64) void {
        if (self.content_initialized) {
            self.allocator.free(self.label);
            self.allocator.free(self.description);
            self.allocator.free(self.value);
            self.allocator.free(self.children);
        }
        self.label = prepared.label;
        self.description = prepared.description;
        self.value = prepared.value;
        self.children = prepared.children;
        prepared.moved = true;
        const node = prepared.source;
        self.parent = parent;
        self.root = root;
        self.bounds = node.bounds;
        self.role = node.role;
        self.actions = prepared.action_mask;
        self.selection = if (prepared.selection) |selection| .{ .anchor = selection.start, .focus = selection.end } else null;
        self.range_min = node.range_min;
        self.range_max = node.range_max;
        self.range_value_number = node.range_value;
        self.disabled = node.disabled;
        self.hidden = node.hidden;
        self.focused = node.focused;
        self.selected = node.selected;
        self.checked = node.checked;
        self.expanded = node.expanded;
        self.multiline = node.multiline;
        self.password = node.password;
        self.seen_generation = generation;
        self.content_initialized = true;
    }

    fn detach(self: *Provider) void {
        self.adapter = null;
        self.parent = null;
        self.root = null;
    }

    fn retain(self: *Provider) u32 {
        return self.references.fetchAdd(1, .monotonic) + 1;
    }

    fn releaseReference(self: *Provider) u32 {
        const previous = self.references.fetchSub(1, .acq_rel);
        if (previous == 1) {
            const allocator = self.allocator;
            allocator.free(self.automation_id);
            if (self.content_initialized) {
                allocator.free(self.label);
                allocator.free(self.description);
                allocator.free(self.value);
                allocator.free(self.children);
            }
            allocator.destroy(self);
            return 0;
        }
        return previous - 1;
    }

    fn supports(self: *const Provider, action: api.Action) bool {
        return self.actions & (@as(u32, 1) << @backingInt(action)) != 0;
    }

    fn contentHash(self: *const Provider) u64 {
        var hash = std.hash.Wyhash.init(0x7569615f6e6f6465);
        hash.update(self.label);
        hash.update(self.description);
        hash.update(self.value);
        hash.update(std.mem.asBytes(&self.bounds));
        hash.update(std.mem.asBytes(&self.role));
        hash.update(std.mem.asBytes(&self.actions));
        hash.update(std.mem.asBytes(&self.disabled));
        hash.update(std.mem.asBytes(&self.hidden));
        hash.update(std.mem.asBytes(&self.focused));
        hash.update(std.mem.asBytes(&self.selected));
        hash.update(std.mem.asBytes(&self.checked));
        hash.update(std.mem.asBytes(&self.expanded));
        hash.update(std.mem.asBytes(&self.range_value_number));
        for (self.children) |child| hash.update(std.mem.asBytes(&child.semantic));
        return hash.final();
    }

    fn query(self: *Provider, id: *const win.GUID, output: *?*anyopaque) win.HRESULT {
        output.* = null;
        const object: ?*uia.Object = if (id.eql(uia.iid_iunknown) or id.eql(uia.iid_simple))
            &self.simple
        else if (id.eql(uia.iid_fragment))
            &self.fragment
        else if (id.eql(uia.iid_fragment_root) and self.root == self)
            &self.fragment_root
        else if (id.eql(uia.iid_invoke) and self.supports(.activate))
            &self.invoke
        else if (id.eql(uia.iid_toggle) and self.checked != null)
            &self.toggle
        else if (id.eql(uia.iid_range_value) and self.range_value_number != null)
            &self.range_value
        else if (id.eql(uia.iid_value) and hasValuePattern(self))
            &self.value_provider
        else if (id.eql(uia.iid_selection_item) and hasSelectionPattern(self))
            &self.selection_item
        else if (id.eql(uia.iid_expand_collapse) and self.expanded != null)
            &self.expand_collapse
        else if (id.eql(uia.iid_text_provider) and hasTextPattern(self))
            &self.text_provider.object
        else
            null;
        const selected = object orelse return win.E_NOINTERFACE;
        output.* = selected;
        _ = self.retain();
        return win.S_OK;
    }

    fn pattern(self: *Provider, pattern_id: i32) ?*uia.Object {
        return switch (pattern_id) {
            uia.invoke_pattern => if (self.supports(.activate)) &self.invoke else null,
            uia.toggle_pattern => if (self.checked != null) &self.toggle else null,
            uia.range_value_pattern => if (self.range_value_number != null) &self.range_value else null,
            uia.value_pattern => if (hasValuePattern(self)) &self.value_provider else null,
            uia.selection_item_pattern => if (hasSelectionPattern(self)) &self.selection_item else null,
            uia.expand_collapse_pattern => if (self.expanded != null) &self.expand_collapse else null,
            uia.text_pattern => if (hasTextPattern(self)) &self.text_provider.object else null,
            else => null,
        };
    }
};

const simple_vtable: uia.SimpleVTable = .{
    .query_interface = simpleQuery,
    .add_ref = simpleAddRef,
    .release = simpleRelease,
    .provider_options = providerOptions,
    .get_pattern_provider = getPatternProvider,
    .get_property_value = getPropertyValue,
    .host_raw_element_provider = hostRawElementProvider,
};

fn simpleParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("simple", object));
}
fn simpleQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return simpleParent(object).query(id, output);
}
fn simpleAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return simpleParent(object).retain();
}
fn simpleRelease(object: *uia.Object) callconv(.winapi) u32 {
    return simpleParent(object).releaseReference();
}
fn providerOptions(object: *uia.Object, output: *i32) callconv(.winapi) win.HRESULT {
    if (simpleParent(object).adapter == null) return uia.element_not_available;
    output.* = uia.provider_server_side | uia.provider_owns_set_focus;
    return win.S_OK;
}
fn getPatternProvider(object: *uia.Object, pattern_id: i32, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = simpleParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = self.pattern(pattern_id);
    if (output.* != null) _ = self.retain();
    return win.S_OK;
}
fn getPropertyValue(object: *uia.Object, property_id: i32, output: *uia.Variant) callconv(.winapi) win.HRESULT {
    const self = simpleParent(object);
    output.* = uia.emptyVariant();
    if (self.adapter == null) return uia.element_not_available;
    output.* = switch (property_id) {
        uia.property_control_type => uia.intVariant(controlType(self.role)),
        uia.property_name => uia.stringVariant(self.label) orelse return uia.out_of_memory,
        uia.property_help_text => uia.stringVariant(self.description) orelse return uia.out_of_memory,
        uia.property_automation_id => uia.stringVariant(self.automation_id) orelse return uia.out_of_memory,
        uia.property_class_name, uia.property_framework_id => uia.stringVariant(std.unicode.utf8ToUtf16LeStringLiteral("ZigUI")) orelse return uia.out_of_memory,
        uia.property_has_keyboard_focus => uia.boolVariant(self.focused),
        uia.property_is_keyboard_focusable => uia.boolVariant(self.supports(.focus)),
        uia.property_is_enabled => uia.boolVariant(!self.disabled),
        uia.property_is_control_element, uia.property_is_content_element => uia.boolVariant(!self.hidden),
        uia.property_is_password => uia.boolVariant(self.password),
        uia.property_is_offscreen => uia.boolVariant(self.hidden),
        uia.property_native_window_handle => uia.intVariant(nativeWindowValue(self)),
        uia.property_value_value => uia.stringVariant(self.value) orelse return uia.out_of_memory,
        uia.property_value_is_read_only, uia.property_range_is_read_only => uia.boolVariant(!self.supports(.set_value)),
        uia.property_range_value => uia.doubleVariant(self.range_value_number orelse 0),
        uia.property_range_minimum => uia.doubleVariant(self.range_min orelse 0),
        uia.property_range_maximum => uia.doubleVariant(self.range_max orelse 100),
        uia.property_range_large_change => uia.doubleVariant(rangeStep(self) * 10),
        uia.property_range_small_change => uia.doubleVariant(rangeStep(self)),
        uia.property_toggle_state => uia.intVariant(if (self.checked orelse false) uia.toggle_on else uia.toggle_off),
        uia.property_expand_state => uia.intVariant(if (self.expanded) |expanded| if (expanded) uia.expand_expanded else uia.expand_collapsed else uia.expand_leaf),
        uia.property_selection_item_selected => uia.boolVariant(self.selected),
        else => uia.emptyVariant(),
    };
    return win.S_OK;
}
fn hostRawElementProvider(object: *uia.Object, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = simpleParent(object);
    output.* = null;
    const adapter = self.adapter orelse return uia.element_not_available;
    if (self.root != self) return win.S_OK;
    const hwnd = adapter.host.window(self.window) orelse return uia.element_not_available;
    return uia.UiaHostProviderFromHwnd(hwnd, output);
}

const fragment_vtable: uia.FragmentVTable = .{
    .query_interface = fragmentQuery,
    .add_ref = fragmentAddRef,
    .release = fragmentRelease,
    .navigate = navigate,
    .get_runtime_id = getRuntimeId,
    .bounding_rectangle = boundingRectangle,
    .embedded_fragment_roots = embeddedFragmentRoots,
    .set_focus = setFocus,
    .fragment_root = getFragmentRoot,
};
fn fragmentParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("fragment", object));
}
fn fragmentQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return fragmentParent(object).query(id, output);
}
fn fragmentAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return fragmentParent(object).retain();
}
fn fragmentRelease(object: *uia.Object) callconv(.winapi) u32 {
    return fragmentParent(object).releaseReference();
}
fn navigate(object: *uia.Object, direction: i32, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = fragmentParent(object);
    output.* = null;
    if (self.adapter == null) return uia.element_not_available;
    const target: ?*Provider = switch (direction) {
        uia.navigate_parent => self.parent,
        uia.navigate_first_child => if (self.children.len == 0) null else self.children[0],
        uia.navigate_last_child => if (self.children.len == 0) null else self.children[self.children.len - 1],
        uia.navigate_next_sibling => sibling(self, 1),
        uia.navigate_previous_sibling => sibling(self, -1),
        else => null,
    };
    if (target) |provider| {
        output.* = &provider.fragment;
        _ = provider.retain();
    }
    return win.S_OK;
}
fn getRuntimeId(object: *uia.Object, output: *?*uia.SafeArray) callconv(.winapi) win.HRESULT {
    const self = fragmentParent(object);
    output.* = null;
    if (self.adapter == null) return uia.element_not_available;
    const array = uia.SafeArrayCreateVector(uia.variant_i4, 0, 5) orelse return uia.out_of_memory;
    var raw: ?*anyopaque = null;
    if (win.succeeded(uia.SafeArrayAccessData(array, &raw)) and raw != null) {
        const values: [*]i32 = @ptrCast(@alignCast(raw.?));
        values[0] = uia.append_runtime_id;
        values[1] = @bitCast(self.window.index);
        values[2] = @bitCast(self.window.generation);
        values[3] = @bitCast(self.semantic.index);
        values[4] = @bitCast(self.semantic.generation);
        if (win.succeeded(uia.SafeArrayUnaccessData(array))) {
            output.* = array;
            return win.S_OK;
        }
    }
    _ = uia.SafeArrayDestroy(array);
    return win.E_FAIL;
}
fn boundingRectangle(object: *uia.Object, output: *uia.Rect) callconv(.winapi) win.HRESULT {
    const self = fragmentParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    output.* = adapter.screenRect(self);
    return win.S_OK;
}
fn embeddedFragmentRoots(object: *uia.Object, output: *?*uia.SafeArray) callconv(.winapi) win.HRESULT {
    if (fragmentParent(object).adapter == null) return uia.element_not_available;
    output.* = null;
    return win.S_OK;
}
fn setFocus(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = fragmentParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    return adapter.emit(self, .focus, null, null);
}
fn getFragmentRoot(object: *uia.Object, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = fragmentParent(object);
    output.* = null;
    if (self.adapter == null) return uia.element_not_available;
    const root = self.root orelse return uia.element_not_available;
    output.* = &root.fragment_root;
    _ = root.retain();
    return win.S_OK;
}

const fragment_root_vtable: uia.FragmentRootVTable = .{
    .query_interface = rootQuery,
    .add_ref = rootAddRef,
    .release = rootRelease,
    .element_from_point = elementFromPoint,
    .get_focus = getFocus,
};
fn rootParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("fragment_root", object));
}
fn rootQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return rootParent(object).query(id, output);
}
fn rootAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return rootParent(object).retain();
}
fn rootRelease(object: *uia.Object) callconv(.winapi) u32 {
    return rootParent(object).releaseReference();
}
fn elementFromPoint(object: *uia.Object, x: f64, y: f64, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = rootParent(object);
    output.* = null;
    const adapter = self.adapter orelse return uia.element_not_available;
    if (adapter.providerFromPoint(self.window, x, y)) |provider| {
        output.* = &provider.fragment;
        _ = provider.retain();
    }
    return win.S_OK;
}
fn getFocus(object: *uia.Object, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = rootParent(object);
    output.* = null;
    const adapter = self.adapter orelse return uia.element_not_available;
    if (adapter.focusedProvider(self.window)) |provider| {
        output.* = &provider.fragment;
        _ = provider.retain();
    }
    return win.S_OK;
}

const invoke_vtable: uia.InvokeVTable = .{ .query_interface = invokeQuery, .add_ref = invokeAddRef, .release = invokeRelease, .invoke = invokeAction };
fn invokeParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("invoke", object));
}
fn invokeQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return invokeParent(object).query(id, output);
}
fn invokeAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return invokeParent(object).retain();
}
fn invokeRelease(object: *uia.Object) callconv(.winapi) u32 {
    return invokeParent(object).releaseReference();
}
fn invokeAction(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = invokeParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    const result = adapter.emit(self, .activate, null, null);
    if (win.succeeded(result)) _ = uia.UiaRaiseAutomationEvent(&self.simple, uia.invoke_invoked_event);
    return result;
}

const toggle_vtable: uia.ToggleVTable = .{ .query_interface = toggleQuery, .add_ref = toggleAddRef, .release = toggleRelease, .toggle = toggleAction, .get_state = toggleState };
fn toggleParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("toggle", object));
}
fn toggleQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return toggleParent(object).query(id, output);
}
fn toggleAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return toggleParent(object).retain();
}
fn toggleRelease(object: *uia.Object) callconv(.winapi) u32 {
    return toggleParent(object).releaseReference();
}
fn toggleAction(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = toggleParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    return adapter.emit(self, .activate, null, null);
}
fn toggleState(object: *uia.Object, output: *i32) callconv(.winapi) win.HRESULT {
    const self = toggleParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = if (self.checked) |checked| if (checked) uia.toggle_on else uia.toggle_off else uia.toggle_indeterminate;
    return win.S_OK;
}

const range_value_vtable: uia.RangeValueVTable = .{
    .query_interface = rangeQuery,
    .add_ref = rangeAddRef,
    .release = rangeRelease,
    .set_value = rangeSetValue,
    .get_value = rangeGetValue,
    .get_is_read_only = rangeReadOnly,
    .get_maximum = rangeMaximum,
    .get_minimum = rangeMinimum,
    .get_large_change = rangeLargeChange,
    .get_small_change = rangeSmallChange,
};
fn rangeParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("range_value", object));
}
fn rangeQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return rangeParent(object).query(id, output);
}
fn rangeAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return rangeParent(object).retain();
}
fn rangeRelease(object: *uia.Object) callconv(.winapi) u32 {
    return rangeParent(object).releaseReference();
}
fn rangeSetValue(object: *uia.Object, number: f64) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    if (!std.math.isFinite(number)) return win.E_INVALIDARG;
    var buffer: [64]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return win.E_FAIL;
    return adapter.emit(self, .set_value, value, null);
}
fn rangeGetValue(object: *uia.Object, output: *f64) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = self.range_value_number orelse 0;
    return win.S_OK;
}
fn rangeReadOnly(object: *uia.Object, output: *win.BOOL) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = @intFromBool(!self.supports(.set_value));
    return win.S_OK;
}
fn rangeMaximum(object: *uia.Object, output: *f64) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = self.range_max orelse 100;
    return win.S_OK;
}
fn rangeMinimum(object: *uia.Object, output: *f64) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = self.range_min orelse 0;
    return win.S_OK;
}
fn rangeLargeChange(object: *uia.Object, output: *f64) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = rangeStep(self) * 10;
    return win.S_OK;
}
fn rangeSmallChange(object: *uia.Object, output: *f64) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = rangeStep(self);
    return win.S_OK;
}

const value_vtable: uia.ValueVTable = .{ .query_interface = valueQuery, .add_ref = valueAddRef, .release = valueRelease, .set_value = valueSet, .get_value = valueGet, .get_is_read_only = valueReadOnly };
fn valueParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("value_provider", object));
}
fn valueQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return valueParent(object).query(id, output);
}
fn valueAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return valueParent(object).retain();
}
fn valueRelease(object: *uia.Object) callconv(.winapi) u32 {
    return valueParent(object).releaseReference();
}
fn valueSet(object: *uia.Object, wide: ?[*:0]const u16) callconv(.winapi) win.HRESULT {
    const self = valueParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    const units: []const u16 = if (wide) |value| value[0..std.mem.len(value)] else &.{};
    const bytes = std.unicode.utf16LeToUtf8Alloc(self.allocator, units) catch return win.E_INVALIDARG;
    defer self.allocator.free(bytes);
    return adapter.emit(self, .set_value, bytes, null);
}
fn valueGet(object: *uia.Object, output: *uia.BStr) callconv(.winapi) win.HRESULT {
    const self = valueParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = uia.SysAllocStringLen(if (self.value.len == 0) null else self.value.ptr, @intCast(self.value.len));
    if (output.* == null and self.value.len != 0) return uia.out_of_memory;
    return win.S_OK;
}
fn valueReadOnly(object: *uia.Object, output: *win.BOOL) callconv(.winapi) win.HRESULT {
    const self = valueParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = @intFromBool(!self.supports(.set_value));
    return win.S_OK;
}

const selection_item_vtable: uia.SelectionItemVTable = .{
    .query_interface = selectionQuery,
    .add_ref = selectionAddRef,
    .release = selectionRelease,
    .select = selectionSelect,
    .add_to_selection = selectionAdd,
    .remove_from_selection = selectionRemove,
    .get_is_selected = selectionSelected,
    .get_selection_container = selectionContainer,
};
fn selectionParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("selection_item", object));
}
fn selectionQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return selectionParent(object).query(id, output);
}
fn selectionAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return selectionParent(object).retain();
}
fn selectionRelease(object: *uia.Object) callconv(.winapi) u32 {
    return selectionParent(object).releaseReference();
}
fn selectionSelect(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = selectionParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    const result = if (self.selected) win.S_OK else adapter.emit(self, .activate, null, null);
    if (win.succeeded(result)) _ = uia.UiaRaiseAutomationEvent(&self.simple, uia.selection_item_selected_event);
    return result;
}
fn selectionAdd(object: *uia.Object) callconv(.winapi) win.HRESULT {
    return selectionSelect(object);
}
fn selectionRemove(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = selectionParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    return if (!self.selected) win.S_OK else adapter.emit(self, .activate, null, null);
}
fn selectionSelected(object: *uia.Object, output: *win.BOOL) callconv(.winapi) win.HRESULT {
    const self = selectionParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = @intFromBool(self.selected);
    return win.S_OK;
}
fn selectionContainer(object: *uia.Object, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = selectionParent(object);
    output.* = null;
    if (self.adapter == null) return uia.element_not_available;
    var parent = self.parent;
    while (parent) |candidate| : (parent = candidate.parent) {
        if (isSelectionContainer(candidate.role)) {
            output.* = &candidate.simple;
            _ = candidate.retain();
            break;
        }
    }
    return win.S_OK;
}

const expand_collapse_vtable: uia.ExpandCollapseVTable = .{ .query_interface = expandQuery, .add_ref = expandAddRef, .release = expandRelease, .expand = expandAction, .collapse = collapseAction, .get_state = expandState };
fn expandParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("expand_collapse", object));
}
fn expandQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return expandParent(object).query(id, output);
}
fn expandAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return expandParent(object).retain();
}
fn expandRelease(object: *uia.Object) callconv(.winapi) u32 {
    return expandParent(object).releaseReference();
}
fn expandAction(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = expandParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    return if (self.expanded orelse false) win.S_OK else adapter.emit(self, .activate, null, null);
}
fn collapseAction(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = expandParent(object);
    const adapter = self.adapter orelse return uia.element_not_available;
    return if (!(self.expanded orelse false)) win.S_OK else adapter.emit(self, .activate, null, null);
}
fn expandState(object: *uia.Object, output: *i32) callconv(.winapi) win.HRESULT {
    const self = expandParent(object);
    if (self.adapter == null) return uia.element_not_available;
    output.* = if (self.expanded) |expanded| if (expanded) uia.expand_expanded else uia.expand_collapsed else uia.expand_leaf;
    return win.S_OK;
}

fn updateOpaque(raw: *anyopaque, tree: *const api.Tree) Error!void {
    try cast(raw).update(tree);
}
fn focusOpaque(raw: *anyopaque, id: handles.SemanticId) Error!void {
    try cast(raw).focus(id);
}
fn removeWindowOpaque(raw: *anyopaque, id: handles.WindowId) void {
    cast(raw).removeWindow(id);
}
fn deinitOpaque(raw: *anyopaque) void {
    cast(raw).deinit();
}
fn cast(raw: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(raw));
}

fn actionMask(actions: []const api.Action) u32 {
    var mask: u32 = 0;
    for (actions) |action| mask |= @as(u32, 1) << @backingInt(action);
    return mask;
}

fn hasValuePattern(provider: *const Provider) bool {
    return provider.role == .text_field or provider.role == .search_field or provider.value.len != 0 or provider.supports(.set_value);
}

fn hasTextPattern(provider: *const Provider) bool {
    return switch (provider.role) {
        .text, .text_field, .search_field, .static_text, .heading => true,
        else => provider.multiline,
    };
}

fn providerTextContent(provider: *const Provider) []const u16 {
    return switch (provider.role) {
        .text, .static_text, .heading => if (provider.value.len != 0) provider.value else provider.label,
        else => provider.value,
    };
}

fn preparedTextContent(prepared: *const PreparedNode) []const u16 {
    return switch (prepared.source.role) {
        .text, .static_text, .heading => if (prepared.value.len != 0) prepared.value else prepared.label,
        else => prepared.value,
    };
}

fn sameSelection(left: ?api.Selection, right: ?uia_text.Selection) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.anchor == right.?.start and left.?.focus == right.?.end;
}

fn raiseProperty(provider: *Provider, property: i32, old_source: uia.Variant, new_source: uia.Variant) void {
    var old_value = old_source;
    var new_value = new_source;
    defer _ = uia.VariantClear(&old_value);
    defer _ = uia.VariantClear(&new_value);
    _ = uia.UiaRaiseAutomationPropertyChangedEvent(&provider.simple, property, old_value, new_value);
}

fn raiseStringProperty(provider: *Provider, property: i32, old_source: ?uia.Variant, next: []const u16) void {
    const old_value = old_source orelse return;
    const new_value = uia.stringVariant(next) orelse {
        var discarded = old_value;
        _ = uia.VariantClear(&discarded);
        return;
    };
    raiseProperty(provider, property, old_value, new_value);
}

fn discardVariant(source: ?uia.Variant) void {
    var value = source orelse return;
    _ = uia.VariantClear(&value);
}

fn toggleValue(value: ?bool) i32 {
    return if (value) |checked| if (checked) uia.toggle_on else uia.toggle_off else uia.toggle_indeterminate;
}

fn expandValue(value: ?bool) i32 {
    return if (value) |expanded| if (expanded) uia.expand_expanded else uia.expand_collapsed else uia.expand_leaf;
}

fn textProvider(raw: *anyopaque) *Provider {
    return @ptrCast(@alignCast(raw));
}

fn textQuery(raw: *anyopaque, id: *const win.GUID, output: *?*anyopaque) win.HRESULT {
    return textProvider(raw).query(id, output);
}

fn textRetain(raw: *anyopaque) u32 {
    return textProvider(raw).retain();
}

fn textRelease(raw: *anyopaque) u32 {
    return textProvider(raw).releaseReference();
}

fn textAvailable(raw: *anyopaque) bool {
    return textProvider(raw).adapter != null;
}

fn textValue(raw: *anyopaque) []const u16 {
    return providerTextContent(textProvider(raw));
}

fn textCurrentSelection(raw: *anyopaque) ?uia_text.Selection {
    const selection = textProvider(raw).selection orelse return null;
    return .{ .start = selection.anchor, .end = selection.focus };
}

fn textBounds(raw: *anyopaque) uia.Rect {
    const provider = textProvider(raw);
    const adapter = provider.adapter orelse return .{ .left = 0, .top = 0, .width = 0, .height = 0 };
    return adapter.screenRect(provider);
}

fn textEnclosing(raw: *anyopaque) *uia.Object {
    return &textProvider(raw).simple;
}

fn textSelect(raw: *anyopaque, selection: uia_text.Selection) win.HRESULT {
    const provider = textProvider(raw);
    const adapter = provider.adapter orelse return uia.element_not_available;
    const value = textValue(raw);
    return adapter.emit(provider, .set_selection, null, .{
        .anchor = utf16UnitsToUtf8Offset(value, selection.start),
        .focus = utf16UnitsToUtf8Offset(value, selection.end),
    });
}

fn textReadOnly(raw: *anyopaque) bool {
    return !textProvider(raw).supports(.set_value);
}

fn textHidden(raw: *anyopaque) bool {
    return textProvider(raw).hidden;
}

fn textMultiline(raw: *anyopaque) bool {
    return textProvider(raw).multiline;
}

fn textSelectable(raw: *anyopaque) bool {
    return textProvider(raw).supports(.set_selection);
}

fn textSelection(value: []const u8, source: ?api.Selection) ?uia_text.Selection {
    const selection = source orelse return null;
    return .{
        .start = utf8OffsetToUtf16Units(value, selection.anchor),
        .end = utf8OffsetToUtf16Units(value, selection.focus),
    };
}

fn utf8OffsetToUtf16Units(value: []const u8, requested: usize) usize {
    const limit = @min(requested, value.len);
    var byte_index: usize = 0;
    var units: usize = 0;
    while (byte_index < limit) {
        const sequence_length = std.unicode.utf8ByteSequenceLength(value[byte_index]) catch break;
        if (byte_index + sequence_length > limit or byte_index + sequence_length > value.len) break;
        const scalar = std.unicode.utf8Decode(value[byte_index..][0..sequence_length]) catch break;
        units += if (scalar > 0xffff) 2 else 1;
        byte_index += sequence_length;
    }
    return units;
}

fn utf16UnitsToUtf8Offset(value: []const u16, requested: usize) usize {
    const limit = @min(requested, value.len);
    var unit_index: usize = 0;
    var bytes: usize = 0;
    while (unit_index < limit) {
        const first = value[unit_index];
        var scalar: u21 = first;
        var width: usize = 1;
        if (first >= 0xd800 and first <= 0xdbff and unit_index + 1 < value.len and value[unit_index + 1] >= 0xdc00 and value[unit_index + 1] <= 0xdfff) {
            if (unit_index + 2 > limit) break;
            scalar = 0x10000 + (@as(u21, first - 0xd800) << 10) + @as(u21, value[unit_index + 1] - 0xdc00);
            width = 2;
        }
        bytes += if (scalar <= 0x7f) 1 else if (scalar <= 0x7ff) 2 else if (scalar <= 0xffff) 3 else 4;
        unit_index += width;
    }
    return bytes;
}

fn hasSelectionPattern(provider: *const Provider) bool {
    return switch (provider.role) {
        .list_item, .tree_item, .tab, .row, .cell, .menu_item_radio => true,
        else => provider.selected,
    };
}

fn isSelectionContainer(role: api.Role) bool {
    return switch (role) {
        .list, .tree, .tab_list, .grid, .menu => true,
        else => false,
    };
}

fn sibling(provider: *Provider, offset: i32) ?*Provider {
    const parent = provider.parent orelse return null;
    var index: usize = 0;
    while (index < parent.children.len and parent.children[index] != provider) : (index += 1) {}
    if (index == parent.children.len) return null;
    if (offset < 0) return if (index == 0) null else parent.children[index - 1];
    return if (index + 1 >= parent.children.len) null else parent.children[index + 1];
}

fn deepestAt(adapter: *Adapter, provider: *Provider, x: f64, y: f64) ?*Provider {
    if (provider.hidden or !contains(adapter.screenRect(provider), x, y)) return null;
    var index = provider.children.len;
    while (index != 0) {
        index -= 1;
        if (deepestAt(adapter, provider.children[index], x, y)) |child| return child;
    }
    return provider;
}

fn contains(rect: uia.Rect, x: f64, y: f64) bool {
    return x >= rect.left and y >= rect.top and x <= rect.left + rect.width and y <= rect.top + rect.height;
}

fn rangeStep(provider: *const Provider) f64 {
    const minimum = provider.range_min orelse 0;
    const maximum = provider.range_max orelse 100;
    return @max((maximum - minimum) / 100, 0.000001);
}

fn nativeWindowValue(provider: *const Provider) i32 {
    if (provider.root != provider) return 0;
    const adapter = provider.adapter orelse return 0;
    const hwnd = adapter.host.window(provider.window) orelse return 0;
    return @bitCast(@as(u32, @truncate(@intFromPtr(hwnd))));
}

fn controlType(role: api.Role) i32 {
    return switch (role) {
        .application, .window, .dialog, .alert => uia.control_window,
        .group => uia.control_group,
        .button => uia.control_button,
        .checkbox, .switch_control => uia.control_checkbox,
        .radio => uia.control_radio,
        .slider => uia.control_slider,
        .progress_indicator => uia.control_progress,
        .text, .static_text, .heading => uia.control_text,
        .text_field, .search_field => uia.control_edit,
        .link => uia.control_hyperlink,
        .image => uia.control_image,
        .list => uia.control_list,
        .list_item => uia.control_list_item,
        .tree => uia.control_tree,
        .tree_item => uia.control_tree_item,
        .grid => uia.control_data_grid,
        .row, .cell => uia.control_data_item,
        .menu => uia.control_menu,
        .menu_item, .menu_item_checkbox, .menu_item_radio => uia.control_menu_item,
        .tab_list => uia.control_tab,
        .tab => uia.control_tab_item,
        .tab_panel, .scroll_view => uia.control_pane,
        .toolbar => uia.control_toolbar,
        .tooltip => uia.control_tooltip,
        .separator => uia.control_separator,
        .none, .canvas => uia.control_custom,
    };
}
