const std = @import("std");
const config = @import("../../config.zig");
const Error = @import("../../core/error.zig").Error;
const clock = @import("../../core/clock.zig");
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const native_media_placement = @import("../../core/native_media.zig");
const input = @import("../../input/event.zig");
const api = @import("../api.zig");
const event_memory = @import("../event_memory.zig");
const metal = @import("../../backend/metal/renderer.zig");
const in_tree_text = if (config.text_enabled) @import("../../text/in_tree_backend.zig") else struct {};
const macos_fonts = if (config.text_enabled) @import("fonts.zig") else struct {};
const macos_a11y = if (config.accessibility_enabled) @import("accessibility.zig") else struct {
    pub const Adapter = opaque {};
};
const objc = @import("objc.zig");
const promised_files = @import("promised_files.zig");
const page_capture = @import("page_capture.zig");
const surface = @import("surface.zig");
const types = @import("types.zig");
const unicode = @import("../../text/unicode.zig");

extern "c" fn pthread_main_np() c_int;
extern "c" fn mach_continuous_time() u64;
extern "c" fn mach_timebase_info(info: *MachTimebaseInfo) c_int;
extern "c" fn CVDisplayLinkCreateWithActiveCGDisplays(link: *CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkCreateWithCGDisplay(display: u32, link: *CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkSetCurrentCGDisplay(link: CVDisplayLinkRef, display: u32) i32;
extern "c" fn CVDisplayLinkGetCurrentCGDisplay(link: CVDisplayLinkRef) u32;
extern "c" fn CVDisplayLinkSetOutputCallback(link: CVDisplayLinkRef, callback: CVDisplayLinkCallback, context: ?*anyopaque) i32;
extern "c" fn CVDisplayLinkStart(link: CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkStop(link: CVDisplayLinkRef) i32;
extern "c" fn CVDisplayLinkIsRunning(link: CVDisplayLinkRef) bool;
extern "c" fn CVDisplayLinkRelease(link: CVDisplayLinkRef) void;
extern "c" fn CGWindowListCreateImage(bounds: types.Rect, list_option: u32, window_id: u32, image_option: u32) objc.Id;
extern "c" fn CGImageGetWidth(image: objc.Id) usize;
extern "c" fn CGImageGetHeight(image: objc.Id) usize;
extern "c" fn CGImageRelease(image: objc.Id) void;
extern "c" var CGRectNull: types.Rect;
extern "c" var _dispatch_main_q: u8;
extern "c" fn dispatch_async_f(queue: objc.Id, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_after_f(when: u64, queue: objc.Id, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" var NSPasteboardURLReadingFileURLsOnlyKey: objc.Id;

const MachTimebaseInfo = extern struct { numerator: u32, denominator: u32 };
const CVDisplayLinkRef = ?*anyopaque;
const CVTimeStamp = extern struct {
    version: u32,
    video_time_scale: i32,
    video_time: i64,
    host_time: u64,
    rate_scalar: f64,
    video_refresh_period: i64,
    smpte_time: [24]u8,
    flags: u64,
    reserved: u64,
};
const CVDisplayLinkCallback = *const fn (
    CVDisplayLinkRef,
    *const CVTimeStamp,
    *const CVTimeStamp,
    u64,
    *u64,
    ?*anyopaque,
) callconv(.c) i32;

const layer_contents_redraw_during_view_resize: usize = 2;
const layer_contents_placement_top_left: usize = 11;
const layer_autoresizing_width_and_height: u32 = (1 << 1) | (1 << 4);
const cg_window_list_option_including_window: u32 = 1 << 3;
const cg_window_image_bounds_ignore_framing: u32 = 1 << 0;
const cg_window_image_nominal_resolution: u32 = 1 << 3;

const DisplayLinkState = struct {
    allocator: std.mem.Allocator,
    context: std.atomic.Value(usize),
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    tick_pending: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    fn retain(self: *DisplayLinkState) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *DisplayLinkState) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};

const DelayedWakeState = struct {
    context: std.atomic.Value(usize),
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    fn retain(self: *DelayedWakeState) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *DelayedWakeState) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(self);
    }
};

const NativeWindow = struct {
    ns_window: objc.Id,
    view: objc.Id,
    layer: objc.Id,
    logical_size: geometry.Size,
    scale_factor: geometry.ScaleFactor,
    visible: bool,
    closing: bool = false,
    candidate_rect: geometry.Rect = .{},
    surrounding_text: ?[]u8 = null,
    selection: input.TextRange = .{ .start = 0, .end = 0 },
    marked_range: types.Range = .{ .location = types.not_found, .length = 0 },
    frame_queued: bool = false,
    text_input_active: bool = false,
    cursor: api.Cursor = .default,
    cursor_hidden: bool = false,
    display_number: u32 = 0,
    mode: api.WindowMode = .normal,

    fn deinit(self: *NativeWindow, context: *Context) void {
        if (self.cursor_hidden) objc.send(void, objc.class("NSCursor"), "unhide", .{});
        context.retained_text.release(context.allocator, &self.surrounding_text);
        _ = objc.setIvar(?*Context, self.view, "_ziguiContext", null);
        objc.send(void, self.ns_window, "setDelegate:", .{@as(objc.Id, null)});
        objc.send(void, self.view, "setLayer:", .{@as(objc.Id, null)});
        objc.send(void, self.ns_window, "close", .{});
        objc.release(self.ns_window);
        self.* = undefined;
    }
};

const CMTime = extern struct {
    value: i64 = 0,
    timescale: i32 = 0,
    flags: u32 = 0,
    epoch: i64 = 0,
};

const NativeMediaPlayer = struct {
    window: handles.WindowId,
    player: objc.Id,
    layer: objc.Id,
    scene_managed: bool = false,
    has_presented_frame: bool = false,

    fn deinit(self: *NativeMediaPlayer) void {
        objc.send(void, self.player, "pause", .{});
        objc.send(void, self.layer, "removeFromSuperlayer", .{});
        objc.release(self.layer);
        objc.release(self.player);
        self.* = undefined;
    }
};

const NativeMediaPool = handles.SlotPool(NativeMediaPlayer, handles.NativeMediaId);

const PrintContext = struct {
    allocator: std.mem.Allocator,
    document: objc.Id,
};

const PrintWindowCandidate = struct {
    native: objc.Id,
    order: u64,
    visible: bool,
    closing: bool,
};

const Pending = struct {
    window: handles.WindowId,
    event: api.WindowEvent,
    owned_text: ?[]u8 = null,
    owned_paths: ?[][]const u8 = null,
    promised_file_service: ?*promised_files.Service = null,
    owned_bytes: usize = 0,

    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        switch (self.event) {
            .input => |event| switch (event) {
                .file_drop_entered, .file_drop_updated, .file_drop_performed => |drop| {
                    if (drop.promised_batch) |batch| {
                        if (self.promised_file_service) |service| {
                            service.interface().releaseBatch(batch) catch {};
                        }
                    }
                },
                else => {},
            },
            else => {},
        }
        if (self.owned_text) |text| allocator.free(text);
        if (self.owned_paths) |paths| {
            for (paths) |path| allocator.free(@constCast(path));
            allocator.free(paths);
        }
        self.* = undefined;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    application: objc.Id,
    view_class: objc.Class,
    windows: std.AutoHashMap(u64, NativeWindow),
    native_media_players: NativeMediaPool,
    maximum_native_media_players: usize,
    promised_file_service: promised_files.Service,
    page_capture_service: page_capture.Service,
    events: std.ArrayList(Pending) = .empty,
    event_cursor: usize = 0,
    maximum_events: usize,
    maximum_windows: usize,
    maximum_event_payload_bytes: usize,
    maximum_event_queue_bytes: usize,
    maximum_file_drop_paths: usize,
    maximum_clipboard_bytes: usize,
    retained_text: event_memory.RetainedTextBudget,
    pending_open_paths: std.ArrayList([]u8) = .empty,
    pending_open_text: std.ArrayList(u8) = .empty,
    pending_open_payload_bytes: usize = 0,
    pending_payload_bytes: usize = 0,
    quit: bool = false,
    failure: ?Error = null,
    active_sink: ?api.EventSink = null,
    sink_dispatch_depth: u32 = 0,
    timebase: MachTimebaseInfo,
    menu_target: objc.Id,
    display_link: CVDisplayLinkRef = null,
    display_link_state: ?*DisplayLinkState = null,
    delayed_wake_state: ?*DelayedWakeState = null,
    previous_mouse_coalescing: ?bool = null,

    fn init(
        allocator: std.mem.Allocator,
        maximum_events: usize,
        maximum_windows: usize,
        maximum_event_payload_bytes: usize,
        maximum_event_queue_bytes: usize,
        maximum_file_drop_paths: usize,
        maximum_clipboard_bytes: usize,
        maximum_retained_text_bytes: usize,
        maximum_native_media_players: usize,
        maximum_platform_objects: usize,
        maximum_page_capture_result_bytes: usize,
        maximum_page_capture_pixels: usize,
        maximum_page_capture_requests: usize,
    ) Error!*Context {
        if (pthread_main_np() == 0) return error.ThreadAffinity;
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        var timebase: MachTimebaseInfo = undefined;
        if (mach_timebase_info(&timebase) != 0 or timebase.denominator == 0) return error.PlatformFailure;
        const view_class = try registerViewClass();
        const application = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{}) orelse return error.PlatformFailure;
        const menu_class = try registerMenuTargetClass();
        const menu_target = objc.send(objc.Id, objc.send(objc.Id, menu_class, "alloc", .{}), "init", .{}) orelse return error.PlatformFailure;
        errdefer objc.release(menu_target);
        _ = objc.send(bool, application, "setActivationPolicy:", .{@as(isize, 0)});
        const display_link_state = try allocator.create(DisplayLinkState);
        errdefer allocator.destroy(display_link_state);
        display_link_state.* = .{
            .allocator = allocator,
            .context = std.atomic.Value(usize).init(@intFromPtr(self)),
        };
        const delayed_wake_state = std.heap.c_allocator.create(DelayedWakeState) catch return error.OutOfMemory;
        errdefer std.heap.c_allocator.destroy(delayed_wake_state);
        delayed_wake_state.* = .{ .context = std.atomic.Value(usize).init(@intFromPtr(self)) };
        self.* = .{
            .allocator = allocator,
            .application = application,
            .view_class = view_class,
            .windows = std.AutoHashMap(u64, NativeWindow).init(allocator),
            .native_media_players = NativeMediaPool.init(allocator),
            .maximum_native_media_players = maximum_native_media_players,
            .promised_file_service = undefined,
            .page_capture_service = undefined,
            .maximum_events = maximum_events,
            .maximum_windows = maximum_windows,
            .maximum_event_payload_bytes = maximum_event_payload_bytes,
            .maximum_event_queue_bytes = maximum_event_queue_bytes,
            .maximum_file_drop_paths = maximum_file_drop_paths,
            .maximum_clipboard_bytes = maximum_clipboard_bytes,
            .retained_text = try event_memory.RetainedTextBudget.init(maximum_retained_text_bytes),
            .timebase = timebase,
            .menu_target = menu_target,
            .display_link_state = display_link_state,
            .delayed_wake_state = delayed_wake_state,
        };
        self.promised_file_service = try promised_files.Service.init(
            allocator,
            maximum_platform_objects,
            maximum_platform_objects,
            maximum_file_drop_paths,
            maximum_event_payload_bytes,
            self,
            wake,
        );
        errdefer self.promised_file_service.deinit();
        _ = self.promised_file_service.interface();
        self.page_capture_service = try page_capture.Service.init(
            allocator,
            maximum_page_capture_requests,
            maximum_retained_text_bytes,
            maximum_page_capture_result_bytes,
            maximum_page_capture_pixels,
            16_384,
            60 * std.time.ns_per_s,
            maximum_event_payload_bytes,
            self,
            wake,
        );
        errdefer self.page_capture_service.deinit();
        _ = self.page_capture_service.interface();
        if (!objc.setIvar(?*Context, menu_target, "_ziguiContext", self)) return error.PlatformFailure;
        objc.send(void, application, "setDelegate:", .{menu_target});
        objc.send(void, application, "finishLaunching", .{});
        objc.send(void, application, "activateIgnoringOtherApps:", .{true});
        try installMainMenu(self, &.{});
        return self;
    }

    fn deinit(self: *Context) void {
        if (self.delayed_wake_state) |state| {
            state.context.store(0, .release);
            state.release();
            self.delayed_wake_state = null;
        }
        if (self.previous_mouse_coalescing) |enabled| {
            objc.send(void, objc.class("NSEvent"), "setMouseCoalescingEnabled:", .{enabled});
            self.previous_mouse_coalescing = null;
        }
        if (self.display_link) |link| {
            if (self.display_link_state) |state| state.context.store(0, .release);
            if (CVDisplayLinkIsRunning(link)) _ = CVDisplayLinkStop(link);
            CVDisplayLinkRelease(link);
            self.display_link = null;
        }
        if (self.display_link_state) |state| {
            drainDisplayLinkCallbacks(state);
            state.release();
            self.display_link_state = null;
        }
        var media_iterator = self.native_media_players.iterator();
        while (media_iterator.next()) |entry| entry.value.deinit();
        self.native_media_players.deinit();
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(self);
        self.windows.deinit();
        for (self.events.items[self.event_cursor..]) |*pending| pending.deinit(self.allocator);
        self.events.deinit(self.allocator);
        // Pending file-drop events release their opaque promise batches from
        // Pending.deinit.  Keep the service alive until those event-owned
        // handles have been released during teardown.
        self.page_capture_service.deinit();
        self.promised_file_service.deinit();
        objc.send(void, self.application, "setWindowsMenu:", .{@as(objc.Id, null)});
        objc.send(void, self.application, "setMainMenu:", .{@as(objc.Id, null)});
        objc.send(void, self.application, "setDelegate:", .{@as(objc.Id, null)});
        _ = objc.setIvar(?*Context, self.menu_target, "_ziguiContext", null);
        objc.release(self.menu_target);
        for (self.pending_open_paths.items) |path| self.allocator.free(path);
        self.pending_open_paths.deinit(self.allocator);
        self.pending_open_text.deinit(self.allocator);
        std.debug.assert(self.retained_text.used_bytes == 0);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn now(self: *const Context) u64 {
        const ticks = mach_continuous_time();
        const nanoseconds = (@as(u128, ticks) * self.timebase.numerator) / self.timebase.denominator;
        return @intCast(@min(nanoseconds, std.math.maxInt(u64)));
    }

    fn queue(self: *Context, window: handles.WindowId, event: api.WindowEvent) void {
        self.appendPending(.{ .window = window, .event = event }) catch |err| self.fail(err);
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

    fn queueIme(self: *Context, window: handles.WindowId, source: input.ImeEvent, bytes: []const u8) void {
        const borrowed: input.Event = .{ .ime = source };
        self.validateInput(&borrowed) catch |err| {
            self.fail(err);
            return;
        };
        _ = event_memory.ensureFits(bytes, null, self.pending_payload_bytes, self.maximum_event_queue_bytes) catch |err| {
            self.fail(err);
            return;
        };
        const owned = self.allocator.dupe(u8, bytes) catch |err| {
            self.fail(err);
            return;
        };
        const owned_event: input.ImeEvent = switch (source) {
            .set_marked_text => |marked| .{ .set_marked_text = .{
                .text = owned,
                .selected_utf8 = marked.selected_utf8,
                .replacement_utf8 = marked.replacement_utf8,
            } },
            .commit_text => |commit| .{ .commit_text = .{
                .text = owned,
                .replacement_utf8 = commit.replacement_utf8,
            } },
            else => unreachable,
        };
        const event: api.WindowEvent = .{ .input = .{ .ime = owned_event } };
        self.appendPending(.{ .window = window, .event = event, .owned_text = owned }) catch |err| {
            self.allocator.free(owned);
            self.fail(err);
            return;
        };
        wake(self);
    }

    fn queueDrop(
        self: *Context,
        window: handles.WindowId,
        tag: DropTag,
        paths_source: []const []const u8,
        text_source: ?[]const u8,
        promised_batch: ?handles.PromisedFileBatchId,
        promised_count: usize,
        position: geometry.Point,
    ) bool {
        // Enter/update only probe promise availability and do not retain
        // receivers. Their advisory event can therefore have no ordinary
        // payload; the performed event carries the owned promise batch.
        if (!dropPayloadRecognized(paths_source, text_source) and promised_batch == null and promised_count == 0)
            return false;
        if (promised_batch) |batch| if (!self.promised_file_service.ownsBatch(batch)) return false;
        const borrowed_drop: input.FileDrop = .{
            .paths = paths_source,
            .position = position,
            .text = text_source,
            .promised_batch = promised_batch,
        };
        const borrowed: input.Event = switch (tag) {
            .entered => .{ .file_drop_entered = borrowed_drop },
            .updated => .{ .file_drop_updated = borrowed_drop },
            .performed => .{ .file_drop_performed = borrowed_drop },
        };
        self.validateInput(&borrowed) catch |err| {
            self.fail(err);
            return false;
        };
        _ = event_memory.ensureFits(text_source, paths_source, self.pending_payload_bytes, self.maximum_event_queue_bytes) catch |err| {
            self.fail(err);
            return false;
        };
        const paths = self.allocator.alloc([]const u8, paths_source.len) catch |err| {
            self.fail(err);
            return false;
        };
        var initialized: usize = 0;
        for (paths_source, 0..) |path, index| {
            paths[index] = self.allocator.dupe(u8, path) catch |err| {
                for (paths[0..initialized]) |owned| self.allocator.free(@constCast(owned));
                self.allocator.free(paths);
                self.fail(err);
                return false;
            };
            initialized += 1;
        }
        const owned_text = if (text_source) |text| self.allocator.dupe(u8, text) catch |err| {
            for (paths) |owned| self.allocator.free(@constCast(owned));
            self.allocator.free(paths);
            self.fail(err);
            return false;
        } else null;
        const drop: input.FileDrop = .{
            .paths = paths,
            .position = position,
            .text = owned_text,
            .promised_batch = promised_batch,
        };
        const input_event: input.Event = switch (tag) {
            .entered => .{ .file_drop_entered = drop },
            .updated => .{ .file_drop_updated = drop },
            .performed => .{ .file_drop_performed = drop },
        };
        self.appendPending(.{
            .window = window,
            .event = .{ .input = input_event },
            .owned_text = owned_text,
            .owned_paths = paths,
            .promised_file_service = &self.promised_file_service,
        }) catch |err| {
            if (owned_text) |owned| self.allocator.free(owned);
            for (paths) |owned| self.allocator.free(@constCast(owned));
            self.allocator.free(paths);
            self.fail(err);
            return false;
        };
        wake(self);
        return true;
    }

    fn queueAccessibility(self: *Context, request: @import("../../a11y/api.zig").ActionRequest) void {
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
        _ = event_memory.ensureFits(request.value, null, self.pending_payload_bytes, self.maximum_event_queue_bytes) catch |err| {
            self.fail(err);
            return;
        };
        var owned_text: ?[]u8 = null;
        var copied = request;
        if (request.value) |value| {
            const owned = self.allocator.dupe(u8, value) catch |err| {
                self.fail(err);
                return;
            };
            owned_text = owned;
            copied.value = owned;
        }
        self.appendPending(.{
            .window = request.window,
            .event = .{ .accessibility_action = copied },
            .owned_text = owned_text,
        }) catch |err| {
            if (owned_text) |owned| self.allocator.free(owned);
            self.fail(err);
            return;
        };
        wake(self);
    }

    fn fail(self: *Context, err: anyerror) void {
        if (self.failure == null) self.failure = mapError(err);
        self.quit = true;
        wake(self);
    }

    fn validateInput(self: *const Context, event: *const input.Event) Error!void {
        try input.validate(event, .{
            .maximum_payload_bytes = self.maximum_event_payload_bytes,
            .maximum_file_paths = self.maximum_file_drop_paths,
        });
    }

    fn pop(self: *Context) ?Pending {
        if (self.event_cursor >= self.events.items.len) {
            self.compact();
            return null;
        }
        const pending = self.events.items[self.event_cursor];
        self.event_cursor += 1;
        switch (pending.event) {
            .frame_requested => {
                if (self.windows.getPtr(pending.window.encode())) |window| window.frame_queued = false;
            },
            else => {},
        }
        if (self.event_cursor == self.events.items.len) self.compact();
        return pending;
    }

    fn releasePending(self: *Context, pending: *const Pending) void {
        if (pending.owned_bytes > self.pending_payload_bytes) return self.fail(error.PlatformFailure);
        self.pending_payload_bytes -= pending.owned_bytes;
    }

    fn compact(self: *Context) void {
        if (self.event_cursor == 0) return;
        const remaining = self.events.items.len - self.event_cursor;
        if (remaining != 0) std.mem.copyForwards(Pending, self.events.items[0..remaining], self.events.items[self.event_cursor..]);
        self.events.items.len = remaining;
        self.event_cursor = 0;
    }

    fn emitWindowMetrics(self: *Context, id: handles.WindowId) void {
        const window = self.windows.getPtr(id.encode()) orelse return;
        const bounds = objc.send(types.Rect, window.view, "bounds", .{});
        const scale_value = objc.send(f64, window.ns_window, "backingScaleFactor", .{});
        const scale = geometry.ScaleFactor.init(@floatCast(scale_value)) catch return self.fail(error.InvalidScaleFactor);
        const size: geometry.Size = .{ .width = @floatCast(bounds.size.width), .height = @floatCast(bounds.size.height) };
        if (size.width != window.logical_size.width or size.height != window.logical_size.height) {
            window.logical_size = size;
            self.queue(id, .{ .resized = size });
        }
        if (scale.value != window.scale_factor.value) {
            window.scale_factor = scale;
            objc.send(void, window.layer, "setContentsScale:", .{@as(f64, scale.value)});
            self.queue(id, .{ .scale_changed = scale });
        }
    }

    fn displayTick(self: *Context, timestamp: u64) void {
        var any_queued = false;
        var iterator = self.windows.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.frame_queued) continue;
            entry.value_ptr.frame_queued = false;
            const id: handles.WindowId = .{
                .index = @truncate(entry.key_ptr.*),
                .generation = @truncate(entry.key_ptr.* >> 32),
            };
            self.queue(id, .{ .frame_requested = timestamp });
            any_queued = true;
        }
        if (any_queued) {
            postWakeEvent(self);
        } else if (self.display_link) |link| {
            if (CVDisplayLinkIsRunning(link)) _ = CVDisplayLinkStop(link);
        }
    }

    fn ensureDisplayLink(self: *Context, window: *NativeWindow) Error!CVDisplayLinkRef {
        if (window.display_number == 0) window.display_number = windowDisplayNumber(window);
        const display = window.display_number;
        if (self.display_link) |link| {
            if (display != 0 and displayLinkNeedsTarget(CVDisplayLinkGetCurrentCGDisplay(link), display)) {
                if (CVDisplayLinkSetCurrentCGDisplay(link, display) != 0) return error.SurfaceUnavailable;
            }
            return link;
        }
        const state = self.display_link_state orelse return error.PlatformFailure;
        var link: CVDisplayLinkRef = null;
        var status = CVDisplayLinkCreateWithActiveCGDisplays(&link);
        if (status != 0 or link == null) {
            if (display == 0) return error.SurfaceUnavailable;
            status = CVDisplayLinkCreateWithCGDisplay(display, &link);
        }
        if (status != 0 or link == null) return error.SurfaceUnavailable;
        errdefer CVDisplayLinkRelease(link);
        if (display != 0 and CVDisplayLinkSetCurrentCGDisplay(link, display) != 0) return error.SurfaceUnavailable;
        if (CVDisplayLinkSetOutputCallback(link, displayLinkTick, state) != 0) return error.PlatformFailure;
        self.display_link = link;
        return link;
    }
};

const DropTag = enum { entered, updated, performed };

fn dropPayloadRecognized(paths: []const []const u8, text: ?[]const u8) bool {
    for (paths) |path| if (path.len != 0) return true;
    const value = text orelse return false;
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
}

fn resolvedWindowMode(ns_window: objc.Id) api.WindowMode {
    return modeFromNativeFlags(
        objc.send(bool, ns_window, "isMiniaturized", .{}),
        objc.send(usize, ns_window, "styleMask", .{}) & types.WindowStyle.fullscreen != 0,
        objc.send(bool, ns_window, "isZoomed", .{}),
    );
}

fn modeFromNativeFlags(minimized: bool, fullscreen: bool, maximized: bool) api.WindowMode {
    if (minimized) return .minimized;
    if (fullscreen) return .fullscreen;
    if (maximized) return .maximized;
    return .normal;
}

fn emitWindowMode(self: *Context, id: handles.WindowId) void {
    const window = self.windows.getPtr(id.encode()) orelse return;
    const mode = resolvedWindowMode(window.ns_window);
    if (window.mode == mode) return;
    window.mode = mode;
    self.queue(id, .{ .mode_changed = mode });
}

fn dropPayloadAccepted(paths: []const []const u8, text: ?[]const u8, promised_count: usize, promises_available: bool) bool {
    // A mixed payload is one logical drag.  Do not accept its ordinary paths
    // while silently discarding promise receivers when the framework cannot
    // retain/initiate them.  Promise-only and mixed drops therefore require
    // the complete promise side to be available; path/text-only drops use the
    // ordinary payload recognizer.
    if (promised_count != 0) return promises_available;
    return dropPayloadRecognized(paths, text);
}

fn logicalCenter(size: geometry.Size) geometry.Point {
    return .{ .x = size.width / 2, .y = size.height / 2 };
}

fn windowDisplayNumber(window: *const NativeWindow) u32 {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const screen = objc.send(objc.Id, window.ns_window, "screen", .{});
    const description = objc.send(objc.Id, screen, "deviceDescription", .{});
    const number = objc.send(objc.Id, description, "objectForKey:", .{objc.nsString("NSScreenNumber")});
    return objc.send(u32, number, "unsignedIntValue", .{});
}

fn displayLinkNeedsTarget(current: u32, requested: u32) bool {
    return requested != 0 and current != requested;
}

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
        app_config.memory.media_source_count,
        app_config.memory.platform_object_count,
        app_config.memory.encoded_image_bytes,
        @max(1, app_config.memory.decoded_image_bytes / 4),
        app_config.memory.offscreen_request_count,
    );
    errdefer context.deinit();
    if (app_config.pointer_event_coalescing == .disabled) {
        const event_class = objc.class("NSEvent");
        const previous = objc.send(bool, event_class, "isMouseCoalescingEnabled", .{});
        context.previous_mouse_coalescing = previous;
        if (previous) objc.send(void, event_class, "setMouseCoalescingEnabled:", .{false});
    }
    const renderer = try metal.Renderer.create(
        allocator,
        .{ .context = context, .layer_fn = layerForWindow },
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
        _ = try macos_fonts.discover(allocator, instance);
        break :blk instance.interface();
    } else null;
    errdefer if (text_backend) |backend| backend.deinit();
    const accessibility_adapter: ?@import("../../a11y/api.zig").Adapter = if (comptime config.accessibility_enabled) try macos_a11y.Adapter.create(
        allocator,
        .{ .context = context, .emit_fn = emitAccessibility },
        .{ .context = context, .parent_fn = accessibilityParent, .screen_rect_fn = accessibilityScreenRect },
        app_config.memory.window_count,
        app_config.memory.accessibility_node_count,
        app_config.memory.accessibility_tree_bytes,
    ) else null;
    errdefer if (accessibility_adapter) |adapter| adapter.deinit();
    return .{
        .event_loop = .{
            .context = context,
            .run_fn = run,
            .step_fn = step,
            .wake_fn = wakeEventLoop,
            .schedule_wake_fn = scheduleWake,
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
            .capture_window_fn = captureWindow,
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
            .read_contents_fn = readClipboardContents,
            .write_paths_fn = writeClipboardPaths,
            .write_image_fn = writeClipboardImage,
            .maximum_bytes = app_config.memory.clipboard_bytes,
            .maximum_paths = app_config.memory.file_drop_path_count,
        },
        .promised_files = context.promised_file_service.interface(),
        .page_capture = context.page_capture_service.interface(),
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
            .open_directory_fn = openDirectory,
            .limits = .{
                .maximum_paths = app_config.memory.file_drop_path_count,
                .maximum_path_bytes = app_config.memory.platform_event_payload_bytes,
                .maximum_suggested_name_bytes = app_config.memory.platform_text_bytes,
            },
        },
        .application_services = .{
            .context = context,
            .open_url_fn = openExternalUrl,
            .open_path_fn = openExternalPath,
            .reveal_path_fn = revealExternalPath,
            .print_path_fn = printExternalPath,
            .maximum_text_bytes = app_config.memory.platform_text_bytes,
        },
        .native_media = if (comptime config.media_enabled) .{
            .context = context,
            .create_fn = createNativeMedia,
            .set_frame_fn = setNativeMediaFrame,
            .synchronize_fn = synchronizeNativeMedia,
            .play_fn = playNativeMedia,
            .pause_fn = pauseNativeMedia,
            .seek_fn = seekNativeMedia,
            .set_volume_fn = setNativeMediaVolume,
            .set_muted_fn = setNativeMediaMuted,
            .state_fn = nativeMediaState,
            .destroy_fn = destroyNativeMedia,
            .maximum_source_bytes = app_config.memory.platform_text_bytes,
            .maximum_placements = app_config.memory.media_source_count,
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

fn step(raw: *anyopaque, sink: api.EventSink, wait_for_event: bool) Error!bool {
    const self = cast(raw);
    if (self.failure) |failure| {
        return failure;
    }
    if (self.quit) return false;
    defer retryPendingApplicationOpen(self);
    if (self.pop()) |pending_value| {
        var pending = pending_value;
        defer pending.deinit(self.allocator);
        defer self.releasePending(&pending);
        sendToSink(self, sink, pending.window, &pending.event);
        return true;
    }
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const date = objc.send(objc.Id, objc.class("NSDate"), if (wait_for_event) "distantFuture" else "distantPast", .{});
    const event = objc.send(objc.Id, self.application, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
        types.any_event_mask,
        date,
        objc.nsString("kCFRunLoopDefaultMode"),
        true,
    });
    if (event != null) {
        self.active_sink = sink;
        defer self.active_sink = null;
        objc.send(void, self.application, "sendEvent:", .{event});
        objc.send(void, self.application, "updateWindows", .{});
    }
    if (self.pop()) |pending_value| {
        var pending = pending_value;
        defer pending.deinit(self.allocator);
        defer self.releasePending(&pending);
        sendToSink(self, sink, pending.window, &pending.event);
        return true;
    }
    return event != null;
}

