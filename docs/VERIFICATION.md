# Verification

The construction pass is followed by one consolidated verification and repair
campaign. Final completion requires every applicable backend gate; a successful
macOS build does not freeze or prove portable contracts.

## Shared conformance

- Generational handle and stale-result rejection.
- Serialized update scopes, reentrancy rejection, deferred effects, and exact
  one-time release invariants.
- Owner-bound, one-shot prepared tokens for dependencies, focus, hit testing,
  and accessibility, including stale and cross-owner misuse.
- Deterministic layout, pixel snapping, hit testing, focus, and scene ordering.
- Stable accessibility identity, committed snapshot ownership, and action
  dispatch outside adapter locks.
- Fixed GPU ABI size, alignment, offsets, and shader record strides.
- Atlas cancellation, eviction, device reset, and completion-safe tile reuse.
- Deep-copied native event payloads; bounded native protocol/message queues,
  retained object tables, caches, allocation failure, and deterministic
  shutdown.
- Dependency closure inspection proving that only Zig standard-library source
  and native OS/GPU-driver contracts are present.

## Live backend coverage

- macOS AppKit/Metal/native IME/VoiceOver with in-tree font discovery,
  OpenType shaping, and glyph rasterization.
- Windows Win32/D3D11/native IME/UIA with the same in-tree text engine.
- Linux in-tree Wayland/Vulkan and X11/Vulkan with the same in-tree font,
  Unicode, shaping, input, D-Bus, and AT-SPI implementations.
- Resize, zero-size, occlusion, monitor migration, fractional scale, device
  loss, surface loss, compositor disconnect, clipboard ownership, and drag/drop.

## Proof applications

- `hello`
- `scene_gallery`
- `input_lab`
- `text_lab`
- `list_canvas_lab`
- `window_lab`
- `a11y_lab`
- `surface_lab`
- `stress_lab`

`surface_lab` drives the renderer-extension callback on every backend. Its
macOS configuration also creates an application-owned Metal texture, imports
it through the public external-surface contract, samples it in the scene, and
retires both ownership claims in submission order.

Product adoption, including Bookmarkitall, is an independent consumer gate and
is not coupled into the framework repository or its dependency graph.

## Consolidated campaign result

The 2026-08-24 through 2026-08-25 campaign used Zig
`0.17.0-dev.1745+ac8a8d0c5`. The Windows and Linux validation repairs were
combined at `7eff8cd0eb91b52f6932a7fce0878ac0af60422c` and completed with the
following repository-level results:

- `zig fmt --check` passed across `build.zig`, `src`, `tests`, `examples`, and
  `tools`.
- The target-selected suites passed in full: 94 tests on macOS, 94 on Linux,
  and 95 on Windows. The Windows run included 82 shared/conformance tests,
  7 protocol tests, 5 native D3D11 shader/offscreen tests, and a real Win32
  two-window lifecycle test.
- The 10,000-frame stress run completed 2,580,000 primitives with stable live
  bytes and zero allocations after warm-up.
- All nine proof applications linked with every capability enabled for native
  arm64 macOS/Metal, x86-64 Windows/D3D11, x86-64 Wayland/Vulkan, and x86-64
  X11/Vulkan. They also compiled in ReleaseSmall headless/null mode.
- Independent backend objects compiled for all four native target/backend
  pairs, and representative invalid pairs were rejected during build
  configuration.
- The Windows proof binary is a GUI-subsystem PE and imports only Windows
  system DLLs. Linux proof binaries import only the normal libc/loader runtime;
  Vulkan is opened dynamically at runtime. The macOS proof binary links only
  Apple frameworks and `libobjc`/`libSystem`.
- `build.zig.zon` has an empty dependency table; the source closure contains no
  vendored C, C++, Objective-C, archive, shared-library, or DLL payloads.
- A minimal ReleaseSmall headless build compiled with text, accessibility,
  images, SVG, media, inspection, and tracing all disabled.

Native macOS QA ran the signed Metal text proof through AppKit. It verified
multiscript shaping, AAT and OpenType behavior, joined color emoji, direct
character input through the registered `NSTextInputClient`, Unicode clipboard
editing, semantic value mutation, accessibility focus forwarding, pointer
enter/exit handling, fullscreen entry/restoration, resize redraw, window close,
and clean Command-Q shutdown. No crash report was produced after the repaired
native pass.

The same native pass exercised `surface_lab` and `window_lab`. It verified an
application-owned Metal texture imported through the public external-surface
contract, a validated custom GPU-pass callback, bounded texture retirement,
scroll overflow without flex shrink, cropped `cover` image placement, secondary
window minimize/restore/title/move/resize/hide/show operations, and cross-window
component invalidation. The available macOS host reported one connected Studio
Display, so physical monitor migration was not claimed.

Native Linux validation ran the exact combined commit on both Wayland/Vulkan
and X11/Vulkan. All nine proof applications opened and rendered; window
lifecycle, clipboard, text, AT-SPI, external surfaces, and custom render passes
were healthy. Its 10,000-frame stress run completed 2,580,000 primitives with
live bytes and allocation counts unchanged after warm-up. KDE/XWayland reported
live windows as `_NET_WM_STATE_HIDDEN`, so minimize-state metadata remains
inconclusive even though rendering, interaction, and process health were good.

Native Windows validation ran the exact combined commit through Win32/D3D11.
All nine full-capability proof applications built, and Hello, Text Lab, Window
Lab, and Surface Lab opened, rendered, and remained responsive. The Hello
action dispatched correctly, window and external-surface paths stayed healthy,
and the 10,000-frame stress contract completed with zero post-warm-up
allocations. A suspected heading/subtitle spacing regression reproduced on the
earlier Windows-only commit and was therefore not introduced by the combined
Linux changes.

The remaining live gates require targeted hardware or manual assistive-input
sessions: physical second-monitor migration, real IME composition, Explorer
drag-and-drop, forced GPU removal/device loss, application-owned external D3D11
texture import, and full screen-reader narration on Windows; physical monitor
migration on the available single-display Mac; and a real marked-text input
source plus forced Metal device loss on macOS. Their bounded shared state
transitions remain covered by deterministic conformance tests.
