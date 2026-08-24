const std = @import("std");
const options = @import("zigui_options");
const core_config = @import("core/config.zig");
const Error = @import("core/error.zig").Error;

pub const Platform = enum {
    auto,
    headless,
    macos,
    windows,
    linux_wayland,
    linux_x11,
};

pub const Renderer = enum {
    auto,
    null,
    metal,
    d3d11,
    vulkan,
};

pub const compiled_platform = std.meta.stringToEnum(Platform, @tagName(options.platform)).?;
pub const compiled_renderer = std.meta.stringToEnum(Renderer, @tagName(options.renderer)).?;
pub const text_enabled = options.enable_text;
pub const accessibility_enabled = options.enable_accessibility;
pub const images_enabled = options.enable_images;
pub const svg_enabled = options.enable_svg;
pub const media_enabled = options.enable_media;
pub const inspector_enabled = options.enable_inspector;
pub const tracing_enabled = options.enable_tracing;

pub const GpuPolicy = core_config.GpuPolicy;
pub const MemoryBudgets = core_config.MemoryBudgets;

pub const LinuxConfig = struct {
    /// Full Wayland socket path. When null, ZigUI resolves XDG_RUNTIME_DIR and
    /// WAYLAND_DISPLAY from the initial process environment.
    wayland_socket_path: ?[]const u8 = null,
    wayland_display: ?[]const u8 = null,
    runtime_directory: ?[]const u8 = null,
    x11_display: ?[]const u8 = null,
};

pub const AppConfig = struct {
    application_name: []const u8 = "ZigUI application",
    application_version: []const u8 = "",
    gpu: GpuPolicy = .{},
    memory: MemoryBudgets = .{},
    linux: LinuxConfig = .{},
    quit_when_last_window_closes: bool = true,
    allow_multiple_apps_for_testing: bool = false,
};

