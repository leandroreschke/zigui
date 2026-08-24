const std = @import("std");
const config = @import("../../../config.zig");
const Error = @import("../../../core/error.zig").Error;
const clock = @import("../../../core/clock.zig");
const geometry = @import("../../../core/geometry.zig");
const handles = @import("../../../core/handle.zig");
const input = @import("../../../input/event.zig");
const api = @import("../../api.zig");
const event_memory = @import("../../event_memory.zig");
const surface_api = @import("../surface.zig");
const sys = @import("../sys.zig");
const vulkan = @import("../../../backend/vulkan/renderer.zig");
const vulkan_device = @import("../../../backend/vulkan/device.zig");
const in_tree_text = if (config.text_enabled) @import("../../../text/in_tree_backend.zig") else struct {};
const linux_fonts = if (config.text_enabled) @import("../fonts.zig") else struct {};
const linux_uri = @import("../uri.zig");
const portal_mod = @import("../portal.zig");
const linux_a11y = if (config.accessibility_enabled) @import("../accessibility.zig") else struct {
    pub const Adapter = opaque {};
};
const client_mod = @import("client.zig");
const keyboard_mod = @import("keyboard.zig");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");

const atom_atom: u32 = 4;
const atom_cardinal: u32 = 6;
const atom_resource_manager: u32 = 23;
const atom_string: u32 = 31;
const atom_wm_name: u32 = 39;
const atom_wm_normal_hints: u32 = 40;
const atom_wm_size_hints: u32 = 41;
const atom_wm_class: u32 = 67;
const present_event_configure: u32 = 1 << 0;
const present_event_complete: u32 = 1 << 1;
const present_event_idle: u32 = 1 << 2;

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

const TimestampState = struct {
    previous: u32 = 0,
    epoch: u64 = 0,
    initialized: bool = false,

    fn extend(self: *TimestampState, milliseconds: u32) u64 {
        if (self.initialized and milliseconds < self.previous and self.previous -% milliseconds > 0x80000000)
            self.epoch +%= @as(u64, 1) << 32;
        self.initialized = true;
        self.previous = milliseconds;
        return (self.epoch | milliseconds) * std.time.ns_per_ms;
    }
};

const Atoms = struct {
    wm_protocols: u32,
    wm_delete_window: u32,
    utf8_string: u32,
    net_wm_name: u32,
    net_wm_pid: u32,
    net_wm_state: u32,
    net_wm_state_above: u32,
    net_wm_state_maximized_vert: u32,
    net_wm_state_maximized_horz: u32,
    net_wm_state_fullscreen: u32,
    net_workarea: u32,
    net_current_desktop: u32,
    wm_change_state: u32,
    motif_wm_hints: u32,
    clipboard: u32,
    targets: u32,
    text: u32,
    incr: u32,
    selection_property: u32,
    xdnd_aware: u32,
    xdnd_enter: u32,
    xdnd_position: u32,
    xdnd_status: u32,
    xdnd_leave: u32,
    xdnd_drop: u32,
    xdnd_finished: u32,
    xdnd_selection: u32,
    xdnd_action_copy: u32,
    xdnd_type_list: u32,
    text_uri_list: u32,
    xdnd_data: u32,

    fn load(client: *client_mod.Client, writer: *wire.Writer) Error!Atoms {
        return .{
            .wm_protocols = try protocol.internAtom(client, writer, "WM_PROTOCOLS", false),
            .wm_delete_window = try protocol.internAtom(client, writer, "WM_DELETE_WINDOW", false),
            .utf8_string = try protocol.internAtom(client, writer, "UTF8_STRING", false),
            .net_wm_name = try protocol.internAtom(client, writer, "_NET_WM_NAME", false),
            .net_wm_pid = try protocol.internAtom(client, writer, "_NET_WM_PID", false),
            .net_wm_state = try protocol.internAtom(client, writer, "_NET_WM_STATE", false),
            .net_wm_state_above = try protocol.internAtom(client, writer, "_NET_WM_STATE_ABOVE", false),
            .net_wm_state_maximized_vert = try protocol.internAtom(client, writer, "_NET_WM_STATE_MAXIMIZED_VERT", false),
            .net_wm_state_maximized_horz = try protocol.internAtom(client, writer, "_NET_WM_STATE_MAXIMIZED_HORZ", false),
            .net_wm_state_fullscreen = try protocol.internAtom(client, writer, "_NET_WM_STATE_FULLSCREEN", false),
            .net_workarea = try protocol.internAtom(client, writer, "_NET_WORKAREA", false),
            .net_current_desktop = try protocol.internAtom(client, writer, "_NET_CURRENT_DESKTOP", false),
            .wm_change_state = try protocol.internAtom(client, writer, "WM_CHANGE_STATE", false),
            .motif_wm_hints = try protocol.internAtom(client, writer, "_MOTIF_WM_HINTS", false),
            .clipboard = try protocol.internAtom(client, writer, "CLIPBOARD", false),
            .targets = try protocol.internAtom(client, writer, "TARGETS", false),
            .text = try protocol.internAtom(client, writer, "TEXT", false),
            .incr = try protocol.internAtom(client, writer, "INCR", false),
            .selection_property = try protocol.internAtom(client, writer, "ZIGUI_SELECTION", false),
            .xdnd_aware = try protocol.internAtom(client, writer, "XdndAware", false),
            .xdnd_enter = try protocol.internAtom(client, writer, "XdndEnter", false),
            .xdnd_position = try protocol.internAtom(client, writer, "XdndPosition", false),
            .xdnd_status = try protocol.internAtom(client, writer, "XdndStatus", false),
            .xdnd_leave = try protocol.internAtom(client, writer, "XdndLeave", false),
            .xdnd_drop = try protocol.internAtom(client, writer, "XdndDrop", false),
            .xdnd_finished = try protocol.internAtom(client, writer, "XdndFinished", false),
            .xdnd_selection = try protocol.internAtom(client, writer, "XdndSelection", false),
            .xdnd_action_copy = try protocol.internAtom(client, writer, "XdndActionCopy", false),
            .xdnd_type_list = try protocol.internAtom(client, writer, "XdndTypeList", false),
            .text_uri_list = try protocol.internAtom(client, writer, "text/uri-list", false),
            .xdnd_data = try protocol.internAtom(client, writer, "ZIGUI_XDND_DATA", false),
        };
    }
};

const NativeWindow = struct {
    context: *Context,
    id: handles.WindowId,
    xid: u32,
    present_event: u32,
    logical_size: geometry.Size,
    position: geometry.Point,
    scale_factor: geometry.ScaleFactor,
    visible: bool,
    destroyed: bool = false,
    close_notified: bool = false,
    configured: bool = true,
    present_pending: bool = false,
    frame_wanted: bool = false,
    cursor: api.Cursor = .default,
    text_input_active: bool = false,
    candidate_rect: geometry.Rect = .{},
    surrounding_text: ?[]u8 = null,
    selection: input.TextRange = .{ .start = 0, .end = 0 },
    pending_dead: ?u21 = null,

    fn deinit(self: *NativeWindow) void {
        self.context.retained_text.release(self.context.allocator, &self.surrounding_text);
        self.* = undefined;
    }
};

const Buffer = struct {
    pixmap: u32,
    released: bool = true,
    last_serial: u32 = 0,
};

