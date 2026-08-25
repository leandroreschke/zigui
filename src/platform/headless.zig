const std = @import("std");
const Error = @import("../core/error.zig").Error;
const config = @import("../config.zig");
const clock = @import("../core/clock.zig");
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const input = @import("../input/event.zig");
const null_renderer = @import("../render/null.zig");
const text = @import("../text/api.zig");
const api = @import("api.zig");
const event_memory = @import("event_memory.zig");

const QueuedEvent = struct {
    window: handles.WindowId,
    event: api.WindowEvent,
    owned_text: ?[]u8 = null,
    owned_paths: ?[][]const u8 = null,
    owned_bytes: usize = 0,

    fn deinit(self: *QueuedEvent, allocator: std.mem.Allocator) void {
        if (self.owned_text) |text_value| allocator.free(text_value);
        if (self.owned_paths) |paths| {
            for (paths) |path| allocator.free(@constCast(path));
            allocator.free(paths);
        }
        self.* = undefined;
    }
};

const Window = struct {
    title: ?[]u8,
    size: geometry.Size,
    position: geometry.Point = .{},
    visible: bool,
    mode: api.WindowMode = .normal,
    always_on_top: bool = false,
};

pub const Harness = struct {
    context: *Context,
    bundle: api.Bundle,

    pub fn post(self: *Harness, window: handles.WindowId, event: api.WindowEvent) Error!void {
        try self.context.post(window, event);
    }

    pub fn advance(self: *Harness, duration_ns: u64) void {
        self.context.manual_clock.advance(duration_ns);
    }

    /// Enters the same terminal failure state used when an asynchronous native
    /// callback cannot publish a required event. The first failure remains
    /// sticky until teardown, which makes recovery policy deterministic in
    /// conformance and embedding tests.
    pub fn injectFailure(self: *Harness, err: Error) void {
        self.context.fail(err);
    }
};

