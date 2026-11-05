const std = @import("std");
const ui = @import("zigui");

const testing = std.testing;
const handles = ui.core.handles;

const WindowCloseProbe = struct {
    app: ?*ui.App = null,
    calls: usize = 0,
    window: ?handles.WindowId = null,
    observed_live_window: bool = false,
    observed_native_window: bool = false,

    fn closeRequested(raw: *anyopaque, window: handles.WindowId) ui.Error!void {
        const self: *WindowCloseProbe = @ptrCast(@alignCast(raw));
        const app = self.app orelse return error.InvalidConfiguration;
        self.calls += 1;
        self.window = window;
        self.observed_live_window = try app.hasWindow(window);
        self.observed_native_window = app.bundle.windows.nativeHandle(window) != null;
    }
};

const ReentrantWindowCloseProbe = struct {
    app: ?*ui.App = null,
    destroy_error: ?ui.Error = null,
    recursive_close_succeeded: bool = false,

    fn closeRequested(raw: *anyopaque, window: handles.WindowId) ui.Error!void {
        const self: *ReentrantWindowCloseProbe = @ptrCast(@alignCast(raw));
        const app = self.app orelse return error.InvalidConfiguration;
        app.destroy() catch |err| {
            self.destroy_error = err;
        };
        try app.closeWindow(window);
        self.recursive_close_succeeded = true;
    }
};

const FramePulseProbe = struct {
    app: ?*ui.App = null,
    native_media: ?handles.NativeMediaId = null,
    builds: usize = 0,
    frames: usize = 0,
    media_state_reads: usize = 0,
    active: bool = false,
    stop_at_ns: u64 = 0,
    timestamps: [4]u64 = @splat(0),

    pub fn build(self: *FramePulseProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.builds += 1;
        return .{};
    }

    pub fn frame(self: *FramePulseProbe, now_ns: u64) ui.Error!ui.Component.FrameUpdate {
        if (!self.active) return .{};
        if (self.native_media) |id| {
            _ = try self.app.?.nativeMediaState(id);
            self.media_state_reads += 1;
        }
        if (self.frames < self.timestamps.len) self.timestamps[self.frames] = now_ns;
        self.frames += 1;
        if (now_ns >= self.stop_at_ns) self.active = false;
        return .{
            // The frame hook is an explicit custom-paint timeline. Its
            // retained tree is stable, so this must not rebuild components or
            // rerun layout on every display tick.
            .dirty = .{ .compose = false, .layout = false, .paint = true, .hit_test = false, .semantics = false, .resources = false },
            .request_next_frame = self.active,
        };
    }
};

const OffscreenPollFrameProbe = struct {
    app: *ui.App,
    request: ui.render.OffscreenRequestId,
    allocator: std.mem.Allocator,
    component: handles.ComponentId = .invalid,
    task_counts: *TaskContextCounts,
    polls: usize = 0,
    pending_polls: usize = 0,
    ready: bool = false,
    failed: bool = false,

    pub fn build(self: *OffscreenPollFrameProbe, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.component = ctx.component;
        return .{ .kind = .spacer };
    }

    pub fn frame(self: *OffscreenPollFrameProbe, _: u64) ui.Error!ui.Component.FrameUpdate {
        if (self.request == 0) return .{};
        self.polls += 1;
        const result = self.app.pollOffscreen(self.request, self.allocator) catch {
            self.failed = true;
            return .{};
        };
        switch (result) {
            .pending => self.pending_polls += 1,
            .ready => |readback| {
                var owned = readback;
                owned.deinit(self.allocator);
                const task = TaskContext.create(self.task_counts) catch {
                    self.failed = true;
                    return .{};
                };
                _ = self.app.spawnTask(self.component, task, TaskContext.run, TaskContext.apply, TaskContext.drop) catch {
                    self.failed = true;
                    return .{};
                };
                self.ready = true;
            },
            .failed, .cancelled => self.failed = true,
        }
        return .{
            .dirty = .{ .compose = false, .layout = false, .paint = true, .hit_test = false, .semantics = false, .resources = false },
            .request_next_frame = !self.ready and !self.failed,
        };
    }
};

const PageCapturePollFrameProbe = struct {
    app: *ui.App,
    request: ui.platform.PageCaptureRequestId = .invalid,
    allocator: std.mem.Allocator,
    polls: usize = 0,
    pending_polls: usize = 0,
    completed: bool = false,
    failed: bool = false,

    pub fn build(_: *PageCapturePollFrameProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        return .{ .kind = .spacer };
    }

    pub fn frame(self: *PageCapturePollFrameProbe, _: u64) ui.Error!ui.Component.FrameUpdate {
        if (!self.request.isValid() or self.completed or self.failed) return .{};
        self.polls += 1;
        const result = self.app.pollPageCapture(self.request, self.allocator) catch {
            self.failed = true;
            return .{};
        };
        switch (result) {
            .pending => self.pending_polls += 1,
            .terminal => |*completion| {
                var owned = completion.*;
                owned.deinit();
                self.completed = true;
            },
        }
        return .{
            .dirty = .{ .compose = false, .layout = false, .paint = true, .hit_test = false, .semantics = false, .resources = false },
            .request_next_frame = !self.completed and !self.failed,
        };
    }
};

const PromisedPollFrameProbe = struct {
    app: *ui.App,
    operation: ui.platform.PromisedFileOperationId = .invalid,
    allocator: std.mem.Allocator,
    polls: usize = 0,
    pending_polls: usize = 0,
    completed: bool = false,
    failed: bool = false,

    pub fn build(_: *PromisedPollFrameProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        return .{ .kind = .spacer };
    }

    pub fn frame(self: *PromisedPollFrameProbe, _: u64) ui.Error!ui.Component.FrameUpdate {
        if (!self.operation.isValid()) return .{};
        self.polls += 1;
        const result = self.app.pollPromisedFiles(self.operation, self.allocator) catch {
            self.failed = true;
            return .{};
        };
        switch (result) {
            .pending => self.pending_polls += 1,
            .terminal => |*completion| {
                var owned = completion.*;
                owned.deinit();
                self.completed = true;
            },
        }
        return .{
            .dirty = .{ .compose = false, .layout = false, .paint = true, .hit_test = false, .semantics = false, .resources = false },
            .request_next_frame = !self.completed and !self.failed,
        };
    }
};

const BuildPhaseServiceProbe = struct {
    app: *ui.App,
    request: ui.render.OffscreenRequestId,
    task_counts: *TaskContextCounts,
    spawn_error: ?ui.Error = null,
    poll_error: ?ui.Error = null,

    pub fn build(self: *BuildPhaseServiceProbe, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const task = try TaskContext.create(self.task_counts);
        _ = self.app.spawnTask(ctx.component, task, TaskContext.run, TaskContext.apply, TaskContext.drop) catch |err| {
            self.spawn_error = err;
        };
        _ = self.app.pollOffscreen(self.request, testing.allocator) catch |err| {
            self.poll_error = err;
        };
        return .{ .kind = .spacer };
    }
};

const BuildPageCaptureProbe = struct {
    app: *ui.App,
    request: ui.platform.PageCaptureRequestId,
    poll_error: ?ui.Error = null,

    pub fn build(self: *BuildPageCaptureProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        _ = self.app.pollPageCapture(self.request, testing.allocator) catch |err| {
            self.poll_error = err;
        };
        return .{ .kind = .spacer };
    }
};

const FocusCloseProbe = struct {
    app: ?*ui.App = null,
    calls: usize = 0,
    handlers: [1]ui.input.Handler = undefined,

    pub fn build(self: *FocusCloseProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.handlers[0] = .{ .context = self, .callback = focusEvent, .phase = .bubble };
        return .{
            .style = .{ .interaction = .{ .focusable = true, .autofocus = true } },
            .handlers = &self.handlers,
        };
    }

    fn focusEvent(
        raw: *anyopaque,
        _: *ui.input.Dispatch,
        event: *const ui.input.Event,
        context: *ui.input.Context,
    ) ui.Error!void {
        const self: *FocusCloseProbe = @ptrCast(@alignCast(raw));
        if (event.* != .focus_in) return;
        self.calls += 1;
        try self.app.?.closeWindow(context.window);
    }
};

test "generational handles reject stale identities and reuse slots" {
    const Pool = handles.SlotPool(u32, handles.NodeId);
    var pool = Pool.init(testing.allocator);
    defer pool.deinit();

    const first = try pool.insert(41);
    try testing.expect(first.isValid());
    try testing.expectEqual(@as(u32, 41), pool.get(first).?.*);
    try testing.expectEqual(@as(u32, 41), pool.remove(first).?);
    try testing.expect(!pool.contains(first));

    const second = try pool.insert(73);
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);
    try testing.expect(pool.get(first) == null);
    try testing.expectEqual(@as(u32, 73), pool.get(second).?.*);
}

test "state writes advance versions and destroyed state stays invalid" {
    var store = ui.runtime_state.Store.init(testing.allocator);
    defer store.deinit();

    const owner = handles.ComponentId.init(4, 1);
    const value = try store.create(u32, owner, 8);
    try testing.expectEqual(@as(u64, 1), try store.version(value.id));
    try testing.expectEqual(@as(u32, 8), (try store.read(u32, value, null)).*);

    var write = try store.beginWrite(u32, value);
    write.value().* = 13;
    write.deinit();
    try testing.expectEqual(@as(u64, 2), try store.version(value.id));
    try testing.expectEqual(@as(u32, 13), (try store.read(u32, value, null)).*);

    try store.destroy(u32, value);
    try testing.expectError(error.InvalidHandle, store.version(value.id));
    try testing.expectError(error.InvalidHandle, store.read(u32, value, null));
}

test "state dependencies invalidate only recorded retained components" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component = handles.ComponentId.init(2, 1);
    const window = handles.WindowId.init(3, 1);
    try coordinator.invalidations.register(component, window);
    _ = coordinator.invalidations.consumeComponent(component);
    _ = coordinator.invalidations.consumeWindow(window);

    const state = try coordinator.states.create(u32, component, 5);
    var dependencies = try coordinator.beginComponentDependencies(component, testing.allocator);
    defer dependencies.deinit();
    _ = try coordinator.states.read(u32, state, dependencies.sink());
    try dependencies.finish();

    var write = try coordinator.states.beginWrite(u32, state);
    write.value().* = 6;
    write.deinit();
    var update = try coordinator.beginUpdate();
    try update.deinit();
    try testing.expect(coordinator.invalidations.isWindowDirty(window));
    try testing.expect(coordinator.invalidations.consumeComponent(component).?.compose);
}

const WindowCompositionProbe = struct {
    builds: usize = 0,
    component: handles.ComponentId = .invalid,

    pub fn build(self: *WindowCompositionProbe, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.builds +|= 1;
        self.component = ctx.component;
        return .{ .kind = .spacer };
    }
};

const CustomEventInvalidationProbe = struct {
    builds: usize = 0,
    measures: usize = 0,
    arranges: usize = 0,
    prepares: usize = 0,
    paints: usize = 0,
    semantics_calls: usize = 0,
    events: usize = 0,
    request_narrow: bool = true,

    pub fn build(self: *CustomEventInvalidationProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.builds += 1;
        return .{
            .kind = .{ .custom = ui.custom.Node.from(CustomEventInvalidationProbe, self) },
            .style = .{ .layout = .{ .width = .{ .points = 320 }, .height = .{ .points = 240 } } },
        };
    }

    pub fn measure(self: *CustomEventInvalidationProbe, _: *ui.custom.MeasureContext, _: ui.layout.Constraints) ui.Error!ui.Size {
        self.measures += 1;
        return .{ .width = 320, .height = 240 };
    }

    pub fn arrange(self: *CustomEventInvalidationProbe, _: *ui.custom.ArrangeContext, _: ui.Rect) ui.Error!void {
        self.arranges += 1;
    }

    pub fn prepare(self: *CustomEventInvalidationProbe, _: *ui.custom.PrepareContext, _: ui.Rect) ui.Error!void {
        self.prepares += 1;
    }

    pub fn paint(self: *CustomEventInvalidationProbe, context: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        self.paints += 1;
        try context.quad(.{ .bounds = bounds, .background = ui.Color.rgba8(40, 48, 64, 255), .border_color = .transparent, .border_widths = .{}, .radii = .{} });
    }

    pub fn semantics(self: *CustomEventInvalidationProbe, writer: *ui.custom.SemanticsWriter, bounds: ui.Rect) ui.Error!void {
        self.semantics_calls += 1;
        _ = try writer.append(1, .{ .role = .button, .label = "custom invalidation probe", .bounds = bounds, .actions = &.{.activate} });
    }

    pub fn event(self: *CustomEventInvalidationProbe, dispatch: *ui.input.Dispatch, value: *const ui.input.Event, context: *ui.input.Context) ui.Error!void {
        if (value.* != .pointer_down) return;
        self.events += 1;
        dispatch.handled = true;
        if (self.request_narrow) try context.invalidate(.{
            .compose = false,
            .layout = false,
            .paint = true,
            .hit_test = false,
            .semantics = true,
            .resources = false,
        });
    }
};

const AppearanceProbe = struct {
    builds: usize = 0,
    last: ui.Appearance = .system,

    pub fn build(self: *AppearanceProbe, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.builds += 1;
        self.last = ctx.appearance;
        return .{ .kind = .spacer };
    }
};

const LargeInitialTree = struct {
    pub fn build(_: *LargeInitialTree, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const children = try ctx.allocator.alloc(ui.NodeSpec, 2_048);
        for (children) |*child| child.* = .{ .kind = .spacer };
        return .{ .children = children };
    }
};

test "custom handled events preserve explicit narrow invalidation" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "custom event invalidation test",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;

    var model: CustomEventInvalidationProbe = .{};
    const window = try app.openWindow(.{ .platform = .{ .title = "custom event invalidation", .size = .{ .width = 320, .height = 240 } } }, ui.Component.Descriptor.from(CustomEventInvalidationProbe, &model));
    while (try app.step(false)) {}
    const settled = model;

    try harness.post(window, .{ .input = .{ .pointer_down = .{ .position = .{ .x = 20, .y = 20 }, .button = .primary } } });
    while (try app.step(false)) {}
    try testing.expectEqual(@as(usize, 1), model.events);
    try testing.expectEqual(settled.builds, model.builds);
    try testing.expectEqual(settled.measures, model.measures);
    try testing.expectEqual(settled.arranges, model.arranges);
    try testing.expectEqual(settled.prepares, model.prepares);
    try testing.expectEqual(settled.paints + 1, model.paints);
    try testing.expectEqual(settled.semantics_calls + 1, model.semantics_calls);

    model.request_narrow = false;
    try harness.post(window, .{ .input = .{ .pointer_down = .{ .position = .{ .x = 24, .y = 24 }, .button = .primary } } });
    while (try app.step(false)) {}
    try testing.expectEqual(@as(usize, 2), model.events);
    try testing.expect(model.builds > settled.builds);
    try testing.expect(model.measures > settled.measures);
    try testing.expect(model.arranges > settled.arranges);
    try testing.expect(model.prepares > settled.prepares);
    try testing.expect(model.paints > settled.paints + 1);
    try testing.expect(model.semantics_calls > settled.semantics_calls + 1);
}

test "initial reconciliation keeps compact undo entries within the default frame arena" {
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "large initial reconciliation test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;

    var model: LargeInitialTree = .{};
    _ = try app.openWindow(.{ .platform = .{ .title = "large tree" } }, ui.Component.Descriptor.from(LargeInitialTree, &model));
    while (try app.step(false)) {}
    try testing.expectEqual(@as(u64, 1), (try app.metricsSnapshot()).frames_submitted);
}

test "whole-window invalidation rebuilds only that window's components" {
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "window composition invalidation test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;

    var first: WindowCompositionProbe = .{};
    var second: WindowCompositionProbe = .{};
    _ = try app.openWindow(.{ .platform = .{ .title = "first" } }, ui.Component.Descriptor.from(WindowCompositionProbe, &first));
    const second_window = try app.openWindow(.{ .platform = .{ .title = "second" } }, ui.Component.Descriptor.from(WindowCompositionProbe, &second));
    while (try app.step(false)) {}

    const first_builds = first.builds;
    const second_builds = second.builds;
    try app.invalidateWindow(second_window);
    while (try app.step(false)) {}

    try testing.expectEqual(first_builds, first.builds);
    try testing.expectEqual(second_builds + 1, second.builds);
}

test "delayed component invalidation wakes only at its deadline" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "delayed invalidation test",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;

    var model: WindowCompositionProbe = .{};
    _ = try app.openWindow(.{ .platform = .{ .title = "delayed invalidation" } }, ui.Component.Descriptor.from(WindowCompositionProbe, &model));
    while (try app.step(false)) {}
    const settled_builds = model.builds;
    const deadline = 3 * std.time.ns_per_s;
    try app.invalidateComponentAt(model.component, .{}, deadline);

    try testing.expect(!(try app.step(false)));
    try testing.expectEqual(settled_builds, model.builds);
    harness.advance(deadline - 1);
    try testing.expect(!(try app.step(false)));
    try testing.expectEqual(settled_builds, model.builds);
    harness.advance(1);
    try testing.expect(try app.step(false));
    while (try app.step(false)) {}
    try testing.expectEqual(settled_builds + 1, model.builds);
}

test "appearance is resolved for composition and duplicate events do not repaint" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "appearance conformance test",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;

    var model: AppearanceProbe = .{};
    const window = try app.openWindow(.{ .platform = .{ .title = "appearance" } }, ui.Component.Descriptor.from(AppearanceProbe, &model));
    while (try app.step(false)) {}
    try testing.expectEqual(ui.Appearance.light, model.last);
    try testing.expectEqual(@as(usize, 1), model.builds);
    const settled = try app.metricsSnapshot();

    try harness.post(window, .{ .appearance_changed = .dark });
    while (try app.step(false)) {}
    try testing.expectEqual(ui.Appearance.dark, model.last);
    try testing.expectEqual(@as(usize, 2), model.builds);
    const changed = try app.metricsSnapshot();
    try testing.expectEqual(settled.frames_submitted + 1, changed.frames_submitted);

    try harness.post(window, .{ .appearance_changed = .dark });
    while (try app.step(false)) {}
    const duplicate = try app.metricsSnapshot();
    try testing.expectEqual(@as(usize, 2), model.builds);
    try testing.expectEqual(changed.frames_submitted, duplicate.frames_submitted);
}

test "window mode follows resolved platform events and deduplicates no-op transitions" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "window mode conformance test",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;

    var model: AppearanceProbe = .{};
    const window = try app.openWindow(.{ .platform = .{ .title = "window mode" } }, ui.Component.Descriptor.from(AppearanceProbe, &model));
    while (try app.step(false)) {}
    try testing.expectEqual(ui.platform.WindowMode.normal, try app.windowMode(window));
    const settled = try app.metricsSnapshot();

    // A platform command is asynchronous from App's perspective: the getter
    // remains at the last confirmed value until the queued event is handled.
    try app.setWindowMode(window, .maximized);
    try testing.expectEqual(ui.platform.WindowMode.normal, try app.windowMode(window));
    while (try app.step(false)) {}
    try testing.expectEqual(ui.platform.WindowMode.maximized, try app.windowMode(window));
    const maximized = try app.metricsSnapshot();
    try testing.expectEqual(settled.frames_submitted + 1, maximized.frames_submitted);

    // Headless command adapters and native callbacks must not produce a
    // second transition when the resolved mode is already current.
    try app.setWindowMode(window, .maximized);
    while (try app.step(false)) {}
    const duplicate_command = try app.metricsSnapshot();
    try testing.expectEqual(maximized.frames_submitted, duplicate_command.frames_submitted);

    try harness.post(window, .{ .mode_changed = .fullscreen });
    while (try app.step(false)) {}
    try testing.expectEqual(ui.platform.WindowMode.fullscreen, try app.windowMode(window));
    const fullscreen = try app.metricsSnapshot();
    try testing.expectEqual(maximized.frames_submitted + 1, fullscreen.frames_submitted);

    try harness.post(window, .{ .mode_changed = .fullscreen });
    while (try app.step(false)) {}
    const duplicate_event = try app.metricsSnapshot();
    try testing.expectEqual(fullscreen.frames_submitted, duplicate_event.frames_submitted);
}

test "component frame hook follows the platform clock and stops requesting frames" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    var native_media_probe: NativeMediaProbe = .{};
    var bundle = harness.bundle;
    bundle.native_media = native_media_probe.service();
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "component frame hook test",
    }, bundle);
    defer app.destroy() catch unreachable;

    var model: FramePulseProbe = .{ .app = app };
    const window = try app.openWindow(.{ .platform = .{ .title = "frame hook" } }, ui.Component.Descriptor.fromWithFrame(FramePulseProbe, &model));
    model.native_media = try app.createNativeMedia(window, .{
        .source = .{ .file = "/tmp/frame-hook.mov" },
        .frame = ui.Rect.fromXYWH(0, 0, 320, 180),
    });
    defer app.destroyNativeMedia(model.native_media.?) catch unreachable;
    while (try app.step(false)) {}
    const settled_builds = model.builds;

    model.active = true;
    model.stop_at_ns = 16 * std.time.ns_per_ms;
    try app.invalidateWindow(window);
    try testing.expect(try app.step(false));
    harness.advance(8 * std.time.ns_per_ms);
    try testing.expect(try app.step(false));
    harness.advance(8 * std.time.ns_per_ms);
    try testing.expect(try app.step(false));

    try testing.expectEqual(@as(usize, 3), model.frames);
    try testing.expectEqual(@as(usize, 3), model.media_state_reads);
    try testing.expectEqual(@as(u64, 0), model.timestamps[0]);
    try testing.expectEqual(@as(u64, 8 * std.time.ns_per_ms), model.timestamps[1]);
    try testing.expectEqual(@as(u64, 16 * std.time.ns_per_ms), model.timestamps[2]);
    // The first invalidated frame still composes; subsequent display-driven
    // frames remain paint-only and reuse the retained tree.
    try testing.expectEqual(settled_builds + 1, model.builds);
    try testing.expect(!model.active);
    try testing.expect(!(try app.step(false)));
}

test "deferred drawable frames keep input live and preserve dirty content" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(testing.allocator, 8 * 1024 * 1024, 16 * 1024 * 1024, 64, 64, 64 * 1024);
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "deferred drawable test",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;
    var model: CustomEventInvalidationProbe = .{};
    const window = try app.openWindow(.{ .platform = .{ .title = "deferred", .size = .{ .width = 320, .height = 240 } } }, ui.Component.Descriptor.from(CustomEventInvalidationProbe, &model));
    while (try app.step(false)) {}
    const before = try app.metricsSnapshot();
    const original = app.bundle.renderer.vtable;
    const Gate = struct {
        var ready: bool = false;
        var attempts: usize = 0;
        var begin: @TypeOf(original.begin_frame) = undefined;
        fn beginFrame(raw: *anyopaque, descriptor: ui.render.FrameDescriptor) ui.Error!ui.render.FrameToken {
            attempts += 1;
            if (!ready) return error.FrameNotReady;
            return begin(raw, descriptor);
        }
    };
    Gate.ready = false;
    Gate.attempts = 0;
    Gate.begin = original.begin_frame;
    var table = original.*;
    table.begin_frame = Gate.beginFrame;
    app.bundle.renderer.vtable = &table;
    defer app.bundle.renderer.vtable = original;
    try app.invalidateWindow(window);
    for (0..4) |_| _ = try app.step(false);
    try testing.expect(Gate.attempts > 0);
    try testing.expectEqual(before.frames_submitted, (try app.metricsSnapshot()).frames_submitted);
    try harness.post(window, .{ .input = .{ .pointer_down = .{ .position = .{ .x = 20, .y = 20 }, .button = .primary } } });
    for (0..8) |_| {
        _ = try app.step(false);
        if (model.events > 0) break;
    }
    try testing.expectEqual(@as(usize, 1), model.events);
    try testing.expectEqual(before.frames_submitted, (try app.metricsSnapshot()).frames_submitted);
    Gate.ready = true;
    var settled = false;
    for (0..16) |_| {
        if (!try app.step(false)) {
            settled = true;
            break;
        }
    }
    try testing.expect(settled);
    try testing.expectEqual(before.frames_submitted + 1, (try app.metricsSnapshot()).frames_submitted);
    try testing.expect(!app.coordinator.invalidations.isWindowDirty(window));
}

test "App records presented timestamps and leaves presentation counters idle" {
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "presentation metrics test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;

    var model: WindowCompositionProbe = .{};
    _ = try app.openWindow(.{ .platform = .{ .title = "presentation metrics" } }, ui.Component.Descriptor.from(WindowCompositionProbe, &model));
    while (try app.step(false)) {}

    const settled = try app.metricsSnapshot();
    try testing.expect(settled.presentation.presented_count > 0);
    try testing.expectEqual(@as(u32, 60_000), settled.presentation.refresh_millihertz);
    try testing.expectEqual(settled.frames_presented, settled.presentation.presented_count);
    try testing.expect(settled.presentation.latest_timestamp_ns != null);

    // No dirty window means no event-loop redraw or submission. This is the
    // observable idle proof used alongside the bounded timestamp ring.
    try testing.expect(!(try app.step(false)));
    const idle = try app.metricsSnapshot();
    try testing.expectEqual(settled.frames_submitted, idle.frames_submitted);
    try testing.expectEqual(settled.frames_presented, idle.frames_presented);
    try testing.expectEqual(settled.presentation.presented_count, idle.presentation.presented_count);
    try testing.expectEqual(settled.presentation.dropped_count, idle.presentation.dropped_count);
}

test "window close callback runs before the framework destroys the window" {
    var probe: WindowCloseProbe = .{};
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "window close callback test",
        .window_close_callback = .{ .context = &probe, .callback = WindowCloseProbe.closeRequested },
    });
    defer app.destroy() catch unreachable;
    probe.app = app;

    var model: WindowCompositionProbe = .{};
    const window = try app.openWindow(.{ .platform = .{ .title = "close callback", .visible = false } }, ui.Component.Descriptor.from(WindowCompositionProbe, &model));
    try app.closeWindow(window);

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(window, probe.window.?);
    try testing.expect(probe.observed_live_window);
    try testing.expect(probe.observed_native_window);
    try testing.expect(!(try app.hasWindow(window)));
}

test "window close callback cannot tear down App while the caller retains it" {
    var probe: ReentrantWindowCloseProbe = .{};
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "reentrant close lifetime test",
        .window_close_callback = .{ .context = &probe, .callback = ReentrantWindowCloseProbe.closeRequested },
    });
    defer app.destroy() catch unreachable;
    probe.app = app;

    var model: WindowCompositionProbe = .{};
    const window = try app.openWindow(
        .{ .platform = .{ .title = "reentrant close lifetime", .visible = false } },
        ui.Component.Descriptor.from(WindowCompositionProbe, &model),
    );
    try app.closeWindow(window);
    try testing.expectEqual(error.CallbackReentrancy, probe.destroy_error.?);
    try testing.expect(probe.recursive_close_succeeded);
    try testing.expect(!(try app.hasWindow(window)));
}

test "native close request invokes the public callback before destruction" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    const text_backend = text_backend_instance.interface();
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend);
    const bundle = harness.bundle;
    harness.bundle = undefined;

    var probe: WindowCloseProbe = .{};
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "native close callback test",
        .window_close_callback = .{ .context = &probe, .callback = WindowCloseProbe.closeRequested },
    }, bundle);
    defer app.destroy() catch unreachable;
    probe.app = app;

    var model: WindowCompositionProbe = .{};
    const window = try app.openWindow(.{ .platform = .{ .title = "native close callback" } }, ui.Component.Descriptor.from(WindowCompositionProbe, &model));
    while (try app.step(false)) {}
    try harness.post(window, .close_requested);
    while (try app.step(false)) {}

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(window, probe.window.?);
    try testing.expect(probe.observed_live_window);
    try testing.expect(probe.observed_native_window);
    try testing.expect(!(try app.hasWindow(window)));
}

