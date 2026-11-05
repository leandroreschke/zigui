//! CPU scene expansion for the Vulkan backend.
//!
//! Vulkan receives compact, already-batched triangles.  Shape construction,
//! path tessellation, gradient stop subdivision, and arbitrary nested rounded
//! clipping are all implemented here without a geometry dependency.  The GPU
//! remains responsible for rasterization, sampling, blending, compositing, and
//! presentation.

const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const geometry = @import("../../core/geometry.zig");
const render = @import("../../render/api.zig");
const layer_plan = @import("../../render/layer_plan.zig");
const path_tessellator = @import("../../render/path_tessellator.zig");
const scene = @import("../../scene/scene.zig");
const scene_abi = @import("../../scene/abi.zig");
const pipeline = @import("pipeline.zig");

pub const DrawKind = enum { color, monochrome_texture, color_texture, external_texture };

pub const DeviceBounds = struct {
    left: u32,
    top: u32,
    width: u32,
    height: u32,

    pub fn right(self: DeviceBounds) u32 {
        return self.left + self.width;
    }
    pub fn bottom(self: DeviceBounds) u32 {
        return self.top + self.height;
    }

    pub fn logical(self: DeviceBounds, scale: geometry.ScaleFactor) geometry.Rect {
        return geometry.Rect.fromXYWH(
            scale.deviceToLogical(@floatFromInt(self.left)),
            scale.deviceToLogical(@floatFromInt(self.top)),
            scale.deviceToLogical(@floatFromInt(self.width)),
            scale.deviceToLogical(@floatFromInt(self.height)),
        );
    }
};

pub const Draw = struct {
    target: u8,
    kind: DrawKind,
    resource: u64,
    variant: u32 = 0,
    first_vertex: u32,
    vertex_count: u32,
};

pub const LayerStart = struct { target: u8, bounds: DeviceBounds };
pub const LayerEnd = struct {
    target: u8,
    parent: u8,
    layer: u32,
    first_vertex: u32,
    vertex_count: u32,
};
pub const Custom = struct {
    target: u8,
    pass_index: u32,
    transform: geometry.Affine2D,
    clip: geometry.Rect,
};
pub const Command = union(enum) { draw: Draw, custom: Custom, begin_layer: LayerStart, end_layer: LayerEnd };

const ClipPolygon = struct { start: u32 = 0, count: u32 = 0, positive: bool = true };

const WorkVertex = struct {
    position: geometry.Point,
    source: geometry.Point,
    color: geometry.Color,
    uv: geometry.Point = .{},
    scalar: f32 = 0,
};

const GradientMaterial = struct {
    kind: scene_abi.MaterialKind,
    start: geometry.Point,
    end: geometry.Point,
    radii: geometry.Point = .{},
    transform: geometry.Affine2D,
    stops: []const scene_abi.GradientStop,
};

const Material = union(enum) {
    solid: geometry.Color,
    gradient: GradientMaterial,
};

const Target = struct {
    active: bool,
    resource: u8,
    bounds: DeviceBounds,
    layer: u32,
    isolated: bool,
};