const OutgoingTransfer = struct {
    requestor: u32,
    property: u32,
    target: u32,
    data: []u8,
    cursor: usize = 0,

    fn deinit(self: *OutgoingTransfer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
};

const PendingRelease = struct {
    window: *NativeWindow,
    keycode: u8,
    state: u16,
    timestamp: u32,
};

const DndState = struct {
    source: u32,
    window: *NativeWindow,
    target: u32,
    position: geometry.Point = .{},
    timestamp: u32 = 0,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    app_config: config.AppConfig,
    client: client_mod.Client,
    writer: wire.Writer,
    wake_fd: sys.fd_t,
    dri3: protocol.Extension,
    present: protocol.Extension,
    randr: ?protocol.Extension,
    atoms: Atoms,
    keyboard: keyboard_mod.Map,
    formats: []surface_api.Format,
    colormap: u32 = 0,
    selection_window: u32 = 0,
    cursor_font: u32 = 0,
    cursors: [@typeInfo(api.Cursor).@"enum".field_names.len]u32 = @splat(0),
    windows: std.AutoHashMap(u64, *NativeWindow),
    xids: std.AutoHashMap(u32, *NativeWindow),
    present_events: std.AutoHashMap(u32, *NativeWindow),
    buffers: std.AutoHashMap(u64, *Buffer),
    pixmaps: std.AutoHashMap(u32, *Buffer),
    outgoing: std.AutoHashMap(u64, OutgoingTransfer),
    events: std.ArrayList(Pending) = .empty,
    event_cursor: usize = 0,
    pending_payload_bytes: usize = 0,
    clipboard_text: ?[]u8 = null,
    clipboard_owned_bytes: usize = 0,
    pending_release: ?PendingRelease = null,
    dnd: ?DndState = null,
    pointer_window: ?*NativeWindow = null,
    pointer_position: geometry.Point = .{},
    buttons: u32 = 0,
    timestamps: TimestampState = .{},
    scale_factor: geometry.ScaleFactor,
    next_present_serial: u32 = 1,
    quit: bool = false,
    failure: ?Error = null,
    portal: ?*portal_mod.Portal = null,
    accessibility: ?*linux_a11y.Adapter = null,
    retained_text: event_memory.RetainedTextBudget,

    fn init(allocator: std.mem.Allocator, app_config: config.AppConfig) Error!*Context {
        var client = try client_mod.Client.connect(
            allocator,
            app_config.linux,
            app_config.memory.platform_event_count,
            app_config.memory.platform_event_queue_bytes,
        );
        var client_owned = true;
        errdefer if (client_owned) client.deinit();
        var writer = wire.Writer.init(allocator);
        var writer_owned = true;
        errdefer if (writer_owned) writer.deinit();
        const dri3 = try protocol.queryExtension(&client, &writer, "DRI3");
        const present = try protocol.queryExtension(&client, &writer, "Present");
        const randr_extension = try protocol.queryExtension(&client, &writer, "RANDR");
        if (!dri3.present or !present.present) return error.MissingCapability;
        const dri3_version = try protocol.dri3QueryVersion(&client, &writer, dri3);
        const present_version = try protocol.presentQueryVersion(&client, &writer, present);
        if (dri3_version.major < 1 or (dri3_version.major == 1 and dri3_version.minor < 2) or present_version.major < 1)
            return error.MissingCapability;
        const randr: ?protocol.Extension = if (randr_extension.present) blk: {
            const version = try protocol.randrQueryVersion(&client, &writer, randr_extension);
            break :blk if (version.major > 1 or (version.major == 1 and version.minor >= 5)) randr_extension else null;
        } else null;
        var modifiers = try protocol.dri3GetSupportedModifiers(
            &client,
            &writer,
            allocator,
            dri3,
            client.setup.root,
            client.setup.presentation_depth,
            client.setup.presentation_format.bits_per_pixel,
            app_config.memory.platform_object_count,
        );
        defer modifiers.deinit();
        if (modifiers.values.len == 0) return error.MissingCapability;
        const formats = try allocator.alloc(surface_api.Format, modifiers.values.len);
        var formats_owned = true;
        errdefer if (formats_owned) allocator.free(formats);
        for (formats, modifiers.values) |*output, modifier| output.* = .{
            .fourcc = vulkan_device.drm_format_argb8888,
            .modifier = modifier,
            .scanout = true,
        };
        var keyboard = try keyboard_mod.Map.load(allocator, &client, &writer);
        var keyboard_owned = true;
        errdefer if (keyboard_owned) keyboard.deinit();
        const atoms = try Atoms.load(&client, &writer);
        const wake_fd = try sys.createWakeFd();
        var wake_owned = true;
        errdefer if (wake_owned) sys.close(wake_fd);
        const scale_factor = try readScaleFactor(&client, &writer, allocator);
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .app_config = app_config,
            .client = client,
            .writer = writer,
            .wake_fd = wake_fd,
            .dri3 = dri3,
            .present = present,
            .randr = randr,
            .atoms = atoms,
            .keyboard = keyboard,
            .formats = formats,
            .windows = std.AutoHashMap(u64, *NativeWindow).init(allocator),
            .xids = std.AutoHashMap(u32, *NativeWindow).init(allocator),
            .present_events = std.AutoHashMap(u32, *NativeWindow).init(allocator),
            .buffers = std.AutoHashMap(u64, *Buffer).init(allocator),
            .pixmaps = std.AutoHashMap(u32, *Buffer).init(allocator),
            .outgoing = std.AutoHashMap(u64, OutgoingTransfer).init(allocator),
            .scale_factor = scale_factor,
            .retained_text = try event_memory.RetainedTextBudget.init(app_config.memory.platform_retained_text_bytes),
        };
        client_owned = false;
        writer_owned = false;
        keyboard_owned = false;
        wake_owned = false;
        formats_owned = false;
        errdefer self.deinit();
        if (self.client.setup.presentation_visual != self.client.setup.root_visual) {
            self.colormap = try self.client.allocateId();
            try protocol.createColormap(&self.client, &self.writer, self.colormap, self.client.setup.root, self.client.setup.presentation_visual);
        }
        try self.createSelectionWindow();
        try self.createCursors();
        return self;
    }

    fn surfaceProvider(self: *Context) surface_api.Provider {
        return .{
            .context = self,
            .explicit_sync_fn = explicitSyncAvailable,
            .formats_fn = supportedFormats,
            .import_buffer_fn = importBuffer,
            .destroy_buffer_fn = destroyBuffer,
            .buffer_released_fn = bufferReleased,
            .import_timeline_fn = importTimeline,
            .destroy_timeline_fn = destroyTimeline,
            .present_fn = presentBuffer,
        };
    }

    fn createSelectionWindow(self: *Context) Error!void {
        self.selection_window = try self.client.allocateId();
        try protocol.createWindow(
            &self.client,
            &self.writer,
            self.client.setup.root_depth,
            self.selection_window,
            self.client.setup.root,
            -1,
            -1,
            1,
            1,
            self.client.setup.root_visual,
            protocol.WindowValueMask.event_mask,
            &.{protocol.EventMask.property_change},
        );
    }

    fn createCursors(self: *Context) Error!void {
        self.cursor_font = try self.client.allocateId();
        try protocol.openFont(&self.client, &self.writer, self.cursor_font, "cursor");
        const glyphs = [_]u16{ 68, 60, 152, 34, 52, 58, 60, 108, 116, 134, 136, 88 };
        inline for (.{
            api.Cursor.default,
            api.Cursor.pointer,
            api.Cursor.text,
            api.Cursor.crosshair,
            api.Cursor.grab,
            api.Cursor.grabbing,
            api.Cursor.resize_horizontal,
            api.Cursor.resize_vertical,
            api.Cursor.resize_diagonal_nw_se,
            api.Cursor.resize_diagonal_ne_sw,
            api.Cursor.not_allowed,
            api.Cursor.hidden,
        }, 0..) |cursor, index| {
            if (cursor == .hidden) continue;
            const id = try self.client.allocateId();
            try protocol.createGlyphCursor(&self.client, &self.writer, id, self.cursor_font, glyphs[index], glyphs[index] + 1);
            self.cursors[@backingInt(cursor)] = id;
        }
        const pixmap = try self.client.allocateId();
        const gc = try self.client.allocateId();
        const hidden = try self.client.allocateId();
        try protocol.createPixmap(&self.client, &self.writer, 1, pixmap, self.client.setup.root, 1, 1);
        try protocol.createGc(&self.client, &self.writer, gc, pixmap, 1 << 2, &.{0});
        try protocol.fillRectangle(&self.client, &self.writer, pixmap, gc, 0, 0, 1, 1);
        try protocol.createCursor(&self.client, &self.writer, hidden, pixmap, pixmap, 0, 0);
        try protocol.freeGc(&self.client, &self.writer, gc);
        try protocol.freePixmap(&self.client, &self.writer, pixmap);
        self.cursors[@backingInt(api.Cursor.hidden)] = hidden;
    }

    fn queue(self: *Context, window: handles.WindowId, event: api.WindowEvent) void {
        self.appendPending(.{ .window = window, .event = event }) catch |err| self.fail(err);
        sys.wake(self.wake_fd);
    }

    fn preparePendingSlots(self: *Context, count: usize) Error!void {
        const maximum = self.app_config.memory.platform_event_count;
        if (count > maximum) return error.BudgetExceeded;
        if (self.event_cursor != 0 and
            (self.event_cursor >= maximum / 2 or
                count > maximum -| (self.events.items.len - self.event_cursor)))
            self.compactEvents();
        const unread = self.events.items.len - self.event_cursor;
        if (count > maximum -| unread) return error.BudgetExceeded;
        try self.events.ensureUnusedCapacity(self.allocator, count);
    }

    fn appendPending(self: *Context, pending_source: Pending) Error!void {
        var pending = pending_source;
        pending.owned_bytes = try event_memory.ownedPayloadBytes(pending.owned_text, pending.owned_paths);
        if (pending.owned_bytes > self.app_config.memory.platform_event_queue_bytes -| self.pending_payload_bytes)
            return error.BudgetExceeded;
        try self.preparePendingSlots(1);
        self.events.appendAssumeCapacity(pending);
        self.pending_payload_bytes += pending.owned_bytes;
    }

    fn queueIme(self: *Context, window: handles.WindowId, ime: input.ImeEvent, bytes: []const u8) void {
        const borrowed: input.Event = .{ .ime = ime };
        self.validateInput(&borrowed) catch |err| {
            self.fail(err);
            return;
        };
        _ = event_memory.ensureFits(
            bytes,
            null,
            self.pending_payload_bytes,
            self.app_config.memory.platform_event_queue_bytes,
        ) catch |err| {
            self.fail(err);
            return;
        };
        const owned = self.allocator.dupe(u8, bytes) catch |err| {
            self.fail(err);
            return;
        };
        var event = ime;
        switch (event) {
            .set_marked_text => |*value| value.text = owned,
            .commit_text => |*value| value.text = owned,
            else => {},
        }
        self.appendPending(.{
            .window = window,
            .event = .{ .input = .{ .ime = event } },
            .owned_text = owned,
        }) catch |err| {
            self.allocator.free(owned);
            self.fail(err);
        };
        sys.wake(self.wake_fd);
    }

    fn queueAccessibility(self: *Context, request: @import("../../../a11y/api.zig").ActionRequest) void {
        const borrowed: input.Event = .{ .accessibility = .{
            .target = request.target,
            .action = request.action,
            .value = request.value,
            .selection = request.selection,
        } };
        self.validateInput(&borrowed) catch |err| {
            self.fail(err);
            return;
        };
        _ = event_memory.ensureFits(
            request.value,
            null,
            self.pending_payload_bytes,
            self.app_config.memory.platform_event_queue_bytes,
        ) catch |err| {
            self.fail(err);
            return;
        };
        const owned = if (request.value) |value| self.allocator.dupe(u8, value) catch |err| {
            self.fail(err);
            return;
        } else null;
        var copied = request;
        copied.value = owned;
        self.appendPending(.{
            .window = request.window,
            .event = .{ .accessibility_action = copied },
            .owned_text = owned,
        }) catch |err| {
            if (owned) |value| self.allocator.free(value);
            self.fail(err);
            return;
        };
        sys.wake(self.wake_fd);
    }

    fn queueDrop(self: *Context, window: handles.WindowId, comptime tag: enum { entered, updated, performed }, paths_source: []const []const u8, position: geometry.Point) void {
        const borrowed_drop: input.FileDrop = .{ .paths = paths_source, .position = position };
        const borrowed: input.Event = switch (tag) {
            .entered => .{ .file_drop_entered = borrowed_drop },
            .updated => .{ .file_drop_updated = borrowed_drop },
            .performed => .{ .file_drop_performed = borrowed_drop },
        };
        self.validateInput(&borrowed) catch |err| {
            self.fail(err);
            return;
        };
        _ = event_memory.ensureFits(
            null,
            paths_source,
            self.pending_payload_bytes,
            self.app_config.memory.platform_event_queue_bytes,
        ) catch |err| {
            self.fail(err);
            return;
        };
        const paths = self.allocator.alloc([]const u8, paths_source.len) catch |err| {
            self.fail(err);
            return;
        };
        var initialized: usize = 0;
        for (paths_source, 0..) |path, index| {
            paths[index] = self.allocator.dupe(u8, path) catch |err| {
                for (paths[0..initialized]) |owned| self.allocator.free(@constCast(owned));
                self.allocator.free(paths);
                self.fail(err);
                return;
            };
            initialized += 1;
        }
        const drop: input.FileDrop = .{ .paths = paths, .position = position };
        const event: input.Event = switch (tag) {
            .entered => .{ .file_drop_entered = drop },
            .updated => .{ .file_drop_updated = drop },
            .performed => .{ .file_drop_performed = drop },
        };
        self.appendPending(.{
            .window = window,
            .event = .{ .input = event },
            .owned_paths = paths,
        }) catch |err| {
            for (paths) |owned| self.allocator.free(@constCast(owned));
            self.allocator.free(paths);
            self.fail(err);
            return;
        };
        sys.wake(self.wake_fd);
    }

    fn popEvent(self: *Context) ?Pending {
        if (self.event_cursor >= self.events.items.len) return null;
        const result = self.events.items[self.event_cursor];
        self.event_cursor += 1;
        return result;
    }

    fn releasePending(self: *Context, pending: *const Pending) void {
        if (pending.owned_bytes > self.pending_payload_bytes) return self.fail(error.PlatformFailure);
        self.pending_payload_bytes -= pending.owned_bytes;
    }

    fn validateInput(self: *const Context, event: *const input.Event) Error!void {
        try input.validate(event, .{
            .maximum_payload_bytes = self.app_config.memory.platform_event_payload_bytes,
            .maximum_file_paths = self.app_config.memory.file_drop_path_count,
        });
    }

    fn compactEvents(self: *Context) void {
        if (self.event_cursor == 0) return;
        const remaining = self.events.items.len - self.event_cursor;
        if (remaining != 0) std.mem.copyForwards(Pending, self.events.items[0..remaining], self.events.items[self.event_cursor..]);
        self.events.items.len = remaining;
        self.event_cursor = 0;
    }

    fn fail(self: *Context, err: anyerror) void {
        if (self.failure == null) self.failure = mapError(err);
        self.quit = true;
        sys.wake(self.wake_fd);
    }

    fn deinit(self: *Context) void {
        if (self.portal) |portal| portal.deinit();
        var window_iterator = self.windows.valueIterator();
        while (window_iterator.next()) |window| {
            window.*.deinit();
            self.allocator.destroy(window.*);
        }
        self.windows.deinit();
        self.xids.deinit();
        self.present_events.deinit();
        var buffer_iterator = self.buffers.valueIterator();
        while (buffer_iterator.next()) |buffer| self.allocator.destroy(buffer.*);
        self.buffers.deinit();
        self.pixmaps.deinit();
        var outgoing_iterator = self.outgoing.valueIterator();
        while (outgoing_iterator.next()) |transfer| transfer.deinit(self.allocator);
        self.outgoing.deinit();
        for (self.events.items[self.event_cursor..]) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        if (self.clipboard_text) |value| self.allocator.free(value);
        for (self.cursors) |cursor| if (cursor != 0) protocol.freeCursor(&self.client, &self.writer, cursor) catch {};
        if (self.cursor_font != 0) protocol.closeFont(&self.client, &self.writer, self.cursor_font) catch {};
        if (self.selection_window != 0) protocol.destroyWindow(&self.client, &self.writer, self.selection_window) catch {};
        if (self.colormap != 0) protocol.freeColormap(&self.client, &self.writer, self.colormap) catch {};
        self.keyboard.deinit();
        self.allocator.free(self.formats);
        self.writer.deinit();
        self.client.deinit();
        sys.close(self.wake_fd);
        std.debug.assert(self.retained_text.used_bytes == 0);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub fn create(allocator: std.mem.Allocator, app_config: config.AppConfig) Error!api.Bundle {
    const context = try Context.init(allocator, app_config);
    errdefer context.deinit();
    const renderer = try vulkan.Renderer.create(
        allocator,
        context.surfaceProvider(),
        app_config.gpu,
        app_config.memory,
    );
    errdefer renderer.deinit();
    const text_backend: ?@import("../../../text/api.zig").Backend = if (comptime config.text_enabled) blk: {
        const instance = try in_tree_text.Backend.createInstance(
            allocator,
            app_config.memory.loaded_font_bytes,
            app_config.memory.mapped_font_bytes,
            app_config.memory.font_instance_count,
            app_config.memory.font_catalog_count,
            app_config.memory.font_catalog_bytes,
        );
        errdefer instance.interface().deinit();
        _ = try linux_fonts.discover(allocator, instance);
        break :blk instance.interface();
    } else null;
    errdefer if (text_backend) |backend| backend.deinit();
    const maximum_property_text = context.client.maximumRequestBytes() -| 24;
    if (maximum_property_text == 0) return error.MissingCapability;
    const windows: api.WindowSystem = .{
        .context = context,
        .create_fn = createWindow,
        .destroy_fn = destroyWindow,
        .show_fn = showWindow,
        .title_fn = titleWindow,
        .request_frame_fn = requestFrame,
        .set_cursor_fn = setCursor,
        .command_fn = commandWindow,
        .native_handle_fn = nativeHandle,
        .maximum_text_bytes = @min(app_config.memory.platform_text_bytes, maximum_property_text),
    };
    context.portal = portal_mod.Portal.create(allocator, .{ .context = context, .identifier_fn = portalParentIdentifier }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    };
    const accessibility_adapter: ?@import("../../../a11y/api.zig").Adapter = if (comptime config.accessibility_enabled) linux_a11y.Adapter.create(
        allocator,
        app_config,
        .{ .context = context, .emit_fn = emitAccessibility },
        .{ .context = context, .screen_rect_fn = accessibilityScreenRect, .detach_fn = detachAccessibility },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => null,
    } else null;
    errdefer if (accessibility_adapter) |adapter| adapter.deinit();
    if (accessibility_adapter) |adapter| context.accessibility = linux_a11y.Adapter.fromApi(adapter);
    return .{
        .event_loop = .{
            .context = context,
            .run_fn = run,
            .step_fn = step,
            .wake_fn = wake,
            .request_quit_fn = requestQuit,
            .clock = .{ .context = context, .now_fn = nowOpaque },
        },
        .windows = windows,
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
        .dialogs = if (context.portal) |portal| blk: {
            var dialogs = portal.dialogs();
            dialogs.limits = .{
                .maximum_paths = app_config.memory.file_drop_path_count,
                .maximum_path_bytes = app_config.memory.platform_event_payload_bytes,
                .maximum_suggested_name_bytes = app_config.memory.platform_text_bytes,
            };
            break :blk dialogs;
        } else null,
        .deinit_context = context,
        .deinit_fn = deinitContext,
    };
}

fn cast(raw: *anyopaque) *Context {
    return @ptrCast(@alignCast(raw));
}

fn run(raw: *anyopaque, sink: api.EventSink) Error!void {
    const self = cast(raw);
    if (self.quit) return error.Shutdown;
    while (true) {
        const progressed = try step(raw, sink, true);
        sink.pump();
        if (!progressed) break;
    }
}

fn step(raw: *anyopaque, sink: api.EventSink, wait: bool) Error!bool {
    const self = cast(raw);
    if (self.client.isBroken()) return error.PlatformFailure;
    if (self.failure) |failure| {
        return failure;
    }
    var delivered = false;
    while (self.popEvent()) |pending_value| {
        var pending = pending_value;
        sink.send(pending.window, &pending.event);
        self.releasePending(&pending);
        pending.deinit(self.allocator);
        delivered = true;
    }
    self.compactEvents();
    if (self.quit) return false;

    var handled_packet = false;
    while (try self.client.nextEvent(false)) |packet_value| {
        var packet = packet_value;
        defer packet.deinit();
        try handlePacket(self, packet.bytes);
        handled_packet = true;
    }
    if (self.accessibility) |adapter| {
        while (try adapter.dispatch()) handled_packet = true;
    }
    try flushPendingRelease(self);
    if (!handled_packet and !delivered and wait) {
        var descriptors = [_]sys.linux.pollfd{
            .{ .fd = self.client.descriptor(), .events = sys.linux.POLL.IN, .revents = 0 },
            .{ .fd = self.wake_fd, .events = sys.linux.POLL.IN, .revents = 0 },
            .{ .fd = if (self.accessibility) |adapter| adapter.descriptor() else -1, .events = sys.linux.POLL.IN, .revents = 0 },
        };
        _ = try sys.poll(&descriptors, -1);
        if (descriptors[0].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0)
            return error.PlatformFailure;
        if (descriptors[1].revents & sys.linux.POLL.IN != 0) sys.drainWake(self.wake_fd);
        if (self.accessibility != null and descriptors[2].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0)
            return error.PlatformFailure;
        if (descriptors[0].revents & sys.linux.POLL.IN != 0) {
            if (try self.client.nextEvent(true)) |packet_value| {
                var packet = packet_value;
                defer packet.deinit();
                try handlePacket(self, packet.bytes);
            }
        }
    }
    while (self.popEvent()) |pending_value| {
        var pending = pending_value;
        sink.send(pending.window, &pending.event);
        self.releasePending(&pending);
        pending.deinit(self.allocator);
    }
    self.compactEvents();
    return !self.quit;
}

fn wake(raw: *anyopaque) void {
    sys.wake(cast(raw).wake_fd);
}

fn requestQuit(raw: *anyopaque) void {
    const self = cast(raw);
    self.quit = true;
    sys.wake(self.wake_fd);
}

fn nowOpaque(_: *anyopaque) u64 {
    return sys.monotonicNanoseconds();
}

fn deinitContext(raw: *anyopaque) void {
    cast(raw).deinit();
}

fn createWindow(raw: *anyopaque, id: handles.WindowId, options: api.WindowOptions) Error!api.NativeHandle {
    const self = cast(raw);
    if (self.client.isBroken()) return error.PlatformFailure;
    if (self.windows.contains(id.encode())) return error.ResourceBusy;
    if (self.windows.count() >= self.app_config.memory.window_count) return error.BudgetExceeded;
    try self.windows.ensureUnusedCapacity(1);
    try self.xids.ensureUnusedCapacity(1);
    try self.present_events.ensureUnusedCapacity(1);
    try self.preparePendingSlots(2);
    const xid = try self.client.allocateId();
    const present_event = try self.client.allocateId();
    const width = dimension(options.size.width);
    const height = dimension(options.size.height);
    const x: i16 = if (options.position) |position| coordinate(position.x) else 0;
    const y: i16 = if (options.position) |position| coordinate(position.y) else 0;
    const event_mask = protocol.EventMask.key_press | protocol.EventMask.key_release |
        protocol.EventMask.button_press | protocol.EventMask.button_release |
        protocol.EventMask.enter_window | protocol.EventMask.leave_window |
        protocol.EventMask.pointer_motion | protocol.EventMask.button_motion |
        protocol.EventMask.exposure | protocol.EventMask.visibility_change |
        protocol.EventMask.structure_notify | protocol.EventMask.focus_change |
        protocol.EventMask.property_change;
    var value_mask = protocol.WindowValueMask.background_pixel | protocol.WindowValueMask.border_pixel |
        protocol.WindowValueMask.event_mask;
    var values: [4]u32 = .{ 0, 0, event_mask, 0 };
    var value_count: usize = 3;
    if (self.colormap != 0) {
        value_mask |= protocol.WindowValueMask.colormap;
        values[value_count] = self.colormap;
        value_count += 1;
    }
    try protocol.createWindow(
        &self.client,
        &self.writer,
        self.client.setup.presentation_depth,
        xid,
        self.client.setup.root,
        x,
        y,
        width,
        height,
        self.client.setup.presentation_visual,
        value_mask,
        values[0..value_count],
    );
    errdefer protocol.destroyWindow(&self.client, &self.writer, xid) catch {};
    try protocol.presentSelectInput(&self.client, &self.writer, self.present, present_event, xid, present_event_configure | present_event_complete | present_event_idle);
    try setWindowProperties(self, xid, options);
    const native = try self.allocator.create(NativeWindow);
    errdefer self.allocator.destroy(native);
    native.* = .{
        .context = self,
        .id = id,
        .xid = xid,
        .present_event = present_event,
        .logical_size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        .position = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
        .scale_factor = self.scale_factor,
        .visible = options.visible,
    };
    if (options.visible) try protocol.mapWindow(&self.client, &self.writer, xid);
    self.windows.putAssumeCapacity(id.encode(), native);
    self.xids.putAssumeCapacity(xid, native);
    self.present_events.putAssumeCapacity(present_event, native);
    self.events.appendAssumeCapacity(.{
        .window = id,
        .event = .{ .created = .{ .kind = .x11, .value = xid } },
    });
    self.events.appendAssumeCapacity(.{
        .window = id,
        .event = .{ .configured = .{ .logical_size = native.logical_size, .scale_factor = native.scale_factor } },
    });
    sys.wake(self.wake_fd);
    return .{ .kind = .x11, .value = xid };
}

fn destroyWindow(raw: *anyopaque, id: handles.WindowId) void {
    const self = cast(raw);
    const removed = self.windows.fetchRemove(id.encode()) orelse return;
    const native = removed.value;
    if (self.pointer_window == native) self.pointer_window = null;
    if (self.pending_release) |pending| {
        if (pending.window == native) self.pending_release = null;
    }
    if (self.dnd) |dnd| {
        if (dnd.window == native) self.dnd = null;
    }
    _ = self.xids.remove(native.xid);
    _ = self.present_events.remove(native.present_event);
    if (!native.destroyed) protocol.destroyWindow(&self.client, &self.writer, native.xid) catch |err| self.fail(err);
    if (!native.close_notified) self.queue(id, .closed);
    native.deinit();
    self.allocator.destroy(native);
}

fn showWindow(raw: *anyopaque, id: handles.WindowId, visible: bool) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (native.visible == visible) return;
    if (visible) {
        if (native.configured and !native.present_pending) try self.preparePendingSlots(1);
        try protocol.mapWindow(&self.client, &self.writer, native.xid);
        native.visible = true;
        try requestFrame(raw, id);
    } else {
        try protocol.unmapWindow(&self.client, &self.writer, native.xid);
        native.visible = false;
        native.frame_wanted = false;
    }
}

fn titleWindow(raw: *anyopaque, id: handles.WindowId, title: []const u8) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    try setTitle(self, native.xid, title);
}

