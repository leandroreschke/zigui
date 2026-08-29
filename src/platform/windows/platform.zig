const std = @import("std");
const config = @import("../../config.zig");
const Error = @import("../../core/error.zig").Error;
const clock = @import("../../core/clock.zig");
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const input = @import("../../input/event.zig");
const api = @import("../api.zig");
const event_memory = @import("../event_memory.zig");
const d3d11 = @import("../../backend/d3d11/renderer.zig");
const in_tree_text = if (config.text_enabled) @import("../../text/in_tree_backend.zig") else struct {};
const windows_fonts = if (config.text_enabled) @import("fonts.zig") else struct {};
const windows_a11y = if (config.accessibility_enabled) @import("accessibility.zig") else struct {
    pub const Adapter = opaque {};
};
const surface = @import("surface.zig");
const win = @import("abi.zig");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigUIWindow");

const Pending = struct {
    window: handles.WindowId,
    event: api.WindowEvent,
    owned_text: ?[]u8 = null,
    owned_paths: ?[][]const u8 = null,
    owned_bytes: usize = 0,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        if (self.owned_text) |value| allocator.free(value);
        if (self.owned_paths) |paths| {
            for (paths) |path| allocator.free(@constCast(path));
            allocator.free(paths);
        }
        self.* = undefined;
    }
};

const OwnedMenuItem = union(enum) {
    action: struct {
        label: []u8,
        action: handles.ActionId,
        payload: u64,
        command: u32,
        enabled: bool,
        checked: bool,
    },
    submenu: struct { label: []u8, items: []OwnedMenuItem },
    application: struct { items: []OwnedMenuItem },
    system_action: struct { label: []u8, action: api.SystemMenuAction },
    separator,

    fn deinit(self: *OwnedMenuItem, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .action => |definition| allocator.free(definition.label),
            .submenu => |submenu| {
                allocator.free(submenu.label);
                deinitOwnedMenuItems(allocator, submenu.items);
            },
            .application => |application| deinitOwnedMenuItems(allocator, application.items),
            .system_action => |definition| allocator.free(definition.label),
            .separator => {},
        }
        self.* = undefined;
    }
};

