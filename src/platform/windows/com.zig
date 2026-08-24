const win = @import("abi.zig");

/// All Win32 COM interfaces are represented by their sole ABI invariant: the
/// first word is a pointer to a table of function pointers. Interface-specific
/// modules own and document the slot indices they invoke.
pub const Object = extern struct {
    vtable: [*]const *const anyopaque,
};

pub fn method(comptime Function: type, object: *Object, comptime index: usize) Function {
    return @ptrCast(object.vtable[index]);
}

pub fn queryInterface(object: *Object, id: *const win.GUID, result: *?*Object) win.HRESULT {
    const Function = *const fn (*Object, *const win.GUID, *?*Object) callconv(.winapi) win.HRESULT;
    return method(Function, object, 0)(object, id, result);
}

pub fn addRef(object: ?*Object) u32 {
    const value = object orelse return 0;
    const Function = *const fn (*Object) callconv(.winapi) u32;
    return method(Function, value, 1)(value);
}

pub fn release(object: ?*Object) void {
    const value = object orelse return;
    const Function = *const fn (*Object) callconv(.winapi) u32;
    _ = method(Function, value, 2)(value);
}

pub fn succeeded(value: win.HRESULT) bool {
    return value >= 0;
}

pub fn failed(value: win.HRESULT) bool {
    return value < 0;
}