pub const Mesh = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(pipeline.Vertex) = .empty,
    commands: std.ArrayList(Command) = .empty,
    layer_bounds: std.ArrayList(?geometry.Rect) = .empty,
    clip_polygons: std.ArrayList(ClipPolygon) = .empty,
    clip_points: std.ArrayList(geometry.Point) = .empty,
    shape_points: std.ArrayList(geometry.Point) = .empty,
    shape_points_b: std.ArrayList(geometry.Point) = .empty,
    scratch_a: std.ArrayList(WorkVertex) = .empty,
    scratch_b: std.ArrayList(WorkVertex) = .empty,
    tessellated_paths: std.ArrayList(path_tessellator.Vertex) = .empty,
    tessellator: path_tessellator.Tessellator,
    descriptor: render.FrameDescriptor = undefined,
    view: render.SceneView = undefined,

    pub fn init(allocator: std.mem.Allocator, path_limits: path_tessellator.Limits) Mesh {
        return .{
            .allocator = allocator,
            .tessellator = path_tessellator.Tessellator.init(allocator, path_limits),
        };
    }

    pub fn deinit(self: *Mesh) void {
        self.vertices.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.layer_bounds.deinit(self.allocator);
        self.clip_polygons.deinit(self.allocator);
        self.clip_points.deinit(self.allocator);
        self.shape_points.deinit(self.allocator);
        self.shape_points_b.deinit(self.allocator);
        self.scratch_a.deinit(self.allocator);
        self.scratch_b.deinit(self.allocator);
        self.tessellated_paths.deinit(self.allocator);
        self.tessellator.deinit();
        self.* = undefined;
    }

    pub fn build(self: *Mesh, descriptor: render.FrameDescriptor, view: render.SceneView) Error!void {
        self.tessellator.beginBatch();
        self.vertices.clearRetainingCapacity();
        self.commands.clearRetainingCapacity();
        self.clip_points.clearRetainingCapacity();
        self.shape_points.clearRetainingCapacity();
        self.shape_points_b.clearRetainingCapacity();
        self.scratch_a.clearRetainingCapacity();
        self.scratch_b.clearRetainingCapacity();
        self.tessellated_paths.clearRetainingCapacity();
        self.descriptor = descriptor;
        self.view = view;
        try self.layer_bounds.resize(self.allocator, view.layers.len);
        try layer_plan.populate(view, self.layer_bounds.items);
        try self.prepareClips();

        var targets: [65]Target = undefined;
        targets[0] = .{
            .active = true,
            .resource = 0,
            .bounds = .{ .left = 0, .top = 0, .width = descriptor.drawable_width, .height = descriptor.drawable_height },
            .layer = scene.none_index,
            .isolated = false,
        };
        var depth: usize = 0;
        for (view.operations) |operation| {
            const kind = std.enums.fromInt(scene_abi.OperationKind, operation.kind) orelse return error.InvalidScene;
            switch (kind) {
                .push_clip, .pop_clip => continue,
                .backdrop_effect => return error.Unsupported,
                .push_layer => {
                    if (depth + 1 >= targets.len or operation.start >= view.layers.len) return error.InvalidScene;
                    depth += 1;
                    const parent = targets[depth - 1];
                    targets[depth] = .{
                        .active = false,
                        .resource = parent.resource,
                        .bounds = parent.bounds,
                        .layer = operation.start,
                        .isolated = false,
                    };
                    if (!parent.active) continue;
                    const layer = view.layers[@intCast(operation.start)];
                    if (layer.opacity <= 0) continue;
                    if (layer.opacity == 1 and layer.blend_mode == @backingInt(scene_abi.BlendMode.normal)) {
                        targets[depth].active = true;
                        continue;
                    }
                    const logical_bounds = self.layer_bounds.items[@intCast(operation.start)] orelse continue;
                    const bounds = cropBounds(logical_bounds, descriptor) orelse continue;
                    targets[depth] = .{
                        .active = true,
                        .resource = @intCast(depth),
                        .bounds = bounds,
                        .layer = operation.start,
                        .isolated = true,
                    };
                    try self.commands.append(self.allocator, .{ .begin_layer = .{ .target = @intCast(depth), .bounds = bounds } });
                    continue;
                },
                .pop_layer => {
                    if (depth == 0 or targets[depth].layer != operation.start) return error.InvalidScene;
                    if (targets[depth].active and targets[depth].isolated) {
                        const first = self.vertices.items.len;
                        try self.appendCompositeQuad(targets[depth - 1], targets[depth], view.layers[@intCast(operation.start)].opacity);
                        try self.commands.append(self.allocator, .{
                            .end_layer = .{
                                .target = targets[depth].resource,
                                .parent = targets[depth - 1].resource,
                                .layer = operation.start,
                                .first_vertex = @intCast(first),
                                .vertex_count = @intCast(self.vertices.items.len - first),
                            },
                        });
                    }
                    depth -= 1;
                    continue;
                },
                else => {},
            }
            if (!targets[depth].active or operation.count == 0) continue;
            try self.appendOperation(targets[depth], operation, kind);
        }
        if (depth != 0 or self.vertices.items.len > std.math.maxInt(u32)) return error.InvalidScene;
    }

    fn prepareClips(self: *Mesh) Error!void {
        try self.clip_polygons.resize(self.allocator, self.view.clips.len);
        for (self.view.clips, 0..) |clip, index| {
            self.shape_points.clearRetainingCapacity();
            try roundedPoints(self.allocator, &self.shape_points, clip.bounds, clip.radii, self.descriptor.scale_factor.value, null);
            const transform = try layerTransform(self.view, clip.layer);
            const start: u32 = @intCast(self.clip_points.items.len);
            for (self.shape_points.items) |point| try self.clip_points.append(self.allocator, transform.transformPoint(point));
            const points = self.clip_points.items[@intCast(start)..];
            self.clip_polygons.items[index] = .{
                .start = start,
                .count = @intCast(points.len),
                .positive = signedArea(points) >= 0,
            };
        }
    }

    fn appendOperation(self: *Mesh, target: Target, operation: scene_abi.Operation, kind: scene_abi.OperationKind) Error!void {
        const transform = try layerTransform(self.view, operation.layer);
        const start: usize = @intCast(operation.start);
        const count: usize = @intCast(operation.count);
        switch (kind) {
            .quads => {
                for (self.view.quads[start..][0..count]) |quad| {
                    const material = try self.resolveMaterial(operation.material, quad.background);
                    try self.appendQuad(target, operation.clip, transform, quad, material);
                }
            },
            .shadows => for (self.view.shadows[start..][0..count]) |shadow|
                try self.appendShadow(target, operation.clip, transform, shadow),
            .paths => for (self.view.paths[start..][0..count]) |path|
                try self.appendPath(target, operation.clip, transform, path, operation.material),
            .underlines => for (self.view.underlines[start..][0..count]) |underline|
                try self.appendUnderline(target, operation.clip, transform, underline),
            .monochrome_sprites => for (self.view.monochrome_sprites[start..][0..count]) |sprite|
                try self.appendSprite(target, operation.clip, transform, sprite, .monochrome_texture),
            .color_sprites => for (self.view.color_sprites[start..][0..count]) |sprite|
                try self.appendSprite(target, operation.clip, transform, sprite, .color_texture),
            .external_surfaces => for (self.view.external_surfaces[start..][0..count]) |surface_value|
                try self.appendExternalSurface(target, operation.clip, transform, surface_value),
            .custom_passes => for (0..count) |index| try self.commands.append(self.allocator, .{ .custom = .{
                .target = target.resource,
                .pass_index = @intCast(start + index),
                .transform = transform,
                .clip = try self.resolvedClipBounds(operation.clip),
            } }),
            .backdrop_effect => return error.Unsupported,
            .push_clip, .pop_clip, .push_layer, .pop_layer => unreachable,
        }
    }

    fn resolvedClipBounds(self: *const Mesh, clip_index: u32) Error!geometry.Rect {
        var bounds = geometry.Rect.fromXYWH(0, 0, self.descriptor.logical_size.width, self.descriptor.logical_size.height);
        var current = clip_index;
        var depth: usize = 0;
        while (current != scene.none_index) : (depth += 1) {
            if (current >= self.view.clips.len or depth >= 64) return error.InvalidScene;
            const clip = self.view.clips[current];
            const transformed = (try layerTransform(self.view, clip.layer)).transformRectBounds(clip.bounds);
            bounds = geometry.Rect.intersection(bounds, transformed) orelse return .{};
            current = clip.parent;
        }
        return bounds;
    }

    fn appendQuad(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        quad: scene_abi.Quad,
        operation_material: Material,
    ) Error!void {
        if (quad.bounds.isEmpty()) return;
        const start = self.vertices.items.len;
        const has_border = quad.border_widths.top > 0 or quad.border_widths.right > 0 or
            quad.border_widths.bottom > 0 or quad.border_widths.left > 0;
        const inner = if (has_border) quad.bounds.inset(quad.border_widths) else quad.bounds;
        const inner_radii = if (has_border) innerRadii(quad.radii, quad.border_widths) else quad.radii;
        if (has_border and quad.border_color.a > 0)
            try self.appendRoundedRing(target, clip, transform, quad.bounds, quad.radii, inner, inner_radii, quad.border_color);
        if (!inner.isEmpty()) {
            try self.appendRoundedFill(target, clip, transform, inner, inner_radii, operation_material);
        }
        try self.recordDraw(target.resource, .color, 0, start);
    }

    fn appendRoundedRing(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        outer: geometry.Rect,
        outer_radii: geometry.CornerRadii,
        inner: geometry.Rect,
        inner_radii: geometry.CornerRadii,
        color: geometry.Color,
    ) Error!void {
        if (outer.isEmpty() or color.a <= 0) return;
        if (inner.isEmpty()) return self.appendRoundedFill(target, clip, transform, outer, outer_radii, .{ .solid = color });

        // Fixed matching subdivisions make the two contours topologically
        // identical even for asymmetric per-edge borders. Emitting the ring
        // directly is essential: drawing a transparent inner fill cannot
        // erase an already blended outer fill.
        const segments = 12;
        try roundedPoints(self.allocator, &self.shape_points, outer, outer_radii, self.descriptor.scale_factor.value, segments);
        try roundedPoints(self.allocator, &self.shape_points_b, inner, inner_radii, self.descriptor.scale_factor.value, segments);
        if (self.shape_points.items.len != self.shape_points_b.items.len or self.shape_points.items.len < 3)
            return error.InvalidScene;
        for (self.shape_points.items, 0..) |outer_point, index| {
            const next = (index + 1) % self.shape_points.items.len;
            const outer_next = self.shape_points.items[next];
            const inner_point = self.shape_points_b.items[index];
            const inner_next = self.shape_points_b.items[next];
            try self.emitSolidTriangle(target, clip, transform, .{
                work(outer_point, color), work(outer_next, color), work(inner_next, color),
            });
            try self.emitSolidTriangle(target, clip, transform, .{
                work(outer_point, color), work(inner_next, color), work(inner_point, color),
            });
        }
    }

    fn appendRoundedFill(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        bounds: geometry.Rect,
        radii: geometry.CornerRadii,
        material: Material,
    ) Error!void {
        if (bounds.isEmpty()) return;
        self.shape_points.clearRetainingCapacity();
        try roundedPoints(self.allocator, &self.shape_points, bounds, radii, self.descriptor.scale_factor.value, null);
        if (self.shape_points.items.len < 3) return;
        const center: geometry.Point = .{ .x = bounds.origin.x + bounds.size.width * 0.5, .y = bounds.origin.y + bounds.size.height * 0.5 };
        var index: usize = 0;
        while (index < self.shape_points.items.len) : (index += 1) {
            const next = (index + 1) % self.shape_points.items.len;
            try self.emitMaterialTriangle(target, clip, transform, .{
                .{ .position = center, .source = center, .color = .transparent },
                .{ .position = self.shape_points.items[index], .source = self.shape_points.items[index], .color = .transparent },
                .{ .position = self.shape_points.items[next], .source = self.shape_points.items[next], .color = .transparent },
            }, material);
        }
    }

    fn appendShadow(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        shadow: scene_abi.Shadow,
    ) Error!void {
        if (shadow.color.a <= 0 or shadow.bounds.isEmpty()) return;
        const start = self.vertices.items.len;
        const base = geometry.Rect.fromXYWH(
            shadow.bounds.origin.x + shadow.offset.x - shadow.spread,
            shadow.bounds.origin.y + shadow.offset.y - shadow.spread,
            @max(0, shadow.bounds.size.width + shadow.spread * 2),
            @max(0, shadow.bounds.size.height + shadow.spread * 2),
        );
        if (base.isEmpty()) return;
        const base_radii = addRadius(shadow.radii, shadow.spread);
        if (shadow.blur_radius <= 0.001) {
            try self.appendRoundedFill(target, clip, transform, base, base_radii, .{ .solid = shadow.color });
            try self.recordDraw(target.resource, .color, 0, start);
            return;
        }
        const rings: usize = 12;
        const extent = @max(1, shadow.blur_radius * 2);
        const sigma = @max(shadow.blur_radius * 0.5, 0.5);
        self.shape_points.clearRetainingCapacity();
        try roundedPoints(self.allocator, &self.shape_points, base, base_radii, self.descriptor.scale_factor.value, 10);
        const center: geometry.Point = .{ .x = base.origin.x + base.size.width * 0.5, .y = base.origin.y + base.size.height * 0.5 };
        var index: usize = 0;
        while (index < self.shape_points.items.len) : (index += 1) {
            const next = (index + 1) % self.shape_points.items.len;
            try self.emitSolidTriangle(target, clip, transform, .{
                work(center, shadow.color), work(self.shape_points.items[index], shadow.color), work(self.shape_points.items[next], shadow.color),
            });
        }
        var previous_distance: f32 = 0;
        var ring: usize = 1;
        while (ring <= rings) : (ring += 1) {
            const distance = extent * @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(rings));
            self.shape_points_b.clearRetainingCapacity();
            const expanded = expandRect(base, distance);
            try roundedPoints(self.allocator, &self.shape_points_b, expanded, addRadius(base_radii, distance), self.descriptor.scale_factor.value, 10);
            const previous_alpha = shadow.color.a * gaussian(previous_distance, sigma);
            const current_alpha = shadow.color.a * gaussian(distance, sigma);
            const previous_color = withAlpha(shadow.color, previous_alpha);
            const current_color = withAlpha(shadow.color, current_alpha);
            for (self.shape_points.items, 0..) |inner_point, point_index| {
                const next = (point_index + 1) % self.shape_points.items.len;
                const outer_point = self.shape_points_b.items[point_index];
                const outer_next = self.shape_points_b.items[next];
                try self.emitSolidTriangle(target, clip, transform, .{
                    work(inner_point, previous_color), work(outer_point, current_color), work(outer_next, current_color),
                });
                try self.emitSolidTriangle(target, clip, transform, .{
                    work(inner_point, previous_color), work(outer_next, current_color), work(self.shape_points.items[next], previous_color),
                });
            }
            std.mem.swap(std.ArrayList(geometry.Point), &self.shape_points, &self.shape_points_b);
            previous_distance = distance;
        }
        try self.recordDraw(target.resource, .color, 0, start);
    }

    fn appendPath(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        path: scene_abi.Path,
        material_index: u32,
    ) Error!void {
        const vertex_start: usize = @intCast(path.vertex_start);
        const vertex_count: usize = @intCast(path.vertex_count);
        if (vertex_start > self.view.path_vertices.len or vertex_count > self.view.path_vertices.len - vertex_start)
            return error.InvalidScene;
        self.tessellated_paths.clearRetainingCapacity();
        const commands = self.view.path_vertices[vertex_start..][0..vertex_count];
        try self.tessellator.tessellate(path, commands, 0.25 / self.descriptor.scale_factor.value, &self.tessellated_paths);
        const material = try self.resolveMaterial(material_index, path.color);
        const start = self.vertices.items.len;
        var index: usize = 0;
        while (index + 2 < self.tessellated_paths.items.len) : (index += 3) {
            try self.emitMaterialTriangle(target, clip, transform, .{
                work(self.tessellated_paths.items[index].position, path.color),
                work(self.tessellated_paths.items[index + 1].position, path.color),
                work(self.tessellated_paths.items[index + 2].position, path.color),
            }, material);
        }
        try self.recordDraw(target.resource, .color, 0, start);
    }

    fn appendUnderline(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        underline: scene_abi.Underline,
    ) Error!void {
        if (underline.bounds.isEmpty() or underline.color.a <= 0 or underline.thickness <= 0) return;
        const start = self.vertices.items.len;
        const device_width = @as(f64, underline.bounds.size.width) * @as(f64, self.descriptor.scale_factor.value);
        const segments: usize = @intFromFloat(@min(@max(@ceil(device_width / 2), 1), 4096));
        var index: usize = 0;
        while (index < segments) : (index += 1) {
            const t0 = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
            const t1 = @as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(segments));
            const x0 = underline.bounds.origin.x + underline.bounds.size.width * t0;
            const x1 = underline.bounds.origin.x + underline.bounds.size.width * t1;
            const y0 = underlineCenter(underline, x0);
            const y1 = underlineCenter(underline, x1);
            const half = underline.thickness * 0.5;
            const a: geometry.Point = .{ .x = x0, .y = y0 - half };
            const b: geometry.Point = .{ .x = x1, .y = y1 - half };
            const c: geometry.Point = .{ .x = x1, .y = y1 + half };
            const d: geometry.Point = .{ .x = x0, .y = y0 + half };
            try self.emitSolidTriangle(target, clip, transform, .{ work(a, underline.color), work(b, underline.color), work(c, underline.color) });
            try self.emitSolidTriangle(target, clip, transform, .{ work(a, underline.color), work(c, underline.color), work(d, underline.color) });
        }
        try self.recordDraw(target.resource, .color, 0, start);
    }

    fn appendSprite(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        sprite: scene_abi.Sprite,
        kind: DrawKind,
    ) Error!void {
        if (sprite.effect != .none) return error.Unsupported;
        if (sprite.bounds.isEmpty() or sprite.color.a <= 0) return;
        const start = self.vertices.items.len;
        const x0 = sprite.bounds.minX();
        const x1 = sprite.bounds.maxX();
        const y0 = sprite.bounds.minY();
        const y1 = sprite.bounds.maxY();
        const uv_min_x = sprite.uv_bounds.minX();
        const uv_max_x = sprite.uv_bounds.maxX();
        const uv_min_y = sprite.uv_bounds.minY();
        const uv_max_y = sprite.uv_bounds.maxY();
        const a = workUv(.{ .x = x0, .y = y0 }, sprite.color, .{ .x = uv_min_x, .y = uv_min_y });
        const b = workUv(.{ .x = x1, .y = y0 }, sprite.color, .{ .x = uv_max_x, .y = uv_min_y });
        const c = workUv(.{ .x = x1, .y = y1 }, sprite.color, .{ .x = uv_max_x, .y = uv_max_y });
        const d = workUv(.{ .x = x0, .y = y1 }, sprite.color, .{ .x = uv_min_x, .y = uv_max_y });
        try self.emitTexturedTriangle(target, clip, transform, .{ a, b, c });
        try self.emitTexturedTriangle(target, clip, transform, .{ a, c, d });
        try self.recordDraw(target.resource, kind, sprite.texture, start);
    }

    fn appendExternalSurface(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        value: scene_abi.ExternalSurface,
    ) Error!void {
        if (value.bounds.isEmpty() or value.opacity <= 0) return;
        const start = self.vertices.items.len;
        const tint: geometry.Color = .{ .r = 1, .g = 1, .b = 1, .a = value.opacity };
        const a = workUv(.{ .x = value.bounds.minX(), .y = value.bounds.minY() }, tint, .{ .x = value.uv_bounds.minX(), .y = value.uv_bounds.minY() });
        const b = workUv(.{ .x = value.bounds.maxX(), .y = value.bounds.minY() }, tint, .{ .x = value.uv_bounds.maxX(), .y = value.uv_bounds.minY() });
        const c = workUv(.{ .x = value.bounds.maxX(), .y = value.bounds.maxY() }, tint, .{ .x = value.uv_bounds.maxX(), .y = value.uv_bounds.maxY() });
        const d = workUv(.{ .x = value.bounds.minX(), .y = value.bounds.maxY() }, tint, .{ .x = value.uv_bounds.minX(), .y = value.uv_bounds.maxY() });
        try self.emitTexturedTriangle(target, clip, transform, .{ a, b, c });
        try self.emitTexturedTriangle(target, clip, transform, .{ a, c, d });
        try self.recordDrawVariant(target.resource, .external_texture, value.surface, value.color_space, start);
    }

    fn appendCompositeQuad(self: *Mesh, parent: Target, child: Target, opacity: f32) Error!void {
        if (!parent.active) return;
        const logical = child.bounds.logical(self.descriptor.scale_factor);
        const tint: geometry.Color = .{ .r = 1, .g = 1, .b = 1, .a = opacity };
        const a = toGpuVertex(parent.bounds, self.descriptor.scale_factor, workUv(
            .{ .x = logical.minX(), .y = logical.minY() },
            tint,
            .{ .x = 0, .y = 0 },
        ));
        const b = toGpuVertex(parent.bounds, self.descriptor.scale_factor, workUv(
            .{ .x = logical.maxX(), .y = logical.minY() },
            tint,
            .{ .x = 1, .y = 0 },
        ));
        const c = toGpuVertex(parent.bounds, self.descriptor.scale_factor, workUv(
            .{ .x = logical.maxX(), .y = logical.maxY() },
            tint,
            .{ .x = 1, .y = 1 },
        ));
        const d = toGpuVertex(parent.bounds, self.descriptor.scale_factor, workUv(
            .{ .x = logical.minX(), .y = logical.maxY() },
            tint,
            .{ .x = 0, .y = 1 },
        ));
        try self.vertices.appendSlice(self.allocator, &.{ a, b, c, a, c, d });
    }

    fn emitMaterialTriangle(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        triangle: [3]WorkVertex,
        material: Material,
    ) Error!void {
        switch (material) {
            .solid => |color| {
                var value = triangle;
                for (&value) |*vertex| vertex.color = color;
                try self.emitSolidTriangle(target, clip, transform, value);
            },
            .gradient => |gradient| try self.emitGradientTriangle(target, clip, transform, triangle, gradient),
        }
    }

    fn emitGradientTriangle(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        triangle: [3]WorkVertex,
        gradient: GradientMaterial,
    ) Error!void {
        if (gradient.kind == .radial_gradient)
            return self.emitAdaptiveRadialTriangle(target, clip, transform, triangle, gradient, 0);
        try self.emitPreparedGradientTriangle(target, clip, transform, triangle, gradient);
    }

    fn emitAdaptiveRadialTriangle(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        triangle: [3]WorkVertex,
        gradient: GradientMaterial,
        depth: u8,
    ) Error!void {
        var initial = triangle;
        for (&initial) |*vertex| {
            vertex.scalar = gradientScalar(gradient, vertex.source);
        }
        if (depth < 6 and radialSubdivisionNeeded(initial, gradient, transform, self.descriptor.scale_factor.value)) {
            const ab = interpolate(initial[0], initial[1], 0.5);
            const bc = interpolate(initial[1], initial[2], 0.5);
            const ca = interpolate(initial[2], initial[0], 0.5);
            try self.emitAdaptiveRadialTriangle(target, clip, transform, .{ initial[0], ab, ca }, gradient, depth + 1);
            try self.emitAdaptiveRadialTriangle(target, clip, transform, .{ ab, initial[1], bc }, gradient, depth + 1);
            try self.emitAdaptiveRadialTriangle(target, clip, transform, .{ ca, bc, initial[2] }, gradient, depth + 1);
            try self.emitAdaptiveRadialTriangle(target, clip, transform, .{ ab, bc, ca }, gradient, depth + 1);
            return;
        }
        try self.emitPreparedGradientTriangle(target, clip, transform, initial, gradient);
    }

    fn emitPreparedGradientTriangle(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        triangle: [3]WorkVertex,
        gradient: GradientMaterial,
    ) Error!void {
        var initial = triangle;
        for (&initial) |*vertex| vertex.scalar = gradientScalar(gradient, vertex.source);
        var lower: f32 = 0;
        for (gradient.stops, 0..) |stop, index| {
            if (index == 0 or stop.offset <= lower or stop.offset >= 1) continue;
            try self.emitGradientBand(target, clip, transform, initial, gradient.stops, lower, stop.offset);
            lower = stop.offset;
        }
        try self.emitGradientBand(target, clip, transform, initial, gradient.stops, lower, 1);
    }

    fn emitGradientBand(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        triangle: [3]WorkVertex,
        stops: []const scene_abi.GradientStop,
        lower: f32,
        upper: f32,
    ) Error!void {
        if (upper <= lower) return;
        self.scratch_a.clearRetainingCapacity();
        try self.scratch_a.appendSlice(self.allocator, &triangle);
        try self.clipScalar(&self.scratch_a, &self.scratch_b, lower, true);
        try self.clipScalar(&self.scratch_a, &self.scratch_b, upper, false);
        if (self.scratch_a.items.len < 3) return;
        for (self.scratch_a.items) |*vertex| vertex.color = gradientColor(stops, vertex.scalar);
        try self.transformAndClipPolygon(target, clip, transform, self.scratch_a.items);
    }

    fn clipScalar(
        self: *Mesh,
        input: *std.ArrayList(WorkVertex),
        output: *std.ArrayList(WorkVertex),
        boundary: f32,
        keep_greater: bool,
    ) Error!void {
        output.clearRetainingCapacity();
        if (input.items.len == 0) return;
        var previous = input.items[input.items.len - 1];
        var previous_inside = if (keep_greater) previous.scalar >= boundary else previous.scalar <= boundary;
        for (input.items) |current| {
            const current_inside = if (keep_greater) current.scalar >= boundary else current.scalar <= boundary;
            if (current_inside != previous_inside) {
                const amount = (boundary - previous.scalar) / (current.scalar - previous.scalar);
                try output.append(self.allocator, interpolate(previous, current, amount));
            }
            if (current_inside) try output.append(self.allocator, current);
            previous = current;
            previous_inside = current_inside;
        }
        std.mem.swap(std.ArrayList(WorkVertex), input, output);
    }

    fn emitSolidTriangle(self: *Mesh, target: Target, clip: u32, transform: geometry.Affine2D, triangle: [3]WorkVertex) Error!void {
        var value = triangle;
        for (&value) |*vertex| vertex.position = transform.transformPoint(vertex.position);
        try self.clipAndAppend(target, clip, &value);
    }

    fn emitTexturedTriangle(self: *Mesh, target: Target, clip: u32, transform: geometry.Affine2D, triangle: [3]WorkVertex) Error!void {
        try self.emitSolidTriangle(target, clip, transform, triangle);
    }

    fn transformAndClipPolygon(
        self: *Mesh,
        target: Target,
        clip: u32,
        transform: geometry.Affine2D,
        polygon: []const WorkVertex,
    ) Error!void {
        self.scratch_b.clearRetainingCapacity();
        for (polygon) |vertex| {
            var transformed = vertex;
            transformed.position = transform.transformPoint(vertex.position);
            try self.scratch_b.append(self.allocator, transformed);
        }
        try self.clipAndAppend(target, clip, self.scratch_b.items);
    }

    fn clipAndAppend(self: *Mesh, target: Target, clip: u32, polygon: []const WorkVertex) Error!void {
        self.scratch_a.clearRetainingCapacity();
        try self.scratch_a.appendSlice(self.allocator, polygon);
        var current = clip;
        var depth: usize = 0;
        while (current != scene.none_index) : (depth += 1) {
            if (current >= self.clip_polygons.items.len or depth >= 64) return error.InvalidScene;
            const clip_polygon = self.clip_polygons.items[@intCast(current)];
            const points = self.clip_points.items[@intCast(clip_polygon.start)..][0..@intCast(clip_polygon.count)];
            try self.clipConvex(&self.scratch_a, &self.scratch_b, points, clip_polygon.positive);
            if (self.scratch_a.items.len < 3) return;
            current = self.view.clips[@intCast(current)].parent;
        }
        try self.appendFan(target, self.scratch_a.items);
    }

    fn clipConvex(
        self: *Mesh,
        input: *std.ArrayList(WorkVertex),
        output: *std.ArrayList(WorkVertex),
        clip: []const geometry.Point,
        positive: bool,
    ) Error!void {
        if (clip.len < 3) {
            input.clearRetainingCapacity();
            return;
        }
        var edge_index: usize = 0;
        while (edge_index < clip.len and input.items.len != 0) : (edge_index += 1) {
            output.clearRetainingCapacity();
            const a = clip[edge_index];
            const b = clip[(edge_index + 1) % clip.len];
            var previous = input.items[input.items.len - 1];
            var previous_distance = edgeDistance(a, b, previous.position);
            var previous_inside = if (positive) previous_distance >= -0.00001 else previous_distance <= 0.00001;
            for (input.items) |current| {
                const current_distance = edgeDistance(a, b, current.position);
                const current_inside = if (positive) current_distance >= -0.00001 else current_distance <= 0.00001;
                if (current_inside != previous_inside) {
                    const denominator = previous_distance - current_distance;
                    const amount = if (@abs(denominator) <= 0.000001) 0 else previous_distance / denominator;
                    try output.append(self.allocator, interpolate(previous, current, amount));
                }
                if (current_inside) try output.append(self.allocator, current);
                previous = current;
                previous_distance = current_distance;
                previous_inside = current_inside;
            }
            std.mem.swap(std.ArrayList(WorkVertex), input, output);
        }
    }

    fn appendFan(self: *Mesh, target: Target, polygon: []const WorkVertex) Error!void {
        if (polygon.len < 3) return;
        var index: usize = 1;
        while (index + 1 < polygon.len) : (index += 1) {
            try self.vertices.append(self.allocator, toGpuVertex(target.bounds, self.descriptor.scale_factor, polygon[0]));
            try self.vertices.append(self.allocator, toGpuVertex(target.bounds, self.descriptor.scale_factor, polygon[index]));
            try self.vertices.append(self.allocator, toGpuVertex(target.bounds, self.descriptor.scale_factor, polygon[index + 1]));
        }
    }

    fn recordDraw(self: *Mesh, target: u8, kind: DrawKind, resource: u64, start: usize) Error!void {
        try self.recordDrawVariant(target, kind, resource, 0, start);
    }

    fn recordDrawVariant(self: *Mesh, target: u8, kind: DrawKind, resource: u64, variant: u32, start: usize) Error!void {
        const count = self.vertices.items.len - start;
        if (count == 0) return;
        if (start > std.math.maxInt(u32) or count > std.math.maxInt(u32)) return error.BudgetExceeded;
        if (self.commands.items.len != 0) switch (self.commands.items[self.commands.items.len - 1]) {
            .draw => |*previous| if (previous.target == target and previous.kind == kind and previous.resource == resource and
                previous.variant == variant and @as(usize, previous.first_vertex) + previous.vertex_count == start)
            {
                previous.vertex_count += @intCast(count);
                return;
            },
            else => {},
        };
        try self.commands.append(self.allocator, .{ .draw = .{
            .target = target,
            .kind = kind,
            .resource = resource,
            .variant = variant,
            .first_vertex = @intCast(start),
            .vertex_count = @intCast(count),
        } });
    }

    fn resolveMaterial(self: *Mesh, index: u32, fallback: geometry.Color) Error!Material {
        if (index == scene.none_index) return .{ .solid = fallback };
        if (index >= self.view.materials.len) return error.InvalidScene;
        const material = self.view.materials[@intCast(index)];
        const kind = std.enums.fromInt(scene_abi.MaterialKind, material.kind) orelse return error.InvalidScene;
        return switch (kind) {
            .none => .{ .solid = fallback },
            .solid => .{ .solid = material.color },
            .linear_gradient, .radial_gradient => blk: {
                if (material.stop_count == 0 or material.stop_start > self.view.gradient_stops.len or
                    material.stop_count > self.view.gradient_stops.len - material.stop_start) return error.InvalidScene;
                break :blk .{ .gradient = .{
                    .kind = kind,
                    .start = material.start,
                    .end = material.end,
                    .radii = .{ .x = material.color.r, .y = material.color.g },
                    .transform = material.gradient_transform,
                    .stops = self.view.gradient_stops[@intCast(material.stop_start)..][0..@intCast(material.stop_count)],
                } };
            },
        };
    }
};

