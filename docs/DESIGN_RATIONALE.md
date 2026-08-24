# Design Rationale

ZigUI uses Zed's GPUI as evidence that a retained, selectively invalidated UI
tree feeding a compact GPU scene can sustain demanding desktop applications.
It does not copy GPUI's crate graph, Rust ownership model, macro registration,
application services, or Zed-specific runtime choices.

## What ZigUI keeps

- Stable element identity and retained state across declarative rebuilds.
- Dependency-driven invalidation instead of rebuilding every application view.
- One ordered, backend-neutral scene handed to a native renderer.
- GPU batching, atlases, explicit submission lifetime, and device-loss
  recovery.
- First-class desktop text, IME, focus, accessibility, actions, and
  virtualization.
- A low-level custom element path for workloads that do not fit a standard
  control.

These are architectural mechanisms, not Rust APIs to transliterate.

## What ZigUI changes

- The engine has no application networking, URL, serialization, telemetry,
  global registration, or prescribed async runtime.
- `zigui_core` is an enforced platform-free module. Native backends, font
  implementation, codecs, diagnostics, and controls cannot enter it
  transitively.
- Exactly one platform/renderer pair is selected at compile time. Optional
  capability islands are not broad default feature bundles.
- Allocators and ownership transfers are explicit. Mutable UI state has one
  thread owner; generational handles cross subsystem boundaries without shared
  reference-counted object graphs.
- Counts, bytes, parser work, tree depth, protocol queues, GPU epochs, and
  replacement peaks have refusal limits. Limits produce typed errors before
  unbounded allocation or work.
- Frame publication is transactional: hit testing, focus, semantics, and scene
  state become visible only with the successfully submitted frame.
- Native platform contracts are narrow capabilities rather than one object
  that accumulates application services.
- Public callback boundaries validate returned geometry, text, pixels,
  identities, and ownership instead of trusting an extension to uphold hidden
  invariants.

## Engine, controls, and custom elements

ZigUI deliberately supplies both an engine and a maintained standard-control
library. Choosing only one would make the framework worse:

- an engine alone repeatedly pushes subtle keyboard, focus, IME,
  accessibility, disabled-state, pointer-capture, and memory mistakes into
  every application;
- a closed widget framework cannot cover editors, timelines, diagrams, maps,
  inspectors, games, or product-specific interaction without becoming a large
  mandatory object hierarchy.

The boundary is therefore three-tiered:

1. Engine primitives provide layout, input, semantics, scene records, and
   lifecycle correctness.
2. `ui.widgets` provides source-only controls for common desktop behavior.
   There is no widget registry, factory table, stylesheet runtime, or automatic
   initialization. Zig's reachability removes unused declarations.
3. `ui.custom.Node` provides statically dispatched custom behavior and
   portable scene painting. `render_extension` separately exposes borrowed
   native command state for the rare backend-specific pass.

An application can use a button without importing an image decoder, use a
custom canvas without any standard control, or assemble a reusable product
component from both. The maintained controls establish safe performance and
accessibility defaults without defining the limits of the framework.

## Cost model

Compile-time selection controls code inclusion. Runtime cost is additionally
demand-driven: no optional manager, cache, atlas, protocol object, or worker
exists before the corresponding capability is enabled and used.

Framework-created textures are counted against `GpuPolicy.maximum_gpu_bytes`
and their CPU recovery copies against `texture_cpu_copy_bytes`. GPU-driver
private allocations, native presentation buffers, and application-owned
external surfaces cannot be measured exactly by a portable framework; their
object counts and ownership transitions remain bounded, and custom GPU
extensions must document and enforce their own native allocation ceiling.

## Zero-dependency consequence

Owning the full stack is intentional, not a claim that specifications are
small. ZigUI must maintain its Unicode/OpenType implementation, codecs,
Wayland/X11 and D-Bus wires, accessibility adapters, and renderer ABIs with the
same conformance discipline normally distributed across dependencies. A
missing case is implemented or rejected explicitly; it is never delegated to
an undeclared runtime library or helper process.
