const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const api = @import("../../a11y/api.zig");
const objc = @import("objc.zig");
const types = @import("types.zig");

extern "c" fn NSAccessibilityPostNotification(element: objc.Id, notification: objc.Id) void;

pub const ActionSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, api.ActionRequest) void,

    fn emit(self: ActionSink, request: api.ActionRequest) void {
        self.emit_fn(self.context, request);
    }
};

pub const Host = struct {
    context: *anyopaque,
    parent_fn: *const fn (*anyopaque, handles.WindowId) objc.Id,
    screen_rect_fn: *const fn (*anyopaque, handles.WindowId, geometry.Rect) types.Rect,

    fn parent(self: Host, window: handles.WindowId) objc.Id {
        return self.parent_fn(self.context, window);
    }

    fn screenRect(self: Host, window: handles.WindowId, rect: geometry.Rect) types.Rect {
        return self.screen_rect_fn(self.context, window, rect);
    }
};

const Element = struct {
    object: objc.Id,
    actions: u32 = 0,
    seen_generation: u64 = 0,
    content_hash: u64 = 0,
    focused: bool = false,
    notify_value: bool = false,
    notify_focus: bool = false,
};

const WindowState = struct {
    root: handles.SemanticId = .invalid,
    generation: u64 = 0,
    tree_hash: u64 = 0,
    elements: std.AutoHashMap(u64, Element),

    fn init(allocator: std.mem.Allocator) WindowState {
        return .{ .elements = std.AutoHashMap(u64, Element).init(allocator) };
    }

    fn deinit(self: *WindowState) void {
        var iterator = self.elements.iterator();
        while (iterator.next()) |entry| {
            _ = objc.setIvar(?*Adapter, entry.value_ptr.object, "_ziguiAdapter", null);
            objc.release(entry.value_ptr.object);
        }
        self.elements.deinit();
        self.* = undefined;
    }
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    sink: ActionSink,
    host: Host,
    element_class: objc.Class,
    windows: std.AutoHashMap(u64, WindowState),
    maximum_windows: usize,
    maximum_nodes_per_window: usize,
    maximum_retained_elements_per_window: usize,
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
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .sink = sink,
            .host = host,
            .element_class = try registerElementClass(),
            .windows = std.AutoHashMap(u64, WindowState).init(allocator),
            .maximum_windows = maximum_windows,
            .maximum_nodes_per_window = maximum_nodes_per_window,
            .maximum_retained_elements_per_window = maximum_nodes_per_window +| maximum_nodes_per_window,
            .maximum_tree_bytes = maximum_tree_bytes,
        };
        return .{ .context = self, .update_fn = updateOpaque, .focus_fn = focusOpaque, .remove_window_fn = removeWindowOpaque, .deinit_fn = deinitOpaque };
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
        const result = try self.windows.getOrPut(tree.window.encode());
        if (!result.found_existing) result.value_ptr.* = WindowState.init(self.allocator);
        const state_is_new = !result.found_existing;
        errdefer if (state_is_new) {
            const removed = self.windows.fetchRemove(tree.window.encode()) orelse unreachable;
            var state = removed.value;
            state.deinit();
        };
        const state = result.value_ptr;
        if (!api.generationFollows(tree.generation, state.generation))
            return error.InvalidLayout;

        var tree_hasher = std.hash.Wyhash.init(0x61785f747265655f);
        for (tree.nodes) |node| {
            const hash = nodeHash(node);
            tree_hasher.update(std.mem.asBytes(&hash));
            for (node.children) |child| tree_hasher.update(std.mem.asBytes(&child));
        }
        const next_tree_hash = tree_hasher.final();
        const layout_changed = state.tree_hash != 0 and state.tree_hash != next_tree_hash;

        var active = std.AutoHashMap(u64, void).init(self.allocator);
        defer active.deinit();
        try active.ensureTotalCapacity(@intCast(tree.nodes.len));
        var missing_count: usize = 0;
        for (tree.nodes) |node| {
            active.putAssumeCapacity(node.id.encode(), {});
            if (!state.elements.contains(node.id.encode())) missing_count += 1;
        }
        if (missing_count > self.maximum_retained_elements_per_window -| state.elements.count())
            return error.BudgetExceeded;
        try state.elements.ensureUnusedCapacity(@intCast(missing_count));
        var created: std.ArrayList(u64) = .empty;
        defer created.deinit(self.allocator);
        try created.ensureTotalCapacity(self.allocator, missing_count);
        errdefer for (created.items) |encoded| {
            const removed = state.elements.fetchRemove(encoded) orelse continue;
            _ = objc.setIvar(?*Adapter, removed.value.object, "_ziguiAdapter", null);
            objc.release(removed.value.object);
        };
        for (tree.nodes) |node| {
            if (state.elements.contains(node.id.encode())) continue;
            const object = objc.send(objc.Id, objc.send(objc.Id, self.element_class, "alloc", .{}), "init", .{}) orelse return error.PlatformFailure;
            var object_owned = true;
            errdefer if (object_owned) {
                _ = objc.setIvar(?*Adapter, object, "_ziguiAdapter", null);
                objc.release(object);
            };
            if (!objc.setIvar(?*Adapter, object, "_ziguiAdapter", self) or
                !objc.setIvar(u64, object, "_ziguiWindow", tree.window.encode()) or
                !objc.setIvar(u64, object, "_ziguiSemantic", node.id.encode()))
                return error.PlatformFailure;
            state.elements.putAssumeCapacity(node.id.encode(), .{ .object = object });
            created.appendAssumeCapacity(node.id.encode());
            object_owned = false;
        }

        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        try stale.ensureTotalCapacity(self.allocator, state.elements.count() - active.count());
        var stale_iterator = state.elements.iterator();
        while (stale_iterator.next()) |entry| if (!active.contains(entry.key_ptr.*))
            stale.appendAssumeCapacity(entry.key_ptr.*);

        for (tree.nodes) |node| {
            const element = state.elements.getPtr(node.id.encode()) orelse unreachable;
            const is_new = element.seen_generation == 0;
            const previous_hash = element.content_hash;
            const previous_focus = element.focused;
            element.actions = actionMask(node.actions);
            element.seen_generation = tree.generation;
            element.content_hash = nodeHash(node);
            element.focused = node.focused;
            element.notify_value = !is_new and previous_hash != element.content_hash;
            element.notify_focus = !is_new and previous_focus != node.focused and node.focused;
        }

        for (tree.nodes) |node| {
            const element = state.elements.getPtr(node.id.encode()) orelse unreachable;
            const object = element.object;
            objc.send(void, object, "setAccessibilityRole:", .{objc.nsString(roleName(node))});
            objc.send(void, object, "setAccessibilityLabel:", .{if (node.label.len == 0) @as(objc.Id, null) else objc.nsString(node.label)});
            objc.send(void, object, "setAccessibilityHelp:", .{if (node.description.len == 0) @as(objc.Id, null) else objc.nsString(node.description)});
            objc.send(void, object, "setAccessibilityFrame:", .{self.host.screenRect(tree.window, node.bounds)});
            objc.send(void, object, "setAccessibilityEnabled:", .{!node.disabled});
            objc.send(void, object, "setAccessibilityHidden:", .{node.hidden});
            objc.send(void, object, "setAccessibilitySelected:", .{node.selected});
            objc.send(void, object, "setAccessibilityFocused:", .{node.focused});
            if (node.checked) |checked| objc.send(void, object, "setAccessibilityValue:", .{objc.send(objc.Id, objc.class("NSNumber"), "numberWithBool:", .{checked})}) else if (node.range_value) |number| objc.send(void, object, "setAccessibilityValue:", .{objc.send(objc.Id, objc.class("NSNumber"), "numberWithDouble:", .{number})}) else if (node.value.len != 0) objc.send(void, object, "setAccessibilityValue:", .{objc.nsString(node.value)}) else objc.send(void, object, "setAccessibilityValue:", .{@as(objc.Id, null)});
            if (node.range_min) |number| objc.send(void, object, "setAccessibilityMinValue:", .{objc.send(objc.Id, objc.class("NSNumber"), "numberWithDouble:", .{number})});
            if (node.range_max) |number| objc.send(void, object, "setAccessibilityMaxValue:", .{objc.send(objc.Id, objc.class("NSNumber"), "numberWithDouble:", .{number})});
            if (node.selection) |selection| objc.send(void, object, "setAccessibilitySelectedTextRange:", .{types.Range{
                .location = @min(selection.anchor, selection.focus),
                .length = if (selection.anchor <= selection.focus) selection.focus - selection.anchor else selection.anchor - selection.focus,
            }});
            const parent = if (node.parent.isValid())
                (state.elements.get(node.parent.encode()) orelse unreachable).object
            else
                self.host.parent(tree.window);
            objc.send(void, object, "setAccessibilityParent:", .{parent});
            const children = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMutableArray"), "alloc", .{}), "initWithCapacity:", .{node.children.len});
            defer objc.release(children);
            for (node.children) |child_id| {
                const child = state.elements.get(child_id.encode()) orelse unreachable;
                objc.send(void, children, "addObject:", .{child.object});
            }
            objc.send(void, object, "setAccessibilityChildren:", .{children});
            if (element.notify_value) NSAccessibilityPostNotification(object, objc.nsString("AXValueChanged"));
            if (element.notify_focus) NSAccessibilityPostNotification(object, objc.nsString("AXFocusedUIElementChanged"));
            element.notify_value = false;
            element.notify_focus = false;
        }

        for (stale.items) |encoded| {
            const removed = state.elements.fetchRemove(encoded) orelse continue;
            _ = objc.setIvar(?*Adapter, removed.value.object, "_ziguiAdapter", null);
            objc.release(removed.value.object);
        }

        const parent = self.host.parent(tree.window);
        if (parent != null) {
            if (!objc.setIvar(?*anyopaque, parent, "_ziguiAccessibility", self)) return error.PlatformFailure;
            objc.send(void, parent, "setAccessibilityElement:", .{false});
            const root = state.elements.get(tree.root.encode()) orelse unreachable;
            objc.send(void, parent, "setAccessibilityChildren:", .{objc.arrayWithObject(root.object)});
            if (layout_changed) NSAccessibilityPostNotification(parent, objc.nsString("AXLayoutChanged"));
        }
        state.root = tree.root;
        state.generation = tree.generation;
        state.tree_hash = next_tree_hash;
    }

    fn focus(self: *Adapter, id: handles.SemanticId) Error!void {
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| {
            const element = entry.value_ptr.elements.get(id.encode()) orelse continue;
            NSAccessibilityPostNotification(element.object, objc.nsString("AXFocusedUIElementChanged"));
            return;
        }
        return error.InvalidHandle;
    }

    fn removeWindow(self: *Adapter, id: handles.WindowId) void {
        const removed = self.windows.fetchRemove(id.encode()) orelse return;
        const parent = self.host.parent(id);
        if (parent != null) {
            _ = objc.setIvar(?*anyopaque, parent, "_ziguiAccessibility", null);
            objc.send(void, parent, "setAccessibilityChildren:", .{@as(objc.Id, null)});
        }
        var state = removed.value;
        state.deinit();
    }

    fn focusedElement(self: *Adapter, id: handles.WindowId) objc.Id {
        const state = self.windows.getPtr(id.encode()) orelse return null;
        var iterator = state.elements.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.focused) return entry.value_ptr.object;
        return null;
    }

    fn action(self: *Adapter, object: objc.Id, requested: api.Action, value: ?[]const u8, selection: ?api.Selection) bool {
        const window = decodeHandle(handles.WindowId, objc.getIvar(u64, object, "_ziguiWindow") orelse return false);
        const semantic = decodeHandle(handles.SemanticId, objc.getIvar(u64, object, "_ziguiSemantic") orelse return false);
        const state = self.windows.getPtr(window.encode()) orelse return false;
        const element = state.elements.get(semantic.encode()) orelse return false;
        if (element.actions & (@as(u32, 1) << @backingInt(requested)) == 0) return false;
        self.sink.emit(.{ .window = window, .target = semantic, .action = requested, .value = value, .selection = selection });
        return true;
    }

    fn deinit(self: *Adapter) void {
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| {
            const window = decodeHandle(handles.WindowId, entry.key_ptr.*);
            const parent = self.host.parent(window);
            if (parent != null) {
                _ = objc.setIvar(?*anyopaque, parent, "_ziguiAccessibility", null);
                objc.send(void, parent, "setAccessibilityChildren:", .{@as(objc.Id, null)});
            }
            entry.value_ptr.deinit();
        }
        self.windows.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

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

fn elementAdapter(object: objc.Id) ?*Adapter {
    if (object == null) return null;
    return objc.getIvar(?*Adapter, object, "_ziguiAdapter") orelse null;
}

fn registerElementClass() Error!objc.Class {
    if (objc.class("ZigUIAccessibilityElement")) |existing| return existing;
    const target = objc.objc_allocateClassPair(objc.class("NSAccessibilityElement"), "ZigUIAccessibilityElement", 0) orelse return error.PlatformFailure;
    if (!objc.addIvar(?*Adapter, target, "_ziguiAdapter", "^v")) return error.PlatformFailure;
    if (!objc.addIvar(u64, target, "_ziguiWindow", "Q")) return error.PlatformFailure;
    if (!objc.addIvar(u64, target, "_ziguiSemantic", "Q")) return error.PlatformFailure;
    inline for (methods) |method| if (!objc.class_addMethod(target, objc.selector(method.name), method.implementation, method.encoding)) return error.PlatformFailure;
    objc.objc_registerClassPair(target);
    return target;
}

const Method = struct { name: [*:0]const u8, implementation: objc.Imp, encoding: [*:0]const u8 };
const methods = [_]Method{
    .{ .name = "accessibilityPerformPress", .implementation = @ptrCast(&performPress), .encoding = "B@:" },
    .{ .name = "accessibilityPerformIncrement", .implementation = @ptrCast(&performIncrement), .encoding = "B@:" },
    .{ .name = "accessibilityPerformDecrement", .implementation = @ptrCast(&performDecrement), .encoding = "B@:" },
    .{ .name = "accessibilityPerformShowMenu", .implementation = @ptrCast(&performShowMenu), .encoding = "B@:" },
    .{ .name = "setAccessibilityFocused:", .implementation = @ptrCast(&setFocused), .encoding = "v@:B" },
    .{ .name = "isAccessibilityFocused", .implementation = @ptrCast(&isFocused), .encoding = "B@:" },
    .{ .name = "accessibilityIsAttributeSettable:", .implementation = @ptrCast(&isAttributeSettable), .encoding = "B@:@" },
    .{ .name = "setAccessibilityValue:", .implementation = @ptrCast(&setValue), .encoding = "v@:@" },
    .{ .name = "setAccessibilitySelectedTextRange:", .implementation = @ptrCast(&setSelectedTextRange), .encoding = "v@:{_NSRange=QQ}" },
};

fn performPress(object: objc.Id, _: objc.Sel) callconv(.c) bool {
    return perform(object, .activate);
}
fn performIncrement(object: objc.Id, _: objc.Sel) callconv(.c) bool {
    return perform(object, .increment);
}
fn performDecrement(object: objc.Id, _: objc.Sel) callconv(.c) bool {
    return perform(object, .decrement);
}
fn performShowMenu(object: objc.Id, _: objc.Sel) callconv(.c) bool {
    return perform(object, .show_menu);
}

fn perform(object: objc.Id, action: api.Action) bool {
    const self = elementAdapter(object) orelse return false;
    return self.action(object, action, null, null);
}

fn setFocused(object: objc.Id, _: objc.Sel, focused: bool) callconv(.c) void {
    const self = elementAdapter(object) orelse return;
    if (self.updating) {
        objc.sendSuper(void, object, objc.class_getSuperclass(objc.object_getClass(object)), "setAccessibilityFocused:", .{focused});
        return;
    }
    _ = self.action(object, if (focused) .focus else .blur, null, null);
}

fn isFocused(object: objc.Id, _: objc.Sel) callconv(.c) bool {
    const self = elementAdapter(object) orelse return false;
    const window = objc.getIvar(u64, object, "_ziguiWindow") orelse return false;
    const semantic = objc.getIvar(u64, object, "_ziguiSemantic") orelse return false;
    const state = self.windows.getPtr(window) orelse return false;
    const element = state.elements.getPtr(semantic) orelse return false;
    return element.focused;
}

pub fn focusedElement(raw: *anyopaque, id: handles.WindowId) objc.Id {
    return cast(raw).focusedElement(id);
}

fn isAttributeSettable(object: objc.Id, _: objc.Sel, attribute: objc.Id) callconv(.c) bool {
    const self = elementAdapter(object) orelse return false;
    const window = objc.getIvar(u64, object, "_ziguiWindow") orelse return false;
    const semantic = objc.getIvar(u64, object, "_ziguiSemantic") orelse return false;
    const state = self.windows.getPtr(window) orelse return false;
    const element = state.elements.getPtr(semantic) orelse return false;
    const name = if (attribute == null) "" else objc.utf8(attribute);
    if (attributeSettableForActions(element.actions, name)) |settable| return settable;
    return objc.sendSuper(
        bool,
        object,
        objc.class_getSuperclass(objc.object_getClass(object)),
        "accessibilityIsAttributeSettable:",
        .{attribute},
    );
}

fn setValue(object: objc.Id, _: objc.Sel, value: objc.Id) callconv(.c) void {
    const self = elementAdapter(object) orelse return;
    if (self.updating) {
        objc.sendSuper(void, object, objc.class_getSuperclass(objc.object_getClass(object)), "setAccessibilityValue:", .{value});
        return;
    }
    const bytes = if (value == null) "" else objc.utf8(objc.send(objc.Id, value, "description", .{}));
    _ = self.action(object, .set_value, bytes, null);
}

fn setSelectedTextRange(object: objc.Id, _: objc.Sel, range: types.Range) callconv(.c) void {
    const self = elementAdapter(object) orelse return;
    if (self.updating) {
        objc.sendSuper(void, object, objc.class_getSuperclass(objc.object_getClass(object)), "setAccessibilitySelectedTextRange:", .{range});
        return;
    }
    _ = self.action(object, .set_selection, null, .{ .anchor = range.location, .focus = range.location +| range.length });
}

fn actionMask(actions: []const api.Action) u32 {
    var result: u32 = 0;
    for (actions) |action| result |= @as(u32, 1) << @backingInt(action);
    return result;
}

fn attributeSettableForActions(actions: u32, attribute: []const u8) ?bool {
    if (std.mem.eql(u8, attribute, "AXValue"))
        return actions & (@as(u32, 1) << @backingInt(api.Action.set_value)) != 0;
    if (std.mem.eql(u8, attribute, "AXSelectedTextRange"))
        return actions & (@as(u32, 1) << @backingInt(api.Action.set_selection)) != 0;
    if (std.mem.eql(u8, attribute, "AXFocused"))
        return actions & ((@as(u32, 1) << @backingInt(api.Action.focus)) | (@as(u32, 1) << @backingInt(api.Action.blur))) != 0;
    return null;
}

fn nodeHash(node: api.Node) u64 {
    var hash = std.hash.Wyhash.init(0x61783131795f6e6f);
    hash.update(node.label);
    hash.update(node.description);
    hash.update(node.value);
    hash.update(std.mem.asBytes(&node.bounds));
    hash.update(std.mem.asBytes(&node.disabled));
    hash.update(std.mem.asBytes(&node.selected));
    if (node.checked) |value| hash.update(std.mem.asBytes(&value));
    if (node.expanded) |value| hash.update(std.mem.asBytes(&value));
    if (node.range_value) |value| hash.update(std.mem.asBytes(&value));
    if (node.selection) |value| hash.update(std.mem.asBytes(&value));
    return hash.final();
}

fn roleName(node: api.Node) []const u8 {
    if (node.role == .text_field and node.multiline) return "AXTextArea";
    return switch (node.role) {
        .none, .group => "AXGroup",
        .application => "AXApplication",
        .window => "AXWindow",
        .button => "AXButton",
        .checkbox => "AXCheckBox",
        .radio => "AXRadioButton",
        .switch_control => "AXSwitch",
        .slider => "AXSlider",
        .progress_indicator => "AXProgressIndicator",
        .text, .static_text => "AXStaticText",
        .text_field => "AXTextField",
        .search_field => "AXSearchField",
        .heading => "AXHeading",
        .link => "AXLink",
        .image => "AXImage",
        .list => "AXList",
        .list_item => "AXGroup",
        .tree => "AXOutline",
        .tree_item => "AXRow",
        .grid => "AXGrid",
        .row => "AXRow",
        .cell => "AXCell",
        .menu => "AXMenu",
        .menu_item => "AXMenuItem",
        .menu_item_checkbox => "AXMenuItem",
        .menu_item_radio => "AXMenuItem",
        .tab_list => "AXTabGroup",
        .tab => "AXRadioButton",
        .tab_panel => "AXGroup",
        .toolbar => "AXToolbar",
        .tooltip => "AXHelpTag",
        .dialog => "AXSheet",
        .alert => "AXGroup",
        .separator => "AXSplitter",
        .scroll_view => "AXScrollArea",
        .canvas => "AXGroup",
    };
}

test "multiline text fields use the native text area role" {
    try std.testing.expectEqualStrings("AXTextField", roleName(.{ .role = .text_field }));
    try std.testing.expectEqualStrings("AXTextArea", roleName(.{ .role = .text_field, .multiline = true }));
    try std.testing.expectEqualStrings("AXSearchField", roleName(.{ .role = .search_field, .multiline = true }));
}

test "editable accessibility attributes follow semantic actions" {
    const actions = actionMask(&.{ .focus, .blur, .set_value, .set_selection });
    try std.testing.expectEqual(true, attributeSettableForActions(actions, "AXValue").?);
    try std.testing.expectEqual(true, attributeSettableForActions(actions, "AXSelectedTextRange").?);
    try std.testing.expectEqual(true, attributeSettableForActions(actions, "AXFocused").?);
    try std.testing.expectEqual(false, attributeSettableForActions(0, "AXValue").?);
    try std.testing.expect(attributeSettableForActions(actions, "AXChildren") == null);
}

fn decodeHandle(comptime T: type, encoded: u64) T {
    return .{ .index = @truncate(encoded), .generation = @truncate(encoded >> 32) };
}
