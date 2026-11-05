const std = @import("std");
const config = @import("../core/config.zig");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const extension = @import("extension.zig");
const scene_abi = @import("../scene/abi.zig");

pub const SubmissionEpoch = u64;
pub const DeviceGeneration = u32;

pub const Capabilities = packed struct {
    subpixel_text: bool = false,
    external_surfaces: bool = false,
    offscreen_readback: bool = false,
    offscreen_async_readback: bool = false,
    wide_color: bool = false,
    hdr: bool = false,
    timestamp_queries: bool = false,
    custom_materials: bool = false,
    backdrop_effects: bool = false,
};

pub const SurfaceState = enum {
    uncreated,
    created,
    awaiting_configure,
    configured,
    resizing,
    suspended_or_zero_sized,
    frame_pending,
    surface_lost,
    device_lost,
    closing,
    closed,
};

pub const FrameDescriptor = struct {
    window: handles.WindowId,
    logical_size: geometry.Size,
    drawable_width: u32,
    drawable_height: u32,
    scale_factor: geometry.ScaleFactor,
    clear_color: geometry.Color,
    /// Hard upper bound for backend upload buffers produced by this frame.
    maximum_upload_bytes: usize = 32 * 1024 * 1024,
};

pub const FrameToken = struct {
    value: u64,
    device_generation: DeviceGeneration,
};

pub const Submission = struct {
    epoch: SubmissionEpoch,
    device_generation: DeviceGeneration,
    presented: bool,
};

pub const OffscreenTarget = struct {
    width: u32,
    height: u32,
    scale_factor: geometry.ScaleFactor,
    format: PixelFormat = .bgra8_srgb,
    readback: bool = true,
};

/// Stable identity for an asynchronous offscreen submission. IDs are owned
/// by one Renderer and are never reused while a request is live.
pub const OffscreenRequestId = u64;

/// A non-blocking result from an asynchronous offscreen request. `ready` is
/// the sole owner of the returned pixel bytes; callers must deinitialize it
/// with the allocator passed to `Renderer.pollOffscreen`. Terminal results
/// are consumed exactly once, so polling an already-consumed request returns
/// `error.InvalidHandle`.
pub const OffscreenPoll = union(enum) {
    pending,
    ready: Readback,
    failed: Error,
    cancelled,
};

pub const PixelFormat = enum { a8, rgba8, rgba8_srgb, bgra8, bgra8_srgb, rgba16_float };
pub const TextureUsage = enum { sampled, render_target, external, atlas };

pub const ColorSpace = enum(u32) {
    srgb,
    linear_srgb,
    display_p3,
    extended_linear_srgb,
    rec2020_pq,
    rec2020_hlg,
    unknown,
};

pub const VulkanImageSurface = struct {
    image: u64,
    image_view: u64,
    layout: u32,
    device_memory: u64 = 0,
};

pub const DmaBufSurface = struct {
    file_descriptor: i32,
    modifier: u64,
    stride: u32,
    offset: u32 = 0,
    fourcc: u32,
};

/// A borrowed native image owned by the application or a media provider. ZigUI
/// retains/imports the object until `destroyExternalSurface` becomes safe.
pub const NativeSurface = union(enum) {
    metal_texture: usize,
    d3d11_texture: usize,
    vulkan_image: VulkanImageSurface,
    dma_buf: DmaBufSurface,
};

pub const ExternalSurfaceDescriptor = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    color_space: ColorSpace = .srgb,
    native: NativeSurface,
};

pub const TextureDescriptor = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    usage: TextureUsage = .sampled,

    pub fn byteLength(self: TextureDescriptor) Error!usize {
        const bytes_per_pixel: usize = switch (self.format) {
            .a8 => 1,
            .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
            .rgba16_float => 8,
        };
        const pixels = std.math.mul(usize, self.width, self.height) catch return error.BudgetExceeded;
        return std.math.mul(usize, pixels, bytes_per_pixel) catch return error.BudgetExceeded;
    }
};

