const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const handles = @import("../../core/handle.zig");
const render = @import("../../render/api.zig");
const linux_surface = @import("../../platform/linux/surface.zig");
const sys = @import("../../platform/linux/sys.zig");
const abi = @import("abi.zig");
const device_mod = @import("device.zig");

pub const Allocation = struct {
    memory: abi.DeviceMemory = 0,
    size: abi.DeviceSize = 0,
    mapped: ?[*]u8 = null,
    coherent: bool = true,

    pub fn deinit(self: *Allocation, context: *device_mod.Context) void {
        if (self.memory == 0) return;
        if (self.mapped != null) context.device_dispatch.unmap_memory(context.device, self.memory);
        context.device_dispatch.free_memory(context.device, self.memory, null);
        self.* = .{};
    }

    pub fn flush(self: Allocation, context: *device_mod.Context) Error!void {
        if (self.coherent or self.memory == 0) return;
        const range: abi.MappedMemoryRange = .{ .memory = self.memory };
        try device_mod.check(context.device_dispatch.flush_mapped_memory_ranges(context.device, 1, @ptrCast(&range)));
    }

    pub fn invalidate(self: Allocation, context: *device_mod.Context) Error!void {
        if (self.coherent or self.memory == 0) return;
        const range: abi.MappedMemoryRange = .{ .memory = self.memory };
        try device_mod.check(context.device_dispatch.invalidate_mapped_memory_ranges(context.device, 1, @ptrCast(&range)));
    }
};

pub const Buffer = struct {
    handle: abi.Buffer = 0,
    allocation: Allocation = .{},
    capacity: usize = 0,
    usage: abi.Flags = 0,

    pub fn create(
        context: *device_mod.Context,
        size: usize,
        usage: abi.Flags,
        mapped: bool,
    ) Error!Buffer {
        if (size == 0) return error.InvalidConfiguration;
        const info: abi.BufferCreateInfo = .{ .size = size, .usage = usage };
        var handle: abi.Buffer = 0;
        try device_mod.check(context.device_dispatch.create_buffer(context.device, &info, null, &handle));
        errdefer context.device_dispatch.destroy_buffer(context.device, handle, null);
        var requirements: abi.MemoryRequirements = undefined;
        context.device_dispatch.get_buffer_memory_requirements(context.device, handle, &requirements);
        const required = if (mapped) abi.memory_property_host_visible_bit else abi.memory_property_device_local_bit;
        const preferred = if (mapped)
            abi.memory_property_host_coherent_bit | abi.memory_property_host_cached_bit
        else
            abi.memory_property_device_local_bit;
        const selected = try selectMemoryType(context, requirements.memory_type_bits, required, preferred);
        const allocate_info: abi.MemoryAllocateInfo = .{
            .allocation_size = requirements.size,
            .memory_type_index = selected.index,
        };
        var memory: abi.DeviceMemory = 0;
        try device_mod.check(context.device_dispatch.allocate_memory(context.device, &allocate_info, null, &memory));
        errdefer context.device_dispatch.free_memory(context.device, memory, null);
        try device_mod.check(context.device_dispatch.bind_buffer_memory(context.device, handle, memory, 0));
        var pointer: ?*anyopaque = null;
        if (mapped) try device_mod.check(context.device_dispatch.map_memory(context.device, memory, 0, requirements.size, 0, &pointer));
        return .{
            .handle = handle,
            .allocation = .{
                .memory = memory,
                .size = requirements.size,
                .mapped = if (pointer) |value| @ptrCast(value) else null,
                .coherent = selected.flags & abi.memory_property_host_coherent_bit != 0,
            },
            .capacity = size,
            .usage = usage,
        };
    }

    pub fn ensureMappedCapacity(self: *Buffer, context: *device_mod.Context, required: usize, usage: abi.Flags) Error!void {
        if (required <= self.capacity and self.handle != 0 and self.allocation.mapped != null) return;
        var capacity: usize = @max(@as(usize, 64 * 1024), self.capacity);
        while (capacity < required) capacity = std.math.mul(usize, capacity, 2) catch return error.BudgetExceeded;
        const replacement = try Buffer.create(context, capacity, usage, true);
        self.deinit(context);
        self.* = replacement;
    }

    pub fn write(self: *Buffer, context: *device_mod.Context, offset: usize, bytes: []const u8) Error!void {
        const end = std.math.add(usize, offset, bytes.len) catch return error.BudgetExceeded;
        if (end > self.capacity) return error.BudgetExceeded;
        const mapped = self.allocation.mapped orelse return error.InvalidConfiguration;
        @memcpy(mapped[offset..end], bytes);
        try self.allocation.flush(context);
    }

    pub fn deinit(self: *Buffer, context: *device_mod.Context) void {
        if (self.handle != 0) context.device_dispatch.destroy_buffer(context.device, self.handle, null);
        self.allocation.deinit(context);
        self.* = .{};
    }
};