fn work(position: geometry.Point, color: geometry.Color) WorkVertex {
    return .{ .position = position, .source = position, .color = color };
}

fn gradientScalar(gradient: GradientMaterial, point: geometry.Point) f32 {
    return switch (gradient.kind) {
        .linear_gradient => blk: {
            const delta = gradient.end.sub(gradient.start);
            const relative = point.sub(gradient.start);
            const denominator = delta.x * delta.x + delta.y * delta.y;
            break :blk if (denominator <= 0.000001) 0 else std.math.clamp((relative.x * delta.x + relative.y * delta.y) / denominator, 0, 1);
        },
        .radial_gradient => blk: {
            const local = gradient.transform.transformPoint(point);
            break :blk std.math.clamp(radialParameter(local, gradient.start, gradient.radii.x, gradient.end, gradient.radii.y) orelse 0, 0, 1);
        },
        else => 0,
    };
}

fn radialSubdivisionNeeded(
    triangle: [3]WorkVertex,
    gradient: GradientMaterial,
    transform: geometry.Affine2D,
    scale: f32,
) bool {
    var maximum_edge_squared: f32 = 0;
    var maximum_error: f32 = 0;
    inline for (0..3) |index| {
        const next = (index + 1) % 3;
        const a = transform.transformPoint(triangle[index].position);
        const b = transform.transformPoint(triangle[next].position);
        const dx = (b.x - a.x) * scale;
        const dy = (b.y - a.y) * scale;
        maximum_edge_squared = @max(maximum_edge_squared, dx * dx + dy * dy);
        const midpoint_source = lerpPoint(triangle[index].source, triangle[next].source, 0.5);
        const actual = gradientScalar(gradient, midpoint_source);
        const interpolated = (triangle[index].scalar + triangle[next].scalar) * 0.5;
        maximum_error = @max(maximum_error, @abs(actual - interpolated));
    }
    if (maximum_edge_squared <= 0.75 * 0.75) return false;
    const centroid: geometry.Point = .{
        .x = (triangle[0].source.x + triangle[1].source.x + triangle[2].source.x) / 3,
        .y = (triangle[0].source.y + triangle[1].source.y + triangle[2].source.y) / 3,
    };
    maximum_error = @max(maximum_error, @abs(
        gradientScalar(gradient, centroid) -
            (triangle[0].scalar + triangle[1].scalar + triangle[2].scalar) / 3,
    ));
    return maximum_error > 1.0 / 512.0;
}

