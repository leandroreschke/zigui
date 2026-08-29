const std = @import("std");
const config = @import("../../config.zig");
const Error = @import("../../core/error.zig").Error;
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const render = @import("../../render/api.zig");
const extension = @import("../../render/extension.zig");
const path_tessellator = @import("../../render/path_tessellator.zig");
const scene = @import("../../scene/scene.zig");
const linux_surface = @import("../../platform/linux/surface.zig");
const sys = @import("../../platform/linux/sys.zig");
const abi = @import("abi.zig");
const device_mod = @import("device.zig");
const mesh_mod = @import("mesh.zig");
const pipeline_mod = @import("pipeline.zig");
const resource = @import("resource.zig");

const ActiveFrame = struct {
    token: render.FrameToken,
    descriptor: render.FrameDescriptor,
    frame: *Frame,
};

const InFlight = struct {
    epoch: render.SubmissionEpoch,
    frame: *Frame,
    done: bool = false,
};

const SampledTarget = struct {
    image: resource.Image = .{},
    descriptor: abi.DescriptorSet = 0,
    pair_descriptor: abi.DescriptorSet = 0,
    pair_source_view: abi.ImageView = 0,

    fn ensure(
        self: *SampledTarget,
        renderer: *Renderer,
        width: u32,
        height: u32,
        format: abi.Format,
    ) Error!void {
        if (self.image.handle != 0 and self.image.width == width and self.image.height == height and self.image.format == format) return;
        self.deinit(renderer);
        self.image = try resource.Image.create(
            renderer.device,
            width,
            height,
            format,
            abi.image_usage_color_attachment_bit | abi.image_usage_sampled_bit |
                abi.image_usage_transfer_src_bit | abi.image_usage_transfer_dst_bit,
        );
        errdefer self.image.deinit(renderer.device);
        self.descriptor = try resource.allocateImageDescriptor(
            renderer.device,
            renderer.descriptor_pool,
            renderer.pipelines.descriptor_layout,
            renderer.pipelines.sampler,
            self.image.view,
        );
    }

    fn deinit(self: *SampledTarget, renderer: *Renderer) void {
        var sets: [2]abi.DescriptorSet = undefined;
        var count: u32 = 0;
        if (self.descriptor != 0) {
            sets[count] = self.descriptor;
            count += 1;
        }
        if (self.pair_descriptor != 0) {
            sets[count] = self.pair_descriptor;
            count += 1;
        }
        if (count != 0) _ = renderer.device.device_dispatch.free_descriptor_sets(
            renderer.device.device,
            renderer.descriptor_pool,
            count,
            &sets,
        );
        self.image.deinit(renderer.device);
        self.* = .{};
    }

    fn compositeDescriptor(self: *SampledTarget, renderer: *Renderer, source_view: abi.ImageView) Error!abi.DescriptorSet {
        if (self.pair_descriptor != 0 and self.pair_source_view == source_view) return self.pair_descriptor;
        if (self.pair_descriptor != 0) {
            const old = [1]abi.DescriptorSet{self.pair_descriptor};
            _ = renderer.device.device_dispatch.free_descriptor_sets(renderer.device.device, renderer.descriptor_pool, 1, &old);
            self.pair_descriptor = 0;
        }
        self.pair_descriptor = try resource.allocateImagePairDescriptor(
            renderer.device,
            renderer.descriptor_pool,
            renderer.pipelines.descriptor_layout,
            renderer.pipelines.sampler,
            source_view,
            abi.image_layout_shader_read_only_optimal,
            self.image.view,
            abi.image_layout_shader_read_only_optimal,
        );
        self.pair_source_view = source_view;
        return self.pair_descriptor;
    }
};

const Frame = struct {
    present: resource.ExportImage,
    command: abi.CommandBuffer,
    vertex_buffer: resource.Buffer = .{},
    layers: std.ArrayList(SampledTarget) = .empty,
    backdrops: std.ArrayList(SampledTarget) = .empty,
    in_flight: bool = false,
    submission_epoch: render.SubmissionEpoch = 0,

    fn create(renderer: *Renderer, width: u32, height: u32) Error!Frame {
        const present = try resource.ExportImage.create(renderer.device, renderer.provider, width, height);
        errdefer {
            var value = present;
            value.deinit(renderer.device, renderer.provider);
        }
        const command = try renderer.device.allocateCommandBuffer();
        return .{ .present = present, .command = command };
    }

    fn ready(self: *Frame, renderer: *Renderer) bool {
        return !self.in_flight and self.present.ready(renderer.device, renderer.provider);
    }

    fn acquireLayer(self: *Frame, renderer: *Renderer, index: usize, bounds: mesh_mod.DeviceBounds, format: abi.Format) Error!*SampledTarget {
        while (self.layers.items.len <= index) try self.layers.append(renderer.allocator, .{});
        const target = &self.layers.items[index];
        try target.ensure(renderer, bounds.width, bounds.height, format);
        return target;
    }

    fn acquireBackdrop(self: *Frame, renderer: *Renderer, index: usize, bounds: mesh_mod.DeviceBounds, format: abi.Format) Error!*SampledTarget {
        while (self.backdrops.items.len <= index) try self.backdrops.append(renderer.allocator, .{});
        const target = &self.backdrops.items[index];
        try target.ensure(renderer, bounds.width, bounds.height, format);
        return target;
    }

    fn deinit(self: *Frame, renderer: *Renderer) void {
        self.present.deinit(renderer.device, renderer.provider);
        self.vertex_buffer.deinit(renderer.device);
        for (self.layers.items) |*target| target.deinit(renderer);
        self.layers.deinit(renderer.allocator);
        for (self.backdrops.items) |*target| target.deinit(renderer);
        self.backdrops.deinit(renderer.allocator);
        renderer.device.freeCommandBuffer(self.command);
        self.* = undefined;
    }
};

const FrameLayoutSnapshot = struct {
    present: i32,
    layer_count: usize,
    layer_handles: [65]abi.Image,
    layer_layouts: [65]i32,
    backdrop_count: usize,
    backdrop_handles: [65]abi.Image,
    backdrop_layouts: [65]i32,

    fn capture(frame: *const Frame) Error!FrameLayoutSnapshot {
        if (frame.layers.items.len > 65 or frame.backdrops.items.len > 65)
            return error.BudgetExceeded;
        var result: FrameLayoutSnapshot = .{
            .present = frame.present.image.layout,
            .layer_count = frame.layers.items.len,
            .layer_handles = undefined,
            .layer_layouts = undefined,
            .backdrop_count = frame.backdrops.items.len,
            .backdrop_handles = undefined,
            .backdrop_layouts = undefined,
        };
        for (frame.layers.items, 0..) |target, index| {
            result.layer_handles[index] = target.image.handle;
            result.layer_layouts[index] = target.image.layout;
        }
        for (frame.backdrops.items, 0..) |target, index| {
            result.backdrop_handles[index] = target.image.handle;
            result.backdrop_layouts[index] = target.image.layout;
        }
        return result;
    }

    fn restore(self: FrameLayoutSnapshot, frame: *Frame) void {
        frame.present.image.layout = self.present;
        for (frame.layers.items, 0..) |*target, index|
            target.image.layout = if (index < self.layer_count and target.image.handle == self.layer_handles[index])
                self.layer_layouts[index]
            else
                abi.image_layout_undefined;
        for (frame.backdrops.items, 0..) |*target, index|
            target.image.layout = if (index < self.backdrop_count and target.image.handle == self.backdrop_handles[index])
                self.backdrop_layouts[index]
            else
                abi.image_layout_undefined;
    }
};

