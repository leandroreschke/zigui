const std = @import("std");
const config = @import("config.zig");
const Error = @import("core/error.zig").Error;
const geometry = @import("core/geometry.zig");
const handles = @import("core/handle.zig");
const metrics = @import("core/metrics.zig");
const compose_component = @import("compose/component.zig");
const compose_custom = @import("compose/custom.zig");
const compose_store = @import("compose/store.zig");
const layout_engine = @import("layout/engine.zig");
const layout_style = @import("layout/style.zig");
const action = @import("input/action.zig");
const input = @import("input/event.zig");
const platform = @import("platform/api.zig");
const render = @import("render/api.zig");
const resource = @import("render/resource.zig");
const render_extension = @import("render/extension.zig");
const surface_resource = @import("render/surface_resource.zig");
const coordinator_mod = @import("runtime/coordinator.zig");
const phase = @import("runtime/phase.zig");
const task = @import("runtime/task.zig");
const scene = @import("scene/scene.zig");
const scene_painter = @import("scene/painter.zig");
const a11y_tree = @import("a11y/tree.zig");
const text_system = if (config.text_enabled) @import("text/system.zig") else struct {
    pub const System = void;
};
const image_manager = if (config.images_enabled) @import("assets/manager.zig") else struct {
    pub const Manager = void;
};
const svg_manager = if (config.svg_enabled) @import("assets/svg_manager.zig") else struct {
    pub const Manager = void;
};
const media_api = @import("media/api.zig");
const media_manager = if (config.media_enabled) @import("media/manager.zig") else struct {
    pub const Manager = void;
};
const y4m = if (config.media_enabled) @import("media/y4m.zig") else struct {
    pub const Source = void;
};
const tracing = if (config.tracing_enabled) @import("debug/tracing.zig") else struct {
    pub const Recorder = void;
    pub const Span = void;
};
const Window = @import("window.zig").Window;

var exclusive_app_active = std.atomic.Value(u8).init(0);

const LayoutFeedback = struct {
    coordinator: *coordinator_mod.Coordinator,
    requested: bool = false,

    fn request(context: *anyopaque, component: handles.ComponentId) void {
        const self: *LayoutFeedback = @ptrCast(@alignCast(context));
        self.requested = true;
        _ = self.coordinator.invalidations.markComponent(component, .{});
    }
};

pub const OpenWindowOptions = struct {
    platform: platform.WindowOptions,
    clear_color: geometry.Color = .black,
};