fn sendToSink(self: *Context, sink: api.EventSink, window: handles.WindowId, event: *const api.WindowEvent) void {
    self.sink_dispatch_depth +|= 1;
    defer self.sink_dispatch_depth -|= 1;
    sink.send(window, event);
}

fn liveResizeSink(self: *Context) ?api.EventSink {
    if (self.sink_dispatch_depth != 0) return null;
    return self.active_sink;
}

fn postWakeEvent(self: *Context) void {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const event = objc.send(objc.Id, objc.class("NSEvent"), "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
        @as(usize, 15), types.Point{}, @as(u64, 0), @as(f64, 0), @as(isize, 0), @as(objc.Id, null), @as(i16, 0), @as(isize, 0), @as(isize, 0),
    });
    if (event != null) objc.send(void, self.application, "postEvent:atStart:", .{ event, false });
}

fn displayLinkTick(
    _: CVDisplayLinkRef,
    _: *const CVTimeStamp,
    _: *const CVTimeStamp,
    _: u64,
    _: *u64,
    raw: ?*anyopaque,
) callconv(.c) i32 {
    const state: *DisplayLinkState = @ptrCast(@alignCast(raw orelse return 0));
    if (!retainDisplayLinkCallback(state)) return 0;
    if (state.tick_pending.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        dispatch_async_f(&_dispatch_main_q, state, deliverDisplayLinkTick);
    } else {
        state.release();
    }
    return 0;
}

fn retainDisplayLinkCallback(state: *DisplayLinkState) bool {
    // The owning Context clears this address before stopping the link and
    // drains callbacks before releasing the base reference. Retain before
    // reading the address: a callback can already be entering while deinit
    // performs that clear, and loading first would let the base reference be
    // released before this callback has established its own lifetime.
    state.retain();
    if (state.context.load(.acquire) == 0) {
        state.release();
        return false;
    }
    return true;
}

fn deliverDisplayLinkTick(raw: ?*anyopaque) callconv(.c) void {
    const state: *DisplayLinkState = @ptrCast(@alignCast(raw orelse return));
    defer state.release();
    _ = state.tick_pending.swap(0, .acq_rel);
    const address = state.context.load(.acquire);
    if (address == 0) return;
    const self: *Context = @ptrFromInt(address);
    self.displayTick(self.now());
}

fn drainDisplayLinkCallbacks(state: *DisplayLinkState) void {
    const run_loop = objc.send(objc.Id, objc.class("NSRunLoop"), "currentRunLoop", .{});
    while (state.references.load(.acquire) > 1) {
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const deadline = objc.send(objc.Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, 0.01)});
        _ = objc.send(bool, run_loop, "runMode:beforeDate:", .{ objc.nsString("kCFRunLoopDefaultMode"), deadline });
    }
}

fn wake(raw: ?*anyopaque) void {
    postWakeEvent(cast(raw orelse return));
}

fn wakeEventLoop(raw: *anyopaque) void {
    wake(raw);
}

fn scheduleWake(raw: *anyopaque, deadline_ns: clock.Timestamp) Error!void {
    const self = cast(raw);
    const state = self.delayed_wake_state orelse return error.AppClosed;
    const now_ns = self.now();
    const delay_ns = deadline_ns -| now_ns;
    const bounded_delay: i64 = @intCast(@min(delay_ns, @as(u64, std.math.maxInt(i64))));
    state.retain();
    dispatch_after_f(dispatch_time(0, bounded_delay), &_dispatch_main_q, state, deliverDelayedWake);
}

fn deliverDelayedWake(raw: ?*anyopaque) callconv(.c) void {
    const state: *DelayedWakeState = @ptrCast(@alignCast(raw orelse return));
    defer state.release();
    const address = state.context.load(.acquire);
    if (address == 0) return;
    postWakeEvent(@ptrFromInt(address));
}

fn requestQuit(raw: *anyopaque) void {
    const self = cast(raw);
    self.quit = true;
    postWakeEvent(self);
}

fn nowOpaque(raw: *anyopaque) clock.Timestamp {
    return cast(raw).now();
}

fn createWindow(raw: *anyopaque, id: handles.WindowId, options: api.WindowOptions) Error!api.NativeHandle {
    const self = cast(raw);
    if (self.windows.contains(id.encode())) return error.ResourceBusy;
    if (self.windows.count() >= self.maximum_windows) return error.BudgetExceeded;
    try self.windows.ensureUnusedCapacity(1);
    // Appearance is delivered before creation/configuration so App's first
    // composition observes a resolved system value rather than a placeholder.
    try self.preparePendingSlots(3 + @as(usize, @intFromBool(options.visible)));
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const frame: types.Rect = .{ .size = .{ .width = options.size.width, .height = options.size.height } };
    var style_mask: usize = 0;
    if (options.decorated) style_mask = types.WindowStyle.titled | types.WindowStyle.closable | types.WindowStyle.miniaturizable;
    if (options.resizable) style_mask |= types.WindowStyle.resizable;
    const ns_window = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
        frame, style_mask, types.backing_store_buffered, false,
    }) orelse return error.PlatformFailure;
    var ns_window_owned = true;
    errdefer if (ns_window_owned) objc.release(ns_window);
    const view = objc.send(objc.Id, objc.send(objc.Id, self.view_class, "alloc", .{}), "initWithFrame:", .{frame}) orelse return error.PlatformFailure;
    var view_owned = true;
    errdefer if (view_owned) objc.release(view);
    if (!objc.setIvar(u64, view, "_ziguiWindow", id.encode())) return error.PlatformFailure;
    const layer = objc.send(objc.Id, objc.class("CAMetalLayer"), "layer", .{}) orelse return error.SurfaceUnavailable;
    objc.send(void, layer, "setPixelFormat:", .{@as(usize, 81)});
    objc.send(void, layer, "setFramebufferOnly:", .{true});
    objc.send(void, layer, "setPresentsWithTransaction:", .{false});
    configureMetalView(view, layer);
    const tracking = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSTrackingArea"), "alloc", .{}), "initWithRect:options:owner:userInfo:", .{
        types.Rect{}, @as(usize, 1 | 2 | 128 | 512 | 1024), view, @as(objc.Id, null),
    });
    if (tracking != null) {
        objc.send(void, view, "addTrackingArea:", .{tracking});
        objc.release(tracking);
    }
    const dragged_type_values = [_]objc.Id{
        objc.nsString("public.file-url"),
        objc.nsString("public.url"),
        objc.nsString("public.utf8-plain-text"),
        objc.nsString("public.plain-text"),
    };
    const dragged_types = objc.send(objc.Id, objc.class("NSMutableArray"), "arrayWithCapacity:", .{
        dragged_type_values.len,
    }) orelse return error.PlatformFailure;
    for (dragged_type_values) |value| objc.send(void, dragged_types, "addObject:", .{value});
    // AppKit's promise receiver publishes the complete set of readable UTIs
    // for the current OS. Register those exact types so promised-only drags
    // enter the normal dragging callbacks; extraction still gates acceptance
    // on a retained batch and a valid receive operation.
    if (objc.class("NSFilePromiseReceiver")) |receiver_class| {
        if (objc.send(objc.Id, receiver_class, "readableDraggedTypes", .{})) |promise_types| {
            objc.send(void, dragged_types, "addObjectsFromArray:", .{promise_types});
        }
    }
    objc.send(void, view, "registerForDraggedTypes:", .{dragged_types});
    objc.send(void, ns_window, "setContentView:", .{view});
    objc.send(void, ns_window, "setDelegate:", .{view});
    objc.send(void, ns_window, "setAcceptsMouseMovedEvents:", .{true});
    objc.send(void, ns_window, "setReleasedWhenClosed:", .{false});
    objc.send(void, ns_window, "setTitle:", .{objc.nsString(options.title)});
    if (options.transparent) {
        objc.send(void, ns_window, "setOpaque:", .{false});
        objc.send(void, ns_window, "setBackgroundColor:", .{objc.send(objc.Id, objc.class("NSColor"), "clearColor", .{})});
    }
    if (options.always_on_top) objc.send(void, ns_window, "setLevel:", .{@as(isize, 3)});
    if (options.minimum_size.width > 0 or options.minimum_size.height > 0) objc.send(void, ns_window, "setContentMinSize:", .{types.Size{
        .width = options.minimum_size.width,
        .height = options.minimum_size.height,
    }});
    if (std.math.isFinite(options.maximum_size.width) or std.math.isFinite(options.maximum_size.height)) objc.send(void, ns_window, "setContentMaxSize:", .{types.Size{
        .width = if (std.math.isFinite(options.maximum_size.width)) options.maximum_size.width else std.math.floatMax(f64),
        .height = if (std.math.isFinite(options.maximum_size.height)) options.maximum_size.height else std.math.floatMax(f64),
    }});
    if (options.position) |position| {
        objc.send(void, ns_window, "setFrameTopLeftPoint:", .{types.Point{ .x = position.x, .y = position.y }});
    } else {
        objc.send(void, ns_window, "center", .{});
    }

    const scale_value = objc.send(f64, ns_window, "backingScaleFactor", .{});
    const scale = try geometry.ScaleFactor.init(@floatCast(scale_value));
    objc.send(void, layer, "setContentsScale:", .{@as(f64, scale.value)});
    if (!objc.setIvar(?*Context, view, "_ziguiContext", self)) return error.PlatformFailure;
    self.windows.putAssumeCapacity(id.encode(), .{
        .ns_window = ns_window,
        .view = view,
        .layer = layer,
        .logical_size = options.size,
        .scale_factor = scale,
        .visible = options.visible,
    });
    ns_window_owned = false;
    objc.release(view);
    view_owned = false;
    var published = true;
    errdefer if (published) {
        self.purgeWindowEvents(id);
        var removed = self.windows.fetchRemove(id.encode()).?;
        removed.value.deinit(self);
    };
    const handle: api.NativeHandle = .{ .kind = .appkit, .value = @intFromPtr(ns_window) };
    try self.appendPending(.{ .window = id, .event = .{ .appearance_changed = appearance(view) } });
    try self.appendPending(.{ .window = id, .event = .{ .created = handle } });
    try self.appendPending(.{ .window = id, .event = .{ .configured = .{ .logical_size = options.size, .scale_factor = scale } } });
    if (options.visible) {
        objc.send(void, ns_window, "makeKeyAndOrderFront:", .{@as(objc.Id, null)});
        try requestFrame(raw, id);
    }
    wake(self);
    published = false;
    return handle;
}

