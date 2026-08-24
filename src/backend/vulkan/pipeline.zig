const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const abi = @import("abi.zig");
const device_mod = @import("device.zig");
const shaders = @import("shaders.zig");

pub const Vertex = extern struct {
    position: [2]f32,
    color: [4]f32,
    uv: [2]f32 = .{ 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == 32);
    std.debug.assert(@offsetOf(Vertex, "position") == 0);
    std.debug.assert(@offsetOf(Vertex, "color") == 8);
    std.debug.assert(@offsetOf(Vertex, "uv") == 24);
}

pub const Pipelines = struct {
    descriptor_layout: abi.DescriptorSetLayout,
    layout: abi.PipelineLayout,
    sampler: abi.Sampler,
    color: abi.Pipeline,
    monochrome: abi.Pipeline,
    texture: abi.Pipeline,
    composite_multiply: abi.Pipeline,
    composite_screen: abi.Pipeline,
    composite_overlay: abi.Pipeline,
    composite_plus: abi.Pipeline,
    external_p3: abi.Pipeline,
    external_pq: abi.Pipeline,
    external_hlg: abi.Pipeline,

    pub fn create(context: *device_mod.Context, format: abi.Format) Error!Pipelines {
        const dispatch = context.device_dispatch;
        const device = context.device;
        const bindings = [_]abi.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = abi.descriptor_type_combined_image_sampler, .stage_flags = abi.shader_stage_fragment_bit },
            .{ .binding = 1, .descriptor_type = abi.descriptor_type_combined_image_sampler, .stage_flags = abi.shader_stage_fragment_bit },
        };
        const descriptor_info: abi.DescriptorSetLayoutCreateInfo = .{
            .binding_count = bindings.len,
            .bindings = &bindings,
        };
        var descriptor_layout: abi.DescriptorSetLayout = 0;
        try device_mod.check(dispatch.create_descriptor_set_layout(device, &descriptor_info, null, &descriptor_layout));
        errdefer dispatch.destroy_descriptor_set_layout(device, descriptor_layout, null);

        const layout_info: abi.PipelineLayoutCreateInfo = .{
            .set_layout_count = 1,
            .set_layouts = @ptrCast(&descriptor_layout),
        };
        var layout: abi.PipelineLayout = 0;
        try device_mod.check(dispatch.create_pipeline_layout(device, &layout_info, null, &layout));
        errdefer dispatch.destroy_pipeline_layout(device, layout, null);

        const sampler_info: abi.SamplerCreateInfo = .{};
        var sampler: abi.Sampler = 0;
        try device_mod.check(dispatch.create_sampler(device, &sampler_info, null, &sampler));
        errdefer dispatch.destroy_sampler(device, sampler, null);

        var source = try shaders.Library.build(context.allocator);
        defer source.deinit(context.allocator);
        const vertex_module = try createShader(context, source.vertex);
        defer dispatch.destroy_shader_module(device, vertex_module, null);
        const color_module = try createShader(context, source.color_fragment);
        defer dispatch.destroy_shader_module(device, color_module, null);
        const monochrome_module = try createShader(context, source.monochrome_fragment);
        defer dispatch.destroy_shader_module(device, monochrome_module, null);
        const texture_module = try createShader(context, source.texture_fragment);
        defer dispatch.destroy_shader_module(device, texture_module, null);
        const composite_multiply_module = try createShader(context, source.composite_multiply_fragment);
        defer dispatch.destroy_shader_module(device, composite_multiply_module, null);
        const composite_screen_module = try createShader(context, source.composite_screen_fragment);
        defer dispatch.destroy_shader_module(device, composite_screen_module, null);
        const composite_overlay_module = try createShader(context, source.composite_overlay_fragment);
        defer dispatch.destroy_shader_module(device, composite_overlay_module, null);
        const composite_plus_module = try createShader(context, source.composite_plus_fragment);
        defer dispatch.destroy_shader_module(device, composite_plus_module, null);
        const external_p3_module = try createShader(context, source.external_p3_fragment);
        defer dispatch.destroy_shader_module(device, external_p3_module, null);
        const external_pq_module = try createShader(context, source.external_pq_fragment);
        defer dispatch.destroy_shader_module(device, external_pq_module, null);
        const external_hlg_module = try createShader(context, source.external_hlg_fragment);
        defer dispatch.destroy_shader_module(device, external_hlg_module, null);

        const color = try createGraphicsPipeline(context, layout, format, vertex_module, color_module, true);
        errdefer dispatch.destroy_pipeline(device, color, null);
        const monochrome = try createGraphicsPipeline(context, layout, format, vertex_module, monochrome_module, true);
        errdefer dispatch.destroy_pipeline(device, monochrome, null);
        const texture = try createGraphicsPipeline(context, layout, format, vertex_module, texture_module, true);
        errdefer dispatch.destroy_pipeline(device, texture, null);
        const composite_multiply = try createGraphicsPipeline(context, layout, format, vertex_module, composite_multiply_module, false);
        errdefer dispatch.destroy_pipeline(device, composite_multiply, null);
        const composite_screen = try createGraphicsPipeline(context, layout, format, vertex_module, composite_screen_module, false);
        errdefer dispatch.destroy_pipeline(device, composite_screen, null);
        const composite_overlay = try createGraphicsPipeline(context, layout, format, vertex_module, composite_overlay_module, false);
        errdefer dispatch.destroy_pipeline(device, composite_overlay, null);
        const composite_plus = try createGraphicsPipeline(context, layout, format, vertex_module, composite_plus_module, false);
        errdefer dispatch.destroy_pipeline(device, composite_plus, null);
        const external_p3 = try createGraphicsPipeline(context, layout, format, vertex_module, external_p3_module, true);
        errdefer dispatch.destroy_pipeline(device, external_p3, null);
        const external_pq = try createGraphicsPipeline(context, layout, format, vertex_module, external_pq_module, true);
        errdefer dispatch.destroy_pipeline(device, external_pq, null);
        const external_hlg = try createGraphicsPipeline(context, layout, format, vertex_module, external_hlg_module, true);
        return .{
            .descriptor_layout = descriptor_layout,
            .layout = layout,
            .sampler = sampler,
            .color = color,
            .monochrome = monochrome,
            .texture = texture,
            .composite_multiply = composite_multiply,
            .composite_screen = composite_screen,
            .composite_overlay = composite_overlay,
            .composite_plus = composite_plus,
            .external_p3 = external_p3,
            .external_pq = external_pq,
            .external_hlg = external_hlg,
        };
    }

    pub fn deinit(self: *Pipelines, context: *device_mod.Context) void {
        const dispatch = context.device_dispatch;
        dispatch.destroy_pipeline(context.device, self.external_hlg, null);
        dispatch.destroy_pipeline(context.device, self.external_pq, null);
        dispatch.destroy_pipeline(context.device, self.external_p3, null);
        dispatch.destroy_pipeline(context.device, self.composite_plus, null);
        dispatch.destroy_pipeline(context.device, self.composite_overlay, null);
        dispatch.destroy_pipeline(context.device, self.composite_screen, null);
        dispatch.destroy_pipeline(context.device, self.composite_multiply, null);
        dispatch.destroy_pipeline(context.device, self.texture, null);
        dispatch.destroy_pipeline(context.device, self.monochrome, null);
        dispatch.destroy_pipeline(context.device, self.color, null);
        dispatch.destroy_sampler(context.device, self.sampler, null);
        dispatch.destroy_pipeline_layout(context.device, self.layout, null);
        dispatch.destroy_descriptor_set_layout(context.device, self.descriptor_layout, null);
        self.* = undefined;
    }
};