pub const Image = struct {
    handle: abi.Image = 0,
    view: abi.ImageView = 0,
    allocation: Allocation = .{},
    width: u32 = 0,
    height: u32 = 0,
    format: abi.Format = 0,
    layout: i32 = abi.image_layout_undefined,

    pub fn create(
        context: *device_mod.Context,
        width: u32,
        height: u32,
        format: abi.Format,
        usage: abi.Flags,
    ) Error!Image {
        if (width == 0 or height == 0) return error.InvalidConfiguration;
        const info: abi.ImageCreateInfo = .{
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .tiling = abi.image_tiling_optimal,
            .usage = usage,
        };
        var image: abi.Image = 0;
        try device_mod.check(context.device_dispatch.create_image(context.device, &info, null, &image));
        errdefer context.device_dispatch.destroy_image(context.device, image, null);
        var requirements: abi.MemoryRequirements = undefined;
        context.device_dispatch.get_image_memory_requirements(context.device, image, &requirements);
        const memory_type = try context.findMemoryType(requirements.memory_type_bits, abi.memory_property_device_local_bit, abi.memory_property_device_local_bit);
        const allocate_info: abi.MemoryAllocateInfo = .{
            .allocation_size = requirements.size,
            .memory_type_index = memory_type,
        };
        var memory: abi.DeviceMemory = 0;
        try device_mod.check(context.device_dispatch.allocate_memory(context.device, &allocate_info, null, &memory));
        errdefer context.device_dispatch.free_memory(context.device, memory, null);
        try device_mod.check(context.device_dispatch.bind_image_memory(context.device, image, memory, 0));
        const view = try createView(context, image, format);
        return .{
            .handle = image,
            .view = view,
            .allocation = .{ .memory = memory, .size = requirements.size },
            .width = width,
            .height = height,
            .format = format,
        };
    }

    pub fn deinit(self: *Image, context: *device_mod.Context) void {
        if (self.view != 0) context.device_dispatch.destroy_image_view(context.device, self.view, null);
        if (self.handle != 0) context.device_dispatch.destroy_image(context.device, self.handle, null);
        self.allocation.deinit(context);
        self.* = .{};
    }
};

pub const Texture = struct {
    id: handles.TextureId,
    image: Image,
    descriptor: abi.DescriptorSet,
    description: render.TextureDescriptor,

    pub fn deinit(self: *Texture, context: *device_mod.Context, descriptor_pool: abi.DescriptorPool) void {
        if (self.descriptor != 0) {
            const descriptors = [1]abi.DescriptorSet{self.descriptor};
            _ = context.device_dispatch.free_descriptor_sets(context.device, descriptor_pool, 1, &descriptors);
        }
        self.image.deinit(context);
        self.* = undefined;
    }
};

