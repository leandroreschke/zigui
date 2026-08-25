const std = @import("std");
const config = @import("../../../config.zig");
const Error = @import("../../../core/error.zig").Error;
const clock = @import("../../../core/clock.zig");
const geometry = @import("../../../core/geometry.zig");
const handles = @import("../../../core/handle.zig");
const input = @import("../../../input/event.zig");
const api = @import("../../api.zig");
const event_memory = @import("../../event_memory.zig");
const sys = @import("../sys.zig");
const client_mod = @import("client.zig");
const feedback_mod = @import("feedback.zig");
const keyboard_mod = @import("keyboard.zig");
const protocol = @import("protocol.zig");
const surface_api = @import("../surface.zig");
const wire = @import("wire.zig");
const vulkan = @import("../../../backend/vulkan/renderer.zig");
const in_tree_text = if (config.text_enabled) @import("../../../text/in_tree_backend.zig") else struct {};
const linux_fonts = if (config.text_enabled) @import("../fonts.zig") else struct {};
const portal_mod = @import("../portal.zig");
const linux_uri = @import("../uri.zig");
const linux_a11y = if (config.accessibility_enabled) @import("../accessibility.zig") else struct {
    pub const Adapter = opaque {};
};

const environment_storage_bytes = 256 * 1024;
const maximum_keymap_bytes = 16 * 1024 * 1024;
const maximum_touch_points = 256;
const maximum_protocol_text_bytes = std.math.maxInt(u16) - 24;

const Pending = struct {
    window: handles.WindowId,
    event: api.WindowEvent,
    owned_text: ?[]u8 = null,
    owned_paths: ?[]const []const u8 = null,
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
    last: u32 = 0,
    epoch: u64 = 0,
    initialized: bool = false,

    fn extend(self: *TimestampState, milliseconds: u32) u64 {
        if (self.initialized and milliseconds < self.last and self.last -% milliseconds > 0x80000000)
            self.epoch +%= @as(u64, 1) << 32;
        self.initialized = true;
        self.last = milliseconds;
        return (self.epoch | milliseconds) * std.time.ns_per_ms;
    }
};

const Output = struct {
    global_name: u32,
    object: u32,
    scale: i32 = 1,
    position: geometry.Point = .{},
    pixel_size: geometry.Size = .{},
    physical_size_mm: geometry.Size = .{},
    refresh_millihertz: u32 = 0,
    transform: i32 = 0,
    make: ?[]u8 = null,
    model: ?[]u8 = null,
    name: ?[]u8 = null,
    description: ?[]u8 = null,
    active: bool = true,

    fn deinit(self: *Output, context: *Context) void {
        self.releaseText(context);
        self.* = undefined;
    }

    fn releaseText(self: *Output, context: *Context) void {
        context.retained_text.release(context.allocator, &self.make);
        context.retained_text.release(context.allocator, &self.model);
        context.retained_text.release(context.allocator, &self.name);
        context.retained_text.release(context.allocator, &self.description);
    }
};

const TouchPoint = struct {
    window: *NativeWindow,
    position: geometry.Point,
};

const DragTransfer = struct {
    offer: u32,
    window: *NativeWindow,
    position: geometry.Point,
    descriptor: ?sys.fd_t,
    bytes: std.ArrayList(u8) = .empty,
    paths: ?[][]const u8 = null,
    entered: bool = false,
    dropped: bool = false,
    ready: bool = false,
    deadline_ns: u64,

    fn deinit(self: *DragTransfer, allocator: std.mem.Allocator) void {
        if (self.descriptor) |descriptor| sys.close(descriptor);
        self.bytes.deinit(allocator);
        if (self.paths) |paths| {
            for (paths) |path| allocator.free(@constCast(path));
            allocator.free(paths);
        }
        self.* = undefined;
    }
};

const Seat = struct {
    context: *Context,
    global_name: u32,
    object: u32,
    pointer: ?u32 = null,
    keyboard: ?u32 = null,
    touch: ?u32 = null,
    cursor_shape: ?u32 = null,
    text_input: ?u32 = null,
    data_device: ?u32 = null,
    capabilities: u32 = 0,
    active: bool = true,
    serial: u32 = 0,
    pointer_window: ?*NativeWindow = null,
    keyboard_window: ?*NativeWindow = null,
    pointer_position: geometry.Point = .{},
    buttons: u32 = 0,
    scroll_delta: geometry.Point = .{},
    scroll_discrete: geometry.Point = .{},
    scroll_source: protocol.PointerAxisSource = .continuous,
    keyboard_state: keyboard_mod.State = .{},
    keymap: ?[]u8 = null,
    timestamps: TimestampState = .{},
    pending_preedit: ?[]u8 = null,
    pending_preedit_selection: input.TextRange = .{ .start = 0, .end = 0 },
    pending_commit: ?[]u8 = null,
    pending_replacement: ?input.TextRange = null,
    touches: std.AutoHashMap(i32, TouchPoint),
    selection_offer: ?u32 = null,
    clipboard_source: ?u32 = null,
    drag: ?DragTransfer = null,

    fn deinit(self: *Seat) void {
        self.context.retained_text.release(self.context.allocator, &self.keymap);
        self.context.retained_text.release(self.context.allocator, &self.pending_preedit);
        self.context.retained_text.release(self.context.allocator, &self.pending_commit);
        if (self.drag) |*drag| drag.deinit(self.context.allocator);
        self.touches.deinit();
        self.* = undefined;
    }
};

const NativeWindow = struct {
    context: *Context,
    id: handles.WindowId,
    surface: u32,
    xdg_surface: u32,
    toplevel: u32,
    viewport: ?u32 = null,
    fractional_scale: ?u32 = null,
    decoration: ?u32 = null,
    portal_export: ?u32 = null,
    portal_handle: ?[]u8 = null,
    sync_surface: ?u32 = null,
    frame_callback: ?u32 = null,
    presentation_feedback: ?u32 = null,
    logical_size: geometry.Size,
    pending_size: ?geometry.Size = null,
    scale_factor: geometry.ScaleFactor,
    minimum_size: geometry.Size,
    maximum_size: geometry.Size,
    outputs: std.ArrayList(u32) = .empty,
    visible: bool,
    configured: bool = false,
    frame_wanted: bool = false,
    text_input_active: bool = false,
    candidate_rect: geometry.Rect = .{},
    surrounding_text: ?[]u8 = null,
    selection: input.TextRange = .{ .start = 0, .end = 0 },
    cursor: api.Cursor = .default,

    fn deinit(self: *NativeWindow) void {
        self.context.retained_text.release(self.context.allocator, &self.portal_handle);
        self.outputs.deinit(self.context.allocator);
        self.context.retained_text.release(self.context.allocator, &self.surrounding_text);
        self.* = undefined;
    }
};

const Buffer = struct {
    object: u32,
    released: bool = true,
};

const DataOffer = struct {
    object: u32,
    mime_types: std.ArrayList([]u8) = .empty,
    mime_bytes: usize = 0,

    fn deinit(self: *DataOffer, context: *Context) void {
        for (self.mime_types.items) |mime_value| {
            var mime: ?[]u8 = mime_value;
            context.retained_text.release(context.allocator, &mime);
        }
        self.mime_types.deinit(context.allocator);
        self.* = undefined;
    }

    fn supportsText(self: *const DataOffer) ?[]const u8 {
        for (self.mime_types.items) |mime| if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) return mime;
        for (self.mime_types.items) |mime| if (std.mem.eql(u8, mime, "text/plain")) return mime;
        for (self.mime_types.items) |mime| if (std.mem.startsWith(u8, mime, "text/plain")) return mime;
        return null;
    }

    fn supportsUriList(self: *const DataOffer) ?[]const u8 {
        for (self.mime_types.items) |mime| if (std.mem.eql(u8, mime, "text/uri-list")) return mime;
        return null;
    }
};