pub const TextureRegion = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
};

pub const Readback = struct {
    width: u32,
    height: u32,
    stride: usize,
    format: PixelFormat,
    pixels: []const u8,

    pub fn deinit(self: *Readback, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.pixels));
        self.* = undefined;
    }
};

/// Owned copy of every borrowed slice in a SceneView. Backends use this at
/// asynchronous submission boundaries so a caller may rebuild or destroy its
/// Scene immediately after `beginOffscreen` returns.
pub const SceneSnapshot = struct {
    allocator: std.mem.Allocator,
    operations: []scene_abi.Operation = &.{},
    materials: []scene_abi.Material = &.{},
    gradient_stops: []scene_abi.GradientStop = &.{},
    clips: []scene_abi.Clip = &.{},
    layers: []scene_abi.Layer = &.{},
    shadows: []scene_abi.Shadow = &.{},
    quads: []scene_abi.Quad = &.{},
    paths: []scene_abi.Path = &.{},
    path_vertices: []scene_abi.PathVertex = &.{},
    underlines: []scene_abi.Underline = &.{},
    monochrome_sprites: []scene_abi.Sprite = &.{},
    color_sprites: []scene_abi.Sprite = &.{},
    external_surfaces: []scene_abi.ExternalSurface = &.{},
    custom_passes: []scene_abi.CustomPass = &.{},
    custom_payload: []u8 = &.{},
    backdrop_effects: []scene_abi.BackdropEffect = &.{},

    pub fn init(allocator: std.mem.Allocator, source: SceneView) Error!SceneSnapshot {
        var snapshot: SceneSnapshot = .{ .allocator = allocator };
        errdefer snapshot.deinit();
        snapshot.operations = try allocator.dupe(scene_abi.Operation, source.operations);
        snapshot.materials = try allocator.dupe(scene_abi.Material, source.materials);
        snapshot.gradient_stops = try allocator.dupe(scene_abi.GradientStop, source.gradient_stops);
        snapshot.clips = try allocator.dupe(scene_abi.Clip, source.clips);
        snapshot.layers = try allocator.dupe(scene_abi.Layer, source.layers);
        snapshot.shadows = try allocator.dupe(scene_abi.Shadow, source.shadows);
        snapshot.quads = try allocator.dupe(scene_abi.Quad, source.quads);
        snapshot.paths = try allocator.dupe(scene_abi.Path, source.paths);
        snapshot.path_vertices = try allocator.dupe(scene_abi.PathVertex, source.path_vertices);
        snapshot.underlines = try allocator.dupe(scene_abi.Underline, source.underlines);
        snapshot.monochrome_sprites = try allocator.dupe(scene_abi.Sprite, source.monochrome_sprites);
        snapshot.color_sprites = try allocator.dupe(scene_abi.Sprite, source.color_sprites);
        snapshot.external_surfaces = try allocator.dupe(scene_abi.ExternalSurface, source.external_surfaces);
        snapshot.custom_passes = try allocator.dupe(scene_abi.CustomPass, source.custom_passes);
        snapshot.custom_payload = try allocator.dupe(u8, source.custom_payload);
        snapshot.backdrop_effects = try allocator.dupe(scene_abi.BackdropEffect, source.backdrop_effects);
        return snapshot;
    }

    pub fn view(self: *const SceneSnapshot) SceneView {
        return .{
            .operations = self.operations,
            .materials = self.materials,
            .gradient_stops = self.gradient_stops,
            .clips = self.clips,
            .layers = self.layers,
            .shadows = self.shadows,
            .quads = self.quads,
            .paths = self.paths,
            .path_vertices = self.path_vertices,
            .underlines = self.underlines,
            .monochrome_sprites = self.monochrome_sprites,
            .color_sprites = self.color_sprites,
            .external_surfaces = self.external_surfaces,
            .custom_passes = self.custom_passes,
            .custom_payload = self.custom_payload,
            .backdrop_effects = self.backdrop_effects,
        };
    }

    pub fn deinit(self: *SceneSnapshot) void {
        self.allocator.free(self.operations);
        self.allocator.free(self.materials);
        self.allocator.free(self.gradient_stops);
        self.allocator.free(self.clips);
        self.allocator.free(self.layers);
        self.allocator.free(self.shadows);
        self.allocator.free(self.quads);
        self.allocator.free(self.paths);
        self.allocator.free(self.path_vertices);
        self.allocator.free(self.underlines);
        self.allocator.free(self.monochrome_sprites);
        self.allocator.free(self.color_sprites);
        self.allocator.free(self.external_surfaces);
        self.allocator.free(self.custom_passes);
        self.allocator.free(self.custom_payload);
        self.allocator.free(self.backdrop_effects);
        self.* = undefined;
    }
};

