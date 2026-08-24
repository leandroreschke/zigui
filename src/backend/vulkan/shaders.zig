//! ZigUI's Vulkan shaders, authored through the in-tree SPIR-V writer.

const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const spv = @import("spirv.zig");

pub const Library = struct {
    vertex: []u32,
    color_fragment: []u32,
    monochrome_fragment: []u32,
    texture_fragment: []u32,
    composite_multiply_fragment: []u32,
    composite_screen_fragment: []u32,
    composite_overlay_fragment: []u32,
    composite_plus_fragment: []u32,
    external_p3_fragment: []u32,
    external_pq_fragment: []u32,
    external_hlg_fragment: []u32,

    pub fn build(allocator: std.mem.Allocator) Error!Library {
        const vertex = try buildVertex(allocator);
        errdefer allocator.free(vertex);
        const color_fragment = try buildColorFragment(allocator);
        errdefer allocator.free(color_fragment);
        const monochrome_fragment = try buildMonochromeFragment(allocator);
        errdefer allocator.free(monochrome_fragment);
        const texture_fragment = try buildTextureFragment(allocator);
        errdefer allocator.free(texture_fragment);
        const composite_multiply_fragment = try buildCompositeFragment(allocator, .multiply);
        errdefer allocator.free(composite_multiply_fragment);
        const composite_screen_fragment = try buildCompositeFragment(allocator, .screen);
        errdefer allocator.free(composite_screen_fragment);
        const composite_overlay_fragment = try buildCompositeFragment(allocator, .overlay);
        errdefer allocator.free(composite_overlay_fragment);
        const composite_plus_fragment = try buildCompositeFragment(allocator, .plus_lighter);
        errdefer allocator.free(composite_plus_fragment);
        const external_p3_fragment = try buildExternalFragment(allocator, .display_p3);
        errdefer allocator.free(external_p3_fragment);
        const external_pq_fragment = try buildExternalFragment(allocator, .rec2020_pq);
        errdefer allocator.free(external_pq_fragment);
        const external_hlg_fragment = try buildExternalFragment(allocator, .rec2020_hlg);
        return .{
            .vertex = vertex,
            .color_fragment = color_fragment,
            .monochrome_fragment = monochrome_fragment,
            .texture_fragment = texture_fragment,
            .composite_multiply_fragment = composite_multiply_fragment,
            .composite_screen_fragment = composite_screen_fragment,
            .composite_overlay_fragment = composite_overlay_fragment,
            .composite_plus_fragment = composite_plus_fragment,
            .external_p3_fragment = external_p3_fragment,
            .external_pq_fragment = external_pq_fragment,
            .external_hlg_fragment = external_hlg_fragment,
        };
    }

    pub fn deinit(self: *Library, allocator: std.mem.Allocator) void {
        allocator.free(self.vertex);
        allocator.free(self.color_fragment);
        allocator.free(self.monochrome_fragment);
        allocator.free(self.texture_fragment);
        allocator.free(self.composite_multiply_fragment);
        allocator.free(self.composite_screen_fragment);
        allocator.free(self.composite_overlay_fragment);
        allocator.free(self.composite_plus_fragment);
        allocator.free(self.external_p3_fragment);
        allocator.free(self.external_pq_fragment);
        allocator.free(self.external_hlg_fragment);
        self.* = undefined;
    }
};

const CommonTypes = struct {
    void_type: spv.Id,
    boolean: spv.Id,
    f32: spv.Id,
    vec2: spv.Id,
    vec3: spv.Id,
    vec4: spv.Id,
    fn_void: spv.Id,
    zero: spv.Id,
    one: spv.Id,
};

fn commonTypes(builder: *spv.Builder) Error!CommonTypes {
    const void_type = try builder.id();
    const boolean = try builder.id();
    const f32_type = try builder.id();
    const vec2 = try builder.id();
    const vec3 = try builder.id();
    const vec4 = try builder.id();
    const fn_void = try builder.id();
    const zero = try builder.id();
    const one = try builder.id();
    try builder.instruction(.declarations, .type_void, &.{void_type});
    try builder.instruction(.declarations, .type_bool, &.{boolean});
    try builder.instruction(.declarations, .type_float, &.{ f32_type, 32 });
    try builder.instruction(.declarations, .type_vector, &.{ vec2, f32_type, 2 });
    try builder.instruction(.declarations, .type_vector, &.{ vec3, f32_type, 3 });
    try builder.instruction(.declarations, .type_vector, &.{ vec4, f32_type, 4 });
    try builder.instruction(.declarations, .type_function, &.{ fn_void, void_type });
    try builder.instruction(.declarations, .constant, &.{ f32_type, zero, @bitCast(@as(f32, 0)) });
    try builder.instruction(.declarations, .constant, &.{ f32_type, one, @bitCast(@as(f32, 1)) });
    return .{ .void_type = void_type, .boolean = boolean, .f32 = f32_type, .vec2 = vec2, .vec3 = vec3, .vec4 = vec4, .fn_void = fn_void, .zero = zero, .one = one };
}

