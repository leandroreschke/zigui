const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const api = @import("api.zig");
const scene = @import("../scene/scene.zig");
const scene_abi = @import("../scene/abi.zig");

pub const Plan = struct {
    allocator: std.mem.Allocator,
    bounds: []?geometry.Rect,

    pub fn build(allocator: std.mem.Allocator, view: api.SceneView) Error!Plan {
        const bounds = try allocator.alloc(?geometry.Rect, view.layers.len);
        errdefer allocator.free(bounds);
        try populate(view, bounds);
        return .{ .allocator = allocator, .bounds = bounds };
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.bounds);
        self.* = undefined;
    }
};

/// Populates caller-owned storage so renderers can retain capacity across
/// frames and avoid allocating after the scene reaches a steady size.
pub fn populate(view: api.SceneView, bounds: []?geometry.Rect) Error!void {
    if (bounds.len != view.layers.len) return error.InvalidConfiguration;
    @memset(bounds, null);
    for (view.operations) |operation| {
        const kind = std.enums.fromInt(scene_abi.OperationKind, operation.kind) orelse return error.InvalidScene;
        const primitive_bounds = try operationBounds(view, operation, kind) orelse continue;
        const clipped = switch (try clipBounds(view, operation.clip)) {
            .unclipped => primitive_bounds,
            .empty => continue,
            .bounds => |clip| geometry.Rect.intersection(primitive_bounds, clip) orelse continue,
        };
        var layer = operation.layer;
        var depth: usize = 0;
        while (layer != scene.none_index) : (depth += 1) {
            if (layer >= view.layers.len or depth >= 64) return error.InvalidScene;
            bounds[layer] = if (bounds[layer]) |existing| unionRect(existing, clipped) else clipped;
            layer = view.layers[layer].parent;
        }
    }
}

fn operationBounds(view: api.SceneView, operation: scene_abi.Operation, kind: scene_abi.OperationKind) Error!?geometry.Rect {
    const transform = try layerTransform(view, operation.layer);
    var result: ?geometry.Rect = null;
    const start: usize = @intCast(operation.start);
    const count: usize = @intCast(operation.count);
    switch (kind) {
        .push_clip, .pop_clip, .push_layer, .pop_layer => return null,
        .quads => {
            for (view.quads[start..][0..count]) |quad| result = include(result, transform.transformRectBounds(quad.bounds));
        },
        .shadows => for (view.shadows[start..][0..count]) |shadow| {
            const extent = @max(0, shadow.spread + shadow.blur_radius * 2);
            const expanded = geometry.Rect.fromXYWH(
                shadow.bounds.origin.x + shadow.offset.x - extent,
                shadow.bounds.origin.y + shadow.offset.y - extent,
                @max(0, shadow.bounds.size.width + extent * 2),
                @max(0, shadow.bounds.size.height + extent * 2),
            );
            result = include(result, transform.transformRectBounds(expanded));
        },
        .paths => {
            for (view.paths[start..][0..count]) |path| result = include(result, transform.transformRectBounds(path.bounds));
        },
        .underlines => {
            for (view.underlines[start..][0..count]) |underline| result = include(result, transform.transformRectBounds(underline.bounds));
        },
        .monochrome_sprites => {
            for (view.monochrome_sprites[start..][0..count]) |sprite| result = include(result, transform.transformRectBounds(sprite.bounds));
        },
        .color_sprites => {
            for (view.color_sprites[start..][0..count]) |sprite| result = include(result, transform.transformRectBounds(sprite.bounds));
        },
        .external_surfaces => {
            for (view.external_surfaces[start..][0..count]) |surface| result = include(result, transform.transformRectBounds(surface.bounds));
        },
        .custom_passes => {
            for (view.custom_passes[start..][0..count]) |pass| result = include(result, transform.transformRectBounds(pass.bounds));
        },
        .backdrop_effect => {
            for (view.backdrop_effects[start..][0..count]) |effect| result = include(result, transform.transformRectBounds(effect.bounds));
        },
    }
    return result;
}

const ClipBounds = union(enum) {
    unclipped,
    empty,
    bounds: geometry.Rect,
};

fn clipBounds(view: api.SceneView, clip_index: u32) Error!ClipBounds {
    var result: ?geometry.Rect = null;
    var current = clip_index;
    var depth: usize = 0;
    while (current != scene.none_index) : (depth += 1) {
        if (current >= view.clips.len or depth >= 64) return error.InvalidScene;
        const clip = view.clips[current];
        const transform = try layerTransform(view, clip.layer);
        const transformed = transform.transformRectBounds(clip.bounds);
        result = if (result) |existing| geometry.Rect.intersection(existing, transformed) orelse return .empty else transformed;
        current = clip.parent;
    }
    return if (result) |bounds| .{ .bounds = bounds } else .unclipped;
}

fn layerTransform(view: api.SceneView, layer_index: u32) Error!geometry.Affine2D {
    if (layer_index == scene.none_index) return .identity;
    var chain: [64]u32 = undefined;
    var count: usize = 0;
    var current = layer_index;
    while (current != scene.none_index) {
        if (current >= view.layers.len or count == chain.len) return error.InvalidScene;
        chain[count] = current;
        count += 1;
        current = view.layers[current].parent;
    }
    var result: geometry.Affine2D = .identity;
    while (count != 0) {
        count -= 1;
        result = geometry.Affine2D.mul(result, view.layers[chain[count]].transform);
    }
    return result;
}

fn include(current: ?geometry.Rect, next: geometry.Rect) ?geometry.Rect {
    if (next.isEmpty()) return current;
    return if (current) |existing| unionRect(existing, next) else next;
}

fn unionRect(left: geometry.Rect, right: geometry.Rect) geometry.Rect {
    const x0 = @min(left.minX(), right.minX());
    const y0 = @min(left.minY(), right.minY());
    const x1 = @max(left.maxX(), right.maxX());
    const y1 = @max(left.maxY(), right.maxY());
    return geometry.Rect.fromXYWH(x0, y0, x1 - x0, y1 - y0);
}
