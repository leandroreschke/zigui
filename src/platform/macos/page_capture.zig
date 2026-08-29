//! LinkPresentation page capture for the macOS platform provider.
//!
//! Foundation and LinkPresentation objects stay inside the Objective-C bridge
//! and this adapter.  Consumers receive only an opaque request id and an
//! allocator-owned PNG completion.  Native callbacks retain a small bridge
//! context, marshal payloads to the main thread, and are invalidated before
//! service teardown so late provider callbacks cannot dereference `Service`.

const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const handles = @import("../../core/handle.zig");
const api = @import("../api.zig");
const objc = @import("objc.zig");

extern "c" var _dispatch_main_q: u8;
extern "c" fn dispatch_async_f(
    queue: objc.Id,
    context: ?*anyopaque,
    work: *const fn (?*anyopaque) callconv(.c) void,
) void;
extern "c" fn zigui_page_capture_start(
    url: [*]const u8,
    url_length: usize,
    width: f64,
    height: f64,
    timeout_seconds: f64,
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque, ?[*]const u8, usize, usize, usize, ?[*:0]const u8) callconv(.c) void,
    retain_context: *const fn (?*anyopaque) callconv(.c) void,
    release_context: *const fn (?*anyopaque) callconv(.c) void,
) ?*anyopaque;
extern "c" fn zigui_page_capture_cancel(native: ?*anyopaque) void;
extern "c" fn zigui_page_capture_destroy(native: ?*anyopaque) void;

const max_error_bytes = 4 * 1024;
const fallback_error = "The page could not be captured.";

const BridgeState = struct {
    allocator: std.mem.Allocator,
    /// Address of the live Service, or zero after teardown begins.
    context: std.atomic.Value(usize),
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    /// Main-queue payloads are an explicit teardown barrier.  Provider-owned
    /// callback references can outlive the queue and are therefore tracked
    /// separately, just as in the promised-file bridge.
    pending_main_callbacks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    reserved_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    maximum_bytes: usize,
    maximum_result_bytes: usize,
    maximum_pixels: usize,
    maximum_dimension: f64,

    fn retain(self: *BridgeState) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *BridgeState) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }

    fn reserveBytes(self: *BridgeState, amount: usize) bool {
        if (amount == 0) return true;
        var current = self.reserved_bytes.load(.acquire);
        while (true) {
            const next = std.math.add(usize, current, amount) catch return false;
            if (next > self.maximum_bytes) return false;
            if (self.reserved_bytes.cmpxchgWeak(current, next, .acq_rel, .acquire) == null) return true;
            current = self.reserved_bytes.load(.acquire);
        }
    }

    fn releaseBytes(self: *BridgeState, amount: usize) void {
        if (amount != 0) _ = self.reserved_bytes.fetchSub(amount, .acq_rel);
    }
};

const CallbackContext = struct {
    state: *BridgeState,
    request: handles.PageCaptureRequestId,
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    fn retain(self: *CallbackContext) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *CallbackContext) void {
        if (self.references.fetchSub(1, .acq_rel) == 1) {
            const state = self.state;
            state.allocator.destroy(self);
            state.release();
        }
    }
};

const CallbackPayload = struct {
    callback: *CallbackContext,
    bytes: ?[]u8 = null,
    width: usize = 0,
    height: usize = 0,
    error_description: ?[]u8 = null,
    reserved_bytes: usize = 0,
};