fn buildVertex(allocator: std.mem.Allocator) Error![]u32 {
    var builder = spv.Builder.init(allocator);
    defer builder.deinit();
    try builder.capability(spv.Capability.shader);
    try builder.memoryModel();
    const types = try commonTypes(&builder);

    const ptr_in_vec2 = try builder.id();
    const ptr_in_vec4 = try builder.id();
    const ptr_out_vec2 = try builder.id();
    const ptr_out_vec4 = try builder.id();
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec2, spv.StorageClass.input, types.vec2 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec4, spv.StorageClass.input, types.vec4 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_out_vec2, spv.StorageClass.output, types.vec2 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_out_vec4, spv.StorageClass.output, types.vec4 });

    const input_position = try builder.id();
    const input_color = try builder.id();
    const input_uv = try builder.id();
    const output_position = try builder.id();
    const output_color = try builder.id();
    const output_uv = try builder.id();
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec2, input_position, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec4, input_color, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec2, input_uv, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_out_vec4, output_position, spv.StorageClass.output });
    try builder.instruction(.declarations, .variable, &.{ ptr_out_vec4, output_color, spv.StorageClass.output });
    try builder.instruction(.declarations, .variable, &.{ ptr_out_vec2, output_uv, spv.StorageClass.output });
    try builder.decorate(input_position, spv.Decoration.location, &.{0});
    try builder.decorate(input_color, spv.Decoration.location, &.{1});
    try builder.decorate(input_uv, spv.Decoration.location, &.{2});
    try builder.decorate(output_position, spv.Decoration.built_in, &.{spv.BuiltIn.position});
    try builder.decorate(output_color, spv.Decoration.location, &.{0});
    try builder.decorate(output_uv, spv.Decoration.location, &.{1});

    const function = try builder.id();
    try builder.entryPoint(spv.ExecutionModel.vertex, function, "main", &.{ input_position, input_color, input_uv, output_position, output_color, output_uv });
    try builder.name(function, "main");

    const label = try builder.id();
    const position = try builder.id();
    const x = try builder.id();
    const y = try builder.id();
    const clip_position = try builder.id();
    const color = try builder.id();
    const uv = try builder.id();
    try builder.instruction(.functions, .function, &.{ types.void_type, function, spv.FunctionControl.none, types.fn_void });
    try builder.instruction(.functions, .label, &.{label});
    try builder.instruction(.functions, .load, &.{ types.vec2, position, input_position });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, x, position, 0 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, y, position, 1 });
    try builder.instruction(.functions, .composite_construct, &.{ types.vec4, clip_position, x, y, types.zero, types.one });
    try builder.instruction(.functions, .store, &.{ output_position, clip_position });
    try builder.instruction(.functions, .load, &.{ types.vec4, color, input_color });
    try builder.instruction(.functions, .store, &.{ output_color, color });
    try builder.instruction(.functions, .load, &.{ types.vec2, uv, input_uv });
    try builder.instruction(.functions, .store, &.{ output_uv, uv });
    try builder.instruction(.functions, .return_, &.{});
    try builder.instruction(.functions, .function_end, &.{});
    return builder.finish(allocator);
}

fn buildMonochromeFragment(allocator: std.mem.Allocator) Error![]u32 {
    return buildSampledFragment(allocator, true);
}

