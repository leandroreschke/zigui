const std = @import("std");
const config = @import("../../config.zig");
const Error = @import("../../core/error.zig").Error;
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const api = @import("../../render/api.zig");
const extension = @import("../../render/extension.zig");
const layer_plan = @import("../../render/layer_plan.zig");
const path_tessellator = @import("../../render/path_tessellator.zig");
const scene = @import("../../scene/scene.zig");
const scene_abi = @import("../../scene/abi.zig");
const surface = @import("../../platform/windows/surface.zig");
const abi = @import("abi.zig");
const compiler = @import("compiler.zig");

const shader_source = @embedFile("zigui_hlsl_source");
const no_alt_enter: u32 = 0x2;

const Globals = extern struct {
    viewport: [2]f32,
    viewport_origin: [2]f32,
    transform_x: [4]f32,
    transform_y: [4]f32,
    composite_origin: [2]f32,
    composite_size: [2]f32,
    payload_start: u32,
    material_index: u32,
    clip_index: u32,
    operation_kind: u32,
    opacity: f32,
    blend_mode: u32,
    padding: [2]u32 = .{ 0, 0 },
};

const ResolvedClip = extern struct {
    bounds: geometry.Rect,
    radii: geometry.CornerRadii,
    parent: u32,
    reserved: [3]u32 = .{ 0, 0, 0 },
    inverse_transform: geometry.Affine2D,
};

comptime {
    std.debug.assert(@sizeOf(Globals) == 96);
    std.debug.assert(@sizeOf(ResolvedClip) == 72);
}

const DeviceSet = struct {
    device: *abi.Object,
    context: *abi.Object,
    factory: *abi.Object,
    feature_level: u32,

    fn create(policy: config.GpuPolicy) Error!DeviceSet {
        const flags = abi.create_device_bgra_support | (if (policy.validation) abi.create_device_debug else 0);
        const hardware = createDeviceForDriver(abi.driver_type_hardware, flags) catch |hardware_error| fallback: {
            if (policy.software_fallback == .forbidden) return hardware_error;
            break :fallback try createDeviceForDriver(abi.driver_type_warp, flags);
        };
        errdefer {
            abi.com.release(hardware.context);
            abi.com.release(hardware.device);
        }
        var factory: ?*abi.Object = null;
        if (abi.CreateDXGIFactory1(&abi.iid_factory1, &factory) < 0) return error.PlatformFailure;
        return .{
            .device = hardware.device,
            .context = hardware.context,
            .factory = factory orelse return error.PlatformFailure,
            .feature_level = hardware.feature_level,
        };
    }

    fn deinit(self: *DeviceSet) void {
        abi.clearState(self.context);
        abi.com.release(self.factory);
        abi.com.release(self.context);
        abi.com.release(self.device);
        self.* = undefined;
    }
};

const CreatedDevice = struct { device: *abi.Object, context: *abi.Object, feature_level: u32 };

fn createDeviceForDriver(driver: u32, flags: u32) Error!CreatedDevice {
    const levels = [_]u32{ abi.feature_level_11_1, abi.feature_level_11_0 };
    var device: ?*abi.Object = null;
    var context: ?*abi.Object = null;
    var selected: u32 = 0;
    var status = abi.D3D11CreateDevice(null, driver, null, flags, &levels, levels.len, abi.sdk_version, &device, &selected, &context);
    if (status == abi.dxgi_error_invalid_call or status == @as(abi.HRESULT, @bitCast(@as(u32, 0x80070057)))) {
        status = abi.D3D11CreateDevice(null, driver, null, flags, levels[1..].ptr, 1, abi.sdk_version, &device, &selected, &context);
    }
    if (status < 0) return error.NoGpuDevice;
    if (selected < abi.feature_level_11_0) {
        abi.com.release(context);
        abi.com.release(device);
        return error.NoGpuDevice;
    }
    return .{ .device = device orelse return error.NoGpuDevice, .context = context orelse return error.NoGpuDevice, .feature_level = selected };
}

const ShaderPair = struct {
    vertex: ?*abi.Object = null,
    pixel: ?*abi.Object = null,

    fn create(device: *abi.Object, tool: compiler.Compiler, vertex_entry: [*:0]const u8, pixel_entry: [*:0]const u8) Error!ShaderPair {
        var vertex_code = try tool.compile(shader_source, vertex_entry, "vs_5_0");
        defer vertex_code.deinit();
        var pixel_code = try tool.compile(shader_source, pixel_entry, "ps_5_0");
        defer pixel_code.deinit();
        const vertex_bytes = vertex_code.bytes();
        const pixel_bytes = pixel_code.bytes();
        if (vertex_bytes.len == 0 or pixel_bytes.len == 0) return error.ShaderInvalid;
        var vertex: ?*abi.Object = null;
        if (abi.createVertexShader(device, vertex_bytes.ptr, vertex_bytes.len, null, &vertex) < 0) return error.ShaderInvalid;
        errdefer abi.com.release(vertex);
        var pixel: ?*abi.Object = null;
        if (abi.createPixelShader(device, pixel_bytes.ptr, pixel_bytes.len, null, &pixel) < 0) return error.ShaderInvalid;
        return .{ .vertex = vertex, .pixel = pixel };
    }

    fn deinit(self: *ShaderPair) void {
        abi.com.release(self.pixel);
        abi.com.release(self.vertex);
        self.* = .{};
    }
};

const Pipelines = struct {
    quad: ShaderPair = .{},
    shadow: ShaderPair = .{},
    underline: ShaderPair = .{},
    monochrome_sprite: ShaderPair = .{},
    color_sprite: ShaderPair = .{},
    path: ShaderPair = .{},
    external_surface: ShaderPair = .{},
    composite: ShaderPair = .{},
    source_over: ?*abi.Object = null,
    replace: ?*abi.Object = null,
    rasterizer: ?*abi.Object = null,
    sampler: ?*abi.Object = null,

    fn create(device: *abi.Object) Error!Pipelines {
        var tool = try compiler.Compiler.load();
        defer tool.deinit();
        var result: Pipelines = .{};
        errdefer result.deinit();
        result.quad = try ShaderPair.create(device, tool, "quad_vertex", "quad_fragment");
        result.shadow = try ShaderPair.create(device, tool, "shadow_vertex", "shadow_fragment");
        result.underline = try ShaderPair.create(device, tool, "underline_vertex", "underline_fragment");
        result.monochrome_sprite = try ShaderPair.create(device, tool, "sprite_vertex", "mono_sprite_fragment");
        result.color_sprite = try ShaderPair.create(device, tool, "sprite_vertex", "color_sprite_fragment");
        result.path = try ShaderPair.create(device, tool, "path_vertex", "path_fragment");
        result.external_surface = try ShaderPair.create(device, tool, "external_surface_vertex", "external_surface_fragment");
        result.composite = try ShaderPair.create(device, tool, "composite_vertex", "composite_fragment");
        var source_over_descriptor: abi.BlendDesc = .{};
        source_over_descriptor.render_target[0].source_blend = abi.blend_one;
        source_over_descriptor.render_target[0].destination_blend = abi.blend_inv_source_alpha;
        source_over_descriptor.render_target[0].source_blend_alpha = abi.blend_one;
        source_over_descriptor.render_target[0].destination_blend_alpha = abi.blend_inv_source_alpha;
        if (abi.createBlendState(device, &source_over_descriptor, &result.source_over) < 0) return error.ShaderInvalid;
        var replace_descriptor: abi.BlendDesc = .{};
        replace_descriptor.render_target[0].blend_enable = 0;
        if (abi.createBlendState(device, &replace_descriptor, &result.replace) < 0) return error.ShaderInvalid;
        const rasterizer_descriptor: abi.RasterizerDesc = .{};
        if (abi.createRasterizerState(device, &rasterizer_descriptor, &result.rasterizer) < 0) return error.ShaderInvalid;
        const sampler_descriptor: abi.SamplerDesc = .{};
        if (abi.createSamplerState(device, &sampler_descriptor, &result.sampler) < 0) return error.ShaderInvalid;
        return result;
    }

    fn deinit(self: *Pipelines) void {
        self.quad.deinit();
        self.shadow.deinit();
        self.underline.deinit();
        self.monochrome_sprite.deinit();
        self.color_sprite.deinit();
        self.path.deinit();
        self.external_surface.deinit();
        self.composite.deinit();
        abi.com.release(self.source_over);
        abi.com.release(self.replace);
        abi.com.release(self.rasterizer);
        abi.com.release(self.sampler);
        self.* = .{};
    }
};