const NativeWindow = struct {
    context: *Context,
    id: handles.WindowId,
    hwnd: win.HWND = null,
    logical_size: geometry.Size,
    scale_factor: geometry.ScaleFactor,
    minimum_size: geometry.Size,
    maximum_size: geometry.Size,
    visible: bool,
    candidate_rect: geometry.Rect = .{},
    surrounding_text: ?[]u8 = null,
    selection: input.TextRange = .{ .start = 0, .end = 0 },
    frame_queued: bool = false,
    mouse_inside: bool = false,
    text_input_active: bool = false,
    cursor: api.Cursor = .default,
    pending_high_surrogate: ?u16 = null,
    menu: win.HMENU = null,
    ready: bool = false,
    destroying: bool = false,
    fullscreen: bool = false,
    windowed_style: isize = 0,
    windowed_ex_style: isize = 0,
    windowed_placement: win.WINDOWPLACEMENT = .{},

    fn deinit(self: *NativeWindow, context: *Context) void {
        context.retained_text.release(context.allocator, &self.surrounding_text);
        self.* = undefined;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    instance: win.HINSTANCE,
    thread_id: win.DWORD,
    performance_frequency: i64,
    windows: std.AutoHashMap(u64, *NativeWindow),
    events: std.ArrayList(Pending) = .empty,
    event_cursor: usize = 0,
    maximum_events: usize,
    maximum_windows: usize,
    maximum_event_payload_bytes: usize,
    maximum_event_queue_bytes: usize,
    maximum_file_drop_paths: usize,
    maximum_clipboard_bytes: usize,
    retained_text: event_memory.RetainedTextBudget,
    pending_payload_bytes: usize = 0,
    quit: bool = false,
    failure: ?Error = null,
    class_registered: bool = false,
    com_initialized: bool = false,
    application_items: []OwnedMenuItem = &.{},
    menu_actions: std.AutoHashMap(u32, api.MenuInvocation),
    next_menu_command: u32 = 0x1000,
    accessibility: ?*windows_a11y.Adapter = null,

    fn init(
        allocator: std.mem.Allocator,
        maximum_events: usize,
        maximum_windows: usize,
        maximum_event_payload_bytes: usize,
        maximum_event_queue_bytes: usize,
        maximum_file_drop_paths: usize,
        maximum_clipboard_bytes: usize,
        maximum_retained_text_bytes: usize,
    ) Error!*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        const instance = win.GetModuleHandleW(null) orelse return error.PlatformFailure;
        var frequency: i64 = 0;
        if (win.QueryPerformanceFrequency(&frequency) == 0 or frequency <= 0) return error.PlatformFailure;
        self.* = .{
            .allocator = allocator,
            .instance = instance,
            .thread_id = win.GetCurrentThreadId(),
            .performance_frequency = frequency,
            .windows = std.AutoHashMap(u64, *NativeWindow).init(allocator),
            .menu_actions = std.AutoHashMap(u32, api.MenuInvocation).init(allocator),
            .maximum_events = maximum_events,
            .maximum_windows = maximum_windows,
            .maximum_event_payload_bytes = maximum_event_payload_bytes,
            .maximum_event_queue_bytes = maximum_event_queue_bytes,
            .maximum_file_drop_paths = maximum_file_drop_paths,
            .maximum_clipboard_bytes = maximum_clipboard_bytes,
            .retained_text = try event_memory.RetainedTextBudget.init(maximum_retained_text_bytes),
        };
        errdefer {
            self.menu_actions.deinit();
            self.windows.deinit();
        }
        _ = win.SetProcessDpiAwarenessContext(-4);
        // Ensure this UI thread owns a Win32 message queue before another
        // thread can attempt to wake it with PostThreadMessageW.
        var queue_probe: win.MSG = undefined;
        _ = win.PeekMessageW(&queue_probe, null, 0, 0, win.PM_NOREMOVE);
        const com_result = win.CoInitializeEx(null, 2);
        if (win.succeeded(com_result)) self.com_initialized = true;
        errdefer if (self.com_initialized) win.CoUninitialize();
        const window_class: win.WNDCLASSEXW = .{
            .style = 0x0002 | 0x0001 | 0x0020,
            .window_proc = windowProcedure,
            .instance = instance,
            .cursor = win.LoadCursorW(null, 32512),
            .class_name = class_name,
        };
        if (win.RegisterClassExW(&window_class) == 0) return error.PlatformFailure;
        self.class_registered = true;
        return self;
    }

    fn deinit(self: *Context) void {
        while (self.windows.count() != 0) {
            var iterator = self.windows.iterator();
            const entry = iterator.next() orelse break;
            const native = entry.value_ptr.*;
            detachAndDestroyMenu(native);
            native.ready = false;
            native.destroying = true;
            if (native.hwnd != null) _ = win.DestroyWindow(native.hwnd);
            _ = self.windows.remove(entry.key_ptr.*);
            native.deinit(self);
            self.allocator.destroy(native);
        }
        for (self.events.items[self.event_cursor..]) |*pending| pending.deinit(self.allocator);
        self.events.deinit(self.allocator);
        deinitOwnedMenuItems(self.allocator, self.application_items);
        self.menu_actions.deinit();
        self.windows.deinit();
        if (self.class_registered) _ = win.UnregisterClassW(class_name, self.instance);
        if (self.com_initialized) win.CoUninitialize();
        std.debug.assert(self.retained_text.used_bytes == 0);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn now(self: *const Context) u64 {
        var counter: i64 = 0;
        if (win.QueryPerformanceCounter(&counter) == 0 or counter <= 0) return 0;
        const nanoseconds = (@as(u128, @intCast(counter)) * std.time.ns_per_s) / @as(u128, @intCast(self.performance_frequency));
        return @intCast(@min(nanoseconds, std.math.maxInt(u64)));
    }

    fn queue(self: *Context, id: handles.WindowId, event: api.WindowEvent) void {
        self.appendPending(.{ .window = id, .event = event }) catch |err| return self.fail(err);
        wake(self);
    }

    fn appendPending(self: *Context, pending_source: Pending) Error!void {
        var pending = pending_source;
        pending.owned_bytes = try event_memory.ownedPayloadBytes(pending.owned_text, pending.owned_paths);
        if (pending.owned_bytes > self.maximum_event_queue_bytes -| self.pending_payload_bytes)
            return error.BudgetExceeded;
        try self.preparePendingSlots(1);
        self.events.appendAssumeCapacity(pending);
        self.pending_payload_bytes += pending.owned_bytes;
    }

    fn preparePendingSlots(self: *Context, count: usize) Error!void {
        if (count == 0) return;
        if (self.event_cursor != 0 and
            (self.event_cursor >= self.maximum_events / 2 or
                count > self.maximum_events -| (self.events.items.len - self.event_cursor)))
            self.compact();
        const unread = self.events.items.len - self.event_cursor;
        if (count > self.maximum_events -| unread) return error.BudgetExceeded;
        try self.events.ensureUnusedCapacity(self.allocator, count);
    }

    fn purgeWindowEvents(self: *Context, window: handles.WindowId) void {
        var write = self.event_cursor;
        for (self.events.items[self.event_cursor..]) |pending_value| {
            var pending = pending_value;
            if (pending.window.eql(window)) {
                self.pending_payload_bytes -|= pending.owned_bytes;
                pending.deinit(self.allocator);
            } else {
                self.events.items[write] = pending;
                write += 1;
            }
        }
        self.events.items.len = write;
        if (self.event_cursor == self.events.items.len) self.compact();
    }

    fn queueText(self: *Context, id: handles.WindowId, ime: input.ImeEvent, source: []const u8) void {
        const borrowed: input.Event = .{ .ime = ime };
        self.validateInput(&borrowed) catch |err| return self.fail(err);
        _ = event_memory.ensureFits(source, null, self.pending_payload_bytes, self.maximum_event_queue_bytes) catch |err| return self.fail(err);
        const owned = self.allocator.dupe(u8, source) catch |err| return self.fail(err);
        const copied: input.ImeEvent = switch (ime) {
            .set_marked_text => |marked| .{ .set_marked_text = .{
                .text = owned,
                .selected_utf8 = marked.selected_utf8,
                .replacement_utf8 = marked.replacement_utf8,
            } },
            .commit_text => |commit| .{ .commit_text = .{ .text = owned, .replacement_utf8 = commit.replacement_utf8 } },
            else => ime,
        };
        self.appendPending(.{
            .window = id,
            .event = .{ .input = .{ .ime = copied } },
            .owned_text = owned,
        }) catch |err| {
            self.allocator.free(owned);
            return self.fail(err);
        };
        wake(self);
    }

    fn queueDrop(self: *Context, id: handles.WindowId, source: []const []const u8, position: geometry.Point) void {
        const borrowed: input.Event = .{ .file_drop_performed = .{ .paths = source, .position = position } };
        self.validateInput(&borrowed) catch |err| return self.fail(err);
        _ = event_memory.ensureFits(null, source, self.pending_payload_bytes, self.maximum_event_queue_bytes) catch |err| return self.fail(err);
        const paths = self.allocator.alloc([]const u8, source.len) catch |err| return self.fail(err);
        var initialized: usize = 0;
        for (source, 0..) |path, index| {
            paths[index] = self.allocator.dupe(u8, path) catch |err| {
                for (paths[0..initialized]) |owned| self.allocator.free(@constCast(owned));
                self.allocator.free(paths);
                return self.fail(err);
            };
            initialized += 1;
        }
        self.appendPending(.{
            .window = id,
            .event = .{ .input = .{ .file_drop_performed = .{ .paths = paths, .position = position } } },
            .owned_paths = paths,
        }) catch |err| {
            for (paths) |owned| self.allocator.free(@constCast(owned));
            self.allocator.free(paths);
            return self.fail(err);
        };
        wake(self);
    }

    fn queueAccessibility(self: *Context, request: @import("../../a11y/api.zig").ActionRequest) void {
        const borrowed: input.Event = .{ .accessibility = .{
            .target = request.target,
            .action = request.action,
            .value = request.value,
            .selection = request.selection,
        } };
        self.validateInput(&borrowed) catch |err| return self.fail(err);
        _ = event_memory.ensureFits(request.value, null, self.pending_payload_bytes, self.maximum_event_queue_bytes) catch |err| return self.fail(err);
        var copied = request;
        var owned: ?[]u8 = null;
        if (request.value) |value| {
            owned = self.allocator.dupe(u8, value) catch |err| return self.fail(err);
            copied.value = owned;
        }
        self.appendPending(.{
            .window = request.window,
            .event = .{ .accessibility_action = copied },
            .owned_text = owned,
        }) catch |err| {
            if (owned) |text| self.allocator.free(text);
            return self.fail(err);
        };
        wake(self);
    }

    fn pop(self: *Context) ?Pending {
        if (self.event_cursor >= self.events.items.len) {
            self.compact();
            return null;
        }
        const value = self.events.items[self.event_cursor];
        self.event_cursor += 1;
        if (self.event_cursor == self.events.items.len) self.compact();
        return value;
    }

    fn releasePending(self: *Context, pending: *const Pending) void {
        if (pending.owned_bytes > self.pending_payload_bytes) return self.fail(error.PlatformFailure);
        self.pending_payload_bytes -= pending.owned_bytes;
    }

    fn validateInput(self: *const Context, event: *const input.Event) Error!void {
        try input.validate(event, .{
            .maximum_payload_bytes = self.maximum_event_payload_bytes,
            .maximum_file_paths = self.maximum_file_drop_paths,
        });
    }

    fn compact(self: *Context) void {
        if (self.event_cursor == 0) return;
        const remaining = self.events.items.len - self.event_cursor;
        if (remaining != 0) std.mem.copyForwards(Pending, self.events.items[0..remaining], self.events.items[self.event_cursor..]);
        self.events.items.len = remaining;
        self.event_cursor = 0;
    }

    fn fail(self: *Context, err: anyerror) void {
        if (self.failure == null) self.failure = mapError(err);
        self.quit = true;
        wake(self);
    }
};

pub fn create(allocator: std.mem.Allocator, app_config: config.AppConfig) Error!api.Bundle {
    const context = try Context.init(
        allocator,
        app_config.memory.platform_event_count,
        app_config.memory.window_count,
        app_config.memory.platform_event_payload_bytes,
        app_config.memory.platform_event_queue_bytes,
        app_config.memory.file_drop_path_count,
        app_config.memory.clipboard_bytes,
        app_config.memory.platform_retained_text_bytes,
    );
    errdefer context.deinit();
    const renderer = try d3d11.Renderer.create(
        allocator,
        .{ .context = context, .window_fn = nativeWindow },
        app_config.gpu,
        app_config.memory,
    );
    errdefer renderer.deinit();
    const text_backend: ?@import("../../text/api.zig").Backend = if (comptime config.text_enabled) blk: {
        const instance = try in_tree_text.Backend.createInstance(
            allocator,
            app_config.memory.loaded_font_bytes,
            app_config.memory.mapped_font_bytes,
            app_config.memory.font_instance_count,
            app_config.memory.font_catalog_count,
            app_config.memory.font_catalog_bytes,
        );
        errdefer instance.interface().deinit();
        _ = try windows_fonts.discover(allocator, instance);
        break :blk instance.interface();
    } else null;
    errdefer if (text_backend) |backend| backend.deinit();
    const accessibility_adapter: ?@import("../../a11y/api.zig").Adapter = if (comptime config.accessibility_enabled) try windows_a11y.Adapter.create(
        allocator,
        .{ .context = context, .emit_fn = emitAccessibility },
        .{ .context = context, .window_fn = nativeWindow, .detach_fn = detachAccessibility },
        app_config.memory.window_count,
        app_config.memory.accessibility_node_count,
        app_config.memory.accessibility_tree_bytes,
    ) else null;
    errdefer if (accessibility_adapter) |adapter| adapter.deinit();
    if (accessibility_adapter) |adapter| context.accessibility = windows_a11y.Adapter.fromApi(adapter);
    return .{
        .event_loop = .{
            .context = context,
            .run_fn = run,
            .step_fn = step,
            .wake_fn = wake,
            .request_quit_fn = requestQuit,
            .clock = .{ .context = context, .now_fn = nowOpaque },
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
            .maximum_text_bytes = app_config.memory.platform_text_bytes,
        },
        .displays = .{
            .context = context,
            .list_fn = listDisplays,
            .maximum_count = app_config.memory.platform_object_count,
            .maximum_text_bytes = app_config.memory.platform_text_bytes,
        },
        .renderer = renderer,
        .text_backend = text_backend,
        .text_input = .{
            .context = context,
            .set_active_fn = setTextInputActive,
            .set_candidate_rect_fn = setCandidateRect,
            .set_surrounding_text_fn = setSurroundingText,
            .maximum_surrounding_text_bytes = app_config.memory.platform_text_bytes,
        },
        .accessibility = accessibility_adapter,
        .clipboard = .{
            .context = context,
            .read_text_fn = readClipboard,
            .write_text_fn = writeClipboard,
            .maximum_bytes = app_config.memory.clipboard_bytes,
        },
        .menus = .{
            .context = context,
            .set_application_menu_fn = setApplicationMenu,
            .show_context_menu_fn = showContextMenu,
            .limits = .{
                .maximum_items = app_config.memory.menu_item_count,
                .maximum_depth = app_config.memory.menu_depth,
                .maximum_text_bytes = app_config.memory.menu_text_bytes,
            },
        },
        .dialogs = .{
            .context = context,
            .open_files_fn = openFiles,
            .save_file_fn = saveFile,
            .limits = .{
                .maximum_paths = app_config.memory.file_drop_path_count,
                .maximum_path_bytes = app_config.memory.platform_event_payload_bytes,
                .maximum_suggested_name_bytes = app_config.memory.platform_text_bytes,
            },
        },
        .deinit_context = context,
        .deinit_fn = deinitContext,
    };
}

fn cast(raw: *anyopaque) *Context {
    return @ptrCast(@alignCast(raw));
}

fn run(raw: *anyopaque, sink: api.EventSink) Error!void {
    const self = cast(raw);
    self.quit = false;
    while (!self.quit) {
        _ = try step(raw, sink, true);
        sink.pump();
    }
    if (self.failure) |failure| {
        return failure;
    }
}

fn step(raw: *anyopaque, sink: api.EventSink, wait_for_event: bool) Error!bool {
    const self = cast(raw);
    if (self.failure) |failure| {
        return failure;
    }
    if (self.quit) return false;
    if (self.pop()) |pending_value| {
        var pending = pending_value;
        defer pending.deinit(self.allocator);
        defer self.releasePending(&pending);
        sink.send(pending.window, &pending.event);
        return true;
    }
    var message: win.MSG = undefined;
    if (wait_for_event) {
        const result = win.GetMessageW(&message, null, 0, 0);
        if (result == -1) return error.PlatformFailure;
        if (result == 0) {
            self.quit = true;
            return false;
        }
    } else if (win.PeekMessageW(&message, null, 0, 0, win.PM_REMOVE) == 0) return false;
    if (message.message != win.WM_ZIGUI_WAKE) {
        _ = win.TranslateMessage(&message);
        _ = win.DispatchMessageW(&message);
    }
    if (self.pop()) |pending_value| {
        var pending = pending_value;
        defer pending.deinit(self.allocator);
        defer self.releasePending(&pending);
        sink.send(pending.window, &pending.event);
    }
    return true;
}

fn wake(raw: *anyopaque) void {
    const self = cast(raw);
    _ = win.PostThreadMessageW(self.thread_id, win.WM_ZIGUI_WAKE, 0, 0);
}

fn requestQuit(raw: *anyopaque) void {
    const self = cast(raw);
    self.quit = true;
    wake(raw);
}

fn nowOpaque(raw: *anyopaque) clock.Timestamp {
    return cast(raw).now();
}

fn createWindow(raw: *anyopaque, id: handles.WindowId, options: api.WindowOptions) Error!api.NativeHandle {
    const self = cast(raw);
    if (self.windows.contains(id.encode())) return error.ResourceBusy;
    if (self.windows.count() >= self.maximum_windows) return error.BudgetExceeded;
    try self.windows.ensureUnusedCapacity(1);
    try self.preparePendingSlots(2);
    const title = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, options.title);
    defer self.allocator.free(title);
    const scale = geometry.ScaleFactor.init(1) catch unreachable;
    const native = try self.allocator.create(NativeWindow);
    var native_owned = true;
    errdefer if (native_owned) self.allocator.destroy(native);
    native.* = .{
        .context = self,
        .id = id,
        .logical_size = options.size,
        .scale_factor = scale,
        .minimum_size = options.minimum_size,
        .maximum_size = options.maximum_size,
        .visible = options.visible,
    };
    var style: win.DWORD = if (options.decorated) win.WS_CAPTION | win.WS_SYSMENU | win.WS_MINIMIZEBOX else win.WS_POPUP;
    if (options.resizable) style |= win.WS_THICKFRAME | win.WS_MAXIMIZEBOX;
    var ex_style: win.DWORD = win.WS_EX_APPWINDOW;
    if (options.transparent) ex_style |= win.WS_EX_LAYERED;
    if (options.always_on_top) ex_style |= win.WS_EX_TOPMOST;
    var frame: win.RECT = .{
        .right = positiveI32(options.size.width),
        .bottom = positiveI32(options.size.height),
    };
    const menu = if (self.application_items.len == 0) null else try buildOwnedMenu(self.allocator, self.application_items, false);
    var menu_owned = menu != null;
    errdefer {
        if (menu_owned) _ = win.DestroyMenu(menu);
    }
    if (win.AdjustWindowRectEx(&frame, style, if (menu != null) 1 else 0, ex_style) == 0) return error.PlatformFailure;
    const x = if (options.position) |position| saturatedI32(position.x) else win.CW_USEDEFAULT;
    const y = if (options.position) |position| saturatedI32(position.y) else win.CW_USEDEFAULT;
    const hwnd = win.CreateWindowExW(
        ex_style,
        class_name,
        title,
        style,
        x,
        y,
        frame.right - frame.left,
        frame.bottom - frame.top,
        null,
        menu,
        self.instance,
        native,
    ) orelse return error.PlatformFailure;
    native.hwnd = hwnd;
    native.menu = menu;
    native.scale_factor = dpiScale(hwnd);
    self.windows.putAssumeCapacity(id.encode(), native);
    native_owned = false;
    menu_owned = false;
    native.ready = true;
    var published = true;
    errdefer if (published) {
        self.purgeWindowEvents(id);
        native.ready = false;
        native.destroying = true;
        detachAndDestroyMenu(native);
        if (native.hwnd != null) _ = win.DestroyWindow(native.hwnd);
        _ = self.windows.remove(id.encode());
        native.deinit(self);
        self.allocator.destroy(native);
    };
    win.DragAcceptFiles(hwnd, 1);
    const handle: api.NativeHandle = .{ .kind = .win32, .value = @intFromPtr(hwnd) };
    try self.appendPending(.{ .window = id, .event = .{ .created = handle } });
    try self.appendPending(.{ .window = id, .event = .{ .configured = .{ .logical_size = clientLogicalSize(hwnd, native.scale_factor), .scale_factor = native.scale_factor } } });
    if (options.visible) {
        try requestFrame(raw, id);
        _ = win.ShowWindow(hwnd, win.SW_SHOWNORMAL);
        _ = win.UpdateWindow(hwnd);
    }
    wake(self);
    published = false;
    return handle;
}