pub const SceneView = struct {
    operations: []const scene_abi.Operation,
    materials: []const scene_abi.Material,
    gradient_stops: []const scene_abi.GradientStop,
    clips: []const scene_abi.Clip,
    layers: []const scene_abi.Layer,
    shadows: []const scene_abi.Shadow,
    quads: []const scene_abi.Quad,
    paths: []const scene_abi.Path,
    path_vertices: []const scene_abi.PathVertex,
    underlines: []const scene_abi.Underline,
    monochrome_sprites: []const scene_abi.Sprite,
    color_sprites: []const scene_abi.Sprite,
    external_surfaces: []const scene_abi.ExternalSurface,
    custom_passes: []const scene_abi.CustomPass,
    custom_payload: []const u8,
    backdrop_effects: []const scene_abi.BackdropEffect = &.{},

    pub fn requiresBackdropEffects(self: SceneView) bool {
        for (self.operations) |operation| {
            if (operation.kind == @backingInt(@import("../scene/abi.zig").OperationKind.backdrop_effect)) return true;
        }
        return false;
    }
};

/// Computes the bytes uploaded by the structured-buffer backends after path
/// tessellation and clip resolution. Custom extensions own and budget their
/// payloads independently through their descriptor contract.
pub fn structuredUploadBytes(view: SceneView, path_bytes: usize, clip_bytes: usize) Error!usize {
    var total: usize = 0;
    inline for (.{
        std.mem.sliceAsBytes(view.materials).len,
        std.mem.sliceAsBytes(view.gradient_stops).len,
        std.mem.sliceAsBytes(view.quads).len,
        std.mem.sliceAsBytes(view.shadows).len,
        std.mem.sliceAsBytes(view.underlines).len,
        std.mem.sliceAsBytes(view.monochrome_sprites).len,
        std.mem.sliceAsBytes(view.color_sprites).len,
        std.mem.sliceAsBytes(view.external_surfaces).len,
        path_bytes,
        clip_bytes,
    }) |amount| total = std.math.add(usize, total, amount) catch return error.BudgetExceeded;
    return total;
}

