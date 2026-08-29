# Getting Started

ZigUI is consumed as Zig source. The package has no transitive package
dependencies and performs no runtime discovery of alternate UI engines. An
application selects one platform/renderer pair at build time; `auto` chooses
the native pair for the target.

```sh
zig build -Dplatform=macos -Drenderer=metal
zig build run-hello -Dplatform=macos -Drenderer=metal
```

The equivalent pairs are `windows`/`d3d11`, `linux_wayland`/`vulkan`,
`linux_x11`/`vulkan`, and `headless`/`null`. Optional implementation islands
are selected with `-Dtext`, `-Da11y`, `-Dimages`, `-Dsvg`, `-Dmedia`,
`-Dinspector`, and `-Dtracing`. A disabled island is not imported by the full
module and cannot allocate or register runtime state.

On macOS, Xcode may require its official Metal compiler component to be
installed with `xcodebuild -downloadComponent MetalToolchain`. Its installed
location can be inspected with
`xcodebuild -showComponent MetalToolchain -json`; pass
`-Dmetal-toolchain=/absolute/path/to/Metal.xctoolchain` when `xcrun` does not
select it automatically. This SDK compiler is a build-environment tool, not a
ZigUI package dependency. Linux resolves `libvulkan.so.1` at runtime through
`std.DynLib`, so a Vulkan SDK or link-time development package is not part of
the ZigUI build.

The macOS backend supplies baseline application and Window menus. Command-Q,
Command-M, Zoom, and Control-Command-F therefore remain native lifecycle
commands before an application installs any custom menu items.

## Application and component lifetime

An application owns its allocator, model values, and the event-loop thread.
The model passed through `Component.Descriptor` must remain at a stable address
until its component is destroyed.

```zig
const std = @import("std");
const ui = @import("zigui");

const Model = struct {
    count: usize = 0,
    button: ui.widgets.Button = undefined,

    fn init(self: *Model) void {
        self.button = .{
            .label = "Count",
            .on_activate = ui.widgets.Callback.from(Model, self, "increment"),
        };
    }

    fn increment(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        self.count +|= 1;
        try ctx.invalidate(.{});
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const label = try std.fmt.allocPrint(ctx.allocator, "Count: {d}", .{self.count});
        const children = try ctx.allocator.alloc(ui.NodeSpec, 2);
        children[0] = try self.button.build(ctx);
        children[1] = .{ .kind = .{ .text = label } };
        return .{ .children = children };
    }
};
```

`BuildContext.allocator` is frame scratch. Node descriptions, temporary child
arrays, and temporary strings may use it; they must not be retained by the
application. Reconciliation copies the data that survives the build. Handler,
custom-element, and component context pointers are not copied, so the values
they address must remain stable.

Create the app, open one or more windows, and run the native event loop:

```zig
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
defer _ = gpa.deinit();
var model: Model = .{};
model.init();

const app = try ui.App.create(gpa.allocator(), .{
    .application_name = "Example",
});
defer app.destroy() catch {};
_ = try app.openWindow(.{
    .platform = .{ .title = "Example", .size = .{ .width = 640, .height = 420 } },
}, ui.Component.Descriptor.from(Model, &model));
try app.run();
```

`App`, window mutation, state mutation, and retained-tree APIs are UI-thread
affine. Library calls return typed errors; applications decide whether to show,
retry, log, or terminate. ZigUI never switches to a CPU renderer after a GPU
failure. Counter, clock, tracing, renderer-capability, and device-generation
queries are also UI-thread affine so snapshots never race a frame submission.

One `App` owns the process UI runtime by default. Deterministic headless tests
that need multiple independent apps may explicitly set
`allow_multiple_apps_for_testing`; production code should not. App and native
service mutations are accepted only while the runtime is idle or inside its
serialized event/update transaction. Calls from build, layout, prepare, paint,
GPU submission, presentation, or accessibility adapter hooks return
`error.FramePhaseViolation` instead of re-entering mutable framework state.

## Child components

A reusable component stores each child identity in a stable slot initialized
to `.invalid`:

```zig
child_id: ui.core.handles.ComponentId = .invalid,

const child = try ctx.childComponent(&self.child_id,
    ui.Component.Descriptor.from(ChildModel, &self.child_model));
```

