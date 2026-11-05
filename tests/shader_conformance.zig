const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ui = @import("zigui");
const vulkan_shaders = ui.internal_shader_test.vulkan_shaders;

const metal_source = @embedFile("zigui_metal_source");
const hlsl_source = @embedFile("zigui_hlsl_source");

test "generated Vulkan modules have complete bounded SPIR-V structure" {
    var library = try vulkan_shaders.Library.build(testing.allocator);
    defer library.deinit(testing.allocator);

    inline for (@typeInfo(vulkan_shaders.Library).@"struct".field_names, 0..) |field, index| {
        const words = @field(library, field);
        try validateSpirv(words, if (index == 0) 0 else 4);
    }
}

test "native shader sources expose every renderer entry point" {
    const common_entries = [_][]const u8{
        "quad_vertex",
        "quad_fragment",
        "shadow_vertex",
        "shadow_fragment",
        "sprite_vertex",
        "mono_sprite_fragment",
        "color_sprite_fragment",
        "external_surface_vertex",
        "external_surface_fragment",
        "underline_vertex",
        "underline_fragment",
        "path_vertex",
        "path_fragment",
        "composite_vertex",
        "composite_fragment",
    };
    for (common_entries) |entry| {
        try testing.expect(std.mem.indexOf(u8, metal_source, entry) != null);
        try testing.expect(std.mem.indexOf(u8, hlsl_source, entry) != null);
    }
    try testing.expect(std.mem.indexOf(u8, metal_source, "present_vertex") != null);
    try testing.expect(std.mem.indexOf(u8, metal_source, "present_fragment") != null);
    for ([_][]const u8{ "backdrop_vertex", "backdrop_fragment" }) |entry|
        try testing.expect(std.mem.indexOf(u8, metal_source, entry) != null);
    try testing.expect(std.mem.indexOf(u8, hlsl_source, "vertex_id == 1 || vertex_id == 3") != null);
}

test "Windows D3D compiler accepts every HLSL renderer entry point" {
    if (builtin.os.tag != .windows) return;

    var compiler = try ui.internal_shader_test.d3d11_compiler.Compiler.load();
    defer compiler.deinit();
    const entries = [_]struct { name: [*:0]const u8, target: [*:0]const u8 }{
        .{ .name = "quad_vertex", .target = "vs_5_0" },
        .{ .name = "quad_fragment", .target = "ps_5_0" },
        .{ .name = "shadow_vertex", .target = "vs_5_0" },
        .{ .name = "shadow_fragment", .target = "ps_5_0" },
        .{ .name = "sprite_vertex", .target = "vs_5_0" },
        .{ .name = "mono_sprite_fragment", .target = "ps_5_0" },
        .{ .name = "color_sprite_fragment", .target = "ps_5_0" },
        .{ .name = "external_surface_vertex", .target = "vs_5_0" },
        .{ .name = "external_surface_fragment", .target = "ps_5_0" },
        .{ .name = "underline_vertex", .target = "vs_5_0" },
        .{ .name = "underline_fragment", .target = "ps_5_0" },
        .{ .name = "path_vertex", .target = "vs_5_0" },
        .{ .name = "path_fragment", .target = "ps_5_0" },
        .{ .name = "composite_vertex", .target = "vs_5_0" },
        .{ .name = "composite_fragment", .target = "ps_5_0" },
    };
    for (entries) |entry| {
        var bytecode = try compiler.compile(hlsl_source, entry.name, entry.target);
        defer bytecode.deinit();
        try testing.expect(bytecode.bytes().len != 0);
    }
}

test "Windows D3D renderer covers a complete triangle-strip quad" {
    if (builtin.os.tag != .windows) return;

    var provider_context: u8 = 0;
    const renderer = try ui.internal_shader_test.d3d11_renderer.Renderer.create(
        testing.allocator,
        ui.internal_shader_test.d3d11NullSurfaceProvider(&provider_context),
        .{},
        .{},
    );
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .background = ui.Color.white,
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 4,
        .height = 4,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    for ([_][2]usize{ .{ 0, 0 }, .{ 3, 0 }, .{ 0, 3 }, .{ 3, 3 } }) |coordinate| {
        const offset = coordinate[1] * readback.stride + coordinate[0] * 4;
        try testing.expect(readback.pixels[offset + 3] >= 120);
    }
}

