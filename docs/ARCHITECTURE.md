# Architecture

## Ownership

The event-loop thread is the sole mutable owner of application UI state,
windows, composition, layout, input dispatch, semantic trees, scene generation,
and renderer submission. Native callbacks and workers enqueue typed messages;
they never mutate the tree directly.

Application state remains application-owned. Framework-managed state and
resources use `{ index, generation }` handles. A state read records a dependency;
a state mutation increments its version and invalidates only dependent component
boundaries or windows.

Callback/update scopes serialize framework mutation and defer queued effects
until dispatch reaches a quiescent boundary. They are not an automatic undo log
for application model writes: a callback that mutates application-owned data
and then returns an error remains responsible for that model state. User
callbacks cannot re-enter UI mutation during layout, preparation, painting,
submission, or accessibility adapter calls.

The framework applies strong allocation-failure guarantees at its retained
ownership boundaries. Node reconciliation and dependency-edge replacement
either publish a complete replacement or leave the prior retained records
intact. Native events and semantic snapshots deep-copy borrowed platform or
tree text before publication, so queued and committed readers never observe
expired callback/frame memory.

Platform-owned titles, surrounding-text snapshots, protocol metadata, keymaps,
and IME staging share one exact aggregate retained-text budget. Clipboard,
menu, and queued-event ownership remain separately budgeted so one service
cannot silently consume another service's allowance.

## Frame transaction

```text
drain native events and worker messages
  -> dispatch against the committed hit tree
  -> run one serialized update scope and drain effects
  -> compose and reconcile dirty component subtrees
  -> measure and arrange
  -> repeat compose/measure/arrange only for declared geometry feedback
  -> prepare text, resources, hit testing, focus, and semantics
  -> generate typed scene streams
  -> encode, submit, and present
  -> commit frame and schedule only required future work
```

Separate phase-context types prevent operations from being invoked in the wrong
phase. Hit testing, focus order, accessibility output, and the scene are staged
and published only after a successful GPU submission. Retained composition and
layout represent the current serialized update state; renderer or adapter
failure does not roll back arbitrary application-owned writes.

Custom arrange hooks can request same-frame recomposition when retained output
depends on geometry learned only during arrangement. ZigUI caps this
stabilization at eight feedback passes and returns `error.BudgetExceeded` if an
element does not converge. Absolute observer nodes also receive their final
containing content bounds and scroll extent, which lets virtualized and
scrolling controls synchronize their public models without a blank or stale
frame.

## Composition

Widget build functions emit short-lived node descriptions into a per-window
frame arena. Reconciliation retains only stable identity, widget state,
dependency versions, focus and scroll state, and explicitly selected caches.

Ordinary nodes are concrete tagged unions. Custom nodes use compile-time static
dispatch and optional hooks for measurement, arrangement, events, semantics,
preparation, and paint. Portable custom painting emits ZigUI scene primitives;
raw native GPU access is a separate advanced extension.

## Scene

The scene owns typed structure-of-arrays payload streams and one ordered
operation stream. An ordered operation references a typed range, clip, layer,
material, and target. Payloads are never duplicated into a second polymorphic
representation.

GPU-facing records use fixed-width `extern struct` layouts. Zig compile-time
size and offset assertions and backend shader-layout tests keep Metal, HLSL,
and SPIR-V interfaces synchronized.

## Resources

Every GPU resource contains both a slot generation and a device generation.
Every submission receives a monotonically increasing epoch. Buffers, textures,
atlas tiles, descriptors, and external surfaces may be reused only after the
last referencing epoch completes.

Device loss increments the device generation and invalidates pipelines,
resource realizations, atlases, glyph references, pending uploads, and window
surface state as one recovery operation. Surface loss retires only the affected
window presentation resources and does not discard device-wide caches.

## Platform boundaries

Backends implement independent capabilities:

- runtime and event loop;
- window system and presentation surface;
- frame clock;
- normalized input and native text input;
- text shaping and rasterization;
- clipboard, menus, dialogs, and drag/drop;
- display information;
- accessibility adapter.

Backend-owned native handles remain opaque. Platform-specific lifecycle state
is explicit rather than represented by optional no-op methods.

Every platform-to-UI event with dynamic text or path data owns a bounded copy
until dispatch completes. Window titles, surrounding text, display names,
dialog results, menus, clipboard snapshots, native object tables, and protocol
message queues all have explicit count or aggregate-byte refusal boundaries.

## Modularity

The mandatory engine includes state, invalidation, composition, layout, input,
semantics, scene construction, rendering contracts, and custom nodes. Standard
controls are a source-only optional layer built from engine primitives. Heavy
capability islands such as images, SVG, media, inspection, and tracing require
explicit build selection and allocate no state until used.

The package exposes `zigui_core` as a genuine platform-free import. The full
`zigui` module selects exactly one native platform and renderer. Standard
controls remain source-only declarations: unused controls do not produce
linked code or runtime registration, and applications can bypass the control
layer entirely through custom nodes and scene primitives.

Grid placement uses a bounded row-major occupancy plan. Automatic items avoid
definite cells even when the definite declaration appears later in source
order; spans reserve their full area. Fully definite row-and-column items may
overlap deliberately. Sparse explicit rows cannot expand scratch storage past
`layout_grid_cell_count`.

## Dependency ownership

The repository depends only on the Zig standard library and unavoidable native
OS/GPU-driver contracts. It does not wrap third-party UI, layout, protocol,
text, image, Unicode, accessibility, or async libraries.

The Linux implementation owns its Wayland and X11 wire protocols, Vulkan
dispatch resolved through the native system loader, D-Bus/AT-SPI messages,
keyboard description and composition,
font discovery, OpenType parsing, Unicode algorithms, shaping, and glyph
rasterization. Optional image and SVG modules likewise use in-tree codecs and
parsers.