fn buildColorFragment(allocator: std.mem.Allocator) Error![]u32 {
    var builder = spv.Builder.init(allocator);
    defer builder.deinit();
    try builder.capability(spv.Capability.shader);
    try builder.memoryModel();
    const types = try commonTypes(&builder);
    const ptr_in_vec4 = try builder.id();
    const ptr_out_vec4 = try builder.id();
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec4, spv.StorageClass.input, types.vec4 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_out_vec4, spv.StorageClass.output, types.vec4 });
    const input_color = try builder.id();
    const output_color = try builder.id();
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec4, input_color, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_out_vec4, output_color, spv.StorageClass.output });
    try builder.decorate(input_color, spv.Decoration.location, &.{0});
    try builder.decorate(output_color, spv.Decoration.location, &.{0});
    const function = try builder.id();
    try builder.entryPoint(spv.ExecutionModel.fragment, function, "main", &.{ input_color, output_color });
    try builder.executionMode(function, spv.ExecutionMode.origin_upper_left, &.{});
    const label = try builder.id();
    const color = try builder.id();
    const red = try builder.id();
    const green = try builder.id();
    const blue = try builder.id();
    const alpha = try builder.id();
    const premultiplied_red = try builder.id();
    const premultiplied_green = try builder.id();
    const premultiplied_blue = try builder.id();
    const premultiplied = try builder.id();
    try builder.instruction(.functions, .function, &.{ types.void_type, function, spv.FunctionControl.none, types.fn_void });
    try builder.instruction(.functions, .label, &.{label});
    try builder.instruction(.functions, .load, &.{ types.vec4, color, input_color });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, red, color, 0 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, green, color, 1 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, blue, color, 2 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, alpha, color, 3 });
    try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_red, red, alpha });
    try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_green, green, alpha });
    try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_blue, blue, alpha });
    try builder.instruction(.functions, .composite_construct, &.{ types.vec4, premultiplied, premultiplied_red, premultiplied_green, premultiplied_blue, alpha });
    try builder.instruction(.functions, .store, &.{ output_color, premultiplied });
    try builder.instruction(.functions, .return_, &.{});
    try builder.instruction(.functions, .function_end, &.{});
    return builder.finish(allocator);
}

fn buildTextureFragment(allocator: std.mem.Allocator) Error![]u32 {
    return buildSampledFragment(allocator, false);
}

fn buildSampledFragment(allocator: std.mem.Allocator, monochrome: bool) Error![]u32 {
    var builder = spv.Builder.init(allocator);
    defer builder.deinit();
    try builder.capability(spv.Capability.shader);
    try builder.memoryModel();
    const types = try commonTypes(&builder);

    const image_type = try builder.id();
    const sampled_image_type = try builder.id();
    const ptr_uniform_image = try builder.id();
    const ptr_in_vec4 = try builder.id();
    const ptr_in_vec2 = try builder.id();
    const ptr_out_vec4 = try builder.id();
    try builder.instruction(.declarations, .type_image, &.{ image_type, types.f32, spv.Dim.two_d, 0, 0, 0, 1, spv.ImageFormat.unknown });
    try builder.instruction(.declarations, .type_sampled_image, &.{ sampled_image_type, image_type });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_uniform_image, spv.StorageClass.uniform_constant, sampled_image_type });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec4, spv.StorageClass.input, types.vec4 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec2, spv.StorageClass.input, types.vec2 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_out_vec4, spv.StorageClass.output, types.vec4 });

    const image_variable = try builder.id();
    const input_color = try builder.id();
    const input_uv = try builder.id();
    const output_color = try builder.id();
    try builder.instruction(.declarations, .variable, &.{ ptr_uniform_image, image_variable, spv.StorageClass.uniform_constant });
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec4, input_color, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec2, input_uv, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_out_vec4, output_color, spv.StorageClass.output });
    try builder.decorate(image_variable, spv.Decoration.descriptor_set, &.{0});
    try builder.decorate(image_variable, spv.Decoration.binding, &.{0});
    try builder.decorate(input_color, spv.Decoration.location, &.{0});
    try builder.decorate(input_uv, spv.Decoration.location, &.{1});
    try builder.decorate(output_color, spv.Decoration.location, &.{0});

    const function = try builder.id();
    try builder.entryPoint(spv.ExecutionModel.fragment, function, "main", &.{ input_color, input_uv, output_color });
    try builder.executionMode(function, spv.ExecutionMode.origin_upper_left, &.{});
    const label = try builder.id();
    const sampled_image = try builder.id();
    const uv = try builder.id();
    const sampled = try builder.id();
    const tint = try builder.id();
    const sampled_red = try builder.id();
    const sampled_green = try builder.id();
    const sampled_blue = try builder.id();
    const sampled_alpha = try builder.id();
    const tint_red = try builder.id();
    const tint_green = try builder.id();
    const tint_blue = try builder.id();
    const tint_alpha = try builder.id();
    const alpha = try builder.id();
    const tinted_red = try builder.id();
    const tinted_green = try builder.id();
    const tinted_blue = try builder.id();
    const premultiplied_red = try builder.id();
    const premultiplied_green = try builder.id();
    const premultiplied_blue = try builder.id();
    const result = try builder.id();
    try builder.instruction(.functions, .function, &.{ types.void_type, function, spv.FunctionControl.none, types.fn_void });
    try builder.instruction(.functions, .label, &.{label});
    try builder.instruction(.functions, .load, &.{ sampled_image_type, sampled_image, image_variable });
    try builder.instruction(.functions, .load, &.{ types.vec2, uv, input_uv });
    try builder.instruction(.functions, .image_sample_implicit_lod, &.{ types.vec4, sampled, sampled_image, uv });
    try builder.instruction(.functions, .load, &.{ types.vec4, tint, input_color });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, sampled_red, sampled, 0 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, sampled_green, sampled, 1 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, sampled_blue, sampled, 2 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, sampled_alpha, sampled, 3 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, tint_red, tint, 0 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, tint_green, tint, 1 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, tint_blue, tint, 2 });
    try builder.instruction(.functions, .composite_extract, &.{ types.f32, tint_alpha, tint, 3 });
    try builder.instruction(.functions, .f_mul, &.{ types.f32, alpha, if (monochrome) sampled_red else sampled_alpha, tint_alpha });
    if (monochrome) {
        try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_red, tint_red, alpha });
        try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_green, tint_green, alpha });
        try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_blue, tint_blue, alpha });
    } else {
        try builder.instruction(.functions, .f_mul, &.{ types.f32, tinted_red, sampled_red, tint_red });
        try builder.instruction(.functions, .f_mul, &.{ types.f32, tinted_green, sampled_green, tint_green });
        try builder.instruction(.functions, .f_mul, &.{ types.f32, tinted_blue, sampled_blue, tint_blue });
        try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_red, tinted_red, alpha });
        try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_green, tinted_green, alpha });
        try builder.instruction(.functions, .f_mul, &.{ types.f32, premultiplied_blue, tinted_blue, alpha });
    }
    try builder.instruction(.functions, .composite_construct, &.{ types.vec4, result, premultiplied_red, premultiplied_green, premultiplied_blue, alpha });
    try builder.instruction(.functions, .store, &.{ output_color, result });
    try builder.instruction(.functions, .return_, &.{});
    try builder.instruction(.functions, .function_end, &.{});
    return builder.finish(allocator);
}

