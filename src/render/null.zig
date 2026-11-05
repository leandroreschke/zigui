const std = @import("std");
const config = @import("../config.zig");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const scene_abi = @import("../scene/abi.zig");
const scene = @import("../scene/scene.zig");
const api = @import("api.zig");
const extension = @import("extension.zig");
const path_tessellator = @import("path_tessellator.zig");

const maximum_offscreen_pixels = 67_108_864;
const maximum_layer_depth = 63;
const maximum_clip_depth = 64;
const maximum_layer_bytes = 512 * 1024 * 1024;

const AsyncOffscreenRequest = struct {
    id: api.OffscreenRequestId,
    target: api.OffscreenTarget,
    snapshot: api.SceneSnapshot,
    /// Each retained ID holds its texture in the renderer map until the
    /// asynchronous request reaches a terminal poll or teardown drain.
    retained_texture_ids: std.ArrayList(u64) = .empty,
    polled: bool = false,
    cancelled: bool = false,
};

pub const NullRenderer = struct {
    allocator: std.mem.Allocator,
    generation: api.DeviceGeneration = 1,
    next_token: u64 = 1,
    active_token: ?api.FrameToken = null,
    submitted_epoch: api.SubmissionEpoch = 0,
    completed_submission: api.SubmissionEpoch = 0,
    textures: std.AutoHashMap(u64, Texture),
    extensions: extension.Registry,
    path_limits: path_tessellator.Limits,
    maximum_textures: usize,
    maximum_offscreen_requests: usize,
    next_offscreen_id: api.OffscreenRequestId = 1,
    offscreen_requests: std.AutoHashMap(api.OffscreenRequestId, *AsyncOffscreenRequest),

    const Texture = struct {
        descriptor: api.TextureDescriptor,
        pixels: []u8,
        release_after: api.SubmissionEpoch = std.math.maxInt(api.SubmissionEpoch),
        async_holds: usize = 0,
    };

    pub fn create(allocator: std.mem.Allocator) Error!api.Renderer {
        return createWithMemory(allocator, .{});
    }

    pub fn createWithMemory(allocator: std.mem.Allocator, memory: config.MemoryBudgets) Error!api.Renderer {
        const instance = try allocator.create(NullRenderer);
        instance.* = .{
            .allocator = allocator,
            .textures = std.AutoHashMap(u64, Texture).init(allocator),
            .extensions = extension.Registry.initWithLimit(allocator, memory.render_extension_count),
            .path_limits = .{
                .maximum_edges = memory.path_edge_count,
                .maximum_work_units = memory.path_work_units,
                .maximum_output_vertices = memory.upload_ring_bytes / @sizeOf(path_tessellator.Vertex),
                .maximum_cache_bytes = 0,
            },
            .maximum_textures = memory.texture_count,
            .maximum_offscreen_requests = memory.offscreen_request_count,
            .offscreen_requests = std.AutoHashMap(api.OffscreenRequestId, *AsyncOffscreenRequest).init(allocator),
        };
        return .{ .context = instance, .vtable = &vtable };
    }

    const vtable: api.Renderer.VTable = .{
        .capabilities = capabilities,
        .device_generation = deviceGeneration,
        .begin_frame = beginFrame,
        .submit = submit,
        .render_offscreen = renderOffscreen,
        .begin_offscreen = beginOffscreen,
        .poll_offscreen = pollOffscreen,
        .cancel_offscreen = cancelOffscreen,
        .drain_offscreen = drainOffscreen,
        .completed_epoch = completedEpoch,
        .invalidate_surface = invalidateSurface,
        .recover = recover,
        .create_texture = createTexture,
        .write_texture = writeTexture,
        .destroy_texture = destroyTexture,
        .import_external_surface = importExternalSurface,
        .replace_external_surface = replaceExternalSurface,
        .destroy_external_surface = destroyExternalSurface,
        .register_extension = registerExtension,
        .destroy_extension = destroyExtension,
        .deinit = deinit,
    };

    fn self(context: *anyopaque) *NullRenderer {
        return @ptrCast(@alignCast(context));
    }

    fn capabilities(_: *anyopaque) api.Capabilities {
        return .{ .offscreen_readback = true, .offscreen_async_readback = true, .custom_materials = true, .backdrop_effects = true };
    }

    fn deviceGeneration(context: *anyopaque) api.DeviceGeneration {
        return self(context).generation;
    }

    fn beginFrame(context: *anyopaque, descriptor: api.FrameDescriptor) Error!api.FrameToken {
        const renderer = self(context);
        renderer.extensions.collect(renderer.completed_submission);
        if (renderer.active_token != null) return error.FrameActive;
        if (descriptor.drawable_width == 0 or descriptor.drawable_height == 0) return error.WindowNotConfigured;
        const token: api.FrameToken = .{ .value = renderer.next_token, .device_generation = renderer.generation };
        renderer.next_token +%= 1;
        if (renderer.next_token == 0) renderer.next_token = 1;
        renderer.active_token = token;
        return token;
    }

    fn submit(context: *anyopaque, token: api.FrameToken, view: api.SceneView) Error!api.Submission {
        const renderer = self(context);
        const active = renderer.active_token orelse return error.FramePhaseViolation;
        defer renderer.active_token = null;
        if (active.value != token.value or active.device_generation != token.device_generation) return error.FramePhaseViolation;
        if (token.device_generation != renderer.generation) return error.DeviceLost;
        try scene.validate(view);
        renderer.submitted_epoch +%= 1;
        if (renderer.submitted_epoch == 0) renderer.submitted_epoch = 1;
        renderer.completed_submission = renderer.submitted_epoch;
        renderer.collectTextures();
        return .{
            .epoch = renderer.submitted_epoch,
            .device_generation = renderer.generation,
            .presented = true,
        };
    }

    fn renderOffscreen(
        context: *anyopaque,
        target: api.OffscreenTarget,
        view: api.SceneView,
        allocator: std.mem.Allocator,
    ) Error!?api.Readback {
        if (!target.readback) return null;
        if (target.width == 0 or target.height == 0) return error.InvalidConfiguration;
        try scene.validate(view);
        const pixel_count = std.math.mul(usize, target.width, target.height) catch return error.BudgetExceeded;
        if (pixel_count > maximum_offscreen_pixels) return error.BudgetExceeded;
        const canvas_stride = std.math.mul(usize, target.width, 4) catch return error.BudgetExceeded;
        const canvas_length = std.math.mul(usize, canvas_stride, target.height) catch return error.BudgetExceeded;
        const canvas = try allocator.alloc(u8, canvas_length);
        errdefer allocator.free(canvas);
        @memset(canvas, 0);
        var raster_target = target;
        raster_target.format = .rgba8;
        const renderer = self(context);
        try rasterize(view, raster_target, canvas, canvas_stride, renderer, allocator, renderer.path_limits);
        const output_bpp = bytesPerPixel(target.format);
        const stride = std.math.mul(usize, target.width, output_bpp) catch return error.BudgetExceeded;
        const length = std.math.mul(usize, stride, target.height) catch return error.BudgetExceeded;
        const pixels = if (target.format == .rgba8)
            canvas
        else blk: {
            const converted = try allocator.alloc(u8, length);
            errdefer allocator.free(converted);
            convertCanvas(canvas, converted, target.format);
            allocator.free(canvas);
            break :blk converted;
        };
        return .{
            .width = target.width,
            .height = target.height,
            .stride = stride,
            .format = target.format,
            .pixels = pixels,
        };
    }

    fn beginOffscreen(
        context: *anyopaque,
        target: api.OffscreenTarget,
        view: api.SceneView,
    ) Error!api.OffscreenRequestId {
        const renderer = self(context);
        if (!target.readback) return error.InvalidConfiguration;
        if (renderer.offscreen_requests.count() >= renderer.maximum_offscreen_requests)
            return error.BudgetExceeded;
        try scene.validate(view);
        try renderer.offscreen_requests.ensureUnusedCapacity(1);
        const snapshot = try api.SceneSnapshot.init(renderer.allocator, view);
        errdefer {
            var owned = snapshot;
            owned.deinit();
        }
        const id = renderer.nextOffscreenIdValue();
        const request = try renderer.allocator.create(AsyncOffscreenRequest);
        errdefer {
            renderer.releaseSceneTextures(request);
            request.retained_texture_ids.deinit(renderer.allocator);
            renderer.allocator.destroy(request);
        }
        request.* = .{ .id = id, .target = target, .snapshot = snapshot };
        try renderer.retainSceneTextures(request, snapshot.view());
        renderer.offscreen_requests.putAssumeCapacity(id, request);
        return id;
    }

    fn retainSceneTextures(renderer: *NullRenderer, request: *AsyncOffscreenRequest, view: api.SceneView) Error!void {
        for (view.operations) |operation| {
            const kind = std.enums.fromInt(scene_abi.OperationKind, operation.kind) orelse return error.InvalidScene;
            const sprites = switch (kind) {
                .monochrome_sprites => view.monochrome_sprites[operation.start..][0..operation.count],
                .color_sprites => view.color_sprites[operation.start..][0..operation.count],
                else => continue,
            };
            for (sprites) |sprite| {
                const texture = renderer.textures.getPtr(sprite.texture) orelse return error.InvalidHandle;
                texture.async_holds += 1;
                request.retained_texture_ids.append(renderer.allocator, sprite.texture) catch |err| {
                    texture.async_holds -= 1;
                    return err;
                };
            }
        }
    }

    fn pollOffscreen(
        context: *anyopaque,
        id: api.OffscreenRequestId,
        allocator: std.mem.Allocator,
    ) Error!api.OffscreenPoll {
        const renderer = self(context);
        const request = renderer.offscreen_requests.get(id) orelse return error.InvalidHandle;
        if (!request.polled) {
            request.polled = true;
            return .pending;
        }
        if (request.cancelled) {
            renderer.finishOffscreenRequest(id, request);
            return .cancelled;
        }
        const result = renderOffscreen(renderer, request.target, request.snapshot.view(), allocator) catch |err| {
            renderer.finishOffscreenRequest(id, request);
            return .{ .failed = err };
        };
        const readback = result orelse {
            renderer.finishOffscreenRequest(id, request);
            return .{ .failed = error.PlatformFailure };
        };
        renderer.finishOffscreenRequest(id, request);
        return .{ .ready = readback };
    }

    fn cancelOffscreen(context: *anyopaque, id: api.OffscreenRequestId) Error!void {
        const request = self(context).offscreen_requests.get(id) orelse return error.InvalidHandle;
        request.cancelled = true;
    }

    fn drainOffscreen(context: *anyopaque) void {
        const renderer = self(context);
        var iterator = renderer.offscreen_requests.iterator();
        while (iterator.next()) |entry| {
            const request = entry.value_ptr.*;
            renderer.releaseSceneTextures(request);
            request.snapshot.deinit();
            request.retained_texture_ids.deinit(renderer.allocator);
            renderer.allocator.destroy(request);
        }
        renderer.offscreen_requests.clearRetainingCapacity();
    }

    fn nextOffscreenIdValue(renderer: *NullRenderer) api.OffscreenRequestId {
        var id = renderer.next_offscreen_id;
        while (id == 0 or renderer.offscreen_requests.contains(id)) {
            id +%= 1;
            if (id == 0) id = 1;
        }
        renderer.next_offscreen_id = id +% 1;
        if (renderer.next_offscreen_id == 0) renderer.next_offscreen_id = 1;
        return id;
    }

    fn finishOffscreenRequest(renderer: *NullRenderer, id: api.OffscreenRequestId, request: *AsyncOffscreenRequest) void {
        _ = renderer.offscreen_requests.remove(id);
        renderer.releaseSceneTextures(request);
        request.snapshot.deinit();
        request.retained_texture_ids.deinit(renderer.allocator);
        renderer.allocator.destroy(request);
    }

    fn releaseSceneTextures(renderer: *NullRenderer, request: *AsyncOffscreenRequest) void {
        for (request.retained_texture_ids.items) |id| {
            if (renderer.textures.getPtr(id)) |texture| texture.async_holds -|= 1;
        }
        renderer.collectTextures();
    }

    fn completedEpoch(context: *anyopaque) api.SubmissionEpoch {
        return self(context).completed_submission;
    }

    fn invalidateSurface(_: *anyopaque, _: @import("../core/handle.zig").WindowId) Error!void {}

    fn recover(context: *anyopaque, policy: config.GpuPolicy) Error!void {
        _ = policy;
        const renderer = self(context);
        if (renderer.extensions.callbacksActive()) return error.CallbackReentrancy;
        drainOffscreen(renderer);
        renderer.generation +%= 1;
        if (renderer.generation == 0) renderer.generation = 1;
        renderer.active_token = null;
        var iterator = renderer.textures.iterator();
        while (iterator.next()) |entry| renderer.allocator.free(entry.value_ptr.pixels);
        renderer.textures.clearRetainingCapacity();
        renderer.extensions.deviceLost(renderer.generation);
    }

    fn createTexture(context: *anyopaque, id: @import("../core/handle.zig").TextureId, descriptor: api.TextureDescriptor) Error!void {
        const renderer = self(context);
        if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
        if (renderer.textures.contains(id.encode())) return error.ResourceBusy;
        if (renderer.textures.count() >= renderer.maximum_textures) return error.BudgetExceeded;
        const pixels = try renderer.allocator.alloc(u8, try descriptor.byteLength());
        errdefer renderer.allocator.free(pixels);
        @memset(pixels, 0);
        try renderer.textures.put(id.encode(), .{ .descriptor = descriptor, .pixels = pixels });
    }

    fn writeTexture(
        context: *anyopaque,
        id: @import("../core/handle.zig").TextureId,
        region: api.TextureRegion,
        source: []const u8,
        source_stride: usize,
    ) Error!void {
        const texture = self(context).textures.getPtr(id.encode()) orelse return error.InvalidHandle;
        if (region.width == 0 or region.height == 0) return;
        if (region.x > texture.descriptor.width or region.width > texture.descriptor.width - region.x or
            region.y > texture.descriptor.height or region.height > texture.descriptor.height - region.y)
            return error.InvalidConfiguration;
        const bpp = bytesPerPixel(texture.descriptor.format);
        const row_bytes = std.math.mul(usize, region.width, bpp) catch return error.BudgetExceeded;
        if (source_stride < row_bytes) return error.InvalidConfiguration;
        const required_source = std.math.add(
            usize,
            std.math.mul(usize, source_stride, region.height - 1) catch return error.BudgetExceeded,
            row_bytes,
        ) catch return error.BudgetExceeded;
        if (source.len < required_source) return error.InvalidConfiguration;
        const destination_stride = std.math.mul(usize, texture.descriptor.width, bpp) catch return error.BudgetExceeded;
        const destination_x = std.math.mul(usize, region.x, bpp) catch return error.BudgetExceeded;
        var row: usize = 0;
        while (row < region.height) : (row += 1) {
            const source_start = std.math.mul(usize, row, source_stride) catch return error.BudgetExceeded;
            const destination_row = std.math.add(usize, region.y, row) catch return error.BudgetExceeded;
            const destination_start = std.math.add(
                usize,
                std.math.mul(usize, destination_row, destination_stride) catch return error.BudgetExceeded,
                destination_x,
            ) catch return error.BudgetExceeded;
            @memcpy(texture.pixels[destination_start..][0..row_bytes], source[source_start..][0..row_bytes]);
        }
    }

    fn destroyTexture(context: *anyopaque, id: @import("../core/handle.zig").TextureId, release_after: api.SubmissionEpoch) Error!void {
        const texture = self(context).textures.getPtr(id.encode()) orelse return error.InvalidHandle;
        texture.release_after = release_after;
        self(context).collectTextures();
    }

    fn importExternalSurface(_: *anyopaque, _: @import("../core/handle.zig").SurfaceId, _: api.ExternalSurfaceDescriptor) Error!void {
        return error.Unsupported;
    }

    fn replaceExternalSurface(
        _: *anyopaque,
        _: @import("../core/handle.zig").SurfaceId,
        _: api.ExternalSurfaceDescriptor,
        _: api.SubmissionEpoch,
    ) Error!void {
        return error.Unsupported;
    }

    fn destroyExternalSurface(_: *anyopaque, _: @import("../core/handle.zig").SurfaceId, _: api.SubmissionEpoch) Error!void {
        return error.Unsupported;
    }

    fn registerExtension(context: *anyopaque, descriptor: extension.Descriptor) Error!@import("../core/handle.zig").RenderExtensionId {
        if (descriptor.requirements.depth != null) return error.Unsupported;
        const renderer = self(context);
        renderer.extensions.collect(renderer.completed_submission);
        return renderer.extensions.register(descriptor);
    }

    fn destroyExtension(context: *anyopaque, id: @import("../core/handle.zig").RenderExtensionId, release_after: api.SubmissionEpoch) Error!void {
        try self(context).extensions.destroy(id, release_after);
    }

    fn deinit(context: *anyopaque) void {
        const renderer = self(context);
        const allocator = renderer.allocator;
        drainOffscreen(renderer);
        renderer.offscreen_requests.deinit();
        var iterator = renderer.textures.iterator();
        while (iterator.next()) |entry| allocator.free(entry.value_ptr.pixels);
        renderer.textures.deinit();
        renderer.extensions.deinit();
        allocator.destroy(renderer);
    }

    fn collectTextures(renderer: *NullRenderer) void {
        var remove: std.ArrayList(u64) = .empty;
        defer remove.deinit(renderer.allocator);
        var iterator = renderer.textures.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.async_holds == 0 and entry.value_ptr.release_after <= renderer.completed_submission)
                remove.append(renderer.allocator, entry.key_ptr.*) catch return;
        }
        for (remove.items) |key| {
            const texture = renderer.textures.fetchRemove(key) orelse continue;
            renderer.allocator.free(texture.value.pixels);
        }
    }
};