test "focus callback can close window without invalid deferred composition cleanup" {
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "focus close cleanup test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;

    var probe: FocusCloseProbe = .{ .app = app };
    const window = try app.openWindow(
        .{ .platform = .{ .title = "focus close cleanup" } },
        ui.Component.Descriptor.from(FocusCloseProbe, &probe),
    );
    while (try app.step(false)) {}

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expect(!(try app.hasWindow(window)));
}

test "App exposes backend-neutral offscreen scene readback" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "offscreen App API test",
    }, bundle);
    defer app.destroy() catch unreachable;

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .background = ui.Color.rgba(1, 0, 0, 1),
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.finish();

    var readback = (try app.renderOffscreen(.{
        .width = 4,
        .height = 4,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    try testing.expect(pixel(readback, 2, 2)[0] > 240);
    try testing.expect(pixel(readback, 2, 2)[3] > 240);
}

test "async offscreen readback copies scene and consumes terminal result once" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    const renderer = try ui.NullRenderer.createWithMemory(testing.allocator, memory);
    defer renderer.deinit();

    var source = ui.scene.Scene.init(testing.allocator);
    const id = blk: {
        var builder = ui.scene.Builder.init(&source, .{});
        defer builder.deinit();
        try builder.quad(.{
            .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
            .background = ui.Color.rgba(1, 0, 0, 1),
            .border_color = .transparent,
            .border_widths = .{},
            .radii = .{},
        }, null);
        try builder.finish();
        break :blk try renderer.beginOffscreen(.{
            .width = 4,
            .height = 4,
            .scale_factor = try ui.ScaleFactor.init(1),
            .format = .rgba8_srgb,
        }, source.view());
    };
    // The request owns a complete copy, so destroying the producer scene is
    // safe before the backend reports readiness.
    source.deinit();

    try testing.expectError(error.BudgetExceeded, renderer.beginOffscreen(.{
        .width = 4,
        .height = 4,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    }, .{
        .operations = &.{},
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = &.{},
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    }));

    try testing.expectEqual(ui.render.OffscreenPoll.pending, try renderer.pollOffscreen(id, testing.allocator));
    const result = try renderer.pollOffscreen(id, testing.allocator);
    switch (result) {
        .ready => |readback| {
            var owned = readback;
            defer owned.deinit(testing.allocator);
            try testing.expect(pixel(owned, 2, 2)[0] > 240);
            try testing.expect(pixel(owned, 2, 2)[3] > 240);
        },
        else => return error.TestExpectedEqual,
    }
    try testing.expectError(error.InvalidHandle, renderer.pollOffscreen(id, testing.allocator));
}

test "async offscreen cancellation retains ownership until terminal poll" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    const id = try renderer.beginOffscreen(.{
        .width = 2,
        .height = 2,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    }, .{
        .operations = &.{},
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = &.{},
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    });
    try renderer.cancelOffscreen(id);
    try testing.expectEqual(ui.render.OffscreenPoll.pending, try renderer.pollOffscreen(id, testing.allocator));
    try testing.expectEqual(ui.render.OffscreenPoll.cancelled, try renderer.pollOffscreen(id, testing.allocator));
    try testing.expectError(error.InvalidHandle, renderer.cancelOffscreen(id));
}

test "App permits asynchronous offscreen polling from a component frame hook" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "async offscreen frame poll test",
        .allow_multiple_apps_for_testing = true,
        .memory = memory,
    });
    defer app.destroy() catch unreachable;

    var task_counts: TaskContextCounts = .{};
    var probe: OffscreenPollFrameProbe = .{
        .app = app,
        .request = 0,
        .allocator = testing.allocator,
        .task_counts = &task_counts,
    };
    const window = try app.openWindow(
        .{ .platform = .{ .title = "async offscreen frame poll" } },
        ui.Component.Descriptor.fromWithFrame(OffscreenPollFrameProbe, &probe),
    );
    while (try app.step(false)) {}
    var host_probe: TaskHostProbe = .{ .mode = .complete };
    try app.installTaskHost(host_probe.host());

    probe.request = try app.beginOffscreen(.{
        .width = 2,
        .height = 2,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    }, .{
        .operations = &.{},
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = &.{},
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    });
    try app.invalidateWindow(window);

    var steps: usize = 0;
    while (try app.step(false)) {
        steps += 1;
        if (probe.ready or probe.failed or steps >= 16) break;
    }
    try testing.expect(probe.pending_polls >= 1);
    try testing.expect(probe.ready);
    try testing.expect(!probe.failed);
    try testing.expectEqual(@as(usize, 1), task_counts.runs);
    _ = try app.drainTaskCompletions();
    try testing.expectEqual(@as(usize, 1), task_counts.applies);
    try testing.expectEqual(@as(usize, 1), task_counts.drops);
}

test "App page capture mirrors terminal ownership and generational release" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "page capture App API test",
        .allow_multiple_apps_for_testing = true,
        .memory = memory,
    });
    defer app.destroy() catch unreachable;

    const request = try app.beginPageCapture(.{
        .url = "https://example.com/preview",
        .size = .{ .width = 320, .height = 180 },
    });
    try testing.expect(request.isValid());
    try testing.expectError(error.ResourceBusy, app.releasePageCapture(request));
    try testing.expectEqual(ui.platform.PageCapturePoll.pending, try app.pollPageCapture(request, testing.allocator));

    var terminal = try app.pollPageCapture(request, testing.allocator);
    switch (terminal) {
        .pending => return error.TestUnexpectedResult,
        .terminal => |*completion| {
            defer completion.deinit();
            try testing.expectEqual(ui.platform.PageCaptureTerminalStatus.completed, completion.status);
            try testing.expect(completion.result != null);
        },
    }
    try testing.expectError(error.InvalidHandle, app.pollPageCapture(request, testing.allocator));
    try app.releasePageCapture(request);
    try testing.expectError(error.InvalidHandle, app.releasePageCapture(request));

    const canceled = try app.beginPageCapture(.{ .url = "https://example.com/canceled" });
    try app.cancelPageCapture(canceled);
    var canceled_terminal = try app.pollPageCapture(canceled, testing.allocator);
    switch (canceled_terminal) {
        .pending => return error.TestUnexpectedResult,
        .terminal => |*completion| {
            defer completion.deinit();
            try testing.expectEqual(ui.platform.PageCaptureTerminalStatus.canceled, completion.status);
            try testing.expect(completion.result == null);
        },
    }
    try app.releasePageCapture(canceled);
}

test "App permits nonblocking page capture polling from a component frame hook" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "page capture frame poll test",
        .allow_multiple_apps_for_testing = true,
        .memory = memory,
    });
    defer app.destroy() catch unreachable;

    var probe: PageCapturePollFrameProbe = .{ .app = app, .allocator = testing.allocator };
    const window = try app.openWindow(
        .{ .platform = .{ .title = "page capture frame poll" } },
        ui.Component.Descriptor.fromWithFrame(PageCapturePollFrameProbe, &probe),
    );
    while (try app.step(false)) {}

    probe.request = try app.beginPageCapture(.{ .url = "https://example.com/frame" });
    try app.invalidateWindow(window);
    var steps: usize = 0;
    while (try app.step(false)) {
        steps += 1;
        if (probe.completed or probe.failed or steps >= 8) break;
    }
    try testing.expectEqual(@as(usize, 1), probe.pending_polls);
    try testing.expectEqual(@as(usize, 2), probe.polls);
    try testing.expect(probe.completed);
    try testing.expect(!probe.failed);
    try app.releasePageCapture(probe.request);
}

test "App permits nonblocking promised-file polling from a component frame hook" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "promised file frame poll test",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;

    const descriptors = [_]ui.platform.PromisedFileDescriptor{
        .{ .suggested_name = "frame.txt", .content_type = "public.plain-text" },
    };
    const outcomes = [_]ui.HeadlessPlatform.FakePromisedOutcome{
        .{ .path = "/tmp/promised/frame.txt" },
    };
    const batch = try harness.addPromisedBatch(&descriptors, &outcomes);

    var probe: PromisedPollFrameProbe = .{
        .app = app,
        .allocator = testing.allocator,
    };
    const window = try app.openWindow(
        .{ .platform = .{ .title = "promised file frame poll" } },
        ui.Component.Descriptor.fromWithFrame(PromisedPollFrameProbe, &probe),
    );
    while (try app.step(false)) {}

    probe.operation = try app.beginPromisedFiles(batch, "/tmp/promised-frame-destination");
    try app.releasePromisedFileBatch(batch);
    try app.invalidateWindow(window);
    var steps: usize = 0;
    while (try app.step(false)) {
        steps += 1;
        if (probe.completed or probe.failed or steps >= 8) break;
    }
    try testing.expectEqual(@as(usize, 1), probe.pending_polls);
    try testing.expectEqual(@as(usize, 2), probe.polls);
    try testing.expect(probe.completed);
    try testing.expect(!probe.failed);
    // Completion release is a state mutation and must be performed by the
    // event/update path after the frame hook has consumed its value.
    try app.releasePromisedFileOperation(probe.operation);
}

test "ordinary retained build cannot poll offscreen or spawn tasks" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "build service phase guard test",
        .allow_multiple_apps_for_testing = true,
        .memory = memory,
    });
    defer app.destroy() catch unreachable;

    const request = try app.beginOffscreen(.{
        .width = 1,
        .height = 1,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    }, .{
        .operations = &.{},
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = &.{},
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    });
    var task_counts: TaskContextCounts = .{};
    var probe: BuildPhaseServiceProbe = .{
        .app = app,
        .request = request,
        .task_counts = &task_counts,
    };
    _ = try app.openWindow(
        .{ .platform = .{ .title = "build service phase guard" } },
        ui.Component.Descriptor.from(BuildPhaseServiceProbe, &probe),
    );
    while (try app.step(false)) {}

    try testing.expectEqual(error.FramePhaseViolation, probe.spawn_error.?);
    try testing.expectEqual(error.FramePhaseViolation, probe.poll_error.?);
    try testing.expectEqual(@as(usize, 1), task_counts.drops);
    try app.cancelOffscreen(request);
}

test "ordinary retained build cannot poll page capture" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "page capture phase guard test",
        .allow_multiple_apps_for_testing = true,
        .memory = memory,
    });
    defer app.destroy() catch unreachable;

    const request = try app.beginPageCapture(.{ .url = "https://example.com/phase" });
    var probe: BuildPageCaptureProbe = .{ .app = app, .request = request };
    _ = try app.openWindow(
        .{ .platform = .{ .title = "page capture phase guard" } },
        ui.Component.Descriptor.from(BuildPageCaptureProbe, &probe),
    );
    while (try app.step(false)) {}

    try testing.expectEqual(error.FramePhaseViolation, probe.poll_error.?);
    try app.cancelPageCapture(request);
}

test "frame callback scope guard resets after every exit" {
    var state: ui.runtime_phase.State = .{ .current = .composing };
    {
        var guard = try state.enterFrameCallback();
        try testing.expectEqual(@as(u32, 1), state.frame_callback_depth);
        guard.deinit();
    }
    try testing.expectEqual(@as(u32, 0), state.frame_callback_depth);
    var second = try state.enterFrameCallback();
    second.deinit();
    try testing.expectEqual(@as(u32, 0), state.frame_callback_depth);
}

test "async null offscreen retains referenced textures through resource retirement" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    const texture = handles.TextureId.init(17, 1);
    try renderer.createTexture(texture, .{ .width = 2, .height = 2, .format = .rgba8 });
    defer renderer.destroyTexture(texture, 0) catch {};
    const texels = [_]u8{
        255, 0, 0, 255, 255, 0, 0, 255,
        255, 0, 0, 255, 255, 0, 0, 255,
    };
    try renderer.writeTexture(texture, .{ .width = 2, .height = 2 }, &texels, 8);

    var scene = ui.scene.Scene.init(testing.allocator);
    const id = blk: {
        var builder = ui.scene.Builder.init(&scene, .{});
        defer builder.deinit();
        try builder.colorSprite(.{
            .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
            .uv_bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
            .color = .white,
            .texture = texture.encode(),
            .tile_generation = texture.generation,
            .format = @backingInt(ui.scene_abi.TextureFormat.rgba8),
        });
        try builder.finish();
        break :blk try renderer.beginOffscreen(.{
            .width = 4,
            .height = 4,
            .scale_factor = try ui.ScaleFactor.init(1),
            .format = .rgba8,
        }, scene.view());
    };
    // Retiring the producer's texture must not invalidate the pending request.
    try renderer.destroyTexture(texture, 0);
    scene.deinit();

    try testing.expectEqual(ui.render.OffscreenPoll.pending, try renderer.pollOffscreen(id, testing.allocator));
    const result = try renderer.pollOffscreen(id, testing.allocator);
    switch (result) {
        .ready => |readback| {
            var owned = readback;
            defer owned.deinit(testing.allocator);
            try testing.expect(pixel(owned, 2, 2)[0] > 240);
            try testing.expect(pixel(owned, 2, 2)[3] > 240);
        },
        else => return error.TestExpectedEqual,
    }
}

test "SceneSnapshot has a strong allocation-failure guarantee" {
    try testing.checkAllAllocationFailures(testing.allocator, sceneSnapshotAllocationProbe, .{});
}

test "App drains pending asynchronous offscreen requests during teardown" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "async offscreen lifecycle test",
        .memory = memory,
    });
    var destroyed = false;
    defer if (!destroyed) app.destroy() catch unreachable;

    const id = try app.beginOffscreen(.{
        .width = 2,
        .height = 2,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    }, .{
        .operations = &.{},
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = &.{},
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    });
    try testing.expect(id != 0);
    try app.cancelOffscreen(id);
    try app.destroy();
    destroyed = true;
}

test "App clears asynchronous offscreen registry across device recovery" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 1;
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    var harness = try ui.HeadlessPlatform.createWithMemory(testing.allocator, text_backend_instance.interface(), memory);
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "async offscreen recovery test",
        .allow_multiple_apps_for_testing = true,
        .memory = memory,
    }, bundle);
    defer app.destroy() catch unreachable;

    var model: WindowCompositionProbe = .{};
    const window = try app.openWindow(.{ .platform = .{ .title = "async offscreen recovery" } }, ui.Component.Descriptor.from(WindowCompositionProbe, &model));
    while (try app.step(false)) {}
    _ = try app.beginOffscreen(.{
        .width = 2,
        .height = 2,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    }, .{
        .operations = &.{},
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = &.{},
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    });

    try harness.post(window, .device_lost);
    while (try app.step(false)) {}

    const recovered_id = try app.beginOffscreen(.{
        .width = 2,
        .height = 2,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8_srgb,
    }, .{
        .operations = &.{},
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = &.{},
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    });
    try testing.expect(recovered_id != 0);
    try app.cancelOffscreen(recovered_id);
}

test "a frame token cannot consume invalidation raised during that frame" {
    var counters: ui.core.metrics.Counters = .{};
    var tracker = ui.runtime_invalidation.Tracker.init(testing.allocator, &counters);
    defer tracker.deinit();
    const component = handles.ComponentId.init(2, 1);
    const window = handles.WindowId.init(3, 1);
    try tracker.register(component, window);
    const token = tracker.windowToken(window).?;
    try testing.expect(!tracker.markWindow(window));
    try testing.expect(!tracker.consumeWindowToken(window, token));
    try testing.expect(tracker.isWindowDirty(window));
    const latest = tracker.windowToken(window).?;
    try testing.expect(tracker.consumeWindowToken(window, latest));
    try testing.expect(!tracker.isWindowDirty(window));
}

test "dirty phase plans preserve dependency boundaries" {
    const paint: ui.layout.Dirty = .{
        .compose = false,
        .layout = false,
        .paint = true,
        .hit_test = false,
        .semantics = false,
        .resources = false,
    };
    const paint_plan = ui.runtime_invalidation.PhasePlan.fromDirty(paint);
    try testing.expect(!paint_plan.compose);
    try testing.expect(!paint_plan.layout);
    try testing.expect(!paint_plan.prepare);
    try testing.expect(paint_plan.scene);
    try testing.expect(!paint_plan.hit_test);
    try testing.expect(!paint_plan.focus);
    try testing.expect(!paint_plan.semantics);
    try testing.expect(!paint_plan.resources);
    try testing.expect(paint_plan.submit);
    try testing.expect(paint_plan.toDirty().paint);

    const layout_dirty: ui.layout.Dirty = .{
        .compose = false,
        .layout = true,
        .paint = false,
        .hit_test = false,
        .semantics = false,
        .resources = false,
    };
    const layout_plan = ui.runtime_invalidation.PhasePlan.fromDirty(layout_dirty);
    try testing.expect(!layout_plan.compose);
    try testing.expect(layout_plan.layout);
    try testing.expect(layout_plan.prepare);
    try testing.expect(layout_plan.scene);
    try testing.expect(layout_plan.hit_test);
    try testing.expect(layout_plan.focus);
    try testing.expect(layout_plan.semantics);
    try testing.expect(!layout_plan.resources);
    try testing.expect(layout_plan.toDirty().layout);

    const resources: ui.layout.Dirty = .{
        .compose = false,
        .layout = false,
        .paint = false,
        .hit_test = false,
        .semantics = false,
        .resources = true,
    };
    const resources_plan = ui.runtime_invalidation.PhasePlan.fromDirty(resources);
    try testing.expect(!resources_plan.compose);
    try testing.expect(!resources_plan.layout);
    try testing.expect(resources_plan.prepare);
    try testing.expect(resources_plan.scene);
    try testing.expect(resources_plan.resources);
    try testing.expect(resources_plan.submit);
    try testing.expect(resources_plan.toDirty().resources);

    const semantic: ui.layout.Dirty = .{
        .compose = false,
        .layout = false,
        .paint = false,
        .hit_test = false,
        .semantics = true,
        .resources = false,
    };
    const semantic_plan = ui.runtime_invalidation.PhasePlan.fromDirty(semantic);
    try testing.expect(!semantic_plan.compose);
    try testing.expect(!semantic_plan.layout);
    try testing.expect(!semantic_plan.scene);
    try testing.expect(!semantic_plan.hit_test);
    try testing.expect(semantic_plan.semantics);
    try testing.expect(semantic_plan.submit);
}

test "ordinary component marks stay conservative while frame marks restore on failure" {
    var counters: ui.core.metrics.Counters = .{};
    var tracker = ui.runtime_invalidation.Tracker.init(testing.allocator, &counters);
    defer tracker.deinit();
    const component = handles.ComponentId.init(7, 1);
    const window = handles.WindowId.init(8, 1);
    try tracker.register(component, window);
    _ = tracker.consumeComponent(component);
    _ = tracker.consumeWindow(window);

    const paint: ui.layout.Dirty = .{
        .compose = false,
        .layout = false,
        .paint = true,
        .hit_test = false,
        .semantics = false,
        .resources = false,
    };
    _ = tracker.markComponent(component, paint);
    try testing.expect(tracker.windowDirty(window).?.compose);
    try testing.expect(tracker.consumeComponent(component).?.compose);
    _ = tracker.consumeWindow(window);

    _ = tracker.markComponentDuringFrame(component, paint);
    try testing.expectEqual(paint, tracker.windowDirty(window).?);
    const in_flight = tracker.beginComponent(component).?;
    try testing.expect(in_flight.paint);
    try testing.expect(!in_flight.compose);
    tracker.finishWindowComposition(window, false);
    try testing.expectEqual(paint, tracker.beginComponent(component).?);
    tracker.finishWindowComposition(window, true);
    try testing.expect(!tracker.windowDirty(window).?.compose);
}

test "bounded queues preserve order, capacity, and shutdown" {
    try testing.expectError(error.InvalidConfiguration, ui.runtime_queue.BoundedQueue(u8).init(testing.allocator, 0));

    var queue = try ui.runtime_queue.BoundedQueue(u8).init(testing.allocator, 2);
    defer queue.deinit();

    try queue.tryPush(1);
    try queue.tryPush(2);
    try testing.expectError(error.QueueFull, queue.tryPush(3));
    try testing.expectEqual(@as(?u8, 1), queue.pop());
    try queue.tryPush(3);
    try testing.expectEqual(@as(?u8, 2), queue.pop());
    try testing.expectEqual(@as(?u8, 3), queue.pop());
    try testing.expectEqual(@as(?u8, null), queue.pop());
    queue.close();
    try testing.expectError(error.Shutdown, queue.tryPush(4));
}

test "task completions apply and release exactly once across terminal states" {
    var registry = ui.runtime_task.Registry.init(testing.allocator);
    defer registry.deinit();
    const component = handles.ComponentId.init(4, 1);
    const window = handles.WindowId.init(8, 1);

    var applied_probe: CompletionProbe = .{};
    const active = try registry.create(component, window);
    const applied = registry.finish(applied_probe.completion(active.id));
    switch (applied) {
        .applied => |owner| try testing.expect(owner.eql(window)),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 1), applied_probe.applied);
    try testing.expectEqual(@as(u32, 1), applied_probe.dropped);
    try testing.expect(!registry.contains(active.id));

    var cancelled_probe: CompletionProbe = .{};
    const cancelled = try registry.create(component, window);
    registry.cancel(cancelled.id);
    switch (registry.finish(cancelled_probe.completion(cancelled.id))) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 0), cancelled_probe.applied);
    try testing.expectEqual(@as(u32, 1), cancelled_probe.dropped);

    var stale_probe: CompletionProbe = .{};
    switch (registry.finish(stale_probe.completion(handles.TaskId.init(99, 7)))) {
        .stale => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u32, 0), stale_probe.applied);
    try testing.expectEqual(@as(u32, 1), stale_probe.dropped);
}

test "affine transforms invert and pixel snapping is scale aware" {
    const transform = ui.Affine2D.mul(
        ui.Affine2D.translation(.{ .x = 7, .y = -3 }),
        ui.Affine2D.scale(2, 4),
    );
    const point: ui.Point = .{ .x = 5, .y = 6 };
    const world = transform.transformPoint(point);
    const restored = transform.inverse().?.transformPoint(world);
    try testing.expectApproxEqAbs(point.x, restored.x, 0.0001);
    try testing.expectApproxEqAbs(point.y, restored.y, 0.0001);

    const scale = try ui.ScaleFactor.init(2);
    try testing.expectApproxEqAbs(@as(f32, 1.5), ui.core.geometry.snap(1.37, scale, .nearest), 0.0001);
    try testing.expect(ui.Affine2D.scale(0, 1).inverse() == null);
}

test "memory budgets and tracked allocations account live bytes" {
    var counters: ui.core.metrics.Counters = .{};
    var budget: ui.core.memory.Budget = .{ .limit = 128 };
    var tracked = ui.core.TrackedAllocator.init(testing.allocator, &counters, &budget);
    const allocator = tracked.allocator();

    const bytes = try allocator.alloc(u8, 32);
    try testing.expectEqual(@as(usize, 32), budget.used);
    try testing.expectEqual(@as(u64, 32), tracked.snapshot().live_bytes);
    allocator.free(bytes);
    try testing.expectEqual(@as(usize, 0), budget.used);
    try testing.expectEqual(@as(u64, 0), tracked.snapshot().live_bytes);
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 129));
    try testing.expectEqual(@as(u64, 1), budget.denied);
}

test "frame arenas defer requested resets until scopes close" {
    var frame = try ui.core.memory.FrameArena.init(testing.allocator, 4096);
    defer frame.deinit();
    const original_generation = frame.generation;

    var scope = frame.enter();
    const allocation = try scope.allocator().alloc(u8, 64);
    @memset(allocation, 0xaa);
    try testing.expectError(error.OutOfMemory, scope.allocator().alloc(u8, 4097));
    try testing.expectEqual(@as(usize, 4096), frame.limit());
    frame.requestReset();
    try testing.expectEqual(original_generation, frame.generation);
    scope.deinit();
    try testing.expect(frame.generation != original_generation);
}

test "Unicode normalization, graphemes, bidi, and line breaks share generated data" {
    const decomposed = "e\xcc\x81";
    const normalized = try ui.unicode.normalize(testing.allocator, decomposed, .nfc);
    defer testing.allocator.free(normalized);
    try testing.expectEqualStrings("\xc3\xa9", normalized);
    try testing.expect(try ui.unicode.isNormalized(testing.allocator, normalized, .nfc));

    const family = "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7";
    var graphemes: ui.unicode.GraphemeIterator = .{ .bytes = family };
    try testing.expectEqualStrings(family, (try graphemes.next()).?);
    try testing.expect((try graphemes.next()) == null);

    const scalars = [_]u21{ 'a', 0x05d0, 0x05d1 };
    var bidi = try ui.unicode.resolveBidi(testing.allocator, &scalars, null);
    defer bidi.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, scalars.len), bidi.visual_to_logical.len);

    var breaks = try ui.unicode.analyzeLineBreaks(testing.allocator, "hello world");
    defer breaks.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, "hello world".len + 1), breaks.boundaries.len);
}

test "Unicode iterators stay linear on long regional and close-punctuation runs" {
    const run_length = 32 * 1024;
    const regional = "\xf0\x9f\x87\xa6";
    var regional_text: std.ArrayList(u8) = .empty;
    defer regional_text.deinit(testing.allocator);
    try regional_text.ensureTotalCapacity(testing.allocator, run_length * regional.len);
    for (0..run_length) |_| regional_text.appendSliceAssumeCapacity(regional);

    var words: ui.unicode.WordIterator = .{ .bytes = regional_text.items };
    var word_count: usize = 0;
    while (try words.next()) |_| word_count += 1;
    try testing.expectEqual(run_length / 2, word_count);

    var line_breaks = try ui.unicode.analyzeLineBreaks(testing.allocator, regional_text.items);
    defer line_breaks.deinit(testing.allocator);
    try testing.expectEqual(run_length + 1, line_breaks.boundaries.len);

    var sentence_text: std.ArrayList(u8) = .empty;
    defer sentence_text.deinit(testing.allocator);
    try sentence_text.append(testing.allocator, '.');
    try sentence_text.appendNTimes(testing.allocator, ')', run_length);
    try sentence_text.appendSlice(testing.allocator, " Next");
    var sentences: ui.unicode.SentenceIterator = .{ .bytes = sentence_text.items };
    var covered: usize = 0;
    while (try sentences.next()) |segment| covered = segment.end;
    try testing.expectEqual(sentence_text.items.len, covered);

    const numbers = try testing.allocator.alloc(u21, run_length);
    defer testing.allocator.free(numbers);
    @memset(numbers, '1');
    var resolved = try ui.unicode.resolveBidi(testing.allocator, numbers, null);
    defer resolved.deinit(testing.allocator);
    try testing.expectEqual(run_length, resolved.visual_to_logical.len);
}

test "QOI decoding and orientation are deterministic and bounded" {
    const qoi = [_]u8{
        'q',  'o',  'i',  'f',
        0,    0,    0,    1,
        0,    0,    0,    1,
        4,    0,    0xff, 0x12,
        0x34, 0x56, 0x78, 0,
        0,    0,    0,    0,
        0,    0,    1,
    };
    var decoded = try ui.image.decode(testing.allocator, &qoi, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), decoded.width);
    try testing.expectEqual(@as(u32, 1), decoded.height);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, decoded.pixels);

    try testing.expectError(error.BudgetExceeded, ui.image.decode(testing.allocator, &qoi, .{ .maximum_compressed_bytes = 8 }));
}

