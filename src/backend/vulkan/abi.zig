//! Minimal Vulkan 1.3 ABI used by ZigUI's Linux renderer.
//!
//! This is deliberately maintained in-tree.  It is not generated from, and
//! does not import, a Vulkan header at build time.  The declarations below are
//! the narrow driver contract exercised by the renderer: core device/queue
//! management, dynamic rendering, synchronization2, timeline semaphores,
//! external DMA-BUF memory, and external semaphore file descriptors.

const std = @import("std");

pub const Bool32 = u32;
pub const Flags = u32;
pub const Flags64 = u64;
pub const DeviceSize = u64;
pub const StructureType = i32;
pub const Result = i32;
pub const Format = i32;

pub const InstanceObject = opaque {};
pub const PhysicalDeviceObject = opaque {};
pub const DeviceObject = opaque {};
pub const QueueObject = opaque {};
pub const CommandBufferObject = opaque {};

pub const Instance = ?*InstanceObject;
pub const PhysicalDevice = ?*PhysicalDeviceObject;
pub const Device = ?*DeviceObject;
pub const Queue = ?*QueueObject;
pub const CommandBuffer = ?*CommandBufferObject;

pub const DeviceMemory = u64;
pub const Buffer = u64;
pub const Image = u64;
pub const ImageView = u64;
pub const Sampler = u64;
pub const Semaphore = u64;
pub const Fence = u64;
pub const CommandPool = u64;
pub const ShaderModule = u64;
pub const Pipeline = u64;
pub const PipelineLayout = u64;
pub const PipelineCache = u64;
pub const RenderPass = u64;
pub const DescriptorSetLayout = u64;
pub const DescriptorPool = u64;
pub const DescriptorSet = u64;
pub const BufferView = u64;

pub const null_handle: u64 = 0;
pub const vk_true: Bool32 = 1;
pub const vk_false: Bool32 = 0;
pub const whole_size: DeviceSize = std.math.maxInt(DeviceSize);
pub const queue_family_ignored: u32 = std.math.maxInt(u32);
pub const queue_family_external: u32 = std.math.maxInt(u32) - 1;
pub const queue_family_foreign_ext: u32 = std.math.maxInt(u32) - 2;

pub const success: Result = 0;
pub const not_ready: Result = 1;
pub const timeout: Result = 2;
pub const incomplete: Result = 5;
pub const error_out_of_host_memory: Result = -1;
pub const error_out_of_device_memory: Result = -2;
pub const error_initialization_failed: Result = -3;
pub const error_device_lost: Result = -4;
pub const error_memory_map_failed: Result = -5;
pub const error_layer_not_present: Result = -6;
pub const error_extension_not_present: Result = -7;
pub const error_feature_not_present: Result = -8;
pub const error_incompatible_driver: Result = -9;
pub const error_too_many_objects: Result = -10;
pub const error_format_not_supported: Result = -11;
pub const error_fragmented_pool: Result = -12;

pub fn makeApiVersion(variant: u32, major: u32, minor: u32, patch: u32) u32 {
    return (variant << 29) | (major << 22) | (minor << 12) | patch;
}

pub const api_version_1_3 = makeApiVersion(0, 1, 3, 0);

pub const st = struct {
    pub const application_info: StructureType = 0;
    pub const instance_create_info: StructureType = 1;
    pub const device_queue_create_info: StructureType = 2;
    pub const device_create_info: StructureType = 3;
    pub const memory_allocate_info: StructureType = 5;
    pub const mapped_memory_range: StructureType = 6;
    pub const fence_create_info: StructureType = 8;
    pub const semaphore_create_info: StructureType = 9;
    pub const buffer_create_info: StructureType = 12;
    pub const image_create_info: StructureType = 14;
    pub const image_view_create_info: StructureType = 15;
    pub const shader_module_create_info: StructureType = 16;
    pub const pipeline_shader_stage_create_info: StructureType = 18;
    pub const pipeline_vertex_input_state_create_info: StructureType = 19;
    pub const pipeline_input_assembly_state_create_info: StructureType = 20;
    pub const pipeline_viewport_state_create_info: StructureType = 22;
    pub const pipeline_rasterization_state_create_info: StructureType = 23;
    pub const pipeline_multisample_state_create_info: StructureType = 24;
    pub const pipeline_depth_stencil_state_create_info: StructureType = 25;
    pub const pipeline_color_blend_state_create_info: StructureType = 26;
    pub const pipeline_dynamic_state_create_info: StructureType = 27;
    pub const graphics_pipeline_create_info: StructureType = 28;
    pub const pipeline_layout_create_info: StructureType = 30;
    pub const sampler_create_info: StructureType = 31;
    pub const descriptor_set_layout_create_info: StructureType = 32;
    pub const descriptor_pool_create_info: StructureType = 33;
    pub const descriptor_set_allocate_info: StructureType = 34;
    pub const write_descriptor_set: StructureType = 35;
    pub const command_pool_create_info: StructureType = 39;
    pub const command_buffer_allocate_info: StructureType = 40;
    pub const command_buffer_begin_info: StructureType = 42;
    pub const memory_dedicated_requirements: StructureType = 1000127000;
    pub const memory_dedicated_allocate_info: StructureType = 1000127001;
    pub const image_memory_requirements_info_2: StructureType = 1000146001;
    pub const memory_requirements_2: StructureType = 1000146003;
    pub const physical_device_features_2: StructureType = 1000059000;
    pub const format_properties_2: StructureType = 1000059002;
    pub const image_format_properties_2: StructureType = 1000059003;
    pub const physical_device_image_format_info_2: StructureType = 1000059004;
    pub const physical_device_external_image_format_info: StructureType = 1000071000;
    pub const external_image_format_properties: StructureType = 1000071001;
    pub const external_memory_image_create_info: StructureType = 1000072001;
    pub const export_memory_allocate_info: StructureType = 1000072002;
    pub const export_semaphore_create_info: StructureType = 1000077000;
    pub const physical_device_external_semaphore_info: StructureType = 1000076000;
    pub const external_semaphore_properties: StructureType = 1000076001;
    pub const physical_device_timeline_semaphore_features: StructureType = 1000207000;
    pub const semaphore_type_create_info: StructureType = 1000207002;
    pub const physical_device_synchronization_2_features: StructureType = 1000314007;
    pub const image_memory_barrier_2: StructureType = 1000314002;
    pub const dependency_info: StructureType = 1000314003;
    pub const submit_info_2: StructureType = 1000314004;
    pub const semaphore_submit_info: StructureType = 1000314005;
    pub const command_buffer_submit_info: StructureType = 1000314006;
    pub const rendering_info: StructureType = 1000044000;
    pub const rendering_attachment_info: StructureType = 1000044001;
    pub const pipeline_rendering_create_info: StructureType = 1000044002;
    pub const physical_device_dynamic_rendering_features: StructureType = 1000044003;
    pub const memory_get_fd_info_khr: StructureType = 1000074002;
    pub const import_memory_fd_info_khr: StructureType = 1000074000;
    pub const memory_fd_properties_khr: StructureType = 1000074001;
    pub const import_semaphore_fd_info_khr: StructureType = 1000079000;
    pub const semaphore_get_fd_info_khr: StructureType = 1000079001;
    pub const physical_device_image_drm_format_modifier_info_ext: StructureType = 1000158002;
    pub const image_drm_format_modifier_list_create_info_ext: StructureType = 1000158003;
    pub const image_drm_format_modifier_explicit_create_info_ext: StructureType = 1000158004;
    pub const image_drm_format_modifier_properties_ext: StructureType = 1000158005;
    pub const drm_format_modifier_properties_list_ext: StructureType = 1000158000;
};

pub const extension = struct {
    pub const external_memory_fd: [:0]const u8 = "VK_KHR_external_memory_fd";
    pub const external_semaphore_fd: [:0]const u8 = "VK_KHR_external_semaphore_fd";
    pub const image_drm_format_modifier: [:0]const u8 = "VK_EXT_image_drm_format_modifier";
};

pub const queue_graphics_bit: Flags = 0x00000001;
pub const queue_transfer_bit: Flags = 0x00000004;
pub const physical_device_type_other: i32 = 0;
pub const physical_device_type_integrated_gpu: i32 = 1;
pub const physical_device_type_discrete_gpu: i32 = 2;
pub const physical_device_type_virtual_gpu: i32 = 3;
pub const physical_device_type_cpu: i32 = 4;

