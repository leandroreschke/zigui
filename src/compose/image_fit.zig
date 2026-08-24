const std = @import("std");
const geometry = @import("../core/geometry.zig");
const node = @import("node.zig");

pub const Placement = struct {
    bounds: geometry.Rect,
    uv_bounds: geometry.Rect,
};

pub fn place(bounds: geometry.Rect, width: u32, height: u32, fit: node.Image.Fit) Placement {
    const full_uv = geometry.Rect.fromXYWH(0, 0, 1, 1);
    if (width == 0 or height == 0 or bounds.size.width <= 0 or bounds.size.height <= 0 or fit == .fill)
        return .{ .bounds = bounds, .uv_bounds = full_uv };

    const source_width: f32 = @floatFromInt(width);
    const source_height: f32 = @floatFromInt(height);
    const contain = @min(bounds.size.width / source_width, bounds.size.height / source_height);
    const cover = @max(bounds.size.width / source_width, bounds.size.height / source_height);
    if (fit == .cover) {
        const rendered_width = source_width * cover;
        const rendered_height = source_height * cover;
        const visible_width = std.math.clamp(bounds.size.width / rendered_width, 0, 1);
        const visible_height = std.math.clamp(bounds.size.height / rendered_height, 0, 1);
        return .{
            .bounds = bounds,
            .uv_bounds = geometry.Rect.fromXYWH(
                (1 - visible_width) / 2,
                (1 - visible_height) / 2,
                visible_width,
                visible_height,
            ),
        };
    }

    const scale: f32 = switch (fit) {
        .fill, .cover => unreachable,
        .contain => contain,
        .none => 1,
        .scale_down => @min(1, contain),
    };
    const size: geometry.Size = .{ .width = source_width * scale, .height = source_height * scale };
    return .{
        .bounds = .{
            .origin = .{
                .x = bounds.origin.x + (bounds.size.width - size.width) / 2,
                .y = bounds.origin.y + (bounds.size.height - size.height) / 2,
            },
            .size = size,
        },
        .uv_bounds = full_uv,
    };
}

test "cover placement crops UVs instead of overflowing destination bounds" {
    const placement = place(geometry.Rect.fromXYWH(10, 20, 300, 180), 100, 100, .cover);
    try std.testing.expectEqual(geometry.Rect.fromXYWH(10, 20, 300, 180), placement.bounds);
    try std.testing.expectApproxEqAbs(@as(f32, 0), placement.uv_bounds.origin.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), placement.uv_bounds.origin.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), placement.uv_bounds.size.width, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), placement.uv_bounds.size.height, 0.0001);
}

test "contain placement preserves the full source and centers its destination" {
    const placement = place(geometry.Rect.fromXYWH(0, 0, 300, 180), 100, 100, .contain);
    try std.testing.expectEqual(geometry.Rect.fromXYWH(60, 0, 180, 180), placement.bounds);
    try std.testing.expectEqual(geometry.Rect.fromXYWH(0, 0, 1, 1), placement.uv_bounds);
}