test "PNG decoding accepts a complete bounded positive fixture" {
    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c, 0x02, 0x00, 0x00, 0x00,
        0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x64, 0xf8, 0x0f, 0x00,
        0x01, 0x05, 0x01, 0x01, 0x27, 0x18, 0xe3, 0x66, 0x00, 0x00, 0x00, 0x00,
        0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    var decoded = try ui.image.decode(testing.allocator, &png, .{});
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), decoded.width);
    try testing.expectEqual(@as(u32, 1), decoded.height);
    try testing.expectEqual(@as(usize, 4), decoded.pixels.len);
}

test "font and image readers reject truncated and hostile offsets" {
    try testing.expectError(error.InvalidFont, ui.opentype.Font.init(&.{}, 0));
    try testing.expectError(error.InvalidFont, ui.opentype.Font.init(&.{
        0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    }, 0));
    try testing.expectError(error.InvalidFont, ui.opentype.Font.faceCount(&.{
        't', 't', 'c', 'f', 0, 1, 0, 0, 0, 0, 0x10, 1,
    }));
    try testing.expectError(error.InvalidFont, ui.opentype.readU16(&.{ 0, 1 }, std.math.maxInt(usize)));
    try testing.expectError(error.InvalidFont, ui.opentype.readU32(&.{ 0, 1, 2, 3 }, std.math.maxInt(usize)));

    const malformed = [_][]const u8{
        &.{ 137, 80, 78, 71, 13, 10, 26, 10 },
        &.{ 0xff, 0xd8, 0xff, 0xd9 },
        "GIF89a",
        "BM",
        "qoif",
    };
    for (malformed) |source| {
        if (ui.image.decode(testing.allocator, source, .{})) |decoded_value| {
            var decoded = decoded_value;
            decoded.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "GIF decoder accepts every frame of a valid disposal animation" {
    const bytes = @embedFile("fixtures/ajax-loader.gif");
    var decoder = try ui.animation.Decoder.init(testing.allocator, bytes, .{});
    defer decoder.deinit();
    var frames: usize = 0;
    while (try decoder.next()) |_| {
        frames += 1;
        if (frames > 256) return error.TestUnexpectedResult;
    }
    try testing.expect(frames > 1);

    var malformed = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(malformed);
    malformed[malformed.len - 1] = 1;
    var strict = try ui.animation.Decoder.init(testing.allocator, malformed, .{});
    defer strict.deinit();
    while (strict.next()) |_| {} else |err| try testing.expectEqual(error.InvalidImage, err);

    var player = try ui.animation.Player.init(testing.allocator, malformed, .{}, 0);
    defer player.deinit();
    _ = try player.advance(10 * std.time.ns_per_s);
    try testing.expectEqual(ui.animation.State.failed, player.state);
    try testing.expectEqual(error.InvalidImage, player.failure.?);
}

test "scene validation preserves operation ordering and bounds nesting depth" {
    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();

    const material = try builder.solidMaterial(ui.Color.rgba(1, 0, 0, 1));
    _ = try builder.pushLayer(0.75, .normal, ui.Affine2D.translation(.{ .x = 2, .y = 3 }));
    _ = try builder.pushClip(ui.Rect.fromXYWH(0, 0, 20, 20), ui.CornerRadii.all(4));
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 20, 20),
        .background = .transparent,
        .border_color = .transparent,
        .border_widths = .{},
        .radii = ui.CornerRadii.all(4),
    }, material);
    try builder.popClip();
    try builder.popLayer();
    try builder.finish();
    try testing.expectEqual(@as(usize, 5), scene.operations.items.len);

    var too_deep_scene = ui.scene.Scene.init(testing.allocator);
    defer too_deep_scene.deinit();
    var too_deep = ui.scene.Builder.init(&too_deep_scene, .{});
    defer too_deep.deinit();
    var depth: usize = 0;
    while (depth < 63) : (depth += 1)
        _ = try too_deep.pushClip(ui.Rect.fromXYWH(0, 0, 10, 10), .{});
    try testing.expectError(error.InvalidScene, too_deep.pushClip(ui.Rect.fromXYWH(0, 0, 10, 10), .{}));
    while (depth != 0) {
        depth -= 1;
        try too_deep.popClip();
    }
    try too_deep.finish();
}

test "backdrop effects encode as a validated retained scene primitive" {
    try testing.expectEqual(@as(u32, 11), @backingInt(ui.scene_abi.OperationKind.custom_passes));
    try testing.expectEqual(@as(u32, 12), @backingInt(ui.scene_abi.OperationKind.backdrop_effect));

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    const effect: ui.scene_abi.BackdropEffect = .{
        .bounds = ui.Rect.fromXYWH(2, 3, 20, 12),
        .radii = ui.CornerRadii.all(4),
        .blur_radius = 6,
        .saturation = 0.75,
        .opacity = 0.5,
    };
    try builder.backdropEffect(effect);
    try builder.finish();

    try testing.expect(scene.view().requiresBackdropEffects());
    try testing.expectEqual(@as(usize, 1), scene.backdrop_effects.items.len);
    try testing.expectEqual(effect, scene.backdrop_effects.items[0]);
    try testing.expectEqual(@as(usize, 1), scene.operations.items.len);
    const operation = scene.operations.items[0];
    try testing.expectEqual(@backingInt(ui.scene_abi.OperationKind.backdrop_effect), operation.kind);
    try testing.expectEqual(@as(u32, 0), operation.start);
    try testing.expectEqual(@as(u32, 1), operation.count);
    try testing.expectEqual(ui.scene.none_index, operation.clip);
    try testing.expectEqual(ui.scene.none_index, operation.layer);
    try testing.expectEqual(ui.scene.none_index, operation.material);
    try testing.expectEqual(ui.scene.none_index, operation.reserved);

    var invalid_scene = ui.scene.Scene.init(testing.allocator);
    defer invalid_scene.deinit();
    var invalid_builder = ui.scene.Builder.init(&invalid_scene, .{});
    defer invalid_builder.deinit();
    try invalid_builder.backdropEffect(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .radii = .{},
        .blur_radius = 129,
        .saturation = 1,
    });
    try testing.expectError(error.InvalidScene, invalid_builder.finish());
}

test "retained paint changes include backdrop effect fields" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const initial_style: ui.style.Style = .{ .paint = .{
        .backdrop_effect = .{ .blur_radius = 4, .saturation = 0.8 },
    } };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .style = initial_style }, 1, scratch.allocator());
    const initial_generation = store.getConst(root).?.paint_generation;

    var updated_style = initial_style;
    updated_style.paint.backdrop_effect = .{ .blur_radius = 8, .saturation = 1.2 };
    _ = try store.reconcile(root, .invalid, .invalid, .{ .style = updated_style }, 1, scratch.allocator());
    try testing.expectEqual(updated_style.paint.backdrop_effect, store.getConst(root).?.borrowedStyle().paint.backdrop_effect);
    try testing.expectEqual(initial_generation + 1, store.getConst(root).?.paint_generation);

    var invalid_style = updated_style;
    invalid_style.paint.backdrop_effect = .{ .blur_radius = 129 };
    try testing.expectError(error.InvalidConfiguration, store.reconcile(root, .invalid, .invalid, .{ .style = invalid_style }, 1, scratch.allocator()));
    try testing.expectEqual(updated_style.paint.backdrop_effect, store.getConst(root).?.borrowedStyle().paint.backdrop_effect);
}

test "scene painter emits styled backdrop before opacity-isolated node paint" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .kind = .spacer,
        .style = .{
            .paint = .{
                .background = .{ .solid = ui.Color.rgba(0.1, 0.2, 0.3, 0.75) },
                .backdrop_effect = .{ .blur_radius = 2, .saturation = 0.9 },
                .opacity = 0.5,
            },
        },
    }, 1, scratch.allocator());
    store.get(root).?.layout.bounds = ui.Rect.fromXYWH(2, 2, 20, 12);

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    var painter: ui.ScenePainter = .{
        .builder = &builder,
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
    };
    try painter.paint(&store, root);
    try builder.finish();

    try testing.expectEqual(@as(usize, 4), scene.operations.items.len);
    try testing.expectEqual(@backingInt(ui.scene_abi.OperationKind.backdrop_effect), scene.operations.items[0].kind);
    try testing.expectEqual(@as(f32, 0.5), scene.backdrop_effects.items[0].opacity);
    try testing.expectEqual(@backingInt(ui.scene_abi.OperationKind.push_layer), scene.operations.items[1].kind);
    try testing.expectEqual(@backingInt(ui.scene_abi.OperationKind.quads), scene.operations.items[2].kind);
    try testing.expectEqual(@backingInt(ui.scene_abi.OperationKind.pop_layer), scene.operations.items[3].kind);
}

test "scene builder leaves no partial primitive when allocation fails" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var scene = ui.scene.Scene.init(failing.allocator());
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try testing.expectError(error.OutOfMemory, builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .background = ui.Color.white,
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null));
    try testing.expectEqual(@as(usize, 0), scene.operations.items.len);
    try testing.expectEqual(@as(usize, 0), scene.quads.items.len);
}

test "native media placements are bounded unique layout declarations" {
    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{ .native_media_placements = 1 });
    defer builder.deinit();
    const id = handles.NativeMediaId.init(2, 1);
    const bounds = ui.Rect.fromXYWH(10, 20, 320, 180);
    try builder.nativeMediaWithVisibility(id, bounds, false);
    try testing.expectEqual(@as(usize, 1), scene.native_media_placements.items.len);
    try testing.expectEqual(bounds, scene.native_media_placements.items[0].bounds);
    try testing.expect(!scene.native_media_placements.items[0].visible);
    try testing.expectError(error.InvalidScene, builder.nativeMedia(id, bounds));
    try testing.expectError(error.InvalidHandle, builder.nativeMedia(.invalid, bounds));
}

test "null renderer respects affine rounded clips and produces readback" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();

    _ = try builder.pushLayer(1, .normal, ui.Affine2D.translation(.{ .x = 2, .y = 2 }));
    _ = try builder.pushClip(ui.Rect.fromXYWH(0, 0, 8, 8), ui.CornerRadii.all(3));
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 8, 8),
        .background = ui.Color.rgba(1, 0, 0, 1),
        .border_color = ui.Color.rgba(0, 0, 1, 1),
        .border_widths = ui.Insets.all(1),
        .radii = ui.CornerRadii.all(3),
    }, null);
    try builder.popClip();
    try builder.popLayer();
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 12,
        .height = 12,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);

    try testing.expect(pixel(readback, 6, 6)[0] > 240);
    try testing.expectEqual(@as(u8, 0), pixel(readback, 0, 0)[3]);
    try testing.expect(pixel(readback, 2, 2)[3] < 128);
}

test "null renderer paints content translated into a parent scroll clip" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();

    _ = try builder.pushClip(ui.Rect.fromXYWH(0, 0, 10, 10), .{});
    _ = try builder.pushLayer(1, .normal, ui.Affine2D.translation(.{ .x = 0, .y = -100 }));
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 100, 10, 10),
        .background = ui.Color.rgba(1, 0, 0, 1),
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.popLayer();
    try builder.popClip();
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 10,
        .height = 10,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    try testing.expect(pixel(readback, 5, 5)[0] > 240);
    try testing.expect(pixel(readback, 5, 5)[3] > 240);
}

test "retained scroll composition paints an absolute virtualized child after offset" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const item = ui.NodeSpec{
        .kind = .spacer,
        .style = .{
            .layout = .{
                .position = .absolute,
                .width = .{ .points = 10 },
                .height = .{ .points = 10 },
                .inset = .{ .top = .{ .points = 100 }, .left = .{ .points = 0 } },
            },
            .paint = .{ .background = .{ .solid = ui.Color.rgba(1, 0, 0, 1) } },
        },
    };
    const content = ui.NodeSpec{
        .kind = .container,
        .style = .{ .layout = .{ .width = .{ .points = 10 }, .height = .{ .points = 110 }, .flex_shrink = 0 } },
        .children = &.{item},
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .kind = .{ .scroll = .{ .vertical = true, .offset_y = 100 } },
        .style = .{ .layout = .{
            .width = .{ .points = 10 },
            .height = .{ .points = 10 },
            .overflow_y = .scroll,
            .overflow_x = .hidden,
        } },
        .children = &.{content},
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 10, .height = 10 });
    const root_record = store.getConst(root).?;
    const content_record = store.getConst(root_record.children.items[0]).?;
    const item_record = store.getConst(content_record.children.items[0]).?;
    try testing.expectApproxEqAbs(@as(f32, 110), content_record.layout.bounds.size.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100), item_record.layout.bounds.origin.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), item_record.layout.bounds.size.height, 0.001);

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    var painter: ui.ScenePainter = .{
        .builder = &builder,
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
    };
    try painter.paint(&store, root);
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 10,
        .height = 10,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    try testing.expect(pixel(readback, 5, 5)[0] > 240);
    try testing.expect(pixel(readback, 5, 5)[3] > 240);
}

test "null renderer advertises and applies retained backdrop effects" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    try testing.expect(renderer.capabilities().backdrop_effects);

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 8),
        .background = ui.Color.rgba(1, 0, 0, 1),
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(4, 0, 4, 8),
        .background = ui.Color.rgba(0, 0, 1, 1),
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.backdropEffect(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 8, 8),
        .radii = .{},
        .blur_radius = 2,
        .saturation = 1,
    });
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 8,
        .height = 8,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    const boundary = pixel(readback, 3, 4);
    try testing.expect(boundary[0] > 0);
    try testing.expect(boundary[2] > 0);
}

test "null backdrop blur preserves uniform pixels and saturation can desaturate them" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    const source = ui.Color.rgba(0.8, 0.2, 0.1, 1);
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 8, 8),
        .background = source,
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try builder.backdropEffect(.{
        .bounds = ui.Rect.fromXYWH(2, 2, 4, 4),
        .radii = .{},
        .blur_radius = 4,
        .saturation = 0,
    });
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 8,
        .height = 8,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    const outside = pixel(readback, 0, 0);
    try testing.expectEqual(@as(u8, 204), outside[0]);
    try testing.expectEqual(@as(u8, 51), outside[1]);
    try testing.expectEqual(@as(u8, 26), outside[2]);
    const desaturated = pixel(readback, 4, 4);
    try testing.expectEqual(desaturated[0], desaturated[1]);
    try testing.expectEqual(desaturated[1], desaturated[2]);
}

test "null renderer samples scaled textures bilinearly" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    const texture = handles.TextureId.init(9, 1);
    try renderer.createTexture(texture, .{ .width = 2, .height = 2, .format = .rgba8 });
    defer renderer.destroyTexture(texture, 0) catch {};
    const texels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    try renderer.writeTexture(texture, .{ .width = 2, .height = 2 }, &texels, 8);

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.colorSprite(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .uv_bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
        .color = .white,
        .texture = texture.encode(),
        .tile_generation = texture.generation,
        .format = @backingInt(ui.scene_abi.TextureFormat.rgba8),
    });
    try builder.finish();

    var readback = (try renderer.renderOffscreen(.{
        .width = 4,
        .height = 4,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    const center = pixel(readback, 1, 1);
    try testing.expect(center[0] > 20 and center[1] > 20 and center[2] > 20);
    try testing.expectEqual(@as(u8, 255), center[3]);
}

test "resource retirement obeys submission epochs and memory budgets" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var resources = ui.resources.Manager.init(testing.allocator, 256, 256);
    defer resources.deinit();

    var pixels: [64]u8 = undefined;
    @memset(&pixels, 0x7f);
    const texture = try resources.createTexture(.{ .width = 4, .height = 4, .format = .rgba8 }, &pixels, true);
    try resources.realize(renderer, texture);
    try resources.markUsed(texture, 5);
    try testing.expectEqual(@as(usize, 64), resources.stats().gpu_reserved);
    try resources.destroyTextureOnRenderer(renderer, texture);
    resources.collect(4);
    try testing.expectEqual(@as(usize, 1), resources.stats().retired_textures);
    resources.collect(5);
    try testing.expectEqual(@as(usize, 0), resources.stats().retired_textures);
    try testing.expectEqual(@as(usize, 0), resources.stats().gpu_reserved);

    try testing.expectError(error.BudgetExceeded, resources.createTexture(.{ .width = 9, .height = 9, .format = .rgba8 }, null, false));
}

test "atlas tiles cannot be reused before their completed submission" {
    var resources = ui.resources.Manager.init(testing.allocator, 1024, 0);
    defer resources.deinit();
    var atlas = try ui.atlas.Atlas.init(testing.allocator, &resources, 4, 1, .a8);
    defer atlas.deinit();

    const first = try atlas.allocate(4, 4, 1, 0);
    try atlas.markUsed(first, 1, 3);
    try atlas.release(first);
    try testing.expectError(error.AtlasFull, atlas.allocate(4, 4, 2, 2));
    const second = try atlas.allocate(4, 4, 2, 3);
    try testing.expectEqual(first.index, second.index);
    try testing.expect(first.generation != second.generation);

    resources.deviceLost();
    try atlas.deviceLost();
    try testing.expect(atlas.get(second) == null);
}

test "atlas tiles selected by a scene cannot be evicted later in that frame" {
    var resources = ui.resources.Manager.init(testing.allocator, 1024, 0);
    defer resources.deinit();
    var atlas = try ui.atlas.Atlas.init(testing.allocator, &resources, 4, 1, .a8);
    defer atlas.deinit();

    const first = try atlas.allocate(4, 4, 7, 0);
    try atlas.touch(first, 7);
    try testing.expectError(error.AtlasFull, atlas.allocate(4, 4, 7, 0));
    const next_frame = try atlas.allocate(4, 4, 8, 0);
    try testing.expectEqual(first.index, next_frame.index);
    try testing.expect(first.generation != next_frame.generation);
}

test "retained reconciliation preserves keyed node identity across reorder" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const first_children = [_]ui.NodeSpec{
        (ui.NodeSpec{ .kind = .{ .text = "first" } }).withKey(11),
        (ui.NodeSpec{ .kind = .{ .text = "second" } }).withKey(22),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &first_children }, 1, scratch.allocator());
    const original = store.get(root).?.children.items;
    const first_id = original[0];
    const second_id = original[1];

    const reordered = [_]ui.NodeSpec{
        (ui.NodeSpec{ .kind = .{ .text = "second changed" } }).withKey(22),
        (ui.NodeSpec{ .kind = .{ .text = "first changed" } }).withKey(11),
    };
    const same_root = try store.reconcile(root, .invalid, .invalid, .{ .children = &reordered }, 1, scratch.allocator());
    try testing.expect(root.eql(same_root));
    const children = store.get(root).?.children.items;
    try testing.expect(children[0].eql(second_id));
    try testing.expect(children[1].eql(first_id));
}

test "retained reconciliation has a strong allocation-failure guarantee" {
    try checkReconcileAllocationFailures(testing.allocator);
}

test "SVG document ownership transfers exactly once across allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, svgManagerAllocationProbe, .{});
}

test "component children have explicit ownership mount and recursive destruction" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    var nodes = ui.NodeStore.init(testing.allocator);
    defer nodes.deinit();
    var components = ui.Component.Store.init(testing.allocator);
    defer components.deinit();

    var parent_probe: ComponentProbe = .{};
    var child_probe: ComponentProbe = .{};
    const window = handles.WindowId.init(1, 1);
    const parent = try components.create(parent_probe.descriptor(), window);
    const anchor = try nodes.createAnchor(1);
    try components.attach(parent, anchor);
    _ = try components.markRegistered(parent);
    try coordinator.invalidations.register(parent, window);

    const child = try components.createChild(child_probe.descriptor(), window, parent);
    try testing.expect(components.isChildOf(child, parent));
    try testing.expect(try components.mount(child, anchor, parent));
    _ = try components.markRegistered(child);
    try coordinator.invalidations.register(child, window);

    components.destroy(parent, &nodes, &coordinator);
    try testing.expect(!components.contains(parent));
    try testing.expect(!components.contains(child));
    try testing.expectEqual(@as(u32, 1), parent_probe.dropped);
    try testing.expectEqual(@as(u32, 1), child_probe.dropped);
}

test "input handler failures propagate through retained dispatch" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    var nodes = ui.NodeStore.init(testing.allocator);
    defer nodes.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var handler_context: u8 = 0;
    const handlers = [_]ui.input.Handler{.{
        .context = &handler_context,
        .callback = failingHandler,
        .phase = .target,
    }};
    const root = try nodes.reconcile(null, .invalid, .invalid, .{ .handlers = &handlers }, 1, scratch.allocator());
    var hits = ui.hit_testing.Tree.init(testing.allocator);
    defer hits.deinit();
    var focus_manager = ui.focus.Manager.init(testing.allocator);
    defer focus_manager.deinit();
    var actions = ui.actions.Registry.init(testing.allocator);
    defer actions.deinit();
    var router = ui.InputRouter.init(testing.allocator, handles.WindowId.init(1, 1), root, &hits, &focus_manager, &actions);
    defer router.deinit();
    const value: ui.input.Event = .focus_in;
    try testing.expectError(error.BudgetExceeded, router.dispatchTo(&nodes, &coordinator, root, &value, scratch.allocator()));
}

test "application path budgets reject unbounded tessellation work" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.path_edge_count = 16;
    memory.path_work_units = 1;
    const renderer = try ui.NullRenderer.createWithMemory(testing.allocator, memory);
    defer renderer.deinit();

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    const vertices = [_]ui.scene_abi.PathVertex{
        .{ .position = .{ .x = 1, .y = 1 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.move_to) },
        .{ .position = .{ .x = 7, .y = 1 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.line_to) },
        .{ .position = .{ .x = 7, .y = 7 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.line_to) },
        .{ .position = .{ .x = 1, .y = 7 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.line_to) },
        .{ .position = .{ .x = 1, .y = 1 }, .control = .{}, .kind = @backingInt(ui.scene_abi.PathCommand.close) },
    };
    try builder.path(.{
        .vertex_start = 0,
        .vertex_count = 0,
        .fill_rule = @backingInt(ui.scene_abi.FillRule.non_zero),
        .color = ui.Color.white,
        .bounds = ui.Rect.fromXYWH(1, 1, 6, 6),
    }, &vertices, null);
    try builder.finish();
    try testing.expectError(error.BudgetExceeded, renderer.renderOffscreen(.{
        .width = 8,
        .height = 8,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator));
}

test "application configuration validates every path work boundary" {
    var missing_edges: ui.config.AppConfig = .{};
    missing_edges.memory.path_edge_count = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(missing_edges));
    var missing_work: ui.config.AppConfig = .{};
    missing_work.memory.path_work_units = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(missing_work));
}

test "pointer event coalescing policy is an explicit application contract" {
    var value: ui.config.AppConfig = .{};
    try ui.config.validate(value);
    try testing.expectEqual(ui.config.PointerEventCoalescing.platform_default, value.pointer_event_coalescing);
    value.pointer_event_coalescing = .disabled;
    try ui.config.validate(value);
}

test "layout, hit testing, focus, and accessibility share retained identities" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        (ui.NodeSpec{
            .kind = .spacer,
            .style = .{
                .layout = .{ .width = .{ .points = 40 }, .height = .{ .points = 30 } },
                .paint = .{ .radii = ui.CornerRadii.all(8) },
                .interaction = .{ .focusable = true, .tab_index = 2 },
            },
            .semantics = .{ .role = .button, .label = "later" },
        }).withKey(11),
        (ui.NodeSpec{
            .kind = .spacer,
            .style = .{
                .layout = .{ .width = .{ .points = 60 }, .height = .{ .points = 30 } },
                .interaction = .{ .focusable = true, .tab_index = 1 },
            },
            .semantics = .{ .role = .button, .label = "first" },
        }).withKey(22),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row, .gap = .{ .width = 5 } } },
        .children = &children,
    }, 1, scratch.allocator());

    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 120, .height = 40 });
    const retained_children = store.get(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 0), store.get(retained_children[0]).?.layout.bounds.origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 45), store.get(retained_children[1]).?.layout.bounds.origin.x, 0.001);

    var hit_tree = ui.hit_testing.Tree.init(testing.allocator);
    defer hit_tree.deinit();
    try hit_tree.rebuild(&store, root);
    try testing.expect(hit_tree.hit(.{ .x = 50, .y = 10 }).?.target.eql(retained_children[1]));

    var focus = ui.focus.Manager.init(testing.allocator);
    defer focus.deinit();
    try focus.rebuild(&store, root);
    try testing.expect(focus.move(&store, .forward).?.eql(retained_children[1]));
    try testing.expect(focus.move(&store, .forward).?.eql(retained_children[0]));

    var accessibility = ui.AccessibilityTree.init(testing.allocator, handles.WindowId.init(1, 1));
    defer accessibility.deinit();
    const first_tree = try accessibility.build(&store, root, retained_children[1], scratch.allocator());
    const semantic = accessibility.semanticForNode(retained_children[1]).?;
    try testing.expect(first_tree.nodes.len >= 3);
    const second_tree = try accessibility.build(&store, root, retained_children[1], scratch.allocator());
    try testing.expectEqual(first_tree.root.encode(), second_tree.root.encode());
    try testing.expectEqual(semantic.encode(), accessibility.semanticForNode(retained_children[1]).?.encode());
    try testing.expect(accessibility.nodeForSemantic(semantic).?.eql(retained_children[1]));
}

test "flex redistribution honors constrained children without leaving free space" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 50 },
            .height = .{ .points = 20 },
            .max_width = .{ .points = 60 },
            .flex_grow = 1,
        } } },
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 50 },
            .height = .{ .points = 20 },
            .flex_grow = 1,
        } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 300, .height = 40 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 60), store.getConst(retained[0]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 240), store.getConst(retained[1]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 300), store.getConst(retained[1]).?.layout.bounds.maxX(), 0.001);
}

test "flex shrink redistributes overflow after a child reaches its minimum" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 100 },
            .height = .{ .points = 20 },
            .min_width = .{ .points = 90 },
        } } },
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 100 },
            .height = .{ .points = 20 },
        } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 40 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 90), store.getConst(retained[0]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), store.getConst(retained[1]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 100), store.getConst(retained[1]).?.layout.bounds.maxX(), 0.001);
}

test "scrolling flex containers preserve overflowing main-axis content" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        .{ .kind = .spacer, .style = .{ .layout = .{ .height = .{ .points = 80 } } } },
        .{ .kind = .spacer, .style = .{ .layout = .{ .height = .{ .points = 80 } } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .kind = .{ .scroll = .{ .vertical = true } },
        .style = .{ .layout = .{ .direction = .column, .overflow_y = .scroll } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 80), store.getConst(retained[0]).?.layout.bounds.size.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80), store.getConst(retained[1]).?.layout.bounds.size.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 80), store.getConst(retained[1]).?.layout.bounds.origin.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 160), store.getConst(root).?.layout.scroll_extent.height, 0.001);
}