const GpuBuffer = struct {
    buffer: ?*abi.Object = null,
    view: ?*abi.Object = null,
    capacity: usize = 0,
    stride: usize = 0,

    fn upload(self: *GpuBuffer, device: *abi.Object, context: *abi.Object, bytes: []const u8, stride: usize) Error!?*abi.Object {
        if (bytes.len == 0) return null;
        if (stride == 0 or bytes.len % stride != 0) return error.InvalidShaderAbi;
        if (self.buffer == null or self.stride != stride or self.capacity < bytes.len) try self.grow(device, bytes.len, stride);
        var mapped: abi.MappedSubresource = undefined;
        if (abi.map(context, self.buffer.?, 0, abi.map_write_discard, 0, &mapped) < 0) return error.DeviceLost;
        defer abi.unmap(context, self.buffer.?, 0);
        const destination = mapped.data orelse return error.DeviceLost;
        @memcpy(@as([*]u8, @ptrCast(destination))[0..bytes.len], bytes);
        return self.view;
    }

    fn grow(self: *GpuBuffer, device: *abi.Object, required: usize, stride: usize) Error!void {
        var item_capacity: usize = @max(@as(usize, 16), if (self.stride == stride) self.capacity / stride else 0);
        const required_items = (required + stride - 1) / stride;
        while (item_capacity < required_items) item_capacity = std.math.mul(usize, item_capacity, 2) catch return error.BudgetExceeded;
        const capacity = std.math.mul(usize, item_capacity, stride) catch return error.BudgetExceeded;
        if (capacity > std.math.maxInt(u32)) return error.BudgetExceeded;
        const descriptor: abi.BufferDesc = .{
            .byte_width = @intCast(capacity),
            .usage = abi.usage_dynamic,
            .bind_flags = abi.bind_shader_resource,
            .cpu_access_flags = abi.cpu_access_write,
            .misc_flags = abi.resource_misc_buffer_structured,
            .structure_byte_stride = @intCast(stride),
        };
        var buffer: ?*abi.Object = null;
        if (abi.createBuffer(device, &descriptor, null, &buffer) < 0) return error.BudgetExceeded;
        errdefer abi.com.release(buffer);
        const view_descriptor = abi.ShaderResourceViewDesc.buffer(@intCast(item_capacity));
        var view: ?*abi.Object = null;
        if (abi.createShaderResourceView(device, buffer.?, &view_descriptor, &view) < 0) return error.BudgetExceeded;
        abi.com.release(self.view);
        abi.com.release(self.buffer);
        self.* = .{ .buffer = buffer, .view = view, .capacity = capacity, .stride = stride };
    }

    fn deinit(self: *GpuBuffer) void {
        abi.com.release(self.view);
        abi.com.release(self.buffer);
        self.* = .{};
    }
};

const ConstantBuffer = struct {
    buffer: ?*abi.Object = null,

    fn init(self: *ConstantBuffer, device: *abi.Object) Error!void {
        const descriptor: abi.BufferDesc = .{
            .byte_width = @sizeOf(Globals),
            .usage = abi.usage_dynamic,
            .bind_flags = abi.bind_constant_buffer,
            .cpu_access_flags = abi.cpu_access_write,
            .misc_flags = 0,
            .structure_byte_stride = 0,
        };
        if (abi.createBuffer(device, &descriptor, null, &self.buffer) < 0) return error.BudgetExceeded;
    }

    fn upload(self: ConstantBuffer, context: *abi.Object, value: *const Globals) Error!void {
        var mapped: abi.MappedSubresource = undefined;
        if (abi.map(context, self.buffer.?, 0, abi.map_write_discard, 0, &mapped) < 0) return error.DeviceLost;
        defer abi.unmap(context, self.buffer.?, 0);
        const destination = mapped.data orelse return error.DeviceLost;
        @memcpy(@as([*]u8, @ptrCast(destination))[0..@sizeOf(Globals)], std.mem.asBytes(value));
    }

    fn deinit(self: *ConstantBuffer) void {
        abi.com.release(self.buffer);
        self.* = .{};
    }
};

const LayerTarget = struct {
    texture: ?*abi.Object = null,
    render_target: ?*abi.Object = null,
    view: ?*abi.Object = null,
    width: u32 = 0,
    height: u32 = 0,

    fn ensure(self: *LayerTarget, device: *abi.Object, width: u32, height: u32) Error!void {
        if (width == 0 or height == 0) return error.InvalidConfiguration;
        if (self.texture != null and self.width == width and self.height == height) return;
        const descriptor: abi.Texture2DDesc = .{
            .width = width,
            .height = height,
            .format = abi.format_b8g8r8a8_unorm_srgb,
            .usage = abi.usage_default,
            .bind_flags = abi.bind_render_target | abi.bind_shader_resource,
            .cpu_access_flags = 0,
            .misc_flags = 0,
        };
        var texture: ?*abi.Object = null;
        if (abi.createTexture2D(device, &descriptor, null, &texture) < 0) return error.BudgetExceeded;
        errdefer abi.com.release(texture);
        var render_target: ?*abi.Object = null;
        if (abi.createRenderTargetView(device, texture.?, null, &render_target) < 0) return error.BudgetExceeded;
        errdefer abi.com.release(render_target);
        var view: ?*abi.Object = null;
        if (abi.createShaderResourceView(device, texture.?, null, &view) < 0) return error.BudgetExceeded;
        abi.com.release(self.view);
        abi.com.release(self.render_target);
        abi.com.release(self.texture);
        self.* = .{
            .texture = texture,
            .render_target = render_target,
            .view = view,
            .width = width,
            .height = height,
        };
    }

    fn deinit(self: *LayerTarget) void {
        abi.com.release(self.view);
        abi.com.release(self.render_target);
        abi.com.release(self.texture);
        self.* = .{};
    }
};

const FrameResources = struct {
    globals: ConstantBuffer = .{},
    query: ?*abi.Object = null,
    quads: GpuBuffer = .{},
    shadows: GpuBuffer = .{},
    underlines: GpuBuffer = .{},
    monochrome_sprites: GpuBuffer = .{},
    color_sprites: GpuBuffer = .{},
    external_surfaces: GpuBuffer = .{},
    paths: GpuBuffer = .{},
    materials: GpuBuffer = .{},
    stops: GpuBuffer = .{},
    clips: GpuBuffer = .{},
    layer_targets: std.ArrayList(LayerTarget) = .empty,
    backdrop_targets: std.ArrayList(LayerTarget) = .empty,
    busy_epoch: api.SubmissionEpoch = 0,

    fn init(self: *FrameResources, device: *abi.Object) Error!void {
        try self.globals.init(device);
        errdefer self.globals.deinit();
        const descriptor: abi.QueryDesc = .{ .query = abi.query_event };
        if (abi.createQuery(device, &descriptor, &self.query) < 0) return error.NoGpuDevice;
    }

    fn acquireLayerTarget(
        self: *FrameResources,
        allocator: std.mem.Allocator,
        device: *abi.Object,
        depth: usize,
        width: u32,
        height: u32,
    ) Error!*LayerTarget {
        return acquireTarget(&self.layer_targets, allocator, device, depth, width, height);
    }

    fn acquireBackdropTarget(
        self: *FrameResources,
        allocator: std.mem.Allocator,
        device: *abi.Object,
        depth: usize,
        width: u32,
        height: u32,
    ) Error!*LayerTarget {
        return acquireTarget(&self.backdrop_targets, allocator, device, depth, width, height);
    }

    fn deinit(self: *FrameResources, allocator: std.mem.Allocator) void {
        self.globals.deinit();
        abi.com.release(self.query);
        self.quads.deinit();
        self.shadows.deinit();
        self.underlines.deinit();
        self.monochrome_sprites.deinit();
        self.color_sprites.deinit();
        self.external_surfaces.deinit();
        self.paths.deinit();
        self.materials.deinit();
        self.stops.deinit();
        self.clips.deinit();
        for (self.layer_targets.items) |*target| target.deinit();
        self.layer_targets.deinit(allocator);
        for (self.backdrop_targets.items) |*target| target.deinit();
        self.backdrop_targets.deinit(allocator);
        self.* = .{};
    }
};