const Context = struct {
    allocator: std.mem.Allocator,
    manual_clock: clock.ManualClock = .{},
    events: std.ArrayList(QueuedEvent) = .empty,
    event_cursor: usize = 0,
    windows: std.AutoHashMap(u64, Window),
    maximum_events: usize,
    maximum_windows: usize,
    maximum_event_payload_bytes: usize,
    maximum_event_queue_bytes: usize,
    maximum_file_drop_paths: usize,
    retained_text: event_memory.RetainedTextBudget,
    pending_payload_bytes: usize = 0,
    clipboard_text: ?[]u8 = null,
    quit: bool = false,
    failure: ?Error = null,

    fn queue(self: *Context, window: handles.WindowId, event: api.WindowEvent) Error!void {
        try self.prepareEventSlots(1);
        self.events.appendAssumeCapacity(.{ .window = window, .event = event });
    }

    fn post(self: *Context, window: handles.WindowId, event: api.WindowEvent) Error!void {
        try self.prepareEventSlots(1);
        var queued = try self.cloneEvent(window, event);
        errdefer queued.deinit(self.allocator);
        const payload_bytes = queued.owned_bytes;
        if (payload_bytes > self.maximum_event_queue_bytes -| self.pending_payload_bytes)
            return error.BudgetExceeded;
        self.events.appendAssumeCapacity(queued);
        self.pending_payload_bytes += payload_bytes;
    }

    fn prepareEventSlots(self: *Context, count: usize) Error!void {
        if (count == 0) return;
        if (self.event_cursor != 0 and
            (self.event_cursor >= self.maximum_events / 2 or
                count > self.maximum_events -| (self.events.items.len - self.event_cursor)))
            self.compactEvents();
        const unread = self.events.items.len - self.event_cursor;
        if (count > self.maximum_events -| unread) return error.BudgetExceeded;
        try self.events.ensureUnusedCapacity(self.allocator, count);
    }

    fn cloneEvent(self: *Context, window: handles.WindowId, source: api.WindowEvent) Error!QueuedEvent {
        var result: QueuedEvent = .{ .window = window, .event = source };
        errdefer result.deinit(self.allocator);
        switch (result.event) {
            .input => |*event_value| {
                try input.validate(event_value, .{
                    .maximum_payload_bytes = self.maximum_event_payload_bytes,
                    .maximum_file_paths = self.maximum_file_drop_paths,
                });
                switch (event_value.*) {
                    .ime => |*ime| switch (ime.*) {
                        .set_marked_text => |*marked| {
                            _ = try event_memory.ensureFits(marked.text, null, self.pending_payload_bytes, self.maximum_event_queue_bytes);
                            result.owned_text = try self.allocator.dupe(u8, marked.text);
                            marked.text = result.owned_text.?;
                        },
                        .commit_text => |*commit| {
                            _ = try event_memory.ensureFits(commit.text, null, self.pending_payload_bytes, self.maximum_event_queue_bytes);
                            result.owned_text = try self.allocator.dupe(u8, commit.text);
                            commit.text = result.owned_text.?;
                        },
                        else => {},
                    },
                    .file_drop_entered, .file_drop_updated, .file_drop_performed => |*drop| {
                        _ = try event_memory.ensureFits(null, drop.paths, self.pending_payload_bytes, self.maximum_event_queue_bytes);
                        result.owned_paths = try clonePaths(self.allocator, drop.paths);
                        drop.paths = result.owned_paths.?;
                    },
                    .accessibility => |*request| if (request.value) |value| {
                        _ = try event_memory.ensureFits(value, null, self.pending_payload_bytes, self.maximum_event_queue_bytes);
                        result.owned_text = try self.allocator.dupe(u8, value);
                        request.value = result.owned_text.?;
                    },
                    else => {},
                }
            },
            .accessibility_action => |*request| {
                var event_value: input.Event = .{ .accessibility = .{
                    .target = request.target,
                    .action = request.action,
                    .value = request.value,
                    .selection = request.selection,
                } };
                try input.validate(&event_value, .{
                    .maximum_payload_bytes = self.maximum_event_payload_bytes,
                    .maximum_file_paths = self.maximum_file_drop_paths,
                });
                if (request.value) |value| {
                    _ = try event_memory.ensureFits(value, null, self.pending_payload_bytes, self.maximum_event_queue_bytes);
                    result.owned_text = try self.allocator.dupe(u8, value);
                    request.value = result.owned_text.?;
                }
            },
            else => {},
        }
        result.owned_bytes = try event_memory.ownedPayloadBytes(result.owned_text, result.owned_paths);
        return result;
    }

    fn compactEvents(self: *Context) void {
        if (self.event_cursor == 0) return;
        if (self.event_cursor < self.events.items.len) {
            std.mem.copyForwards(QueuedEvent, self.events.items[0 .. self.events.items.len - self.event_cursor], self.events.items[self.event_cursor..]);
        }
        self.events.items.len -= self.event_cursor;
        self.event_cursor = 0;
    }

    fn fail(self: *Context, err: Error) void {
        if (self.failure == null) self.failure = err;
        self.quit = true;
    }
};

pub fn create(allocator: std.mem.Allocator, text_backend: ?text.Backend) Error!Harness {
    return createWithMemory(allocator, text_backend, .{});
}

