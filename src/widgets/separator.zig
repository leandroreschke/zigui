const geometry = @import("../core/geometry.zig");
const node = @import("../compose/node.zig");
const Theme = @import("theme.zig").Theme;

pub const Orientation = enum { horizontal, vertical };

pub fn separator(orientation: Orientation, theme: *const Theme) node.Spec {
    return .{
        .kind = .container,
        .style = .{
            .layout = switch (orientation) {
                .horizontal => .{ .width = .{ .percent = 1 }, .height = .{ .points = 1 } },
                .vertical => .{ .width = .{ .points = 1 }, .height = .{ .percent = 1 } },
            },
            .paint = .{ .background = .{ .solid = theme.border } },
        },
        .semantics = .{ .role = .separator },
    };
}

comptime {
    _ = geometry.Color;
}