pub const memory_property_device_local_bit: Flags = 0x00000001;
pub const memory_property_host_visible_bit: Flags = 0x00000002;
pub const memory_property_host_coherent_bit: Flags = 0x00000004;
pub const memory_property_host_cached_bit: Flags = 0x00000008;

pub const buffer_usage_transfer_src_bit: Flags = 0x00000001;
pub const buffer_usage_transfer_dst_bit: Flags = 0x00000002;
pub const buffer_usage_storage_buffer_bit: Flags = 0x00000020;
pub const buffer_usage_index_buffer_bit: Flags = 0x00000040;
pub const buffer_usage_vertex_buffer_bit: Flags = 0x00000080;

pub const image_usage_transfer_src_bit: Flags = 0x00000001;
pub const image_usage_transfer_dst_bit: Flags = 0x00000002;
pub const image_usage_sampled_bit: Flags = 0x00000004;
pub const image_usage_color_attachment_bit: Flags = 0x00000010;

pub const format_r8_unorm: Format = 9;
pub const format_r8g8b8a8_unorm: Format = 37;
pub const format_r8g8b8a8_srgb: Format = 43;
pub const format_b8g8r8a8_unorm: Format = 44;
pub const format_b8g8r8a8_srgb: Format = 50;
pub const format_r16g16b16a16_sfloat: Format = 97;
pub const format_r32g32_sfloat: Format = 103;
pub const format_r32g32b32a32_sfloat: Format = 109;

pub const image_type_2d: i32 = 1;
pub const image_view_type_2d: i32 = 1;
pub const image_tiling_optimal: i32 = 0;
pub const image_tiling_drm_format_modifier_ext: i32 = 1000158000;
pub const sharing_mode_exclusive: i32 = 0;
pub const sample_count_1_bit: Flags = 1;
pub const image_layout_undefined: i32 = 0;
pub const image_layout_general: i32 = 1;
pub const image_layout_color_attachment_optimal: i32 = 2;
pub const image_layout_shader_read_only_optimal: i32 = 5;
pub const image_layout_transfer_src_optimal: i32 = 6;
pub const image_layout_transfer_dst_optimal: i32 = 7;
pub const image_aspect_color_bit: Flags = 1;
pub const component_swizzle_identity: i32 = 0;

pub const external_memory_handle_type_dma_buf_bit_ext: Flags = 0x00000200;
pub const external_memory_feature_exportable_bit: Flags = 0x00000002;
pub const external_memory_feature_importable_bit: Flags = 0x00000004;
pub const external_semaphore_handle_type_opaque_fd_bit: Flags = 0x00000001;
pub const external_semaphore_feature_exportable_bit: Flags = 0x00000001;
pub const external_semaphore_feature_importable_bit: Flags = 0x00000002;

pub const command_pool_create_reset_command_buffer_bit: Flags = 0x00000002;
pub const command_buffer_level_primary: i32 = 0;
pub const command_buffer_usage_one_time_submit_bit: Flags = 0x00000001;
pub const fence_create_signaled_bit: Flags = 0x00000001;
pub const semaphore_type_timeline: i32 = 1;

pub const pipeline_stage_2_none: Flags64 = 0;
pub const pipeline_stage_2_fragment_shader_bit: Flags64 = 0x00000080;
pub const pipeline_stage_2_color_attachment_output_bit: Flags64 = 0x00000400;
pub const pipeline_stage_2_transfer_bit: Flags64 = 0x00001000;
pub const pipeline_stage_2_all_commands_bit: Flags64 = 0x00010000;
pub const access_2_none: Flags64 = 0;
pub const access_2_color_attachment_read_bit: Flags64 = 0x00000080;
pub const access_2_color_attachment_write_bit: Flags64 = 0x00000100;
pub const access_2_transfer_read_bit: Flags64 = 0x00000800;
pub const access_2_transfer_write_bit: Flags64 = 0x00001000;
pub const access_2_shader_sampled_read_bit: Flags64 = 0x100000000;
pub const access_2_shader_storage_read_bit: Flags64 = 0x200000000;

pub const shader_stage_vertex_bit: Flags = 0x00000001;
pub const shader_stage_fragment_bit: Flags = 0x00000010;
pub const shader_stage_all_graphics: Flags = 0x0000001f;
pub const descriptor_type_combined_image_sampler: i32 = 1;
pub const descriptor_type_storage_buffer: i32 = 7;
pub const descriptor_pool_create_free_descriptor_set_bit: Flags = 0x00000001;
pub const primitive_topology_triangle_list: i32 = 3;
pub const polygon_mode_fill: i32 = 0;
pub const cull_mode_none: Flags = 0;
pub const front_face_counter_clockwise: i32 = 0;
pub const filter_linear: i32 = 1;
pub const sampler_mipmap_mode_linear: i32 = 1;
pub const sampler_address_mode_clamp_to_edge: i32 = 2;
pub const compare_op_always: i32 = 7;
pub const border_color_float_transparent_black: i32 = 0;
pub const dynamic_state_viewport: i32 = 0;
pub const dynamic_state_scissor: i32 = 1;
pub const blend_factor_zero: i32 = 0;
pub const blend_factor_one: i32 = 1;
pub const blend_factor_one_minus_src_alpha: i32 = 7;
pub const blend_op_add: i32 = 0;
pub const color_component_rgba: Flags = 0x0f;
pub const attachment_load_op_load: i32 = 0;
pub const attachment_load_op_clear: i32 = 1;
pub const attachment_store_op_store: i32 = 0;
pub const resolve_mode_none: Flags = 0;
pub const pipeline_bind_point_graphics: i32 = 0;
pub const index_type_uint32: i32 = 1;

pub const format_feature_sampled_image_bit: Flags = 0x00000001;
pub const format_feature_color_attachment_bit: Flags = 0x00000080;
pub const format_feature_color_attachment_blend_bit: Flags = 0x00000100;

pub const Offset2D = extern struct { x: i32 = 0, y: i32 = 0 };
pub const Offset3D = extern struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };
pub const Extent2D = extern struct { width: u32 = 0, height: u32 = 0 };
pub const Extent3D = extern struct { width: u32 = 0, height: u32 = 0, depth: u32 = 1 };
pub const Rect2D = extern struct { offset: Offset2D = .{}, extent: Extent2D = .{} };

pub const ApplicationInfo = extern struct {
    s_type: StructureType = st.application_info,
    next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32 = api_version_1_3,
};

