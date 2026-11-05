//! Platform-free resource and rendering policy contracts.

/// Retained algorithms intentionally use bounded recursion for the hot tree
/// walks. Keeping the public limit fixed makes the stack bound portable across
/// every supported desktop target.
pub const maximum_retained_tree_depth: usize = 512;
pub const maximum_menu_depth: usize = 128;

pub const GpuPolicy = struct {
    power_preference: PowerPreference = .high_performance,
    software_fallback: SoftwareFallback = .forbidden,
    validation: bool = false,
    preferred_adapter: ?u32 = null,
    maximum_gpu_bytes: usize = 512 * 1024 * 1024,
    frames_in_flight: u8 = 3,
    /// Metal: acquire display drawables off the UI thread and defer frames
    /// while either the drawable or a GPU frame slot is unavailable.
    asynchronous_drawables: bool = false,

    pub const PowerPreference = enum { low_power, high_performance };
    pub const SoftwareFallback = enum { forbidden, permitted };
};

pub const MemoryBudgets = struct {
    frame_arena_bytes: usize = 8 * 1024 * 1024,
    event_arena_bytes: usize = 2 * 1024 * 1024,
    retained_node_count: usize = 1_000_000,
    retained_tree_depth: usize = maximum_retained_tree_depth,
    /// Live retained-node strings, style arrays, handlers, semantics, and
    /// child storage. Slot-pool metadata is bounded separately by node count.
    retained_tree_bytes: usize = 256 * 1024 * 1024,
    /// Per-window CPU scene cache, including its metadata and glyph references.
    /// Zero disables scene retention; exhausted caches draw normally.
    retained_scene_bytes: usize = 16 * 1024 * 1024,
    /// Maximum temporary occupancy cells used to place one grid container.
    /// This prevents sparse explicit row indices from consuming an unbounded
    /// frame arena even when the retained node count is small.
    layout_grid_cell_count: usize = 1_048_576,
    component_count: usize = 131_072,
    state_count: usize = 1_000_000,
    dependency_edge_count: usize = 4_194_304,
    effect_count: usize = 65_536,
    window_count: usize = 256,
    platform_event_count: usize = 65_536,
    platform_event_payload_bytes: usize = 16 * 1024 * 1024,
    /// Aggregate owned payload retained by the native-to-UI event queue.
    platform_event_queue_bytes: usize = 64 * 1024 * 1024,
    /// Maximum UTF-8 payload accepted by one platform-facing text operation,
    /// including titles and native surrounding-text snapshots.
    platform_text_bytes: usize = 16 * 1024 * 1024,
    /// Aggregate framework-owned platform text, including headless titles,
    /// native surrounding-text snapshots, protocol names, keymaps, and IME
    /// staging strings. Clipboard, menu, and queued event payloads have their
    /// own independent aggregate budgets below.
    platform_retained_text_bytes: usize = 64 * 1024 * 1024,
    clipboard_bytes: usize = 64 * 1024 * 1024,
    /// Aggregate clipboard snapshots retained while native ownership
    /// transfers are still live.
    clipboard_retained_bytes: usize = 256 * 1024 * 1024,
    file_drop_path_count: usize = 4_096,
    menu_item_count: usize = 16_384,
    menu_depth: usize = 64,
    menu_text_bytes: usize = 8 * 1024 * 1024,
    /// Live native protocol objects advertised or created on one connection.
    platform_object_count: usize = 65_536,
    action_count: usize = 65_536,
    action_binding_count: usize = 262_144,
    /// Aggregate UTF-8 bytes retained by registered action names.
    action_name_bytes: usize = 8 * 1024 * 1024,
    action_context_count: usize = 256,
    pointer_capture_count: usize = 256,
    texture_count: usize = 262_144,
    /// Aggregate framework-owned CPU copies retained for texture recovery.
    /// This is independent of optional image-decoder working/output memory.
    texture_cpu_copy_bytes: usize = 256 * 1024 * 1024,
    external_surface_count: usize = 16_384,
    render_extension_count: usize = 1_024,
    image_count: usize = 65_536,
    animation_count: usize = 4_096,
    media_source_count: usize = 4_096,
    upload_ring_bytes: usize = 32 * 1024 * 1024,
    glyph_atlas_bytes: usize = 64 * 1024 * 1024,
    /// Live plus submission-retired tiles across each glyph atlas.
    glyph_atlas_tile_count: usize = 1_048_576,
    encoded_image_bytes: usize = 128 * 1024 * 1024,
    /// Aggregate decoded output and animation-canvas memory owned by the
    /// optional image capability.
    decoded_image_bytes: usize = 256 * 1024 * 1024,
    svg_document_bytes: usize = 128 * 1024 * 1024,
    svg_document_count: usize = 16_384,
    media_encoded_bytes: usize = 512 * 1024 * 1024,
    /// Maximum decoder-owned bytes for one in-tree media source. Encoded
    /// source retention and uploaded GPU resources are accounted separately.
    media_decoded_bytes: usize = 512 * 1024 * 1024,
    media_frame_count: usize = 1_000_000,
    /// Installed faces retained as lazy font-catalog metadata.
    font_catalog_count: usize = 32 * 1024,
    /// Aggregate retained catalog paths and family names. Font file contents
    /// are accounted independently by the resident and mapped font budgets.
    font_catalog_bytes: usize = 32 * 1024 * 1024,
    /// Retained resolved font instances, including variable-axis coordinate
    /// combinations.
    font_instance_count: usize = 65_536,
    /// Heap-resident font data registered directly by the application.
    loaded_font_bytes: usize = 128 * 1024 * 1024,
    /// Read-only installed-font mappings. Mapped pages are faulted on demand,
    /// so large system collections and color fonts do not become heap copies.
    mapped_font_bytes: usize = 1024 * 1024 * 1024,
    text_layout_bytes: usize = 32 * 1024 * 1024,
    path_cache_bytes: usize = 32 * 1024 * 1024,
    /// Maximum flattened path edges accepted across one render batch.
    path_edge_count: usize = 262_144,
    /// Maximum edge-pair and band-scan operations across one render batch.
    path_work_units: usize = 4_194_304,
    scene_operation_count: usize = 1_000_000,
    scene_material_count: usize = 131_072,
    scene_gradient_stop_count: usize = 1_048_576,
    scene_clip_count: usize = 131_072,
    scene_layer_count: usize = 131_072,
    scene_primitive_count: usize = 4_000_000,
    scene_path_vertex_count: usize = 8_000_000,
    scene_custom_pass_count: usize = 65_536,
    scene_custom_payload_bytes: usize = 64 * 1024 * 1024,
    accessibility_tree_bytes: usize = 32 * 1024 * 1024,
    accessibility_node_count: usize = 250_000,
    trace_event_count: usize = 262_144,
    worker_queue_capacity: usize = 4096,
    /// Maximum live asynchronous offscreen submissions retained by a backend.
    /// This is intentionally separate from worker and scene budgets because
    /// each request owns a copied scene until its GPU command completes.
    offscreen_request_count: usize = 64,
};