pub const ExportImage = struct {
    pub const SubmissionState = struct {
        acquire_value: u64,
        release_value: u64,
    };

    image: Image,
    buffer: linux_surface.BufferHandle,
    semaphore: abi.Semaphore,
    timeline: linux_surface.TimelineHandle,
    fence: abi.Fence,
    acquire_value: u64 = 0,
    release_value: u64 = 0,
    submitted_epoch: render.SubmissionEpoch = 0,

    pub fn create(context: *device_mod.Context, provider: linux_surface.Provider, width: u32, height: u32) Error!ExportImage {
        const format = context.export_format;
        var modifier_info: abi.ImageDrmFormatModifierListCreateInfo = .{
            .modifier_count = 1,
            .modifiers = @ptrCast(&format.modifier),
        };
        var external_info: abi.ExternalMemoryImageCreateInfo = .{
            .next = &modifier_info,
            .handle_types = abi.external_memory_handle_type_dma_buf_bit_ext,
        };
        const image_info: abi.ImageCreateInfo = .{
            .next = &external_info,
            .format = format.vulkan,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .tiling = abi.image_tiling_drm_format_modifier_ext,
            .usage = abi.image_usage_color_attachment_bit | abi.image_usage_transfer_src_bit | abi.image_usage_transfer_dst_bit,
        };
        var image_handle: abi.Image = 0;
        try device_mod.check(context.device_dispatch.create_image(context.device, &image_info, null, &image_handle));
        errdefer context.device_dispatch.destroy_image(context.device, image_handle, null);

        var dedicated_requirements: abi.MemoryDedicatedRequirements = .{};
        const requirements_info: abi.ImageMemoryRequirementsInfo2 = .{ .image = image_handle };
        var requirements: abi.MemoryRequirements2 = .{ .next = &dedicated_requirements };
        context.device_dispatch.get_image_memory_requirements_2(context.device, &requirements_info, &requirements);
        const memory_type = try context.findMemoryType(
            requirements.memory_requirements.memory_type_bits,
            abi.memory_property_device_local_bit,
            abi.memory_property_device_local_bit,
        );
        var export_allocation: abi.ExportMemoryAllocateInfo = .{
            .handle_types = abi.external_memory_handle_type_dma_buf_bit_ext,
        };
        const dedicated: abi.MemoryDedicatedAllocateInfo = .{
            .next = &export_allocation,
            .image = image_handle,
        };
        const allocation_info: abi.MemoryAllocateInfo = .{
            .next = &dedicated,
            .allocation_size = requirements.memory_requirements.size,
            .memory_type_index = memory_type,
        };
        var memory: abi.DeviceMemory = 0;
        try device_mod.check(context.device_dispatch.allocate_memory(context.device, &allocation_info, null, &memory));
        errdefer context.device_dispatch.free_memory(context.device, memory, null);
        try device_mod.check(context.device_dispatch.bind_image_memory(context.device, image_handle, memory, 0));
        const view = try createView(context, image_handle, format.vulkan);
        errdefer context.device_dispatch.destroy_image_view(context.device, view, null);

        var modifier_properties: abi.ImageDrmFormatModifierProperties = .{};
        try device_mod.check(context.device_dispatch.get_image_drm_format_modifier_properties(context.device, image_handle, &modifier_properties));
        if (modifier_properties.modifier != format.modifier) return error.PlatformFailure;
        const subresource: abi.ImageSubresource = .{};
        var layout: abi.SubresourceLayout = undefined;
        context.device_dispatch.get_image_subresource_layout(context.device, image_handle, &subresource, &layout);
        const stride = std.math.cast(u32, layout.row_pitch) orelse return error.BudgetExceeded;
        const offset = std.math.cast(u32, layout.offset) orelse return error.BudgetExceeded;

        var dma_fd: i32 = -1;
        const memory_fd_info: abi.MemoryGetFdInfo = .{
            .memory = memory,
            .handle_type = abi.external_memory_handle_type_dma_buf_bit_ext,
        };
        try device_mod.check(context.device_dispatch.get_memory_fd(context.device, &memory_fd_info, &dma_fd));
        if (dma_fd < 0) return error.PlatformFailure;
        defer sys.close(dma_fd);
        const planes = [1]linux_surface.DmabufPlane{.{
            .descriptor = dma_fd,
            .offset = offset,
            .stride = stride,
            .modifier = modifier_properties.modifier,
        }};
        const buffer = try provider.importBuffer(.{
            .width = width,
            .height = height,
            .fourcc = format.drm,
            .planes = &planes,
        });
        errdefer provider.destroyBuffer(buffer);

        var semaphore: abi.Semaphore = 0;
        var timeline: linux_surface.TimelineHandle = 0;
        if (provider.explicitSync()) {
            var export_semaphore: abi.ExportSemaphoreCreateInfo = .{
                .handle_types = abi.external_semaphore_handle_type_opaque_fd_bit,
            };
            const timeline_type: abi.SemaphoreTypeCreateInfo = .{
                .next = &export_semaphore,
                .initial_value = 0,
            };
            const semaphore_info: abi.SemaphoreCreateInfo = .{ .next = &timeline_type };
            try device_mod.check(context.device_dispatch.create_semaphore(context.device, &semaphore_info, null, &semaphore));
            errdefer if (semaphore != 0) context.device_dispatch.destroy_semaphore(context.device, semaphore, null);
            var semaphore_fd: i32 = -1;
            const semaphore_fd_info: abi.SemaphoreGetFdInfo = .{
                .semaphore = semaphore,
                .handle_type = abi.external_semaphore_handle_type_opaque_fd_bit,
            };
            try device_mod.check(context.device_dispatch.get_semaphore_fd(context.device, &semaphore_fd_info, &semaphore_fd));
            if (semaphore_fd < 0) return error.PlatformFailure;
            defer sys.close(semaphore_fd);
            timeline = try provider.importTimeline(semaphore_fd);
            errdefer if (timeline != 0) provider.destroyTimeline(timeline);
        }

        var fence: abi.Fence = 0;
        const fence_info: abi.FenceCreateInfo = .{ .flags = abi.fence_create_signaled_bit };
        try device_mod.check(context.device_dispatch.create_fence(context.device, &fence_info, null, &fence));
        return .{
            .image = .{
                .handle = image_handle,
                .view = view,
                .allocation = .{ .memory = memory, .size = requirements.memory_requirements.size },
                .width = width,
                .height = height,
                .format = format.vulkan,
            },
            .buffer = buffer,
            .semaphore = semaphore,
            .timeline = timeline,
            .fence = fence,
        };
    }

    pub fn ready(self: *const ExportImage, context: *device_mod.Context, provider: linux_surface.Provider) bool {
        if (self.fence == 0 or !provider.bufferReleased(self.buffer)) return false;
        return context.device_dispatch.get_fence_status(context.device, self.fence) == abi.success;
    }

    pub fn wait(self: *const ExportImage, context: *device_mod.Context) Error!void {
        if (self.fence == 0) return error.DeviceLost;
        const fences = [1]abi.Fence{self.fence};
        try device_mod.check(context.device_dispatch.wait_for_fences(context.device, 1, &fences, abi.vk_true, std.math.maxInt(u64)));
    }

    pub fn beginSubmission(self: *ExportImage, context: *device_mod.Context) Error!SubmissionState {
        if (self.fence == 0) return error.DeviceLost;
        const previous: SubmissionState = .{
            .acquire_value = self.acquire_value,
            .release_value = self.release_value,
        };
        const next_acquire = if (self.semaphore != 0)
            std.math.add(u64, self.release_value, 1) catch return error.BudgetExceeded
        else
            self.acquire_value;
        const next_release = if (self.semaphore != 0)
            std.math.add(u64, next_acquire, 1) catch return error.BudgetExceeded
        else
            self.release_value;
        const fences = [1]abi.Fence{self.fence};
        try device_mod.check(context.device_dispatch.reset_fences(context.device, 1, &fences));
        self.acquire_value = next_acquire;
        self.release_value = next_release;
        return previous;
    }

    /// A failed queue submission leaves the reset fence permanently
    /// unsignalled. Replace it with a host-signalled fence before the frame is
    /// returned to the reusable surface pool.
    pub fn abortSubmission(self: *ExportImage, context: *device_mod.Context, previous: SubmissionState) Error!void {
        self.acquire_value = previous.acquire_value;
        self.release_value = previous.release_value;
        const abandoned = self.fence;
        self.fence = 0;
        if (abandoned != 0) context.device_dispatch.destroy_fence(context.device, abandoned, null);
        const fence_info: abi.FenceCreateInfo = .{ .flags = abi.fence_create_signaled_bit };
        try device_mod.check(context.device_dispatch.create_fence(context.device, &fence_info, null, &self.fence));
    }

    pub fn deinit(self: *ExportImage, context: *device_mod.Context, provider: linux_surface.Provider) void {
        if (self.fence != 0) self.wait(context) catch {};
        if (self.timeline != 0) provider.destroyTimeline(self.timeline);
        if (self.buffer != 0) provider.destroyBuffer(self.buffer);
        if (self.fence != 0) context.device_dispatch.destroy_fence(context.device, self.fence, null);
        if (self.semaphore != 0) context.device_dispatch.destroy_semaphore(context.device, self.semaphore, null);
        self.image.deinit(context);
        self.* = undefined;
    }
};