test "dialog keeps overflowing modal content in a live scroll viewport" {
    var open = true;
    var content_children: [8]ui.NodeSpec = undefined;
    for (&content_children) |*child| child.* = .{ .kind = .spacer, .style = .{ .layout = .{ .height = .{ .points = 80 }, .flex_shrink = 0 } } };
    const dialog_content = ui.NodeSpec{ .kind = .container, .style = .{ .layout = .{ .direction = .column } }, .children = &content_children };
    const footer = ui.NodeSpec{ .kind = .spacer, .style = .{ .layout = .{ .height = .{ .points = 40 }, .flex_shrink = 0 } } };
    var dialog = ui.widgets.Dialog{ .open = &open, .title = "Scrollable dialog", .content = dialog_content, .footer = footer, .width = 420 };

    var build_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer build_arena.deinit();
    var build_context: ui.Component.BuildContext = undefined;
    build_context.allocator = build_arena.allocator();
    const spec = try dialog.build(&build_context);
    const panel = spec.children[1];
    try testing.expectEqual(@as(usize, 1), panel.children.len);
    const scroll = panel.children[0];
    try testing.expect(std.meta.activeTag(scroll.kind) == .scroll);
    try testing.expectEqual(ui.layout.Overflow.scroll, scroll.style.layout.overflow_y);

    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, handles.NodeId.invalid, handles.NodeId.invalid, spec, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{ .context = &measure_context, .text_fn = emptyTextMeasure, .custom_measure_fn = emptyCustomMeasure },
    };
    try engine.layout(&store, root, .{ .width = 480, .height = 300 });
    const panel_id = store.getConst(root).?.children.items[1];
    const scroll_id = store.getConst(panel_id).?.children.items[0];
    const scroll_record = store.getConst(scroll_id).?;
    try testing.expect(scroll_record.layout.scroll_extent.height > scroll_record.layout.content_bounds.size.height);
    try testing.expect(scroll_record.layout.bounds.size.height <= 246);
}

test "flex remeasures wrapped content at its allocated main size" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{
        .{ .kind = .{ .text = "abcdefghijklmnopqrst" } },
        .{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 50 },
            .height = .{ .points = 10 },
            .flex_shrink = 0,
        } } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .direction = .row, .align_items = .start } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = wrappingTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const retained = store.getConst(root).?.children.items;
    const text = store.getConst(retained[0]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 50), text.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), text.size.height, 0.001);
}

test "text baselines clamp when exact constraints clip line height" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const root = try store.reconcile(null, .invalid, .invalid, .{
        .kind = .{ .text = "clipped" },
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = clippedTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };

    try engine.layout(&store, root, .{ .width = 32, .height = 6 });
    const record = store.getConst(root).?;
    try testing.expectApproxEqAbs(@as(f32, 6), record.layout.bounds.size.height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 6), record.layout.baseline.?, 0.001);
}

test "fractional grid tracks redistribute around intrinsic minimums" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const tracks = [_]ui.layout.GridTrack{
        .{ .minmax = .{ .min = .{ .points = 80 }, .max = .{ .fraction = 1 } } },
        .{ .fraction = 1 },
    };
    const children = [_]ui.NodeSpec{
        .{ .kind = .spacer },
        .{ .kind = .spacer },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid, .grid_columns = &tracks } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 120, .height = 20 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 80), store.getConst(retained[0]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), store.getConst(retained[1]).?.layout.bounds.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 120), store.getConst(retained[1]).?.layout.bounds.maxX(), 0.001);
}

test "grid rows measure wrapped content at the resolved column width" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const tracks = [_]ui.layout.GridTrack{ .{ .points = 50 }, .{ .points = 50 } };
    const children = [_]ui.NodeSpec{.{ .kind = .{ .text = "abcdefghijklmnopqrst" } }};
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid, .grid_columns = &tracks, .align_items = .start } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = wrappingTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const child = store.getConst(store.getConst(root).?.children.items[0]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 50), child.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), child.size.height, 0.001);
}

test "grid baseline alignment contributes the full ascent and descent" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const tracks = [_]ui.layout.GridTrack{ .{ .points = 50 }, .{ .points = 50 } };
    const children = [_]ui.NodeSpec{
        .{ .kind = .{ .text = "high" } },
        .{ .kind = .{ .text = "low" } },
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid, .grid_columns = &tracks, .align_items = .baseline } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = variableBaselineTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 30 });
    const retained = store.getConst(root).?.children.items;
    const high = store.getConst(retained[0]).?.layout.bounds;
    const low = store.getConst(retained[1]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 0), high.origin.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), low.origin.y, 0.001);
    try testing.expectApproxEqAbs(high.origin.y + 8, low.origin.y + 3, 0.001);
}

test "absolute layout applies margins and derives an auto aspect axis" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const children = [_]ui.NodeSpec{.{
        .kind = .spacer,
        .style = .{ .layout = .{
            .position = .absolute,
            .aspect_ratio = 2,
            .margin = .{
                .top = .{ .points = 3 },
                .right = .{ .points = 5 },
                .bottom = .{ .points = 3 },
                .left = .{ .points = 5 },
            },
            .inset = .{
                .top = .{ .points = 4 },
                .right = .{ .points = 10 },
                .bottom = .auto,
                .left = .{ .points = 10 },
            },
        } },
    }};
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 100 });
    const child = store.getConst(store.getConst(root).?.children.items[0]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 15), child.origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 7), child.origin.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 70), child.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 35), child.size.height, 0.001);
}

test "absolute point-width menus honor right and bottom insets" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const menu_items = [_]ui.NodeSpec{
        .{ .kind = .{ .text = "New Note" } },
        .{ .kind = .{ .text = "New Sticky" } },
        .{ .kind = .{ .text = "New Folder" } },
        .{ .kind = .{ .text = "New Palette" } },
        .{ .kind = .{ .text = "Palette from Image" } },
    };
    const children = [_]ui.NodeSpec{.{
        .kind = .container,
        .style = .{ .layout = .{
            .position = .absolute,
            .width = .{ .points = 220 },
            .inset = .{ .top = .auto, .right = .{ .points = 14 }, .bottom = .{ .points = 78 }, .left = .auto },
            .direction = .column,
            .gap = .{ .height = 3 },
            .padding = .{ .top = .{ .points = 10 }, .right = .{ .points = 10 }, .bottom = .{ .points = 10 }, .left = .{ .points = 10 } },
        } },
        .children = &menu_items,
    }};
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = menuTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 800, .height = 600 });

    const menu = store.getConst(store.getConst(root).?.children.items[0]).?.layout.bounds;
    try testing.expectApproxEqAbs(@as(f32, 566), menu.origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 310), menu.origin.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 220), menu.size.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 212), menu.size.height, 0.001);
}

test "custom measurement cannot publish non-finite layout geometry" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var probe: InvalidMeasureProbe = .{};
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .kind = .{ .custom = ui.custom.Node.from(InvalidMeasureProbe, &probe) },
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try testing.expectError(error.InvalidLayout, engine.layout(&store, root, .{ .width = 100, .height = 100 }));
}

test "headless platform deterministically exposes windows displays clipboard and events" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();

    const window = handles.WindowId.init(3, 1);
    const native = try harness.bundle.windows.create(window, .{
        .title = "Conformance",
        .size = .{ .width = 640, .height = 480 },
    });
    try testing.expectEqual(ui.platform.NativeHandle.Kind.headless, native.kind);
    try testing.expect(harness.bundle.windows.nativeHandle(window) != null);
    try testing.expectError(error.MissingCapability, harness.bundle.windows.captureWindow(
        window,
        .{ .width = 640, .height = 480 },
        testing.allocator,
    ));

    var displays = try harness.bundle.displays.list(testing.allocator);
    defer displays.deinit();
    try testing.expectEqual(@as(usize, 1), displays.values.len);
    try testing.expect(displays.values[0].primary);

    try harness.bundle.clipboard.?.writeText("clipboard");
    const clipboard = (try harness.bundle.clipboard.?.readText(testing.allocator)).?;
    defer testing.allocator.free(clipboard);
    try testing.expectEqualStrings("clipboard", clipboard);
    var contents = try harness.bundle.clipboard.?.readContents(testing.allocator);
    defer contents.deinit();
    try testing.expectEqualStrings("clipboard", contents.text.?);
    try testing.expectEqual(@as(usize, 0), contents.paths.len);
    try testing.expect(contents.image == null);

    var events: EventCollector = .{};
    const sink: ui.platform.EventSink = .{ .context = &events, .callback = EventCollector.receive };
    while (try harness.bundle.event_loop.step(sink, false)) {}
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqual(@as(EventCollector.Tag, .created), events.tags[0]);
    try testing.expectEqual(@as(EventCollector.Tag, .configured), events.tags[1]);
    try testing.expectEqual(@as(EventCollector.Tag, .frame_requested), events.tags[2]);

    try harness.bundle.windows.command(window, .{ .resize = .{ .width = 800, .height = 600 } });
    try harness.bundle.windows.requestFrame(window);
    while (try harness.bundle.event_loop.step(sink, false)) {}
    try testing.expectEqual(@as(usize, 6), events.len);
    try harness.bundle.windows.command(window, .{ .always_on_top = true });
    try harness.bundle.windows.command(window, .{ .always_on_top = false });
    harness.bundle.windows.destroy(window);
    while (try harness.bundle.event_loop.step(sink, false)) {}
    try testing.expectEqual(@as(EventCollector.Tag, .closed), events.tags[events.len - 1]);
}

test "headless directory picker is deterministic, owned, and cancellable" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    const text_backend = text_backend_instance.interface();
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend);
    const bundle = harness.bundle;
    harness.bundle = undefined;
    try harness.setDirectoryPickerResult("/tmp/headless-directory");
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "directory picker conformance",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;

    var root: WindowCompositionProbe = .{};
    const window = try app.openWindow(
        .{ .platform = .{ .title = "directory picker", .visible = false } },
        ui.Component.Descriptor.from(WindowCompositionProbe, &root),
    );
    while (try app.step(false)) {}
    var selected = (try app.openDirectory(window, testing.allocator)) orelse return error.TestUnexpectedResult;
    defer selected.deinit();
    try testing.expectEqualStrings("/tmp/headless-directory", selected.value);

    try harness.setDirectoryPickerResult(null);
    try testing.expect((try app.openDirectory(window, testing.allocator)) == null);
}

test "headless promised-file service preserves mixed outcomes and cancellation" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    const service = harness.bundle.promised_files orelse return error.MissingCapability;
    const descriptors = [_]ui.platform.PromisedFileDescriptor{
        .{ .suggested_name = "one.txt", .content_type = "public.plain-text" },
        .{ .suggested_name = "two.pdf", .content_type = "com.adobe.pdf" },
    };
    const outcomes = [_]ui.HeadlessPlatform.FakePromisedOutcome{
        .{ .path = "/tmp/promised/one.txt" },
        .{ .error_description = "provider refused the second file" },
    };
    const batch = try harness.addPromisedBatch(&descriptors, &outcomes);
    var description = try service.describe(batch, testing.allocator);
    defer description.deinit();
    try testing.expectEqualStrings("one.txt", description.values[0].suggested_name);
    const operation = try service.begin(batch, "/tmp/promised-destination");
    try service.releaseBatch(batch);
    try testing.expectEqual(ui.platform.PromisedFilePoll.pending, try service.poll(operation, testing.allocator));
    var terminal = try service.poll(operation, testing.allocator);
    switch (terminal) {
        .pending => {
            return error.TestUnexpectedResult;
        },
        .terminal => |*completion| {
            defer completion.deinit();
            try testing.expectEqual(ui.platform.PromisedFileTerminalStatus.partial, completion.status);
            try testing.expectEqualStrings("/tmp/promised/one.txt", completion.outputs[0].path.?);
            try testing.expectEqualStrings("provider refused the second file", completion.outputs[1].error_description.?);
        },
    }
    try service.releaseOperation(operation);
    try testing.expectError(error.InvalidHandle, service.releaseBatch(batch));

    const canceled_batch = try harness.addPromisedBatch(&descriptors, &.{ .{}, .{} });
    const canceled_operation = try service.begin(canceled_batch, "/tmp/promised-canceled");
    try service.cancel(canceled_operation);
    var canceled = try service.poll(canceled_operation, testing.allocator);
    switch (canceled) {
        .pending => {
            return error.TestUnexpectedResult;
        },
        .terminal => |*completion| {
            defer completion.deinit();
            try testing.expectEqual(ui.platform.PromisedFileTerminalStatus.canceled, completion.status);
            try testing.expect(completion.outputs[0].path == null);
        },
    }
    try service.releaseOperation(canceled_operation);
    try service.releaseBatch(canceled_batch);
}

test "headless page capture is bounded, generational, and one-shot" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.offscreen_request_count = 2;
    var harness = try ui.HeadlessPlatform.createWithMemory(testing.allocator, null, memory);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();

    const service = harness.bundle.page_capture orelse return error.MissingCapability;
    harness.setPageCaptureOutcome(.{ .status = .completed, .width = 640, .height = 360 });
    const options: ui.platform.PageCaptureOptions = .{
        .url = "https://example.com/article",
        .size = .{ .width = 320, .height = 180 },
        .timeout_ns = 2 * std.time.ns_per_s,
    };
    const request = try service.begin(options);
    try testing.expect(request.isValid());
    try testing.expectError(error.ResourceBusy, service.release(request));
    try testing.expectEqual(ui.platform.PageCapturePoll.pending, try service.poll(request, testing.allocator));

    var terminal = try service.poll(request, testing.allocator);
    switch (terminal) {
        .pending => return error.TestUnexpectedResult,
        .terminal => |*completion| {
            defer completion.deinit();
            try testing.expectEqual(ui.platform.PageCaptureTerminalStatus.completed, completion.status);
            const result = completion.result orelse return error.TestUnexpectedResult;
            try testing.expectEqual(@as(u32, 640), result.width);
            try testing.expectEqual(@as(u32, 360), result.height);
            try testing.expectEqualStrings("\x89PNG\r\n\x1a\n", result.bytes);
        },
    }
    try testing.expectError(error.InvalidHandle, service.poll(request, testing.allocator));
    try service.release(request);
    try testing.expectError(error.InvalidHandle, service.release(request));

    const replacement = try service.begin(options);
    try testing.expectEqual(request.index, replacement.index);
    try testing.expect(request.generation != replacement.generation);
    try service.cancel(replacement);
    var canceled = try service.poll(replacement, testing.allocator);
    switch (canceled) {
        .pending => return error.TestUnexpectedResult,
        .terminal => |*completion| {
            defer completion.deinit();
            try testing.expectEqual(ui.platform.PageCaptureTerminalStatus.canceled, completion.status);
            try testing.expect(completion.result == null);
        },
    }
    try service.release(replacement);
}

test "headless page capture preserves failure details and validates URLs" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    const service = harness.bundle.page_capture orelse return error.MissingCapability;

    try testing.expectError(error.InvalidConfiguration, service.begin(.{ .url = "file:///tmp/private" }));
    try testing.expectError(error.InvalidConfiguration, service.begin(.{ .url = "https://" }));
    try testing.expectError(error.InvalidConfiguration, service.begin(.{ .url = "https://example.com", .size = .{ .width = 0, .height = 180 } }));

    harness.setPageCaptureOutcome(.{
        .status = .failed,
        .error_description = "LinkPresentation refused the page",
    });
    const request = try service.begin(.{ .url = "https://example.com" });
    _ = try service.poll(request, testing.allocator);
    var terminal = try service.poll(request, testing.allocator);
    switch (terminal) {
        .pending => return error.TestUnexpectedResult,
        .terminal => |*completion| {
            defer completion.deinit();
            try testing.expectEqual(ui.platform.PageCaptureTerminalStatus.failed, completion.status);
            try testing.expectEqualStrings("LinkPresentation refused the page", completion.error_description.?);
            try testing.expect(completion.result == null);
        },
    }
    try service.release(request);
}

test "headless purging a queued promised drop releases its batch" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    const service = harness.bundle.promised_files orelse return error.MissingCapability;
    const descriptors = [_]ui.platform.PromisedFileDescriptor{.{ .suggested_name = "queued.txt" }};
    const outcomes = [_]ui.HeadlessPlatform.FakePromisedOutcome{.{ .path = "/tmp/queued.txt" }};
    const batch = try harness.addPromisedBatch(&descriptors, &outcomes);
    const window = handles.WindowId.init(51, 1);
    _ = try harness.bundle.windows.create(window, .{ .title = "queued promise", .visible = false });
    try harness.post(window, .{ .input = .{ .file_drop_performed = .{
        .paths = &.{},
        .position = .{},
        .promised_batch = batch,
    } } });

    harness.bundle.windows.destroy(window);
    try testing.expectError(error.InvalidHandle, service.describe(batch, testing.allocator));
}

test "coordinator binding is single owner and returns a typed error" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    try testing.expectError(error.ResourceBusy, coordinator.bind());
}

test "effects execute and release exactly once or release unread on shutdown" {
    var executed: EffectProbe = .{};
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    try coordinator.deferEffect(executed.deferred());
    try coordinator.flushEffects();
    try testing.expectEqual(@as(usize, 1), executed.runs);
    try testing.expectEqual(@as(usize, 1), executed.drops);
    try coordinator.deinit();

    var unread: EffectProbe = .{};
    var queue = ui.runtime_effect.Queue.initWithLimit(testing.allocator, 2);
    try queue.push(.{ .deferred = unread.deferred() });
    try testing.expectError(error.FramePhaseViolation, queue.reset());
    queue.deinit();
    try testing.expectEqual(@as(usize, 0), unread.runs);
    try testing.expectEqual(@as(usize, 1), unread.drops);
}

test "dependency replacements use exact one-shot prepared tokens" {
    const component = handles.ComponentId.init(1, 1);
    const state_a = handles.StateId.init(2, 1);
    const state_b = handles.StateId.init(3, 1);
    var graph = ui.runtime_dependency.Graph.initWithLimits(testing.allocator, 8, 8, 2);
    defer graph.deinit();

    const initial = try graph.prepareComponent(component, &.{state_a});
    try graph.commitPrepared(initial);
    try testing.expectEqual(@as(usize, 1), graph.dependents(state_a).len);

    const stale = try graph.prepareComponent(component, &.{state_b});
    const current = try graph.prepareComponent(component, &.{state_a});
    try testing.expectError(error.FramePhaseViolation, graph.commitPrepared(stale));

    var other = ui.runtime_dependency.Graph.initWithLimits(testing.allocator, 8, 8, 2);
    defer other.deinit();
    try testing.expectError(error.FramePhaseViolation, other.commitPrepared(current));
    try graph.commitPrepared(current);
    try testing.expectEqual(@as(usize, 0), graph.dependents(state_b).len);
    try testing.expectEqual(@as(usize, 1), graph.dependents(state_a).len);
    try testing.expectError(error.InvalidConfiguration, graph.prepareComponent(component, &.{ state_a, state_a }));
    try testing.expectEqual(@as(usize, 1), graph.dependents(state_a).len);
}

test "dependency edge budget failure preserves the committed graph" {
    const component = handles.ComponentId.init(1, 1);
    const state_a = handles.StateId.init(2, 1);
    const state_b = handles.StateId.init(3, 1);
    var graph = ui.runtime_dependency.Graph.initWithLimits(testing.allocator, 8, 8, 1);
    defer graph.deinit();
    const prepared = try graph.prepareComponent(component, &.{state_a});
    try graph.commitPrepared(prepared);
    try testing.expectError(error.BudgetExceeded, graph.prepareComponent(component, &.{ state_a, state_b }));
    try testing.expectEqual(@as(usize, 1), graph.dependents(state_a).len);
    try testing.expectEqual(@as(usize, 0), graph.dependents(state_b).len);
}

test "destroying state removes dependency edges and invalidates its owner path" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component = handles.ComponentId.init(4, 1);
    const window = handles.WindowId.init(5, 1);
    try coordinator.invalidations.register(component, window);
    _ = coordinator.invalidations.consumeComponent(component);
    _ = coordinator.invalidations.consumeWindow(window);

    const value = try coordinator.states.create(u32, component, 9);
    var recorder = try coordinator.beginComponentDependencies(component, testing.allocator);
    defer recorder.deinit();
    _ = try coordinator.states.read(u32, value, recorder.sink());
    try recorder.finish();
    try testing.expectEqual(@as(usize, 1), coordinator.dependencies.dependents(value.id).len);

    try coordinator.states.destroy(u32, value);
    try testing.expectEqual(@as(usize, 0), coordinator.dependencies.dependents(value.id).len);
    try testing.expect(coordinator.invalidations.isWindowDirty(window));
    try testing.expect(coordinator.invalidations.consumeComponent(component) != null);
}

test "focus and hit-tree publication rejects stale or missing prepares" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const children = [_]ui.NodeSpec{.{
        .style = .{ .interaction = .{ .focusable = true } },
    }};
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());

    var manager = ui.focus.Manager.init(testing.allocator);
    defer manager.deinit();
    const stale = try manager.prepare(&store, root);
    const current = try manager.prepare(&store, root);
    try testing.expectError(error.FramePhaseViolation, manager.commitPrepared(stale));
    var other = ui.focus.Manager.init(testing.allocator);
    defer other.deinit();
    try testing.expectError(error.FramePhaseViolation, other.commitPrepared(current));
    try manager.commitPrepared(current);

    var hits = ui.hit_testing.Tree.init(testing.allocator);
    defer hits.deinit();
    try testing.expectError(error.FramePhaseViolation, hits.commitPrepared());
}

test "focus removal hands control to a newly mounted autofocus target" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var manager = ui.focus.Manager.init(testing.allocator);
    defer manager.deinit();

    const initial_children = [_]ui.NodeSpec{(ui.NodeSpec{
        .style = .{ .interaction = .{ .focusable = true } },
    }).withKey(1)};
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &initial_children }, 1, scratch.allocator());
    const initial_focus = store.getConst(root).?.children.items[0];
    try manager.rebuild(&store, root);
    try testing.expect(manager.request(&store, initial_focus));

    const replacement_children = [_]ui.NodeSpec{(ui.NodeSpec{
        .style = .{ .interaction = .{ .focusable = true, .autofocus = true } },
    }).withKey(2)};
    _ = try store.reconcile(root, .invalid, .invalid, .{ .children = &replacement_children }, 1, scratch.allocator());
    const replacement_focus = store.getConst(root).?.children.items[0];
    try manager.rebuild(&store, root);
    try testing.expect(manager.focused.eql(replacement_focus));
    try testing.expect(!manager.focused.eql(initial_focus));
}

test "accessibility snapshots own committed text across retained mutations and failed prepares" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .semantics = .{ .role = .button, .label = "before" },
    }, 1, scratch.allocator());
    var builder = ui.AccessibilityTree.initWithLimits(
        testing.allocator,
        handles.WindowId.init(1, 1),
        32,
        4096,
    );
    defer builder.deinit();
    const committed = try builder.build(&store, root, root, scratch.allocator());
    try testing.expectEqualStrings("before", committed.nodes[0].label);

    var oversized: [8192]u8 = undefined;
    @memset(&oversized, 'x');
    _ = try store.reconcile(root, .invalid, .invalid, .{
        .semantics = .{ .role = .button, .label = &oversized },
    }, 1, scratch.allocator());
    try testing.expectEqualStrings("before", committed.nodes[0].label);
    try testing.expectError(error.BudgetExceeded, builder.prepare(&store, root, root, scratch.allocator()));
    try testing.expectEqualStrings("before", committed.nodes[0].label);
}

test "accessibility prepared snapshots are owner-bound and one-shot" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .semantics = .{ .role = .button, .label = "owned" },
    }, 1, scratch.allocator());
    var first = ui.AccessibilityTree.init(testing.allocator, handles.WindowId.init(1, 1));
    defer first.deinit();
    var second = ui.AccessibilityTree.init(testing.allocator, handles.WindowId.init(2, 1));
    defer second.deinit();
    var prepared = try first.prepare(&store, root, root, scratch.allocator());
    defer prepared.deinit();
    try testing.expectError(error.FramePhaseViolation, second.commitPrepared(&prepared));
    _ = try first.commitPrepared(&prepared);
    try testing.expectError(error.FramePhaseViolation, first.commitPrepared(&prepared));
}

test "retained updates reject invalid payloads without changing committed records" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{ .kind = .{ .text = "safe" } }, 1, scratch.allocator());
    const initial_bytes = store.retainedBytes();
    const initial_generation = store.getConst(root).?.paint_generation;
    const invalid_utf8 = [_]u8{0xff};
    try testing.expectError(error.InvalidUtf8, store.reconcile(root, .invalid, .invalid, .{
        .kind = .{ .text = &invalid_utf8 },
    }, 1, scratch.allocator()));
    try testing.expectEqual(initial_bytes, store.retainedBytes());
    try testing.expectEqual(initial_generation, store.getConst(root).?.paint_generation);

    const nan: f32 = @bitCast(@as(u32, 0x7fc00000));
    try testing.expectError(error.InvalidConfiguration, store.reconcile(root, .invalid, .invalid, .{
        .kind = .{ .text = "safe" },
        .style = .{ .paint = .{ .opacity = nan } },
    }, 1, scratch.allocator()));
    try testing.expectEqual(initial_bytes, store.retainedBytes());
    try testing.expectEqual(initial_generation, store.getConst(root).?.paint_generation);
}

test "file drops preserve mixed paths and text within the aggregate payload bound" {
    const path = "/tmp/from-native-file-url";
    const uri_list = "https://example.com/item\r\nfile:///tmp/from-uri-list\r\n";
    var event: ui.input.Event = .{ .file_drop_performed = .{
        .paths = &.{path},
        .position = .{ .x = 4, .y = 8 },
        .text = uri_list,
    } };
    try ui.input.validate(&event, .{ .maximum_payload_bytes = path.len + uri_list.len });

    try testing.expectError(error.BudgetExceeded, ui.input.validate(&event, .{
        .maximum_payload_bytes = path.len + uri_list.len - 1,
    }));

    const invalid_text = [_]u8{0xff};
    event = .{ .file_drop_performed = .{
        .paths = &.{path},
        .position = .{ .x = 4, .y = 8 },
        .text = &invalid_text,
    } };
    try testing.expectError(error.InvalidUtf8, ui.input.validate(&event, .{}));
}

test "retained byte budget rejects replacement and preserves old ownership" {
    var store = ui.NodeStore.initWithLimits(testing.allocator, .{
        .maximum_nodes = 16,
        .maximum_depth = 16,
        .maximum_bytes = 1024,
    });
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .semantics = .{ .label = "old" },
    }, 1, scratch.allocator());
    const initial_bytes = store.retainedBytes();
    var oversized: [2048]u8 = undefined;
    @memset(&oversized, 'b');
    try testing.expectError(error.BudgetExceeded, store.reconcile(root, .invalid, .invalid, .{
        .semantics = .{ .label = &oversized },
    }, 1, scratch.allocator()));
    try testing.expectEqual(initial_bytes, store.retainedBytes());
    var iterator = store.inspectIterator();
    try testing.expectEqualStrings("old", iterator.next().?.semantic_label);
}

test "retained tree validation detects duplicates parent mismatch cycles and depth" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const children = [_]ui.NodeSpec{ .{}, .{} };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());
    const first_child = store.getConst(root).?.children.items[0];
    const second_child = store.getConst(root).?.children.items[1];

    store.get(root).?.children.items[1] = first_child;
    try testing.expectError(error.InvalidConfiguration, store.validateTree(root, scratch.allocator()));
    store.get(root).?.children.items[1] = second_child;

    store.get(first_child).?.parent = .invalid;
    try testing.expectError(error.InvalidConfiguration, store.validateTree(root, scratch.allocator()));
    store.get(first_child).?.parent = root;

    try store.reserveChildren(first_child, 1);
    store.get(first_child).?.children.appendAssumeCapacity(root);
    try testing.expectError(error.InvalidConfiguration, store.validateTree(root, scratch.allocator()));
    store.get(first_child).?.children.clearRetainingCapacity();
    try store.validateTree(root, scratch.allocator());

    var shallow = ui.NodeStore.initWithLimits(testing.allocator, .{
        .maximum_nodes = 16,
        .maximum_depth = 3,
        .maximum_bytes = 4096,
    });
    defer shallow.deinit();
    const level_three_children = [_]ui.NodeSpec{.{}};
    const level_two_children = [_]ui.NodeSpec{.{ .children = &level_three_children }};
    const level_one_children = [_]ui.NodeSpec{.{ .children = &level_two_children }};
    try testing.expectError(error.BudgetExceeded, shallow.reconcile(null, .invalid, .invalid, .{
        .children = &level_one_children,
    }, 1, scratch.allocator()));
    try testing.expectEqual(@as(usize, 0), shallow.retainedBytes());
}