fn configureMetalView(view: objc.Id, layer: objc.Id) void {
    objc.send(void, view, "setWantsLayer:", .{true});
    objc.send(void, view, "setLayer:", .{layer});
    // AppKit defaults developer-provided layer-hosting views to `never`, with
    // scale-axes-independently placement. That stretches the last drawable
    // while the window is resized. Request the native live-resize redraw path
    // so each new logical size receives a correctly arranged Metal frame.
    objc.send(void, view, "setLayerContentsRedrawPolicy:", .{layer_contents_redraw_during_view_resize});
    // A display-backed GPU layer can still miss an intermediate present while
    // AppKit is changing the view bounds. Keep the last completed drawable at
    // its native point geometry instead of mapping it through resize gravity;
    // the next Metal frame simply reveals the newly exposed extent.
    objc.send(void, view, "setLayerContentsPlacement:", .{layer_contents_placement_top_left});
    objc.send(void, layer, "setNeedsDisplayOnBoundsChange:", .{true});
    objc.send(void, layer, "setAutoresizingMask:", .{layer_autoresizing_width_and_height});
}

fn destroyWindow(raw: *anyopaque, id: handles.WindowId) void {
    const self = cast(raw);
    destroyNativeMediaForWindow(self, id);
    var removed = self.windows.fetchRemove(id.encode()) orelse return;
    removed.value.deinit(self);
    self.queue(id, .closed);
}

fn createNativeMedia(raw: *anyopaque, window_id: handles.WindowId, options: api.NativeMediaOptions) Error!handles.NativeMediaId {
    const self = cast(raw);
    const window = self.windows.getPtr(window_id.encode()) orelse return error.InvalidHandle;
    if (self.native_media_players.live_count >= self.maximum_native_media_players) return error.BudgetExceeded;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const url = switch (options.source) {
        .file => |path| try fileUrl(path),
        .url => |value| objc.send(objc.Id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(value)}) orelse return error.InvalidConfiguration,
    };
    const player = objc.send(objc.Id, objc.class("AVPlayer"), "playerWithURL:", .{url}) orelse return error.PlatformFailure;
    _ = objc.retain(player);
    errdefer objc.release(player);
    const layer = objc.send(objc.Id, objc.class("AVPlayerLayer"), "playerLayerWithPlayer:", .{player}) orelse return error.PlatformFailure;
    _ = objc.retain(layer);
    errdefer objc.release(layer);
    objc.send(void, layer, "setFrame:", .{nativeMediaRect(window, options.frame)});
    objc.send(void, layer, "setVideoGravity:", .{objc.nsString("AVLayerVideoGravityResizeAspect")});
    objc.send(void, player, "setVolume:", .{options.volume});
    objc.send(void, player, "setMuted:", .{options.muted});
    const entry: NativeMediaPlayer = .{ .window = window_id, .player = player, .layer = layer };
    const id = try self.native_media_players.insert(entry);
    objc.send(void, window.layer, "addSublayer:", .{layer});
    if (options.autoplay) objc.send(void, player, "play", .{});
    return id;
}

fn setNativeMediaFrame(raw: *anyopaque, id: handles.NativeMediaId, frame: geometry.Rect) Error!void {
    const self = cast(raw);
    const entry = self.native_media_players.get(id) orelse return error.InvalidHandle;
    const window = self.windows.getPtr(entry.window.encode()) orelse return error.WindowClosed;
    entry.scene_managed = false;
    objc.send(void, entry.layer, "setFrame:", .{nativeMediaRect(window, frame)});
    objc.send(void, entry.layer, "setZPosition:", .{@as(f64, 0)});
    objc.send(void, entry.layer, "setHidden:", .{false});
}

fn synchronizeNativeMedia(raw: *anyopaque, window_id: handles.WindowId, placements: []const native_media_placement.Placement) Error!void {
    const self = cast(raw);
    const window = self.windows.getPtr(window_id.encode()) orelse return error.WindowClosed;
    for (placements) |placement| {
        const entry = self.native_media_players.get(placement.id) orelse return error.InvalidHandle;
        if (!entry.window.eql(window_id)) return error.InvalidHandle;
    }
    var iterator = self.native_media_players.iterator();
    while (iterator.next()) |entry| if (entry.value.window.eql(window_id) and entry.value.scene_managed)
        objc.send(void, entry.value.layer, "setHidden:", .{true});
    for (placements, 0..) |placement, index| {
        const entry = self.native_media_players.get(placement.id).?;
        entry.scene_managed = true;
        objc.send(void, entry.layer, "setFrame:", .{nativeMediaRect(window, placement.bounds)});
        objc.send(void, entry.layer, "setZPosition:", .{@as(f64, @floatFromInt(index + 1))});
        objc.send(void, entry.layer, "setHidden:", .{!placement.visible});
    }
}

fn playNativeMedia(raw: *anyopaque, id: handles.NativeMediaId) Error!void {
    const entry = cast(raw).native_media_players.get(id) orelse return error.InvalidHandle;
    objc.send(void, entry.player, "play", .{});
}

fn pauseNativeMedia(raw: *anyopaque, id: handles.NativeMediaId) Error!void {
    const entry = cast(raw).native_media_players.get(id) orelse return error.InvalidHandle;
    objc.send(void, entry.player, "pause", .{});
}

fn seekNativeMedia(raw: *anyopaque, id: handles.NativeMediaId, position_ns: u64) Error!void {
    const entry = cast(raw).native_media_players.get(id) orelse return error.InvalidHandle;
    const value: i64 = @intCast(@min(position_ns, @as(u64, std.math.maxInt(i64))));
    objc.send(void, entry.player, "seekToTime:", .{CMTime{ .value = value, .timescale = std.time.ns_per_s, .flags = 1 }});
}

fn setNativeMediaVolume(raw: *anyopaque, id: handles.NativeMediaId, volume: f32) Error!void {
    const entry = cast(raw).native_media_players.get(id) orelse return error.InvalidHandle;
    objc.send(void, entry.player, "setVolume:", .{volume});
}

fn setNativeMediaMuted(raw: *anyopaque, id: handles.NativeMediaId, muted: bool) Error!void {
    const entry = cast(raw).native_media_players.get(id) orelse return error.InvalidHandle;
    objc.send(void, entry.player, "setMuted:", .{muted});
}

fn nativeMediaState(raw: *anyopaque, id: handles.NativeMediaId) Error!api.NativeMediaState {
    const entry = cast(raw).native_media_players.get(id) orelse return error.InvalidHandle;
    const current = objc.send(CMTime, entry.player, "currentTime", .{});
    const item = objc.send(objc.Id, entry.player, "currentItem", .{});
    const duration = if (item != null) objc.send(CMTime, item, "duration", .{}) else CMTime{};
    const status = nativeMediaStatus(item);
    entry.has_presented_frame = entry.has_presented_frame or nativeMediaLayerHasPresentedFrame(entry.layer);
    return .{
        .status = status,
        .error_description = if (status == .failed) nativeMediaErrorDescription(item) else null,
        .has_presented_frame = entry.has_presented_frame,
        .playing = objc.send(f32, entry.player, "rate", .{}) != 0,
        .position_ns = timeNanoseconds(current) orelse 0,
        .duration_ns = timeNanoseconds(duration),
        .volume = objc.send(f32, entry.player, "volume", .{}),
        .muted = objc.send(bool, entry.player, "isMuted", .{}),
    };
}

/// AVPlayerLayer's readiness is the platform's native presentation boundary:
/// it becomes true only after the layer has a decoded frame to display. Keep
/// this observation in the platform adapter so consumers do not need to
/// inspect AVFoundation objects or poll pixel buffers on the CPU.
fn nativeMediaLayerHasPresentedFrame(layer: objc.Id) bool {
    if (layer == null) return false;
    return objc.send(bool, layer, "isReadyForDisplay", .{});
}

fn nativeMediaStatus(item: objc.Id) api.NativeMediaStatus {
    if (item == null) return .loading;
    return nativeMediaStatusFromRaw(objc.send(isize, item, "status", .{}));
}

fn nativeMediaErrorDescription(item: objc.Id) ?api.NativeMediaErrorDescription {
    const media_item = item orelse return null;
    const failure = objc.send(objc.Id, media_item, "error", .{}) orelse return null;
    if (!objc.send(bool, failure, "respondsToSelector:", .{objc.selector("localizedDescription")})) return null;
    const localized = objc.send(objc.Id, failure, "localizedDescription", .{});
    const bytes = objc.utf8(localized);
    if (bytes.len == 0) return null;
    return api.NativeMediaErrorDescription.init(bytes) catch null;
}

fn nativeMediaStatusFromRaw(status: isize) api.NativeMediaStatus {
    return switch (status) {
        1 => .ready,
        2 => .failed,
        else => .loading,
    };
}

fn destroyNativeMedia(raw: *anyopaque, id: handles.NativeMediaId) Error!void {
    var removed = cast(raw).native_media_players.remove(id) orelse return error.InvalidHandle;
    removed.deinit();
}

fn destroyNativeMediaForWindow(self: *Context, window: handles.WindowId) void {
    while (true) {
        var matching_id: ?handles.NativeMediaId = null;
        var iterator = self.native_media_players.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.window.eql(window)) {
                matching_id = entry.id;
                break;
            }
        }
        const id = matching_id orelse break;
        if (self.native_media_players.remove(id)) |removed_value| {
            var removed = removed_value;
            removed.deinit();
        }
    }
}

fn nativeMediaRect(window: *const NativeWindow, frame: geometry.Rect) types.Rect {
    const flipped = objc.send(bool, window.layer, "isGeometryFlipped", .{});
    return .{
        .origin = .{
            .x = frame.origin.x,
            .y = if (flipped) frame.origin.y else window.logical_size.height - frame.origin.y - frame.size.height,
        },
        .size = .{ .width = frame.size.width, .height = frame.size.height },
    };
}

fn timeNanoseconds(value: CMTime) ?u64 {
    if (value.flags & 1 == 0 or value.timescale <= 0 or value.value < 0) return null;
    const result = (@as(u128, @intCast(value.value)) * std.time.ns_per_s) / @as(u32, @intCast(value.timescale));
    return @intCast(@min(result, std.math.maxInt(u64)));
}

fn showWindow(raw: *anyopaque, id: handles.WindowId, visible: bool) Error!void {
    const self = cast(raw);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    if (window.visible == visible) return;
    if (visible) {
        window.visible = true;
        window.closing = false;
        errdefer window.visible = false;
        objc.send(void, window.ns_window, "makeKeyAndOrderFront:", .{@as(objc.Id, null)});
        try requestFrame(raw, id);
    } else {
        objc.send(void, window.ns_window, "orderOut:", .{@as(objc.Id, null)});
        window.visible = false;
        window.frame_queued = false;
    }
}

fn titleWindow(raw: *anyopaque, id: handles.WindowId, title: []const u8) Error!void {
    const window = cast(raw).windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    objc.send(void, window.ns_window, "setTitle:", .{objc.nsString(title)});
}

fn requestFrame(raw: *anyopaque, id: handles.WindowId) Error!void {
    const self = cast(raw);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    if (!window.visible) return;
    if (window.frame_queued) return;
    window.frame_queued = true;
    errdefer window.frame_queued = false;
    objc.send(void, window.view, "setNeedsDisplay:", .{true});
    const link = try self.ensureDisplayLink(window);
    if (!CVDisplayLinkIsRunning(link) and CVDisplayLinkStart(link) != 0) return error.PlatformFailure;
}

fn setCursor(raw: *anyopaque, id: handles.WindowId, cursor: api.Cursor) Error!void {
    const window = cast(raw).windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    if (window.cursor == cursor) return;
    if (cursor == .hidden) {
        if (!window.cursor_hidden) {
            objc.send(void, objc.class("NSCursor"), "hide", .{});
            window.cursor_hidden = true;
        }
        window.cursor = cursor;
        return;
    }
    const selector_name: [*:0]const u8 = switch (cursor) {
        .default => "arrowCursor",
        .pointer => "pointingHandCursor",
        .text => "IBeamCursor",
        .crosshair => "crosshairCursor",
        .grab => "openHandCursor",
        .grabbing => "closedHandCursor",
        .resize_horizontal, .resize_diagonal_nw_se => "resizeLeftRightCursor",
        .resize_vertical, .resize_diagonal_ne_sw => "resizeUpDownCursor",
        .not_allowed => "operationNotAllowedCursor",
        .hidden => unreachable,
    };
    const native = objc.send(objc.Id, objc.class("NSCursor"), selector_name, .{});
    if (native == null) return error.PlatformFailure;
    if (window.cursor_hidden) {
        objc.send(void, objc.class("NSCursor"), "unhide", .{});
        window.cursor_hidden = false;
    }
    objc.send(void, native, "set", .{});
    window.cursor = cursor;
}

fn commandWindow(raw: *anyopaque, id: handles.WindowId, command: api.WindowCommand) Error!void {
    const window = cast(raw).windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    switch (command) {
        .move => |position| objc.send(void, window.ns_window, "setFrameTopLeftPoint:", .{types.Point{
            .x = position.x,
            .y = position.y,
        }}),
        .resize => |size| objc.send(void, window.ns_window, "setContentSize:", .{types.Size{
            .width = size.width,
            .height = size.height,
        }}),
        .mode => |mode| switch (mode) {
            .normal => {
                if (objc.send(bool, window.ns_window, "isMiniaturized", .{}))
                    objc.send(void, window.ns_window, "deminiaturize:", .{@as(objc.Id, null)});
                if (objc.send(bool, window.ns_window, "isZoomed", .{}))
                    objc.send(void, window.ns_window, "performZoom:", .{@as(objc.Id, null)});
                if (objc.send(usize, window.ns_window, "styleMask", .{}) & types.WindowStyle.fullscreen != 0)
                    objc.send(void, window.ns_window, "toggleFullScreen:", .{@as(objc.Id, null)});
            },
            .minimized => objc.send(void, window.ns_window, "miniaturize:", .{@as(objc.Id, null)}),
            .maximized => if (!objc.send(bool, window.ns_window, "isZoomed", .{}))
                objc.send(void, window.ns_window, "performZoom:", .{@as(objc.Id, null)}),
            .fullscreen => if (objc.send(usize, window.ns_window, "styleMask", .{}) & types.WindowStyle.fullscreen == 0)
                objc.send(void, window.ns_window, "toggleFullScreen:", .{@as(objc.Id, null)}),
        },
        .always_on_top => |enabled| objc.send(void, window.ns_window, "setLevel:", .{@as(isize, if (enabled) 3 else 0)}),
    }
}

fn listDisplays(_: *anyopaque, allocator: std.mem.Allocator) Error!api.OwnedDisplays {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const screens = objc.send(objc.Id, objc.class("NSScreen"), "screens", .{}) orelse return error.PlatformFailure;
    const count = objc.send(usize, screens, "count", .{});
    const values = try allocator.alloc(api.Display, count);
    errdefer allocator.free(values);
    var initialized: usize = 0;
    errdefer for (values[0..initialized]) |display| allocator.free(@constCast(display.name));

    const main = objc.send(objc.Id, objc.class("NSScreen"), "mainScreen", .{});
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const screen = objc.send(objc.Id, screens, "objectAtIndex:", .{index}) orelse return error.PlatformFailure;
        const frame = objc.send(types.Rect, screen, "frame", .{});
        const visible = objc.send(types.Rect, screen, "visibleFrame", .{});
        const description = objc.send(objc.Id, screen, "deviceDescription", .{});
        const number = objc.send(objc.Id, description, "objectForKey:", .{objc.nsString("NSScreenNumber")});
        const id = if (number) |value| objc.send(u64, value, "unsignedLongLongValue", .{}) else @as(u64, index + 1);
        const localized = if (objc.send(bool, screen, "respondsToSelector:", .{objc.selector("localizedName")}))
            objc.utf8(objc.send(objc.Id, screen, "localizedName", .{}))
        else
            "Display";
        const scale_value = objc.send(f64, screen, "backingScaleFactor", .{});
        const scale = geometry.ScaleFactor.init(@floatCast(scale_value)) catch return error.PlatformFailure;
        const name = if (localized.len != 0)
            try allocator.dupe(u8, localized)
        else
            try std.fmt.allocPrint(allocator, "Display {d}", .{index + 1});
        const refresh: u32 = if (objc.send(bool, screen, "respondsToSelector:", .{objc.selector("maximumFramesPerSecond")}))
            @intCast(@max(0, objc.send(isize, screen, "maximumFramesPerSecond", .{})) * 1000)
        else
            0;
        values[index] = .{
            .id = id,
            .name = name,
            .bounds = nativeRect(frame),
            .work_area = nativeRect(visible),
            .scale_factor = scale,
            .refresh_millihertz = refresh,
            .primary = screen == main,
        };
        initialized += 1;
    }
    return .{ .allocator = allocator, .values = values };
}

fn nativeRect(value: types.Rect) geometry.Rect {
    return geometry.Rect.fromXYWH(
        @floatCast(value.origin.x),
        @floatCast(value.origin.y),
        @floatCast(value.size.width),
        @floatCast(value.size.height),
    );
}

fn nativeHandle(raw: *anyopaque, id: handles.WindowId) ?api.NativeHandle {
    const window = cast(raw).windows.getPtr(id.encode()) orelse return null;
    return .{ .kind = .appkit, .value = @intFromPtr(window.ns_window.?) };
}