fn destroyWindow(raw: *anyopaque, id: handles.WindowId) void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return;
    native.ready = false;
    native.destroying = true;
    detachAndDestroyMenu(native);
    if (native.hwnd != null) _ = win.DestroyWindow(native.hwnd);
    _ = self.windows.remove(id.encode());
    native.deinit(self);
    self.allocator.destroy(native);
}

fn showWindow(raw: *anyopaque, id: handles.WindowId, visible: bool) Error!void {
    const native = cast(raw).windows.get(id.encode()) orelse return error.InvalidHandle;
    if (native.visible == visible) return;
    if (visible) {
        native.visible = true;
        errdefer native.visible = false;
        try requestFrame(raw, id);
        _ = win.ShowWindow(native.hwnd, win.SW_SHOW);
    } else {
        _ = win.ShowWindow(native.hwnd, win.SW_HIDE);
        native.visible = false;
        native.frame_queued = false;
    }
}

fn titleWindow(raw: *anyopaque, id: handles.WindowId, title_value: []const u8) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    const title = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, title_value);
    defer self.allocator.free(title);
    if (win.SetWindowTextW(native.hwnd, title) == 0) return error.PlatformFailure;
}

fn requestFrame(raw: *anyopaque, id: handles.WindowId) Error!void {
    const native = cast(raw).windows.get(id.encode()) orelse return error.InvalidHandle;
    if (!native.visible) return;
    if (native.frame_queued) return;
    native.frame_queued = true;
    errdefer native.frame_queued = false;
    if (win.InvalidateRect(native.hwnd, null, 0) == 0) return error.PlatformFailure;
}

fn setCursor(raw: *anyopaque, id: handles.WindowId, cursor: api.Cursor) Error!void {
    const native = cast(raw).windows.get(id.encode()) orelse return error.InvalidHandle;
    native.cursor = cursor;
    _ = win.SetCursor(cursorHandle(cursor));
}