test "configuration validates retained platform clipboard menu and action budgets" {
    var config_value: ui.config.AppConfig = .{};
    config_value.memory.retained_tree_depth = 513;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.platform_event_payload_bytes = config_value.memory.platform_event_queue_bytes + 1;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.platform_text_bytes = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.platform_retained_text_bytes = config_value.memory.platform_text_bytes - 1;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.clipboard_retained_bytes = config_value.memory.clipboard_bytes - 1;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.menu_depth = 129;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.action_name_bytes = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.layout_grid_cell_count = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.font_catalog_count = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.font_catalog_bytes = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));

    config_value = .{};
    config_value.memory.font_instance_count = 0;
    try testing.expectError(error.InvalidConfiguration, ui.config.validate(config_value));
}

test "action registry owns names within an aggregate byte budget" {
    var registry = ui.actions.Registry.initWithBudgets(testing.allocator, 4, 4, 5);
    defer registry.deinit();
    const first = try registry.register("abc");
    try testing.expect((try registry.register("abc")).eql(first));
    try testing.expectEqual(@as(usize, 3), registry.registeredNameBytes());
    _ = try registry.register("de");
    try testing.expectEqual(@as(usize, 5), registry.registeredNameBytes());
    try testing.expectError(error.InvalidConfiguration, registry.register("longer"));
    try testing.expectError(error.BudgetExceeded, registry.register("f"));
    try testing.expectEqual(@as(usize, 5), registry.registeredNameBytes());
}

test "menu validation rejects invalid trees before invoking native code" {
    var probe: MenuProbe = .{};
    const menus: ui.platform.Menus = .{
        .context = &probe,
        .set_application_menu_fn = MenuProbe.set,
        .show_context_menu_fn = MenuProbe.show,
        .limits = .{ .maximum_items = 2, .maximum_depth = 2, .maximum_text_bytes = 8 },
    };
    const action_id = handles.ActionId.init(1, 1);
    const valid = [_]ui.platform.MenuItem{.{ .action = .{
        .label = "Open",
        .action = action_id,
        .payload = 0xfeed_beef,
        .shortcut = .{ .key = .{ .character = 'o' }, .modifiers = .{ .command = true } },
    } }};
    try menus.setApplicationMenu(&valid);
    try testing.expectEqual(@as(usize, 1), probe.set_calls);
    try testing.expectEqual(@as(u64, 0xfeed_beef), probe.payload);
    var invocation_event: ui.platform.WindowEvent = .{ .menu_action = .{ .action = action_id, .payload = 0xfeed_beef } };
    try ui.platform.validateWindowEvent(&invocation_event);

    const standard = [_]ui.platform.MenuItem{.{ .application = .{ .items = &.{.{ .system_action = .{ .label = "About", .action = .about_application } }} } }};
    try menus.setApplicationMenu(&standard);
    try testing.expectEqual(@as(usize, 2), probe.set_calls);

    const too_many = [_]ui.platform.MenuItem{ .separator, .separator, .separator };
    try testing.expectError(error.BudgetExceeded, menus.setApplicationMenu(&too_many));
    const invalid_text = [_]u8{0xff};
    const invalid = [_]ui.platform.MenuItem{.{ .action = .{ .label = &invalid_text, .action = action_id } }};
    try testing.expectError(error.InvalidUtf8, menus.setApplicationMenu(&invalid));
    const invalid_function = [_]ui.platform.MenuItem{.{ .action = .{ .label = "Open", .action = action_id, .shortcut = .{ .key = .{ .function = 0 } } } }};
    try testing.expectError(error.InvalidConfiguration, menus.setApplicationMenu(&invalid_function));
    const native_shortcut = [_]ui.platform.MenuItem{.{ .action = .{ .label = "Open", .action = action_id, .shortcut = .{ .key = .{ .native = 1 } } } }};
    try testing.expectError(error.Unsupported, menus.setApplicationMenu(&native_shortcut));
    const leaf = [_]ui.platform.MenuItem{.separator};
    const middle = [_]ui.platform.MenuItem{.{ .submenu = .{ .label = "M", .items = &leaf } }};
    const deep = [_]ui.platform.MenuItem{.{ .submenu = .{ .label = "D", .items = &middle } }};
    try testing.expectError(error.BudgetExceeded, menus.setApplicationMenu(&deep));
    try testing.expectEqual(@as(usize, 2), probe.set_calls);
}

const MenuDispatchProbe = struct {
    action: handles.ActionId,
    invocations: usize = 0,
    child_invocations: usize = 0,
    payload: u64 = 0,
    focus_target: bool = false,

    pub fn build(self: *MenuDispatchProbe, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const handlers = try ctx.allocator.dupe(ui.actions.Handler, &.{.{
            .action = self.action,
            .callback_context = self,
            .callback = receive,
        }});
        const child_handlers = try ctx.allocator.dupe(ui.actions.Handler, &.{.{
            .action = self.action,
            .callback_context = self,
            .callback = receiveChild,
        }});
        const children = try ctx.allocator.alloc(ui.NodeSpec, 1);
        children[0] = .{
            .kind = .spacer,
            .style = .{ .layout = .{ .width = .{ .points = 10 }, .height = .{ .points = 10 } }, .interaction = .{ .focusable = true, .tab_index = -1, .autofocus = self.focus_target } },
            .action_handlers = child_handlers,
        };
        return .{
            .kind = .container,
            .action_handlers = handlers,
            .children = children,
        };
    }

    fn receive(
        context: *anyopaque,
        dispatch: *ui.actions.Dispatch,
        invocation: ui.actions.ActionEvent,
        ctx: *ui.input.Context,
    ) ui.Error!void {
        const self: *MenuDispatchProbe = @ptrCast(@alignCast(context));
        self.invocations += 1;
        self.payload = invocation.menu_payload;
        self.focus_target = true;
        ctx.requestAutofocusAfterReconcile();
        try ctx.invalidate(.{});
        dispatch.handled = true;
    }

    fn receiveChild(context: *anyopaque, dispatch: *ui.actions.Dispatch, _: ui.actions.ActionEvent, _: *ui.input.Context) ui.Error!void {
        const self: *MenuDispatchProbe = @ptrCast(@alignCast(context));
        self.child_invocations += 1;
        dispatch.handled = true;
    }
};

test "application menu actions dispatch to the retained component root" {
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(
        testing.allocator,
        8 * 1024 * 1024,
        16 * 1024 * 1024,
        64,
        64,
        64 * 1024,
    );
    const text_backend = text_backend_instance.interface();
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend);
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "menu dispatch conformance",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;

    const action = try app.registerAction("conformance.root-menu-action");
    var model: MenuDispatchProbe = .{ .action = action };
    const window = try app.openWindow(.{
        .platform = .{ .title = "menu dispatch", .size = .{ .width = 320, .height = 240 } },
    }, ui.Component.Descriptor.from(MenuDispatchProbe, &model));
    while (try app.step(false)) {}

    try harness.post(window, .{ .menu_action = .{ .action = action, .payload = 0x5eed } });
    while (try app.step(false)) {}

    try testing.expectEqual(@as(usize, 1), model.invocations);
    try testing.expectEqual(@as(u64, 0x5eed), model.payload);

    try harness.post(window, .{ .menu_action = .{ .action = action, .payload = 0xbeef } });
    while (try app.step(false)) {}
    try testing.expectEqual(@as(usize, 1), model.child_invocations);
}

test "application and native media services validate inputs before platform calls" {
    var clipboard_probe: ClipboardPathProbe = .{};
    const clipboard = clipboard_probe.service();
    const clipboard_paths = [_][]const u8{ "/tmp/first.txt", "/tmp/second.txt" };
    try clipboard.writePaths(&clipboard_paths);
    try testing.expectEqual(@as(usize, 1), clipboard_probe.calls);
    try testing.expectEqual(@as(usize, 2), clipboard_probe.path_count);
    try clipboard.writeImage(.{ .format = .png, .bytes = "png" });
    try testing.expectEqual(@as(usize, 1), clipboard_probe.image_calls);
    try testing.expectEqualStrings("png", clipboard_probe.image_bytes);
    try testing.expectError(error.InvalidConfiguration, clipboard.writeImage(.{ .format = .png, .bytes = &.{} }));
    try testing.expectError(error.InvalidConfiguration, clipboard.writePaths(&.{}));
    try testing.expectError(error.InvalidUtf8, clipboard.writePaths(&.{"bad\x00path"}));

    var applications: ApplicationServiceProbe = .{};
    const services = applications.service();
    try services.openUrl("https://example.com/item");
    try services.openPath("/tmp/item");
    try services.revealPath("/tmp/item");
    try services.printPath("/tmp/item.pdf");
    try testing.expectEqual(@as(usize, 4), applications.calls);
    try testing.expectError(error.InvalidConfiguration, services.openUrl(""));
    try testing.expectError(error.InvalidUtf8, services.openPath("bad\x00path"));

    var media_probe: NativeMediaProbe = .{};
    const native_media = media_probe.service();
    const window = handles.WindowId.init(3, 1);
    const id = try native_media.create(window, .{
        .source = .{ .file = "/tmp/movie.mov" },
        .frame = ui.Rect.fromXYWH(10, 20, 320, 180),
        .volume = 0.75,
    });
    try native_media.setFrame(id, ui.Rect.fromXYWH(0, 0, 640, 360));
    const placements = [_]ui.core.native_media.Placement{.{ .id = id, .bounds = ui.Rect.fromXYWH(12, 18, 300, 170) }};
    try native_media.synchronize(window, &placements);
    try native_media.pause(id);
    try native_media.play(id);
    try native_media.seek(id, 42);
    try native_media.setVolume(id, 0.25);
    try native_media.setMuted(id, true);
    const state = try native_media.state(id);
    try testing.expectEqual(ui.platform.NativeMediaStatus.ready, state.status);
    try testing.expect(state.playing);
    try testing.expectEqual(@as(f32, 0.25), state.volume);
    try testing.expect(state.muted);
    try native_media.destroy(id);
    try testing.expectEqual(@as(usize, 10), media_probe.calls);
    try testing.expectError(error.InvalidConfiguration, native_media.setVolume(id, 2));
}

test "native media failure detail is copied and malformed provider state is rejected" {
    var media_probe: NativeMediaProbe = .{};
    const native_media = media_probe.service();
    const id = try native_media.create(handles.WindowId.init(4, 1), .{
        .source = .{ .file = "/tmp/malformed.mov" },
        .frame = ui.Rect.fromXYWH(0, 0, 320, 180),
    });

    media_probe.status = .failed;
    media_probe.error_description = try ui.platform.NativeMediaErrorDescription.init(
        "The media could not be opened: unsupported codec",
    );
    const state = try native_media.state(id);
    try testing.expectEqual(ui.platform.NativeMediaStatus.failed, state.status);
    try testing.expect(state.error_description != null);
    try testing.expectEqualStrings(
        "The media could not be opened: unsupported codec",
        state.error_description.?.slice(),
    );

    var malformed: ui.platform.NativeMediaErrorDescription = .{ .length = 1 };
    malformed.bytes[0] = 0xff;
    media_probe.error_description = malformed;
    try testing.expectError(error.PlatformFailure, native_media.state(id));

    try native_media.destroy(id);
}

test "native media keeps a presented frame independent of playback rate" {
    var media_probe: NativeMediaProbe = .{ .playing = false, .has_presented_frame = true };
    const native_media = media_probe.service();
    const id = try native_media.create(handles.WindowId.init(5, 1), .{
        .source = .{ .file = "/tmp/paused.mov" },
        .frame = ui.Rect.fromXYWH(0, 0, 320, 180),
    });
    const state = try native_media.state(id);
    try testing.expect(!state.playing);
    try testing.expect(state.has_presented_frame);
    try native_media.destroy(id);
}

test "headless queued payloads are deep copied and aggregate bounded" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    const window = handles.WindowId.init(9, 1);
    var collector: PayloadCollector = .{};
    const sink: ui.platform.EventSink = .{ .context = &collector, .callback = PayloadCollector.receive };

    var ime_bytes = [_]u8{ 'i', 'm', 'e' };
    try harness.post(window, .{ .input = .{ .ime = .{ .commit_text = .{
        .text = &ime_bytes,
        .replacement_utf8 = null,
    } } } });
    var path_bytes = [_]u8{ '/', 't', 'm', 'p', '/', 'a' };
    var drop_text_bytes = [_]u8{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm' };
    var paths = [_][]const u8{&path_bytes};
    try harness.post(window, .{ .input = .{ .file_drop_performed = .{
        .paths = &paths,
        .position = .{ .x = 3, .y = 4 },
        .text = &drop_text_bytes,
    } } });
    var accessibility_bytes = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    try harness.post(window, .{ .accessibility_action = .{
        .window = window,
        .target = handles.SemanticId.init(2, 1),
        .action = .set_value,
        .value = &accessibility_bytes,
    } });
    ime_bytes[0] = 'x';
    path_bytes[5] = 'z';
    drop_text_bytes[0] = 'x';
    accessibility_bytes[0] = 'x';
    while (try harness.bundle.event_loop.step(sink, false)) {}
    try testing.expect(collector.ime_owned);
    try testing.expect(collector.path_owned);
    try testing.expect(collector.drop_text_owned);
    try testing.expect(collector.accessibility_owned);

    var constrained_memory: ui.config.MemoryBudgets = .{};
    constrained_memory.platform_event_payload_bytes = 8;
    constrained_memory.platform_event_queue_bytes = 10;
    var constrained = try ui.HeadlessPlatform.createWithMemory(testing.allocator, null, constrained_memory);
    defer constrained.bundle.deinit();
    defer constrained.bundle.renderer.deinit();
    var six = [_]u8{ '1', '2', '3', '4', '5', '6' };
    const queued: ui.platform.WindowEvent = .{ .input = .{ .ime = .{ .commit_text = .{
        .text = &six,
        .replacement_utf8 = null,
    } } } };
    try constrained.post(window, queued);
    try testing.expectError(error.BudgetExceeded, constrained.post(window, queued));
}

test "headless window creation reserves its entire initial event transaction" {
    var memory: ui.config.MemoryBudgets = .{};
    memory.platform_event_count = 1;
    var harness = try ui.HeadlessPlatform.createWithMemory(testing.allocator, null, memory);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    const window = handles.WindowId.init(7, 1);
    try testing.expectError(error.BudgetExceeded, harness.bundle.windows.create(window, .{
        .title = "bounded",
        .visible = false,
    }));
    try testing.expect(harness.bundle.windows.nativeHandle(window) == null);
}

test "scene primitive budget spans every typed primitive stream" {
    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{ .primitives = 1 });
    defer builder.deinit();
    try builder.quad(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
        .background = ui.Color.white,
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    }, null);
    try testing.expectError(error.BudgetExceeded, builder.backdropEffect(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
        .radii = .{},
        .blur_radius = 1,
        .saturation = 1,
    }));
    try testing.expectError(error.BudgetExceeded, builder.underline(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
        .color = ui.Color.white,
        .thickness = 1,
        .wave_amplitude = 0,
        .wave_period = 1,
    }));
    try testing.expectEqual(@as(usize, 1), scene.quads.items.len);
    try testing.expectEqual(@as(usize, 0), scene.underlines.items.len);
}

test "platform event validation rejects malformed native lifecycle data" {
    const valid: ui.platform.WindowEvent = .{ .configured = .{
        .logical_size = .{ .width = 640, .height = 480 },
        .scale_factor = try ui.ScaleFactor.init(2),
    } };
    try ui.platform.validateWindowEvent(&valid);

    const nan: f32 = @bitCast(@as(u32, 0x7fc00000));
    const invalid_size: ui.platform.WindowEvent = .{ .resized = .{ .width = nan, .height = 10 } };
    try testing.expectError(error.InvalidConfiguration, ui.platform.validateWindowEvent(&invalid_size));
    const invalid_handle: ui.platform.WindowEvent = .{ .created = .{ .kind = .none, .value = 0 } };
    try testing.expectError(error.PlatformFailure, ui.platform.validateWindowEvent(&invalid_handle));
}

test "headless asynchronous failures remain sticky until teardown" {
    var harness = try ui.HeadlessPlatform.create(testing.allocator, null);
    defer harness.bundle.deinit();
    defer harness.bundle.renderer.deinit();
    harness.injectFailure(error.DeviceLost);
    var events: EventCollector = .{};
    const sink: ui.platform.EventSink = .{ .context = &events, .callback = EventCollector.receive };
    try testing.expectError(error.DeviceLost, harness.bundle.event_loop.step(sink, false));
    try testing.expectError(error.DeviceLost, harness.bundle.event_loop.step(sink, false));
    try testing.expectError(error.DeviceLost, harness.bundle.event_loop.run(sink));
}

test "grid auto placement avoids later explicit cells and respects spans" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const tracks = [_]ui.layout.GridTrack{ .{ .points = 50 }, .{ .points = 50 } };
    const children = [_]ui.NodeSpec{
        (ui.NodeSpec{ .kind = .spacer, .style = .{ .layout = .{ .width = .{ .points = 10 }, .height = .{ .points = 10 } } } }).withKey(1),
        (ui.NodeSpec{ .kind = .spacer, .style = .{ .layout = .{
            .width = .{ .points = 10 },
            .height = .{ .points = 10 },
            .grid_column = 1,
            .grid_row = 1,
        } } }).withKey(2),
        (ui.NodeSpec{ .kind = .spacer, .style = .{ .layout = .{
            .height = .{ .points = 10 },
            .grid_column_span = 2,
        } } }).withKey(3),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid, .grid_columns = &tracks } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try engine.layout(&store, root, .{ .width = 100, .height = 80 });
    const retained = store.getConst(root).?.children.items;
    try testing.expectApproxEqAbs(@as(f32, 50), store.getConst(retained[0]).?.layout.bounds.origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), store.getConst(retained[1]).?.layout.bounds.origin.x, 0.001);
    try testing.expect(store.getConst(retained[2]).?.layout.bounds.origin.y > 0);
    try testing.expectApproxEqAbs(@as(f32, 100), store.getConst(retained[2]).?.layout.bounds.size.width, 0.001);
}

test "grid sparse placement is refused by the configured cell budget" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const children = [_]ui.NodeSpec{.{
        .kind = .spacer,
        .style = .{ .layout = .{ .grid_row = 4 } },
    }};
    const root = try store.reconcile(null, .invalid, .invalid, .{
        .style = .{ .layout = .{ .display = .grid } },
        .children = &children,
    }, 1, scratch.allocator());
    var measure_context: u8 = 0;
    var engine: ui.LayoutEngine = .{
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .maximum_grid_cells = 3,
        .measures = .{
            .context = &measure_context,
            .text_fn = emptyTextMeasure,
            .custom_measure_fn = emptyCustomMeasure,
        },
    };
    try testing.expectError(error.BudgetExceeded, engine.layout(&store, root, .{ .width = 100, .height = 100 }));
}

test "arrange feedback stabilizes inside one submitted frame" {
    var model: LayoutFeedbackProbe = .{ .stop_after = 3 };
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "layout feedback test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;
    _ = try app.openWindow(.{ .platform = .{ .title = "feedback" } }, ui.Component.Descriptor.from(LayoutFeedbackProbe, &model));
    while (try app.step(false)) {}
    try testing.expectEqual(@as(usize, 3), model.arrange_count);
    try testing.expectEqual(@as(u64, 1), (try app.metricsSnapshot()).frames_submitted);
}

test "unbounded arrange feedback terminates with a sticky typed failure" {
    var model: LayoutFeedbackProbe = .{ .stop_after = std.math.maxInt(usize) };
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "layout feedback budget test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;
    _ = try app.openWindow(.{ .platform = .{ .title = "feedback budget" } }, ui.Component.Descriptor.from(LayoutFeedbackProbe, &model));
    var observed = false;
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        _ = app.step(false) catch |err| {
            try testing.expectEqual(error.BudgetExceeded, err);
            observed = true;
            break;
        };
    }
    try testing.expect(observed);
    try testing.expectError(error.BudgetExceeded, app.step(false));
}

test "text field clipboard editing history and IME are bounded and reversible" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component_id = handles.ComponentId.init(1, 1);
    const window_id = handles.WindowId.init(1, 1);
    const node_id = handles.NodeId.init(1, 1);
    try coordinator.invalidations.register(component_id, window_id);
    var clipboard: ClipboardProbe = .{};
    defer clipboard.deinit();
    var text_input: TextInputProbe = .{};
    var context: ui.input.Context = .{
        .coordinator = &coordinator,
        .component = component_id,
        .window = window_id,
        .current_layout_bounds = ui.Rect.fromXYWH(0, 0, 200, 30),
        .native_clipboard = clipboard.bridge(),
        .native_text_input = text_input.bridge(),
    };
    var dispatch: ui.input.Dispatch = .{
        .window = window_id,
        .target = node_id,
        .current = node_id,
        .phase = .target,
    };
    var field = try ui.widgets.TextField.init(testing.allocator, "hello");
    defer field.deinit();
    field.selection = .{ .start = 1, .end = 4 };

    try field.replaceSelection("**ell**", .{ .start = 2, .end = 5 }, &context);
    try testing.expectEqualStrings("h**ell**o", field.value());
    try testing.expectEqual(ui.input.TextRange{ .start = 3, .end = 6 }, field.selection);
    try testing.expectEqual(ui.input.TextRange{ .start = 3, .end = 6 }, text_input.selection);
    try sendShortcut(&field, &dispatch, &context, 'z', false);
    try testing.expectEqualStrings("hello", field.value());
    try testing.expectEqual(ui.input.TextRange{ .start = 1, .end = 4 }, field.selection);
    try sendShortcut(&field, &dispatch, &context, 'z', true);
    try testing.expectEqualStrings("h**ell**o", field.value());
    try testing.expectEqual(ui.input.TextRange{ .start = 3, .end = 6 }, field.selection);
    try field.setValue("hello");
    field.selection = .{ .start = 1, .end = 4 };

    try sendShortcut(&field, &dispatch, &context, 'x', false);
    try testing.expectEqualStrings("ho", field.value());
    try testing.expectEqualStrings("ell", clipboard.value());
    try sendShortcut(&field, &dispatch, &context, 'z', false);
    try testing.expectEqualStrings("hello", field.value());
    try sendShortcut(&field, &dispatch, &context, 'z', true);
    try testing.expectEqualStrings("ho", field.value());
    try sendShortcut(&field, &dispatch, &context, 'v', false);
    try testing.expectEqualStrings("hello", field.value());

    field.selection = .{ .start = field.value().len, .end = field.value().len };
    const marked: ui.input.Event = .{ .ime = .{ .set_marked_text = .{
        .text = "世",
        .selected_utf8 = .{ .start = 3, .end = 3 },
        .replacement_utf8 = null,
    } } };
    try field.event(&dispatch, &marked, &context);
    const cancel: ui.input.Event = .{ .ime = .cancel_composition };
    try field.event(&dispatch, &cancel, &context);
    try testing.expectEqualStrings("hello", field.value());
    try field.event(&dispatch, &marked, &context);
    const unmark: ui.input.Event = .{ .ime = .unmark_text };
    try field.event(&dispatch, &unmark, &context);
    try testing.expectEqualStrings("hello世", field.value());

    field.selection = .{ .start = field.value().len, .end = 0 };
    try sendShortcut(&field, &dispatch, &context, 'c', false);
    try testing.expectEqual(@as(usize, 0), text_input.selection.start);
    try testing.expectEqual(field.value().len, text_input.selection.end);

    field.clearHistory();
    field.maximum_history_entries = 0;
    field.selection = .{ .start = field.value().len, .end = field.value().len };
    const history_free_commit: ui.input.Event = .{ .ime = .{ .commit_text = .{
        .text = "!",
        .replacement_utf8 = null,
    } } };
    try field.event(&dispatch, &history_free_commit, &context);
    try testing.expectEqualStrings("hello世!", field.value());
}

test "text field publishes selection before native input activation" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component_id = handles.ComponentId.init(1, 1);
    const window_id = handles.WindowId.init(1, 1);
    const node_id = handles.NodeId.init(1, 1);
    try coordinator.invalidations.register(component_id, window_id);
    var text_input: TextInputProbe = .{};
    var context: ui.input.Context = .{
        .coordinator = &coordinator,
        .component = component_id,
        .window = window_id,
        .current_layout_bounds = ui.Rect.fromXYWH(0, 0, 200, 30),
        .native_text_input = text_input.bridge(),
    };
    var dispatch: ui.input.Dispatch = .{
        .window = window_id,
        .target = node_id,
        .current = node_id,
        .phase = .target,
    };
    var field = try ui.widgets.TextField.init(testing.allocator, "## Heading");
    defer field.deinit();
    field.selection = .{ .start = 3, .end = 10 };

    const focus: ui.input.Event = .focus_in;
    try field.event(&dispatch, &focus, &context);

    try testing.expect(text_input.active);
    try testing.expect(text_input.activation_observed_surrounding_text);
    try testing.expectEqual(ui.input.TextRange{ .start = 3, .end = 10 }, text_input.activation_selection);
}