pub const App = struct {
    const WindowPool = handles.SlotPool(*Window, handles.WindowId);

    allocator: std.mem.Allocator,
    app_config: config.AppConfig,
    bundle: platform.Bundle,
    coordinator: coordinator_mod.Coordinator,
    nodes: compose_store.Store,
    components: compose_component.Store,
    actions: action.Registry,
    resources: resource.Manager,
    surfaces: surface_resource.Manager,
    text: ?text_system.System,
    images: ?image_manager.Manager,
    svgs: ?svg_manager.Manager,
    media: ?media_manager.Manager,
    trace: ?tracing.Recorder,
    task_host: ?task.Host,
    completions: ?task.CompletionQueue,
    windows: WindowPool,
    frame_sequence: u64 = 0,
    running: bool = false,
    closing: bool = false,
    pending_error: ?Error = null,
    exclusive_app_slot: bool,

    pub fn create(allocator: std.mem.Allocator, app_config: config.AppConfig) Error!*App {
        try config.validate(app_config);
        const bundle = try @import("platform/factory.zig").createBundle(allocator, app_config);
        return createWithBundle(allocator, app_config, bundle);
    }

    /// Consumes `bundle` on both success and failure. This makes custom and
    /// headless platform factories obey the same single-owner teardown rule as
    /// native `App.create`.
    pub fn createWithBundle(
        allocator: std.mem.Allocator,
        app_config: config.AppConfig,
        owned_bundle: platform.Bundle,
    ) Error!*App {
        var bundle = owned_bundle;
        config.validate(app_config) catch |err| {
            deinitUnclaimedBundle(bundle);
            return err;
        };
        boundBundleServices(&bundle, app_config.memory);
        validateBundleConfiguration(bundle) catch |err| {
            deinitUnclaimedBundle(bundle);
            return err;
        };
        const exclusive_app_slot = !app_config.allow_multiple_apps_for_testing;
        if (exclusive_app_slot and exclusive_app_active.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
            deinitUnclaimedBundle(bundle);
            return error.AlreadyRunning;
        }
        const self = allocator.create(App) catch |err| {
            if (exclusive_app_slot) exclusive_app_active.store(0, .release);
            deinitUnclaimedBundle(bundle);
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .app_config = app_config,
            .bundle = bundle,
            .coordinator = coordinator_mod.Coordinator.initWithLimits(allocator, .{
                .maximum_states = app_config.memory.state_count,
                .maximum_components = app_config.memory.component_count,
                .maximum_windows = app_config.memory.window_count,
                .maximum_dependency_edges = app_config.memory.dependency_edge_count,
                .maximum_effects = app_config.memory.effect_count,
                .maximum_tasks = app_config.memory.worker_queue_capacity,
            }),
            .nodes = compose_store.Store.initWithLimits(allocator, .{
                .maximum_nodes = app_config.memory.retained_node_count,
                .maximum_depth = app_config.memory.retained_tree_depth,
                .maximum_bytes = app_config.memory.retained_tree_bytes,
            }),
            .components = compose_component.Store.initWithLimit(allocator, app_config.memory.component_count),
            .actions = action.Registry.initWithBudgets(
                allocator,
                app_config.memory.action_count,
                app_config.memory.action_binding_count,
                app_config.memory.action_name_bytes,
            ),
            .resources = resource.Manager.initWithLimit(
                allocator,
                app_config.gpu.maximum_gpu_bytes,
                app_config.memory.texture_cpu_copy_bytes,
                app_config.memory.texture_count,
            ),
            .surfaces = surface_resource.Manager.initWithLimit(
                allocator,
                bundle.renderer,
                app_config.memory.external_surface_count,
            ),
            .text = null,
            .images = null,
            .svgs = null,
            .media = null,
            .trace = null,
            .task_host = null,
            .completions = null,
            .windows = WindowPool.init(allocator),
            .frame_sequence = 0,
            .exclusive_app_slot = exclusive_app_slot,
        };
        errdefer {
            self.destroyPartially();
            allocator.destroy(self);
        }
        try self.coordinator.bind();
        self.resources.bindCounters(&self.coordinator.counters);
        if (comptime config.tracing_enabled) {
            self.trace = try tracing.Recorder.init(
                allocator,
                bundle.event_loop.clock,
                app_config.memory.trace_event_count,
            );
        }
        if (comptime config.text_enabled) {
            const backend = bundle.text_backend orelse return error.TextUnavailable;
            self.text = try text_system.System.init(
                allocator,
                backend,
                bundle.renderer,
                &self.resources,
                geometry.ScaleFactor.init(1) catch unreachable,
                app_config.memory.text_layout_bytes,
                app_config.memory.glyph_atlas_bytes,
                app_config.memory.glyph_atlas_tile_count,
                &self.coordinator.counters,
            );
        }
        if (comptime config.images_enabled) {
            self.images = image_manager.Manager.initWithLimits(
                allocator,
                bundle.renderer,
                &self.resources,
                .{
                    .maximum_compressed_bytes = app_config.memory.encoded_image_bytes,
                    .maximum_decoded_bytes = app_config.memory.decoded_image_bytes,
                    .maximum_animation_canvas_bytes = app_config.memory.decoded_image_bytes,
                },
                app_config.memory.image_count,
                app_config.memory.animation_count,
            );
        }
        if (comptime config.svg_enabled) {
            self.svgs = svg_manager.Manager.init(
                allocator,
                .{ .maximum_bytes = @min(16 * 1024 * 1024, app_config.memory.svg_document_bytes) },
                app_config.memory.svg_document_bytes,
                app_config.memory.svg_document_count,
            );
        }
        if (comptime config.media_enabled) {
            self.media = media_manager.Manager.initWithLimit(
                allocator,
                bundle.renderer,
                &self.resources,
                &self.surfaces,
                app_config.memory.media_source_count,
            );
        }
        return self;
    }

    pub fn destroy(self: *App) Error!void {
        try self.coordinator.affinity.assertCurrent();
        if (self.running) return error.ResourceBusy;
        if (self.coordinator.phase_state.callback_depth != 0) return error.CallbackReentrancy;
        if (self.coordinator.phase_state.current != .idle or self.coordinator.phase_state.transaction_depth != 0)
            return error.FramePhaseViolation;
        self.closing = true;
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| self.closeWindowInternal(entry.id, true);
        self.destroyPartially();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn destroyPartially(self: *App) void {
        self.shutdownTaskHost();
        self.windows.deinit();
        if (comptime config.media_enabled) if (self.media) |*manager| manager.deinit();
        if (comptime config.svg_enabled) if (self.svgs) |*manager| manager.deinit();
        if (comptime config.images_enabled) if (self.images) |*manager| manager.deinit();
        if (comptime config.tracing_enabled) if (self.trace) |*recorder| recorder.deinit();
        if (comptime config.text_enabled) {
            if (self.text) |*system| system.deinit() else if (self.bundle.text_backend) |backend| backend.deinit();
        } else if (self.bundle.text_backend) |backend| backend.deinit();
        self.surfaces.deinit();
        self.resources.deinit();
        self.actions.deinit();
        self.components.deinit();
        self.nodes.deinit();
        self.coordinator.deinit() catch {};
        if (self.bundle.accessibility) |adapter| adapter.deinit();
        self.bundle.renderer.deinit();
        self.bundle.deinit();
        if (self.exclusive_app_slot) exclusive_app_active.store(0, .release);
    }

    pub fn openWindow(self: *App, options: OpenWindowOptions, root: compose_component.Descriptor) Error!handles.WindowId {
        try self.assertMutationPhase();
        if (!validColor(options.clear_color)) return error.InvalidConfiguration;
        if (self.windows.live_count >= self.app_config.memory.window_count) return error.BudgetExceeded;
        const target_window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(target_window);
        const id = try self.windows.insert(target_window);
        errdefer _ = self.windows.remove(id);
        const anchor = try self.nodes.createAnchor(id.encode());
        errdefer self.nodes.destroyTree(anchor);
        const component = try self.components.create(root, id);
        errdefer self.components.destroy(component, &self.nodes, &self.coordinator);
        try self.components.attach(component, anchor);
        _ = try self.components.markRegistered(component);
        try self.coordinator.invalidations.register(component, id);
        errdefer self.coordinator.invalidations.unregisterWindow(id);
        const native = try self.bundle.windows.create(id, options.platform);
        errdefer self.bundle.windows.destroy(id);
        try target_window.init(
            self.allocator,
            id,
            native,
            options.platform.size,
            options.platform.position,
            geometry.ScaleFactor.init(1) catch unreachable,
            options.clear_color,
            anchor,
            component,
            self.app_config.memory.frame_arena_bytes,
            self.app_config.memory.event_arena_bytes,
            sceneLimits(self.app_config.memory),
            self.app_config.memory.retained_node_count,
            self.app_config.memory.accessibility_node_count,
            self.app_config.memory.accessibility_tree_bytes,
            .{
                .maximum_pointer_captures = self.app_config.memory.pointer_capture_count,
                .maximum_contexts = self.app_config.memory.action_context_count,
                .maximum_hover_depth = self.app_config.memory.retained_tree_depth,
                .maximum_event_payload_bytes = self.app_config.memory.platform_event_payload_bytes,
                .maximum_file_drop_paths = self.app_config.memory.file_drop_path_count,
            },
            &self.actions,
        );
        target_window.router.setNativeTextInput(if (self.bundle.text_input) |text_input| text_input.bridge() else null);
        target_window.router.setNativeClipboard(if (self.bundle.clipboard) |clipboard| clipboard.bridge() else null);
        target_window.visible = options.platform.visible;
        target_window.pending_frame = options.platform.visible;
        return id;
    }

    pub fn closeWindow(self: *App, id: handles.WindowId) Error!void {
        try self.assertMutationPhase();
        const target = self.window(id) orelse return error.InvalidHandle;
        if (self.coordinator.phase_state.callback_depth != 0) {
            if (target.close_scheduled) return;
            const pending = try self.allocator.create(CloseWindowEffect);
            errdefer self.allocator.destroy(pending);
            pending.* = .{ .allocator = self.allocator, .app = self, .window = id };
            try self.coordinator.deferEffect(pending.deferred());
            target.close_scheduled = true;
            return;
        }
        if (self.coordinator.phase_state.current != .idle or self.coordinator.phase_state.transaction_depth != 0)
            return error.FramePhaseViolation;
        self.closeWindowInternal(id, true);
    }

    fn window(self: *App, id: handles.WindowId) ?*Window {
        const pointer = self.windows.get(id) orelse return null;
        return pointer.*;
    }

    /// Public service mutation is legal while quiescent or inside the
    /// serialized event/update transaction. Retained build, layout, prepare,
    /// paint, encode, submit, present, and teardown hooks must remain pure with
    /// respect to App-owned registries and native services.
    fn assertMutationPhase(self: *App) Error!void {
        try self.coordinator.affinity.assertCurrent();
        if (self.closing) return error.AppClosed;
        if (self.pending_error) |err| return err;
        switch (self.coordinator.phase_state.current) {
            .idle, .dispatching, .updating => {},
            else => return error.FramePhaseViolation,
        }
    }

    fn assertQuiescentPhase(self: *App) Error!void {
        try self.coordinator.affinity.assertCurrent();
        if (self.closing) return error.AppClosed;
        if (self.pending_error) |err| return err;
        if (self.coordinator.phase_state.current != .idle or
            self.coordinator.phase_state.callback_depth != 0 or
            self.coordinator.phase_state.transaction_depth != 0)
            return error.FramePhaseViolation;
    }

    pub fn hasWindow(self: *App, id: handles.WindowId) Error!bool {
        try self.coordinator.affinity.assertCurrent();
        return self.windows.contains(id);
    }

    pub fn setWindowVisible(self: *App, id: handles.WindowId, visible: bool) Error!void {
        try self.assertMutationPhase();
        const target = self.window(id) orelse return error.InvalidHandle;
        if (target.visible == visible) return;
        try self.bundle.windows.show(id, visible);
        target.visible = visible;
        target.pending_frame = visible;
        if (visible) _ = self.coordinator.invalidations.markWindow(id);
    }

    pub fn setWindowTitle(self: *App, id: handles.WindowId, title: []const u8) Error!void {
        try self.assertMutationPhase();
        if (!self.windows.contains(id)) return error.InvalidHandle;
        if (!std.unicode.utf8ValidateSlice(title) or std.mem.indexOfScalar(u8, title, 0) != null) return error.InvalidUtf8;
        try self.bundle.windows.setTitle(id, title);
    }

    pub fn setWindowCursor(self: *App, id: handles.WindowId, cursor: platform.Cursor) Error!void {
        try self.assertMutationPhase();
        if (!self.windows.contains(id)) return error.InvalidHandle;
        try self.bundle.windows.setCursor(id, cursor);
    }

    pub fn moveWindow(self: *App, id: handles.WindowId, position: geometry.Point) Error!void {
        try self.assertMutationPhase();
        if (!self.windows.contains(id)) return error.InvalidHandle;
        try self.bundle.windows.command(id, .{ .move = position });
    }

    pub fn resizeWindow(self: *App, id: handles.WindowId, size: geometry.Size) Error!void {
        try self.assertMutationPhase();
        if (!self.windows.contains(id)) return error.InvalidHandle;
        try self.bundle.windows.command(id, .{ .resize = size });
    }

    pub fn setWindowMode(self: *App, id: handles.WindowId, mode: platform.WindowMode) Error!void {
        try self.assertMutationPhase();
        const target = self.window(id) orelse return error.InvalidHandle;
        try self.bundle.windows.command(id, .{ .mode = mode });
        target.mode = mode;
    }

    pub fn setWindowAlwaysOnTop(self: *App, id: handles.WindowId, enabled: bool) Error!void {
        try self.assertMutationPhase();
        if (!self.windows.contains(id)) return error.InvalidHandle;
        try self.bundle.windows.command(id, .{ .always_on_top = enabled });
    }

    pub fn displays(self: *App, allocator: std.mem.Allocator) Error!platform.OwnedDisplays {
        try self.assertMutationPhase();
        return self.bundle.displays.list(allocator);
    }

    pub fn registerAction(self: *App, name: []const u8) Error!handles.ActionId {
        try self.assertMutationPhase();
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfScalar(u8, name, 0) != null)
            return error.InvalidConfiguration;
        return self.actions.register(name);
    }

    /// Installs an application-supplied worker host. ZigUI owns no thread pool
    /// or async runtime; the host receives a bounded terminal-completion sink
    /// and must synchronously join its workers during shutdown.
    pub fn installTaskHost(self: *App, host: task.Host) Error!void {
        try self.assertMutationPhase();
        if (self.task_host != null or self.completions != null) return error.InvalidConfiguration;
        const capacity = self.app_config.memory.worker_queue_capacity;
        self.completions = try task.CompletionQueue.init(self.allocator, capacity);
        errdefer {
            if (self.completions) |*queue| queue.deinit();
            self.completions = null;
        }
        try self.coordinator.tasks.setLimit(capacity);
        try host.start(self.completionSink());
        self.task_host = host;
    }

    /// Consumes `context` on every outcome. On acceptance `run_fn` executes on
    /// a worker, `apply_fn` executes once on ZigUI's event-loop thread, and
    /// `drop_fn` destroys the context after apply, cancellation, or rejection.
    pub fn spawnTask(
        self: *App,
        owner: handles.ComponentId,
        context: *anyopaque,
        run_fn: *const fn (*anyopaque, *task.CancellationToken) void,
        apply_fn: *const fn (*anyopaque) void,
        drop_fn: *const fn (*anyopaque) void,
    ) Error!handles.TaskId {
        var context_owned = true;
        errdefer if (context_owned) drop_fn(context);
        try self.assertMutationPhase();
        const host = self.task_host orelse return error.MissingCapability;
        const owner_window = self.components.getWindow(owner) orelse return error.InvalidHandle;
        const registration = try self.coordinator.tasks.create(owner, owner_window);
        const work: task.Work = .{
            .task = registration.id,
            .token = registration.token,
            .context = context,
            .run_fn = run_fn,
            .apply_fn = apply_fn,
            .drop_fn = drop_fn,
        };
        host.spawn(work) catch |err| {
            self.coordinator.tasks.abandon(registration.id);
            return err;
        };
        context_owned = false;
        return registration.id;
    }

    pub fn cancelTask(self: *App, id: handles.TaskId) Error!void {
        try self.assertMutationPhase();
        if (!self.coordinator.tasks.contains(id)) return error.InvalidHandle;
        self.coordinator.tasks.cancel(id);
    }

    /// Drains completed worker results. `run` and `step` call this
    /// automatically; embedders can call it before handing control elsewhere.
    pub fn drainTaskCompletions(self: *App) Error!usize {
        try self.assertQuiescentPhase();
        const completions = if (self.completions) |*queue| queue else return 0;
        var count: usize = 0;
        while (completions.pop()) |completion| {
            var completion_owned = true;
            errdefer if (completion_owned) {
                self.coordinator.tasks.abandon(completion.task);
                completion.drop();
            };
            var update = try self.coordinator.beginUpdate();
            defer if (update.active) update.deinit() catch |err| self.recordPendingError(err);
            var callback = try self.coordinator.phase_state.enterCallback();
            defer callback.deinit();
            const finish = self.coordinator.tasks.finish(completion);
            completion_owned = false;
            callback.deinit();
            try update.deinit();
            switch (finish) {
                .applied => |window_id| _ = self.coordinator.invalidations.markWindow(window_id),
                .stale => self.coordinator.counters.stale_results +|= 1,
                .cancelled => {},
            }
            self.coordinator.counters.worker_messages +|= 1;
            count += 1;
        }
        return count;
    }

    pub fn bindAction(
        self: *App,
        chord: action.Chord,
        action_id: handles.ActionId,
        action_context: action.Context,
        priority: i16,
    ) Error!void {
        try self.assertMutationPhase();
        try self.actions.bind(chord, action_id, action_context, priority);
    }

    pub fn setWindowActionContexts(self: *App, id: handles.WindowId, contexts: []const action.Context) Error!void {
        try self.assertMutationPhase();
        const target = self.window(id) orelse return error.InvalidHandle;
        try target.router.setContexts(contexts);
    }

    pub fn readClipboardText(self: *App, allocator: std.mem.Allocator) Error!?[]u8 {
        try self.assertMutationPhase();
        const clipboard = self.bundle.clipboard orelse return error.MissingCapability;
        return clipboard.readText(allocator);
    }

    pub fn writeClipboardText(self: *App, value: []const u8) Error!void {
        try self.assertMutationPhase();
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidUtf8;
        const clipboard = self.bundle.clipboard orelse return error.MissingCapability;
        try clipboard.writeText(value);
    }

    pub fn readClipboardContents(self: *App, allocator: std.mem.Allocator) Error!platform.ClipboardContents {
        try self.assertMutationPhase();
        const clipboard = self.bundle.clipboard orelse return error.MissingCapability;
        return clipboard.readContents(allocator);
    }

    pub fn writeClipboardPaths(self: *App, paths: []const []const u8) Error!void {
        try self.assertMutationPhase();
        const clipboard = self.bundle.clipboard orelse return error.MissingCapability;
        try clipboard.writePaths(paths);
    }

    pub fn openUrl(self: *App, url: []const u8) Error!void {
        try self.assertMutationPhase();
        const services = self.bundle.application_services orelse return error.MissingCapability;
        try services.openUrl(url);
    }

    pub fn openPath(self: *App, path: []const u8) Error!void {
        try self.assertMutationPhase();
        const services = self.bundle.application_services orelse return error.MissingCapability;
        try services.openPath(path);
    }

    pub fn revealPath(self: *App, path: []const u8) Error!void {
        try self.assertMutationPhase();
        const services = self.bundle.application_services orelse return error.MissingCapability;
        try services.revealPath(path);
    }

    pub fn printPath(self: *App, path: []const u8) Error!void {
        try self.assertMutationPhase();
        const services = self.bundle.application_services orelse return error.MissingCapability;
        try services.printPath(path);
    }

    pub fn createNativeMedia(self: *App, window_id: handles.WindowId, options: platform.NativeMediaOptions) Error!handles.NativeMediaId {
        try self.assertMutationPhase();
        if (!self.windows.contains(window_id)) return error.InvalidHandle;
        const native_media = self.bundle.native_media orelse return error.MissingCapability;
        return native_media.create(window_id, options);
    }

    pub fn setNativeMediaFrame(self: *App, id: handles.NativeMediaId, frame: geometry.Rect) Error!void {
        try self.assertMutationPhase();
        const native_media = self.bundle.native_media orelse return error.MissingCapability;
        try native_media.setFrame(id, frame);
    }
    pub fn playNativeMedia(self: *App, id: handles.NativeMediaId) Error!void {
        try self.assertMutationPhase();
        const service = self.bundle.native_media orelse return error.MissingCapability;
        try service.play(id);
    }
    pub fn pauseNativeMedia(self: *App, id: handles.NativeMediaId) Error!void {
        try self.assertMutationPhase();
        const service = self.bundle.native_media orelse return error.MissingCapability;
        try service.pause(id);
    }
    pub fn seekNativeMedia(self: *App, id: handles.NativeMediaId, position_ns: u64) Error!void {
        try self.assertMutationPhase();
        const service = self.bundle.native_media orelse return error.MissingCapability;
        try service.seek(id, position_ns);
    }
    pub fn setNativeMediaVolume(self: *App, id: handles.NativeMediaId, volume: f32) Error!void {
        try self.assertMutationPhase();
        const service = self.bundle.native_media orelse return error.MissingCapability;
        try service.setVolume(id, volume);
    }
    pub fn setNativeMediaMuted(self: *App, id: handles.NativeMediaId, muted: bool) Error!void {
        try self.assertMutationPhase();
        const service = self.bundle.native_media orelse return error.MissingCapability;
        try service.setMuted(id, muted);
    }
    pub fn nativeMediaState(self: *App, id: handles.NativeMediaId) Error!platform.NativeMediaState {
        try self.assertMutationPhase();
        const service = self.bundle.native_media orelse return error.MissingCapability;
        return service.state(id);
    }
    pub fn destroyNativeMedia(self: *App, id: handles.NativeMediaId) Error!void {
        try self.assertMutationPhase();
        const service = self.bundle.native_media orelse return error.MissingCapability;
        try service.destroy(id);
    }

    pub fn setApplicationMenu(self: *App, items: []const platform.MenuItem) Error!void {
        try self.assertMutationPhase();
        try self.validateMenuItems(items);
        const menus = self.bundle.menus orelse return error.MissingCapability;
        try menus.setApplicationMenu(items);
    }

    pub fn showContextMenu(
        self: *App,
        window_id: handles.WindowId,
        point: geometry.Point,
        items: []const platform.MenuItem,
    ) Error!void {
        try self.assertMutationPhase();
        if (!self.windows.contains(window_id)) return error.InvalidHandle;
        try self.validateMenuItems(items);
        const menus = self.bundle.menus orelse return error.MissingCapability;
        try menus.showContextMenu(window_id, point, items);
    }

    pub fn openFiles(
        self: *App,
        window_id: handles.WindowId,
        multiple: bool,
        allocator: std.mem.Allocator,
    ) Error!platform.OwnedPaths {
        try self.assertMutationPhase();
        if (!self.windows.contains(window_id)) return error.InvalidHandle;
        const dialogs = self.bundle.dialogs orelse return error.MissingCapability;
        return dialogs.openFiles(window_id, multiple, allocator);
    }

    pub fn saveFile(
        self: *App,
        window_id: handles.WindowId,
        suggested_name: []const u8,
        allocator: std.mem.Allocator,
    ) Error!?platform.OwnedPath {
        try self.assertMutationPhase();
        if (!self.windows.contains(window_id)) return error.InvalidHandle;
        if (!std.unicode.utf8ValidateSlice(suggested_name) or std.mem.indexOfScalar(u8, suggested_name, 0) != null)
            return error.InvalidUtf8;
        const dialogs = self.bundle.dialogs orelse return error.MissingCapability;
        return dialogs.saveFile(window_id, suggested_name, allocator);
    }

    fn validateMenuItems(self: *const App, items: []const platform.MenuItem) Error!void {
        var remaining = self.app_config.memory.menu_item_count;
        try validateMenuLevel(
            &self.actions,
            items,
            1,
            self.app_config.memory.menu_depth,
            &remaining,
        );
    }

    pub fn tracer(self: *App) Error!?*tracing.Recorder {
        try self.coordinator.affinity.assertCurrent();
        if (comptime config.tracing_enabled)
            return if (self.trace) |*recorder| recorder else null
        else
            return null;
    }

    /// A UI-thread copy of the counters and most recent phase timings.
    /// Applications can sample this for overlays or export it through their
    /// own telemetry without enabling the detailed trace journal.
    pub fn metricsSnapshot(self: *const App) Error!metrics.Counters {
        try self.coordinator.affinity.assertCurrent();
        return self.coordinator.counters;
    }

    /// The monotonic clock used by the platform event loop and media engine.
    /// Custom animation systems should use this clock so headless replay can
    /// control time deterministically.
    pub fn clockNow(self: *const App) Error!u64 {
        try self.coordinator.affinity.assertCurrent();
        return self.bundle.event_loop.clock.now();
    }

    pub fn rendererCapabilities(self: *const App) Error!render.Capabilities {
        try self.coordinator.affinity.assertCurrent();
        return self.bundle.renderer.capabilities();
    }

    pub fn deviceGeneration(self: *const App) Error!render.DeviceGeneration {
        try self.coordinator.affinity.assertCurrent();
        return self.bundle.renderer.deviceGeneration();
    }

    pub fn loadImage(self: *App, bytes: []const u8) Error!handles.TextureId {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            return manager.load(bytes);
        } else return error.MissingCapability;
    }

    pub fn retainImage(self: *App, texture: handles.TextureId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            try manager.retain(texture);
        } else return error.MissingCapability;
    }

    pub fn releaseImage(self: *App, texture: handles.TextureId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            try manager.release(texture);
        } else return error.MissingCapability;
    }

    pub fn loadSvg(self: *App, bytes: []const u8) Error!handles.SvgId {
        try self.assertMutationPhase();
        if (comptime config.svg_enabled) {
            const manager = if (self.svgs) |*value| value else return error.MissingCapability;
            return manager.load(bytes);
        } else return error.MissingCapability;
    }

    pub fn retainSvg(self: *App, id: handles.SvgId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.svg_enabled) {
            const manager = if (self.svgs) |*value| value else return error.MissingCapability;
            try manager.retain(id);
        } else return error.MissingCapability;
    }

    pub fn releaseSvg(self: *App, id: handles.SvgId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.svg_enabled) {
            const manager = if (self.svgs) |*value| value else return error.MissingCapability;
            try manager.release(id);
        } else return error.MissingCapability;
    }

    pub fn svgIntrinsicSize(self: *App, id: handles.SvgId) Error!geometry.Size {
        try self.coordinator.affinity.assertCurrent();
        if (comptime config.svg_enabled) {
            const manager = if (self.svgs) |*value| value else return error.MissingCapability;
            return manager.intrinsicSize(id) orelse error.InvalidHandle;
        } else return error.MissingCapability;
    }

    pub fn loadAnimation(self: *App, bytes: []const u8) Error!handles.AnimationId {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            return manager.loadAnimation(bytes, self.bundle.event_loop.clock.now());
        } else return error.MissingCapability;
    }

    pub fn animationTexture(self: *App, id: handles.AnimationId) Error!handles.TextureId {
        try self.coordinator.affinity.assertCurrent();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            return manager.animationTexture(id) orelse error.InvalidHandle;
        } else return error.MissingCapability;
    }

    pub fn retainAnimation(self: *App, id: handles.AnimationId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            try manager.retainAnimation(id);
        } else return error.MissingCapability;
    }

    pub fn releaseAnimation(self: *App, id: handles.AnimationId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            try manager.releaseAnimation(id);
        } else return error.MissingCapability;
    }

    pub fn playAnimation(self: *App, id: handles.AnimationId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            try manager.playAnimation(id, self.bundle.event_loop.clock.now());
            try self.invalidateAllWindowFrames();
        } else return error.MissingCapability;
    }

    pub fn pauseAnimation(self: *App, id: handles.AnimationId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            try manager.pauseAnimation(id);
        } else return error.MissingCapability;
    }

    pub fn restartAnimation(self: *App, id: handles.AnimationId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.images_enabled) {
            const manager = if (self.images) |*value| value else return error.MissingCapability;
            try manager.restartAnimation(id, self.bundle.event_loop.clock.now());
            try self.invalidateAllWindowFrames();
        } else return error.MissingCapability;
    }

    /// Consumes `source` on every outcome. This makes native decoder and worker
    /// ownership deterministic even when registration or initial polling is
    /// rejected.
    pub fn createMedia(self: *App, source: media_api.Source) Error!handles.MediaId {
        self.assertMutationPhase() catch |err| {
            source.deinit();
            return err;
        };
        if (comptime config.media_enabled) {
            const manager = if (self.media) |*value| value else {
                source.deinit();
                return error.MissingCapability;
            };
            return manager.create(source, self.bundle.event_loop.clock.now());
        } else {
            source.deinit();
            return error.MissingCapability;
        }
    }

    pub fn createY4mMedia(self: *App, bytes: []const u8) Error!handles.MediaId {
        try self.assertMutationPhase();
        if (comptime config.media_enabled) {
            const source = try y4m.Source.create(
                self.allocator,
                bytes,
                self.app_config.memory.media_frame_count,
                self.app_config.memory.media_encoded_bytes,
                self.app_config.memory.media_decoded_bytes,
            );
            return self.createMedia(source);
        } else return error.MissingCapability;
    }

    pub fn mediaVisual(self: *App, id: handles.MediaId) Error!media_api.Visual {
        try self.coordinator.affinity.assertCurrent();
        if (comptime config.media_enabled) {
            const manager = if (self.media) |*value| value else return error.MissingCapability;
            return manager.visual(id) orelse error.InvalidHandle;
        } else return error.MissingCapability;
    }

    pub fn retainMedia(self: *App, id: handles.MediaId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.media_enabled) {
            const manager = if (self.media) |*value| value else return error.MissingCapability;
            try manager.retain(id);
        } else return error.MissingCapability;
    }

    pub fn releaseMedia(self: *App, id: handles.MediaId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.media_enabled) {
            const manager = if (self.media) |*value| value else return error.MissingCapability;
            try manager.release(id);
        } else return error.MissingCapability;
    }

    pub fn playMedia(self: *App, id: handles.MediaId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.media_enabled) {
            const manager = if (self.media) |*value| value else return error.MissingCapability;
            try manager.play(id, self.bundle.event_loop.clock.now());
            try self.invalidateAllWindowFrames();
        } else return error.MissingCapability;
    }

    pub fn pauseMedia(self: *App, id: handles.MediaId) Error!void {
        try self.assertMutationPhase();
        if (comptime config.media_enabled) {
            const manager = if (self.media) |*value| value else return error.MissingCapability;
            try manager.pause(id, self.bundle.event_loop.clock.now());
        } else return error.MissingCapability;
    }

    pub fn seekMedia(self: *App, id: handles.MediaId, media_ns: u64) Error!void {
        try self.assertMutationPhase();
        if (comptime config.media_enabled) {
            const manager = if (self.media) |*value| value else return error.MissingCapability;
            try manager.seek(id, media_ns, self.bundle.event_loop.clock.now());
            try self.invalidateAllWindowFrames();
        } else return error.MissingCapability;
    }

    pub fn importExternalSurface(self: *App, descriptor: render.ExternalSurfaceDescriptor) Error!handles.SurfaceId {
        try self.assertMutationPhase();
        return self.surfaces.import(descriptor);
    }

    /// Transfers ownership of the extension descriptor context to the active
    /// renderer on success. On error ownership remains with the caller.
    /// Destruction is deferred until every submission that invoked the
    /// extension has completed on the GPU.
    pub fn registerRenderExtension(self: *App, descriptor: render_extension.Descriptor) Error!handles.RenderExtensionId {
        try self.assertMutationPhase();
        return self.bundle.renderer.registerExtension(descriptor);
    }

    pub fn destroyRenderExtension(self: *App, id: handles.RenderExtensionId) Error!void {
        try self.assertMutationPhase();
        try self.bundle.renderer.destroyExtension(id, self.bundle.renderer.completedEpoch());
    }

    pub fn replaceExternalSurface(
        self: *App,
        id: handles.SurfaceId,
        descriptor: render.ExternalSurfaceDescriptor,
    ) Error!void {
        try self.assertMutationPhase();
        try self.surfaces.replace(id, descriptor);
    }

    pub fn destroyExternalSurface(self: *App, id: handles.SurfaceId) Error!void {
        try self.assertMutationPhase();
        try self.surfaces.destroy(id);
    }

    pub fn run(self: *App) Error!void {
        try self.assertQuiescentPhase();
        if (self.running) return error.AlreadyRunning;
        if (self.closing) return error.AppClosed;
        self.running = true;
        defer self.running = false;
        try self.bundle.event_loop.run(self.eventSink());
        if (self.pending_error) |err| return err;
    }

    pub fn step(self: *App, wait: bool) Error!bool {
        try self.assertQuiescentPhase();
        if (self.running) return error.AlreadyRunning;
        self.running = true;
        defer self.running = false;
        const progressed = try self.bundle.event_loop.step(self.eventSink(), wait);
        _ = try self.drainTaskCompletions();
        if (self.pending_error) |err| return err;
        try self.scheduleDirtyWindows();
        return progressed;
    }

    pub fn requestFrame(self: *App, id: handles.WindowId) Error!void {
        try self.assertMutationPhase();
        const target = self.window(id) orelse return error.InvalidHandle;
        if (!target.visible or target.occluded or target.pending_frame or
            target.logical_size.width <= 0 or target.logical_size.height <= 0 or
            target.state == .closed or target.state == .closing or
            target.state == .suspended_or_zero_sized) return;
        try self.bundle.windows.requestFrame(id);
        target.pending_frame = true;
    }

    /// Invalidates retained component composition for an entire window. This
    /// is the escape hatch for application-owned data shared outside ZigUI's
    /// tracked state store. Prefer tracked state or `invalidateComponent`
    /// where the affected component identity is known.
    pub fn invalidateWindow(self: *App, id: handles.WindowId) Error!void {
        try self.assertMutationPhase();
        if (!self.windows.contains(id)) return error.InvalidHandle;
        var marked_component = false;
        var iterator = self.components.iterator();
        while (iterator.next()) |entry| {
            if (!entry.window.eql(id) or !entry.registered) continue;
            _ = self.coordinator.invalidations.markComponent(entry.id, .{});
            marked_component = true;
        }
        if (!marked_component) _ = self.coordinator.invalidations.markWindow(id);
        try self.requestFrame(id);
    }

    /// Marks one retained component dirty. This is the low-level bridge for
    /// application-owned animation clocks and data sources that are updated
    /// outside an input callback; most controls should use state dependencies
    /// or `input.Context.invalidate` instead.
    pub fn invalidateComponent(self: *App, id: handles.ComponentId, dirty: layout_style.Dirty) Error!void {
        try self.assertMutationPhase();
        const window_id = self.components.getWindow(id) orelse return error.InvalidHandle;
        _ = self.coordinator.invalidations.markComponent(id, dirty);
        try self.requestFrame(window_id);
    }

    fn eventSink(self: *App) platform.EventSink {
        return .{ .context = self, .callback = receiveEvent, .pump_callback = receivePump };
    }

    fn receiveEvent(context: *anyopaque, id: handles.WindowId, event: *const platform.WindowEvent) void {
        const self: *App = @ptrCast(@alignCast(context));
        self.handleEvent(id, event) catch |err| {
            self.recordPendingError(err);
        };
    }

    fn receivePump(context: *anyopaque) void {
        const self: *App = @ptrCast(@alignCast(context));
        _ = self.drainTaskCompletions() catch |err| {
            self.recordPendingError(err);
            return;
        };
        self.scheduleDirtyWindows() catch |err| {
            self.recordPendingError(err);
        };
    }

    fn handleEvent(self: *App, id: handles.WindowId, event: *const platform.WindowEvent) Error!void {
        const target = self.window(id) orelse return;
        try platform.validateWindowEvent(event);
        self.coordinator.counters.native_events +|= 1;
        switch (event.*) {
            .created => |native| {
                if (native.kind != target.native.kind or native.value != target.native.value)
                    return error.PlatformFailure;
                target.native = native;
                target.state = .created;
            },
            .configured => |configured| {
                target.logical_size = configured.logical_size;
                target.scale_factor = configured.scale_factor;
                target.state = if (configured.logical_size.width <= 0 or configured.logical_size.height <= 0) .suspended_or_zero_sized else .configured;
                try self.invalidateWindowFrame(id);
            },
            .resized => |size| {
                target.logical_size = size;
                target.state = if (size.width <= 0 or size.height <= 0) .suspended_or_zero_sized else .resizing;
                try self.invalidateWindowFrame(id);
            },
            .scale_changed => |scale_factor| {
                target.scale_factor = scale_factor;
                try self.invalidateWindowFrame(id);
            },
            .focused => |focused_value| target.platform_focused = focused_value,
            .occluded => |occluded| {
                if (target.occluded == occluded) return;
                target.occluded = occluded;
                if (!occluded and self.coordinator.invalidations.isWindowDirty(id))
                    try self.requestFrame(id);
            },
            .input => |value| try self.dispatchInput(target, &value),
            .menu_action => |invocation| try self.dispatchMenuAction(target, invocation),
            .accessibility_action => |request| try self.dispatchAccessibilityAction(target, request),
            .frame_requested => {
                target.pending_frame = false;
                // A Win32 paint generated by newly exposed content is the
                // resume signal after DXGI reported an occluded presentation.
                if (comptime config.compiled_platform == .windows) target.occluded = false;
                if (target.visible and self.coordinator.invalidations.isWindowDirty(id) and !target.occluded) {
                    self.renderWindow(target) catch |err| switch (err) {
                        error.SurfaceLost => try self.recoverSurface(target),
                        error.DeviceLost => try self.recoverDevice(),
                        else => return err,
                    };
                }
            },
            .close_requested => self.closeWindowInternal(id, true),
            .closed => self.closeWindowInternal(id, false),
            .surface_lost => try self.recoverSurface(target),
            .device_lost => try self.recoverDevice(),
            .moved => |position| target.position = position,
            .appearance_changed => |appearance| target.appearance = appearance,
        }
    }

    fn dispatchInput(self: *App, target: *Window, event: *const input.Event) Error!void {
        const target_id = target.id;
        const input_started = self.bundle.event_loop.clock.now();
        var update = try self.coordinator.beginUpdate();
        defer if (update.active) update.deinit() catch |err| self.recordPendingError(err);
        try target.event_arena.resetNow();
        var arena_scope = target.event_arena.enter();
        defer if (arena_scope.active) {
            arena_scope.deinit();
            target.event_arena.requestReset();
        };
        var callback = try self.coordinator.phase_state.enterCallback();
        defer callback.deinit();
        const result = try target.router.dispatch(&self.nodes, &self.coordinator, event, arena_scope.allocator());
        switch (event.*) {
            .pointer_down, .pointer_up, .pointer_move, .pointer_enter => if (self.nodes.getConst(result.target)) |record| {
                const cursor: platform.Cursor = @fromBackingInt(@intCast(@backingInt(record.borrowedStyle().interaction.cursor)));
                try self.bundle.windows.setCursor(target.id, cursor);
            },
            .pointer_leave => try self.bundle.windows.setCursor(target.id, .default),
            else => {},
        }
        if (result.handled or result.focus_changed) _ = self.coordinator.invalidations.markWindow(target.id);
        callback.deinit();
        const record_input_latency = target.last_input_ns == null and self.coordinator.invalidations.isWindowDirty(target.id);
        arena_scope.deinit();
        target.event_arena.requestReset();
        try update.deinit();
        if (record_input_latency) {
            if (self.window(target_id)) |remaining| {
                if (remaining.last_input_ns == null) remaining.last_input_ns = input_started;
            }
        }
    }

    fn dispatchMenuAction(self: *App, target: *Window, invocation: platform.MenuInvocation) Error!void {
        var update = try self.coordinator.beginUpdate();
        defer if (update.active) update.deinit() catch |err| self.recordPendingError(err);
        try target.event_arena.resetNow();
        var arena_scope = target.event_arena.enter();
        defer if (arena_scope.active) {
            arena_scope.deinit();
            target.event_arena.requestReset();
        };
        var callback = try self.coordinator.phase_state.enterCallback();
        defer callback.deinit();
        const action_target = if (target.focus_manager.focused.isValid()) target.focus_manager.focused else target.anchor;
        const handled = try target.router.dispatchAction(&self.nodes, &self.coordinator, action_target, .{
            .id = invocation.action,
            .source = .menu,
            .menu_payload = invocation.payload,
        });
        if (handled) _ = self.coordinator.invalidations.markWindow(target.id);
        callback.deinit();
        arena_scope.deinit();
        target.event_arena.requestReset();
        try update.deinit();
    }

    fn dispatchAccessibilityAction(self: *App, target: *Window, request: @import("a11y/api.zig").ActionRequest) Error!void {
        if (!request.window.eql(target.id)) return error.InvalidHandle;
        const node_id = target.semantic_tree.nodeForSemantic(request.target) orelse return error.InvalidHandle;
        var update = try self.coordinator.beginUpdate();
        defer if (update.active) update.deinit() catch |err| self.recordPendingError(err);
        try target.event_arena.resetNow();
        var arena_scope = target.event_arena.enter();
        defer if (arena_scope.active) {
            arena_scope.deinit();
            target.event_arena.requestReset();
        };
        var callback = try self.coordinator.phase_state.enterCallback();
        defer callback.deinit();
        const event: input.Event = .{ .accessibility = .{
            .target = request.target,
            .action = request.action,
            .value = request.value,
            .selection = request.selection,
        } };
        const result = try target.router.dispatchTo(&self.nodes, &self.coordinator, node_id, &event, arena_scope.allocator());
        if (result.handled or result.focus_changed) _ = self.coordinator.invalidations.markWindow(target.id);
        callback.deinit();
        arena_scope.deinit();
        target.event_arena.requestReset();
        try update.deinit();
    }

    fn renderWindow(self: *App, target: *Window) Error!void {
        if (target.state == .closed or target.state == .closing or target.logical_size.width <= 0 or target.logical_size.height <= 0) return;
        var invalidation_token = self.coordinator.invalidations.windowToken(target.id) orelse return;
        self.frame_sequence +%= 1;
        if (self.frame_sequence == 0) self.frame_sequence = 1;
        const frame_sequence = self.frame_sequence;
        var frame_span: ?tracing.Span = null;
        if (comptime config.tracing_enabled) {
            frame_span = if (self.trace) |*recorder| recorder.begin(.application, .frame, .{
                .first = target.id.encode(),
                .second = target.frame_number + 1,
            }) else null;
        }
        defer {
            if (comptime config.tracing_enabled) if (frame_span) |*span| span.end(.{
                .first = self.coordinator.counters.scene_operations,
                .second = self.coordinator.counters.frames_submitted,
            });
        }
        try target.frame_arena.resetNow();
        var arena_scope = target.frame_arena.enter();
        defer if (arena_scope.active) arena_scope.deinit();
        const scratch = arena_scope.allocator();
        errdefer self.coordinator.phase_state.current = .idle;

        if (comptime config.images_enabled) {
            if (self.images) |*manager| {
                const previous = target.committedScene().view();
                const now = self.bundle.event_loop.clock.now();
                for (previous.color_sprites) |sprite| _ = try manager.advanceTexture(decodeTexture(sprite.texture), now);
            }
        }
        if (comptime config.media_enabled) {
            if (self.media) |*manager| {
                const previous = target.committedScene().view();
                const now = self.bundle.event_loop.clock.now();
                for (previous.color_sprites) |sprite| _ = try manager.tickTexture(decodeTexture(sprite.texture), now);
                for (previous.external_surfaces) |surface_value| _ = try manager.tickSurface(decodeSurface(surface_value.surface), now);
            }
        }

        try self.coordinator.phase_state.transition(.draining);
        try self.coordinator.phase_state.transition(.dispatching);
        try self.coordinator.phase_state.transition(.updating);
        {
            var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .update);
            defer timer.end();
            // Every serialized update boundary drains effects before a frame
            // can be scheduled. Running an arbitrary effect here could close
            // `target` while this frame still owns its arenas and staged data.
            if (self.coordinator.effects.pending() != 0) return error.FramePhaseViolation;
        }
        const previous_focus = target.focus_manager.focused;
        const previous_focus_endpoint = try target.router.captureFocusEndpoint(&self.nodes, previous_focus, scratch);
        var root: handles.NodeId = .invalid;
        var layout_feedback: LayoutFeedback = .{ .coordinator = &self.coordinator };
        var engine: layout_engine.Engine = .{
            .scratch = scratch,
            .scale_factor = target.scale_factor,
            .measures = self.textMeasures(),
            .maximum_grid_cells = self.app_config.memory.layout_grid_cell_count,
            .svg = self.svgServices(),
            .feedback_context = &layout_feedback,
            .request_recompose_fn = LayoutFeedback.request,
        };
        var layout_passes: usize = 0;
        try self.coordinator.phase_state.transition(.composing);
        while (true) {
            {
                var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .compose);
                defer timer.end();
                try self.composeWindow(target, scratch);
                try self.nodes.validateTree(target.anchor, scratch);
            }
            root = self.components.root(target.root_component) orelse return error.InvalidHandle;
            try self.coordinator.phase_state.transition(.measuring);
            {
                var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .measure);
                defer timer.end();
                _ = try engine.measureNode(&self.nodes, target.anchor, .{ .minimum = target.logical_size, .maximum = target.logical_size });
            }
            layout_feedback.requested = false;
            try self.coordinator.phase_state.transition(.arranging);
            {
                var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .arrange);
                defer timer.end();
                try engine.arrangeNode(&self.nodes, target.anchor, .{ .origin = .{}, .size = target.logical_size });
                try engine.arrangePortals(&self.nodes, target.anchor, .{ .origin = .{}, .size = target.logical_size });
            }
            if (!layout_feedback.requested) break;
            layout_passes += 1;
            if (layout_passes > 8) return error.BudgetExceeded;
            invalidation_token = self.coordinator.invalidations.windowToken(target.id) orelse invalidation_token;
            try self.coordinator.phase_state.transition(.composing);
        }

        try self.coordinator.phase_state.transition(.preparing);
        {
            var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .prepare);
            defer timer.end();
            if (comptime config.text_enabled) {
                if (self.text) |*system| {
                    system.beginFrame(frame_sequence, target.scale_factor);
                    try system.prepareTree(&self.nodes, root);
                }
            }
            if (comptime config.images_enabled) if (self.images) |*manager| manager.beginFrame(frame_sequence);
            var preparer: scene_painter.Preparer = .{
                .scratch = scratch,
                .scale_factor = target.scale_factor,
                .device_generation = self.bundle.renderer.deviceGeneration(),
            };
            try preparer.prepare(&self.nodes, root);
        }

        try self.coordinator.phase_state.transition(.building_scene);
        const target_scene = target.sceneForBuild();
        {
            var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .scene);
            defer timer.end();
            var builder = scene.Builder.init(target_scene, target.scene_limits);
            defer builder.deinit();
            var painter: scene_painter.Painter = .{
                .builder = &builder,
                .text = self.textPainter(),
                .svg = self.svgServices(),
                .scratch = scratch,
                .scale_factor = target.scale_factor,
            };
            try painter.paint(&self.nodes, root);
            try builder.finish();
        }

        var hit_tree_pending = false;
        defer if (hit_tree_pending) target.hits.discardPrepared();
        try target.hits.prepare(&self.nodes, target.anchor);
        hit_tree_pending = true;

        var focus_pending = false;
        defer if (focus_pending) target.focus_manager.discardPrepared();
        const prepared_focus = try target.focus_manager.prepare(&self.nodes, target.anchor);
        const committed_focus_changed = !previous_focus.eql(prepared_focus.focused);
        const committed_focus = prepared_focus.focused;
        focus_pending = true;

        var prepared_semantics: ?a11y_tree.Prepared = null;
        if (comptime config.accessibility_enabled) prepared_semantics = try target.semantic_tree.prepare(
            &self.nodes,
            target.anchor,
            prepared_focus.focused,
            scratch,
        );
        var semantics_pending = prepared_semantics != null;
        defer {
            if (prepared_semantics) |*prepared| prepared.deinit();
            if (semantics_pending) target.semantic_tree.discardPrepared();
        }
        self.coordinator.counters.scene_operations +|= target_scene.operations.items.len;
        self.coordinator.counters.scene_primitives +|= scenePrimitiveCount(target_scene.view());
        const source_upload_bytes = try render.structuredUploadBytes(
            target_scene.view(),
            std.mem.sliceAsBytes(target_scene.path_vertices.items).len,
            std.mem.sliceAsBytes(target_scene.clips.items).len,
        );
        self.coordinator.counters.upload_bytes +|= source_upload_bytes;

        try self.coordinator.phase_state.transition(.encoding);
        const token = blk: {
            var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .encode);
            defer timer.end();
            try self.prepareSceneResources(target_scene.view());
            break :blk try self.bundle.renderer.beginFrame(.{
                .window = target.id,
                .logical_size = target.logical_size,
                .drawable_width = try target.drawableWidth(),
                .drawable_height = try target.drawableHeight(),
                .scale_factor = target.scale_factor,
                .clear_color = target.clear_color,
                .maximum_upload_bytes = self.app_config.memory.upload_ring_bytes,
            });
        };
        try self.coordinator.phase_state.transition(.submitting);
        const submission = blk: {
            var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .submit);
            defer timer.end();
            break :blk try self.bundle.renderer.submit(token, target_scene.view());
        };
        const keep_animating = self.sceneContainsPlayingAnimation(target_scene.view());
        if (comptime config.tracing_enabled) if (self.trace) |*recorder| recorder.instant(.renderer, .render_submit, .{
            .first = target.id.encode(),
            .second = submission.epoch,
            .third = target_scene.operations.items.len,
        });
        if (comptime config.text_enabled) if (self.text) |*system| try system.markSubmitted(submission.epoch);
        try self.markSceneResources(target_scene.view(), submission.epoch);
        try self.coordinator.phase_state.transition(.presenting);
        {
            var timer = metrics.PhaseTimer.begin(&self.coordinator.counters, self.bundle.event_loop.clock, .present);
            defer timer.end();
            target.commitScene();
            try self.syncNativeMediaPlacements(target.id, target.committedScene().native_media_placements.items);
            try target.hits.commitPrepared();
            hit_tree_pending = false;
            try target.focus_manager.commitPrepared(prepared_focus);
            focus_pending = false;
            if (prepared_semantics) |*prepared| {
                const semantic_snapshot = try target.semantic_tree.commitPrepared(prepared);
                semantics_pending = false;
                if (self.bundle.accessibility) |adapter| try adapter.update(&semantic_snapshot);
            }
        }
        target.state = .configured;
        self.coordinator.counters.frames_built +|= 1;
        self.coordinator.counters.frames_submitted +|= 1;
        if (submission.presented) self.coordinator.counters.frames_presented +|= 1;
        if (submission.presented) if (target.last_input_ns) |started| {
            self.coordinator.counters.input_to_present_ns = self.bundle.event_loop.clock.now() -| started;
            target.last_input_ns = null;
        };
        _ = self.coordinator.invalidations.consumeWindowToken(target.id, invalidation_token);
        try self.coordinator.phase_state.transition(.idle);
        if (!submission.presented) {
            // Preserve the newest committed frame as dirty without spinning
            // Present while the native compositor reports full occlusion.
            target.occluded = true;
            _ = self.coordinator.invalidations.markWindow(target.id);
        } else if (keep_animating) {
            _ = self.coordinator.invalidations.markWindow(target.id);
            try self.requestFrame(target.id);
        }
        var focus_update: ?coordinator_mod.Coordinator.Update = null;
        var focus_dispatch_error: ?Error = null;
        if (committed_focus_changed) {
            _ = self.coordinator.invalidations.markWindow(target.id);
            try self.requestFrame(target.id);
            focus_update = try self.coordinator.beginUpdate();
            self.dispatchCommittedFocusTransition(target, previous_focus_endpoint, committed_focus) catch |err| {
                focus_dispatch_error = err;
            };
        }
        // A focus callback may have scheduled window closure. Release every
        // frame-scratch borrow before ending its update transaction, because
        // that boundary is allowed to flush the close effect and destroy the
        // window immediately.
        arena_scope.deinit();
        if (focus_update) |*update| {
            if (focus_dispatch_error) |dispatch_error| {
                update.deinit() catch |effect_error| self.recordPendingError(effect_error);
                return dispatch_error;
            }
            try update.deinit();
        }
    }

    fn dispatchCommittedFocusTransition(
        self: *App,
        target: *Window,
        previous: ?@import("input/router.zig").CapturedFocusEndpoint,
        next: handles.NodeId,
    ) Error!void {
        try target.event_arena.resetNow();
        var arena_scope = target.event_arena.enter();
        defer if (arena_scope.active) {
            arena_scope.deinit();
            target.event_arena.requestReset();
        };
        var callback = try self.coordinator.phase_state.enterCallback();
        defer callback.deinit();
        try target.router.dispatchCommittedFocusTransition(&self.nodes, &self.coordinator, previous, next);
        callback.deinit();
        arena_scope.deinit();
        target.event_arena.requestReset();
    }

    fn sceneContainsPlayingAnimation(self: *App, view: render.SceneView) bool {
        if (comptime config.images_enabled) {
            if (self.images) |*manager| for (view.color_sprites) |sprite|
                if (manager.isPlayingTexture(decodeTexture(sprite.texture))) return true;
        }
        if (comptime config.media_enabled) {
            if (self.media) |*media_manager_value| {
                for (view.color_sprites) |sprite| if (media_manager_value.isPlayingTexture(decodeTexture(sprite.texture))) return true;
                for (view.external_surfaces) |surface_value| if (media_manager_value.isPlayingSurface(decodeSurface(surface_value.surface))) return true;
            }
        }
        return false;
    }

    fn invalidateAllWindowFrames(self: *App) Error!void {
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| try self.invalidateWindowFrame(entry.id);
    }

    /// Dirties only the existing retained scene. Native geometry changes,
    /// resource animation, and renderer recovery do not require recomposing
    /// application components.
    fn invalidateWindowFrame(self: *App, id: handles.WindowId) Error!void {
        if (!self.windows.contains(id)) return error.InvalidHandle;
        _ = self.coordinator.invalidations.markWindow(id);
        try self.requestFrame(id);
    }

    fn markSceneResources(self: *App, view: render.SceneView, submission: render.SubmissionEpoch) Error!void {
        for (view.monochrome_sprites) |sprite| try self.resources.markUsed(decodeTexture(sprite.texture), submission);
        for (view.color_sprites) |sprite| try self.resources.markUsed(decodeTexture(sprite.texture), submission);
        for (view.external_surfaces) |surface_value| try self.surfaces.markUsed(decodeSurface(surface_value.surface), submission);
    }

    fn syncNativeMediaPlacements(self: *App, window_id: handles.WindowId, placements: []const @import("core/native_media.zig").Placement) Error!void {
        if (self.bundle.native_media) |service| return service.synchronize(window_id, placements);
        if (placements.len != 0) return error.MissingCapability;
    }

    fn prepareSceneResources(self: *App, view: render.SceneView) Error!void {
        for (view.monochrome_sprites) |sprite| try self.resources.realize(self.bundle.renderer, decodeTexture(sprite.texture));
        for (view.color_sprites) |sprite| try self.resources.realize(self.bundle.renderer, decodeTexture(sprite.texture));
        for (view.external_surfaces) |surface_value| try self.surfaces.validateUse(decodeSurface(surface_value.surface));
    }

    fn composeWindow(self: *App, target: *Window, scratch: std.mem.Allocator) Error!void {
        var passes: usize = 0;
        while (true) {
            var built_any = false;
            var iterator = self.components.iterator();
            while (iterator.next()) |entry| {
                if (!entry.window.eql(target.id) or !entry.registered) continue;
                const dirty = self.coordinator.invalidations.consumeComponent(entry.id) orelse continue;
                if (!dirty.any()) continue;
                _ = self.components.build(entry.id, &self.nodes, &self.coordinator, scratch) catch |err| {
                    _ = self.coordinator.invalidations.markComponent(entry.id, dirty);
                    return err;
                };
                built_any = true;
            }
            self.components.beginMountPass(target.id, target.root_component);
            try self.attachNestedComponents(target, target.anchor);
            self.components.finishMountPass(target.id, target.root_component, &self.coordinator);
            if (!built_any) break;
            passes += 1;
            if (passes > 4096) return error.BudgetExceeded;
        }
    }

    fn attachNestedComponents(self: *App, target: *Window, node_id: handles.NodeId) Error!void {
        const record = self.nodes.getConst(node_id) orelse return;
        switch (record.kind) {
            .component => |component| {
                const owner_window = self.components.getWindow(component) orelse return error.InvalidHandle;
                if (!owner_window.eql(target.id)) return error.InvalidHandle;
                if (try self.components.mount(component, node_id, record.component)) {
                    try self.coordinator.invalidations.register(component, target.id);
                    _ = try self.components.markRegistered(component);
                }
            },
            else => {},
        }
        for (record.children.items) |child| try self.attachNestedComponents(target, child);
    }

    fn scheduleDirtyWindows(self: *App) Error!void {
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| if (self.coordinator.invalidations.isWindowDirty(entry.id)) try self.requestFrame(entry.id);
    }

    fn recoverDevice(self: *App) Error!void {
        try self.bundle.renderer.recover(self.app_config.gpu);
        self.resources.deviceLost();
        self.surfaces.deviceLost();
        if (comptime config.media_enabled) if (self.media) |*manager| try manager.deviceLost(self.bundle.event_loop.clock.now());
        if (comptime config.text_enabled) if (self.text) |*system| try system.deviceLost();
        self.coordinator.counters.device_recoveries +|= 1;
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| {
            entry.value.*.state = .device_lost;
            try self.invalidateWindowFrame(entry.id);
        }
    }

    fn recoverSurface(self: *App, target: *Window) Error!void {
        target.state = .surface_lost;
        try self.bundle.renderer.invalidateSurface(target.id);
        try self.invalidateWindowFrame(target.id);
    }

    fn closeWindowInternal(self: *App, id: handles.WindowId, destroy_native: bool) void {
        const pointer = self.windows.remove(id) orelse return;
        const target = pointer;
        target.state = .closing;
        if (self.bundle.accessibility) |adapter| adapter.removeWindow(id);
        if (destroy_native) self.bundle.windows.destroy(id);
        self.components.destroy(target.root_component, &self.nodes, &self.coordinator);
        self.coordinator.invalidations.unregisterWindow(id);
        self.nodes.destroyTree(target.anchor);
        target.state = .closed;
        target.deinit();
        self.allocator.destroy(target);
        if (!self.closing and self.app_config.quit_when_last_window_closes and self.windows.live_count == 0) self.bundle.event_loop.requestQuit();
    }

    fn completionSink(self: *App) task.CompletionSink {
        const queue = if (self.completions) |*value| value else unreachable;
        return .{
            .queue = queue,
            .wake_context = self,
            .wake_fn = wakeForCompletion,
        };
    }

    fn shutdownTaskHost(self: *App) void {
        self.coordinator.tasks.cancelAll();
        if (self.task_host) |host| host.shutdown();
        self.task_host = null;
        if (self.completions) |*queue| {
            queue.close();
            while (queue.pop()) |completion| switch (self.coordinator.tasks.finish(completion)) {
                .stale => self.coordinator.counters.stale_results +|= 1,
                else => {},
            };
            queue.deinit();
        }
        self.completions = null;
    }

    fn recordPendingError(self: *App, err: Error) void {
        if (self.pending_error == null) self.pending_error = err;
        self.bundle.event_loop.requestQuit();
    }

    fn textMeasures(self: *App) layout_engine.MeasureProvider {
        if (comptime config.text_enabled) if (self.text) |*system| return system.measureProvider();
        return noTextMeasureProvider();
    }

    fn textPainter(self: *App) ?scene_painter.TextPainter {
        if (comptime config.text_enabled) if (self.text) |*system| return system.painter();
        return null;
    }

    fn svgServices(self: *App) ?compose_custom.SvgServices {
        if (comptime config.svg_enabled) if (self.svgs) |*manager| return manager.services();
        return null;
    }
};

