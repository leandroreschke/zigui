# ZigUI Goal Contract

## Outcome

ZigUI is a complete, reusable, Zig-native desktop UI framework that lets an
application build responsive, accessible, GPU-rendered interfaces on macOS,
Windows, and Linux without inheriting Zed-specific application architecture or
third-party framework weight.

It preserves the mechanisms GPUI has demonstrated at real editor scale—stable
retained identity, selective invalidation, batched scene construction, native
GPU rendering, text correctness, input correctness, accessibility, and large
list virtualization—while making ownership, memory limits, capability
selection, failure handling, and custom extension boundaries explicit.

## Completion Criteria

- One platform-free engine owns retained composition, dependency tracking,
  layout, focus, input routing, accessibility semantics, scene construction,
  and deterministic frame transactions.
- macOS uses AppKit and Metal; Windows uses Win32 and D3D11; Linux supports
  native Wayland and X11 clients with Vulkan. Headless mode uses a deterministic
  CPU reference renderer.
- Text includes in-tree Unicode algorithms, OpenType parsing and shaping,
  fallback, TrueType and CFF rasterization, color-font support, selection,
  caret geometry, and native IME exchange.
- Custom elements can participate in measurement, arrangement, events,
  semantics, preparation, and portable scene painting without runtime
  reflection or registration. An advanced native GPU-pass API remains an
  explicitly unsafe ownership boundary.
- Source-only standard controls cover the common desktop vocabulary and are
  accessible, keyboard-correct, themeable, and individually dead-strippable.
  Applications may use none of them, mix them with custom elements, or replace
  them completely.
- Images, SVG, media, inspection, and detailed tracing are compile-time
  capability islands. Disabled islands contribute no linked implementation and
  allocate no runtime state.
- All retained collections, protocol queues, parser work, decoded data, atlas
  contents, platform text, accessibility trees, and framework-managed GPU
  resources have caller-configurable refusal boundaries.
- Application errors remain typed and recoverable. ZigUI never exits the
  process, silently substitutes another backend, or hides device/surface loss.
- Proof applications exercise windows, text and IME, input, accessibility,
  lists and custom canvas painting, scenes, external surfaces, and stress
  behavior through the public API.
- Public contracts, shaders, native backends, parsers, controls, allocation
  failure guarantees, malformed input handling, device loss, and cross-target
  compilation pass the consolidated verification campaign.

## Constraints

- Zig standard library plus native operating-system and GPU-driver APIs only.
- No Zig package dependencies, vendored third-party source, package-manager
  resolution, build-time downloads, runtime helper subprocesses, or convenience
  libraries for layout, text, codecs, windowing, protocols, accessibility, or
  rendering.
- The architecture is Zig-native and may use comptime specialization, tagged
  unions, explicit allocators, arenas, generational handles, and error unions;
  it is not a line-for-line Rust translation.
- The implementation is application-general and cannot require networking,
  storage, telemetry, a particular async runtime, global registries, or a
  Bookmarkitall/Zed domain model.
- Construction is completed across the committed scope before the consolidated
  build/test/repair campaign. The final campaign is not replaced by narrow
  checks performed during construction.

## Boundaries

- Applications own business state, persistence, networking, credentials,
  background execution policy, and product-specific components.
- ZigUI owns UI state lifecycles, rendering resources, platform services, and
  the validity of every public framework boundary.
- Native OS and GPU objects are borrowed or owned only according to their
  documented adapter contract. Driver-private memory, presentation buffers,
  and application-owned external surfaces cannot be counted as exact ZigUI
  allocations; all framework-created resources and all handle counts are still
  bounded.
- Standard controls are a maintained library above the engine, not mandatory
  runtime registration and not a closed component universe.
- Unsupported file-format or protocol features fail explicitly; malformed or
  over-budget input cannot become unchecked allocation or arithmetic.

## Verification

- Format and compile the default macOS/Metal framework and both public module
  consumers with the pinned Zig toolchain.
- Compile every proof application and run the complete headless conformance,
  parser, protocol, allocation-failure, malformed-input, and stress suites.
- Compile every valid target/backend/capability combination for macOS, Windows,
  Wayland, and X11, and prove invalid combinations fail configuration.
- Compile Metal and HLSL sources and validate generated Vulkan shader ABI and
  scene record layouts against their Zig definitions.
- Audit the package closure and produced binaries for third-party dependencies,
  hidden feature imports, and unrequested control/capability retention.
- Exercise native macOS windowing, input, text/IME, accessibility, resize,
  display-scale changes, minimize/restore, surface loss, and device-loss paths.
- Repeat the consolidated campaign after repairs until every applicable check
  is green or a real external blocker is evidenced.

## Blocked Conditions

- A required native SDK, compiler, target sysroot, display server, GPU driver,
  accessibility permission, or supported test machine is unavailable after all
  source-level and cross-compilation checks that do not require it are complete.
- A platform contract requires credentials, signing authority, hardware, or a
  manual OS permission that cannot be supplied by repository code.
- A published standard needed for interoperability is unavailable for lawful
  in-tree implementation and no native OS contract provides the capability.

Large scope, implementation difficulty, or the absence of a third-party
library are not blocked conditions.
