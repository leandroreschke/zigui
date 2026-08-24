//! macOS installed-font roots for ZigUI's in-tree OpenType engine.

const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const in_tree = @import("../../text/in_tree_backend.zig");
const catalog = @import("../../text/system_font_catalog.zig");
const objc = @import("objc.zig");

extern "c" fn NSHomeDirectory() objc.Id;

const preferred_families = [_][]const u8{
    "SF Pro",
    "SF Pro Text",
    "SF Pro Display",
    ".AppleSystemUIFont",
    "Helvetica Neue",
    "Helvetica",
    "Arial",
};

pub fn discover(allocator: std.mem.Allocator, backend: *in_tree.Backend) Error!catalog.Result {
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(allocator);
    try roots.appendSlice(allocator, &.{
        "/System/Library/Fonts",
        "/System/Library/AssetsV2/com_apple_MobileAsset_Font7",
        "/Library/Fonts",
        "/Network/Library/Fonts",
    });

    var user_fonts: ?[]u8 = null;
    defer if (user_fonts) |path| allocator.free(path);
    const home = objc.utf8(NSHomeDirectory());
    if (home.len != 0 and std.Io.Dir.path.isAbsolute(home)) {
        user_fonts = try std.Io.Dir.path.join(allocator, &.{ home, "Library", "Fonts" });
        try roots.append(allocator, user_fonts.?);
    }
    return catalog.discover(allocator, backend, roots.items, .{ .preferred_families = &preferred_families });
}