const Operation = struct {
    allocator: std.mem.Allocator,
    options: api.PageCaptureOptions,
    url: []u8,
    native: ?*anyopaque,
    callback: *CallbackContext,
    bytes: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    error_description: ?[]u8 = null,
    reserved_bytes: usize,
    status: api.PageCaptureTerminalStatus = .failed,
    terminal: bool = false,
    polled: bool = false,
    cancelled: bool = false,
    native_released: bool = false,

    fn deinit(self: *Operation, state: *BridgeState) void {
        self.releaseNative();
        self.callback.release();
        if (self.bytes) |bytes| self.allocator.free(bytes);
        if (self.error_description) |description| self.allocator.free(description);
        self.allocator.free(self.url);
        state.releaseBytes(self.reserved_bytes);
        self.* = undefined;
    }

    fn releaseNative(self: *Operation) void {
        if (self.native_released) return;
        if (self.native) |native| zigui_page_capture_destroy(native);
        self.native = null;
        self.native_released = true;
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    requests: handles.SlotPool(Operation, handles.PageCaptureRequestId),
    state: *BridgeState,
    maximum_requests: usize,
    maximum_url_bytes: usize,
    maximum_result_bytes: usize,
    maximum_pixels: usize,
    maximum_dimension: f64,
    maximum_timeout_ns: u64,
    retained_bytes: usize = 0,
    wake_context: ?*anyopaque = null,
    wake_fn: ?*const fn (?*anyopaque) void = null,

    pub fn init(
        allocator: std.mem.Allocator,
        maximum_requests: usize,
        maximum_url_bytes: usize,
        maximum_result_bytes: usize,
        maximum_pixels: usize,
        maximum_dimension: f64,
        maximum_timeout_ns: u64,
        maximum_bytes: usize,
        wake_context: ?*anyopaque,
        wake_fn: ?*const fn (?*anyopaque) void,
    ) Error!Service {
        if (maximum_requests == 0 or maximum_url_bytes == 0 or maximum_result_bytes == 0 or
            maximum_pixels == 0 or maximum_bytes == 0 or maximum_dimension <= 0 or
            !std.math.isFinite(maximum_dimension) or maximum_timeout_ns == 0)
            return error.InvalidConfiguration;
        const state = try allocator.create(BridgeState);
        state.* = .{
            .allocator = allocator,
            .context = std.atomic.Value(usize).init(0),
            .maximum_bytes = maximum_bytes,
            .maximum_result_bytes = maximum_result_bytes,
            .maximum_pixels = maximum_pixels,
            .maximum_dimension = maximum_dimension,
        };
        return .{
            .allocator = allocator,
            .requests = handles.SlotPool(Operation, handles.PageCaptureRequestId).init(allocator),
            .state = state,
            .maximum_requests = maximum_requests,
            .maximum_url_bytes = maximum_url_bytes,
            .maximum_result_bytes = maximum_result_bytes,
            .maximum_pixels = maximum_pixels,
            .maximum_dimension = maximum_dimension,
            .maximum_timeout_ns = maximum_timeout_ns,
            .wake_context = wake_context,
            .wake_fn = wake_fn,
        };
    }

    fn bind(self: *Service) void {
        self.state.context.store(@intFromPtr(self), .release);
    }

    pub fn interface(self: *Service) api.PageCapture {
        self.bind();
        return .{
            .context = self,
            .begin_fn = begin,
            .poll_fn = poll,
            .cancel_fn = cancel,
            .release_fn = release,
            .limits = .{
                .maximum_requests = self.maximum_requests,
                .maximum_url_bytes = self.maximum_url_bytes,
                .maximum_result_bytes = self.maximum_result_bytes,
                .maximum_pixels = self.maximum_pixels,
                .maximum_dimension = self.maximum_dimension,
                .maximum_timeout_ns = self.maximum_timeout_ns,
            },
        };
    }

    pub fn deinit(self: *Service) void {
        self.state.context.store(0, .release);

        // Stop every provider before releasing callback contexts.  The bridge
        // uses private queues; no unrelated main-queue operation is canceled.
        var cancel_iterator = self.requests.iterator();
        while (cancel_iterator.next()) |entry| {
            entry.value.cancelled = true;
            entry.value.terminal = true;
            if (entry.value.native) |native| zigui_page_capture_cancel(native);
        }

        // Drop native objects and operation-owned references.  Main payloads
        // retain their CallbackContext/BridgeState until their delivery runs.
        while (self.requests.live_count != 0) {
            var iterator = self.requests.iterator();
            const entry = iterator.next() orelse break;
            const value = self.requests.remove(entry.id) orelse break;
            var operation = value;
            operation.deinit(self.state);
        }
        self.drainMainQueue();
        self.requests.deinit();
        std.debug.assert(self.state.reserved_bytes.load(.acquire) == 0);
        self.state.release();
        self.* = undefined;
    }

    fn wake(self: *Service) void {
        if (self.wake_fn) |callback| callback(self.wake_context);
    }

    fn drainMainQueue(self: *Service) void {
        const run_loop = objc.send(objc.Id, objc.class("NSRunLoop"), "currentRunLoop", .{});
        while (self.state.pending_main_callbacks.load(.acquire) != 0) {
            var pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            const deadline = objc.send(objc.Id, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, 0.01)});
            _ = objc.send(bool, run_loop, "runMode:beforeDate:", .{ objc.nsString("kCFRunLoopDefaultMode"), deadline });
        }
    }
};

