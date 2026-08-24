const std = @import("std");
const config = @import("../config.zig");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const metrics = @import("../core/metrics.zig");
const layout = @import("../layout/style.zig");
const compose_style = @import("../compose/style.zig");
const a11y = @import("../a11y/api.zig");
const render_resource = @import("../render/resource.zig");
const App = @import("../app.zig").App;

pub const Node = struct {
    id: handles.NodeId,
    parent: handles.NodeId,
    component: handles.ComponentId,
    key: u64,
    kind: []u8,
    bounds: geometry.Rect,
    content_bounds: geometry.Rect,
    scroll_extent: geometry.Size,
    children: []handles.NodeId,
    semantic_id: handles.SemanticId,
    semantic_role: a11y.Role,
    semantic_label: []u8,
    semantic_value: []u8,
    display: layout.Display,
    position: layout.Position,
    opacity: f32,
    cursor: compose_style.Cursor,
    focusable: bool,
    disabled: bool,
    dirty: layout.Dirty,
    paint_generation: u64,

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.children);
        allocator.free(self.semantic_label);
        allocator.free(self.semantic_value);
        self.* = undefined;
    }
};

pub const Component = struct {
    id: handles.ComponentId,
    window: handles.WindowId,
    anchor: handles.NodeId,
    root: handles.NodeId,
    registered: bool,
};

pub const SceneCounts = struct {
    operations: usize,
    materials: usize,
    clips: usize,
    layers: usize,
    shadows: usize,
    quads: usize,
    paths: usize,
    path_vertices: usize,
    underlines: usize,
    monochrome_sprites: usize,
    color_sprites: usize,
    external_surfaces: usize,
};

pub const Window = struct {
    id: handles.WindowId,
    native: u64,
    state: @import("../platform/api.zig").WindowState,
    logical_size: geometry.Size,
    scale_factor: geometry.ScaleFactor,
    frame_number: u64,
    pending_frame: bool,
    occluded: bool,
    focused: bool,
    root_component: handles.ComponentId,
    anchor: handles.NodeId,
    scene: SceneCounts,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    captured_ns: u64,
    nodes: []Node,
    components: []Component,
    windows: []Window,
    counters: metrics.Counters,
    resources: render_resource.Manager.Stats,

    pub fn deinit(self: *Snapshot) void {
        for (self.nodes) |*node_value| node_value.deinit(self.allocator);
        self.allocator.free(self.nodes);
        self.allocator.free(self.components);
        self.allocator.free(self.windows);
        self.* = undefined;
    }

    pub fn node(self: *const Snapshot, id: handles.NodeId) ?*const Node {
        for (self.nodes) |*value| if (value.id.eql(id)) return value;
        return null;
    }

    pub fn nodeAt(self: *const Snapshot, window: handles.WindowId, point: geometry.Point) ?*const Node {
        _ = window;
        var best: ?*const Node = null;
        for (self.nodes) |*value| {
            if (!value.bounds.contains(point) or value.display == .none) continue;
            if (best == null or descendantDepth(self, value) >= descendantDepth(self, best.?)) best = value;
        }
        return best;
    }

    pub fn writeText(self: *const Snapshot, writer: *std.Io.Writer) !void {
        try writer.print("ZigUI inspector snapshot @ {d} ns\n", .{self.captured_ns});
        try writer.print("windows={d} components={d} nodes={d} textures={d} gpu={d}/{d} bytes\n", .{
            self.windows.len,
            self.components.len,
            self.nodes.len,
            self.resources.live_textures,
            self.resources.gpu_reserved,
            self.resources.gpu_budget,
        });
        for (self.windows) |window| try writer.print(
            "window {x}:{x} {d:.1}x{d:.1} scale={d:.2} frame={d} ops={d} primitives={d}\n",
            .{
                window.id.index,           window.id.generation, window.logical_size.width, window.logical_size.height,
                window.scale_factor.value, window.frame_number,  window.scene.operations,   window.scene.quads + window.scene.paths + window.scene.monochrome_sprites + window.scene.color_sprites,
            },
        );
        for (self.nodes) |node_value| {
            const depth = descendantDepth(self, &node_value);
            var index: usize = 0;
            while (index < depth) : (index += 1) try writer.writeAll("  ");
            try writer.print("{s} {x}:{x} [{d:.1},{d:.1} {d:.1}x{d:.1}] role={s} label={s}\n", .{
                node_value.kind,
                node_value.id.index,
                node_value.id.generation,
                node_value.bounds.origin.x,
                node_value.bounds.origin.y,
                node_value.bounds.size.width,
                node_value.bounds.size.height,
                @tagName(node_value.semantic_role),
                node_value.semantic_label,
            });
        }
    }
};