/// Captures the final native window surface before any preview overlay is
/// composed. AppKit/CoreGraphics objects remain private to this adapter;
/// callers receive an owned, sRGB PNG through WindowSystem.
fn captureWindow(
    raw: *anyopaque,
    id: handles.WindowId,
    target: geometry.Size,
    allocator: std.mem.Allocator,
) Error!api.OwnedWindowSnapshot {
    const self = cast(raw);
    if (pthread_main_np() == 0) return error.ThreadAffinity;
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    if (!std.math.isFinite(target.width) or !std.math.isFinite(target.height) or target.width <= 0 or target.height <= 0)
        return error.InvalidConfiguration;

    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const window_number = objc.send(isize, window.ns_window, "windowNumber", .{});
    if (window_number <= 0 or @as(u64, @intCast(window_number)) > std.math.maxInt(u32)) return error.InvalidHandle;
    const capture = CGWindowListCreateImage(
        CGRectNull,
        cg_window_list_option_including_window,
        @intCast(window_number),
        cg_window_image_bounds_ignore_framing | cg_window_image_nominal_resolution,
    ) orelse return error.PlatformFailure;
    defer CGImageRelease(capture);

    const source_width = CGImageGetWidth(capture);
    const source_height = CGImageGetHeight(capture);
    if (source_width == 0 or source_height == 0) return error.InvalidImage;
    const source_pixels = std.math.mul(usize, source_width, source_height) catch return error.BudgetExceeded;
    if (source_pixels > 64 * 1024 * 1024) return error.BudgetExceeded;
    const source_aspect = @as(f64, @floatFromInt(source_width)) / @as(f64, @floatFromInt(source_height));
    const target_aspect = target.width / target.height;
    const crop: types.Rect = if (source_aspect < target_aspect) blk: {
        const height = std.math.clamp(
            @round(@as(f64, @floatFromInt(source_width)) / target_aspect),
            1.0,
            @as(f64, @floatFromInt(source_height)),
        );
        break :blk .{ .origin = .{}, .size = .{ .width = @floatFromInt(source_width), .height = height } };
    } else blk: {
        const width = std.math.clamp(
            @round(@as(f64, @floatFromInt(source_height)) * target_aspect),
            1.0,
            @as(f64, @floatFromInt(source_width)),
        );
        break :blk .{ .origin = .{ .x = (@as(f64, @floatFromInt(source_width)) - width) * 0.5 }, .size = .{ .width = width, .height = @floatFromInt(source_height) } };
    };
    const blur_radius = 18.0 * (crop.size.width / target.width);

    const ci_source = objc.send(objc.Id, objc.class("CIImage"), "imageWithCGImage:", .{capture}) orelse return error.PlatformFailure;
    const ci_cropped = objc.send(objc.Id, ci_source, "imageByCroppingToRect:", .{crop}) orelse return error.PlatformFailure;
    const input_image = objc.nsString("inputImage");
    const input_radius = objc.nsString("inputRadius");
    const input_saturation = objc.nsString("inputSaturation");
    const output_image = objc.nsString("outputImage");
    const blur = objc.send(objc.Id, objc.class("CIFilter"), "filterWithName:", .{objc.nsString("CIGaussianBlur")}) orelse return error.PlatformFailure;
    objc.send(void, blur, "setValue:forKey:", .{ ci_cropped, input_image });
    objc.send(void, blur, "setValue:forKey:", .{ objc.send(objc.Id, objc.class("NSNumber"), "numberWithDouble:", .{blur_radius}), input_radius });
    const blurred = objc.send(objc.Id, blur, "valueForKey:", .{output_image}) orelse return error.PlatformFailure;
    const color = objc.send(objc.Id, objc.class("CIFilter"), "filterWithName:", .{objc.nsString("CIColorControls")}) orelse return error.PlatformFailure;
    objc.send(void, color, "setValue:forKey:", .{ blurred, input_image });
    objc.send(void, color, "setValue:forKey:", .{ objc.send(objc.Id, objc.class("NSNumber"), "numberWithDouble:", .{@as(f64, 1.08)}), input_saturation });
    const saturated = objc.send(objc.Id, color, "valueForKey:", .{output_image}) orelse return error.PlatformFailure;
    const ci_context = objc.send(objc.Id, objc.class("CIContext"), "contextWithOptions:", .{@as(objc.Id, null)}) orelse return error.PlatformFailure;
    const output = objc.send(objc.Id, ci_context, "createCGImage:fromRect:", .{ saturated, crop }) orelse return error.PlatformFailure;
    defer CGImageRelease(output);

    var representation = objc.send(objc.Id, objc.class("NSBitmapImageRep"), "alloc", .{}) orelse return error.PlatformFailure;
    representation = objc.send(objc.Id, representation, "initWithCGImage:", .{output}) orelse return error.PlatformFailure;
    defer objc.release(representation);
    const data = objc.send(objc.Id, representation, "representationUsingType:properties:", .{
        @as(usize, 4), objc.send(objc.Id, objc.class("NSDictionary"), "dictionary", .{}),
    }) orelse return error.PlatformFailure;
    const length = objc.send(usize, data, "length", .{});
    if (length == 0 or length > 256 * 1024 * 1024) return error.BudgetExceeded;
    const bytes = objc.send(?[*]const u8, data, "bytes", .{}) orelse return error.PlatformFailure;
    const owned = try allocator.dupe(u8, bytes[0..length]);
    errdefer allocator.free(owned);
    const output_width = CGImageGetWidth(output);
    const output_height = CGImageGetHeight(output);
    if (output_width == 0 or output_height == 0 or output_width > std.math.maxInt(u32) or output_height > std.math.maxInt(u32))
        return error.InvalidImage;
    return .{
        .allocator = allocator,
        .bytes = owned,
        .format = .png_srgb8,
        .width = @intCast(output_width),
        .height = @intCast(output_height),
        .scale_factor = window.scale_factor,
    };
}

fn layerForWindow(raw: *anyopaque, id: handles.WindowId) objc.Id {
    const window = cast(raw).windows.getPtr(id.encode()) orelse return null;
    return window.layer;
}

fn emitAccessibility(raw: *anyopaque, request: @import("../../a11y/api.zig").ActionRequest) void {
    cast(raw).queueAccessibility(request);
}

fn accessibilityParent(raw: *anyopaque, id: handles.WindowId) objc.Id {
    const window = cast(raw).windows.getPtr(id.encode()) orelse return null;
    return window.view;
}

fn accessibilityScreenRect(raw: *anyopaque, id: handles.WindowId, source: geometry.Rect) types.Rect {
    const window = cast(raw).windows.getPtr(id.encode()) orelse return .{};
    var rect: types.Rect = .{
        .origin = .{ .x = source.origin.x, .y = source.origin.y },
        .size = .{ .width = source.size.width, .height = source.size.height },
    };
    rect = objc.send(types.Rect, window.view, "convertRect:toView:", .{ rect, @as(objc.Id, null) });
    return objc.send(types.Rect, window.ns_window, "convertRectToScreen:", .{rect});
}

fn setTextInputActive(raw: *anyopaque, id: handles.WindowId, active: bool) Error!void {
    const self = cast(raw);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    if (active) {
        if (!objc.send(bool, window.ns_window, "makeFirstResponder:", .{window.view}))
            return error.PlatformFailure;
        const context = objc.send(objc.Id, window.view, "inputContext", .{});
        if (context != null) objc.send(void, context, "activate", .{});
    } else {
        const context = objc.send(objc.Id, window.view, "inputContext", .{});
        if (context != null) objc.send(void, context, "discardMarkedText", .{});
    }
    window.text_input_active = active;
    if (!active) {
        self.retained_text.release(self.allocator, &window.surrounding_text);
        window.selection = .{ .start = 0, .end = 0 };
    }
}

fn setCandidateRect(raw: *anyopaque, id: handles.WindowId, rect: geometry.Rect) Error!void {
    const window = cast(raw).windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    window.candidate_rect = rect;
    const context = objc.send(objc.Id, window.view, "inputContext", .{});
    if (context != null) objc.send(void, context, "invalidateCharacterCoordinates", .{});
}

fn setSurroundingText(raw: *anyopaque, id: handles.WindowId, text: []const u8, selection: input.TextRange) Error!void {
    const self = cast(raw);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    if (selection.start > text.len or selection.end > text.len) return error.InvalidConfiguration;
    try self.retained_text.replace(self.allocator, &window.surrounding_text, text);
    window.selection = selection;
}

fn readClipboard(raw: *anyopaque, allocator: std.mem.Allocator) Error!?[]u8 {
    const self = cast(raw);
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const pasteboard = objc.send(objc.Id, objc.class("NSPasteboard"), "generalPasteboard", .{}) orelse return error.PlatformFailure;
    const string = objc.send(objc.Id, pasteboard, "stringForType:", .{objc.nsString("public.utf8-plain-text")});
    if (string == null) return null;
    const value = objc.utf8(string);
    if (value.len > self.maximum_clipboard_bytes) return error.BudgetExceeded;
    return try allocator.dupe(u8, value);
}

fn writeClipboard(_: *anyopaque, text: []const u8) Error!void {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const pasteboard = objc.send(objc.Id, objc.class("NSPasteboard"), "generalPasteboard", .{}) orelse return error.PlatformFailure;
    _ = objc.send(isize, pasteboard, "clearContents", .{});
    if (!objc.send(bool, pasteboard, "setString:forType:", .{ objc.nsString(text), objc.nsString("public.utf8-plain-text") })) return error.PlatformFailure;
}

fn writeClipboardPaths(_: *anyopaque, paths: []const []const u8) Error!void {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const urls = objc.send(objc.Id, objc.class("NSMutableArray"), "arrayWithCapacity:", .{paths.len}) orelse return error.PlatformFailure;
    for (paths) |path| objc.send(void, urls, "addObject:", .{try fileUrl(path)});
    const pasteboard = objc.send(objc.Id, objc.class("NSPasteboard"), "generalPasteboard", .{}) orelse return error.PlatformFailure;
    _ = objc.send(isize, pasteboard, "clearContents", .{});
    if (!objc.send(bool, pasteboard, "writeObjects:", .{urls})) return error.PlatformFailure;
}

fn writeClipboardImage(_: *anyopaque, image: api.ClipboardImage) Error!void {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const data = objc.send(objc.Id, objc.class("NSData"), "dataWithBytes:length:", .{ image.bytes.ptr, image.bytes.len }) orelse return error.PlatformFailure;
    const pasteboard = objc.send(objc.Id, objc.class("NSPasteboard"), "generalPasteboard", .{}) orelse return error.PlatformFailure;
    _ = objc.send(isize, pasteboard, "clearContents", .{});
    if (!objc.send(bool, pasteboard, "setData:forType:", .{ data, objc.nsString("public.png") })) return error.PlatformFailure;
}

fn readClipboardContents(raw: *anyopaque, allocator: std.mem.Allocator) Error!api.ClipboardContents {
    const self = cast(raw);
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const pasteboard = objc.send(objc.Id, objc.class("NSPasteboard"), "generalPasteboard", .{}) orelse return error.PlatformFailure;
    var result: api.ClipboardContents = .{ .allocator = allocator };
    errdefer result.deinit();
    errdefer if (result.promised_batch) |batch| self.promised_file_service.interface().releaseBatch(batch) catch {};

    if (objc.send(objc.Id, pasteboard, "stringForType:", .{objc.nsString("public.utf8-plain-text")})) |string| {
        const value = objc.utf8(string);
        if (value.len > self.maximum_clipboard_bytes) return error.BudgetExceeded;
        result.text = try allocator.dupe(u8, value);
    }

    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(@constCast(path));
        paths.deinit(allocator);
    }
    const file_url_options = objc.send(objc.Id, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{
        objc.send(objc.Id, objc.class("NSNumber"), "numberWithBool:", .{true}), NSPasteboardURLReadingFileURLsOnlyKey,
    });
    const file_urls = objc.send(objc.Id, pasteboard, "readObjectsForClasses:options:", .{
        objc.arrayWithObject(objc.class("NSURL")), file_url_options,
    });
    if (file_urls != null and objc.send(usize, file_urls, "count", .{}) != 0) {
        const count = objc.send(usize, file_urls, "count", .{});
        if (count > self.maximum_file_drop_paths) return error.BudgetExceeded;
        try paths.ensureTotalCapacity(allocator, count);
        for (0..count) |index| {
            const url = objc.send(objc.Id, file_urls, "objectAtIndex:", .{index});
            if (!objc.send(bool, url, "isFileURL", .{})) continue;
            const path = objc.utf8(objc.send(objc.Id, url, "path", .{}));
            if (path.len == 0) continue;
            paths.appendAssumeCapacity(try allocator.dupe(u8, path));
        }
    } else {
        const legacy = objc.send(objc.Id, pasteboard, "propertyListForType:", .{objc.nsString("NSFilenamesPboardType")});
        if (legacy != null and objc.send(bool, legacy, "isKindOfClass:", .{objc.class("NSArray")})) {
            const count = objc.send(usize, legacy, "count", .{});
            if (count > self.maximum_file_drop_paths) return error.BudgetExceeded;
            try paths.ensureTotalCapacity(allocator, count);
            for (0..count) |index| {
                const path = objc.utf8(objc.send(objc.Id, legacy, "objectAtIndex:", .{index}));
                if (path.len == 0) continue;
                paths.appendAssumeCapacity(try allocator.dupe(u8, path));
            }
        }
    }
    result.paths = try paths.toOwnedSlice(allocator);
    paths = .empty;

    var image_data = objc.send(objc.Id, pasteboard, "dataForType:", .{objc.nsString("public.png")});
    if (image_data == null) {
        const tiff = objc.send(objc.Id, pasteboard, "dataForType:", .{objc.nsString("public.tiff")});
        if (tiff != null) {
            const representation = objc.send(objc.Id, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{tiff});
            if (representation != null) image_data = objc.send(objc.Id, representation, "representationUsingType:properties:", .{
                @as(usize, 4), objc.send(objc.Id, objc.class("NSDictionary"), "dictionary", .{}),
            });
        }
    }
    if (image_data != null) {
        const length = objc.send(usize, image_data, "length", .{});
        if (length > self.maximum_clipboard_bytes) return error.BudgetExceeded;
        if (length != 0) {
            const bytes = objc.send(?[*]const u8, image_data, "bytes", .{}) orelse return error.PlatformFailure;
            result.image = .{ .format = .png, .bytes = try allocator.dupe(u8, bytes[0..length]) };
        }
    }
    const promise_count = try self.promised_file_service.promiseCount(pasteboard);
    result.promised_file_count = promise_count;
    if (promise_count != 0) {
        result.contains_promised_files = true;
        // A clipboard snapshot can still carry ordinary paths/text/image
        // values when the bounded receiver service has no capacity for its
        // promise side.  Preserve the explicit count rather than silently
        // dropping that representation or failing the entire snapshot.
        result.promised_batch = self.promised_file_service.capturePasteboard(pasteboard) catch |err| switch (err) {
            error.BudgetExceeded, error.PlatformFailure, error.OutOfSlots => null,
            else => return err,
        };
    }
    return result;
}

fn openExternalUrl(_: *anyopaque, value: []const u8) Error!void {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const url = objc.send(objc.Id, objc.class("NSURL"), "URLWithString:", .{objc.nsString(value)}) orelse return error.InvalidConfiguration;
    const workspace = objc.send(objc.Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}) orelse return error.PlatformFailure;
    if (!objc.send(bool, workspace, "openURL:", .{url})) return error.PlatformFailure;
}

fn fileUrl(path: []const u8) Error!objc.Id {
    return objc.send(objc.Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)}) orelse error.InvalidConfiguration;
}

fn openExternalPath(_: *anyopaque, path: []const u8) Error!void {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const workspace = objc.send(objc.Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}) orelse return error.PlatformFailure;
    if (!objc.send(bool, workspace, "openURL:", .{try fileUrl(path)})) return error.PlatformFailure;
}

fn revealExternalPath(_: *anyopaque, path: []const u8) Error!void {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const workspace = objc.send(objc.Id, objc.class("NSWorkspace"), "sharedWorkspace", .{}) orelse return error.PlatformFailure;
    objc.send(void, workspace, "activateFileViewerSelectingURLs:", .{objc.arrayWithObject(try fileUrl(path))});
}

fn chooseTrackedPrintWindow(candidates: []const PrintWindowCandidate) ?objc.Id {
    var selected: ?objc.Id = null;
    var selected_order: u64 = std.math.maxInt(u64);
    for (candidates) |candidate| {
        if (candidate.native == null or !candidate.visible or candidate.closing) continue;
        if (selected == null or candidate.order < selected_order) {
            selected = candidate.native;
            selected_order = candidate.order;
        }
    }
    return selected;
}

fn preferredPrintWindow(key_window: objc.Id, main_window: objc.Id, tracked_window: ?objc.Id) ?objc.Id {
    return key_window orelse main_window orelse tracked_window;
}

fn nativePrintWindowUsable(window: *const NativeWindow) bool {
    if (window.ns_window == null or !window.visible or window.closing) return false;
    if (!objc.send(bool, window.ns_window, "isVisible", .{})) return false;
    return !objc.send(bool, window.ns_window, "isMiniaturized", .{});
}

fn resolvePrintWindow(self: *Context) ?objc.Id {
    // AppKit's key and main windows are the strongest native status signals.
    // AX activation can leave both unset while one of ZigUI's own windows is
    // still visible, so deterministically select the lowest encoded live
    // window as the final, framework-owned candidate.
    const key_window = objc.send(objc.Id, self.application, "keyWindow", .{});
    const main_window = objc.send(objc.Id, self.application, "mainWindow", .{});

    var selected: ?objc.Id = null;
    var selected_order: u64 = std.math.maxInt(u64);
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (!nativePrintWindowUsable(entry.value_ptr)) continue;
        if (selected == null or entry.key_ptr.* < selected_order) {
            selected = entry.value_ptr.ns_window;
            selected_order = entry.key_ptr.*;
        }
    }
    return preferredPrintWindow(key_window, main_window, selected);
}

fn printExternalPath(raw: *anyopaque, path: []const u8) Error!void {
    const self: *Context = @ptrCast(@alignCast(raw));
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const window = resolvePrintWindow(self) orelse return error.PlatformFailure;
    const document_class = objc.class("PDFDocument") orelse return error.PlatformFailure;
    const document = objc.send(objc.Id, objc.send(objc.Id, document_class, "alloc", .{}), "initWithURL:", .{try fileUrl(path)}) orelse return error.PlatformFailure;
    errdefer objc.release(document);
    const print_info = objc.send(objc.Id, objc.class("NSPrintInfo"), "sharedPrintInfo", .{}) orelse return error.PlatformFailure;
    const operation = objc.send(objc.Id, document, "printOperationForPrintInfo:scalingMode:autoRotate:", .{
        print_info,
        @as(isize, 1),
        true,
    }) orelse return error.PlatformFailure;
    objc.send(void, operation, "setShowsPrintPanel:", .{true});
    objc.send(void, operation, "setShowsProgressPanel:", .{true});
    const delegate_class = try registerPrintDelegateClass();
    const delegate = objc.send(objc.Id, objc.send(objc.Id, delegate_class, "alloc", .{}), "init", .{}) orelse return error.PlatformFailure;
    errdefer objc.release(delegate);
    const context = try self.allocator.create(PrintContext);
    context.* = .{ .allocator = self.allocator, .document = document };
    errdefer self.allocator.destroy(context);
    _ = objc.send(void, operation, "runOperationModalForWindow:delegate:didRunSelector:contextInfo:", .{
        window,
        delegate,
        objc.selector("printOperationDidRun:success:contextInfo:"),
        context,
    });
}

fn registerPrintDelegateClass() Error!objc.Class {
    if (objc.class("ZigUIPrintDelegate")) |existing| return existing;
    const target = objc.objc_allocateClassPair(objc.class("NSObject"), "ZigUIPrintDelegate", 0) orelse return error.PlatformFailure;
    if (!objc.class_addMethod(target, objc.selector("printOperationDidRun:success:contextInfo:"), @ptrCast(&printOperationDidRun), "v@:@B^v")) return error.PlatformFailure;
    objc.objc_registerClassPair(target);
    return target;
}

fn printOperationDidRun(delegate: objc.Id, _: objc.Sel, _: objc.Id, _: bool, raw_context: ?*anyopaque) callconv(.c) void {
    if (raw_context) |raw| {
        const context: *PrintContext = @ptrCast(@alignCast(raw));
        objc.release(context.document);
        context.allocator.destroy(context);
    }
    objc.release(delegate);
}

