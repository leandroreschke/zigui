const windows = @import("../../platform/windows/abi.zig");
pub const com = @import("../../platform/windows/com.zig");

pub const Object = com.Object;
pub const HRESULT = windows.HRESULT;
pub const HWND = windows.HWND;
pub const HMODULE = windows.HMODULE;

pub const Rational = extern struct { numerator: u32 = 0, denominator: u32 = 1 };
pub const ModeDesc = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    refresh_rate: Rational = .{},
    format: u32 = format_unknown,
    scanline_ordering: u32 = 0,
    scaling: u32 = 0,
};
pub const SampleDesc = extern struct { count: u32 = 1, quality: u32 = 0 };
pub const SwapChainDesc = extern struct {
    buffer_desc: ModeDesc,
    sample_desc: SampleDesc,
    buffer_usage: u32,
    buffer_count: u32,
    output_window: HWND,
    windowed: windows.BOOL,
    swap_effect: u32,
    flags: u32,
};

pub const BufferDesc = extern struct {
    byte_width: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
    structure_byte_stride: u32,
};

pub const Texture2DDesc = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32 = 1,
    array_size: u32 = 1,
    format: u32,
    sample_desc: SampleDesc = .{},
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
};

pub const SubresourceData = extern struct {
    system_memory: *const anyopaque,
    system_memory_pitch: u32,
    system_memory_slice_pitch: u32 = 0,
};

pub const MappedSubresource = extern struct {
    data: ?*anyopaque,
    row_pitch: u32,
    depth_pitch: u32,
};

pub const Box = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

pub const Viewport = extern struct {
    top_left_x: f32 = 0,
    top_left_y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};

pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const QueryDesc = extern struct { query: u32, misc_flags: u32 = 0 };

pub const ShaderResourceViewDesc = extern struct {
    format: u32,
    view_dimension: u32,
    data: [4]u32 = .{ 0, 0, 0, 0 },

    pub fn buffer(elements: u32) ShaderResourceViewDesc {
        return .{ .format = format_unknown, .view_dimension = srv_dimension_buffer, .data = .{ 0, elements, 0, 0 } };
    }

    pub fn texture2D(format: u32) ShaderResourceViewDesc {
        return .{ .format = format, .view_dimension = srv_dimension_texture2d, .data = .{ 0, 1, 0, 0 } };
    }
};

pub const RenderTargetViewDesc = extern struct {
    format: u32,
    view_dimension: u32 = rtv_dimension_texture2d,
    data: [3]u32 = .{ 0, 0, 0 },
};

pub const RenderTargetBlendDesc = extern struct {
    blend_enable: windows.BOOL = 1,
    source_blend: u32 = blend_one,
    destination_blend: u32 = blend_inv_source_alpha,
    blend_operation: u32 = blend_op_add,
    source_blend_alpha: u32 = blend_one,
    destination_blend_alpha: u32 = blend_inv_source_alpha,
    blend_operation_alpha: u32 = blend_op_add,
    write_mask: u8 = color_write_all,
    padding: [3]u8 = .{ 0, 0, 0 },
};

pub const BlendDesc = extern struct {
    alpha_to_coverage_enable: windows.BOOL = 0,
    independent_blend_enable: windows.BOOL = 0,
    render_target: [8]RenderTargetBlendDesc = @splat(.{}),
};

pub const RasterizerDesc = extern struct {
    fill_mode: u32 = fill_solid,
    cull_mode: u32 = cull_none,
    front_counter_clockwise: windows.BOOL = 0,
    depth_bias: i32 = 0,
    depth_bias_clamp: f32 = 0,
    slope_scaled_depth_bias: f32 = 0,
    depth_clip_enable: windows.BOOL = 1,
    scissor_enable: windows.BOOL = 1,
    multisample_enable: windows.BOOL = 0,
    antialiased_line_enable: windows.BOOL = 0,
};