pub fn capture(allocator: std.mem.Allocator, app: *App) Error!Snapshot {
    if (!config.inspector_enabled) return error.MissingCapability;
    try app.coordinator.affinity.assertCurrent();
    var nodes: std.ArrayList(Node) = .empty;
    errdefer {
        for (nodes.items) |*node| node.deinit(allocator);
        nodes.deinit(allocator);
    }
    var node_iterator = app.nodes.inspectIterator();
    while (node_iterator.next()) |view| {
        const kind = try allocator.dupe(u8, view.kind);
        errdefer allocator.free(kind);
        const children = try allocator.dupe(handles.NodeId, view.children);
        errdefer allocator.free(children);
        const label = try allocator.dupe(u8, view.semantic_label);
        errdefer allocator.free(label);
        const value = try allocator.dupe(u8, view.semantic_value);
        errdefer allocator.free(value);
        try nodes.append(allocator, .{
            .id = view.id,
            .parent = view.parent,
            .component = view.component,
            .key = view.key,
            .kind = kind,
            .bounds = view.layout_result.bounds,
            .content_bounds = view.layout_result.content_bounds,
            .scroll_extent = view.layout_result.scroll_extent,
            .children = children,
            .semantic_id = view.semantic_id,
            .semantic_role = view.semantic_role,
            .semantic_label = label,
            .semantic_value = value,
            .display = view.style.layout.display,
            .position = view.style.layout.position,
            .opacity = view.style.paint.opacity,
            .cursor = view.style.interaction.cursor,
            .focusable = view.style.interaction.focusable,
            .disabled = view.style.interaction.disabled,
            .dirty = view.dirty,
            .paint_generation = view.paint_generation,
        });
    }
    var components: std.ArrayList(Component) = .empty;
    errdefer components.deinit(allocator);
    var component_iterator = app.components.iterator();
    while (component_iterator.next()) |entry| try components.append(allocator, .{
        .id = entry.id,
        .window = entry.window,
        .anchor = entry.anchor,
        .root = entry.root,
        .registered = entry.registered,
    });
    var windows: std.ArrayList(Window) = .empty;
    errdefer windows.deinit(allocator);
    var window_iterator = app.windows.iterator();
    while (window_iterator.next()) |entry| {
        const window = entry.value.*;
        const committed = window.committedScene();
        try windows.append(allocator, .{
            .id = entry.id,
            .native = window.native.value,
            .state = window.state,
            .logical_size = window.logical_size,
            .scale_factor = window.scale_factor,
            .frame_number = window.frame_number,
            .pending_frame = window.pending_frame,
            .occluded = window.occluded,
            .focused = window.platform_focused,
            .root_component = window.root_component,
            .anchor = window.anchor,
            .scene = .{
                .operations = committed.operations.items.len,
                .materials = committed.materials.items.len,
                .clips = committed.clips.items.len,
                .layers = committed.layers.items.len,
                .shadows = committed.shadows.items.len,
                .quads = committed.quads.items.len,
                .paths = committed.paths.items.len,
                .path_vertices = committed.path_vertices.items.len,
                .underlines = committed.underlines.items.len,
                .monochrome_sprites = committed.monochrome_sprites.items.len,
                .color_sprites = committed.color_sprites.items.len,
                .external_surfaces = committed.external_surfaces.items.len,
            },
        });
    }
    return .{
        .allocator = allocator,
        .captured_ns = app.bundle.clock.now(),
        .nodes = try nodes.toOwnedSlice(allocator),
        .components = try components.toOwnedSlice(allocator),
        .windows = try windows.toOwnedSlice(allocator),
        .counters = app.coordinator.counters,
        .resources = app.resources.stats(),
    };
}

fn descendantDepth(snapshot: *const Snapshot, value: *const Node) usize {
    var depth: usize = 0;
    var parent = value.parent;
    while (parent.isValid() and depth < 1024) : (depth += 1) {
        const node_value = snapshot.node(parent) orelse break;
        parent = node_value.parent;
    }
    return depth;
}