fn radialParameter(point: geometry.Point, c0: geometry.Point, r0: f32, c1: geometry.Point, r1: f32) ?f32 {
    const centers = c1.sub(c0);
    const relative = point.sub(c0);
    const radius_delta = r1 - r0;
    const a = centers.x * centers.x + centers.y * centers.y - radius_delta * radius_delta;
    const b = -2 * (relative.x * centers.x + relative.y * centers.y + r0 * radius_delta);
    const c = relative.x * relative.x + relative.y * relative.y - r0 * r0;
    if (@abs(a) <= 0.000001) {
        if (@abs(b) <= 0.000001) return null;
        const value = -c / b;
        return if (r0 + radius_delta * value > 0) value else null;
    }
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return null;
    const root = @sqrt(@max(0, discriminant));
    const first = (-b - root) / (2 * a);
    const second = (-b + root) / (2 * a);
    var result: ?f32 = null;
    if (r0 + radius_delta * first > 0) result = first;
    if (r0 + radius_delta * second > 0 and (result == null or second > result.?)) result = second;
    return result;
}

fn workUv(position: geometry.Point, color: geometry.Color, uv: geometry.Point) WorkVertex {
    return .{ .position = position, .source = position, .color = color, .uv = uv };
}

fn toGpuVertex(bounds: DeviceBounds, scale: geometry.ScaleFactor, vertex: WorkVertex) pipeline.Vertex {
    const target = bounds.logical(scale);
    const width = @max(target.size.width, 0.000001);
    const height = @max(target.size.height, 0.000001);
    return .{
        .position = .{
            ((vertex.position.x - target.origin.x) / width) * 2 - 1,
            ((vertex.position.y - target.origin.y) / height) * 2 - 1,
        },
        .color = .{ vertex.color.r, vertex.color.g, vertex.color.b, vertex.color.a },
        .uv = .{ vertex.uv.x, vertex.uv.y },
    };
}

