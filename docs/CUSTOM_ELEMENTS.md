# Controls and Custom Elements

## Use a standard control when behavior is standard

`ui.widgets` contains button, toggle, radio, tabs, select, dialog, tooltip,
split pane, slider, progress, scroll view, editable text field, separator, and
virtual list. These controls encode the focus order, keyboard commands,
pointer-capture transaction, disabled state, semantics, and bounded retained
state expected by desktop users.

Importing `ui.widgets` does not instantiate or register them. Referencing one
control reaches only the declarations and engine facilities that control uses;
heavy image, SVG, media, inspector, and tracing islands still require explicit
build options.

## Compose before writing a custom node

Product components should normally be ordinary build functions that return a
tree of `NodeSpec` values. This retains framework layout, focus, hit testing,
semantics, and scene batching with no custom lifecycle surface.

Use `ui.custom.Node` when the element needs one or more of:

- intrinsic measurement that cannot be represented by an ordinary node;
- final-geometry observation or same-frame geometry feedback;
- high-volume custom scene primitives;
- a specialized input gesture or virtual semantic descendants;
- device-generation-aware preparation;
- a backend-neutral drawing vocabulary beyond a standard control.

## Static custom contract

The custom value has a stable address and implements `paint`. Optional methods
are selected at comptime:

```zig
const Timeline = struct {
    pub fn measure(
        self: *Timeline,
        context: *ui.custom.MeasureContext,
        constraints: ui.layout.Constraints,
    ) ui.Error!ui.Size {
        _ = self;
        _ = context;
        return constraints.constrain(.{ .width = 640, .height = 180 });
    }

    pub fn paint(
        self: *Timeline,
        context: *ui.custom.PaintContext,
        bounds: ui.Rect,
    ) ui.Error!void {
        _ = self;
        try context.quad(.{
            .bounds = bounds,
            .background = ui.Color.rgba(0.08, 0.09, 0.11, 1),
            .border_color = .transparent,
            .border_widths = .{},
            .radii = .{},
        });
    }
};
```

Return it as `.kind = .{ .custom = ui.custom.Node.from(Timeline, &model.timeline) }`.
The pointer must outlive the retained node. Hook allocations use the supplied
scratch allocator unless the model deliberately owns longer-lived bounded
state.

Public custom results are validated. Non-finite geometry, invalid UTF-8,
malformed selection offsets, excessive semantic descendants, invalid scene
records, and over-budget payloads return typed errors rather than reaching a
native backend.

## Portable paint first

`PaintContext` emits typed quads, gradients, paths, shadows, underlines,
sprites, external surfaces, clips, layers, and text. Those records retain
batching and run unchanged on Metal, D3D11, Vulkan, and headless.

Use a `render_extension.Registry` entry only when the effect truly requires a
native GPU pipeline. The registry copies its UTF-8 label and owns the extension
context after successful registration. Destruction is submission-retired; the
context's `deinit` runs only after the last referencing epoch completes.
Borrowed device, encoder, command-buffer, target, and dispatch handles are valid
only during callbacks. An extension cannot submit, present, end ZigUI's active
pass, release borrowed objects, or retain callback pointers. It owns and bounds
every native resource it creates. Each encode callback receives the exact
bounded payload and flags emitted by `PaintContext.gpuPass`; neither value is
interpreted or discarded by the renderer.

## Performance rules

- Keep model/context pointers stable; do not allocate a new callback object per
  frame.
- Put temporary node descriptions and scene payloads in frame scratch.
- Retain only identity, interaction state, and measured caches that survive a
  rebuild.
- Virtualize before producing a large child tree.
- Request same-frame recomposition only when arrangement changed retained
  output, and converge within the eight-pass hard limit.
- Prefer scene primitives over a custom GPU pass so batching, clipping,
  headless conformance, and device-loss recovery remain framework-owned.