const ClipboardSource = struct {
    object: u32,
    text: []u8,
    retired: bool = false,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    app_config: config.AppConfig,
    client: client_mod.Client,
    wake_fd: sys.fd_t,
    windows: std.AutoHashMap(u64, *NativeWindow),
    surfaces: std.AutoHashMap(u32, *NativeWindow),
    seats: std.AutoHashMap(u32, *Seat),
    outputs: std.AutoHashMap(u32, *Output),
    buffers: std.AutoHashMap(u64, *Buffer),
    offers: std.AutoHashMap(u32, *DataOffer),
    clipboard_sources: std.AutoHashMap(u32, *ClipboardSource),
    events: std.ArrayList(Pending) = .empty,
    event_cursor: usize = 0,
    pending_payload_bytes: usize = 0,
    quit: bool = false,
    failure: ?Error = null,
    portal: ?*portal_mod.Portal = null,
    accessibility: ?*linux_a11y.Adapter = null,
    compositor: u32,
    xdg_wm_base: u32,
    viewporter: ?u32 = null,
    fractional_scale_manager: ?u32 = null,
    cursor_shape_manager: ?u32 = null,
    text_input_manager: ?u32 = null,
    data_device_manager: ?u32 = null,
    dmabuf: u32,
    dmabuf_feedback_object: ?u32 = null,
    dmabuf_feedback: feedback_mod.Collector,
    presentation: ?u32 = null,
    decoration_manager: ?u32 = null,
    foreign_exporter: ?u32 = null,
    syncobj_manager: ?u32 = null,
    clipboard_text: ?[]u8 = null,
    clipboard_owned_bytes: usize = 0,
    retained_text: event_memory.RetainedTextBudget,
    poll_descriptors: std.ArrayList(sys.linux.pollfd) = .empty,

    fn init(allocator: std.mem.Allocator, app_config: config.AppConfig) Error!*Context {
        const socket_path = try resolveSocketPath(allocator, app_config.linux);
        defer allocator.free(socket_path);
        var client_value = try client_mod.Client.connect(allocator, socket_path, app_config.memory.platform_object_count);
        var client_owned = true;
        errdefer if (client_owned) client_value.deinit();
        const wake_fd = try sys.createWakeFd();
        var wake_owned = true;
        errdefer if (wake_owned) sys.close(wake_fd);
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);

        const compositor_global = client_value.findFirstGlobal(.wl_compositor) orelse return error.MissingCapability;
        const xdg_global = client_value.findFirstGlobal(.xdg_wm_base) orelse return error.MissingCapability;
        const dmabuf_global = client_value.findFirstGlobal(.zwp_linux_dmabuf_v1) orelse return error.MissingCapability;
        if (dmabuf_global.version < 4) return error.MissingCapability;
        const compositor = try client_value.bind(compositor_global, @intFromPtr(self));
        const xdg_wm_base = try client_value.bind(xdg_global, @intFromPtr(self));
        const dmabuf = try client_value.bind(dmabuf_global, @intFromPtr(self));

        self.* = .{
            .allocator = allocator,
            .app_config = app_config,
            .client = client_value,
            .wake_fd = wake_fd,
            .windows = std.AutoHashMap(u64, *NativeWindow).init(allocator),
            .surfaces = std.AutoHashMap(u32, *NativeWindow).init(allocator),
            .seats = std.AutoHashMap(u32, *Seat).init(allocator),
            .outputs = std.AutoHashMap(u32, *Output).init(allocator),
            .buffers = std.AutoHashMap(u64, *Buffer).init(allocator),
            .offers = std.AutoHashMap(u32, *DataOffer).init(allocator),
            .clipboard_sources = std.AutoHashMap(u32, *ClipboardSource).init(allocator),
            .retained_text = try event_memory.RetainedTextBudget.init(app_config.memory.platform_retained_text_bytes),
            .compositor = compositor,
            .xdg_wm_base = xdg_wm_base,
            .dmabuf = dmabuf,
            .dmabuf_feedback = feedback_mod.Collector.init(allocator),
        };
        client_owned = false;
        wake_owned = false;
        errdefer self.deinit();

        try self.bindOptionalManagers();
        try self.bindSeatsAndOutputs();
        const feedback_object = try self.client.createObject(.zwp_linux_dmabuf_feedback_v1, self.client.objects.get(dmabuf).?.version, @intFromPtr(self));
        errdefer self.client.objects.abandon(feedback_object);
        try protocol.dmabufGetDefaultFeedback(&self.client.connection, dmabuf, feedback_object);
        self.dmabuf_feedback_object = feedback_object;
        try self.client.roundtripWith(self.handler());
        if (self.dmabuf_feedback.view().len == 0) return error.MissingCapability;
        return self;
    }

    fn bindOptionalManagers(self: *Context) Error!void {
        self.viewporter = try self.client.bindFirst(.wp_viewporter, @intFromPtr(self));
        self.fractional_scale_manager = try self.client.bindFirst(.wp_fractional_scale_manager_v1, @intFromPtr(self));
        self.cursor_shape_manager = try self.client.bindFirst(.wp_cursor_shape_manager_v1, @intFromPtr(self));
        self.text_input_manager = try self.client.bindFirst(.zwp_text_input_manager_v3, @intFromPtr(self));
        self.data_device_manager = try self.client.bindFirst(.wl_data_device_manager, @intFromPtr(self));
        if (self.data_device_manager) |manager| {
            if (self.client.objects.get(manager).?.version < 2) self.data_device_manager = null;
        }
        self.presentation = try self.client.bindFirst(.wp_presentation, @intFromPtr(self));
        self.decoration_manager = try self.client.bindFirst(.zxdg_decoration_manager_v1, @intFromPtr(self));
        self.foreign_exporter = try self.client.bindFirst(.zxdg_exporter_v2, @intFromPtr(self));
        self.syncobj_manager = try self.client.bindFirst(.wp_linux_drm_syncobj_manager_v1, @intFromPtr(self));
    }

    fn bindSeatsAndOutputs(self: *Context) Error!void {
        var globals = self.client.globals.valueIterator();
        while (globals.next()) |global| switch (global.interface) {
            .wl_seat => try self.addSeat(global.*),
            .wl_output => try self.addOutput(global.*),
            else => {},
        };
    }

    fn addSeat(self: *Context, global: client_mod.Global) Error!void {
        if (global.version < 5) return error.Unsupported;
        if (self.seats.count() >= self.app_config.memory.platform_object_count)
            return error.BudgetExceeded;
        try self.seats.ensureUnusedCapacity(1);
        const seat = try self.allocator.create(Seat);
        errdefer self.allocator.destroy(seat);
        seat.* = .{
            .context = self,
            .global_name = global.name,
            .object = 0,
            .touches = std.AutoHashMap(i32, TouchPoint).init(self.allocator),
        };
        errdefer seat.deinit();
        const object = try self.client.bind(global, @intFromPtr(seat));
        seat.object = object;
        errdefer rollbackVersionedObject(self, object, 5, 3);

        const text_input = if (self.text_input_manager) |manager| blk: {
            const version = self.client.objects.get(manager).?.version;
            break :blk try self.client.createObject(.zwp_text_input_v3, version, @intFromPtr(seat));
        } else null;
        var text_input_published = false;
        errdefer if (text_input) |value| rollbackCreatedObject(self, value, text_input_published);
        const data_device = if (self.data_device_manager) |manager| blk: {
            const version = self.client.objects.get(manager).?.version;
            break :blk try self.client.createObject(.wl_data_device, version, @intFromPtr(seat));
        } else null;
        var data_device_published = false;
        errdefer if (data_device) |value| rollbackVersionedCreatedObject(self, value, data_device_published, 2, 2);

        if (self.text_input_manager) |manager| {
            try protocol.textInputManagerGet(&self.client.connection, manager, text_input.?, object);
            text_input_published = true;
        }
        if (self.data_device_manager) |manager| {
            try protocol.dataDeviceManagerGetDevice(&self.client.connection, manager, data_device.?, object);
            data_device_published = true;
        }
        seat.text_input = text_input;
        seat.data_device = data_device;
        self.seats.putAssumeCapacity(object, seat);
    }

    fn addOutput(self: *Context, global: client_mod.Global) Error!void {
        if (global.version < 3) return error.Unsupported;
        if (self.outputs.count() >= self.app_config.memory.platform_object_count)
            return error.BudgetExceeded;
        try self.outputs.ensureUnusedCapacity(1);
        const output = try self.allocator.create(Output);
        errdefer self.allocator.destroy(output);
        output.* = .{ .global_name = global.name, .object = 0 };
        errdefer output.deinit(self);
        const object = try self.client.bind(global, @intFromPtr(output));
        output.object = object;
        errdefer rollbackVersionedObject(self, object, 3, 0);
        self.outputs.putAssumeCapacity(object, output);
    }

    fn handler(self: *Context) client_mod.Handler {
        return .{
            .context = self,
            .event_fn = handleProtocolEvent,
            .removed_fn = handleProtocolRemoval,
        };
    }

    fn queue(self: *Context, window: handles.WindowId, event: api.WindowEvent) void {
        self.appendPending(.{ .window = window, .event = event }) catch |err| return self.fail(err);
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

    fn queueText(self: *Context, window: handles.WindowId, event: input.ImeEvent, source: []const u8) void {
        const borrowed: input.Event = .{ .ime = event };
        self.validateInput(&borrowed) catch |err| return self.fail(err);
        _ = event_memory.ensureFits(
            source,
            null,
            self.pending_payload_bytes,
            self.app_config.memory.platform_event_queue_bytes,
        ) catch |err| return self.fail(err);
        const owned = self.allocator.dupe(u8, source) catch |err| return self.fail(err);
        const copied: input.ImeEvent = switch (event) {
            .set_marked_text => |marked| .{ .set_marked_text = .{
                .text = owned,
                .selected_utf8 = marked.selected_utf8,
                .replacement_utf8 = marked.replacement_utf8,
            } },
            .commit_text => |commit| .{ .commit_text = .{ .text = owned, .replacement_utf8 = commit.replacement_utf8 } },
            else => event,
        };
        self.appendPending(.{
            .window = window,
            .event = .{ .input = .{ .ime = copied } },
            .owned_text = owned,
        }) catch |err| {
            self.allocator.free(owned);
            return self.fail(err);
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
        self.validateInput(&borrowed) catch |err| return self.fail(err);
        _ = event_memory.ensureFits(
            request.value,
            null,
            self.pending_payload_bytes,
            self.app_config.memory.platform_event_queue_bytes,
        ) catch |err| return self.fail(err);
        const owned = if (request.value) |value| self.allocator.dupe(u8, value) catch |err| return self.fail(err) else null;
        var copied = request;
        copied.value = owned;
        self.appendPending(.{
            .window = request.window,
            .event = .{ .accessibility_action = copied },
            .owned_text = owned,
        }) catch |err| {
            if (owned) |value| self.allocator.free(value);
            return self.fail(err);
        };
        sys.wake(self.wake_fd);
    }

    fn queueDrop(
        self: *Context,
        window: handles.WindowId,
        comptime tag: enum { entered, updated, performed },
        paths_source: []const []const u8,
        position: geometry.Point,
    ) void {
        const borrowed_drop: input.FileDrop = .{ .paths = paths_source, .position = position };
        const borrowed: input.Event = switch (tag) {
            .entered => .{ .file_drop_entered = borrowed_drop },
            .updated => .{ .file_drop_updated = borrowed_drop },
            .performed => .{ .file_drop_performed = borrowed_drop },
        };
        self.validateInput(&borrowed) catch |err| return self.fail(err);
        _ = event_memory.ensureFits(
            null,
            paths_source,
            self.pending_payload_bytes,
            self.app_config.memory.platform_event_queue_bytes,
        ) catch |err| return self.fail(err);
        const paths = self.allocator.alloc([]const u8, paths_source.len) catch |err| return self.fail(err);
        var initialized: usize = 0;
        for (paths_source, 0..) |path, index| {
            paths[index] = self.allocator.dupe(u8, path) catch |err| {
                for (paths[0..initialized]) |owned| self.allocator.free(@constCast(owned));
                self.allocator.free(paths);
                return self.fail(err);
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
            return self.fail(err);
        };
        sys.wake(self.wake_fd);
    }

    fn popEvent(self: *Context) ?Pending {
        if (self.event_cursor >= self.events.items.len) return null;
        const event = self.events.items[self.event_cursor];
        self.event_cursor += 1;
        return event;
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

    fn deinit(self: *Context) void {
        if (self.portal) |portal| portal.deinit();
        var source_iterator = self.clipboard_sources.valueIterator();
        while (source_iterator.next()) |source| {
            self.allocator.free(source.*.text);
            self.allocator.destroy(source.*);
        }
        self.clipboard_sources.deinit();
        var offer_iterator = self.offers.valueIterator();
        while (offer_iterator.next()) |offer| {
            offer.*.deinit(self);
            self.allocator.destroy(offer.*);
        }
        self.offers.deinit();
        var buffer_iterator = self.buffers.valueIterator();
        while (buffer_iterator.next()) |buffer| self.allocator.destroy(buffer.*);
        self.buffers.deinit();
        var window_iterator = self.windows.valueIterator();
        while (window_iterator.next()) |window| {
            window.*.deinit();
            self.allocator.destroy(window.*);
        }
        self.windows.deinit();
        self.surfaces.deinit();
        var seat_iterator = self.seats.valueIterator();
        while (seat_iterator.next()) |seat| {
            seat.*.deinit();
            self.allocator.destroy(seat.*);
        }
        self.seats.deinit();
        var output_iterator = self.outputs.valueIterator();
        while (output_iterator.next()) |output| {
            output.*.deinit(self);
            self.allocator.destroy(output.*);
        }
        self.outputs.deinit();
        for (self.events.items[self.event_cursor..]) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.poll_descriptors.deinit(self.allocator);
        if (self.clipboard_text) |value| self.allocator.free(value);
        self.dmabuf_feedback.deinit();
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
        .maximum_text_bytes = @min(app_config.memory.platform_text_bytes, maximum_protocol_text_bytes),
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
        .text_input = if (context.text_input_manager != null) .{
            .context = context,
            .set_active_fn = setTextInputActive,
            .set_candidate_rect_fn = setCandidateRect,
            .set_surrounding_text_fn = setSurroundingText,
            .maximum_surrounding_text_bytes = app_config.memory.platform_text_bytes,
        } else null,
        .accessibility = accessibility_adapter,
        .clipboard = if (context.data_device_manager != null) .{
            .context = context,
            .read_text_fn = readClipboard,
            .write_text_fn = writeClipboard,
            .maximum_bytes = app_config.memory.clipboard_bytes,
        } else null,
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
    self.quit = false;
    while (!self.quit) {
        _ = try step(raw, sink, true);
        sink.pump();
    }
    if (self.failure) |failure| {
        return failure;
    }
}

fn step(raw: *anyopaque, sink: api.EventSink, wait: bool) Error!bool {
    const self = cast(raw);
    while (true) {
        if (self.client.connection.isBroken()) return error.PlatformFailure;
        if (self.failure) |failure| {
            return failure;
        }
        if (self.popEvent()) |pending_value| {
            var pending = pending_value;
            defer pending.deinit(self.allocator);
            defer self.releasePending(&pending);
            sink.send(pending.window, &pending.event);
            if (self.event_cursor >= self.events.items.len) self.compactEvents();
            return true;
        }
        if (try self.client.dispatchBuffered(self.handler())) continue;
        if (try self.client.receive()) continue;
        if (try drainDragTransfers(self)) continue;
        if (self.accessibility) |adapter| if (try adapter.dispatch()) continue;
        if (!wait or self.quit) return false;

        self.poll_descriptors.clearRetainingCapacity();
        try self.poll_descriptors.append(self.allocator, .{ .fd = self.client.descriptor(), .events = sys.linux.POLL.IN, .revents = 0 });
        try self.poll_descriptors.append(self.allocator, .{ .fd = self.wake_fd, .events = sys.linux.POLL.IN, .revents = 0 });
        try self.poll_descriptors.append(self.allocator, .{
            .fd = if (self.accessibility) |adapter| adapter.descriptor() else -1,
            .events = sys.linux.POLL.IN,
            .revents = 0,
        });
        var seats = self.seats.valueIterator();
        while (seats.next()) |seat| if (seat.*.drag) |drag| if (drag.descriptor) |descriptor|
            try self.poll_descriptors.append(self.allocator, .{ .fd = descriptor, .events = sys.linux.POLL.IN, .revents = 0 });
        _ = try sys.poll(self.poll_descriptors.items, dragPollTimeout(self));
        if (self.poll_descriptors.items[0].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0)
            return error.PlatformFailure;
        if (self.poll_descriptors.items[1].revents & sys.linux.POLL.IN != 0) sys.drainWake(self.wake_fd);
        if (self.accessibility != null and self.poll_descriptors.items[2].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0)
            return error.PlatformFailure;
        for (self.poll_descriptors.items[3..]) |descriptor| if (descriptor.revents & (sys.linux.POLL.ERR | sys.linux.POLL.NVAL) != 0)
            return error.PlatformFailure;
    }
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
    if (self.client.connection.isBroken()) return error.PlatformFailure;
    if (self.windows.contains(id.encode())) return error.ResourceBusy;
    if (self.windows.count() >= self.app_config.memory.window_count) return error.BudgetExceeded;
    if (options.always_on_top) return error.Unsupported;
    try self.client.connection.prepareOutgoing(@max(64, options.title.len + 16), 0);
    const compositor_version = self.client.objects.get(self.compositor).?.version;
    const xdg_version = self.client.objects.get(self.xdg_wm_base).?.version;
    const native = try self.allocator.create(NativeWindow);
    errdefer self.allocator.destroy(native);

    const surface = try self.client.createObject(.wl_surface, compositor_version, @intFromPtr(native));
    var surface_published = false;
    errdefer rollbackCreatedObject(self, surface, surface_published);
    const xdg_surface = try self.client.createObject(.xdg_surface, xdg_version, @intFromPtr(native));
    var xdg_surface_published = false;
    errdefer rollbackCreatedObject(self, xdg_surface, xdg_surface_published);
    const toplevel = try self.client.createObject(.xdg_toplevel, xdg_version, @intFromPtr(native));
    var toplevel_published = false;
    errdefer rollbackCreatedObject(self, toplevel, toplevel_published);

    const portal_export = if (self.foreign_exporter != null)
        try self.client.createObject(.zxdg_exported_v2, 1, @intFromPtr(native))
    else
        null;
    var portal_export_published = false;
    errdefer if (portal_export) |object| rollbackCreatedObject(self, object, portal_export_published);
    const viewport = if (self.viewporter != null)
        try self.client.createObject(.wp_viewport, 1, @intFromPtr(native))
    else
        null;
    var viewport_published = false;
    errdefer if (viewport) |object| rollbackCreatedObject(self, object, viewport_published);
    const fractional_scale = if (self.fractional_scale_manager != null)
        try self.client.createObject(.wp_fractional_scale_v1, 1, @intFromPtr(native))
    else
        null;
    var fractional_scale_published = false;
    errdefer if (fractional_scale) |object| rollbackCreatedObject(self, object, fractional_scale_published);
    const decoration = if (options.decorated and self.decoration_manager != null) blk: {
        const manager = self.decoration_manager.?;
        const version = self.client.objects.get(manager).?.version;
        break :blk try self.client.createObject(.zxdg_toplevel_decoration_v1, version, @intFromPtr(native));
    } else null;
    var decoration_published = false;
    errdefer if (decoration) |object| rollbackCreatedObject(self, object, decoration_published);
    const sync_surface = if (self.syncobj_manager != null)
        try self.client.createObject(.wp_linux_drm_syncobj_surface_v1, 1, @intFromPtr(native))
    else
        null;
    var sync_surface_published = false;
    errdefer if (sync_surface) |object| rollbackCreatedObject(self, object, sync_surface_published);

    try self.windows.ensureUnusedCapacity(1);
    try self.surfaces.ensureUnusedCapacity(1);
    try self.preparePendingSlots(1);
    native.* = .{
        .context = self,
        .id = id,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .viewport = viewport,
        .fractional_scale = fractional_scale,
        .decoration = decoration,
        .portal_export = portal_export,
        .sync_surface = sync_surface,
        .logical_size = options.size,
        .scale_factor = geometry.ScaleFactor.init(1) catch unreachable,
        .minimum_size = options.minimum_size,
        .maximum_size = options.maximum_size,
        .visible = options.visible,
        .frame_wanted = options.visible,
    };
    errdefer {
        clearWindowObjectOwners(self, native);
        native.deinit();
    }

    try protocol.compositorCreateSurface(&self.client.connection, self.compositor, surface);
    surface_published = true;
    try protocol.xdgWmBaseGetSurface(&self.client.connection, self.xdg_wm_base, xdg_surface, surface);
    xdg_surface_published = true;
    try protocol.xdgSurfaceGetToplevel(&self.client.connection, xdg_surface, toplevel);
    toplevel_published = true;
    if (portal_export) |exported| {
        try protocol.foreignExporterExportToplevel(&self.client.connection, self.foreign_exporter.?, exported, surface);
        portal_export_published = true;
    }
    try protocol.xdgToplevelSetTitle(&self.client.connection, toplevel, options.title);
    if (!options.resizable) {
        const width = positiveDimension(options.size.width);
        const height = positiveDimension(options.size.height);
        try protocol.xdgToplevelSetMinimumSize(&self.client.connection, toplevel, width, height);
        try protocol.xdgToplevelSetMaximumSize(&self.client.connection, toplevel, width, height);
    } else {
        try protocol.xdgToplevelSetMinimumSize(
            &self.client.connection,
            toplevel,
            optionalDimension(options.minimum_size.width),
            optionalDimension(options.minimum_size.height),
        );
        try protocol.xdgToplevelSetMaximumSize(
            &self.client.connection,
            toplevel,
            boundedDimension(options.maximum_size.width),
            boundedDimension(options.maximum_size.height),
        );
    }

    if (viewport) |object| {
        try protocol.viewporterGetViewport(&self.client.connection, self.viewporter.?, object, surface);
        viewport_published = true;
    }
    if (fractional_scale) |object| {
        try protocol.fractionalScaleGet(&self.client.connection, self.fractional_scale_manager.?, object, surface);
        fractional_scale_published = true;
    }
    if (decoration) |object| {
        try protocol.decorationGetToplevel(&self.client.connection, self.decoration_manager.?, object, toplevel);
        decoration_published = true;
        try protocol.decorationSetMode(&self.client.connection, object, .server_side);
    }
    if (sync_surface) |object| {
        try protocol.syncobjGetSurface(&self.client.connection, self.syncobj_manager.?, object, surface);
        sync_surface_published = true;
    }

    try protocol.surfaceCommit(&self.client.connection, surface);
    self.windows.putAssumeCapacity(id.encode(), native);
    self.surfaces.putAssumeCapacity(surface, native);
    const handle: api.NativeHandle = .{ .kind = .wayland, .value = surface };
    self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .created = handle } });
    sys.wake(self.wake_fd);
    return handle;
}

fn destroyWindow(raw: *anyopaque, id: handles.WindowId) void {
    const self = cast(raw);
    const removed = self.windows.fetchRemove(id.encode()) orelse return;
    const native = removed.value;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat_pointer| {
        const seat = seat_pointer.*;
        if (seat.drag) |drag| if (drag.window == native) clearDrag(self, seat);
        if (seat.pointer_window == native) seat.pointer_window = null;
        if (seat.keyboard_window == native) seat.keyboard_window = null;
    }
    _ = self.surfaces.remove(native.surface);
    destroyWindowObjects(self, native);
    native.deinit();
    self.allocator.destroy(native);
    self.queue(id, .closed);
}

fn destroyWindowObjects(self: *Context, native: *NativeWindow) void {
    clearWindowObjectOwners(self, native);
    inline for (.{ native.portal_export, native.decoration, native.sync_surface, native.fractional_scale, native.viewport }) |maybe_object|
        if (maybe_object) |object| retireWithDestructor(self, object);
    retireWithDestructor(self, native.toplevel);
    retireWithDestructor(self, native.xdg_surface);
    retireWithDestructor(self, native.surface);
}

fn clearWindowObjectOwners(self: *Context, native: *const NativeWindow) void {
    if (native.frame_callback) |object| {
        if (self.client.objects.getPtr(object)) |record| record.owner = 0;
    }
    if (native.presentation_feedback) |object| {
        if (self.client.objects.getPtr(object)) |record| record.owner = 0;
    }
    inline for (.{
        native.portal_export,
        native.decoration,
        native.sync_surface,
        native.fractional_scale,
        native.viewport,
        @as(?u32, native.toplevel),
        @as(?u32, native.xdg_surface),
        @as(?u32, native.surface),
    }) |maybe_object| {
        if (maybe_object) |object| {
            if (self.client.objects.getPtr(object)) |record| record.owner = 0;
        }
    }
}

fn rollbackCreatedObject(self: *Context, object: u32, published: bool) void {
    rollbackCreatedObjectWithOpcode(self, object, published, 0);
}

fn rollbackCreatedObjectWithOpcode(self: *Context, object: u32, published: bool, opcode: u16) void {
    if (!published) {
        self.client.objects.abandon(object);
        return;
    }
    if (self.client.objects.getPtr(object)) |record| record.owner = 0;
    if (!self.client.connection.isBroken()) retireWithOpcode(self, object, opcode);
}

fn rollbackVersionedObject(
    self: *Context,
    object: u32,
    minimum_release_version: u32,
    opcode: u16,
) void {
    const record = self.client.objects.getPtr(object) orelse return;
    record.owner = 0;
    if (!self.client.connection.isBroken() and record.version >= minimum_release_version)
        retireWithOpcode(self, object, opcode);
}

fn rollbackVersionedCreatedObject(
    self: *Context,
    object: u32,
    published: bool,
    minimum_release_version: u32,
    opcode: u16,
) void {
    if (!published) {
        self.client.objects.abandon(object);
        return;
    }
    rollbackVersionedObject(self, object, minimum_release_version, opcode);
}

fn retireVersioned(
    self: *Context,
    object: u32,
    minimum_release_version: u32,
    opcode: u16,
) void {
    const record = self.client.objects.get(object) orelse return;
    if (record.version >= minimum_release_version) retireWithOpcode(self, object, opcode);
}

fn showWindow(raw: *anyopaque, id: handles.WindowId, visible: bool) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (native.visible == visible) return;
    if (!visible) {
        try protocol.surfaceAttach(&self.client.connection, native.surface, null, 0, 0);
        try protocol.surfaceCommit(&self.client.connection, native.surface);
        native.visible = false;
        native.frame_wanted = false;
    } else {
        native.visible = true;
        errdefer native.visible = false;
        try requestFrame(raw, id);
    }
}