fn setApplicationMenu(raw: *anyopaque, items: []const api.MenuItem) Error!void {
    const self = cast(raw);
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    try installMainMenu(self, items);
}

fn installMainMenu(self: *Context, items: []const api.MenuItem) Error!void {
    const main = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.nsString("Main")}) orelse return error.PlatformFailure;
    defer objc.release(main);

    const process_info = objc.send(objc.Id, objc.class("NSProcessInfo"), "processInfo", .{});
    const process_name = objc.send(objc.Id, process_info, "processName", .{});
    const app_item = try menuRootItem(process_name);
    defer objc.release(app_item);
    const app_menu = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{process_name}) orelse return error.PlatformFailure;
    defer objc.release(app_menu);
    const ownership = inspectMenuOwnership(items);
    var has_application_items = false;
    for (items) |definition| switch (definition) {
        .application => |application| {
            if (application.items.len != 0) {
                try appendMenuItems(self, app_menu, application.items);
                has_application_items = true;
            }
        },
        else => {},
    };
    if (!ownership.explicit_quit) {
        if (has_application_items) objc.send(void, app_menu, "addItem:", .{objc.send(objc.Id, objc.class("NSMenuItem"), "separatorItem", .{})});
        const quit_title = objc.send(objc.Id, objc.nsString("Quit "), "stringByAppendingString:", .{process_name});
        const quit_item = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
            quit_title, objc.selector("ziguiQuit:"), objc.nsString("q"),
        }) orelse return error.PlatformFailure;
        defer objc.release(quit_item);
        objc.send(void, quit_item, "setTarget:", .{self.menu_target});
        objc.send(void, app_menu, "addItem:", .{quit_item});
    }
    objc.send(void, app_item, "setSubmenu:", .{app_menu});
    objc.send(void, main, "addItem:", .{app_item});

    var explicit_window_menu: objc.Id = null;
    for (items) |definition| switch (definition) {
        .application => {},
        .submenu => |submenu| {
            const item = try menuRootItem(objc.nsString(submenu.label));
            defer objc.release(item);
            const child = try buildMenu(self, submenu.items, submenu.label);
            defer objc.release(child);
            objc.send(void, item, "setSubmenu:", .{child});
            objc.send(void, main, "addItem:", .{item});
            if (std.mem.eql(u8, submenu.label, "Window")) explicit_window_menu = child;
        },
        else => |other| try appendMenuItems(self, main, &.{other}),
    };

    if (explicit_window_menu) |window_menu| {
        objc.send(void, self.application, "setWindowsMenu:", .{window_menu});
    } else {
        const window_item = try menuRootItem(objc.nsString("Window"));
        defer objc.release(window_item);
        const window_menu = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.nsString("Window")}) orelse return error.PlatformFailure;
        defer objc.release(window_menu);
        try addSystemMenuItem(window_menu, "Minimize", "performMiniaturize:", "m", null);
        try addSystemMenuItem(window_menu, "Zoom", "performZoom:", "", null);
        const fullscreen_modifiers = types.Modifier.command | types.Modifier.control;
        try addSystemMenuItem(window_menu, "Enter Full Screen", "toggleFullScreen:", "f", fullscreen_modifiers);
        try addSystemMenuItem(window_menu, "Bring All to Front", "arrangeInFront:", "", null);
        objc.send(void, window_item, "setSubmenu:", .{window_menu});
        objc.send(void, main, "addItem:", .{window_item});
        objc.send(void, self.application, "setWindowsMenu:", .{window_menu});
    }
    objc.send(void, self.application, "setMainMenu:", .{main});
}

fn menuContainsSystemAction(items: []const api.MenuItem, target: api.SystemMenuAction) bool {
    for (items) |item| switch (item) {
        .system_action => |definition| if (definition.action == target) return true,
        .submenu => |submenu| if (menuContainsSystemAction(submenu.items, target)) return true,
        .application => |application| if (menuContainsSystemAction(application.items, target)) return true,
        else => {},
    };
    return false;
}

const MenuOwnership = struct {
    explicit_quit: bool = false,
    explicit_window: bool = false,
};

fn inspectMenuOwnership(items: []const api.MenuItem) MenuOwnership {
    var result: MenuOwnership = .{};
    for (items) |item| switch (item) {
        .application => |application| result.explicit_quit = result.explicit_quit or menuContainsSystemAction(application.items, .quit_application),
        .submenu => |submenu| result.explicit_window = result.explicit_window or std.mem.eql(u8, submenu.label, "Window"),
        else => {},
    };
    return result;
}

fn menuRootItem(title: objc.Id) Error!objc.Id {
    const item = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
        title, @as(objc.Sel, null), objc.nsString(""),
    }) orelse return error.PlatformFailure;
    return item;
}

fn addSystemMenuItem(menu: objc.Id, label: []const u8, action: [*:0]const u8, equivalent: []const u8, modifier_mask: ?u64) Error!void {
    const item = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
        objc.nsString(label), objc.selector(action), objc.nsString(equivalent),
    }) orelse return error.PlatformFailure;
    defer objc.release(item);
    if (modifier_mask) |mask| objc.send(void, item, "setKeyEquivalentModifierMask:", .{mask});
    objc.send(void, menu, "addItem:", .{item});
}

fn showContextMenu(raw: *anyopaque, id: handles.WindowId, point: geometry.Point, items: []const api.MenuItem) Error!void {
    const self = cast(raw);
    const window = self.windows.getPtr(id.encode()) orelse return error.InvalidHandle;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const menu = try buildMenu(self, items, "Context");
    defer objc.release(menu);
    objc.send(void, menu, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(objc.Id, null), types.Point{ .x = point.x, .y = point.y }, window.view });
}

fn buildMenu(self: *Context, items: []const api.MenuItem, title: []const u8) Error!objc.Id {
    const menu = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.nsString(title)}) orelse return error.PlatformFailure;
    errdefer objc.release(menu);
    objc.send(void, menu, "setAutoenablesItems:", .{false});
    try appendMenuItems(self, menu, items);
    return menu;
}

fn appendMenuItems(self: *Context, menu: objc.Id, items: []const api.MenuItem) Error!void {
    for (items) |definition| switch (definition) {
        .separator => {
            const item = objc.send(objc.Id, objc.class("NSMenuItem"), "separatorItem", .{});
            objc.send(void, menu, "addItem:", .{item});
        },
        .action => |action_item| {
            var equivalent_buffer: [4]u8 = undefined;
            const equivalent = if (action_item.shortcut) |shortcut|
                try menuShortcutEquivalent(shortcut, &equivalent_buffer)
            else
                "";
            const item = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
                objc.nsString(action_item.label), objc.selector("ziguiMenuAction:"), objc.nsString(equivalent),
            }) orelse return error.PlatformFailure;
            defer objc.release(item);
            objc.send(void, item, "setTarget:", .{self.menu_target});
            objc.send(void, item, "setTag:", .{@as(isize, @bitCast(action_item.action.encode()))});
            const payload = objc.send(objc.Id, objc.class("NSNumber"), "numberWithUnsignedLongLong:", .{action_item.payload});
            objc.send(void, item, "setRepresentedObject:", .{payload});
            objc.send(void, item, "setEnabled:", .{action_item.enabled});
            objc.send(void, item, "setState:", .{@as(isize, if (action_item.checked) 1 else 0)});
            if (action_item.shortcut) |shortcut|
                objc.send(void, item, "setKeyEquivalentModifierMask:", .{menuShortcutModifierMask(shortcut.modifiers)});
            objc.send(void, menu, "addItem:", .{item});
        },
        .submenu => |submenu| {
            const item = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
                objc.nsString(submenu.label), @as(objc.Sel, null), objc.nsString(""),
            }) orelse return error.PlatformFailure;
            defer objc.release(item);
            const child = try buildMenu(self, submenu.items, submenu.label);
            defer objc.release(child);
            objc.send(void, item, "setSubmenu:", .{child});
            objc.send(void, menu, "addItem:", .{item});
        },
        .application => {},
        .system_action => |system_definition| try appendSystemMenuItem(self, menu, system_definition),
    };
}

fn menuShortcutEquivalent(shortcut: api.MenuShortcut, buffer: *[4]u8) Error![]const u8 {
    const scalar: u21 = switch (shortcut.key) {
        .character => |value| value,
        .enter => '\r',
        .escape => 0x1b,
        .tab => '\t',
        .backspace => 0x08,
        .delete => 0x7f,
        .insert => 0xf727,
        .home => 0xf729,
        .end => 0xf72b,
        .page_up => 0xf72c,
        .page_down => 0xf72d,
        .arrow_up => 0xf700,
        .arrow_down => 0xf701,
        .arrow_left => 0xf702,
        .arrow_right => 0xf703,
        .space => ' ',
        .function => |number| if (number >= 1 and number <= 35) 0xf704 + @as(u21, number - 1) else return error.InvalidConfiguration,
        .native => return error.Unsupported,
    };
    if (scalar == 0 or !std.unicode.utf8ValidCodepoint(scalar)) return error.InvalidConfiguration;
    const length = std.unicode.utf8Encode(scalar, buffer) catch return error.InvalidConfiguration;
    return buffer[0..length];
}

fn menuShortcutModifierMask(shortcut_modifiers: input.Modifiers) u64 {
    var mask: u64 = 0;
    if (shortcut_modifiers.shift) mask |= types.Modifier.shift;
    if (shortcut_modifiers.control) mask |= types.Modifier.control;
    if (shortcut_modifiers.alt) mask |= types.Modifier.option;
    if (shortcut_modifiers.command) mask |= types.Modifier.command;
    if (shortcut_modifiers.caps_lock) mask |= types.Modifier.caps_lock;
    if (shortcut_modifiers.num_lock) mask |= types.Modifier.numeric_pad;
    if (shortcut_modifiers.function) mask |= types.Modifier.function;
    return mask;
}

fn appendSystemMenuItem(self: *Context, menu: objc.Id, definition: @FieldType(api.MenuItem, "system_action")) Error!void {
    if (definition.action == .services) {
        const item = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
            objc.nsString(definition.label), @as(objc.Sel, null), objc.nsString(""),
        }) orelse return error.PlatformFailure;
        defer objc.release(item);
        const services_menu = objc.send(objc.Id, self.application, "servicesMenu", .{}) orelse blk: {
            const created = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.nsString(definition.label)}) orelse return error.PlatformFailure;
            objc.send(void, self.application, "setServicesMenu:", .{created});
            objc.release(created);
            break :blk objc.send(objc.Id, self.application, "servicesMenu", .{}) orelse return error.PlatformFailure;
        };
        objc.send(void, item, "setSubmenu:", .{services_menu});
        objc.send(void, menu, "addItem:", .{item});
        return;
    }

    const selector_name = switch (definition.action) {
        .about_application => "orderFrontStandardAboutPanel:",
        .hide_application => "hide:",
        .hide_other_applications => "hideOtherApplications:",
        .show_all_applications => "unhideAllApplications:",
        .quit_application => "ziguiQuit:",
        .close_window => "performClose:",
        .minimize_window => "performMiniaturize:",
        .zoom_window => "performZoom:",
        .enter_fullscreen => "toggleFullScreen:",
        .bring_all_to_front => "arrangeInFront:",
        .undo => "undo:",
        .redo => "redo:",
        .cut => "cut:",
        .copy => "copy:",
        .paste => "paste:",
        .select_all => "selectAll:",
        .services => unreachable,
    };
    const equivalent = switch (definition.action) {
        .hide_application => "h",
        .hide_other_applications => "h",
        .quit_application => "q",
        .close_window => "w",
        .minimize_window => "m",
        .enter_fullscreen => "f",
        .undo => "z",
        .redo => "z",
        .cut => "x",
        .copy => "c",
        .paste => "v",
        .select_all => "a",
        else => "",
    };
    const modifier_mask: u64 = switch (definition.action) {
        .hide_other_applications => types.Modifier.command | types.Modifier.option,
        .quit_application, .close_window, .minimize_window, .undo, .cut, .copy, .paste, .select_all => types.Modifier.command,
        .redo => types.Modifier.command | types.Modifier.shift,
        .enter_fullscreen => types.Modifier.command | types.Modifier.control,
        else => 0,
    };
    const item = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
        objc.nsString(definition.label), objc.selector(selector_name), objc.nsString(equivalent),
    }) orelse return error.PlatformFailure;
    defer objc.release(item);
    if (modifier_mask != 0) objc.send(void, item, "setKeyEquivalentModifierMask:", .{modifier_mask});
    switch (definition.action) {
        .about_application, .hide_application, .hide_other_applications, .show_all_applications => objc.send(void, item, "setTarget:", .{self.application}),
        .quit_application => objc.send(void, item, "setTarget:", .{self.menu_target}),
        else => {},
    }
    objc.send(void, menu, "addItem:", .{item});
}

fn openFiles(raw: *anyopaque, id: handles.WindowId, multiple: bool, allocator: std.mem.Allocator) Error!api.OwnedPaths {
    const self = cast(raw);
    if (!self.windows.contains(id.encode())) return error.InvalidHandle;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const panel = objc.send(objc.Id, objc.class("NSOpenPanel"), "openPanel", .{}) orelse return error.PlatformFailure;
    objc.send(void, panel, "setAllowsMultipleSelection:", .{multiple});
    objc.send(void, panel, "setCanChooseFiles:", .{true});
    objc.send(void, panel, "setCanChooseDirectories:", .{false});
    if (objc.send(isize, panel, "runModal", .{}) != 1) return .{
        .allocator = allocator,
        .values = try allocator.alloc([]const u8, 0),
    };
    const urls = objc.send(objc.Id, panel, "URLs", .{});
    const count = objc.send(usize, urls, "count", .{});
    const paths = try allocator.alloc([]const u8, count);
    var initialized: usize = 0;
    errdefer {
        for (paths[0..initialized]) |path| allocator.free(@constCast(path));
        allocator.free(paths);
    }
    for (0..count) |index| {
        const url = objc.send(objc.Id, urls, "objectAtIndex:", .{index});
        const path = objc.send(objc.Id, url, "path", .{});
        paths[index] = try allocator.dupe(u8, objc.utf8(path));
        initialized += 1;
    }
    return .{ .allocator = allocator, .values = paths };
}

fn openDirectory(raw: *anyopaque, id: handles.WindowId, allocator: std.mem.Allocator) Error!?api.OwnedPath {
    const self = cast(raw);
    if (!self.windows.contains(id.encode())) return error.InvalidHandle;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const panel = objc.send(objc.Id, objc.class("NSOpenPanel"), "openPanel", .{}) orelse return error.PlatformFailure;
    objc.send(void, panel, "setAllowsMultipleSelection:", .{false});
    objc.send(void, panel, "setCanChooseFiles:", .{false});
    objc.send(void, panel, "setCanChooseDirectories:", .{true});
    if (objc.send(isize, panel, "runModal", .{}) != 1) return null;
    const url = objc.send(objc.Id, panel, "URL", .{});
    const path = objc.send(objc.Id, url, "path", .{});
    return .{ .allocator = allocator, .value = try allocator.dupe(u8, objc.utf8(path)) };
}

fn saveFile(raw: *anyopaque, id: handles.WindowId, suggested_name: []const u8, allocator: std.mem.Allocator) Error!?api.OwnedPath {
    const self = cast(raw);
    if (!self.windows.contains(id.encode())) return error.InvalidHandle;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const panel = objc.send(objc.Id, objc.class("NSSavePanel"), "savePanel", .{}) orelse return error.PlatformFailure;
    if (suggested_name.len != 0) objc.send(void, panel, "setNameFieldStringValue:", .{objc.nsString(suggested_name)});
    if (objc.send(isize, panel, "runModal", .{}) != 1) return null;
    const url = objc.send(objc.Id, panel, "URL", .{});
    const path = objc.send(objc.Id, url, "path", .{});
    return .{ .allocator = allocator, .value = try allocator.dupe(u8, objc.utf8(path)) };
}

fn deinitContext(raw: *anyopaque) void {
    cast(raw).deinit();
}

fn firstWindow(self: *Context) ?handles.WindowId {
    var iterator = self.windows.iterator();
    const entry = iterator.next() orelse return null;
    return .{ .index = @truncate(entry.key_ptr.*), .generation = @truncate(entry.key_ptr.* >> 32) };
}

fn applicationOpenPosition(self: *const Context, window: handles.WindowId) geometry.Point {
    const native = self.windows.get(window.encode()) orelse return .{};
    return logicalCenter(native.logical_size);
}

fn pendingApplicationOpenHasCapacity(self: *const Context) bool {
    const unread = self.events.items.len - self.event_cursor;
    if (unread >= self.maximum_events) return false;
    return self.pending_open_payload_bytes <= self.maximum_event_queue_bytes -| self.pending_payload_bytes;
}

fn flushPendingApplicationOpen(self: *Context, window: handles.WindowId) bool {
    if (self.pending_open_paths.items.len == 0 and self.pending_open_text.items.len == 0) return false;
    // A pre-window payload is the only owner of its original path/text
    // buffers until queueDrop has accepted a deep-copied event.  Do not call
    // queueDrop while its bounded queue is full: queueDrop reports rejection
    // through the platform failure path, and freeing the originals here would
    // otherwise lose the Finder/Open With request.
    if (!pendingApplicationOpenHasCapacity(self)) return false;
    const accepted = self.queueDrop(
        window,
        .performed,
        self.pending_open_paths.items,
        if (self.pending_open_text.items.len == 0) null else self.pending_open_text.items,
        null,
        0,
        applicationOpenPosition(self, window),
    );
    if (!accepted) return false;

    var paths = self.pending_open_paths;
    self.pending_open_paths = .empty;
    var text = self.pending_open_text;
    self.pending_open_text = .empty;
    self.pending_open_payload_bytes = 0;
    for (paths.items) |path| self.allocator.free(path);
    paths.deinit(self.allocator);
    text.deinit(self.allocator);
    return true;
}

fn appendPendingApplicationOpen(self: *Context, paths: *std.ArrayList([]u8), text: *std.ArrayList(u8)) bool {
    if (paths.items.len > self.maximum_file_drop_paths -| self.pending_open_paths.items.len) {
        self.fail(error.BudgetExceeded);
        return false;
    }
    const incoming_bytes = event_memory.ownedPayloadBytes(
        if (text.items.len == 0) null else text.items,
        paths.items,
    ) catch |err| {
        self.fail(err);
        return false;
    };
    const separator_bytes: usize = if (self.pending_open_text.items.len != 0 and text.items.len != 0) 1 else 0;
    const additional_bytes = std.math.add(usize, incoming_bytes, separator_bytes) catch {
        self.fail(error.BudgetExceeded);
        return false;
    };
    if (additional_bytes > self.maximum_event_queue_bytes -| self.pending_open_payload_bytes) {
        self.fail(error.BudgetExceeded);
        return false;
    }

    const pending_path_start = self.pending_open_paths.items.len;
    for (paths.items, 0..) |path, index| {
        self.pending_open_paths.append(self.allocator, path) catch {
            for (self.pending_open_paths.items[pending_path_start..]) |owned| self.allocator.free(owned);
            self.pending_open_paths.shrinkRetainingCapacity(pending_path_start);
            for (paths.items[index..]) |owned| self.allocator.free(owned);
            paths.clearRetainingCapacity();
            self.fail(error.BudgetExceeded);
            return false;
        };
    }
    paths.clearRetainingCapacity();
    const pending_text_start = self.pending_open_text.items.len;
    if (separator_bytes != 0) {
        self.pending_open_text.append(self.allocator, '\n') catch {
            for (self.pending_open_paths.items[pending_path_start..]) |owned| self.allocator.free(owned);
            self.pending_open_paths.shrinkRetainingCapacity(pending_path_start);
            self.pending_open_text.shrinkRetainingCapacity(pending_text_start);
            self.fail(error.BudgetExceeded);
            return false;
        };
    }
    self.pending_open_text.appendSlice(self.allocator, text.items) catch {
        for (self.pending_open_paths.items[pending_path_start..]) |owned| self.allocator.free(owned);
        self.pending_open_paths.shrinkRetainingCapacity(pending_path_start);
        self.pending_open_text.shrinkRetainingCapacity(pending_text_start);
        self.fail(error.BudgetExceeded);
        return false;
    };
    self.pending_open_payload_bytes += additional_bytes;
    return true;
}