fn requestFrame(raw: *anyopaque, id: handles.WindowId) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (!native.visible or !native.configured) return;
    if (!native.present_pending) {
        try self.preparePendingSlots(1);
        self.events.appendAssumeCapacity(.{
            .window = id,
            .event = .{ .frame_requested = sys.monotonicNanoseconds() },
        });
        sys.wake(self.wake_fd);
    } else {
        native.frame_wanted = true;
    }
}

fn setCursor(raw: *anyopaque, id: handles.WindowId, cursor: api.Cursor) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    const cursor_id = self.cursors[@backingInt(cursor)];
    if (cursor_id == 0) return error.MissingCapability;
    try protocol.changeWindowAttributes(&self.client, &self.writer, native.xid, protocol.WindowValueMask.cursor, &.{cursor_id});
    native.cursor = cursor;
}

fn commandWindow(raw: *anyopaque, id: handles.WindowId, command: api.WindowCommand) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    switch (command) {
        .move => |position| {
            const values = [_]u32{
                @bitCast(saturatedI32(position.x)),
                @bitCast(saturatedI32(position.y)),
            };
            try protocol.configureWindow(&self.client, &self.writer, native.xid, protocol.ConfigureMask.x | protocol.ConfigureMask.y, &values);
        },
        .resize => |size| {
            const values = [_]u32{
                dimension32(size.width),
                dimension32(size.height),
            };
            try protocol.configureWindow(&self.client, &self.writer, native.xid, protocol.ConfigureMask.width | protocol.ConfigureMask.height, &values);
        },
        .mode => |mode| switch (mode) {
            .normal => {
                try sendWmState(self, native.xid, 0, self.atoms.net_wm_state_fullscreen, 0);
                try sendWmState(self, native.xid, 0, self.atoms.net_wm_state_maximized_vert, self.atoms.net_wm_state_maximized_horz);
                if (!native.visible) try showWindow(raw, id, true);
            },
            .minimized => try sendIconify(self, native.xid),
            .maximized => try sendWmState(self, native.xid, 1, self.atoms.net_wm_state_maximized_vert, self.atoms.net_wm_state_maximized_horz),
            .fullscreen => try sendWmState(self, native.xid, 1, self.atoms.net_wm_state_fullscreen, 0),
        },
    }
}