fn titleWindow(raw: *anyopaque, id: handles.WindowId, title: []const u8) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    try protocol.xdgToplevelSetTitle(&self.client.connection, native.toplevel, title);
}

fn requestFrame(raw: *anyopaque, id: handles.WindowId) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (!native.visible) return;
    if (native.configured and native.frame_callback == null) {
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
    native.cursor = cursor;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat_pointer| {
        const seat = seat_pointer.*;
        if (!seat.active) continue;
        if (seat.pointer_window != native) continue;
        if (cursor == .hidden) {
            if (seat.pointer) |pointer| try protocol.pointerSetCursor(&self.client.connection, pointer, seat.serial, null, 0, 0);
        } else if (seat.cursor_shape) |device| {
            try protocol.cursorShapeSet(&self.client.connection, device, seat.serial, cursorShape(cursor));
        }
    }
}

fn commandWindow(raw: *anyopaque, id: handles.WindowId, command: api.WindowCommand) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    switch (command) {
        // The Wayland toplevel protocol intentionally gives placement and
        // arbitrary resize authority to the compositor.
        .move, .resize => return error.Unsupported,
        .always_on_top => return error.Unsupported,
        .mode => |mode| switch (mode) {
            .normal => {
                try protocol.xdgToplevelSetMaximized(&self.client.connection, native.toplevel, false);
                try protocol.xdgToplevelUnsetFullscreen(&self.client.connection, native.toplevel);
            },
            .minimized => try protocol.xdgToplevelSetMinimized(&self.client.connection, native.toplevel),
            .maximized => try protocol.xdgToplevelSetMaximized(&self.client.connection, native.toplevel, true),
            .fullscreen => try protocol.xdgToplevelSetFullscreen(&self.client.connection, native.toplevel, null),
        },
    }
    try protocol.surfaceCommit(&self.client.connection, native.surface);
}

fn listDisplays(raw: *anyopaque, allocator: std.mem.Allocator) Error!api.OwnedDisplays {
    const self = cast(raw);
    var values: std.ArrayList(api.Display) = .empty;
    errdefer {
        for (values.items) |display| allocator.free(@constCast(display.name));
        values.deinit(allocator);
    }
    var iterator = self.outputs.valueIterator();
    while (iterator.next()) |output_pointer| {
        const output = output_pointer.*;
        if (!output.active or output.pixel_size.width <= 0 or output.pixel_size.height <= 0) continue;
        const scale: f32 = @floatFromInt(@max(1, output.scale));
        const rotated = output.transform == 1 or output.transform == 3 or output.transform == 5 or output.transform == 7;
        const pixel_width = if (rotated) output.pixel_size.height else output.pixel_size.width;
        const pixel_height = if (rotated) output.pixel_size.width else output.pixel_size.height;
        const label = output.name orelse output.description orelse output.model orelse output.make orelse "Wayland output";
        const owned_name = try allocator.dupe(u8, label);
        const bounds = geometry.Rect.fromXYWH(
            output.position.x,
            output.position.y,
            pixel_width / scale,
            pixel_height / scale,
        );
        values.append(allocator, .{
            .id = output.object,
            .name = owned_name,
            .bounds = bounds,
            .work_area = bounds,
            .scale_factor = geometry.ScaleFactor.init(scale) catch unreachable,
            .refresh_millihertz = output.refresh_millihertz,
            .physical_size_mm = output.physical_size_mm,
        }) catch |err| {
            allocator.free(owned_name);
            return err;
        };
    }
    if (values.items.len == 0) return error.MissingCapability;
    std.mem.sort(api.Display, values.items, {}, struct {
        fn less(_: void, a: api.Display, b: api.Display) bool {
            return a.id < b.id;
        }
    }.less);
    values.items[0].primary = true;
    return .{ .allocator = allocator, .values = try values.toOwnedSlice(allocator) };
}

