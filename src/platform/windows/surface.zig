const handles = @import("../../core/handle.zig");
const win = @import("abi.zig");

pub const Provider = struct {
    context: *anyopaque,
    window_fn: *const fn (*anyopaque, handles.WindowId) win.HWND,

    pub fn window(self: Provider, id: handles.WindowId) win.HWND {
        return self.window_fn(self.context, id);
    }
};