const CloseWindowEffect = struct {
    allocator: std.mem.Allocator,
    app: *App,
    window: handles.WindowId,

    fn deferred(self: *CloseWindowEffect) @import("runtime/effect.zig").Deferred {
        return .{ .context = self, .run_fn = run, .drop_fn = drop };
    }

    fn run(raw: *anyopaque) void {
        const self: *CloseWindowEffect = @ptrCast(@alignCast(raw));
        self.app.closeWindowInternal(self.window, true);
    }

    fn drop(raw: *anyopaque) void {
        const self: *CloseWindowEffect = @ptrCast(@alignCast(raw));
        self.allocator.destroy(self);
    }
};

fn wakeForCompletion(context: *anyopaque) void {
    const self: *App = @ptrCast(@alignCast(context));
    self.bundle.event_loop.wake();
}

fn boundBundleServices(bundle: *platform.Bundle, memory: config.MemoryBudgets) void {
    bundle.windows.maximum_text_bytes = @min(bundle.windows.maximum_text_bytes, memory.platform_text_bytes);
    bundle.displays.maximum_count = @min(bundle.displays.maximum_count, memory.platform_object_count);
    bundle.displays.maximum_text_bytes = @min(bundle.displays.maximum_text_bytes, memory.platform_text_bytes);
    if (bundle.text_input) |*text_input| text_input.maximum_surrounding_text_bytes = @min(
        text_input.maximum_surrounding_text_bytes,
        memory.platform_text_bytes,
    );
    if (bundle.clipboard) |*clipboard| {
        clipboard.maximum_bytes = @min(clipboard.maximum_bytes, memory.clipboard_bytes);
        clipboard.maximum_paths = @min(clipboard.maximum_paths, memory.file_drop_path_count);
    }
    if (bundle.application_services) |*services| services.maximum_text_bytes = @min(
        services.maximum_text_bytes,
        memory.platform_text_bytes,
    );
    if (bundle.native_media) |*native_media| native_media.maximum_source_bytes = @min(
        native_media.maximum_source_bytes,
        memory.platform_text_bytes,
    );
    if (bundle.native_media) |*native_media| native_media.maximum_placements = @min(
        native_media.maximum_placements,
        memory.media_source_count,
    );
    if (bundle.menus) |*menus| {
        menus.limits.maximum_items = @min(menus.limits.maximum_items, memory.menu_item_count);
        menus.limits.maximum_depth = @min(menus.limits.maximum_depth, memory.menu_depth);
        menus.limits.maximum_text_bytes = @min(menus.limits.maximum_text_bytes, memory.menu_text_bytes);
    }
    if (bundle.dialogs) |*dialogs| {
        dialogs.limits.maximum_paths = @min(dialogs.limits.maximum_paths, memory.file_drop_path_count);
        dialogs.limits.maximum_path_bytes = @min(dialogs.limits.maximum_path_bytes, memory.platform_event_payload_bytes);
        dialogs.limits.maximum_suggested_name_bytes = @min(dialogs.limits.maximum_suggested_name_bytes, memory.platform_text_bytes);
    }
}

