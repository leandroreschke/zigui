const std = @import("std");
const config = @import("../core/config.zig");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");

pub const SubmissionEpoch = u64;
pub const DeviceGeneration = u32;

pub const Capabilities = packed struct {
    subpixel_text: bool = false,
    external_surfaces: bool = false,
    offscreen_readback: bool = false,
    wide_color: bool = false,
    hdr: bool = false,
    timestamp_queries: bool = false,
    custom_materials: bool = false,
    _padding: u1 = 0,
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

pub const SceneView = struct {
    operations: []const @import("../scene/abi.zig").Operation,
    materials: []const @import("../scene/abi.zig").Material,
    gradient_stops: []const @import("../scene/abi.zig").GradientStop,
    clips: []const @import("../scene/abi.zig").Clip,
    layers: []const @import("../scene/abi.zig").Layer,
    shadows: []const @import("../scene/abi.zig").Shadow,
    quads: []const @import("../scene/abi.zig").Quad,
    paths: []const @import("../scene/abi.zig").Path,
    path_vertices: []const @import("../scene/abi.zig").PathVertex,
    underlines: []const @import("../scene/abi.zig").Underline,
    monochrome_sprites: []const @import("../scene/abi.zig").Sprite,
    color_sprites: []const @import("../scene/abi.zig").Sprite,
    external_surfaces: []const @import("../scene/abi.zig").ExternalSurface,
    custom_passes: []const @import("../scene/abi.zig").CustomPass,
    custom_payload: []const u8,
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

    pub fn beginFrame(self: Renderer, descriptor: FrameDescriptor) Error!FrameToken {
        try validateFrameDescriptor(descriptor);
        const result = try self.vtable.begin_frame(self.context, descriptor);
        if (result.value == 0 or result.device_generation == 0 or
            result.device_generation != self.deviceGeneration()) return error.PlatformFailure;
        return result;
    }

    pub fn submit(self: Renderer, token: FrameToken, scene: SceneView) Error!Submission {
        if (token.value == 0 or token.device_generation == 0) return error.InvalidHandle;
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
        var result = try self.vtable.render_offscreen(self.context, target, scene, allocator);
        if (target.readback and result == null) return error.PlatformFailure;
        if (result) |*readback| validateReadback(target, readback.*) catch |err| {
            readback.deinit(allocator);
            return err;
        };
        return result;
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

    pub fn registerExtension(self: Renderer, descriptor: @import("extension.zig").Descriptor) Error!handles.RenderExtensionId {
        if (!validLabel(descriptor.label)) return error.InvalidConfiguration;
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