fn acquireTarget(
    targets: *std.ArrayList(LayerTarget),
    allocator: std.mem.Allocator,
    device: *abi.Object,
    index: usize,
    width: u32,
    height: u32,
) Error!*LayerTarget {
    while (targets.items.len <= index) try targets.append(allocator, .{});
    const target = &targets.items[index];
    try target.ensure(device, width, height);
    return target;
}

const SwapChain = struct {
    window: handles.WindowId,
    hwnd: abi.HWND,
    swap_chain: *abi.Object,
    back_buffer: ?*abi.Object,
    render_target: ?*abi.Object,
    width: u32,
    height: u32,
    last_submission: api.SubmissionEpoch = 0,

    fn deinit(self: *SwapChain) void {
        abi.com.release(self.render_target);
        abi.com.release(self.back_buffer);
        abi.com.release(self.swap_chain);
        self.* = undefined;
    }
};

const Texture = struct {
    texture: *abi.Object,
    view: *abi.Object,
    descriptor: api.TextureDescriptor,
};

const ExternalTexture = struct { texture: *abi.Object, view: *abi.Object };
const RetiredResource = struct { resource: *abi.Object, view: ?*abi.Object, release_after: api.SubmissionEpoch };
const InFlight = struct { epoch: api.SubmissionEpoch, slot: usize };
const ActiveFrame = struct { token: api.FrameToken, descriptor: api.FrameDescriptor, slot: usize };
const PathDraw = struct { start: u32 = 0, count: u32 = 0 };

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

const EncodeTarget = struct {
    texture: *abi.Object,
    render_target: *abi.Object,
    view: ?*abi.Object,
    bounds: DeviceBounds,
};