fn interpolate(a: WorkVertex, b: WorkVertex, raw: f32) WorkVertex {
    const amount = std.math.clamp(raw, 0, 1);
    return .{
        .position = lerpPoint(a.position, b.position, amount),
        .source = lerpPoint(a.source, b.source, amount),
        .color = lerpColor(a.color, b.color, amount),
        .uv = lerpPoint(a.uv, b.uv, amount),
        .scalar = a.scalar + (b.scalar - a.scalar) * amount,
    };
}

fn lerpPoint(a: geometry.Point, b: geometry.Point, amount: f32) geometry.Point {
    return .{ .x = a.x + (b.x - a.x) * amount, .y = a.y + (b.y - a.y) * amount };
}

fn lerpColor(a: geometry.Color, b: geometry.Color, amount: f32) geometry.Color {
    return .{
        .r = a.r + (b.r - a.r) * amount,
        .g = a.g + (b.g - a.g) * amount,
        .b = a.b + (b.b - a.b) * amount,
        .a = a.a + (b.a - a.a) * amount,
    };
}

fn gradientColor(stops: []const scene_abi.GradientStop, scalar: f32) geometry.Color {
    if (stops.len == 0) return .transparent;
    const value = std.math.clamp(scalar, 0, 1);
    var previous = stops[0];
    for (stops[1..]) |next| {
        if (value <= next.offset) {
            const span = @max(next.offset - previous.offset, 0.000001);
            return lerpColor(previous.color, next.color, std.math.clamp((value - previous.offset) / span, 0, 1));
        }
        previous = next;
    }
    return previous.color;
}