fn retryPendingApplicationOpen(self: *Context) void {
    if (self.failure != null or self.quit) return;
    if (self.pending_open_paths.items.len == 0 and self.pending_open_text.items.len == 0) return;
    const window = firstWindow(self) orelse return;
    if (self.event_cursor < self.events.items.len) return;
    _ = flushPendingApplicationOpen(self, window);
}

fn queueApplicationOpenPayload(self: *Context, paths: *std.ArrayList([]u8), text: *std.ArrayList(u8)) bool {
    if (paths.items.len == 0 and text.items.len == 0) return false;
    const window = firstWindow(self);
    if (window) |id| {
        // Preserve ordering if a previous pre-window payload is waiting for
        // queue capacity.  New application-open callbacks join that owned
        // payload instead of bypassing it through a later event.
        if (self.pending_open_paths.items.len != 0 or self.pending_open_text.items.len != 0) {
            if (!appendPendingApplicationOpen(self, paths, text)) return false;
            _ = flushPendingApplicationOpen(self, id);
            return true;
        }
        const accepted = self.queueDrop(id, .performed, paths.items, if (text.items.len == 0) null else text.items, null, 0, applicationOpenPosition(self, id));
        for (paths.items) |path| self.allocator.free(path);
        paths.clearRetainingCapacity();
        return accepted;
    }
    return appendPendingApplicationOpen(self, paths, text);
}

fn queueApplicationFiles(self: *Context, values: objc.Id) void {
    const count = objc.send(usize, values, "count", .{});
    if (count > self.maximum_file_drop_paths) return self.fail(error.BudgetExceeded);
    var paths: std.ArrayList([]u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    defer {
        for (paths.items) |path| self.allocator.free(path);
        paths.deinit(self.allocator);
        text.deinit(self.allocator);
    }
    for (0..count) |index| {
        const value = objc.send(objc.Id, values, "objectAtIndex:", .{index}) orelse continue;
        const path = objc.utf8(value);
        if (path.len == 0 or path.len > self.maximum_event_payload_bytes) continue;
        const copy = self.allocator.dupe(u8, path) catch {
            self.fail(error.OutOfMemory);
            return;
        };
        paths.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            self.fail(error.OutOfMemory);
            return;
        };
    }
    _ = queueApplicationOpenPayload(self, &paths, &text);
}

fn queueApplicationURLs(self: *Context, values: objc.Id) void {
    const count = objc.send(usize, values, "count", .{});
    if (count > self.maximum_file_drop_paths) return self.fail(error.BudgetExceeded);
    var paths: std.ArrayList([]u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    defer {
        for (paths.items) |path| self.allocator.free(path);
        paths.deinit(self.allocator);
        text.deinit(self.allocator);
    }
    for (0..count) |index| {
        const value = objc.send(objc.Id, values, "objectAtIndex:", .{index}) orelse continue;
        if (objc.send(bool, value, "isFileURL", .{})) {
            const path = objc.utf8(objc.send(objc.Id, value, "path", .{}));
            if (path.len == 0 or path.len > self.maximum_event_payload_bytes) continue;
            const copy = self.allocator.dupe(u8, path) catch {
                self.fail(error.OutOfMemory);
                return;
            };
            paths.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                self.fail(error.OutOfMemory);
                return;
            };
        } else {
            const url = objc.utf8(objc.send(objc.Id, value, "absoluteString", .{}));
            if (!std.ascii.startsWithIgnoreCase(url, "http://") and !std.ascii.startsWithIgnoreCase(url, "https://")) continue;
            if (url.len == 0 or url.len > self.maximum_event_payload_bytes) continue;
            const separator_bytes: usize = if (text.items.len == 0) 0 else 1;
            const url_bytes = std.math.add(usize, separator_bytes, url.len) catch {
                self.fail(error.BudgetExceeded);
                return;
            };
            if (url_bytes > self.maximum_event_payload_bytes -| text.items.len) {
                self.fail(error.BudgetExceeded);
                return;
            }
            if (text.items.len != 0) text.append(self.allocator, '\n') catch return self.fail(error.OutOfMemory);
            text.appendSlice(self.allocator, url) catch return self.fail(error.OutOfMemory);
        }
    }
    _ = queueApplicationOpenPayload(self, &paths, &text);
}

fn applicationOpenFiles(target: objc.Id, _: objc.Sel, _: objc.Id, values: objc.Id) callconv(.c) void {
    const self = (objc.getIvar(?*Context, target, "_ziguiContext") orelse null) orelse return;
    queueApplicationFiles(self, values);
}

fn applicationOpenURLs(target: objc.Id, _: objc.Sel, _: objc.Id, values: objc.Id) callconv(.c) void {
    const self = (objc.getIvar(?*Context, target, "_ziguiContext") orelse null) orelse return;
    queueApplicationURLs(self, values);
}

fn applicationOpenFile(target: objc.Id, _: objc.Sel, _: objc.Id, value: objc.Id) callconv(.c) bool {
    const self = (objc.getIvar(?*Context, target, "_ziguiContext") orelse null) orelse return false;
    const path = objc.utf8(value);
    if (path.len == 0 or path.len > self.maximum_event_payload_bytes) return false;
    var paths: std.ArrayList([]u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    defer {
        for (paths.items) |owned| self.allocator.free(owned);
        paths.deinit(self.allocator);
        text.deinit(self.allocator);
    }
    const copy = self.allocator.dupe(u8, path) catch return false;
    paths.append(self.allocator, copy) catch {
        self.allocator.free(copy);
        return false;
    };
    return queueApplicationOpenPayload(self, &paths, &text);
}

fn viewContext(view: objc.Id) ?*Context {
    if (view == null) return null;
    return objc.getIvar(?*Context, view, "_ziguiContext") orelse null;
}

fn viewWindow(view: objc.Id) handles.WindowId {
    const encoded = objc.getIvar(u64, view, "_ziguiWindow") orelse return .invalid;
    return .{ .index = @truncate(encoded), .generation = @truncate(encoded >> 32) };
}

fn registerViewClass() Error!objc.Class {
    if (objc.class("ZigUIView")) |existing| return existing;
    const target = objc.objc_allocateClassPair(objc.class("NSView"), "ZigUIView", 0) orelse return error.PlatformFailure;
    const text_input_protocol = objc.objc_getProtocol("NSTextInputClient") orelse return error.PlatformFailure;
    if (!objc.class_addProtocol(target, text_input_protocol)) return error.PlatformFailure;
    if (!objc.addIvar(?*Context, target, "_ziguiContext", "^v")) return error.PlatformFailure;
    if (!objc.addIvar(?*anyopaque, target, "_ziguiAccessibility", "^v")) return error.PlatformFailure;
    if (!objc.addIvar(u64, target, "_ziguiWindow", "Q")) return error.PlatformFailure;
    inline for (view_methods) |method| {
        if (!objc.class_addMethod(target, objc.selector(method.name), method.implementation, method.encoding)) return error.PlatformFailure;
    }
    objc.objc_registerClassPair(target);
    return target;
}

fn registerMenuTargetClass() Error!objc.Class {
    if (objc.class("ZigUIMenuTarget")) |existing| return existing;
    const target = objc.objc_allocateClassPair(objc.class("NSObject"), "ZigUIMenuTarget", 0) orelse return error.PlatformFailure;
    if (!objc.addIvar(?*Context, target, "_ziguiContext", "^v")) return error.PlatformFailure;
    if (!objc.class_addMethod(target, objc.selector("ziguiMenuAction:"), @ptrCast(&menuAction), "v@:@")) return error.PlatformFailure;
    if (!objc.class_addMethod(target, objc.selector("ziguiQuit:"), @ptrCast(&menuQuit), "v@:@")) return error.PlatformFailure;
    if (!objc.class_addMethod(target, objc.selector("application:openFiles:"), @ptrCast(&applicationOpenFiles), "v@:@@")) return error.PlatformFailure;
    if (!objc.class_addMethod(target, objc.selector("application:openURLs:"), @ptrCast(&applicationOpenURLs), "v@:@@")) return error.PlatformFailure;
    if (!objc.class_addMethod(target, objc.selector("application:openFile:"), @ptrCast(&applicationOpenFile), "B@:@")) return error.PlatformFailure;
    objc.objc_registerClassPair(target);
    return target;
}

fn menuQuit(target: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = (objc.getIvar(?*Context, target, "_ziguiContext") orelse null) orelse return;
    self.quit = true;
    wake(self);
}

fn menuAction(target: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) void {
    const self = (objc.getIvar(?*Context, target, "_ziguiContext") orelse null) orelse return;
    const encoded: u64 = @bitCast(objc.send(isize, sender, "tag", .{}));
    const action_id: handles.ActionId = .{ .index = @truncate(encoded), .generation = @truncate(encoded >> 32) };
    const represented = objc.send(objc.Id, sender, "representedObject", .{});
    const payload = if (represented != null) objc.send(u64, represented, "unsignedLongLongValue", .{}) else 0;
    const key_window = objc.send(objc.Id, self.application, "keyWindow", .{});
    var selected: ?handles.WindowId = null;
    var iterator = self.windows.iterator();
    while (iterator.next()) |entry| {
        if (selected == null) selected = .{ .index = @truncate(entry.key_ptr.*), .generation = @truncate(entry.key_ptr.* >> 32) };
        if (entry.value_ptr.ns_window == key_window) {
            selected = .{ .index = @truncate(entry.key_ptr.*), .generation = @truncate(entry.key_ptr.* >> 32) };
            break;
        }
    }
    if (selected) |window| self.queue(window, .{ .menu_action = .{ .action = action_id, .payload = payload } });
}

const Method = struct { name: [*:0]const u8, implementation: objc.Imp, encoding: [*:0]const u8 };
const view_methods = [_]Method{
    .{ .name = "isFlipped", .implementation = @ptrCast(&viewTrue), .encoding = "B@:" },
    .{ .name = "acceptsFirstResponder", .implementation = @ptrCast(&viewTrue), .encoding = "B@:" },
    .{ .name = "acceptsFirstMouse:", .implementation = @ptrCast(&acceptsFirstMouse), .encoding = "B@:@" },
    .{ .name = "wantsUpdateLayer", .implementation = @ptrCast(&viewTrue), .encoding = "B@:" },
    .{ .name = "setFrameSize:", .implementation = @ptrCast(&setFrameSize), .encoding = "v@:{CGSize=dd}" },
    .{ .name = "updateLayer", .implementation = @ptrCast(&updateLayer), .encoding = "v@:" },
    .{ .name = "viewDidChangeEffectiveAppearance", .implementation = @ptrCast(&viewDidChangeEffectiveAppearance), .encoding = "v@:" },
    .{ .name = "mouseDown:", .implementation = @ptrCast(&mouseDown), .encoding = "v@:@" },
    .{ .name = "mouseUp:", .implementation = @ptrCast(&mouseUp), .encoding = "v@:@" },
    .{ .name = "rightMouseDown:", .implementation = @ptrCast(&rightMouseDown), .encoding = "v@:@" },
    .{ .name = "rightMouseUp:", .implementation = @ptrCast(&rightMouseUp), .encoding = "v@:@" },
    .{ .name = "otherMouseDown:", .implementation = @ptrCast(&otherMouseDown), .encoding = "v@:@" },
    .{ .name = "otherMouseUp:", .implementation = @ptrCast(&otherMouseUp), .encoding = "v@:@" },
    .{ .name = "mouseMoved:", .implementation = @ptrCast(&mouseMoved), .encoding = "v@:@" },
    .{ .name = "mouseDragged:", .implementation = @ptrCast(&mouseMoved), .encoding = "v@:@" },
    .{ .name = "rightMouseDragged:", .implementation = @ptrCast(&mouseMoved), .encoding = "v@:@" },
    .{ .name = "otherMouseDragged:", .implementation = @ptrCast(&mouseMoved), .encoding = "v@:@" },
    .{ .name = "mouseEntered:", .implementation = @ptrCast(&mouseEntered), .encoding = "v@:@" },
    .{ .name = "mouseExited:", .implementation = @ptrCast(&mouseExited), .encoding = "v@:@" },
    .{ .name = "scrollWheel:", .implementation = @ptrCast(&scrollWheel), .encoding = "v@:@" },
    .{ .name = "keyDown:", .implementation = @ptrCast(&keyDown), .encoding = "v@:@" },
    .{ .name = "keyUp:", .implementation = @ptrCast(&keyUp), .encoding = "v@:@" },
    .{ .name = "flagsChanged:", .implementation = @ptrCast(&flagsChanged), .encoding = "v@:@" },
    .{ .name = "undo:", .implementation = @ptrCast(&systemUndo), .encoding = "v@:@" },
    .{ .name = "redo:", .implementation = @ptrCast(&systemRedo), .encoding = "v@:@" },
    .{ .name = "cut:", .implementation = @ptrCast(&systemCut), .encoding = "v@:@" },
    .{ .name = "copy:", .implementation = @ptrCast(&systemCopy), .encoding = "v@:@" },
    .{ .name = "paste:", .implementation = @ptrCast(&systemPaste), .encoding = "v@:@" },
    .{ .name = "selectAll:", .implementation = @ptrCast(&systemSelectAll), .encoding = "v@:@" },
    .{ .name = "draggingEntered:", .implementation = @ptrCast(&draggingEntered), .encoding = "Q@:@" },
    .{ .name = "draggingUpdated:", .implementation = @ptrCast(&draggingUpdated), .encoding = "Q@:@" },
    .{ .name = "draggingExited:", .implementation = @ptrCast(&draggingExited), .encoding = "v@:@" },
    .{ .name = "prepareForDragOperation:", .implementation = @ptrCast(&prepareForDragOperation), .encoding = "B@:@" },
    .{ .name = "performDragOperation:", .implementation = @ptrCast(&performDragOperation), .encoding = "B@:@" },
    .{ .name = "windowShouldClose:", .implementation = @ptrCast(&windowShouldClose), .encoding = "B@:@" },
    .{ .name = "windowDidResize:", .implementation = @ptrCast(&windowDidResize), .encoding = "v@:@" },
    .{ .name = "windowDidChangeBackingProperties:", .implementation = @ptrCast(&windowDidResize), .encoding = "v@:@" },
    .{ .name = "windowDidEnterFullScreen:", .implementation = @ptrCast(&windowDidEnterFullScreen), .encoding = "v@:@" },
    .{ .name = "windowDidExitFullScreen:", .implementation = @ptrCast(&windowDidExitFullScreen), .encoding = "v@:@" },
    .{ .name = "windowDidMiniaturize:", .implementation = @ptrCast(&windowDidMiniaturize), .encoding = "v@:@" },
    .{ .name = "windowDidDeminiaturize:", .implementation = @ptrCast(&windowDidDeminiaturize), .encoding = "v@:@" },
    .{ .name = "windowDidMove:", .implementation = @ptrCast(&windowDidMove), .encoding = "v@:@" },
    .{ .name = "windowDidChangeScreen:", .implementation = @ptrCast(&windowDidChangeScreen), .encoding = "v@:@" },
    .{ .name = "windowDidBecomeKey:", .implementation = @ptrCast(&windowDidBecomeKey), .encoding = "v@:@" },
    .{ .name = "windowDidResignKey:", .implementation = @ptrCast(&windowDidResignKey), .encoding = "v@:@" },
    .{ .name = "windowDidChangeOcclusionState:", .implementation = @ptrCast(&windowDidChangeOcclusion), .encoding = "v@:@" },
    .{ .name = "hasMarkedText", .implementation = @ptrCast(&hasMarkedText), .encoding = "B@:" },
    .{ .name = "markedRange", .implementation = @ptrCast(&markedRange), .encoding = "{_NSRange=QQ}@:" },
    .{ .name = "selectedRange", .implementation = @ptrCast(&selectedRange), .encoding = "{_NSRange=QQ}@:" },
    .{ .name = "setMarkedText:selectedRange:replacementRange:", .implementation = @ptrCast(&setMarkedText), .encoding = "v@:@{_NSRange=QQ}{_NSRange=QQ}" },
    .{ .name = "unmarkText", .implementation = @ptrCast(&unmarkText), .encoding = "v@:" },
    .{ .name = "validAttributesForMarkedText", .implementation = @ptrCast(&validAttributesForMarkedText), .encoding = "@@:" },
    .{ .name = "attributedSubstringForProposedRange:actualRange:", .implementation = @ptrCast(&attributedSubstring), .encoding = "@@:{_NSRange=QQ}^{_NSRange=QQ}" },
    .{ .name = "insertText:replacementRange:", .implementation = @ptrCast(&insertText), .encoding = "v@:@{_NSRange=QQ}" },
    .{ .name = "characterIndexForPoint:", .implementation = @ptrCast(&characterIndexForPoint), .encoding = "Q@:{CGPoint=dd}" },
    .{ .name = "firstRectForCharacterRange:actualRange:", .implementation = @ptrCast(&firstRectForCharacterRange), .encoding = "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}" },
    .{ .name = "doCommandBySelector:", .implementation = @ptrCast(&doCommandBySelector), .encoding = "v@::" },
    .{ .name = "accessibilityFocusedUIElement", .implementation = @ptrCast(&accessibilityFocusedUIElement), .encoding = "@@:" },
};

fn viewTrue(_: objc.Id, _: objc.Sel) callconv(.c) bool {
    return true;
}
fn acceptsFirstMouse(_: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) bool {
    return true;
}

fn updateLayer(view: objc.Id, _: objc.Sel) callconv(.c) void {
    const self = viewContext(view) orelse return;
    const id = viewWindow(view);
    // AppKit may ask a layer-hosting view to update after its bounds changed
    // before (or without another useful delegate notification). Refresh the
    // owned logical metrics at the redraw boundary so the next drawable can
    // never be arranged using the previous window size.
    self.emitWindowMetrics(id);
    requestFrame(self, id) catch |err| self.fail(err);
}

fn setFrameSize(view: objc.Id, _: objc.Sel, size: types.Size) callconv(.c) void {
    objc.sendSuper(void, view, objc.class("NSView"), "setFrameSize:", .{size});
    const self = viewContext(view) orelse return;
    const id = viewWindow(view);
    const window = self.windows.getPtr(id.encode()) orelse return;
    const scale = window.scale_factor.value;
    objc.send(void, window.layer, "setDrawableSize:", .{types.Size{
        .width = size.width * scale,
        .height = size.height * scale,
    }});
    if (liveResizeSink(self)) |sink| {
        const changed = size.width != window.logical_size.width or size.height != window.logical_size.height;
        window.logical_size = .{ .width = @floatCast(size.width), .height = @floatCast(size.height) };
        if (changed) {
            const resized: api.WindowEvent = .{ .resized = window.logical_size };
            sendToSink(self, sink, id, &resized);
        }
        window.frame_queued = false;
        const frame: api.WindowEvent = .{ .frame_requested = self.now() };
        sendToSink(self, sink, id, &frame);
        return;
    }
    self.emitWindowMetrics(id);
    requestFrame(self, id) catch |err| self.fail(err);
}

fn viewDidChangeEffectiveAppearance(view: objc.Id, _: objc.Sel) callconv(.c) void {
    const self = viewContext(view) orelse return;
    self.queue(viewWindow(view), .{ .appearance_changed = appearance(view) });
}

fn mouseDown(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .down, .primary);
}
fn mouseUp(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .up, .primary);
}
fn rightMouseDown(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .down, .secondary);
}
fn rightMouseUp(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .up, .secondary);
}
fn otherMouseDown(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .down, mapMouseButton(event));
}
fn otherMouseUp(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .up, mapMouseButton(event));
}
fn mouseMoved(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .move, null);
}
fn mouseEntered(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .entered, null);
}
fn mouseExited(view: objc.Id, _: objc.Sel, event: objc.Id) callconv(.c) void {
    emitPointer(view, event, .exited, null);
}