pub const InstanceCreateInfo = extern struct {
    s_type: StructureType = st.instance_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

pub const ExtensionProperties = extern struct {
    name: [256]u8,
    spec_version: u32,

    pub fn slice(self: *const ExtensionProperties) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

pub const LayerProperties = extern struct {
    name: [256]u8,
    spec_version: u32,
    implementation_version: u32,
    description: [256]u8,
};

pub const PhysicalDevicePropertiesHeader = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: i32,
    device_name: [256]u8,
    pipeline_cache_uuid: [16]u8,
};

/// Large enough for every Vulkan 1.3 `VkPhysicalDeviceProperties` layout.
/// The union keeps the storage naturally eight-byte aligned while exposing the
/// stable prefix used by adapter selection.
pub const PhysicalDeviceProperties = extern union {
    header: PhysicalDevicePropertiesHeader,
    storage: [2048]u8,
    alignment: u64,
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: Flags,
    queue_count: u32,
    timestamp_valid_bits: u32,
    min_image_transfer_granularity: Extent3D,
};

pub const MemoryType = extern struct { property_flags: Flags, heap_index: u32 };
pub const MemoryHeap = extern struct { size: DeviceSize, flags: Flags, _padding: u32 = 0 };
pub const PhysicalDeviceMemoryProperties = extern struct {
    memory_type_count: u32,
    memory_types: [32]MemoryType,
    memory_heap_count: u32,
    memory_heaps: [16]MemoryHeap,
};

pub const PhysicalDeviceFeatures = extern struct { values: [55]Bool32 = @splat(0) };
pub const PhysicalDeviceFeatures2 = extern struct {
    s_type: StructureType = st.physical_device_features_2,
    next: ?*anyopaque = null,
    features: PhysicalDeviceFeatures = .{},
};

pub const PhysicalDeviceTimelineSemaphoreFeatures = extern struct {
    s_type: StructureType = st.physical_device_timeline_semaphore_features,
    next: ?*anyopaque = null,
    timeline_semaphore: Bool32 = vk_false,
};

pub const PhysicalDeviceSynchronization2Features = extern struct {
    s_type: StructureType = st.physical_device_synchronization_2_features,
    next: ?*anyopaque = null,
    synchronization_2: Bool32 = vk_false,
};

pub const PhysicalDeviceDynamicRenderingFeatures = extern struct {
    s_type: StructureType = st.physical_device_dynamic_rendering_features,
    next: ?*anyopaque = null,
    dynamic_rendering: Bool32 = vk_false,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: StructureType = st.device_queue_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    queue_family_index: u32,
    queue_count: u32 = 1,
    queue_priorities: [*]const f32,
};

pub const DeviceCreateInfo = extern struct {
    s_type: StructureType = st.device_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    queue_create_info_count: u32,
    queue_create_infos: [*]const DeviceQueueCreateInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32,
    enabled_extension_names: [*]const [*:0]const u8,
    enabled_features: ?*const PhysicalDeviceFeatures = null,
};

pub const MemoryRequirements = extern struct {
    size: DeviceSize,
    alignment: DeviceSize,
    memory_type_bits: u32,
    _padding: u32 = 0,
};

pub const MemoryDedicatedRequirements = extern struct {
    s_type: StructureType = st.memory_dedicated_requirements,
    next: ?*anyopaque = null,
    prefers_dedicated_allocation: Bool32 = vk_false,
    requires_dedicated_allocation: Bool32 = vk_false,
};

pub const MemoryDedicatedAllocateInfo = extern struct {
    s_type: StructureType = st.memory_dedicated_allocate_info,
    next: ?*const anyopaque = null,
    image: Image = 0,
    buffer: Buffer = 0,
};

pub const ImageMemoryRequirementsInfo2 = extern struct {
    s_type: StructureType = st.image_memory_requirements_info_2,
    next: ?*const anyopaque = null,
    image: Image,
};

pub const MemoryRequirements2 = extern struct {
    s_type: StructureType = st.memory_requirements_2,
    next: ?*anyopaque = null,
    memory_requirements: MemoryRequirements = undefined,
};

pub const MemoryAllocateInfo = extern struct {
    s_type: StructureType = st.memory_allocate_info,
    next: ?*const anyopaque = null,
    allocation_size: DeviceSize,
    memory_type_index: u32,
};

pub const MappedMemoryRange = extern struct {
    s_type: StructureType = st.mapped_memory_range,
    next: ?*const anyopaque = null,
    memory: DeviceMemory,
    offset: DeviceSize = 0,
    size: DeviceSize = whole_size,
};

pub const ExportMemoryAllocateInfo = extern struct {
    s_type: StructureType = st.export_memory_allocate_info,
    next: ?*const anyopaque = null,
    handle_types: Flags,
};

pub const ImportMemoryFdInfo = extern struct {
    s_type: StructureType = st.import_memory_fd_info_khr,
    next: ?*const anyopaque = null,
    handle_type: Flags,
    fd: i32,
};

pub const MemoryFdProperties = extern struct {
    s_type: StructureType = st.memory_fd_properties_khr,
    next: ?*anyopaque = null,
    memory_type_bits: u32 = 0,
};

pub const MemoryGetFdInfo = extern struct {
    s_type: StructureType = st.memory_get_fd_info_khr,
    next: ?*const anyopaque = null,
    memory: DeviceMemory,
    handle_type: Flags,
};

pub const BufferCreateInfo = extern struct {
    s_type: StructureType = st.buffer_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    size: DeviceSize,
    usage: Flags,
    sharing_mode: i32 = sharing_mode_exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
};

pub const ExternalMemoryImageCreateInfo = extern struct {
    s_type: StructureType = st.external_memory_image_create_info,
    next: ?*const anyopaque = null,
    handle_types: Flags,
};

pub const ImageDrmFormatModifierListCreateInfo = extern struct {
    s_type: StructureType = st.image_drm_format_modifier_list_create_info_ext,
    next: ?*const anyopaque = null,
    modifier_count: u32,
    modifiers: [*]const u64,
};

pub const SubresourceLayout = extern struct {
    offset: DeviceSize,
    size: DeviceSize,
    row_pitch: DeviceSize,
    array_pitch: DeviceSize,
    depth_pitch: DeviceSize,
};

pub const ImageDrmFormatModifierExplicitCreateInfo = extern struct {
    s_type: StructureType = st.image_drm_format_modifier_explicit_create_info_ext,
    next: ?*const anyopaque = null,
    modifier: u64,
    plane_count: u32,
    plane_layouts: [*]const SubresourceLayout,
};

pub const ImageCreateInfo = extern struct {
    s_type: StructureType = st.image_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    image_type: i32 = image_type_2d,
    format: Format,
    extent: Extent3D,
    mip_levels: u32 = 1,
    array_layers: u32 = 1,
    samples: Flags = sample_count_1_bit,
    tiling: i32,
    usage: Flags,
    sharing_mode: i32 = sharing_mode_exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    initial_layout: i32 = image_layout_undefined,
};

pub const ImageSubresource = extern struct {
    aspect_mask: Flags = image_aspect_color_bit,
    mip_level: u32 = 0,
    array_layer: u32 = 0,
};

pub const ComponentMapping = extern struct {
    r: i32 = component_swizzle_identity,
    g: i32 = component_swizzle_identity,
    b: i32 = component_swizzle_identity,
    a: i32 = component_swizzle_identity,
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: Flags = image_aspect_color_bit,
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const ImageViewCreateInfo = extern struct {
    s_type: StructureType = st.image_view_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    image: Image,
    view_type: i32 = image_view_type_2d,
    format: Format,
    components: ComponentMapping = .{},
    subresource_range: ImageSubresourceRange = .{},
};

pub const ImageDrmFormatModifierProperties = extern struct {
    s_type: StructureType = st.image_drm_format_modifier_properties_ext,
    next: ?*anyopaque = null,
    modifier: u64 = 0,
};

pub const DrmFormatModifierProperties = extern struct {
    modifier: u64,
    plane_count: u32,
    tiling_features: Flags,
};

pub const DrmFormatModifierPropertiesList = extern struct {
    s_type: StructureType = st.drm_format_modifier_properties_list_ext,
    next: ?*anyopaque = null,
    modifier_count: u32 = 0,
    modifiers: ?[*]DrmFormatModifierProperties = null,
};

pub const FormatProperties = extern struct {
    linear_tiling_features: Flags = 0,
    optimal_tiling_features: Flags = 0,
    buffer_features: Flags = 0,
};

pub const FormatProperties2 = extern struct {
    s_type: StructureType = st.format_properties_2,
    next: ?*anyopaque = null,
    format_properties: FormatProperties = .{},
};

pub const ImageFormatProperties = extern struct {
    max_extent: Extent3D,
    max_mip_levels: u32,
    max_array_layers: u32,
    sample_counts: Flags,
    max_resource_size: DeviceSize,
};

pub const PhysicalDeviceImageFormatInfo2 = extern struct {
    s_type: StructureType = st.physical_device_image_format_info_2,
    next: ?*const anyopaque = null,
    format: Format,
    image_type: i32,
    tiling: i32,
    usage: Flags,
    flags: Flags = 0,
};

pub const PhysicalDeviceExternalImageFormatInfo = extern struct {
    s_type: StructureType = st.physical_device_external_image_format_info,
    next: ?*const anyopaque = null,
    handle_type: Flags,
};

pub const PhysicalDeviceImageDrmFormatModifierInfo = extern struct {
    s_type: StructureType = st.physical_device_image_drm_format_modifier_info_ext,
    next: ?*const anyopaque = null,
    modifier: u64,
    sharing_mode: i32 = sharing_mode_exclusive,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
};

pub const ExternalMemoryProperties = extern struct {
    external_memory_features: Flags = 0,
    export_from_imported_handle_types: Flags = 0,
    compatible_handle_types: Flags = 0,
};

pub const ExternalImageFormatProperties = extern struct {
    s_type: StructureType = st.external_image_format_properties,
    next: ?*anyopaque = null,
    external_memory_properties: ExternalMemoryProperties = .{},
};

pub const ImageFormatProperties2 = extern struct {
    s_type: StructureType = st.image_format_properties_2,
    next: ?*anyopaque = null,
    image_format_properties: ImageFormatProperties = undefined,
};

pub const SemaphoreCreateInfo = extern struct {
    s_type: StructureType = st.semaphore_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
};

pub const SemaphoreTypeCreateInfo = extern struct {
    s_type: StructureType = st.semaphore_type_create_info,
    next: ?*const anyopaque = null,
    semaphore_type: i32 = semaphore_type_timeline,
    initial_value: u64 = 0,
};

pub const ExportSemaphoreCreateInfo = extern struct {
    s_type: StructureType = st.export_semaphore_create_info,
    next: ?*const anyopaque = null,
    handle_types: Flags,
};

pub const SemaphoreGetFdInfo = extern struct {
    s_type: StructureType = st.semaphore_get_fd_info_khr,
    next: ?*const anyopaque = null,
    semaphore: Semaphore,
    handle_type: Flags,
};

pub const ImportSemaphoreFdInfo = extern struct {
    s_type: StructureType = st.import_semaphore_fd_info_khr,
    next: ?*const anyopaque = null,
    semaphore: Semaphore,
    flags: Flags = 0,
    handle_type: Flags,
    fd: i32,
};

pub const PhysicalDeviceExternalSemaphoreInfo = extern struct {
    s_type: StructureType = st.physical_device_external_semaphore_info,
    next: ?*const anyopaque = null,
    handle_type: Flags,
};

pub const ExternalSemaphoreProperties = extern struct {
    s_type: StructureType = st.external_semaphore_properties,
    next: ?*anyopaque = null,
    export_from_imported_handle_types: Flags = 0,
    compatible_handle_types: Flags = 0,
    external_semaphore_features: Flags = 0,
};

pub const FenceCreateInfo = extern struct {
    s_type: StructureType = st.fence_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
};

pub const CommandPoolCreateInfo = extern struct {
    s_type: StructureType = st.command_pool_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = command_pool_create_reset_command_buffer_bit,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: StructureType = st.command_buffer_allocate_info,
    next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: i32 = command_buffer_level_primary,
    command_buffer_count: u32,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: StructureType = st.command_buffer_begin_info,
    next: ?*const anyopaque = null,
    flags: Flags = command_buffer_usage_one_time_submit_bit,
    inheritance_info: ?*const anyopaque = null,
};

pub const ImageMemoryBarrier2 = extern struct {
    s_type: StructureType = st.image_memory_barrier_2,
    next: ?*const anyopaque = null,
    source_stage_mask: Flags64,
    source_access_mask: Flags64,
    destination_stage_mask: Flags64,
    destination_access_mask: Flags64,
    old_layout: i32,
    new_layout: i32,
    source_queue_family_index: u32 = queue_family_ignored,
    destination_queue_family_index: u32 = queue_family_ignored,
    image: Image,
    subresource_range: ImageSubresourceRange = .{},
};

pub const DependencyInfo = extern struct {
    s_type: StructureType = st.dependency_info,
    next: ?*const anyopaque = null,
    dependency_flags: Flags = 0,
    memory_barrier_count: u32 = 0,
    memory_barriers: ?*const anyopaque = null,
    buffer_memory_barrier_count: u32 = 0,
    buffer_memory_barriers: ?*const anyopaque = null,
    image_memory_barrier_count: u32 = 0,
    image_memory_barriers: ?[*]const ImageMemoryBarrier2 = null,
};

pub const SemaphoreSubmitInfo = extern struct {
    s_type: StructureType = st.semaphore_submit_info,
    next: ?*const anyopaque = null,
    semaphore: Semaphore,
    value: u64,
    stage_mask: Flags64,
    device_index: u32 = 0,
};

pub const CommandBufferSubmitInfo = extern struct {
    s_type: StructureType = st.command_buffer_submit_info,
    next: ?*const anyopaque = null,
    command_buffer: CommandBuffer,
    device_mask: u32 = 0,
};

pub const SubmitInfo2 = extern struct {
    s_type: StructureType = st.submit_info_2,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    wait_semaphore_info_count: u32 = 0,
    wait_semaphore_infos: ?[*]const SemaphoreSubmitInfo = null,
    command_buffer_info_count: u32,
    command_buffer_infos: [*]const CommandBufferSubmitInfo,
    signal_semaphore_info_count: u32 = 0,
    signal_semaphore_infos: ?[*]const SemaphoreSubmitInfo = null,
};

pub const ClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};

pub const ClearDepthStencilValue = extern struct { depth: f32, stencil: u32 };
pub const ClearValue = extern union { color: ClearColorValue, depth_stencil: ClearDepthStencilValue };

pub const RenderingAttachmentInfo = extern struct {
    s_type: StructureType = st.rendering_attachment_info,
    next: ?*const anyopaque = null,
    image_view: ImageView,
    image_layout: i32,
    resolve_mode: Flags = resolve_mode_none,
    resolve_image_view: ImageView = 0,
    resolve_image_layout: i32 = image_layout_undefined,
    load_op: i32,
    store_op: i32 = attachment_store_op_store,
    clear_value: ClearValue,
};

pub const RenderingInfo = extern struct {
    s_type: StructureType = st.rendering_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    render_area: Rect2D,
    layer_count: u32 = 1,
    view_mask: u32 = 0,
    color_attachment_count: u32 = 1,
    color_attachments: [*]const RenderingAttachmentInfo,
    depth_attachment: ?*const anyopaque = null,
    stencil_attachment: ?*const anyopaque = null,
};

pub const PipelineRenderingCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_rendering_create_info,
    next: ?*const anyopaque = null,
    view_mask: u32 = 0,
    color_attachment_count: u32,
    color_attachment_formats: [*]const Format,
    depth_attachment_format: Format = 0,
    stencil_attachment_format: Format = 0,
};