fn validateBundleConfiguration(bundle: platform.Bundle) Error!void {
    if (bundle.windows.maximum_text_bytes == 0 or bundle.displays.maximum_count == 0 or
        bundle.displays.maximum_text_bytes == 0)
        return error.InvalidConfiguration;
    if (bundle.text_input) |text_input| if (text_input.maximum_surrounding_text_bytes == 0)
        return error.InvalidConfiguration;
    if (bundle.clipboard) |clipboard| if (clipboard.maximum_bytes == 0 or clipboard.maximum_paths == 0)
        return error.InvalidConfiguration;
    if (bundle.application_services) |services| if (services.maximum_text_bytes == 0)
        return error.InvalidConfiguration;
    if (bundle.native_media) |native_media| if (native_media.maximum_source_bytes == 0 or native_media.maximum_placements == 0)
        return error.InvalidConfiguration;
    if (bundle.menus) |menus| if (menus.limits.maximum_items == 0 or menus.limits.maximum_depth == 0 or
        menus.limits.maximum_text_bytes == 0)
        return error.InvalidConfiguration;
    if (bundle.dialogs) |dialogs| if (dialogs.limits.maximum_paths == 0 or dialogs.limits.maximum_path_bytes == 0 or
        dialogs.limits.maximum_suggested_name_bytes == 0)
        return error.InvalidConfiguration;
}