pub fn createWithMemory(
    allocator: std.mem.Allocator,
    text_backend: ?text.Backend,
    memory: config.MemoryBudgets,
) Error!Harness {
    const context = try allocator.create(Context);
    errdefer allocator.destroy(context);
    context.* = .{
        .allocator = allocator,
        .windows = std.AutoHashMap(u64, Window).init(allocator),
        .maximum_events = memory.platform_event_count,
        .maximum_windows = memory.window_count,
        .maximum_event_payload_bytes = memory.platform_event_payload_bytes,
        .maximum_event_queue_bytes = memory.platform_event_queue_bytes,
        .maximum_file_drop_paths = memory.file_drop_path_count,
        .retained_text = try event_memory.RetainedTextBudget.init(memory.platform_retained_text_bytes),
    };
    errdefer context.windows.deinit();
    const renderer = try null_renderer.NullRenderer.createWithMemory(allocator, memory);
    errdefer renderer.deinit();
    const bundle: api.Bundle = .{
        .event_loop = .{
            .context = context,
            .run_fn = run,
            .step_fn = step,
            .wake_fn = wake,
            .request_quit_fn = requestQuit,
            .clock = context.manual_clock.clock(),
        },
        .windows = .{
            .context = context,
            .create_fn = createWindow,
            .destroy_fn = destroyWindow,
            .show_fn = showWindow,
            .title_fn = titleWindow,
            .request_frame_fn = requestFrame,
            .set_cursor_fn = setCursor,
            .command_fn = commandWindow,
            .native_handle_fn = nativeHandle,
            .maximum_text_bytes = memory.platform_text_bytes,
        },
        .displays = .{
            .context = context,
            .list_fn = listDisplays,
            .maximum_count = memory.platform_object_count,
            .maximum_text_bytes = memory.platform_text_bytes,
        },
        .renderer = renderer,
        .text_backend = text_backend,
        .clipboard = .{
            .context = context,
            .read_text_fn = readClipboard,
            .write_text_fn = writeClipboard,
            .read_contents_fn = readClipboardContents,
            .maximum_bytes = memory.clipboard_bytes,
            .maximum_paths = memory.file_drop_path_count,
        },
        .deinit_context = context,
        .deinit_fn = deinit,
    };
    return .{ .context = context, .bundle = bundle };
}

fn cast(context: *anyopaque) *Context {
    return @ptrCast(@alignCast(context));
}

fn run(context: *anyopaque, sink: api.EventSink) Error!void {
    const self = cast(context);
    if (self.failure) |failure| return failure;
    self.quit = false;
    while (!self.quit) {
        const progressed = try step(context, sink, true);
        sink.pump();
        if (!progressed) break;
    }
    if (self.failure) |failure| return failure;
}

fn step(context: *anyopaque, sink: api.EventSink, wait: bool) Error!bool {
    _ = wait;
    const self = cast(context);
    if (self.failure) |failure| return failure;
    if (self.quit) return false;
    if (self.event_cursor >= self.events.items.len) {
        self.compactEvents();
        return false;
    }
    var queued = self.events.items[self.event_cursor];
    self.event_cursor += 1;
    sink.send(queued.window, &queued.event);
    self.pending_payload_bytes -= queued.owned_bytes;
    queued.deinit(self.allocator);
    if (self.event_cursor >= self.events.items.len) self.compactEvents();
    return true;
}

fn wake(_: *anyopaque) void {}

fn requestQuit(context: *anyopaque) void {
    cast(context).quit = true;
}

fn createWindow(context: *anyopaque, id: handles.WindowId, options: api.WindowOptions) Error!api.NativeHandle {
    const self = cast(context);
    if (self.windows.contains(id.encode())) return error.ResourceBusy;
    if (self.windows.count() >= self.maximum_windows) return error.BudgetExceeded;
    const event_count: usize = if (options.visible) 3 else 2;
    try self.prepareEventSlots(event_count);
    const title = try self.retained_text.duplicate(self.allocator, options.title);
    var title_owned: ?[]u8 = title;
    errdefer self.retained_text.release(self.allocator, &title_owned);
    try self.windows.put(id.encode(), .{
        .title = title,
        .size = options.size,
        .position = options.position orelse .{},
        .visible = options.visible,
        .always_on_top = options.always_on_top,
    });
    title_owned = null;
    const handle: api.NativeHandle = .{ .kind = .headless, .value = @intCast(id.encode()) };
    self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .created = handle } });
    self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .configured = .{
        .logical_size = options.size,
        .scale_factor = geometry.ScaleFactor.init(1) catch unreachable,
    } } });
    if (options.visible) self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .frame_requested = self.manual_clock.current } });
    return handle;
}

fn destroyWindow(context: *anyopaque, id: handles.WindowId) void {
    const self = cast(context);
    const removed = self.windows.fetchRemove(id.encode()) orelse return;
    var title = removed.value.title;
    self.retained_text.release(self.allocator, &title);
    self.queue(id, .closed) catch |err| self.fail(err);
}

fn showWindow(context: *anyopaque, id: handles.WindowId, visible: bool) Error!void {
    const self = cast(context);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    if (window.visible == visible) return;
    if (visible) try self.prepareEventSlots(1);
    window.visible = visible;
    if (visible) self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .frame_requested = self.manual_clock.current } });
}