pub const Renderer = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        capabilities: *const fn (*anyopaque) Capabilities,
        device_generation: *const fn (*anyopaque) DeviceGeneration,
        begin_frame: *const fn (*anyopaque, FrameDescriptor) Error!FrameToken,
        submit: *const fn (*anyopaque, FrameToken, SceneView) Error!Submission,
        render_offscreen: *const fn (*anyopaque, OffscreenTarget, SceneView, std.mem.Allocator) Error!?Readback,
        /// Optional non-blocking offscreen path. Backends that do not provide
        /// asynchronous GPU readback leave these hooks null and the public
        /// methods return `error.Unsupported`.
        begin_offscreen: ?*const fn (*anyopaque, OffscreenTarget, SceneView) Error!OffscreenRequestId = null,
        poll_offscreen: ?*const fn (*anyopaque, OffscreenRequestId, std.mem.Allocator) Error!OffscreenPoll = null,
        cancel_offscreen: ?*const fn (*anyopaque, OffscreenRequestId) Error!void = null,
        drain_offscreen: ?*const fn (*anyopaque) void = null,
        completed_epoch: *const fn (*anyopaque) SubmissionEpoch,
        invalidate_surface: *const fn (*anyopaque, handles.WindowId) Error!void,
        recover: *const fn (*anyopaque, config.GpuPolicy) Error!void,
        create_texture: *const fn (*anyopaque, handles.TextureId, TextureDescriptor) Error!void,
        write_texture: *const fn (*anyopaque, handles.TextureId, TextureRegion, []const u8, usize) Error!void,
        destroy_texture: *const fn (*anyopaque, handles.TextureId, SubmissionEpoch) Error!void,
        import_external_surface: *const fn (*anyopaque, handles.SurfaceId, ExternalSurfaceDescriptor) Error!void,
        replace_external_surface: *const fn (*anyopaque, handles.SurfaceId, ExternalSurfaceDescriptor, SubmissionEpoch) Error!void,
        destroy_external_surface: *const fn (*anyopaque, handles.SurfaceId, SubmissionEpoch) Error!void,
        register_extension: *const fn (*anyopaque, @import("extension.zig").Descriptor) Error!handles.RenderExtensionId,
        destroy_extension: *const fn (*anyopaque, handles.RenderExtensionId, SubmissionEpoch) Error!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn capabilities(self: Renderer) Capabilities {
        return self.vtable.capabilities(self.context);
    }

    pub fn deviceGeneration(self: Renderer) DeviceGeneration {
        return self.vtable.device_generation(self.context);
    }

    /// FrameNotReady is transient backpressure: preserve invalidations and
    /// retry on a later display tick without consuming a frame token.
    pub fn beginFrame(self: Renderer, descriptor: FrameDescriptor) Error!FrameToken {
        try validateFrameDescriptor(descriptor);
        const result = try self.vtable.begin_frame(self.context, descriptor);
        if (result.value == 0 or result.device_generation == 0 or
            result.device_generation != self.deviceGeneration()) return error.PlatformFailure;
        return result;
    }

    pub fn submit(self: Renderer, token: FrameToken, scene: SceneView) Error!Submission {
        if (token.value == 0 or token.device_generation == 0) return error.InvalidHandle;
        if (scene.requiresBackdropEffects() and !self.capabilities().backdrop_effects) return error.Unsupported;
        const result = try self.vtable.submit(self.context, token, scene);
        if (result.epoch == 0 or result.device_generation == 0 or
            result.device_generation != token.device_generation) return error.PlatformFailure;
        return result;
    }

    pub fn renderOffscreen(
        self: Renderer,
        target: OffscreenTarget,
        scene: SceneView,
        allocator: std.mem.Allocator,
    ) Error!?Readback {
        try validateOffscreenTarget(target);
        if (scene.requiresBackdropEffects() and !self.capabilities().backdrop_effects) return error.Unsupported;
        var result = try self.vtable.render_offscreen(self.context, target, scene, allocator);
        if (target.readback and result == null) return error.PlatformFailure;
        if (result) |*readback| validateReadback(target, readback.*) catch |err| {
            readback.deinit(allocator);
            return err;
        };
        return result;
    }

    /// Begins a bounded asynchronous offscreen render. The backend must copy
    /// every borrowed SceneView slice before returning; after this call the
    /// caller may rebuild or destroy the source Scene immediately. No GPU
    /// completion wait is permitted on this path.
    pub fn beginOffscreen(self: Renderer, target: OffscreenTarget, scene: SceneView) Error!OffscreenRequestId {
        try validateOffscreenTarget(target);
        if (!target.readback) return error.InvalidConfiguration;
        if (scene.requiresBackdropEffects() and !self.capabilities().backdrop_effects) return error.Unsupported;
        if (!self.capabilities().offscreen_async_readback) return error.Unsupported;
        const begin = self.vtable.begin_offscreen orelse return error.Unsupported;
        const id = try begin(self.context, target, scene);
        if (id == 0) return error.PlatformFailure;
        return id;
    }

    /// Polls one asynchronous request without waiting for the GPU. A terminal
    /// result consumes the request exactly once; `ready` owns its returned
    /// pixels and must be deinitialized by the caller.
    pub fn pollOffscreen(
        self: Renderer,
        id: OffscreenRequestId,
        allocator: std.mem.Allocator,
    ) Error!OffscreenPoll {
        if (id == 0) return error.InvalidHandle;
        const poll = self.vtable.poll_offscreen orelse return error.Unsupported;
        return poll(self.context, id, allocator);
    }

    /// Requests cancellation without waiting. A cancelled request remains
    /// owned by the backend until its GPU submission reaches a terminal state.
    pub fn cancelOffscreen(self: Renderer, id: OffscreenRequestId) Error!void {
        if (id == 0) return error.InvalidHandle;
        const cancel = self.vtable.cancel_offscreen orelse return error.Unsupported;
        return cancel(self.context, id);
    }

    /// Teardown-only drain. Implementations may wait for GPU work here; this
    /// method is never used by the frame path and exists to establish that no
    /// request retains backend resources before renderer destruction.
    pub fn drainOffscreen(self: Renderer) void {
        if (self.vtable.drain_offscreen) |drain| drain(self.context);
    }

    pub fn completedEpoch(self: Renderer) SubmissionEpoch {
        return self.vtable.completed_epoch(self.context);
    }

    /// Retires only the presentation resources associated with one window.
    /// Textures, atlases, pipelines, and the device generation remain valid.
    pub fn invalidateSurface(self: Renderer, window: handles.WindowId) Error!void {
        if (!window.isValid()) return error.InvalidHandle;
        try self.vtable.invalidate_surface(self.context, window);
    }

    pub fn recover(self: Renderer, policy: config.GpuPolicy) Error!void {
        try validateGpuPolicy(policy);
        return self.vtable.recover(self.context, policy);
    }

    pub fn createTexture(self: Renderer, id: handles.TextureId, descriptor: TextureDescriptor) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try validateTextureDescriptor(descriptor);
        try self.vtable.create_texture(self.context, id, descriptor);
    }

    pub fn writeTexture(
        self: Renderer,
        id: handles.TextureId,
        region: TextureRegion,
        pixels: []const u8,
        stride: usize,
    ) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        if (region.width == 0 or region.height == 0) return;
        if (stride == 0) return error.InvalidConfiguration;
        const required = std.math.mul(usize, stride, region.height) catch return error.BudgetExceeded;
        if (pixels.len < required) return error.InvalidConfiguration;
        try self.vtable.write_texture(self.context, id, region, pixels, stride);
    }

    pub fn destroyTexture(self: Renderer, id: handles.TextureId, release_after: SubmissionEpoch) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.vtable.destroy_texture(self.context, id, release_after);
    }

    pub fn importExternalSurface(self: Renderer, id: handles.SurfaceId, descriptor: ExternalSurfaceDescriptor) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try validateExternalSurfaceDescriptor(descriptor);
        try self.vtable.import_external_surface(self.context, id, descriptor);
    }

    pub fn replaceExternalSurface(
        self: Renderer,
        id: handles.SurfaceId,
        descriptor: ExternalSurfaceDescriptor,
        release_after: SubmissionEpoch,
    ) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try validateExternalSurfaceDescriptor(descriptor);
        try self.vtable.replace_external_surface(self.context, id, descriptor, release_after);
    }

    pub fn destroyExternalSurface(self: Renderer, id: handles.SurfaceId, release_after: SubmissionEpoch) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.vtable.destroy_external_surface(self.context, id, release_after);
    }

    pub fn registerExtension(self: Renderer, descriptor: extension.Descriptor) Error!handles.RenderExtensionId {
        if (!validLabel(descriptor.label)) return error.InvalidConfiguration;
        try extension.validateRequirements(descriptor.requirements);
        const result = try self.vtable.register_extension(self.context, descriptor);
        if (!result.isValid()) return error.PlatformFailure;
        return result;
    }

    pub fn destroyExtension(self: Renderer, id: handles.RenderExtensionId, release_after: SubmissionEpoch) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.vtable.destroy_extension(self.context, id, release_after);
    }

    pub fn deinit(self: Renderer) void {
        self.vtable.deinit(self.context);
    }
};