fn deinitUnclaimedBundle(bundle: platform.Bundle) void {
    if (bundle.accessibility) |adapter| adapter.deinit();
    if (bundle.text_backend) |backend| backend.deinit();
    bundle.renderer.deinit();
    bundle.deinit();
}

fn validateMenuLevel(
    actions: *const action.Registry,
    items: []const platform.MenuItem,
    depth: usize,
    maximum_depth: usize,
    remaining: *usize,
) Error!void {
    if (depth > maximum_depth or items.len > remaining.*) return error.BudgetExceeded;
    remaining.* -= items.len;
    for (items) |item| switch (item) {
        .action => |definition| {
            if (!std.unicode.utf8ValidateSlice(definition.label) or std.mem.indexOfScalar(u8, definition.label, 0) != null)
                return error.InvalidUtf8;
            if (!actions.contains(definition.action)) return error.InvalidHandle;
        },
        .submenu => |submenu| {
            if (!std.unicode.utf8ValidateSlice(submenu.label) or std.mem.indexOfScalar(u8, submenu.label, 0) != null)
                return error.InvalidUtf8;
            try validateMenuLevel(actions, submenu.items, depth + 1, maximum_depth, remaining);
        },
        .separator => {},
    };
}

fn decodeTexture(encoded: u64) handles.TextureId {
    return .{ .index = @truncate(encoded), .generation = @truncate(encoded >> 32) };
}