pub const SamplerDesc = extern struct {
    filter: u32 = filter_min_mag_mip_linear,
    address_u: u32 = texture_address_clamp,
    address_v: u32 = texture_address_clamp,
    address_w: u32 = texture_address_clamp,
    mip_lod_bias: f32 = 0,
    maximum_anisotropy: u32 = 1,
    comparison_function: u32 = comparison_never,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    minimum_lod: f32 = 0,
    maximum_lod: f32 = 3.402823466e+38,
};

pub const format_unknown: u32 = 0;
pub const format_r16g16b16a16_float: u32 = 10;
pub const format_r8g8b8a8_unorm: u32 = 28;
pub const format_r8g8b8a8_unorm_srgb: u32 = 29;
pub const format_r8_unorm: u32 = 61;
pub const format_b8g8r8a8_unorm: u32 = 87;
pub const format_b8g8r8a8_unorm_srgb: u32 = 91;

pub const usage_default: u32 = 0;
pub const usage_immutable: u32 = 1;
pub const usage_dynamic: u32 = 2;
pub const usage_staging: u32 = 3;
pub const bind_vertex_buffer: u32 = 0x1;
pub const bind_index_buffer: u32 = 0x2;
pub const bind_constant_buffer: u32 = 0x4;
pub const bind_shader_resource: u32 = 0x8;
pub const bind_render_target: u32 = 0x20;
pub const cpu_access_write: u32 = 0x10000;
pub const cpu_access_read: u32 = 0x20000;
pub const resource_misc_buffer_structured: u32 = 0x40;
pub const map_read: u32 = 1;
pub const map_write_discard: u32 = 4;
pub const primitive_topology_triangle_list: u32 = 4;
pub const primitive_topology_triangle_strip: u32 = 5;
pub const srv_dimension_buffer: u32 = 1;
pub const srv_dimension_texture2d: u32 = 4;
pub const rtv_dimension_texture2d: u32 = 4;
pub const query_event: u32 = 0;
pub const async_getdata_do_not_flush: u32 = 1;

pub const driver_type_hardware: u32 = 1;
pub const driver_type_warp: u32 = 5;
pub const create_device_debug: u32 = 0x2;
pub const create_device_bgra_support: u32 = 0x20;
pub const sdk_version: u32 = 7;
pub const feature_level_11_1: u32 = 0xb100;
pub const feature_level_11_0: u32 = 0xb000;
pub const feature_level_10_1: u32 = 0xa100;
pub const feature_level_10_0: u32 = 0xa000;

pub const usage_render_target_output: u32 = 0x20;
pub const swap_effect_flip_discard: u32 = 4;
pub const swap_effect_discard: u32 = 0;
pub const present_test: u32 = 0x1;

pub const blend_zero: u32 = 1;
pub const blend_one: u32 = 2;
pub const blend_source_color: u32 = 3;
pub const blend_inv_source_color: u32 = 4;
pub const blend_source_alpha: u32 = 5;
pub const blend_inv_source_alpha: u32 = 6;
pub const blend_destination_alpha: u32 = 7;
pub const blend_inv_destination_alpha: u32 = 8;
pub const blend_destination_color: u32 = 9;
pub const blend_inv_destination_color: u32 = 10;
pub const blend_op_add: u32 = 1;
pub const color_write_all: u8 = 0xf;
pub const fill_solid: u32 = 3;
pub const cull_none: u32 = 1;
pub const filter_min_mag_mip_linear: u32 = 0x15;
pub const texture_address_clamp: u32 = 3;
pub const comparison_never: u32 = 1;

pub const dxgi_error_device_removed: HRESULT = @bitCast(@as(u32, 0x887a0005));
pub const dxgi_error_device_reset: HRESULT = @bitCast(@as(u32, 0x887a0007));
pub const dxgi_error_invalid_call: HRESULT = @bitCast(@as(u32, 0x887a0001));
pub const dxgi_status_occluded: HRESULT = @bitCast(@as(u32, 0x087a0001));

