const std = @import("std");
const config = @import("../../config.zig");
const Error = @import("../../core/error.zig").Error;
const linux_surface = @import("../../platform/linux/surface.zig");
const abi = @import("abi.zig");

pub const drm_format_argb8888 = fourcc('A', 'R', '2', '4');
pub const drm_format_abgr8888 = fourcc('A', 'B', '2', '4');

pub const ExportFormat = struct {
    vulkan: abi.Format,
    drm: u32,
    modifier: u64,
    scanout: bool,
};

const Candidate = struct {
    physical: abi.PhysicalDevice,
    properties: abi.PhysicalDeviceProperties,
    queue_family: u32,
    export_format: ExportFormat,
    score: i64,
    ordinal: u32,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    global: abi.GlobalDispatch,
    instance_dispatch: abi.InstanceDispatch,
    device_dispatch: abi.DeviceDispatch,
    instance: abi.Instance,
    physical_device: abi.PhysicalDevice,
    device: abi.Device,
    queue: abi.Queue,
    queue_family: u32,
    memory: abi.PhysicalDeviceMemoryProperties,
    properties: abi.PhysicalDeviceProperties,
    export_format: ExportFormat,
    command_pool: abi.CommandPool,

    pub fn create(
        allocator: std.mem.Allocator,
        policy: config.GpuPolicy,
        compositor_formats: []const linux_surface.Format,
    ) Error!*Context {
        var global = abi.GlobalDispatch.load() catch return error.NoGpuDevice;
        errdefer global.deinit();
        var loader_version: u32 = 0;
        try check(global.enumerate_instance_version(&loader_version));
        if (loader_version < abi.api_version_1_3) return error.MissingCapability;

        var enabled_layers: [1][*:0]const u8 = undefined;
        var enabled_layer_count: u32 = 0;
        if (policy.validation) {
            const validation: [:0]const u8 = "VK_LAYER_KHRONOS_validation";
            if (!try instanceLayerAvailable(allocator, global, validation)) return error.MissingCapability;
            enabled_layers[0] = validation.ptr;
            enabled_layer_count = 1;
        }

        const application_info: abi.ApplicationInfo = .{
            .application_name = "ZigUI",
            .engine_name = "ZigUI",
        };
        const instance_info: abi.InstanceCreateInfo = .{
            .application_info = &application_info,
            .enabled_layer_count = enabled_layer_count,
            .enabled_layer_names = if (enabled_layer_count == 0) null else &enabled_layers,
        };
        var instance: abi.Instance = null;
        try check(global.create_instance(&instance_info, null, &instance));
        const destroy_instance = abi.loadProc(
            @FieldType(abi.InstanceDispatch, "destroy_instance"),
            global.get_instance_proc_addr(instance, "vkDestroyInstance"),
        ) catch return error.MissingCapability;
        errdefer destroy_instance(instance, null);
        const instance_dispatch = abi.InstanceDispatch.load(global, instance) catch return error.MissingCapability;
        const candidate = try selectAdapter(allocator, instance_dispatch, instance, policy, compositor_formats);

        var timeline_features: abi.PhysicalDeviceTimelineSemaphoreFeatures = .{
            .timeline_semaphore = abi.vk_true,
        };
        var synchronization_features: abi.PhysicalDeviceSynchronization2Features = .{
            .next = &timeline_features,
            .synchronization_2 = abi.vk_true,
        };
        var rendering_features: abi.PhysicalDeviceDynamicRenderingFeatures = .{
            .next = &synchronization_features,
            .dynamic_rendering = abi.vk_true,
        };
        const priority: f32 = 1;
        const queue_info: abi.DeviceQueueCreateInfo = .{
            .queue_family_index = candidate.queue_family,
            .queue_priorities = @ptrCast(&priority),
        };
        const extension_names = [_][*:0]const u8{
            abi.extension.external_memory_fd.ptr,
            abi.extension.external_semaphore_fd.ptr,
            abi.extension.image_drm_format_modifier.ptr,
        };
        const device_info: abi.DeviceCreateInfo = .{
            .next = &rendering_features,
            .queue_create_info_count = 1,
            .queue_create_infos = @ptrCast(&queue_info),
            .enabled_extension_count = @intCast(extension_names.len),
            .enabled_extension_names = &extension_names,
        };
        var device: abi.Device = null;
        try check(instance_dispatch.create_device(candidate.physical, &device_info, null, &device));
        const destroy_device = abi.loadProc(
            @FieldType(abi.DeviceDispatch, "destroy_device"),
            instance_dispatch.get_device_proc_addr(device, "vkDestroyDevice"),
        ) catch return error.MissingCapability;
        errdefer destroy_device(device, null);
        const device_dispatch = abi.DeviceDispatch.load(instance_dispatch, device) catch return error.MissingCapability;

        var queue: abi.Queue = null;
        device_dispatch.get_device_queue(device, candidate.queue_family, 0, &queue);
        if (queue == null) return error.NoGpuDevice;

        var memory: abi.PhysicalDeviceMemoryProperties = undefined;
        instance_dispatch.get_physical_device_memory_properties(candidate.physical, &memory);
        if (memory.memory_type_count == 0 or memory.memory_type_count > memory.memory_types.len) return error.NoGpuDevice;

        var command_pool: abi.CommandPool = 0;
        const pool_info: abi.CommandPoolCreateInfo = .{ .queue_family_index = candidate.queue_family };
        try check(device_dispatch.create_command_pool(device, &pool_info, null, &command_pool));
        errdefer device_dispatch.destroy_command_pool(device, command_pool, null);

        const self = try allocator.create(Context);
        self.* = .{
            .allocator = allocator,
            .global = global,
            .instance_dispatch = instance_dispatch,
            .device_dispatch = device_dispatch,
            .instance = instance,
            .physical_device = candidate.physical,
            .device = device,
            .queue = queue,
            .queue_family = candidate.queue_family,
            .memory = memory,
            .properties = candidate.properties,
            .export_format = candidate.export_format,
            .command_pool = command_pool,
        };
        return self;
    }

    pub fn deinit(self: *Context) void {
        _ = self.device_dispatch.device_wait_idle(self.device);
        self.device_dispatch.destroy_command_pool(self.device, self.command_pool, null);
        self.device_dispatch.destroy_device(self.device, null);
        self.instance_dispatch.destroy_instance(self.instance, null);
        self.global.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn findMemoryType(self: *const Context, mask: u32, required: abi.Flags, preferred: abi.Flags) Error!u32 {
        var fallback: ?u32 = null;
        var index: u32 = 0;
        while (index < self.memory.memory_type_count) : (index += 1) {
            if (mask & (@as(u32, 1) << @intCast(index)) == 0) continue;
            const flags = self.memory.memory_types[index].property_flags;
            if (flags & required != required) continue;
            if (flags & preferred == preferred) return index;
            if (fallback == null) fallback = index;
        }
        return fallback orelse error.MissingCapability;
    }

    pub fn allocateCommandBuffer(self: *const Context) Error!abi.CommandBuffer {
        var command: [1]abi.CommandBuffer = .{null};
        const info: abi.CommandBufferAllocateInfo = .{
            .command_pool = self.command_pool,
            .command_buffer_count = 1,
        };
        try check(self.device_dispatch.allocate_command_buffers(self.device, &info, &command));
        return command[0] orelse error.NoGpuDevice;
    }

    pub fn freeCommandBuffer(self: *const Context, command: abi.CommandBuffer) void {
        const commands = [1]abi.CommandBuffer{command};
        self.device_dispatch.free_command_buffers(self.device, self.command_pool, 1, &commands);
    }
};

fn selectAdapter(
    allocator: std.mem.Allocator,
    dispatch: abi.InstanceDispatch,
    instance: abi.Instance,
    policy: config.GpuPolicy,
    compositor_formats: []const linux_surface.Format,
) Error!Candidate {
    var count: u32 = 0;
    try check(dispatch.enumerate_physical_devices(instance, &count, null));
    if (count == 0 or count > 256) return error.NoGpuDevice;
    const devices = try allocator.alloc(abi.PhysicalDevice, count);
    defer allocator.free(devices);
    var written = count;
    const result = dispatch.enumerate_physical_devices(instance, &written, devices.ptr);
    if (result != abi.success and result != abi.incomplete) try check(result);

    var best: ?Candidate = null;
    for (devices[0..written], 0..) |physical, ordinal_usize| {
        const ordinal: u32 = @intCast(ordinal_usize);
        if (policy.preferred_adapter) |preferred| if (preferred != ordinal) continue;
        const candidate = inspectAdapter(allocator, dispatch, physical, ordinal, policy, compositor_formats) catch continue;
        if (best == null or candidate.score > best.?.score) best = candidate;
    }
    return best orelse error.NoGpuDevice;
}

fn inspectAdapter(
    allocator: std.mem.Allocator,
    dispatch: abi.InstanceDispatch,
    physical: abi.PhysicalDevice,
    ordinal: u32,
    policy: config.GpuPolicy,
    compositor_formats: []const linux_surface.Format,
) Error!Candidate {
    var properties: abi.PhysicalDeviceProperties = undefined;
    dispatch.get_physical_device_properties(physical, &properties);
    if (properties.header.api_version < abi.api_version_1_3) return error.MissingCapability;
    if (properties.header.device_type == abi.physical_device_type_cpu and policy.software_fallback == .forbidden)
        return error.NoGpuDevice;

    inline for (.{ abi.extension.external_memory_fd, abi.extension.external_semaphore_fd, abi.extension.image_drm_format_modifier }) |required|
        if (!try deviceExtensionAvailable(allocator, dispatch, physical, required)) return error.MissingCapability;

    var timeline: abi.PhysicalDeviceTimelineSemaphoreFeatures = .{};
    var synchronization: abi.PhysicalDeviceSynchronization2Features = .{ .next = &timeline };
    var dynamic_rendering: abi.PhysicalDeviceDynamicRenderingFeatures = .{ .next = &synchronization };
    var features: abi.PhysicalDeviceFeatures2 = .{ .next = &dynamic_rendering };
    dispatch.get_physical_device_features_2(physical, &features);
    if (timeline.timeline_semaphore == 0 or synchronization.synchronization_2 == 0 or dynamic_rendering.dynamic_rendering == 0)
        return error.MissingCapability;

    var semaphore_properties: abi.ExternalSemaphoreProperties = .{};
    const semaphore_info: abi.PhysicalDeviceExternalSemaphoreInfo = .{
        .handle_type = abi.external_semaphore_handle_type_opaque_fd_bit,
    };
    dispatch.get_physical_device_external_semaphore_properties(physical, &semaphore_info, &semaphore_properties);
    if (semaphore_properties.external_semaphore_features & abi.external_semaphore_feature_exportable_bit == 0)
        return error.MissingCapability;

    const queue_family = try graphicsQueueFamily(allocator, dispatch, physical);
    const export_format = try selectExportFormat(allocator, dispatch, physical, compositor_formats);

    var score: i64 = switch (properties.header.device_type) {
        abi.physical_device_type_discrete_gpu => if (policy.power_preference == .high_performance) 10_000 else 2_000,
        abi.physical_device_type_integrated_gpu => if (policy.power_preference == .low_power) 10_000 else 5_000,
        abi.physical_device_type_virtual_gpu => 1_000,
        abi.physical_device_type_cpu => -10_000,
        else => 0,
    };
    if (export_format.scanout) score += 500;
    score -= @as(i64, @intCast(ordinal));
    return .{
        .physical = physical,
        .properties = properties,
        .queue_family = queue_family,
        .export_format = export_format,
        .score = score,
        .ordinal = ordinal,
    };
}

fn graphicsQueueFamily(allocator: std.mem.Allocator, dispatch: abi.InstanceDispatch, physical: abi.PhysicalDevice) Error!u32 {
    var count: u32 = 0;
    dispatch.get_physical_device_queue_family_properties(physical, &count, null);
    if (count == 0 or count > 256) return error.NoGpuDevice;
    const values = try allocator.alloc(abi.QueueFamilyProperties, count);
    defer allocator.free(values);
    dispatch.get_physical_device_queue_family_properties(physical, &count, values.ptr);
    for (values[0..count], 0..) |value, index| if (value.queue_count != 0 and value.queue_flags & abi.queue_graphics_bit != 0)
        return @intCast(index);
    return error.NoGpuDevice;
}

fn selectExportFormat(
    allocator: std.mem.Allocator,
    dispatch: abi.InstanceDispatch,
    physical: abi.PhysicalDevice,
    compositor_formats: []const linux_surface.Format,
) Error!ExportFormat {
    const candidates = [_]struct { vulkan: abi.Format, drm: u32 }{
        // DRM fourcc describes byte layout, not transfer function. Rendering
        // through the sRGB Vulkan view stores encoded bytes for the compositor
        // while keeping shader evaluation and blending in linear light.
        .{ .vulkan = abi.format_b8g8r8a8_srgb, .drm = drm_format_argb8888 },
        .{ .vulkan = abi.format_r8g8b8a8_srgb, .drm = drm_format_abgr8888 },
    };
    var best: ?ExportFormat = null;
    for (candidates) |candidate| {
        var list: abi.DrmFormatModifierPropertiesList = .{};
        var properties: abi.FormatProperties2 = .{ .next = &list };
        dispatch.get_physical_device_format_properties_2(physical, candidate.vulkan, &properties);
        if (list.modifier_count == 0 or list.modifier_count > 16_384) continue;
        const modifiers = try allocator.alloc(abi.DrmFormatModifierProperties, list.modifier_count);
        defer allocator.free(modifiers);
        list.modifiers = modifiers.ptr;
        dispatch.get_physical_device_format_properties_2(physical, candidate.vulkan, &properties);
        for (modifiers[0..list.modifier_count]) |modifier| {
            if (modifier.plane_count != 1) continue;
            const required = abi.format_feature_color_attachment_bit;
            if (modifier.tiling_features & required != required) continue;
            const compositor = findCompositorFormat(compositor_formats, candidate.drm, modifier.modifier) orelse continue;
            const value: ExportFormat = .{
                .vulkan = candidate.vulkan,
                .drm = candidate.drm,
                .modifier = modifier.modifier,
                .scanout = compositor.scanout,
            };
            if (best == null or value.scanout and !best.?.scanout) best = value;
        }
    }
    return best orelse error.MissingCapability;
}

fn findCompositorFormat(formats: []const linux_surface.Format, fourcc_value: u32, modifier: u64) ?linux_surface.Format {
    for (formats) |value| if (value.fourcc == fourcc_value and value.modifier == modifier) return value;
    return null;
}

fn instanceLayerAvailable(
    allocator: std.mem.Allocator,
    global: abi.GlobalDispatch,
    name: []const u8,
) Error!bool {
    var count: u32 = 0;
    try check(global.enumerate_instance_layer_properties(&count, null));
    if (count == 0) return false;
    if (count > 16_384) return error.PlatformFailure;
    const values = try allocator.alloc(abi.LayerProperties, count);
    defer allocator.free(values);
    const result = global.enumerate_instance_layer_properties(&count, values.ptr);
    if (result != abi.success and result != abi.incomplete) try check(result);
    for (values[0..count]) |*value| if (std.mem.eql(u8, name, std.mem.sliceTo(&value.name, 0))) return true;
    return false;
}

fn deviceExtensionAvailable(
    allocator: std.mem.Allocator,
    dispatch: abi.InstanceDispatch,
    physical: abi.PhysicalDevice,
    name: []const u8,
) Error!bool {
    var count: u32 = 0;
    try check(dispatch.enumerate_device_extension_properties(physical, null, &count, null));
    if (count == 0) return false;
    if (count > 16_384) return error.PlatformFailure;
    const values = try allocator.alloc(abi.ExtensionProperties, count);
    defer allocator.free(values);
    const result = dispatch.enumerate_device_extension_properties(physical, null, &count, values.ptr);
    if (result != abi.success and result != abi.incomplete) try check(result);
    for (values[0..count]) |*value| if (std.mem.eql(u8, name, value.slice())) return true;
    return false;
}

pub fn check(result: abi.Result) Error!void {
    return switch (result) {
        abi.success => {},
        abi.error_out_of_host_memory => error.OutOfMemory,
        abi.error_out_of_device_memory, abi.error_too_many_objects, abi.error_fragmented_pool => error.BudgetExceeded,
        abi.error_device_lost => error.DeviceLost,
        abi.error_extension_not_present, abi.error_feature_not_present, abi.error_format_not_supported => error.MissingCapability,
        abi.error_incompatible_driver, abi.error_initialization_failed => error.NoGpuDevice,
        abi.error_memory_map_failed => error.PlatformFailure,
        else => error.PlatformFailure,
    };
}

fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}