fn nativeHandle(raw: *anyopaque, id: handles.WindowId) ?api.NativeHandle {
    const native = cast(raw).windows.get(id.encode()) orelse return null;
    return .{ .kind = .wayland, .value = native.surface };
}

fn portalParentIdentifier(raw: *anyopaque, id: handles.WindowId, allocator: std.mem.Allocator) Error![]u8 {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (native.portal_export == null) return allocator.dupe(u8, "");
    if (native.portal_handle == null) try self.client.roundtripWith(self.handler());
    const handle = native.portal_handle orelse return error.PlatformFailure;
    return std.fmt.allocPrint(allocator, "wayland:{s}", .{handle});
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
        .origin = .{ .x = source.origin.x * scale, .y = source.origin.y * scale },
        .size = .{ .width = source.size.width * scale, .height = source.size.height * scale },
    };
}

fn explicitSyncAvailable(raw: *anyopaque) bool {
    return cast(raw).syncobj_manager != null;
}

fn supportedFormats(raw: *anyopaque) []const surface_api.Format {
    return cast(raw).dmabuf_feedback.view();
}

fn importBuffer(raw: *anyopaque, descriptor: surface_api.DmabufDescriptor) Error!surface_api.BufferHandle {
    const self = cast(raw);
    if (descriptor.width == 0 or descriptor.height == 0 or descriptor.planes.len == 0 or descriptor.planes.len > 4)
        return error.InvalidConfiguration;
    if (self.buffers.count() >= self.app_config.memory.platform_object_count)
        return error.BudgetExceeded;
    try self.client.connection.prepareOutgoing(64, 1);
    try self.buffers.ensureUnusedCapacity(1);
    const buffer_value = try self.allocator.create(Buffer);
    errdefer self.allocator.destroy(buffer_value);
    const params_version = self.client.objects.get(self.dmabuf).?.version;
    const params = try self.client.createObject(.zwp_linux_buffer_params_v1, params_version, @intFromPtr(self));
    var params_published = false;
    errdefer rollbackCreatedObject(self, params, params_published);
    const buffer_object = try self.client.createObject(.wl_buffer, 1, @intFromPtr(buffer_value));
    var buffer_published = false;
    errdefer rollbackCreatedObject(self, buffer_object, buffer_published);
    buffer_value.* = .{ .object = buffer_object };
    errdefer {
        if (self.client.objects.getPtr(buffer_object)) |record| record.owner = 0;
    }

    try protocol.dmabufCreateParams(&self.client.connection, self.dmabuf, params);
    params_published = true;
    for (descriptor.planes, 0..) |plane, index| try protocol.dmabufParamsAdd(
        &self.client.connection,
        params,
        plane.descriptor,
        @intCast(index),
        plane.offset,
        plane.stride,
        plane.modifier,
    );
    try protocol.dmabufParamsCreateImmediate(
        &self.client.connection,
        params,
        buffer_object,
        @intCast(descriptor.width),
        @intCast(descriptor.height),
        descriptor.fourcc,
        descriptor.flags,
    );
    buffer_published = true;
    try protocol.dmabufParamsDestroy(&self.client.connection, params);
    try self.client.objects.retire(params);
    self.buffers.putAssumeCapacity(buffer_object, buffer_value);
    return buffer_object;
}

fn destroyBuffer(raw: *anyopaque, handle: surface_api.BufferHandle) void {
    const self = cast(raw);
    const object: u32 = @intCast(handle);
    const removed = self.buffers.fetchRemove(handle) orelse return;
    if (self.client.objects.getPtr(object)) |record| record.owner = 0;
    retireWithDestructor(self, object);
    self.allocator.destroy(removed.value);
}

fn bufferReleased(raw: *anyopaque, handle: surface_api.BufferHandle) bool {
    const buffer_value = cast(raw).buffers.get(handle) orelse return false;
    return buffer_value.released;
}

fn importTimeline(raw: *anyopaque, descriptor: sys.fd_t) Error!surface_api.TimelineHandle {
    const self = cast(raw);
    const manager = self.syncobj_manager orelse return error.MissingCapability;
    try self.client.connection.prepareOutgoing(16, 1);
    const timeline = try self.client.createObject(.wp_linux_drm_syncobj_timeline_v1, 1, @intFromPtr(self));
    var published = false;
    errdefer rollbackCreatedObject(self, timeline, published);
    try protocol.syncobjImportTimeline(&self.client.connection, manager, timeline, descriptor);
    published = true;
    return timeline;
}

fn destroyTimeline(raw: *anyopaque, handle: surface_api.TimelineHandle) void {
    const self = cast(raw);
    const object: u32 = @intCast(handle);
    retireWithDestructor(self, object);
}

fn presentBuffer(raw: *anyopaque, presentation: surface_api.Presentation) Error!void {
    const self = cast(raw);
    const native = self.windows.get(presentation.window.encode()) orelse return error.InvalidHandle;
    if (!native.visible or !native.configured) return error.SurfaceUnavailable;
    const buffer_value = self.buffers.get(presentation.buffer) orelse return error.InvalidHandle;
    if (!buffer_value.released) return error.ResourceBusy;
    try self.client.connection.prepareOutgoing(64, 0);
    const callback = if (native.frame_callback == null)
        try self.client.createObject(.wl_callback, 1, @intFromPtr(native))
    else
        null;
    var callback_published = false;
    errdefer if (callback) |object| rollbackCreatedObject(self, object, callback_published);
    const feedback_object = if (self.presentation != null and native.presentation_feedback == null) blk: {
        const version = self.client.objects.get(self.presentation.?).?.version;
        break :blk try self.client.createObject(.wp_presentation_feedback, version, @intFromPtr(native));
    } else null;
    var feedback_published = false;
    errdefer if (feedback_object) |object| rollbackCreatedObject(self, object, feedback_published);

    if (presentation.acquire != null or presentation.release != null) {
        const sync_surface = native.sync_surface orelse return error.MissingCapability;
        const acquire = presentation.acquire orelse return error.InvalidConfiguration;
        const release = presentation.release orelse return error.InvalidConfiguration;
        try protocol.syncobjSetAcquirePoint(&self.client.connection, sync_surface, @intCast(acquire.timeline), acquire.value);
        try protocol.syncobjSetReleasePoint(&self.client.connection, sync_surface, @intCast(release.timeline), release.value);
    }
    try protocol.surfaceAttach(&self.client.connection, native.surface, buffer_value.object, 0, 0);
    const damage = presentation.damage;
    try protocol.surfaceDamageBuffer(
        &self.client.connection,
        native.surface,
        saturatedI32(@floor(damage.origin.x * native.scale_factor.value)),
        saturatedI32(@floor(damage.origin.y * native.scale_factor.value)),
        saturatedI32(@ceil(damage.size.width * native.scale_factor.value)),
        saturatedI32(@ceil(damage.size.height * native.scale_factor.value)),
    );
    if (native.viewport) |viewport| try protocol.viewportSetDestination(
        &self.client.connection,
        viewport,
        positiveDimension(native.logical_size.width),
        positiveDimension(native.logical_size.height),
    );
    if (callback) |object| {
        try protocol.surfaceFrame(&self.client.connection, native.surface, object);
        callback_published = true;
    }
    if (feedback_object) |object| {
        try protocol.presentationFeedback(&self.client.connection, self.presentation.?, native.surface, object);
        feedback_published = true;
    }
    try protocol.surfaceCommit(&self.client.connection, native.surface);
    if (callback) |object| native.frame_callback = object;
    if (feedback_object) |object| native.presentation_feedback = object;
    buffer_value.released = false;
}

fn handleProtocolEvent(
    raw: *anyopaque,
    _: *client_mod.Client,
    object_id: u32,
    object: client_mod.Object,
    opcode: u16,
    reader: *wire.Reader,
) Error!void {
    const self = cast(raw);
    switch (object.interface) {
        .wl_registry => try handleRegistry(self, opcode, reader),
        .wl_callback => try handleCallback(self, object, opcode, reader),
        .wl_surface => try handleSurface(self, object, opcode, reader),
        .wl_buffer => try handleBuffer(self, object, opcode, reader),
        .wl_seat => try handleSeat(self, object, opcode, reader),
        .wl_pointer => try handlePointer(self, object, opcode, reader),
        .wl_keyboard => try handleKeyboard(self, object, opcode, reader),
        .wl_touch => try handleTouch(self, object, opcode, reader),
        .wl_output => try handleOutput(self, object, opcode, reader),
        .xdg_wm_base => try handleWmBase(self, object_id, opcode, reader),
        .xdg_surface => try handleXdgSurface(self, object, opcode, reader),
        .xdg_toplevel => try handleToplevel(self, object, opcode, reader),
        .wp_fractional_scale_v1 => try handleFractionalScale(self, object, opcode, reader),
        .wp_cursor_shape_device_v1 => return error.PlatformFailure,
        .zwp_text_input_v3 => try handleTextInput(self, object, opcode, reader),
        .wl_data_offer => try handleDataOffer(self, object, opcode, reader),
        .wl_data_source => try handleDataSource(self, object_id, opcode, reader),
        .wl_data_device => try handleDataDevice(self, object, opcode, reader),
        .zwp_linux_dmabuf_v1 => try handleDmabuf(opcode, reader),
        .zwp_linux_buffer_params_v1 => try handleDmabufParams(self, object_id, opcode, reader),
        .zwp_linux_dmabuf_feedback_v1 => try self.dmabuf_feedback.handle(opcode, reader),
        .wp_presentation => {
            if (opcode != 0) return error.PlatformFailure;
            _ = try reader.u32();
        },
        .wp_presentation_feedback => try handlePresentationFeedback(object, opcode, reader),
        .zxdg_toplevel_decoration_v1 => try handleDecoration(opcode, reader),
        .zxdg_exported_v2 => try handleExported(self, object, opcode, reader),
        else => return error.PlatformFailure,
    }
}

fn handleProtocolRemoval(
    raw: *anyopaque,
    _: *client_mod.Client,
    object_id: u32,
    object: client_mod.Object,
) Error!void {
    const self = cast(raw);
    switch (object.interface) {
        .wl_data_source => {
            const removed = self.clipboard_sources.fetchRemove(object_id) orelse {
                if (object.owner == 0) return;
                return error.PlatformFailure;
            };
            var seats = self.seats.valueIterator();
            while (seats.next()) |seat| {
                if (seat.*.clipboard_source == object_id) seat.*.clipboard_source = null;
            }
            self.clipboard_owned_bytes -= removed.value.text.len;
            self.allocator.free(removed.value.text);
            self.allocator.destroy(removed.value);
        },
        else => {},
    }
}

fn handleRegistry(self: *Context, opcode: u16, reader: *wire.Reader) Error!void {
    switch (opcode) {
        0 => {
            const name = try reader.u32();
            const interface_name = try reader.string();
            _ = try reader.u32();
            const interface = protocol.Interface.parse(interface_name) orelse return;
            const global = self.client.globals.get(name) orelse return error.PlatformFailure;
            switch (interface) {
                .wl_seat => try self.addSeat(global),
                .wl_output => try self.addOutput(global),
                else => {},
            }
        },
        1 => {
            const name = try reader.u32();
            var seats = self.seats.valueIterator();
            while (seats.next()) |seat_pointer| if (seat_pointer.*.global_name == name) {
                seat_pointer.*.active = false;
                releaseSeatDevices(self, seat_pointer.*);
            };
            var outputs = self.outputs.valueIterator();
            while (outputs.next()) |output_pointer| if (output_pointer.*.global_name == name) {
                output_pointer.*.active = false;
                output_pointer.*.releaseText(self);
            };
        },
        else => return error.PlatformFailure,
    }
}

