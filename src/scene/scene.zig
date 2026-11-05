const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const native_media = @import("../core/native_media.zig");
const custom = @import("../compose/custom.zig");
const abi = @import("abi.zig");
const render = @import("../render/api.zig");

pub const none_index = std.math.maxInt(u32);

pub const Limits = struct {
    operations: usize = 1_000_000,
    materials: usize = 131_072,
    gradient_stops: usize = 1_048_576,
    clips: usize = 131_072,
    layers: usize = 131_072,
    backdrop_effects: usize = 131_072,
    primitives: usize = 4_000_000,
    path_vertices: usize = 8_000_000,
    custom_passes: usize = 65_536,
    custom_payload_bytes: usize = 64 * 1024 * 1024,
    native_media_placements: usize = 4_096,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    operations: std.ArrayList(abi.Operation) = .empty,
    materials: std.ArrayList(abi.Material) = .empty,
    gradient_stops: std.ArrayList(abi.GradientStop) = .empty,
    clips: std.ArrayList(abi.Clip) = .empty,
    layers: std.ArrayList(abi.Layer) = .empty,
    shadows: std.ArrayList(abi.Shadow) = .empty,
    quads: std.ArrayList(abi.Quad) = .empty,
    paths: std.ArrayList(abi.Path) = .empty,
    path_vertices: std.ArrayList(abi.PathVertex) = .empty,
    underlines: std.ArrayList(abi.Underline) = .empty,
    monochrome_sprites: std.ArrayList(abi.Sprite) = .empty,
    color_sprites: std.ArrayList(abi.Sprite) = .empty,
    external_surfaces: std.ArrayList(abi.ExternalSurface) = .empty,
    custom_passes: std.ArrayList(abi.CustomPass) = .empty,
    custom_payload: std.ArrayList(u8) = .empty,
    backdrop_effects: std.ArrayList(abi.BackdropEffect) = .empty,
    native_media_placements: std.ArrayList(native_media.Placement) = .empty,
    generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Scene {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scene) void {
        self.operations.deinit(self.allocator);
        self.materials.deinit(self.allocator);
        self.gradient_stops.deinit(self.allocator);
        self.clips.deinit(self.allocator);
        self.layers.deinit(self.allocator);
        self.shadows.deinit(self.allocator);
        self.quads.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.path_vertices.deinit(self.allocator);
        self.underlines.deinit(self.allocator);
        self.monochrome_sprites.deinit(self.allocator);
        self.color_sprites.deinit(self.allocator);
        self.external_surfaces.deinit(self.allocator);
        self.custom_passes.deinit(self.allocator);
        self.custom_payload.deinit(self.allocator);
        self.backdrop_effects.deinit(self.allocator);
        self.native_media_placements.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clearRetainingCapacity(self: *Scene) void {
        self.operations.clearRetainingCapacity();
        self.materials.clearRetainingCapacity();
        self.gradient_stops.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
        self.layers.clearRetainingCapacity();
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.path_vertices.clearRetainingCapacity();
        self.underlines.clearRetainingCapacity();
        self.monochrome_sprites.clearRetainingCapacity();
        self.color_sprites.clearRetainingCapacity();
        self.external_surfaces.clearRetainingCapacity();
        self.custom_passes.clearRetainingCapacity();
        self.custom_payload.clearRetainingCapacity();
        self.backdrop_effects.clearRetainingCapacity();
        self.native_media_placements.clearRetainingCapacity();
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }

    pub fn view(self: *const Scene) render.SceneView {
        return .{
            .operations = self.operations.items,
            .materials = self.materials.items,
            .gradient_stops = self.gradient_stops.items,
            .clips = self.clips.items,
            .layers = self.layers.items,
            .shadows = self.shadows.items,
            .quads = self.quads.items,
            .paths = self.paths.items,
            .path_vertices = self.path_vertices.items,
            .underlines = self.underlines.items,
            .monochrome_sprites = self.monochrome_sprites.items,
            .color_sprites = self.color_sprites.items,
            .external_surfaces = self.external_surfaces.items,
            .custom_passes = self.custom_passes.items,
            .custom_payload = self.custom_payload.items,
            .backdrop_effects = self.backdrop_effects.items,
        };
    }
};

pub const Builder = struct {
    scene: *Scene,
    limits: Limits,
    clip_stack: std.ArrayList(u32) = .empty,
    layer_stack: std.ArrayList(u32) = .empty,
    target: u32 = 0,
    custom_clip_floor: usize = 0,
    custom_layer_floor: usize = 0,
    in_custom_scope: bool = false,
    primitive_count: usize = 0,

    pub const CustomCheckpoint = struct { clip_depth: usize, layer_depth: usize };

    pub fn init(scene: *Scene, limits: Limits) Builder {
        scene.clearRetainingCapacity();
        return .{ .scene = scene, .limits = limits };
    }

    pub fn deinit(self: *Builder) void {
        self.clip_stack.deinit(self.scene.allocator);
        self.layer_stack.deinit(self.scene.allocator);
        self.* = undefined;
    }

    pub fn finish(self: *Builder) Error!void {
        if (self.clip_stack.items.len != 0 or self.layer_stack.items.len != 0) return error.InvalidScene;
        try validate(self.scene.view());
    }

    pub fn beginCustom(self: *Builder) Error!CustomCheckpoint {
        if (self.in_custom_scope) return error.CallbackReentrancy;
        self.in_custom_scope = true;
        self.custom_clip_floor = self.clip_stack.items.len;
        self.custom_layer_floor = self.layer_stack.items.len;
        return .{ .clip_depth = self.custom_clip_floor, .layer_depth = self.custom_layer_floor };
    }

    pub fn endCustom(self: *Builder, checkpoint: CustomCheckpoint) Error!void {
        defer {
            self.in_custom_scope = false;
            self.custom_clip_floor = 0;
            self.custom_layer_floor = 0;
        }
        if (self.clip_stack.items.len != checkpoint.clip_depth or self.layer_stack.items.len != checkpoint.layer_depth)
            return error.InvalidScene;
    }

    pub fn pushClip(self: *Builder, bounds: geometry.Rect, radii: geometry.CornerRadii) Error!u32 {
        if (self.clip_stack.items.len >= 63) return error.InvalidScene;
        try self.ensure(self.scene.clips.items.len, 1, self.limits.clips);
        const index: u32 = @intCast(self.scene.clips.items.len);
        const layer = self.currentLayer();
        const plan = try self.prepareOperation(.push_clip, index, 1, none_index, none_index, index, layer);
        try self.scene.clips.ensureUnusedCapacity(self.scene.allocator, 1);
        try self.clip_stack.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.clips.appendAssumeCapacity(.{
            .bounds = bounds,
            .radii = radii,
            .parent = self.currentClip(),
            .layer = layer,
        });
        self.clip_stack.appendAssumeCapacity(index);
        self.commitOperation(plan, .push_clip, index, 1, none_index, none_index);
        return index;
    }

    pub fn popClip(self: *Builder) Error!void {
        if (self.clip_stack.items.len == 0) return error.InvalidScene;
        const next_clip = if (self.clip_stack.items.len == 1) none_index else self.clip_stack.items[self.clip_stack.items.len - 2];
        const index = self.clip_stack.items[self.clip_stack.items.len - 1];
        const plan = try self.prepareOperation(.pop_clip, index, 1, none_index, none_index, next_clip, self.currentLayer());
        _ = self.clip_stack.pop();
        self.commitOperation(plan, .pop_clip, index, 1, none_index, none_index);
    }

    pub fn pushLayer(self: *Builder, opacity: f32, blend_mode: abi.BlendMode, transform: geometry.Affine2D) Error!u32 {
        if (self.layer_stack.items.len >= 63) return error.InvalidScene;
        try self.ensure(self.scene.layers.items.len, 1, self.limits.layers);
        const index: u32 = @intCast(self.scene.layers.items.len);
        const clip = self.currentClip();
        const plan = try self.prepareOperation(.push_layer, index, 1, none_index, none_index, clip, index);
        try self.scene.layers.ensureUnusedCapacity(self.scene.allocator, 1);
        try self.layer_stack.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.layers.appendAssumeCapacity(.{
            .opacity = std.math.clamp(opacity, 0, 1),
            .blend_mode = @backingInt(blend_mode),
            .parent = self.currentLayer(),
            .transform = transform,
        });
        self.layer_stack.appendAssumeCapacity(index);
        self.commitOperation(plan, .push_layer, index, 1, none_index, none_index);
        return index;
    }

    pub fn popLayer(self: *Builder) Error!void {
        if (self.layer_stack.items.len == 0) return error.InvalidScene;
        const next_layer = if (self.layer_stack.items.len == 1) none_index else self.layer_stack.items[self.layer_stack.items.len - 2];
        const index = self.layer_stack.items[self.layer_stack.items.len - 1];
        const plan = try self.prepareOperation(.pop_layer, index, 1, none_index, none_index, self.currentClip(), next_layer);
        _ = self.layer_stack.pop();
        self.commitOperation(plan, .pop_layer, index, 1, none_index, none_index);
    }

    pub fn solidMaterial(self: *Builder, color: geometry.Color) Error!u32 {
        try self.ensure(self.scene.materials.items.len, 1, self.limits.materials);
        const index: u32 = @intCast(self.scene.materials.items.len);
        try self.scene.materials.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.materials.appendAssumeCapacity(.{
            .kind = @backingInt(abi.MaterialKind.solid),
            .stop_start = 0,
            .stop_count = 0,
            .color = color,
            .start = .{},
            .end = .{},
            .gradient_transform = .identity,
        });
        return index;
    }

    pub fn linearGradientMaterial(
        self: *Builder,
        start: geometry.Point,
        end: geometry.Point,
        stops: []const abi.GradientStop,
    ) Error!u32 {
        if (stops.len == 0) return error.InvalidScene;
        try self.ensure(self.scene.materials.items.len, 1, self.limits.materials);
        try self.ensure(self.scene.gradient_stops.items.len, stops.len, self.limits.gradient_stops);
        try self.scene.gradient_stops.ensureUnusedCapacity(self.scene.allocator, stops.len);
        try self.scene.materials.ensureUnusedCapacity(self.scene.allocator, 1);
        const stop_start: u32 = @intCast(self.scene.gradient_stops.items.len);
        self.scene.gradient_stops.appendSliceAssumeCapacity(stops);
        const index: u32 = @intCast(self.scene.materials.items.len);
        self.scene.materials.appendAssumeCapacity(.{
            .kind = @backingInt(abi.MaterialKind.linear_gradient),
            .stop_start = stop_start,
            .stop_count = @intCast(stops.len),
            .color = .transparent,
            .start = start,
            .end = end,
            .gradient_transform = .identity,
        });
        return index;
    }

    pub fn radialGradientMaterial(
        self: *Builder,
        center: geometry.Point,
        radius: f32,
        world_to_gradient: geometry.Affine2D,
        stops: []const abi.GradientStop,
    ) Error!u32 {
        return self.conicalGradientMaterial(center, 0, center, radius, world_to_gradient, stops);
    }

    /// A two-circle radial (conical) gradient. This is the native primitive
    /// used by SVG focal gradients and COLR-style radial paints.
    pub fn conicalGradientMaterial(
        self: *Builder,
        start_center: geometry.Point,
        start_radius: f32,
        end_center: geometry.Point,
        end_radius: f32,
        world_to_gradient: geometry.Affine2D,
        stops: []const abi.GradientStop,
    ) Error!u32 {
        if (stops.len == 0 or start_radius < 0 or end_radius < 0 or
            !std.math.isFinite(start_radius) or !std.math.isFinite(end_radius) or
            (start_center.x == end_center.x and start_center.y == end_center.y and start_radius == end_radius)) return error.InvalidScene;
        try self.ensure(self.scene.materials.items.len, 1, self.limits.materials);
        try self.ensure(self.scene.gradient_stops.items.len, stops.len, self.limits.gradient_stops);
        try self.scene.gradient_stops.ensureUnusedCapacity(self.scene.allocator, stops.len);
        try self.scene.materials.ensureUnusedCapacity(self.scene.allocator, 1);
        const stop_start: u32 = @intCast(self.scene.gradient_stops.items.len);
        self.scene.gradient_stops.appendSliceAssumeCapacity(stops);
        const index: u32 = @intCast(self.scene.materials.items.len);
        self.scene.materials.appendAssumeCapacity(.{
            .kind = @backingInt(abi.MaterialKind.radial_gradient),
            .stop_start = stop_start,
            .stop_count = @intCast(stops.len),
            .color = .{ .r = start_radius, .g = end_radius, .b = 0, .a = 0 },
            .start = start_center,
            .end = end_center,
            .gradient_transform = world_to_gradient,
        });
        return index;
    }

    pub fn shadow(self: *Builder, value: abi.Shadow) Error!void {
        try self.ensurePrimitive(self.scene.shadows.items.len);
        const start: u32 = @intCast(self.scene.shadows.items.len);
        const plan = try self.prepareCurrentOperation(.shadows, start, 1, none_index, none_index);
        try self.scene.shadows.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.shadows.appendAssumeCapacity(value);
        self.commitOperation(plan, .shadows, start, 1, none_index, none_index);
    }

    pub fn backdropEffect(self: *Builder, value: abi.BackdropEffect) Error!void {
        try self.ensurePrimitive(self.scene.backdrop_effects.items.len);
        try self.ensure(self.scene.backdrop_effects.items.len, 1, self.limits.backdrop_effects);
        const start: u32 = @intCast(self.scene.backdrop_effects.items.len);
        const plan = try self.prepareCurrentOperation(.backdrop_effect, start, 1, none_index, none_index);
        try self.scene.backdrop_effects.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.backdrop_effects.appendAssumeCapacity(value);
        self.commitOperation(plan, .backdrop_effect, start, 1, none_index, none_index);
    }

    pub fn quad(self: *Builder, value: abi.Quad, material: ?u32) Error!void {
        try self.ensurePrimitive(self.scene.quads.items.len);
        const start: u32 = @intCast(self.scene.quads.items.len);
        const material_index = material orelse none_index;
        const plan = try self.prepareCurrentOperation(.quads, start, 1, material_index, none_index);
        try self.scene.quads.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.quads.appendAssumeCapacity(value);
        self.commitOperation(plan, .quads, start, 1, material_index, none_index);
    }

    pub fn path(self: *Builder, source: abi.Path, vertices: []const abi.PathVertex, material: ?u32) Error!void {
        try self.ensurePrimitive(self.scene.paths.items.len);
        try self.ensure(self.scene.path_vertices.items.len, vertices.len, self.limits.path_vertices);
        const start: u32 = @intCast(self.scene.paths.items.len);
        const material_index = material orelse none_index;
        const plan = try self.prepareCurrentOperation(.paths, start, 1, material_index, none_index);
        try self.scene.path_vertices.ensureUnusedCapacity(self.scene.allocator, vertices.len);
        try self.scene.paths.ensureUnusedCapacity(self.scene.allocator, 1);
        var value = source;
        value.vertex_start = @intCast(self.scene.path_vertices.items.len);
        value.vertex_count = @intCast(vertices.len);
        self.scene.path_vertices.appendSliceAssumeCapacity(vertices);
        self.scene.paths.appendAssumeCapacity(value);
        self.commitOperation(plan, .paths, start, 1, material_index, none_index);
    }

    pub fn underline(self: *Builder, value: abi.Underline) Error!void {
        try self.ensurePrimitive(self.scene.underlines.items.len);
        const start: u32 = @intCast(self.scene.underlines.items.len);
        const plan = try self.prepareCurrentOperation(.underlines, start, 1, none_index, none_index);
        try self.scene.underlines.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.underlines.appendAssumeCapacity(value);
        self.commitOperation(plan, .underlines, start, 1, none_index, none_index);
    }

    pub fn monochromeSprite(self: *Builder, value: abi.Sprite) Error!void {
        try self.ensurePrimitive(self.scene.monochrome_sprites.items.len);
        const start: u32 = @intCast(self.scene.monochrome_sprites.items.len);
        const resource_index: u32 = @truncate(value.texture);
        const plan = try self.prepareCurrentOperation(.monochrome_sprites, start, 1, none_index, resource_index);
        try self.scene.monochrome_sprites.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.monochrome_sprites.appendAssumeCapacity(value);
        self.commitOperation(plan, .monochrome_sprites, start, 1, none_index, resource_index);
    }

    pub fn colorSprite(self: *Builder, value: abi.Sprite) Error!void {
        try self.ensurePrimitive(self.scene.color_sprites.items.len);
        const start: u32 = @intCast(self.scene.color_sprites.items.len);
        const resource_index: u32 = @truncate(value.texture);
        const plan = try self.prepareCurrentOperation(.color_sprites, start, 1, none_index, resource_index);
        try self.scene.color_sprites.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.color_sprites.appendAssumeCapacity(value);
        self.commitOperation(plan, .color_sprites, start, 1, none_index, resource_index);
    }

    pub fn externalSurface(self: *Builder, value: abi.ExternalSurface) Error!void {
        try self.ensurePrimitive(self.scene.external_surfaces.items.len);
        const start: u32 = @intCast(self.scene.external_surfaces.items.len);
        const resource_index: u32 = @truncate(value.surface);
        const plan = try self.prepareCurrentOperation(.external_surfaces, start, 1, none_index, resource_index);
        try self.scene.external_surfaces.ensureUnusedCapacity(self.scene.allocator, 1);
        self.scene.external_surfaces.appendAssumeCapacity(value);
        self.commitOperation(plan, .external_surfaces, start, 1, none_index, resource_index);
    }

    pub fn customPass(
        self: *Builder,
        extension: @import("../core/handle.zig").RenderExtensionId,
        bounds: geometry.Rect,
        payload: []const u8,
        flags: u32,
    ) Error!void {
        if (!extension.isValid()) return error.InvalidHandle;
        try self.ensurePrimitive(self.scene.custom_passes.items.len);
        try self.ensure(self.scene.custom_passes.items.len, 1, self.limits.custom_passes);
        try self.ensure(self.scene.custom_payload.items.len, payload.len, self.limits.custom_payload_bytes);
        const start: u32 = @intCast(self.scene.custom_passes.items.len);
        const plan = try self.prepareCurrentOperation(.custom_passes, start, 1, none_index, extension.index);
        try self.scene.custom_payload.ensureUnusedCapacity(self.scene.allocator, payload.len);
        try self.scene.custom_passes.ensureUnusedCapacity(self.scene.allocator, 1);
        const payload_start: u32 = @intCast(self.scene.custom_payload.items.len);
        self.scene.custom_payload.appendSliceAssumeCapacity(payload);
        self.scene.custom_passes.appendAssumeCapacity(.{
            .bounds = bounds,
            .extension = extension.encode(),
            .payload_start = payload_start,
            .payload_length = @intCast(payload.len),
            .flags = flags,
        });
        self.commitOperation(plan, .custom_passes, start, 1, none_index, extension.index);
    }

    pub fn nativeMedia(self: *Builder, id: handles.NativeMediaId, bounds: geometry.Rect) Error!void {
        try self.nativeMediaWithVisibility(id, bounds, true);
    }

    pub fn nativeMediaWithVisibility(self: *Builder, id: handles.NativeMediaId, bounds: geometry.Rect, visible: bool) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        if (!validRect(bounds) or bounds.size.width <= 0 or bounds.size.height <= 0) return error.InvalidScene;
        for (self.scene.native_media_placements.items) |placement| if (placement.id.eql(id)) return error.InvalidScene;
        if (self.scene.native_media_placements.items.len >= self.limits.native_media_placements) return error.BudgetExceeded;
        try self.scene.native_media_placements.append(self.scene.allocator, .{ .id = id, .bounds = bounds, .visible = visible });
    }

    pub fn emitCustom(context: *anyopaque, command: custom.PaintCommand) Error!void {
        const self: *Builder = @ptrCast(@alignCast(context));
        switch (command) {
            .push_clip => |value| _ = try self.pushClip(value.bounds, value.radii),
            .pop_clip => {
                if (self.in_custom_scope and self.clip_stack.items.len <= self.custom_clip_floor) return error.InvalidScene;
                try self.popClip();
            },
            .push_layer => |value| _ = try self.pushLayer(value.opacity, value.blend_mode, value.transform),
            .pop_layer => {
                if (self.in_custom_scope and self.layer_stack.items.len <= self.custom_layer_floor) return error.InvalidScene;
                try self.popLayer();
            },
            .quad => |value| try self.quad(value, null),
            .gradient_quad => |value| {
                const materials_start = self.scene.materials.items.len;
                const stops_start = self.scene.gradient_stops.items.len;
                errdefer {
                    self.scene.materials.items.len = materials_start;
                    self.scene.gradient_stops.items.len = stops_start;
                }
                const material = try self.linearGradientMaterial(value.start, value.end, value.stops);
                try self.quad(value.value, material);
            },
            .path => |value| try self.path(value.value, value.vertices, null),
            .shadow => |value| try self.shadow(value),
            .backdrop_effect => |value| try self.backdropEffect(value),
            .underline => |value| try self.underline(value),
            .monochrome_sprite => |value| try self.monochromeSprite(value),
            .color_sprite => |value| try self.colorSprite(value),
            .external_surface => |value| try self.externalSurface(value),
            .native_media => |value| try self.nativeMediaWithVisibility(value.id, value.bounds, value.visible),
            .custom_pass => |value| try self.customPass(value.extension, value.bounds, value.payload, value.flags),
        }
    }

    /// Replays a complete, balanced scene that was built independently of
    /// this builder. Every index owned by the source scene is rebased into
    /// the destination scene; source-root clip and layer references inherit
    /// the stacks active at the call site.
    ///
    /// The source is validated before any destination storage is changed and
    /// all capacity and budget checks are completed before appending. This is
    /// important for retained caches: a rejected cache must not leave a
    /// partially appended frame behind.
    pub fn appendRetained(self: *Builder, source: *const Scene) Error!void {
        if (@intFromPtr(source) == @intFromPtr(self.scene)) return error.InvalidScene;
        try validate(source.view());
        for (source.custom_passes.items) |pass| {
            const extension = handles.RenderExtensionId{
                .index = @truncate(pass.extension),
                .generation = @truncate(pass.extension >> 32),
            };
            if (!extension.isValid()) return error.InvalidScene;
        }

        const inherited_clip = self.currentClip();
        const inherited_layer = self.currentLayer();
        const bases = RetainedBases{
            .materials = self.scene.materials.items.len,
            .gradient_stops = self.scene.gradient_stops.items.len,
            .clips = self.scene.clips.items.len,
            .layers = self.scene.layers.items.len,
            .shadows = self.scene.shadows.items.len,
            .quads = self.scene.quads.items.len,
            .paths = self.scene.paths.items.len,
            .path_vertices = self.scene.path_vertices.items.len,
            .underlines = self.scene.underlines.items.len,
            .monochrome_sprites = self.scene.monochrome_sprites.items.len,
            .color_sprites = self.scene.color_sprites.items.len,
            .external_surfaces = self.scene.external_surfaces.items.len,
            .custom_passes = self.scene.custom_passes.items.len,
            .custom_payload = self.scene.custom_payload.items.len,
            .backdrop_effects = self.scene.backdrop_effects.items.len,
        };

        // A Scene's public view does not include native media placements. They
        // still participate in cache ownership and must retain Builder's
        // duplicate-ID and positive-bounds invariants when copied.
        try validateNativeMedia(source.native_media_placements.items);
        try validateNativeMedia(self.scene.native_media_placements.items);
        for (source.native_media_placements.items) |placement| {
            for (self.scene.native_media_placements.items) |existing| {
                if (placement.id.eql(existing.id)) return error.InvalidScene;
            }
        }
        try self.ensure(source.native_media_placements.items.len, 0, self.limits.native_media_placements);
        try self.ensure(self.scene.native_media_placements.items.len, source.native_media_placements.items.len, self.limits.native_media_placements);

        try self.ensure(self.scene.materials.items.len, source.materials.items.len, self.limits.materials);
        try self.ensure(self.scene.gradient_stops.items.len, source.gradient_stops.items.len, self.limits.gradient_stops);
        try self.ensure(self.scene.clips.items.len, source.clips.items.len, self.limits.clips);
        try self.ensure(self.scene.layers.items.len, source.layers.items.len, self.limits.layers);
        try self.ensure(self.scene.shadows.items.len, source.shadows.items.len, self.limits.primitives);
        try self.ensure(self.scene.quads.items.len, source.quads.items.len, self.limits.primitives);
        try self.ensure(self.scene.paths.items.len, source.paths.items.len, self.limits.primitives);
        try self.ensure(self.scene.path_vertices.items.len, source.path_vertices.items.len, self.limits.path_vertices);
        try self.ensure(self.scene.underlines.items.len, source.underlines.items.len, self.limits.primitives);
        try self.ensure(self.scene.monochrome_sprites.items.len, source.monochrome_sprites.items.len, self.limits.primitives);
        try self.ensure(self.scene.color_sprites.items.len, source.color_sprites.items.len, self.limits.primitives);
        try self.ensure(self.scene.external_surfaces.items.len, source.external_surfaces.items.len, self.limits.primitives);
        try self.ensure(self.scene.custom_passes.items.len, source.custom_passes.items.len, self.limits.custom_passes);
        try self.ensure(self.scene.custom_payload.items.len, source.custom_payload.items.len, self.limits.custom_payload_bytes);
        try self.ensure(self.scene.backdrop_effects.items.len, source.backdrop_effects.items.len, self.limits.backdrop_effects);

        var additional_primitives: usize = 0;
        var additional_operations: usize = 0;
        var simulated_previous: ?abi.Operation = if (self.scene.operations.items.len == 0)
            null
        else
            self.scene.operations.items[self.scene.operations.items.len - 1];
        for (source.operations.items) |source_operation| {
            if (source_operation.target != self.target) return error.InvalidScene;
            const operation = try self.remapRetainedOperation(source_operation, bases, inherited_clip, inherited_layer);
            if (isPrimitive(std.enums.fromInt(abi.OperationKind, source_operation.kind) orelse return error.InvalidScene)) {
                additional_primitives = std.math.add(usize, additional_primitives, source_operation.count) catch return error.BudgetExceeded;
            }
            if (simulated_previous) |previous| {
                if (canMerge(previous, operation)) {
                    var merged = previous;
                    merged.count = std.math.add(u32, merged.count, operation.count) catch return error.BudgetExceeded;
                    simulated_previous = merged;
                    continue;
                }
            }
            additional_operations = std.math.add(usize, additional_operations, 1) catch return error.BudgetExceeded;
            simulated_previous = operation;
        }
        try self.ensure(self.primitive_count, additional_primitives, self.limits.primitives);
        try self.ensure(self.scene.operations.items.len, additional_operations, self.limits.operations);

        // The source is balanced, but its maximum depth must fit on top of
        // the inherited stacks. The normal push APIs cap each stack at 63.
        var clip_depth = self.clip_stack.items.len;
        var layer_depth = self.layer_stack.items.len;
        var max_clip_depth = clip_depth;
        var max_layer_depth = layer_depth;
        for (source.operations.items) |source_operation| {
            switch (std.enums.fromInt(abi.OperationKind, source_operation.kind) orelse return error.InvalidScene) {
                .push_clip => {
                    clip_depth += 1;
                    max_clip_depth = @max(max_clip_depth, clip_depth);
                },
                .pop_clip => clip_depth -= 1,
                .push_layer => {
                    layer_depth += 1;
                    max_layer_depth = @max(max_layer_depth, layer_depth);
                },
                .pop_layer => layer_depth -= 1,
                else => {},
            }
        }
        if (clip_depth != self.clip_stack.items.len or layer_depth != self.layer_stack.items.len or
            max_clip_depth > 63 or max_layer_depth > 63)
            return error.InvalidScene;

        try self.scene.operations.ensureUnusedCapacity(self.scene.allocator, additional_operations);
        try self.scene.materials.ensureUnusedCapacity(self.scene.allocator, source.materials.items.len);
        try self.scene.gradient_stops.ensureUnusedCapacity(self.scene.allocator, source.gradient_stops.items.len);
        try self.scene.clips.ensureUnusedCapacity(self.scene.allocator, source.clips.items.len);
        try self.scene.layers.ensureUnusedCapacity(self.scene.allocator, source.layers.items.len);
        try self.scene.shadows.ensureUnusedCapacity(self.scene.allocator, source.shadows.items.len);
        try self.scene.quads.ensureUnusedCapacity(self.scene.allocator, source.quads.items.len);
        try self.scene.paths.ensureUnusedCapacity(self.scene.allocator, source.paths.items.len);
        try self.scene.path_vertices.ensureUnusedCapacity(self.scene.allocator, source.path_vertices.items.len);
        try self.scene.underlines.ensureUnusedCapacity(self.scene.allocator, source.underlines.items.len);
        try self.scene.monochrome_sprites.ensureUnusedCapacity(self.scene.allocator, source.monochrome_sprites.items.len);
        try self.scene.color_sprites.ensureUnusedCapacity(self.scene.allocator, source.color_sprites.items.len);
        try self.scene.external_surfaces.ensureUnusedCapacity(self.scene.allocator, source.external_surfaces.items.len);
        try self.scene.custom_passes.ensureUnusedCapacity(self.scene.allocator, source.custom_passes.items.len);
        try self.scene.custom_payload.ensureUnusedCapacity(self.scene.allocator, source.custom_payload.items.len);
        try self.scene.backdrop_effects.ensureUnusedCapacity(self.scene.allocator, source.backdrop_effects.items.len);
        try self.scene.native_media_placements.ensureUnusedCapacity(self.scene.allocator, source.native_media_placements.items.len);
        try self.clip_stack.ensureUnusedCapacity(self.scene.allocator, max_clip_depth - self.clip_stack.items.len);
        try self.layer_stack.ensureUnusedCapacity(self.scene.allocator, max_layer_depth - self.layer_stack.items.len);

        for (source.gradient_stops.items) |stop| self.scene.gradient_stops.appendAssumeCapacity(stop);
        for (source.materials.items) |source_material| {
            var material = source_material;
            const kind = std.enums.fromInt(abi.MaterialKind, material.kind) orelse unreachable;
            if (kind == .linear_gradient or kind == .radial_gradient)
                material.stop_start = @intCast(bases.gradient_stops + @as(usize, source_material.stop_start));
            self.scene.materials.appendAssumeCapacity(material);
        }
        for (source.clips.items) |source_clip| {
            var clip = source_clip;
            clip.parent = try remapRetainedIndex(source_clip.parent, bases.clips, inherited_clip);
            clip.layer = try remapRetainedIndex(source_clip.layer, bases.layers, inherited_layer);
            self.scene.clips.appendAssumeCapacity(clip);
        }
        for (source.layers.items) |source_layer| {
            var layer = source_layer;
            layer.parent = try remapRetainedIndex(source_layer.parent, bases.layers, inherited_layer);
            self.scene.layers.appendAssumeCapacity(layer);
        }
        for (source.shadows.items) |value| self.scene.shadows.appendAssumeCapacity(value);
        for (source.quads.items) |value| self.scene.quads.appendAssumeCapacity(value);
        for (source.paths.items) |source_path| {
            var value = source_path;
            value.vertex_start = @intCast(bases.path_vertices + @as(usize, source_path.vertex_start));
            self.scene.paths.appendAssumeCapacity(value);
        }
        for (source.path_vertices.items) |value| self.scene.path_vertices.appendAssumeCapacity(value);
        for (source.underlines.items) |value| self.scene.underlines.appendAssumeCapacity(value);
        for (source.monochrome_sprites.items) |value| self.scene.monochrome_sprites.appendAssumeCapacity(value);
        for (source.color_sprites.items) |value| self.scene.color_sprites.appendAssumeCapacity(value);
        for (source.external_surfaces.items) |value| self.scene.external_surfaces.appendAssumeCapacity(value);
        for (source.custom_payload.items) |value| self.scene.custom_payload.appendAssumeCapacity(value);
        for (source.custom_passes.items) |source_pass| {
            var value = source_pass;
            value.payload_start = @intCast(bases.custom_payload + @as(usize, source_pass.payload_start));
            self.scene.custom_passes.appendAssumeCapacity(value);
        }
        for (source.backdrop_effects.items) |value| self.scene.backdrop_effects.appendAssumeCapacity(value);
        for (source.native_media_placements.items) |value| self.scene.native_media_placements.appendAssumeCapacity(value);

        for (source.operations.items) |source_operation| {
            const operation = self.remapRetainedOperation(source_operation, bases, inherited_clip, inherited_layer) catch unreachable;
            self.commitRetainedOperation(operation);
            switch (std.enums.fromInt(abi.OperationKind, source_operation.kind) orelse unreachable) {
                .push_clip => self.clip_stack.appendAssumeCapacity(operation.start),
                .pop_clip => _ = self.clip_stack.pop(),
                .push_layer => self.layer_stack.appendAssumeCapacity(operation.start),
                .pop_layer => _ = self.layer_stack.pop(),
                else => {},
            }
        }
    }

    const RetainedBases = struct {
        materials: usize,
        gradient_stops: usize,
        clips: usize,
        layers: usize,
        shadows: usize,
        quads: usize,
        paths: usize,
        path_vertices: usize,
        underlines: usize,
        monochrome_sprites: usize,
        color_sprites: usize,
        external_surfaces: usize,
        custom_passes: usize,
        custom_payload: usize,
        backdrop_effects: usize,
    };

    fn remapRetainedOperation(
        _: *const Builder,
        source: abi.Operation,
        bases: RetainedBases,
        inherited_clip: u32,
        inherited_layer: u32,
    ) Error!abi.Operation {
        const kind = std.enums.fromInt(abi.OperationKind, source.kind) orelse return error.InvalidScene;
        const start_base = switch (kind) {
            .push_clip, .pop_clip => bases.clips,
            .push_layer, .pop_layer => bases.layers,
            .shadows => bases.shadows,
            .quads => bases.quads,
            .paths => bases.paths,
            .underlines => bases.underlines,
            .monochrome_sprites => bases.monochrome_sprites,
            .color_sprites => bases.color_sprites,
            .external_surfaces => bases.external_surfaces,
            .custom_passes => bases.custom_passes,
            .backdrop_effect => bases.backdrop_effects,
        };
        var result = source;
        result.start = try remapRetainedIndex(source.start, start_base, none_index);
        result.clip = try remapRetainedIndex(source.clip, bases.clips, inherited_clip);
        result.layer = try remapRetainedIndex(source.layer, bases.layers, inherited_layer);
        result.material = try remapRetainedIndex(source.material, bases.materials, none_index);
        return result;
    }

    fn commitRetainedOperation(self: *Builder, operation: abi.Operation) void {
        const kind = std.enums.fromInt(abi.OperationKind, operation.kind) orelse unreachable;
        if (self.scene.operations.items.len != 0 and canMerge(self.scene.operations.items[self.scene.operations.items.len - 1], operation)) {
            self.scene.operations.items[self.scene.operations.items.len - 1].count += operation.count;
        } else {
            self.scene.operations.appendAssumeCapacity(operation);
        }
        if (isPrimitive(kind)) self.primitive_count += operation.count;
    }

    fn currentClip(self: *const Builder) u32 {
        return if (self.clip_stack.items.len == 0) none_index else self.clip_stack.items[self.clip_stack.items.len - 1];
    }

    fn currentLayer(self: *const Builder) u32 {
        return if (self.layer_stack.items.len == 0) none_index else self.layer_stack.items[self.layer_stack.items.len - 1];
    }

    const OperationPlan = struct {
        merge: bool,
        clip: u32,
        layer: u32,
    };

    fn prepareCurrentOperation(
        self: *Builder,
        kind: abi.OperationKind,
        start: u32,
        count: u32,
        material: u32,
        resource_index: u32,
    ) Error!OperationPlan {
        return self.prepareOperation(kind, start, count, material, resource_index, self.currentClip(), self.currentLayer());
    }

    fn prepareOperation(
        self: *Builder,
        kind: abi.OperationKind,
        start: u32,
        _: u32,
        material: u32,
        resource_index: u32,
        clip: u32,
        layer: u32,
    ) Error!OperationPlan {
        if (self.scene.operations.items.len != 0 and isMergeable(kind)) {
            const previous = self.scene.operations.items[self.scene.operations.items.len - 1];
            if (previous.kind == @backingInt(kind) and previous.start + previous.count == start and
                previous.clip == clip and previous.layer == layer and previous.material == material and previous.target == self.target and previous.reserved == resource_index)
            {
                return .{ .merge = true, .clip = clip, .layer = layer };
            }
        }
        try self.ensure(self.scene.operations.items.len, 1, self.limits.operations);
        try self.scene.operations.ensureUnusedCapacity(self.scene.allocator, 1);
        return .{ .merge = false, .clip = clip, .layer = layer };
    }

    fn commitOperation(
        self: *Builder,
        plan: OperationPlan,
        kind: abi.OperationKind,
        start: u32,
        count: u32,
        material: u32,
        resource_index: u32,
    ) void {
        if (plan.merge) {
            self.scene.operations.items[self.scene.operations.items.len - 1].count += count;
            if (isPrimitive(kind)) self.primitive_count += count;
            return;
        }
        self.scene.operations.appendAssumeCapacity(.{
            .kind = @backingInt(kind),
            .start = start,
            .count = count,
            .clip = plan.clip,
            .layer = plan.layer,
            .material = material,
            .target = self.target,
            .reserved = resource_index,
        });
        if (isPrimitive(kind)) self.primitive_count += count;
    }

    fn ensurePrimitive(self: *Builder, _: usize) Error!void {
        try self.ensure(self.primitive_count, 1, self.limits.primitives);
    }

    fn ensure(_: *Builder, current: usize, additional: usize, maximum: usize) Error!void {
        if (additional > maximum or current > maximum - additional) return error.BudgetExceeded;
        if (current + additional > std.math.maxInt(u32)) return error.BudgetExceeded;
    }
};