const CompositeMode = enum { multiply, screen, overlay, plus_lighter };

fn scalarBinary(builder: *spv.Builder, op: spv.Op, float_type: spv.Id, lhs: spv.Id, rhs: spv.Id) Error!spv.Id {
    const result = try builder.id();
    try builder.instruction(.functions, op, &.{ float_type, result, lhs, rhs });
    return result;
}

fn scalarSelect(
    builder: *spv.Builder,
    float_type: spv.Id,
    condition: spv.Id,
    when_true: spv.Id,
    when_false: spv.Id,
) Error!spv.Id {
    const result = try builder.id();
    try builder.instruction(.functions, .select, &.{ float_type, result, condition, when_true, when_false });
    return result;
}

fn scalarCompare(
    builder: *spv.Builder,
    op: spv.Op,
    boolean_type: spv.Id,
    lhs: spv.Id,
    rhs: spv.Id,
) Error!spv.Id {
    const result = try builder.id();
    try builder.instruction(.functions, op, &.{ boolean_type, result, lhs, rhs });
    return result;
}

fn scalarClamp(
    builder: *spv.Builder,
    glsl: spv.Id,
    float_type: spv.Id,
    value: spv.Id,
    lower: spv.Id,
    upper: spv.Id,
) Error!spv.Id {
    const result = try builder.id();
    try builder.instruction(.functions, .ext_inst, &.{ float_type, result, glsl, spv.Glsl450.clamp, value, lower, upper });
    return result;
}

fn scalarExt1(builder: *spv.Builder, glsl: spv.Id, operation: u32, float_type: spv.Id, value: spv.Id) Error!spv.Id {
    const result = try builder.id();
    try builder.instruction(.functions, .ext_inst, &.{ float_type, result, glsl, operation, value });
    return result;
}

fn scalarExt2(
    builder: *spv.Builder,
    glsl: spv.Id,
    operation: u32,
    float_type: spv.Id,
    lhs: spv.Id,
    rhs: spv.Id,
) Error!spv.Id {
    const result = try builder.id();
    try builder.instruction(.functions, .ext_inst, &.{ float_type, result, glsl, operation, lhs, rhs });
    return result;
}