fn sendWmState(self: *Context, xid: u32, action: u32, first: u32, second: u32) Error!void {
    var event: [32]u8 = @splat(0);
    event[0] = 33;
    event[1] = 32;
    std.mem.writeInt(u32, event[4..8], xid, .little);
    std.mem.writeInt(u32, event[8..12], self.atoms.net_wm_state, .little);
    std.mem.writeInt(u32, event[12..16], action, .little);
    std.mem.writeInt(u32, event[16..20], first, .little);
    std.mem.writeInt(u32, event[20..24], second, .little);
    std.mem.writeInt(u32, event[24..28], 1, .little);
    try protocol.sendEvent(&self.client, &self.writer, false, self.client.setup.root, (1 << 19) | (1 << 20), &event);
}

fn sendIconify(self: *Context, xid: u32) Error!void {
    var event: [32]u8 = @splat(0);
    event[0] = 33;
    event[1] = 32;
    std.mem.writeInt(u32, event[4..8], xid, .little);
    std.mem.writeInt(u32, event[8..12], self.atoms.wm_change_state, .little);
    std.mem.writeInt(u32, event[12..16], 3, .little);
    try protocol.sendEvent(&self.client, &self.writer, false, self.client.setup.root, (1 << 19) | (1 << 20), &event);
}

fn listDisplays(raw: *anyopaque, allocator: std.mem.Allocator) Error!api.OwnedDisplays {
    const self = cast(raw);
    const desktop_work_area = try readDesktopWorkArea(self, allocator);
    if (self.randr) |randr| {
        var monitors = try protocol.randrGetMonitors(
            &self.client,
            &self.writer,
            allocator,
            randr,
            self.client.setup.root,
            self.app_config.memory.platform_object_count,
        );
        defer monitors.deinit();
        var values: std.ArrayList(api.Display) = .empty;
        errdefer {
            for (values.items) |display| allocator.free(@constCast(display.name));
            values.deinit(allocator);
        }
        for (monitors.values, 0..) |monitor, index| {
            if (monitor.width == 0 or monitor.height == 0) continue;
            const name = try monitorName(self, allocator, monitor.name_atom, index);
            const bounds = geometry.Rect.fromXYWH(
                @floatFromInt(monitor.x),
                @floatFromInt(monitor.y),
                @floatFromInt(monitor.width),
                @floatFromInt(monitor.height),
            );
            const id = if (monitor.name_atom != 0 or monitor.first_output != 0)
                (@as(u64, monitor.name_atom) << 32) | @as(u64, monitor.first_output)
            else
                (@as(u64, self.client.setup.root) << 32) | @as(u64, @intCast(index + 1));
            values.append(allocator, .{
                .id = id,
                .name = name,
                .bounds = bounds,
                .work_area = if (desktop_work_area) |work_area| geometry.Rect.intersection(bounds, work_area) orelse bounds else bounds,
                .scale_factor = self.scale_factor,
                .physical_size_mm = .{
                    .width = @floatFromInt(monitor.width_mm),
                    .height = @floatFromInt(monitor.height_mm),
                },
                .primary = monitor.primary,
            }) catch |err| {
                allocator.free(name);
                return err;
            };
        }
        if (values.items.len != 0) {
            std.mem.sort(api.Display, values.items, {}, struct {
                fn less(_: void, a: api.Display, b: api.Display) bool {
                    if (a.primary != b.primary) return a.primary;
                    if (a.bounds.origin.y != b.bounds.origin.y) return a.bounds.origin.y < b.bounds.origin.y;
                    if (a.bounds.origin.x != b.bounds.origin.x) return a.bounds.origin.x < b.bounds.origin.x;
                    return a.id < b.id;
                }
            }.less);
            var has_primary = false;
            for (values.items) |display| has_primary = has_primary or display.primary;
            if (!has_primary) values.items[0].primary = true;
            return .{ .allocator = allocator, .values = try values.toOwnedSlice(allocator) };
        }
    }
    return rootDisplay(self, allocator, desktop_work_area);
}