pub fn pixelFormat(format: render.PixelFormat) abi.Format {
    return switch (format) {
        .a8 => abi.format_r8_unorm,
        .rgba8 => abi.format_r8g8b8a8_unorm,
        .rgba8_srgb => abi.format_r8g8b8a8_srgb,
        .bgra8 => abi.format_b8g8r8a8_unorm,
        .bgra8_srgb => abi.format_b8g8r8a8_srgb,
        .rgba16_float => abi.format_r16g16b16a16_sfloat,
    };
}

pub fn createDescriptorPool(context: *device_mod.Context, maximum_sets: u32) Error!abi.DescriptorPool {
    const descriptor_count = std.math.mul(u32, maximum_sets, 2) catch return error.BudgetExceeded;
    const pool_size: abi.DescriptorPoolSize = .{
        .descriptor_type = abi.descriptor_type_combined_image_sampler,
        .descriptor_count = descriptor_count,
    };
    const info: abi.DescriptorPoolCreateInfo = .{
        .flags = abi.descriptor_pool_create_free_descriptor_set_bit,
        .max_sets = maximum_sets,
        .pool_size_count = 1,
        .pool_sizes = @ptrCast(&pool_size),
    };
    var pool: abi.DescriptorPool = 0;
    try device_mod.check(context.device_dispatch.create_descriptor_pool(context.device, &info, null, &pool));
    return pool;
}