fn blendChannel(
    builder: *spv.Builder,
    mode: CompositeMode,
    types: CommonTypes,
    half: spv.Id,
    two: spv.Id,
    source: spv.Id,
    backdrop: spv.Id,
) Error!spv.Id {
    return switch (mode) {
        .multiply => scalarBinary(builder, .f_mul, types.f32, source, backdrop),
        .screen => blk: {
            const sum = try scalarBinary(builder, .f_add, types.f32, source, backdrop);
            const product = try scalarBinary(builder, .f_mul, types.f32, source, backdrop);
            break :blk try scalarBinary(builder, .f_sub, types.f32, sum, product);
        },
        .overlay => blk: {
            const product = try scalarBinary(builder, .f_mul, types.f32, source, backdrop);
            const low = try scalarBinary(builder, .f_mul, types.f32, two, product);
            const one_minus_source = try scalarBinary(builder, .f_sub, types.f32, types.one, source);
            const one_minus_backdrop = try scalarBinary(builder, .f_sub, types.f32, types.one, backdrop);
            const high_product = try scalarBinary(builder, .f_mul, types.f32, one_minus_source, one_minus_backdrop);
            const doubled = try scalarBinary(builder, .f_mul, types.f32, two, high_product);
            const high = try scalarBinary(builder, .f_sub, types.f32, types.one, doubled);
            const lower_half = try scalarCompare(builder, .f_ord_less_than, types.boolean, backdrop, half);
            break :blk try scalarSelect(builder, types.f32, lower_half, low, high);
        },
        .plus_lighter => unreachable,
    };
}