test "text field visual configuration drives layout paint hit testing and IME geometry" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var build_context: ui.Component.BuildContext = undefined;
    build_context.allocator = scratch.allocator();

    var field = try ui.widgets.TextField.init(testing.allocator, "abcd");
    defer field.deinit();

    const default_spec = try field.build(&build_context);
    try testing.expect(std.meta.eql(default_spec.style.layout.padding, ui.layout.LengthEdges{
        .top = .{ .points = 6 },
        .right = .{ .points = 9 },
        .bottom = .{ .points = 6 },
        .left = .{ .points = 9 },
    }));
    try testing.expectEqual(ui.widgets.Theme.dark.surface, switch (default_spec.style.paint.background) {
        .solid => |color| color,
        else => unreachable,
    });
    try testing.expectEqual(ui.widgets.Theme.dark.border, default_spec.style.paint.border.color);
    try testing.expectEqual(ui.widgets.Theme.dark.radius, default_spec.style.paint.radii.top_left);
    try testing.expectEqual(ui.widgets.Theme.dark.text, default_spec.style.text.color);
    try testing.expect(default_spec.style.text.line_height == null);

    const surface = ui.Color.rgba(0.12, 0.18, 0.24, 0.92);
    const border = ui.Color.rgba(0.35, 0.48, 0.61, 1);
    const text = ui.Color.rgba(0.91, 0.86, 0.72, 1);
    const placeholder = ui.Color.rgba(0.42, 0.49, 0.57, 1);
    field.visual = .{
        .content_insets = .{ .top = 7, .right = 11, .bottom = 5, .left = 13 },
        .surface_color = surface,
        .border_color = border,
        .radius = 17,
        .text_color = text,
        .placeholder_color = placeholder,
        .line_height = 42,
    };
    const configured_spec = try field.build(&build_context);
    try testing.expect(std.meta.eql(configured_spec.style.layout.padding, ui.layout.LengthEdges{
        .top = .{ .points = 7 },
        .right = .{ .points = 11 },
        .bottom = .{ .points = 5 },
        .left = .{ .points = 13 },
    }));
    try testing.expectEqual(surface, switch (configured_spec.style.paint.background) {
        .solid => |color| color,
        else => unreachable,
    });
    try testing.expectEqual(border, configured_spec.style.paint.border.color);
    try testing.expectEqual(@as(f32, 17), configured_spec.style.paint.radii.top_left);
    try testing.expectEqual(text, configured_spec.style.text.color);
    try testing.expectEqual(@as(f32, 42), configured_spec.style.text.line_height.?);

    var probe: TextGeometryProbe = .{};
    var measure_context: ui.custom.MeasureContext = .{
        .allocator = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .text = probe.services(),
    };
    const measured = try field.measure(&measure_context, .{ .maximum = .{ .width = 100, .height = 100 } });
    try testing.expectEqual(@as(f32, 42), measured.height);
    try testing.expectEqual(@as(f32, 42), probe.last_measure_style.line_height.?);
    try testing.expectEqual(text, probe.last_measure_style.color);

    var paint_context: ui.custom.PaintContext = .{
        .scene_context = &probe,
        .emit_fn = TextGeometryProbe.emit,
        .scratch = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
        .text = probe.services(),
    };
    try field.paint(&paint_context, ui.Rect.fromXYWH(0, 0, 120, 80));
    try testing.expectEqual(ui.Rect.fromXYWH(13, 7, 96, 68), field.last_content_bounds);
    try testing.expectEqual(ui.Rect.fromXYWH(13, 7, 96, 68), probe.last_paint_bounds);
    try testing.expectEqual(text, probe.last_paint_style.color);
    try testing.expectEqual(@as(f32, 42), probe.last_paint_style.line_height.?);
    try testing.expectEqual(@as(f32, 96), probe.last_caret_max_width);
    try testing.expectEqual(@as(f32, 42), probe.last_caret_style.line_height.?);

    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component_id = handles.ComponentId.init(1, 1);
    const window_id = handles.WindowId.init(1, 1);
    const node_id = handles.NodeId.init(1, 1);
    try coordinator.invalidations.register(component_id, window_id);
    var text_input: TextInputProbe = .{};
    var input_context: ui.input.Context = .{
        .coordinator = &coordinator,
        .component = component_id,
        .window = window_id,
        .current_layout_bounds = ui.Rect.fromXYWH(0, 0, 120, 80),
        .native_text_input = text_input.bridge(),
    };
    var dispatch: ui.input.Dispatch = .{
        .window = window_id,
        .target = node_id,
        .current = node_id,
        .phase = .target,
    };
    const pointer_down: ui.input.Event = .{ .pointer_down = .{
        .pointer_id = 17,
        .position = .{ .x = 29, .y = 12 },
        .button = .primary,
        .click_count = 1,
    } };
    try field.event(&dispatch, &pointer_down, &input_context);
    try testing.expectEqual(@as(usize, 2), field.selection.start);
    try testing.expectEqual(@as(usize, 2), field.selection.end);
    try testing.expectEqual(@as(f32, 16), probe.last_hit_point.x);
    try testing.expectEqual(@as(f32, 96), probe.last_hit_max_width);
    try testing.expectEqual(text, probe.last_hit_style.color);
    try testing.expectEqual(@as(f32, 42), probe.last_hit_style.line_height.?);
    try testing.expect(text_input.candidate_rect_calls != 0);
    try testing.expectEqual(@as(f32, 29), text_input.candidate_rect.origin.x);
    try testing.expectEqual(@as(f32, 7), text_input.candidate_rect.origin.y);

    field.placeholder = "placeholder";
    try field.setValue("");
    try field.paint(&paint_context, ui.Rect.fromXYWH(0, 0, 120, 80));
    try testing.expectEqual(placeholder, probe.last_paint_style.color);

    field.disabled = true;
    const disabled_spec = try field.build(&build_context);
    try testing.expect(disabled_spec.semantics.disabled);
    try testing.expectEqual(@as(usize, 0), disabled_spec.semantics.actions.len);
    field.disabled = false;
    field.focused = true;
    const focused_spec = try field.build(&build_context);
    try testing.expectEqual(ui.widgets.Theme.dark.focus_ring, focused_spec.style.paint.border.color);
    try testing.expectEqual(configured_spec.semantics.actions.len, focused_spec.semantics.actions.len);
}

test "text field setValue preserves committed text across allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, textFieldSetValueAllocationProbe, .{});
}

test "button clicks keep focus without a ring and keyboard navigation restores it" {
    const Model = struct {
        button: ui.widgets.Button = undefined,
        other: ui.widgets.Button = undefined,
        activations: usize = 0,
        paint: ui.style.PaintStyle = .{},

        pub fn build(self: *@This(), ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
            var first = try self.button.build(ctx);
            var second = try self.other.build(ctx);
            // Exercise icon-only controls without depending on installed fonts.
            first.children = &.{};
            second.children = &.{};
            first.style.layout.width = .{ .points = 120 };
            second.style.layout.width = .{ .points = 120 };
            self.paint = first.style.paint;
            return .{
                .style = .{ .layout = .{ .direction = .column, .align_items = .start } },
                .children = try ctx.allocator.dupe(ui.NodeSpec, &.{ first.withKey(1), second.withKey(2) }),
            };
        }

        pub fn activate(self: *@This(), _: *ui.input.Context) void {
            self.activations += 1;
        }
    };
    var model: Model = .{};
    const callback = ui.widgets.Callback.from(Model, &model, "activate");
    model.button = .{ .label = "Sort direction", .on_activate = callback };
    model.other = .{ .label = "Other", .on_activate = callback };
    var text_backend_instance = try ui.InTreeTextBackend.createInstance(testing.allocator, 8 * 1024 * 1024, 16 * 1024 * 1024, 64, 64, 64 * 1024);
    var harness = try ui.HeadlessPlatform.create(testing.allocator, text_backend_instance.interface());
    const bundle = harness.bundle;
    harness.bundle = undefined;
    const app = try ui.App.createWithBundle(testing.allocator, .{
        .application_name = "button focus visibility test",
        .allow_multiple_apps_for_testing = true,
    }, bundle);
    defer app.destroy() catch unreachable;
    const window = try app.openWindow(.{ .platform = .{ .title = "button focus", .size = .{ .width = 320, .height = 240 } } }, ui.Component.Descriptor.from(Model, &model));
    while (try app.step(false)) {}

    // Repeat after keyboard activation to cover clicking an already focused button.
    for (0..2) |click| {
        try harness.post(window, .{ .input = .{ .pointer_down = .{ .position = .{ .x = 10, .y = 10 }, .button = .primary } } });
        while (try app.step(false)) {}
        try testing.expect(model.button.focused and model.button.pressed);
        try testing.expect(!model.button.focusVisible());
        try testing.expectEqual(model.button.theme.border, model.paint.border.color);
        try testing.expectEqual(model.button.theme.surface_pressed, model.paint.background.solid);

        try harness.post(window, .{ .input = .{ .pointer_up = .{ .position = .{ .x = 10, .y = 10 }, .button = .primary } } });
        while (try app.step(false)) {}
        try testing.expectEqual(click * 2 + 1, model.activations);
        try testing.expect(model.button.focused and !model.button.pressed);
        try testing.expect(!model.button.focusVisible());
        try testing.expectEqual(model.button.theme.surface_hovered, model.paint.background.solid);

        try harness.post(window, .{ .input = .{ .pointer_move = .{ .position = .{ .x = 300, .y = 200 } } } });
        while (try app.step(false)) {}
        try testing.expect(!model.button.hovered and !model.button.focusVisible());
        try testing.expectEqual(model.button.theme.surface, model.paint.background.solid);
        try testing.expectEqual(model.button.theme.border, model.paint.border.color);

        try harness.post(window, .{ .input = .{ .key_down = .{ .key = .enter, .physical_code = 0 } } });
        while (try app.step(false)) {}
        try testing.expectEqual(click * 2 + 2, model.activations);
        try testing.expect(model.button.focusVisible());
        try testing.expectEqual(model.button.theme.focus_ring, model.paint.border.color);
    }

    try harness.post(window, .{ .input = .{ .key_down = .{ .key = .tab, .physical_code = 0 } } });
    while (try app.step(false)) {}
    try testing.expect(!model.button.focused and model.other.focusVisible());
    try harness.post(window, .{ .input = .{ .key_down = .{ .key = .tab, .physical_code = 0, .modifiers = .{ .shift = true } } } });
    while (try app.step(false)) {}
    try testing.expect(model.button.focusVisible() and !model.other.focused);
    try testing.expectEqual(model.button.theme.focus_ring, model.paint.border.color);
}

test "disabled standard controls expose no invokable accessibility actions" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var context: ui.Component.BuildContext = undefined;
    context.allocator = scratch.allocator();
    var callback_probe: usize = 0;
    const callback: ui.widgets.Callback = .{ .context = &callback_probe, .callback = noopWidgetCallback };

    const product_fonts: []const []const u8 = &.{ "Inter", "Avenir", "system-ui" };
    const product_theme: ui.widgets.Theme = .{ .font_families = product_fonts };
    var button: ui.widgets.Button = .{ .label = "button", .on_activate = callback, .theme = &product_theme };
    const enabled_button_spec = try button.build(&context);
    try testing.expect(enabled_button_spec.style.interaction.focusable);
    try testing.expect(!enabled_button_spec.style.interaction.disabled);
    try testing.expectEqual(@as(usize, 1), enabled_button_spec.semantics.actions.len);
    try testing.expectEqual(ui.accessibility.Action.activate, enabled_button_spec.semantics.actions[0]);
    try testing.expectEqualSlices([]const u8, product_fonts, enabled_button_spec.children[0].style.text.font_families);

    button.focused = true;
    const focused_button_spec = try button.build(&context);
    try testing.expectEqual(button.theme.focus_ring, focused_button_spec.style.paint.border.color);
    try testing.expectEqual(button.theme.focus_ring_width, focused_button_spec.style.paint.border.widths.top);

    button.disabled = true;
    const button_spec = try button.build(&context);
    try testing.expect(!button_spec.style.interaction.focusable);
    try testing.expect(button_spec.style.interaction.disabled);
    try testing.expect(button_spec.semantics.disabled);
    try testing.expectEqual(@as(usize, 0), button_spec.semantics.actions.len);
    try testing.expectEqual(ui.text.WrapMode.none, button_spec.children[0].style.text.wrap);
    try testing.expectEqual(@as(?u32, 1), button_spec.children[0].style.text.maximum_lines);

    var checked = false;
    var toggle: ui.widgets.Toggle = .{ .label = "toggle", .value = &checked, .disabled = true };
    try testing.expectEqual(@as(usize, 0), (try toggle.build(&context)).semantics.actions.len);

    var selected: usize = 0;
    var radio: ui.widgets.Radio = .{ .label = "radio", .selected_index = &selected, .index = 0, .disabled = true };
    try testing.expectEqual(@as(usize, 0), (try radio.build(&context)).semantics.actions.len);

    const labels = [_][]const u8{ "one", "two" };
    const disabled_tabs = [_]bool{ true, true };
    var tabs = try ui.widgets.Tabs.init(testing.allocator, &labels, &selected);
    defer tabs.deinit();
    tabs.disabled = &disabled_tabs;
    const tabs_spec = try tabs.build(&context);
    for (tabs_spec.children[0].children) |tab| try testing.expectEqual(@as(usize, 0), tab.semantics.actions.len);

    var select = try ui.widgets.Select.init(testing.allocator, &labels, &selected);
    defer select.deinit();
    select.disabled = true;
    try testing.expectEqual(@as(usize, 0), (try select.build(&context)).semantics.actions.len);

    var slider_value: f64 = 0.5;
    var slider: ui.widgets.Slider = .{ .value = &slider_value, .disabled = true };
    try testing.expectEqual(@as(usize, 0), (try slider.build(&context)).semantics.actions.len);

    var field = try ui.widgets.TextField.init(testing.allocator, "text");
    defer field.deinit();
    field.disabled = true;
    try testing.expectEqual(@as(usize, 0), (try field.build(&context)).semantics.actions.len);
    field.disabled = false;
    field.password = true;
    field.selection = .{ .start = 1, .end = 4 };
    const password_spec = try field.build(&context);
    try testing.expect(password_spec.semantics.selection == null);
    try testing.expectEqualStrings("", password_spec.semantics.value);
}

test "editable text fields advertise activation for native accessibility press" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var context: ui.Component.BuildContext = undefined;
    context.allocator = scratch.allocator();

    var field = try ui.widgets.TextField.init(testing.allocator, "text");
    defer field.deinit();

    const editable = try field.build(&context);
    try testing.expectEqual(@as(usize, 4), editable.semantics.actions.len);
    try testing.expectEqual(ui.accessibility.Action.focus, editable.semantics.actions[0]);
    try testing.expectEqual(ui.accessibility.Action.activate, editable.semantics.actions[1]);
    try testing.expectEqual(ui.accessibility.Action.set_selection, editable.semantics.actions[2]);
    try testing.expectEqual(ui.accessibility.Action.set_value, editable.semantics.actions[3]);

    field.read_only = true;
    const read_only = try field.build(&context);
    try testing.expectEqual(@as(usize, 3), read_only.semantics.actions.len);
    try testing.expectEqual(ui.accessibility.Action.focus, read_only.semantics.actions[0]);
    try testing.expectEqual(ui.accessibility.Action.activate, read_only.semantics.actions[1]);
    try testing.expectEqual(ui.accessibility.Action.set_selection, read_only.semantics.actions[2]);
}

test "text field keeps the caret visible and marks active IME text" {
    var field = try ui.widgets.TextField.init(testing.allocator, "abcdefghijklmnopqrstuvwxyz");
    defer field.deinit();
    field.focused = true;

    var probe: TextGeometryProbe = .{};
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const scale = try ui.ScaleFactor.init(2);
    var measure_context: ui.custom.MeasureContext = .{
        .allocator = scratch.allocator(),
        .scale_factor = scale,
        .text = probe.services(),
    };
    _ = try field.measure(&measure_context, .{ .maximum = .{ .width = 62, .height = 28 } });
    var paint_context: ui.custom.PaintContext = .{
        .scene_context = &probe,
        .emit_fn = TextGeometryProbe.emit,
        .scratch = scratch.allocator(),
        .scale_factor = scale,
        .text = probe.services(),
    };
    try field.paint(&paint_context, ui.Rect.fromXYWH(0, 0, 80, 40));
    try testing.expect(field.scroll_offset.x > 0);

    field.selection = .{ .start = 5, .end = 5 };
    try field.marked_text.appendSlice(testing.allocator, "世");
    field.marked_selection = .{ .start = 3, .end = 3 };
    field.composition_active = true;
    field.reveal_caret = true;
    try field.paint(&paint_context, ui.Rect.fromXYWH(0, 0, 80, 40));
    try testing.expect(probe.underlines != 0);
}

test "accessibility tree validation rejects duplicate identities and malformed values" {
    const window = handles.WindowId.init(1, 1);
    const root_id = handles.SemanticId.init(1, 1);
    const child_id = handles.SemanticId.init(2, 1);
    const children = [_]handles.SemanticId{child_id};
    const valid_nodes = [_]ui.accessibility.Node{
        .{ .id = root_id, .role = .window, .children = &children },
        .{ .id = child_id, .parent = root_id, .role = .button, .label = "valid" },
    };
    const valid: ui.accessibility.Tree = .{ .window = window, .root = root_id, .nodes = &valid_nodes, .generation = 1 };
    try ui.accessibility.validateTree(testing.allocator, &valid, .{ .maximum_nodes = 4, .maximum_bytes = 4096 });

    const duplicate_nodes = [_]ui.accessibility.Node{
        .{ .id = root_id, .role = .window, .children = &children },
        .{ .id = root_id, .parent = root_id, .role = .button },
    };
    const duplicate: ui.accessibility.Tree = .{ .window = window, .root = root_id, .nodes = &duplicate_nodes, .generation = 1 };
    try testing.expectError(error.InvalidLayout, ui.accessibility.validateTree(testing.allocator, &duplicate, .{ .maximum_nodes = 4, .maximum_bytes = 4096 }));

    const invalid_text = [_]u8{0xff};
    const malformed_nodes = [_]ui.accessibility.Node{.{ .id = root_id, .role = .window, .label = &invalid_text }};
    const malformed: ui.accessibility.Tree = .{ .window = window, .root = root_id, .nodes = &malformed_nodes, .generation = 1 };
    try testing.expectError(error.InvalidUtf8, ui.accessibility.validateTree(testing.allocator, &malformed, .{ .maximum_nodes = 4, .maximum_bytes = 4096 }));
}

test "App task contexts have one terminal owner across rejection completion and shutdown" {
    var owner: TaskOwnerProbe = .{};
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "task ownership test",
        .allow_multiple_apps_for_testing = true,
    });
    _ = try app.openWindow(.{ .platform = .{ .title = "tasks" } }, ui.Component.Descriptor.from(TaskOwnerProbe, &owner));
    while (try app.step(false)) {}
    try testing.expect(owner.component.isValid());

    var counts: TaskContextCounts = .{};
    const missing = try TaskContext.create(&counts);
    try testing.expectError(error.MissingCapability, app.spawnTask(owner.component, missing, TaskContext.run, TaskContext.apply, TaskContext.drop));
    try testing.expectEqual(@as(usize, 1), counts.drops);

    var host_probe: TaskHostProbe = .{};
    try app.installTaskHost(host_probe.host());
    host_probe.mode = .reject;
    const rejected = try TaskContext.create(&counts);
    try testing.expectError(error.QueueFull, app.spawnTask(owner.component, rejected, TaskContext.run, TaskContext.apply, TaskContext.drop));
    try testing.expectEqual(@as(usize, 2), counts.drops);

    host_probe.mode = .complete;
    const completed = try TaskContext.create(&counts);
    _ = try app.spawnTask(owner.component, completed, TaskContext.run, TaskContext.apply, TaskContext.drop);
    try testing.expectEqual(@as(usize, 1), try app.drainTaskCompletions());
    try testing.expectEqual(@as(usize, 1), counts.runs);
    try testing.expectEqual(@as(usize, 1), counts.applies);
    try testing.expectEqual(@as(usize, 3), counts.drops);

    host_probe.mode = .hold;
    const held = try TaskContext.create(&counts);
    _ = try app.spawnTask(owner.component, held, TaskContext.run, TaskContext.apply, TaskContext.drop);
    try app.destroy();
    try testing.expectEqual(@as(usize, 4), counts.drops);
    try testing.expectEqual(@as(usize, 1), host_probe.shutdowns);
}

test "scroll view reconciles stale model offsets during frame stabilization" {
    var model = ScrollSyncProbe.init();
    const app = try ui.App.create(testing.allocator, .{
        .application_name = "scroll synchronization test",
        .allow_multiple_apps_for_testing = true,
    });
    defer app.destroy() catch unreachable;
    _ = try app.openWindow(.{ .platform = .{
        .title = "scroll",
        .size = .{ .width = 200, .height = 120 },
    } }, ui.Component.Descriptor.from(ScrollSyncProbe, &model));
    while (try app.step(false)) {}
    try testing.expectEqual(@as(f32, 0), model.scroll.offset_y);
    try testing.expectEqual(@as(u64, 1), (try app.metricsSnapshot()).frames_submitted);
}

test "programmatic focus includes negative tab index without adding it to traversal" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const children = [_]ui.NodeSpec{
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = -1 } } }).withKey(1),
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = 0 } } }).withKey(2),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &children }, 1, scratch.allocator());
    const retained = store.getConst(root).?.children.items;

    var manager = ui.focus.Manager.init(testing.allocator);
    defer manager.deinit();
    try manager.rebuild(&store, root);
    try testing.expect(manager.request(&store, retained[0]));
    try manager.rebuild(&store, root);
    try testing.expect(manager.focused.eql(retained[0]));
    try testing.expect(manager.move(&store, .forward).?.eql(retained[1]));
    try testing.expect(manager.move(&store, .backward).?.eql(retained[1]));
}

test "roving focus transfers to the newly committed autofocus identity" {
    var store = ui.NodeStore.init(testing.allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const initial = [_]ui.NodeSpec{
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = 0, .autofocus = true } } }).withKey(1),
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = -1 } } }).withKey(2),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &initial }, 1, scratch.allocator());
    const first = store.getConst(root).?.children.items[0];
    const second = store.getConst(root).?.children.items[1];
    var manager = ui.focus.Manager.init(testing.allocator);
    defer manager.deinit();
    try manager.rebuild(&store, root);
    try testing.expect(manager.focused.eql(first));

    manager.requestAutofocusAfterReconcile();
    const replacement = [_]ui.NodeSpec{
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = -1 } } }).withKey(1),
        (ui.NodeSpec{ .style = .{ .interaction = .{ .focusable = true, .tab_index = 0, .autofocus = true } } }).withKey(2),
    };
    _ = try store.reconcile(root, .invalid, .invalid, .{ .children = &replacement }, 1, scratch.allocator());
    try manager.rebuild(&store, root);
    try testing.expect(manager.focused.eql(second));
}

test "tabs request atomic roving focus when keyboard selection changes" {
    var coordinator = ui.runtime.Coordinator.init(testing.allocator);
    try coordinator.bind();
    defer coordinator.deinit() catch unreachable;
    const component_id = handles.ComponentId.init(1, 1);
    const window_id = handles.WindowId.init(1, 1);
    const node_id = handles.NodeId.init(1, 1);
    try coordinator.invalidations.register(component_id, window_id);
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var build_context: ui.Component.BuildContext = undefined;
    build_context.allocator = scratch.allocator();
    const labels = [_][]const u8{ "one", "two", "three" };
    var selected: usize = 0;
    var tabs = try ui.widgets.Tabs.init(testing.allocator, &labels, &selected);
    defer tabs.deinit();
    const spec = try tabs.build(&build_context);
    const first_tab = spec.children[0].children[0];
    var dispatch: ui.input.Dispatch = .{
        .window = window_id,
        .target = node_id,
        .current = node_id,
        .phase = .target,
    };
    var event_context: ui.input.Context = .{
        .coordinator = &coordinator,
        .component = component_id,
        .window = window_id,
    };
    const key: ui.input.Event = .{ .key_down = .{ .key = .arrow_right, .physical_code = 0 } };
    try first_tab.handlers[0].callback(first_tab.handlers[0].context, &dispatch, &key, &event_context);
    try testing.expectEqual(@as(usize, 1), selected);
    try testing.expect(dispatch.requested_autofocus_after_reconcile);
    try testing.expect(dispatch.requested_focus == null);
}

test "split pane clamps its ratio from committed geometry" {
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    var context: ui.Component.BuildContext = undefined;
    context.allocator = scratch.allocator();
    var fraction: f32 = 0;
    var pane: ui.widgets.SplitPane = .{
        .first = .{},
        .second = .{},
        .fraction = &fraction,
        .minimum_first = 100,
        .minimum_second = 50,
        .divider_size = 10,
    };
    var arrange_context: ui.custom.ArrangeContext = .{
        .allocator = scratch.allocator(),
        .scale_factor = try ui.ScaleFactor.init(1),
    };
    try pane.arrange(&arrange_context, ui.Rect.fromXYWH(0, 0, 300, 100));
    const spacious = try pane.build(&context);
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 290.0), spacious.children[0].style.layout.flex_grow, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 190.0 / 290.0), spacious.children[2].style.layout.flex_grow, 0.0001);

    try pane.arrange(&arrange_context, ui.Rect.fromXYWH(0, 0, 120, 100));
    const constrained = try pane.build(&context);
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), constrained.children[0].style.layout.flex_grow, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), constrained.children[2].style.layout.flex_grow, 0.0001);

    pane.minimum_first = 3.0e38;
    pane.minimum_second = 3.0e38;
    try testing.expectError(error.InvalidConfiguration, pane.build(&context));
}

test "text backend wrappers reject malformed provider output and free it" {
    var probe: MalformedTextBackend = .{};
    const backend = probe.backend();
    const font = handles.FontId.init(1, 1);
    try testing.expectError(error.PlatformFailure, backend.resolveFont(.{ .families = &.{"Test"} }));
    try testing.expectError(error.PlatformFailure, backend.metrics(font, 14));
    try testing.expectError(error.PlatformFailure, backend.shape(.{ .text = "abc", .font = font, .size = 14 }, testing.allocator));
    try testing.expectError(error.PlatformFailure, backend.rasterize(.{
        .font = font,
        .glyph_id = 1,
        .size = 14,
        .scale_factor = 1,
    }, testing.allocator));
    backend.deinit();
    try testing.expectEqual(@as(usize, 1), probe.deinits);
}

test "custom text selection providers cannot overwrite caller rectangles" {
    var context: u8 = 0;
    const services: ui.custom.TextServices = .{
        .context = &context,
        .measure_fn = TextGeometryProbe.measure,
        .selection_rects_fn = mutatingSelectionRects,
    };
    var output: std.ArrayList(ui.Rect) = .empty;
    defer output.deinit(testing.allocator);
    try output.append(testing.allocator, ui.Rect.fromXYWH(99, 99, 1, 1));
    try services.selectionRects("ab", .{}, 100, 0, 1, &output, testing.allocator);
    try testing.expectEqual(@as(usize, 2), output.items.len);
    try testing.expectApproxEqAbs(@as(f32, 99), output.items[0].origin.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), output.items[1].origin.x, 0.001);
}

test "media source validation releases rejected frames and Y4M obeys decoded budget" {
    var probe: MalformedMediaSource = .{};
    const source = probe.source();
    try testing.expectError(error.InvalidMedia, source.poll(0));
    try testing.expectEqual(@as(usize, 1), probe.releases);
    source.deinit();
    try testing.expectEqual(@as(usize, 1), probe.deinits);

    const encoded = "YUV4MPEG2 W100 H100 F30:1 Ip C420\nFRAME\n";
    try testing.expectError(error.BudgetExceeded, ui.media.Y4mSource.create(
        testing.allocator,
        encoded,
        4,
        encoded.len,
        100,
    ));

    var build_context: ui.Component.BuildContext = undefined;
    var invalid_view: ui.media.View = .{
        .visual = .{ .texture = .{ .id = .invalid, .width = 1, .height = 1, .format = .rgba8 } },
    };
    try testing.expectError(error.InvalidHandle, invalid_view.build(&build_context));
}

test "SVG path arithmetic cannot retain non-finite geometry" {
    const source =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
        \\  <path d="M 3e38 0 l 3e38 0"/>
        \\</svg>
    ;
    try testing.expectError(error.InvalidSvg, ui.svg.Document.parse(testing.allocator, source, .{}));
}

test "SVG dashed strokes reject non-finite length before subdivision" {
    const source =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1" viewBox="0 0 1 1">
        \\  <path d="M 0 0 L 1e20 0" fill="none" stroke="black" stroke-dasharray="1 1"/>
        \\</svg>
    ;
    var document = try ui.svg.Document.parse(testing.allocator, source, .{ .maximum_dash_subdivisions = 1_024 });
    defer document.deinit();
    var rendered = ui.scene.Scene.init(testing.allocator);
    defer rendered.deinit();
    var builder = ui.scene.Builder.init(&rendered, .{});
    defer builder.deinit();
    try testing.expectError(error.BudgetExceeded, document.paint(
        &builder,
        ui.Rect.fromXYWH(0, 0, 1, 1),
        .none,
    ));
}