fn decodeSurface(encoded: u64) handles.SurfaceId {
    return .{ .index = @truncate(encoded), .generation = @truncate(encoded >> 32) };
}

fn scenePrimitiveCount(view: render.SceneView) u64 {
    var count: u64 = 0;
    inline for (.{
        view.shadows.len,
        view.quads.len,
        view.paths.len,
        view.underlines.len,
        view.monochrome_sprites.len,
        view.color_sprites.len,
        view.external_surfaces.len,
        view.custom_passes.len,
    }) |length| count +|= @intCast(length);
    return count;
}

fn sceneLimits(memory: config.MemoryBudgets) scene.Limits {
    return .{
        .operations = memory.scene_operation_count,
        .materials = memory.scene_material_count,
        .gradient_stops = memory.scene_gradient_stop_count,
        .clips = memory.scene_clip_count,
        .layers = memory.scene_layer_count,
        .primitives = memory.scene_primitive_count,
        .path_vertices = memory.scene_path_vertex_count,
        .custom_passes = memory.scene_custom_pass_count,
        .custom_payload_bytes = memory.scene_custom_payload_bytes,
        .native_media_placements = memory.media_source_count,
    };
}

fn validColor(value: geometry.Color) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and
        std.math.isFinite(value.b) and std.math.isFinite(value.a) and
        value.a >= 0 and value.a <= 1;
}

fn noTextMeasureProvider() layout_engine.MeasureProvider {
    return .{ .context = @ptrFromInt(1), .text_fn = noTextMeasure, .custom_measure_fn = noCustomTextMeasure };
}

fn noTextMeasure(
    _: *anyopaque,
    _: []const u8,
    _: @import("compose/style.zig").TextStyle,
    _: layout_style.Constraints,
) Error!layout_engine.TextMeasure {
    return error.TextUnavailable;
}

fn noCustomTextMeasure(
    _: *anyopaque,
    _: []const u8,
    _: @import("compose/style.zig").TextStyle,
    _: layout_style.Constraints,
) Error!geometry.Size {
    return error.TextUnavailable;
}