fn buildCompositeFragment(allocator: std.mem.Allocator, mode: CompositeMode) Error![]u32 {
    var builder = spv.Builder.init(allocator);
    defer builder.deinit();
    try builder.capability(spv.Capability.shader);
    try builder.memoryModel();
    const glsl = try builder.importGlsl450();
    const types = try commonTypes(&builder);

    const half = try builder.id();
    const two = try builder.id();
    const epsilon = try builder.id();
    try builder.instruction(.declarations, .constant, &.{ types.f32, half, @bitCast(@as(f32, 0.5)) });
    try builder.instruction(.declarations, .constant, &.{ types.f32, two, @bitCast(@as(f32, 2)) });
    try builder.instruction(.declarations, .constant, &.{ types.f32, epsilon, @bitCast(@as(f32, 0.000001)) });

    const image_type = try builder.id();
    const sampled_image_type = try builder.id();
    const ptr_uniform_image = try builder.id();
    const ptr_in_vec4 = try builder.id();
    const ptr_in_vec2 = try builder.id();
    const ptr_out_vec4 = try builder.id();
    try builder.instruction(.declarations, .type_image, &.{ image_type, types.f32, spv.Dim.two_d, 0, 0, 0, 1, spv.ImageFormat.unknown });
    try builder.instruction(.declarations, .type_sampled_image, &.{ sampled_image_type, image_type });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_uniform_image, spv.StorageClass.uniform_constant, sampled_image_type });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec4, spv.StorageClass.input, types.vec4 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec2, spv.StorageClass.input, types.vec2 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_out_vec4, spv.StorageClass.output, types.vec4 });

    const source_variable = try builder.id();
    const backdrop_variable = try builder.id();
    const input_color = try builder.id();
    const input_uv = try builder.id();
    const output_color = try builder.id();
    try builder.instruction(.declarations, .variable, &.{ ptr_uniform_image, source_variable, spv.StorageClass.uniform_constant });
    try builder.instruction(.declarations, .variable, &.{ ptr_uniform_image, backdrop_variable, spv.StorageClass.uniform_constant });
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec4, input_color, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec2, input_uv, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_out_vec4, output_color, spv.StorageClass.output });
    try builder.decorate(source_variable, spv.Decoration.descriptor_set, &.{0});
    try builder.decorate(source_variable, spv.Decoration.binding, &.{0});
    try builder.decorate(backdrop_variable, spv.Decoration.descriptor_set, &.{0});
    try builder.decorate(backdrop_variable, spv.Decoration.binding, &.{1});
    try builder.decorate(input_color, spv.Decoration.location, &.{0});
    try builder.decorate(input_uv, spv.Decoration.location, &.{1});
    try builder.decorate(output_color, spv.Decoration.location, &.{0});

    const function = try builder.id();
    try builder.entryPoint(spv.ExecutionModel.fragment, function, "main", &.{ source_variable, backdrop_variable, input_color, input_uv, output_color });
    try builder.executionMode(function, spv.ExecutionMode.origin_upper_left, &.{});
    const label = try builder.id();
    try builder.instruction(.functions, .function, &.{ types.void_type, function, spv.FunctionControl.none, types.fn_void });
    try builder.instruction(.functions, .label, &.{label});

    const source_image = try builder.id();
    const backdrop_image = try builder.id();
    const uv = try builder.id();
    const sampled_source = try builder.id();
    const sampled_backdrop = try builder.id();
    const tint = try builder.id();
    try builder.instruction(.functions, .load, &.{ sampled_image_type, source_image, source_variable });
    try builder.instruction(.functions, .load, &.{ sampled_image_type, backdrop_image, backdrop_variable });
    try builder.instruction(.functions, .load, &.{ types.vec2, uv, input_uv });
    try builder.instruction(.functions, .image_sample_implicit_lod, &.{ types.vec4, sampled_source, source_image, uv });
    try builder.instruction(.functions, .image_sample_implicit_lod, &.{ types.vec4, sampled_backdrop, backdrop_image, uv });
    try builder.instruction(.functions, .load, &.{ types.vec4, tint, input_color });

    var source: [4]spv.Id = undefined;
    var backdrop: [4]spv.Id = undefined;
    for (0..4) |index| {
        const raw_source = try builder.id();
        backdrop[index] = try builder.id();
        try builder.instruction(.functions, .composite_extract, &.{ types.f32, raw_source, sampled_source, @intCast(index) });
        try builder.instruction(.functions, .composite_extract, &.{ types.f32, backdrop[index], sampled_backdrop, @intCast(index) });
        if (index == 3) {
            const opacity = try builder.id();
            try builder.instruction(.functions, .composite_extract, &.{ types.f32, opacity, tint, 3 });
            source[index] = try scalarBinary(&builder, .f_mul, types.f32, raw_source, opacity);
        } else {
            const opacity = try builder.id();
            try builder.instruction(.functions, .composite_extract, &.{ types.f32, opacity, tint, 3 });
            source[index] = try scalarBinary(&builder, .f_mul, types.f32, raw_source, opacity);
        }
    }

    var output: [4]spv.Id = undefined;
    if (mode == .plus_lighter) {
        for (0..4) |index| {
            const sum = try scalarBinary(&builder, .f_add, types.f32, source[index], backdrop[index]);
            output[index] = try scalarClamp(&builder, glsl, types.f32, sum, types.zero, types.one);
        }
    } else {
        const source_has_alpha = try scalarCompare(&builder, .f_ord_greater_than, types.boolean, source[3], epsilon);
        const backdrop_has_alpha = try scalarCompare(&builder, .f_ord_greater_than, types.boolean, backdrop[3], epsilon);
        const safe_source_alpha = try scalarSelect(&builder, types.f32, source_has_alpha, source[3], types.one);
        const safe_backdrop_alpha = try scalarSelect(&builder, types.f32, backdrop_has_alpha, backdrop[3], types.one);
        const one_minus_source_alpha = try scalarBinary(&builder, .f_sub, types.f32, types.one, source[3]);
        const one_minus_backdrop_alpha = try scalarBinary(&builder, .f_sub, types.f32, types.one, backdrop[3]);
        const alpha_product = try scalarBinary(&builder, .f_mul, types.f32, source[3], backdrop[3]);
        for (0..3) |index| {
            const unpremultiplied_source = try scalarBinary(&builder, .f_div, types.f32, source[index], safe_source_alpha);
            const unpremultiplied_backdrop = try scalarBinary(&builder, .f_div, types.f32, backdrop[index], safe_backdrop_alpha);
            const blended = try blendChannel(&builder, mode, types, half, two, unpremultiplied_source, unpremultiplied_backdrop);
            const uncovered_source = try scalarBinary(&builder, .f_mul, types.f32, one_minus_backdrop_alpha, source[index]);
            const uncovered_backdrop = try scalarBinary(&builder, .f_mul, types.f32, one_minus_source_alpha, backdrop[index]);
            const overlap = try scalarBinary(&builder, .f_mul, types.f32, alpha_product, blended);
            const partial = try scalarBinary(&builder, .f_add, types.f32, uncovered_source, uncovered_backdrop);
            const combined = try scalarBinary(&builder, .f_add, types.f32, partial, overlap);
            output[index] = try scalarClamp(&builder, glsl, types.f32, combined, types.zero, types.one);
        }
        const alpha_sum = try scalarBinary(&builder, .f_add, types.f32, source[3], backdrop[3]);
        const alpha = try scalarBinary(&builder, .f_sub, types.f32, alpha_sum, alpha_product);
        output[3] = try scalarClamp(&builder, glsl, types.f32, alpha, types.zero, types.one);
    }

    const result = try builder.id();
    try builder.instruction(.functions, .composite_construct, &.{ types.vec4, result, output[0], output[1], output[2], output[3] });
    try builder.instruction(.functions, .store, &.{ output_color, result });
    try builder.instruction(.functions, .return_, &.{});
    try builder.instruction(.functions, .function_end, &.{});
    return builder.finish(allocator);
}

const ExternalMode = enum { display_p3, rec2020_pq, rec2020_hlg };

fn declareFloat(builder: *spv.Builder, float_type: spv.Id, value: f32) Error!spv.Id {
    const id = try builder.id();
    try builder.instruction(.declarations, .constant, &.{ float_type, id, @bitCast(value) });
    return id;
}