fn commandWindow(raw: *anyopaque, id: handles.WindowId, command: api.WindowCommand) Error!void {
    const native = cast(raw).windows.get(id.encode()) orelse return error.InvalidHandle;
    switch (command) {
        .move => |position| {
            if (native.fullscreen) try leaveFullscreen(native);
            if (win.SetWindowPos(
                native.hwnd,
                null,
                saturatedI32(position.x),
                saturatedI32(position.y),
                0,
                0,
                win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOACTIVATE,
            ) == 0) return error.PlatformFailure;
        },
        .resize => |size| {
            if (native.fullscreen) try leaveFullscreen(native);
            var frame: win.RECT = .{
                .right = positiveI32(@as(f64, size.width) * native.scale_factor.value),
                .bottom = positiveI32(@as(f64, size.height) * native.scale_factor.value),
            };
            const style: u32 = @truncate(@as(usize, @bitCast(win.GetWindowLongPtrW(native.hwnd, win.GWL_STYLE))));
            const ex_style: u32 = @truncate(@as(usize, @bitCast(win.GetWindowLongPtrW(native.hwnd, win.GWL_EXSTYLE))));
            if (win.AdjustWindowRectEx(&frame, style, if (native.menu != null) 1 else 0, ex_style) == 0) return error.PlatformFailure;
            if (win.SetWindowPos(
                native.hwnd,
                null,
                0,
                0,
                frame.right - frame.left,
                frame.bottom - frame.top,
                win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE,
            ) == 0) return error.PlatformFailure;
        },
        .mode => |mode| switch (mode) {
            .normal => {
                if (native.fullscreen) try leaveFullscreen(native);
                _ = win.ShowWindow(native.hwnd, win.SW_RESTORE);
            },
            .minimized => {
                if (native.fullscreen) try leaveFullscreen(native);
                _ = win.ShowWindow(native.hwnd, win.SW_MINIMIZE);
            },
            .maximized => {
                if (native.fullscreen) try leaveFullscreen(native);
                _ = win.ShowWindow(native.hwnd, win.SW_SHOWMAXIMIZED);
            },
            .fullscreen => try enterFullscreen(native),
        },
        .always_on_top => |enabled| {
            const insert_after = if (enabled) win.HWND_TOPMOST else win.HWND_NOTOPMOST;
            if (win.SetWindowPos(native.hwnd, insert_after, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE) == 0) return error.PlatformFailure;
        },
    }
}

fn enterFullscreen(native: *NativeWindow) Error!void {
    if (native.fullscreen) return;
    native.windowed_placement = .{};
    if (win.GetWindowPlacement(native.hwnd, &native.windowed_placement) == 0) return error.PlatformFailure;
    native.windowed_style = win.GetWindowLongPtrW(native.hwnd, win.GWL_STYLE);
    native.windowed_ex_style = win.GetWindowLongPtrW(native.hwnd, win.GWL_EXSTYLE);
    const monitor = win.MonitorFromWindow(native.hwnd, win.MONITOR_DEFAULTTONEAREST) orelse return error.PlatformFailure;
    var info: win.MONITORINFOEXW = .{};
    if (win.GetMonitorInfoW(monitor, &info) == 0) return error.PlatformFailure;
    const decoration_mask: isize = @intCast(win.WS_CAPTION | win.WS_SYSMENU | win.WS_THICKFRAME | win.WS_MINIMIZEBOX | win.WS_MAXIMIZEBOX);
    _ = win.SetWindowLongPtrW(native.hwnd, win.GWL_STYLE, native.windowed_style & ~decoration_mask);
    if (win.SetWindowPos(
        native.hwnd,
        null,
        info.monitor.left,
        info.monitor.top,
        info.monitor.right - info.monitor.left,
        info.monitor.bottom - info.monitor.top,
        win.SWP_NOZORDER | win.SWP_FRAMECHANGED,
    ) == 0) return error.PlatformFailure;
    native.fullscreen = true;
}

fn leaveFullscreen(native: *NativeWindow) Error!void {
    if (!native.fullscreen) return;
    _ = win.SetWindowLongPtrW(native.hwnd, win.GWL_STYLE, native.windowed_style);
    _ = win.SetWindowLongPtrW(native.hwnd, win.GWL_EXSTYLE, native.windowed_ex_style);
    if (win.SetWindowPlacement(native.hwnd, &native.windowed_placement) == 0) return error.PlatformFailure;
    if (win.SetWindowPos(native.hwnd, null, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOACTIVATE | win.SWP_FRAMECHANGED) == 0)
        return error.PlatformFailure;
    native.fullscreen = false;
}

const DisplayCollector = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(api.Display) = .empty,
    failure: ?Error = null,

    fn deinit(self: *DisplayCollector) void {
        for (self.values.items) |display| self.allocator.free(@constCast(display.name));
        self.values.deinit(self.allocator);
    }
};

fn listDisplays(_: *anyopaque, allocator: std.mem.Allocator) Error!api.OwnedDisplays {
    var collector: DisplayCollector = .{ .allocator = allocator };
    errdefer collector.deinit();
    const pointer_bits: usize = @intFromPtr(&collector);
    if (win.EnumDisplayMonitors(null, null, collectDisplay, @bitCast(pointer_bits)) == 0) return error.PlatformFailure;
    if (collector.failure) |failure| return failure;
    if (collector.values.items.len == 0) return error.MissingCapability;
    return .{ .allocator = allocator, .values = try collector.values.toOwnedSlice(allocator) };
}

fn collectDisplay(monitor: win.HMONITOR, _: win.HDC, _: *win.RECT, data: win.LPARAM) callconv(.winapi) win.BOOL {
    const pointer_bits: usize = @bitCast(data);
    const collector: *DisplayCollector = @ptrFromInt(pointer_bits);
    var info: win.MONITORINFOEXW = .{};
    if (win.GetMonitorInfoW(monitor, &info) == 0) {
        collector.failure = error.PlatformFailure;
        return 0;
    }
    const name_length = std.mem.indexOfScalar(u16, &info.device, 0) orelse info.device.len;
    const name = std.unicode.wtf16LeToWtf8Alloc(collector.allocator, info.device[0..name_length]) catch |err| {
        collector.failure = err;
        return 0;
    };
    var dpi_x: win.UINT = 96;
    var dpi_y: win.UINT = 96;
    if (!win.succeeded(win.GetDpiForMonitor(monitor, 0, &dpi_x, &dpi_y)) or dpi_x == 0) dpi_x = 96;
    collector.values.append(collector.allocator, .{
        .id = @intFromPtr(monitor.?),
        .name = name,
        .bounds = winRect(info.monitor),
        .work_area = winRect(info.work),
        .scale_factor = geometry.ScaleFactor.init(@as(f32, @floatFromInt(dpi_x)) / 96) catch unreachable,
        .primary = info.flags & win.MONITORINFOF_PRIMARY != 0,
    }) catch |err| {
        collector.allocator.free(name);
        collector.failure = err;
        return 0;
    };
    return 1;
}

fn winRect(value: win.RECT) geometry.Rect {
    return geometry.Rect.fromXYWH(
        @floatFromInt(value.left),
        @floatFromInt(value.top),
        @floatFromInt(value.right - value.left),
        @floatFromInt(value.bottom - value.top),
    );
}

fn nativeHandle(raw: *anyopaque, id: handles.WindowId) ?api.NativeHandle {
    const native = cast(raw).windows.get(id.encode()) orelse return null;
    return .{ .kind = .win32, .value = @intFromPtr(native.hwnd.?) };
}

fn nativeWindow(raw: *anyopaque, id: handles.WindowId) win.HWND {
    const native = cast(raw).windows.get(id.encode()) orelse return null;
    return native.hwnd;
}

fn emitAccessibility(raw: *anyopaque, request: @import("../../a11y/api.zig").ActionRequest) void {
    cast(raw).queueAccessibility(request);
}

fn detachAccessibility(raw: *anyopaque, adapter: *windows_a11y.Adapter) void {
    const context = cast(raw);
    if (context.accessibility == adapter) context.accessibility = null;
}

fn setTextInputActive(raw: *anyopaque, id: handles.WindowId, active: bool) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (win.ImmAssociateContextEx(native.hwnd, null, if (active) win.IACE_DEFAULT else win.IACE_CHILDREN) == 0 and active)
        return error.PlatformFailure;
    native.text_input_active = active;
    if (!active) {
        self.retained_text.release(self.allocator, &native.surrounding_text);
        native.selection = .{ .start = 0, .end = 0 };
    }
}