pub const BufferCopy = extern struct { source_offset: DeviceSize = 0, destination_offset: DeviceSize = 0, size: DeviceSize };
pub const ImageSubresourceLayers = extern struct {
    aspect_mask: Flags = image_aspect_color_bit,
    mip_level: u32 = 0,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};
pub const BufferImageCopy = extern struct {
    buffer_offset: DeviceSize = 0,
    buffer_row_length: u32 = 0,
    buffer_image_height: u32 = 0,
    image_subresource: ImageSubresourceLayers = .{},
    image_offset: Offset3D = .{},
    image_extent: Extent3D,
};
pub const ImageCopy = extern struct {
    source_subresource: ImageSubresourceLayers = .{},
    source_offset: Offset3D = .{},
    destination_subresource: ImageSubresourceLayers = .{},
    destination_offset: Offset3D = .{},
    extent: Extent3D,
};

pub const ShaderModuleCreateInfo = extern struct {
    s_type: StructureType = st.shader_module_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    code_size: usize,
    code: [*]const u32,
};

pub const SpecializationInfo = opaque {};
pub const PipelineShaderStageCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_shader_stage_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    stage: Flags,
    module: ShaderModule,
    name: [*:0]const u8,
    specialization_info: ?*const SpecializationInfo = null,
};

pub const PushConstantRange = extern struct { stage_flags: Flags, offset: u32, size: u32 };
pub const PipelineLayoutCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_layout_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    set_layout_count: u32 = 0,
    set_layouts: ?[*]const DescriptorSetLayout = null,
    push_constant_range_count: u32 = 0,
    push_constant_ranges: ?[*]const PushConstantRange = null,
};

pub const SamplerCreateInfo = extern struct {
    s_type: StructureType = st.sampler_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    mag_filter: i32 = filter_linear,
    min_filter: i32 = filter_linear,
    mipmap_mode: i32 = sampler_mipmap_mode_linear,
    address_mode_u: i32 = sampler_address_mode_clamp_to_edge,
    address_mode_v: i32 = sampler_address_mode_clamp_to_edge,
    address_mode_w: i32 = sampler_address_mode_clamp_to_edge,
    mip_lod_bias: f32 = 0,
    anisotropy_enable: Bool32 = vk_false,
    max_anisotropy: f32 = 1,
    compare_enable: Bool32 = vk_false,
    compare_op: i32 = compare_op_always,
    min_lod: f32 = 0,
    max_lod: f32 = 0,
    border_color: i32 = border_color_float_transparent_black,
    unnormalized_coordinates: Bool32 = vk_false,
};

pub const DescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptor_type: i32,
    descriptor_count: u32 = 1,
    stage_flags: Flags,
    immutable_samplers: ?[*]const Sampler = null,
};

pub const DescriptorSetLayoutCreateInfo = extern struct {
    s_type: StructureType = st.descriptor_set_layout_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    binding_count: u32,
    bindings: [*]const DescriptorSetLayoutBinding,
};

pub const DescriptorPoolSize = extern struct { descriptor_type: i32, descriptor_count: u32 };
pub const DescriptorPoolCreateInfo = extern struct {
    s_type: StructureType = st.descriptor_pool_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    max_sets: u32,
    pool_size_count: u32,
    pool_sizes: [*]const DescriptorPoolSize,
};

