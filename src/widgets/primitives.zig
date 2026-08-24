const geometry = @import("../core/geometry.zig");
const node = @import("../compose/node.zig");
const compose_style = @import("../compose/style.zig");
const layout = @import("../layout/style.zig");

pub fn text(value: []const u8, text_style: compose_style.TextStyle) node.Spec {
    return .{ .kind = .{ .text = value }, .style = .{ .text = text_style } };
}

pub fn container(children: []const node.Spec, style: compose_style.Style) node.Spec {
    return .{ .kind = .container, .style = style, .children = children };
}

pub fn row(children: []const node.Spec, gap: f32) node.Spec {
    return .{
        .kind = .container,
        .style = .{ .layout = .{ .direction = .row, .gap = .{ .width = gap } } },
        .children = children,
    };
}

pub fn column(children: []const node.Spec, gap: f32) node.Spec {
    return .{
        .kind = .container,
        .style = .{ .layout = .{ .direction = .column, .gap = .{ .height = gap } } },
        .children = children,
    };
}

pub fn spacer(width: layout.Length, height: layout.Length) node.Spec {
    return .{ .kind = .spacer, .style = .{ .layout = .{ .width = width, .height = height } } };
}

pub fn flexibleSpacer() node.Spec {
    return .{ .kind = .spacer, .style = .{ .layout = .{ .flex_grow = 1 } } };
}

pub fn padding(allocator: @import("std").mem.Allocator, child: node.Spec, insets: geometry.Insets) @import("std").mem.Allocator.Error!node.Spec {
    const children = try allocator.dupe(node.Spec, &.{child});
    return .{
        .kind = .container,
        .style = .{ .layout = .{ .padding = .{
            .top = .{ .points = insets.top },
            .right = .{ .points = insets.right },
            .bottom = .{ .points = insets.bottom },
            .left = .{ .points = insets.left },
        } } },
        .children = children,
    };
}
