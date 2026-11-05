const std = @import("std");
const config = @import("../../config.zig");
const Error = @import("../../core/error.zig").Error;
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const api = @import("../../render/api.zig");
const extension = @import("../../render/extension.zig");
const layer_plan = @import("../../render/layer_plan.zig");
const scene = @import("../../scene/scene.zig");
const scene_abi = @import("../../scene/abi.zig");
const path_tessellator = @import("../../render/path_tessellator.zig");
const objc = @import("../../platform/macos/objc.zig");
const surface = @import("../../platform/macos/surface.zig");
const Acquisition = @import("drawable.zig").Acquisition;

extern "c" fn MTLCreateSystemDefaultDevice() objc.Id;
extern "c" fn dispatch_data_create(buffer: *const anyopaque, size: usize, queue: objc.Id, destructor: objc.Id) objc.Id;
extern "c" fn dispatch_release(object: objc.Id) void;

const ClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
const Size = extern struct { width: f64, height: f64 };
const Origin = extern struct { x: usize, y: usize, z: usize };
const Extent = extern struct { width: usize, height: usize, depth: usize };
const Region = extern struct { origin: Origin, size: Extent };
const ScissorRect = extern struct { x: usize, y: usize, width: usize, height: usize };

const Globals = extern struct {
    viewport: [2]f32,
    viewport_origin: [2]f32,
    transform: geometry.Affine2D,
    material_index: u32,
    clip_index: u32,
    opacity: f32,
    blend_mode: u32,
    pad: [2]u32 = .{ 0, 0 },
};

const Composite = extern struct {
    bounds: geometry.Rect,
    opacity: f32,
    reserved: [3]f32 = .{ 0, 0, 0 },
};

const BackdropComposite = extern struct {
    bounds: geometry.Rect,
    radii: geometry.CornerRadii,
    capture_origin: geometry.Point,
    capture_size: geometry.Size,
    blur_radius: f32,
    saturation: f32,
    opacity: f32 = 1,
};

comptime {
    std.debug.assert(@sizeOf(BackdropComposite) == 60);
}

const ResolvedClip = extern struct {
    bounds: geometry.Rect,
    radii: geometry.CornerRadii,
    parent: u32,
    reserved: [3]u32 = .{ 0, 0, 0 },
    inverse_transform: geometry.Affine2D,
};

const ActiveFrame = struct {
    token: api.FrameToken,
    descriptor: api.FrameDescriptor,
    drawable: objc.Id,
    slot: usize,
};

const InFlight = struct {
    epoch: api.SubmissionEpoch,
    command_buffer: objc.Id,
    slot: usize,
};

const AsyncOffscreenRequest = struct {
    id: api.OffscreenRequestId,
    target: api.OffscreenTarget,
    snapshot: api.SceneSnapshot,
    /// Async submissions own their transient upload and layer resources so
    /// they cannot consume the presentation frame slots or stall a window.
    frame: FrameResources,
    command_buffer: objc.Id,
    texture: objc.Id,
    read_buffer: objc.Id,
    gpu_stride: usize,
    /// Retains every texture/surface referenced by the copied scene until the
    /// command buffer has reached a terminal state. The application may drop
    /// its resource handle immediately after beginOffscreen returns.
    retained_resources: std.ArrayList(objc.Id) = .empty,
    cancelled: bool = false,
};

const RetiredTexture = struct {
    texture: objc.Id,
    release_after: api.SubmissionEpoch,
};

const DrawSelection = struct { payload: objc.Id, pipeline: objc.Id, stride: usize };
const PathDraw = struct { start: u32 = 0, count: u32 = 0 };

const LayerTarget = struct {
    texture: objc.Id = null,
    width: u32 = 0,
    height: u32 = 0,
    pixel_format: usize = 0,

    fn deinit(self: *LayerTarget) void {
        release(self.texture);
        self.* = .{};
    }
};

const UploadBuffer = struct {
    handle: objc.Id = null,
    capacity: usize = 0,

    fn upload(self: *UploadBuffer, device: objc.Id, bytes: []const u8) Error!objc.Id {
        if (bytes.len == 0) return null;
        if (bytes.len > self.capacity) {
            var capacity: usize = @max(self.capacity, 4096);
            while (capacity < bytes.len) capacity = std.math.mul(usize, capacity, 2) catch return error.BudgetExceeded;
            const replacement = objc.send(objc.Id, device, "newBufferWithLength:options:", .{ capacity, @as(usize, 0) }) orelse return error.BudgetExceeded;
            release(self.handle);
            self.handle = replacement;
            self.capacity = capacity;
        }
        const destination = objc.send(?*anyopaque, self.handle, "contents", .{}) orelse return error.DeviceLost;
        const destination_bytes: [*]u8 = @ptrCast(destination);
        @memcpy(destination_bytes[0..bytes.len], bytes);
        return self.handle;
    }

    fn deinit(self: *UploadBuffer) void {
        release(self.handle);
        self.* = .{};
    }
};

const FrameResources = struct {
    materials: UploadBuffer = .{},
    stops: UploadBuffer = .{},
    quads: UploadBuffer = .{},
    shadows: UploadBuffer = .{},
    underlines: UploadBuffer = .{},
    monochrome_sprites: UploadBuffer = .{},
    color_sprites: UploadBuffer = .{},
    external_surfaces: UploadBuffer = .{},
    paths: UploadBuffer = .{},
    clips: UploadBuffer = .{},
    layer_targets: std.ArrayList(LayerTarget) = .empty,
    backdrop_targets: std.ArrayList(LayerTarget) = .empty,
    extension_depth_targets: std.ArrayList(LayerTarget) = .empty,
    extension_snapshot_color_targets: std.ArrayList(LayerTarget) = .empty,
    extension_snapshot_depth_targets: std.ArrayList(LayerTarget) = .empty,
    busy_epoch: api.SubmissionEpoch = 0,

    fn acquireLayerTarget(
        self: *FrameResources,
        allocator: std.mem.Allocator,
        device: objc.Id,
        depth: usize,
        width: u32,
        height: u32,
    ) Error!objc.Id {
        return acquireTarget(&self.layer_targets, allocator, device, depth, width, height, 81);
    }

    fn acquireBackdropTarget(
        self: *FrameResources,
        allocator: std.mem.Allocator,
        device: objc.Id,
        depth: usize,
        width: u32,
        height: u32,
    ) Error!objc.Id {
        return acquireTarget(&self.backdrop_targets, allocator, device, depth, width, height, 81);
    }

    fn acquireExtensionDepthTarget(
        self: *FrameResources,
        allocator: std.mem.Allocator,
        device: objc.Id,
        depth: usize,
        width: u32,
        height: u32,
    ) Error!objc.Id {
        return acquireTarget(&self.extension_depth_targets, allocator, device, depth, width, height, 252);
    }

    fn acquireExtensionSnapshotColorTarget(
        self: *FrameResources,
        allocator: std.mem.Allocator,
        device: objc.Id,
        depth: usize,
        width: u32,
        height: u32,
    ) Error!objc.Id {
        return acquireTarget(&self.extension_snapshot_color_targets, allocator, device, depth, width, height, 81);
    }

    fn acquireExtensionSnapshotDepthTarget(
        self: *FrameResources,
        allocator: std.mem.Allocator,
        device: objc.Id,
        depth: usize,
        width: u32,
        height: u32,
    ) Error!objc.Id {
        return acquireTarget(&self.extension_snapshot_depth_targets, allocator, device, depth, width, height, 252);
    }

    fn deinit(self: *FrameResources, allocator: std.mem.Allocator) void {
        self.materials.deinit();
        self.stops.deinit();
        self.quads.deinit();
        self.shadows.deinit();
        self.underlines.deinit();
        self.monochrome_sprites.deinit();
        self.color_sprites.deinit();
        self.external_surfaces.deinit();
        self.paths.deinit();
        self.clips.deinit();
        for (self.layer_targets.items) |*target| target.deinit();
        self.layer_targets.deinit(allocator);
        for (self.backdrop_targets.items) |*target| target.deinit();
        self.backdrop_targets.deinit(allocator);
        for (self.extension_depth_targets.items) |*target| target.deinit();
        self.extension_depth_targets.deinit(allocator);
        for (self.extension_snapshot_color_targets.items) |*target| target.deinit();
        self.extension_snapshot_color_targets.deinit(allocator);
        for (self.extension_snapshot_depth_targets.items) |*target| target.deinit();
        self.extension_snapshot_depth_targets.deinit(allocator);
        self.* = .{};
    }
};

fn acquireTarget(
    targets: *std.ArrayList(LayerTarget),
    allocator: std.mem.Allocator,
    device: objc.Id,
    index: usize,
    width: u32,
    height: u32,
    pixel_format: usize,
) Error!objc.Id {
    if (width == 0 or height == 0) return error.InvalidConfiguration;
    while (targets.items.len <= index) try targets.append(allocator, .{});
    const target = &targets.items[index];
    if (target.texture != null and target.width == width and target.height == height and target.pixel_format == pixel_format) return target.texture;
    const descriptor = objc.send(objc.Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
        pixel_format, @as(usize, width), @as(usize, height), false,
    }) orelse return error.NoGpuDevice;
    objc.send(void, descriptor, "setUsage:", .{@as(usize, 5)});
    objc.send(void, descriptor, "setStorageMode:", .{@as(usize, 2)});
    const replacement = objc.send(objc.Id, device, "newTextureWithDescriptor:", .{descriptor}) orelse return error.BudgetExceeded;
    release(target.texture);
    target.* = .{ .texture = replacement, .width = width, .height = height, .pixel_format = pixel_format };
    return replacement;
}

const Pipelines = struct {
    quad: objc.Id = null,
    shadow: objc.Id = null,
    underline: objc.Id = null,
    monochrome_sprite: objc.Id = null,
    color_sprite: objc.Id = null,
    path: objc.Id = null,
    external_surface: objc.Id = null,
    backdrop: objc.Id = null,
    composite: objc.Id = null,
    present: objc.Id = null,

    fn deinit(self: *Pipelines) void {
        inline for (.{ self.quad, self.shadow, self.underline, self.monochrome_sprite, self.color_sprite, self.path, self.external_surface, self.backdrop, self.composite, self.present }) |pipeline| release(pipeline);
        self.* = .{};
    }
};

const DeviceBounds = struct {
    left: u32,
    top: u32,
    width: u32,
    height: u32,

    fn right(self: DeviceBounds) u32 {
        return self.left + self.width;
    }
    fn bottom(self: DeviceBounds) u32 {
        return self.top + self.height;
    }
    fn logical(self: DeviceBounds, scale: geometry.ScaleFactor) geometry.Rect {
        return geometry.Rect.fromXYWH(
            scale.deviceToLogical(@floatFromInt(self.left)),
            scale.deviceToLogical(@floatFromInt(self.top)),
            scale.deviceToLogical(@floatFromInt(self.width)),
            scale.deviceToLogical(@floatFromInt(self.height)),
        );
    }
};

