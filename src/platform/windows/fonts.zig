//! Windows installed-font roots for ZigUI's in-tree OpenType engine.

const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const in_tree = @import("../../text/in_tree_backend.zig");
const catalog = @import("../../text/system_font_catalog.zig");
const win = @import("abi.zig");

const preferred_families = [_][]const u8{
    "Segoe UI",
    "Arial",
    "Tahoma",
    "Calibri",
};

const folder_id_local_app_data: win.GUID = .{
    .data1 = 0xf1b32785,
    .data2 = 0x6fba,
    .data3 = 0x4fcf,
    .data4 = .{ 0x9d, 0x55, 0x7b, 0x8e, 0x7f, 0x15, 0x70, 0x91 },
};

pub fn discover(allocator: std.mem.Allocator, backend: *in_tree.Backend) Error!catalog.Result {
    const windows_root = try windowsDirectory(allocator);
    defer allocator.free(windows_root);
    const system_fonts = try std.Io.Dir.path.join(allocator, &.{ windows_root, "Fonts" });
    defer allocator.free(system_fonts);

    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(allocator);
    try roots.append(allocator, system_fonts);

    var local_fonts: ?[]u8 = null;
    defer if (local_fonts) |path| allocator.free(path);
    if (try localAppData(allocator)) |local| {
        defer allocator.free(local);
        local_fonts = try std.Io.Dir.path.join(allocator, &.{ local, "Microsoft", "Windows", "Fonts" });
        try roots.append(allocator, local_fonts.?);
    }
    return catalog.discover(allocator, backend, roots.items, .{ .preferred_families = &preferred_families });
}

fn windowsDirectory(allocator: std.mem.Allocator) Error![]u8 {
    var buffer: [32_768]u16 = undefined;
    const length = win.GetWindowsDirectoryW(&buffer, buffer.len);
    if (length == 0 or length >= buffer.len) return error.PlatformFailure;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..length]);
}

fn localAppData(allocator: std.mem.Allocator) Error!?[]u8 {
    var native: ?[*:0]win.WCHAR = null;
    if (!win.succeeded(win.SHGetKnownFolderPath(&folder_id_local_app_data, 0, null, &native)) or native == null) return null;
    defer win.CoTaskMemFree(native);
    return try std.unicode.wtf16LeToWtf8Alloc(allocator, std.mem.span(native.?));
}