const LayerSurface = struct {
    index: u32,
    pixels: []u8,
};

const ResolvedClip = struct {
    bounds: geometry.Rect,
    radii: geometry.CornerRadii,
    inverse_transform: geometry.Affine2D,
};

const ClipChain = struct {
    items: [maximum_clip_depth]ResolvedClip = undefined,
    len: usize = 0,
    bounds: geometry.Rect,

    fn coverage(self: *const ClipChain, point: geometry.Point) f32 {
        if (self.bounds.isEmpty() or !self.bounds.contains(point)) return 0;
        var result: f32 = 1;
        for (self.items[0..self.len]) |clip| {
            const local = clip.inverse_transform.transformPoint(point);
            result *= roundedCoverage(clip.bounds, clip.radii, local);
            if (result <= 0) return 0;
        }
        return result;
    }
};

const PixelBounds = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
};

fn resolveClipChain(view: api.SceneView, target: api.OffscreenTarget, clip_index: u32) Error!ClipChain {
    const scale = target.scale_factor.value;
    const viewport = geometry.Rect.fromXYWH(
        0,
        0,
        @as(f32, @floatFromInt(target.width)) / scale,
        @as(f32, @floatFromInt(target.height)) / scale,
    );
    var result: ClipChain = .{ .bounds = viewport };
    var current = clip_index;
    while (current != scene.none_index) {
        if (current >= view.clips.len or result.len >= maximum_clip_depth) return error.InvalidScene;
        const source = view.clips[current];
        const transform = try layerTransform(view, source.layer);
        const inverse = transform.inverse() orelse return error.InvalidScene;
        result.items[result.len] = .{
            .bounds = source.bounds,
            .radii = source.radii,
            .inverse_transform = inverse,
        };
        result.len += 1;
        result.bounds = geometry.Rect.intersection(result.bounds, transform.transformRectBounds(source.bounds)) orelse .{};
        current = source.parent;
    }
    return result;
}