fn roundedPoints(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(geometry.Point),
    bounds: geometry.Rect,
    input_radii: geometry.CornerRadii,
    scale: f32,
    fixed_segments: ?usize,
) Error!void {
    output.clearRetainingCapacity();
    if (bounds.isEmpty()) return;
    const radii = normalizedRadii(bounds, input_radii);
    const corners = [_]struct { center: geometry.Point, radius: f32, start: f32 }{
        .{ .center = .{ .x = bounds.maxX() - radii.top_right, .y = bounds.minY() + radii.top_right }, .radius = radii.top_right, .start = -std.math.pi / 2.0 },
        .{ .center = .{ .x = bounds.maxX() - radii.bottom_right, .y = bounds.maxY() - radii.bottom_right }, .radius = radii.bottom_right, .start = 0 },
        .{ .center = .{ .x = bounds.minX() + radii.bottom_left, .y = bounds.maxY() - radii.bottom_left }, .radius = radii.bottom_left, .start = std.math.pi / 2.0 },
        .{ .center = .{ .x = bounds.minX() + radii.top_left, .y = bounds.minY() + radii.top_left }, .radius = radii.top_left, .start = std.math.pi },
    };
    for (corners) |corner| {
        const device_radius = @as(f64, corner.radius) * @as(f64, scale) * 0.35;
        const segments = fixed_segments orelse @as(usize, @intFromFloat(@min(@max(@ceil(device_radius), 2), 16)));
        if (corner.radius <= 0 and fixed_segments == null) {
            try output.append(allocator, corner.center);
            continue;
        }
        var segment: usize = 0;
        while (segment <= segments) : (segment += 1) {
            const angle = corner.start + std.math.pi * 0.5 * @as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(segments));
            try output.append(allocator, .{
                .x = corner.center.x + @cos(angle) * corner.radius,
                .y = corner.center.y + @sin(angle) * corner.radius,
            });
        }
    }
    if (fixed_segments == null) deduplicatePoints(output);
}

