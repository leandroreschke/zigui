const geometry = @import("geometry.zig");
const handles = @import("handle.zig");

/// One final window-space placement for a platform-owned native media layer.
pub const Placement = struct {
    id: handles.NativeMediaId,
    bounds: geometry.Rect,
};
