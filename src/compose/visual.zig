const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const Store = @import("store.zig").Store;
const Record = @import("store.zig").Record;

pub fn localTransform(record: *const Record) geometry.Affine2D {
    const paint = record.borrowedStyle().paint;
    return paint.transform.around(record.layout.bounds.origin);
}

pub fn transformForChildren(record: *const Record, world: geometry.Affine2D) geometry.Affine2D {
    return switch (record.kind) {
        .scroll => |scroll| geometry.Affine2D.mul(world, geometry.Affine2D.translation(.{
            .x = -scroll.offset_x,
            .y = -scroll.offset_y,
        })),
        else => world,
    };
}

/// Returns the visual transform used by the retained painter for `id`.
/// The nearest portal begins a new visual root while the logical parent chain
/// remains intact for dispatch and accessibility ownership.
pub fn transformForNode(
    nodes: *const Store,
    id: handles.NodeId,
    scratch: std.mem.Allocator,
) Error!geometry.Affine2D {
    var chain: std.ArrayList(handles.NodeId) = .empty;
    defer chain.deinit(scratch);

    var current = id;
    while (current.isValid()) {
        const record = nodes.getConst(current) orelse return error.InvalidHandle;
        try chain.append(scratch, current);
        current = record.parent;
    }
    if (chain.items.len == 0) return error.InvalidHandle;

    var visual_root = chain.items.len - 1;
    for (chain.items, 0..) |candidate, index| {
        const record = nodes.getConst(candidate) orelse return error.InvalidHandle;
        if (record.borrowedStyle().layout.portal.target != .none) {
            visual_root = index;
            break;
        }
    }

    var result = geometry.Affine2D.identity;
    var index = visual_root + 1;
    while (index != 0) {
        index -= 1;
        const record = nodes.getConst(chain.items[index]) orelse return error.InvalidHandle;
        result = geometry.Affine2D.mul(result, localTransform(record));
        if (index != 0) result = transformForChildren(record, result);
    }
    return result;
}

pub fn visualBounds(
    nodes: *const Store,
    id: handles.NodeId,
    scratch: std.mem.Allocator,
) Error!geometry.Rect {
    const record = nodes.getConst(id) orelse return error.InvalidHandle;
    return (try transformForNode(nodes, id, scratch)).transformRectBounds(record.layout.bounds);
}
