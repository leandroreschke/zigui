const std = @import("std");
const core_config = @import("../core/config.zig");
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const Error = @import("../core/error.zig").Error;

pub const Role = enum {
    none,
    application,
    window,
    group,
    button,
    checkbox,
    radio,
    switch_control,
    slider,
    progress_indicator,
    text,
    text_field,
    search_field,
    static_text,
    heading,
    link,
    image,
    list,
    list_item,
    tree,
    tree_item,
    grid,
    row,
    cell,
    menu,
    menu_item,
    menu_item_checkbox,
    menu_item_radio,
    tab_list,
    tab,
    tab_panel,
    toolbar,
    tooltip,
    dialog,
    alert,
    separator,
    scroll_view,
    canvas,
};

pub const Action = enum {
    focus,
    blur,
    activate,
    increment,
    decrement,
    show_menu,
    scroll_up,
    scroll_down,
    scroll_left,
    scroll_right,
    set_value,
    set_selection,
};

pub const Selection = struct {
    anchor: usize,
    focus: usize,
};

pub const Node = struct {
    id: handles.SemanticId = .invalid,
    parent: handles.SemanticId = .invalid,
    role: Role = .none,
    label: []const u8 = "",
    description: []const u8 = "",
    value: []const u8 = "",
    bounds: geometry.Rect = .{},
    children: []const handles.SemanticId = &.{},
    actions: []const Action = &.{},
    selection: ?Selection = null,
    range_min: ?f64 = null,
    range_max: ?f64 = null,
    range_value: ?f64 = null,
    disabled: bool = false,
    hidden: bool = false,
    focused: bool = false,
    selected: bool = false,
    checked: ?bool = null,
    expanded: ?bool = null,
    multiline: bool = false,
    password: bool = false,
};

pub const Tree = struct {
    window: handles.WindowId,
    root: handles.SemanticId,
    nodes: []const Node,
    generation: u64,
};

pub const TreeLimits = struct {
    maximum_nodes: usize,
    maximum_bytes: usize,
    maximum_depth: usize = core_config.maximum_retained_tree_depth,
};

/// Validates a complete accessibility snapshot at the native adapter boundary.
/// The retained-tree builder already produces this shape, but adapters remain
/// public platform contracts and must reject malformed or unbounded callers on
/// their own.
pub fn validateTree(
    allocator: std.mem.Allocator,
    tree: *const Tree,
    limits: TreeLimits,
) Error!void {
    if (limits.maximum_nodes == 0 or limits.maximum_bytes == 0 or limits.maximum_depth == 0 or
        limits.maximum_depth > core_config.maximum_retained_tree_depth)
        return error.InvalidConfiguration;
    if (!tree.window.isValid() or !tree.root.isValid() or tree.generation == 0 or
        tree.nodes.len == 0)
        return error.InvalidLayout;
    if (tree.nodes.len > limits.maximum_nodes or tree.nodes.len > std.math.maxInt(u32))
        return error.BudgetExceeded;

    var indices = std.AutoHashMap(u64, usize).init(allocator);
    defer indices.deinit();
    try indices.ensureTotalCapacity(@intCast(tree.nodes.len));

    var accounted = std.math.mul(usize, tree.nodes.len, @sizeOf(Node)) catch
        return error.BudgetExceeded;
    var edge_count: usize = 0;
    for (tree.nodes, 0..) |node, index| {
        try validateNode(node);
        if (indices.contains(node.id.encode())) return error.InvalidLayout;
        accounted = std.math.add(usize, accounted, try nodePayloadBytes(node)) catch
            return error.BudgetExceeded;
        edge_count = std.math.add(usize, edge_count, node.children.len) catch
            return error.BudgetExceeded;
        if (accounted > limits.maximum_bytes) return error.BudgetExceeded;
        indices.putAssumeCapacity(node.id.encode(), index);
    }
    if (edge_count != tree.nodes.len - 1) return error.InvalidLayout;

    const root_index = indices.get(tree.root.encode()) orelse return error.InvalidLayout;
    if (tree.nodes[root_index].parent.isValid()) return error.InvalidLayout;
    const incoming = try allocator.alloc(u8, tree.nodes.len);
    defer allocator.free(incoming);
    @memset(incoming, 0);
    for (tree.nodes) |node| {
        if (!node.id.eql(tree.root) and
            (!node.parent.isValid() or indices.get(node.parent.encode()) == null))
            return error.InvalidLayout;
        for (node.children) |child_id| {
            const child_index = indices.get(child_id.encode()) orelse return error.InvalidLayout;
            if (!tree.nodes[child_index].parent.eql(node.id)) return error.InvalidLayout;
            if (incoming[child_index] != 0) return error.InvalidLayout;
            incoming[child_index] = 1;
        }
    }
    for (incoming, 0..) |count, index| {
        if (index == root_index) {
            if (count != 0) return error.InvalidLayout;
        } else if (count != 1) return error.InvalidLayout;
    }

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(tree.nodes.len));
    const Walk = struct { id: handles.SemanticId, depth: usize };
    var stack: std.ArrayList(Walk) = .empty;
    defer stack.deinit(allocator);
    try stack.ensureTotalCapacity(allocator, tree.nodes.len);
    stack.appendAssumeCapacity(.{ .id = tree.root, .depth = 1 });
    while (stack.pop()) |item| {
        if (item.depth > limits.maximum_depth) return error.BudgetExceeded;
        if (seen.contains(item.id.encode())) return error.InvalidLayout;
        seen.putAssumeCapacity(item.id.encode(), {});
        const node_index = indices.get(item.id.encode()) orelse return error.InvalidLayout;
        if (tree.nodes[node_index].children.len > stack.capacity - stack.items.len)
            return error.InvalidLayout;
        for (tree.nodes[node_index].children) |child|
            stack.appendAssumeCapacity(.{ .id = child, .depth = item.depth + 1 });
    }
    if (seen.count() != tree.nodes.len) return error.InvalidLayout;
}

