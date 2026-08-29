const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const geometry = @import("../core/geometry.zig");
const custom = @import("../compose/custom.zig");

/// A layout-aware declaration for a platform native-media layer. Store this
/// value at a stable address and use it as a custom node while its handle is
/// alive. Native overlays are window-space rectangles above the GPU scene and
/// do not participate in ZigUI clipping or transforms.
pub const NativeMediaView = struct {
    id: handles.NativeMediaId,
    visible: bool = true,

    pub fn paint(self: *NativeMediaView, context: *custom.PaintContext, bounds: geometry.Rect) Error!void {
        try context.nativeMediaWithVisibility(self.id, bounds, self.visible);
    }
};
