const std = @import("std");
const a11y = @import("../a11y/api.zig");
const clock = @import("../core/clock.zig");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const input = @import("../input/event.zig");
const render = @import("../render/api.zig");
const text = @import("../text/api.zig");

pub const NativeHandle = struct {
    kind: Kind,
    value: usize,

    pub const Kind = enum { none, appkit, win32, wayland, x11, headless };
};

pub const WindowState = render.SurfaceState;

pub const WindowMode = enum {
    normal,
    minimized,
    maximized,
    fullscreen,
};

pub const WindowCommand = union(enum) {
    move: geometry.Point,
    resize: geometry.Size,
    mode: WindowMode,
};

pub const WindowOptions = struct {
    title: []const u8,
    size: geometry.Size = .{ .width = 1024, .height = 768 },
    minimum_size: geometry.Size = .{},
    maximum_size: geometry.Size = .unbounded,
    position: ?geometry.Point = null,
    visible: bool = true,
    decorated: bool = true,
    resizable: bool = true,
    transparent: bool = false,
    always_on_top: bool = false,
};

pub const WindowEvent = union(enum) {
    created: NativeHandle,
    configured: struct { logical_size: geometry.Size, scale_factor: geometry.ScaleFactor },
    moved: geometry.Point,
    resized: geometry.Size,
    scale_changed: geometry.ScaleFactor,
    focused: bool,
    occluded: bool,
    appearance_changed: Appearance,
    input: input.Event,
    menu_action: handles.ActionId,
    accessibility_action: a11y.ActionRequest,
    frame_requested: u64,
    close_requested,
    closed,
    surface_lost,
    device_lost,
};

pub const Appearance = enum { system, light, dark, high_contrast_light, high_contrast_dark };

pub const Cursor = enum {
    default,
    pointer,
    text,
    crosshair,
    grab,
    grabbing,
    resize_horizontal,
    resize_vertical,
    resize_diagonal_nw_se,
    resize_diagonal_ne_sw,
    not_allowed,
    hidden,
};

pub const EventSink = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, handles.WindowId, *const WindowEvent) void,
    /// Invoked by native `run` loops after every wait/dispatch iteration,
    /// including iterations woken without a window event. App uses it to drain
    /// bounded worker completions on the UI thread.
    pump_callback: *const fn (*anyopaque) void = ignorePump,

    pub fn send(self: EventSink, window: handles.WindowId, event: *const WindowEvent) void {
        self.callback(self.context, window, event);
    }

    pub fn pump(self: EventSink) void {
        self.pump_callback(self.context);
    }
};

pub const EventLoop = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, EventSink) Error!void,
    step_fn: *const fn (*anyopaque, EventSink, bool) Error!bool,
    wake_fn: *const fn (*anyopaque) void,
    request_quit_fn: *const fn (*anyopaque) void,
    clock: clock.Clock,

    pub fn run(self: EventLoop, sink: EventSink) Error!void {
        try self.run_fn(self.context, sink);
    }

    pub fn step(self: EventLoop, sink: EventSink, wait: bool) Error!bool {
        return self.step_fn(self.context, sink, wait);
    }

    pub fn wake(self: EventLoop) void {
        self.wake_fn(self.context);
    }

    pub fn requestQuit(self: EventLoop) void {
        self.request_quit_fn(self.context);
    }
};