pub const DescriptorSetAllocateInfo = extern struct {
    s_type: StructureType = st.descriptor_set_allocate_info,
    next: ?*const anyopaque = null,
    descriptor_pool: DescriptorPool,
    descriptor_set_count: u32,
    set_layouts: [*]const DescriptorSetLayout,
};

pub const DescriptorBufferInfo = extern struct { buffer: Buffer, offset: DeviceSize = 0, range: DeviceSize = whole_size };
pub const DescriptorImageInfo = extern struct { sampler: Sampler, image_view: ImageView, image_layout: i32 };
pub const WriteDescriptorSet = extern struct {
    s_type: StructureType = st.write_descriptor_set,
    next: ?*const anyopaque = null,
    destination_set: DescriptorSet,
    destination_binding: u32,
    destination_array_element: u32 = 0,
    descriptor_count: u32 = 1,
    descriptor_type: i32,
    image_info: ?[*]const DescriptorImageInfo = null,
    buffer_info: ?[*]const DescriptorBufferInfo = null,
    texel_buffer_view: ?[*]const BufferView = null,
};

pub const VertexInputBindingDescription = extern struct { binding: u32, stride: u32, input_rate: i32 };
pub const VertexInputAttributeDescription = extern struct { location: u32, binding: u32, format: Format, offset: u32 };
pub const vertex_input_rate_vertex: i32 = 0;
pub const PipelineVertexInputStateCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_vertex_input_state_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    vertex_binding_description_count: u32 = 0,
    vertex_binding_descriptions: ?[*]const VertexInputBindingDescription = null,
    vertex_attribute_description_count: u32 = 0,
    vertex_attribute_descriptions: ?[*]const VertexInputAttributeDescription = null,
};
pub const PipelineInputAssemblyStateCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_input_assembly_state_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    topology: i32 = primitive_topology_triangle_list,
    primitive_restart_enable: Bool32 = vk_false,
};
pub const Viewport = extern struct { x: f32, y: f32, width: f32, height: f32, min_depth: f32 = 0, max_depth: f32 = 1 };
pub const PipelineViewportStateCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_viewport_state_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    viewport_count: u32 = 1,
    viewports: ?[*]const Viewport = null,
    scissor_count: u32 = 1,
    scissors: ?[*]const Rect2D = null,
};
pub const PipelineRasterizationStateCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_rasterization_state_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    depth_clamp_enable: Bool32 = vk_false,
    rasterizer_discard_enable: Bool32 = vk_false,
    polygon_mode: i32 = polygon_mode_fill,
    cull_mode: Flags = cull_mode_none,
    front_face: i32 = front_face_counter_clockwise,
    depth_bias_enable: Bool32 = vk_false,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    line_width: f32 = 1,
};
pub const PipelineMultisampleStateCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_multisample_state_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    rasterization_samples: Flags = sample_count_1_bit,
    sample_shading_enable: Bool32 = vk_false,
    min_sample_shading: f32 = 0,
    sample_mask: ?[*]const u32 = null,
    alpha_to_coverage_enable: Bool32 = vk_false,
    alpha_to_one_enable: Bool32 = vk_false,
};
pub const StencilOpState = extern struct {
    fail_op: i32 = 0,
    pass_op: i32 = 0,
    depth_fail_op: i32 = 0,
    compare_op: i32 = compare_op_always,
    compare_mask: u32 = 0,
    write_mask: u32 = 0,
    reference: u32 = 0,
};
pub const PipelineDepthStencilStateCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_depth_stencil_state_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    depth_test_enable: Bool32 = vk_false,
    depth_write_enable: Bool32 = vk_false,
    depth_compare_op: i32 = compare_op_always,
    depth_bounds_test_enable: Bool32 = vk_false,
    stencil_test_enable: Bool32 = vk_false,
    front: StencilOpState = .{},
    back: StencilOpState = .{},
    min_depth_bounds: f32 = 0,
    max_depth_bounds: f32 = 1,
};
pub const PipelineColorBlendAttachmentState = extern struct {
    blend_enable: Bool32 = vk_true,
    source_color_blend_factor: i32 = blend_factor_one,
    destination_color_blend_factor: i32 = blend_factor_one_minus_src_alpha,
    color_blend_op: i32 = blend_op_add,
    source_alpha_blend_factor: i32 = blend_factor_one,
    destination_alpha_blend_factor: i32 = blend_factor_one_minus_src_alpha,
    alpha_blend_op: i32 = blend_op_add,
    color_write_mask: Flags = color_component_rgba,
};
pub const PipelineColorBlendStateCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_color_blend_state_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    logic_op_enable: Bool32 = vk_false,
    logic_op: i32 = 0,
    attachment_count: u32,
    attachments: [*]const PipelineColorBlendAttachmentState,
    blend_constants: [4]f32 = .{ 0, 0, 0, 0 },
};
pub const PipelineDynamicStateCreateInfo = extern struct {
    s_type: StructureType = st.pipeline_dynamic_state_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    dynamic_state_count: u32,
    dynamic_states: [*]const i32,
};
pub const GraphicsPipelineCreateInfo = extern struct {
    s_type: StructureType = st.graphics_pipeline_create_info,
    next: ?*const anyopaque = null,
    flags: Flags = 0,
    stage_count: u32,
    stages: [*]const PipelineShaderStageCreateInfo,
    vertex_input_state: *const PipelineVertexInputStateCreateInfo,
    input_assembly_state: *const PipelineInputAssemblyStateCreateInfo,
    tessellation_state: ?*const anyopaque = null,
    viewport_state: *const PipelineViewportStateCreateInfo,
    rasterization_state: *const PipelineRasterizationStateCreateInfo,
    multisample_state: *const PipelineMultisampleStateCreateInfo,
    depth_stencil_state: ?*const PipelineDepthStencilStateCreateInfo = null,
    color_blend_state: *const PipelineColorBlendStateCreateInfo,
    dynamic_state: *const PipelineDynamicStateCreateInfo,
    layout: PipelineLayout,
    render_pass: RenderPass = 0,
    subpass: u32 = 0,
    base_pipeline_handle: Pipeline = 0,
    base_pipeline_index: i32 = -1,
};

comptime {
    std.debug.assert(@sizeOf(Offset2D) == 8);
    std.debug.assert(@sizeOf(Extent3D) == 12);
    std.debug.assert(@sizeOf(MemoryRequirements) == 24);
    std.debug.assert(@sizeOf(SubresourceLayout) == 40);
    std.debug.assert(@sizeOf(ExtensionProperties) == 260);
}

pub const VoidFunction = *const fn () callconv(.c) void;
pub const GetInstanceProcAddr = *const fn (Instance, [*:0]const u8) callconv(.c) ?VoidFunction;
pub const GetDeviceProcAddr = *const fn (Device, [*:0]const u8) callconv(.c) ?VoidFunction;

pub fn loadProc(comptime T: type, raw: ?VoidFunction) !T {
    return @ptrCast(raw orelse return error.MissingVulkanSymbol);
}

pub const GlobalDispatch = struct {
    loader: std.DynLib,
    get_instance_proc_addr: GetInstanceProcAddr,
    enumerate_instance_version: *const fn (*u32) callconv(.c) Result,
    enumerate_instance_extension_properties: *const fn (?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) Result,
    enumerate_instance_layer_properties: *const fn (*u32, ?[*]LayerProperties) callconv(.c) Result,
    create_instance: *const fn (*const InstanceCreateInfo, ?*const anyopaque, *Instance) callconv(.c) Result,

    pub fn load() !GlobalDispatch {
        var loader = std.DynLib.open("libvulkan.so.1") catch try std.DynLib.open("libvulkan.so");
        errdefer loader.close();
        const get = loader.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.MissingVulkanSymbol;
        return .{
            .loader = loader,
            .get_instance_proc_addr = get,
            .enumerate_instance_version = try loadProc(@FieldType(GlobalDispatch, "enumerate_instance_version"), get(null, "vkEnumerateInstanceVersion")),
            .enumerate_instance_extension_properties = try loadProc(@FieldType(GlobalDispatch, "enumerate_instance_extension_properties"), get(null, "vkEnumerateInstanceExtensionProperties")),
            .enumerate_instance_layer_properties = try loadProc(@FieldType(GlobalDispatch, "enumerate_instance_layer_properties"), get(null, "vkEnumerateInstanceLayerProperties")),
            .create_instance = try loadProc(@FieldType(GlobalDispatch, "create_instance"), get(null, "vkCreateInstance")),
        };
    }

    pub fn deinit(self: *GlobalDispatch) void {
        self.loader.close();
        self.* = undefined;
    }
};