fn handleCallback(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (opcode != 0) return error.PlatformFailure;
    const callback_time = try reader.u32();
    if (object.owner == 0) return;
    const native: *NativeWindow = @ptrFromInt(object.owner);
    const request_frame = native.frame_wanted and native.visible and native.configured;
    if (request_frame) try self.preparePendingSlots(1);
    native.frame_callback = null;
    if (request_frame) {
        native.frame_wanted = false;
        self.events.appendAssumeCapacity(.{
            .window = native.id,
            .event = .{ .frame_requested = @as(u64, callback_time) * std.time.ns_per_ms },
        });
        sys.wake(self.wake_fd);
    }
}

fn handleSurface(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) {
        switch (opcode) {
            0, 1 => _ = try reader.object(),
            2 => _ = try reader.int(),
            3 => _ = try reader.u32(),
            else => return error.PlatformFailure,
        }
        return;
    }
    const native: *NativeWindow = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => {
            const output = try reader.object();
            if (!containsU32(native.outputs.items, output)) try native.outputs.append(self.allocator, output);
            if (native.fractional_scale == null) try updateWindowIntegerScale(self, native);
        },
        1 => {
            const output = try reader.object();
            removeU32(&native.outputs, output);
            if (native.fractional_scale == null) try updateWindowIntegerScale(self, native);
        },
        2 => {
            const scale = try reader.int();
            if (native.fractional_scale == null and scale > 0) try setWindowScale(self, native, @floatFromInt(scale));
        },
        3 => _ = try reader.u32(),
        else => return error.PlatformFailure,
    }
}

fn handleBuffer(_: *Context, object: client_mod.Object, opcode: u16, _: *wire.Reader) Error!void {
    if (opcode != 0) return error.PlatformFailure;
    if (object.owner == 0) return;
    const buffer_value: *Buffer = @ptrFromInt(object.owner);
    buffer_value.released = true;
}

fn handleSeat(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) return error.PlatformFailure;
    const seat: *Seat = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => try updateSeatCapabilities(self, seat, try reader.u32()),
        1 => _ = try reader.string(),
        else => return error.PlatformFailure,
    }
}

fn updateSeatCapabilities(self: *Context, seat: *Seat, capabilities: u32) Error!void {
    const added = capabilities & ~seat.capabilities;
    const removed = seat.capabilities & ~capabilities;
    const seat_version = self.client.objects.get(seat.object).?.version;
    if (added & protocol.SeatCapability.pointer != 0) {
        const pointer = try self.client.createObject(.wl_pointer, seat_version, @intFromPtr(seat));
        var pointer_published = false;
        errdefer rollbackVersionedCreatedObject(self, pointer, pointer_published, 3, 1);
        const cursor_shape = if (self.cursor_shape_manager) |manager| blk: {
            const version = self.client.objects.get(manager).?.version;
            break :blk try self.client.createObject(.wp_cursor_shape_device_v1, version, @intFromPtr(seat));
        } else null;
        var cursor_shape_published = false;
        errdefer if (cursor_shape) |device| rollbackCreatedObject(self, device, cursor_shape_published);
        try protocol.seatGetPointer(&self.client.connection, seat.object, pointer);
        pointer_published = true;
        if (self.cursor_shape_manager) |manager| {
            try protocol.cursorShapeGetPointer(&self.client.connection, manager, cursor_shape.?, pointer);
            cursor_shape_published = true;
        }
        seat.pointer = pointer;
        seat.cursor_shape = cursor_shape;
        seat.capabilities |= protocol.SeatCapability.pointer;
    }
    if (added & protocol.SeatCapability.keyboard != 0) {
        const keyboard = try self.client.createObject(.wl_keyboard, seat_version, @intFromPtr(seat));
        var keyboard_published = false;
        errdefer rollbackVersionedCreatedObject(self, keyboard, keyboard_published, 3, 0);
        try protocol.seatGetKeyboard(&self.client.connection, seat.object, keyboard);
        keyboard_published = true;
        seat.keyboard = keyboard;
        seat.capabilities |= protocol.SeatCapability.keyboard;
    }
    if (added & protocol.SeatCapability.touch != 0) {
        const touch = try self.client.createObject(.wl_touch, seat_version, @intFromPtr(seat));
        var touch_published = false;
        errdefer rollbackVersionedCreatedObject(self, touch, touch_published, 3, 0);
        try protocol.seatGetTouch(&self.client.connection, seat.object, touch);
        touch_published = true;
        seat.touch = touch;
        seat.capabilities |= protocol.SeatCapability.touch;
    }
    if (removed & protocol.SeatCapability.pointer != 0) {
        if (seat.cursor_shape) |device| retireWithOpcode(self, device, 0);
        if (seat.pointer) |pointer| retireVersioned(self, pointer, 3, 1);
        seat.cursor_shape = null;
        seat.pointer = null;
        seat.pointer_window = null;
        seat.capabilities &= ~protocol.SeatCapability.pointer;
    }
    if (removed & protocol.SeatCapability.keyboard != 0) {
        if (seat.keyboard) |keyboard| retireVersioned(self, keyboard, 3, 0);
        seat.keyboard = null;
        seat.keyboard_window = null;
        seat.capabilities &= ~protocol.SeatCapability.keyboard;
    }
    if (removed & protocol.SeatCapability.touch != 0) {
        if (seat.touch) |touch| retireVersioned(self, touch, 3, 0);
        seat.touch = null;
        seat.touches.clearRetainingCapacity();
        seat.capabilities &= ~protocol.SeatCapability.touch;
    }
    seat.capabilities = capabilities;
}

fn handlePointer(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) return error.PlatformFailure;
    const seat: *Seat = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => {
            seat.serial = try reader.u32();
            try ensureSeatClipboard(self, seat);
            const surface = try reader.object();
            const native = self.surfaces.get(surface) orelse return error.PlatformFailure;
            seat.pointer_position = .{ .x = try reader.fixed(), .y = try reader.fixed() };
            seat.pointer_window = native;
            self.queue(native.id, .{ .input = .{ .pointer_enter = pointerEvent(seat, null, sys.monotonicNanoseconds()) } });
            try setCursor(self, native.id, native.cursor);
        },
        1 => {
            seat.serial = try reader.u32();
            _ = try reader.object();
            if (seat.pointer_window) |native| self.queue(native.id, .{ .input = .{ .pointer_leave = pointerEvent(seat, null, sys.monotonicNanoseconds()) } });
            seat.pointer_window = null;
        },
        2 => {
            const timestamp = seat.timestamps.extend(try reader.u32());
            const previous = seat.pointer_position;
            seat.pointer_position = .{ .x = try reader.fixed(), .y = try reader.fixed() };
            if (seat.pointer_window) |native| {
                var event = pointerEvent(seat, null, timestamp);
                event.delta = seat.pointer_position.sub(previous);
                self.queue(native.id, .{ .input = .{ .pointer_move = event } });
            }
        },
        3 => {
            seat.serial = try reader.u32();
            try ensureSeatClipboard(self, seat);
            const timestamp = seat.timestamps.extend(try reader.u32());
            const button_code = try reader.u32();
            const pressed = try reader.u32() == @backingInt(protocol.PointerButtonState.pressed);
            const button = mouseButton(button_code);
            const mask = buttonMask(button);
            if (pressed) seat.buttons |= mask else seat.buttons &= ~mask;
            if (seat.pointer_window) |native| {
                const event = pointerEvent(seat, button, timestamp);
                self.queue(native.id, .{ .input = if (pressed) .{ .pointer_down = event } else .{ .pointer_up = event } });
            }
        },
        4 => {
            _ = seat.timestamps.extend(try reader.u32());
            const axis = try reader.u32();
            const value = try reader.fixed();
            if (axis == @backingInt(protocol.PointerAxis.vertical)) seat.scroll_delta.y += value else if (axis == @backingInt(protocol.PointerAxis.horizontal)) seat.scroll_delta.x += value else return error.PlatformFailure;
            if (object.version < 5) emitScroll(self, seat, .changed);
        },
        5 => emitScroll(self, seat, .changed),
        6 => seat.scroll_source = std.enums.fromInt(protocol.PointerAxisSource, try reader.u32()) orelse .continuous,
        7 => {
            _ = seat.timestamps.extend(try reader.u32());
            _ = try reader.u32();
            emitScroll(self, seat, .ended);
        },
        8 => {
            const axis = try reader.u32();
            const steps: f32 = @floatFromInt(try reader.int());
            if (axis == 0) seat.scroll_discrete.y += steps else if (axis == 1) seat.scroll_discrete.x += steps else return error.PlatformFailure;
        },
        9 => {
            const axis = try reader.u32();
            const units: f32 = @as(f32, @floatFromInt(try reader.int())) / 120.0;
            if (axis == 0) seat.scroll_discrete.y += units else if (axis == 1) seat.scroll_discrete.x += units else return error.PlatformFailure;
        },
        10 => {
            _ = try reader.u32();
            _ = try reader.u32();
        },
        11 => {
            const previous = seat.pointer_position;
            seat.pointer_position = .{ .x = try reader.fixed(), .y = try reader.fixed() };
            if (seat.pointer_window) |native| {
                var event = pointerEvent(seat, null, sys.monotonicNanoseconds());
                event.delta = seat.pointer_position.sub(previous);
                self.queue(native.id, .{ .input = .{ .pointer_move = event } });
            }
        },
        else => return error.PlatformFailure,
    }
}

fn handleKeyboard(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) return error.PlatformFailure;
    const seat: *Seat = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => {
            const format = try reader.u32();
            const descriptor = try reader.fd();
            defer sys.close(descriptor);
            const size: usize = try reader.u32();
            if (format != 1 or size == 0 or size > maximum_keymap_bytes) return error.PlatformFailure;
            const bytes = try self.allocator.alloc(u8, size);
            var bytes_owned = true;
            errdefer if (bytes_owned) self.allocator.free(bytes);
            try sys.preadAll(descriptor, bytes, 0);
            try self.retained_text.adoptReplacement(self.allocator, &seat.keymap, bytes);
            bytes_owned = false;
        },
        1 => {
            seat.serial = try reader.u32();
            try ensureSeatClipboard(self, seat);
            const surface = try reader.object();
            const keys = try reader.array();
            if (keys.len % 4 != 0) return error.PlatformFailure;
            const native = self.surfaces.get(surface) orelse return error.PlatformFailure;
            seat.keyboard_window = native;
            var offset: usize = 0;
            while (offset < keys.len) : (offset += 4) {
                const code = std.mem.readInt(u32, keys[offset..][0..4], @import("builtin").cpu.arch.endian());
                if (code < 768) seat.keyboard_state.pressed.set(@intCast(code));
            }
            self.queue(native.id, .{ .focused = true });
            self.queue(native.id, .{ .input = .focus_in });
            if (native.text_input_active) try updateTextInputActivation(seat, native, true);
        },
        2 => {
            seat.serial = try reader.u32();
            _ = try reader.object();
            if (seat.keyboard_window) |native| {
                if (native.text_input_active) try updateTextInputActivation(seat, native, false);
                self.queue(native.id, .{ .input = .focus_out });
                self.queue(native.id, .{ .focused = false });
            }
            seat.keyboard_window = null;
            seat.keyboard_state.pressed = .empty;
        },
        3 => {
            seat.serial = try reader.u32();
            try ensureSeatClipboard(self, seat);
            const timestamp = seat.timestamps.extend(try reader.u32());
            const code = try reader.u32();
            const state = try reader.u32();
            const pressed = state != @backingInt(protocol.KeyboardKeyState.released);
            const repeated = state == @backingInt(protocol.KeyboardKeyState.repeated);
            if (seat.keyboard_window) |native| {
                const event = seat.keyboard_state.keyEvent(code, pressed, repeated, timestamp);
                self.queue(native.id, .{ .input = if (pressed) .{ .key_down = event } else .{ .key_up = event } });
            }
        },
        4 => {
            _ = try reader.u32();
            seat.keyboard_state.updateModifiers(try reader.u32(), try reader.u32(), try reader.u32(), try reader.u32());
        },
        5 => {
            seat.keyboard_state.repeat_rate = try reader.int();
            seat.keyboard_state.repeat_delay_ms = try reader.int();
        },
        else => return error.PlatformFailure,
    }
}

