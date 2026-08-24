const handles = @import("../../core/handle.zig");
const objc = @import("objc.zig");

pub const Provider = struct {
    context: *anyopaque,
    layer_fn: *const fn (*anyopaque, handles.WindowId) objc.Id,

    pub fn layer(self: Provider, window: handles.WindowId) objc.Id {
        return self.layer_fn(self.context, window);
    }
};