fn monitorName(self: *Context, allocator: std.mem.Allocator, atom: u32, index: usize) Error![]u8 {
    if (atom != 0) {
        const candidate: ?[]u8 = protocol.getAtomName(&self.client, &self.writer, allocator, atom) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
        if (candidate) |name| {
            if (name.len != 0 and std.unicode.utf8ValidateSlice(name)) return name;
            allocator.free(name);
        }
    }
    return std.fmt.allocPrint(allocator, "X11 monitor {d}", .{index + 1});
}

fn readDesktopWorkArea(self: *Context, allocator: std.mem.Allocator) Error!?geometry.Rect {
    var desktop_property = try protocol.getProperty(
        &self.client,
        &self.writer,
        allocator,
        false,
        self.client.setup.root,
        self.atoms.net_current_desktop,
        atom_cardinal,
        0,
        1,
    );
    defer desktop_property.deinit();
    const desktop = if (desktop_property.property_type == atom_cardinal and desktop_property.format == 32 and desktop_property.value.len >= 4)
        try wire.readU32(desktop_property.value, 0)
    else
        0;
    const offset = std.math.mul(u32, desktop, 4) catch return null;
    var work_property = try protocol.getProperty(
        &self.client,
        &self.writer,
        allocator,
        false,
        self.client.setup.root,
        self.atoms.net_workarea,
        atom_cardinal,
        offset,
        4,
    );
    defer work_property.deinit();
    if (work_property.property_type != atom_cardinal or work_property.format != 32 or work_property.value.len < 16) return null;
    const width = try wire.readU32(work_property.value, 8);
    const height = try wire.readU32(work_property.value, 12);
    if (width == 0 or height == 0) return null;
    return geometry.Rect.fromXYWH(
        @floatFromInt(try wire.readU32(work_property.value, 0)),
        @floatFromInt(try wire.readU32(work_property.value, 4)),
        @floatFromInt(width),
        @floatFromInt(height),
    );
}

fn rootDisplay(self: *Context, allocator: std.mem.Allocator, desktop_work_area: ?geometry.Rect) Error!api.OwnedDisplays {
    const values = try allocator.alloc(api.Display, 1);
    errdefer allocator.free(values);
    const name = try allocator.dupe(u8, "X11 root screen");
    const bounds = geometry.Rect.fromXYWH(
        0,
        0,
        @floatFromInt(self.client.setup.width_pixels),
        @floatFromInt(self.client.setup.height_pixels),
    );
    values[0] = .{
        .id = self.client.setup.root,
        .name = name,
        .bounds = bounds,
        .work_area = if (desktop_work_area) |work_area| geometry.Rect.intersection(bounds, work_area) orelse bounds else bounds,
        .scale_factor = self.scale_factor,
        .primary = true,
    };
    return .{ .allocator = allocator, .values = values };
}

fn dimension32(value: f32) u32 {
    return @intFromFloat(std.math.clamp(@round(value), 1, @as(f32, @floatFromInt(std.math.maxInt(u16)))));
}

fn nativeHandle(raw: *anyopaque, id: handles.WindowId) ?api.NativeHandle {
    const native = cast(raw).windows.get(id.encode()) orelse return null;
    return .{ .kind = .x11, .value = native.xid };
}

fn portalParentIdentifier(raw: *anyopaque, id: handles.WindowId, allocator: std.mem.Allocator) Error![]u8 {
    const native = cast(raw).windows.get(id.encode()) orelse return error.InvalidHandle;
    return std.fmt.allocPrint(allocator, "x11:{x}", .{native.xid});
}

fn emitAccessibility(raw: *anyopaque, request: @import("../../../a11y/api.zig").ActionRequest) void {
    cast(raw).queueAccessibility(request);
}

fn detachAccessibility(raw: *anyopaque, adapter: *linux_a11y.Adapter) void {
    const context = cast(raw);
    if (context.accessibility == adapter) context.accessibility = null;
}

fn accessibilityScreenRect(raw: *anyopaque, id: handles.WindowId, source: geometry.Rect) geometry.Rect {
    const native = cast(raw).windows.get(id.encode()) orelse return .{};
    const scale = native.scale_factor.value;
    return .{
        .origin = .{
            .x = native.position.x + source.origin.x * scale,
            .y = native.position.y + source.origin.y * scale,
        },
        .size = .{ .width = source.size.width * scale, .height = source.size.height * scale },
    };
}

fn explicitSyncAvailable(_: *anyopaque) bool {
    return false;
}

fn supportedFormats(raw: *anyopaque) []const surface_api.Format {
    return cast(raw).formats;
}

fn importBuffer(raw: *anyopaque, descriptor: surface_api.DmabufDescriptor) Error!surface_api.BufferHandle {
    const self = cast(raw);
    if (descriptor.width == 0 or descriptor.height == 0 or descriptor.width > std.math.maxInt(u16) or
        descriptor.height > std.math.maxInt(u16) or descriptor.planes.len != 1 or
        descriptor.fourcc != vulkan_device.drm_format_argb8888) return error.InvalidConfiguration;
    if (self.buffers.count() >= self.app_config.memory.platform_object_count)
        return error.BudgetExceeded;
    try self.buffers.ensureUnusedCapacity(1);
    try self.pixmaps.ensureUnusedCapacity(1);
    const pixmap = try self.client.allocateId();
    const plane = descriptor.planes[0];
    try protocol.dri3PixmapFromBuffers(
        &self.client,
        &self.writer,
        self.dri3,
        pixmap,
        self.client.setup.root,
        @intCast(descriptor.width),
        @intCast(descriptor.height),
        plane.stride,
        plane.offset,
        self.client.setup.presentation_depth,
        self.client.setup.presentation_format.bits_per_pixel,
        plane.modifier,
        plane.descriptor,
    );
    errdefer protocol.freePixmap(&self.client, &self.writer, pixmap) catch {};
    const buffer = try self.allocator.create(Buffer);
    errdefer self.allocator.destroy(buffer);
    buffer.* = .{ .pixmap = pixmap };
    self.buffers.putAssumeCapacity(pixmap, buffer);
    self.pixmaps.putAssumeCapacity(pixmap, buffer);
    return pixmap;
}

fn destroyBuffer(raw: *anyopaque, handle: surface_api.BufferHandle) void {
    const self = cast(raw);
    const removed = self.buffers.fetchRemove(handle) orelse return;
    _ = self.pixmaps.remove(removed.value.pixmap);
    protocol.freePixmap(&self.client, &self.writer, removed.value.pixmap) catch |err| self.fail(err);
    self.allocator.destroy(removed.value);
}

fn bufferReleased(raw: *anyopaque, handle: surface_api.BufferHandle) bool {
    return if (cast(raw).buffers.get(handle)) |buffer| buffer.released else false;
}

fn importTimeline(_: *anyopaque, _: sys.fd_t) Error!surface_api.TimelineHandle {
    return error.MissingCapability;
}

fn destroyTimeline(_: *anyopaque, _: surface_api.TimelineHandle) void {}

fn presentBuffer(raw: *anyopaque, presentation: surface_api.Presentation) Error!void {
    const self = cast(raw);
    if (presentation.acquire != null or presentation.release != null) return error.InvalidConfiguration;
    const native = self.windows.get(presentation.window.encode()) orelse return error.InvalidHandle;
    if (!native.visible or !native.configured) return error.SurfaceUnavailable;
    const buffer = self.buffers.get(presentation.buffer) orelse return error.InvalidHandle;
    if (!buffer.released) return error.ResourceBusy;
    const serial = self.next_present_serial;
    self.next_present_serial +%= 1;
    if (self.next_present_serial == 0) self.next_present_serial = 1;
    try protocol.presentPixmap(&self.client, &self.writer, self.present, native.xid, buffer.pixmap, serial);
    buffer.released = false;
    buffer.last_serial = serial;
    native.present_pending = true;
}

fn handlePacket(self: *Context, bytes: []const u8) Error!void {
    if (bytes.len < 32) return error.PlatformFailure;
    const event_type = bytes[0] & 0x7f;
    if (event_type == protocol.EventType.key_press) {
        if (self.pending_release) |release| {
            if (release.keycode == bytes[1] and release.timestamp == try wire.readU32(bytes, 4)) {
                self.pending_release = null;
                try handleKeyPress(self, bytes, true);
                return;
            }
        }
    }
    if (event_type != protocol.EventType.key_release) try flushPendingRelease(self);
    switch (event_type) {
        protocol.EventType.key_press => try handleKeyPress(self, bytes, false),
        protocol.EventType.key_release => {
            const native = self.xids.get(try wire.readU32(bytes, 12)) orelse return;
            self.pending_release = .{
                .window = native,
                .keycode = bytes[1],
                .state = try wire.readU16(bytes, 28),
                .timestamp = try wire.readU32(bytes, 4),
            };
        },
        protocol.EventType.button_press, protocol.EventType.button_release => try handleButton(self, bytes, event_type == protocol.EventType.button_press),
        protocol.EventType.motion_notify => try handleMotion(self, bytes),
        protocol.EventType.enter_notify => try handleCrossing(self, bytes, true),
        protocol.EventType.leave_notify => try handleCrossing(self, bytes, false),
        protocol.EventType.focus_in, protocol.EventType.focus_out => {
            const native = self.xids.get(try wire.readU32(bytes, 4)) orelse return;
            const focused = event_type == protocol.EventType.focus_in;
            try self.preparePendingSlots(2);
            if (!focused) native.pending_dead = null;
            self.events.appendAssumeCapacity(.{ .window = native.id, .event = .{ .focused = focused } });
            self.events.appendAssumeCapacity(.{
                .window = native.id,
                .event = .{ .input = if (focused) .focus_in else .focus_out },
            });
            sys.wake(self.wake_fd);
        },
        protocol.EventType.expose => {
            const native = self.xids.get(try wire.readU32(bytes, 4)) orelse return;
            if (!native.present_pending) self.queue(native.id, .{ .frame_requested = sys.monotonicNanoseconds() });
        },
        protocol.EventType.visibility_notify => {
            const native = self.xids.get(try wire.readU32(bytes, 4)) orelse return;
            self.queue(native.id, .{ .occluded = bytes[8] == 2 });
        },
        protocol.EventType.configure_notify => try handleConfigure(self, bytes),
        protocol.EventType.destroy_notify => {
            const native = self.xids.get(try wire.readU32(bytes, 8)) orelse return;
            native.destroyed = true;
            native.visible = false;
            native.configured = false;
            if (!native.close_notified) {
                native.close_notified = true;
                self.queue(native.id, .closed);
            }
        },
        protocol.EventType.client_message => try handleClientMessage(self, bytes),
        protocol.EventType.selection_request => try handleSelectionRequest(self, bytes),
        protocol.EventType.selection_notify => try handleSelectionNotify(self, bytes),
        protocol.EventType.selection_clear => if (try wire.readU32(bytes, 8) == self.atoms.clipboard) {
            if (self.clipboard_text) |value| self.allocator.free(value);
            self.clipboard_text = null;
        },
        protocol.EventType.property_notify => try handlePropertyNotify(self, bytes),
        protocol.EventType.mapping_notify => try self.keyboard.reload(&self.client, &self.writer),
        protocol.EventType.generic_event => try handleGenericEvent(self, bytes),
        else => {},
    }
}