const PointerPhase = enum { down, up, move, entered, exited };

fn emitPointer(view: objc.Id, native_event: objc.Id, phase: PointerPhase, button: ?input.MouseButton) void {
    const self = viewContext(view) orelse return;
    const point = eventPoint(view, native_event);
    const event_type = objc.send(usize, native_event, "type", .{});
    const pointer: input.PointerEvent = .{
        .position = point,
        .delta = .{
            .x = @floatCast(objc.send(f64, native_event, "deltaX", .{})),
            .y = @floatCast(objc.send(f64, native_event, "deltaY", .{})),
        },
        .button = button,
        .buttons = @truncate(objc.send(u64, objc.class("NSEvent"), "pressedMouseButtons", .{})),
        .pressure = if (eventCarriesPressure(event_type)) objc.send(f32, native_event, "pressure", .{}) else 0,
        .modifiers = modifiers(objc.send(u64, native_event, "modifierFlags", .{})),
        .click_count = if (eventCarriesClickCount(event_type))
            @intCast(@min(objc.send(usize, native_event, "clickCount", .{}), std.math.maxInt(u8)))
        else
            0,
        .timestamp_ns = eventTimestamp(native_event),
    };
    const value: input.Event = switch (phase) {
        .down => .{ .pointer_down = pointer },
        .up => .{ .pointer_up = pointer },
        .move => .{ .pointer_move = pointer },
        .entered => .{ .pointer_enter = pointer },
        .exited => .{ .pointer_leave = pointer },
    };
    self.queue(viewWindow(view), .{ .input = value });
}

fn eventCarriesPressure(event_type: usize) bool {
    return switch (event_type) {
        types.EventType.left_mouse_down,
        types.EventType.left_mouse_up,
        types.EventType.right_mouse_down,
        types.EventType.right_mouse_up,
        types.EventType.left_mouse_dragged,
        types.EventType.right_mouse_dragged,
        types.EventType.tablet_point,
        types.EventType.other_mouse_down,
        types.EventType.other_mouse_up,
        types.EventType.other_mouse_dragged,
        => true,
        else => false,
    };
}

fn eventCarriesClickCount(event_type: usize) bool {
    return switch (event_type) {
        types.EventType.left_mouse_down,
        types.EventType.left_mouse_up,
        types.EventType.right_mouse_down,
        types.EventType.right_mouse_up,
        types.EventType.other_mouse_down,
        types.EventType.other_mouse_up,
        => true,
        else => false,
    };
}

fn scrollWheel(view: objc.Id, _: objc.Sel, native_event: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    const momentum = objc.send(usize, native_event, "momentumPhase", .{});
    const native_phase = objc.send(usize, native_event, "phase", .{});
    const value: input.Event = .{ .scroll = .{
        .position = eventPoint(view, native_event),
        .delta = .{
            .x = -@as(f32, @floatCast(objc.send(f64, native_event, "scrollingDeltaX", .{}))),
            .y = -@as(f32, @floatCast(objc.send(f64, native_event, "scrollingDeltaY", .{}))),
        },
        .precise = objc.send(bool, native_event, "hasPreciseScrollingDeltas", .{}),
        .phase = scrollPhase(native_phase, momentum),
        .modifiers = modifiers(objc.send(u64, native_event, "modifierFlags", .{})),
        .timestamp_ns = eventTimestamp(native_event),
    } };
    self.queue(viewWindow(view), .{ .input = value });
}

fn keyDown(view: objc.Id, _: objc.Sel, native_event: objc.Id) callconv(.c) void {
    emitKey(view, native_event, true);
    const flags = modifiers(objc.send(u64, native_event, "modifierFlags", .{}));
    if (!flags.command and !flags.control) objc.send(void, view, "interpretKeyEvents:", .{objc.arrayWithObject(native_event)});
}

fn keyUp(view: objc.Id, _: objc.Sel, native_event: objc.Id) callconv(.c) void {
    emitKey(view, native_event, false);
}

const SystemEditCommand = enum { undo, redo, cut, copy, paste, select_all };

fn systemEditKey(command: SystemEditCommand) input.KeyEvent {
    return .{
        .key = .{ .character = switch (command) {
            .undo, .redo => 'z',
            .cut => 'x',
            .copy => 'c',
            .paste => 'v',
            .select_all => 'a',
        } },
        .physical_code = 0,
        .modifiers = .{ .command = true, .shift = command == .redo },
    };
}

fn emitSystemEditCommand(view: objc.Id, command: SystemEditCommand) void {
    const self = viewContext(view) orelse return;
    self.queue(viewWindow(view), .{ .input = .{ .key_down = systemEditKey(command) } });
}

fn systemUndo(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    emitSystemEditCommand(view, .undo);
}
fn systemRedo(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    emitSystemEditCommand(view, .redo);
}
fn systemCut(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    emitSystemEditCommand(view, .cut);
}
fn systemCopy(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    emitSystemEditCommand(view, .copy);
}
fn systemPaste(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    emitSystemEditCommand(view, .paste);
}
fn systemSelectAll(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    emitSystemEditCommand(view, .select_all);
}

fn flagsChanged(view: objc.Id, _: objc.Sel, native_event: objc.Id) callconv(.c) void {
    const code: u16 = objc.send(u16, native_event, "keyCode", .{});
    const flags = objc.send(u64, native_event, "modifierFlags", .{});
    const mask = modifierMaskForKeyCode(code);
    emitKey(view, native_event, flags & mask != 0);
}

fn draggingEntered(view: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) usize {
    return @intFromBool(emitDrop(view, sender, .entered));
}

fn draggingUpdated(view: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) usize {
    return @intFromBool(emitDrop(view, sender, .updated));
}

fn draggingExited(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    self.queue(viewWindow(view), .{ .input = .file_drop_exited });
}

fn prepareForDragOperation(view: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) bool {
    const self = viewContext(view) orelse return false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(self.allocator);
    var text: ?[]const u8 = null;
    const promise_count = extractDropPayload(self, sender, &paths, &text, null) catch |err| {
        self.fail(err);
        return false;
    };
    return dropPayloadAccepted(paths.items, text, promise_count, self.promised_file_service.canAccept(promise_count));
}

fn performDragOperation(view: objc.Id, _: objc.Sel, sender: objc.Id) callconv(.c) bool {
    return emitDrop(view, sender, .performed);
}

/// Extract the representations that ZigUI can safely pass to a consumer. A
/// performed operation may additionally retain the native receivers in one
/// opaque batch; enter/update/prepare only probe the count so hover events do
/// not allocate a new batch on every callback.
fn extractDropPayload(
    self: *Context,
    sender: objc.Id,
    paths: *std.ArrayList([]const u8),
    text: *?[]const u8,
    promised_batch: ?*?handles.PromisedFileBatchId,
) Error!usize {
    const pasteboard = objc.send(objc.Id, sender, "draggingPasteboard", .{});
    const items = objc.send(objc.Id, pasteboard, "pasteboardItems", .{});
    const count = objc.send(usize, items, "count", .{});
    for (0..count) |index| {
        const item = objc.send(objc.Id, items, "objectAtIndex:", .{index});
        const url_string = objc.send(objc.Id, item, "stringForType:", .{objc.nsString("public.file-url")});
        if (url_string != null) {
            const url = objc.send(objc.Id, objc.class("NSURL"), "URLWithString:", .{url_string});
            const path = objc.send(objc.Id, url, "path", .{});
            if (path != null) {
                const value = objc.utf8(path);
                if (value.len > self.maximum_event_payload_bytes) return error.BudgetExceeded;
                if (value.len != 0) {
                    if (paths.items.len >= self.maximum_file_drop_paths) return error.BudgetExceeded;
                    try paths.append(self.allocator, value);
                }
            }
        }
        if (text.* == null) {
            for ([3][]const u8{ "public.url", "public.utf8-plain-text", "public.plain-text" }) |type_name| {
                if (objc.send(objc.Id, item, "stringForType:", .{objc.nsString(type_name)})) |value| {
                    const candidate = objc.utf8(value);
                    if (candidate.len != 0) {
                        if (candidate.len > self.maximum_event_payload_bytes) return error.BudgetExceeded;
                        text.* = candidate;
                        break;
                    }
                }
            }
        }
    }
    const promise_count = self.promised_file_service.promiseCount(pasteboard) catch |err| return err;
    if (promised_batch) |batch| {
        batch.* = try self.promised_file_service.capturePasteboard(pasteboard);
    }
    return promise_count;
}

fn emitDrop(view: objc.Id, sender: objc.Id, tag: DropTag) bool {
    const self = viewContext(view) orelse return false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(self.allocator);
    var text: ?[]const u8 = null;
    var promised_batch: ?handles.PromisedFileBatchId = null;
    const batch_target: ?*?handles.PromisedFileBatchId = if (tag == .performed) &promised_batch else null;
    const promise_count = extractDropPayload(self, sender, &paths, &text, batch_target) catch |err| {
        self.fail(err);
        return false;
    };
    const promises_available = if (promise_count == 0)
        true
    else if (tag == .performed)
        promised_batch != null and self.promised_file_service.canAcceptCaptured(promise_count)
    else
        self.promised_file_service.canAccept(promise_count);
    if (!dropPayloadAccepted(paths.items, text, promise_count, promises_available)) {
        if (promised_batch) |batch| self.promised_file_service.interface().releaseBatch(batch) catch {};
        return false;
    }
    const point = objc.send(types.Point, sender, "draggingLocation", .{});
    const local = objc.send(types.Point, view, "convertPoint:fromView:", .{ point, @as(objc.Id, null) });
    const accepted = self.queueDrop(
        viewWindow(view),
        tag,
        paths.items,
        text,
        promised_batch,
        promise_count,
        .{ .x = @floatCast(local.x), .y = @floatCast(local.y) },
    );
    if (!accepted) if (promised_batch) |batch| self.promised_file_service.interface().releaseBatch(batch) catch {};
    return accepted;
}

fn emitKey(view: objc.Id, native_event: objc.Id, down: bool) void {
    const self = viewContext(view) orelse return;
    const code: u16 = objc.send(u16, native_event, "keyCode", .{});
    const event_type = objc.send(usize, native_event, "type", .{});
    const carries_characters = event_type == types.EventType.key_down or event_type == types.EventType.key_up;
    const native = self.windows.getPtr(viewWindow(view).encode());
    const key_event: input.KeyEvent = .{
        .key = mapKey(native_event, code, carries_characters),
        .physical_code = code,
        .location = keyLocation(code),
        .modifiers = modifiers(objc.send(u64, native_event, "modifierFlags", .{})),
        .repeat = if (down and event_type == types.EventType.key_down) objc.send(bool, native_event, "isARepeat", .{}) else false,
        .composing = if (native) |window| window.marked_range.location != types.not_found else false,
        .timestamp_ns = eventTimestamp(native_event),
    };
    self.queue(viewWindow(view), .{ .input = if (down) .{ .key_down = key_event } else .{ .key_up = key_event } });
}

fn windowShouldClose(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) bool {
    const self = viewContext(view) orelse return false;
    if (self.windows.getPtr(viewWindow(view).encode())) |window| window.closing = true;
    self.queue(viewWindow(view), .close_requested);
    return false;
}

fn windowDidResize(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    const id = viewWindow(view);
    self.emitWindowMetrics(id);
    emitWindowMode(self, id);
    requestFrame(self, id) catch |err| self.fail(err);
}

fn windowDidEnterFullScreen(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    emitWindowMode(self, viewWindow(view));
}

fn windowDidExitFullScreen(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    emitWindowMode(self, viewWindow(view));
}

fn windowDidMiniaturize(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    emitWindowMode(self, viewWindow(view));
}

fn windowDidDeminiaturize(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    emitWindowMode(self, viewWindow(view));
}

fn windowDidMove(view: objc.Id, _: objc.Sel, notification: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    if (self.windows.getPtr(viewWindow(view).encode())) |native| native.display_number = windowDisplayNumber(native);
    const window = objc.send(objc.Id, notification, "object", .{});
    const frame = objc.send(types.Rect, window, "frame", .{});
    self.queue(viewWindow(view), .{ .moved = .{ .x = @floatCast(frame.origin.x), .y = @floatCast(frame.origin.y) } });
}

fn windowDidChangeScreen(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    if (self.windows.getPtr(viewWindow(view).encode())) |native| native.display_number = windowDisplayNumber(native);
}

fn windowDidBecomeKey(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    self.queue(viewWindow(view), .{ .focused = true });
}

fn windowDidResignKey(view: objc.Id, _: objc.Sel, _: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    self.queue(viewWindow(view), .{ .focused = false });
}

fn windowDidChangeOcclusion(view: objc.Id, _: objc.Sel, notification: objc.Id) callconv(.c) void {
    const self = viewContext(view) orelse return;
    const window = objc.send(objc.Id, notification, "object", .{});
    const state = objc.send(usize, window, "occlusionState", .{});
    self.queue(viewWindow(view), .{ .occluded = state & 2 == 0 });
}

fn hasMarkedText(view: objc.Id, _: objc.Sel) callconv(.c) bool {
    const self = viewContext(view) orelse return false;
    const window = self.windows.getPtr(viewWindow(view).encode()) orelse return false;
    return window.marked_range.location != types.not_found and window.marked_range.length != 0;
}

fn markedRange(view: objc.Id, _: objc.Sel) callconv(.c) types.Range {
    const self = viewContext(view) orelse return .{ .location = types.not_found, .length = 0 };
    const window = self.windows.getPtr(viewWindow(view).encode()) orelse return .{ .location = types.not_found, .length = 0 };
    return window.marked_range;
}

fn selectedRange(view: objc.Id, _: objc.Sel) callconv(.c) types.Range {
    const self = viewContext(view) orelse return .{ .location = types.not_found, .length = 0 };
    const window = self.windows.getPtr(viewWindow(view).encode()) orelse return .{ .location = types.not_found, .length = 0 };
    const selection = window.selection.normalized();
    const surrounding = window.surrounding_text orelse "";
    const location = utf8ToUtf16(surrounding, selection.start);
    const end = utf8ToUtf16(surrounding, selection.end);
    return .{ .location = location, .length = end - location };
}

fn setMarkedText(view: objc.Id, _: objc.Sel, value: objc.Id, selected: types.Range, replacement: types.Range) callconv(.c) void {
    const self = viewContext(view) orelse return;
    const id = viewWindow(view);
    const window = self.windows.getPtr(id.encode()) orelse return;
    const bytes = stringBytes(value);
    const selected_utf8: input.TextRange = .{
        .start = utf16ToUtf8(bytes, selected.location),
        .end = utf16ToUtf8(bytes, selected.location +| selected.length),
    };
    const surrounding = window.surrounding_text orelse "";
    const replacement_utf8 = rangeToUtf8(surrounding, replacement);
    const start_utf16 = if (replacement.location == types.not_found)
        utf8ToUtf16(surrounding, window.selection.normalized().start)
    else
        replacement.location;
    window.marked_range = .{ .location = start_utf16, .length = utf8ToUtf16(bytes, bytes.len) };
    self.queueIme(id, .{ .set_marked_text = .{
        .text = bytes,
        .selected_utf8 = selected_utf8,
        .replacement_utf8 = replacement_utf8,
    } }, bytes);
}

fn unmarkText(view: objc.Id, _: objc.Sel) callconv(.c) void {
    const self = viewContext(view) orelse return;
    const id = viewWindow(view);
    const window = self.windows.getPtr(id.encode()) orelse return;
    window.marked_range = .{ .location = types.not_found, .length = 0 };
    self.queue(id, .{ .input = .{ .ime = .unmark_text } });
}

fn validAttributesForMarkedText(_: objc.Id, _: objc.Sel) callconv(.c) objc.Id {
    return objc.send(objc.Id, objc.class("NSArray"), "array", .{});
}

fn attributedSubstring(view: objc.Id, _: objc.Sel, proposed: types.Range, actual: ?*types.Range) callconv(.c) objc.Id {
    const self = viewContext(view) orelse return null;
    const window = self.windows.getPtr(viewWindow(view).encode()) orelse return null;
    if (proposed.location == types.not_found) return null;
    const surrounding = window.surrounding_text orelse "";
    const start = utf16ToUtf8(surrounding, proposed.location);
    const end = utf16ToUtf8(surrounding, proposed.location +| proposed.length);
    if (actual) |range| range.* = .{ .location = proposed.location, .length = utf8ToUtf16(surrounding[start..end], end - start) };
    const string = objc.nsString(surrounding[start..end]);
    return objc.autorelease(objc.send(objc.Id, objc.send(objc.Id, objc.class("NSAttributedString"), "alloc", .{}), "initWithString:", .{string}));
}

fn insertText(view: objc.Id, _: objc.Sel, value: objc.Id, replacement: types.Range) callconv(.c) void {
    const self = viewContext(view) orelse return;
    const id = viewWindow(view);
    const window = self.windows.getPtr(id.encode()) orelse return;
    const bytes = stringBytes(value);
    const replacement_utf8 = rangeToUtf8(window.surrounding_text orelse "", replacement);
    window.marked_range = .{ .location = types.not_found, .length = 0 };
    self.queueIme(id, .{ .commit_text = .{ .text = bytes, .replacement_utf8 = replacement_utf8 } }, bytes);
}

fn characterIndexForPoint(_: objc.Id, _: objc.Sel, _: types.Point) callconv(.c) usize {
    return types.not_found;
}

fn firstRectForCharacterRange(view: objc.Id, _: objc.Sel, requested: types.Range, actual: ?*types.Range) callconv(.c) types.Rect {
    const self = viewContext(view) orelse return .{};
    const window = self.windows.getPtr(viewWindow(view).encode()) orelse return .{};
    if (actual) |range| range.* = requested;
    const source = window.candidate_rect;
    var rect: types.Rect = .{
        .origin = .{ .x = source.origin.x, .y = source.origin.y },
        .size = .{ .width = @max(source.size.width, 1), .height = @max(source.size.height, 1) },
    };
    rect = objc.send(types.Rect, window.view, "convertRect:toView:", .{ rect, @as(objc.Id, null) });
    return objc.send(types.Rect, window.ns_window, "convertRectToScreen:", .{rect});
}

fn doCommandBySelector(_: objc.Id, _: objc.Sel, _: objc.Sel) callconv(.c) void {}

fn accessibilityFocusedUIElement(view: objc.Id, _: objc.Sel) callconv(.c) objc.Id {
    if (comptime config.accessibility_enabled) {
        const adapter = (objc.getIvar(?*anyopaque, view, "_ziguiAccessibility") orelse null) orelse return null;
        return macos_a11y.focusedElement(adapter, viewWindow(view));
    }
    return null;
}

fn eventPoint(view: objc.Id, native_event: objc.Id) geometry.Point {
    const point = objc.send(types.Point, native_event, "locationInWindow", .{});
    const local = objc.send(types.Point, view, "convertPoint:fromView:", .{ point, @as(objc.Id, null) });
    return .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
}

fn eventTimestamp(native_event: objc.Id) u64 {
    const seconds = objc.send(f64, native_event, "timestamp", .{});
    if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
    return @intFromFloat(@min(seconds * 1_000_000_000.0, @as(f64, @floatFromInt(std.math.maxInt(u64)))));
}