pub fn validate(view: render.SceneView) Error!void {
    inline for (.{
        view.operations.len,
        view.materials.len,
        view.gradient_stops.len,
        view.clips.len,
        view.layers.len,
        view.shadows.len,
        view.quads.len,
        view.paths.len,
        view.path_vertices.len,
        view.underlines.len,
        view.monochrome_sprites.len,
        view.color_sprites.len,
        view.external_surfaces.len,
        view.custom_passes.len,
        view.custom_payload.len,
        view.backdrop_effects.len,
    }) |length| if (length > std.math.maxInt(u32)) return error.BudgetExceeded;
    var active_clip: u32 = none_index;
    var active_layer: u32 = none_index;
    for (view.operations) |operation| {
        const kind = std.enums.fromInt(abi.OperationKind, operation.kind) orelse return error.InvalidScene;
        if (operation.count == 0 or operation.target != 0) return error.InvalidScene;
        if (operation.clip != none_index and operation.clip >= view.clips.len) return error.InvalidScene;
        if (operation.layer != none_index and operation.layer >= view.layers.len) return error.InvalidScene;
        if (operation.material != none_index and operation.material >= view.materials.len) return error.InvalidScene;
        const end = @as(usize, operation.start) + @as(usize, operation.count);
        const length: usize = switch (kind) {
            .push_clip, .pop_clip => view.clips.len,
            .push_layer, .pop_layer => view.layers.len,
            .shadows => view.shadows.len,
            .quads => view.quads.len,
            .paths => view.paths.len,
            .underlines => view.underlines.len,
            .monochrome_sprites => view.monochrome_sprites.len,
            .color_sprites => view.color_sprites.len,
            .external_surfaces => view.external_surfaces.len,
            .custom_passes => view.custom_passes.len,
            .backdrop_effect => view.backdrop_effects.len,
        };
        if (end > length) return error.InvalidScene;
        switch (kind) {
            .push_clip => {
                if (operation.count != 1 or operation.material != none_index or operation.reserved != none_index)
                    return error.InvalidScene;
                if (operation.start >= view.clips.len) return error.InvalidScene;
                const pushed = view.clips[operation.start];
                if (pushed.parent != active_clip or operation.clip != operation.start or operation.layer != active_layer) return error.InvalidScene;
                active_clip = operation.start;
            },
            .pop_clip => {
                if (operation.count != 1 or operation.material != none_index or operation.reserved != none_index)
                    return error.InvalidScene;
                if (active_clip == none_index or operation.start != active_clip) return error.InvalidScene;
                active_clip = view.clips[active_clip].parent;
                if (operation.clip != active_clip or operation.layer != active_layer) return error.InvalidScene;
            },
            .push_layer => {
                if (operation.count != 1 or operation.material != none_index or operation.reserved != none_index)
                    return error.InvalidScene;
                if (operation.start >= view.layers.len) return error.InvalidScene;
                const pushed = view.layers[operation.start];
                if (pushed.parent != active_layer or operation.layer != operation.start or operation.clip != active_clip) return error.InvalidScene;
                active_layer = operation.start;
            },
            .pop_layer => {
                if (operation.count != 1 or operation.material != none_index or operation.reserved != none_index)
                    return error.InvalidScene;
                if (active_layer == none_index or operation.start != active_layer) return error.InvalidScene;
                active_layer = view.layers[active_layer].parent;
                if (operation.layer != active_layer or operation.clip != active_clip) return error.InvalidScene;
            },
            else => {
                if (operation.clip != active_clip or operation.layer != active_layer) return error.InvalidScene;
                const may_have_material = kind == .quads or kind == .paths;
                if (kind == .backdrop_effect and
                    (operation.count != 1 or operation.material != none_index or operation.reserved != none_index))
                    return error.InvalidScene;
                if (!may_have_material and operation.material != none_index) return error.InvalidScene;
                switch (kind) {
                    .monochrome_sprites => for (view.monochrome_sprites[operation.start..][0..operation.count]) |sprite|
                        if (@as(u32, @truncate(sprite.texture)) != operation.reserved) return error.InvalidScene,
                    .color_sprites => for (view.color_sprites[operation.start..][0..operation.count]) |sprite|
                        if (@as(u32, @truncate(sprite.texture)) != operation.reserved) return error.InvalidScene,
                    .external_surfaces => for (view.external_surfaces[operation.start..][0..operation.count]) |surface|
                        if (@as(u32, @truncate(surface.surface)) != operation.reserved) return error.InvalidScene,
                    .custom_passes => for (view.custom_passes[operation.start..][0..operation.count]) |pass|
                        if (@as(u32, @truncate(pass.extension)) != operation.reserved) return error.InvalidScene,
                    else => if (operation.reserved != none_index) return error.InvalidScene,
                }
            },
        }
    }
    if (active_clip != none_index or active_layer != none_index) return error.InvalidScene;
    for (view.materials) |material| {
        const kind = std.enums.fromInt(abi.MaterialKind, material.kind) orelse return error.InvalidScene;
        if ((kind == .linear_gradient or kind == .radial_gradient) and @as(usize, material.stop_start) + @as(usize, material.stop_count) > view.gradient_stops.len)
            return error.InvalidScene;
        if ((kind == .linear_gradient or kind == .radial_gradient) and material.stop_count == 0)
            return error.InvalidScene;
        if (!finiteColor(material.color) or !finitePoint(material.start) or !finitePoint(material.end) or !finiteTransform(material.gradient_transform)) return error.InvalidScene;
        if (kind == .radial_gradient and (material.color.r < 0 or material.color.g < 0 or
            !std.math.isFinite(material.color.r) or !std.math.isFinite(material.color.g) or
            (material.start.x == material.end.x and material.start.y == material.end.y and material.color.r == material.color.g))) return error.InvalidScene;
        if (kind == .linear_gradient or kind == .radial_gradient) {
            const stops = view.gradient_stops[material.stop_start..][0..material.stop_count];
            var previous: f32 = -std.math.inf(f32);
            for (stops) |stop| {
                if (!std.math.isFinite(stop.offset) or stop.offset < previous or !finiteColor(stop.color)) return error.InvalidScene;
                previous = stop.offset;
            }
        }
    }
    for (view.clips, 0..) |clip, index| {
        if (clip.parent != none_index and clip.parent >= index) return error.InvalidScene;
        if (clip.layer != none_index and clip.layer >= view.layers.len) return error.InvalidScene;
        if (!validRect(clip.bounds) or !finiteRadii(clip.radii)) return error.InvalidScene;
        var cursor = clip.parent;
        var depth: usize = 1;
        while (cursor != none_index) : (depth += 1) {
            if (cursor >= view.clips.len or depth >= 64) return error.InvalidScene;
            cursor = view.clips[cursor].parent;
        }
    }
    for (view.layers, 0..) |layer, index| {
        if (layer.parent != none_index and layer.parent >= index) return error.InvalidScene;
        _ = std.enums.fromInt(abi.BlendMode, layer.blend_mode) orelse return error.InvalidScene;
        if (!std.math.isFinite(layer.opacity) or layer.opacity < 0 or layer.opacity > 1 or !finiteTransform(layer.transform)) return error.InvalidScene;
        var cursor = layer.parent;
        var depth: usize = 1;
        while (cursor != none_index) : (depth += 1) {
            if (cursor >= view.layers.len or depth >= 64) return error.InvalidScene;
            cursor = view.layers[cursor].parent;
        }
        _ = try checkedLayerTransform(view, @intCast(index));
    }
    for (view.quads) |quad| if (!validRect(quad.bounds) or !finiteColor(quad.background) or !finiteColor(quad.border_color) or
        !finiteInsets(quad.border_widths) or !finiteRadii(quad.radii)) return error.InvalidScene;
    for (view.shadows) |shadow| if (!validRect(shadow.bounds) or !finiteColor(shadow.color) or !finiteRadii(shadow.radii) or
        !finitePoint(shadow.offset) or !std.math.isFinite(shadow.blur_radius) or shadow.blur_radius < 0 or !std.math.isFinite(shadow.spread)) return error.InvalidScene;
    for (view.paths) |path_value| {
        if (@as(usize, path_value.vertex_start) + @as(usize, path_value.vertex_count) > view.path_vertices.len)
            return error.InvalidScene;
        _ = std.enums.fromInt(abi.FillRule, path_value.fill_rule) orelse return error.InvalidScene;
        if (!finiteColor(path_value.color) or !validRect(path_value.bounds)) return error.InvalidScene;
        const commands = view.path_vertices[@as(usize, path_value.vertex_start)..][0..path_value.vertex_count];
        if (commands.len != 0) {
            const first = std.enums.fromInt(abi.PathCommand, commands[0].kind) orelse return error.InvalidScene;
            if (first != .move_to) return error.InvalidScene;
        }
        for (commands) |command| {
            _ = std.enums.fromInt(abi.PathCommand, command.kind) orelse return error.InvalidScene;
            if (!finitePoint(command.position) or !finitePoint(command.control)) return error.InvalidScene;
        }
    }
    for (view.underlines) |underline| if (!validRect(underline.bounds) or !finiteColor(underline.color) or
        !std.math.isFinite(underline.thickness) or underline.thickness < 0 or !std.math.isFinite(underline.wave_amplitude) or
        !std.math.isFinite(underline.wave_period) or underline.wave_period < 0) return error.InvalidScene;
    for (view.monochrome_sprites) |sprite| try validateSprite(sprite);
    for (view.color_sprites) |sprite| try validateSprite(sprite);
    for (view.external_surfaces) |surface| {
        if (!validRect(surface.bounds) or !validRect(surface.uv_bounds) or surface.surface == 0 or surface.generation == 0 or
            !std.math.isFinite(surface.opacity) or surface.opacity < 0 or surface.opacity > 1) return error.InvalidScene;
    }
    for (view.custom_passes) |pass| {
        if (!validRect(pass.bounds) or pass.extension == 0 or
            @as(usize, pass.payload_start) + @as(usize, pass.payload_length) > view.custom_payload.len)
            return error.InvalidScene;
    }
    for (view.backdrop_effects) |effect| {
        if (!validRect(effect.bounds) or !finiteRadii(effect.radii) or
            !std.math.isFinite(effect.blur_radius) or effect.blur_radius < 0 or
            effect.blur_radius > 128 or !std.math.isFinite(effect.saturation) or
            effect.saturation < 0 or effect.saturation > 4 or
            !std.math.isFinite(effect.opacity) or effect.opacity < 0 or effect.opacity > 1)
            return error.InvalidScene;
    }
    try validateEffectiveGeometry(view);
}