fn handleKeyPress(self: *Context, bytes: []const u8, repeat: bool) Error!void {
    const native = self.xids.get(try wire.readU32(bytes, 12)) orelse return;
    const timestamp = try wire.readU32(bytes, 4);
    var decoded = self.keyboard.decode(bytes[1], try wire.readU16(bytes, 28), repeat, self.timestamps.extend(timestamp));
    if (native.pending_dead != null) decoded.event.composing = true;
    self.queue(native.id, .{ .input = .{ .key_down = decoded.event } });
    if (!native.text_input_active or decoded.event.modifiers.control or decoded.event.modifiers.alt or decoded.event.modifiers.command) return;
    if (decoded.dead_mark) |mark| {
        native.pending_dead = mark;
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(mark, &encoded) catch return error.InvalidUtf8;
        self.queueIme(native.id, .{ .set_marked_text = .{
            .text = encoded[0..length],
            .selected_utf8 = .{ .start = length, .end = length },
            .replacement_utf8 = null,
        } }, encoded[0..length]);
        return;
    }
    if (decoded.scalar) |scalar| {
        var encoded: [8]u8 = undefined;
        var length: usize = 0;
        if (native.pending_dead) |mark| {
            if (keyboard_mod.compose(scalar, mark)) |composed| {
                length = std.unicode.utf8Encode(composed, encoded[0..4]) catch return error.InvalidUtf8;
            } else {
                length = std.unicode.utf8Encode(scalar, encoded[0..4]) catch return error.InvalidUtf8;
                length += std.unicode.utf8Encode(mark, encoded[length..]) catch return error.InvalidUtf8;
            }
            native.pending_dead = null;
        } else length = std.unicode.utf8Encode(scalar, encoded[0..4]) catch return error.InvalidUtf8;
        self.queueIme(native.id, .{ .commit_text = .{ .text = encoded[0..length], .replacement_utf8 = null } }, encoded[0..length]);
    } else if (switch (decoded.event.key) {
        .escape => true,
        else => false,
    } and native.pending_dead != null) {
        native.pending_dead = null;
        self.queue(native.id, .{ .input = .{ .ime = .cancel_composition } });
    }
}

fn flushPendingRelease(self: *Context) Error!void {
    const release = self.pending_release orelse return;
    self.pending_release = null;
    const decoded = self.keyboard.decode(release.keycode, release.state, false, self.timestamps.extend(release.timestamp));
    self.queue(release.window.id, .{ .input = .{ .key_up = decoded.event } });
}

fn handleButton(self: *Context, bytes: []const u8, pressed: bool) Error!void {
    const native = self.xids.get(try wire.readU32(bytes, 12)) orelse return;
    self.pointer_window = native;
    self.pointer_position = .{ .x = @floatFromInt(try wire.readI16(bytes, 24)), .y = @floatFromInt(try wire.readI16(bytes, 26)) };
    const detail = bytes[1];
    const timestamp = self.timestamps.extend(try wire.readU32(bytes, 4));
    const modifiers = keyboard_mod.decodeModifiers(try wire.readU16(bytes, 28));
    if (detail >= 4 and detail <= 7) {
        if (pressed) {
            const delta: geometry.Point = switch (detail) {
                4 => .{ .x = 0, .y = -40 },
                5 => .{ .x = 0, .y = 40 },
                6 => .{ .x = -40, .y = 0 },
                else => .{ .x = 40, .y = 0 },
            };
            self.queue(native.id, .{ .input = .{ .scroll = .{
                .position = self.pointer_position,
                .delta = delta,
                .precise = false,
                .phase = .changed,
                .modifiers = modifiers,
                .timestamp_ns = timestamp,
            } } });
        }
        return;
    }
    const button = mouseButton(detail);
    const mask = buttonMask(button);
    if (pressed) self.buttons |= mask else self.buttons &= ~mask;
    const event: input.PointerEvent = .{
        .position = self.pointer_position,
        .button = button,
        .buttons = self.buttons,
        .modifiers = modifiers,
        .timestamp_ns = timestamp,
    };
    self.queue(native.id, .{ .input = if (pressed) .{ .pointer_down = event } else .{ .pointer_up = event } });
}

fn handleMotion(self: *Context, bytes: []const u8) Error!void {
    const native = self.xids.get(try wire.readU32(bytes, 12)) orelse return;
    const previous = self.pointer_position;
    self.pointer_window = native;
    self.pointer_position = .{ .x = @floatFromInt(try wire.readI16(bytes, 24)), .y = @floatFromInt(try wire.readI16(bytes, 26)) };
    self.queue(native.id, .{ .input = .{ .pointer_move = .{
        .position = self.pointer_position,
        .delta = self.pointer_position.sub(previous),
        .buttons = self.buttons,
        .modifiers = keyboard_mod.decodeModifiers(try wire.readU16(bytes, 28)),
        .timestamp_ns = self.timestamps.extend(try wire.readU32(bytes, 4)),
    } } });
}

fn handleCrossing(self: *Context, bytes: []const u8, entered: bool) Error!void {
    const native = self.xids.get(try wire.readU32(bytes, 12)) orelse return;
    self.pointer_window = if (entered) native else null;
    self.pointer_position = .{ .x = @floatFromInt(try wire.readI16(bytes, 24)), .y = @floatFromInt(try wire.readI16(bytes, 26)) };
    const event: input.PointerEvent = .{
        .position = self.pointer_position,
        .buttons = self.buttons,
        .modifiers = keyboard_mod.decodeModifiers(try wire.readU16(bytes, 28)),
        .timestamp_ns = self.timestamps.extend(try wire.readU32(bytes, 4)),
    };
    self.queue(native.id, .{ .input = if (entered) .{ .pointer_enter = event } else .{ .pointer_leave = event } });
}

fn handleConfigure(self: *Context, bytes: []const u8) Error!void {
    const native = self.xids.get(try wire.readU32(bytes, 8)) orelse return;
    const position: geometry.Point = .{ .x = @floatFromInt(try wire.readI16(bytes, 12)), .y = @floatFromInt(try wire.readI16(bytes, 14)) };
    const size: geometry.Size = .{ .width = @floatFromInt(try wire.readU16(bytes, 16)), .height = @floatFromInt(try wire.readU16(bytes, 18)) };
    const moved = !std.meta.eql(native.position, position);
    const resized = !std.meta.eql(native.logical_size, size);
    const event_count: usize = @intFromBool(moved) + 2 * @as(usize, @intFromBool(resized));
    try self.preparePendingSlots(event_count);
    if (moved) {
        native.position = position;
        self.events.appendAssumeCapacity(.{ .window = native.id, .event = .{ .moved = position } });
    }
    if (resized) {
        native.logical_size = size;
        self.events.appendAssumeCapacity(.{ .window = native.id, .event = .{ .resized = size } });
        self.events.appendAssumeCapacity(.{
            .window = native.id,
            .event = .{ .configured = .{ .logical_size = size, .scale_factor = native.scale_factor } },
        });
    }
    if (event_count != 0) sys.wake(self.wake_fd);
}

fn handleClientMessage(self: *Context, bytes: []const u8) Error!void {
    if (bytes[1] != 32) return;
    const native = self.xids.get(try wire.readU32(bytes, 4)) orelse return;
    const message_type = try wire.readU32(bytes, 8);
    if (message_type == self.atoms.wm_protocols and try wire.readU32(bytes, 12) == self.atoms.wm_delete_window) {
        self.queue(native.id, .close_requested);
        return;
    }
    if (message_type == self.atoms.xdnd_enter or message_type == self.atoms.xdnd_position or
        message_type == self.atoms.xdnd_leave or message_type == self.atoms.xdnd_drop)
        try handleDndMessage(self, native, message_type, bytes[12..32]);
}

fn handleGenericEvent(self: *Context, bytes: []const u8) Error!void {
    if (bytes[1] != self.present.opcode or bytes.len < 32) return;
    const event_type = try wire.readU16(bytes, 8);
    if (event_type == 2) {
        const pixmap = try wire.readU32(bytes, 24);
        if (self.pixmaps.get(pixmap)) |buffer| buffer.released = true;
        return;
    }
    const event_id = try wire.readU32(bytes, 12);
    const native = self.present_events.get(event_id) orelse return;
    switch (event_type) {
        0 => {},
        1 => {
            if (native.frame_wanted and native.visible) try self.preparePendingSlots(1);
            native.present_pending = false;
            if (native.frame_wanted and native.visible) {
                native.frame_wanted = false;
                self.events.appendAssumeCapacity(.{
                    .window = native.id,
                    .event = .{ .frame_requested = sys.monotonicNanoseconds() },
                });
                sys.wake(self.wake_fd);
            }
        },
        else => {},
    }
}

fn setTextInputActive(raw: *anyopaque, id: handles.WindowId, active: bool) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    native.text_input_active = active;
    if (!active) {
        native.pending_dead = null;
        self.retained_text.release(self.allocator, &native.surrounding_text);
        native.selection = .{ .start = 0, .end = 0 };
    }
}