fn normalizedRadii(bounds: geometry.Rect, input: geometry.CornerRadii) geometry.CornerRadii {
    var result: geometry.CornerRadii = .{
        .top_left = @max(0, input.top_left),
        .top_right = @max(0, input.top_right),
        .bottom_right = @max(0, input.bottom_right),
        .bottom_left = @max(0, input.bottom_left),
    };
    const horizontal = @max(result.top_left + result.top_right, result.bottom_left + result.bottom_right);
    const vertical = @max(result.top_left + result.bottom_left, result.top_right + result.bottom_right);
    const factor = @min(@as(f32, 1), @min(
        if (horizontal > 0) bounds.size.width / horizontal else 1,
        if (vertical > 0) bounds.size.height / vertical else 1,
    ));
    result.top_left *= factor;
    result.top_right *= factor;
    result.bottom_right *= factor;
    result.bottom_left *= factor;
    return result;
}

fn deduplicatePoints(points: *std.ArrayList(geometry.Point)) void {
    if (points.items.len < 2) return;
    var write: usize = 1;
    for (points.items[1..]) |point| {
        const previous = points.items[write - 1];
        if (@abs(point.x - previous.x) <= 0.000001 and @abs(point.y - previous.y) <= 0.000001) continue;
        points.items[write] = point;
        write += 1;
    }
    points.items.len = write;
    if (points.items.len > 1) {
        const first = points.items[0];
        const last = points.items[points.items.len - 1];
        if (@abs(first.x - last.x) <= 0.000001 and @abs(first.y - last.y) <= 0.000001) points.items.len -= 1;
    }
}