pub const InstanceDispatch = struct {
    get_device_proc_addr: GetDeviceProcAddr,
    destroy_instance: *const fn (Instance, ?*const anyopaque) callconv(.c) void,
    enumerate_physical_devices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) Result,
    get_physical_device_properties: *const fn (PhysicalDevice, *PhysicalDeviceProperties) callconv(.c) void,
    get_physical_device_queue_family_properties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void,
    get_physical_device_memory_properties: *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(.c) void,
    get_physical_device_features_2: *const fn (PhysicalDevice, *PhysicalDeviceFeatures2) callconv(.c) void,
    enumerate_device_extension_properties: *const fn (PhysicalDevice, ?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) Result,
    get_physical_device_format_properties_2: *const fn (PhysicalDevice, Format, *FormatProperties2) callconv(.c) void,
    get_physical_device_image_format_properties_2: *const fn (PhysicalDevice, *const PhysicalDeviceImageFormatInfo2, *ImageFormatProperties2) callconv(.c) Result,
    get_physical_device_external_semaphore_properties: *const fn (PhysicalDevice, *const PhysicalDeviceExternalSemaphoreInfo, *ExternalSemaphoreProperties) callconv(.c) void,
    create_device: *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const anyopaque, *Device) callconv(.c) Result,

    pub fn load(global: GlobalDispatch, instance: Instance) !InstanceDispatch {
        const get = global.get_instance_proc_addr;
        return .{
            .get_device_proc_addr = try loadProc(GetDeviceProcAddr, get(instance, "vkGetDeviceProcAddr")),
            .destroy_instance = try loadProc(@FieldType(InstanceDispatch, "destroy_instance"), get(instance, "vkDestroyInstance")),
            .enumerate_physical_devices = try loadProc(@FieldType(InstanceDispatch, "enumerate_physical_devices"), get(instance, "vkEnumeratePhysicalDevices")),
            .get_physical_device_properties = try loadProc(@FieldType(InstanceDispatch, "get_physical_device_properties"), get(instance, "vkGetPhysicalDeviceProperties")),
            .get_physical_device_queue_family_properties = try loadProc(@FieldType(InstanceDispatch, "get_physical_device_queue_family_properties"), get(instance, "vkGetPhysicalDeviceQueueFamilyProperties")),
            .get_physical_device_memory_properties = try loadProc(@FieldType(InstanceDispatch, "get_physical_device_memory_properties"), get(instance, "vkGetPhysicalDeviceMemoryProperties")),
            .get_physical_device_features_2 = try loadProc(@FieldType(InstanceDispatch, "get_physical_device_features_2"), get(instance, "vkGetPhysicalDeviceFeatures2")),
            .enumerate_device_extension_properties = try loadProc(@FieldType(InstanceDispatch, "enumerate_device_extension_properties"), get(instance, "vkEnumerateDeviceExtensionProperties")),
            .get_physical_device_format_properties_2 = try loadProc(@FieldType(InstanceDispatch, "get_physical_device_format_properties_2"), get(instance, "vkGetPhysicalDeviceFormatProperties2")),
            .get_physical_device_image_format_properties_2 = try loadProc(@FieldType(InstanceDispatch, "get_physical_device_image_format_properties_2"), get(instance, "vkGetPhysicalDeviceImageFormatProperties2")),
            .get_physical_device_external_semaphore_properties = try loadProc(@FieldType(InstanceDispatch, "get_physical_device_external_semaphore_properties"), get(instance, "vkGetPhysicalDeviceExternalSemaphoreProperties")),
            .create_device = try loadProc(@FieldType(InstanceDispatch, "create_device"), get(instance, "vkCreateDevice")),
        };
    }
};