pub fn validateFrameDescriptor(descriptor: FrameDescriptor) Error!void {
    if (!descriptor.window.isValid()) return error.InvalidHandle;
    if (!validPositiveSize(descriptor.logical_size) or descriptor.drawable_width == 0 or
        descriptor.drawable_height == 0 or !validScale(descriptor.scale_factor) or
        !validColor(descriptor.clear_color) or descriptor.maximum_upload_bytes == 0)
        return error.InvalidConfiguration;
}

pub fn validateOffscreenTarget(target: OffscreenTarget) Error!void {
    if (target.width == 0 or target.height == 0 or !validScale(target.scale_factor))
        return error.InvalidConfiguration;
    const pixels = std.math.mul(usize, target.width, target.height) catch return error.BudgetExceeded;
    _ = std.math.mul(usize, pixels, bytesPerPixel(target.format)) catch return error.BudgetExceeded;
}

pub fn validateTextureDescriptor(descriptor: TextureDescriptor) Error!void {
    if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
    _ = try descriptor.byteLength();
}

pub fn validateExternalSurfaceDescriptor(descriptor: ExternalSurfaceDescriptor) Error!void {
    if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
    switch (descriptor.native) {
        .metal_texture, .d3d11_texture => |handle| if (handle == 0) return error.InvalidHandle,
        .vulkan_image => |image| if (image.image == 0 or image.image_view == 0) return error.InvalidHandle,
        .dma_buf => |buffer| {
            const row_bytes = std.math.mul(usize, descriptor.width, bytesPerPixel(descriptor.format)) catch
                return error.BudgetExceeded;
            if (buffer.file_descriptor < 0 or @as(usize, buffer.stride) < row_bytes or buffer.fourcc == 0)
                return error.InvalidConfiguration;
        },
    }
}

