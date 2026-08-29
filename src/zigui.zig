const builtin = @import("builtin");

pub const config = @import("config.zig");
const DisabledCapability = struct {
    pub const enabled = false;
};

pub const layout = @import("layout/style.zig");
pub const appearance = @import("core/appearance.zig");
pub const layout_engine = @import("layout/engine.zig");
pub const LayoutEngine = @import("layout/engine.zig").Engine;
pub const input = @import("input/event.zig");
pub const hit_testing = @import("input/hit_tree.zig");
pub const focus = @import("input/focus.zig");
pub const actions = @import("input/action.zig");
pub const InputRouter = @import("input/router.zig").Router;
pub const accessibility = @import("a11y/api.zig");
pub const AccessibilityTree = @import("a11y/tree.zig").Builder;
pub const text = @import("text/api.zig");
pub const unicode = @import("text/unicode.zig");
pub const opentype = if (config.text_enabled) @import("text/opentype.zig") else DisabledCapability;
pub const InTreeTextBackend = if (config.text_enabled) @import("text/in_tree_backend.zig").Backend else DisabledCapability;
pub const TextSystem = if (config.text_enabled) @import("text/system.zig").System else DisabledCapability;
pub const scene_abi = @import("scene/abi.zig");
pub const scene = @import("scene/scene.zig");
pub const ScenePainter = @import("scene/painter.zig").Painter;
pub const render = @import("render/api.zig");
pub const render_extension = @import("render/extension.zig");
pub const resources = @import("render/resource.zig");
pub const surface_resources = @import("render/surface_resource.zig");
pub const atlas = @import("render/atlas.zig");
pub const NullRenderer = if (config.compiled_renderer == .null) @import("render/null.zig").NullRenderer else DisabledCapability;
pub const platform = @import("platform/api.zig");
pub const PlatformFactory = @import("platform/factory.zig");
pub const HeadlessPlatform = if (config.compiled_platform == .headless) @import("platform/headless.zig") else DisabledCapability;
pub const runtime_phase = @import("runtime/phase.zig");
pub const runtime_state = @import("runtime/state.zig");
pub const runtime_dependency = @import("runtime/dependency.zig");
pub const runtime_effect = @import("runtime/effect.zig");
pub const runtime_queue = @import("runtime/queue.zig");
pub const runtime_task = @import("runtime/task.zig");
pub const runtime_invalidation = @import("runtime/invalidation.zig");
pub const runtime = @import("runtime/coordinator.zig");
pub const ThreadAffinity = @import("runtime/thread_affinity.zig").ThreadAffinity;
pub const style = @import("compose/style.zig");
pub const node = @import("compose/node.zig");
pub const custom = @import("compose/custom.zig");
pub const NodeStore = @import("compose/store.zig").Store;
pub const NodeSpec = node.Spec;
pub const Component = @import("compose/component.zig");
pub const App = @import("app.zig").App;
pub const OpenWindowOptions = @import("app.zig").OpenWindowOptions;
pub const widgets = @import("widgets/widgets.zig");
pub const image = if (config.images_enabled) @import("assets/image.zig") else DisabledCapability;
pub const animation = if (config.images_enabled) @import("assets/animation.zig") else DisabledCapability;
pub const ImageManager = if (config.images_enabled) @import("assets/manager.zig").Manager else DisabledCapability;
pub const svg = if (config.svg_enabled) @import("assets/svg.zig") else DisabledCapability;
pub const SvgManager = if (config.svg_enabled) @import("assets/svg_manager.zig").Manager else DisabledCapability;
pub const SvgView = if (config.svg_enabled) @import("assets/svg_view.zig").View else DisabledCapability;
pub const media = if (config.media_enabled) struct {
    pub const api = @import("media/api.zig");
    pub const Player = @import("media/player.zig").Player;
    pub const Manager = @import("media/manager.zig").Manager;
    pub const View = @import("media/view.zig").View;
    pub const Y4mSource = @import("media/y4m.zig").Source;
} else DisabledCapability;
pub const tracing = if (config.tracing_enabled) @import("debug/tracing.zig") else DisabledCapability;
pub const inspector = if (config.inspector_enabled) @import("debug/inspector.zig") else DisabledCapability;

/// Internal wire contracts are reachable only while compiling repository
/// tests. They are not part of the application-facing module surface.
pub const internal_protocol_test = if (builtin.is_test) struct {
    pub const wayland_wire = @import("platform/linux/wayland/wire.zig");
    pub const dbus_wire = @import("platform/linux/dbus/wire.zig");
    pub const x11_wire = @import("platform/linux/x11/wire.zig");
    pub const x11_protocol = @import("platform/linux/x11/protocol.zig");
} else DisabledCapability;

/// Backend-neutral shader generation is exposed only to repository tests so
/// the same module ownership graph can validate it on every host.
pub const internal_shader_test = if (builtin.is_test) struct {
    pub const vulkan_shaders = @import("backend/vulkan/shaders.zig");
    pub const d3d11_compiler = if (builtin.os.tag == .windows) @import("backend/d3d11/compiler.zig") else DisabledCapability;
    pub const d3d11_renderer = if (builtin.os.tag == .windows) @import("backend/d3d11/renderer.zig") else DisabledCapability;

    pub fn d3d11NullSurfaceProvider(context: *anyopaque) @import("platform/windows/surface.zig").Provider {
        const Provider = struct {
            fn window(_: *anyopaque, _: core.handles.WindowId) @import("platform/windows/abi.zig").HWND {
                return null;
            }
        };
        return .{ .context = context, .window_fn = Provider.window };
    }
} else DisabledCapability;

/// Native backend modules are exposed only to their dedicated repository
/// conformance roots; applications never depend on this test-only surface.
pub const internal_backend_test = if (builtin.is_test) struct {
    pub const metal_renderer = if (builtin.os.tag == .macos and config.compiled_renderer == .metal)
        @import("backend/metal/renderer.zig")
    else
        DisabledCapability;
} else DisabledCapability;

pub const core = struct {
    pub const clock = @import("core/clock.zig");
    pub const errors = @import("core/error.zig");
    pub const geometry = @import("core/geometry.zig");
    pub const appearance = @import("core/appearance.zig");
    pub const handles = @import("core/handle.zig");
    pub const memory = @import("core/memory.zig");
    pub const native_media = @import("core/native_media.zig");
    pub const metrics = @import("core/metrics.zig");
    pub const TrackedAllocator = @import("core/tracked_allocator.zig").TrackedAllocator;
};

pub const Error = core.errors.Error;
pub const Point = core.geometry.Point;
pub const Size = core.geometry.Size;
pub const Rect = core.geometry.Rect;
pub const Insets = core.geometry.Insets;
pub const Color = core.geometry.Color;
pub const CornerRadii = core.geometry.CornerRadii;
pub const Affine2D = core.geometry.Affine2D;
pub const ScaleFactor = core.geometry.ScaleFactor;
pub const Appearance = core.appearance.Appearance;