const TargetState = struct {
    target: ?EncodeTarget,
    layer: u32,
    isolated: bool = false,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    provider: surface.Provider,
    policy: config.GpuPolicy,
    device: DeviceSet,
    pipelines: Pipelines,
    frames: []FrameResources,
    surfaces: std.AutoHashMap(u64, SwapChain),
    textures: std.AutoHashMap(u64, Texture),
    external_surfaces: std.AutoHashMap(u64, ExternalTexture),
    retired: std.ArrayList(RetiredResource) = .empty,
    in_flight: std.ArrayList(InFlight) = .empty,
    active: ?ActiveFrame = null,
    generation: api.DeviceGeneration = 1,
    next_token: u64 = 1,
    submitted: api.SubmissionEpoch = 0,
    completed: api.SubmissionEpoch = 0,
    tessellator: path_tessellator.Tessellator,
    path_vertices: std.ArrayList(path_tessellator.Vertex) = .empty,
    path_draws: std.ArrayList(PathDraw) = .empty,
    resolved_clips: std.ArrayList(ResolvedClip) = .empty,
    layer_bounds: std.ArrayList(?geometry.Rect) = .empty,
    stale_surfaces: std.ArrayList(u64) = .empty,
    extensions: extension.Registry,
    maximum_textures: usize,
    maximum_external_surfaces: usize,
    maximum_resources: usize,
    maximum_surfaces: usize,

    pub fn create(
        allocator: std.mem.Allocator,
        provider: surface.Provider,
        policy: config.GpuPolicy,
        memory: config.MemoryBudgets,
    ) Error!api.Renderer {
        const self = try allocator.create(Renderer);
        errdefer allocator.destroy(self);
        var device = try DeviceSet.create(policy);
        errdefer device.deinit();
        var pipelines = try Pipelines.create(device.device);
        errdefer pipelines.deinit();
        const frames = try createFrames(allocator, device.device, @max(@as(usize, policy.frames_in_flight), 1));
        errdefer destroyFrames(allocator, frames);
        self.* = .{
            .allocator = allocator,
            .provider = provider,
            .policy = policy,
            .device = device,
            .pipelines = pipelines,
            .frames = frames,
            .surfaces = std.AutoHashMap(u64, SwapChain).init(allocator),
            .textures = std.AutoHashMap(u64, Texture).init(allocator),
            .external_surfaces = std.AutoHashMap(u64, ExternalTexture).init(allocator),
            .tessellator = path_tessellator.Tessellator.init(allocator, .{
                .maximum_edges = memory.path_edge_count,
                .maximum_work_units = memory.path_work_units,
                .maximum_output_vertices = memory.upload_ring_bytes / @sizeOf(path_tessellator.Vertex),
                .maximum_cache_bytes = memory.path_cache_bytes,
            }),
            .extensions = extension.Registry.initWithLimit(allocator, memory.render_extension_count),
            .maximum_textures = memory.texture_count,
            .maximum_external_surfaces = memory.external_surface_count,
            .maximum_resources = std.math.add(usize, memory.texture_count, memory.external_surface_count) catch return error.BudgetExceeded,
            .maximum_surfaces = memory.window_count,
        };
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: api.Renderer.VTable = .{
        .capabilities = capabilities,
        .device_generation = deviceGeneration,
        .begin_frame = beginFrame,
        .submit = submit,
        .render_offscreen = renderOffscreen,
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

    fn cast(raw: *anyopaque) *Renderer {
        return @ptrCast(@alignCast(raw));
    }

    fn capabilities(_: *anyopaque) api.Capabilities {
        return .{ .external_surfaces = true, .offscreen_readback = true, .custom_materials = true };
    }

    fn deviceGeneration(raw: *anyopaque) api.DeviceGeneration {
        return cast(raw).generation;
    }

    fn beginFrame(raw: *anyopaque, descriptor: api.FrameDescriptor) Error!api.FrameToken {
        const self = cast(raw);
        if (self.active != null) return error.FrameActive;
        if (descriptor.drawable_width == 0 or descriptor.drawable_height == 0) return error.WindowNotConfigured;
        try self.collect(false);
        var slot = self.availableFrameSlot();
        if (slot == null) {
            try self.waitOldest();
            slot = self.availableFrameSlot();
        }
        _ = try self.ensureSurface(descriptor.window, descriptor.drawable_width, descriptor.drawable_height);
        const token: api.FrameToken = .{ .value = self.next_token, .device_generation = self.generation };
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        self.active = .{ .token = token, .descriptor = descriptor, .slot = slot orelse return error.ResourceBusy };
        return token;
    }

    fn submit(raw: *anyopaque, token: api.FrameToken, view: api.SceneView) Error!api.Submission {
        const self = cast(raw);
        const active = self.active orelse return error.FramePhaseViolation;
        defer self.active = null;
        if (active.token.value != token.value or token.device_generation != self.generation) return error.DeviceLost;
        try scene.validate(view);
        try self.in_flight.ensureUnusedCapacity(self.allocator, 1);
        const target = self.surfaces.getPtr(active.descriptor.window.encode()) orelse return error.SurfaceUnavailable;
        const frame = &self.frames[active.slot];
        const root_resource = try frame.acquireLayerTarget(
            self.allocator,
            self.device.device,
            0,
            active.descriptor.drawable_width,
            active.descriptor.drawable_height,
        );
        const root: EncodeTarget = .{
            .texture = root_resource.texture.?,
            .render_target = root_resource.render_target.?,
            .view = root_resource.view,
            .bounds = .{ .left = 0, .top = 0, .width = active.descriptor.drawable_width, .height = active.descriptor.drawable_height },
        };
        self.encode(active.descriptor, view, frame, root, active.descriptor.clear_color) catch |err| {
            abi.end(self.device.context, frame.query.?);
            abi.flush(self.device.context);
            self.waitQuery(frame.query.?) catch {};
            abi.clearState(self.device.context);
            return err;
        };
        self.unbindShaderResources();
        abi.omSetRenderTargets(self.device.context, &.{});
        abi.copyResource(self.device.context, target.back_buffer orelse return error.SurfaceUnavailable, root.texture);
        abi.end(self.device.context, frame.query.?);
        abi.clearState(self.device.context);
        const status = abi.present(target.swap_chain, 1, 0);
        if (status < 0) {
            abi.flush(self.device.context);
            self.waitQuery(frame.query.?) catch {};
            if (status == abi.dxgi_error_device_removed or status == abi.dxgi_error_device_reset) return error.DeviceLost;
            return error.SurfaceLost;
        }
        self.submitted +%= 1;
        if (self.submitted == 0) self.submitted = 1;
        target.last_submission = self.submitted;
        frame.busy_epoch = self.submitted;
        self.in_flight.appendAssumeCapacity(.{ .epoch = self.submitted, .slot = active.slot });
        return .{
            .epoch = self.submitted,
            .device_generation = self.generation,
            .presented = status != abi.dxgi_status_occluded,
        };
    }

    fn bindTarget(self: *Renderer, target: EncodeTarget, clear: ?geometry.Color) void {
        self.unbindShaderResources();
        abi.omSetRenderTargets(self.device.context, &.{target.render_target});
        const viewport: abi.Viewport = .{
            .width = @floatFromInt(target.bounds.width),
            .height = @floatFromInt(target.bounds.height),
        };
        abi.rsSetViewports(self.device.context, &.{viewport});
        abi.rsSetState(self.device.context, self.pipelines.rasterizer);
        abi.iaSetPrimitiveTopology(self.device.context, abi.primitive_topology_triangle_strip);
        self.setFullScissor(target);
        if (clear) |color| {
            const premultiplied = color.premultiplied();
            const value: [4]f32 = .{ premultiplied.r, premultiplied.g, premultiplied.b, premultiplied.a };
            abi.clearRenderTarget(self.device.context, target.render_target, &value);
        }
    }

    fn encode(
        self: *Renderer,
        descriptor: api.FrameDescriptor,
        view: api.SceneView,
        frame: *FrameResources,
        root: EncodeTarget,
        clear_color: geometry.Color,
    ) Error!void {
        try self.prepareClips(view);
        try self.preparePaths(descriptor, view);
        const upload_bytes = try api.structuredUploadBytes(
            view,
            std.mem.sliceAsBytes(self.path_vertices.items).len,
            std.mem.sliceAsBytes(self.resolved_clips.items).len,
        );
        if (upload_bytes > descriptor.maximum_upload_bytes) return error.BudgetExceeded;
        const quad_view = try frame.quads.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(view.quads), @sizeOf(scene_abi.Quad));
        const shadow_view = try frame.shadows.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(view.shadows), @sizeOf(scene_abi.Shadow));
        const underline_view = try frame.underlines.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(view.underlines), @sizeOf(scene_abi.Underline));
        const mono_view = try frame.monochrome_sprites.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(view.monochrome_sprites), @sizeOf(scene_abi.Sprite));
        const color_view = try frame.color_sprites.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(view.color_sprites), @sizeOf(scene_abi.Sprite));
        const surface_view = try frame.external_surfaces.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(view.external_surfaces), @sizeOf(scene_abi.ExternalSurface));
        const material_view = try frame.materials.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(view.materials), @sizeOf(scene_abi.Material));
        const stop_view = try frame.stops.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(view.gradient_stops), @sizeOf(scene_abi.GradientStop));
        const clip_view = try frame.clips.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(self.resolved_clips.items), @sizeOf(ResolvedClip));
        const path_view = try frame.paths.upload(self.device.device, self.device.context, std.mem.sliceAsBytes(self.path_vertices.items), @sizeOf(path_tessellator.Vertex));

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
        self.bindTarget(root, clear_color);

        for (view.operations, 0..) |operation, operation_index| {
            const kind = std.enums.fromInt(scene_abi.OperationKind, operation.kind) orelse return error.InvalidScene;
            switch (kind) {
                .push_clip, .pop_clip => continue,
                .backdrop_effect => return error.Unsupported,
                .push_layer => {
                    if (depth + 1 >= targets.len or operation.start >= view.layers.len) return error.InvalidScene;
                    depth += 1;
                    targets[depth] = .{ .target = null, .layer = operation.start };
                    const parent = targets[depth - 1].target orelse continue;
                    const layer = view.layers[@as(usize, operation.start)];
                    if (layer.opacity <= 0) continue;
                    if (layer.opacity == 1 and layer.blend_mode == @backingInt(scene_abi.BlendMode.normal)) {
                        targets[depth].target = parent;
                        continue;
                    }
                    const visual_bounds = self.layer_bounds.items[@as(usize, operation.start)] orelse continue;
                    const bounds = cropLayerBounds(visual_bounds, descriptor) orelse continue;
                    const resource = try frame.acquireLayerTarget(self.allocator, self.device.device, depth, bounds.width, bounds.height);
                    const child: EncodeTarget = .{
                        .texture = resource.texture.?,
                        .render_target = resource.render_target.?,
                        .view = resource.view,
                        .bounds = bounds,
                    };
                    targets[depth].target = child;
                    targets[depth].isolated = true;
                    self.bindTarget(child, .transparent);
                    continue;
                },
                .pop_layer => {
                    if (depth == 0 or targets[depth].layer != operation.start) return error.InvalidScene;
                    if (targets[depth].isolated) {
                        const child = targets[depth].target orelse return error.InvalidScene;
                        const parent = targets[depth - 1].target orelse return error.InvalidScene;
                        try self.compositeLayer(descriptor, frame, depth, parent, child, view.layers[@as(usize, operation.start)]);
                    }
                    depth -= 1;
                    continue;
                },
                else => {},
            }
            const target = targets[depth].target orelse continue;
            if (operation.count == 0) continue;
            try setClip(self.device.context, descriptor, view, operation.clip, target.bounds);
            const transform = layerTransform(view, operation.layer);
            const logical_target = target.bounds.logical(descriptor.scale_factor);
            const globals: Globals = .{
                .viewport = .{ logical_target.size.width, logical_target.size.height },
                .viewport_origin = .{ logical_target.origin.x, logical_target.origin.y },
                .transform_x = .{ transform.m11, transform.m21, transform.tx, 0 },
                .transform_y = .{ transform.m12, transform.m22, transform.ty, 0 },
                .composite_origin = .{ 0, 0 },
                .composite_size = .{ 0, 0 },
                .payload_start = if (kind == .paths) self.path_draws.items[operation_index].start else operation.start,
                .material_index = operation.material,
                .clip_index = operation.clip,
                .operation_kind = operation.kind,
                .opacity = 1,
                .blend_mode = @backingInt(scene_abi.BlendMode.normal),
            };
            if (kind == .custom_passes) {
                const clip_bounds = try resolvedClipRect(descriptor, view, operation.clip);
                for (view.custom_passes[operation.start..][0..operation.count]) |pass| {
                    const payload = view.custom_payload[@as(usize, pass.payload_start)..][0..pass.payload_length];
                    try self.extensions.encode(
                        extension.decodeId(pass.extension),
                        .{ .d3d11 = .{
                            .device = @intFromPtr(self.device.device),
                            .immediate_context = @intFromPtr(self.device.context),
                        } },
                        .{ .d3d11 = .{
                            .device = @intFromPtr(self.device.device),
                            .immediate_context = @intFromPtr(self.device.context),
                            .render_target_view = @intFromPtr(target.render_target),
                            .target_texture = @intFromPtr(target.texture),
                            .geometry = .{
                                .window = descriptor.window,
                                .logical_size = descriptor.logical_size,
                                .drawable_width = descriptor.drawable_width,
                                .drawable_height = descriptor.drawable_height,
                                .scale_factor = descriptor.scale_factor,
                                .clear_color = descriptor.clear_color,
                                .bounds = transform.transformRectBounds(pass.bounds),
                                .clip = clip_bounds,
                                .transform = transform,
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
                }
                self.bindTarget(target, null);
                try setClip(self.device.context, descriptor, view, operation.clip, target.bounds);
                continue;
            }
            try frame.globals.upload(self.device.context, &globals);
            abi.vsSetConstantBuffers(self.device.context, 10, &.{frame.globals.buffer});
            abi.psSetConstantBuffers(self.device.context, 10, &.{frame.globals.buffer});
            abi.psSetSamplers(self.device.context, 0, &.{self.pipelines.sampler});
            abi.omSetBlendState(self.device.context, self.pipelines.source_over);

            var views: [11]?*abi.Object = .{ null, null, null, null, null, null, null, null, null, null, null };
            views[0] = quad_view;
            views[1] = shadow_view;
            views[2] = underline_view;
            views[4] = surface_view;
            views[5] = path_view;
            views[6] = material_view;
            views[7] = stop_view;
            views[8] = clip_view;
            const pair: *const ShaderPair = switch (kind) {
                .quads => &self.pipelines.quad,
                .shadows => &self.pipelines.shadow,
                .underlines => &self.pipelines.underline,
                .monochrome_sprites => pair: {
                    views[3] = mono_view;
                    const sprite = view.monochrome_sprites[@as(usize, operation.start)];
                    views[9] = (self.textures.get(sprite.texture) orelse return error.InvalidHandle).view;
                    break :pair &self.pipelines.monochrome_sprite;
                },
                .color_sprites => pair: {
                    views[3] = color_view;
                    const sprite = view.color_sprites[@as(usize, operation.start)];
                    views[9] = (self.textures.get(sprite.texture) orelse return error.InvalidHandle).view;
                    break :pair &self.pipelines.color_sprite;
                },
                .external_surfaces => pair: {
                    const external = view.external_surfaces[@as(usize, operation.start)];
                    views[9] = (self.external_surfaces.get(external.surface) orelse return error.InvalidHandle).view;
                    break :pair &self.pipelines.external_surface;
                },
                .paths => &self.pipelines.path,
                else => unreachable,
            };
            abi.vsSetShaderResources(self.device.context, 0, &views);
            abi.psSetShaderResources(self.device.context, 0, &views);
            abi.vsSetShader(self.device.context, pair.vertex);
            abi.psSetShader(self.device.context, pair.pixel);
            if (kind == .paths) {
                const draw = self.path_draws.items[operation_index];
                if (draw.count == 0) continue;
                abi.iaSetPrimitiveTopology(self.device.context, abi.primitive_topology_triangle_list);
                abi.draw(self.device.context, draw.count, 0);
            } else {
                abi.iaSetPrimitiveTopology(self.device.context, abi.primitive_topology_triangle_strip);
                abi.drawInstanced(self.device.context, 4, operation.count, 0, 0);
            }
        }
        if (depth != 0) return error.InvalidScene;
    }

    fn compositeLayer(
        self: *Renderer,
        descriptor: api.FrameDescriptor,
        frame: *FrameResources,
        depth: usize,
        parent: EncodeTarget,
        child: EncodeTarget,
        layer: scene_abi.Layer,
    ) Error!void {
        if (child.bounds.left < parent.bounds.left or child.bounds.top < parent.bounds.top or
            child.bounds.right() > parent.bounds.right() or child.bounds.bottom() > parent.bounds.bottom())
            return error.InvalidScene;
        const backdrop_resource = try frame.acquireBackdropTarget(
            self.allocator,
            self.device.device,
            depth,
            child.bounds.width,
            child.bounds.height,
        );
        self.unbindShaderResources();
        abi.omSetRenderTargets(self.device.context, &.{});
        const source_box: abi.Box = .{
            .left = child.bounds.left - parent.bounds.left,
            .top = child.bounds.top - parent.bounds.top,
            .front = 0,
            .right = child.bounds.right() - parent.bounds.left,
            .bottom = child.bounds.bottom() - parent.bounds.top,
            .back = 1,
        };
        abi.copySubresourceRegion(
            self.device.context,
            backdrop_resource.texture.?,
            0,
            0,
            0,
            0,
            parent.texture,
            0,
            &source_box,
        );

        self.bindTarget(parent, null);
        const logical_parent = parent.bounds.logical(descriptor.scale_factor);
        const logical_child = child.bounds.logical(descriptor.scale_factor);
        const globals: Globals = .{
            .viewport = .{ logical_parent.size.width, logical_parent.size.height },
            .viewport_origin = .{ logical_parent.origin.x, logical_parent.origin.y },
            .transform_x = .{ 1, 0, 0, 0 },
            .transform_y = .{ 0, 1, 0, 0 },
            .composite_origin = .{ logical_child.origin.x, logical_child.origin.y },
            .composite_size = .{ logical_child.size.width, logical_child.size.height },
            .payload_start = 0,
            .material_index = scene.none_index,
            .clip_index = scene.none_index,
            .operation_kind = @backingInt(scene_abi.OperationKind.pop_layer),
            .opacity = layer.opacity,
            .blend_mode = layer.blend_mode,
        };
        try frame.globals.upload(self.device.context, &globals);
        abi.vsSetConstantBuffers(self.device.context, 10, &.{frame.globals.buffer});
        abi.psSetConstantBuffers(self.device.context, 10, &.{frame.globals.buffer});
        abi.psSetSamplers(self.device.context, 0, &.{self.pipelines.sampler});
        abi.omSetBlendState(self.device.context, self.pipelines.replace);
        var views: [11]?*abi.Object = .{ null, null, null, null, null, null, null, null, null, null, null };
        views[9] = child.view orelse return error.InvalidShaderAbi;
        views[10] = backdrop_resource.view orelse return error.InvalidShaderAbi;
        abi.vsSetShaderResources(self.device.context, 0, &views);
        abi.psSetShaderResources(self.device.context, 0, &views);
        abi.vsSetShader(self.device.context, self.pipelines.composite.vertex);
        abi.psSetShader(self.device.context, self.pipelines.composite.pixel);
        abi.iaSetPrimitiveTopology(self.device.context, abi.primitive_topology_triangle_strip);
        abi.draw(self.device.context, 4, 0);
    }

    fn unbindShaderResources(self: *Renderer) void {
        const empty: [11]?*abi.Object = .{ null, null, null, null, null, null, null, null, null, null, null };
        abi.vsSetShaderResources(self.device.context, 0, &empty);
        abi.psSetShaderResources(self.device.context, 0, &empty);
    }

    fn setFullScissor(self: *Renderer, target: EncodeTarget) void {
        const rect: abi.Rect = .{
            .left = 0,
            .top = 0,
            .right = @intCast(target.bounds.width),
            .bottom = @intCast(target.bounds.height),
        };
        abi.rsSetScissorRects(self.device.context, &.{rect});
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
        try self.resolved_clips.resize(self.allocator, view.clips.len);
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

    fn renderOffscreen(raw: *anyopaque, target: api.OffscreenTarget, view: api.SceneView, allocator: std.mem.Allocator) Error!?api.Readback {
        const self = cast(raw);
        if (self.active != null) return error.FrameActive;
        if (target.width == 0 or target.height == 0) return error.InvalidConfiguration;
        try scene.validate(view);
        try self.collect(false);
        var slot = self.availableFrameSlot();
        if (slot == null) {
            try self.waitOldest();
            slot = self.availableFrameSlot();
        }
        const frame = &self.frames[slot orelse return error.ResourceBusy];
        const render_descriptor: abi.Texture2DDesc = .{
            .width = target.width,
            .height = target.height,
            .format = abi.format_b8g8r8a8_unorm_srgb,
            .usage = abi.usage_default,
            .bind_flags = abi.bind_render_target | abi.bind_shader_resource,
            .cpu_access_flags = 0,
            .misc_flags = 0,
        };
        var render_texture: ?*abi.Object = null;
        if (abi.createTexture2D(self.device.device, &render_descriptor, null, &render_texture) < 0) return error.BudgetExceeded;
        defer abi.com.release(render_texture);
        var render_target: ?*abi.Object = null;
        if (abi.createRenderTargetView(self.device.device, render_texture.?, null, &render_target) < 0) return error.BudgetExceeded;
        defer abi.com.release(render_target);

        var staging_texture: ?*abi.Object = null;
        if (target.readback) {
            const staging_descriptor: abi.Texture2DDesc = .{
                .width = target.width,
                .height = target.height,
                .format = abi.format_b8g8r8a8_unorm_srgb,
                .usage = abi.usage_staging,
                .bind_flags = 0,
                .cpu_access_flags = abi.cpu_access_read,
                .misc_flags = 0,
            };
            if (abi.createTexture2D(self.device.device, &staging_descriptor, null, &staging_texture) < 0) return error.BudgetExceeded;
        }
        defer abi.com.release(staging_texture);

        const scale = target.scale_factor.value;
        const descriptor: api.FrameDescriptor = .{
            .window = .invalid,
            .logical_size = .{
                .width = @as(f32, @floatFromInt(target.width)) / scale,
                .height = @as(f32, @floatFromInt(target.height)) / scale,
            },
            .drawable_width = target.width,
            .drawable_height = target.height,
            .scale_factor = target.scale_factor,
            .clear_color = .transparent,
        };
        const root: EncodeTarget = .{
            .texture = render_texture.?,
            .render_target = render_target.?,
            .view = null,
            .bounds = .{ .left = 0, .top = 0, .width = target.width, .height = target.height },
        };
        self.encode(descriptor, view, frame, root, .transparent) catch |err| {
            abi.end(self.device.context, frame.query.?);
            abi.flush(self.device.context);
            self.waitQuery(frame.query.?) catch {};
            abi.clearState(self.device.context);
            return err;
        };
        self.unbindShaderResources();
        abi.omSetRenderTargets(self.device.context, &.{});
        if (staging_texture) |staging| abi.copyResource(self.device.context, staging, render_texture.?);
        abi.end(self.device.context, frame.query.?);
        abi.clearState(self.device.context);
        abi.flush(self.device.context);
        if (!target.readback) {
            try self.waitQuery(frame.query.?);
            return null;
        }
        var mapped: abi.MappedSubresource = undefined;
        if (abi.map(self.device.context, staging_texture.?, 0, abi.map_read, 0, &mapped) < 0) return error.DeviceLost;
        const source = mapped.data orelse {
            abi.unmap(self.device.context, staging_texture.?, 0);
            return error.DeviceLost;
        };
        const result = convertReadback(allocator, target, @ptrCast(source), mapped.row_pitch) catch |err| {
            abi.unmap(self.device.context, staging_texture.?, 0);
            return err;
        };
        abi.unmap(self.device.context, staging_texture.?, 0);
        try self.waitQuery(frame.query.?);
        return result;
    }

    fn completedEpoch(raw: *anyopaque) api.SubmissionEpoch {
        const self = cast(raw);
        self.collect(false) catch {};
        return self.completed;
    }

    fn invalidateSurface(raw: *anyopaque, window: handles.WindowId) Error!void {
        const self = cast(raw);
        // A DXGI swap chain may still be referenced by an outstanding copy or
        // present. Surface loss is rare, so wait only here rather than making
        // ordinary resize and frame paths globally synchronous.
        try self.waitAll();
        if (self.surfaces.fetchRemove(window.encode())) |removed| {
            var value = removed.value;
            value.deinit();
        }
    }

    fn recover(raw: *anyopaque, policy: config.GpuPolicy) Error!void {
        const self = cast(raw);
        if (self.extensions.callbacksActive()) return error.CallbackReentrancy;
        // A removed device can no longer complete its event queries. Recovery
        // abandons that device generation instead of waiting on work that is
        // guaranteed to report DeviceLost.
        self.active = null;
        var replacement_device = try DeviceSet.create(policy);
        errdefer replacement_device.deinit();
        var replacement_pipelines = try Pipelines.create(replacement_device.device);
        errdefer replacement_pipelines.deinit();
        const replacement_frames = try createFrames(self.allocator, replacement_device.device, @max(@as(usize, policy.frames_in_flight), 1));
        errdefer destroyFrames(self.allocator, replacement_frames);

        var next_generation = self.generation +% 1;
        if (next_generation == 0) next_generation = 1;
        self.extensions.deviceLost(next_generation);

        self.releaseDeviceResources();
        destroyFrames(self.allocator, self.frames);
        self.pipelines.deinit();
        self.device.deinit();
        self.device = replacement_device;
        self.pipelines = replacement_pipelines;
        self.frames = replacement_frames;
        self.policy = policy;
        self.active = null;
        self.completed = self.submitted;
        self.generation = next_generation;
    }

    fn createTexture(raw: *anyopaque, id: handles.TextureId, descriptor: api.TextureDescriptor) Error!void {
        const self = cast(raw);
        try self.collect(false);
        if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
        if (self.textures.contains(id.encode())) return error.ResourceBusy;
        if (self.textures.count() >= self.maximum_textures) return error.BudgetExceeded;
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        try self.textures.ensureUnusedCapacity(1);
        const texture_descriptor: abi.Texture2DDesc = .{
            .width = descriptor.width,
            .height = descriptor.height,
            .format = dxgiFormat(descriptor.format),
            .usage = abi.usage_default,
            .bind_flags = abi.bind_shader_resource | (if (descriptor.usage == .render_target) abi.bind_render_target else 0),
            .cpu_access_flags = 0,
            .misc_flags = 0,
        };
        var texture: ?*abi.Object = null;
        if (abi.createTexture2D(self.device.device, &texture_descriptor, null, &texture) < 0) return error.BudgetExceeded;
        errdefer abi.com.release(texture);
        var view: ?*abi.Object = null;
        if (abi.createShaderResourceView(self.device.device, texture.?, null, &view) < 0) return error.BudgetExceeded;
        self.textures.putAssumeCapacity(id.encode(), .{ .texture = texture.?, .view = view.?, .descriptor = descriptor });
    }

    fn writeTexture(raw: *anyopaque, id: handles.TextureId, region: api.TextureRegion, pixels: []const u8, stride: usize) Error!void {
        const self = cast(raw);
        const texture = self.textures.get(id.encode()) orelse return error.InvalidHandle;
        if (region.width == 0 or region.height == 0) return;
        if (@as(u64, region.x) + region.width > texture.descriptor.width or @as(u64, region.y) + region.height > texture.descriptor.height)
            return error.InvalidConfiguration;
        const bytes_per_pixel = bytesPerPixel(texture.descriptor.format);
        const row_bytes = std.math.mul(usize, region.width, bytes_per_pixel) catch return error.BudgetExceeded;
        if (stride < row_bytes or stride > std.math.maxInt(u32)) return error.InvalidConfiguration;
        const required = std.math.add(usize, std.math.mul(usize, stride, region.height - 1) catch return error.BudgetExceeded, row_bytes) catch return error.BudgetExceeded;
        if (pixels.len < required) return error.InvalidConfiguration;
        const box: abi.Box = .{
            .left = region.x,
            .top = region.y,
            .front = 0,
            .right = region.x + region.width,
            .bottom = region.y + region.height,
            .back = 1,
        };
        abi.updateSubresource(self.device.context, texture.texture, 0, &box, pixels.ptr, @intCast(stride), 0);
    }

    fn destroyTexture(raw: *anyopaque, id: handles.TextureId, release_after: api.SubmissionEpoch) Error!void {
        const self = cast(raw);
        try self.collect(false);
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        const removed = self.textures.fetchRemove(id.encode()) orelse return error.InvalidHandle;
        self.retired.appendAssumeCapacity(.{ .resource = removed.value.texture, .view = removed.value.view, .release_after = release_after });
    }

    fn importExternalSurface(raw: *anyopaque, id: handles.SurfaceId, descriptor: api.ExternalSurfaceDescriptor) Error!void {
        const self = cast(raw);
        if (descriptor.width == 0 or descriptor.height == 0 or self.external_surfaces.contains(id.encode()))
            return if (self.external_surfaces.contains(id.encode())) error.ResourceBusy else error.InvalidConfiguration;
        if (self.external_surfaces.count() >= self.maximum_external_surfaces) return error.BudgetExceeded;
        try self.collect(false);
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        const address = switch (descriptor.native) {
            .d3d11_texture => |value| value,
            else => return error.Unsupported,
        };
        if (address == 0) return error.InvalidHandle;
        try self.external_surfaces.ensureUnusedCapacity(1);
        const texture: *abi.Object = @ptrFromInt(address);
        _ = abi.com.addRef(texture);
        errdefer abi.com.release(texture);
        var native_descriptor: abi.Texture2DDesc = undefined;
        abi.texture2DDescription(texture, &native_descriptor);
        if (native_descriptor.width != descriptor.width or native_descriptor.height != descriptor.height) return error.InvalidConfiguration;
        var view: ?*abi.Object = null;
        if (abi.createShaderResourceView(self.device.device, texture, null, &view) < 0) return error.InvalidConfiguration;
        self.external_surfaces.putAssumeCapacity(id.encode(), .{ .texture = texture, .view = view.? });
    }

    fn replaceExternalSurface(raw: *anyopaque, id: handles.SurfaceId, descriptor: api.ExternalSurfaceDescriptor, release_after: api.SubmissionEpoch) Error!void {
        const self = cast(raw);
        const entry = self.external_surfaces.getPtr(id.encode()) orelse return error.InvalidHandle;
        try self.collect(false);
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidConfiguration;
        const address = switch (descriptor.native) {
            .d3d11_texture => |value| value,
            else => return error.Unsupported,
        };
        if (address == 0) return error.InvalidHandle;
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        const texture: *abi.Object = @ptrFromInt(address);
        _ = abi.com.addRef(texture);
        errdefer abi.com.release(texture);
        var native_descriptor: abi.Texture2DDesc = undefined;
        abi.texture2DDescription(texture, &native_descriptor);
        if (native_descriptor.width != descriptor.width or native_descriptor.height != descriptor.height) return error.InvalidConfiguration;
        var view: ?*abi.Object = null;
        if (abi.createShaderResourceView(self.device.device, texture, null, &view) < 0) return error.InvalidConfiguration;
        self.retired.appendAssumeCapacity(.{ .resource = entry.texture, .view = entry.view, .release_after = release_after });
        entry.* = .{ .texture = texture, .view = view.? };
    }

    fn destroyExternalSurface(raw: *anyopaque, id: handles.SurfaceId, release_after: api.SubmissionEpoch) Error!void {
        const self = cast(raw);
        try self.collect(false);
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        const removed = self.external_surfaces.fetchRemove(id.encode()) orelse return error.InvalidHandle;
        self.retired.appendAssumeCapacity(.{ .resource = removed.value.texture, .view = removed.value.view, .release_after = release_after });
    }

    fn registerExtension(raw: *anyopaque, descriptor: extension.Descriptor) Error!handles.RenderExtensionId {
        if (descriptor.requirements.depth != null) return error.Unsupported;
        const self = cast(raw);
        try self.collect(false);
        return self.extensions.register(descriptor);
    }

    fn destroyExtension(raw: *anyopaque, id: handles.RenderExtensionId, release_after: api.SubmissionEpoch) Error!void {
        try cast(raw).extensions.destroy(id, release_after);
    }

    fn retire(self: *Renderer, retired: RetiredResource) void {
        self.retired.append(self.allocator, retired) catch {
            self.waitAll() catch {};
            abi.com.release(retired.view);
            abi.com.release(retired.resource);
            return;
        };
        self.collect(false) catch {};
    }

    fn totalResourceCount(self: *const Renderer) usize {
        return self.textures.count() +| self.external_surfaces.count() +| self.retired.items.len;
    }

    fn ensureSurface(self: *Renderer, window: handles.WindowId, width: u32, height: u32) Error!*SwapChain {
        if (self.surfaces.getPtr(window.encode())) |existing| {
            if (existing.width == width and existing.height == height) return existing;
            try self.waitAll();
            abi.clearState(self.device.context);
            abi.com.release(existing.render_target);
            abi.com.release(existing.back_buffer);
            existing.render_target = null;
            existing.back_buffer = null;
            const status = abi.resizeBuffers(existing.swap_chain, 0, width, height, abi.format_unknown, 0);
            if (status < 0) {
                if (status == abi.dxgi_error_device_removed or status == abi.dxgi_error_device_reset) return error.DeviceLost;
                return error.SurfaceLost;
            }
            const replacement = try createSwapChainTarget(self.device.device, existing.swap_chain);
            existing.back_buffer = replacement.texture;
            existing.render_target = replacement.render_target;
            existing.width = width;
            existing.height = height;
            return existing;
        }
        if (self.surfaces.count() >= self.maximum_surfaces) return error.BudgetExceeded;
        const hwnd = self.provider.window(window) orelse return error.SurfaceUnavailable;
        try self.surfaces.ensureUnusedCapacity(1);
        var descriptor: abi.SwapChainDesc = .{
            .buffer_desc = .{ .width = width, .height = height, .format = abi.format_b8g8r8a8_unorm },
            .sample_desc = .{},
            .buffer_usage = abi.usage_render_target_output,
            .buffer_count = 2,
            .output_window = hwnd,
            .windowed = 1,
            .swap_effect = abi.swap_effect_flip_discard,
            .flags = 0,
        };
        var swap_chain: ?*abi.Object = null;
        var status = abi.createSwapChain(self.device.factory, self.device.device, &descriptor, &swap_chain);
        if (status < 0) {
            descriptor.buffer_count = 1;
            descriptor.swap_effect = abi.swap_effect_discard;
            status = abi.createSwapChain(self.device.factory, self.device.device, &descriptor, &swap_chain);
        }
        if (status < 0) return error.SurfaceUnavailable;
        errdefer abi.com.release(swap_chain);
        _ = abi.makeWindowAssociation(self.device.factory, hwnd, no_alt_enter);
        const swap_chain_target = try createSwapChainTarget(self.device.device, swap_chain.?);
        self.surfaces.putAssumeCapacity(window.encode(), .{
            .window = window,
            .hwnd = hwnd,
            .swap_chain = swap_chain.?,
            .back_buffer = swap_chain_target.texture,
            .render_target = swap_chain_target.render_target,
            .width = width,
            .height = height,
        });
        return self.surfaces.getPtr(window.encode()).?;
    }

    fn collect(self: *Renderer, wait_for_oldest: bool) Error!void {
        var may_wait = wait_for_oldest;
        while (self.in_flight.items.len != 0) {
            const item = self.in_flight.items[0];
            var status = abi.getData(self.device.context, self.frames[item.slot].query.?, null, 0, abi.async_getdata_do_not_flush);
            if (status == 1 and may_wait) {
                try self.waitQuery(self.frames[item.slot].query.?);
                status = 0;
            }
            if (status == 1) break;
            if (status < 0) return error.DeviceLost;
            _ = self.in_flight.orderedRemove(0);
            self.frames[item.slot].busy_epoch = 0;
            self.completed = @max(self.completed, item.epoch);
            may_wait = false;
        }
        var write: usize = 0;
        for (self.retired.items) |item| {
            if (item.release_after <= self.completed) {
                abi.com.release(item.view);
                abi.com.release(item.resource);
            } else {
                self.retired.items[write] = item;
                write += 1;
            }
        }
        self.retired.items.len = write;
        self.extensions.collect(self.completed);
        self.collectStaleSurfaces();
    }

    fn collectStaleSurfaces(self: *Renderer) void {
        self.stale_surfaces.clearRetainingCapacity();
        var iterator = self.surfaces.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_submission > self.completed) continue;
            if (self.provider.window(entry.value_ptr.window) != null) continue;
            self.stale_surfaces.append(self.allocator, entry.key_ptr.*) catch return;
        }
        for (self.stale_surfaces.items) |key| {
            var removed = self.surfaces.fetchRemove(key) orelse continue;
            removed.value.deinit();
        }
    }

    fn waitQuery(self: *Renderer, query: *abi.Object) Error!void {
        abi.flush(self.device.context);
        while (true) {
            const status = abi.getData(self.device.context, query, null, 0, 0);
            if (status == 0) return;
            if (status < 0 or abi.deviceRemovedReason(self.device.device) < 0) return error.DeviceLost;
            std.Thread.yield() catch {};
        }
    }

    fn waitOldest(self: *Renderer) Error!void {
        try self.collect(true);
    }

    fn waitAll(self: *Renderer) Error!void {
        while (self.in_flight.items.len != 0) try self.collect(true);
    }

    fn availableFrameSlot(self: *const Renderer) ?usize {
        for (self.frames, 0..) |frame, index| if (frame.busy_epoch == 0) return index;
        return null;
    }

    fn releaseDeviceResources(self: *Renderer) void {
        var surface_iterator = self.surfaces.iterator();
        while (surface_iterator.next()) |entry| entry.value_ptr.deinit();
        self.surfaces.clearRetainingCapacity();
        var texture_iterator = self.textures.iterator();
        while (texture_iterator.next()) |entry| {
            abi.com.release(entry.value_ptr.view);
            abi.com.release(entry.value_ptr.texture);
        }
        self.textures.clearRetainingCapacity();
        var external_iterator = self.external_surfaces.iterator();
        while (external_iterator.next()) |entry| {
            abi.com.release(entry.value_ptr.view);
            abi.com.release(entry.value_ptr.texture);
        }
        self.external_surfaces.clearRetainingCapacity();
        for (self.retired.items) |item| {
            abi.com.release(item.view);
            abi.com.release(item.resource);
        }
        self.retired.clearRetainingCapacity();
        self.in_flight.clearRetainingCapacity();
    }

    fn deinit(raw: *anyopaque) void {
        const self = cast(raw);
        self.waitAll() catch {};
        self.releaseDeviceResources();
        self.surfaces.deinit();
        self.textures.deinit();
        self.external_surfaces.deinit();
        self.retired.deinit(self.allocator);
        self.in_flight.deinit(self.allocator);
        self.tessellator.deinit();
        self.path_vertices.deinit(self.allocator);
        self.path_draws.deinit(self.allocator);
        self.resolved_clips.deinit(self.allocator);
        self.layer_bounds.deinit(self.allocator);
        self.stale_surfaces.deinit(self.allocator);
        self.extensions.deinit();
        destroyFrames(self.allocator, self.frames);
        self.pipelines.deinit();
        self.device.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn createFrames(allocator: std.mem.Allocator, device: *abi.Object, count: usize) Error![]FrameResources {
    const result = try allocator.alloc(FrameResources, count);
    @memset(result, .{});
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*frame| frame.deinit(allocator);
        allocator.free(result);
    }
    for (result) |*frame| {
        try frame.init(device);
        initialized += 1;
    }
    return result;
}

fn destroyFrames(allocator: std.mem.Allocator, frames: []FrameResources) void {
    for (frames) |*frame| frame.deinit(allocator);
    allocator.free(frames);
}

const SwapChainTarget = struct { texture: *abi.Object, render_target: *abi.Object };

fn createSwapChainTarget(device: *abi.Object, swap_chain: *abi.Object) Error!SwapChainTarget {
    var texture: ?*abi.Object = null;
    if (abi.getBuffer(swap_chain, 0, &abi.iid_texture2d, &texture) < 0) return error.SurfaceUnavailable;
    errdefer abi.com.release(texture);
    var target: ?*abi.Object = null;
    const descriptor: abi.RenderTargetViewDesc = .{ .format = abi.format_b8g8r8a8_unorm_srgb };
    if (abi.createRenderTargetView(device, texture.?, &descriptor, &target) < 0) return error.SurfaceUnavailable;
    return .{
        .texture = texture orelse return error.SurfaceUnavailable,
        .render_target = target orelse return error.SurfaceUnavailable,
    };
}

fn cropLayerBounds(bounds: geometry.Rect, descriptor: api.FrameDescriptor) ?DeviceBounds {
    var left = clampedDeviceFloor(bounds.minX(), descriptor.scale_factor, descriptor.drawable_width);
    var top = clampedDeviceFloor(bounds.minY(), descriptor.scale_factor, descriptor.drawable_height);
    var right = clampedDeviceCeil(bounds.maxX(), descriptor.scale_factor, descriptor.drawable_width);
    var bottom = clampedDeviceCeil(bounds.maxY(), descriptor.scale_factor, descriptor.drawable_height);
    // Preserve one device pixel for analytic antialiasing at group edges.
    left -|= 1;
    top -|= 1;
    right = @min(descriptor.drawable_width, right +| 1);
    bottom = @min(descriptor.drawable_height, bottom +| 1);
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .width = right - left, .height = bottom - top };
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
    context: *abi.Object,
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
    const rect: abi.Rect = .{
        .left = @intCast(@min(left, right)),
        .top = @intCast(@min(top, bottom)),
        .right = @intCast(@max(left, right)),
        .bottom = @intCast(@max(top, bottom)),
    };
    abi.rsSetScissorRects(context, &.{rect});
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

fn dxgiFormat(format: api.PixelFormat) u32 {
    return switch (format) {
        .a8 => abi.format_r8_unorm,
        .rgba8 => abi.format_r8g8b8a8_unorm,
        .rgba8_srgb => abi.format_r8g8b8a8_unorm_srgb,
        .bgra8 => abi.format_b8g8r8a8_unorm,
        .bgra8_srgb => abi.format_b8g8r8a8_unorm_srgb,
        .rgba16_float => abi.format_r16g16b16a16_float,
    };
}

fn bytesPerPixel(format: api.PixelFormat) usize {
    return switch (format) {
        .a8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba16_float => 8,
    };
}

fn convertReadback(allocator: std.mem.Allocator, target: api.OffscreenTarget, source: [*]const u8, source_stride: usize) Error!api.Readback {
    const bytes_per_pixel = bytesPerPixel(target.format);
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
    return .{ .width = target.width, .height = target.height, .stride = stride, .format = target.format, .pixels = pixels };
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
