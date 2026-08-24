# ZigUI

ZigUI is a modular, GPU-driven desktop UI framework written for Zig. It keeps
the correct fast path as the default, supports portable high-performance custom
elements, and makes heavyweight capabilities explicit.

The supported desktop architecture is:

- macOS: AppKit window/input services, Metal, ZigUI's in-tree text engine,
  native IME bridging, and accessibility;
- Windows: Win32 window/input services, D3D11, ZigUI's in-tree text engine,
  native IME bridging, and UI Automation;
- Linux: in-tree Wayland or X11 protocols, the native Vulkan loader ABI with
  dynamically resolved dispatch, an
  in-tree OpenType/Unicode text stack, and in-tree D-Bus/AT-SPI transport;
- headless: deterministic scene construction plus explicit CPU reference
  rasterization for conformance tests and image snapshots.

ZigUI does not include application networking, databases, credential storage,
telemetry, or an async runtime. Applications own their domain state and supply
optional task execution and asset providers.

ZigUI has no third-party package or runtime-library dependencies. It uses the
Zig standard library and native operating-system/GPU-driver contracts only.
Linux protocol clients, text processing, keyboard handling, image codecs, and
accessibility transport are implemented inside this repository.

## Design commitments

- One authoritative UI-thread owner and no atomic reference counting in the
  ordinary state path.
- Caller-owned allocators, frame arenas, generational handles, bounded caches,
  and explicit GPU submission epochs.
- Retained state and identity with declarative, dirty-subtree composition.
- A backend-neutral typed scene consumed by native GPU renderers.
- Native text, IME, accessibility, focus, actions, virtualization, and custom
  elements as correctness features rather than afterthoughts.
- Narrow platform capabilities instead of one universal platform object.
- Typed recoverable failures; library code never exits the process.
- Compile-time selection of one platform/backend and only requested optional
  capability modules.

See the [Goal Contract](docs/GOAL.md), [Design Rationale](docs/DESIGN_RATIONALE.md), [Getting Started](docs/GETTING_STARTED.md), [Architecture](docs/ARCHITECTURE.md), [Controls and Custom Elements](docs/CUSTOM_ELEMENTS.md), [Platform Contracts](docs/PLATFORMS.md),
[Supported Formats](docs/FORMATS.md), [Performance Contract](docs/PERFORMANCE.md),
[Dependency Policy](docs/DEPENDENCIES.md), [Data Provenance](docs/PROVENANCE.md),
and [Verification](docs/VERIFICATION.md).

## Build configuration

```sh
zig build -Dplatform=macos -Drenderer=metal
zig build -Dplatform=windows -Drenderer=d3d11
zig build -Dplatform=linux_wayland -Drenderer=vulkan
zig build -Dplatform=headless -Drenderer=null
```

Optional capability islands are selected with `-Dtext`, `-Da11y`, `-Dimages`,
`-Dsvg`, `-Dmedia`, `-Dinspector`, and `-Dtracing`.

All optional capabilities are implemented in this repository. Enabling one
never downloads or links a third-party package.

`zigui_core` is a separate public module containing only platform-free engine
contracts. It does not import a window system, GPU backend, font engine, codec,
standard control, inspector, or tracing implementation. A bare `zig build`
compiles dedicated consumers for both public modules so a lazy module graph
cannot produce a false-success no-op build. The `examples` step compiles every
proof application; ordinary builds do not compile those executables.