fn handleTouch(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) return error.PlatformFailure;
    const seat: *Seat = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => {
            seat.serial = try reader.u32();
            const timestamp = seat.timestamps.extend(try reader.u32());
            const surface = try reader.object();
            const touch_id = try reader.int();
            const native = self.surfaces.get(surface) orelse return error.PlatformFailure;
            const position: geometry.Point = .{ .x = try reader.fixed(), .y = try reader.fixed() };
            if (!seat.touches.contains(touch_id) and seat.touches.count() >= maximum_touch_points)
                return error.BudgetExceeded;
            try seat.touches.put(touch_id, .{ .window = native, .position = position });
            self.queue(native.id, .{ .input = .{ .pointer_down = touchEvent(seat, touch_id, position, timestamp) } });
        },
        1 => {
            seat.serial = try reader.u32();
            const timestamp = seat.timestamps.extend(try reader.u32());
            const touch_id = try reader.int();
            const removed = seat.touches.fetchRemove(touch_id) orelse return error.PlatformFailure;
            self.queue(removed.value.window.id, .{ .input = .{ .pointer_up = touchEvent(seat, touch_id, removed.value.position, timestamp) } });
        },
        2 => {
            const timestamp = seat.timestamps.extend(try reader.u32());
            const touch_id = try reader.int();
            const point = seat.touches.getPtr(touch_id) orelse return error.PlatformFailure;
            const previous = point.position;
            point.position = .{ .x = try reader.fixed(), .y = try reader.fixed() };
            var event = touchEvent(seat, touch_id, point.position, timestamp);
            event.delta = point.position.sub(previous);
            self.queue(point.window.id, .{ .input = .{ .pointer_move = event } });
        },
        3 => {},
        4 => {
            var touches = seat.touches.iterator();
            while (touches.next()) |entry| self.queue(entry.value_ptr.window.id, .{ .input = .{ .pointer_cancel = touchEvent(seat, entry.key_ptr.*, entry.value_ptr.position, sys.monotonicNanoseconds()) } });
            seat.touches.clearRetainingCapacity();
        },
        5 => {
            const touch_id = try reader.int();
            const point = seat.touches.get(touch_id) orelse return error.PlatformFailure;
            const major = try reader.fixed();
            const minor = try reader.fixed();
            _ = point;
            _ = major;
            _ = minor;
        },
        6 => {
            _ = try reader.int();
            _ = try reader.fixed();
        },
        else => return error.PlatformFailure,
    }
}

fn handleOutput(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) return error.PlatformFailure;
    const output: *Output = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => {
            output.position = .{ .x = @floatFromInt(try reader.int()), .y = @floatFromInt(try reader.int()) };
            output.physical_size_mm = .{ .width = @floatFromInt(try reader.int()), .height = @floatFromInt(try reader.int()) };
            _ = try reader.int();
            try self.retained_text.replace(self.allocator, &output.make, try reader.string());
            try self.retained_text.replace(self.allocator, &output.model, try reader.string());
            output.transform = try reader.int();
        },
        1 => {
            const flags = try reader.u32();
            const width = try reader.int();
            const height = try reader.int();
            const refresh = try reader.int();
            if (flags & 1 != 0 and width > 0 and height > 0) {
                output.pixel_size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
                output.refresh_millihertz = @intCast(@max(0, refresh));
            }
        },
        2 => {},
        3 => {
            const scale = try reader.int();
            if (scale <= 0) return error.PlatformFailure;
            output.scale = scale;
            var windows = self.windows.valueIterator();
            while (windows.next()) |window| if (window.*.fractional_scale == null and containsU32(window.*.outputs.items, output.object))
                try updateWindowIntegerScale(self, window.*);
        },
        4 => try self.retained_text.replace(self.allocator, &output.name, try reader.string()),
        5 => try self.retained_text.replace(self.allocator, &output.description, try reader.string()),
        else => return error.PlatformFailure,
    }
}

fn handleWmBase(self: *Context, object_id: u32, opcode: u16, reader: *wire.Reader) Error!void {
    if (opcode != 0) return error.PlatformFailure;
    try protocol.xdgWmBasePong(&self.client.connection, object_id, try reader.u32());
}

fn handleXdgSurface(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (opcode != 0) return error.PlatformFailure;
    const serial = try reader.u32();
    if (object.owner == 0) return;
    const native: *NativeWindow = @ptrFromInt(object.owner);
    const size = native.pending_size orelse native.logical_size;
    const first = !native.configured;
    const changed = size.width != native.logical_size.width or size.height != native.logical_size.height;
    const frame_requested = native.visible and native.frame_wanted and native.frame_callback == null;
    const event_count = @as(usize, @intFromBool(first or changed)) +
        @as(usize, @intFromBool(frame_requested));
    try self.preparePendingSlots(event_count);
    try protocol.xdgSurfaceAckConfigure(&self.client.connection, native.xdg_surface, serial);
    native.pending_size = null;
    native.logical_size = size;
    native.configured = true;
    if (first) {
        self.events.appendAssumeCapacity(.{
            .window = native.id,
            .event = .{ .configured = .{ .logical_size = size, .scale_factor = native.scale_factor } },
        });
    } else if (changed) {
        self.events.appendAssumeCapacity(.{ .window = native.id, .event = .{ .resized = size } });
    }
    if (frame_requested) {
        native.frame_wanted = false;
        self.events.appendAssumeCapacity(.{
            .window = native.id,
            .event = .{ .frame_requested = sys.monotonicNanoseconds() },
        });
    }
    if (event_count != 0) sys.wake(self.wake_fd);
}

fn handleToplevel(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    switch (opcode) {
        0 => {
            const width = try reader.int();
            const height = try reader.int();
            _ = try reader.array();
            if (object.owner == 0) return;
            const native: *NativeWindow = @ptrFromInt(object.owner);
            native.pending_size = .{
                .width = if (width > 0) @floatFromInt(width) else native.logical_size.width,
                .height = if (height > 0) @floatFromInt(height) else native.logical_size.height,
            };
        },
        1 => if (object.owner != 0) {
            const native: *NativeWindow = @ptrFromInt(object.owner);
            self.queue(native.id, .close_requested);
        },
        2 => {
            _ = try reader.int();
            _ = try reader.int();
        },
        3 => _ = try reader.array(),
        else => return error.PlatformFailure,
    }
}

fn handleFractionalScale(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (opcode != 0) return error.PlatformFailure;
    const scale_120 = try reader.u32();
    if (scale_120 == 0) return error.PlatformFailure;
    if (object.owner == 0) return;
    const native: *NativeWindow = @ptrFromInt(object.owner);
    try setWindowScale(self, native, @as(f32, @floatFromInt(scale_120)) / 120.0);
}

fn handleTextInput(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) return error.PlatformFailure;
    const seat: *Seat = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => {
            const surface = try reader.object();
            seat.keyboard_window = self.surfaces.get(surface) orelse return error.PlatformFailure;
        },
        1 => {
            _ = try reader.object();
            clearPendingIme(seat);
        },
        2 => {
            const source = try reader.nullableString();
            const begin = try reader.int();
            const end = try reader.int();
            if (source) |value|
                try self.retained_text.replace(self.allocator, &seat.pending_preedit, value)
            else
                self.retained_text.release(self.allocator, &seat.pending_preedit);
            const length = if (source) |value| value.len else 0;
            seat.pending_preedit_selection = .{
                .start = signedIndex(begin, length),
                .end = signedIndex(end, length),
            };
        },
        3 => {
            const source = try reader.nullableString();
            if (source) |value|
                try self.retained_text.replace(self.allocator, &seat.pending_commit, value)
            else
                self.retained_text.release(self.allocator, &seat.pending_commit);
        },
        4 => {
            const before: usize = try reader.u32();
            const after: usize = try reader.u32();
            if (seat.keyboard_window) |native| {
                const surrounding = native.surrounding_text orelse "";
                const cursor = @min(native.selection.end, surrounding.len);
                seat.pending_replacement = .{
                    .start = cursor -| before,
                    .end = @min(cursor +| after, surrounding.len),
                };
            }
        },
        5 => {
            _ = try reader.u32();
            try commitPendingIme(self, seat);
        },
        6 => {
            _ = try reader.u32();
            _ = try reader.u32();
        },
        7 => _ = try reader.string(),
        8 => {
            _ = try reader.u32();
            _ = try reader.u32();
            _ = try reader.u32();
        },
        else => return error.PlatformFailure,
    }
}

fn handleDataOffer(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) return error.PlatformFailure;
    const offer: *DataOffer = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => {
            const source = try reader.string();
            if (source.len == 0 or !std.unicode.utf8ValidateSlice(source) or
                std.mem.indexOfScalar(u8, source, 0) != null)
                return error.PlatformFailure;
            if (offer.mime_types.items.len >= self.app_config.memory.platform_object_count or
                source.len > self.app_config.memory.platform_text_bytes -| offer.mime_bytes)
                return error.BudgetExceeded;
            const owned = try self.retained_text.duplicate(self.allocator, source);
            offer.mime_types.append(self.allocator, owned) catch |err| {
                var rollback: ?[]u8 = owned;
                self.retained_text.release(self.allocator, &rollback);
                return err;
            };
            offer.mime_bytes += owned.len;
        },
        1, 2 => _ = try reader.u32(),
        else => return error.PlatformFailure,
    }
}

fn handleDataSource(self: *Context, object_id: u32, opcode: u16, reader: *wire.Reader) Error!void {
    const source = self.clipboard_sources.get(object_id) orelse {
        const object = self.client.objects.get(object_id) orelse return error.PlatformFailure;
        if (object.owner != 0) return error.PlatformFailure;
        switch (opcode) {
            0 => _ = try reader.nullableString(),
            1 => {
                _ = try reader.string();
                sys.close(try reader.fd());
            },
            2, 3, 4 => {},
            5 => _ = try reader.u32(),
            else => return error.PlatformFailure,
        }
        return;
    };
    switch (opcode) {
        0 => _ = try reader.nullableString(),
        1 => {
            _ = try reader.string();
            const descriptor = try reader.fd();
            defer sys.close(descriptor);
            try sys.writeAll(descriptor, source.text);
        },
        2 => destroyClipboardSource(self, object_id),
        3, 4 => {},
        5 => _ = try reader.u32(),
        else => return error.PlatformFailure,
    }
}

fn handleDataDevice(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.owner == 0) return error.PlatformFailure;
    const seat: *Seat = @ptrFromInt(object.owner);
    switch (opcode) {
        0 => {
            const id = try reader.object();
            if (self.offers.count() >= self.app_config.memory.platform_object_count)
                return error.BudgetExceeded;
            try self.offers.ensureUnusedCapacity(1);
            const offer = try self.allocator.create(DataOffer);
            errdefer self.allocator.destroy(offer);
            offer.* = .{ .object = id };
            try self.client.registerServerObject(id, .wl_data_offer, object.version, @intFromPtr(offer));
            errdefer self.client.objects.removeServer(id) catch {};
            self.offers.putAssumeCapacity(id, offer);
        },
        1 => {
            seat.serial = try reader.u32();
            const surface = try reader.object();
            const window = self.surfaces.get(surface) orelse return error.PlatformFailure;
            seat.pointer_window = window;
            seat.pointer_position = .{ .x = try reader.fixed(), .y = try reader.fixed() };
            try beginDrag(self, seat, window, try reader.nullableObject());
        },
        2 => {
            if (seat.drag) |drag| if (drag.entered)
                self.queue(drag.window.id, .{ .input = .file_drop_exited });
            clearDrag(self, seat);
        },
        3 => {
            _ = seat.timestamps.extend(try reader.u32());
            seat.pointer_position = .{ .x = try reader.fixed(), .y = try reader.fixed() };
            if (seat.drag) |*drag| {
                drag.position = seat.pointer_position;
                if (drag.ready and drag.entered)
                    self.queueDrop(drag.window.id, .updated, drag.paths orelse &.{}, drag.position);
            }
        },
        4 => {
            if (seat.drag) |*drag| {
                drag.dropped = true;
                if (drag.ready) finishDrop(self, seat);
            }
        },
        5 => {
            const selected = try reader.nullableObject();
            const previous = seat.selection_offer;
            seat.selection_offer = selected;
            if (previous) |old| releaseOfferIfUnused(self, old);
        },
        else => return error.PlatformFailure,
    }
}

fn beginDrag(self: *Context, seat: *Seat, window: *NativeWindow, offer_object: ?u32) Error!void {
    if (seat.drag) |drag| if (drag.entered)
        self.queue(drag.window.id, .{ .input = .file_drop_exited });
    clearDrag(self, seat);
    const object = offer_object orelse return;
    const offer = self.offers.get(object) orelse return error.PlatformFailure;
    const mime = offer.supportsUriList() orelse {
        try protocol.dataOfferAccept(&self.client.connection, object, seat.serial, null);
        releaseOfferIfUnused(self, object);
        return;
    };
    try protocol.dataOfferAccept(&self.client.connection, object, seat.serial, mime);
    const version = self.client.objects.get(object).?.version;
    if (version >= 3) try protocol.dataOfferSetActions(&self.client.connection, object, 1, 1);
    const descriptors = try sys.createPipe();
    var read_open = true;
    errdefer if (read_open) sys.close(descriptors[0]);
    var write_open = true;
    errdefer if (write_open) sys.close(descriptors[1]);
    try protocol.dataOfferReceive(&self.client.connection, object, mime, descriptors[1]);
    sys.close(descriptors[1]);
    write_open = false;
    seat.drag = .{
        .offer = object,
        .window = window,
        .position = seat.pointer_position,
        .descriptor = descriptors[0],
        .deadline_ns = sys.monotonicNanoseconds() +| 30 * std.time.ns_per_s,
    };
    read_open = false;
}