pub const WindowSystem = struct {
    context: *anyopaque,
    create_fn: *const fn (*anyopaque, handles.WindowId, WindowOptions) Error!NativeHandle,
    destroy_fn: *const fn (*anyopaque, handles.WindowId) void,
    show_fn: *const fn (*anyopaque, handles.WindowId, bool) Error!void,
    title_fn: *const fn (*anyopaque, handles.WindowId, []const u8) Error!void,
    request_frame_fn: *const fn (*anyopaque, handles.WindowId) Error!void,
    set_cursor_fn: *const fn (*anyopaque, handles.WindowId, Cursor) Error!void,
    command_fn: *const fn (*anyopaque, handles.WindowId, WindowCommand) Error!void,
    native_handle_fn: *const fn (*anyopaque, handles.WindowId) ?NativeHandle,
    maximum_text_bytes: usize = 16 * 1024 * 1024,

    pub fn create(self: WindowSystem, id: handles.WindowId, options: WindowOptions) Error!NativeHandle {
        if (!id.isValid()) return error.InvalidHandle;
        if (!validWindowOptions(options) or self.maximum_text_bytes == 0) return error.InvalidConfiguration;
        if (options.title.len > self.maximum_text_bytes) return error.BudgetExceeded;
        const native = try self.create_fn(self.context, id, options);
        if (native.kind == .none or native.value == 0) return error.PlatformFailure;
        return native;
    }

    pub fn destroy(self: WindowSystem, id: handles.WindowId) void {
        if (!id.isValid()) return;
        self.destroy_fn(self.context, id);
    }

    pub fn show(self: WindowSystem, id: handles.WindowId, visible: bool) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        return self.show_fn(self.context, id, visible);
    }

    pub fn setTitle(self: WindowSystem, id: handles.WindowId, title: []const u8) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        if (!validUtf8Text(title)) return error.InvalidUtf8;
        if (title.len > self.maximum_text_bytes) return error.BudgetExceeded;
        return self.title_fn(self.context, id, title);
    }

    pub fn requestFrame(self: WindowSystem, id: handles.WindowId) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        return self.request_frame_fn(self.context, id);
    }

    pub fn setCursor(self: WindowSystem, id: handles.WindowId, cursor: Cursor) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.set_cursor_fn(self.context, id, cursor);
    }

    pub fn command(self: WindowSystem, id: handles.WindowId, value: WindowCommand) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        switch (value) {
            .move => |point| if (!finitePoint(point)) return error.InvalidConfiguration,
            .resize => |size| if (!finitePositiveSize(size)) return error.InvalidConfiguration,
            .mode => {},
        }
        try self.command_fn(self.context, id, value);
    }

    pub fn nativeHandle(self: WindowSystem, id: handles.WindowId) ?NativeHandle {
        if (!id.isValid()) return null;
        const native = self.native_handle_fn(self.context, id) orelse return null;
        if (native.kind == .none or native.value == 0) return null;
        return native;
    }
};

pub const Display = struct {
    /// Stable for the lifetime of the current native display connection.
    id: u64,
    name: []const u8,
    /// Desktop coordinates in the same coordinate space accepted by
    /// `WindowCommand.move` on this platform.
    bounds: geometry.Rect,
    work_area: geometry.Rect,
    scale_factor: geometry.ScaleFactor,
    refresh_millihertz: u32 = 0,
    physical_size_mm: geometry.Size = .{},
    primary: bool = false,
};