fn p3Channel(
    builder: *spv.Builder,
    glsl: spv.Id,
    types: CommonTypes,
    channels: [3]spv.Id,
    coefficients: [3]spv.Id,
) Error!spv.Id {
    const first = try scalarBinary(builder, .f_mul, types.f32, channels[0], coefficients[0]);
    const second = try scalarBinary(builder, .f_mul, types.f32, channels[1], coefficients[1]);
    const third = try scalarBinary(builder, .f_mul, types.f32, channels[2], coefficients[2]);
    const partial = try scalarBinary(builder, .f_add, types.f32, first, second);
    const result = try scalarBinary(builder, .f_add, types.f32, partial, third);
    return scalarExt2(builder, glsl, spv.Glsl450.max, types.f32, result, types.zero);
}

fn buildExternalFragment(allocator: std.mem.Allocator, mode: ExternalMode) Error![]u32 {
    var builder = spv.Builder.init(allocator);
    defer builder.deinit();
    try builder.capability(spv.Capability.shader);
    try builder.memoryModel();
    const glsl = try builder.importGlsl450();
    const types = try commonTypes(&builder);

    const image_type = try builder.id();
    const sampled_image_type = try builder.id();
    const ptr_uniform_image = try builder.id();
    const ptr_in_vec4 = try builder.id();
    const ptr_in_vec2 = try builder.id();
    const ptr_out_vec4 = try builder.id();
    try builder.instruction(.declarations, .type_image, &.{ image_type, types.f32, spv.Dim.two_d, 0, 0, 0, 1, spv.ImageFormat.unknown });
    try builder.instruction(.declarations, .type_sampled_image, &.{ sampled_image_type, image_type });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_uniform_image, spv.StorageClass.uniform_constant, sampled_image_type });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec4, spv.StorageClass.input, types.vec4 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_in_vec2, spv.StorageClass.input, types.vec2 });
    try builder.instruction(.declarations, .type_pointer, &.{ ptr_out_vec4, spv.StorageClass.output, types.vec4 });

    const image_variable = try builder.id();
    const input_color = try builder.id();
    const input_uv = try builder.id();
    const output_color = try builder.id();
    try builder.instruction(.declarations, .variable, &.{ ptr_uniform_image, image_variable, spv.StorageClass.uniform_constant });
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec4, input_color, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_in_vec2, input_uv, spv.StorageClass.input });
    try builder.instruction(.declarations, .variable, &.{ ptr_out_vec4, output_color, spv.StorageClass.output });
    try builder.decorate(image_variable, spv.Decoration.descriptor_set, &.{0});
    try builder.decorate(image_variable, spv.Decoration.binding, &.{0});
    try builder.decorate(input_color, spv.Decoration.location, &.{0});
    try builder.decorate(input_uv, spv.Decoration.location, &.{1});
    try builder.decorate(output_color, spv.Decoration.location, &.{0});

    const function = try builder.id();
    try builder.entryPoint(spv.ExecutionModel.fragment, function, "main", &.{ image_variable, input_color, input_uv, output_color });
    try builder.executionMode(function, spv.ExecutionMode.origin_upper_left, &.{});
    const label = try builder.id();
    try builder.instruction(.functions, .function, &.{ types.void_type, function, spv.FunctionControl.none, types.fn_void });
    try builder.instruction(.functions, .label, &.{label});
    const sampled_image = try builder.id();
    const uv = try builder.id();
    const sampled = try builder.id();
    const tint = try builder.id();
    try builder.instruction(.functions, .load, &.{ sampled_image_type, sampled_image, image_variable });
    try builder.instruction(.functions, .load, &.{ types.vec2, uv, input_uv });
    try builder.instruction(.functions, .image_sample_implicit_lod, &.{ types.vec4, sampled, sampled_image, uv });
    try builder.instruction(.functions, .load, &.{ types.vec4, tint, input_color });
    var channels: [4]spv.Id = undefined;
    var tint_channels: [4]spv.Id = undefined;
    for (0..4) |index| {
        channels[index] = try builder.id();
        tint_channels[index] = try builder.id();
        try builder.instruction(.functions, .composite_extract, &.{ types.f32, channels[index], sampled, @intCast(index) });
        try builder.instruction(.functions, .composite_extract, &.{ types.f32, tint_channels[index], tint, @intCast(index) });
    }

    var converted: [3]spv.Id = undefined;
    switch (mode) {
        .display_p3 => {
            const matrix = [3][3]spv.Id{
                .{ try declareFloat(&builder, types.f32, 1.224745), try declareFloat(&builder, types.f32, -0.224904), types.zero },
                .{ try declareFloat(&builder, types.f32, -0.042058), try declareFloat(&builder, types.f32, 1.042081), types.zero },
                .{ try declareFloat(&builder, types.f32, -0.019642), try declareFloat(&builder, types.f32, -0.078655), try declareFloat(&builder, types.f32, 1.098537) },
            };
            const rgb = [3]spv.Id{ channels[0], channels[1], channels[2] };
            for (0..3) |index| converted[index] = try p3Channel(&builder, glsl, types, rgb, matrix[index]);
        },
        .rec2020_pq => {
            const inverse_m2 = try declareFloat(&builder, types.f32, 1.0 / 78.84375);
            const c1 = try declareFloat(&builder, types.f32, 0.8359375);
            const c2 = try declareFloat(&builder, types.f32, 18.8515625);
            const c3 = try declareFloat(&builder, types.f32, 18.6875);
            const epsilon = try declareFloat(&builder, types.f32, 0.00001);
            const ten_thousand = try declareFloat(&builder, types.f32, 10000);
            const inverse_m1 = try declareFloat(&builder, types.f32, 1.0 / 0.1593017578);
            const reference_white = try declareFloat(&builder, types.f32, 203);
            for (0..3) |index| {
                const nonnegative = try scalarExt2(&builder, glsl, spv.Glsl450.max, types.f32, channels[index], types.zero);
                const powered = try scalarExt2(&builder, glsl, spv.Glsl450.pow, types.f32, nonnegative, inverse_m2);
                const numerator_raw = try scalarBinary(&builder, .f_sub, types.f32, powered, c1);
                const numerator = try scalarExt2(&builder, glsl, spv.Glsl450.max, types.f32, numerator_raw, types.zero);
                const c3_powered = try scalarBinary(&builder, .f_mul, types.f32, c3, powered);
                const denominator_raw = try scalarBinary(&builder, .f_sub, types.f32, c2, c3_powered);
                const denominator = try scalarExt2(&builder, glsl, spv.Glsl450.max, types.f32, denominator_raw, epsilon);
                const ratio = try scalarBinary(&builder, .f_div, types.f32, numerator, denominator);
                const raised = try scalarExt2(&builder, glsl, spv.Glsl450.pow, types.f32, ratio, inverse_m1);
                const nits = try scalarBinary(&builder, .f_mul, types.f32, ten_thousand, raised);
                const divisor = try scalarBinary(&builder, .f_add, types.f32, nits, reference_white);
                converted[index] = try scalarBinary(&builder, .f_div, types.f32, nits, divisor);
            }
        },
        .rec2020_hlg => {
            const three = try declareFloat(&builder, types.f32, 3);
            const half = try declareFloat(&builder, types.f32, 0.5);
            const offset = try declareFloat(&builder, types.f32, 0.55991073);
            const scale = try declareFloat(&builder, types.f32, 0.17883277);
            const bias = try declareFloat(&builder, types.f32, 0.28466892);
            const twelve = try declareFloat(&builder, types.f32, 12);
            for (0..3) |index| {
                const squared = try scalarBinary(&builder, .f_mul, types.f32, channels[index], channels[index]);
                const low = try scalarBinary(&builder, .f_div, types.f32, squared, three);
                const shifted = try scalarBinary(&builder, .f_sub, types.f32, channels[index], offset);
                const normalized = try scalarBinary(&builder, .f_div, types.f32, shifted, scale);
                const exponential = try scalarExt1(&builder, glsl, spv.Glsl450.exp, types.f32, normalized);
                const biased = try scalarBinary(&builder, .f_add, types.f32, exponential, bias);
                const high = try scalarBinary(&builder, .f_div, types.f32, biased, twelve);
                const upper_half = try scalarCompare(&builder, .f_ord_greater_than_equal, types.boolean, channels[index], half);
                const linear = try scalarSelect(&builder, types.f32, upper_half, high, low);
                const divisor = try scalarBinary(&builder, .f_add, types.f32, linear, types.one);
                converted[index] = try scalarBinary(&builder, .f_div, types.f32, linear, divisor);
            }
        },
    }

    const alpha = try scalarBinary(&builder, .f_mul, types.f32, channels[3], tint_channels[3]);
    var output_rgb: [3]spv.Id = undefined;
    for (0..3) |index| {
        const tinted = try scalarBinary(&builder, .f_mul, types.f32, converted[index], tint_channels[index]);
        output_rgb[index] = try scalarBinary(&builder, .f_mul, types.f32, tinted, alpha);
    }
    const result = try builder.id();
    try builder.instruction(.functions, .composite_construct, &.{ types.vec4, result, output_rgb[0], output_rgb[1], output_rgb[2], alpha });
    try builder.instruction(.functions, .store, &.{ output_color, result });
    try builder.instruction(.functions, .return_, &.{});
    try builder.instruction(.functions, .function_end, &.{});
    return builder.finish(allocator);
}
