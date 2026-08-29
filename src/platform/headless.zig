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
    promised_batch_context: ?*anyopaque = null,
    release_promised_batch_fn: ?*const fn (*anyopaque, handles.PromisedFileBatchId) void = null,
    owned_bytes: usize = 0,

    fn deinit(self: *QueuedEvent, allocator: std.mem.Allocator) void {
        if (self.promised_batch_context) |context| {
            if (self.release_promised_batch_fn) |release| {
                switch (self.event) {
                    .input => |event| switch (event) {
                        .file_drop_entered, .file_drop_updated, .file_drop_performed => |drop| {
                            if (drop.promised_batch) |batch| release(context, batch);
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        }
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

const FakePromisedBatch = struct {
    allocator: std.mem.Allocator,
    descriptors: []api.PromisedFileDescriptor,
    outcomes: []OwnedFakePromisedOutcome,
    bytes: usize = 0,
    released: bool = false,
    operation_refs: usize = 0,
    started: bool = false,

    fn deinit(self: *FakePromisedBatch) void {
        for (self.descriptors) |descriptor| {
            self.allocator.free(@constCast(descriptor.suggested_name));
            if (descriptor.content_type.len != 0) self.allocator.free(@constCast(descriptor.content_type));
        }
        for (self.outcomes) |outcome| {
            if (outcome.path) |path| self.allocator.free(@constCast(path));
            if (outcome.error_description) |description| self.allocator.free(@constCast(description));
        }
        self.allocator.free(self.descriptors);
        self.allocator.free(self.outcomes);
        self.* = undefined;
    }
};

pub const FakePromisedOutcome = struct {
    /// Empty path means the fake provider reports an error for this receiver.
    path: ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

const OwnedFakePromisedOutcome = struct {
    path: ?[]u8 = null,
    error_description: ?[]u8 = null,
};

const FakePromisedOperation = struct {
    allocator: std.mem.Allocator,
    batch: handles.PromisedFileBatchId,
    destination: []u8,
    bytes: usize,
    poll_count: usize = 0,
    cancelled: bool = false,
    terminal: bool = false,
    polled: bool = false,
    release_requested: bool = false,

    fn deinit(self: *FakePromisedOperation) void {
        self.allocator.free(self.destination);
        self.* = undefined;
    }
};

const FakePageCaptureOperation = struct {
    allocator: std.mem.Allocator,
    url: []u8,
    size: geometry.Size,
    timeout_ns: u64,
    outcome: FakePageCaptureOutcome,
    poll_count: usize = 0,
    terminal: bool = false,
    polled: bool = false,
    cancelled: bool = false,

    fn deinit(self: *FakePageCaptureOperation) void {
        self.allocator.free(self.url);
        self.* = undefined;
    }
};

/// Deterministic page-capture result used by headless conformance.  The fake
/// intentionally exercises the same pending/terminal ownership contract as
/// the native LinkPresentation provider without pretending to fetch a site.
pub const FakePageCaptureOutcome = struct {
    status: api.PageCaptureTerminalStatus = .completed,
    width: u32 = 1280,
    height: u32 = 800,
    error_description: ?[]const u8 = null,
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

    /// Installs a deterministic native-promise batch for conformance tests.
    /// The fake uses the same public opaque handles and ownership transitions
    /// as a native provider: the first poll is pending and the second poll
    /// publishes all per-receiver outcomes.
    pub fn addPromisedBatch(
        self: *Harness,
        descriptors: []const api.PromisedFileDescriptor,
        outcomes: []const FakePromisedOutcome,
    ) Error!handles.PromisedFileBatchId {
        return self.context.addPromisedBatch(descriptors, outcomes);
    }

    /// Selects the next deterministic page-capture outcome.  The value is
    /// copied into each request; any error text must remain valid until the
    /// request reaches its terminal poll.
    pub fn setPageCaptureOutcome(self: *Harness, outcome: FakePageCaptureOutcome) void {
        self.context.page_capture_outcome = outcome;
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
    promised_batches: handles.SlotPool(FakePromisedBatch, handles.PromisedFileBatchId),
    promised_operations: handles.SlotPool(FakePromisedOperation, handles.PromisedFileOperationId),
    page_capture_requests: handles.SlotPool(FakePageCaptureOperation, handles.PageCaptureRequestId),
    maximum_promise_batches: usize,
    maximum_promise_operations: usize,
    maximum_promise_files: usize,
    maximum_promise_bytes: usize,
    maximum_page_capture_requests: usize,
    page_capture_outcome: FakePageCaptureOutcome = .{},
    promised_retained_bytes: usize = 0,
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
                        if (drop.promised_batch) |batch| {
                            const promised = self.promised_batches.getConst(batch) orelse return error.InvalidHandle;
                            if (promised.released) return error.InvalidHandle;
                            result.promised_batch_context = self;
                            result.release_promised_batch_fn = releaseQueuedPromisedBatch;
                        }
                        _ = try event_memory.ensureFits(drop.text, drop.paths, self.pending_payload_bytes, self.maximum_event_queue_bytes);
                        result.owned_paths = try clonePaths(self.allocator, drop.paths);
                        drop.paths = result.owned_paths.?;
                        if (drop.text) |value| {
                            result.owned_text = try self.allocator.dupe(u8, value);
                            drop.text = result.owned_text.?;
                        }
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

    fn purgeWindowEvents(self: *Context, window: handles.WindowId) void {
        var write = self.event_cursor;
        for (self.events.items[self.event_cursor..]) |event_value| {
            var event = event_value;
            if (event.window.eql(window)) {
                self.pending_payload_bytes -|= event.owned_bytes;
                event.deinit(self.allocator);
            } else {
                self.events.items[write] = event;
                write += 1;
            }
        }
        self.events.items.len = write;
        if (self.event_cursor == self.events.items.len) self.compactEvents();
    }

    fn addPromisedBatch(
        self: *Context,
        descriptors_source: []const api.PromisedFileDescriptor,
        outcomes_source: []const FakePromisedOutcome,
    ) Error!handles.PromisedFileBatchId {
        if (descriptors_source.len == 0 or descriptors_source.len != outcomes_source.len)
            return error.InvalidConfiguration;
        if (descriptors_source.len > self.maximum_promise_files or
            self.promised_batches.live_count >= self.maximum_promise_batches)
            return error.BudgetExceeded;
        var descriptors = try self.allocator.alloc(api.PromisedFileDescriptor, descriptors_source.len);
        var descriptor_count: usize = 0;
        errdefer {
            for (descriptors[0..descriptor_count]) |descriptor| {
                self.allocator.free(@constCast(descriptor.suggested_name));
                if (descriptor.content_type.len != 0) self.allocator.free(@constCast(descriptor.content_type));
            }
            self.allocator.free(descriptors);
        }
        var outcomes = try self.allocator.alloc(OwnedFakePromisedOutcome, outcomes_source.len);
        var outcome_count: usize = 0;
        errdefer {
            for (outcomes[0..outcome_count]) |outcome| {
                if (outcome.path) |path| self.allocator.free(path);
                if (outcome.error_description) |description| self.allocator.free(description);
            }
            self.allocator.free(outcomes);
        }
        var bytes: usize = 0;
        for (descriptors_source, 0..) |descriptor, index| {
            if (descriptor.suggested_name.len == 0 or !validPromiseText(descriptor.suggested_name) or
                !validPromiseTextAllowEmpty(descriptor.content_type)) return error.InvalidConfiguration;
            bytes = std.math.add(usize, bytes, descriptor.suggested_name.len) catch return error.BudgetExceeded;
            bytes = std.math.add(usize, bytes, descriptor.content_type.len) catch return error.BudgetExceeded;
            if (bytes > self.maximum_promise_bytes -| self.promised_retained_bytes) return error.BudgetExceeded;
            var name_owned: ?[]u8 = try self.allocator.dupe(u8, descriptor.suggested_name);
            errdefer if (name_owned) |value| self.allocator.free(value);
            var type_owned: ?[]u8 = if (descriptor.content_type.len == 0) null else try self.allocator.dupe(u8, descriptor.content_type);
            errdefer if (type_owned) |value| self.allocator.free(value);
            descriptors[index] = .{
                .suggested_name = name_owned.?,
                .content_type = type_owned orelse "",
            };
            name_owned = null;
            type_owned = null;
            descriptor_count += 1;
            const outcome = outcomes_source[index];
            if (outcome.path) |path| {
                if (!validPromiseText(path)) return error.InvalidConfiguration;
            }
            if (outcome.error_description) |description| {
                if (!validPromiseText(description)) return error.InvalidConfiguration;
            }
            var path_owned: ?[]u8 = if (outcome.path) |path| try self.allocator.dupe(u8, path) else null;
            errdefer if (path_owned) |value| self.allocator.free(value);
            var description_owned: ?[]u8 = if (outcome.error_description) |description| try self.allocator.dupe(u8, description) else null;
            errdefer if (description_owned) |value| self.allocator.free(value);
            outcomes[index] = .{
                .path = path_owned,
                .error_description = description_owned,
            };
            path_owned = null;
            description_owned = null;
            if (outcome.path) |path| bytes = std.math.add(usize, bytes, path.len) catch return error.BudgetExceeded;
            if (outcome.error_description) |description| bytes = std.math.add(usize, bytes, description.len) catch return error.BudgetExceeded;
            if (bytes > self.maximum_promise_bytes -| self.promised_retained_bytes) return error.BudgetExceeded;
            outcome_count += 1;
        }
        const batch = FakePromisedBatch{
            .allocator = self.allocator,
            .descriptors = descriptors,
            .outcomes = outcomes,
            .bytes = bytes,
        };
        const id = self.promised_batches.insert(batch) catch |err| {
            var owned = batch;
            owned.deinit();
            return err;
        };
        self.promised_retained_bytes += bytes;
        return id;
    }

    fn fail(self: *Context, err: Error) void {
        if (self.failure == null) self.failure = err;
        self.quit = true;
    }
};

fn castPromiseContext(raw: *anyopaque) *Context {
    return @ptrCast(@alignCast(raw));
}

fn describePromisedBatch(
    raw: *anyopaque,
    id: handles.PromisedFileBatchId,
    allocator: std.mem.Allocator,
) Error!api.OwnedPromisedFileDescriptors {
    const self = castPromiseContext(raw);
    const batch = self.promised_batches.getConst(id) orelse return error.InvalidHandle;
    if (batch.released) return error.InvalidHandle;
    const values = try allocator.alloc(api.PromisedFileDescriptor, batch.descriptors.len);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |descriptor| {
            allocator.free(@constCast(descriptor.suggested_name));
            if (descriptor.content_type.len != 0) allocator.free(@constCast(descriptor.content_type));
        }
        allocator.free(values);
    }
    for (batch.descriptors, 0..) |descriptor, index| {
        var name_owned: ?[]u8 = try allocator.dupe(u8, descriptor.suggested_name);
        errdefer if (name_owned) |value| allocator.free(value);
        var type_owned: ?[]u8 = if (descriptor.content_type.len == 0) null else try allocator.dupe(u8, descriptor.content_type);
        errdefer if (type_owned) |value| allocator.free(value);
        values[index] = .{
            .suggested_name = name_owned.?,
            .content_type = type_owned orelse "",
        };
        name_owned = null;
        type_owned = null;
        initialized += 1;
    }
    return .{ .allocator = allocator, .batch = id, .values = values };
}

fn beginPromisedReceive(
    raw: *anyopaque,
    id: handles.PromisedFileBatchId,
    destination: []const u8,
) Error!handles.PromisedFileOperationId {
    const self = castPromiseContext(raw);
    if (self.promised_operations.live_count >= self.maximum_promise_operations) return error.BudgetExceeded;
    const batch = self.promised_batches.get(id) orelse return error.InvalidHandle;
    if (batch.released or batch.started) return error.ResourceBusy;
    if (destination.len > self.maximum_promise_bytes -| self.promised_retained_bytes)
        return error.BudgetExceeded;
    const owned_destination = try self.allocator.dupe(u8, destination);
    errdefer self.allocator.free(owned_destination);
    const operation = FakePromisedOperation{
        .allocator = self.allocator,
        .batch = id,
        .destination = owned_destination,
        .bytes = destination.len,
    };
    const operation_id = self.promised_operations.insert(operation) catch |err| {
        var owned = operation;
        owned.deinit();
        return err;
    };
    batch.started = true;
    batch.operation_refs += 1;
    self.promised_retained_bytes += destination.len;
    return operation_id;
}

fn pollPromisedReceive(
    raw: *anyopaque,
    id: handles.PromisedFileOperationId,
    allocator: std.mem.Allocator,
) Error!api.PromisedFilePoll {
    const self = castPromiseContext(raw);
    const operation = self.promised_operations.get(id) orelse return error.InvalidHandle;
    if (operation.polled) return error.InvalidHandle;
    if (!operation.terminal) {
        if (operation.poll_count == 0) {
            operation.poll_count = 1;
            return .pending;
        }
        operation.terminal = true;
    }
    const batch = self.promised_batches.get(operation.batch) orelse return error.PlatformFailure;
    const outputs = try allocator.alloc(api.PromisedFileOutput, batch.outcomes.len);
    var initialized: usize = 0;
    errdefer {
        for (outputs[0..initialized]) |output| {
            if (output.path) |path| allocator.free(@constCast(path));
            if (output.error_description) |description| allocator.free(@constCast(description));
        }
        allocator.free(outputs);
    }
    var successes: usize = 0;
    var failures: usize = 0;
    for (batch.outcomes, 0..) |outcome, index| {
        outputs[index] = .{ .descriptor_index = index };
        if (!operation.cancelled) {
            if (outcome.path) |path| {
                outputs[index].path = try allocator.dupe(u8, path);
                successes += 1;
            } else {
                if (outcome.error_description) |description| outputs[index].error_description = try allocator.dupe(u8, description);
                failures += 1;
            }
        }
        initialized += 1;
    }
    const status: api.PromisedFileTerminalStatus = if (operation.cancelled) .canceled else if (failures == 0) .completed else if (successes == 0) .failed else .partial;
    operation.polled = true;
    return .{ .terminal = .{
        .allocator = allocator,
        .operation = id,
        .status = status,
        .outputs = outputs,
        .error_description = if (status == .failed or status == .partial) try allocator.dupe(u8, "The promised file could not be materialized.") else null,
    } };
}

fn cancelPromisedReceive(raw: *anyopaque, id: handles.PromisedFileOperationId) Error!void {
    const self = castPromiseContext(raw);
    const operation = self.promised_operations.get(id) orelse return error.InvalidHandle;
    if (operation.polled) return error.InvalidHandle;
    operation.cancelled = true;
    operation.terminal = true;
}

fn releasePromisedBatch(raw: *anyopaque, id: handles.PromisedFileBatchId) Error!void {
    const self = castPromiseContext(raw);
    const batch = self.promised_batches.get(id) orelse return error.InvalidHandle;
    if (batch.released) return error.InvalidHandle;
    batch.released = true;
    maybeDestroyPromisedBatch(self, id);
}

fn releasePromisedOperation(raw: *anyopaque, id: handles.PromisedFileOperationId) Error!void {
    const self = castPromiseContext(raw);
    const operation = self.promised_operations.get(id) orelse return error.InvalidHandle;
    if (!operation.polled or !operation.terminal) return error.ResourceBusy;
    const value = self.promised_operations.remove(id) orelse return error.InvalidHandle;
    var removed = value;
    const batch_id = removed.batch;
    self.promised_retained_bytes -|= removed.bytes;
    removed.deinit();
    if (self.promised_batches.get(batch_id)) |batch| {
        batch.operation_refs -|= 1;
        maybeDestroyPromisedBatch(self, batch_id);
    }
}

fn maybeDestroyPromisedBatch(self: *Context, id: handles.PromisedFileBatchId) void {
    const batch = self.promised_batches.get(id) orelse return;
    if (!batch.released or batch.operation_refs != 0) return;
    const value = self.promised_batches.remove(id) orelse return;
    var removed = value;
    self.promised_retained_bytes -|= removed.bytes;
    removed.deinit();
}

fn beginPageCapture(
    raw: *anyopaque,
    options: api.PageCaptureOptions,
) Error!handles.PageCaptureRequestId {
    const self = cast(raw);
    if (self.page_capture_requests.live_count >= self.maximum_page_capture_requests)
        return error.BudgetExceeded;
    const url = try self.allocator.dupe(u8, options.url);
    errdefer self.allocator.free(url);
    const operation = FakePageCaptureOperation{
        .allocator = self.allocator,
        .url = url,
        .size = options.size,
        .timeout_ns = options.timeout_ns,
        .outcome = self.page_capture_outcome,
    };
    const id = self.page_capture_requests.insert(operation) catch |err| {
        var owned = operation;
        owned.deinit();
        return err;
    };
    return id;
}

fn pollPageCapture(
    raw: *anyopaque,
    id: handles.PageCaptureRequestId,
    allocator: std.mem.Allocator,
) Error!api.PageCapturePoll {
    const self = cast(raw);
    const operation = self.page_capture_requests.get(id) orelse return error.InvalidHandle;
    if (operation.polled) return error.InvalidHandle;
    if (!operation.terminal) {
        if (operation.poll_count == 0) {
            operation.poll_count = 1;
            return .pending;
        }
        operation.terminal = true;
    }
    const status = if (operation.cancelled) .canceled else operation.outcome.status;
    var description: ?[]u8 = null;
    errdefer if (description) |value| allocator.free(value);
    if (status == .failed) {
        const error_text = operation.outcome.error_description orelse "The page could not be captured.";
        description = try allocator.dupe(u8, error_text);
    }
    var result: ?api.OwnedPageCapture = null;
    errdefer if (result) |*value| value.deinit();
    if (status == .completed) {
        const width = if (operation.outcome.width != 0) operation.outcome.width else @as(u32, @intFromFloat(@round(operation.size.width)));
        const height = if (operation.outcome.height != 0) operation.outcome.height else @as(u32, @intFromFloat(@round(operation.size.height)));
        const bytes = try allocator.dupe(u8, "\x89PNG\r\n\x1a\n");
        result = .{
            .allocator = allocator,
            .bytes = bytes,
            .width = width,
            .height = height,
        };
    }
    operation.polled = true;
    return .{ .terminal = .{
        .allocator = allocator,
        .request = id,
        .status = status,
        .result = result,
        .error_description = description,
    } };
}

fn cancelPageCapture(raw: *anyopaque, id: handles.PageCaptureRequestId) Error!void {
    const self = cast(raw);
    const operation = self.page_capture_requests.get(id) orelse return error.InvalidHandle;
    if (operation.polled) return error.InvalidHandle;
    operation.cancelled = true;
    operation.terminal = true;
}

fn releasePageCapture(raw: *anyopaque, id: handles.PageCaptureRequestId) Error!void {
    const self = cast(raw);
    const operation = self.page_capture_requests.get(id) orelse return error.InvalidHandle;
    if (!operation.polled or !operation.terminal) return error.ResourceBusy;
    const removed = self.page_capture_requests.remove(id) orelse return error.InvalidHandle;
    var owned = removed;
    owned.deinit();
}

fn validPromiseText(value: []const u8) bool {
    return value.len != 0 and validPromiseTextAllowEmpty(value);
}

fn validPromiseTextAllowEmpty(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

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
        .promised_batches = handles.SlotPool(FakePromisedBatch, handles.PromisedFileBatchId).init(allocator),
        .promised_operations = handles.SlotPool(FakePromisedOperation, handles.PromisedFileOperationId).init(allocator),
        .page_capture_requests = handles.SlotPool(FakePageCaptureOperation, handles.PageCaptureRequestId).init(allocator),
        .maximum_promise_batches = memory.platform_object_count,
        .maximum_promise_operations = memory.platform_object_count,
        .maximum_promise_files = memory.file_drop_path_count,
        .maximum_promise_bytes = memory.platform_event_payload_bytes,
        .maximum_page_capture_requests = memory.offscreen_request_count,
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
            .schedule_wake_fn = scheduleWake,
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
        .promised_files = .{
            .context = context,
            .describe_batch_fn = describePromisedBatch,
            .begin_fn = beginPromisedReceive,
            .poll_fn = pollPromisedReceive,
            .cancel_fn = cancelPromisedReceive,
            .release_batch_fn = releasePromisedBatch,
            .release_operation_fn = releasePromisedOperation,
            .limits = .{
                .maximum_batches = memory.platform_object_count,
                .maximum_operations = memory.platform_object_count,
                .maximum_files = memory.file_drop_path_count,
                .maximum_bytes = memory.platform_event_payload_bytes,
            },
        },
        .page_capture = .{
            .context = context,
            .begin_fn = beginPageCapture,
            .poll_fn = pollPageCapture,
            .cancel_fn = cancelPageCapture,
            .release_fn = releasePageCapture,
            .limits = .{
                .maximum_requests = memory.offscreen_request_count,
                .maximum_url_bytes = memory.platform_text_bytes,
                .maximum_result_bytes = memory.encoded_image_bytes,
                .maximum_pixels = @max(1, memory.decoded_image_bytes / 4),
            },
        },
        .deinit_context = context,
        .deinit_fn = deinit,
    };
    return .{ .context = context, .bundle = bundle };
}

fn cast(context: *anyopaque) *Context {
    return @ptrCast(@alignCast(context));
}

fn releaseQueuedPromisedBatch(raw: *anyopaque, id: handles.PromisedFileBatchId) void {
    const self = cast(raw);
    releasePromisedBatch(self, id) catch {};
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

fn scheduleWake(_: *anyopaque, _: clock.Timestamp) Error!void {}

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
    self.purgeWindowEvents(id);
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
        .mode => |mode| {
            if (window.mode == mode) return;
            try self.prepareEventSlots(1);
            window.mode = mode;
            self.events.appendAssumeCapacity(.{ .window = id, .event = .{ .mode_changed = mode } });
        },
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
    var windows_iterator = self.windows.iterator();
    while (windows_iterator.next()) |entry| self.retained_text.release(self.allocator, &entry.value_ptr.title);
    self.windows.deinit();
    for (self.events.items[self.event_cursor..]) |*queued| queued.deinit(self.allocator);
    self.events.deinit(self.allocator);
    if (self.clipboard_text) |value| self.allocator.free(value);
    while (self.page_capture_requests.live_count != 0) {
        var page_capture_iterator = self.page_capture_requests.iterator();
        const entry = page_capture_iterator.next() orelse break;
        const value = self.page_capture_requests.remove(entry.id) orelse break;
        var operation = value;
        operation.deinit();
    }
    self.page_capture_requests.deinit();
    while (self.promised_operations.live_count != 0) {
        var promised_operation_iterator = self.promised_operations.iterator();
        const entry = promised_operation_iterator.next() orelse break;
        const value = self.promised_operations.remove(entry.id) orelse break;
        var operation = value;
        const batch_id = operation.batch;
        self.promised_retained_bytes -|= operation.bytes;
        operation.deinit();
        if (self.promised_batches.get(batch_id)) |batch| batch.operation_refs -|= 1;
    }
    while (self.promised_batches.live_count != 0) {
        var batch_iterator = self.promised_batches.iterator();
        const entry = batch_iterator.next() orelse break;
        const value = self.promised_batches.remove(entry.id) orelse break;
        var batch = value;
        self.promised_retained_bytes -|= batch.bytes;
        batch.deinit();
    }
    self.promised_operations.deinit();
    self.promised_batches.deinit();
    std.debug.assert(self.promised_retained_bytes == 0);
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

test "headless promised files preserve mixed results and cancellation ownership" {
    var harness = try create(std.testing.allocator, null);
    defer harness.bundle.deinit();
    const service = harness.bundle.promised_files orelse return error.MissingCapability;

    const descriptors = [_]api.PromisedFileDescriptor{
        .{ .suggested_name = "one.txt", .content_type = "public.plain-text" },
        .{ .suggested_name = "two.pdf", .content_type = "com.adobe.pdf" },
    };
    const outcomes = [_]FakePromisedOutcome{
        .{ .path = "/tmp/promised/one.txt" },
        .{ .error_description = "provider refused the second file" },
    };
    const batch = try harness.addPromisedBatch(&descriptors, &outcomes);

    var described = try service.describe(batch, std.testing.allocator);
    defer described.deinit();
    try std.testing.expectEqual(@as(usize, 2), described.values.len);
    try std.testing.expectEqualStrings("one.txt", described.values[0].suggested_name);
    try std.testing.expectEqualStrings("com.adobe.pdf", described.values[1].content_type);

    const operation = try service.begin(batch, "/tmp/promised-destination");
    try service.releaseBatch(batch);
    try std.testing.expectEqual(api.PromisedFilePoll.pending, try service.poll(operation, std.testing.allocator));
    var terminal = try service.poll(operation, std.testing.allocator);
    switch (terminal) {
        .pending => {
            return error.TestUnexpectedResult;
        },
        .terminal => |*completion| {
            defer completion.deinit();
            try std.testing.expectEqual(api.PromisedFileTerminalStatus.partial, completion.status);
            try std.testing.expectEqual(@as(usize, 2), completion.outputs.len);
            try std.testing.expectEqualStrings("/tmp/promised/one.txt", completion.outputs[0].path.?);
            try std.testing.expectEqualStrings("provider refused the second file", completion.outputs[1].error_description.?);
        },
    }
    try service.releaseOperation(operation);
    try std.testing.expectError(error.InvalidHandle, service.releaseBatch(batch));

    const canceled_batch = try harness.addPromisedBatch(&descriptors, &.{ .{}, .{} });
    const canceled_operation = try service.begin(canceled_batch, "/tmp/promised-canceled");
    try service.cancel(canceled_operation);
    var canceled = try service.poll(canceled_operation, std.testing.allocator);
    switch (canceled) {
        .pending => {
            return error.TestUnexpectedResult;
        },
        .terminal => |*completion| {
            defer completion.deinit();
            try std.testing.expectEqual(api.PromisedFileTerminalStatus.canceled, completion.status);
            try std.testing.expectEqual(@as(usize, 2), completion.outputs.len);
            try std.testing.expect(completion.outputs[0].path == null);
        },
    }
    try service.releaseOperation(canceled_operation);
    try service.releaseBatch(canceled_batch);
}

test "headless discarded promised drop releases its batch" {
    var harness = try create(std.testing.allocator, null);
    defer harness.bundle.deinit();
    const service = harness.bundle.promised_files orelse return error.MissingCapability;
    const descriptors = [_]api.PromisedFileDescriptor{.{ .suggested_name = "queued.txt" }};
    const outcomes = [_]FakePromisedOutcome{.{ .path = "/tmp/queued.txt" }};
    const batch = try harness.addPromisedBatch(&descriptors, &outcomes);
    const window = handles.WindowId.init(1, 1);
    _ = try harness.bundle.windows.create(window, .{ .title = "queued promise", .visible = false });
    try harness.post(window, .{ .input = .{ .file_drop_performed = .{
        .paths = &.{},
        .position = .{},
        .promised_batch = batch,
    } } });

    // Window purge is the same discard path used by teardown. The event owns
    // the batch until it is removed, so releasing the window must invalidate
    // the batch even though no receive operation was started.
    harness.bundle.windows.destroy(window);
    try std.testing.expectError(error.InvalidHandle, service.describe(batch, std.testing.allocator));
}