pub fn validate(value: AppConfig) Error!void {
    if (!validText(value.application_name) or !validTextAllowEmpty(value.application_version))
        return error.InvalidConfiguration;
    if (value.allow_multiple_apps_for_testing and compiled_platform != .headless)
        return error.InvalidConfiguration;
    inline for (.{
        value.memory.retained_node_count,
        value.memory.retained_tree_depth,
        value.memory.layout_grid_cell_count,
        value.memory.component_count,
        value.memory.state_count,
        value.memory.dependency_edge_count,
        value.memory.effect_count,
        value.memory.window_count,
        value.memory.platform_event_count,
        value.memory.file_drop_path_count,
        value.memory.menu_item_count,
        value.memory.menu_depth,
        value.memory.platform_object_count,
        value.memory.action_count,
        value.memory.action_binding_count,
        value.memory.action_context_count,
        value.memory.pointer_capture_count,
        value.memory.texture_count,
        value.memory.external_surface_count,
        value.memory.render_extension_count,
        value.memory.scene_operation_count,
        value.memory.scene_material_count,
        value.memory.scene_gradient_stop_count,
        value.memory.scene_clip_count,
        value.memory.scene_layer_count,
        value.memory.scene_primitive_count,
        value.memory.scene_path_vertex_count,
        value.memory.scene_custom_pass_count,
        value.memory.scene_custom_payload_bytes,
        value.memory.worker_queue_capacity,
    }) |count| if (count == 0 or count > std.math.maxInt(u32)) return error.InvalidConfiguration;
    if (value.memory.retained_tree_depth > core_config.maximum_retained_tree_depth)
        return error.InvalidConfiguration;
    if (value.memory.menu_depth > core_config.maximum_menu_depth)
        return error.InvalidConfiguration;
    if (value.memory.platform_event_payload_bytes > value.memory.platform_event_queue_bytes)
        return error.InvalidConfiguration;
    if (value.gpu.maximum_gpu_bytes == 0 or value.gpu.frames_in_flight == 0 or value.gpu.frames_in_flight > 8)
        return error.InvalidConfiguration;
    if (value.memory.frame_arena_bytes < 4096 or value.memory.event_arena_bytes < 4096 or
        value.memory.retained_tree_bytes == 0 or
        value.memory.action_name_bytes == 0 or
        value.memory.action_binding_count == 0 or
        value.memory.platform_event_payload_bytes == 0 or
        value.memory.platform_event_queue_bytes == 0 or
        value.memory.platform_text_bytes == 0 or
        value.memory.platform_retained_text_bytes == 0 or
        value.memory.clipboard_bytes == 0 or
        value.memory.clipboard_retained_bytes == 0 or
        value.memory.menu_text_bytes == 0 or
        value.memory.texture_cpu_copy_bytes == 0 or
        value.memory.upload_ring_bytes < 4096 or value.memory.path_cache_bytes == 0 or
        value.memory.path_edge_count == 0 or value.memory.path_work_units == 0 or
        value.memory.scene_operation_count == 0 or value.memory.scene_material_count == 0 or
        value.memory.scene_gradient_stop_count == 0 or value.memory.scene_clip_count == 0 or
        value.memory.scene_layer_count == 0 or value.memory.scene_primitive_count == 0 or
        value.memory.scene_path_vertex_count == 0 or value.memory.scene_custom_pass_count == 0 or
        value.memory.scene_custom_payload_bytes == 0)
        return error.InvalidConfiguration;
    if (value.memory.clipboard_bytes > value.memory.clipboard_retained_bytes)
        return error.InvalidConfiguration;
    if (value.memory.platform_text_bytes > value.memory.platform_retained_text_bytes)
        return error.InvalidConfiguration;
    if (value.application_name.len > value.memory.platform_text_bytes or
        value.application_version.len > value.memory.platform_text_bytes)
        return error.BudgetExceeded;
    if (comptime text_enabled) {
        if (!validCount(value.memory.font_catalog_count) or value.memory.font_catalog_bytes == 0 or
            !validCount(value.memory.font_instance_count) or
            value.memory.loaded_font_bytes == 0 or value.memory.mapped_font_bytes == 0 or
            value.memory.text_layout_bytes == 0 or value.memory.glyph_atlas_bytes == 0 or
            !validCount(value.memory.glyph_atlas_tile_count))
            return error.InvalidConfiguration;
    }
    if (comptime images_enabled) {
        if (!validCount(value.memory.image_count) or !validCount(value.memory.animation_count) or
            value.memory.encoded_image_bytes == 0 or value.memory.decoded_image_bytes == 0)
            return error.InvalidConfiguration;
    }
    if (comptime svg_enabled) {
        if (value.memory.svg_document_bytes == 0 or !validCount(value.memory.svg_document_count))
            return error.InvalidConfiguration;
    }
    if (comptime media_enabled) {
        if (!validCount(value.memory.media_source_count) or value.memory.media_encoded_bytes == 0 or
            value.memory.media_decoded_bytes == 0 or
            value.memory.media_frame_count == 0)
            return error.InvalidConfiguration;
    }
    if (comptime accessibility_enabled) {
        if (value.memory.accessibility_tree_bytes == 0 or value.memory.accessibility_node_count == 0 or
            value.memory.accessibility_node_count > std.math.maxInt(u32))
            return error.InvalidConfiguration;
    }
    if (comptime tracing_enabled) {
        if (value.memory.trace_event_count == 0) return error.InvalidConfiguration;
    }
    inline for (.{
        value.linux.wayland_socket_path,
        value.linux.wayland_display,
        value.linux.runtime_directory,
        value.linux.x11_display,
    }) |optional| if (optional) |text| {
        if (!validText(text)) return error.InvalidConfiguration;
        if (text.len > value.memory.platform_text_bytes) return error.BudgetExceeded;
    };
}

fn validText(value: []const u8) bool {
    return value.len != 0 and validTextAllowEmpty(value);
}

fn validCount(value: usize) bool {
    return value != 0 and value <= std.math.maxInt(u32);
}

fn validTextAllowEmpty(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}