pub const DeviceDispatch = struct {
    destroy_device: *const fn (Device, ?*const anyopaque) callconv(.c) void,
    get_device_queue: *const fn (Device, u32, u32, *Queue) callconv(.c) void,
    device_wait_idle: *const fn (Device) callconv(.c) Result,
    queue_wait_idle: *const fn (Queue) callconv(.c) Result,
    queue_submit_2: *const fn (Queue, u32, [*]const SubmitInfo2, Fence) callconv(.c) Result,
    create_fence: *const fn (Device, *const FenceCreateInfo, ?*const anyopaque, *Fence) callconv(.c) Result,
    destroy_fence: *const fn (Device, Fence, ?*const anyopaque) callconv(.c) void,
    get_fence_status: *const fn (Device, Fence) callconv(.c) Result,
    wait_for_fences: *const fn (Device, u32, [*]const Fence, Bool32, u64) callconv(.c) Result,
    reset_fences: *const fn (Device, u32, [*]const Fence) callconv(.c) Result,
    create_semaphore: *const fn (Device, *const SemaphoreCreateInfo, ?*const anyopaque, *Semaphore) callconv(.c) Result,
    destroy_semaphore: *const fn (Device, Semaphore, ?*const anyopaque) callconv(.c) void,
    get_semaphore_counter_value: *const fn (Device, Semaphore, *u64) callconv(.c) Result,
    get_semaphore_fd: *const fn (Device, *const SemaphoreGetFdInfo, *i32) callconv(.c) Result,
    import_semaphore_fd: *const fn (Device, *const ImportSemaphoreFdInfo) callconv(.c) Result,
    create_command_pool: *const fn (Device, *const CommandPoolCreateInfo, ?*const anyopaque, *CommandPool) callconv(.c) Result,
    destroy_command_pool: *const fn (Device, CommandPool, ?*const anyopaque) callconv(.c) void,
    reset_command_pool: *const fn (Device, CommandPool, Flags) callconv(.c) Result,
    allocate_command_buffers: *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(.c) Result,
    free_command_buffers: *const fn (Device, CommandPool, u32, [*]const CommandBuffer) callconv(.c) void,
    begin_command_buffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) Result,
    end_command_buffer: *const fn (CommandBuffer) callconv(.c) Result,
    reset_command_buffer: *const fn (CommandBuffer, Flags) callconv(.c) Result,
    cmd_pipeline_barrier_2: *const fn (CommandBuffer, *const DependencyInfo) callconv(.c) void,
    cmd_begin_rendering: *const fn (CommandBuffer, *const RenderingInfo) callconv(.c) void,
    cmd_end_rendering: *const fn (CommandBuffer) callconv(.c) void,
    cmd_copy_buffer: *const fn (CommandBuffer, Buffer, Buffer, u32, [*]const BufferCopy) callconv(.c) void,
    cmd_copy_buffer_to_image: *const fn (CommandBuffer, Buffer, Image, i32, u32, [*]const BufferImageCopy) callconv(.c) void,
    cmd_copy_image_to_buffer: *const fn (CommandBuffer, Image, i32, Buffer, u32, [*]const BufferImageCopy) callconv(.c) void,
    cmd_copy_image: *const fn (CommandBuffer, Image, i32, Image, i32, u32, [*]const ImageCopy) callconv(.c) void,
    cmd_bind_pipeline: *const fn (CommandBuffer, i32, Pipeline) callconv(.c) void,
    cmd_bind_descriptor_sets: *const fn (CommandBuffer, i32, PipelineLayout, u32, u32, [*]const DescriptorSet, u32, ?[*]const u32) callconv(.c) void,
    cmd_push_constants: *const fn (CommandBuffer, PipelineLayout, Flags, u32, u32, *const anyopaque) callconv(.c) void,
    cmd_set_viewport: *const fn (CommandBuffer, u32, u32, [*]const Viewport) callconv(.c) void,
    cmd_set_scissor: *const fn (CommandBuffer, u32, u32, [*]const Rect2D) callconv(.c) void,
    cmd_bind_vertex_buffers: *const fn (CommandBuffer, u32, u32, [*]const Buffer, [*]const DeviceSize) callconv(.c) void,
    cmd_bind_index_buffer: *const fn (CommandBuffer, Buffer, DeviceSize, i32) callconv(.c) void,
    cmd_draw: *const fn (CommandBuffer, u32, u32, u32, u32) callconv(.c) void,
    cmd_draw_indexed: *const fn (CommandBuffer, u32, u32, u32, i32, u32) callconv(.c) void,
    create_buffer: *const fn (Device, *const BufferCreateInfo, ?*const anyopaque, *Buffer) callconv(.c) Result,
    destroy_buffer: *const fn (Device, Buffer, ?*const anyopaque) callconv(.c) void,
    get_buffer_memory_requirements: *const fn (Device, Buffer, *MemoryRequirements) callconv(.c) void,
    bind_buffer_memory: *const fn (Device, Buffer, DeviceMemory, DeviceSize) callconv(.c) Result,
    create_image: *const fn (Device, *const ImageCreateInfo, ?*const anyopaque, *Image) callconv(.c) Result,
    destroy_image: *const fn (Device, Image, ?*const anyopaque) callconv(.c) void,
    get_image_memory_requirements: *const fn (Device, Image, *MemoryRequirements) callconv(.c) void,
    get_image_memory_requirements_2: *const fn (Device, *const ImageMemoryRequirementsInfo2, *MemoryRequirements2) callconv(.c) void,
    bind_image_memory: *const fn (Device, Image, DeviceMemory, DeviceSize) callconv(.c) Result,
    get_image_subresource_layout: *const fn (Device, Image, *const ImageSubresource, *SubresourceLayout) callconv(.c) void,
    get_image_drm_format_modifier_properties: *const fn (Device, Image, *ImageDrmFormatModifierProperties) callconv(.c) Result,
    allocate_memory: *const fn (Device, *const MemoryAllocateInfo, ?*const anyopaque, *DeviceMemory) callconv(.c) Result,
    free_memory: *const fn (Device, DeviceMemory, ?*const anyopaque) callconv(.c) void,
    map_memory: *const fn (Device, DeviceMemory, DeviceSize, DeviceSize, Flags, *?*anyopaque) callconv(.c) Result,
    unmap_memory: *const fn (Device, DeviceMemory) callconv(.c) void,
    flush_mapped_memory_ranges: *const fn (Device, u32, [*]const MappedMemoryRange) callconv(.c) Result,
    invalidate_mapped_memory_ranges: *const fn (Device, u32, [*]const MappedMemoryRange) callconv(.c) Result,
    get_memory_fd: *const fn (Device, *const MemoryGetFdInfo, *i32) callconv(.c) Result,
    get_memory_fd_properties: *const fn (Device, Flags, i32, *MemoryFdProperties) callconv(.c) Result,
    create_image_view: *const fn (Device, *const ImageViewCreateInfo, ?*const anyopaque, *ImageView) callconv(.c) Result,
    destroy_image_view: *const fn (Device, ImageView, ?*const anyopaque) callconv(.c) void,
    create_sampler: *const fn (Device, *const SamplerCreateInfo, ?*const anyopaque, *Sampler) callconv(.c) Result,
    destroy_sampler: *const fn (Device, Sampler, ?*const anyopaque) callconv(.c) void,
    create_shader_module: *const fn (Device, *const ShaderModuleCreateInfo, ?*const anyopaque, *ShaderModule) callconv(.c) Result,
    destroy_shader_module: *const fn (Device, ShaderModule, ?*const anyopaque) callconv(.c) void,
    create_descriptor_set_layout: *const fn (Device, *const DescriptorSetLayoutCreateInfo, ?*const anyopaque, *DescriptorSetLayout) callconv(.c) Result,
    destroy_descriptor_set_layout: *const fn (Device, DescriptorSetLayout, ?*const anyopaque) callconv(.c) void,
    create_descriptor_pool: *const fn (Device, *const DescriptorPoolCreateInfo, ?*const anyopaque, *DescriptorPool) callconv(.c) Result,
    destroy_descriptor_pool: *const fn (Device, DescriptorPool, ?*const anyopaque) callconv(.c) void,
    reset_descriptor_pool: *const fn (Device, DescriptorPool, Flags) callconv(.c) Result,
    allocate_descriptor_sets: *const fn (Device, *const DescriptorSetAllocateInfo, [*]DescriptorSet) callconv(.c) Result,
    free_descriptor_sets: *const fn (Device, DescriptorPool, u32, [*]const DescriptorSet) callconv(.c) Result,
    update_descriptor_sets: *const fn (Device, u32, [*]const WriteDescriptorSet, u32, ?*const anyopaque) callconv(.c) void,
    create_pipeline_layout: *const fn (Device, *const PipelineLayoutCreateInfo, ?*const anyopaque, *PipelineLayout) callconv(.c) Result,
    destroy_pipeline_layout: *const fn (Device, PipelineLayout, ?*const anyopaque) callconv(.c) void,
    create_graphics_pipelines: *const fn (Device, PipelineCache, u32, [*]const GraphicsPipelineCreateInfo, ?*const anyopaque, [*]Pipeline) callconv(.c) Result,
    destroy_pipeline: *const fn (Device, Pipeline, ?*const anyopaque) callconv(.c) void,

    pub fn load(instance: InstanceDispatch, device: Device) !DeviceDispatch {
        const get = instance.get_device_proc_addr;
        const Loader = struct {
            fn one(comptime T: type, get_fn: GetDeviceProcAddr, value: Device, comptime name: [:0]const u8) !T {
                return loadProc(T, get_fn(value, name));
            }
        };
        return .{
            .destroy_device = try Loader.one(@FieldType(DeviceDispatch, "destroy_device"), get, device, "vkDestroyDevice"),
            .get_device_queue = try Loader.one(@FieldType(DeviceDispatch, "get_device_queue"), get, device, "vkGetDeviceQueue"),
            .device_wait_idle = try Loader.one(@FieldType(DeviceDispatch, "device_wait_idle"), get, device, "vkDeviceWaitIdle"),
            .queue_wait_idle = try Loader.one(@FieldType(DeviceDispatch, "queue_wait_idle"), get, device, "vkQueueWaitIdle"),
            .queue_submit_2 = try Loader.one(@FieldType(DeviceDispatch, "queue_submit_2"), get, device, "vkQueueSubmit2"),
            .create_fence = try Loader.one(@FieldType(DeviceDispatch, "create_fence"), get, device, "vkCreateFence"),
            .destroy_fence = try Loader.one(@FieldType(DeviceDispatch, "destroy_fence"), get, device, "vkDestroyFence"),
            .get_fence_status = try Loader.one(@FieldType(DeviceDispatch, "get_fence_status"), get, device, "vkGetFenceStatus"),
            .wait_for_fences = try Loader.one(@FieldType(DeviceDispatch, "wait_for_fences"), get, device, "vkWaitForFences"),
            .reset_fences = try Loader.one(@FieldType(DeviceDispatch, "reset_fences"), get, device, "vkResetFences"),
            .create_semaphore = try Loader.one(@FieldType(DeviceDispatch, "create_semaphore"), get, device, "vkCreateSemaphore"),
            .destroy_semaphore = try Loader.one(@FieldType(DeviceDispatch, "destroy_semaphore"), get, device, "vkDestroySemaphore"),
            .get_semaphore_counter_value = try Loader.one(@FieldType(DeviceDispatch, "get_semaphore_counter_value"), get, device, "vkGetSemaphoreCounterValue"),
            .get_semaphore_fd = try Loader.one(@FieldType(DeviceDispatch, "get_semaphore_fd"), get, device, "vkGetSemaphoreFdKHR"),
            .import_semaphore_fd = try Loader.one(@FieldType(DeviceDispatch, "import_semaphore_fd"), get, device, "vkImportSemaphoreFdKHR"),
            .create_command_pool = try Loader.one(@FieldType(DeviceDispatch, "create_command_pool"), get, device, "vkCreateCommandPool"),
            .destroy_command_pool = try Loader.one(@FieldType(DeviceDispatch, "destroy_command_pool"), get, device, "vkDestroyCommandPool"),
            .reset_command_pool = try Loader.one(@FieldType(DeviceDispatch, "reset_command_pool"), get, device, "vkResetCommandPool"),
            .allocate_command_buffers = try Loader.one(@FieldType(DeviceDispatch, "allocate_command_buffers"), get, device, "vkAllocateCommandBuffers"),
            .free_command_buffers = try Loader.one(@FieldType(DeviceDispatch, "free_command_buffers"), get, device, "vkFreeCommandBuffers"),
            .begin_command_buffer = try Loader.one(@FieldType(DeviceDispatch, "begin_command_buffer"), get, device, "vkBeginCommandBuffer"),
            .end_command_buffer = try Loader.one(@FieldType(DeviceDispatch, "end_command_buffer"), get, device, "vkEndCommandBuffer"),
            .reset_command_buffer = try Loader.one(@FieldType(DeviceDispatch, "reset_command_buffer"), get, device, "vkResetCommandBuffer"),
            .cmd_pipeline_barrier_2 = try Loader.one(@FieldType(DeviceDispatch, "cmd_pipeline_barrier_2"), get, device, "vkCmdPipelineBarrier2"),
            .cmd_begin_rendering = try Loader.one(@FieldType(DeviceDispatch, "cmd_begin_rendering"), get, device, "vkCmdBeginRendering"),
            .cmd_end_rendering = try Loader.one(@FieldType(DeviceDispatch, "cmd_end_rendering"), get, device, "vkCmdEndRendering"),
            .cmd_copy_buffer = try Loader.one(@FieldType(DeviceDispatch, "cmd_copy_buffer"), get, device, "vkCmdCopyBuffer"),
            .cmd_copy_buffer_to_image = try Loader.one(@FieldType(DeviceDispatch, "cmd_copy_buffer_to_image"), get, device, "vkCmdCopyBufferToImage"),
            .cmd_copy_image_to_buffer = try Loader.one(@FieldType(DeviceDispatch, "cmd_copy_image_to_buffer"), get, device, "vkCmdCopyImageToBuffer"),
            .cmd_copy_image = try Loader.one(@FieldType(DeviceDispatch, "cmd_copy_image"), get, device, "vkCmdCopyImage"),
            .cmd_bind_pipeline = try Loader.one(@FieldType(DeviceDispatch, "cmd_bind_pipeline"), get, device, "vkCmdBindPipeline"),
            .cmd_bind_descriptor_sets = try Loader.one(@FieldType(DeviceDispatch, "cmd_bind_descriptor_sets"), get, device, "vkCmdBindDescriptorSets"),
            .cmd_push_constants = try Loader.one(@FieldType(DeviceDispatch, "cmd_push_constants"), get, device, "vkCmdPushConstants"),
            .cmd_set_viewport = try Loader.one(@FieldType(DeviceDispatch, "cmd_set_viewport"), get, device, "vkCmdSetViewport"),
            .cmd_set_scissor = try Loader.one(@FieldType(DeviceDispatch, "cmd_set_scissor"), get, device, "vkCmdSetScissor"),
            .cmd_bind_vertex_buffers = try Loader.one(@FieldType(DeviceDispatch, "cmd_bind_vertex_buffers"), get, device, "vkCmdBindVertexBuffers"),
            .cmd_bind_index_buffer = try Loader.one(@FieldType(DeviceDispatch, "cmd_bind_index_buffer"), get, device, "vkCmdBindIndexBuffer"),
            .cmd_draw = try Loader.one(@FieldType(DeviceDispatch, "cmd_draw"), get, device, "vkCmdDraw"),
            .cmd_draw_indexed = try Loader.one(@FieldType(DeviceDispatch, "cmd_draw_indexed"), get, device, "vkCmdDrawIndexed"),
            .create_buffer = try Loader.one(@FieldType(DeviceDispatch, "create_buffer"), get, device, "vkCreateBuffer"),
            .destroy_buffer = try Loader.one(@FieldType(DeviceDispatch, "destroy_buffer"), get, device, "vkDestroyBuffer"),
            .get_buffer_memory_requirements = try Loader.one(@FieldType(DeviceDispatch, "get_buffer_memory_requirements"), get, device, "vkGetBufferMemoryRequirements"),
            .bind_buffer_memory = try Loader.one(@FieldType(DeviceDispatch, "bind_buffer_memory"), get, device, "vkBindBufferMemory"),
            .create_image = try Loader.one(@FieldType(DeviceDispatch, "create_image"), get, device, "vkCreateImage"),
            .destroy_image = try Loader.one(@FieldType(DeviceDispatch, "destroy_image"), get, device, "vkDestroyImage"),
            .get_image_memory_requirements = try Loader.one(@FieldType(DeviceDispatch, "get_image_memory_requirements"), get, device, "vkGetImageMemoryRequirements"),
            .get_image_memory_requirements_2 = try Loader.one(@FieldType(DeviceDispatch, "get_image_memory_requirements_2"), get, device, "vkGetImageMemoryRequirements2"),
            .bind_image_memory = try Loader.one(@FieldType(DeviceDispatch, "bind_image_memory"), get, device, "vkBindImageMemory"),
            .get_image_subresource_layout = try Loader.one(@FieldType(DeviceDispatch, "get_image_subresource_layout"), get, device, "vkGetImageSubresourceLayout"),
            .get_image_drm_format_modifier_properties = try Loader.one(@FieldType(DeviceDispatch, "get_image_drm_format_modifier_properties"), get, device, "vkGetImageDrmFormatModifierPropertiesEXT"),
            .allocate_memory = try Loader.one(@FieldType(DeviceDispatch, "allocate_memory"), get, device, "vkAllocateMemory"),
            .free_memory = try Loader.one(@FieldType(DeviceDispatch, "free_memory"), get, device, "vkFreeMemory"),
            .map_memory = try Loader.one(@FieldType(DeviceDispatch, "map_memory"), get, device, "vkMapMemory"),
            .unmap_memory = try Loader.one(@FieldType(DeviceDispatch, "unmap_memory"), get, device, "vkUnmapMemory"),
            .flush_mapped_memory_ranges = try Loader.one(@FieldType(DeviceDispatch, "flush_mapped_memory_ranges"), get, device, "vkFlushMappedMemoryRanges"),
            .invalidate_mapped_memory_ranges = try Loader.one(@FieldType(DeviceDispatch, "invalidate_mapped_memory_ranges"), get, device, "vkInvalidateMappedMemoryRanges"),
            .get_memory_fd = try Loader.one(@FieldType(DeviceDispatch, "get_memory_fd"), get, device, "vkGetMemoryFdKHR"),
            .get_memory_fd_properties = try Loader.one(@FieldType(DeviceDispatch, "get_memory_fd_properties"), get, device, "vkGetMemoryFdPropertiesKHR"),
            .create_image_view = try Loader.one(@FieldType(DeviceDispatch, "create_image_view"), get, device, "vkCreateImageView"),
            .destroy_image_view = try Loader.one(@FieldType(DeviceDispatch, "destroy_image_view"), get, device, "vkDestroyImageView"),
            .create_sampler = try Loader.one(@FieldType(DeviceDispatch, "create_sampler"), get, device, "vkCreateSampler"),
            .destroy_sampler = try Loader.one(@FieldType(DeviceDispatch, "destroy_sampler"), get, device, "vkDestroySampler"),
            .create_shader_module = try Loader.one(@FieldType(DeviceDispatch, "create_shader_module"), get, device, "vkCreateShaderModule"),
            .destroy_shader_module = try Loader.one(@FieldType(DeviceDispatch, "destroy_shader_module"), get, device, "vkDestroyShaderModule"),
            .create_descriptor_set_layout = try Loader.one(@FieldType(DeviceDispatch, "create_descriptor_set_layout"), get, device, "vkCreateDescriptorSetLayout"),
            .destroy_descriptor_set_layout = try Loader.one(@FieldType(DeviceDispatch, "destroy_descriptor_set_layout"), get, device, "vkDestroyDescriptorSetLayout"),
            .create_descriptor_pool = try Loader.one(@FieldType(DeviceDispatch, "create_descriptor_pool"), get, device, "vkCreateDescriptorPool"),
            .destroy_descriptor_pool = try Loader.one(@FieldType(DeviceDispatch, "destroy_descriptor_pool"), get, device, "vkDestroyDescriptorPool"),
            .reset_descriptor_pool = try Loader.one(@FieldType(DeviceDispatch, "reset_descriptor_pool"), get, device, "vkResetDescriptorPool"),
            .allocate_descriptor_sets = try Loader.one(@FieldType(DeviceDispatch, "allocate_descriptor_sets"), get, device, "vkAllocateDescriptorSets"),
            .free_descriptor_sets = try Loader.one(@FieldType(DeviceDispatch, "free_descriptor_sets"), get, device, "vkFreeDescriptorSets"),
            .update_descriptor_sets = try Loader.one(@FieldType(DeviceDispatch, "update_descriptor_sets"), get, device, "vkUpdateDescriptorSets"),
            .create_pipeline_layout = try Loader.one(@FieldType(DeviceDispatch, "create_pipeline_layout"), get, device, "vkCreatePipelineLayout"),
            .destroy_pipeline_layout = try Loader.one(@FieldType(DeviceDispatch, "destroy_pipeline_layout"), get, device, "vkDestroyPipelineLayout"),
            .create_graphics_pipelines = try Loader.one(@FieldType(DeviceDispatch, "create_graphics_pipelines"), get, device, "vkCreateGraphicsPipelines"),
            .destroy_pipeline = try Loader.one(@FieldType(DeviceDispatch, "destroy_pipeline"), get, device, "vkDestroyPipeline"),
        };
    }
};
