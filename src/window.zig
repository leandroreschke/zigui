const std = @import("std");
const a11y_tree = @import("a11y/tree.zig");
const geometry = @import("core/geometry.zig");
const handles = @import("core/handle.zig");
const memory = @import("core/memory.zig");
const focus = @import("input/focus.zig");
const hit_tree = @import("input/hit_tree.zig");
const input_router = @import("input/router.zig");
const action = @import("input/action.zig");
const platform = @import("platform/api.zig");
const scene = @import("scene/scene.zig");

pub const Window = struct {
    allocator: std.mem.Allocator,
    id: handles.WindowId,
    native: platform.NativeHandle,
    state: platform.WindowState = .created,
    logical_size: geometry.Size,
    position: ?geometry.Point,
    scale_factor: geometry.ScaleFactor,
    /// Platform-reported refresh rate for presentation deadline evidence.
    /// Zero means the display provider did not expose a rate.
    reported_refresh_millihertz: u32 = 0,
    // Non-native/headless platforms use a deterministic resolved baseline.
    // Native adapters publish their actual value before the first frame.
    appearance: platform.Appearance = .light,
    mode: platform.WindowMode = .normal,
    clear_color: geometry.Color,
    anchor: handles.NodeId,
    root_component: handles.ComponentId,
    frame_arena: memory.FrameArena,
    event_arena: memory.FrameArena,
    scenes: [2]scene.Scene,
    retained_scene: @import("scene/retained.zig").Cache,
    scene_limits: scene.Limits,
    next_scene: u1 = 0,
    hits: hit_tree.Tree,
    focus_manager: focus.Manager,
    semantic_tree: a11y_tree.Builder,
    router: input_router.Router = undefined,
    frame_number: u64 = 0,
    pending_frame: bool = false,
    visible: bool = false,
    close_scheduled: bool = false,
    close_callback_invoked: bool = false,
    occluded: bool = false,
    platform_focused: bool = false,
    last_input_ns: ?u64 = null,

    pub fn init(
        self: *Window,
        allocator: std.mem.Allocator,
        id: handles.WindowId,
        native: platform.NativeHandle,
        logical_size: geometry.Size,
        position: ?geometry.Point,
        scale_factor: geometry.ScaleFactor,
        clear_color: geometry.Color,
        anchor: handles.NodeId,
        root_component: handles.ComponentId,
        frame_arena_bytes: usize,
        event_arena_bytes: usize,
        scene_limits: scene.Limits,
        maximum_retained_nodes: usize,
        maximum_accessibility_nodes: usize,
        maximum_accessibility_bytes: usize,
        router_limits: input_router.Router.Limits,
        actions: *action.Registry,
    ) std.mem.Allocator.Error!void {
        var frame_arena = try memory.FrameArena.init(allocator, frame_arena_bytes);
        errdefer frame_arena.deinit();
        var event_arena = try memory.FrameArena.init(allocator, event_arena_bytes);
        errdefer event_arena.deinit();
        self.* = .{
            .allocator = allocator,
            .id = id,
            .native = native,
            .logical_size = logical_size,
            .position = position,
            .scale_factor = scale_factor,
            .clear_color = clear_color,
            .anchor = anchor,
            .root_component = root_component,
            .frame_arena = frame_arena,
            .event_arena = event_arena,
            .scenes = .{ scene.Scene.init(allocator), scene.Scene.init(allocator) },
            .retained_scene = @import("scene/retained.zig").Cache.init(allocator, 0),
            .scene_limits = scene_limits,
            .hits = hit_tree.Tree.initWithLimit(allocator, maximum_retained_nodes),
            .focus_manager = focus.Manager.initWithLimit(allocator, maximum_retained_nodes),
            .semantic_tree = a11y_tree.Builder.initWithLimits(
                allocator,
                id,
                maximum_accessibility_nodes,
                maximum_accessibility_bytes,
            ),
        };
        self.router = input_router.Router.initWithLimits(
            allocator,
            id,
            anchor,
            &self.hits,
            &self.focus_manager,
            actions,
            router_limits,
        );
    }

    pub fn deinit(self: *Window) void {
        self.router.deinit();
        self.semantic_tree.deinit();
        self.focus_manager.deinit();
        self.hits.deinit();
        self.scenes[0].deinit();
        self.scenes[1].deinit();
        self.retained_scene.deinit();
        self.event_arena.deinit();
        self.frame_arena.deinit();
        self.* = undefined;
    }

    pub fn sceneForBuild(self: *Window) *scene.Scene {
        return &self.scenes[self.next_scene];
    }

    pub fn commitScene(self: *Window) void {
        self.next_scene ^= 1;
        self.frame_number +%= 1;
        if (self.frame_number == 0) self.frame_number = 1;
    }

    pub fn committedScene(self: *const Window) *const scene.Scene {
        return &self.scenes[self.next_scene ^ 1];
    }

    pub fn drawableWidth(self: *const Window) error{ WindowNotConfigured, BudgetExceeded }!u32 {
        return drawableDimension(self.logical_size.width, self.scale_factor.value);
    }

    pub fn drawableHeight(self: *const Window) error{ WindowNotConfigured, BudgetExceeded }!u32 {
        return drawableDimension(self.logical_size.height, self.scale_factor.value);
    }
};

fn drawableDimension(logical: f32, scale: f32) error{ WindowNotConfigured, BudgetExceeded }!u32 {
    if (!std.math.isFinite(logical) or !std.math.isFinite(scale) or logical <= 0 or scale <= 0)
        return error.WindowNotConfigured;
    const device = @as(f64, logical) * @as(f64, scale);
    if (!std.math.isFinite(device) or device > @as(f64, @floatFromInt(std.math.maxInt(u32))))
        return error.BudgetExceeded;
    return @intFromFloat(@max(@as(f64, 1), @round(device)));
}