const Surface = struct {
    window: handles.WindowId,
    width: u32,
    height: u32,
    frames: []Frame,
    cursor: usize = 0,

    fn create(renderer: *Renderer, window: handles.WindowId, width: u32, height: u32) Error!Surface {
        const count: usize = @max(@as(usize, renderer.policy.frames_in_flight), 2);
        const frames = try renderer.allocator.alloc(Frame, count);
        var initialized: usize = 0;
        errdefer {
            for (frames[0..initialized]) |*frame| frame.deinit(renderer);
            renderer.allocator.free(frames);
        }
        while (initialized < frames.len) : (initialized += 1) frames[initialized] = try Frame.create(renderer, width, height);
        return .{ .window = window, .width = width, .height = height, .frames = frames };
    }

    fn acquire(self: *Surface, renderer: *Renderer) ?*Frame {
        var offset: usize = 0;
        while (offset < self.frames.len) : (offset += 1) {
            const index = (self.cursor + offset) % self.frames.len;
            if (!self.frames[index].ready(renderer)) continue;
            self.cursor = (index + 1) % self.frames.len;
            return &self.frames[index];
        }
        return null;
    }

    fn canDestroy(self: *Surface, renderer: *Renderer) bool {
        for (self.frames) |*frame| if (frame.in_flight or !renderer.provider.bufferReleased(frame.present.buffer)) return false;
        return true;
    }

    fn deinit(self: *Surface, renderer: *Renderer) void {
        for (self.frames) |*frame| frame.deinit(renderer);
        renderer.allocator.free(self.frames);
        self.* = undefined;
    }
};

const RetiredTexture = struct {
    texture: resource.Texture,
    release_after: render.SubmissionEpoch,
};

const ExternalTexture = struct {
    descriptor: abi.DescriptorSet,
    owned: ?resource.Image = null,
    borrowed_view: abi.ImageView = 0,
    layout: i32,
    description: render.ExternalSurfaceDescriptor,

    fn view(self: *const ExternalTexture) abi.ImageView {
        return if (self.owned) |image| image.view else self.borrowed_view;
    }

    fn deinit(self: *ExternalTexture, renderer: *Renderer) void {
        if (self.descriptor != 0) {
            const sets = [1]abi.DescriptorSet{self.descriptor};
            _ = renderer.device.device_dispatch.free_descriptor_sets(renderer.device.device, renderer.descriptor_pool, 1, &sets);
        }
        if (self.owned) |*image| image.deinit(renderer.device);
        self.* = undefined;
    }
};