pub fn allocateImageDescriptor(
    context: *device_mod.Context,
    pool: abi.DescriptorPool,
    layout: abi.DescriptorSetLayout,
    sampler: abi.Sampler,
    image_view: abi.ImageView,
) Error!abi.DescriptorSet {
    return allocateImageDescriptorWithLayout(
        context,
        pool,
        layout,
        sampler,
        image_view,
        abi.image_layout_shader_read_only_optimal,
    );
}

pub fn allocateImageDescriptorWithLayout(
    context: *device_mod.Context,
    pool: abi.DescriptorPool,
    layout: abi.DescriptorSetLayout,
    sampler: abi.Sampler,
    image_view: abi.ImageView,
    image_layout: i32,
) Error!abi.DescriptorSet {
    const info: abi.DescriptorSetAllocateInfo = .{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .set_layouts = @ptrCast(&layout),
    };
    var descriptor: abi.DescriptorSet = 0;
    try device_mod.check(context.device_dispatch.allocate_descriptor_sets(context.device, &info, @ptrCast(&descriptor)));
    const image_info: abi.DescriptorImageInfo = .{
        .sampler = sampler,
        .image_view = image_view,
        .image_layout = image_layout,
    };
    const write: abi.WriteDescriptorSet = .{
        .destination_set = descriptor,
        .destination_binding = 0,
        .descriptor_type = abi.descriptor_type_combined_image_sampler,
        .image_info = @ptrCast(&image_info),
    };
    context.device_dispatch.update_descriptor_sets(context.device, 1, @ptrCast(&write), 0, null);
    return descriptor;
}