const EncodeTarget = struct { texture: objc.Id, bounds: DeviceBounds };
const DepthEncodeTarget = struct { texture: objc.Id, clear_depth: f32, load: bool = false };
const TargetState = struct { target: ?EncodeTarget, layer: u32, isolated: bool = false };

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    provider: surface.Provider,
    policy: config.GpuPolicy,
    device: objc.Id,
    command_queue: objc.Id,
    library: objc.Id,
    pipelines: Pipelines,
    textures: std.AutoHashMap(u64, objc.Id),
    external_surfaces: std.AutoHashMap(u64, objc.Id),
    retired_textures: std.ArrayList(RetiredTexture) = .empty,
    in_flight: std.ArrayList(InFlight) = .empty,
    active: ?ActiveFrame = null,
    acquisitions: std.ArrayList(struct { window: handles.WindowId, value: *Acquisition }) = .empty,
    maximum_windows: usize,
    generation: api.DeviceGeneration = 1,
    next_token: u64 = 1,
    submitted: api.SubmissionEpoch = 0,
    completed: api.SubmissionEpoch = 0,
    tessellator: path_tessellator.Tessellator,
    path_vertices: std.ArrayList(path_tessellator.Vertex) = .empty,
    path_draws: std.ArrayList(PathDraw) = .empty,
    resolved_clips: std.ArrayList(ResolvedClip) = .empty,
    layer_bounds: std.ArrayList(?geometry.Rect) = .empty,
    frame_resources: []FrameResources,
    extensions: extension.Registry,
    maximum_textures: usize,
    maximum_external_surfaces: usize,
    maximum_resources: usize,
    maximum_offscreen_requests: usize,
    next_offscreen_id: api.OffscreenRequestId = 1,
    offscreen_requests: std.AutoHashMap(api.OffscreenRequestId, *AsyncOffscreenRequest),

    pub fn create(
        allocator: std.mem.Allocator,
        provider: surface.Provider,
        policy: config.GpuPolicy,
        memory: config.MemoryBudgets,
    ) Error!api.Renderer {
        const self = try allocator.create(Renderer);
        errdefer allocator.destroy(self);
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoGpuDevice;
        errdefer release(device);
        const queue = objc.send(objc.Id, device, "newCommandQueue", .{}) orelse return error.NoGpuDevice;
        errdefer release(queue);
        const library = try compileLibrary(device);
        errdefer release(library);
        var pipelines = try createPipelines(device, library);
        errdefer pipelines.deinit();
        const frame_count: usize = @max(@as(usize, policy.frames_in_flight), 1);
        const frame_resources = try allocator.alloc(FrameResources, frame_count);
        @memset(frame_resources, .{});
        errdefer allocator.free(frame_resources);
        self.* = .{
            .allocator = allocator,
            .maximum_windows = memory.window_count,
            .provider = provider,
            .policy = policy,
            .device = device,
            .command_queue = queue,
            .library = library,
            .pipelines = pipelines,
            .textures = std.AutoHashMap(u64, objc.Id).init(allocator),
            .external_surfaces = std.AutoHashMap(u64, objc.Id).init(allocator),
            .tessellator = path_tessellator.Tessellator.init(allocator, .{
                .maximum_edges = memory.path_edge_count,
                .maximum_work_units = memory.path_work_units,
                .maximum_output_vertices = memory.upload_ring_bytes / @sizeOf(path_tessellator.Vertex),
                .maximum_cache_bytes = memory.path_cache_bytes,
            }),
            .frame_resources = frame_resources,
            .extensions = extension.Registry.initWithLimit(allocator, memory.render_extension_count),
            .maximum_textures = memory.texture_count,
            .maximum_external_surfaces = memory.external_surface_count,
            .maximum_resources = std.math.add(usize, memory.texture_count, memory.external_surface_count) catch return error.BudgetExceeded,
            .maximum_offscreen_requests = memory.offscreen_request_count,
            .offscreen_requests = std.AutoHashMap(api.OffscreenRequestId, *AsyncOffscreenRequest).init(allocator),
        };
        return .{ .context = self, .vtable = &vtable };
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

    fn cast(context: *anyopaque) *Renderer {
        return @ptrCast(@alignCast(context));
    }

    fn capabilities(_: *anyopaque) api.Capabilities {
        return .{ .external_surfaces = true, .offscreen_readback = true, .offscreen_async_readback = true, .custom_materials = true, .backdrop_effects = true };
    }

    fn deviceGeneration(context: *anyopaque) api.DeviceGeneration {
        return cast(context).generation;
    }

    fn beginFrame(context: *anyopaque, descriptor: api.FrameDescriptor) Error!api.FrameToken {
        const self = cast(context);
        if (self.active != null) return error.FrameActive;
        try self.collect(false);
        if (self.policy.asynchronous_drawables and self.availableFrameSlot() == null) return error.FrameNotReady;
        while (self.in_flight.items.len >= self.frame_resources.len) try self.waitOldest();
        var maybe_slot = self.availableFrameSlot();
        if (maybe_slot == null) {
            try self.waitOldest();
            maybe_slot = self.availableFrameSlot();
        }
        const slot = maybe_slot orelse return error.ResourceBusy;
        const layer = self.provider.layer(descriptor.window) orelse return error.SurfaceUnavailable;
        const drawable = if (self.policy.asynchronous_drawables) blk: {
            const acquisition = try self.getAcquisition(descriptor.window, layer);
            const size = objc.send(Size, layer, "drawableSize", .{});
            const changed = objc.send(objc.Id, layer, "device", .{}) != self.device or
                objc.send(usize, layer, "pixelFormat", .{}) != 81 or
                size.width != descriptor.drawable_width or size.height != descriptor.drawable_height;
            if (changed) {
                if (acquisition.pending()) return error.FrameNotReady;
                release(acquisition.take() catch null);
                configureLayer(layer, self.device, descriptor);
            }
            if (try acquisition.take()) |ready| {
                const texture = objc.send(objc.Id, ready, "texture", .{});
                if (objc.send(usize, texture, "width", .{}) == descriptor.drawable_width and
                    objc.send(usize, texture, "height", .{}) == descriptor.drawable_height) break :blk ready;
                release(ready);
            }
            acquisition.start();
            return error.FrameNotReady;
        } else blk: {
            objc.send(void, layer, "setDevice:", .{self.device});
            objc.send(void, layer, "setPixelFormat:", .{@as(usize, 81)});
            objc.send(void, layer, "setDrawableSize:", .{Size{ .width = descriptor.drawable_width, .height = descriptor.drawable_height }});
            break :blk retain(objc.send(objc.Id, layer, "nextDrawable", .{}) orelse return error.SurfaceUnavailable);
        };
        const token: api.FrameToken = .{ .value = self.next_token, .device_generation = self.generation };
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        self.active = .{ .token = token, .descriptor = descriptor, .drawable = drawable, .slot = slot };
        return token;
    }

    fn configureLayer(layer: objc.Id, device: objc.Id, descriptor: api.FrameDescriptor) void {
        if (objc.send(objc.Id, layer, "device", .{}) != device) objc.send(void, layer, "setDevice:", .{device});
        if (objc.send(usize, layer, "pixelFormat", .{}) != 81) objc.send(void, layer, "setPixelFormat:", .{@as(usize, 81)});
        const size = objc.send(Size, layer, "drawableSize", .{});
        if (size.width != descriptor.drawable_width or size.height != descriptor.drawable_height)
            objc.send(void, layer, "setDrawableSize:", .{Size{ .width = descriptor.drawable_width, .height = descriptor.drawable_height }});
    }

    fn getAcquisition(self: *Renderer, window: handles.WindowId, layer: objc.Id) Error!*Acquisition {
        var found: ?*Acquisition = null;
        var index: usize = 0;
        while (index < self.acquisitions.items.len) {
            const entry = self.acquisitions.items[index];
            if (entry.window.eql(window) and entry.value.layer == layer) found = entry.value;
            if (self.provider.layer(entry.window) != entry.value.layer and !entry.value.pending()) {
                entry.value.deinit();
                self.allocator.destroy(entry.value);
                _ = self.acquisitions.swapRemove(index);
            } else index += 1;
        }
        if (found) |value| return value;
        if (self.acquisitions.items.len >= self.maximum_windows) return error.FrameNotReady;
        try self.acquisitions.ensureUnusedCapacity(self.allocator, 1);
        const value = try self.allocator.create(Acquisition);
        errdefer self.allocator.destroy(value);
        value.* = try Acquisition.init(layer);
        self.acquisitions.appendAssumeCapacity(.{ .window = window, .value = value });
        return value;
    }

    fn drainAcquisitions(self: *Renderer) void {
        for (self.acquisitions.items) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
        self.acquisitions.clearRetainingCapacity();
    }

    fn submit(context: *anyopaque, token: api.FrameToken, view: api.SceneView) Error!api.Submission {
        const self = cast(context);
        const active = self.active orelse return error.FramePhaseViolation;
        errdefer {
            release(active.drawable);
            self.active = null;
        }
        if (active.token.value != token.value or token.device_generation != self.generation) return error.DeviceLost;
        try scene.validate(view);
        try self.in_flight.ensureUnusedCapacity(self.allocator, 1);
        const command_buffer = objc.send(objc.Id, self.command_queue, "commandBuffer", .{}) orelse return error.DeviceLost;
        const frame = &self.frame_resources[active.slot];
        const root_texture = try frame.acquireLayerTarget(
            self.allocator,
            self.device,
            0,
            active.descriptor.drawable_width,
            active.descriptor.drawable_height,
        );
        const root: EncodeTarget = .{
            .texture = root_texture,
            .bounds = .{ .left = 0, .top = 0, .width = active.descriptor.drawable_width, .height = active.descriptor.drawable_height },
        };
        try self.encode(command_buffer, active.descriptor, view, &self.frame_resources[active.slot], root, active.descriptor.clear_color, &self.pipelines);
        const drawable_texture = objc.send(objc.Id, active.drawable, "texture", .{}) orelse return error.SurfaceUnavailable;
        const drawable_target: EncodeTarget = .{ .texture = drawable_texture, .bounds = root.bounds };
        const present_encoder = try beginRenderEncoder(command_buffer, drawable_target, .dont_care, null, null);
        objc.send(void, present_encoder, "setRenderPipelineState:", .{self.pipelines.present});
        objc.send(void, present_encoder, "setFragmentTexture:atIndex:", .{ root.texture, @as(usize, 0) });
        objc.send(void, present_encoder, "drawPrimitives:vertexStart:vertexCount:", .{
            @as(usize, 4), @as(usize, 0), @as(usize, 4),
        });
        objc.send(void, present_encoder, "endEncoding", .{});
        objc.send(void, command_buffer, "presentDrawable:", .{active.drawable});
        objc.send(void, command_buffer, "commit", .{});
        self.submitted +%= 1;
        if (self.submitted == 0) self.submitted = 1;
        self.frame_resources[active.slot].busy_epoch = self.submitted;
        self.in_flight.appendAssumeCapacity(.{ .epoch = self.submitted, .command_buffer = retain(command_buffer), .slot = active.slot });
        release(active.drawable);
        self.active = null;
        // Start waiting only after returning this drawable to the compositor.
        // A single retained result is reused by the next dirty frame.
        for (self.acquisitions.items) |entry| if (entry.window.eql(active.descriptor.window) and entry.value.layer == self.provider.layer(entry.window)) {
            entry.value.start();
            break;
        };
        return .{ .epoch = self.submitted, .device_generation = self.generation, .presented = true };
    }

    fn encode(
        self: *Renderer,
        command_buffer: objc.Id,
        descriptor: api.FrameDescriptor,
        view: api.SceneView,
        frame: *FrameResources,
        root: EncodeTarget,
        clear_color: geometry.Color,
        pipelines: *const Pipelines,
    ) Error!void {
        const dummy_material: scene_abi.Material = .{
            .kind = @backingInt(scene_abi.MaterialKind.none),
            .stop_start = 0,
            .stop_count = 0,
            .color = .transparent,
            .start = .{},
            .end = .{},
            .gradient_transform = .identity,
        };
        const dummy_stop: scene_abi.GradientStop = .{ .offset = 0, .color = .transparent };
        try self.prepareClips(view);
        try self.preparePaths(descriptor, view);
        var upload_bytes = try api.structuredUploadBytes(
            view,
            std.mem.sliceAsBytes(self.path_vertices.items).len,
            std.mem.sliceAsBytes(self.resolved_clips.items).len,
        );
        if (view.materials.len == 0)
            upload_bytes = std.math.add(usize, upload_bytes, @sizeOf(scene_abi.Material)) catch return error.BudgetExceeded;
        if (view.gradient_stops.len == 0)
            upload_bytes = std.math.add(usize, upload_bytes, @sizeOf(scene_abi.GradientStop)) catch return error.BudgetExceeded;
        if (upload_bytes > descriptor.maximum_upload_bytes) return error.BudgetExceeded;
        const materials = try frame.materials.upload(self.device, if (view.materials.len == 0) std.mem.asBytes(&dummy_material) else std.mem.sliceAsBytes(view.materials));
        const stops = try frame.stops.upload(self.device, if (view.gradient_stops.len == 0) std.mem.asBytes(&dummy_stop) else std.mem.sliceAsBytes(view.gradient_stops));
        const quads = try frame.quads.upload(self.device, std.mem.sliceAsBytes(view.quads));
        const shadows = try frame.shadows.upload(self.device, std.mem.sliceAsBytes(view.shadows));
        const underlines = try frame.underlines.upload(self.device, std.mem.sliceAsBytes(view.underlines));
        const mono = try frame.monochrome_sprites.upload(self.device, std.mem.sliceAsBytes(view.monochrome_sprites));
        const color = try frame.color_sprites.upload(self.device, std.mem.sliceAsBytes(view.color_sprites));
        const external = try frame.external_surfaces.upload(self.device, std.mem.sliceAsBytes(view.external_surfaces));
        const clips = try frame.clips.upload(self.device, std.mem.sliceAsBytes(self.resolved_clips.items));
        const path_buffer = try frame.paths.upload(self.device, std.mem.sliceAsBytes(self.path_vertices.items));

        var needs_isolation = false;
        for (view.layers) |layer| {
            if (layer.opacity != 1 or layer.blend_mode != @backingInt(scene_abi.BlendMode.normal)) {
                needs_isolation = true;
                break;
            }
        }
        if (needs_isolation) {
            try self.layer_bounds.resize(self.allocator, view.layers.len);
            try layer_plan.populate(view, self.layer_bounds.items);
        } else {
            self.layer_bounds.clearRetainingCapacity();
        }
        var targets: [65]TargetState = undefined;
        targets[0] = .{ .target = root, .layer = scene.none_index };
        var depth: usize = 0;
        var encoder = try beginRenderEncoder(command_buffer, root, .clear, clear_color, null);
        var encoder_open = true;
        errdefer if (encoder_open) objc.send(void, encoder, "endEncoding", .{});

        for (view.operations, 0..) |operation, operation_index| {
            const kind = std.enums.fromInt(scene_abi.OperationKind, operation.kind) orelse return error.InvalidScene;
            switch (kind) {
                .push_clip, .pop_clip => continue,
                .push_layer => {
                    if (depth + 1 >= targets.len or operation.start >= view.layers.len) return error.InvalidScene;
                    depth += 1;
                    targets[depth] = .{ .target = null, .layer = operation.start };
                    if (targets[depth - 1].target == null) continue;
                    const parent = targets[depth - 1].target.?;
                    const layer = view.layers[@as(usize, operation.start)];
                    if (layer.opacity <= 0) continue;
                    if (layer.opacity == 1 and layer.blend_mode == @backingInt(scene_abi.BlendMode.normal)) {
                        targets[depth].target = parent;
                        continue;
                    }
                    const visual_bounds = self.layer_bounds.items[@as(usize, operation.start)] orelse continue;
                    const bounds = cropLayerBounds(visual_bounds, descriptor) orelse continue;
                    const texture = try frame.acquireLayerTarget(self.allocator, self.device, depth, bounds.width, bounds.height);
                    const child: EncodeTarget = .{ .texture = texture, .bounds = bounds };
                    targets[depth].target = child;
                    targets[depth].isolated = true;
                    objc.send(void, encoder, "endEncoding", .{});
                    encoder_open = false;
                    encoder = try beginRenderEncoder(command_buffer, child, .clear, .transparent, null);
                    encoder_open = true;
                    continue;
                },
                .pop_layer => {
                    if (depth == 0 or targets[depth].layer != operation.start) return error.InvalidScene;
                    if (targets[depth].isolated) {
                        const child = targets[depth].target orelse return error.InvalidScene;
                        const parent = targets[depth - 1].target orelse return error.InvalidScene;
                        objc.send(void, encoder, "endEncoding", .{});
                        encoder_open = false;
                        encoder = try self.compositeLayer(
                            command_buffer,
                            descriptor,
                            frame,
                            depth,
                            parent,
                            child,
                            view.layers[@as(usize, operation.start)],
                            pipelines,
                        );
                        encoder_open = true;
                    }
                    depth -= 1;
                    continue;
                },
                else => {},
            }
            const target = targets[depth].target orelse continue;
            if (operation.count == 0) continue;
            if (kind == .backdrop_effect) {
                const effect = view.backdrop_effects[operation.start];
                try self.encodeBackdropEffect(
                    command_buffer,
                    descriptor,
                    frame,
                    depth,
                    target,
                    effect,
                    operation,
                    view,
                    &encoder,
                    &encoder_open,
                );
                continue;
            }
            try setClip(encoder, descriptor, view, operation.clip, target.bounds);
            const logical_target = target.bounds.logical(descriptor.scale_factor);
            const globals: Globals = .{
                .viewport = .{ logical_target.size.width, logical_target.size.height },
                .viewport_origin = .{ logical_target.origin.x, logical_target.origin.y },
                .transform = layerTransform(view, operation.layer),
                .material_index = operation.material,
                .clip_index = operation.clip,
                .opacity = 1,
                .blend_mode = @backingInt(scene_abi.BlendMode.normal),
            };
            if (kind == .custom_passes) {
                const clip_bounds = try resolvedClipRect(descriptor, view, operation.clip);
                for (view.custom_passes[operation.start..][0..operation.count]) |pass| {
                    const extension_id = extension.decodeId(pass.extension);
                    const requirements = try self.extensions.requirements(extension_id);
                    const capture_snapshot = if (requirements.snapshot) |request|
                        if (request.when_flag) |flag| (pass.flags & flag) != 0 else true
                    else
                        false;
                    var depth_attachment: ?extension.DepthAttachment = null;
                    var depth_texture: ?objc.Id = null;
                    if (requirements.depth != null) {
                        depth_texture = try frame.acquireExtensionDepthTarget(
                            self.allocator,
                            self.device,
                            depth,
                            target.bounds.width,
                            target.bounds.height,
                        );
                    }

                    // Extension requirements that cross an encoder boundary
                    // must capture the current target before opening the
                    // extension's encoder. Snapshot resources belong to the
                    // frame slot and remain valid until its GPU submission is
                    // complete.
                    if (requirements.depth != null or capture_snapshot) {
                        objc.send(void, encoder, "endEncoding", .{});
                        encoder_open = false;
                    }

                    var snapshot_color: ?objc.Id = null;
                    var snapshot_depth: ?objc.Id = null;
                    if (capture_snapshot) {
                        const request = requirements.snapshot orelse return error.InvalidConfiguration;
                        if (request.color) {
                            snapshot_color = try frame.acquireExtensionSnapshotColorTarget(
                                self.allocator,
                                self.device,
                                depth,
                                target.bounds.width,
                                target.bounds.height,
                            );
                        }
                        if (request.depth) {
                            const source_depth = depth_texture orelse return error.InvalidConfiguration;
                            snapshot_depth = try frame.acquireExtensionSnapshotDepthTarget(
                                self.allocator,
                                self.device,
                                depth,
                                target.bounds.width,
                                target.bounds.height,
                            );
                            try copyTexture(
                                command_buffer,
                                source_depth,
                                snapshot_depth.?,
                                target.bounds.width,
                                target.bounds.height,
                            );
                        }
                        if (request.color) {
                            try copyTexture(
                                command_buffer,
                                target.texture,
                                snapshot_color.?,
                                target.bounds.width,
                                target.bounds.height,
                            );
                        }
                    }

                    if (requirements.depth) |request| {
                        const load_depth = if (request.load_flag) |flag| (pass.flags & flag) != 0 else false;
                        const depth_target = depth_texture orelse return error.InvalidConfiguration;
                        encoder = try beginRenderEncoder(command_buffer, target, .load, null, .{
                            .texture = depth_target,
                            .clear_depth = request.clear_depth,
                            .load = load_depth,
                        });
                        encoder_open = true;
                        depth_attachment = .{
                            .texture = pointerValue(depth_target),
                            .format = request.format,
                        };
                    } else if (capture_snapshot) {
                        // Snapshot-only extensions still need a fresh encoder
                        // after the blit, preserving the current color target.
                        encoder = try beginRenderEncoder(command_buffer, target, .load, null, null);
                        encoder_open = true;
                    }
                    try setClip(encoder, descriptor, view, operation.clip, target.bounds);
                    const payload = view.custom_payload[@as(usize, pass.payload_start)..][0..pass.payload_length];
                    try self.extensions.encode(
                        extension_id,
                        .{ .metal = .{
                            .device = pointerValue(self.device),
                            .command_queue = pointerValue(self.command_queue),
                        } },
                        .{ .metal = .{
                            .device = pointerValue(self.device),
                            .command_buffer = pointerValue(command_buffer),
                            .render_encoder = pointerValue(encoder),
                            .target_texture = pointerValue(target.texture),
                            .depth = depth_attachment,
                            .snapshot = if (snapshot_color != null or snapshot_depth != null) .{
                                .color = if (snapshot_color) |texture| pointerValue(texture) else null,
                                .depth = if (snapshot_depth) |texture| pointerValue(texture) else null,
                            } else null,
                            .geometry = .{
                                .window = descriptor.window,
                                .logical_size = descriptor.logical_size,
                                .drawable_width = descriptor.drawable_width,
                                .drawable_height = descriptor.drawable_height,
                                .scale_factor = descriptor.scale_factor,
                                .clear_color = descriptor.clear_color,
                                .bounds = globals.transform.transformRectBounds(pass.bounds),
                                .clip = clip_bounds,
                                .transform = globals.transform,
                                .opacity = 1,
                                .target_origin = logical_target.origin,
                                .target_width = target.bounds.width,
                                .target_height = target.bounds.height,
                            },
                        } },
                        payload,
                        pass.flags,
                        self.generation,
                        self.submitted +| 1,
                    );
                    if (requirements.depth != null) {
                        objc.send(void, encoder, "endEncoding", .{});
                        encoder_open = false;
                        encoder = try beginRenderEncoder(command_buffer, target, .load, null, null);
                        encoder_open = true;
                    }
                }
                continue;
            }
            objc.send(void, encoder, "setVertexBytes:length:atIndex:", .{ &globals, @as(usize, @sizeOf(Globals)), @as(usize, 10) });
            objc.send(void, encoder, "setFragmentBytes:length:atIndex:", .{ &globals, @as(usize, @sizeOf(Globals)), @as(usize, 10) });
            if (materials != null) objc.send(void, encoder, "setFragmentBuffer:offset:atIndex:", .{ materials, @as(usize, 0), @as(usize, 1) });
            if (stops != null) objc.send(void, encoder, "setFragmentBuffer:offset:atIndex:", .{ stops, @as(usize, 0), @as(usize, 2) });
            if (clips != null) objc.send(void, encoder, "setFragmentBuffer:offset:atIndex:", .{ clips, @as(usize, 0), @as(usize, 3) });
            if (kind == .paths) {
                const draw = self.path_draws.items[operation_index];
                if (draw.count == 0 or path_buffer == null) continue;
                objc.send(void, encoder, "setRenderPipelineState:", .{pipelines.path});
                objc.send(void, encoder, "setVertexBuffer:offset:atIndex:", .{
                    path_buffer, @as(usize, draw.start) * @sizeOf(path_tessellator.Vertex), @as(usize, 0),
                });
                objc.send(void, encoder, "drawPrimitives:vertexStart:vertexCount:", .{
                    @as(usize, 3), @as(usize, 0), @as(usize, draw.count),
                });
                continue;
            }
            const selected: DrawSelection = switch (kind) {
                .quads => .{ .payload = quads, .pipeline = pipelines.quad, .stride = @sizeOf(scene_abi.Quad) },
                .shadows => .{ .payload = shadows, .pipeline = pipelines.shadow, .stride = @sizeOf(scene_abi.Shadow) },
                .underlines => .{ .payload = underlines, .pipeline = pipelines.underline, .stride = @sizeOf(scene_abi.Underline) },
                .monochrome_sprites => .{ .payload = mono, .pipeline = pipelines.monochrome_sprite, .stride = @sizeOf(scene_abi.Sprite) },
                .color_sprites => .{ .payload = color, .pipeline = pipelines.color_sprite, .stride = @sizeOf(scene_abi.Sprite) },
                .external_surfaces => .{ .payload = external, .pipeline = pipelines.external_surface, .stride = @sizeOf(scene_abi.ExternalSurface) },
                else => unreachable,
            };
            if (selected.payload == null) continue;
            objc.send(void, encoder, "setRenderPipelineState:", .{selected.pipeline});
            objc.send(void, encoder, "setVertexBuffer:offset:atIndex:", .{ selected.payload, @as(usize, operation.start) * selected.stride, @as(usize, 0) });
            objc.send(void, encoder, "setFragmentBuffer:offset:atIndex:", .{ selected.payload, @as(usize, operation.start) * selected.stride, @as(usize, 0) });
            if (kind == .monochrome_sprites or kind == .color_sprites) {
                const sprites = if (kind == .monochrome_sprites) view.monochrome_sprites else view.color_sprites;
                const texture_id = sprites[@as(usize, operation.start)].texture;
                const source_texture = self.textures.get(texture_id) orelse return error.InvalidHandle;
                objc.send(void, encoder, "setFragmentTexture:atIndex:", .{ source_texture, @as(usize, 0) });
            } else if (kind == .external_surfaces) {
                const source_surface = view.external_surfaces[@as(usize, operation.start)];
                const source_texture = self.external_surfaces.get(source_surface.surface) orelse return error.InvalidHandle;
                objc.send(void, encoder, "setFragmentTexture:atIndex:", .{ source_texture, @as(usize, 0) });
            }
            objc.send(void, encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                @as(usize, 4), @as(usize, 0), @as(usize, 4), @as(usize, operation.count),
            });
        }
        if (depth != 0) return error.InvalidScene;
        objc.send(void, encoder, "endEncoding", .{});
        encoder_open = false;
    }

    fn compositeLayer(
        self: *Renderer,
        command_buffer: objc.Id,
        descriptor: api.FrameDescriptor,
        frame: *FrameResources,
        depth: usize,
        parent: EncodeTarget,
        child: EncodeTarget,
        layer: scene_abi.Layer,
        pipelines: *const Pipelines,
    ) Error!objc.Id {
        if (child.bounds.left < parent.bounds.left or child.bounds.top < parent.bounds.top or
            child.bounds.right() > parent.bounds.right() or child.bounds.bottom() > parent.bounds.bottom())
            return error.InvalidScene;
        const backdrop = try frame.acquireBackdropTarget(
            self.allocator,
            self.device,
            depth,
            child.bounds.width,
            child.bounds.height,
        );
        const blit = objc.send(objc.Id, command_buffer, "blitCommandEncoder", .{}) orelse return error.DeviceLost;
        objc.send(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
            parent.texture,
            @as(usize, 0),
            @as(usize, 0),
            Origin{
                .x = child.bounds.left - parent.bounds.left,
                .y = child.bounds.top - parent.bounds.top,
                .z = 0,
            },
            Extent{ .width = child.bounds.width, .height = child.bounds.height, .depth = 1 },
            backdrop,
            @as(usize, 0),
            @as(usize, 0),
            Origin{ .x = 0, .y = 0, .z = 0 },
        });
        objc.send(void, blit, "endEncoding", .{});

        const encoder = try beginRenderEncoder(command_buffer, parent, .load, null, null);
        errdefer objc.send(void, encoder, "endEncoding", .{});
        const logical_parent = parent.bounds.logical(descriptor.scale_factor);
        const logical_child = child.bounds.logical(descriptor.scale_factor);
        const globals: Globals = .{
            .viewport = .{ logical_parent.size.width, logical_parent.size.height },
            .viewport_origin = .{ logical_parent.origin.x, logical_parent.origin.y },
            .transform = .identity,
            .material_index = scene.none_index,
            .clip_index = scene.none_index,
            .opacity = 1,
            .blend_mode = layer.blend_mode,
        };
        const item: Composite = .{ .bounds = logical_child, .opacity = layer.opacity };
        objc.send(void, encoder, "setRenderPipelineState:", .{pipelines.composite});
        objc.send(void, encoder, "setVertexBytes:length:atIndex:", .{ &item, @as(usize, @sizeOf(Composite)), @as(usize, 0) });
        objc.send(void, encoder, "setFragmentBytes:length:atIndex:", .{ &item, @as(usize, @sizeOf(Composite)), @as(usize, 0) });
        objc.send(void, encoder, "setVertexBytes:length:atIndex:", .{ &globals, @as(usize, @sizeOf(Globals)), @as(usize, 10) });
        objc.send(void, encoder, "setFragmentBytes:length:atIndex:", .{ &globals, @as(usize, @sizeOf(Globals)), @as(usize, 10) });
        objc.send(void, encoder, "setFragmentTexture:atIndex:", .{ child.texture, @as(usize, 0) });
        objc.send(void, encoder, "setFragmentTexture:atIndex:", .{ backdrop, @as(usize, 1) });
        objc.send(void, encoder, "drawPrimitives:vertexStart:vertexCount:", .{
            @as(usize, 4), @as(usize, 0), @as(usize, 4),
        });
        return encoder;
    }

    fn encodeBackdropEffect(
        self: *Renderer,
        command_buffer: objc.Id,
        descriptor: api.FrameDescriptor,
        frame: *FrameResources,
        depth: usize,
        target: EncodeTarget,
        effect: scene_abi.BackdropEffect,
        operation: scene_abi.Operation,
        view: api.SceneView,
        encoder: *objc.Id,
        encoder_open: *bool,
    ) Error!void {
        const transform = layerTransform(view, operation.layer);
        const world_bounds = transform.transformRectBounds(effect.bounds);
        const capture_bounds = cropToTarget(
            expandRect(world_bounds, effect.blur_radius * 2),
            descriptor.scale_factor,
            target.bounds,
        ) orelse return;
        const backdrop = try frame.acquireBackdropTarget(
            self.allocator,
            self.device,
            depth,
            capture_bounds.width,
            capture_bounds.height,
        );

        objc.send(void, encoder.*, "endEncoding", .{});
        encoder_open.* = false;
        const blit = objc.send(objc.Id, command_buffer, "blitCommandEncoder", .{}) orelse return error.DeviceLost;
        objc.send(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
            target.texture,
            @as(usize, 0),
            @as(usize, 0),
            Origin{
                .x = capture_bounds.left - target.bounds.left,
                .y = capture_bounds.top - target.bounds.top,
                .z = 0,
            },
            Extent{ .width = capture_bounds.width, .height = capture_bounds.height, .depth = 1 },
            backdrop,
            @as(usize, 0),
            @as(usize, 0),
            Origin{ .x = 0, .y = 0, .z = 0 },
        });
        objc.send(void, blit, "endEncoding", .{});

        encoder.* = try beginRenderEncoder(command_buffer, target, .load, null, null);
        encoder_open.* = true;
        try setClip(encoder.*, descriptor, view, operation.clip, target.bounds);
        const logical_target = target.bounds.logical(descriptor.scale_factor);
        const capture_logical = capture_bounds.logical(descriptor.scale_factor);
        const globals: Globals = .{
            .viewport = .{ logical_target.size.width, logical_target.size.height },
            .viewport_origin = .{ logical_target.origin.x, logical_target.origin.y },
            .transform = transform,
            .material_index = scene.none_index,
            .clip_index = operation.clip,
            .opacity = 1,
            .blend_mode = @backingInt(scene_abi.BlendMode.normal),
        };
        const item: BackdropComposite = .{
            .bounds = effect.bounds,
            .radii = effect.radii,
            .capture_origin = capture_logical.origin,
            .capture_size = capture_logical.size,
            .blur_radius = effect.blur_radius * descriptor.scale_factor.value,
            .saturation = effect.saturation,
            .opacity = effect.opacity,
        };
        objc.send(void, encoder.*, "setRenderPipelineState:", .{self.pipelines.backdrop});
        objc.send(void, encoder.*, "setVertexBytes:length:atIndex:", .{ &item, @as(usize, @sizeOf(BackdropComposite)), @as(usize, 0) });
        objc.send(void, encoder.*, "setFragmentBytes:length:atIndex:", .{ &item, @as(usize, @sizeOf(BackdropComposite)), @as(usize, 0) });
        objc.send(void, encoder.*, "setVertexBytes:length:atIndex:", .{ &globals, @as(usize, @sizeOf(Globals)), @as(usize, 10) });
        objc.send(void, encoder.*, "setFragmentBytes:length:atIndex:", .{ &globals, @as(usize, @sizeOf(Globals)), @as(usize, 10) });
        objc.send(void, encoder.*, "setFragmentTexture:atIndex:", .{ backdrop, @as(usize, 0) });
        objc.send(void, encoder.*, "drawPrimitives:vertexStart:vertexCount:", .{
            @as(usize, 4), @as(usize, 0), @as(usize, 4),
        });
    }

    fn preparePaths(self: *Renderer, descriptor: api.FrameDescriptor, view: api.SceneView) Error!void {
        self.tessellator.beginBatch();
        self.path_vertices.clearRetainingCapacity();
        try self.path_draws.resize(self.allocator, view.operations.len);
        @memset(self.path_draws.items, .{});
        for (view.operations, 0..) |operation, operation_index| {
            const kind = std.enums.fromInt(scene_abi.OperationKind, operation.kind) orelse return error.InvalidScene;
            if (kind != .paths) continue;
            const start: u32 = @intCast(self.path_vertices.items.len);
            const paths = view.paths[@as(usize, operation.start)..][0..@as(usize, operation.count)];
            for (paths) |path| {
                const commands = view.path_vertices[@as(usize, path.vertex_start)..][0..@as(usize, path.vertex_count)];
                try self.tessellator.tessellate(path, commands, 0.25 / descriptor.scale_factor.value, &self.path_vertices);
            }
            self.path_draws.items[operation_index] = .{
                .start = start,
                .count = @intCast(self.path_vertices.items.len - @as(usize, start)),
            };
        }
    }

    fn prepareClips(self: *Renderer, view: api.SceneView) Error!void {
        try self.resolved_clips.resize(self.allocator, @max(view.clips.len, 1));
        if (view.clips.len == 0) {
            self.resolved_clips.items[0] = .{
                .bounds = .{},
                .radii = .{},
                .parent = scene.none_index,
                .inverse_transform = .identity,
            };
            return;
        }
        for (view.clips, 0..) |clip, index| {
            const transform = layerTransform(view, clip.layer);
            self.resolved_clips.items[index] = .{
                .bounds = clip.bounds,
                .radii = clip.radii,
                .parent = clip.parent,
                .inverse_transform = transform.inverse() orelse return error.InvalidScene,
            };
        }
    }

    fn renderOffscreen(context: *anyopaque, target: api.OffscreenTarget, view: api.SceneView, allocator: std.mem.Allocator) Error!?api.Readback {
        const self = cast(context);
        if (self.active != null) return error.FrameActive;
        if (target.width == 0 or target.height == 0) return error.InvalidConfiguration;
        try scene.validate(view);
        try self.collect(false);
        var maybe_slot = self.availableFrameSlot();
        if (maybe_slot == null) {
            try self.waitOldest();
            maybe_slot = self.availableFrameSlot();
        }
        const slot = maybe_slot orelse return error.ResourceBusy;
        const texture_descriptor = objc.send(objc.Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            @as(usize, 81), @as(usize, target.width), @as(usize, target.height), false,
        }) orelse return error.NoGpuDevice;
        objc.send(void, texture_descriptor, "setUsage:", .{@as(usize, 5)});
        objc.send(void, texture_descriptor, "setStorageMode:", .{@as(usize, 2)});
        const texture = objc.send(objc.Id, self.device, "newTextureWithDescriptor:", .{texture_descriptor}) orelse return error.BudgetExceeded;
        defer release(texture);
        const command_buffer = objc.send(objc.Id, self.command_queue, "commandBuffer", .{}) orelse return error.DeviceLost;
        const descriptor: api.FrameDescriptor = .{
            .window = .invalid,
            .logical_size = .{
                .width = @as(f32, @floatFromInt(target.width)) / target.scale_factor.value,
                .height = @as(f32, @floatFromInt(target.height)) / target.scale_factor.value,
            },
            .drawable_width = target.width,
            .drawable_height = target.height,
            .scale_factor = target.scale_factor,
            .clear_color = .transparent,
        };
        const root: EncodeTarget = .{
            .texture = texture,
            .bounds = .{ .left = 0, .top = 0, .width = target.width, .height = target.height },
        };
        try self.encode(command_buffer, descriptor, view, &self.frame_resources[slot], root, .transparent, &self.pipelines);

        var read_buffer: objc.Id = null;
        defer release(read_buffer);
        var gpu_stride: usize = 0;
        if (target.readback) {
            const unaligned_stride = std.math.mul(usize, target.width, 4) catch return error.BudgetExceeded;
            gpu_stride = (unaligned_stride + 255) & ~@as(usize, 255);
            const length = std.math.mul(usize, gpu_stride, target.height) catch return error.BudgetExceeded;
            read_buffer = objc.send(objc.Id, self.device, "newBufferWithLength:options:", .{ length, @as(usize, 0) }) orelse return error.BudgetExceeded;
            const blit = objc.send(objc.Id, command_buffer, "blitCommandEncoder", .{}) orelse return error.DeviceLost;
            objc.send(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
                texture,
                @as(usize, 0),
                @as(usize, 0),
                Origin{ .x = 0, .y = 0, .z = 0 },
                Extent{ .width = target.width, .height = target.height, .depth = 1 },
                read_buffer,
                @as(usize, 0),
                gpu_stride,
                gpu_stride * @as(usize, target.height),
            });
            objc.send(void, blit, "endEncoding", .{});
        }
        objc.send(void, command_buffer, "commit", .{});
        objc.send(void, command_buffer, "waitUntilCompleted", .{});
        const status = objc.send(usize, command_buffer, "status", .{});
        if (status == 5) return error.DeviceLost;
        if (status == 6) return error.Cancelled;
        if (!target.readback) return null;
        const source_pointer = objc.send(?*anyopaque, read_buffer, "contents", .{}) orelse return error.DeviceLost;
        const source: [*]const u8 = @ptrCast(source_pointer);
        return try convertReadback(allocator, target, source, gpu_stride);
    }

    fn beginOffscreen(
        context: *anyopaque,
        target: api.OffscreenTarget,
        view: api.SceneView,
    ) Error!api.OffscreenRequestId {
        const self = cast(context);
        if (!target.readback) return error.InvalidConfiguration;
        if (self.active != null) return error.FrameActive;
        if (self.offscreen_requests.count() >= self.maximum_offscreen_requests)
            return error.BudgetExceeded;
        try scene.validate(view);
        try self.collect(false);
        try self.offscreen_requests.ensureUnusedCapacity(1);

        const request = try self.allocator.create(AsyncOffscreenRequest);
        request.* = undefined;
        request.id = self.nextOffscreenIdValue();
        request.target = target;
        request.frame = .{};
        request.command_buffer = null;
        request.texture = null;
        request.read_buffer = null;
        request.gpu_stride = 0;
        request.retained_resources = .empty;
        request.cancelled = false;
        request.snapshot = .{ .allocator = self.allocator };
        errdefer self.destroyOffscreenRequest(request);
        request.snapshot = try api.SceneSnapshot.init(self.allocator, view);
        try self.retainSceneResources(request, request.snapshot.view());

        const texture_descriptor = objc.send(objc.Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            @as(usize, 81), @as(usize, target.width), @as(usize, target.height), false,
        }) orelse return error.NoGpuDevice;
        objc.send(void, texture_descriptor, "setUsage:", .{@as(usize, 5)});
        objc.send(void, texture_descriptor, "setStorageMode:", .{@as(usize, 2)});
        request.texture = objc.send(objc.Id, self.device, "newTextureWithDescriptor:", .{texture_descriptor}) orelse return error.BudgetExceeded;
        const command_buffer = objc.send(objc.Id, self.command_queue, "commandBuffer", .{}) orelse return error.DeviceLost;
        request.command_buffer = retain(command_buffer);
        const descriptor: api.FrameDescriptor = .{
            .window = .invalid,
            .logical_size = .{
                .width = @as(f32, @floatFromInt(target.width)) / target.scale_factor.value,
                .height = @as(f32, @floatFromInt(target.height)) / target.scale_factor.value,
            },
            .drawable_width = target.width,
            .drawable_height = target.height,
            .scale_factor = target.scale_factor,
            .clear_color = .transparent,
        };
        const root: EncodeTarget = .{
            .texture = request.texture,
            .bounds = .{ .left = 0, .top = 0, .width = target.width, .height = target.height },
        };
        try self.encode(command_buffer, descriptor, request.snapshot.view(), &request.frame, root, .transparent, &self.pipelines);

        const unaligned_stride = std.math.mul(usize, target.width, 4) catch return error.BudgetExceeded;
        request.gpu_stride = (unaligned_stride + 255) & ~@as(usize, 255);
        const length = std.math.mul(usize, request.gpu_stride, target.height) catch return error.BudgetExceeded;
        request.read_buffer = objc.send(objc.Id, self.device, "newBufferWithLength:options:", .{ length, @as(usize, 0) }) orelse return error.BudgetExceeded;
        const blit = objc.send(objc.Id, command_buffer, "blitCommandEncoder", .{}) orelse return error.DeviceLost;
        objc.send(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
            request.texture,
            @as(usize, 0),
            @as(usize, 0),
            Origin{ .x = 0, .y = 0, .z = 0 },
            Extent{ .width = target.width, .height = target.height, .depth = 1 },
            request.read_buffer,
            @as(usize, 0),
            request.gpu_stride,
            request.gpu_stride * @as(usize, target.height),
        });
        objc.send(void, blit, "endEncoding", .{});
        objc.send(void, command_buffer, "commit", .{});
        self.offscreen_requests.putAssumeCapacity(request.id, request);
        return request.id;
    }

    fn retainSceneResources(self: *Renderer, request: *AsyncOffscreenRequest, view: api.SceneView) Error!void {
        for (view.operations) |operation| {
            const kind = std.enums.fromInt(scene_abi.OperationKind, operation.kind) orelse return error.InvalidScene;
            switch (kind) {
                .monochrome_sprites => for (view.monochrome_sprites[operation.start..][0..operation.count]) |sprite| {
                    const source = self.textures.get(sprite.texture) orelse return error.InvalidHandle;
                    const retained = retain(source);
                    request.retained_resources.append(self.allocator, retained) catch |err| {
                        release(retained);
                        return err;
                    };
                },
                .color_sprites => for (view.color_sprites[operation.start..][0..operation.count]) |sprite| {
                    const source = self.textures.get(sprite.texture) orelse return error.InvalidHandle;
                    const retained = retain(source);
                    request.retained_resources.append(self.allocator, retained) catch |err| {
                        release(retained);
                        return err;
                    };
                },
                .external_surfaces => for (view.external_surfaces[operation.start..][0..operation.count]) |surface_value| {
                    const source = self.external_surfaces.get(surface_value.surface) orelse return error.InvalidHandle;
                    const retained = retain(source);
                    request.retained_resources.append(self.allocator, retained) catch |err| {
                        release(retained);
                        return err;
                    };
                },
                else => {},
            }
        }
    }

    fn pollOffscreen(
        context: *anyopaque,
        id: api.OffscreenRequestId,
        allocator: std.mem.Allocator,
    ) Error!api.OffscreenPoll {
        const self = cast(context);
        const request = self.offscreen_requests.get(id) orelse return error.InvalidHandle;
        const status = objc.send(usize, request.command_buffer, "status", .{});
        if (status < 4) return .pending;
        if (request.cancelled or status == 6) {
            self.finishOffscreenRequest(id, request);
            return .cancelled;
        }
        if (status != 4) {
            self.finishOffscreenRequest(id, request);
            return .{ .failed = if (status == 5) error.DeviceLost else error.PlatformFailure };
        }
        const source_pointer = objc.send(?*anyopaque, request.read_buffer, "contents", .{}) orelse {
            self.finishOffscreenRequest(id, request);
            return .{ .failed = error.DeviceLost };
        };
        const source: [*]const u8 = @ptrCast(source_pointer);
        const readback = convertReadback(allocator, request.target, source, request.gpu_stride) catch |err| {
            self.finishOffscreenRequest(id, request);
            return .{ .failed = err };
        };
        self.finishOffscreenRequest(id, request);
        return .{ .ready = readback };
    }

    fn cancelOffscreen(context: *anyopaque, id: api.OffscreenRequestId) Error!void {
        const request = cast(context).offscreen_requests.get(id) orelse return error.InvalidHandle;
        request.cancelled = true;
    }

    fn drainOffscreen(context: *anyopaque) void {
        const self = cast(context);
        while (self.offscreen_requests.count() != 0) {
            var iterator = self.offscreen_requests.iterator();
            const entry = iterator.next().?;
            const request = entry.value_ptr.*;
            if (request.command_buffer) |command_buffer| objc.send(void, command_buffer, "waitUntilCompleted", .{});
            self.finishOffscreenRequest(entry.key_ptr.*, request);
        }
    }

    fn nextOffscreenIdValue(renderer: *Renderer) api.OffscreenRequestId {
        var id = renderer.next_offscreen_id;
        while (id == 0 or renderer.offscreen_requests.contains(id)) {
            id +%= 1;
            if (id == 0) id = 1;
        }
        renderer.next_offscreen_id = id +% 1;
        if (renderer.next_offscreen_id == 0) renderer.next_offscreen_id = 1;
        return id;
    }

    fn destroyOffscreenRequest(renderer: *Renderer, request: *AsyncOffscreenRequest) void {
        if (request.command_buffer) |value| release(value);
        if (request.read_buffer) |value| release(value);
        if (request.texture) |value| release(value);
        request.frame.deinit(renderer.allocator);
        for (request.retained_resources.items) |value| release(value);
        request.retained_resources.deinit(renderer.allocator);
        request.snapshot.deinit();
        renderer.allocator.destroy(request);
    }

    fn finishOffscreenRequest(renderer: *Renderer, id: api.OffscreenRequestId, request: *AsyncOffscreenRequest) void {
        _ = renderer.offscreen_requests.remove(id);
        request.frame.deinit(renderer.allocator);
        for (request.retained_resources.items) |value| release(value);
        request.retained_resources.deinit(renderer.allocator);
        request.snapshot.deinit();
        release(request.command_buffer);
        release(request.read_buffer);
        release(request.texture);
        renderer.allocator.destroy(request);
    }

    fn completedEpoch(context: *anyopaque) api.SubmissionEpoch {
        const self = cast(context);
        self.collect(false) catch {};
        return self.completed;
    }

    fn invalidateSurface(context: *anyopaque, window: handles.WindowId) Error!void {
        const self = cast(context);
        var index: usize = 0;
        while (index < self.acquisitions.items.len) {
            const entry = self.acquisitions.items[index];
            if (entry.window.eql(window)) {
                entry.value.deinit();
                self.allocator.destroy(entry.value);
                _ = self.acquisitions.swapRemove(index);
            } else index += 1;
        }
    }

    fn recover(context: *anyopaque, policy: config.GpuPolicy) Error!void {
        const self = cast(context);
        if (self.extensions.callbacksActive()) return error.CallbackReentrancy;
        self.drainAcquisitions();
        // Failed command buffers belong to the lost device generation. Drop
        // the framework's references and rebuild immediately; waiting for a
        // successful completion would make recovery itself return DeviceLost.
        while (self.in_flight.items.len != 0) {
            const abandoned = self.in_flight.orderedRemove(0);
            self.frame_resources[abandoned.slot].busy_epoch = 0;
            release(abandoned.command_buffer);
        }
        drainOffscreen(self);
        const next_device = MTLCreateSystemDefaultDevice() orelse return error.NoGpuDevice;
        errdefer release(next_device);
        const next_queue = objc.send(objc.Id, next_device, "newCommandQueue", .{}) orelse return error.NoGpuDevice;
        errdefer release(next_queue);
        const next_library = try compileLibrary(next_device);
        errdefer release(next_library);
        var next_pipelines = try createPipelines(next_device, next_library);
        errdefer next_pipelines.deinit();
        const next_frame_count: usize = @max(@as(usize, policy.frames_in_flight), 1);
        const next_frames = try self.allocator.alloc(FrameResources, next_frame_count);
        @memset(next_frames, .{});
        errdefer self.allocator.free(next_frames);

        var next_generation = self.generation +% 1;
        if (next_generation == 0) next_generation = 1;
        self.extensions.deviceLost(next_generation);

        self.pipelines.deinit();
        for (self.frame_resources) |*frame| frame.deinit(self.allocator);
        self.allocator.free(self.frame_resources);
        release(self.library);
        release(self.command_queue);
        release(self.device);
        var texture_iterator = self.textures.iterator();
        while (texture_iterator.next()) |entry| release(entry.value_ptr.*);
        self.textures.clearRetainingCapacity();
        var surface_iterator = self.external_surfaces.iterator();
        while (surface_iterator.next()) |entry| release(entry.value_ptr.*);
        self.external_surfaces.clearRetainingCapacity();
        for (self.retired_textures.items) |entry| release(entry.texture);
        self.retired_textures.clearRetainingCapacity();
        self.policy = policy;
        self.device = next_device;
        self.command_queue = next_queue;
        self.library = next_library;
        self.pipelines = next_pipelines;
        self.frame_resources = next_frames;
        self.generation = next_generation;
    }

    fn createTexture(context: *anyopaque, id: handles.TextureId, description: api.TextureDescriptor) Error!void {
        const self = cast(context);
        try self.collect(false);
        if (description.width == 0 or description.height == 0) return error.InvalidConfiguration;
        if (self.textures.contains(id.encode())) return error.ResourceBusy;
        if (self.textures.count() >= self.maximum_textures) return error.BudgetExceeded;
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        const pixel_format: usize = switch (description.format) {
            .a8 => 10,
            .rgba8 => 70,
            .rgba8_srgb => 71,
            .bgra8 => 80,
            .bgra8_srgb => 81,
            .rgba16_float => 112,
        };
        const descriptor = objc.send(objc.Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            pixel_format, @as(usize, description.width), @as(usize, description.height), false,
        }) orelse return error.NoGpuDevice;
        objc.send(void, descriptor, "setUsage:", .{@as(usize, if (description.usage == .render_target) 5 else 1)});
        const texture = objc.send(objc.Id, self.device, "newTextureWithDescriptor:", .{descriptor}) orelse return error.BudgetExceeded;
        errdefer release(texture);
        try self.textures.put(id.encode(), texture);
    }

    fn writeTexture(context: *anyopaque, id: handles.TextureId, region: api.TextureRegion, pixels: []const u8, stride: usize) Error!void {
        const self = cast(context);
        const texture = self.textures.get(id.encode()) orelse return error.InvalidHandle;
        const description_width: usize = objc.send(usize, texture, "width", .{});
        const description_height: usize = objc.send(usize, texture, "height", .{});
        if (@as(usize, region.x) + region.width > description_width or @as(usize, region.y) + region.height > description_height) return error.InvalidConfiguration;
        const bytes_per_pixel: usize = switch (objc.send(usize, texture, "pixelFormat", .{})) {
            10 => 1,
            70, 71, 80, 81 => 4,
            112 => 8,
            else => return error.InvalidConfiguration,
        };
        const row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.BudgetExceeded;
        if (stride < row_bytes) return error.InvalidConfiguration;
        const required = std.math.mul(usize, stride, region.height) catch return error.BudgetExceeded;
        if (pixels.len < required) return error.InvalidConfiguration;
        objc.send(void, texture, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .origin = .{ .x = region.x, .y = region.y, .z = 0 }, .size = .{ .width = region.width, .height = region.height, .depth = 1 } },
            @as(usize, 0),
            pixels.ptr,
            stride,
        });
    }

    fn destroyTexture(context: *anyopaque, id: handles.TextureId, release_after: api.SubmissionEpoch) Error!void {
        const self = cast(context);
        try self.collect(false);
        try self.retired_textures.ensureUnusedCapacity(self.allocator, 1);
        const removed = self.textures.fetchRemove(id.encode()) orelse return error.InvalidHandle;
        self.retired_textures.appendAssumeCapacity(.{ .texture = removed.value, .release_after = release_after });
    }

    fn importExternalSurface(context: *anyopaque, id: handles.SurfaceId, descriptor: api.ExternalSurfaceDescriptor) Error!void {
        const self = cast(context);
        if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
        if (self.external_surfaces.contains(id.encode())) return error.ResourceBusy;
        if (self.external_surfaces.count() >= self.maximum_external_surfaces) return error.BudgetExceeded;
        try self.collect(false);
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        const native = switch (descriptor.native) {
            .metal_texture => |value| value,
            else => return error.Unsupported,
        };
        if (native == 0) return error.InvalidHandle;
        const texture: objc.Id = @ptrFromInt(native);
        try self.external_surfaces.put(id.encode(), retain(texture));
    }

    fn replaceExternalSurface(
        context: *anyopaque,
        id: handles.SurfaceId,
        descriptor: api.ExternalSurfaceDescriptor,
        release_after: api.SubmissionEpoch,
    ) Error!void {
        const self = cast(context);
        const previous = self.external_surfaces.get(id.encode()) orelse return error.InvalidHandle;
        try self.collect(false);
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        const native = switch (descriptor.native) {
            .metal_texture => |value| value,
            else => return error.Unsupported,
        };
        if (native == 0 or descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
        const replacement: objc.Id = @ptrFromInt(native);
        try self.retired_textures.append(self.allocator, .{ .texture = previous, .release_after = release_after });
        self.external_surfaces.getPtr(id.encode()).?.* = retain(replacement);
    }

    fn destroyExternalSurface(context: *anyopaque, id: handles.SurfaceId, release_after: api.SubmissionEpoch) Error!void {
        const self = cast(context);
        try self.collect(false);
        try self.retired_textures.ensureUnusedCapacity(self.allocator, 1);
        const removed = self.external_surfaces.fetchRemove(id.encode()) orelse return error.InvalidHandle;
        self.retired_textures.appendAssumeCapacity(.{ .texture = removed.value, .release_after = release_after });
    }

    fn registerExtension(context: *anyopaque, descriptor: extension.Descriptor) Error!handles.RenderExtensionId {
        const self = cast(context);
        try self.collect(false);
        return self.extensions.register(descriptor);
    }

    fn destroyExtension(context: *anyopaque, id: handles.RenderExtensionId, release_after: api.SubmissionEpoch) Error!void {
        try cast(context).extensions.destroy(id, release_after);
    }

    fn deinit(context: *anyopaque) void {
        const self = cast(context);
        self.drainAcquisitions();
        self.acquisitions.deinit(self.allocator);
        while (self.in_flight.items.len != 0) self.waitOldest() catch break;
        drainOffscreen(self);
        self.pipelines.deinit();
        var iterator = self.textures.iterator();
        while (iterator.next()) |entry| release(entry.value_ptr.*);
        for (self.retired_textures.items) |entry| release(entry.texture);
        self.textures.deinit();
        var surface_iterator = self.external_surfaces.iterator();
        while (surface_iterator.next()) |entry| release(entry.value_ptr.*);
        self.external_surfaces.deinit();
        self.retired_textures.deinit(self.allocator);
        self.in_flight.deinit(self.allocator);
        self.offscreen_requests.deinit();
        self.tessellator.deinit();
        self.path_vertices.deinit(self.allocator);
        self.path_draws.deinit(self.allocator);
        self.resolved_clips.deinit(self.allocator);
        self.layer_bounds.deinit(self.allocator);
        self.extensions.deinit();
        for (self.frame_resources) |*frame| frame.deinit(self.allocator);
        self.allocator.free(self.frame_resources);
        release(self.library);
        release(self.command_queue);
        release(self.device);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn collect(self: *Renderer, wait: bool) Error!void {
        while (self.in_flight.items.len != 0) {
            const status: usize = objc.send(usize, self.in_flight.items[0].command_buffer, "status", .{});
            if (status < 4 and !wait) break;
            if (status < 4) objc.send(void, self.in_flight.items[0].command_buffer, "waitUntilCompleted", .{});
            const completed = self.in_flight.orderedRemove(0);
            const final_status: usize = objc.send(usize, completed.command_buffer, "status", .{});
            self.completed = @max(self.completed, completed.epoch);
            self.frame_resources[completed.slot].busy_epoch = 0;
            release(completed.command_buffer);
            if (final_status == 5) return error.DeviceLost;
            if (final_status == 6) return error.Cancelled;
        }
        var write: usize = 0;
        for (self.retired_textures.items) |entry| {
            if (entry.release_after <= self.completed) release(entry.texture) else {
                self.retired_textures.items[write] = entry;
                write += 1;
            }
        }
        self.retired_textures.items.len = write;
        self.extensions.collect(self.completed);
    }

    fn waitOldest(self: *Renderer) Error!void {
        if (self.in_flight.items.len == 0) return;
        objc.send(void, self.in_flight.items[0].command_buffer, "waitUntilCompleted", .{});
        try self.collect(false);
    }

    fn availableFrameSlot(self: *const Renderer) ?usize {
        for (self.frame_resources, 0..) |frame, index| if (frame.busy_epoch == 0) return index;
        return null;
    }

    fn totalResourceCount(self: *const Renderer) usize {
        return self.textures.count() +| self.external_surfaces.count() +| self.retired_textures.items.len;
    }
};

fn compileLibrary(device: objc.Id) Error!objc.Id {
    const bytes = @embedFile("zigui_metal_library");
    const data = dispatch_data_create(bytes.ptr, bytes.len, null, null) orelse return error.ShaderInvalid;
    defer dispatch_release(data);
    var error_object: objc.Id = null;
    return objc.send(objc.Id, device, "newLibraryWithData:error:", .{ data, &error_object }) orelse error.ShaderInvalid;
}

fn createPipelines(device: objc.Id, library: objc.Id) Error!Pipelines {
    var pipelines: Pipelines = .{};
    errdefer pipelines.deinit();
    pipelines.quad = try createPipeline(device, library, "quad_vertex", "quad_fragment", .source_over);
    pipelines.shadow = try createPipeline(device, library, "shadow_vertex", "shadow_fragment", .source_over);
    pipelines.underline = try createPipeline(device, library, "underline_vertex", "underline_fragment", .source_over);
    pipelines.monochrome_sprite = try createPipeline(device, library, "sprite_vertex", "mono_sprite_fragment", .source_over);
    pipelines.color_sprite = try createPipeline(device, library, "sprite_vertex", "color_sprite_fragment", .source_over);
    pipelines.path = try createPipeline(device, library, "path_vertex", "path_fragment", .source_over);
    pipelines.external_surface = try createPipeline(device, library, "external_surface_vertex", "external_surface_fragment", .source_over);
    pipelines.backdrop = try createPipeline(device, library, "backdrop_vertex", "backdrop_fragment", .replace);
    pipelines.composite = try createPipeline(device, library, "composite_vertex", "composite_fragment", .replace);
    pipelines.present = try createPipeline(device, library, "present_vertex", "present_fragment", .replace);
    return pipelines;
}

const PipelineBlend = enum { source_over, replace };

fn createPipeline(
    device: objc.Id,
    library: objc.Id,
    vertex_name: []const u8,
    fragment_name: []const u8,
    blend: PipelineBlend,
) Error!objc.Id {
    const vertex = objc.send(objc.Id, library, "newFunctionWithName:", .{objc.nsString(vertex_name)}) orelse return error.ShaderInvalid;
    defer release(vertex);
    const fragment = objc.send(objc.Id, library, "newFunctionWithName:", .{objc.nsString(fragment_name)}) orelse return error.ShaderInvalid;
    defer release(fragment);
    const descriptor = objc.send(objc.Id, objc.send(objc.Id, objc.class("MTLRenderPipelineDescriptor"), "alloc", .{}), "init", .{});
    defer release(descriptor);
    objc.send(void, descriptor, "setVertexFunction:", .{vertex});
    objc.send(void, descriptor, "setFragmentFunction:", .{fragment});
    const attachments = objc.send(objc.Id, descriptor, "colorAttachments", .{});
    const attachment = objc.send(objc.Id, attachments, "objectAtIndexedSubscript:", .{@as(usize, 0)});
    objc.send(void, attachment, "setPixelFormat:", .{@as(usize, 81)});
    objc.send(void, attachment, "setBlendingEnabled:", .{blend == .source_over});
    if (blend == .source_over) {
        objc.send(void, attachment, "setSourceRGBBlendFactor:", .{@as(usize, 1)});
        objc.send(void, attachment, "setDestinationRGBBlendFactor:", .{@as(usize, 5)});
        objc.send(void, attachment, "setSourceAlphaBlendFactor:", .{@as(usize, 1)});
        objc.send(void, attachment, "setDestinationAlphaBlendFactor:", .{@as(usize, 5)});
    }
    var error_object: objc.Id = null;
    return objc.send(objc.Id, device, "newRenderPipelineStateWithDescriptor:error:", .{ descriptor, &error_object }) orelse error.ShaderInvalid;
}

const LoadAction = enum(usize) { dont_care = 0, load = 1, clear = 2 };

fn copyTexture(
    command_buffer: objc.Id,
    source: objc.Id,
    destination: objc.Id,
    width: u32,
    height: u32,
) Error!void {
    const blit = objc.send(objc.Id, command_buffer, "blitCommandEncoder", .{}) orelse return error.DeviceLost;
    objc.send(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
        source,
        @as(usize, 0),
        @as(usize, 0),
        Origin{ .x = 0, .y = 0, .z = 0 },
        Extent{ .width = width, .height = height, .depth = 1 },
        destination,
        @as(usize, 0),
        @as(usize, 0),
        Origin{ .x = 0, .y = 0, .z = 0 },
    });
    objc.send(void, blit, "endEncoding", .{});
}