pub const iid_factory1: windows.GUID = .{ .data1 = 0x770aae78, .data2 = 0xf26f, .data3 = 0x4dba, .data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 } };
pub const iid_texture2d: windows.GUID = .{ .data1 = 0x6f15aaf2, .data2 = 0xd208, .data3 = 0x4e89, .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

pub extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*Object,
    driver_type: u32,
    software: HMODULE,
    flags: u32,
    feature_levels: ?[*]const u32,
    feature_level_count: u32,
    version: u32,
    device: *?*Object,
    selected_feature_level: *u32,
    immediate_context: *?*Object,
) callconv(.winapi) HRESULT;

pub extern "dxgi" fn CreateDXGIFactory1(id: *const windows.GUID, result: *?*Object) callconv(.winapi) HRESULT;

pub fn createSwapChain(factory: *Object, device: *Object, descriptor: *const SwapChainDesc, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *Object, *const SwapChainDesc, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, factory, 10)(factory, device, descriptor, result);
}

pub fn makeWindowAssociation(factory: *Object, window: HWND, flags: u32) HRESULT {
    const Function = *const fn (*Object, HWND, u32) callconv(.winapi) HRESULT;
    return com.method(Function, factory, 8)(factory, window, flags);
}

pub fn present(swap_chain: *Object, interval: u32, flags: u32) HRESULT {
    const Function = *const fn (*Object, u32, u32) callconv(.winapi) HRESULT;
    return com.method(Function, swap_chain, 8)(swap_chain, interval, flags);
}

pub fn getBuffer(swap_chain: *Object, index: u32, id: *const windows.GUID, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, u32, *const windows.GUID, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, swap_chain, 9)(swap_chain, index, id, result);
}

pub fn resizeBuffers(swap_chain: *Object, count: u32, width: u32, height: u32, format: u32, flags: u32) HRESULT {
    const Function = *const fn (*Object, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT;
    return com.method(Function, swap_chain, 13)(swap_chain, count, width, height, format, flags);
}

pub fn createBuffer(device: *Object, descriptor: *const BufferDesc, initial: ?*const SubresourceData, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *const BufferDesc, ?*const SubresourceData, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 3)(device, descriptor, initial, result);
}

pub fn createTexture2D(device: *Object, descriptor: *const Texture2DDesc, initial: ?[*]const SubresourceData, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *const Texture2DDesc, ?[*]const SubresourceData, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 5)(device, descriptor, initial, result);
}

pub fn texture2DDescription(texture: *Object, descriptor: *Texture2DDesc) void {
    const Function = *const fn (*Object, *Texture2DDesc) callconv(.winapi) void;
    com.method(Function, texture, 10)(texture, descriptor);
}

pub fn createShaderResourceView(device: *Object, resource: *Object, descriptor: ?*const ShaderResourceViewDesc, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *Object, ?*const ShaderResourceViewDesc, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 7)(device, resource, descriptor, result);
}

pub fn createRenderTargetView(device: *Object, resource: *Object, descriptor: ?*const RenderTargetViewDesc, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *Object, ?*const RenderTargetViewDesc, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 9)(device, resource, descriptor, result);
}

pub fn createVertexShader(device: *Object, bytes: *const anyopaque, length: usize, linkage: ?*Object, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *const anyopaque, usize, ?*Object, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 12)(device, bytes, length, linkage, result);
}

pub fn createPixelShader(device: *Object, bytes: *const anyopaque, length: usize, linkage: ?*Object, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *const anyopaque, usize, ?*Object, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 15)(device, bytes, length, linkage, result);
}

pub fn createBlendState(device: *Object, descriptor: *const BlendDesc, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *const BlendDesc, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 20)(device, descriptor, result);
}

pub fn createRasterizerState(device: *Object, descriptor: *const RasterizerDesc, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *const RasterizerDesc, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 22)(device, descriptor, result);
}