fn clearDrag(self: *Context, seat: *Seat) void {
    const drag = if (seat.drag) |*value| value else return;
    const offer = drag.offer;
    drag.deinit(self.allocator);
    seat.drag = null;
    releaseOfferIfUnused(self, offer);
}

fn finishDrop(self: *Context, seat: *Seat) void {
    const drag = if (seat.drag) |*value| value else return;
    const paths = drag.paths orelse &.{};
    if (paths.len != 0) self.queueDrop(drag.window.id, .performed, paths, drag.position);
    clearDrag(self, seat);
}

fn drainDragTransfers(self: *Context) Error!bool {
    var progress = false;
    const now = sys.monotonicNanoseconds();
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat_pointer| {
        const seat = seat_pointer.*;
        const drag = if (seat.drag) |*value| value else continue;
        if (!drag.ready and now >= drag.deadline_ns) {
            if (drag.entered) self.queue(drag.window.id, .{ .input = .file_drop_exited });
            clearDrag(self, seat);
            progress = true;
            continue;
        }
        const descriptor = drag.descriptor orelse continue;
        var scratch: [64 * 1024]u8 = undefined;
        var pass_bytes: usize = 0;
        while (pass_bytes < 1024 * 1024) switch (try sys.readNonBlocking(descriptor, &scratch)) {
            .bytes => |count| {
                if (drag.bytes.items.len > self.app_config.memory.platform_event_payload_bytes -| count) {
                    if (drag.entered) self.queue(drag.window.id, .{ .input = .file_drop_exited });
                    clearDrag(self, seat);
                    progress = true;
                    break;
                }
                try drag.bytes.appendSlice(self.allocator, scratch[0..count]);
                pass_bytes += count;
                progress = true;
            },
            .would_block => break,
            .end_of_file => {
                sys.close(descriptor);
                drag.descriptor = null;
                const paths = linux_uri.parseFileUriListWithLimits(self.allocator, drag.bytes.items, .{
                    .maximum_bytes = self.app_config.memory.platform_event_payload_bytes,
                    .maximum_path_bytes = self.app_config.memory.platform_event_payload_bytes,
                    .maximum_paths = self.app_config.memory.file_drop_path_count,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {
                        if (drag.entered) self.queue(drag.window.id, .{ .input = .file_drop_exited });
                        clearDrag(self, seat);
                        progress = true;
                        break;
                    },
                };
                if (paths.len > self.app_config.memory.file_drop_path_count) {
                    for (paths) |path| self.allocator.free(@constCast(path));
                    self.allocator.free(paths);
                    if (drag.entered) self.queue(drag.window.id, .{ .input = .file_drop_exited });
                    clearDrag(self, seat);
                    progress = true;
                    break;
                }
                drag.paths = paths;
                drag.bytes.deinit(self.allocator);
                drag.bytes = .empty;
                drag.ready = true;
                progress = true;
                if (drag.dropped) {
                    finishDrop(self, seat);
                } else if (paths.len != 0) {
                    drag.entered = true;
                    self.queueDrop(drag.window.id, .entered, paths, drag.position);
                }
                break;
            },
        };
    }
    return progress;
}

fn dragPollTimeout(self: *Context) i32 {
    const now = sys.monotonicNanoseconds();
    var deadline: ?u64 = null;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat| {
        if (seat.*.drag) |drag| {
            if (!drag.ready) deadline = if (deadline) |existing| @min(existing, drag.deadline_ns) else drag.deadline_ns;
        }
    }
    const value = deadline orelse return -1;
    if (value <= now) return 0;
    return @intCast(@min((value - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(i32)));
}

fn releaseOfferIfUnused(self: *Context, object: u32) void {
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat| {
        if (seat.*.selection_offer == object) return;
        if (seat.*.drag) |drag| if (drag.offer == object) return;
    }
    const removed = self.offers.fetchRemove(object) orelse return;
    protocol.dataOfferDestroy(&self.client.connection, object) catch |err| self.fail(err);
    self.client.objects.retire(object) catch |err| self.fail(err);
    removed.value.deinit(self);
    self.allocator.destroy(removed.value);
}

fn handleDmabuf(opcode: u16, reader: *wire.Reader) Error!void {
    switch (opcode) {
        0 => _ = try reader.u32(),
        1 => {
            _ = try reader.u32();
            _ = try reader.u32();
            _ = try reader.u32();
        },
        else => return error.PlatformFailure,
    }
}

fn handleDmabufParams(_: *Context, object_id: u32, opcode: u16, reader: *wire.Reader) Error!void {
    switch (opcode) {
        0 => {
            const buffer_id = try reader.object();
            _ = object_id;
            _ = buffer_id;
            return error.PlatformFailure;
        },
        1 => return error.SurfaceUnavailable,
        else => return error.PlatformFailure,
    }
}

fn handlePresentationFeedback(object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    switch (opcode) {
        0 => _ = try reader.object(),
        1 => {
            inline for (0..7) |_| _ = try reader.u32();
            if (object.owner != 0) {
                const native: *NativeWindow = @ptrFromInt(object.owner);
                native.presentation_feedback = null;
            }
        },
        2 => if (object.owner != 0) {
            const native: *NativeWindow = @ptrFromInt(object.owner);
            native.presentation_feedback = null;
        },
        else => return error.PlatformFailure,
    }
}

fn handleDecoration(opcode: u16, reader: *wire.Reader) Error!void {
    if (opcode != 0) return error.PlatformFailure;
    _ = try reader.u32();
}

fn handleExported(self: *Context, object: client_mod.Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (opcode != 0) return error.PlatformFailure;
    const source = try reader.string();
    if (object.owner == 0) return;
    const native: *NativeWindow = @ptrFromInt(object.owner);
    try self.retained_text.replace(self.allocator, &native.portal_handle, source);
}

fn setTextInputActive(raw: *anyopaque, id: handles.WindowId, active: bool) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (native.text_input_active == active) return;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat_pointer| {
        const seat = seat_pointer.*;
        if (seat.keyboard_window == native) try updateTextInputActivation(seat, native, active);
    }
    native.text_input_active = active;
    if (!active) {
        self.retained_text.release(self.allocator, &native.surrounding_text);
        native.selection = .{ .start = 0, .end = 0 };
    }
}

fn setCandidateRect(raw: *anyopaque, id: handles.WindowId, rect: geometry.Rect) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    const previous = native.candidate_rect;
    native.candidate_rect = rect;
    errdefer native.candidate_rect = previous;
    if (!native.text_input_active) return;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat_pointer| if (seat_pointer.*.keyboard_window == native and seat_pointer.*.text_input != null) {
        try sendCursorRectangle(seat_pointer.*, native);
        try protocol.textInputCommit(&self.client.connection, seat_pointer.*.text_input.?);
    };
}

fn setSurroundingText(raw: *anyopaque, id: handles.WindowId, text: []const u8, selection: input.TextRange) Error!void {
    const self = cast(raw);
    const native = self.windows.get(id.encode()) orelse return error.InvalidHandle;
    if (selection.start > text.len or selection.end > text.len) return error.InvalidConfiguration;
    try self.retained_text.replace(self.allocator, &native.surrounding_text, text);
    native.selection = selection;
    if (!native.text_input_active) return;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat_pointer| if (seat_pointer.*.keyboard_window == native and seat_pointer.*.text_input != null) {
        try sendSurroundingText(seat_pointer.*, native);
        try protocol.textInputCommit(&self.client.connection, seat_pointer.*.text_input.?);
    };
}

fn updateTextInputActivation(seat: *Seat, native: *NativeWindow, active: bool) Error!void {
    const text_input = seat.text_input orelse return;
    if (active) {
        try protocol.textInputEnable(&seat.context.client.connection, text_input);
        try sendSurroundingText(seat, native);
        try sendCursorRectangle(seat, native);
    } else {
        try protocol.textInputDisable(&seat.context.client.connection, text_input);
    }
    try protocol.textInputCommit(&seat.context.client.connection, text_input);
}

fn sendSurroundingText(seat: *Seat, native: *NativeWindow) Error!void {
    const text_input = seat.text_input orelse return;
    const maximum = 60 * 1024;
    const surrounding = native.surrounding_text orelse "";
    const normalized = native.selection.normalized();
    const cursor = @min(normalized.end, surrounding.len);
    const anchor = @min(normalized.start, surrounding.len);
    var start: usize = 0;
    var end = surrounding.len;
    if (end > maximum) {
        start = cursor -| maximum / 2;
        end = @min(start + maximum, surrounding.len);
        if (anchor < start) start = anchor;
        if (anchor > end) end = anchor;
        if (end - start > maximum) {
            start = @min(anchor, cursor);
            end = @max(anchor, cursor);
            if (end - start > maximum) return error.BudgetExceeded;
        }
        while (start < end and isUtf8Continuation(surrounding[start])) start += 1;
        while (end > start and end < surrounding.len and isUtf8Continuation(surrounding[end])) end -= 1;
    }
    try protocol.textInputSetSurrounding(
        &seat.context.client.connection,
        text_input,
        surrounding[start..end],
        @intCast(cursor - start),
        @intCast(anchor - start),
    );
}

fn sendCursorRectangle(seat: *Seat, native: *NativeWindow) Error!void {
    const text_input = seat.text_input orelse return;
    const rect = native.candidate_rect;
    try protocol.textInputSetCursorRectangle(
        &seat.context.client.connection,
        text_input,
        saturatedI32(@floor(rect.origin.x)),
        saturatedI32(@floor(rect.origin.y)),
        @max(1, saturatedI32(@ceil(rect.size.width))),
        @max(1, saturatedI32(@ceil(rect.size.height))),
    );
}

fn commitPendingIme(self: *Context, seat: *Seat) Error!void {
    const native = seat.keyboard_window orelse {
        clearPendingIme(seat);
        return;
    };
    if (seat.pending_commit) |commit| {
        self.queueText(native.id, .{ .commit_text = .{ .text = commit, .replacement_utf8 = seat.pending_replacement } }, commit);
    } else if (seat.pending_replacement) |replacement| {
        self.queueText(native.id, .{ .commit_text = .{ .text = "", .replacement_utf8 = replacement } }, "");
    }
    if (seat.pending_preedit) |preedit| {
        self.queueText(native.id, .{ .set_marked_text = .{
            .text = preedit,
            .selected_utf8 = seat.pending_preedit_selection,
            .replacement_utf8 = seat.pending_replacement,
        } }, preedit);
    } else {
        self.queue(native.id, .{ .input = .{ .ime = .unmark_text } });
    }
    clearPendingIme(seat);
}

fn clearPendingIme(seat: *Seat) void {
    seat.context.retained_text.release(seat.context.allocator, &seat.pending_preedit);
    seat.context.retained_text.release(seat.context.allocator, &seat.pending_commit);
    seat.pending_replacement = null;
    seat.pending_preedit_selection = .{ .start = 0, .end = 0 };
}