fn beginRenderEncoder(
    command_buffer: objc.Id,
    target: EncodeTarget,
    load_action: LoadAction,
    clear_color: ?geometry.Color,
    depth_target: ?DepthEncodeTarget,
) Error!objc.Id {
    const pass = objc.send(objc.Id, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{}) orelse return error.DeviceLost;
    const attachments = objc.send(objc.Id, pass, "colorAttachments", .{});
    const attachment = objc.send(objc.Id, attachments, "objectAtIndexedSubscript:", .{@as(usize, 0)});
    objc.send(void, attachment, "setTexture:", .{target.texture});
    objc.send(void, attachment, "setLoadAction:", .{@backingInt(load_action)});
    objc.send(void, attachment, "setStoreAction:", .{@as(usize, 1)});
    if (load_action == .clear) {
        const color = (clear_color orelse geometry.Color.transparent).premultiplied();
        objc.send(void, attachment, "setClearColor:", .{ClearColor{
            .red = color.r,
            .green = color.g,
            .blue = color.b,
            .alpha = color.a,
        }});
    }
    if (depth_target) |depth| {
        const depth_attachment = objc.send(objc.Id, pass, "depthAttachment", .{});
        objc.send(void, depth_attachment, "setTexture:", .{depth.texture});
        objc.send(void, depth_attachment, "setLoadAction:", .{@backingInt(if (depth.load) LoadAction.load else LoadAction.clear)});
        // A later custom pass may copy or load this attachment. Keep it alive
        // until the command buffer completes instead of discarding it here.
        objc.send(void, depth_attachment, "setStoreAction:", .{@as(usize, 1)});
        objc.send(void, depth_attachment, "setClearDepth:", .{@as(f64, depth.clear_depth)});
    }
    const encoder = objc.send(objc.Id, command_buffer, "renderCommandEncoderWithDescriptor:", .{pass}) orelse return error.DeviceLost;
    objc.send(void, encoder, "setScissorRect:", .{ScissorRect{
        .x = 0,
        .y = 0,
        .width = target.bounds.width,
        .height = target.bounds.height,
    }});
    return encoder;
}