fn setCandidateRect(raw: *anyopaque, id: handles.WindowId, rect: geometry.Rect) Error!void {
    const native = cast(raw).windows.get(id.encode()) orelse return error.InvalidHandle;
    native.candidate_rect = rect;
    const ime = win.ImmGetContext(native.hwnd) orelse return;
    defer _ = win.ImmReleaseContext(native.hwnd, ime);
    const scale = native.scale_factor.value;
    const point: win.POINT = .{
        .x = saturatedI32(@as(f64, rect.origin.x) * scale),
        .y = saturatedI32((@as(f64, rect.origin.y) + rect.size.height) * scale),
    };
    const composition: win.COMPOSITIONFORM = .{ .style = win.CFS_POINT, .current_pos = point, .area = .{} };
    _ = win.ImmSetCompositionWindow(ime, &composition);
    const candidate: win.CANDIDATEFORM = .{ .index = 0, .style = win.CFS_EXCLUDE, .current_pos = point, .area = .{
        .left = saturatedI32(@floor(@as(f64, rect.origin.x) * scale)),
        .top = saturatedI32(@floor(@as(f64, rect.origin.y) * scale)),
        .right = saturatedI32(@ceil((@as(f64, rect.origin.x) + rect.size.width) * scale)),
        .bottom = saturatedI32(@ceil((@as(f64, rect.origin.y) + rect.size.height) * scale)),
    } };
    _ = win.ImmSetCandidateWindow(ime, &candidate);
}

fn setSurroundingText(raw: *anyopaque, id: handles.WindowId, text: []const u8, selection: input.TextRange) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (selection.start > text.len or selection.end > text.len) return error.InvalidConfiguration;
    try self.retained_text.replace(self.allocator, &native.surrounding_text, text);
    native.selection = selection;
}

fn readClipboard(raw: *anyopaque, allocator: std.mem.Allocator) Error!?[]u8 {
    const self = cast(raw);
    if (win.OpenClipboard(null) == 0) return error.ResourceBusy;
    defer _ = win.CloseClipboard();
    const memory = win.GetClipboardData(win.CF_UNICODETEXT) orelse return null;
    const byte_count = win.GlobalSize(memory);
    if (byte_count == 0 or byte_count % @sizeOf(u16) != 0) return error.PlatformFailure;
    if (byte_count / @sizeOf(u16) > self.maximum_clipboard_bytes) return error.BudgetExceeded;
    const pointer = win.GlobalLock(memory) orelse return error.PlatformFailure;
    defer _ = win.GlobalUnlock(memory);
    const source: [*]const u16 = @ptrCast(@alignCast(pointer));
    const bounded = source[0 .. byte_count / @sizeOf(u16)];
    const end = std.mem.indexOfScalar(u16, bounded, 0) orelse return error.InvalidUtf8;
    _ = try utf16Utf8Length(bounded[0..end], self.maximum_clipboard_bytes);
    return try utf16ToUtf8Alloc(allocator, bounded[0..end]);
}

fn utf16ToUtf8Alloc(allocator: std.mem.Allocator, units: []const u16) Error![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf8,
    };
}

fn utf16Utf8Length(units: []const u16, maximum: usize) Error!usize {
    var result: usize = 0;
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        const amount: usize = if (unit >= 0xd800 and unit <= 0xdbff) block: {
            if (index + 1 >= units.len or units[index + 1] < 0xdc00 or units[index + 1] > 0xdfff)
                return error.InvalidUtf8;
            index += 2;
            break :block 4;
        } else if (unit >= 0xdc00 and unit <= 0xdfff) return error.InvalidUtf8 else block: {
            index += 1;
            break :block if (unit <= 0x7f) 1 else if (unit <= 0x7ff) 2 else 3;
        };
        if (amount > maximum -| result) return error.BudgetExceeded;
        result += amount;
    }
    return result;
}

fn writeClipboard(raw: *anyopaque, text: []const u8) Error!void {
    const self = cast(raw);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, text);
    defer self.allocator.free(wide);
    if (win.OpenClipboard(null) == 0) return error.ResourceBusy;
    defer _ = win.CloseClipboard();
    if (win.EmptyClipboard() == 0) return error.PlatformFailure;
    const bytes = wide.len * @sizeOf(u16) + @sizeOf(u16);
    const memory = win.GlobalAlloc(win.GMEM_MOVEABLE | win.GMEM_ZEROINIT, bytes) orelse return error.OutOfMemory;
    errdefer _ = win.GlobalFree(memory);
    const pointer = win.GlobalLock(memory) orelse return error.PlatformFailure;
    const destination: [*]u16 = @ptrCast(@alignCast(pointer));
    @memcpy(destination[0..wide.len], wide);
    destination[wide.len] = 0;
    _ = win.GlobalUnlock(memory);
    if (win.SetClipboardData(win.CF_UNICODETEXT, memory) == null) return error.PlatformFailure;
}

fn setApplicationMenu(raw: *anyopaque, items: []const api.MenuItem) Error!void {
    const self = cast(raw);
    var actions = std.AutoHashMap(u32, api.MenuInvocation).init(self.allocator);
    errdefer actions.deinit();
    var next: u32 = 0x1000;
    const owned = try cloneMenuItems(self.allocator, items, &actions, &next);
    errdefer deinitOwnedMenuItems(self.allocator, owned);

    const Replacement = struct { window: *NativeWindow, menu: win.HMENU };
    var replacements: std.ArrayList(Replacement) = .empty;
    defer replacements.deinit(self.allocator);
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        const menu = if (owned.len == 0) null else try buildOwnedMenu(self.allocator, owned, false);
        errdefer {
            if (menu != null) _ = win.DestroyMenu(menu);
        }
        try replacements.append(self.allocator, .{ .window = entry.value_ptr.*, .menu = menu });
    }

    var installed: usize = 0;
    while (installed < replacements.items.len) : (installed += 1) {
        const replacement = replacements.items[installed];
        if (win.SetMenu(replacement.window.hwnd, replacement.menu) == 0) {
            for (replacements.items[0..installed]) |rollback| {
                _ = win.SetMenu(rollback.window.hwnd, rollback.window.menu);
                _ = win.DrawMenuBar(rollback.window.hwnd);
            }
            return error.PlatformFailure;
        }
        _ = win.DrawMenuBar(replacement.window.hwnd);
    }
    for (replacements.items) |replacement| {
        if (replacement.window.menu != null) _ = win.DestroyMenu(replacement.window.menu);
        replacement.window.menu = replacement.menu;
    }

    deinitOwnedMenuItems(self.allocator, self.application_items);
    self.menu_actions.deinit();
    self.menu_actions = actions;
    self.application_items = owned;
    self.next_menu_command = next;
}

fn cloneMenuItems(
    allocator: std.mem.Allocator,
    source: []const api.MenuItem,
    actions: *std.AutoHashMap(u32, api.MenuInvocation),
    next: *u32,
) Error![]OwnedMenuItem {
    const result = try allocator.alloc(OwnedMenuItem, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*item| item.deinit(allocator);
        allocator.free(result);
    }
    for (source, 0..) |item, index| {
        result[index] = switch (item) {
            .separator => .separator,
            .action => |definition| action: {
                if (next.* > 0xffff) return error.OutOfSlots;
                const command = next.*;
                next.* += 1;
                const label = try allocator.dupe(u8, definition.label);
                errdefer allocator.free(label);
                try actions.put(command, .{ .action = definition.action, .payload = definition.payload });
                break :action .{ .action = .{
                    .label = label,
                    .action = definition.action,
                    .payload = definition.payload,
                    .command = command,
                    .enabled = definition.enabled,
                    .checked = definition.checked,
                } };
            },
            .submenu => |submenu| submenu_result: {
                const label = try allocator.dupe(u8, submenu.label);
                errdefer allocator.free(label);
                const children = try cloneMenuItems(allocator, submenu.items, actions, next);
                break :submenu_result .{ .submenu = .{ .label = label, .items = children } };
            },
            .application => |application| application_result: {
                const children = try cloneMenuItems(allocator, application.items, actions, next);
                break :application_result .{ .application = .{ .items = children } };
            },
            .system_action => |definition| .{ .system_action = .{ .label = try allocator.dupe(u8, definition.label), .action = definition.action } },
        };
        initialized += 1;
    }
    return result;
}

fn deinitOwnedMenuItems(allocator: std.mem.Allocator, items: []OwnedMenuItem) void {
    for (items) |*item| item.deinit(allocator);
    if (items.len != 0) allocator.free(items);
}