fn validateSprite(sprite: abi.Sprite) Error!void {
    if (!validRect(sprite.bounds) or !validRect(sprite.uv_bounds) or !finiteColor(sprite.color) or
        sprite.texture == 0 or sprite.tile_generation == 0) return error.InvalidScene;
    _ = std.enums.fromInt(abi.TextureFormat, sprite.format) orelse return error.InvalidScene;
    if (!std.math.isFinite(sprite.effect_radius) or sprite.effect_radius < 0 or sprite.effect_radius > 32 or
        !std.math.isFinite(sprite.effect_height) or sprite.effect_height < 0 or
        (sprite.effect != .none and sprite.effect_height <= 0)) return error.InvalidScene;
}

fn finitePoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}
fn validRect(value: geometry.Rect) bool {
    return finitePoint(value.origin) and std.math.isFinite(value.size.width) and std.math.isFinite(value.size.height) and
        value.size.width >= 0 and value.size.height >= 0 and
        std.math.isFinite(value.maxX()) and std.math.isFinite(value.maxY());
}
fn finiteColor(value: geometry.Color) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and std.math.isFinite(value.b) and
        std.math.isFinite(value.a) and value.a >= 0 and value.a <= 1;
}
fn finiteInsets(value: geometry.Insets) bool {
    return std.math.isFinite(value.top) and std.math.isFinite(value.right) and std.math.isFinite(value.bottom) and
        std.math.isFinite(value.left) and value.top >= 0 and value.right >= 0 and value.bottom >= 0 and value.left >= 0;
}
fn finiteRadii(value: geometry.CornerRadii) bool {
    return std.math.isFinite(value.top_left) and std.math.isFinite(value.top_right) and
        std.math.isFinite(value.bottom_right) and std.math.isFinite(value.bottom_left) and
        value.top_left >= 0 and value.top_right >= 0 and value.bottom_right >= 0 and value.bottom_left >= 0;
}
fn finiteTransform(value: geometry.Affine2D) bool {
    return std.math.isFinite(value.m11) and std.math.isFinite(value.m12) and std.math.isFinite(value.m21) and
        std.math.isFinite(value.m22) and std.math.isFinite(value.tx) and std.math.isFinite(value.ty);
}