fn cropLayerBounds(bounds: geometry.Rect, descriptor: api.FrameDescriptor) ?DeviceBounds {
    var left = clampedDeviceFloor(bounds.minX(), descriptor.scale_factor, descriptor.drawable_width);
    var top = clampedDeviceFloor(bounds.minY(), descriptor.scale_factor, descriptor.drawable_height);
    var right = clampedDeviceCeil(bounds.maxX(), descriptor.scale_factor, descriptor.drawable_width);
    var bottom = clampedDeviceCeil(bounds.maxY(), descriptor.scale_factor, descriptor.drawable_height);
    left -|= 1;
    top -|= 1;
    right = @min(descriptor.drawable_width, right +| 1);
    bottom = @min(descriptor.drawable_height, bottom +| 1);
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .width = right - left, .height = bottom - top };
}

fn cropToTarget(bounds: geometry.Rect, scale: geometry.ScaleFactor, target: DeviceBounds) ?DeviceBounds {
    if (bounds.isEmpty()) return null;
    const raw_left = @as(f64, bounds.minX()) * @as(f64, scale.value);
    const raw_top = @as(f64, bounds.minY()) * @as(f64, scale.value);
    const raw_right = @as(f64, bounds.maxX()) * @as(f64, scale.value);
    const raw_bottom = @as(f64, bounds.maxY()) * @as(f64, scale.value);
    if (!std.math.isFinite(raw_left) or !std.math.isFinite(raw_top) or
        !std.math.isFinite(raw_right) or !std.math.isFinite(raw_bottom)) return null;
    const target_left = @as(f64, @floatFromInt(target.left));
    const target_top = @as(f64, @floatFromInt(target.top));
    const target_right = @as(f64, @floatFromInt(target.right()));
    const target_bottom = @as(f64, @floatFromInt(target.bottom()));
    const left_value = @max(target_left, @min(target_right, raw_left));
    const top_value = @max(target_top, @min(target_bottom, raw_top));
    const right_value = @max(target_left, @min(target_right, raw_right));
    const bottom_value = @max(target_top, @min(target_bottom, raw_bottom));
    const left: u32 = @intFromFloat(@floor(left_value));
    const top: u32 = @intFromFloat(@floor(top_value));
    const right: u32 = @intFromFloat(@ceil(right_value));
    const bottom: u32 = @intFromFloat(@ceil(bottom_value));
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .width = right - left, .height = bottom - top };
}