fn buildOwnedMenu(allocator: std.mem.Allocator, items: []const OwnedMenuItem, popup: bool) Error!win.HMENU {
    const menu = if (popup) win.CreatePopupMenu() else win.CreateMenu();
    if (menu == null) return error.PlatformFailure;
    errdefer _ = win.DestroyMenu(menu);
    for (items) |item| switch (item) {
        .separator => if (win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null) == 0) return error.PlatformFailure,
        .action => |definition| {
            const label = try std.unicode.utf8ToUtf16LeAllocZ(allocator, definition.label);
            defer allocator.free(label);
            var flags = win.MF_STRING;
            if (!definition.enabled) flags |= win.MF_GRAYED;
            if (definition.checked) flags |= win.MF_CHECKED;
            if (win.AppendMenuW(menu, flags, definition.command, label) == 0) return error.PlatformFailure;
        },
        .submenu => |submenu| {
            const child = try buildOwnedMenu(allocator, submenu.items, true);
            const label = try std.unicode.utf8ToUtf16LeAllocZ(allocator, submenu.label);
            defer allocator.free(label);
            if (win.AppendMenuW(menu, win.MF_POPUP, @intFromPtr(child.?), label) == 0) {
                _ = win.DestroyMenu(child);
                return error.PlatformFailure;
            }
        },
        .application => |application| {
            const child = try buildOwnedMenu(allocator, application.items, true);
            const label = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "Application");
            defer allocator.free(label);
            if (win.AppendMenuW(menu, win.MF_POPUP, @intFromPtr(child.?), label) == 0) {
                _ = win.DestroyMenu(child);
                return error.PlatformFailure;
            }
        },
        .system_action => return error.Unsupported,
    };
    return menu;
}

fn detachAndDestroyMenu(window: *NativeWindow) void {
    if (window.menu == null) return;
    if (window.hwnd != null) {
        _ = win.SetMenu(window.hwnd, null);
        _ = win.DrawMenuBar(window.hwnd);
    }
    _ = win.DestroyMenu(window.menu);
    window.menu = null;
}

fn showContextMenu(raw: *anyopaque, id: handles.WindowId, point: geometry.Point, items: []const api.MenuItem) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    var actions = std.AutoHashMap(u32, api.MenuInvocation).init(self.allocator);
    defer actions.deinit();
    var next: u32 = 1;
    const menu = try buildMenu(self.allocator, items, &actions, &next, true);
    defer _ = win.DestroyMenu(menu);
    var screen = win.POINT{
        .x = saturatedI32(@as(f64, point.x) * native.scale_factor.value),
        .y = saturatedI32(@as(f64, point.y) * native.scale_factor.value),
    };
    if (win.ClientToScreen(native.hwnd, &screen) == 0) return error.PlatformFailure;
    const command = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_RIGHTBUTTON, screen.x, screen.y, 0, native.hwnd, null);
    if (actions.get(command)) |invocation| self.queue(id, .{ .menu_action = invocation });
}

fn buildMenu(
    allocator: std.mem.Allocator,
    items: []const api.MenuItem,
    actions: *std.AutoHashMap(u32, api.MenuInvocation),
    next: *u32,
    popup: bool,
) Error!win.HMENU {
    const menu = if (popup) win.CreatePopupMenu() else win.CreateMenu();
    if (menu == null) return error.PlatformFailure;
    errdefer _ = win.DestroyMenu(menu);
    for (items) |item| switch (item) {
        .separator => if (win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null) == 0) return error.PlatformFailure,
        .action => |definition| {
            if (next.* > 0xffff) return error.OutOfSlots;
            const command = next.*;
            next.* += 1;
            try actions.put(command, .{ .action = definition.action, .payload = definition.payload });
            const label = try std.unicode.utf8ToUtf16LeAllocZ(allocator, definition.label);
            defer allocator.free(label);
            var flags = win.MF_STRING;
            if (!definition.enabled) flags |= win.MF_GRAYED;
            if (definition.checked) flags |= win.MF_CHECKED;
            if (win.AppendMenuW(menu, flags, command, label) == 0) return error.PlatformFailure;
        },
        .submenu => |submenu| {
            const child = try buildMenu(allocator, submenu.items, actions, next, true);
            const label = try std.unicode.utf8ToUtf16LeAllocZ(allocator, submenu.label);
            defer allocator.free(label);
            if (win.AppendMenuW(menu, win.MF_POPUP, @intFromPtr(child.?), label) == 0) {
                _ = win.DestroyMenu(child);
                return error.PlatformFailure;
            }
        },
        .application => |application| {
            const child = try buildMenu(allocator, application.items, actions, next, true);
            const label = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "Application");
            defer allocator.free(label);
            if (win.AppendMenuW(menu, win.MF_POPUP, @intFromPtr(child.?), label) == 0) {
                _ = win.DestroyMenu(child);
                return error.PlatformFailure;
            }
        },
        .system_action => return error.Unsupported,
    };
    return menu;
}

fn openFiles(raw: *anyopaque, id: handles.WindowId, multiple: bool, allocator: std.mem.Allocator) Error!api.OwnedPaths {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    const buffer = try allocator.alloc(u16, 65_536);
    defer allocator.free(buffer);
    @memset(buffer, 0);
    var options: win.OPENFILENAMEW = .{
        .owner = native.hwnd,
        .file = buffer.ptr,
        .max_file = @intCast(buffer.len),
        .flags = win.OFN_EXPLORER | win.OFN_FILEMUSTEXIST | win.OFN_PATHMUSTEXIST |
            (if (multiple) win.OFN_ALLOWMULTISELECT else 0),
    };
    if (win.GetOpenFileNameW(&options) == 0) return .{ .allocator = allocator, .values = try allocator.alloc([]const u8, 0) };
    var fields: std.ArrayList([]const u16) = .empty;
    defer fields.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < buffer.len and buffer[cursor] != 0) {
        const start = cursor;
        while (cursor < buffer.len and buffer[cursor] != 0) cursor += 1;
        try fields.append(allocator, buffer[start..cursor]);
        cursor += 1;
    }
    if (fields.items.len == 0) return .{ .allocator = allocator, .values = try allocator.alloc([]const u8, 0) };
    const count = if (fields.items.len == 1) 1 else fields.items.len - 1;
    const paths = try allocator.alloc([]const u8, count);
    var initialized: usize = 0;
    errdefer {
        for (paths[0..initialized]) |path| allocator.free(@constCast(path));
        allocator.free(paths);
    }
    if (fields.items.len == 1) {
        paths[0] = try utf16ToUtf8Alloc(allocator, fields.items[0]);
        initialized = 1;
    } else {
        const directory = try utf16ToUtf8Alloc(allocator, fields.items[0]);
        defer allocator.free(directory);
        for (fields.items[1..], 0..) |name_wide, index| {
            const name = try utf16ToUtf8Alloc(allocator, name_wide);
            defer allocator.free(name);
            paths[index] = try std.fs.path.join(allocator, &.{ directory, name });
            initialized += 1;
        }
    }
    return .{ .allocator = allocator, .values = paths };
}

fn saveFile(raw: *anyopaque, id: handles.WindowId, suggested: []const u8, allocator: std.mem.Allocator) Error!?api.OwnedPath {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    const buffer = try allocator.alloc(u16, 65_536);
    defer allocator.free(buffer);
    @memset(buffer, 0);
    const suggested_wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, suggested);
    defer allocator.free(suggested_wide);
    const copied = @min(suggested_wide.len, buffer.len - 1);
    @memcpy(buffer[0..copied], suggested_wide[0..copied]);
    var options: win.OPENFILENAMEW = .{
        .owner = native.hwnd,
        .file = buffer.ptr,
        .max_file = @intCast(buffer.len),
        .flags = win.OFN_EXPLORER | win.OFN_PATHMUSTEXIST | win.OFN_OVERWRITEPROMPT,
    };
    if (win.GetSaveFileNameW(&options) == 0) return null;
    const length = std.mem.indexOfScalar(u16, buffer, 0) orelse buffer.len;
    return .{ .allocator = allocator, .value = try utf16ToUtf8Alloc(allocator, buffer[0..length]) };
}

fn deinitContext(raw: *anyopaque) void {
    cast(raw).deinit();
}