fn readClipboard(raw: *anyopaque, allocator: std.mem.Allocator) Error!?[]u8 {
    const self = cast(raw);
    var selected_offer: ?*DataOffer = null;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat_pointer| {
        const object = seat_pointer.*.selection_offer orelse continue;
        const offer = self.offers.get(object) orelse continue;
        if (offer.supportsText() != null) {
            selected_offer = offer;
            break;
        }
    }
    const offer = selected_offer orelse return if (self.clipboard_text) |text| try allocator.dupe(u8, text) else null;
    const mime = offer.supportsText() orelse return null;
    const descriptors = try sys.createPipe();
    var read_open = true;
    defer if (read_open) sys.close(descriptors[0]);
    var write_open = true;
    defer if (write_open) sys.close(descriptors[1]);
    try protocol.dataOfferReceive(&self.client.connection, offer.object, mime, descriptors[1]);
    sys.close(descriptors[1]);
    write_open = false;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const deadline = sys.monotonicNanoseconds() +| 30 * std.time.ns_per_s;
    var scratch: [16 * 1024]u8 = undefined;
    while (true) {
        switch (try sys.readNonBlocking(descriptors[0], &scratch)) {
            .bytes => |count| {
                if (count > self.app_config.memory.clipboard_bytes -| result.items.len)
                    return error.BudgetExceeded;
                try result.appendSlice(allocator, scratch[0..count]);
                continue;
            },
            .end_of_file => break,
            .would_block => {},
        }
        const now = sys.monotonicNanoseconds();
        if (now >= deadline) return error.Cancelled;
        const timeout_ms: i32 = @intCast(@min((deadline - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(i32)));
        var polled = [_]sys.linux.pollfd{
            .{ .fd = descriptors[0], .events = sys.linux.POLL.IN, .revents = 0 },
            .{ .fd = self.client.descriptor(), .events = sys.linux.POLL.IN, .revents = 0 },
        };
        _ = try sys.poll(&polled, timeout_ms);
        if (polled[0].revents & (sys.linux.POLL.ERR | sys.linux.POLL.NVAL) != 0) return error.PlatformFailure;
        if (polled[1].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0) return error.PlatformFailure;
        if (polled[1].revents & sys.linux.POLL.IN != 0) {
            _ = try self.client.receive();
            _ = try self.client.drainBuffered(self.handler());
        }
    }
    sys.close(descriptors[0]);
    read_open = false;
    return try result.toOwnedSlice(allocator);
}

fn writeClipboard(raw: *anyopaque, value: []const u8) Error!void {
    const self = cast(raw);
    const old_bytes = if (self.clipboard_text) |old| old.len else 0;
    const retained_without_current = self.clipboard_owned_bytes - old_bytes;
    var publication_count: usize = 0;
    var seats_for_budget = self.seats.valueIterator();
    while (seats_for_budget.next()) |seat_pointer| {
        if (seat_pointer.*.active and seat_pointer.*.serial != 0) publication_count += 1;
    }
    const publication_bytes = std.math.mul(usize, value.len, publication_count) catch
        return error.BudgetExceeded;
    const required = std.math.add(usize, value.len, publication_bytes) catch
        return error.BudgetExceeded;
    if (required > self.app_config.memory.clipboard_retained_bytes -| retained_without_current)
        return error.BudgetExceeded;
    const replacement = try self.allocator.dupe(u8, value);
    if (self.clipboard_text) |old| self.allocator.free(old);
    self.clipboard_text = replacement;
    self.clipboard_owned_bytes = retained_without_current + replacement.len;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat_pointer| {
        if (seat_pointer.*.active and seat_pointer.*.serial != 0) try publishClipboard(self, seat_pointer.*);
    }
}

fn publishClipboard(self: *Context, seat: *Seat) Error!void {
    const manager = self.data_device_manager orelse return error.MissingCapability;
    const device = seat.data_device orelse return error.MissingCapability;
    const text = self.clipboard_text orelse return;
    if (text.len > self.app_config.memory.clipboard_retained_bytes -| self.clipboard_owned_bytes)
        return error.BudgetExceeded;
    if (self.clipboard_sources.count() >= self.app_config.memory.platform_object_count)
        return error.BudgetExceeded;
    try self.client.connection.prepareOutgoing(64, 0);
    try self.clipboard_sources.ensureUnusedCapacity(1);
    const source = try self.allocator.create(ClipboardSource);
    errdefer self.allocator.destroy(source);
    source.* = .{ .object = 0, .text = try self.allocator.dupe(u8, text) };
    errdefer self.allocator.free(source.text);
    const version = self.client.objects.get(manager).?.version;
    const object = try self.client.createObject(.wl_data_source, version, @intFromPtr(source));
    var published = false;
    errdefer rollbackCreatedObject(self, object, published);
    errdefer {
        if (self.client.objects.getPtr(object)) |record| record.owner = 0;
    }
    source.object = object;
    try protocol.dataDeviceManagerCreateSource(&self.client.connection, manager, object);
    published = true;
    try protocol.dataSourceOffer(&self.client.connection, object, "text/plain;charset=utf-8");
    try protocol.dataSourceOffer(&self.client.connection, object, "text/plain");
    try protocol.dataDeviceSetSelection(&self.client.connection, device, object, seat.serial);
    self.clipboard_sources.putAssumeCapacity(object, source);
    self.clipboard_owned_bytes += source.text.len;
    seat.clipboard_source = object;
}

fn ensureSeatClipboard(self: *Context, seat: *Seat) Error!void {
    if (self.clipboard_text != null and seat.clipboard_source == null and seat.data_device != null)
        try publishClipboard(self, seat);
}

fn destroyClipboardSource(self: *Context, object: u32) void {
    const source = self.clipboard_sources.get(object) orelse return;
    if (source.retired) return;
    protocol.dataSourceDestroy(&self.client.connection, object) catch |err| self.fail(err);
    self.client.objects.retire(object) catch |err| self.fail(err);
    source.retired = true;
    var seats = self.seats.valueIterator();
    while (seats.next()) |seat| {
        if (seat.*.clipboard_source == object) seat.*.clipboard_source = null;
    }
}

fn releaseSeatDevices(self: *Context, seat: *Seat) void {
    clearDrag(self, seat);
    clearPendingIme(seat);
    self.retained_text.release(self.allocator, &seat.keymap);
    if (seat.selection_offer) |offer| {
        seat.selection_offer = null;
        releaseOfferIfUnused(self, offer);
    }
    if (seat.cursor_shape) |device| retireWithOpcode(self, device, 0);
    if (seat.pointer) |pointer| retireVersioned(self, pointer, 3, 1);
    if (seat.keyboard) |keyboard| retireVersioned(self, keyboard, 3, 0);
    if (seat.touch) |touch| retireVersioned(self, touch, 3, 0);
    if (seat.text_input) |text_input| retireWithOpcode(self, text_input, 0);
    if (seat.data_device) |data_device| retireVersioned(self, data_device, 2, 2);
    retireVersioned(self, seat.object, 5, 3);
    seat.cursor_shape = null;
    seat.pointer = null;
    seat.keyboard = null;
    seat.touch = null;
    seat.text_input = null;
    seat.data_device = null;
    seat.pointer_window = null;
    seat.keyboard_window = null;
    seat.touches.clearRetainingCapacity();
}

fn retireWithDestructor(self: *Context, object: u32) void {
    retireWithOpcode(self, object, 0);
}

fn retireWithOpcode(self: *Context, object: u32, opcode: u16) void {
    const record = self.client.objects.get(object) orelse return;
    if (record.state == .retired) return;
    if (self.client.connection.isBroken()) return;
    const message = self.client.connection.begin(object, opcode) catch |err| return self.fail(err);
    _ = message;
    self.client.connection.send() catch |err| return self.fail(err);
    self.client.objects.retire(object) catch |err| self.fail(err);
}

fn updateWindowIntegerScale(self: *Context, native: *NativeWindow) Error!void {
    var scale: i32 = 1;
    for (native.outputs.items) |object| {
        if (self.outputs.get(object)) |output| {
            if (output.active) scale = @max(scale, output.scale);
        }
    }
    try setWindowScale(self, native, @floatFromInt(scale));
}

fn setWindowScale(self: *Context, native: *NativeWindow, value: f32) Error!void {
    const scale = geometry.ScaleFactor.init(value) catch return error.InvalidScaleFactor;
    if (scale.value == native.scale_factor.value) return;
    const frame_event = native.visible and native.configured and native.frame_callback == null;
    try self.preparePendingSlots(1 + @as(usize, @intFromBool(frame_event)));
    native.scale_factor = scale;
    self.events.appendAssumeCapacity(.{ .window = native.id, .event = .{ .scale_changed = scale } });
    try requestFrame(self, native.id);
    sys.wake(self.wake_fd);
}

fn pointerEvent(seat: *Seat, button: ?input.MouseButton, timestamp: u64) input.PointerEvent {
    return .{
        .position = seat.pointer_position,
        .button = button,
        .buttons = seat.buttons,
        .modifiers = seat.keyboard_state.modifiers,
        .click_count = if (button != null) 1 else 0,
        .timestamp_ns = timestamp,
    };
}

fn touchEvent(seat: *Seat, id: i32, position: geometry.Point, timestamp: u64) input.PointerEvent {
    return .{
        .pointer_id = @bitCast(@as(i64, id)),
        .kind = .touch,
        .position = position,
        .button = .primary,
        .buttons = 1,
        .pressure = 1,
        .modifiers = seat.keyboard_state.modifiers,
        .timestamp_ns = timestamp,
    };
}

fn emitScroll(self: *Context, seat: *Seat, phase: input.ScrollPhase) void {
    const native = seat.pointer_window orelse {
        seat.scroll_delta = .{};
        seat.scroll_discrete = .{};
        return;
    };
    var delta = seat.scroll_delta;
    if (delta.x == 0 and delta.y == 0) delta = .{
        .x = seat.scroll_discrete.x * 40,
        .y = seat.scroll_discrete.y * 40,
    };
    if (delta.x != 0 or delta.y != 0 or phase == .ended) self.queue(native.id, .{ .input = .{ .scroll = .{
        .position = seat.pointer_position,
        .delta = delta,
        .precise = seat.scroll_source != .wheel and seat.scroll_discrete.x == 0 and seat.scroll_discrete.y == 0,
        .phase = phase,
        .modifiers = seat.keyboard_state.modifiers,
        .timestamp_ns = sys.monotonicNanoseconds(),
    } } });
    seat.scroll_delta = .{};
    seat.scroll_discrete = .{};
}

fn mouseButton(code: u32) input.MouseButton {
    return switch (code) {
        0x110 => .primary,
        0x111 => .secondary,
        0x112 => .middle,
        0x113, 0x116 => .back,
        0x114, 0x115 => .forward,
        else => .other,
    };
}

fn buttonMask(button: input.MouseButton) u32 {
    return @as(u32, 1) << @as(u5, @intCast(@backingInt(button)));
}

fn cursorShape(cursor: api.Cursor) protocol.CursorShape {
    return switch (cursor) {
        .default => .default,
        .pointer => .pointer,
        .text => .text,
        .crosshair => .crosshair,
        .grab => .grab,
        .grabbing => .grabbing,
        .resize_horizontal => .ew_resize,
        .resize_vertical => .ns_resize,
        .resize_diagonal_nw_se => .nwse_resize,
        .resize_diagonal_ne_sw => .nesw_resize,
        .not_allowed => .not_allowed,
        .hidden => .default,
    };
}

fn resolveSocketPath(allocator: std.mem.Allocator, linux_config: config.LinuxConfig) Error![]u8 {
    if (linux_config.wayland_socket_path) |path| return allocator.dupe(u8, path);
    var environment: [environment_storage_bytes]u8 = undefined;
    const display = linux_config.wayland_display orelse (try sys.initialEnvironment("WAYLAND_DISPLAY", &environment)) orelse "wayland-0";
    if (std.fs.path.isAbsolute(display)) return allocator.dupe(u8, display);
    var runtime_environment: [environment_storage_bytes]u8 = undefined;
    const runtime_directory = linux_config.runtime_directory orelse (try sys.initialEnvironment("XDG_RUNTIME_DIR", &runtime_environment)) orelse return error.MissingCapability;
    return std.fs.path.join(allocator, &.{ runtime_directory, display });
}

fn positiveDimension(value: f32) i32 {
    return @max(1, saturatedI32(@round(value)));
}

fn optionalDimension(value: f32) i32 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return positiveDimension(value);
}

fn boundedDimension(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    return optionalDimension(value);
}

fn saturatedI32(value: f32) i32 {
    if (!std.math.isFinite(value)) return if (value < 0) std.math.minInt(i32) else std.math.maxInt(i32);
    return @intFromFloat(std.math.clamp(value, @as(f32, @floatFromInt(std.math.minInt(i32))), @as(f32, @floatFromInt(std.math.maxInt(i32)))));
}

fn signedIndex(value: i32, length: usize) usize {
    if (value <= 0) return 0;
    return @min(@as(usize, @intCast(value)), length);
}

fn containsU32(values: []const u32, needle: u32) bool {
    return std.mem.indexOfScalar(u32, values, needle) != null;
}

fn removeU32(values: *std.ArrayList(u32), needle: u32) void {
    const index = std.mem.indexOfScalar(u32, values.items, needle) orelse return;
    _ = values.swapRemove(index);
}

fn isUtf8Continuation(value: u8) bool {
    return value & 0xc0 == 0x80;
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BudgetExceeded => error.BudgetExceeded,
        error.InvalidConfiguration => error.InvalidConfiguration,
        error.InvalidHandle => error.InvalidHandle,
        error.MissingCapability => error.MissingCapability,
        error.ResourceBusy => error.ResourceBusy,
        error.SurfaceUnavailable => error.SurfaceUnavailable,
        error.Unsupported => error.Unsupported,
        else => error.PlatformFailure,
    };
}