fn setCandidateRect(raw: *anyopaque, id: handles.WindowId, rect: geometry.Rect) Error!void {
    const native = cast(raw).windows.get(id.encode()) orelse return error.InvalidHandle;
    native.candidate_rect = rect;
}

fn setSurroundingText(raw: *anyopaque, id: handles.WindowId, text: []const u8, selection: input.TextRange) Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    const native = cast(raw).windows.get(id.encode()) orelse return error.InvalidHandle;
    if (selection.start > text.len or selection.end > text.len) return error.InvalidConfiguration;
    try native.context.retained_text.replace(native.context.allocator, &native.surrounding_text, text);
    native.selection = selection;
}

fn writeClipboard(raw: *anyopaque, value: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    const self = cast(raw);
    const old_bytes = if (self.clipboard_text) |old| old.len else 0;
    const retained_without_current = self.clipboard_owned_bytes - old_bytes;
    if (value.len > self.app_config.memory.clipboard_retained_bytes -| retained_without_current)
        return error.BudgetExceeded;
    const copy = try self.allocator.dupe(u8, value);
    var copy_owned = true;
    errdefer if (copy_owned) self.allocator.free(copy);
    try protocol.setSelectionOwner(&self.client, &self.writer, self.selection_window, self.atoms.clipboard, protocol.current_time);
    if (self.clipboard_text) |old| self.allocator.free(old);
    self.clipboard_text = copy;
    self.clipboard_owned_bytes = retained_without_current + copy.len;
    copy_owned = false;
}

fn readClipboard(raw: *anyopaque, allocator: std.mem.Allocator) Error!?[]u8 {
    const self = cast(raw);
    if (self.clipboard_text) |value| return try allocator.dupe(u8, value);
    try protocol.deleteProperty(&self.client, &self.writer, self.selection_window, self.atoms.selection_property);
    try protocol.convertSelection(
        &self.client,
        &self.writer,
        self.selection_window,
        self.atoms.clipboard,
        self.atoms.utf8_string,
        self.atoms.selection_property,
        protocol.current_time,
    );
    while (true) {
        var packet = (try self.client.nextEvent(true)) orelse continue;
        defer packet.deinit();
        const event_type = packet.responseType();
        if (event_type == protocol.EventType.selection_notify and
            try wire.readU32(packet.bytes, 8) == self.selection_window and
            try wire.readU32(packet.bytes, 12) == self.atoms.clipboard)
        {
            const property_atom = try wire.readU32(packet.bytes, 20);
            if (property_atom == protocol.none) return null;
            var property = try protocol.getProperty(
                &self.client,
                &self.writer,
                allocator,
                true,
                self.selection_window,
                property_atom,
                protocol.none,
                0,
                propertyLongLength(self.app_config.memory.clipboard_bytes),
            );
            if (property.property_type != self.atoms.incr) return property.value;
            property.deinit();
            return try receiveIncremental(self, allocator, property_atom, self.app_config.memory.clipboard_bytes);
        }
        try handlePacket(self, packet.bytes);
    }
}

fn handleSelectionRequest(self: *Context, bytes: []const u8) Error!void {
    var registered_transfer: ?u64 = null;
    errdefer if (registered_transfer) |key| removeOutgoing(self, key);
    const time = try wire.readU32(bytes, 4);
    const requestor = try wire.readU32(bytes, 8);
    const selection = try wire.readU32(bytes, 12);
    const target = try wire.readU32(bytes, 16);
    const requested_property = try wire.readU32(bytes, 20);
    const property = if (requested_property == protocol.none) target else requested_property;
    var success = false;
    if (selection == self.atoms.clipboard and self.clipboard_text != null) {
        if (target == self.atoms.targets) {
            const targets = [_]u32{ self.atoms.targets, self.atoms.utf8_string, self.atoms.text, atom_string };
            try protocol.changeProperty(&self.client, &self.writer, .replace, requestor, property, atom_atom, 32, std.mem.sliceAsBytes(&targets));
            success = true;
        } else if (target == self.atoms.utf8_string or target == self.atoms.text or target == atom_string) {
            const value = self.clipboard_text.?;
            const maximum_chunk = maximumPropertyChunk(&self.client);
            if (value.len <= maximum_chunk) {
                try protocol.changeProperty(&self.client, &self.writer, .replace, requestor, property, target, 8, value);
            } else {
                const length: u32 = @intCast(@min(value.len, std.math.maxInt(u32)));
                const key = transferKey(requestor, property);
                removeOutgoing(self, key);
                if (self.outgoing.count() >= self.app_config.memory.platform_object_count or
                    value.len > self.app_config.memory.clipboard_retained_bytes -| self.clipboard_owned_bytes)
                    return error.BudgetExceeded;
                try self.outgoing.ensureUnusedCapacity(1);
                const snapshot = try self.allocator.dupe(u8, value);
                var snapshot_owned = true;
                errdefer if (snapshot_owned) self.allocator.free(snapshot);
                try protocol.changeProperty(&self.client, &self.writer, .replace, requestor, property, self.atoms.incr, 32, std.mem.asBytes(&length));
                try protocol.changeWindowAttributes(&self.client, &self.writer, requestor, protocol.WindowValueMask.event_mask, &.{protocol.EventMask.property_change});
                self.outgoing.putAssumeCapacity(key, .{
                    .requestor = requestor,
                    .property = property,
                    .target = target,
                    .data = snapshot,
                });
                snapshot_owned = false;
                self.clipboard_owned_bytes += snapshot.len;
                registered_transfer = key;
            }
            success = true;
        }
    }
    try sendSelectionNotify(self, requestor, selection, target, if (success) property else protocol.none, time);
}

fn handlePropertyNotify(self: *Context, bytes: []const u8) Error!void {
    if (bytes[16] != 1) return;
    const window = try wire.readU32(bytes, 4);
    const property = try wire.readU32(bytes, 8);
    const key = transferKey(window, property);
    const transfer = self.outgoing.getPtr(key) orelse return;
    const maximum_chunk = maximumPropertyChunk(&self.client);
    const remaining = transfer.data.len -| transfer.cursor;
    const count = @min(remaining, maximum_chunk);
    try protocol.changeProperty(
        &self.client,
        &self.writer,
        .replace,
        transfer.requestor,
        transfer.property,
        transfer.target,
        8,
        transfer.data[transfer.cursor..][0..count],
    );
    transfer.cursor += count;
    if (count == 0) removeOutgoing(self, key);
}

fn receiveIncremental(self: *Context, allocator: std.mem.Allocator, property_atom: u32, maximum_bytes: usize) Error![]u8 {
    return receiveIncrementalOnWindow(self, allocator, self.selection_window, property_atom, maximum_bytes);
}

fn receiveIncrementalOnWindow(
    self: *Context,
    allocator: std.mem.Allocator,
    window: u32,
    property_atom: u32,
    maximum_bytes: usize,
) Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    while (true) {
        var packet = (try self.client.nextEvent(true)) orelse continue;
        defer packet.deinit();
        if (packet.responseType() == protocol.EventType.property_notify and
            try wire.readU32(packet.bytes, 4) == window and
            try wire.readU32(packet.bytes, 8) == property_atom and packet.bytes[16] == 0)
        {
            var property = try protocol.getProperty(
                &self.client,
                &self.writer,
                allocator,
                true,
                window,
                property_atom,
                protocol.none,
                0,
                propertyLongLength(maximum_bytes),
            );
            defer property.deinit();
            if (property.value.len == 0) return result.toOwnedSlice(allocator);
            if (property.value.len > maximum_bytes -| result.items.len) return error.BudgetExceeded;
            try result.appendSlice(allocator, property.value);
            continue;
        }
        try handlePacket(self, packet.bytes);
    }
}

fn sendSelectionNotify(self: *Context, requestor: u32, selection: u32, target: u32, property: u32, time: u32) Error!void {
    var event: [32]u8 = @splat(0);
    event[0] = protocol.EventType.selection_notify;
    std.mem.writeInt(u32, event[4..8], time, .little);
    std.mem.writeInt(u32, event[8..12], requestor, .little);
    std.mem.writeInt(u32, event[12..16], selection, .little);
    std.mem.writeInt(u32, event[16..20], target, .little);
    std.mem.writeInt(u32, event[20..24], property, .little);
    try protocol.sendEvent(&self.client, &self.writer, false, requestor, 0, &event);
}

fn handleSelectionNotify(self: *Context, bytes: []const u8) Error!void {
    if (try wire.readU32(bytes, 12) != self.atoms.xdnd_selection) return;
    const dnd = self.dnd orelse return;
    const requestor = try wire.readU32(bytes, 8);
    if (requestor != dnd.window.xid) return;
    const property_atom = try wire.readU32(bytes, 20);
    if (property_atom == protocol.none) {
        try sendDndFinished(self, dnd, false);
        self.dnd = null;
        return;
    }
    var property = try protocol.getProperty(
        &self.client,
        &self.writer,
        self.allocator,
        true,
        requestor,
        property_atom,
        protocol.none,
        0,
        propertyLongLength(self.app_config.memory.platform_event_payload_bytes),
    );
    var bytes_owned: []u8 = undefined;
    if (property.property_type == self.atoms.incr) {
        property.deinit();
        bytes_owned = receiveIncrementalOnWindow(
            self,
            self.allocator,
            requestor,
            property_atom,
            self.app_config.memory.platform_event_payload_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try sendDndFinished(self, dnd, false);
                self.dnd = null;
                return;
            },
        };
    } else {
        bytes_owned = property.value;
    }
    defer self.allocator.free(bytes_owned);
    const paths = linux_uri.parseFileUriListWithLimits(self.allocator, bytes_owned, .{
        .maximum_bytes = self.app_config.memory.platform_event_payload_bytes,
        .maximum_path_bytes = self.app_config.memory.platform_event_payload_bytes,
        .maximum_paths = self.app_config.memory.file_drop_path_count,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            try sendDndFinished(self, dnd, false);
            self.dnd = null;
            return;
        },
    };
    defer {
        for (paths) |path| self.allocator.free(@constCast(path));
        self.allocator.free(paths);
    }
    const position: geometry.Point = .{
        .x = dnd.position.x - dnd.window.position.x,
        .y = dnd.position.y - dnd.window.position.y,
    };
    self.queueDrop(dnd.window.id, .performed, paths, position);
    try sendDndFinished(self, dnd, paths.len != 0);
    self.dnd = null;
}