fn windowProcedure(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    var native: ?*NativeWindow = if (win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA) == 0) null else @ptrFromInt(@as(usize, @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))));
    if (message == win.WM_NCCREATE) {
        const create_info: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        native = @ptrCast(@alignCast(create_info.create_params orelse return 0));
        native.?.hwnd = hwnd;
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(native.?)));
    }
    const window = native orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    const self = window.context;
    if (!window.ready and message != win.WM_GETMINMAXINFO and message != win.WM_NCDESTROY)
        return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win.WM_GETOBJECT => {
            if (self.accessibility) |adapter| {
                if (adapter.handleGetObject(window.id, hwnd, wparam, lparam)) |result| return result;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_CLOSE => {
            self.queue(window.id, .close_requested);
            return 0;
        },
        win.WM_DESTROY => {
            if (!window.destroying) {
                detachAndDestroyMenu(window);
                self.purgeWindowEvents(window.id);
            }
            self.queue(window.id, .closed);
            return 0;
        },
        win.WM_NCDESTROY => {
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, 0);
            if (!window.destroying) {
                if (self.windows.get(window.id.encode())) |registered| {
                    if (registered != window) return win.DefWindowProcW(hwnd, message, wparam, lparam);
                    _ = self.windows.remove(window.id.encode());
                    window.deinit(self);
                    self.allocator.destroy(window);
                }
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_PAINT => {
            var paint: win.PAINTSTRUCT = undefined;
            _ = win.BeginPaint(hwnd, &paint);
            _ = win.EndPaint(hwnd, &paint);
            // Win32 also generates WM_PAINT when previously covered content
            // becomes visible. Always publish that paint: App uses it to
            // resume a dirty window after DXGI_STATUS_OCCLUDED without polling
            // Present in a hot loop.
            window.frame_queued = false;
            self.queue(window.id, .{ .frame_requested = self.now() });
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_SIZE => {
            window.logical_size = clientLogicalSize(hwnd, window.scale_factor);
            self.queue(window.id, .{ .resized = window.logical_size });
            return 0;
        },
        win.WM_MOVE => {
            self.queue(window.id, .{ .moved = .{
                .x = @as(f32, @floatFromInt(win.signedLowWord(@bitCast(lparam)))) / window.scale_factor.value,
                .y = @as(f32, @floatFromInt(win.signedHighWord(@bitCast(lparam)))) / window.scale_factor.value,
            } });
            return 0;
        },
        win.WM_DPICHANGED => {
            const dpi: u32 = win.lowWord(wparam);
            window.scale_factor = geometry.ScaleFactor.init(@as(f32, @floatFromInt(dpi)) / 96.0) catch return 0;
            const suggested: *const win.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = win.SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, win.SWP_NOZORDER | win.SWP_NOACTIVATE);
            self.queue(window.id, .{ .scale_changed = window.scale_factor });
            return 0;
        },
        win.WM_SETFOCUS => {
            self.queue(window.id, .{ .focused = true });
            return 0;
        },
        win.WM_KILLFOCUS => {
            self.queue(window.id, .{ .focused = false });
            return 0;
        },
        win.WM_GETMINMAXINFO => {
            const info: *win.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const scale = window.scale_factor.value;
            if (window.minimum_size.width > 0) info.min_track_size.x = positiveI32(@as(f64, window.minimum_size.width) * scale);
            if (window.minimum_size.height > 0) info.min_track_size.y = positiveI32(@as(f64, window.minimum_size.height) * scale);
            if (std.math.isFinite(window.maximum_size.width)) info.max_track_size.x = positiveI32(@as(f64, window.maximum_size.width) * scale);
            if (std.math.isFinite(window.maximum_size.height)) info.max_track_size.y = positiveI32(@as(f64, window.maximum_size.height) * scale);
            return 0;
        },
        win.WM_SETCURSOR => {
            _ = win.SetCursor(cursorHandle(window.cursor));
            return 1;
        },
        win.WM_MOUSEMOVE => {
            if (!window.mouse_inside) {
                window.mouse_inside = true;
                var tracking: win.TRACKMOUSEEVENT = .{ .flags = win.TME_LEAVE, .hwnd_track = hwnd };
                _ = win.TrackMouseEvent(&tracking);
                emitPointer(window, .enter, wparam, lparam, null);
            } else emitPointer(window, .move, wparam, lparam, null);
            return 0;
        },
        win.WM_MOUSELEAVE => {
            window.mouse_inside = false;
            const event: input.Event = .{ .pointer_leave = pointerEvent(window, 0, 0, null) };
            self.queue(window.id, .{ .input = event });
            return 0;
        },
        win.WM_LBUTTONDOWN, win.WM_RBUTTONDOWN, win.WM_MBUTTONDOWN, win.WM_XBUTTONDOWN => {
            _ = win.SetCapture(hwnd);
            emitPointer(window, .down, wparam, lparam, mouseButton(message, wparam));
            return 0;
        },
        win.WM_LBUTTONUP, win.WM_RBUTTONUP, win.WM_MBUTTONUP, win.WM_XBUTTONUP => {
            emitPointer(window, .up, wparam, lparam, mouseButton(message, wparam));
            if (wparam & (win.MK_LBUTTON | win.MK_RBUTTON | win.MK_MBUTTON | win.MK_XBUTTON1 | win.MK_XBUTTON2) == 0) _ = win.ReleaseCapture();
            return 0;
        },
        win.WM_MOUSEWHEEL, win.WM_MOUSEHWHEEL => {
            var point: win.POINT = .{ .x = win.signedLowWord(@bitCast(lparam)), .y = win.signedHighWord(@bitCast(lparam)) };
            _ = win.ScreenToClient(hwnd, &point);
            const delta = @as(f32, @floatFromInt(win.signedHighWord(wparam))) / @as(f32, @floatFromInt(win.WHEEL_DELTA)) * 48.0;
            self.queue(window.id, .{ .input = .{ .scroll = .{
                .position = .{ .x = @as(f32, @floatFromInt(point.x)) / window.scale_factor.value, .y = @as(f32, @floatFromInt(point.y)) / window.scale_factor.value },
                .delta = if (message == win.WM_MOUSEWHEEL) .{ .y = -delta } else .{ .x = delta },
                .precise = false,
                .modifiers = currentModifiers(),
                .timestamp_ns = self.now(),
            } } });
            return 0;
        },
        win.WM_KEYDOWN, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_SYSKEYUP => {
            const down = message == win.WM_KEYDOWN or message == win.WM_SYSKEYDOWN;
            const key_event = keyEvent(window, @intCast(wparam), lparam, down);
            self.queue(window.id, .{ .input = if (down) .{ .key_down = key_event } else .{ .key_up = key_event } });
            return 0;
        },
        win.WM_CHAR => {
            handleCharacter(window, @truncate(wparam));
            return 0;
        },
        win.WM_IME_STARTCOMPOSITION => {
            window.pending_high_surrogate = null;
            return 0;
        },
        win.WM_IME_COMPOSITION => {
            handleComposition(window, @truncate(@as(usize, @bitCast(lparam))));
            return 0;
        },
        win.WM_IME_ENDCOMPOSITION => {
            self.queue(window.id, .{ .input = .{ .ime = .unmark_text } });
            return 0;
        },
        win.WM_DROPFILES => {
            handleDrop(window, @ptrFromInt(wparam));
            return 0;
        },
        win.WM_COMMAND => {
            const command: u32 = win.lowWord(wparam);
            if (self.menu_actions.get(command)) |invocation| self.queue(window.id, .{ .menu_action = invocation });
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

const PointerPhase = enum { down, up, move, enter };

fn emitPointer(window: *NativeWindow, phase: PointerPhase, wparam: usize, lparam: isize, button: ?input.MouseButton) void {
    const pointer = pointerEvent(window, wparam, lparam, button);
    const event: input.Event = switch (phase) {
        .down => .{ .pointer_down = pointer },
        .up => .{ .pointer_up = pointer },
        .move => .{ .pointer_move = pointer },
        .enter => .{ .pointer_enter = pointer },
    };
    window.context.queue(window.id, .{ .input = event });
}

fn pointerEvent(window: *NativeWindow, wparam: usize, lparam: isize, button: ?input.MouseButton) input.PointerEvent {
    const raw: usize = @bitCast(lparam);
    return .{
        .position = .{
            .x = @as(f32, @floatFromInt(win.signedLowWord(raw))) / window.scale_factor.value,
            .y = @as(f32, @floatFromInt(win.signedHighWord(raw))) / window.scale_factor.value,
        },
        .button = button,
        .buttons = @truncate(wparam & 0xffff),
        .modifiers = currentModifiers(),
        .timestamp_ns = window.context.now(),
    };
}

fn mouseButton(message: u32, wparam: usize) input.MouseButton {
    return switch (message) {
        win.WM_LBUTTONDOWN, win.WM_LBUTTONUP => .primary,
        win.WM_RBUTTONDOWN, win.WM_RBUTTONUP => .secondary,
        win.WM_MBUTTONDOWN, win.WM_MBUTTONUP => .middle,
        win.WM_XBUTTONDOWN, win.WM_XBUTTONUP => if (win.highWord(wparam) == 1) .back else .forward,
        else => .other,
    };
}

fn keyEvent(window: *NativeWindow, virtual_key: u32, lparam: isize, down: bool) input.KeyEvent {
    const raw: usize = @bitCast(lparam);
    const scan = @as(u32, @truncate(raw >> 16)) & 0xff;
    const extended = raw & (1 << 24) != 0;
    const extended_scan: u32 = if (extended) 0x100 else 0;
    return .{
        .key = mapKey(virtual_key),
        .physical_code = scan | extended_scan,
        .location = keyLocation(virtual_key, extended),
        .modifiers = currentModifiers(),
        .repeat = down and raw & (1 << 30) != 0,
        .composing = false,
        .timestamp_ns = window.context.now(),
    };
}

fn mapKey(key: u32) input.Key {
    return switch (key) {
        win.VK_RETURN => .enter,
        win.VK_ESCAPE => .escape,
        win.VK_TAB => .tab,
        win.VK_BACK => .backspace,
        win.VK_DELETE => .delete,
        win.VK_INSERT => .insert,
        win.VK_HOME => .home,
        win.VK_END => .end,
        win.VK_PRIOR => .page_up,
        win.VK_NEXT => .page_down,
        win.VK_LEFT => .arrow_left,
        win.VK_RIGHT => .arrow_right,
        win.VK_UP => .arrow_up,
        win.VK_DOWN => .arrow_down,
        win.VK_SPACE => .space,
        win.VK_F1...win.VK_F24 => .{ .function = @intCast(key - win.VK_F1 + 1) },
        'A'...'Z' => .{ .character = @intCast(key + ('a' - 'A')) },
        '0'...'9' => .{ .character = @intCast(key) },
        else => .{ .native = key },
    };
}

fn keyLocation(key: u32, extended: bool) input.KeyLocation {
    return switch (key) {
        win.VK_LSHIFT, win.VK_LCONTROL, win.VK_LMENU, win.VK_LWIN => .left,
        win.VK_RSHIFT, win.VK_RCONTROL, win.VK_RMENU, win.VK_RWIN => .right,
        win.VK_RETURN => if (extended) .numpad else .standard,
        else => .standard,
    };
}

fn currentModifiers() input.Modifiers {
    return .{
        .shift = keyPressed(win.VK_SHIFT),
        .control = keyPressed(win.VK_CONTROL),
        .alt = keyPressed(win.VK_MENU),
        .command = keyPressed(win.VK_LWIN) or keyPressed(win.VK_RWIN),
        .caps_lock = keyToggled(win.VK_CAPITAL),
        .num_lock = keyToggled(win.VK_NUMLOCK),
    };
}

fn keyPressed(key: u32) bool {
    return win.GetKeyState(@intCast(key)) < 0;
}
fn keyToggled(key: u32) bool {
    return win.GetKeyState(@intCast(key)) & 1 != 0;
}

fn handleCharacter(window: *NativeWindow, unit: u16) void {
    if (unit >= 0xd800 and unit <= 0xdbff) {
        window.pending_high_surrogate = unit;
        return;
    }
    var units: [2]u16 = undefined;
    var count: usize = 1;
    units[0] = unit;
    if (unit >= 0xdc00 and unit <= 0xdfff) {
        const high = window.pending_high_surrogate orelse return;
        units = .{ high, unit };
        count = 2;
    }
    window.pending_high_surrogate = null;
    var bytes: [4]u8 = undefined;
    const length = std.unicode.utf16LeToUtf8(&bytes, units[0..count]) catch return;
    window.context.queueText(window.id, .{ .commit_text = .{ .text = bytes[0..length], .replacement_utf8 = null } }, bytes[0..length]);
}

fn handleComposition(window: *NativeWindow, flags: u32) void {
    const ime = win.ImmGetContext(window.hwnd) orelse return;
    defer _ = win.ImmReleaseContext(window.hwnd, ime);
    if (flags & win.GCS_RESULTSTR != 0) {
        const text = compositionString(window.context.allocator, ime, win.GCS_RESULTSTR) catch |err| return window.context.fail(err);
        defer window.context.allocator.free(text);
        window.context.queueText(window.id, .{ .commit_text = .{ .text = text, .replacement_utf8 = null } }, text);
    }
    if (flags & win.GCS_COMPSTR != 0) {
        const text = compositionString(window.context.allocator, ime, win.GCS_COMPSTR) catch |err| return window.context.fail(err);
        defer window.context.allocator.free(text);
        const cursor_units = if (flags & win.GCS_CURSORPOS != 0) @max(win.ImmGetCompositionStringW(ime, win.GCS_CURSORPOS, null, 0), 0) else 0;
        const wide = std.unicode.utf8ToUtf16LeAlloc(window.context.allocator, text) catch |err| return window.context.fail(err);
        defer window.context.allocator.free(wide);
        const byte_cursor = utf16OffsetToUtf8(wide, @intCast(cursor_units));
        window.context.queueText(window.id, .{ .set_marked_text = .{
            .text = text,
            .selected_utf8 = .{ .start = byte_cursor, .end = byte_cursor },
            .replacement_utf8 = null,
        } }, text);
    }
}

fn compositionString(allocator: std.mem.Allocator, ime: win.HIMC, kind: u32) Error![]u8 {
    const byte_count = win.ImmGetCompositionStringW(ime, kind, null, 0);
    if (byte_count < 0 or @rem(byte_count, 2) != 0) return error.PlatformFailure;
    const units = try allocator.alloc(u16, @intCast(@divExact(byte_count, 2)));
    defer allocator.free(units);
    if (byte_count != 0 and win.ImmGetCompositionStringW(ime, kind, units.ptr, @intCast(byte_count)) != byte_count) return error.PlatformFailure;
    return try utf16ToUtf8Alloc(allocator, units);
}

fn utf16OffsetToUtf8(units: []const u16, offset: usize) usize {
    const prefix = units[0..@min(offset, units.len)];
    var iterator = std.unicode.Utf16LeIterator.init(prefix);
    var bytes: usize = 0;
    while ((iterator.nextCodepoint() catch return 0)) |codepoint| {
        bytes += std.unicode.utf8CodepointSequenceLength(codepoint) catch return 0;
    }
    return bytes;
}

fn handleDrop(window: *NativeWindow, drop: win.HDROP) void {
    defer win.DragFinish(drop);
    const count = win.DragQueryFileW(drop, std.math.maxInt(u32), null, 0);
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| window.context.allocator.free(@constCast(path));
        paths.deinit(window.context.allocator);
    }
    for (0..count) |index| {
        const length = win.DragQueryFileW(drop, @intCast(index), null, 0);
        const wide = window.context.allocator.alloc(u16, @as(usize, length) + 1) catch |err| return window.context.fail(err);
        defer window.context.allocator.free(wide);
        if (win.DragQueryFileW(drop, @intCast(index), wide.ptr, @intCast(wide.len)) == 0) continue;
        const path = utf16ToUtf8Alloc(window.context.allocator, wide[0..length]) catch |err| return window.context.fail(err);
        paths.append(window.context.allocator, path) catch |err| {
            window.context.allocator.free(path);
            return window.context.fail(err);
        };
    }
    var point: win.POINT = .{};
    _ = win.DragQueryPoint(drop, &point);
    window.context.queueDrop(window.id, paths.items, .{
        .x = @as(f32, @floatFromInt(point.x)) / window.scale_factor.value,
        .y = @as(f32, @floatFromInt(point.y)) / window.scale_factor.value,
    });
}

fn dpiScale(hwnd: win.HWND) geometry.ScaleFactor {
    const dpi = win.GetDpiForWindow(hwnd);
    return geometry.ScaleFactor.init(if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96.0) catch .{ .value = 1 };
}

fn clientLogicalSize(hwnd: win.HWND, scale: geometry.ScaleFactor) geometry.Size {
    var rect: win.RECT = .{};
    if (win.GetClientRect(hwnd, &rect) == 0) return .zero;
    return .{
        .width = @as(f32, @floatFromInt(rect.right - rect.left)) / scale.value,
        .height = @as(f32, @floatFromInt(rect.bottom - rect.top)) / scale.value,
    };
}

fn saturatedI32(value: anytype) i32 {
    const widened: f64 = @floatCast(value);
    if (std.math.isNan(widened)) return 0;
    if (widened <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (widened >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(@round(widened));
}

fn positiveI32(value: anytype) i32 {
    return @max(1, saturatedI32(value));
}

fn cursorHandle(cursor: api.Cursor) win.HCURSOR {
    const identifier: usize = switch (cursor) {
        .default => 32512,
        .pointer => 32649,
        .text => 32513,
        .crosshair => 32515,
        .grab, .grabbing => 32646,
        .resize_horizontal => 32644,
        .resize_vertical => 32645,
        .resize_diagonal_nw_se => 32642,
        .resize_diagonal_ne_sw => 32643,
        .not_allowed => 32648,
        .hidden => return null,
    };
    return win.LoadCursorW(null, identifier);
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidUtf8 => error.InvalidUtf8,
        error.InvalidHandle => error.InvalidHandle,
        error.InvalidConfiguration => error.InvalidConfiguration,
        else => error.PlatformFailure,
    };
}