fn modifiers(flags: u64) input.Modifiers {
    return .{
        .shift = flags & types.Modifier.shift != 0,
        .control = flags & types.Modifier.control != 0,
        .alt = flags & types.Modifier.option != 0,
        .command = flags & types.Modifier.command != 0,
        .caps_lock = flags & types.Modifier.caps_lock != 0,
        .function = flags & types.Modifier.function != 0,
    };
}

fn modifierMaskForKeyCode(code: u16) u64 {
    return switch (code) {
        56, 60 => types.Modifier.shift,
        59, 62 => types.Modifier.control,
        58, 61 => types.Modifier.option,
        55, 54 => types.Modifier.command,
        57 => types.Modifier.caps_lock,
        63 => types.Modifier.function,
        else => 0,
    };
}

fn keyLocation(code: u16) input.KeyLocation {
    return switch (code) {
        60, 62, 61, 54 => .right,
        56, 59, 58, 55 => .left,
        65, 67, 69, 71, 75, 76, 78, 81, 82...92 => .numpad,
        else => .standard,
    };
}

fn mapKey(native_event: objc.Id, code: u16, carries_characters: bool) input.Key {
    return switch (code) {
        36, 76 => .enter,
        53 => .escape,
        48 => .tab,
        51 => .backspace,
        117 => .delete,
        114 => .insert,
        115 => .home,
        119 => .end,
        116 => .page_up,
        121 => .page_down,
        123 => .arrow_left,
        124 => .arrow_right,
        125 => .arrow_down,
        126 => .arrow_up,
        49 => .space,
        122 => .{ .function = 1 },
        120 => .{ .function = 2 },
        99 => .{ .function = 3 },
        118 => .{ .function = 4 },
        96 => .{ .function = 5 },
        97 => .{ .function = 6 },
        98 => .{ .function = 7 },
        100 => .{ .function = 8 },
        101 => .{ .function = 9 },
        109 => .{ .function = 10 },
        103 => .{ .function = 11 },
        111 => .{ .function = 12 },
        else => if (carries_characters) characterKey(native_event) orelse .{ .native = code } else .{ .native = code },
    };
}

fn characterKey(native_event: objc.Id) ?input.Key {
    const string = objc.send(objc.Id, native_event, "charactersIgnoringModifiers", .{});
    const bytes = objc.utf8(string);
    var iterator: unicode.Iterator = .{ .bytes = bytes };
    const scalar = iterator.next() catch return null;
    return if (scalar) |value| .{ .character = value.value } else null;
}

fn mapMouseButton(native_event: objc.Id) input.MouseButton {
    return switch (objc.send(usize, native_event, "buttonNumber", .{})) {
        0 => .primary,
        1 => .secondary,
        2 => .middle,
        3 => .back,
        4 => .forward,
        else => .other,
    };
}

fn scrollPhase(native: usize, momentum: usize) input.ScrollPhase {
    if (momentum & 1 != 0) return .momentum_began;
    if (momentum & (8 | 16) != 0) return .momentum_ended;
    if (native & 1 != 0) return .began;
    if (native & 4 != 0) return .changed;
    if (native & 8 != 0) return .ended;
    if (native & 16 != 0) return .cancelled;
    return .none;
}

fn appearance(view: objc.Id) api.Appearance {
    const effective = objc.send(objc.Id, view, "effectiveAppearance", .{});
    const appearance_values = [_]objc.Id{
        objc.nsString("NSAppearanceNameDarkAqua"),
        objc.nsString("NSAppearanceNameAqua"),
    };
    const names = objc.arrayWithObjects(appearance_values[0..]);
    const best = objc.send(objc.Id, effective, "bestMatchFromAppearancesWithNames:", .{names});
    const dark = std.mem.eql(u8, objc.utf8(best), "NSAppearanceNameDarkAqua");
    const workspace = objc.send(objc.Id, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const high_contrast = objc.send(bool, workspace, "accessibilityDisplayShouldIncreaseContrast", .{});
    return if (dark) (if (high_contrast) .high_contrast_dark else .dark) else (if (high_contrast) .high_contrast_light else .light);
}

fn stringBytes(value: objc.Id) []const u8 {
    if (value == null) return "";
    const selected = if (objc.send(bool, value, "respondsToSelector:", .{objc.selector("string")})) objc.send(objc.Id, value, "string", .{}) else value;
    return objc.utf8(selected);
}

fn utf8ToUtf16(bytes: []const u8, byte_offset: usize) usize {
    const limit = @min(byte_offset, bytes.len);
    var iterator: unicode.Iterator = .{ .bytes = bytes };
    var units: usize = 0;
    while (iterator.next() catch null) |scalar| {
        if (scalar.start >= limit) break;
        units += if (scalar.value > 0xffff) 2 else 1;
    }
    return units;
}

fn utf16ToUtf8(bytes: []const u8, utf16_offset: usize) usize {
    var iterator: unicode.Iterator = .{ .bytes = bytes };
    var units: usize = 0;
    while (iterator.next() catch null) |scalar| {
        const width: usize = if (scalar.value > 0xffff) 2 else 1;
        if (units + width > utf16_offset) return scalar.start;
        units += width;
        if (units == utf16_offset) return scalar.end;
    }
    return bytes.len;
}

fn rangeToUtf8(bytes: []const u8, range: types.Range) ?input.TextRange {
    if (range.location == types.not_found) return null;
    return .{
        .start = utf16ToUtf8(bytes, range.location),
        .end = utf16ToUtf8(bytes, range.location +| range.length),
    };
}

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidHandle => error.InvalidHandle,
        error.InvalidScaleFactor => error.InvalidScaleFactor,
        else => error.PlatformFailure,
    };
}

test "macOS print operation delegate exposes the PDFKit completion callback" {
    if (comptime config.compiled_platform != .macos) return;
    const delegate_class = try registerPrintDelegateClass();
    const delegate = objc.send(objc.Id, objc.send(objc.Id, delegate_class, "alloc", .{}), "init", .{}) orelse return error.PlatformFailure;
    defer objc.release(delegate);
    try std.testing.expect(objc.send(bool, delegate, "respondsToSelector:", .{
        objc.selector("printOperationDidRun:success:contextInfo:"),
    }));
}

test "macOS print window selection uses a deterministic visible tracked fallback" {
    var first: u8 = 0;
    var second: u8 = 0;
    const first_window: objc.Id = @ptrCast(&first);
    const second_window: objc.Id = @ptrCast(&second);
    const candidates = [_]PrintWindowCandidate{
        .{ .native = second_window, .order = 42, .visible = true, .closing = false },
        .{ .native = first_window, .order = 7, .visible = true, .closing = false },
        .{ .native = @as(objc.Id, null), .order = 1, .visible = true, .closing = false },
        .{ .native = second_window, .order = 3, .visible = false, .closing = false },
        .{ .native = first_window, .order = 2, .visible = true, .closing = true },
    };
    const tracked = chooseTrackedPrintWindow(&candidates);
    try std.testing.expectEqual(first_window, tracked);
    try std.testing.expectEqual(first_window, preferredPrintWindow(null, null, tracked));
    try std.testing.expectEqual(second_window, preferredPrintWindow(null, second_window, tracked));
    try std.testing.expectEqual(first_window, preferredPrintWindow(first_window, second_window, tracked));

    const unusable = [_]PrintWindowCandidate{
        .{ .native = second_window, .order = 1, .visible = false, .closing = false },
        .{ .native = first_window, .order = 2, .visible = true, .closing = true },
        .{ .native = @as(objc.Id, null), .order = 3, .visible = true, .closing = false },
    };
    try std.testing.expect(chooseTrackedPrintWindow(&unusable) == null);
    try std.testing.expect(preferredPrintWindow(null, null, chooseTrackedPrintWindow(&unusable)) == null);
}

test "macOS system edit selectors preserve framework shortcut routing" {
    const paste = systemEditKey(.paste);
    try std.testing.expectEqual(input.Key{ .character = 'v' }, paste.key);
    try std.testing.expect(paste.modifiers.command);
    try std.testing.expect(!paste.modifiers.shift);

    const redo = systemEditKey(.redo);
    try std.testing.expectEqual(input.Key{ .character = 'z' }, redo.key);
    try std.testing.expect(redo.modifiers.command);
    try std.testing.expect(redo.modifiers.shift);
}

test "macOS NSNotFound replacement range preserves the client selection" {
    try std.testing.expectEqual(@as(usize, @intCast(std.math.maxInt(isize))), types.not_found);
    try std.testing.expect(rangeToUtf8("## Heading", .{ .location = types.not_found, .length = 0 }) == null);
}

test "macOS resolved window mode gives native state precedence" {
    try std.testing.expectEqual(api.WindowMode.normal, modeFromNativeFlags(false, false, false));
    try std.testing.expectEqual(api.WindowMode.maximized, modeFromNativeFlags(false, false, true));
    try std.testing.expectEqual(api.WindowMode.fullscreen, modeFromNativeFlags(false, true, true));
    // AppKit can report a miniaturized window while its previous fullscreen
    // or zoom state is still present; minimized is the user-visible state.
    try std.testing.expectEqual(api.WindowMode.minimized, modeFromNativeFlags(true, true, true));
}

test "macOS menu ownership preserves explicit Quit and Window contracts" {
    const explicit = [_]api.MenuItem{
        .{ .application = .{ .items = &.{.{ .system_action = .{ .label = "Quit Example", .action = .quit_application } }} } },
        .{ .submenu = .{ .label = "Window", .items = &.{
            .{ .system_action = .{ .label = "Minimize", .action = .minimize_window } },
            .{ .system_action = .{ .label = "Zoom", .action = .zoom_window } },
        } } },
    };
    const explicit_ownership = inspectMenuOwnership(&explicit);
    try std.testing.expect(explicit_ownership.explicit_quit);
    try std.testing.expect(explicit_ownership.explicit_window);

    const synthesized = [_]api.MenuItem{.{ .submenu = .{ .label = "File", .items = &.{} } }};
    const synthesized_ownership = inspectMenuOwnership(&synthesized);
    try std.testing.expect(!synthesized_ownership.explicit_quit);
    try std.testing.expect(!synthesized_ownership.explicit_window);
}

test "macOS native media status preserves AVPlayerItem readiness" {
    try std.testing.expectEqual(api.NativeMediaStatus.loading, nativeMediaStatusFromRaw(0));
    try std.testing.expectEqual(api.NativeMediaStatus.ready, nativeMediaStatusFromRaw(1));
    try std.testing.expectEqual(api.NativeMediaStatus.failed, nativeMediaStatusFromRaw(2));
    try std.testing.expectEqual(api.NativeMediaStatus.loading, nativeMediaStatusFromRaw(-1));
    try std.testing.expectEqual(api.NativeMediaStatus.loading, nativeMediaStatusFromRaw(99));
}

test "macOS native media readiness is the presented-frame signal" {
    try std.testing.expect(!nativeMediaLayerHasPresentedFrame(null));
}

test "macOS drag acceptance requires a recognized payload" {
    try std.testing.expect(!dropPayloadRecognized(&.{}, null));
    try std.testing.expect(!dropPayloadRecognized(&.{}, " \n\t"));
    try std.testing.expect(!dropPayloadRecognized(&.{""}, null));
    try std.testing.expect(dropPayloadRecognized(&.{"/tmp/item.txt"}, null));
    try std.testing.expect(dropPayloadRecognized(&.{}, "https://example.com"));
}

test "macOS promised-file detection never advertises partial drag acceptance" {
    try std.testing.expect(!dropPayloadAccepted(&.{}, null, 0, false));
    try std.testing.expect(dropPayloadAccepted(&.{}, null, 1, true));
    try std.testing.expect(dropPayloadAccepted(&.{"/tmp/item.txt"}, null, 1, true));
    try std.testing.expect(dropPayloadAccepted(&.{}, "https://example.com", 1, true));
    try std.testing.expect(!dropPayloadAccepted(&.{"/tmp/item.txt"}, null, 1, false));
    try std.testing.expect(dropPayloadAccepted(&.{"/tmp/item.txt"}, null, 0, false));
}

test "macOS application-open payloads target logical window center" {
    try std.testing.expectEqual(geometry.Point{ .x = 400, .y = 300 }, logicalCenter(.{ .width = 800, .height = 600 }));
    try std.testing.expectEqual(geometry.Point{ .x = 512, .y = 384 }, logicalCenter(.{ .width = 1024, .height = 768 }));
}

test "macOS pending application-open payload retries without duplicate delivery" {
    if (comptime config.compiled_platform != .macos) return;
    var context: Context = undefined;
    context.allocator = std.testing.allocator;
    context.application = null;
    context.events = .empty;
    context.event_cursor = 0;
    context.maximum_events = 0;
    context.maximum_event_queue_bytes = 4096;
    context.maximum_file_drop_paths = 4;
    context.maximum_event_payload_bytes = 1024;
    context.pending_payload_bytes = 0;
    context.pending_open_paths = .empty;
    context.pending_open_text = .empty;
    context.pending_open_payload_bytes = 0;
    context.quit = false;
    context.failure = null;
    context.windows = std.AutoHashMap(u64, NativeWindow).init(context.allocator);
    defer context.windows.deinit();
    defer {
        for (context.pending_open_paths.items) |path| context.allocator.free(path);
        context.pending_open_paths.deinit(context.allocator);
        context.pending_open_text.deinit(context.allocator);
        for (context.events.items) |*pending| pending.deinit(context.allocator);
        context.events.deinit(context.allocator);
    }

    const window: handles.WindowId = .{ .index = 7, .generation = 1 };
    try context.windows.put(window.encode(), .{
        .ns_window = null,
        .view = null,
        .layer = null,
        .logical_size = .{ .width = 800, .height = 600 },
        .scale_factor = try geometry.ScaleFactor.init(1),
        .visible = true,
    });
    const path = try context.allocator.dupe(u8, "/tmp/pre-window-open.txt");
    try context.pending_open_paths.append(context.allocator, path);
    context.pending_open_payload_bytes = try event_memory.ownedPayloadBytes(null, context.pending_open_paths.items);

    try std.testing.expect(!flushPendingApplicationOpen(&context, window));
    try std.testing.expectEqual(@as(usize, 1), context.pending_open_paths.items.len);
    try std.testing.expectEqual(@as(usize, 0), context.events.items.len);
    try std.testing.expect(!context.quit);

    context.maximum_events = 1;
    retryPendingApplicationOpen(&context);
    try std.testing.expectEqual(@as(usize, 0), context.pending_open_paths.items.len);
    try std.testing.expectEqual(@as(usize, 0), context.pending_open_payload_bytes);
    try std.testing.expectEqual(@as(usize, 1), context.events.items.len);
    switch (context.events.items[0].event) {
        .input => |event| switch (event) {
            .file_drop_performed => |drop| {
                try std.testing.expectEqual(geometry.Point{ .x = 400, .y = 300 }, drop.position);
                try std.testing.expectEqualStrings("/tmp/pre-window-open.txt", drop.paths[0]);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!flushPendingApplicationOpen(&context, window));
    try std.testing.expectEqual(@as(usize, 1), context.events.items.len);
}

test "macOS display-link retargeting follows the window display" {
    try std.testing.expect(!displayLinkNeedsTarget(0, 0));
    try std.testing.expect(!displayLinkNeedsTarget(42, 0));
    try std.testing.expect(!displayLinkNeedsTarget(42, 42));
    try std.testing.expect(displayLinkNeedsTarget(42, 84));
    if (comptime config.compiled_platform != .macos) return;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    var link: CVDisplayLinkRef = null;
    if (CVDisplayLinkCreateWithActiveCGDisplays(&link) != 0 or link == null) return;
    defer CVDisplayLinkRelease(link);
    const screen = objc.send(objc.Id, objc.class("NSScreen"), "mainScreen", .{});
    const description = objc.send(objc.Id, screen, "deviceDescription", .{});
    const number = objc.send(objc.Id, description, "objectForKey:", .{objc.nsString("NSScreenNumber")});
    const target = objc.send(u32, number, "unsignedIntValue", .{});
    if (target == 0) return;
    try std.testing.expectEqual(@as(i32, 0), CVDisplayLinkSetCurrentCGDisplay(link, target));
    try std.testing.expectEqual(target, CVDisplayLinkGetCurrentCGDisplay(link));
}

test "macOS native menu shortcuts preserve keys and modifiers" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("k", try menuShortcutEquivalent(.{
        .key = .{ .character = 'k' },
        .modifiers = .{ .command = true, .shift = true },
    }, &buffer));
    try std.testing.expectEqual(types.Modifier.command | types.Modifier.shift, menuShortcutModifierMask(.{ .command = true, .shift = true }));
    try std.testing.expectEqualStrings("\xef\x9c\x80", try menuShortcutEquivalent(.{ .key = .arrow_up }, &buffer));
    try std.testing.expectError(error.InvalidConfiguration, menuShortcutEquivalent(.{ .key = .{ .function = 0 } }, &buffer));
}

test "macOS Metal host redraws instead of stretching during live resize" {
    if (comptime config.compiled_platform != .macos) return;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const frame: types.Rect = .{ .size = .{ .width = 800, .height = 600 } };
    const view = objc.send(objc.Id, objc.send(objc.Id, objc.class("NSView"), "alloc", .{}), "initWithFrame:", .{frame}) orelse return error.PlatformFailure;
    defer objc.release(view);
    const layer = objc.send(objc.Id, objc.class("CAMetalLayer"), "layer", .{}) orelse return error.SurfaceUnavailable;
    configureMetalView(view, layer);
    try std.testing.expectEqual(layer_contents_redraw_during_view_resize, objc.send(usize, view, "layerContentsRedrawPolicy", .{}));
    try std.testing.expectEqual(layer_contents_placement_top_left, objc.send(usize, view, "layerContentsPlacement", .{}));
    try std.testing.expect(objc.send(bool, layer, "needsDisplayOnBoundsChange", .{}));
    try std.testing.expectEqual(layer_autoresizing_width_and_height, objc.send(u32, layer, "autoresizingMask", .{}));
    objc.send(void, view, "setLayer:", .{@as(objc.Id, null)});
}

test "macOS display-link frames post an AppKit wake event" {
    if (comptime config.compiled_platform != .macos) return;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const application = objc.send(objc.Id, objc.class("NSApplication"), "sharedApplication", .{});
    const before = objc.send(objc.Id, application, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
        types.any_event_mask,
        objc.send(objc.Id, objc.class("NSDate"), "distantPast", .{}),
        objc.nsString("kCFRunLoopDefaultMode"),
        true,
    });
    _ = before;

    var context: Context = undefined;
    context.application = application;
    postWakeEvent(&context);
    const event = objc.send(objc.Id, application, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
        types.any_event_mask,
        objc.send(objc.Id, objc.class("NSDate"), "distantPast", .{}),
        objc.nsString("kCFRunLoopDefaultMode"),
        true,
    });
    try std.testing.expect(event != null);
}

test "display-link callback retain is balanced when teardown wins" {
    var state: DisplayLinkState = .{
        .allocator = std.testing.allocator,
        .context = std.atomic.Value(usize).init(0),
    };
    try std.testing.expect(!retainDisplayLinkCallback(&state));
    try std.testing.expectEqual(@as(usize, 1), state.references.load(.acquire));
}

test "macOS live resize dispatches only outside an existing app callback" {
    var context: Context = undefined;
    context.active_sink = .{
        .context = @ptrCast(&context),
        .callback = struct {
            fn ignore(_: *anyopaque, _: handles.WindowId, _: *const api.WindowEvent) void {}
        }.ignore,
    };
    context.sink_dispatch_depth = 0;
    try std.testing.expect(liveResizeSink(&context) != null);
    context.sink_dispatch_depth = 1;
    try std.testing.expect(liveResizeSink(&context) == null);
    context.active_sink = null;
    context.sink_dispatch_depth = 0;
    try std.testing.expect(liveResizeSink(&context) == null);
}