const RetiredExternal = struct {
    texture: ExternalTexture,
    release_after: render.SubmissionEpoch,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    provider: linux_surface.Provider,
    policy: config.GpuPolicy,
    device: *device_mod.Context,
    pipelines: pipeline_mod.Pipelines,
    descriptor_pool: abi.DescriptorPool,
    mesh: mesh_mod.Mesh,
    surfaces: std.AutoHashMap(u64, Surface),
    retired_surfaces: std.ArrayList(Surface) = .empty,
    textures: std.AutoHashMap(u64, resource.Texture),
    retired_textures: std.ArrayList(RetiredTexture) = .empty,
    external_surfaces: std.AutoHashMap(u64, ExternalTexture),
    retired_external: std.ArrayList(RetiredExternal) = .empty,
    in_flight: std.ArrayList(InFlight) = .empty,
    in_flight_cursor: usize = 0,
    active: ?ActiveFrame = null,
    generation: render.DeviceGeneration = 1,
    next_token: u64 = 1,
    submitted: render.SubmissionEpoch = 0,
    completed: render.SubmissionEpoch = 0,
    extensions: extension.Registry,
    maximum_textures: usize,
    maximum_external_surfaces: usize,
    maximum_resources: usize,
    maximum_surfaces: usize,

    pub fn create(
        allocator: std.mem.Allocator,
        provider: linux_surface.Provider,
        policy: config.GpuPolicy,
        memory: config.MemoryBudgets,
    ) Error!render.Renderer {
        const self = try allocator.create(Renderer);
        errdefer allocator.destroy(self);
        const device = try device_mod.Context.create(allocator, policy, provider.formats());
        errdefer device.deinit();
        var pipelines = try pipeline_mod.Pipelines.create(device, device.export_format.vulkan);
        errdefer pipelines.deinit(device);
        const maximum_sets: u32 = @intCast(std.math.clamp(policy.maximum_gpu_bytes / 4096, 1024, 65_536));
        const descriptor_pool = try resource.createDescriptorPool(device, maximum_sets);
        errdefer device.device_dispatch.destroy_descriptor_pool(device.device, descriptor_pool, null);
        self.* = .{
            .allocator = allocator,
            .provider = provider,
            .policy = policy,
            .device = device,
            .pipelines = pipelines,
            .descriptor_pool = descriptor_pool,
            .mesh = mesh_mod.Mesh.init(allocator, .{
                .maximum_edges = memory.path_edge_count,
                .maximum_work_units = memory.path_work_units,
                .maximum_output_vertices = memory.upload_ring_bytes / @sizeOf(path_tessellator.Vertex),
                .maximum_cache_bytes = memory.path_cache_bytes,
            }),
            .surfaces = std.AutoHashMap(u64, Surface).init(allocator),
            .textures = std.AutoHashMap(u64, resource.Texture).init(allocator),
            .external_surfaces = std.AutoHashMap(u64, ExternalTexture).init(allocator),
            .extensions = extension.Registry.initWithLimit(allocator, memory.render_extension_count),
            .maximum_textures = memory.texture_count,
            .maximum_external_surfaces = memory.external_surface_count,
            .maximum_resources = std.math.add(usize, memory.texture_count, memory.external_surface_count) catch return error.BudgetExceeded,
            .maximum_surfaces = std.math.mul(
                usize,
                memory.window_count,
                @as(usize, policy.frames_in_flight) + 1,
            ) catch return error.BudgetExceeded,
        };
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: render.Renderer.VTable = .{
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

    fn capabilities(_: *anyopaque) render.Capabilities {
        return .{ .external_surfaces = true, .offscreen_readback = true, .custom_materials = true };
    }

    fn deviceGeneration(raw: *anyopaque) render.DeviceGeneration {
        return cast(raw).generation;
    }

    fn beginFrame(raw: *anyopaque, descriptor: render.FrameDescriptor) Error!render.FrameToken {
        const self = cast(raw);
        if (self.active != null) return error.FrameActive;
        if (descriptor.drawable_width == 0 or descriptor.drawable_height == 0) return error.WindowNotConfigured;
        try self.collect();
        const surface_value = try self.ensureSurface(descriptor.window, descriptor.drawable_width, descriptor.drawable_height);
        var frame = surface_value.acquire(self);
        if (frame == null) {
            for (surface_value.frames) |*candidate| {
                if (!candidate.in_flight) continue;
                try candidate.present.wait(self.device);
                break;
            }
            try self.collect();
            frame = surface_value.acquire(self);
        }
        const selected = frame orelse return error.ResourceBusy;
        const token: render.FrameToken = .{ .value = self.next_token, .device_generation = self.generation };
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        self.active = .{ .token = token, .descriptor = descriptor, .frame = selected };
        return token;
    }

    fn submit(raw: *anyopaque, token: render.FrameToken, view: render.SceneView) Error!render.Submission {
        const self = cast(raw);
        const active = self.active orelse return error.FramePhaseViolation;
        defer self.active = null;
        if (active.token.value != token.value or token.device_generation != self.generation) return error.DeviceLost;
        try scene.validate(view);
        try self.mesh.build(active.descriptor, view);

        const vertex_bytes = std.mem.sliceAsBytes(self.mesh.vertices.items);
        if (vertex_bytes.len > active.descriptor.maximum_upload_bytes) return error.BudgetExceeded;
        try self.in_flight.ensureUnusedCapacity(self.allocator, 1);
        try active.frame.vertex_buffer.ensureMappedCapacity(
            self.device,
            @max(vertex_bytes.len, @sizeOf(pipeline_mod.Vertex)),
            abi.buffer_usage_vertex_buffer_bit,
        );
        if (vertex_bytes.len != 0) try active.frame.vertex_buffer.write(self.device, 0, vertex_bytes);

        const layout_snapshot = try FrameLayoutSnapshot.capture(active.frame);
        var submitted = false;
        defer if (!submitted) layout_snapshot.restore(active.frame);
        try self.recordPresentCommands(active.frame, active.descriptor, view);
        const prior_release = active.frame.present.release_value;
        const submission_state = try active.frame.present.beginSubmission(self.device);
        const command_info: abi.CommandBufferSubmitInfo = .{ .command_buffer = active.frame.command };
        var wait_info: abi.SemaphoreSubmitInfo = undefined;
        var signal_info: abi.SemaphoreSubmitInfo = undefined;
        const explicit = self.provider.explicitSync();
        if (explicit) {
            if (active.frame.present.semaphore == 0 or active.frame.present.timeline == 0) return error.MissingCapability;
            wait_info = .{
                .semaphore = active.frame.present.semaphore,
                .value = prior_release,
                .stage_mask = abi.pipeline_stage_2_all_commands_bit,
            };
            signal_info = .{
                .semaphore = active.frame.present.semaphore,
                .value = active.frame.present.acquire_value,
                .stage_mask = abi.pipeline_stage_2_all_commands_bit,
            };
        }
        const submit_info: abi.SubmitInfo2 = .{
            .wait_semaphore_info_count = if (explicit and prior_release != 0) 1 else 0,
            .wait_semaphore_infos = if (explicit and prior_release != 0) @ptrCast(&wait_info) else null,
            .command_buffer_info_count = 1,
            .command_buffer_infos = @ptrCast(&command_info),
            .signal_semaphore_info_count = if (explicit) 1 else 0,
            .signal_semaphore_infos = if (explicit) @ptrCast(&signal_info) else null,
        };
        const submit_result = self.device.device_dispatch.queue_submit_2(self.device.queue, 1, @ptrCast(&submit_info), active.frame.present.fence);
        if (submit_result != abi.success) {
            try active.frame.present.abortSubmission(self.device, submission_state);
            device_mod.check(submit_result) catch |err| return err;
            return error.PlatformFailure;
        }
        submitted = true;

        self.submitted +%= 1;
        if (self.submitted == 0) self.submitted = 1;
        active.frame.in_flight = true;
        active.frame.submission_epoch = self.submitted;
        active.frame.present.submitted_epoch = self.submitted;
        self.in_flight.appendAssumeCapacity(.{ .epoch = self.submitted, .frame = active.frame });

        if (!explicit) try active.frame.present.wait(self.device);
        self.provider.present(.{
            .window = active.descriptor.window,
            .buffer = active.frame.present.buffer,
            .damage = .{ .origin = .{}, .size = active.descriptor.logical_size },
            .acquire = if (explicit) .{ .timeline = active.frame.present.timeline, .value = active.frame.present.acquire_value } else null,
            .release = if (explicit) .{ .timeline = active.frame.present.timeline, .value = active.frame.present.release_value } else null,
        }) catch |err| {
            // Submission already consumed every sampled resource. Wait for the
            // fence before reporting a presentation failure so App may safely
            // leave those resources at their previously committed epochs.
            active.frame.present.wait(self.device) catch return error.DeviceLost;
            return err;
        };
        return .{ .epoch = self.submitted, .device_generation = self.generation, .presented = true };
    }

    fn recordPresentCommands(self: *Renderer, frame: *Frame, descriptor: render.FrameDescriptor, view: render.SceneView) Error!void {
        const dispatch = self.device.device_dispatch;
        try device_mod.check(dispatch.reset_command_buffer(frame.command, 0));
        const begin_info: abi.CommandBufferBeginInfo = .{};
        try device_mod.check(dispatch.begin_command_buffer(frame.command, &begin_info));
        errdefer _ = dispatch.end_command_buffer(frame.command);
        try self.acquirePresentedImage(frame.command, &frame.present.image);
        try self.encodeScene(frame, descriptor, view, frame.command, &frame.present.image, self.device.export_format.vulkan, &self.pipelines);
        self.releasePresentedImage(frame.command, &frame.present.image);
        try device_mod.check(dispatch.end_command_buffer(frame.command));
    }

    fn acquirePresentedImage(self: *Renderer, command: abi.CommandBuffer, image: *resource.Image) Error!void {
        const from_external = image.layout != abi.image_layout_undefined;
        const barrier: abi.ImageMemoryBarrier2 = .{
            .source_stage_mask = if (from_external) abi.pipeline_stage_2_all_commands_bit else abi.pipeline_stage_2_none,
            .source_access_mask = abi.access_2_none,
            .destination_stage_mask = abi.pipeline_stage_2_color_attachment_output_bit,
            .destination_access_mask = abi.access_2_color_attachment_write_bit,
            .old_layout = image.layout,
            .new_layout = abi.image_layout_color_attachment_optimal,
            .source_queue_family_index = if (from_external) abi.queue_family_foreign_ext else abi.queue_family_ignored,
            .destination_queue_family_index = if (from_external) self.device.queue_family else abi.queue_family_ignored,
            .image = image.handle,
        };
        const dependency: abi.DependencyInfo = .{
            .image_memory_barrier_count = 1,
            .image_memory_barriers = @ptrCast(&barrier),
        };
        self.device.device_dispatch.cmd_pipeline_barrier_2(command, &dependency);
        image.layout = abi.image_layout_color_attachment_optimal;
    }

    fn releasePresentedImage(self: *Renderer, command: abi.CommandBuffer, image: *resource.Image) void {
        const barrier: abi.ImageMemoryBarrier2 = .{
            .source_stage_mask = abi.pipeline_stage_2_color_attachment_output_bit,
            .source_access_mask = abi.access_2_color_attachment_write_bit,
            .destination_stage_mask = abi.pipeline_stage_2_none,
            .destination_access_mask = abi.access_2_none,
            .old_layout = image.layout,
            .new_layout = abi.image_layout_general,
            .source_queue_family_index = self.device.queue_family,
            .destination_queue_family_index = abi.queue_family_foreign_ext,
            .image = image.handle,
        };
        const dependency: abi.DependencyInfo = .{
            .image_memory_barrier_count = 1,
            .image_memory_barriers = @ptrCast(&barrier),
        };
        self.device.device_dispatch.cmd_pipeline_barrier_2(command, &dependency);
        image.layout = abi.image_layout_general;
    }

    fn encodeScene(
        self: *Renderer,
        frame: *Frame,
        descriptor: render.FrameDescriptor,
        view: render.SceneView,
        command: abi.CommandBuffer,
        root: *resource.Image,
        format: abi.Format,
        pipelines: *pipeline_mod.Pipelines,
    ) Error!void {
        var targets: [65]?*resource.Image = undefined;
        @memset(&targets, null);
        targets[0] = root;
        var target_bounds: [65]mesh_mod.DeviceBounds = undefined;
        target_bounds[0] = .{ .left = 0, .top = 0, .width = root.width, .height = root.height };
        var current: u8 = 0;
        try self.beginRendering(command, root, target_bounds[0], descriptor.clear_color, true);
        const buffers = [1]abi.Buffer{frame.vertex_buffer.handle};
        const offsets = [1]abi.DeviceSize{0};
        self.device.device_dispatch.cmd_bind_vertex_buffers(command, 0, 1, &buffers, &offsets);

        for (self.mesh.commands.items) |mesh_command| switch (mesh_command) {
            .begin_layer => |layer| {
                self.device.device_dispatch.cmd_end_rendering(command);
                const target = try frame.acquireLayer(self, layer.target, layer.bounds, format);
                targets[layer.target] = &target.image;
                target_bounds[layer.target] = layer.bounds;
                resource.transition(
                    self.device,
                    command,
                    &target.image,
                    abi.image_layout_color_attachment_optimal,
                    if (target.image.layout == abi.image_layout_undefined) abi.pipeline_stage_2_none else abi.pipeline_stage_2_fragment_shader_bit,
                    if (target.image.layout == abi.image_layout_undefined) abi.access_2_none else abi.access_2_shader_sampled_read_bit,
                    abi.pipeline_stage_2_color_attachment_output_bit,
                    abi.access_2_color_attachment_write_bit,
                );
                current = layer.target;
                try self.beginRendering(command, &target.image, layer.bounds, .transparent, true);
            },
            .draw => |draw_value| {
                if (draw_value.target != current) return error.InvalidScene;
                try self.draw(command, pipelines, draw_value);
            },
            .custom => |custom| {
                if (custom.target != current) return error.InvalidScene;
                const target = targets[current] orelse return error.InvalidScene;
                const bounds = target_bounds[current];
                const pass = view.custom_passes[custom.pass_index];
                const payload = view.custom_payload[@as(usize, pass.payload_start)..][0..pass.payload_length];
                setCustomScissor(self.device.device_dispatch, command, descriptor, custom.clip, bounds);
                const logical_target = bounds.logical(descriptor.scale_factor);
                try self.extensions.encode(
                    extension.decodeId(pass.extension),
                    .{ .vulkan = .{
                        .instance = optionalPointerValue(self.device.instance),
                        .physical_device = optionalPointerValue(self.device.physical_device),
                        .device = optionalPointerValue(self.device.device),
                        .graphics_queue = optionalPointerValue(self.device.queue),
                        .queue_family = self.device.queue_family,
                        .device_dispatch = @ptrCast(&self.device.device_dispatch),
                    } },
                    .{ .vulkan = .{
                        .device = optionalPointerValue(self.device.device),
                        .command_buffer = optionalPointerValue(command),
                        .target_image = @intCast(target.handle),
                        .target_image_view = @intCast(target.view),
                        .target_format = @intCast(format),
                        .device_dispatch = @ptrCast(&self.device.device_dispatch),
                        .geometry = .{
                            .window = descriptor.window,
                            .logical_size = descriptor.logical_size,
                            .drawable_width = descriptor.drawable_width,
                            .drawable_height = descriptor.drawable_height,
                            .scale_factor = descriptor.scale_factor,
                            .clear_color = descriptor.clear_color,
                            .bounds = custom.transform.transformRectBounds(pass.bounds),
                            .clip = custom.clip,
                            .transform = custom.transform,
                            .opacity = 1,
                            .target_origin = logical_target.origin,
                            .target_width = bounds.width,
                            .target_height = bounds.height,
                        },
                    } },
                    payload,
                    pass.flags,
                    self.generation,
                    self.submitted +| 1,
                );
                setFullViewportAndScissor(self.device.device_dispatch, command, bounds);
                self.device.device_dispatch.cmd_bind_vertex_buffers(command, 0, 1, &buffers, &offsets);
            },
            .end_layer => |layer| {
                if (current != layer.target) return error.InvalidScene;
                self.device.device_dispatch.cmd_end_rendering(command);
                const child = targets[layer.target] orelse return error.InvalidScene;
                resource.transition(
                    self.device,
                    command,
                    child,
                    abi.image_layout_shader_read_only_optimal,
                    abi.pipeline_stage_2_color_attachment_output_bit,
                    abi.access_2_color_attachment_write_bit,
                    abi.pipeline_stage_2_fragment_shader_bit,
                    abi.access_2_shader_sampled_read_bit,
                );
                const parent = targets[layer.parent] orelse return error.InvalidScene;
                current = layer.parent;
                const sampled = &frame.layers.items[layer.target];
                const blend_mode = std.enums.fromInt(@import("../../scene/abi.zig").BlendMode, view.layers[@intCast(layer.layer)].blend_mode) orelse return error.InvalidScene;
                var selected_pipeline = pipelines.texture;
                var selected_descriptor = sampled.descriptor;
                if (blend_mode != .normal) {
                    const child_bounds = target_bounds[layer.target];
                    const parent_bounds = target_bounds[layer.parent];
                    if (child_bounds.left < parent_bounds.left or child_bounds.top < parent_bounds.top or
                        child_bounds.right() > parent_bounds.right() or child_bounds.bottom() > parent_bounds.bottom())
                        return error.InvalidScene;
                    const backdrop = try frame.acquireBackdrop(self, layer.target, child_bounds, format);
                    resource.transition(
                        self.device,
                        command,
                        parent,
                        abi.image_layout_transfer_src_optimal,
                        abi.pipeline_stage_2_color_attachment_output_bit,
                        abi.access_2_color_attachment_write_bit,
                        abi.pipeline_stage_2_transfer_bit,
                        abi.access_2_transfer_read_bit,
                    );
                    resource.transition(
                        self.device,
                        command,
                        &backdrop.image,
                        abi.image_layout_transfer_dst_optimal,
                        if (backdrop.image.layout == abi.image_layout_undefined) abi.pipeline_stage_2_none else abi.pipeline_stage_2_fragment_shader_bit,
                        if (backdrop.image.layout == abi.image_layout_undefined) abi.access_2_none else abi.access_2_shader_sampled_read_bit,
                        abi.pipeline_stage_2_transfer_bit,
                        abi.access_2_transfer_write_bit,
                    );
                    const copy: abi.ImageCopy = .{
                        .source_offset = .{
                            .x = @intCast(child_bounds.left - parent_bounds.left),
                            .y = @intCast(child_bounds.top - parent_bounds.top),
                        },
                        .extent = .{ .width = child_bounds.width, .height = child_bounds.height, .depth = 1 },
                    };
                    self.device.device_dispatch.cmd_copy_image(
                        command,
                        parent.handle,
                        parent.layout,
                        backdrop.image.handle,
                        backdrop.image.layout,
                        1,
                        @ptrCast(&copy),
                    );
                    resource.transition(
                        self.device,
                        command,
                        parent,
                        abi.image_layout_color_attachment_optimal,
                        abi.pipeline_stage_2_transfer_bit,
                        abi.access_2_transfer_read_bit,
                        abi.pipeline_stage_2_color_attachment_output_bit,
                        abi.access_2_color_attachment_write_bit,
                    );
                    resource.transition(
                        self.device,
                        command,
                        &backdrop.image,
                        abi.image_layout_shader_read_only_optimal,
                        abi.pipeline_stage_2_transfer_bit,
                        abi.access_2_transfer_write_bit,
                        abi.pipeline_stage_2_fragment_shader_bit,
                        abi.access_2_shader_sampled_read_bit,
                    );
                    selected_descriptor = try backdrop.compositeDescriptor(self, sampled.image.view);
                    selected_pipeline = switch (blend_mode) {
                        .normal => unreachable,
                        .multiply => pipelines.composite_multiply,
                        .screen => pipelines.composite_screen,
                        .overlay => pipelines.composite_overlay,
                        .plus_lighter => pipelines.composite_plus,
                    };
                }
                try self.beginRendering(command, parent, target_bounds[layer.parent], .transparent, false);
                self.device.device_dispatch.cmd_bind_pipeline(command, abi.pipeline_bind_point_graphics, selected_pipeline);
                const sets = [1]abi.DescriptorSet{selected_descriptor};
                self.device.device_dispatch.cmd_bind_descriptor_sets(command, abi.pipeline_bind_point_graphics, pipelines.layout, 0, 1, &sets, 0, null);
                self.device.device_dispatch.cmd_draw(command, layer.vertex_count, 1, layer.first_vertex, 0);
            },
        };
        self.device.device_dispatch.cmd_end_rendering(command);
    }

    fn beginRendering(
        self: *Renderer,
        command: abi.CommandBuffer,
        image: *resource.Image,
        bounds: mesh_mod.DeviceBounds,
        clear: geometry.Color,
        should_clear: bool,
    ) Error!void {
        const premultiplied = clear.premultiplied();
        const attachment: abi.RenderingAttachmentInfo = .{
            .image_view = image.view,
            .image_layout = abi.image_layout_color_attachment_optimal,
            .load_op = if (should_clear) abi.attachment_load_op_clear else abi.attachment_load_op_load,
            .clear_value = .{ .color = .{ .float32 = .{ premultiplied.r, premultiplied.g, premultiplied.b, premultiplied.a } } },
        };
        const info: abi.RenderingInfo = .{
            .render_area = .{ .extent = .{ .width = bounds.width, .height = bounds.height } },
            .color_attachments = @ptrCast(&attachment),
        };
        self.device.device_dispatch.cmd_begin_rendering(command, &info);
        const viewport: abi.Viewport = .{ .x = 0, .y = 0, .width = @floatFromInt(bounds.width), .height = @floatFromInt(bounds.height) };
        const scissor: abi.Rect2D = .{ .extent = .{ .width = bounds.width, .height = bounds.height } };
        self.device.device_dispatch.cmd_set_viewport(command, 0, 1, @ptrCast(&viewport));
        self.device.device_dispatch.cmd_set_scissor(command, 0, 1, @ptrCast(&scissor));
    }

    fn draw(self: *Renderer, command: abi.CommandBuffer, pipelines: *pipeline_mod.Pipelines, draw_value: mesh_mod.Draw) Error!void {
        const pipeline: abi.Pipeline = switch (draw_value.kind) {
            .color => pipelines.color,
            .monochrome_texture => pipelines.monochrome,
            .color_texture => pipelines.texture,
            .external_texture => switch (std.enums.fromInt(render.ColorSpace, draw_value.variant) orelse .unknown) {
                .display_p3 => pipelines.external_p3,
                .rec2020_pq => pipelines.external_pq,
                .rec2020_hlg => pipelines.external_hlg,
                .srgb, .linear_srgb, .extended_linear_srgb, .unknown => pipelines.texture,
            },
        };
        self.device.device_dispatch.cmd_bind_pipeline(command, abi.pipeline_bind_point_graphics, pipeline);
        switch (draw_value.kind) {
            .color => {},
            .monochrome_texture, .color_texture => {
                const texture = self.textures.get(draw_value.resource) orelse return error.InvalidHandle;
                const sets = [1]abi.DescriptorSet{texture.descriptor};
                self.device.device_dispatch.cmd_bind_descriptor_sets(command, abi.pipeline_bind_point_graphics, pipelines.layout, 0, 1, &sets, 0, null);
            },
            .external_texture => {
                const texture = self.external_surfaces.get(draw_value.resource) orelse return error.InvalidHandle;
                const sets = [1]abi.DescriptorSet{texture.descriptor};
                self.device.device_dispatch.cmd_bind_descriptor_sets(command, abi.pipeline_bind_point_graphics, pipelines.layout, 0, 1, &sets, 0, null);
            },
        }
        self.device.device_dispatch.cmd_draw(command, draw_value.vertex_count, 1, draw_value.first_vertex, 0);
    }

    fn ensureSurface(self: *Renderer, window: handles.WindowId, width: u32, height: u32) Error!*Surface {
        if (self.surfaces.getPtr(window.encode())) |existing| {
            if (existing.width == width and existing.height == height) return existing;
            try self.collect();
            if (self.surfaces.count() +| self.retired_surfaces.items.len >= self.maximum_surfaces)
                return error.BudgetExceeded;
            var replacement = try Surface.create(self, window, width, height);
            errdefer replacement.deinit(self);
            try self.retired_surfaces.ensureUnusedCapacity(self.allocator, 1);
            const removed = self.surfaces.fetchRemove(window.encode()) orelse unreachable;
            self.retired_surfaces.appendAssumeCapacity(removed.value);
            self.surfaces.putAssumeCapacity(window.encode(), replacement);
            return self.surfaces.getPtr(window.encode()).?;
        }
        try self.collect();
        if (self.surfaces.count() +| self.retired_surfaces.items.len >= self.maximum_surfaces)
            return error.BudgetExceeded;
        try self.surfaces.ensureUnusedCapacity(1);
        var value = try Surface.create(self, window, width, height);
        errdefer value.deinit(self);
        self.surfaces.putAssumeCapacity(window.encode(), value);
        return self.surfaces.getPtr(window.encode()).?;
    }

    fn collect(self: *Renderer) Error!void {
        var index = self.in_flight_cursor;
        while (index < self.in_flight.items.len) : (index += 1) {
            const entry = &self.in_flight.items[index];
            if (entry.done) continue;
            if (entry.frame.submission_epoch != entry.epoch) continue;
            if (self.device.device_dispatch.get_fence_status(self.device.device, entry.frame.present.fence) != abi.success) continue;
            if (!self.provider.bufferReleased(entry.frame.present.buffer)) continue;
            entry.done = true;
            entry.frame.in_flight = false;
        }
        while (self.in_flight_cursor < self.in_flight.items.len and self.in_flight.items[self.in_flight_cursor].done) {
            self.completed = self.in_flight.items[self.in_flight_cursor].epoch;
            self.in_flight_cursor += 1;
        }
        if (self.in_flight_cursor > 1024 and self.in_flight_cursor * 2 >= self.in_flight.items.len) {
            const remaining = self.in_flight.items.len - self.in_flight_cursor;
            std.mem.copyForwards(InFlight, self.in_flight.items[0..remaining], self.in_flight.items[self.in_flight_cursor..]);
            self.in_flight.items.len = remaining;
            self.in_flight_cursor = 0;
        }

        index = 0;
        while (index < self.retired_surfaces.items.len) {
            if (!self.retired_surfaces.items[index].canDestroy(self)) {
                index += 1;
                continue;
            }
            var removed = self.retired_surfaces.swapRemove(index);
            removed.deinit(self);
        }
        index = 0;
        while (index < self.retired_textures.items.len) {
            if (self.retired_textures.items[index].release_after > self.completed) {
                index += 1;
                continue;
            }
            var removed = self.retired_textures.swapRemove(index);
            removed.texture.deinit(self.device, self.descriptor_pool);
        }
        index = 0;
        while (index < self.retired_external.items.len) {
            if (self.retired_external.items[index].release_after > self.completed) {
                index += 1;
                continue;
            }
            var removed = self.retired_external.swapRemove(index);
            removed.texture.deinit(self);
        }
        self.extensions.collect(self.completed);
    }

    fn renderOffscreen(raw: *anyopaque, target: render.OffscreenTarget, view: render.SceneView, allocator: std.mem.Allocator) Error!?render.Readback {
        const self = cast(raw);
        if (self.active != null) return error.FrameActive;
        if (target.width == 0 or target.height == 0) return error.InvalidConfiguration;
        try scene.validate(view);
        const format = resource.pixelFormat(target.format);
        var temporary_pipelines: ?pipeline_mod.Pipelines = null;
        defer if (temporary_pipelines) |*value| value.deinit(self.device);
        const pipelines = if (format == self.device.export_format.vulkan)
            &self.pipelines
        else blk: {
            temporary_pipelines = try pipeline_mod.Pipelines.create(self.device, format);
            break :blk &temporary_pipelines.?;
        };
        var root = try resource.Image.create(
            self.device,
            target.width,
            target.height,
            format,
            abi.image_usage_color_attachment_bit | abi.image_usage_transfer_src_bit | abi.image_usage_sampled_bit,
        );
        defer root.deinit(self.device);
        const command = try self.device.allocateCommandBuffer();
        defer self.device.freeCommandBuffer(command);
        var fence: abi.Fence = 0;
        const fence_info: abi.FenceCreateInfo = .{};
        try device_mod.check(self.device.device_dispatch.create_fence(self.device.device, &fence_info, null, &fence));
        defer self.device.device_dispatch.destroy_fence(self.device.device, fence, null);

        var frame: Frame = .{ .present = undefined, .command = command };
        defer {
            frame.vertex_buffer.deinit(self.device);
            for (frame.layers.items) |*value| value.deinit(self);
            frame.layers.deinit(self.allocator);
            for (frame.backdrops.items) |*value| value.deinit(self);
            frame.backdrops.deinit(self.allocator);
        }
        const descriptor: render.FrameDescriptor = .{
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
        try self.mesh.build(descriptor, view);
        const vertex_bytes = std.mem.sliceAsBytes(self.mesh.vertices.items);
        if (vertex_bytes.len > descriptor.maximum_upload_bytes) return error.BudgetExceeded;
        try frame.vertex_buffer.ensureMappedCapacity(self.device, @max(vertex_bytes.len, @sizeOf(pipeline_mod.Vertex)), abi.buffer_usage_vertex_buffer_bit);
        if (vertex_bytes.len != 0) try frame.vertex_buffer.write(self.device, 0, vertex_bytes);

        var readback_buffer: resource.Buffer = .{};
        defer readback_buffer.deinit(self.device);
        const bytes_per_pixel = bytesPerPixel(target.format);
        const stride = std.math.mul(usize, target.width, bytes_per_pixel) catch return error.BudgetExceeded;
        const byte_length = std.math.mul(usize, stride, target.height) catch return error.BudgetExceeded;
        if (target.readback) readback_buffer = try resource.Buffer.create(self.device, byte_length, abi.buffer_usage_transfer_dst_bit, true);

        try device_mod.check(self.device.device_dispatch.reset_command_buffer(command, 0));
        const begin_info: abi.CommandBufferBeginInfo = .{};
        try device_mod.check(self.device.device_dispatch.begin_command_buffer(command, &begin_info));
        resource.transition(self.device, command, &root, abi.image_layout_color_attachment_optimal, abi.pipeline_stage_2_none, abi.access_2_none, abi.pipeline_stage_2_color_attachment_output_bit, abi.access_2_color_attachment_write_bit);
        try self.encodeScene(&frame, descriptor, view, command, &root, format, pipelines);
        if (target.readback) {
            resource.transition(self.device, command, &root, abi.image_layout_transfer_src_optimal, abi.pipeline_stage_2_color_attachment_output_bit, abi.access_2_color_attachment_write_bit, abi.pipeline_stage_2_transfer_bit, abi.access_2_transfer_read_bit);
            const copy: abi.BufferImageCopy = .{ .image_extent = .{ .width = target.width, .height = target.height, .depth = 1 } };
            self.device.device_dispatch.cmd_copy_image_to_buffer(command, root.handle, root.layout, readback_buffer.handle, 1, @ptrCast(&copy));
        }
        try device_mod.check(self.device.device_dispatch.end_command_buffer(command));
        const command_info: abi.CommandBufferSubmitInfo = .{ .command_buffer = command };
        const submit_info: abi.SubmitInfo2 = .{
            .command_buffer_info_count = 1,
            .command_buffer_infos = @ptrCast(&command_info),
        };
        try device_mod.check(self.device.device_dispatch.queue_submit_2(self.device.queue, 1, @ptrCast(&submit_info), fence));
        const fences = [1]abi.Fence{fence};
        try device_mod.check(self.device.device_dispatch.wait_for_fences(self.device.device, 1, &fences, abi.vk_true, std.math.maxInt(u64)));
        if (!target.readback) return null;
        try readback_buffer.allocation.invalidate(self.device);
        const mapped = readback_buffer.allocation.mapped orelse return error.PlatformFailure;
        const pixels = try allocator.dupe(u8, mapped[0..byte_length]);
        return .{ .width = target.width, .height = target.height, .stride = stride, .format = target.format, .pixels = pixels };
    }

    fn completedEpoch(raw: *anyopaque) render.SubmissionEpoch {
        const self = cast(raw);
        self.collect() catch {};
        return self.completed;
    }

    fn invalidateSurface(raw: *anyopaque, window: handles.WindowId) Error!void {
        const self = cast(raw);
        try self.retired_surfaces.ensureUnusedCapacity(self.allocator, 1);
        const removed = self.surfaces.fetchRemove(window.encode()) orelse return;
        self.retired_surfaces.appendAssumeCapacity(removed.value);
        try self.collect();
    }

    fn recover(raw: *anyopaque, policy: config.GpuPolicy) Error!void {
        const self = cast(raw);
        self.active = null;
        self.waitAllGpu() catch {};

        const replacement_device = try device_mod.Context.create(self.allocator, policy, self.provider.formats());
        errdefer replacement_device.deinit();
        var replacement_pipelines = try pipeline_mod.Pipelines.create(replacement_device, replacement_device.export_format.vulkan);
        errdefer replacement_pipelines.deinit(replacement_device);
        const maximum_sets: u32 = @intCast(std.math.clamp(policy.maximum_gpu_bytes / 4096, 1024, 65_536));
        const replacement_pool = try resource.createDescriptorPool(replacement_device, maximum_sets);
        errdefer replacement_device.device_dispatch.destroy_descriptor_pool(replacement_device.device, replacement_pool, null);

        var next_generation = self.generation +% 1;
        if (next_generation == 0) next_generation = 1;
        self.extensions.deviceLost(next_generation);

        self.releaseAllGpuResources();
        self.device.device_dispatch.destroy_descriptor_pool(self.device.device, self.descriptor_pool, null);
        self.pipelines.deinit(self.device);
        self.device.deinit();

        self.device = replacement_device;
        self.pipelines = replacement_pipelines;
        self.descriptor_pool = replacement_pool;
        self.policy = policy;
        self.generation = next_generation;
        self.completed = self.submitted;
    }

    fn releaseAllGpuResources(self: *Renderer) void {
        var surface_iterator = self.surfaces.valueIterator();
        while (surface_iterator.next()) |surface_value| surface_value.deinit(self);
        self.surfaces.clearRetainingCapacity();
        for (self.retired_surfaces.items) |*surface_value| surface_value.deinit(self);
        self.retired_surfaces.clearRetainingCapacity();

        var texture_iterator = self.textures.valueIterator();
        while (texture_iterator.next()) |texture| texture.deinit(self.device, self.descriptor_pool);
        self.textures.clearRetainingCapacity();
        for (self.retired_textures.items) |*retired| retired.texture.deinit(self.device, self.descriptor_pool);
        self.retired_textures.clearRetainingCapacity();

        var external_iterator = self.external_surfaces.valueIterator();
        while (external_iterator.next()) |external| external.deinit(self);
        self.external_surfaces.clearRetainingCapacity();
        for (self.retired_external.items) |*retired| retired.texture.deinit(self);
        self.retired_external.clearRetainingCapacity();

        self.in_flight.clearRetainingCapacity();
        self.in_flight_cursor = 0;
    }

    fn createTexture(raw: *anyopaque, id: handles.TextureId, description: render.TextureDescriptor) Error!void {
        const self = cast(raw);
        try self.collect();
        if (description.width == 0 or description.height == 0) return error.InvalidConfiguration;
        if (self.textures.contains(id.encode())) return error.ResourceBusy;
        if (self.textures.count() >= self.maximum_textures) return error.BudgetExceeded;
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        try self.textures.ensureUnusedCapacity(1);
        var image = try resource.Image.create(
            self.device,
            description.width,
            description.height,
            resource.pixelFormat(description.format),
            abi.image_usage_sampled_bit | abi.image_usage_transfer_dst_bit |
                (if (description.usage == .render_target) abi.image_usage_color_attachment_bit else 0),
        );
        errdefer image.deinit(self.device);
        const descriptor = try resource.allocateImageDescriptor(
            self.device,
            self.descriptor_pool,
            self.pipelines.descriptor_layout,
            self.pipelines.sampler,
            image.view,
        );
        self.textures.putAssumeCapacity(id.encode(), .{ .id = id, .image = image, .descriptor = descriptor, .description = description });
    }

    fn writeTexture(raw: *anyopaque, id: handles.TextureId, region: render.TextureRegion, pixels: []const u8, stride: usize) Error!void {
        const self = cast(raw);
        const texture = self.textures.getPtr(id.encode()) orelse return error.InvalidHandle;
        if (region.width == 0 or region.height == 0) return;
        if (@as(u64, region.x) + region.width > texture.description.width or @as(u64, region.y) + region.height > texture.description.height)
            return error.InvalidConfiguration;
        const row_bytes = std.math.mul(usize, region.width, bytesPerPixel(texture.description.format)) catch return error.BudgetExceeded;
        if (stride < row_bytes) return error.InvalidConfiguration;
        const required = std.math.add(usize, std.math.mul(usize, stride, region.height - 1) catch return error.BudgetExceeded, row_bytes) catch return error.BudgetExceeded;
        if (pixels.len < required) return error.InvalidConfiguration;
        const packed_length = std.math.mul(usize, row_bytes, region.height) catch return error.BudgetExceeded;
        var staging = try resource.Buffer.create(self.device, packed_length, abi.buffer_usage_transfer_src_bit, true);
        defer staging.deinit(self.device);
        const mapped = staging.allocation.mapped orelse return error.PlatformFailure;
        var row: usize = 0;
        while (row < region.height) : (row += 1)
            @memcpy(mapped[row * row_bytes ..][0..row_bytes], pixels[row * stride ..][0..row_bytes]);
        try staging.allocation.flush(self.device);
        const command = try self.device.allocateCommandBuffer();
        defer self.device.freeCommandBuffer(command);
        var fence: abi.Fence = 0;
        const fence_info: abi.FenceCreateInfo = .{};
        try device_mod.check(self.device.device_dispatch.create_fence(self.device.device, &fence_info, null, &fence));
        defer self.device.device_dispatch.destroy_fence(self.device.device, fence, null);
        const begin_info: abi.CommandBufferBeginInfo = .{};
        const previous_layout = texture.image.layout;
        var submitted = false;
        defer {
            if (!submitted) texture.image.layout = previous_layout;
        }
        try device_mod.check(self.device.device_dispatch.begin_command_buffer(command, &begin_info));
        resource.transition(
            self.device,
            command,
            &texture.image,
            abi.image_layout_transfer_dst_optimal,
            if (texture.image.layout == abi.image_layout_undefined) abi.pipeline_stage_2_none else abi.pipeline_stage_2_fragment_shader_bit,
            if (texture.image.layout == abi.image_layout_undefined) abi.access_2_none else abi.access_2_shader_sampled_read_bit,
            abi.pipeline_stage_2_transfer_bit,
            abi.access_2_transfer_write_bit,
        );
        const copy: abi.BufferImageCopy = .{
            .image_offset = .{ .x = @intCast(region.x), .y = @intCast(region.y) },
            .image_extent = .{ .width = region.width, .height = region.height, .depth = 1 },
        };
        self.device.device_dispatch.cmd_copy_buffer_to_image(command, staging.handle, texture.image.handle, texture.image.layout, 1, @ptrCast(&copy));
        resource.transition(self.device, command, &texture.image, abi.image_layout_shader_read_only_optimal, abi.pipeline_stage_2_transfer_bit, abi.access_2_transfer_write_bit, abi.pipeline_stage_2_fragment_shader_bit, abi.access_2_shader_sampled_read_bit);
        try device_mod.check(self.device.device_dispatch.end_command_buffer(command));
        const command_info: abi.CommandBufferSubmitInfo = .{ .command_buffer = command };
        const submit_info: abi.SubmitInfo2 = .{ .command_buffer_info_count = 1, .command_buffer_infos = @ptrCast(&command_info) };
        try device_mod.check(self.device.device_dispatch.queue_submit_2(self.device.queue, 1, @ptrCast(&submit_info), fence));
        submitted = true;
        const fences = [1]abi.Fence{fence};
        try device_mod.check(self.device.device_dispatch.wait_for_fences(self.device.device, 1, &fences, abi.vk_true, std.math.maxInt(u64)));
        try self.collect();
    }

    fn destroyTexture(raw: *anyopaque, id: handles.TextureId, release_after: render.SubmissionEpoch) Error!void {
        const self = cast(raw);
        try self.collect();
        try self.retired_textures.ensureUnusedCapacity(self.allocator, 1);
        const removed = self.textures.fetchRemove(id.encode()) orelse return error.InvalidHandle;
        self.retired_textures.appendAssumeCapacity(.{ .texture = removed.value, .release_after = release_after });
    }

    fn importExternalSurface(raw: *anyopaque, id: handles.SurfaceId, description: render.ExternalSurfaceDescriptor) Error!void {
        const self = cast(raw);
        if (description.width == 0 or description.height == 0) return error.InvalidConfiguration;
        if (self.external_surfaces.contains(id.encode())) return error.ResourceBusy;
        if (self.external_surfaces.count() >= self.maximum_external_surfaces) return error.BudgetExceeded;
        try self.collect();
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        try self.external_surfaces.ensureUnusedCapacity(1);
        var texture = try self.createExternalTexture(description);
        errdefer texture.deinit(self);
        self.external_surfaces.putAssumeCapacity(id.encode(), texture);
    }

    fn replaceExternalSurface(raw: *anyopaque, id: handles.SurfaceId, description: render.ExternalSurfaceDescriptor, release_after: render.SubmissionEpoch) Error!void {
        const self = cast(raw);
        const existing = self.external_surfaces.getPtr(id.encode()) orelse return error.InvalidHandle;
        try self.collect();
        if (self.totalResourceCount() >= self.maximum_resources) return error.BudgetExceeded;
        try self.retired_external.ensureUnusedCapacity(self.allocator, 1);
        var replacement = try self.createExternalTexture(description);
        errdefer replacement.deinit(self);
        const old = existing.*;
        existing.* = replacement;
        self.retired_external.appendAssumeCapacity(.{ .texture = old, .release_after = release_after });
    }

    fn destroyExternalSurface(raw: *anyopaque, id: handles.SurfaceId, release_after: render.SubmissionEpoch) Error!void {
        const self = cast(raw);
        try self.collect();
        try self.retired_external.ensureUnusedCapacity(self.allocator, 1);
        const removed = self.external_surfaces.fetchRemove(id.encode()) orelse return error.InvalidHandle;
        self.retired_external.appendAssumeCapacity(.{ .texture = removed.value, .release_after = release_after });
    }

    fn registerExtension(raw: *anyopaque, descriptor: extension.Descriptor) Error!handles.RenderExtensionId {
        if (descriptor.requirements.depth != null) return error.Unsupported;
        const self = cast(raw);
        try self.collect();
        return self.extensions.register(descriptor);
    }

    fn destroyExtension(raw: *anyopaque, id: handles.RenderExtensionId, release_after: render.SubmissionEpoch) Error!void {
        try cast(raw).extensions.destroy(id, release_after);
    }

    fn createExternalTexture(self: *Renderer, description: render.ExternalSurfaceDescriptor) Error!ExternalTexture {
        switch (description.native) {
            .vulkan_image => |native| {
                if (native.image_view == 0) return error.InvalidHandle;
                const descriptor = try resource.allocateImageDescriptorWithLayout(
                    self.device,
                    self.descriptor_pool,
                    self.pipelines.descriptor_layout,
                    self.pipelines.sampler,
                    native.image_view,
                    @intCast(native.layout),
                );
                return .{
                    .descriptor = descriptor,
                    .borrowed_view = native.image_view,
                    .layout = @intCast(native.layout),
                    .description = description,
                };
            },
            .dma_buf => |native| {
                var image = try self.importDmabuf(description, native);
                errdefer image.deinit(self.device);
                const descriptor = try resource.allocateImageDescriptorWithLayout(
                    self.device,
                    self.descriptor_pool,
                    self.pipelines.descriptor_layout,
                    self.pipelines.sampler,
                    image.view,
                    image.layout,
                );
                return .{ .descriptor = descriptor, .owned = image, .layout = image.layout, .description = description };
            },
            .metal_texture, .d3d11_texture => return error.Unsupported,
        }
    }

    fn totalResourceCount(self: *const Renderer) usize {
        return self.textures.count() +| self.retired_textures.items.len +|
            self.external_surfaces.count() +| self.retired_external.items.len;
    }

    fn importDmabuf(self: *Renderer, description: render.ExternalSurfaceDescriptor, native: render.DmaBufSurface) Error!resource.Image {
        if (native.file_descriptor < 0 or native.stride == 0) return error.InvalidConfiguration;
        const format = resource.pixelFormat(description.format);
        const plane: abi.SubresourceLayout = .{ .offset = native.offset, .size = 0, .row_pitch = native.stride, .array_pitch = 0, .depth_pitch = 0 };
        const modifier: abi.ImageDrmFormatModifierExplicitCreateInfo = .{
            .modifier = native.modifier,
            .plane_count = 1,
            .plane_layouts = @ptrCast(&plane),
        };
        const external: abi.ExternalMemoryImageCreateInfo = .{
            .next = &modifier,
            .handle_types = abi.external_memory_handle_type_dma_buf_bit_ext,
        };
        const image_info: abi.ImageCreateInfo = .{
            .next = &external,
            .format = format,
            .extent = .{ .width = description.width, .height = description.height, .depth = 1 },
            .tiling = abi.image_tiling_drm_format_modifier_ext,
            .usage = abi.image_usage_sampled_bit,
        };
        var image_handle: abi.Image = 0;
        try device_mod.check(self.device.device_dispatch.create_image(self.device.device, &image_info, null, &image_handle));
        errdefer self.device.device_dispatch.destroy_image(self.device.device, image_handle, null);
        var requirements: abi.MemoryRequirements = undefined;
        self.device.device_dispatch.get_image_memory_requirements(self.device.device, image_handle, &requirements);
        const duplicate = try sys.duplicate(native.file_descriptor);
        var descriptor_owned = true;
        defer if (descriptor_owned) sys.close(duplicate);
        var fd_properties: abi.MemoryFdProperties = .{};
        try device_mod.check(self.device.device_dispatch.get_memory_fd_properties(
            self.device.device,
            abi.external_memory_handle_type_dma_buf_bit_ext,
            duplicate,
            &fd_properties,
        ));
        const memory_bits = requirements.memory_type_bits & fd_properties.memory_type_bits;
        const memory_type = try self.device.findMemoryType(memory_bits, 0, abi.memory_property_device_local_bit);
        const dedicated: abi.MemoryDedicatedAllocateInfo = .{ .image = image_handle };
        const import_info: abi.ImportMemoryFdInfo = .{
            .next = &dedicated,
            .handle_type = abi.external_memory_handle_type_dma_buf_bit_ext,
            .fd = duplicate,
        };
        const allocation_info: abi.MemoryAllocateInfo = .{
            .next = &import_info,
            .allocation_size = requirements.size,
            .memory_type_index = memory_type,
        };
        var memory: abi.DeviceMemory = 0;
        try device_mod.check(self.device.device_dispatch.allocate_memory(self.device.device, &allocation_info, null, &memory));
        descriptor_owned = false;
        errdefer self.device.device_dispatch.free_memory(self.device.device, memory, null);
        try device_mod.check(self.device.device_dispatch.bind_image_memory(self.device.device, image_handle, memory, 0));
        const view_info: abi.ImageViewCreateInfo = .{ .image = image_handle, .format = format };
        var view: abi.ImageView = 0;
        try device_mod.check(self.device.device_dispatch.create_image_view(self.device.device, &view_info, null, &view));
        return .{
            .handle = image_handle,
            .view = view,
            .allocation = .{ .memory = memory, .size = requirements.size },
            .width = description.width,
            .height = description.height,
            .format = format,
            .layout = abi.image_layout_general,
        };
    }

    fn waitAllGpu(self: *Renderer) Error!void {
        try device_mod.check(self.device.device_dispatch.device_wait_idle(self.device.device));
        for (self.in_flight.items[self.in_flight_cursor..]) |*entry| {
            entry.done = true;
            entry.frame.in_flight = false;
            self.completed = @max(self.completed, entry.epoch);
        }
        self.in_flight_cursor = self.in_flight.items.len;
        self.extensions.collect(self.completed);
    }

    fn deinit(raw: *anyopaque) void {
        const self = cast(raw);
        self.waitAllGpu() catch {};
        self.releaseAllGpuResources();
        self.surfaces.deinit();
        self.retired_surfaces.deinit(self.allocator);
        self.textures.deinit();
        self.retired_textures.deinit(self.allocator);
        self.external_surfaces.deinit();
        self.retired_external.deinit(self.allocator);
        self.in_flight.deinit(self.allocator);
        self.mesh.deinit();
        self.extensions.deinit();
        self.device.device_dispatch.destroy_descriptor_pool(self.device.device, self.descriptor_pool, null);
        self.pipelines.deinit(self.device);
        self.device.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn bytesPerPixel(format: render.PixelFormat) usize {
    return switch (format) {
        .a8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba16_float => 8,
    };
}

fn optionalPointerValue(value: anytype) usize {
    return if (value) |pointer| @intFromPtr(pointer) else 0;
}

fn setCustomScissor(
    dispatch: abi.DeviceDispatch,
    command: abi.CommandBuffer,
    descriptor: render.FrameDescriptor,
    logical_clip: geometry.Rect,
    target: mesh_mod.DeviceBounds,
) void {
    const global_left = clampedDeviceFloor(logical_clip.minX(), descriptor.scale_factor, descriptor.drawable_width);
    const global_top = clampedDeviceFloor(logical_clip.minY(), descriptor.scale_factor, descriptor.drawable_height);
    const global_right = clampedDeviceCeil(logical_clip.maxX(), descriptor.scale_factor, descriptor.drawable_width);
    const global_bottom = clampedDeviceCeil(logical_clip.maxY(), descriptor.scale_factor, descriptor.drawable_height);
    const left = if (global_left <= target.left) 0 else @min(target.width, global_left - target.left);
    const top = if (global_top <= target.top) 0 else @min(target.height, global_top - target.top);
    const right = if (global_right <= target.left) 0 else @min(target.width, global_right - target.left);
    const bottom = if (global_bottom <= target.top) 0 else @min(target.height, global_bottom - target.top);
    const scissor: abi.Rect2D = .{
        .offset = .{ .x = @intCast(@min(left, right)), .y = @intCast(@min(top, bottom)) },
        .extent = .{ .width = @max(left, right) - @min(left, right), .height = @max(top, bottom) - @min(top, bottom) },
    };
    dispatch.cmd_set_scissor(command, 0, 1, @ptrCast(&scissor));
}

fn setFullViewportAndScissor(dispatch: abi.DeviceDispatch, command: abi.CommandBuffer, bounds: mesh_mod.DeviceBounds) void {
    const viewport: abi.Viewport = .{ .x = 0, .y = 0, .width = @floatFromInt(bounds.width), .height = @floatFromInt(bounds.height) };
    const scissor: abi.Rect2D = .{ .extent = .{ .width = bounds.width, .height = bounds.height } };
    dispatch.cmd_set_viewport(command, 0, 1, @ptrCast(&viewport));
    dispatch.cmd_set_scissor(command, 0, 1, @ptrCast(&scissor));
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