fn expandRect(rect: geometry.Rect, amount: f32) geometry.Rect {
    return geometry.Rect.fromXYWH(
        rect.origin.x - amount,
        rect.origin.y - amount,
        rect.size.width + amount * 2,
        rect.size.height + amount * 2,
    );
}

fn clampedDeviceFloor(value: f32, scale: geometry.ScaleFactor, maximum: u32) u32 {
    const scaled = @as(f64, value) * @as(f64, scale.value);
    if (!std.math.isFinite(scaled)) return if (scaled > 0) maximum else 0;
    if (scaled <= 0) return 0;
    if (scaled >= @as(f64, @floatFromInt(maximum))) return maximum;
    return @intFromFloat(@floor(scaled));
}

fn clampedDeviceCeil(value: f32, scale: geometry.ScaleFactor, maximum: u32) u32 {
    const scaled = @as(f64, value) * @as(f64, scale.value);
    if (!std.math.isFinite(scaled)) return if (scaled > 0) maximum else 0;
    if (scaled <= 0) return 0;
    if (scaled >= @as(f64, @floatFromInt(maximum))) return maximum;
    return @intFromFloat(@ceil(scaled));
}

fn setClip(
    encoder: objc.Id,
    descriptor: api.FrameDescriptor,
    view: api.SceneView,
    clip_index: u32,
    target: DeviceBounds,
) Error!void {
    const bounds = try resolvedClipRect(descriptor, view, clip_index);
    const global_left = clampedDeviceFloor(bounds.minX(), descriptor.scale_factor, descriptor.drawable_width);
    const global_top = clampedDeviceFloor(bounds.minY(), descriptor.scale_factor, descriptor.drawable_height);
    const global_right = clampedDeviceCeil(bounds.maxX(), descriptor.scale_factor, descriptor.drawable_width);
    const global_bottom = clampedDeviceCeil(bounds.maxY(), descriptor.scale_factor, descriptor.drawable_height);
    const left = if (global_left <= target.left) 0 else @min(target.width, global_left - target.left);
    const top = if (global_top <= target.top) 0 else @min(target.height, global_top - target.top);
    const right = if (global_right <= target.left) 0 else @min(target.width, global_right - target.left);
    const bottom = if (global_bottom <= target.top) 0 else @min(target.height, global_bottom - target.top);
    objc.send(void, encoder, "setScissorRect:", .{ScissorRect{
        .x = @min(left, right),
        .y = @min(top, bottom),
        .width = @max(left, right) - @min(left, right),
        .height = @max(top, bottom) - @min(top, bottom),
    }});
}