The parent owns the child. When absent from a retained mount pass, the child is
suspended and its dependencies and tasks are detached; when the parent is
destroyed, children are recursively destroyed. A child cannot be mounted under
another parent or window.

Application-owned visual timelines can opt a component into the native
display cadence with `ui.Component.Descriptor.fromWithFrame(T, &model)`. The
model implements `frame(now_ns) !ui.Component.FrameUpdate`; the timestamp uses
the platform event-loop clock, `dirty` identifies the retained work changed by
that sample, and `request_next_frame` keeps the native display scheduler active
only while more samples are required. Ordinary components are not scanned.
Easing, semantic targets, interruption, and reduced-motion policy remain in
the application. The hook runs before composition in a phase where App service
mutation is rejected, so it cannot re-enter window or resource ownership.

## Standard controls and custom elements

`ui.widgets` supplies the common desktop controls: button, toggle, radio,
tabs, select, dialog, tooltip, split pane, slider, progress, scroll view,
editable text field, separator, and virtual list. They are ordinary Zig source
declarations with no registry and no separate runtime. Unreferenced controls do
not contribute linked code.

Applications can bypass them at any depth. A custom element is a stable model
pointer wrapped with `ui.custom.Node.from(T, &value)`. `T` must implement
`paint`; it may also implement `measure`, `arrange`, `prepare`, `event`, and
`semantics`. Portable paint hooks emit typed quads, gradients, paths, sprites,
layers, clips, text, and external surfaces. The advanced custom-GPU-pass API is
separate so ordinary custom elements remain backend-neutral.

Custom hooks receive scratch allocators and narrow services. They never own the
font system, atlases, scene, renderer, or app. A custom value must remain at a
stable address as long as its retained node can exist.

An `arrange` hook may call `ArrangeContext.requestRecompose()` after learning
geometry that changes the node descriptions it will build. The runtime repeats
compose, measure, and arrange in the current frame and refuses a ninth feedback
pass. Arrange-time model changes must be limited to transient geometry/cache
state; App registries and native services remain unavailable in that phase.

`Tabs`, `Select`, and `TextField` own bounded backing allocations and must be
initialized with their `init` functions, kept at stable addresses, and
deinitialized explicitly. `HeightIndex` has the same explicit lifetime rule.
Other controls are allocation-free model values. The text field includes
grapheme-safe selection, word/line navigation, pointer selection, IME marked
text, clipboard editing, and bounded undo/redo history. Password fields never
copy their contents to the clipboard.

Native context-menu definitions may attach an opaque `u64` payload to each
action item. ZigUI copies that value into `ActionEvent.menu_payload`, allowing
an application to identify the originating record without maintaining a
global action-to-selection bridge. Keyboard and accessibility actions receive
zero unless a native menu supplied a payload.

Desktop shortcuts that belong to a surrounding workspace but must yield to an
editable field can use `App.bindActionExcludingTextInput`. The router derives
that state from the committed focused semantic role (`text_field` or
`search_field`) before resolving keyboard bindings. The exclusion applies only
to keyboard resolution; menu, accessibility, and programmatic actions retain
their ordinary context dispatch.

Native menu topology remains application-owned. A macOS application group may
include an explicit `quit_application` item when it needs the standard Quit
action with a product-specific label; ZigUI synthesizes an app-named Quit only
when that action is absent. Likewise, a top-level `Window` submenu is installed
as the application's native windows menu without adding another framework
Window menu. When no Window submenu is supplied, ZigUI provides the standard
Minimize, Zoom, Enter Full Screen, and Bring All to Front fallback. System menu
actions retain AppKit ownership, selectors, and key equivalents in both cases.

`App.readClipboardContents` returns one allocator-owned snapshot containing
available text, native file paths, encoded PNG bytes, and promised-file
detection. `App.writeClipboardPaths` publishes native file URLs when that
optional clipboard operation is available. `App.openUrl`, `openPath`,
`revealPath`, and `printPath` use the
platform's optional application-services contract. A missing native service is
reported as `error.MissingCapability`; ZigUI never launches a helper fallback.