fn signedArea(points: []const geometry.Point) f32 {
    var result: f32 = 0;
    for (points, 0..) |point, index| {
        const next = points[(index + 1) % points.len];
        result += point.x * next.y - point.y * next.x;
    }
    return result * 0.5;
}

fn edgeDistance(a: geometry.Point, b: geometry.Point, point: geometry.Point) f32 {
    return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x);
}

fn layerTransform(view: render.SceneView, layer_index: u32) Error!geometry.Affine2D {
    if (layer_index == scene.none_index) return .identity;
    var chain: [64]u32 = undefined;
    var count: usize = 0;
    var current = layer_index;
    while (current != scene.none_index) {
        if (current >= view.layers.len or count == chain.len) return error.InvalidScene;
        chain[count] = current;
        count += 1;
        current = view.layers[@intCast(current)].parent;
    }
    var result: geometry.Affine2D = .identity;
    while (count != 0) {
        count -= 1;
        result = geometry.Affine2D.mul(result, view.layers[@intCast(chain[count])].transform);
    }
    return result;
}

fn cropBounds(bounds: geometry.Rect, descriptor: render.FrameDescriptor) ?DeviceBounds {
    const scale = @as(f64, descriptor.scale_factor.value);
    const raw_left = @as(f64, bounds.minX()) * scale;
    const raw_top = @as(f64, bounds.minY()) * scale;
    const raw_right = @as(f64, bounds.maxX()) * scale;
    const raw_bottom = @as(f64, bounds.maxY()) * scale;
    if (!std.math.isFinite(raw_left) or !std.math.isFinite(raw_top) or
        !std.math.isFinite(raw_right) or !std.math.isFinite(raw_bottom)) return null;
    const left_f = std.math.clamp(@floor(raw_left), 0, @as(f64, @floatFromInt(descriptor.drawable_width)));
    const top_f = std.math.clamp(@floor(raw_top), 0, @as(f64, @floatFromInt(descriptor.drawable_height)));
    const right_f = std.math.clamp(@ceil(raw_right), 0, @as(f64, @floatFromInt(descriptor.drawable_width)));
    const bottom_f = std.math.clamp(@ceil(raw_bottom), 0, @as(f64, @floatFromInt(descriptor.drawable_height)));
    if (right_f <= left_f or bottom_f <= top_f) return null;
    const left: u32 = @intFromFloat(left_f);
    const top: u32 = @intFromFloat(top_f);
    const right: u32 = @intFromFloat(right_f);
    const bottom: u32 = @intFromFloat(bottom_f);
    return .{ .left = left, .top = top, .width = right - left, .height = bottom - top };
}

fn innerRadii(radii: geometry.CornerRadii, insets: geometry.Insets) geometry.CornerRadii {
    return .{
        .top_left = @max(0, radii.top_left - @max(insets.left, insets.top)),
        .top_right = @max(0, radii.top_right - @max(insets.right, insets.top)),
        .bottom_right = @max(0, radii.bottom_right - @max(insets.right, insets.bottom)),
        .bottom_left = @max(0, radii.bottom_left - @max(insets.left, insets.bottom)),
    };
}

fn addRadius(radii: geometry.CornerRadii, value: f32) geometry.CornerRadii {
    return .{
        .top_left = @max(0, radii.top_left + value),
        .top_right = @max(0, radii.top_right + value),
        .bottom_right = @max(0, radii.bottom_right + value),
        .bottom_left = @max(0, radii.bottom_left + value),
    };
}

fn expandRect(rect: geometry.Rect, amount: f32) geometry.Rect {
    return geometry.Rect.fromXYWH(rect.origin.x - amount, rect.origin.y - amount, rect.size.width + amount * 2, rect.size.height + amount * 2);
}

fn gaussian(distance: f32, sigma: f32) f32 {
    return @exp(-0.5 * distance * distance / (sigma * sigma));
}

fn withAlpha(color: geometry.Color, alpha: f32) geometry.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = std.math.clamp(alpha, 0, 1) };
}

fn underlineCenter(underline: scene_abi.Underline, x: f32) f32 {
    var center = underline.bounds.origin.y + underline.bounds.size.height * 0.5;
    if (underline.wave_period > 0 and underline.wave_amplitude != 0)
        center += @sin((x - underline.bounds.origin.x) * (2 * std.math.pi) / underline.wave_period) * underline.wave_amplitude;
    return center;
}
