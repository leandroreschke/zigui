//! ZigUI's platform-free contract module.
//!
//! Import `zigui_core` when code needs geometry, retained descriptions,
//! runtime state, input, semantics, scene records, or renderer contracts but
//! must not pull a window system, GPU backend, font engine, codec, widget set,
//! inspector, or tracing implementation into the compilation graph.

pub const layout = @import("layout/style.zig");
pub const layout_engine = @import("layout/engine.zig");
pub const input = @import("input/event.zig");
pub const hit_testing = @import("input/hit_tree.zig");
pub const focus = @import("input/focus.zig");
pub const actions = @import("input/action.zig");
pub const accessibility = @import("a11y/api.zig");
pub const text = @import("text/api.zig");
pub const scene_abi = @import("scene/abi.zig");
pub const scene = @import("scene/scene.zig");
pub const render = @import("render/api.zig");
pub const render_extension = @import("render/extension.zig");
pub const runtime_phase = @import("runtime/phase.zig");
pub const runtime_state = @import("runtime/state.zig");
pub const runtime_dependency = @import("runtime/dependency.zig");
pub const runtime_effect = @import("runtime/effect.zig");
pub const runtime_queue = @import("runtime/queue.zig");
pub const runtime_task = @import("runtime/task.zig");
pub const runtime_invalidation = @import("runtime/invalidation.zig");
pub const ThreadAffinity = @import("runtime/thread_affinity.zig").ThreadAffinity;
pub const style = @import("compose/style.zig");
pub const node = @import("compose/node.zig");
pub const custom = @import("compose/custom.zig");
pub const NodeStore = @import("compose/store.zig").Store;
pub const NodeSpec = node.Spec;

pub const clock = @import("core/clock.zig");
pub const configuration = @import("core/config.zig");
pub const errors = @import("core/error.zig");
pub const geometry = @import("core/geometry.zig");
pub const handles = @import("core/handle.zig");
pub const memory = @import("core/memory.zig");
pub const native_media = @import("core/native_media.zig");
pub const metrics = @import("core/metrics.zig");
pub const TrackedAllocator = @import("core/tracked_allocator.zig").TrackedAllocator;

pub const Error = errors.Error;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Insets = geometry.Insets;
pub const Color = geometry.Color;
pub const CornerRadii = geometry.CornerRadii;
pub const Affine2D = geometry.Affine2D;
pub const ScaleFactor = geometry.ScaleFactor;