fn checkedLayerTransform(view: render.SceneView, layer_index: u32) Error!geometry.Affine2D {
    if (layer_index == none_index) return .identity;
    var chain: [64]u32 = undefined;
    var count: usize = 0;
    var current = layer_index;
    while (current != none_index) {
        if (current >= view.layers.len or count == chain.len) return error.InvalidScene;
        chain[count] = current;
        count += 1;
        current = view.layers[current].parent;
    }
    var result: geometry.Affine2D = .identity;
    while (count != 0) {
        count -= 1;
        result = geometry.Affine2D.mul(result, view.layers[chain[count]].transform);
        if (!finiteTransform(result)) return error.InvalidScene;
    }
    return result;
}

fn validateEffectiveGeometry(view: render.SceneView) Error!void {
    for (view.clips) |clip| {
        const transform = try checkedLayerTransform(view, clip.layer);
        if (!validRect(transform.transformRectBounds(clip.bounds))) return error.InvalidScene;
    }
    var transforms: [64]geometry.Affine2D = undefined;
    var depth: usize = 0;
    var transform: geometry.Affine2D = .identity;
    for (view.operations) |operation| {
        const kind = std.enums.fromInt(abi.OperationKind, operation.kind) orelse return error.InvalidScene;
        switch (kind) {
            .push_clip, .pop_clip => continue,
            .push_layer => {
                if (depth == transforms.len) return error.InvalidScene;
                transform = geometry.Affine2D.mul(transform, view.layers[operation.start].transform);
                if (!finiteTransform(transform)) return error.InvalidScene;
                transforms[depth] = transform;
                depth += 1;
                continue;
            },
            .pop_layer => {
                if (depth == 0) return error.InvalidScene;
                depth -= 1;
                transform = if (depth == 0) .identity else transforms[depth - 1];
                continue;
            },
            else => {},
        }
        const start: usize = @intCast(operation.start);
        const count: usize = @intCast(operation.count);
        switch (kind) {
            .quads => for (view.quads[start..][0..count]) |quad| try validateTransformedRect(transform, quad.bounds),
            .shadows => for (view.shadows[start..][0..count]) |shadow| {
                const extent = @max(0, shadow.spread + shadow.blur_radius * 2);
                const expanded = geometry.Rect.fromXYWH(
                    shadow.bounds.origin.x + shadow.offset.x - extent,
                    shadow.bounds.origin.y + shadow.offset.y - extent,
                    @max(0, shadow.bounds.size.width + extent * 2),
                    @max(0, shadow.bounds.size.height + extent * 2),
                );
                if (!validRect(expanded)) return error.InvalidScene;
                try validateTransformedRect(transform, expanded);
            },
            .paths => for (view.paths[start..][0..count]) |path_value| {
                try validateTransformedRect(transform, path_value.bounds);
                const vertex_start: usize = @intCast(path_value.vertex_start);
                const vertex_count: usize = @intCast(path_value.vertex_count);
                for (view.path_vertices[vertex_start..][0..vertex_count]) |vertex| {
                    if (!finitePoint(transform.transformPoint(vertex.position)) or
                        !finitePoint(transform.transformPoint(vertex.control))) return error.InvalidScene;
                }
            },
            .underlines => for (view.underlines[start..][0..count]) |underline|
                try validateTransformedRect(transform, underline.bounds),
            .monochrome_sprites => for (view.monochrome_sprites[start..][0..count]) |sprite|
                try validateTransformedRect(transform, sprite.bounds),
            .color_sprites => for (view.color_sprites[start..][0..count]) |sprite|
                try validateTransformedRect(transform, sprite.bounds),
            .external_surfaces => for (view.external_surfaces[start..][0..count]) |surface|
                try validateTransformedRect(transform, surface.bounds),
            .custom_passes => for (view.custom_passes[start..][0..count]) |pass|
                try validateTransformedRect(transform, pass.bounds),
            .backdrop_effect => for (view.backdrop_effects[start..][0..count]) |effect|
                try validateTransformedRect(transform, effect.bounds),
            .push_clip, .pop_clip, .push_layer, .pop_layer => unreachable,
        }
    }
    if (depth != 0) return error.InvalidScene;
}