pub const OwnedDisplays = struct {
    allocator: std.mem.Allocator,
    values: []Display,

    pub fn deinit(self: *OwnedDisplays) void {
        for (self.values) |display| self.allocator.free(@constCast(display.name));
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub const Displays = struct {
    context: *anyopaque,
    list_fn: *const fn (*anyopaque, std.mem.Allocator) Error!OwnedDisplays,
    maximum_count: usize = 256,
    maximum_text_bytes: usize = 16 * 1024 * 1024,

    pub fn list(self: Displays, allocator: std.mem.Allocator) Error!OwnedDisplays {
        var result = try self.list_fn(self.context, allocator);
        validateDisplays(result.values, self.maximum_count, self.maximum_text_bytes) catch |err| {
            result.deinit();
            return err;
        };
        return result;
    }
};

pub const Clipboard = struct {
    context: *anyopaque,
    read_text_fn: *const fn (*anyopaque, std.mem.Allocator) Error!?[]u8,
    write_text_fn: *const fn (*anyopaque, []const u8) Error!void,
    maximum_bytes: usize = 64 * 1024 * 1024,

    pub fn readText(self: Clipboard, allocator: std.mem.Allocator) Error!?[]u8 {
        const result = try self.read_text_fn(self.context, allocator);
        if (result) |value| {
            if (value.len > self.maximum_bytes) {
                allocator.free(value);
                return error.BudgetExceeded;
            }
            if (!validUtf8Text(value)) {
                allocator.free(value);
                return error.InvalidUtf8;
            }
        }
        return result;
    }

    pub fn writeText(self: Clipboard, value: []const u8) Error!void {
        if (!validUtf8Text(value)) return error.InvalidUtf8;
        if (value.len > self.maximum_bytes) return error.BudgetExceeded;
        try self.write_text_fn(self.context, value);
    }

    pub fn bridge(self: Clipboard) input.NativeClipboard {
        return .{
            .context = self.context,
            .read_text_fn = self.read_text_fn,
            .write_text_fn = self.write_text_fn,
            .maximum_bytes = self.maximum_bytes,
        };
    }
};

pub const MenuItem = union(enum) {
    action: struct { label: []const u8, action: handles.ActionId, enabled: bool = true, checked: bool = false },
    submenu: struct { label: []const u8, items: []const MenuItem },
    separator,
};

pub const MenuLimits = struct {
    maximum_items: usize = 16_384,
    maximum_depth: usize = 64,
    maximum_text_bytes: usize = 8 * 1024 * 1024,
};

pub const Menus = struct {
    context: *anyopaque,
    set_application_menu_fn: *const fn (*anyopaque, []const MenuItem) Error!void,
    show_context_menu_fn: *const fn (*anyopaque, handles.WindowId, geometry.Point, []const MenuItem) Error!void,
    limits: MenuLimits = .{},

    pub fn setApplicationMenu(self: Menus, items: []const MenuItem) Error!void {
        try validateMenu(items, self.limits);
        try self.set_application_menu_fn(self.context, items);
    }

    pub fn showContextMenu(self: Menus, window: handles.WindowId, point: geometry.Point, items: []const MenuItem) Error!void {
        if (!window.isValid()) return error.InvalidHandle;
        if (!finitePoint(point)) return error.InvalidConfiguration;
        try validateMenu(items, self.limits);
        try self.show_context_menu_fn(self.context, window, point, items);
    }
};

pub const Dialogs = struct {
    context: *anyopaque,
    open_files_fn: *const fn (*anyopaque, handles.WindowId, bool, std.mem.Allocator) Error!OwnedPaths,
    save_file_fn: *const fn (*anyopaque, handles.WindowId, []const u8, std.mem.Allocator) Error!?OwnedPath,
    limits: DialogLimits = .{},

    pub fn openFiles(self: Dialogs, window: handles.WindowId, multiple: bool, allocator: std.mem.Allocator) Error!OwnedPaths {
        if (!window.isValid()) return error.InvalidHandle;
        var result = try self.open_files_fn(self.context, window, multiple, allocator);
        validatePaths(result.values, self.limits) catch |err| {
            result.deinit();
            return err;
        };
        if (!multiple and result.values.len > 1) {
            result.deinit();
            return error.PlatformFailure;
        }
        return result;
    }

    pub fn saveFile(self: Dialogs, window: handles.WindowId, suggested_name: []const u8, allocator: std.mem.Allocator) Error!?OwnedPath {
        if (!window.isValid()) return error.InvalidHandle;
        if (!validUtf8Text(suggested_name)) return error.InvalidUtf8;
        if (suggested_name.len > self.limits.maximum_suggested_name_bytes) return error.BudgetExceeded;
        var result = try self.save_file_fn(self.context, window, suggested_name, allocator);
        if (result) |*path| {
            validatePath(path.value, self.limits.maximum_path_bytes) catch |err| {
                path.deinit();
                return err;
            };
        }
        return result;
    }
};

pub const DialogLimits = struct {
    maximum_paths: usize = 4_096,
    maximum_path_bytes: usize = 16 * 1024 * 1024,
    maximum_suggested_name_bytes: usize = 16 * 1024 * 1024,
};

pub const OwnedPath = struct {
    allocator: std.mem.Allocator,
    value: []const u8,

    pub fn deinit(self: *OwnedPath) void {
        self.allocator.free(@constCast(self.value));
        self.* = undefined;
    }
};

pub const OwnedPaths = struct {
    allocator: std.mem.Allocator,
    values: []const []const u8,

    pub fn deinit(self: *OwnedPaths) void {
        for (self.values) |value| self.allocator.free(@constCast(value));
        self.allocator.free(@constCast(self.values));
        self.* = undefined;
    }
};

pub const TextInput = struct {
    context: *anyopaque,
    set_active_fn: *const fn (*anyopaque, handles.WindowId, bool) Error!void,
    set_candidate_rect_fn: *const fn (*anyopaque, handles.WindowId, geometry.Rect) Error!void,
    set_surrounding_text_fn: *const fn (*anyopaque, handles.WindowId, []const u8, input.TextRange) Error!void,
    maximum_surrounding_text_bytes: usize = 16 * 1024 * 1024,

    pub fn bridge(self: TextInput) input.NativeTextInput {
        return .{
            .context = self.context,
            .set_active_fn = self.set_active_fn,
            .set_candidate_rect_fn = self.set_candidate_rect_fn,
            .set_surrounding_text_fn = self.set_surrounding_text_fn,
            .maximum_surrounding_text_bytes = self.maximum_surrounding_text_bytes,
        };
    }
};

pub const Bundle = struct {
    event_loop: EventLoop,
    windows: WindowSystem,
    displays: Displays,
    renderer: render.Renderer,
    text_backend: ?text.Backend = null,
    text_input: ?TextInput = null,
    accessibility: ?a11y.Adapter = null,
    clipboard: ?Clipboard = null,
    menus: ?Menus = null,
    dialogs: ?Dialogs = null,
    deinit_context: *anyopaque,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn deinit(self: Bundle) void {
        self.deinit_fn(self.deinit_context);
    }
};

pub fn validateWindowEvent(value: *const WindowEvent) Error!void {
    switch (value.*) {
        .created => |native| if (native.kind == .none or native.value == 0)
            return error.PlatformFailure,
        .configured => |configured| {
            if (!finiteNonNegativeSize(configured.logical_size) or
                !std.math.isFinite(configured.scale_factor.value) or configured.scale_factor.value <= 0)
                return error.InvalidConfiguration;
        },
        .moved => |point| if (!finitePoint(point)) return error.InvalidConfiguration,
        .resized => |size| if (!finiteNonNegativeSize(size)) return error.InvalidConfiguration,
        .scale_changed => |scale_factor| if (!std.math.isFinite(scale_factor.value) or scale_factor.value <= 0)
            return error.InvalidScaleFactor,
        .menu_action => |action| if (!action.isValid()) return error.InvalidHandle,
        .accessibility_action => |request| {
            if (!request.window.isValid() or !request.target.isValid()) return error.InvalidHandle;
            if (request.value) |text_value| if (!validUtf8Text(text_value)) return error.InvalidUtf8;
        },
        .input,
        .focused,
        .occluded,
        .appearance_changed,
        .frame_requested,
        .close_requested,
        .closed,
        .surface_lost,
        .device_lost,
        => {},
    }
}

fn finitePoint(point: geometry.Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn finiteRect(rect: geometry.Rect) bool {
    return finitePoint(rect.origin) and finiteNonNegativeSize(rect.size);
}

fn ignorePump(_: *anyopaque) void {}

fn finitePositiveSize(size: geometry.Size) bool {
    return std.math.isFinite(size.width) and std.math.isFinite(size.height) and
        size.width > 0 and size.height > 0;
}

fn validWindowOptions(options: WindowOptions) bool {
    if (!validUtf8Text(options.title) or !finitePositiveSize(options.size) or
        !finiteNonNegativeSize(options.minimum_size) or !validMaximumSize(options.maximum_size))
        return false;
    if (options.minimum_size.width > options.maximum_size.width or options.minimum_size.height > options.maximum_size.height)
        return false;
    if (options.size.width < options.minimum_size.width or options.size.height < options.minimum_size.height or
        options.size.width > options.maximum_size.width or options.size.height > options.maximum_size.height)
        return false;
    if (options.position) |position| if (!finitePoint(position)) return false;
    return true;
}

fn finiteNonNegativeSize(size: geometry.Size) bool {
    return std.math.isFinite(size.width) and std.math.isFinite(size.height) and
        size.width >= 0 and size.height >= 0;
}

fn validMaximumSize(size: geometry.Size) bool {
    inline for (.{ size.width, size.height }) |amount| {
        if (std.math.isNan(amount) or amount <= 0) return false;
    }
    return true;
}

fn validUtf8Text(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn validateDisplays(values: []const Display, maximum_count: usize, maximum_text_bytes: usize) Error!void {
    if (maximum_count == 0 or maximum_text_bytes == 0) return error.InvalidConfiguration;
    if (values.len > maximum_count) return error.BudgetExceeded;
    var text_bytes: usize = 0;
    for (values) |display| {
        if (!validUtf8Text(display.name) or display.name.len == 0) return error.InvalidUtf8;
        text_bytes = std.math.add(usize, text_bytes, display.name.len) catch return error.BudgetExceeded;
        if (text_bytes > maximum_text_bytes) return error.BudgetExceeded;
        if (!finiteRect(display.bounds) or !finiteRect(display.work_area) or
            !finiteNonNegativeSize(display.physical_size_mm) or
            !std.math.isFinite(display.scale_factor.value) or display.scale_factor.value <= 0)
            return error.InvalidConfiguration;
    }
}

fn validatePaths(values: []const []const u8, limits: DialogLimits) Error!void {
    if (limits.maximum_paths == 0 or limits.maximum_path_bytes == 0 or limits.maximum_suggested_name_bytes == 0)
        return error.InvalidConfiguration;
    if (values.len > limits.maximum_paths) return error.BudgetExceeded;
    var total: usize = 0;
    for (values) |value| {
        try validatePath(value, limits.maximum_path_bytes);
        total = std.math.add(usize, total, value.len) catch return error.BudgetExceeded;
        if (total > limits.maximum_path_bytes) return error.BudgetExceeded;
    }
}

fn validatePath(value: []const u8, maximum_bytes: usize) Error!void {
    if (value.len == 0) return error.InvalidConfiguration;
    if (value.len > maximum_bytes) return error.BudgetExceeded;
    if (!validUtf8Text(value)) return error.InvalidUtf8;
}

fn validateMenu(items: []const MenuItem, limits: MenuLimits) Error!void {
    if (limits.maximum_items == 0 or limits.maximum_depth == 0 or limits.maximum_text_bytes == 0)
        return error.InvalidConfiguration;
    var count: usize = 0;
    var text_bytes: usize = 0;
    try validateMenuLevel(items, limits, 1, &count, &text_bytes);
}

fn validateMenuLevel(
    items: []const MenuItem,
    limits: MenuLimits,
    depth: usize,
    count: *usize,
    text_bytes: *usize,
) Error!void {
    if (depth > limits.maximum_depth) return error.BudgetExceeded;
    for (items) |item| {
        count.* = std.math.add(usize, count.*, 1) catch return error.BudgetExceeded;
        if (count.* > limits.maximum_items) return error.BudgetExceeded;
        switch (item) {
            .separator => {},
            .action => |definition| {
                if (!definition.action.isValid()) return error.InvalidHandle;
                try chargeMenuText(definition.label, limits.maximum_text_bytes, text_bytes);
            },
            .submenu => |submenu| {
                try chargeMenuText(submenu.label, limits.maximum_text_bytes, text_bytes);
                try validateMenuLevel(submenu.items, limits, depth + 1, count, text_bytes);
            },
        }
    }
}

fn chargeMenuText(value: []const u8, maximum: usize, used: *usize) Error!void {
    if (!validUtf8Text(value)) return error.InvalidUtf8;
    const next = std.math.add(usize, used.*, value.len) catch return error.BudgetExceeded;
    if (next > maximum) return error.BudgetExceeded;
    used.* = next;
}