fn titleWindow(context: *anyopaque, id: handles.WindowId, title: []const u8) Error!void {
    const self = cast(context);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    try self.retained_text.replace(self.allocator, &window.title, title);
}

fn requestFrame(context: *anyopaque, id: handles.WindowId) Error!void {
    const self = cast(context);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    if (!window.visible) return;
    try self.queue(id, .{ .frame_requested = self.manual_clock.current });
}

fn setCursor(context: *anyopaque, id: handles.WindowId, _: api.Cursor) Error!void {
    if (!cast(context).windows.contains(id.encode())) return error.InvalidHandle;
}

fn commandWindow(context: *anyopaque, id: handles.WindowId, command: api.WindowCommand) Error!void {
    const self = cast(context);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    switch (command) {
        .move => |position| {
            try self.prepareEventSlots(1);
            window.position = position;
            self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .moved = position } });
        },
        .resize => |size| {
            try self.prepareEventSlots(2);
            window.size = size;
            self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .resized = size } });
            self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .configured = .{
                .logical_size = size,
                .scale_factor = geometry.ScaleFactor.init(1) catch unreachable,
            } } });
        },
        .mode => |mode| window.mode = mode,
        .always_on_top => |enabled| window.always_on_top = enabled,
    }
}

fn listDisplays(_: *anyopaque, allocator: std.mem.Allocator) Error!api.OwnedDisplays {
    const values = try allocator.alloc(api.Display, 1);
    errdefer allocator.free(values);
    const name = try allocator.dupe(u8, "Headless display");
    values[0] = .{
        .id = 1,
        .name = name,
        .bounds = geometry.Rect.fromXYWH(0, 0, 1920, 1080),
        .work_area = geometry.Rect.fromXYWH(0, 0, 1920, 1080),
        .scale_factor = geometry.ScaleFactor.init(1) catch unreachable,
        .refresh_millihertz = 60_000,
        .primary = true,
    };
    return .{ .allocator = allocator, .values = values };
}

fn nativeHandle(context: *anyopaque, id: handles.WindowId) ?api.NativeHandle {
    if (!cast(context).windows.contains(id.encode())) return null;
    return .{ .kind = .headless, .value = @intCast(id.encode()) };
}

fn readClipboard(context: *anyopaque, allocator: std.mem.Allocator) Error!?[]u8 {
    const value = cast(context).clipboard_text orelse return null;
    return try allocator.dupe(u8, value);
}

fn writeClipboard(context: *anyopaque, value: []const u8) Error!void {
    const self = cast(context);
    const replacement = try self.allocator.dupe(u8, value);
    if (self.clipboard_text) |existing| self.allocator.free(existing);
    self.clipboard_text = replacement;
}

fn readClipboardContents(context: *anyopaque, allocator: std.mem.Allocator) Error!api.ClipboardContents {
    const self = cast(context);
    return .{
        .allocator = allocator,
        .text = if (self.clipboard_text) |value| try allocator.dupe(u8, value) else null,
    };
}

fn deinit(context: *anyopaque) void {
    const self = cast(context);
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| self.retained_text.release(self.allocator, &entry.value_ptr.title);
    self.windows.deinit();
    for (self.events.items[self.event_cursor..]) |*queued| queued.deinit(self.allocator);
    self.events.deinit(self.allocator);
    if (self.clipboard_text) |value| self.allocator.free(value);
    std.debug.assert(self.retained_text.used_bytes == 0);
    const allocator = self.allocator;
    allocator.destroy(self);
}

fn clonePaths(allocator: std.mem.Allocator, source: []const []const u8) Error![][]const u8 {
    const paths = try allocator.alloc([]const u8, source.len);
    var initialized: usize = 0;
    errdefer {
        for (paths[0..initialized]) |path| allocator.free(@constCast(path));
        allocator.free(paths);
    }
    for (source, 0..) |path, index| {
        paths[index] = try allocator.dupe(u8, path);
        initialized += 1;
    }
    return paths;
}