fn validateTransformedRect(transform: geometry.Affine2D, bounds: geometry.Rect) Error!void {
    if (!validRect(transform.transformRectBounds(bounds))) return error.InvalidScene;
}

fn isMergeable(kind: abi.OperationKind) bool {
    return switch (kind) {
        .shadows, .quads, .paths, .underlines, .monochrome_sprites, .color_sprites, .external_surfaces => true,
        else => false,
    };
}

fn remapRetainedIndex(index: u32, base: usize, inherited: u32) Error!u32 {
    if (index == none_index) return inherited;
    const result = std.math.add(usize, base, index) catch return error.BudgetExceeded;
    if (result > std.math.maxInt(u32)) return error.BudgetExceeded;
    return @intCast(result);
}

fn canMerge(previous: abi.Operation, next: abi.Operation) bool {
    const kind = std.enums.fromInt(abi.OperationKind, next.kind) orelse return false;
    if (!isMergeable(kind) or previous.kind != next.kind) return false;
    const contiguous = std.math.add(u32, previous.start, previous.count) catch return false;
    return contiguous == next.start and previous.clip == next.clip and previous.layer == next.layer and
        previous.material == next.material and previous.target == next.target and previous.reserved == next.reserved;
}

fn validateNativeMedia(placements: []const native_media.Placement) Error!void {
    for (placements, 0..) |placement, index| {
        if (!placement.id.isValid() or !validRect(placement.bounds) or
            placement.bounds.size.width <= 0 or placement.bounds.size.height <= 0)
            return error.InvalidScene;
        for (placements[0..index]) |previous| if (placement.id.eql(previous.id)) return error.InvalidScene;
    }
}

fn isPrimitive(kind: abi.OperationKind) bool {
    return switch (kind) {
        .push_clip, .pop_clip, .push_layer, .pop_layer => false,
        else => true,
    };
}