test "native shader record declarations match the fixed Zig scene ABI" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(ui.scene_abi.Operation));
    try testing.expectEqual(@as(usize, 72), @sizeOf(ui.scene_abi.Material));
    try testing.expectEqual(@as(usize, 32), @sizeOf(ui.scene_abi.GradientStop));
    try testing.expectEqual(@as(usize, 80), @sizeOf(ui.scene_abi.Quad));
    try testing.expectEqual(@as(usize, 64), @sizeOf(ui.scene_abi.Shadow));
    try testing.expectEqual(@as(usize, 48), @sizeOf(ui.scene_abi.Underline));
    try testing.expectEqual(@as(usize, 80), @sizeOf(ui.scene_abi.Sprite));
    try testing.expectEqual(@as(usize, 56), @sizeOf(ui.scene_abi.ExternalSurface));
    try testing.expectEqual(@as(usize, 40), @sizeOf(ui.scene_abi.CustomPass));
    try testing.expectEqual(@as(usize, 44), @sizeOf(ui.scene_abi.BackdropEffect));

    const declarations = [_][]const u8{
        "structQuad{Rectbounds;Colorbackground;Colorborder_color;Insetsborder_widths;Radiiradii;};",
        "structShadow{Rectbounds;Colorcolor;Radiiradii;Pointoffset;floatblur_radius;floatspread;};",
        "structUnderline{Rectbounds;Colorcolor;floatthickness;floatwave_amplitude;floatwave_period;floatreserved;};",
        "structSprite{Rectbounds;Rectuv_bounds;Colorcolor;ulongtexture;uinttile_generation;uintformat;uinteffect;floateffect_radius;floateffect_height;uinteffect_reserved;};",
        "structExternalSurface{Rectbounds;Rectuv_bounds;ulongsurface;uintgeneration;uintcolor_space;floatopacity;floatreserved;};",
        "structMaterial{uintkind;uintstop_start;uintstop_count;uintreserved;Colorcolor;Pointstart;Pointend;Affinegradient_transform;};",
        "structGradientStop{floatoffset;floatreserved0;floatreserved1;floatreserved2;Colorcolor;};",
    };
    const hlsl_declarations = [_][]const u8{
        declarations[0],
        declarations[1],
        declarations[2],
        "structSprite{Rectbounds;Rectuv_bounds;Colorcolor;uint2texture_id;uinttile_generation;uintformat;uinteffect;floateffect_radius;floateffect_height;uinteffect_reserved;};",
        "structExternalSurface{Rectbounds;Rectuv_bounds;uint2surface;uintgeneration;uintcolor_space;floatopacity;floatreserved;};",
        declarations[5],
        "structGradientStop{floatoffset;float3reserved;Colorcolor;};",
    };
    const normalized_metal = try normalize(testing.allocator, metal_source);
    defer testing.allocator.free(normalized_metal);
    const normalized_hlsl = try normalize(testing.allocator, hlsl_source);
    defer testing.allocator.free(normalized_hlsl);
    for (declarations) |declaration| try testing.expect(std.mem.indexOf(u8, normalized_metal, declaration) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        normalized_metal,
        "structBackdropComposite{Rectbounds;Radiiradii;Pointcapture_origin;Sizecapture_size;floatblur_radius;floatsaturation;floatopacity;};",
    ) != null);
    for (hlsl_declarations) |declaration| try testing.expect(std.mem.indexOf(u8, normalized_hlsl, declaration) != null);
}

fn validateSpirv(words: []const u32, expected_model: u32) !void {
    try testing.expect(words.len >= 6 and words.len <= 1_000_000);
    try testing.expectEqual(@as(u32, 0x0723_0203), words[0]);
    try testing.expectEqual(@as(u32, 0x0001_0500), words[1]);
    try testing.expectEqual(@as(u32, 0x5a49_4701), words[2]);
    try testing.expect(words[3] > 1);
    try testing.expectEqual(@as(u32, 0), words[4]);

    var cursor: usize = 5;
    var capabilities: usize = 0;
    var memory_models: usize = 0;
    var entry_points: usize = 0;
    var functions: usize = 0;
    var function_ends: usize = 0;
    var global_variables: [64]u32 = undefined;
    var global_variable_count: usize = 0;
    var entry_interfaces: [64]u32 = undefined;
    var entry_interface_count: usize = 0;
    while (cursor < words.len) {
        const word_count: usize = words[cursor] >> 16;
        const opcode: u16 = @truncate(words[cursor]);
        try testing.expect(word_count != 0 and word_count <= words.len - cursor);
        switch (opcode) {
            14 => memory_models += 1,
            15 => {
                try testing.expect(word_count >= 4);
                try testing.expectEqual(expected_model, words[cursor + 1]);
                var interface_start = cursor + 3;
                while (interface_start < cursor + word_count) : (interface_start += 1) {
                    const value = words[interface_start];
                    if ((value & 0xff) == 0 or (value & 0xff00) == 0 or
                        (value & 0xff0000) == 0 or (value & 0xff000000) == 0)
                    {
                        interface_start += 1;
                        break;
                    }
                }
                for (words[interface_start .. cursor + word_count]) |interface_id| {
                    try testing.expect(entry_interface_count < entry_interfaces.len);
                    entry_interfaces[entry_interface_count] = interface_id;
                    entry_interface_count += 1;
                }
                entry_points += 1;
            },
            17 => capabilities += 1,
            54 => functions += 1,
            56 => function_ends += 1,
            59 => {
                try testing.expect(word_count >= 4);
                const storage_class = words[cursor + 3];
                if (storage_class != 7) {
                    try testing.expect(global_variable_count < global_variables.len);
                    global_variables[global_variable_count] = words[cursor + 2];
                    global_variable_count += 1;
                }
            },
            else => {},
        }
        cursor += word_count;
    }
    try testing.expectEqual(words.len, cursor);
    try testing.expect(capabilities >= 1);
    try testing.expectEqual(@as(usize, 1), memory_models);
    try testing.expectEqual(@as(usize, 1), entry_points);
    try testing.expect(functions >= 1);
    try testing.expectEqual(functions, function_ends);
    for (global_variables[0..global_variable_count]) |variable_id|
        try testing.expect(std.mem.indexOfScalar(u32, entry_interfaces[0..entry_interface_count], variable_id) != null);
}

fn normalize(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (source) |byte| if (!std.ascii.isWhitespace(byte)) try output.append(allocator, byte);
    return output.toOwnedSlice(allocator);
}