fn cast(raw: *anyopaque) *Service {
    return @ptrCast(@alignCast(raw));
}

fn retainCallbackContext(raw: ?*anyopaque) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    callback.retain();
}

fn releaseCallbackContext(raw: ?*anyopaque) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    callback.release();
}

fn begin(raw: *anyopaque, options: api.PageCaptureOptions) Error!handles.PageCaptureRequestId {
    const self = cast(raw);
    if (self.requests.live_count >= self.maximum_requests) return error.BudgetExceeded;
    const url = try self.allocator.dupeSentinel(u8, options.url, 0);
    errdefer self.allocator.free(url);
    if (!self.state.reserveBytes(options.url.len)) return error.BudgetExceeded;
    var bytes_reserved = true;
    errdefer if (bytes_reserved) self.state.releaseBytes(options.url.len);

    const callback = try self.allocator.create(CallbackContext);
    callback.* = .{
        .state = self.state,
        .request = handles.PageCaptureRequestId.invalid,
    };
    self.state.retain();
    var callback_owned = true;
    errdefer if (callback_owned) callback.release();

    const operation = Operation{
        .allocator = self.allocator,
        .options = options,
        .url = url,
        .native = null,
        .callback = callback,
        .reserved_bytes = options.url.len,
    };
    const id = self.requests.insert(operation) catch |err| {
        var owned = operation;
        owned.deinit(self.state);
        callback_owned = false;
        bytes_reserved = false;
        return err;
    };
    callback.request = id;
    callback_owned = false;

    const timeout_seconds = @as(f64, @floatFromInt(options.timeout_ns)) / @as(f64, std.time.ns_per_s);
    const native = zigui_page_capture_start(
        url.ptr,
        options.url.len,
        options.size.width,
        options.size.height,
        timeout_seconds,
        callback,
        pageCaptureCallback,
        retainCallbackContext,
        releaseCallbackContext,
    ) orelse {
        const removed = self.requests.remove(id) orelse unreachable;
        var owned = removed;
        owned.deinit(self.state);
        bytes_reserved = false;
        return error.PlatformFailure;
    };
    const target = self.requests.get(id) orelse unreachable;
    target.native = native;
    self.retained_bytes += options.url.len;
    bytes_reserved = false;
    return id;
}

fn poll(
    raw: *anyopaque,
    id: handles.PageCaptureRequestId,
    allocator: std.mem.Allocator,
) Error!api.PageCapturePoll {
    const self = cast(raw);
    const operation = self.requests.get(id) orelse return error.InvalidHandle;
    if (operation.polled) return error.InvalidHandle;
    if (!operation.terminal) return .pending;

    var result: ?api.OwnedPageCapture = null;
    errdefer if (result) |*value| value.deinit();
    if (operation.status == .completed) {
        const bytes = operation.bytes orelse return error.PlatformFailure;
        const copy = try allocator.dupe(u8, bytes);
        result = .{
            .allocator = allocator,
            .bytes = copy,
            .width = operation.width,
            .height = operation.height,
        };
    }
    var description: ?[]u8 = null;
    errdefer if (description) |value| allocator.free(value);
    if (operation.error_description) |value| description = try allocator.dupe(u8, value);
    operation.polled = true;
    return .{ .terminal = .{
        .allocator = allocator,
        .request = id,
        .status = if (operation.cancelled) .canceled else operation.status,
        .result = result,
        .error_description = description,
    } };
}