test "SVG near-zero dash cycles consume the subdivision budget" {
    const source =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">
        \\  <path d="M 0 0 L 1 0" fill="none" stroke="black" stroke-dasharray="0.000001 0.000001"/>
        \\</svg>
    ;
    var document = try ui.svg.Document.parse(testing.allocator, source, .{ .maximum_dash_subdivisions = 32 });
    defer document.deinit();
    var rendered = ui.scene.Scene.init(testing.allocator);
    defer rendered.deinit();
    var builder = ui.scene.Builder.init(&rendered, .{});
    defer builder.deinit();
    try testing.expectError(error.BudgetExceeded, document.paint(
        &builder,
        ui.Rect.fromXYWH(0, 0, 1, 1),
        .none,
    ));
}

test "accessibility validation enforces its iterative depth limit" {
    const window = handles.WindowId.init(1, 1);
    const root = handles.SemanticId.init(1, 1);
    const middle = handles.SemanticId.init(2, 1);
    const leaf = handles.SemanticId.init(3, 1);
    const root_children = [_]handles.SemanticId{middle};
    const middle_children = [_]handles.SemanticId{leaf};
    const nodes = [_]ui.accessibility.Node{
        .{ .id = root, .role = .window, .children = &root_children },
        .{ .id = middle, .parent = root, .role = .group, .children = &middle_children },
        .{ .id = leaf, .parent = middle, .role = .button },
    };
    const tree: ui.accessibility.Tree = .{ .window = window, .root = root, .nodes = &nodes, .generation = 1 };
    try testing.expectError(error.BudgetExceeded, ui.accessibility.validateTree(testing.allocator, &tree, .{
        .maximum_nodes = nodes.len,
        .maximum_bytes = 4096,
        .maximum_depth = 2,
    }));
}

test "render extension registry owns labels and bounds retired entries" {
    var probe: RenderExtensionProbe = .{};
    var registry = ui.render_extension.Registry.initWithLimit(testing.allocator, 1);
    defer registry.deinit();
    const label = try testing.allocator.dupe(u8, "mutable");
    const first = try registry.register(probe.descriptor(label));
    @memset(label, 'x');
    testing.allocator.free(label);
    try registry.destroy(first, 10);
    try testing.expectError(error.BudgetExceeded, registry.register(probe.descriptor("second")));
    registry.collect(9);
    try testing.expectEqual(@as(usize, 0), probe.deinits);
    registry.collect(10);
    try testing.expectEqual(@as(usize, 1), probe.deinits);
    _ = try registry.register(probe.descriptor("second"));
}

test "render extension callbacks cannot mutate their borrowed registry" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var probe: ReentrantRenderExtensionProbe = .{ .renderer = renderer };
    probe.id = try renderer.registerExtension(probe.descriptor());

    var rendered = ui.scene.Scene.init(testing.allocator);
    defer rendered.deinit();
    var builder = ui.scene.Builder.init(&rendered, .{});
    defer builder.deinit();
    try builder.customPass(probe.id, ui.Rect.fromXYWH(0, 0, 1, 1), &.{}, 0);
    try builder.finish();
    var readback = (try renderer.renderOffscreen(.{
        .width = 1,
        .height = 1,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, rendered.view(), testing.allocator)).?;
    defer readback.deinit(testing.allocator);
    try testing.expectEqual(error.CallbackReentrancy, probe.destroy_error.?);
    try testing.expectEqual(error.CallbackReentrancy, probe.register_error.?);
}

test "render extension deinit cannot mutate its registry" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    var probe: ReentrantRenderExtensionProbe = .{ .renderer = renderer };
    probe.id = try renderer.registerExtension(probe.descriptor());
    renderer.deinit();
    try testing.expectEqual(error.CallbackReentrancy, probe.deinit_destroy_error.?);
    try testing.expectEqual(error.CallbackReentrancy, probe.deinit_register_error.?);
}

test "collect removes a retired extension before its deinit callback reenters" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var probe: ReentrantRenderExtensionProbe = .{ .renderer = renderer };
    probe.id = try renderer.registerExtension(probe.descriptor());
    try renderer.destroyExtension(probe.id, 0);

    var replacement: RenderExtensionProbe = .{};
    _ = try renderer.registerExtension(replacement.descriptor("replacement"));
    try testing.expectEqual(error.CallbackReentrancy, probe.deinit_destroy_error.?);
    try testing.expectEqual(error.CallbackReentrancy, probe.deinit_register_error.?);
}

test "render extension device-lost callback cannot recover recursively" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var probe: ReentrantRenderExtensionProbe = .{ .renderer = renderer };
    _ = try renderer.registerExtension(probe.descriptor());
    try renderer.recover(.{});
    try testing.expectEqual(error.CallbackReentrancy, probe.device_lost_recover_error.?);
}

test "render extension deinit cannot recursively destroy App" {
    const app = try ui.App.create(testing.allocator, .{ .allow_multiple_apps_for_testing = true });
    var probe: ReentrantRenderExtensionProbe = .{ .app = app };
    _ = try app.registerRenderExtension(probe.descriptor());
    try app.destroy();
    try testing.expectEqual(error.AppClosed, probe.deinit_app_destroy_error.?);
}

test "renderer rejects backdrop scenes when the backend does not advertise support" {
    var context: u8 = 0;
    const renderer = UnsupportedBackdropRenderer.renderer(&context);

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.backdropEffect(.{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .radii = .{},
        .blur_radius = 0,
        .saturation = 1,
    });
    try builder.finish();
    try testing.expect(scene.view().requiresBackdropEffects());

    try testing.expectError(error.Unsupported, renderer.renderOffscreen(.{
        .width = 4,
        .height = 4,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator));
    try testing.expectError(error.Unsupported, renderer.submit(.{ .value = 1, .device_generation = 1 }, scene.view()));
    renderer.deinit();
}

test "render extension depth requirements are validated and retained" {
    var probe: RenderExtensionProbe = .{};
    var registry = ui.render_extension.Registry.initWithLimit(testing.allocator, 2);
    defer registry.deinit();

    var descriptor = probe.descriptor("depth-aware extension");
    descriptor.requirements.depth = .{ .clear_depth = 0.75 };
    const id = try registry.register(descriptor);
    const requirements = try registry.requirements(id);
    try testing.expect(requirements.depth != null);
    try testing.expectEqual(ui.render_extension.DepthFormat.depth32_float, requirements.depth.?.format);
    try testing.expectEqual(@as(f32, 0.75), requirements.depth.?.clear_depth);

    var invalid = probe.descriptor("invalid depth clear");
    invalid.requirements.depth = .{ .clear_depth = std.math.nan(f32) };
    try testing.expectError(error.InvalidConfiguration, registry.register(invalid));
    invalid.requirements.depth = .{ .clear_depth = -0.01 };
    try testing.expectError(error.InvalidConfiguration, registry.register(invalid));
    invalid.requirements.depth = .{ .clear_depth = 1.01 };
    try testing.expectError(error.InvalidConfiguration, registry.register(invalid));
}

test "null renderer rejects native depth extension requirements" {
    var probe: RenderExtensionProbe = .{};
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var descriptor = probe.descriptor("depth requires a native backend");
    descriptor.requirements.depth = .{};
    try testing.expectError(error.Unsupported, renderer.registerExtension(descriptor));
}

test "null renderer executes custom passes with payload flags and device recovery" {
    var probe: RenderExtensionProbe = .{};
    const renderer = try ui.NullRenderer.create(testing.allocator);
    var renderer_owned = true;
    defer if (renderer_owned) renderer.deinit();
    const extension = try renderer.registerExtension(probe.descriptor("integrated custom pass"));

    var scene = ui.scene.Scene.init(testing.allocator);
    defer scene.deinit();
    var builder = ui.scene.Builder.init(&scene, .{});
    defer builder.deinit();
    try builder.customPass(extension, ui.Rect.fromXYWH(2, 3, 7, 5), "pass-payload", 0xa55a_1734);
    try builder.finish();

    var first = (try renderer.renderOffscreen(.{
        .width = 16,
        .height = 12,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    first.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), probe.prepares);
    try testing.expectEqual(@as(usize, 1), probe.encodes);
    try testing.expectEqual(ui.render_extension.Backend.null, probe.last_device);
    try testing.expectEqual(ui.render_extension.Backend.null, probe.last_pass);
    try testing.expectEqual(@as(usize, "pass-payload".len), probe.payload_length);
    try testing.expectEqual(@as(u8, 'p'), probe.payload_first);
    try testing.expectEqual(@as(u32, 0xa55a_1734), probe.flags);
    try testing.expectEqual(ui.Rect.fromXYWH(2, 3, 7, 5), probe.geometry.bounds);

    try renderer.recover(.{});
    try testing.expectEqual(@as(usize, 1), probe.device_losses);
    var second = (try renderer.renderOffscreen(.{
        .width = 16,
        .height = 12,
        .scale_factor = try ui.ScaleFactor.init(1),
        .format = .rgba8,
    }, scene.view(), testing.allocator)).?;
    second.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), probe.prepares);
    try testing.expectEqual(@as(usize, 2), probe.encodes);

    renderer.deinit();
    renderer_owned = false;
    try testing.expectEqual(@as(usize, 1), probe.deinits);
}

fn pixel(readback: ui.render.Readback, x: usize, y: usize) []const u8 {
    const offset = y * readback.stride + x * 4;
    return readback.pixels[offset..][0..4];
}

const LayoutFeedbackProbe = struct {
    arrange_count: usize = 0,
    stop_after: usize,

    pub fn build(self: *LayoutFeedbackProbe, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        return .{ .kind = .{ .custom = ui.custom.Node.from(LayoutFeedbackProbe, self) } };
    }

    pub fn arrange(self: *LayoutFeedbackProbe, context: *ui.custom.ArrangeContext, _: ui.Rect) ui.Error!void {
        self.arrange_count += 1;
        if (self.arrange_count < self.stop_after) _ = context.requestRecompose();
    }

    pub fn paint(_: *LayoutFeedbackProbe, _: *ui.custom.PaintContext, _: ui.Rect) ui.Error!void {}
};

const TaskOwnerProbe = struct {
    component: handles.ComponentId = .invalid,

    pub fn build(self: *TaskOwnerProbe, context: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.component = context.component;
        return .{};
    }
};

const TaskContextCounts = struct {
    runs: usize = 0,
    applies: usize = 0,
    drops: usize = 0,
};

const TaskContext = struct {
    counts: *TaskContextCounts,

    fn create(counts: *TaskContextCounts) !*TaskContext {
        const self = try testing.allocator.create(TaskContext);
        self.* = .{ .counts = counts };
        return self;
    }

    fn run(context: *anyopaque, _: *ui.runtime_task.CancellationToken) void {
        const self: *TaskContext = @ptrCast(@alignCast(context));
        self.counts.runs += 1;
    }

    fn apply(context: *anyopaque) void {
        const self: *TaskContext = @ptrCast(@alignCast(context));
        self.counts.applies += 1;
    }

    fn drop(context: *anyopaque) void {
        const self: *TaskContext = @ptrCast(@alignCast(context));
        self.counts.drops += 1;
        testing.allocator.destroy(self);
    }
};

const TaskHostProbe = struct {
    const Mode = enum { reject, complete, hold };

    mode: Mode = .reject,
    sink: ?ui.runtime_task.CompletionSink = null,
    held: ?ui.runtime_task.Work = null,
    shutdowns: usize = 0,

    fn host(self: *TaskHostProbe) ui.runtime_task.Host {
        return .{
            .context = self,
            .start_fn = start,
            .spawn_fn = spawn,
            .shutdown_fn = shutdown,
        };
    }

    fn start(context: *anyopaque, sink: ui.runtime_task.CompletionSink) ui.Error!void {
        const self: *TaskHostProbe = @ptrCast(@alignCast(context));
        self.sink = sink;
    }

    fn spawn(context: *anyopaque, work: ui.runtime_task.Work) ui.Error!void {
        const self: *TaskHostProbe = @ptrCast(@alignCast(context));
        switch (self.mode) {
            .reject => return error.QueueFull,
            .complete => work.run(self.sink.?),
            .hold => {
                if (self.held != null) return error.QueueFull;
                self.held = work;
            },
        }
    }

    fn shutdown(context: *anyopaque) void {
        const self: *TaskHostProbe = @ptrCast(@alignCast(context));
        if (self.held) |work| work.drop();
        self.held = null;
        self.sink = null;
        self.shutdowns += 1;
    }
};

const ScrollSyncProbe = struct {
    scroll: ui.widgets.ScrollView,

    fn init() ScrollSyncProbe {
        return .{ .scroll = .{
            .offset_y = 500,
            .content = .{},
            .style = .{ .layout = .{
                .width = .{ .percent = 1 },
                .height = .{ .percent = 1 },
            } },
        } };
    }

    pub fn build(self: *ScrollSyncProbe, context: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        self.scroll.content = .{
            .kind = .spacer,
            .style = .{ .layout = .{
                .width = .{ .percent = 1 },
                .height = .{ .points = 20 },
            } },
        };
        return self.scroll.build(context);
    }
};

const MalformedTextBackend = struct {
    deinits: usize = 0,

    fn backend(self: *MalformedTextBackend) ui.text.Backend {
        return .{
            .context = self,
            .resolve_font_fn = resolveFont,
            .metrics_fn = metrics,
            .shape_fn = shape,
            .color_glyph_fn = colorGlyph,
            .rasterize_fn = rasterize,
            .deinit_fn = deinit,
        };
    }

    fn resolveFont(_: *anyopaque, _: ui.text.FontDescriptor) ui.Error!handles.FontId {
        return .invalid;
    }

    fn metrics(_: *anyopaque, _: handles.FontId, _: f32) ui.Error!ui.text.FontMetrics {
        return .{
            .ascent = @bitCast(@as(u32, 0x7fc00000)),
            .descent = 0,
            .leading = 0,
            .x_height = 0,
            .cap_height = 0,
            .underline_position = 0,
            .underline_thickness = 1,
        };
    }

    fn shape(_: *anyopaque, request: ui.text.ShapeRequest, allocator: std.mem.Allocator) ui.Error!ui.text.ShapedRun {
        const glyphs = try allocator.alloc(ui.text.Glyph, 1);
        errdefer allocator.free(glyphs);
        const fonts = try allocator.alloc(handles.FontId, 1);
        fonts[0] = request.font;
        glyphs[0] = .{
            .glyph_id = 1,
            .cluster_utf8 = 0,
            .advance_x = 1,
            .advance_y = 0,
            .offset_x = 0,
            .offset_y = 0,
            .font_index = 0,
        };
        return .{
            .text_utf8 = request.text,
            .glyphs = glyphs,
            .fonts = fonts,
            .direction = if (request.direction == .auto) .left_to_right else request.direction,
            .width = @bitCast(@as(u32, 0x7fc00000)),
            .metrics = .{
                .ascent = 10,
                .descent = 2,
                .leading = 0,
                .x_height = 5,
                .cap_height = 7,
                .underline_position = 1,
                .underline_thickness = 1,
            },
        };
    }

    fn colorGlyph(_: *anyopaque, _: handles.FontId, _: u32) ui.text.ColorGlyphKind {
        return .none;
    }

    fn rasterize(_: *anyopaque, _: ui.text.RasterRequest, allocator: std.mem.Allocator) ui.Error!ui.text.RasterizedGlyph {
        const pixels = try allocator.alloc(u8, 4);
        @memset(pixels, 0);
        return .{
            .size = .{ .width = 2, .height = 2 },
            .origin = .{},
            .stride = 1,
            .pixels = pixels,
            .mode = .grayscale,
        };
    }

    fn deinit(context: *anyopaque) void {
        const self: *MalformedTextBackend = @ptrCast(@alignCast(context));
        self.deinits += 1;
    }
};

const MalformedMediaSource = struct {
    pixels: [4]u8 = @splat(0),
    releases: usize = 0,
    deinits: usize = 0,

    fn source(self: *MalformedMediaSource) ui.media.api.Source {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: ui.media.api.Source.VTable = .{
        .info = info,
        .poll = poll,
        .seek = seek,
        .deinit = deinit,
    };

    fn cast(context: *anyopaque) *MalformedMediaSource {
        return @ptrCast(@alignCast(context));
    }

    fn info(_: *anyopaque) ui.media.api.Info {
        return .{ .width = 2, .height = 2 };
    }

    fn poll(context: *anyopaque, _: ui.media.api.Timestamp) ui.Error!ui.media.api.Poll {
        const self = cast(context);
        return .{ .frame = .{
            .presentation_time_ns = 0,
            .duration_ns = 1,
            .content = .{ .cpu = .{
                .width = 2,
                .height = 2,
                .stride = 1,
                .format = .rgba8,
                .pixels = &self.pixels,
            } },
            .release_context = self,
            .release_fn = release,
        } };
    }

    fn seek(_: *anyopaque, _: ui.media.api.Timestamp) ui.Error!void {}

    fn release(context: *anyopaque) void {
        cast(context).releases += 1;
    }

    fn deinit(context: *anyopaque) void {
        cast(context).deinits += 1;
    }
};

const RenderExtensionProbe = struct {
    deinits: usize = 0,
    prepares: usize = 0,
    encodes: usize = 0,
    device_losses: usize = 0,
    last_device: ui.render_extension.Backend = .null,
    last_pass: ui.render_extension.Backend = .null,
    payload_length: usize = 0,
    payload_first: u8 = 0,
    flags: u32 = 0,
    geometry: ui.render_extension.Geometry = undefined,

    fn descriptor(self: *RenderExtensionProbe, label: []const u8) ui.render_extension.Descriptor {
        return .{ .context = self, .vtable = &vtable, .label = label };
    }

    const vtable: ui.render_extension.Descriptor.VTable = .{
        .prepare = prepare,
        .encode = encode,
        .device_lost = deviceLost,
        .deinit = deinit,
    };

    fn prepare(context: *anyopaque, device: ui.render_extension.Device, _: ui.render_extension.DeviceGeneration) ui.Error!void {
        const self: *RenderExtensionProbe = @ptrCast(@alignCast(context));
        self.prepares += 1;
        self.last_device = std.meta.activeTag(device);
    }
    fn encode(context: *anyopaque, pass: ui.render_extension.Pass, payload: []const u8, flags: u32) ui.Error!void {
        const self: *RenderExtensionProbe = @ptrCast(@alignCast(context));
        self.encodes += 1;
        self.last_pass = std.meta.activeTag(pass);
        self.payload_length = payload.len;
        self.payload_first = if (payload.len == 0) 0 else payload[0];
        self.flags = flags;
        self.geometry = pass.geometry().*;
    }
    fn deviceLost(context: *anyopaque, _: ui.render_extension.DeviceGeneration) void {
        const self: *RenderExtensionProbe = @ptrCast(@alignCast(context));
        self.device_losses += 1;
    }
    fn deinit(context: *anyopaque) void {
        const self: *RenderExtensionProbe = @ptrCast(@alignCast(context));
        self.deinits += 1;
    }
};

const ReentrantRenderExtensionProbe = struct {
    renderer: ui.render.Renderer = undefined,
    app: ?*ui.App = null,
    id: handles.RenderExtensionId = .invalid,
    destroy_error: ?ui.Error = null,
    register_error: ?ui.Error = null,
    deinit_destroy_error: ?ui.Error = null,
    deinit_register_error: ?ui.Error = null,
    deinit_app_destroy_error: ?ui.Error = null,
    device_lost_recover_error: ?ui.Error = null,

    fn descriptor(self: *ReentrantRenderExtensionProbe) ui.render_extension.Descriptor {
        return .{ .context = self, .vtable = &vtable, .label = "reentrant extension" };
    }

    const vtable: ui.render_extension.Descriptor.VTable = .{
        .prepare = prepare,
        .encode = encode,
        .device_lost = deviceLost,
        .deinit = deinit,
    };

    fn prepare(raw: *anyopaque, _: ui.render_extension.Device, _: ui.render_extension.DeviceGeneration) ui.Error!void {
        const self: *ReentrantRenderExtensionProbe = @ptrCast(@alignCast(raw));
        self.renderer.destroyExtension(self.id, 0) catch |err| {
            self.destroy_error = err;
        };
        _ = self.renderer.registerExtension(self.descriptor()) catch |err| {
            self.register_error = err;
            return;
        };
    }

    fn encode(_: *anyopaque, _: ui.render_extension.Pass, _: []const u8, _: u32) ui.Error!void {}
    fn deviceLost(raw: *anyopaque, _: ui.render_extension.DeviceGeneration) void {
        const self: *ReentrantRenderExtensionProbe = @ptrCast(@alignCast(raw));
        self.renderer.recover(.{}) catch |err| {
            self.device_lost_recover_error = err;
        };
    }
    fn deinit(raw: *anyopaque) void {
        const self: *ReentrantRenderExtensionProbe = @ptrCast(@alignCast(raw));
        if (self.app) |app| app.destroy() catch |err| {
            self.deinit_app_destroy_error = err;
        } else {
            self.renderer.destroyExtension(self.id, 0) catch |err| {
                self.deinit_destroy_error = err;
            };
            _ = self.renderer.registerExtension(self.descriptor()) catch |err| {
                self.deinit_register_error = err;
                return;
            };
        }
    }
};

const UnsupportedBackdropRenderer = struct {
    fn renderer(context: *anyopaque) ui.render.Renderer {
        return .{ .context = context, .vtable = &vtable };
    }

    const vtable: ui.render.Renderer.VTable = .{
        .capabilities = capabilities,
        .device_generation = deviceGeneration,
        .begin_frame = beginFrame,
        .submit = submit,
        .render_offscreen = renderOffscreen,
        .completed_epoch = completedEpoch,
        .invalidate_surface = invalidateSurface,
        .recover = recover,
        .create_texture = createTexture,
        .write_texture = writeTexture,
        .destroy_texture = destroyTexture,
        .import_external_surface = importExternalSurface,
        .replace_external_surface = replaceExternalSurface,
        .destroy_external_surface = destroyExternalSurface,
        .register_extension = registerExtension,
        .destroy_extension = destroyExtension,
        .deinit = deinit,
    };

    fn capabilities(_: *anyopaque) ui.render.Capabilities {
        return .{};
    }
    fn deviceGeneration(_: *anyopaque) ui.render.DeviceGeneration {
        return 1;
    }
    fn beginFrame(_: *anyopaque, _: ui.render.FrameDescriptor) ui.Error!ui.render.FrameToken {
        return error.Unsupported;
    }
    fn submit(_: *anyopaque, _: ui.render.FrameToken, _: ui.render.SceneView) ui.Error!ui.render.Submission {
        return error.Unsupported;
    }
    fn renderOffscreen(
        _: *anyopaque,
        _: ui.render.OffscreenTarget,
        _: ui.render.SceneView,
        _: std.mem.Allocator,
    ) ui.Error!?ui.render.Readback {
        return error.Unsupported;
    }
    fn completedEpoch(_: *anyopaque) ui.render.SubmissionEpoch {
        return 0;
    }
    fn invalidateSurface(_: *anyopaque, _: handles.WindowId) ui.Error!void {
        return error.Unsupported;
    }
    fn recover(_: *anyopaque, _: ui.config.GpuPolicy) ui.Error!void {
        return error.Unsupported;
    }
    fn createTexture(_: *anyopaque, _: handles.TextureId, _: ui.render.TextureDescriptor) ui.Error!void {
        return error.Unsupported;
    }
    fn writeTexture(
        _: *anyopaque,
        _: handles.TextureId,
        _: ui.render.TextureRegion,
        _: []const u8,
        _: usize,
    ) ui.Error!void {
        return error.Unsupported;
    }
    fn destroyTexture(_: *anyopaque, _: handles.TextureId, _: ui.render.SubmissionEpoch) ui.Error!void {
        return error.Unsupported;
    }
    fn importExternalSurface(
        _: *anyopaque,
        _: handles.SurfaceId,
        _: ui.render.ExternalSurfaceDescriptor,
    ) ui.Error!void {
        return error.Unsupported;
    }
    fn replaceExternalSurface(
        _: *anyopaque,
        _: handles.SurfaceId,
        _: ui.render.ExternalSurfaceDescriptor,
        _: ui.render.SubmissionEpoch,
    ) ui.Error!void {
        return error.Unsupported;
    }
    fn destroyExternalSurface(_: *anyopaque, _: handles.SurfaceId, _: ui.render.SubmissionEpoch) ui.Error!void {
        return error.Unsupported;
    }
    fn registerExtension(_: *anyopaque, _: ui.render_extension.Descriptor) ui.Error!handles.RenderExtensionId {
        return error.Unsupported;
    }
    fn destroyExtension(_: *anyopaque, _: handles.RenderExtensionId, _: ui.render.SubmissionEpoch) ui.Error!void {
        return error.Unsupported;
    }
    fn deinit(_: *anyopaque) void {}
};

fn noopWidgetCallback(context: *anyopaque, _: *ui.input.Context) ui.Error!void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

fn mutatingSelectionRects(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    _: f32,
    _: usize,
    _: usize,
    output: *std.ArrayList(ui.Rect),
    allocator: std.mem.Allocator,
) ui.Error!void {
    output.clearRetainingCapacity();
    try output.append(allocator, ui.Rect.fromXYWH(0, 0, 8, 18));
}

const TextGeometryProbe = struct {
    underlines: usize = 0,
    last_measure_style: ui.style.TextStyle = .{},
    last_paint_style: ui.style.TextStyle = .{},
    last_hit_style: ui.style.TextStyle = .{},
    last_caret_style: ui.style.TextStyle = .{},
    last_measure_max_width: f32 = 0,
    last_paint_bounds: ui.Rect = .{},
    last_hit_max_width: f32 = 0,
    last_hit_point: ui.Point = .{},
    last_caret_max_width: f32 = 0,

    fn services(self: *TextGeometryProbe) ui.custom.TextServices {
        return .{
            .context = self,
            .measure_fn = measure,
            .paint_fn = paint,
            .hit_test_fn = hitTest,
            .caret_rect_fn = caretRect,
            .selection_rects_fn = selectionRects,
        };
    }

    fn measure(
        context: *anyopaque,
        value: []const u8,
        style: ui.style.TextStyle,
        constraints: ui.layout.Constraints,
    ) ui.Error!ui.Size {
        const self: *TextGeometryProbe = @ptrCast(@alignCast(context));
        self.last_measure_style = style;
        self.last_measure_max_width = constraints.maximum.width;
        const natural_width = @as(f32, @floatFromInt(value.len)) * 8;
        const width = if (style.wrap == .none or !std.math.isFinite(constraints.maximum.width))
            natural_width
        else
            @min(natural_width, constraints.maximum.width);
        const lines = if (style.wrap == .none or width <= 0)
            1
        else
            @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(natural_width / width))));
        return constraints.constrain(.{ .width = width, .height = @as(f32, @floatFromInt(lines)) * 18 });
    }

    fn paint(
        context: *anyopaque,
        _: *anyopaque,
        _: []const u8,
        style: ui.style.TextStyle,
        bounds: ui.Rect,
    ) ui.Error!void {
        const self: *TextGeometryProbe = @ptrCast(@alignCast(context));
        self.last_paint_style = style;
        self.last_paint_bounds = bounds;
    }

    fn hitTest(
        context: *anyopaque,
        value: []const u8,
        style: ui.style.TextStyle,
        maximum_width: f32,
        point: ui.Point,
    ) ui.Error!ui.text.Hit {
        const self: *TextGeometryProbe = @ptrCast(@alignCast(context));
        self.last_hit_style = style;
        self.last_hit_max_width = maximum_width;
        self.last_hit_point = point;
        const offset: usize = @intFromFloat(@max(0, @round(point.x / 8)));
        return .{ .utf8_offset = @min(offset, value.len) };
    }

    fn caretRect(
        context: *anyopaque,
        value: []const u8,
        style: ui.style.TextStyle,
        maximum_width: f32,
        utf8_offset: usize,
        _: ui.text.CaretAffinity,
    ) ui.Error!ui.Rect {
        const self: *TextGeometryProbe = @ptrCast(@alignCast(context));
        self.last_caret_style = style;
        self.last_caret_max_width = maximum_width;
        return ui.Rect.fromXYWH(@as(f32, @floatFromInt(@min(utf8_offset, value.len))) * 8, 0, 1, 18);
    }

    fn selectionRects(
        _: *anyopaque,
        _: []const u8,
        _: ui.style.TextStyle,
        _: f32,
        start: usize,
        end: usize,
        output: *std.ArrayList(ui.Rect),
        allocator: std.mem.Allocator,
    ) ui.Error!void {
        if (start == end) return;
        const left = @min(start, end);
        const right = @max(start, end);
        try output.append(allocator, ui.Rect.fromXYWH(
            @as(f32, @floatFromInt(left)) * 8,
            0,
            @as(f32, @floatFromInt(right - left)) * 8,
            18,
        ));
    }

    fn emit(context: *anyopaque, command: ui.custom.PaintCommand) ui.Error!void {
        const self: *TextGeometryProbe = @ptrCast(@alignCast(context));
        switch (command) {
            .underline => self.underlines += 1,
            else => {},
        }
    }
};