fn resolvedClipRect(descriptor: api.FrameDescriptor, view: api.SceneView, clip_index: u32) Error!geometry.Rect {
    var bounds = geometry.Rect.fromXYWH(0, 0, descriptor.logical_size.width, descriptor.logical_size.height);
    var current = clip_index;
    while (current != scene.none_index) {
        if (current >= view.clips.len) return error.InvalidScene;
        const clip = view.clips[current];
        const transformed = layerTransform(view, clip.layer).transformRectBounds(clip.bounds);
        bounds = geometry.Rect.intersection(bounds, transformed) orelse .{};
        current = clip.parent;
    }
    return bounds;
}

fn pointerValue(value: objc.Id) usize {
    return if (value) |pointer| @intFromPtr(pointer) else 0;
}

fn layerTransform(view: api.SceneView, index: u32) geometry.Affine2D {
    if (index == scene.none_index) return .identity;
    var chain: [64]u32 = undefined;
    var count: usize = 0;
    var current = index;
    while (current != scene.none_index and current < view.layers.len and count < chain.len) {
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

fn convertReadback(
    allocator: std.mem.Allocator,
    target: api.OffscreenTarget,
    source: [*]const u8,
    source_stride: usize,
) Error!api.Readback {
    const bytes_per_pixel: usize = switch (target.format) {
        .a8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba16_float => 8,
    };
    const stride = std.math.mul(usize, target.width, bytes_per_pixel) catch return error.BudgetExceeded;
    const length = std.math.mul(usize, stride, target.height) catch return error.BudgetExceeded;
    const pixels = try allocator.alloc(u8, length);
    errdefer allocator.free(pixels);
    for (0..target.height) |y| {
        const source_row = source[y * source_stride ..][0 .. @as(usize, target.width) * 4];
        const destination = pixels[y * stride ..][0..stride];
        for (0..target.width) |x| {
            const source_offset = x * 4;
            const destination_offset = x * bytes_per_pixel;
            const blue = source_row[source_offset];
            const green = source_row[source_offset + 1];
            const red = source_row[source_offset + 2];
            const alpha = source_row[source_offset + 3];
            switch (target.format) {
                .a8 => destination[destination_offset] = alpha,
                .rgba8, .rgba8_srgb => {
                    const linear = target.format == .rgba8;
                    destination[destination_offset] = if (linear) srgbByteToLinearByte(red) else red;
                    destination[destination_offset + 1] = if (linear) srgbByteToLinearByte(green) else green;
                    destination[destination_offset + 2] = if (linear) srgbByteToLinearByte(blue) else blue;
                    destination[destination_offset + 3] = alpha;
                },
                .bgra8, .bgra8_srgb => if (target.format == .bgra8) {
                    destination[destination_offset] = srgbByteToLinearByte(blue);
                    destination[destination_offset + 1] = srgbByteToLinearByte(green);
                    destination[destination_offset + 2] = srgbByteToLinearByte(red);
                    destination[destination_offset + 3] = alpha;
                } else @memcpy(destination[destination_offset..][0..4], source_row[source_offset..][0..4]),
                .rgba16_float => {
                    writeHalf(destination[destination_offset..][0..2], srgbByteToLinear(red));
                    writeHalf(destination[destination_offset + 2 ..][0..2], srgbByteToLinear(green));
                    writeHalf(destination[destination_offset + 4 ..][0..2], srgbByteToLinear(blue));
                    writeHalf(destination[destination_offset + 6 ..][0..2], @as(f32, @floatFromInt(alpha)) / 255.0);
                },
            }
        }
    }
    return .{
        .width = target.width,
        .height = target.height,
        .stride = stride,
        .format = target.format,
        .pixels = pixels,
    };
}

fn writeHalf(destination: *[2]u8, value: f32) void {
    const bits: u16 = @bitCast(@as(f16, @floatCast(value)));
    std.mem.writeInt(u16, destination, bits, .little);
}

fn srgbByteToLinear(value: u8) f32 {
    const channel = @as(f32, @floatFromInt(value)) / 255.0;
    return if (channel <= 0.04045) channel / 12.92 else std.math.pow(f32, (channel + 0.055) / 1.055, 2.4);
}

fn srgbByteToLinearByte(value: u8) u8 {
    return @intFromFloat(@round(std.math.clamp(srgbByteToLinear(value), 0, 1) * 255));
}

fn retain(value: objc.Id) objc.Id {
    if (value != null) return objc.send(objc.Id, value, "retain", .{});
    return null;
}
fn release(value: objc.Id) void {
    if (value != null) objc.send(void, value, "release", .{});
}