pub fn createSamplerState(device: *Object, descriptor: *const SamplerDesc, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *const SamplerDesc, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 23)(device, descriptor, result);
}

pub fn createQuery(device: *Object, descriptor: *const QueryDesc, result: *?*Object) HRESULT {
    const Function = *const fn (*Object, *const QueryDesc, *?*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 24)(device, descriptor, result);
}

pub fn deviceRemovedReason(device: *Object) HRESULT {
    const Function = *const fn (*Object) callconv(.winapi) HRESULT;
    return com.method(Function, device, 39)(device);
}

pub fn vsSetConstantBuffers(context: *Object, slot: u32, buffers: []const ?*Object) void {
    const Function = *const fn (*Object, u32, u32, [*]const ?*Object) callconv(.winapi) void;
    com.method(Function, context, 7)(context, slot, @intCast(buffers.len), buffers.ptr);
}

pub fn psSetShaderResources(context: *Object, slot: u32, views: []const ?*Object) void {
    const Function = *const fn (*Object, u32, u32, [*]const ?*Object) callconv(.winapi) void;
    com.method(Function, context, 8)(context, slot, @intCast(views.len), views.ptr);
}

pub fn psSetShader(context: *Object, shader: ?*Object) void {
    const Function = *const fn (*Object, ?*Object, ?[*]const ?*Object, u32) callconv(.winapi) void;
    com.method(Function, context, 9)(context, shader, null, 0);
}

pub fn psSetSamplers(context: *Object, slot: u32, samplers: []const ?*Object) void {
    const Function = *const fn (*Object, u32, u32, [*]const ?*Object) callconv(.winapi) void;
    com.method(Function, context, 10)(context, slot, @intCast(samplers.len), samplers.ptr);
}

pub fn vsSetShader(context: *Object, shader: ?*Object) void {
    const Function = *const fn (*Object, ?*Object, ?[*]const ?*Object, u32) callconv(.winapi) void;
    com.method(Function, context, 11)(context, shader, null, 0);
}

pub fn draw(context: *Object, vertex_count: u32, start: u32) void {
    const Function = *const fn (*Object, u32, u32) callconv(.winapi) void;
    com.method(Function, context, 13)(context, vertex_count, start);
}

pub fn map(context: *Object, resource: *Object, subresource: u32, map_type: u32, flags: u32, mapped: *MappedSubresource) HRESULT {
    const Function = *const fn (*Object, *Object, u32, u32, u32, *MappedSubresource) callconv(.winapi) HRESULT;
    return com.method(Function, context, 14)(context, resource, subresource, map_type, flags, mapped);
}

pub fn unmap(context: *Object, resource: *Object, subresource: u32) void {
    const Function = *const fn (*Object, *Object, u32) callconv(.winapi) void;
    com.method(Function, context, 15)(context, resource, subresource);
}

pub fn psSetConstantBuffers(context: *Object, slot: u32, buffers: []const ?*Object) void {
    const Function = *const fn (*Object, u32, u32, [*]const ?*Object) callconv(.winapi) void;
    com.method(Function, context, 16)(context, slot, @intCast(buffers.len), buffers.ptr);
}

pub fn iaSetPrimitiveTopology(context: *Object, topology: u32) void {
    const Function = *const fn (*Object, u32) callconv(.winapi) void;
    com.method(Function, context, 24)(context, topology);
}

pub fn vsSetShaderResources(context: *Object, slot: u32, views: []const ?*Object) void {
    const Function = *const fn (*Object, u32, u32, [*]const ?*Object) callconv(.winapi) void;
    com.method(Function, context, 25)(context, slot, @intCast(views.len), views.ptr);
}

pub fn end(context: *Object, query: *Object) void {
    const Function = *const fn (*Object, *Object) callconv(.winapi) void;
    com.method(Function, context, 28)(context, query);
}

