# Platform Contracts

ZigUI compiles exactly one window system and one renderer into an application.
Platform selection is explicit, and a platform may report a capability as
absent instead of installing a hidden fallback.

| Contract | macOS | Windows | Wayland | X11 | Headless |
| --- | --- | --- | --- | --- | --- |
| Window/event loop | AppKit | Win32 | in-tree Wayland client | in-tree X11 client | deterministic queue |
| Always-on-top windows | NSWindow level | Win32 topmost | unsupported | `_NET_WM_STATE_ABOVE` | deterministic state |
| Renderer | Metal | D3D11 | Vulkan | Vulkan | CPU reference |
| Text engine | in-tree | in-tree | in-tree | in-tree | in-tree when enabled |
| Native IME | `NSTextInputClient` | IMM32 | text-input-v3 when advertised | XIM wire protocol | absent |
| Accessibility | NSAccessibility | UI Automation | AT-SPI over in-tree D-Bus | AT-SPI over in-tree D-Bus | semantic tree only |
| Clipboard text | NSPasteboard | Win32 clipboard | data-device when advertised | X selections | deterministic memory clipboard |
| Rich clipboard | read text/file paths/PNG, detect promises, write file paths | absent | absent | absent | text snapshot |
| Open/save dialogs | AppKit panels | Win32 common dialogs | XDG desktop portal when reachable | XDG desktop portal when reachable | absent |
| Open/reveal/print service | NSWorkspace/Finder | absent | absent | absent | absent |
| Native media layer | AVPlayerLayer when media enabled | absent | absent | absent | absent |
| Native application/context menus | yes | yes | absent; use ZigUI controls | absent; use ZigUI controls | absent |
| Incoming file drag/drop | entered, moved, exited, dropped | dropped | entered, moved, exited, dropped | entered, moved, exited, dropped | injectable input events |
| Display enumeration | CoreGraphics/AppKit | monitor APIs | output protocol | RandR | one deterministic display |

The macOS adapter always installs a baseline application and Window menu, so
Quit, Minimize, Zoom, and Enter/Exit Full Screen behave as native commands even
when an application has not supplied custom menus. Application-defined menu
items are inserted without removing those lifecycle commands.

## Deliberate native differences

Wayland does not permit clients to choose global window coordinates. Therefore
`WindowOptions.position`, programmatic `WindowCommand.move`, programmatic
`WindowCommand.resize`, and `always_on_top` are rejected with `error.Unsupported`
instead of pretending that a compositor honored them. Interactive compositor
resize and configure events remain supported.

Wayland text input, clipboard, and fractional-scale behavior depend on the
protocol globals advertised by the compositor. Optional globals become absent
capabilities in `platform.Bundle`; they never cause a second window system or
text stack to be loaded.

Linux dialogs use the desktop portal through ZigUI's own D-Bus client. If the
session bus or portal is unavailable, `Bundle.dialogs` is null. No GTK, Qt, or
external helper process is used.

The Windows legacy file-drop contract provides a completed list, not native
hover phases. ZigUI emits `file_drop_performed` for that path. Applications
must not infer that entered/updated events exist on every platform.

macOS exposes `ApplicationServices` for opening URLs/files, revealing files in
Finder, and asking the owning application to print a document. Rich clipboard
snapshots own their text, file paths, and PNG bytes and explicitly report the
presence of promised-file representations. macOS can also publish bounded file
paths as native file URLs. These values are bounded by the normal clipboard and
file-path budgets.

With `-Dmedia=true`, macOS also exposes a bounded `NativeMedia` service backed
by AVPlayer and AVPlayerLayer. Its handles are tied to a ZigUI window and offer
frame updates, play/pause/seek, volume, mute, state, and deterministic teardown.
`widgets.NativeMediaView` synchronizes final committed layout bounds without
mutating platform state during component composition. The layer is a native
overlay above the Metal scene and does not inherit ZigUI clips or transforms;
applications keep controls outside its rectangle or provide their own
scene-integrated external surface source when GPU compositing order is required.

## Surface and device lifecycle

All native backends expose the same explicit surface states: uncreated,
awaiting configuration, configured, resizing, zero-sized/suspended, frame
pending, surface lost, device lost, closing, and closed. A zero-sized window is
not submitted. Surface loss recreates only the surface; device loss increments
the renderer device generation and invalidates all GPU-derived caches.

Renderer selection never falls back silently. Metal, D3D11, or Vulkan failure
is returned to the application. The null renderer is available only in an
explicit headless build.

Linux opens `libvulkan.so.1` through Zig's standard dynamic-library API and
resolves the dispatch table from `vkGetInstanceProcAddr`. The loader remains an
unavoidable native GPU-driver contract, but applications do not need a Vulkan
SDK or link-time development package to build.

If an asynchronous native callback cannot publish its bounded, owned event,
the platform context enters a terminal typed-failure state. Subsequent event
loop calls return the original failure until teardown; ZigUI never continues
after silently dropping a lifecycle or input transition.

## Coordinates and scale

Application layout, input, accessibility, and window sizes use logical pixels.
Render targets use device pixels and carry an explicit positive scale factor.
Display bounds and window move commands use the native desktop coordinate
space documented by `platform.Display`; Wayland global coordinates remain
unavailable. Fractional scales are retained as floating-point values and
pixel snapping occurs only at the rendering boundary.