const InvalidMeasureProbe = struct {
    pub fn measure(_: *InvalidMeasureProbe, _: *ui.custom.MeasureContext, _: ui.layout.Constraints) ui.Error!ui.Size {
        return .{ .width = @bitCast(@as(u32, 0x7fc00000)), .height = 10 };
    }

    pub fn paint(_: *InvalidMeasureProbe, _: *ui.custom.PaintContext, _: ui.Rect) ui.Error!void {}
};

const ClipboardProbe = struct {
    text: ?[]u8 = null,

    fn deinit(self: *ClipboardProbe) void {
        if (self.text) |owned_text| testing.allocator.free(owned_text);
        self.* = undefined;
    }

    fn value(self: *const ClipboardProbe) []const u8 {
        return self.text orelse "";
    }

    fn bridge(self: *ClipboardProbe) ui.input.NativeClipboard {
        return .{
            .context = self,
            .read_text_fn = read,
            .write_text_fn = write,
            .maximum_bytes = 1024,
        };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator) ui.Error!?[]u8 {
        const self: *ClipboardProbe = @ptrCast(@alignCast(context));
        const value_text = self.text orelse return null;
        return try allocator.dupe(u8, value_text);
    }

    fn write(context: *anyopaque, value_text: []const u8) ui.Error!void {
        const self: *ClipboardProbe = @ptrCast(@alignCast(context));
        const replacement = try testing.allocator.dupe(u8, value_text);
        if (self.text) |previous| testing.allocator.free(previous);
        self.text = replacement;
    }
};

const TextInputProbe = struct {
    active: bool = false,
    selection: ui.input.TextRange = .{ .start = 0, .end = 0 },
    candidate_rect: ui.Rect = .{},
    candidate_rect_calls: usize = 0,
    surrounding_text: [64]u8 = undefined,
    surrounding_text_length: usize = 0,
    activation_observed_surrounding_text: bool = false,
    activation_selection: ui.input.TextRange = .{},

    fn bridge(self: *TextInputProbe) ui.input.NativeTextInput {
        return .{
            .context = self,
            .set_active_fn = setActive,
            .set_candidate_rect_fn = setCandidateRect,
            .set_surrounding_text_fn = setSurroundingText,
            .maximum_surrounding_text_bytes = 1024,
        };
    }

    fn setActive(context: *anyopaque, _: handles.WindowId, active: bool) ui.Error!void {
        const self: *TextInputProbe = @ptrCast(@alignCast(context));
        self.active = active;
        if (active) {
            self.activation_observed_surrounding_text = std.mem.eql(
                u8,
                self.surrounding_text[0..self.surrounding_text_length],
                "## Heading",
            );
            self.activation_selection = self.selection;
        }
    }

    fn setCandidateRect(context: *anyopaque, _: handles.WindowId, rect: ui.Rect) ui.Error!void {
        const self: *TextInputProbe = @ptrCast(@alignCast(context));
        self.candidate_rect = rect;
        self.candidate_rect_calls += 1;
    }

    fn setSurroundingText(
        context: *anyopaque,
        _: handles.WindowId,
        text: []const u8,
        selection: ui.input.TextRange,
    ) ui.Error!void {
        const self: *TextInputProbe = @ptrCast(@alignCast(context));
        if (text.len > self.surrounding_text.len) return error.BudgetExceeded;
        @memcpy(self.surrounding_text[0..text.len], text);
        self.surrounding_text_length = text.len;
        self.selection = selection;
    }
};

fn sendShortcut(
    field: *ui.widgets.TextField,
    dispatch: *ui.input.Dispatch,
    context: *ui.input.Context,
    scalar: u21,
    shift: bool,
) ui.Error!void {
    const value: ui.input.Event = .{ .key_down = .{
        .key = .{ .character = scalar },
        .physical_code = 0,
        .modifiers = .{ .command = true, .shift = shift },
    } };
    try field.event(dispatch, &value, context);
}

fn textFieldSetValueAllocationProbe(allocator: std.mem.Allocator) !void {
    var field = try ui.widgets.TextField.init(allocator, "committed");
    defer field.deinit();
    field.setValue("replacement value") catch |err| {
        if (err == error.OutOfMemory) try testing.expectEqualStrings("committed", field.value());
        return err;
    };
    try testing.expectEqualStrings("replacement value", field.value());
}

fn emptyTextMeasure(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    _: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    return .{ .size = .zero };
}

fn menuTextMeasure(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    constraints: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    return .{ .size = constraints.constrain(.{ .width = 160, .height = 36 }) };
}

fn wrappingTextMeasure(
    _: *anyopaque,
    value: []const u8,
    _: ui.style.TextStyle,
    constraints: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    const natural_width = @as(f32, @floatFromInt(value.len)) * 10;
    const width = @min(natural_width, constraints.maximum.width);
    const lines = @max(@as(f32, 1), @ceil(natural_width / @max(width, 1)));
    return .{
        .size = constraints.constrain(.{ .width = width, .height = lines * 10 }),
        .baseline = 8,
    };
}

fn clippedTextMeasure(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    constraints: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    return .{
        .size = constraints.constrain(.{ .width = 32, .height = 30 }),
        .baseline = 24,
    };
}

fn variableBaselineTextMeasure(
    _: *anyopaque,
    value: []const u8,
    _: ui.style.TextStyle,
    constraints: ui.layout.Constraints,
) ui.Error!ui.layout_engine.TextMeasure {
    return .{
        .size = constraints.constrain(.{ .width = 20, .height = 10 }),
        .baseline = if (std.mem.eql(u8, value, "high")) 8 else 3,
    };
}

fn emptyCustomMeasure(
    _: *anyopaque,
    _: []const u8,
    _: ui.style.TextStyle,
    _: ui.layout.Constraints,
) ui.Error!ui.Size {
    return .zero;
}

const EventCollector = struct {
    const Tag = std.meta.Tag(ui.platform.WindowEvent);
    tags: [32]Tag = undefined,
    len: usize = 0,

    fn receive(context: *anyopaque, _: handles.WindowId, event: *const ui.platform.WindowEvent) void {
        const self: *EventCollector = @ptrCast(@alignCast(context));
        if (self.len == self.tags.len) return;
        self.tags[self.len] = std.meta.activeTag(event.*);
        self.len += 1;
    }
};

const EffectProbe = struct {
    runs: usize = 0,
    drops: usize = 0,

    fn deferred(self: *EffectProbe) ui.runtime_effect.Deferred {
        return .{ .context = self, .run_fn = run, .drop_fn = drop };
    }

    fn run(context: *anyopaque) void {
        const self: *EffectProbe = @ptrCast(@alignCast(context));
        self.runs += 1;
    }

    fn drop(context: *anyopaque) void {
        const self: *EffectProbe = @ptrCast(@alignCast(context));
        self.drops += 1;
    }
};

const MenuProbe = struct {
    set_calls: usize = 0,
    show_calls: usize = 0,
    payload: u64 = 0,

    fn set(context: *anyopaque, items: []const ui.platform.MenuItem) ui.Error!void {
        const self: *MenuProbe = @ptrCast(@alignCast(context));
        self.set_calls += 1;
        if (items.len != 0) switch (items[0]) {
            .action => |item| self.payload = item.payload,
            else => {},
        };
    }

    fn show(
        context: *anyopaque,
        _: handles.WindowId,
        _: ui.Point,
        _: []const ui.platform.MenuItem,
    ) ui.Error!void {
        const self: *MenuProbe = @ptrCast(@alignCast(context));
        self.show_calls += 1;
    }
};

const ApplicationServiceProbe = struct {
    calls: usize = 0,

    fn service(self: *ApplicationServiceProbe) ui.platform.ApplicationServices {
        return .{
            .context = self,
            .open_url_fn = call,
            .open_path_fn = call,
            .reveal_path_fn = call,
            .print_path_fn = call,
            .maximum_text_bytes = 128,
        };
    }

    fn call(context: *anyopaque, _: []const u8) ui.Error!void {
        const self: *ApplicationServiceProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
    }
};

const ClipboardPathProbe = struct {
    calls: usize = 0,
    path_count: usize = 0,
    image_calls: usize = 0,
    image_bytes: []const u8 = "",

    fn service(self: *ClipboardPathProbe) ui.platform.Clipboard {
        return .{
            .context = self,
            .read_text_fn = readText,
            .write_text_fn = writeText,
            .write_paths_fn = writePaths,
            .write_image_fn = writeImage,
            .maximum_bytes = 128,
            .maximum_paths = 4,
        };
    }

    fn readText(_: *anyopaque, _: std.mem.Allocator) ui.Error!?[]u8 {
        return null;
    }

    fn writeText(_: *anyopaque, _: []const u8) ui.Error!void {}

    fn writePaths(context: *anyopaque, paths: []const []const u8) ui.Error!void {
        const self: *ClipboardPathProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.path_count = paths.len;
    }

    fn writeImage(context: *anyopaque, image: ui.platform.ClipboardImage) ui.Error!void {
        const self: *ClipboardPathProbe = @ptrCast(@alignCast(context));
        self.image_calls += 1;
        self.image_bytes = image.bytes;
    }
};

const NativeMediaProbe = struct {
    calls: usize = 0,
    volume: f32 = 0.75,
    muted: bool = false,
    status: ui.platform.NativeMediaStatus = .ready,
    playing: bool = true,
    has_presented_frame: bool = false,
    error_description: ?ui.platform.NativeMediaErrorDescription = null,

    fn service(self: *NativeMediaProbe) ui.platform.NativeMedia {
        return .{
            .context = self,
            .create_fn = create,
            .set_frame_fn = setFrame,
            .synchronize_fn = synchronize,
            .play_fn = play,
            .pause_fn = pause,
            .seek_fn = seek,
            .set_volume_fn = setVolume,
            .set_muted_fn = setMuted,
            .state_fn = state,
            .destroy_fn = destroy,
        };
    }

    fn count(context: *anyopaque) *NativeMediaProbe {
        const self: *NativeMediaProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
        return self;
    }
    fn create(context: *anyopaque, _: handles.WindowId, _: ui.platform.NativeMediaOptions) ui.Error!handles.NativeMediaId {
        _ = count(context);
        return handles.NativeMediaId.init(1, 1);
    }
    fn setFrame(context: *anyopaque, _: handles.NativeMediaId, _: ui.Rect) ui.Error!void {
        _ = count(context);
    }
    fn synchronize(context: *anyopaque, _: handles.WindowId, _: []const ui.core.native_media.Placement) ui.Error!void {
        _ = count(context);
    }
    fn play(context: *anyopaque, _: handles.NativeMediaId) ui.Error!void {
        _ = count(context);
    }
    fn pause(context: *anyopaque, _: handles.NativeMediaId) ui.Error!void {
        _ = count(context);
    }
    fn seek(context: *anyopaque, _: handles.NativeMediaId, _: u64) ui.Error!void {
        _ = count(context);
    }
    fn setVolume(context: *anyopaque, _: handles.NativeMediaId, volume: f32) ui.Error!void {
        count(context).volume = volume;
    }
    fn setMuted(context: *anyopaque, _: handles.NativeMediaId, muted: bool) ui.Error!void {
        count(context).muted = muted;
    }
    fn state(context: *anyopaque, _: handles.NativeMediaId) ui.Error!ui.platform.NativeMediaState {
        const self = count(context);
        return .{
            .status = self.status,
            .error_description = self.error_description,
            .has_presented_frame = self.has_presented_frame,
            .playing = self.playing,
            .position_ns = 42,
            .duration_ns = 84,
            .volume = self.volume,
            .muted = self.muted,
        };
    }
    fn destroy(context: *anyopaque, _: handles.NativeMediaId) ui.Error!void {
        _ = count(context);
    }
};

const PayloadCollector = struct {
    ime_owned: bool = false,
    path_owned: bool = false,
    drop_text_owned: bool = false,
    accessibility_owned: bool = false,

    fn receive(context: *anyopaque, _: handles.WindowId, event: *const ui.platform.WindowEvent) void {
        const self: *PayloadCollector = @ptrCast(@alignCast(context));
        switch (event.*) {
            .input => |input_event| switch (input_event) {
                .ime => |ime| switch (ime) {
                    .commit_text => |commit| self.ime_owned = std.mem.eql(u8, commit.text, "ime"),
                    else => {},
                },
                .file_drop_performed => |drop| {
                    self.path_owned = drop.paths.len == 1 and std.mem.eql(u8, drop.paths[0], "/tmp/a");
                    self.drop_text_owned = drop.text != null and std.mem.eql(u8, drop.text.?, "https://example.com");
                },
                else => {},
            },
            .accessibility_action => |request| {
                self.accessibility_owned = if (request.value) |value|
                    std.mem.eql(u8, value, "value")
                else
                    false;
            },
            else => {},
        }
    }
};

const CompletionProbe = struct {
    applied: u32 = 0,
    dropped: u32 = 0,

    fn completion(self: *CompletionProbe, task: handles.TaskId) ui.runtime_task.Completion {
        return .{
            .task = task,
            .context = self,
            .apply_fn = apply,
            .drop_fn = drop,
        };
    }

    fn apply(context: *anyopaque) void {
        const self: *CompletionProbe = @ptrCast(@alignCast(context));
        self.applied += 1;
    }

    fn drop(context: *anyopaque) void {
        const self: *CompletionProbe = @ptrCast(@alignCast(context));
        self.dropped += 1;
    }
};

const ComponentProbe = struct {
    dropped: u32 = 0,

    fn descriptor(self: *ComponentProbe) ui.Component.Descriptor {
        return .{ .context = self, .build_fn = build, .drop_fn = drop };
    }

    fn build(_: *anyopaque, _: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        return .{};
    }

    fn drop(context: *anyopaque) void {
        const self: *ComponentProbe = @ptrCast(@alignCast(context));
        self.dropped += 1;
    }
};

fn failingHandler(
    _: *anyopaque,
    _: *ui.input.Dispatch,
    _: *const ui.input.Event,
    _: *ui.input.Context,
) ui.Error!void {
    return error.BudgetExceeded;
}

fn checkReconcileAllocationFailures(allocator: std.mem.Allocator) !void {
    // Force every resize through the allocate-copy-free path so the number of
    // independently fail-able allocation points does not depend on whether a
    // backing allocator can grow one particular block in place.
    var baseline = testing.FailingAllocator.init(allocator, .{ .resize_fail_index = 0 });
    try reconcileAllocationProbe(baseline.allocator());
    const required = baseline.alloc_index;
    for (0..required) |fail_index| {
        var failing = testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        reconcileAllocationProbe(failing.allocator()) catch |err| switch (err) {
            error.OutOfMemory => {
                if (failing.allocated_bytes != failing.freed_bytes) return error.MemoryLeakDetected;
                continue;
            },
            else => return err,
        };
        if (failing.has_induced_failure) return error.SwallowedOutOfMemoryError;
        return error.NondeterministicMemoryUsage;
    }
}

fn reconcileAllocationProbe(allocator: std.mem.Allocator) !void {
    var store = ui.NodeStore.init(allocator);
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const original_children = [_]ui.NodeSpec{
        (ui.NodeSpec{
            .kind = .{ .text = "first" },
            .style = .{ .layout = .{ .width = .{ .points = 10 } } },
            .semantics = .{ .label = "first-original" },
        }).withKey(11),
        (ui.NodeSpec{
            .kind = .{ .text = "second" },
            .style = .{ .layout = .{ .width = .{ .points = 12 } } },
            .semantics = .{ .label = "second-original" },
        }).withKey(22),
    };
    const root = try store.reconcile(null, .invalid, .invalid, .{ .children = &original_children }, 1, scratch.allocator());
    const initial_retained_bytes = store.retainedBytes();
    const initial = store.getConst(root).?;
    const original_ids = [2]handles.NodeId{ initial.children.items[0], initial.children.items[1] };
    _ = scratch.reset(.free_all);

    const replacement_children = [_]ui.NodeSpec{
        (ui.NodeSpec{
            .kind = .spacer,
            .style = .{ .layout = .{ .width = .{ .points = 20 } } },
            .semantics = .{ .label = "first-replaced" },
        }).withKey(11),
        (ui.NodeSpec{
            .kind = .{ .text = "second-updated" },
            .style = .{ .layout = .{ .width = .{ .points = 24 } } },
            .semantics = .{ .label = "second-updated" },
        }).withKey(22),
        (ui.NodeSpec{
            .kind = .{ .text = "third" },
            .style = .{ .layout = .{ .width = .{ .points = 30 } } },
            .semantics = .{ .label = "third-new" },
        }).withKey(33),
    };
    const reconciled = store.reconcile(root, .invalid, .invalid, .{ .children = &replacement_children }, 1, scratch.allocator()) catch |err| {
        if (err != error.OutOfMemory) return err;
        const committed = store.getConst(root) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 2), committed.children.items.len);
        try testing.expect(committed.children.items[0].eql(original_ids[0]));
        try testing.expect(committed.children.items[1].eql(original_ids[1]));
        try testing.expect(std.meta.eql(ui.layout.Length{ .points = 10 }, store.getConst(original_ids[0]).?.borrowedStyle().layout.width));
        try testing.expect(std.meta.eql(ui.layout.Length{ .points = 12 }, store.getConst(original_ids[1]).?.borrowedStyle().layout.width));
        var live: usize = 0;
        var iterator = store.inspectIterator();
        while (iterator.next()) |_| live += 1;
        try testing.expectEqual(@as(usize, 3), live);
        try testing.expectEqual(initial_retained_bytes, store.retainedBytes());
        return err;
    };
    try testing.expect(reconciled.eql(root));
    const committed = store.getConst(root).?;
    try testing.expectEqual(@as(usize, 3), committed.children.items.len);
    try testing.expect(!committed.children.items[0].eql(original_ids[0]));
    try testing.expect(committed.children.items[1].eql(original_ids[1]));
    try testing.expect(store.retainedBytes() >= initial_retained_bytes);
}

fn svgManagerAllocationProbe(allocator: std.mem.Allocator) !void {
    var manager = ui.SvgManager.init(allocator, .{}, 1024 * 1024, 8);
    defer manager.deinit();
    const source =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
        \\  <rect width="8" height="8" fill="#336699"/>
        \\</svg>
    ;
    const id = try manager.load(source);
    try manager.release(id);
}

fn sceneSnapshotAllocationProbe(allocator: std.mem.Allocator) !void {
    const operation = ui.scene_abi.Operation{
        .kind = @backingInt(ui.scene_abi.OperationKind.quads),
        .start = 0,
        .count = 1,
        .clip = ui.scene.none_index,
        .layer = ui.scene.none_index,
        .material = ui.scene.none_index,
        .target = 0,
        .reserved = ui.scene.none_index,
    };
    const quad = ui.scene_abi.Quad{
        .bounds = ui.Rect.fromXYWH(0, 0, 4, 4),
        .background = ui.Color.rgba(1, 0, 0, 1),
        .border_color = .transparent,
        .border_widths = .{},
        .radii = .{},
    };
    const source: ui.render.SceneView = .{
        .operations = @as([]const ui.scene_abi.Operation, &.{operation}),
        .materials = &.{},
        .gradient_stops = &.{},
        .clips = &.{},
        .layers = &.{},
        .shadows = &.{},
        .quads = @as([]const ui.scene_abi.Quad, &.{quad}),
        .paths = &.{},
        .path_vertices = &.{},
        .underlines = &.{},
        .monochrome_sprites = &.{},
        .color_sprites = &.{},
        .external_surfaces = &.{},
        .custom_passes = &.{},
        .custom_payload = &.{},
    };
    var snapshot = try ui.render.SceneSnapshot.init(allocator, source);
    defer snapshot.deinit();
    try testing.expectEqual(source.operations.len, snapshot.view().operations.len);
    try testing.expectEqual(source.quads.len, snapshot.view().quads.len);
}

test "owned texture pixels survive recovery and retire with their original allocator" {
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var resources = ui.resources.Manager.init(testing.allocator, 256, 256);
    defer resources.deinit();
    const pixels = try testing.allocator.alloc(u8, 64);
    @memset(pixels, 127);
    const id = try resources.createTextureOwned(.{ .width = 4, .height = 4, .format = .rgba8 }, pixels, testing.allocator);
    try testing.expectEqual(pixels.ptr, resources.get(id).?.cpu_copy.?.ptr);
    try resources.realize(renderer, id);
    try renderer.recover(.{});
    resources.deviceLost();
    try resources.realize(renderer, id);
    try resources.markUsed(id, 5);
    try resources.destroyTextureOnRenderer(renderer, id);
    resources.collect(4);
    try testing.expectEqual(@as(usize, 64), resources.stats().cpu_reserved);
    resources.collect(5);
    try testing.expectEqual(@as(usize, 0), resources.stats().cpu_reserved);
}

test "owned texture rejection leaves pixel ownership with caller" {
    var resources = ui.resources.Manager.init(testing.allocator, 1, 1);
    defer resources.deinit();
    const pixels = try testing.allocator.alloc(u8, 64);
    defer testing.allocator.free(pixels);
    try testing.expectError(error.BudgetExceeded, resources.createTextureOwned(.{ .width = 4, .height = 4, .format = .rgba8 }, pixels, testing.allocator));
    try testing.expectEqual(@as(usize, 0), resources.stats().cpu_reserved);
}

test "atlas eviction notifies the owner with the removed generation" {
    const Probe = struct {
        removed: ?ui.core.handles.AtlasTileId = null,
        fn evicted(raw: *anyopaque, id: ui.core.handles.AtlasTileId) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.removed = id;
        }
    };
    var resources = ui.resources.Manager.init(testing.allocator, 1024, 0);
    defer resources.deinit();
    var atlas = try ui.atlas.Atlas.init(testing.allocator, &resources, 4, 1, .a8);
    defer atlas.deinit();
    var probe = Probe{};
    const first = try atlas.allocate(4, 4, 1, 0);
    const second = try atlas.allocateNotifying(4, 4, 2, 0, .{ .context = &probe, .evicted = Probe.evicted });
    try testing.expect(probe.removed.?.eql(first));
    try testing.expect(!second.eql(first));
    try testing.expect(atlas.get(first) == null);
}

test "prepared images transfer once including duplicate and rejected uploads" {
    if (comptime !ui.config.images_enabled) return;
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var resources = ui.resources.Manager.init(testing.allocator, 64, 64);
    defer resources.deinit();
    var manager = ui.ImageManager.init(testing.allocator, renderer, &resources, .{});
    defer manager.deinit();
    const pixels = try testing.allocator.alloc(u8, 64);
    @memset(pixels, 255);
    var prepared = try ui.image.Prepared.init(testing.allocator, .{ .width = 4, .height = 4, .stride = 16, .pixels = pixels });
    defer prepared.deinit();
    const id = try manager.adopt(&prepared);
    try testing.expectEqual(@as(usize, 0), prepared.value.pixels.len);
    try testing.expectEqual(pixels.ptr, resources.get(id).?.cpu_copy.?.ptr);
    const duplicate = try testing.allocator.alloc(u8, 64);
    @memset(duplicate, 255);
    var second = try ui.image.Prepared.init(testing.allocator, .{ .width = 4, .height = 4, .stride = 16, .pixels = duplicate });
    defer second.deinit();
    try testing.expect((try manager.adopt(&second)).eql(id));
    try testing.expectEqual(@as(usize, 0), second.value.pixels.len);
    const other = try testing.allocator.alloc(u8, 64);
    @memset(other, 127);
    var rejected = try ui.image.Prepared.init(testing.allocator, .{ .width = 4, .height = 4, .stride = 16, .pixels = other });
    defer rejected.deinit();
    try testing.expectError(error.BudgetExceeded, manager.adopt(&rejected));
    try testing.expectEqual(@as(usize, 0), rejected.value.pixels.len);
    try manager.release(id);
    try manager.release(id);
    resources.collect(renderer.completedEpoch());
    try testing.expectEqual(@as(usize, 0), resources.stats().cpu_reserved);
}

test "continuous zoom keeps glyph metadata bounded by live atlas tiles" {
    const Valid = struct {
        fn font(_: *anyopaque, _: ui.text.FontDescriptor) ui.Error!handles.FontId {
            return handles.FontId.init(0, 1);
        }
        fn metrics(_: *anyopaque, _: handles.FontId, _: f32) ui.Error!ui.text.FontMetrics {
            return .{ .ascent = 10, .descent = 2, .leading = 0, .x_height = 5, .cap_height = 7, .underline_position = 1, .underline_thickness = 1 };
        }
        fn shape(raw: *anyopaque, request: ui.text.ShapeRequest, allocator: std.mem.Allocator) ui.Error!ui.text.ShapedRun {
            var result = try MalformedTextBackend.shape(raw, request, allocator);
            result.width = 1;
            return result;
        }
        fn rasterize(raw: *anyopaque, request: ui.text.RasterRequest, allocator: std.mem.Allocator) ui.Error!ui.text.RasterizedGlyph {
            var result = try MalformedTextBackend.rasterize(raw, request, allocator);
            result.stride = 2;
            return result;
        }
    };
    var probe = MalformedTextBackend{};
    var backend = probe.backend();
    backend.resolve_font_fn = Valid.font;
    backend.metrics_fn = Valid.metrics;
    backend.shape_fn = Valid.shape;
    backend.rasterize_fn = Valid.rasterize;
    const renderer = try ui.NullRenderer.create(testing.allocator);
    defer renderer.deinit();
    var resources = ui.resources.Manager.init(testing.allocator, 16 * 1024 * 1024, 0);
    defer resources.deinit();
    var counters = ui.core.metrics.Counters{};
    var system = try ui.TextSystem.init(testing.allocator, backend, renderer, &resources, try ui.ScaleFactor.init(1), 1024 * 1024, 5 * 1024 * 1024, 4, &counters);
    defer system.deinit();
    for (0..512) |index| {
        system.beginFrame(index + 1, try ui.ScaleFactor.init(1));
        _ = try system.prepare("A", .{ .font_size = 12 + @as(f32, @floatFromInt(index)) / 128 }, 100);
        try testing.expect(system.glyphs.count() <= 4);
        try testing.expectEqual(system.glyphs.count(), system.glyph_keys.count());
    }
    try testing.expectEqual(@as(u32, 4), system.glyphs.count());
}