pub fn getData(context: *Object, query: *Object, data: ?*anyopaque, size: u32, flags: u32) HRESULT {
    const Function = *const fn (*Object, *Object, ?*anyopaque, u32, u32) callconv(.winapi) HRESULT;
    return com.method(Function, context, 29)(context, query, data, size, flags);
}

pub fn omSetRenderTargets(context: *Object, targets: []const ?*Object) void {
    const Function = *const fn (*Object, u32, ?[*]const ?*Object, ?*Object) callconv(.winapi) void;
    com.method(Function, context, 33)(context, @intCast(targets.len), if (targets.len == 0) null else targets.ptr, null);
}

pub fn omSetBlendState(context: *Object, state: ?*Object) void {
    const Function = *const fn (*Object, ?*Object, *const [4]f32, u32) callconv(.winapi) void;
    const factors: [4]f32 = .{ 1, 1, 1, 1 };
    com.method(Function, context, 35)(context, state, &factors, 0xffffffff);
}

pub fn drawInstanced(context: *Object, vertex_count: u32, instances: u32, vertex_start: u32, instance_start: u32) void {
    const Function = *const fn (*Object, u32, u32, u32, u32) callconv(.winapi) void;
    com.method(Function, context, 21)(context, vertex_count, instances, vertex_start, instance_start);
}

pub fn rsSetState(context: *Object, state: ?*Object) void {
    const Function = *const fn (*Object, ?*Object) callconv(.winapi) void;
    com.method(Function, context, 43)(context, state);
}

pub fn rsSetViewports(context: *Object, viewports: []const Viewport) void {
    const Function = *const fn (*Object, u32, [*]const Viewport) callconv(.winapi) void;
    com.method(Function, context, 44)(context, @intCast(viewports.len), viewports.ptr);
}

pub fn rsSetScissorRects(context: *Object, rects: []const Rect) void {
    const Function = *const fn (*Object, u32, [*]const Rect) callconv(.winapi) void;
    com.method(Function, context, 45)(context, @intCast(rects.len), rects.ptr);
}

pub fn copySubresourceRegion(
    context: *Object,
    destination: *Object,
    destination_subresource: u32,
    destination_x: u32,
    destination_y: u32,
    destination_z: u32,
    source: *Object,
    source_subresource: u32,
    source_box: ?*const Box,
) void {
    const Function = *const fn (*Object, *Object, u32, u32, u32, u32, *Object, u32, ?*const Box) callconv(.winapi) void;
    com.method(Function, context, 46)(
        context,
        destination,
        destination_subresource,
        destination_x,
        destination_y,
        destination_z,
        source,
        source_subresource,
        source_box,
    );
}

pub fn copyResource(context: *Object, destination: *Object, source: *Object) void {
    const Function = *const fn (*Object, *Object, *Object) callconv(.winapi) void;
    com.method(Function, context, 47)(context, destination, source);
}

pub fn updateSubresource(context: *Object, destination: *Object, subresource: u32, box: ?*const Box, source: *const anyopaque, row_pitch: u32, depth_pitch: u32) void {
    const Function = *const fn (*Object, *Object, u32, ?*const Box, *const anyopaque, u32, u32) callconv(.winapi) void;
    com.method(Function, context, 48)(context, destination, subresource, box, source, row_pitch, depth_pitch);
}

pub fn clearRenderTarget(context: *Object, target: *Object, color: *const [4]f32) void {
    const Function = *const fn (*Object, *Object, *const [4]f32) callconv(.winapi) void;
    com.method(Function, context, 50)(context, target, color);
}

pub fn clearState(context: *Object) void {
    const Function = *const fn (*Object) callconv(.winapi) void;
    com.method(Function, context, 110)(context);
}

pub fn flush(context: *Object) void {
    const Function = *const fn (*Object) callconv(.winapi) void;
    com.method(Function, context, 111)(context);
}