pub fn validateGpuPolicy(policy: config.GpuPolicy) Error!void {
    if (policy.maximum_gpu_bytes == 0 or policy.frames_in_flight == 0 or policy.frames_in_flight > 8)
        return error.InvalidConfiguration;
}

fn validateReadback(target: OffscreenTarget, readback: Readback) Error!void {
    if (!target.readback or readback.width != target.width or readback.height != target.height or
        readback.format != target.format)
        return error.PlatformFailure;
    const row_bytes = std.math.mul(usize, readback.width, bytesPerPixel(readback.format)) catch
        return error.PlatformFailure;
    if (readback.stride < row_bytes) return error.PlatformFailure;
    const required = std.math.mul(usize, readback.stride, readback.height) catch
        return error.PlatformFailure;
    if (readback.pixels.len < required) return error.PlatformFailure;
}

fn bytesPerPixel(format: PixelFormat) usize {
    return switch (format) {
        .a8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba16_float => 8,
    };
}

fn validPositiveSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and
        value.width > 0 and value.height > 0;
}

fn validScale(value: geometry.ScaleFactor) bool {
    return std.math.isFinite(value.value) and value.value > 0;
}

fn validColor(value: geometry.Color) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and
        std.math.isFinite(value.b) and std.math.isFinite(value.a) and
        value.a >= 0 and value.a <= 1;
}

fn validLabel(value: []const u8) bool {
    return value.len <= 4096 and std.unicode.utf8ValidateSlice(value) and
        std.mem.indexOfScalar(u8, value, 0) == null;
}