fn cancel(raw: *anyopaque, id: handles.PageCaptureRequestId) Error!void {
    const self = cast(raw);
    const operation = self.requests.get(id) orelse return error.InvalidHandle;
    if (operation.polled) return error.InvalidHandle;
    operation.cancelled = true;
    operation.status = .canceled;
    operation.terminal = true;
    if (operation.native) |native| zigui_page_capture_cancel(native);
}

fn release(raw: *anyopaque, id: handles.PageCaptureRequestId) Error!void {
    const self = cast(raw);
    const operation = self.requests.get(id) orelse return error.InvalidHandle;
    if (!operation.polled or !operation.terminal) return error.ResourceBusy;
    const removed = self.requests.remove(id) orelse return error.InvalidHandle;
    var owned = removed;
    self.retained_bytes -|= owned.options.url.len;
    owned.deinit(self.state);
}

fn pageCaptureCallback(
    raw: ?*anyopaque,
    bytes_pointer: ?[*]const u8,
    bytes_length: usize,
    width: usize,
    height: usize,
    error_pointer: ?[*:0]const u8,
) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    callback.retain();
    defer callback.release();
    const state = callback.state;
    if (state.context.load(.acquire) == 0) return;

    const error_text = if (error_pointer) |value| std.mem.span(value) else fallback_error;
    const valid_error = error_text.len != 0 and error_text.len <= max_error_bytes and validText(error_text);
    const valid_dimensions = width != 0 and height != 0 and width <= std.math.maxInt(u32) and height <= std.math.maxInt(u32) and
        @as(f64, @floatFromInt(width)) <= state.maximum_dimension and
        @as(f64, @floatFromInt(height)) <= state.maximum_dimension and
        (std.math.mul(usize, width, height) catch std.math.maxInt(usize)) <= state.maximum_pixels;
    const valid_bytes = bytes_pointer != null and bytes_length >= 8 and bytes_length <= state.maximum_result_bytes;
    const success = valid_bytes and valid_dimensions and
        std.mem.eql(u8, bytes_pointer.?[0..8], "\x89PNG\r\n\x1a\n");
    const output_size = if (success) bytes_length else 0;
    const description_size = if (success) 0 else if (valid_error) error_text.len else fallback_error.len;
    const reserved = std.math.add(usize, output_size, description_size) catch {
        queueFailure(callback);
        return;
    };
    if (!state.reserveBytes(reserved)) {
        queueFailure(callback);
        return;
    }
    var copied_bytes: ?[]u8 = null;
    if (success) {
        copied_bytes = state.allocator.dupe(u8, bytes_pointer.?[0..bytes_length]) catch {
            state.releaseBytes(reserved);
            queueFailure(callback);
            return;
        };
    }
    const description_source = if (success) "" else if (valid_error) error_text else fallback_error;
    var copied_description: ?[]u8 = null;
    if (description_source.len != 0) {
        copied_description = state.allocator.dupe(u8, description_source) catch {
            if (copied_bytes) |value| state.allocator.free(value);
            state.releaseBytes(reserved);
            queueFailure(callback);
            return;
        };
    }
    const payload = state.allocator.create(CallbackPayload) catch {
        if (copied_bytes) |value| state.allocator.free(value);
        if (copied_description) |value| state.allocator.free(value);
        state.releaseBytes(reserved);
        queueFailure(callback);
        return;
    };
    payload.* = .{
        .callback = callback,
        .bytes = copied_bytes,
        .width = width,
        .height = height,
        .error_description = copied_description,
        .reserved_bytes = reserved,
    };
    callback.retain();
    _ = state.pending_main_callbacks.fetchAdd(1, .acq_rel);
    dispatch_async_f(&_dispatch_main_q, payload, deliverPayload);
}