fn pixelBounds(target: api.OffscreenTarget, logical: geometry.Rect) ?PixelBounds {
    if (logical.isEmpty()) return null;
    const scale = @as(f64, target.scale_factor.value);
    const raw_left = @as(f64, logical.minX()) * scale;
    const raw_top = @as(f64, logical.minY()) * scale;
    const raw_right = @as(f64, logical.maxX()) * scale;
    const raw_bottom = @as(f64, logical.maxY()) * scale;
    if (!std.math.isFinite(raw_left) or !std.math.isFinite(raw_top) or
        !std.math.isFinite(raw_right) or !std.math.isFinite(raw_bottom)) return null;
    const left_value = std.math.clamp(raw_left, 0, @as(f64, @floatFromInt(target.width)));
    const top_value = std.math.clamp(raw_top, 0, @as(f64, @floatFromInt(target.height)));
    const right_value = std.math.clamp(raw_right, 0, @as(f64, @floatFromInt(target.width)));
    const bottom_value = std.math.clamp(raw_bottom, 0, @as(f64, @floatFromInt(target.height)));
    const left: u32 = @intFromFloat(@floor(left_value));
    const top: u32 = @intFromFloat(@floor(top_value));
    const right: u32 = @intFromFloat(@ceil(right_value));
    const bottom: u32 = @intFromFloat(@ceil(bottom_value));
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

fn rasterize(
    view: api.SceneView,
    target: api.OffscreenTarget,
    pixels: []u8,
    stride: usize,
    renderer: *NullRenderer,
    allocator: std.mem.Allocator,
    path_limits: path_tessellator.Limits,
) Error!void {
    var layers: std.ArrayList(LayerSurface) = .empty;
    defer {
        for (layers.items) |surface| allocator.free(surface.pixels);
        layers.deinit(allocator);
    }
    var tessellator = path_tessellator.Tessellator.init(allocator, path_limits);
    defer tessellator.deinit();
    tessellator.beginBatch();
    var path_vertices: std.ArrayList(path_tessellator.Vertex) = .empty;
    defer path_vertices.deinit(allocator);
    var live_layer_bytes: usize = 0;
    for (view.operations) |operation| {
        const kind = std.enums.fromInt(scene_abi.OperationKind, operation.kind) orelse continue;
        if (kind == .push_layer) {
            if (layers.items.len >= maximum_layer_depth or pixels.len > maximum_layer_bytes -| live_layer_bytes) return error.BudgetExceeded;
            const layer_pixels = try allocator.alloc(u8, pixels.len);
            @memset(layer_pixels, 0);
            errdefer allocator.free(layer_pixels);
            try layers.append(allocator, .{ .index = operation.start, .pixels = layer_pixels });
            live_layer_bytes += pixels.len;
            continue;
        }
        if (kind == .pop_layer) {
            const child = layers.pop() orelse return error.InvalidScene;
            if (child.index != operation.start or child.index >= view.layers.len) {
                allocator.free(child.pixels);
                return error.InvalidScene;
            }
            const destination = if (layers.items.len == 0) pixels else layers.items[layers.items.len - 1].pixels;
            try compositeSurface(destination, child.pixels, view.layers[child.index]);
            allocator.free(child.pixels);
            live_layer_bytes -= pixels.len;
            continue;
        }
        const destination = if (layers.items.len == 0) pixels else layers.items[layers.items.len - 1].pixels;
        const transform = try layerTransform(view, operation.layer);
        const opacity: f32 = 1;
        const clip = try resolveClipChain(view, target, operation.clip);
        switch (kind) {
            .quads => for (view.quads[operation.start..][0..operation.count]) |quad| {
                paintQuad(view, target, destination, stride, quad, transform, &clip, operation.material, opacity);
            },
            .shadows => for (view.shadows[operation.start..][0..operation.count]) |shadow| {
                paintShadow(target, destination, stride, shadow, transform, &clip, opacity);
            },
            .underlines => for (view.underlines[operation.start..][0..operation.count]) |underline| {
                paintUnderline(target, destination, stride, underline, transform, &clip, opacity);
            },
            .paths => for (view.paths[operation.start..][0..operation.count]) |path| {
                const commands = view.path_vertices[path.vertex_start..][0..path.vertex_count];
                path_vertices.clearRetainingCapacity();
                try tessellator.tessellate(path, commands, 0.2 / target.scale_factor.value, &path_vertices);
                try paintTriangles(view, target, destination, stride, path_vertices.items, transform, &clip, operation.material, opacity);
            },
            .monochrome_sprites => for (view.monochrome_sprites[operation.start..][0..operation.count]) |sprite| {
                paintSprite(renderer, target, destination, stride, sprite, transform, &clip, opacity, true);
            },
            .color_sprites => for (view.color_sprites[operation.start..][0..operation.count]) |sprite| {
                paintSprite(renderer, target, destination, stride, sprite, transform, &clip, opacity, false);
            },
            .custom_passes => for (view.custom_passes[operation.start..][0..operation.count]) |pass| {
                const payload = view.custom_payload[@as(usize, pass.payload_start)..][0..pass.payload_length];
                const logical_target = geometry.Rect.fromXYWH(
                    0,
                    0,
                    target.scale_factor.deviceToLogical(@floatFromInt(target.width)),
                    target.scale_factor.deviceToLogical(@floatFromInt(target.height)),
                );
                try renderer.extensions.encode(
                    extension.decodeId(pass.extension),
                    .{ .null = {} },
                    .{ .null = .{
                        .pixels = destination,
                        .stride = stride,
                        .format = @backingInt(target.format),
                        .geometry = .{
                            .window = .invalid,
                            .logical_size = logical_target.size,
                            .drawable_width = target.width,
                            .drawable_height = target.height,
                            .scale_factor = target.scale_factor,
                            .clear_color = .transparent,
                            .bounds = transform.transformRectBounds(pass.bounds),
                            .clip = clip.bounds,
                            .transform = transform,
                            .opacity = opacity,
                            .target_origin = .{},
                            .target_width = target.width,
                            .target_height = target.height,
                        },
                    } },
                    payload,
                    pass.flags,
                    renderer.generation,
                    renderer.submitted_epoch +| 1,
                );
            },
            .backdrop_effect => for (view.backdrop_effects[operation.start..][0..operation.count]) |effect|
                try paintBackdropEffect(target, destination, stride, effect, transform, &clip, allocator),
            else => {},
        }
    }
    if (layers.items.len != 0) return error.InvalidScene;
}

fn convertCanvas(source: []const u8, destination: []u8, format: api.PixelFormat) void {
    var source_offset: usize = 0;
    var destination_offset: usize = 0;
    while (source_offset + 4 <= source.len) : (source_offset += 4) switch (format) {
        .a8 => {
            destination[destination_offset] = source[source_offset + 3];
            destination_offset += 1;
        },
        .rgba8 => unreachable,
        .rgba8_srgb => {
            destination[destination_offset] = linearByteToSrgb(source[source_offset]);
            destination[destination_offset + 1] = linearByteToSrgb(source[source_offset + 1]);
            destination[destination_offset + 2] = linearByteToSrgb(source[source_offset + 2]);
            destination[destination_offset + 3] = source[source_offset + 3];
            destination_offset += 4;
        },
        .bgra8, .bgra8_srgb => {
            const convert = format == .bgra8_srgb;
            destination[destination_offset] = if (convert) linearByteToSrgb(source[source_offset + 2]) else source[source_offset + 2];
            destination[destination_offset + 1] = if (convert) linearByteToSrgb(source[source_offset + 1]) else source[source_offset + 1];
            destination[destination_offset + 2] = if (convert) linearByteToSrgb(source[source_offset]) else source[source_offset];
            destination[destination_offset + 3] = source[source_offset + 3];
            destination_offset += 4;
        },
        .rgba16_float => {
            for (0..4) |channel| {
                const normalized = @as(f32, @floatFromInt(source[source_offset + channel])) / 255;
                const bits: u16 = @bitCast(@as(f16, @floatCast(normalized)));
                std.mem.writeInt(u16, destination[destination_offset + channel * 2 ..][0..2], bits, .little);
            }
            destination_offset += 8;
        },
    };
}

fn compositeSurface(destination: []u8, source: []const u8, layer: scene_abi.Layer) Error!void {
    if (destination.len != source.len or destination.len % 4 != 0) return error.InvalidScene;
    const mode = std.enums.fromInt(scene_abi.BlendMode, layer.blend_mode) orelse return error.InvalidScene;
    const layer_opacity = std.math.clamp(layer.opacity, 0, 1);
    var offset: usize = 0;
    while (offset < source.len) : (offset += 4) {
        const source_color = byteColor(source, offset);
        const destination_color = byteColor(destination, offset);
        const source_alpha = source_color.a * layer_opacity;
        const destination_alpha = destination_color.a;
        if (mode == .plus_lighter) {
            const output_alpha = @min(1, source_alpha + destination_alpha);
            const red = @min(1, source_color.r * source_alpha + destination_color.r * destination_alpha);
            const green = @min(1, source_color.g * source_alpha + destination_color.g * destination_alpha);
            const blue = @min(1, source_color.b * source_alpha + destination_color.b * destination_alpha);
            writeByteColor(destination, offset, .{
                .r = if (output_alpha == 0) 0 else red / output_alpha,
                .g = if (output_alpha == 0) 0 else green / output_alpha,
                .b = if (output_alpha == 0) 0 else blue / output_alpha,
                .a = output_alpha,
            });
            continue;
        }
        const blended: geometry.Color = .{
            .r = blendChannel(mode, destination_color.r, source_color.r),
            .g = blendChannel(mode, destination_color.g, source_color.g),
            .b = blendChannel(mode, destination_color.b, source_color.b),
            .a = source_alpha,
        };
        const output_alpha = source_alpha + destination_alpha - source_alpha * destination_alpha;
        const source_only = source_alpha * (1 - destination_alpha);
        const destination_only = destination_alpha * (1 - source_alpha);
        const overlap = source_alpha * destination_alpha;
        writeByteColor(destination, offset, .{
            .r = if (output_alpha == 0) 0 else (source_color.r * source_only + destination_color.r * destination_only + blended.r * overlap) / output_alpha,
            .g = if (output_alpha == 0) 0 else (source_color.g * source_only + destination_color.g * destination_only + blended.g * overlap) / output_alpha,
            .b = if (output_alpha == 0) 0 else (source_color.b * source_only + destination_color.b * destination_only + blended.b * overlap) / output_alpha,
            .a = output_alpha,
        });
    }
}

fn blendChannel(mode: scene_abi.BlendMode, backdrop: f32, source: f32) f32 {
    return switch (mode) {
        .normal => source,
        .multiply => backdrop * source,
        .screen => backdrop + source - backdrop * source,
        .overlay => if (backdrop <= 0.5) 2 * backdrop * source else 1 - 2 * (1 - backdrop) * (1 - source),
        .plus_lighter => unreachable,
    };
}

fn byteColor(bytes: []const u8, offset: usize) geometry.Color {
    return .{
        .r = @as(f32, @floatFromInt(bytes[offset])) / 255,
        .g = @as(f32, @floatFromInt(bytes[offset + 1])) / 255,
        .b = @as(f32, @floatFromInt(bytes[offset + 2])) / 255,
        .a = @as(f32, @floatFromInt(bytes[offset + 3])) / 255,
    };
}

fn writeByteColor(bytes: []u8, offset: usize, color: geometry.Color) void {
    bytes[offset] = toByte(color.r);
    bytes[offset + 1] = toByte(color.g);
    bytes[offset + 2] = toByte(color.b);
    bytes[offset + 3] = toByte(color.a);
}

fn paintQuad(
    view: api.SceneView,
    target: api.OffscreenTarget,
    pixels: []u8,
    stride: usize,
    quad: scene_abi.Quad,
    transform: geometry.Affine2D,
    clip: *const ClipChain,
    material_index: u32,
    opacity: f32,
) void {
    if (quad.bounds.isEmpty()) return;
    const inverse = transform.inverse() orelse return;
    const world_bounds = transform.transformRectBounds(quad.bounds);
    const clipped = geometry.Rect.intersection(world_bounds, clip.bounds) orelse return;
    const device = pixelBounds(target, clipped) orelse return;
    const scale = target.scale_factor.value;
    const has_border = quad.border_widths.top > 0 or quad.border_widths.right > 0 or
        quad.border_widths.bottom > 0 or quad.border_widths.left > 0;
    const inner = quad.bounds.inset(quad.border_widths);
    const inner_radii: geometry.CornerRadii = .{
        .top_left = @max(0, quad.radii.top_left - @max(quad.border_widths.left, quad.border_widths.top)),
        .top_right = @max(0, quad.radii.top_right - @max(quad.border_widths.right, quad.border_widths.top)),
        .bottom_right = @max(0, quad.radii.bottom_right - @max(quad.border_widths.right, quad.border_widths.bottom)),
        .bottom_left = @max(0, quad.radii.bottom_left - @max(quad.border_widths.left, quad.border_widths.bottom)),
    };
    var y = device.top;
    while (y < device.bottom) : (y += 1) {
        var x = device.left;
        while (x < device.right) : (x += 1) {
            const world_point: geometry.Point = .{
                .x = (@as(f32, @floatFromInt(x)) + 0.5) / scale,
                .y = (@as(f32, @floatFromInt(y)) + 0.5) / scale,
            };
            const clip_coverage = clip.coverage(world_point);
            if (clip_coverage <= 0) continue;
            const local_point = inverse.transformPoint(world_point);
            const outer_coverage = roundedCoverage(quad.bounds, quad.radii, local_point);
            if (outer_coverage <= 0) continue;
            const offset = @as(usize, y) * stride + @as(usize, x) * 4;
            if (has_border) {
                var border = quad.border_color;
                border.a *= opacity * clip_coverage * outer_coverage;
                if (border.a > 0) blendPixel(pixels, offset, target.format, border);
                if (!inner.isEmpty()) {
                    const inner_coverage = roundedCoverage(inner, inner_radii, local_point);
                    if (inner_coverage > 0) {
                        var fill = materialColor(view, material_index, local_point, quad.background);
                        fill.a *= opacity * clip_coverage * inner_coverage;
                        if (fill.a > 0) blendPixel(pixels, offset, target.format, fill);
                    }
                }
            } else {
                var fill = materialColor(view, material_index, local_point, quad.background);
                fill.a *= opacity * clip_coverage * outer_coverage;
                if (fill.a > 0) blendPixel(pixels, offset, target.format, fill);
            }
        }
    }
}

fn paintBackdropEffect(
    target: api.OffscreenTarget,
    pixels: []u8,
    stride: usize,
    effect: scene_abi.BackdropEffect,
    transform: geometry.Affine2D,
    clip: *const ClipChain,
    allocator: std.mem.Allocator,
) Error!void {
    if (effect.bounds.isEmpty()) return;
    const inverse = transform.inverse() orelse return;
    const world_bounds = transform.transformRectBounds(effect.bounds);
    const output_bounds = geometry.Rect.intersection(world_bounds, clip.bounds) orelse return;
    const output = pixelBounds(target, output_bounds) orelse return;
    const capture_bounds = pixelBounds(target, expandRect(world_bounds, effect.blur_radius * 2)) orelse return;
    const capture_width = capture_bounds.right - capture_bounds.left;
    const capture_height = capture_bounds.bottom - capture_bounds.top;
    const capture_stride = std.math.mul(usize, capture_width, 4) catch return error.BudgetExceeded;
    const capture_length = std.math.mul(usize, capture_stride, capture_height) catch return error.BudgetExceeded;
    const snapshot = try allocator.alloc(u8, capture_length);
    defer allocator.free(snapshot);

    for (0..capture_height) |row| {
        const source_start = (@as(usize, capture_bounds.top) + row) * stride + @as(usize, capture_bounds.left) * 4;
        @memcpy(snapshot[row * capture_stride ..][0..capture_stride], pixels[source_start..][0..capture_stride]);
    }

    const scale = target.scale_factor.value;
    const blur_radius: u32 = @intFromFloat(@ceil(effect.blur_radius * scale));
    var y = output.top;
    while (y < output.bottom) : (y += 1) {
        var x = output.left;
        while (x < output.right) : (x += 1) {
            const world_point: geometry.Point = .{
                .x = (@as(f32, @floatFromInt(x)) + 0.5) / scale,
                .y = (@as(f32, @floatFromInt(y)) + 0.5) / scale,
            };
            const local_point = inverse.transformPoint(world_point);
            const shape_coverage = roundedCoverage(effect.bounds, effect.radii, local_point);
            if (shape_coverage <= 0) continue;
            const coverage = shape_coverage * clip.coverage(world_point) * effect.opacity;
            if (coverage <= 0) continue;
            const filtered = saturateBackdrop(
                blurBackdrop(snapshot, capture_stride, capture_bounds, x, y, blur_radius),
                effect.saturation,
            );
            const offset = @as(usize, y) * stride + @as(usize, x) * 4;
            const original = byteColor(pixels, offset);
            writeByteColor(pixels, offset, mixBackdrop(original, filtered, coverage));
        }
    }
}

fn blurBackdrop(
    snapshot: []const u8,
    stride: usize,
    bounds: PixelBounds,
    x: u32,
    y: u32,
    radius: u32,
) geometry.Color {
    if (radius == 0) return snapshotColor(snapshot, stride, bounds, @intCast(x), @intCast(y));
    const near: i64 = @max(@as(i64, 1), @as(i64, @intFromFloat(@round(@as(f32, @floatFromInt(radius)) * 0.5))));
    const far: i64 = @max(near, @as(i64, radius));
    const diagonal: i64 = @max(@as(i64, 1), @as(i64, @intFromFloat(@round(@as(f32, @floatFromInt(radius)) * 0.7071))));
    var result: geometry.Color = .{ .a = 0 };
    addPremultiplied(&result, snapshotColor(snapshot, stride, bounds, @intCast(x), @intCast(y)), 0.3125);
    for ([_][2]i64{ .{ -near, 0 }, .{ near, 0 }, .{ 0, -near }, .{ 0, near } }) |offset|
        addPremultiplied(&result, snapshotColor(snapshot, stride, bounds, @as(i64, x) + offset[0], @as(i64, y) + offset[1]), 0.125);
    for ([_][2]i64{ .{ -far, 0 }, .{ far, 0 }, .{ 0, -far }, .{ 0, far } }) |offset|
        addPremultiplied(&result, snapshotColor(snapshot, stride, bounds, @as(i64, x) + offset[0], @as(i64, y) + offset[1]), 0.03125);
    for ([_][2]i64{ .{ -diagonal, -diagonal }, .{ diagonal, -diagonal }, .{ -diagonal, diagonal }, .{ diagonal, diagonal } }) |offset|
        addPremultiplied(&result, snapshotColor(snapshot, stride, bounds, @as(i64, x) + offset[0], @as(i64, y) + offset[1]), 0.015625);
    if (result.a <= 0) return .transparent;
    return .{
        .r = result.r / result.a,
        .g = result.g / result.a,
        .b = result.b / result.a,
        .a = result.a,
    };
}

fn addPremultiplied(result: *geometry.Color, sample: geometry.Color, weight: f32) void {
    const weighted_alpha = sample.a * weight;
    result.r += sample.r * weighted_alpha;
    result.g += sample.g * weighted_alpha;
    result.b += sample.b * weighted_alpha;
    result.a += weighted_alpha;
}

fn snapshotColor(snapshot: []const u8, stride: usize, bounds: PixelBounds, x: i64, y: i64) geometry.Color {
    const clamped_x = std.math.clamp(x, @as(i64, bounds.left), @as(i64, bounds.right) - 1);
    const clamped_y = std.math.clamp(y, @as(i64, bounds.top), @as(i64, bounds.bottom) - 1);
    const offset = @as(usize, @intCast(clamped_y - bounds.top)) * stride + @as(usize, @intCast(clamped_x - bounds.left)) * 4;
    return byteColor(snapshot, offset);
}

fn saturateBackdrop(color: geometry.Color, saturation: f32) geometry.Color {
    const luminance = color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722;
    return .{
        .r = luminance + (color.r - luminance) * saturation,
        .g = luminance + (color.g - luminance) * saturation,
        .b = luminance + (color.b - luminance) * saturation,
        .a = color.a,
    };
}

fn mixBackdrop(original: geometry.Color, filtered: geometry.Color, amount: f32) geometry.Color {
    const t = std.math.clamp(amount, 0, 1);
    const original_alpha = original.a;
    const filtered_alpha = filtered.a;
    const alpha = original_alpha + (filtered_alpha - original_alpha) * t;
    if (alpha <= 0) return .transparent;
    return .{
        .r = (original.r * original_alpha + (filtered.r * filtered_alpha - original.r * original_alpha) * t) / alpha,
        .g = (original.g * original_alpha + (filtered.g * filtered_alpha - original.g * original_alpha) * t) / alpha,
        .b = (original.b * original_alpha + (filtered.b * filtered_alpha - original.b * original_alpha) * t) / alpha,
        .a = alpha,
    };
}

fn paintUnderline(
    target: api.OffscreenTarget,
    pixels: []u8,
    stride: usize,
    underline: scene_abi.Underline,
    transform: geometry.Affine2D,
    clip: *const ClipChain,
    opacity: f32,
) void {
    if (underline.bounds.isEmpty()) return;
    const inverse = transform.inverse() orelse return;
    const world_bounds = transform.transformRectBounds(underline.bounds);
    const clipped = geometry.Rect.intersection(world_bounds, clip.bounds) orelse return;
    const device = pixelBounds(target, clipped) orelse return;
    const scale = target.scale_factor.value;
    var color = underline.color;
    var y = device.top;
    while (y < device.bottom) : (y += 1) {
        var x = device.left;
        while (x < device.right) : (x += 1) {
            const world_point: geometry.Point = .{
                .x = (@as(f32, @floatFromInt(x)) + 0.5) / scale,
                .y = (@as(f32, @floatFromInt(y)) + 0.5) / scale,
            };
            const local_point = inverse.transformPoint(world_point);
            if (!underline.bounds.contains(local_point)) continue;
            const center = underline.bounds.origin.y + underline.bounds.size.height * 0.5 + if (underline.wave_amplitude != 0 and underline.wave_period > 0)
                @sin((local_point.x - underline.bounds.origin.x) * (2 * std.math.pi / underline.wave_period)) * underline.wave_amplitude
            else
                0;
            const coverage = 1 - smoothstep(
                underline.thickness * 0.5 - 0.5,
                underline.thickness * 0.5 + 0.5,
                @abs(local_point.y - center),
            );
            const clip_coverage = clip.coverage(world_point);
            color.a = underline.color.a * opacity * coverage * clip_coverage;
            if (color.a <= 0) continue;
            blendPixel(pixels, @as(usize, y) * stride + @as(usize, x) * 4, target.format, color);
        }
    }
}

fn paintTriangles(
    view: api.SceneView,
    target: api.OffscreenTarget,
    pixels: []u8,
    stride: usize,
    vertices: []const path_tessellator.Vertex,
    transform: geometry.Affine2D,
    clip: *const ClipChain,
    material_index: u32,
    opacity: f32,
) Error!void {
    if (vertices.len % 3 != 0) return error.InvalidScene;
    const inverse = transform.inverse() orelse return;
    var triangle: usize = 0;
    while (triangle < vertices.len) : (triangle += 3) {
        const a = transform.transformPoint(vertices[triangle].position);
        const b = transform.transformPoint(vertices[triangle + 1].position);
        const c = transform.transformPoint(vertices[triangle + 2].position);
        const world_bounds = geometry.Rect.fromXYWH(
            @min(a.x, @min(b.x, c.x)),
            @min(a.y, @min(b.y, c.y)),
            @max(a.x, @max(b.x, c.x)) - @min(a.x, @min(b.x, c.x)),
            @max(a.y, @max(b.y, c.y)) - @min(a.y, @min(b.y, c.y)),
        );
        const bounds = geometry.Rect.intersection(world_bounds, clip.bounds) orelse continue;
        const device = pixelBounds(target, bounds) orelse continue;
        const scale = target.scale_factor.value;
        const area = edge(a, b, c);
        if (@abs(area) <= 0.000001) continue;
        var y = device.top;
        while (y < device.bottom) : (y += 1) {
            var x = device.left;
            while (x < device.right) : (x += 1) {
                const point: geometry.Point = .{
                    .x = (@as(f32, @floatFromInt(x)) + 0.5) / scale,
                    .y = (@as(f32, @floatFromInt(y)) + 0.5) / scale,
                };
                const clip_coverage = clip.coverage(point);
                if (clip_coverage <= 0) continue;
                const first = edge(b, c, point) / area;
                const second = edge(c, a, point) / area;
                const third = 1 - first - second;
                if (first < -0.00001 or second < -0.00001 or third < -0.00001) continue;
                const ca = vertices[triangle].color;
                const cb = vertices[triangle + 1].color;
                const cc = vertices[triangle + 2].color;
                const fallback: geometry.Color = .{
                    .r = ca.r * first + cb.r * second + cc.r * third,
                    .g = ca.g * first + cb.g * second + cc.g * third,
                    .b = ca.b * first + cb.b * second + cc.b * third,
                    .a = ca.a * first + cb.a * second + cc.a * third,
                };
                var color = materialColor(view, material_index, inverse.transformPoint(point), fallback);
                color.a *= opacity * clip_coverage;
                color.r = std.math.clamp(color.r, 0, 1);
                color.g = std.math.clamp(color.g, 0, 1);
                color.b = std.math.clamp(color.b, 0, 1);
                blendPixel(pixels, @as(usize, y) * stride + @as(usize, x) * 4, target.format, color);
            }
        }
    }
}

fn edge(a: geometry.Point, b: geometry.Point, point: geometry.Point) f32 {
    return (point.x - a.x) * (b.y - a.y) - (point.y - a.y) * (b.x - a.x);
}

fn paintSprite(
    renderer: *NullRenderer,
    target: api.OffscreenTarget,
    output: []u8,
    output_stride: usize,
    sprite: scene_abi.Sprite,
    transform: geometry.Affine2D,
    clip: *const ClipChain,
    opacity: f32,
    monochrome: bool,
) void {
    const texture = renderer.textures.get(sprite.texture) orelse return;
    const inverse = transform.inverse() orelse return;
    const world_bounds = transform.transformRectBounds(sprite.bounds);
    const bounds = geometry.Rect.intersection(world_bounds, clip.bounds) orelse return;
    const device = pixelBounds(target, bounds) orelse return;
    const scale = target.scale_factor.value;
    var y = device.top;
    while (y < device.bottom) : (y += 1) {
        var x = device.left;
        while (x < device.right) : (x += 1) {
            const world_point: geometry.Point = .{
                .x = (@as(f32, @floatFromInt(x)) + 0.5) / scale,
                .y = (@as(f32, @floatFromInt(y)) + 0.5) / scale,
            };
            const clip_coverage = clip.coverage(world_point);
            if (clip_coverage <= 0) continue;
            const local_point = inverse.transformPoint(world_point);
            if (!sprite.bounds.contains(local_point)) continue;
            const u = std.math.clamp((local_point.x - sprite.bounds.origin.x) / @max(sprite.bounds.size.width, 0.00001), 0, 1);
            const v = std.math.clamp((local_point.y - sprite.bounds.origin.y) / @max(sprite.bounds.size.height, 0.00001), 0, 1);
            const uv_x = sprite.uv_bounds.origin.x + u * sprite.uv_bounds.size.width;
            const uv_y = sprite.uv_bounds.origin.y + v * sprite.uv_bounds.size.height;
            var sampled = sampleTexture(texture, uv_x, uv_y);
            if (!monochrome and sprite.effect != .none) {
                var t: f32 = if (sprite.effect == .preview_blur) 1 else std.math.clamp((v * sprite.bounds.size.height - (sprite.bounds.size.height - sprite.effect_height)) / sprite.effect_height, 0, 1);
                t = t * t * (3 - 2 * t);
                const dx = sprite.uv_bounds.size.width / @max(sprite.bounds.size.width, 0.001) * sprite.effect_radius * t;
                const dy = sprite.uv_bounds.size.height / @max(sprite.bounds.size.height, 0.001) * sprite.effect_radius * t;
                const low_x = sprite.uv_bounds.minX();
                const high_x = sprite.uv_bounds.maxX();
                const low_y = sprite.uv_bounds.minY();
                const high_y = sprite.uv_bounds.maxY();
                const taps = [_]geometry.Color{
                    sampleTexture(texture, std.math.clamp(uv_x + dx, low_x, high_x), uv_y),
                    sampleTexture(texture, std.math.clamp(uv_x - dx, low_x, high_x), uv_y),
                    sampleTexture(texture, uv_x, std.math.clamp(uv_y + dy, low_y, high_y)),
                    sampleTexture(texture, uv_x, std.math.clamp(uv_y - dy, low_y, high_y)),
                };
                var blurred: geometry.Color = .{ .r = sampled.r * 0.4, .g = sampled.g * 0.4, .b = sampled.b * 0.4, .a = sampled.a * 0.4 };
                for (taps) |tap| {
                    blurred.r += tap.r * 0.15;
                    blurred.g += tap.g * 0.15;
                    blurred.b += tap.b * 0.15;
                    blurred.a += tap.a * 0.15;
                }
                const luminance = blurred.r * 0.2126 + blurred.g * 0.7152 + blurred.b * 0.0722;
                if (sprite.effect == .light_text) {
                    const strength = @min(1, 0.22 / @max(luminance, 0.001));
                    blurred.r *= strength;
                    blurred.g *= strength;
                    blurred.b *= strength;
                } else if (sprite.effect == .dark_text) {
                    const strength = std.math.clamp((0.72 - luminance) / @max(1 - luminance, 0.001), 0, 1);
                    blurred.r += (1 - blurred.r) * strength;
                    blurred.g += (1 - blurred.g) * strength;
                    blurred.b += (1 - blurred.b) * strength;
                }
                sampled = blurred;
                if (sprite.effect != .preview_blur) sampled.a *= t;
            }
            var color = sprite.color;
            if (monochrome or texture.descriptor.format == .a8) {
                color.a *= sampled.a;
            } else {
                color.r *= sampled.r;
                color.g *= sampled.g;
                color.b *= sampled.b;
                color.a *= sampled.a;
            }
            color.a *= opacity * clip_coverage;
            blendPixel(output, @as(usize, y) * output_stride + @as(usize, x) * 4, target.format, color);
        }
    }
}

fn sampleTexture(texture: NullRenderer.Texture, u: f32, v: f32) geometry.Color {
    if (texture.descriptor.width == 0 or texture.descriptor.height == 0) return .transparent;
    if (!std.math.isFinite(u) or !std.math.isFinite(v)) return .transparent;
    const width_f: f32 = @floatFromInt(texture.descriptor.width);
    const height_f: f32 = @floatFromInt(texture.descriptor.height);
    const source_x = @as(f64, std.math.clamp(u, 0, 1) * width_f - 0.5);
    const source_y = @as(f64, std.math.clamp(v, 0, 1) * height_f - 0.5);
    const floor_x = @floor(source_x);
    const floor_y = @floor(source_y);
    const raw_x: i64 = @intFromFloat(floor_x);
    const raw_y: i64 = @intFromFloat(floor_y);
    const x0 = clampedTexel(raw_x, texture.descriptor.width);
    const y0 = clampedTexel(raw_y, texture.descriptor.height);
    const x1 = clampedTexel(raw_x + 1, texture.descriptor.width);
    const y1 = clampedTexel(raw_y + 1, texture.descriptor.height);
    const amount_x: f32 = @floatCast(source_x - floor_x);
    const amount_y: f32 = @floatCast(source_y - floor_y);
    const bpp = bytesPerPixel(texture.descriptor.format);
    const source_stride = @as(usize, texture.descriptor.width) * bpp;
    const top_left = textureSample(texture, y0 * source_stride + x0 * bpp);
    const top_right = textureSample(texture, y0 * source_stride + x1 * bpp);
    const bottom_left = textureSample(texture, y1 * source_stride + x0 * bpp);
    const bottom_right = textureSample(texture, y1 * source_stride + x1 * bpp);
    return mix(mix(top_left, top_right, amount_x), mix(bottom_left, bottom_right, amount_x), amount_y);
}

fn clampedTexel(value: i64, length: u32) usize {
    if (value <= 0) return 0;
    const maximum = @as(i64, length) - 1;
    return @intCast(@min(value, maximum));
}

fn textureSample(texture: NullRenderer.Texture, offset: usize) geometry.Color {
    return switch (texture.descriptor.format) {
        .a8 => .{ .r = 1, .g = 1, .b = 1, .a = @as(f32, @floatFromInt(texture.pixels[offset])) / 255 },
        .rgba8, .rgba8_srgb => .{
            .r = textureChannel(texture.pixels[offset], texture.descriptor.format == .rgba8_srgb),
            .g = textureChannel(texture.pixels[offset + 1], texture.descriptor.format == .rgba8_srgb),
            .b = textureChannel(texture.pixels[offset + 2], texture.descriptor.format == .rgba8_srgb),
            .a = @as(f32, @floatFromInt(texture.pixels[offset + 3])) / 255,
        },
        .bgra8, .bgra8_srgb => .{
            .r = textureChannel(texture.pixels[offset + 2], texture.descriptor.format == .bgra8_srgb),
            .g = textureChannel(texture.pixels[offset + 1], texture.descriptor.format == .bgra8_srgb),
            .b = textureChannel(texture.pixels[offset], texture.descriptor.format == .bgra8_srgb),
            .a = @as(f32, @floatFromInt(texture.pixels[offset + 3])) / 255,
        },
        .rgba16_float => .{
            .r = readHalf(texture.pixels[offset..][0..2]),
            .g = readHalf(texture.pixels[offset + 2 ..][0..2]),
            .b = readHalf(texture.pixels[offset + 4 ..][0..2]),
            .a = readHalf(texture.pixels[offset + 6 ..][0..2]),
        },
    };
}

fn readHalf(bytes: *const [2]u8) f32 {
    const bits = std.mem.readInt(u16, bytes, .little);
    return @floatCast(@as(f16, @bitCast(bits)));
}

fn paintShadow(
    target: api.OffscreenTarget,
    pixels: []u8,
    stride: usize,
    shadow: scene_abi.Shadow,
    transform: geometry.Affine2D,
    clip: *const ClipChain,
    opacity: f32,
) void {
    const base = geometry.Rect.fromXYWH(
        shadow.bounds.origin.x + shadow.offset.x - shadow.spread,
        shadow.bounds.origin.y + shadow.offset.y - shadow.spread,
        @max(0, shadow.bounds.size.width + shadow.spread * 2),
        @max(0, shadow.bounds.size.height + shadow.spread * 2),
    );
    if (base.isEmpty() or shadow.color.a <= 0) return;
    const radii = addRadius(shadow.radii, shadow.spread);
    const blur_extent = if (shadow.blur_radius <= 0.001) 0 else shadow.blur_radius * 2;
    const raster_bounds = expandRect(base, blur_extent);
    const inverse = transform.inverse() orelse return;
    const world_bounds = transform.transformRectBounds(raster_bounds);
    const clipped = geometry.Rect.intersection(world_bounds, clip.bounds) orelse return;
    const device = pixelBounds(target, clipped) orelse return;
    const scale = target.scale_factor.value;
    const sigma = @max(shadow.blur_radius * 0.5, 0.5);
    var y = device.top;
    while (y < device.bottom) : (y += 1) {
        var x = device.left;
        while (x < device.right) : (x += 1) {
            const world_point: geometry.Point = .{
                .x = (@as(f32, @floatFromInt(x)) + 0.5) / scale,
                .y = (@as(f32, @floatFromInt(y)) + 0.5) / scale,
            };
            const local_point = inverse.transformPoint(world_point);
            if (!raster_bounds.contains(local_point)) continue;
            const distance = roundedDistance(base, radii, local_point);
            const coverage = if (shadow.blur_radius <= 0.001)
                1 - smoothstep(-0.75, 0.75, distance)
            else blk: {
                const outside = @max(distance, 0);
                break :blk @exp(-0.5 * outside * outside / (sigma * sigma));
            };
            const clip_coverage = clip.coverage(world_point);
            if (coverage <= 0 or clip_coverage <= 0) continue;
            var color = shadow.color;
            color.a *= opacity * coverage * clip_coverage;
            blendPixel(pixels, @as(usize, y) * stride + @as(usize, x) * 4, target.format, color);
        }
    }
}

fn materialColor(view: api.SceneView, index: u32, point: geometry.Point, fallback: geometry.Color) geometry.Color {
    if (index == scene.none_index or index >= view.materials.len) return fallback;
    const material = view.materials[index];
    const kind = std.enums.fromInt(scene_abi.MaterialKind, material.kind) orelse return fallback;
    return switch (kind) {
        .none => fallback,
        .solid => material.color,
        .linear_gradient => gradientColor(view, material, point),
        .radial_gradient => radialGradientColor(view, material, point),
    };
}

fn radialGradientColor(view: api.SceneView, material: scene_abi.Material, point: geometry.Point) geometry.Color {
    const local = material.gradient_transform.transformPoint(point);
    const scalar = radialParameter(local, material.start, material.color.r, material.end, material.color.g) orelse return .transparent;
    return colorAtStops(view, material, scalar);
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

fn colorAtStops(view: api.SceneView, material: scene_abi.Material, scalar: f32) geometry.Color {
    if (material.stop_count == 0) return .transparent;
    const projection = std.math.clamp(scalar, 0, 1);
    const stops = view.gradient_stops[material.stop_start..][0..material.stop_count];
    if (projection <= stops[0].offset) return stops[0].color;
    var index: usize = 1;
    while (index < stops.len) : (index += 1) {
        if (projection > stops[index].offset) continue;
        const previous = stops[index - 1];
        const next = stops[index];
        const span = @max(0.000001, next.offset - previous.offset);
        return mix(previous.color, next.color, (projection - previous.offset) / span);
    }
    return stops[stops.len - 1].color;
}

fn gradientColor(view: api.SceneView, material: scene_abi.Material, point: geometry.Point) geometry.Color {
    if (material.stop_count == 0) return .transparent;
    const delta = material.end.sub(material.start);
    const length_squared = delta.x * delta.x + delta.y * delta.y;
    const projection = if (length_squared <= 0.000001) 0 else std.math.clamp(((point.x - material.start.x) * delta.x + (point.y - material.start.y) * delta.y) / length_squared, 0, 1);
    return colorAtStops(view, material, projection);
}

fn layerTransform(view: api.SceneView, index: u32) Error!geometry.Affine2D {
    if (index == scene.none_index) return .identity;
    var chain: [64]u32 = undefined;
    var count: usize = 0;
    var cursor = index;
    while (cursor != scene.none_index) {
        if (cursor >= view.layers.len or count >= chain.len) return error.InvalidScene;
        chain[count] = cursor;
        count += 1;
        cursor = view.layers[cursor].parent;
    }
    var result: geometry.Affine2D = .identity;
    while (count != 0) {
        count -= 1;
        result = geometry.Affine2D.mul(result, view.layers[chain[count]].transform);
    }
    return result;
}

fn roundedCoverage(rect: geometry.Rect, radii: geometry.CornerRadii, point: geometry.Point) f32 {
    return 1 - smoothstep(-0.75, 0.75, roundedDistance(rect, radii, point));
}

fn roundedDistance(rect: geometry.Rect, radii: geometry.CornerRadii, point: geometry.Point) f32 {
    const center: geometry.Point = .{
        .x = rect.origin.x + rect.size.width * 0.5,
        .y = rect.origin.y + rect.size.height * 0.5,
    };
    const maximum_radius = @max(0, @min(rect.size.width, rect.size.height) * 0.5);
    const radius = std.math.clamp(if (point.y < center.y)
        (if (point.x < center.x) radii.top_left else radii.top_right)
    else
        (if (point.x < center.x) radii.bottom_left else radii.bottom_right), 0, maximum_radius);
    const half_width = rect.size.width * 0.5;
    const half_height = rect.size.height * 0.5;
    const qx = @abs(point.x - center.x) - half_width + radius;
    const qy = @abs(point.y - center.y) - half_height + radius;
    const outside_x = @max(qx, 0);
    const outside_y = @max(qy, 0);
    return @sqrt(outside_x * outside_x + outside_y * outside_y) + @min(@max(qx, qy), 0) - radius;
}

fn smoothstep(lower: f32, upper: f32, value: f32) f32 {
    if (upper <= lower) return if (value < lower) 0 else 1;
    const t = std.math.clamp((value - lower) / (upper - lower), 0, 1);
    return t * t * (3 - 2 * t);
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
    return geometry.Rect.fromXYWH(
        rect.origin.x - amount,
        rect.origin.y - amount,
        rect.size.width + amount * 2,
        rect.size.height + amount * 2,
    );
}

fn blendPixel(pixels: []u8, offset: usize, format: api.PixelFormat, source: geometry.Color) void {
    const source_alpha = std.math.clamp(source.a, 0, 1);
    const destination_alpha = @as(f32, @floatFromInt(pixels[offset + 3])) / 255.0;
    const rgba_order = format == .rgba8 or format == .rgba8_srgb;
    const destination_r_index: usize = if (rgba_order) 0 else 2;
    const destination_b_index: usize = if (rgba_order) 2 else 0;
    const destination_r = @as(f32, @floatFromInt(pixels[offset + destination_r_index])) / 255.0;
    const destination_g = @as(f32, @floatFromInt(pixels[offset + 1])) / 255.0;
    const destination_b = @as(f32, @floatFromInt(pixels[offset + destination_b_index])) / 255.0;
    const out_alpha = source_alpha + destination_alpha * (1 - source_alpha);
    const divisor = @max(out_alpha, 0.000001);
    const out_r = (source.r * source_alpha + destination_r * destination_alpha * (1 - source_alpha)) / divisor;
    const out_g = (source.g * source_alpha + destination_g * destination_alpha * (1 - source_alpha)) / divisor;
    const out_b = (source.b * source_alpha + destination_b * destination_alpha * (1 - source_alpha)) / divisor;
    pixels[offset + destination_r_index] = toByte(out_r);
    pixels[offset + 1] = toByte(out_g);
    pixels[offset + destination_b_index] = toByte(out_b);
    pixels[offset + 3] = toByte(out_alpha);
}

fn toByte(value: f32) u8 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

fn textureChannel(value: u8, srgb: bool) f32 {
    const normalized = @as(f32, @floatFromInt(value)) / 255;
    return if (!srgb or normalized <= 0.04045) (if (srgb) normalized / 12.92 else normalized) else std.math.pow(f32, (normalized + 0.055) / 1.055, 2.4);
}

fn linearByteToSrgb(value: u8) u8 {
    const linear = @as(f32, @floatFromInt(value)) / 255;
    const encoded = if (linear <= 0.0031308) linear * 12.92 else 1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(encoded, 0, 1) * 255));
}

fn mix(a: geometry.Color, b: geometry.Color, amount: f32) geometry.Color {
    const t = std.math.clamp(amount, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
    };
}

fn bytesPerPixel(format: api.PixelFormat) usize {
    return switch (format) {
        .a8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba16_float => 8,
    };
}