pub fn validateNode(node: Node) Error!void {
    if (!node.id.isValid() or !finiteRect(node.bounds))
        return error.InvalidLayout;
    if (!validText(node.label) or !validText(node.description) or !validText(node.value))
        return error.InvalidUtf8;
    for (node.children) |child| if (!child.isValid()) return error.InvalidLayout;
    if (node.selection) |selection| {
        if (selection.anchor > node.value.len or selection.focus > node.value.len or
            !utf8Boundary(node.value, selection.anchor) or
            !utf8Boundary(node.value, selection.focus))
            return error.InvalidLayout;
    }
    if (node.range_min) |value| if (!std.math.isFinite(value)) return error.InvalidLayout;
    if (node.range_max) |value| if (!std.math.isFinite(value)) return error.InvalidLayout;
    if (node.range_value) |value| if (!std.math.isFinite(value)) return error.InvalidLayout;
    if (node.range_min != null and node.range_max != null and node.range_min.? > node.range_max.?)
        return error.InvalidLayout;
    if (node.range_value) |value| {
        if (node.range_min) |minimum| if (value < minimum) return error.InvalidLayout;
        if (node.range_max) |maximum| if (value > maximum) return error.InvalidLayout;
    }
}

pub fn nodePayloadBytes(node: Node) Error!usize {
    var bytes = std.math.add(usize, node.label.len, node.description.len) catch
        return error.BudgetExceeded;
    bytes = std.math.add(usize, bytes, node.value.len) catch return error.BudgetExceeded;
    const children_bytes = std.math.mul(usize, node.children.len, @sizeOf(handles.SemanticId)) catch
        return error.BudgetExceeded;
    bytes = std.math.add(usize, bytes, children_bytes) catch return error.BudgetExceeded;
    const action_bytes = std.math.mul(usize, node.actions.len, @sizeOf(Action)) catch
        return error.BudgetExceeded;
    bytes = std.math.add(usize, bytes, action_bytes) catch return error.BudgetExceeded;
    return bytes;
}

/// Accessibility generations are nonzero wrapping sequence numbers. The
/// half-range rule preserves stale-snapshot rejection across `u64` rollover.
pub fn generationFollows(next: u64, current: u64) bool {
    if (next == 0) return false;
    if (current == 0) return true;
    const distance = next -% current;
    return distance != 0 and distance <= std.math.maxInt(u64) / 2;
}

pub const ActionRequest = struct {
    window: handles.WindowId,
    target: handles.SemanticId,
    action: Action,
    value: ?[]const u8 = null,
    selection: ?Selection = null,
};

pub const Adapter = struct {
    context: *anyopaque,
    update_fn: *const fn (*anyopaque, *const Tree) Error!void,
    focus_fn: *const fn (*anyopaque, handles.SemanticId) Error!void,
    remove_window_fn: *const fn (*anyopaque, handles.WindowId) void,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn update(self: Adapter, tree: *const Tree) Error!void {
        try self.update_fn(self.context, tree);
    }

    pub fn focus(self: Adapter, id: handles.SemanticId) Error!void {
        try self.focus_fn(self.context, id);
    }

    pub fn removeWindow(self: Adapter, id: handles.WindowId) void {
        self.remove_window_fn(self.context, id);
    }

    pub fn deinit(self: Adapter) void {
        self.deinit_fn(self.context);
    }
};

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