fn handleDndMessage(self: *Context, native: *NativeWindow, message_type: u32, data: []const u8) Error!void {
    if (message_type == self.atoms.xdnd_enter) {
        const source = try wire.readU32(data, 0);
        const flags = try wire.readU32(data, 4);
        var target: u32 = 0;
        if ((flags & 1) == 0) {
            for (0..3) |index| {
                const offered = try wire.readU32(data, 8 + index * 4);
                if (offered == self.atoms.text_uri_list) target = offered;
            }
        } else {
            var property = try protocol.getProperty(&self.client, &self.writer, self.allocator, false, source, self.atoms.xdnd_type_list, atom_atom, 0, 1024);
            defer property.deinit();
            var offset: usize = 0;
            while (offset + 4 <= property.value.len) : (offset += 4) {
                if (try wire.readU32(property.value, offset) == self.atoms.text_uri_list) target = self.atoms.text_uri_list;
            }
        }
        self.dnd = .{ .source = source, .window = native, .target = target };
        const no_paths: [0][]const u8 = .{};
        self.queueDrop(native.id, .entered, &no_paths, .{});
        return;
    }
    if (message_type == self.atoms.xdnd_position) {
        if (self.dnd) |*dnd| {
            const packed_position = try wire.readU32(data, 8);
            dnd.position = .{ .x = @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(packed_position >> 16))))), .y = @floatFromInt(@as(i16, @bitCast(@as(u16, @truncate(packed_position))))) };
            dnd.timestamp = try wire.readU32(data, 12);
            try sendDndStatus(self, dnd.*);
            const no_paths: [0][]const u8 = .{};
            self.queueDrop(dnd.window.id, .updated, &no_paths, .{
                .x = dnd.position.x - dnd.window.position.x,
                .y = dnd.position.y - dnd.window.position.y,
            });
        }
        return;
    }
    if (message_type == self.atoms.xdnd_leave) {
        if (self.dnd) |dnd| self.queue(dnd.window.id, .{ .input = .file_drop_exited });
        self.dnd = null;
        return;
    }
    if (message_type == self.atoms.xdnd_drop) if (self.dnd) |dnd| {
        if (dnd.target == 0) {
            try sendDndFinished(self, dnd, false);
            self.dnd = null;
            return;
        }
        try protocol.convertSelection(&self.client, &self.writer, native.xid, self.atoms.xdnd_selection, dnd.target, self.atoms.xdnd_data, dnd.timestamp);
    };
}

fn sendDndStatus(self: *Context, dnd: DndState) Error!void {
    var event: [32]u8 = @splat(0);
    event[0] = protocol.EventType.client_message;
    event[1] = 32;
    std.mem.writeInt(u32, event[4..8], dnd.source, .little);
    std.mem.writeInt(u32, event[8..12], self.atoms.xdnd_status, .little);
    std.mem.writeInt(u32, event[12..16], dnd.window.xid, .little);
    std.mem.writeInt(u32, event[16..20], @intFromBool(dnd.target != 0), .little);
    std.mem.writeInt(u32, event[28..32], if (dnd.target != 0) self.atoms.xdnd_action_copy else 0, .little);
    try protocol.sendEvent(&self.client, &self.writer, false, dnd.source, 0, &event);
}

fn sendDndFinished(self: *Context, dnd: DndState, success: bool) Error!void {
    var event: [32]u8 = @splat(0);
    event[0] = protocol.EventType.client_message;
    event[1] = 32;
    std.mem.writeInt(u32, event[4..8], dnd.source, .little);
    std.mem.writeInt(u32, event[8..12], self.atoms.xdnd_finished, .little);
    std.mem.writeInt(u32, event[12..16], dnd.window.xid, .little);
    std.mem.writeInt(u32, event[16..20], @intFromBool(success), .little);
    std.mem.writeInt(u32, event[20..24], if (success) self.atoms.xdnd_action_copy else 0, .little);
    try protocol.sendEvent(&self.client, &self.writer, false, dnd.source, 0, &event);
}

fn setWindowProperties(self: *Context, xid: u32, options: api.WindowOptions) Error!void {
    try setTitle(self, xid, options.title);
    const protocols = [_]u32{self.atoms.wm_delete_window};
    try protocol.changeProperty(&self.client, &self.writer, .replace, xid, self.atoms.wm_protocols, atom_atom, 32, std.mem.sliceAsBytes(&protocols));
    const pid: u32 = @intCast(sys.linux.getpid());
    try protocol.changeProperty(&self.client, &self.writer, .replace, xid, self.atoms.net_wm_pid, atom_cardinal, 32, std.mem.asBytes(&pid));
    const class = "zigui\x00ZigUI\x00";
    try protocol.changeProperty(&self.client, &self.writer, .replace, xid, atom_wm_class, atom_string, 8, class);
    const xdnd_version: u32 = 5;
    try protocol.changeProperty(&self.client, &self.writer, .replace, xid, self.atoms.xdnd_aware, atom_atom, 32, std.mem.asBytes(&xdnd_version));
    var hints: [18]u32 = @splat(0);
    const min_width = if (options.minimum_size.width > 0) @as(u32, dimension(options.minimum_size.width)) else 1;
    const min_height = if (options.minimum_size.height > 0) @as(u32, dimension(options.minimum_size.height)) else 1;
    const max_width = if (std.math.isFinite(options.maximum_size.width)) @as(u32, dimension(options.maximum_size.width)) else std.math.maxInt(u16);
    const max_height = if (std.math.isFinite(options.maximum_size.height)) @as(u32, dimension(options.maximum_size.height)) else std.math.maxInt(u16);
    hints[0] = (1 << 4) | (1 << 5);
    hints[5] = min_width;
    hints[6] = min_height;
    hints[7] = if (options.resizable) max_width else dimension(options.size.width);
    hints[8] = if (options.resizable) max_height else dimension(options.size.height);
    try protocol.changeProperty(&self.client, &self.writer, .replace, xid, atom_wm_normal_hints, atom_wm_size_hints, 32, std.mem.sliceAsBytes(&hints));
    const motif = [_]u32{ 1 << 1, 0, @intFromBool(options.decorated), 0, 0 };
    try protocol.changeProperty(&self.client, &self.writer, .replace, xid, self.atoms.motif_wm_hints, self.atoms.motif_wm_hints, 32, std.mem.sliceAsBytes(&motif));
    if (options.always_on_top) {
        const state = [_]u32{self.atoms.net_wm_state_above};
        try protocol.changeProperty(&self.client, &self.writer, .replace, xid, self.atoms.net_wm_state, atom_atom, 32, std.mem.sliceAsBytes(&state));
    }
}

fn setTitle(self: *Context, xid: u32, title: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(title)) return error.InvalidUtf8;
    try protocol.changeProperty(&self.client, &self.writer, .replace, xid, self.atoms.net_wm_name, self.atoms.utf8_string, 8, title);
    try protocol.changeProperty(&self.client, &self.writer, .replace, xid, atom_wm_name, atom_string, 8, title);
}

fn readScaleFactor(client: *client_mod.Client, writer: *wire.Writer, allocator: std.mem.Allocator) Error!geometry.ScaleFactor {
    var property = protocol.getProperty(client, writer, allocator, false, client.setup.root, atom_resource_manager, atom_string, 0, 262_144) catch
        return geometry.ScaleFactor.init(1);
    defer property.deinit();
    const marker = "Xft.dpi:";
    const offset = std.mem.indexOf(u8, property.value, marker) orelse return geometry.ScaleFactor.init(1);
    const tail = std.mem.trimStart(u8, property.value[offset + marker.len ..], " \t");
    const end = std.mem.indexOfAny(u8, tail, "\r\n\x00") orelse tail.len;
    const dpi = std.fmt.parseFloat(f32, std.mem.trim(u8, tail[0..end], " \t")) catch return geometry.ScaleFactor.init(1);
    return geometry.ScaleFactor.init(std.math.clamp(dpi / 96, 0.5, 8));
}

fn mouseButton(detail: u8) input.MouseButton {
    return switch (detail) {
        1 => .primary,
        2 => .middle,
        3 => .secondary,
        8 => .back,
        9 => .forward,
        else => .other,
    };
}

fn buttonMask(button: input.MouseButton) u32 {
    return @as(u32, 1) << @as(u5, @intCast(@backingInt(button)));
}

fn dimension(value: f32) u16 {
    if (!std.math.isFinite(value)) return std.math.maxInt(u16);
    return @intFromFloat(std.math.clamp(@round(value), 1, std.math.maxInt(u16)));
}

fn coordinate(value: f32) i16 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(std.math.clamp(@round(value), std.math.minInt(i16), std.math.maxInt(i16)));
}

fn saturatedI32(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(std.math.clamp(
        @round(value),
        @as(f32, @floatFromInt(std.math.minInt(i32))),
        @as(f32, @floatFromInt(std.math.maxInt(i32))),
    ));
}

fn transferKey(window: u32, property: u32) u64 {
    return @as(u64, window) << 32 | property;
}

fn maximumPropertyChunk(client: *const client_mod.Client) usize {
    return @max(client.maximumRequestBytes() -| 24, 1);
}

fn propertyLongLength(maximum_bytes: usize) u32 {
    return @intCast(@min((maximum_bytes +| 3) / 4, std.math.maxInt(u32)));
}

fn removeOutgoing(self: *Context, key: u64) void {
    const removed = self.outgoing.fetchRemove(key) orelse return;
    var transfer = removed.value;
    self.clipboard_owned_bytes -= transfer.data.len;
    transfer.deinit(self.allocator);
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BudgetExceeded => error.BudgetExceeded,
        error.InvalidConfiguration => error.InvalidConfiguration,
        error.InvalidHandle => error.InvalidHandle,
        error.InvalidUtf8 => error.InvalidUtf8,
        error.MissingCapability => error.MissingCapability,
        error.Unsupported => error.Unsupported,
        else => error.PlatformFailure,
    };
}