pub fn allocateImagePairDescriptor(
    context: *device_mod.Context,
    pool: abi.DescriptorPool,
    layout: abi.DescriptorSetLayout,
    sampler: abi.Sampler,
    first_view: abi.ImageView,
    first_layout: i32,
    second_view: abi.ImageView,
    second_layout: i32,
) Error!abi.DescriptorSet {
    const info: abi.DescriptorSetAllocateInfo = .{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .set_layouts = @ptrCast(&layout),
    };
    var descriptor: abi.DescriptorSet = 0;
    try device_mod.check(context.device_dispatch.allocate_descriptor_sets(context.device, &info, @ptrCast(&descriptor)));
    const images = [_]abi.DescriptorImageInfo{
        .{ .sampler = sampler, .image_view = first_view, .image_layout = first_layout },
        .{ .sampler = sampler, .image_view = second_view, .image_layout = second_layout },
    };
    const writes = [_]abi.WriteDescriptorSet{
        .{
            .destination_set = descriptor,
            .destination_binding = 0,
            .descriptor_type = abi.descriptor_type_combined_image_sampler,
            .image_info = @ptrCast(&images[0]),
        },
        .{
            .destination_set = descriptor,
            .destination_binding = 1,
            .descriptor_type = abi.descriptor_type_combined_image_sampler,
            .image_info = @ptrCast(&images[1]),
        },
    };
    context.device_dispatch.update_descriptor_sets(context.device, writes.len, &writes, 0, null);
    return descriptor;
}

pub fn transition(
    context: *device_mod.Context,
    command: abi.CommandBuffer,
    image: *Image,
    new_layout: i32,
    source_stage: abi.Flags64,
    source_access: abi.Flags64,
    destination_stage: abi.Flags64,
    destination_access: abi.Flags64,
) void {
    const barrier: abi.ImageMemoryBarrier2 = .{
        .source_stage_mask = source_stage,
        .source_access_mask = source_access,
        .destination_stage_mask = destination_stage,
        .destination_access_mask = destination_access,
        .old_layout = image.layout,
        .new_layout = new_layout,
        .image = image.handle,
    };
    const dependency: abi.DependencyInfo = .{
        .image_memory_barrier_count = 1,
        .image_memory_barriers = @ptrCast(&barrier),
    };
    context.device_dispatch.cmd_pipeline_barrier_2(command, &dependency);
    image.layout = new_layout;
}

const SelectedMemory = struct { index: u32, flags: abi.Flags };

fn selectMemoryType(context: *const device_mod.Context, mask: u32, required: abi.Flags, preferred: abi.Flags) Error!SelectedMemory {
    var fallback: ?SelectedMemory = null;
    var index: u32 = 0;
    while (index < context.memory.memory_type_count) : (index += 1) {
        if (mask & (@as(u32, 1) << @intCast(index)) == 0) continue;
        const flags = context.memory.memory_types[index].property_flags;
        if (flags & required != required) continue;
        const value: SelectedMemory = .{ .index = index, .flags = flags };
        if (flags & preferred == preferred) return value;
        if (fallback == null) fallback = value;
    }
    return fallback orelse error.MissingCapability;
}

fn createView(context: *device_mod.Context, image: abi.Image, format: abi.Format) Error!abi.ImageView {
    const info: abi.ImageViewCreateInfo = .{ .image = image, .format = format };
    var view: abi.ImageView = 0;
    try device_mod.check(context.device_dispatch.create_image_view(context.device, &info, null, &view));
    return view;
}