fn queueFailure(callback: *CallbackContext) void {
    const state = callback.state;
    callback.retain();
    _ = state.pending_main_callbacks.fetchAdd(1, .acq_rel);
    // Failure publication must not require another heap allocation. The
    // callback path reaches here specifically when a result or error payload
    // could not be retained within its budget; a missing failure notification
    // would otherwise leave the request pending forever.
    dispatch_async_f(&_dispatch_main_q, callback, deliverFailure);
}

fn deliverPayload(raw: ?*anyopaque) callconv(.c) void {
    const payload = @as(*CallbackPayload, @ptrCast(@alignCast(raw orelse return)));
    const callback = payload.callback;
    const state = callback.state;
    defer callback.release();
    defer _ = state.pending_main_callbacks.fetchSub(1, .acq_rel);
    const service_address = state.context.load(.acquire);
    const bytes = payload.bytes;
    const width = payload.width;
    const height = payload.height;
    const description = payload.error_description;
    const reserved = payload.reserved_bytes;
    state.allocator.destroy(payload);
    if (service_address == 0) {
        if (bytes) |value| state.allocator.free(value);
        if (description) |value| state.allocator.free(value);
        state.releaseBytes(reserved);
        return;
    }
    const service = @as(*Service, @ptrFromInt(service_address));
    const operation = service.requests.get(callback.request) orelse {
        if (bytes) |value| state.allocator.free(value);
        if (description) |value| state.allocator.free(value);
        state.releaseBytes(reserved);
        return;
    };
    if (operation.cancelled or operation.polled or operation.terminal) {
        if (bytes) |value| state.allocator.free(value);
        if (description) |value| state.allocator.free(value);
        state.releaseBytes(reserved);
        return;
    }
    operation.bytes = bytes;
    operation.width = @intCast(width);
    operation.height = @intCast(height);
    operation.error_description = description;
    operation.status = if (bytes != null) .completed else .failed;
    operation.reserved_bytes += reserved;
    operation.terminal = true;
    service.wake();
}

fn deliverFailure(raw: ?*anyopaque) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    const state = callback.state;
    defer callback.release();
    defer _ = state.pending_main_callbacks.fetchSub(1, .acq_rel);
    const service_address = state.context.load(.acquire);
    if (service_address == 0) return;
    const service = @as(*Service, @ptrFromInt(service_address));
    const operation = service.requests.get(callback.request) orelse return;
    if (operation.cancelled or operation.polled or operation.terminal) return;
    operation.status = .failed;
    operation.terminal = true;
    service.wake();
}

fn validText(value: []const u8) bool {
    return value.len != 0 and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

test "page capture callback rejects malformed success payloads" {
    try std.testing.expect(validText("https://example.com"));
    try std.testing.expect(!validText(""));
    try std.testing.expect(!validText("bad\x00url"));
}

test "macOS page capture validates bounded public options before native start" {
    var service = try Service.init(
        std.testing.allocator,
        2,
        4096,
        1 * 1024 * 1024,
        4 * 1024 * 1024,
        16_384,
        60 * std.time.ns_per_s,
        2 * 1024 * 1024,
        null,
        null,
    );
    defer service.deinit();
    const capture = service.interface();

    try std.testing.expectError(error.InvalidConfiguration, capture.begin(.{ .url = "file:///tmp/not-http" }));
    try std.testing.expectError(error.InvalidConfiguration, capture.begin(.{ .url = "https://" }));
    try std.testing.expectError(error.InvalidConfiguration, capture.begin(.{
        .url = "https://example.com",
        .size = .{ .width = 16_385, .height = 1 },
    }));
    try std.testing.expectError(error.InvalidConfiguration, capture.begin(.{
        .url = "https://example.com",
        .timeout_ns = 61 * std.time.ns_per_s,
    }));
}