On macOS with `-Dmedia=true`, `App.createNativeMedia` creates a bounded native
AVPlayerLayer attached to a ZigUI window. The returned generational handle
supports frame updates, play/pause/seek, volume, mute, state queries, and
explicit destruction. Closing the owner window destroys any remaining native
players. State queries report platform-neutral `loading`, `ready`, or `failed`
readiness, a `has_presented_frame` signal independent of playback rate, and may
include a bounded inline-owned `error_description` for a failed item, so
product code can render its own status treatment without native object access.
For layout-driven presentation, keep a `widgets.NativeMediaView` at a
stable address and expose it as a custom node; its paint declaration moves the
native layer to the final committed bounds. Do not call native-media services
from component build, measure, arrange, prepare, or paint hooks.
Read-only `App.nativeMediaState` queries are allowed from a registered
component frame hook so playback controls can sample at the platform display
cadence. Playback, seek, volume, mute, frame, creation, and destruction remain
serialized mutations and are rejected from that hook.

## Tasks

ZigUI deliberately owns no thread pool or async runtime. An application may
install one `runtime_task.Host`. The host contract is strict:

- `start` installs the bounded completion sink without retaining it on error;
- `spawn` consumes work only on success;
- every accepted work item is either run once to a terminal completion or
  dropped once during bounded queue cancellation;
- `shutdown` joins all workers before returning and leaves no access to work,
  tokens, or the completion sink.

`App.spawnTask` consumes its context on every outcome. For accepted work,
`run_fn` executes on a worker, `apply_fn` executes at most once on the UI thread
if the owner is still live, and `drop_fn` executes exactly once after apply,
cancellation, staleness, queue rejection, spawn rejection, or an earlier API
validation failure.

## Memory policy

`AppConfig.memory` controls retained and per-batch bounds. Important hot-path
limits include:

- `frame_arena_bytes` and `event_arena_bytes` for short-lived UI work;
- `retained_node_count`, `retained_tree_depth`, and `retained_tree_bytes` for
  live retained identity, child storage, handlers, styles, and owned text;
- `layout_grid_cell_count` for one grid container's temporary occupancy plan;
- `component_count`, `state_count`, `dependency_edge_count`, `effect_count`,
  and `window_count` for framework runtime identity and relationships;
- `platform_event_count`, `platform_event_payload_bytes`, and
  `platform_event_queue_bytes` for deep-copied native events;
- `platform_text_bytes` for one platform-facing text operation and
  `platform_retained_text_bytes` for aggregate framework-owned native titles,
  surrounding-text snapshots, keymaps, protocol names, and IME staging;
- `clipboard_bytes`, `clipboard_retained_bytes`, `file_drop_path_count`,
  `menu_item_count`, `menu_depth`, `menu_text_bytes`, and
  `platform_object_count` for other native services and protocol state;
- `action_count`, `action_binding_count`, `action_name_bytes`,
  `action_context_count`, and `pointer_capture_count` for input routing;
- `texture_count` and `texture_cpu_copy_bytes` for framework texture identity
  and recovery copies, independently of optional image decoding;
- `upload_ring_bytes` for structured GPU uploads and tessellated path output;
- `path_edge_count` and `path_work_units` for one scene render batch;
- `path_cache_bytes`, `text_layout_bytes`, and `glyph_atlas_bytes` for retained
  caches;
- external-surface, render-extension, scene stream, encoded/decoded image, SVG
  document, media, font catalog/instance, accessibility, trace, and worker-queue
  limits. Capability-specific limits may be zero when that island is disabled.

A limit is a refusal boundary, not a hint. Inputs that would exceed it return
`error.BudgetExceeded` before unbounded work or attacker-sized allocation. The
path tessellator spatially prunes non-overlapping edges and charges both
edge-pair checks and band scans against the frame-wide work budget.

Allocation counters are exact when the application supplies
`core.TrackedAllocator`; framework phase, invalidation, scene, cache, atlas,
upload, worker, presentation, and latency counters remain available with any
allocator.

Replacing a retained value may temporarily own both the committed and proposed
copies so failure can preserve the committed value. Configure budgets for this
bounded replacement peak, not only the eventual steady-state payload.

## Dependency boundary

ZigUI itself uses only Zig's standard library and direct APIs provided by the
target OS or installed GPU driver. Those native ABIs are required to create a
window, receive native input/IME/accessibility events, and submit GPU commands;
they are not replaceable framework dependencies. ZigUI does not link or vendor
a layout, text, Unicode, image, SVG, window, protocol, accessibility, GPU
abstraction, task-runtime, logging, networking, or widget library.