fn createShader(context: *device_mod.Context, words: []const u32) Error!abi.ShaderModule {
    if (words.len < 5 or words[0] != @import("spirv.zig").magic) return error.ShaderInvalid;
    const info: abi.ShaderModuleCreateInfo = .{
        .code_size = std.math.mul(usize, words.len, @sizeOf(u32)) catch return error.BudgetExceeded,
        .code = words.ptr,
    };
    var module: abi.ShaderModule = 0;
    const result = context.device_dispatch.create_shader_module(context.device, &info, null, &module);
    if (result != abi.success) return error.ShaderInvalid;
    return module;
}

fn createGraphicsPipeline(
    context: *device_mod.Context,
    layout: abi.PipelineLayout,
    format: abi.Format,
    vertex_module: abi.ShaderModule,
    fragment_module: abi.ShaderModule,
    source_over: bool,
) Error!abi.Pipeline {
    const stages = [_]abi.PipelineShaderStageCreateInfo{
        .{ .stage = abi.shader_stage_vertex_bit, .module = vertex_module, .name = "main" },
        .{ .stage = abi.shader_stage_fragment_bit, .module = fragment_module, .name = "main" },
    };
    const binding: abi.VertexInputBindingDescription = .{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = abi.vertex_input_rate_vertex,
    };
    const attributes = [_]abi.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = abi.format_r32g32_sfloat, .offset = @offsetOf(Vertex, "position") },
        .{ .location = 1, .binding = 0, .format = abi.format_r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "color") },
        .{ .location = 2, .binding = 0, .format = abi.format_r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
    };
    const vertex_input: abi.PipelineVertexInputStateCreateInfo = .{
        .vertex_binding_description_count = 1,
        .vertex_binding_descriptions = @ptrCast(&binding),
        .vertex_attribute_description_count = attributes.len,
        .vertex_attribute_descriptions = &attributes,
    };
    const input_assembly: abi.PipelineInputAssemblyStateCreateInfo = .{};
    const viewport: abi.PipelineViewportStateCreateInfo = .{};
    const rasterization: abi.PipelineRasterizationStateCreateInfo = .{};
    const multisample: abi.PipelineMultisampleStateCreateInfo = .{};
    const blend_attachment: abi.PipelineColorBlendAttachmentState = if (source_over)
        .{}
    else
        .{ .blend_enable = abi.vk_false };
    const blend: abi.PipelineColorBlendStateCreateInfo = .{
        .attachment_count = 1,
        .attachments = @ptrCast(&blend_attachment),
    };
    const dynamic_values = [_]i32{ abi.dynamic_state_viewport, abi.dynamic_state_scissor };
    const dynamic: abi.PipelineDynamicStateCreateInfo = .{
        .dynamic_state_count = dynamic_values.len,
        .dynamic_states = &dynamic_values,
    };
    const rendering: abi.PipelineRenderingCreateInfo = .{
        .color_attachment_count = 1,
        .color_attachment_formats = @ptrCast(&format),
    };
    const info: abi.GraphicsPipelineCreateInfo = .{
        .next = &rendering,
        .stage_count = stages.len,
        .stages = &stages,
        .vertex_input_state = &vertex_input,
        .input_assembly_state = &input_assembly,
        .viewport_state = &viewport,
        .rasterization_state = &rasterization,
        .multisample_state = &multisample,
        .color_blend_state = &blend,
        .dynamic_state = &dynamic,
        .layout = layout,
    };
    var pipeline: abi.Pipeline = 0;
    const result = context.device_dispatch.create_graphics_pipelines(context.device, 0, 1, @ptrCast(&info), null, @ptrCast(&pipeline));
    if (result != abi.success) return error.ShaderInvalid;
    return pipeline;
}
