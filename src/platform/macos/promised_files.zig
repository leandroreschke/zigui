//! AppKit file-promise materialization.
//!
//! This module owns the native receiver and Objective-C block lifetimes.  Its
//! public face is `platform.PromisedFiles`; Foundation objects never escape
//! this file.  A receive operation deliberately has one destination and one
//! callback context per receiver so partial results and teardown can be
//! accounted for without borrowing pasteboard memory.

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
extern "c" fn zigui_promise_make_reader(
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque, objc.Id, objc.Id) callconv(.c) void,
    retain_context: *const fn (?*anyopaque) callconv(.c) void,
    release_context: *const fn (?*anyopaque) callconv(.c) void,
) ?*anyopaque;
extern "c" fn zigui_promise_release_reader(reader: ?*anyopaque) void;
extern "c" fn zigui_promise_receive(
    receiver: objc.Id,
    destination: objc.Id,
    operation_queue: objc.Id,
    reader: ?*anyopaque,
) void;
extern "c" fn zigui_promise_queue_finished(
    operation_queue: objc.Id,
    context: ?*anyopaque,
    callback: *const fn (?*anyopaque) callconv(.c) void,
    retain_context: *const fn (?*anyopaque) callconv(.c) void,
    release_context: *const fn (?*anyopaque) callconv(.c) void,
) bool;
extern "c" fn zigui_promise_test_invoke_reader(reader: ?*anyopaque) void;
extern "c" fn zigui_promise_test_invoke_failure(reader: ?*anyopaque) void;

const max_error_bytes = 4 * 1024;
const fallback_error = "The promised file could not be materialized.";

const BridgeState = struct {
    allocator: std.mem.Allocator,
    context: std.atomic.Value(usize),
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    /// Main-queue deliveries retain their callback context independently of
    /// the operation's ownership. This is the precise teardown barrier: the
    /// base/context references may remain held by a provider after its queue
    /// has stopped, so they must not be used as a run-loop drain condition.
    pending_main_callbacks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Includes all provider-owned descriptor, destination, and callback
    /// payload bytes. Callback delivery may begin off the main thread, so the
    /// reservation itself is atomic even though the operation tables are
    /// main-thread confined.
    reserved_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    maximum_bytes: usize,

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

const OperationIngress = struct {
    claimed_callbacks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    budget_exceeded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    maximum_files: usize,

    fn claim(self: *OperationIngress) bool {
        var current = self.claimed_callbacks.load(.acquire);
        while (current < self.maximum_files) {
            if (self.claimed_callbacks.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) == null)
                return true;
            current = self.claimed_callbacks.load(.acquire);
        }
        self.budget_exceeded.store(true, .release);
        return false;
    }
};

const CallbackContext = struct {
    state: *BridgeState,
    ingress: *OperationIngress,
    operation: handles.PromisedFileOperationId,
    descriptor_start: usize,
    descriptor_count: usize,
    delivered_outputs: usize = 0,
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

    fn claimDescriptor(self: *CallbackContext) usize {
        std.debug.assert(self.descriptor_count != 0);
        const offset = self.delivered_outputs;
        self.delivered_outputs += 1;
        return self.descriptor_start + @min(offset, self.descriptor_count - 1);
    }
};

const CallbackPayload = struct {
    callback: *CallbackContext,
    path: ?[]u8 = null,
    error_description: ?[]u8 = null,
    reserved_bytes: usize = 0,
};

const Batch = struct {
    allocator: std.mem.Allocator,
    receivers: []objc.Id,
    descriptors: []api.PromisedFileDescriptor,
    descriptor_starts: []usize,
    descriptor_counts: []usize,
    bytes: usize,
    released: bool = false,
    operation_refs: usize = 0,
    started: bool = false,

    fn deinit(self: *Batch) void {
        for (self.receivers) |receiver| objc.release(receiver);
        self.allocator.free(self.receivers);
        for (self.descriptors) |descriptor| {
            self.allocator.free(@constCast(descriptor.suggested_name));
            if (descriptor.content_type.len != 0) self.allocator.free(@constCast(descriptor.content_type));
        }
        self.allocator.free(self.descriptors);
        self.allocator.free(self.descriptor_starts);
        self.allocator.free(self.descriptor_counts);
        self.* = undefined;
    }
};

const Operation = struct {
    allocator: std.mem.Allocator,
    batch: handles.PromisedFileBatchId,
    destination: []u8,
    operation_queue: objc.Id,
    ingress: *OperationIngress,
    callbacks: []*CallbackContext,
    readers: []?*anyopaque,
    outputs: []api.PromisedFileOutput,
    output_count: usize = 0,
    successful_outputs: usize = 0,
    failed_outputs: usize = 0,
    bytes: usize = 0,
    terminal: bool = false,
    status: api.PromisedFileTerminalStatus = .failed,
    public_visible: bool = true,
    poll_consumed: bool = false,
    release_requested: bool = false,
    cancelled: bool = false,
    native_finished: bool = false,
    native_released: bool = false,

    fn deinit(self: *Operation, state: *BridgeState) void {
        if (!self.native_released) {
            for (self.readers) |reader| if (reader) |value| zigui_promise_release_reader(value);
        }
        for (self.callbacks) |callback| callback.release();
        for (self.outputs[0..self.output_count]) |output| {
            if (output.path) |path| self.allocator.free(@constCast(path));
            if (output.error_description) |description| self.allocator.free(@constCast(description));
        }
        self.allocator.free(self.outputs);
        self.allocator.free(self.readers);
        self.allocator.free(self.callbacks);
        self.allocator.destroy(self.ingress);
        objc.release(self.operation_queue);
        self.allocator.free(self.destination);
        state.releaseBytes(self.bytes);
        self.* = undefined;
    }

    fn releaseNative(self: *Operation) void {
        if (self.native_released) return;
        for (self.readers) |reader| if (reader) |value| zigui_promise_release_reader(value);
        self.native_released = true;
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    batches: handles.SlotPool(Batch, handles.PromisedFileBatchId),
    operations: handles.SlotPool(Operation, handles.PromisedFileOperationId),
    state: *BridgeState,
    maximum_batches: usize,
    maximum_operations: usize,
    maximum_files: usize,
    maximum_bytes: usize,
    retained_bytes: usize = 0,
    wake_context: ?*anyopaque = null,
    wake_fn: ?*const fn (?*anyopaque) void = null,

    pub fn init(
        allocator: std.mem.Allocator,
        maximum_batches: usize,
        maximum_operations: usize,
        maximum_files: usize,
        maximum_bytes: usize,
        wake_context: ?*anyopaque,
        wake_fn: ?*const fn (?*anyopaque) void,
    ) Error!Service {
        if (maximum_batches == 0 or maximum_operations == 0 or maximum_files == 0 or maximum_bytes == 0)
            return error.InvalidConfiguration;
        const state = try allocator.create(BridgeState);
        state.* = .{
            .allocator = allocator,
            .context = std.atomic.Value(usize).init(0),
            .maximum_bytes = maximum_bytes,
        };
        return .{
            .allocator = allocator,
            .batches = handles.SlotPool(Batch, handles.PromisedFileBatchId).init(allocator),
            .operations = handles.SlotPool(Operation, handles.PromisedFileOperationId).init(allocator),
            .state = state,
            .maximum_batches = maximum_batches,
            .maximum_operations = maximum_operations,
            .maximum_files = maximum_files,
            .maximum_bytes = maximum_bytes,
            .wake_context = wake_context,
            .wake_fn = wake_fn,
        };
    }

    pub fn bind(self: *Service) void {
        self.state.context.store(@intFromPtr(self), .release);
    }

    pub fn deinit(self: *Service) void {
        self.state.context.store(0, .release);

        // Cancellation is cooperative.  Stop the provider queues before
        // releasing their blocks, then drain main-queue deliveries while the
        // bridge's base reference keeps its address valid.
        var op_iterator = self.operations.iterator();
        while (op_iterator.next()) |entry| {
            entry.value.cancelled = true;
            entry.value.terminal = true;
            cancelAndDrainQueue(entry.value.operation_queue);
        }
        var release_iterator = self.operations.iterator();
        while (release_iterator.next()) |entry| entry.value.releaseNative();
        self.drainMainQueue();

        while (self.operations.live_count != 0) {
            var iterator = self.operations.iterator();
            const entry = iterator.next() orelse break;
            const value = self.operations.remove(entry.id) orelse break;
            var operation = value;
            operation.deinit(self.state);
        }
        while (self.batches.live_count != 0) {
            var iterator = self.batches.iterator();
            const entry = iterator.next() orelse break;
            const value = self.batches.remove(entry.id) orelse break;
            var batch = value;
            self.retained_bytes -|= batch.bytes;
            self.state.releaseBytes(batch.bytes);
            batch.deinit();
        }
        self.operations.deinit();
        self.batches.deinit();
        std.debug.assert(self.state.reserved_bytes.load(.acquire) == 0);
        self.state.release();
        self.* = undefined;
    }

    pub fn interface(self: *Service) api.PromisedFiles {
        self.bind();
        return .{
            .context = self,
            .describe_batch_fn = describeBatch,
            .begin_fn = beginReceive,
            .poll_fn = pollReceive,
            .cancel_fn = cancelReceive,
            .release_batch_fn = releaseBatch,
            .release_operation_fn = releaseOperation,
            .limits = .{
                .maximum_batches = self.maximum_batches,
                .maximum_operations = self.maximum_operations,
                .maximum_files = self.maximum_files,
                .maximum_bytes = self.maximum_bytes,
            },
        };
    }

    /// Captures native receivers from a pasteboard. This is called only for a
    /// performed drop or clipboard read; enter/update/prepare use
    /// `promiseCount` so hover probing never leaks a batch per event.
    pub fn capturePasteboard(self: *Service, pasteboard: objc.Id) Error!?handles.PromisedFileBatchId {
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const receiver_class = objc.class("NSFilePromiseReceiver") orelse return null;
        const objects = objc.send(objc.Id, pasteboard, "readObjectsForClasses:options:", .{
            objc.arrayWithObject(receiver_class), @as(objc.Id, null),
        }) orelse return null;
        const receiver_total = objc.send(usize, objects, "count", .{});
        if (receiver_total == 0) return null;
        if (receiver_total > self.maximum_files or self.batches.live_count >= self.maximum_batches)
            return error.BudgetExceeded;
        if (self.state.reserved_bytes.load(.acquire) >= self.maximum_bytes) return error.BudgetExceeded;

        var descriptor_total: usize = 0;
        for (0..receiver_total) |index| {
            const receiver = objc.send(objc.Id, objects, "objectAtIndex:", .{index}) orelse return error.PlatformFailure;
            const names = objc.send(objc.Id, receiver, "fileNames", .{});
            const name_count = if (names) |value| objc.send(usize, value, "count", .{}) else 0;
            descriptor_total = std.math.add(usize, descriptor_total, advertisedReceiverCount(name_count)) catch return error.BudgetExceeded;
            if (descriptor_total > self.maximum_files) return error.BudgetExceeded;
        }

        const receivers = try self.allocator.alloc(objc.Id, receiver_total);
        var receiver_count: usize = 0;
        errdefer {
            for (receivers[0..receiver_count]) |receiver| objc.release(receiver);
            self.allocator.free(receivers);
        }
        const descriptors = try self.allocator.alloc(api.PromisedFileDescriptor, descriptor_total);
        var descriptors_initialized: usize = 0;
        errdefer {
            for (descriptors[0..descriptors_initialized]) |descriptor| {
                self.allocator.free(@constCast(descriptor.suggested_name));
                if (descriptor.content_type.len != 0) self.allocator.free(@constCast(descriptor.content_type));
            }
            self.allocator.free(descriptors);
        }
        const descriptor_starts = try self.allocator.alloc(usize, receiver_total);
        errdefer self.allocator.free(descriptor_starts);
        const descriptor_counts = try self.allocator.alloc(usize, receiver_total);
        errdefer self.allocator.free(descriptor_counts);
        var bytes: usize = 0;
        for (0..receiver_total) |index| {
            const receiver = objc.send(objc.Id, objects, "objectAtIndex:", .{index}) orelse return error.PlatformFailure;
            const names = objc.send(objc.Id, receiver, "fileNames", .{});
            const types = objc.send(objc.Id, receiver, "fileTypes", .{});
            const name_count = if (names) |value| objc.send(usize, value, "count", .{}) else 0;
            const type_count = if (types) |value| objc.send(usize, value, "count", .{}) else 0;
            const receiver_descriptor_count = advertisedReceiverCount(name_count);
            descriptor_starts[index] = descriptors_initialized;
            descriptor_counts[index] = receiver_descriptor_count;
            receivers[index] = objc.retain(receiver);
            receiver_count += 1;
            for (0..receiver_descriptor_count) |file_index| {
                const descriptor_index = descriptor_starts[index] + file_index;
                const name = if (name_count != 0)
                    objc.utf8(objc.send(objc.Id, names, "objectAtIndex:", .{@min(file_index, name_count - 1)}))
                else
                    "Promised File";
                if (!validText(name)) return error.PlatformFailure;
                const content_type = if (type_count != 0)
                    objc.utf8(objc.send(objc.Id, types, "objectAtIndex:", .{@min(file_index, type_count - 1)}))
                else
                    "";
                bytes = std.math.add(usize, bytes, name.len) catch return error.BudgetExceeded;
                bytes = std.math.add(usize, bytes, content_type.len) catch return error.BudgetExceeded;
                if (bytes > self.maximum_bytes -| self.retained_bytes) return error.BudgetExceeded;
                var name_owned: ?[]u8 = try self.allocator.dupe(u8, name);
                errdefer if (name_owned) |value| self.allocator.free(value);
                var type_owned: ?[]u8 = if (content_type.len == 0) null else try self.allocator.dupe(u8, content_type);
                errdefer if (type_owned) |value| self.allocator.free(value);
                descriptors[descriptor_index] = .{
                    .suggested_name = name_owned.?,
                    .content_type = type_owned orelse "",
                };
                name_owned = null;
                type_owned = null;
                descriptors_initialized += 1;
            }
        }
        if (!self.state.reserveBytes(bytes)) return error.BudgetExceeded;
        var bytes_reserved = true;
        errdefer if (bytes_reserved) self.state.releaseBytes(bytes);
        const batch = Batch{
            .allocator = self.allocator,
            .receivers = receivers,
            .descriptors = descriptors,
            .descriptor_starts = descriptor_starts,
            .descriptor_counts = descriptor_counts,
            .bytes = bytes,
        };
        const id = self.batches.insert(batch) catch |err| {
            var owned = batch;
            owned.deinit();
            return err;
        };
        self.retained_bytes += bytes;
        bytes_reserved = false;
        return id;
    }

    pub fn promiseCount(self: *Service, pasteboard: objc.Id) Error!usize {
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const receiver_class = objc.class("NSFilePromiseReceiver") orelse return 0;
        const objects = objc.send(objc.Id, pasteboard, "readObjectsForClasses:options:", .{
            objc.arrayWithObject(receiver_class), @as(objc.Id, null),
        });
        const receivers = if (objects) |value| value else return 0;
        const receiver_count = objc.send(usize, receivers, "count", .{});
        var descriptor_count: usize = 0;
        for (0..receiver_count) |index| {
            const receiver = objc.send(objc.Id, receivers, "objectAtIndex:", .{index}) orelse
                return error.PlatformFailure;
            const names = objc.send(objc.Id, receiver, "fileNames", .{});
            const name_count = if (names) |value| objc.send(usize, value, "count", .{}) else 0;
            descriptor_count = std.math.add(usize, descriptor_count, advertisedReceiverCount(name_count)) catch
                return error.BudgetExceeded;
            if (descriptor_count > self.maximum_files) return error.BudgetExceeded;
        }
        return descriptor_count;
    }

    pub fn canAccept(self: *const Service, count: usize) bool {
        return count != 0 and count <= self.maximum_files and
            self.batches.live_count < self.maximum_batches and
            self.operations.live_count < self.maximum_operations and
            self.state.reserved_bytes.load(.acquire) < self.maximum_bytes;
    }

    /// Checks the remaining budgets after `capturePasteboard` has already
    /// retained the batch.  The captured batch itself occupies the one batch
    /// slot, so requiring another free batch slot here would reject every
    /// promise drop when the configured batch budget is one.
    pub fn canAcceptCaptured(self: *const Service, count: usize) bool {
        return count != 0 and count <= self.maximum_files and
            self.operations.live_count < self.maximum_operations and
            self.state.reserved_bytes.load(.acquire) < self.maximum_bytes;
    }

    pub fn ownsBatch(self: *const Service, id: handles.PromisedFileBatchId) bool {
        const batch = self.batches.getConst(id) orelse return false;
        return !batch.released;
    }

    fn describeBatch(raw: *anyopaque, id: handles.PromisedFileBatchId, allocator: std.mem.Allocator) Error!api.OwnedPromisedFileDescriptors {
        const self = @as(*Service, @ptrCast(@alignCast(raw)));
        const batch = self.batches.getConst(id) orelse return error.InvalidHandle;
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

    fn beginReceive(raw: *anyopaque, id: handles.PromisedFileBatchId, destination: []const u8) Error!handles.PromisedFileOperationId {
        const self = @as(*Service, @ptrCast(@alignCast(raw)));
        var pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        if (self.operations.live_count >= self.maximum_operations) return error.BudgetExceeded;
        const batch = self.batches.get(id) orelse return error.InvalidHandle;
        if (batch.released or batch.started or batch.operation_refs != 0) return error.ResourceBusy;
        if (destination.len > self.maximum_bytes or !validText(destination)) return error.InvalidConfiguration;
        if (batch.descriptors.len == 0 or batch.descriptors.len > self.maximum_files) return error.BudgetExceeded;

        var copied_destination: ?[]u8 = try self.allocator.dupe(u8, destination);
        errdefer if (copied_destination) |value| self.allocator.free(value);
        const output_storage_bytes = std.math.mul(usize, self.maximum_files, @sizeOf(api.PromisedFileOutput)) catch
            return error.BudgetExceeded;
        const operation_base_bytes = std.math.add(usize, destination.len, output_storage_bytes) catch
            return error.BudgetExceeded;
        if (!self.state.reserveBytes(operation_base_bytes)) return error.BudgetExceeded;
        var operation_bytes_reserved = true;
        errdefer if (operation_bytes_reserved) self.state.releaseBytes(operation_base_bytes);
        // The callback itself is marshaled to the main queue below.  Keep the
        // receive operation on a private queue so cancellation can never
        // cancel unrelated work submitted to NSOperationQueue.mainQueue.
        const queue = createPrivateOperationQueue() orelse return error.PlatformFailure;
        objc.send(void, queue, "setSuspended:", .{true});
        var operation_inserted = false;
        errdefer if (!operation_inserted) objc.release(queue);
        const destination_url = fileUrl(destination) orelse return error.PlatformFailure;
        const callback_count = batch.receivers.len;
        const ingress = try self.allocator.create(OperationIngress);
        ingress.* = .{ .maximum_files = self.maximum_files };
        errdefer if (!operation_inserted) self.allocator.destroy(ingress);
        const callbacks = try self.allocator.alloc(*CallbackContext, callback_count);
        var callbacks_initialized: usize = 0;
        errdefer if (!operation_inserted) {
            for (callbacks[0..callbacks_initialized]) |callback| callback.release();
            self.allocator.free(callbacks);
        };
        const readers = try self.allocator.alloc(?*anyopaque, callback_count);
        @memset(readers, null);
        errdefer if (!operation_inserted) self.allocator.free(readers);
        const outputs = try self.allocator.alloc(api.PromisedFileOutput, self.maximum_files);
        errdefer if (!operation_inserted) self.allocator.free(outputs);
        for (callbacks, 0..) |*callback, index| {
            const value = try self.allocator.create(CallbackContext);
            value.* = .{
                .state = self.state,
                .ingress = ingress,
                .operation = handles.PromisedFileOperationId.invalid,
                .descriptor_start = batch.descriptor_starts[index],
                .descriptor_count = batch.descriptor_counts[index],
            };
            self.state.retain();
            callback.* = value;
            callbacks_initialized += 1;
        }

        const operation = Operation{
            .allocator = self.allocator,
            .batch = id,
            .destination = copied_destination.?,
            .operation_queue = queue,
            .ingress = ingress,
            .callbacks = callbacks,
            .readers = readers,
            .outputs = outputs,
            .bytes = operation_base_bytes,
        };
        copied_destination = null;
        operation_bytes_reserved = false;
        const operation_id = self.operations.insert(operation) catch |err| {
            operation_inserted = true;
            var owned = operation;
            owned.deinit(self.state);
            return err;
        };
        operation_inserted = true;
        const stored = self.operations.get(operation_id) orelse unreachable;
        for (stored.callbacks) |callback| callback.operation = operation_id;
        batch.started = true;
        batch.operation_refs += 1;

        var begin_completed = false;
        errdefer if (!begin_completed) {
            stored.cancelled = true;
            stored.terminal = true;
            stored.status = .failed;
            objc.send(void, stored.operation_queue, "setSuspended:", .{false});
            cancelAndDrainQueue(stored.operation_queue);
            stored.releaseNative();
            batch.operation_refs -|= 1;
            if (self.operations.remove(operation_id)) |value| {
                var removed = value;
                removed.deinit(self.state);
            }
        };
        for (batch.receivers, 0..) |receiver, index| {
            const reader = zigui_promise_make_reader(
                stored.callbacks[index],
                promiseReaderCallback,
                retainCallbackContext,
                releaseCallbackContext,
            ) orelse {
                return error.PlatformFailure;
            };
            stored.readers[index] = reader;
            zigui_promise_receive(receiver, destination_url, queue, reader);
        }
        // File-name and type metadata cannot reliably predict how many files
        // a receiver will materialize. Completion is therefore defined by a
        // barrier placed after AppKit's serial receive operations, while each
        // reader callback claims from the shared bounded ingress dynamically.
        if (!zigui_promise_queue_finished(
            stored.operation_queue,
            stored.callbacks[0],
            promiseQueueFinished,
            retainCallbackContext,
            releaseCallbackContext,
        )) return error.PlatformFailure;
        objc.send(void, stored.operation_queue, "setSuspended:", .{false});
        begin_completed = true;
        return operation_id;
    }

    fn pollReceive(raw: *anyopaque, id: handles.PromisedFileOperationId, allocator: std.mem.Allocator) Error!api.PromisedFilePoll {
        const self = @as(*Service, @ptrCast(@alignCast(raw)));
        const operation = self.operations.get(id) orelse return error.InvalidHandle;
        if (!operation.public_visible) return error.InvalidHandle;
        if (!operation.terminal) return .pending;
        const error_description = if (operation.status == .failed or operation.status == .partial)
            try allocator.dupe(u8, fallback_error)
        else
            null;
        errdefer if (error_description) |description| allocator.free(description);
        const outputs = try allocator.alloc(api.PromisedFileOutput, operation.output_count);
        var initialized: usize = 0;
        errdefer {
            for (outputs[0..initialized]) |output| {
                if (output.path) |path| allocator.free(@constCast(path));
                if (output.error_description) |description| allocator.free(@constCast(description));
            }
            allocator.free(outputs);
        }
        for (operation.outputs[0..operation.output_count], 0..) |output, index| {
            outputs[index] = .{ .descriptor_index = output.descriptor_index };
            initialized += 1;
            if (output.path) |path| outputs[index].path = try allocator.dupe(u8, path);
            if (output.error_description) |description| outputs[index].error_description = try allocator.dupe(u8, description);
        }
        operation.public_visible = false;
        operation.poll_consumed = true;
        return .{ .terminal = .{
            .allocator = allocator,
            .operation = id,
            .status = operation.status,
            .outputs = outputs,
            .error_description = error_description,
        } };
    }

    fn cancelReceive(raw: *anyopaque, id: handles.PromisedFileOperationId) Error!void {
        const self = @as(*Service, @ptrCast(@alignCast(raw)));
        const operation = self.operations.get(id) orelse return error.InvalidHandle;
        if (!operation.public_visible) return error.InvalidHandle;
        if (operation.terminal) return;
        operation.cancelled = true;
        operation.terminal = true;
        operation.status = .canceled;
        objc.send(void, operation.operation_queue, "cancelAllOperations", .{});
        // Cancellation may suppress the original completion operation. Queue
        // a fresh serial drain marker after canceling so release still waits
        // for every in-flight reader callback without blocking the UI thread.
        if (!zigui_promise_queue_finished(
            operation.operation_queue,
            operation.callbacks[0],
            promiseQueueFinished,
            retainCallbackContext,
            releaseCallbackContext,
        )) return error.PlatformFailure;
        self.wake();
    }

    fn releaseBatch(raw: *anyopaque, id: handles.PromisedFileBatchId) Error!void {
        const self = @as(*Service, @ptrCast(@alignCast(raw)));
        const batch = self.batches.get(id) orelse return error.InvalidHandle;
        if (batch.released) return error.InvalidHandle;
        batch.released = true;
        self.maybeDestroyBatch(id);
    }

    fn releaseOperation(raw: *anyopaque, id: handles.PromisedFileOperationId) Error!void {
        const self = @as(*Service, @ptrCast(@alignCast(raw)));
        const operation = self.operations.get(id) orelse return error.InvalidHandle;
        if (!operation.poll_consumed) return error.ResourceBusy;
        operation.release_requested = true;
        self.maybeDestroyOperation(id);
    }

    fn deliver(self: *Service, callback: *CallbackContext, path: ?[]u8, description: ?[]u8) void {
        const operation = self.operations.get(callback.operation) orelse {
            if (path) |value| {
                self.state.releaseBytes(value.len);
                self.allocator.free(value);
            }
            if (description) |value| {
                self.state.releaseBytes(value.len);
                self.allocator.free(value);
            }
            return;
        };
        var path_owned = path;
        var description_owned = description;
        defer {
            if (path_owned) |value| {
                self.state.releaseBytes(value.len);
                self.allocator.free(value);
            }
            if (description_owned) |value| {
                self.state.releaseBytes(value.len);
                self.allocator.free(value);
            }
        }
        if (operation.cancelled or operation.native_finished) return;
        if (operation.output_count >= operation.outputs.len) {
            operation.ingress.budget_exceeded.store(true, .release);
            return;
        }
        const output_index = operation.output_count;
        operation.output_count += 1;
        const output = &operation.outputs[output_index];
        output.* = .{ .descriptor_index = callback.claimDescriptor() };
        if (path_owned) |value| {
            if (value.len != 0 and validText(value) and value.len <= self.maximum_bytes -| operation.bytes) {
                output.path = value;
                path_owned = null;
                operation.bytes += value.len;
                operation.successful_outputs += 1;
                return;
            }
        }
        if (description_owned) |value| {
            if (value.len <= self.maximum_bytes -| operation.bytes) {
                output.error_description = value;
                description_owned = null;
                operation.bytes += value.len;
            }
        }
        if (output.error_description == null) {
            if (fallback_error.len <= self.maximum_bytes -| operation.bytes and self.state.reserveBytes(fallback_error.len)) {
                output.error_description = self.allocator.dupe(u8, fallback_error) catch null;
                if (output.error_description == null) self.state.releaseBytes(fallback_error.len) else operation.bytes += fallback_error.len;
            }
        }
        operation.failed_outputs += 1;
    }

    fn nativeFinished(self: *Service, operation_id: handles.PromisedFileOperationId) void {
        const operation = self.operations.get(operation_id) orelse return;
        if (operation.native_finished) return;
        operation.native_finished = true;
        const budget_exceeded = operation.ingress.budget_exceeded.load(.acquire);
        if (operation.cancelled) operation.status = .canceled else if (!budget_exceeded and operation.output_count != 0 and operation.failed_outputs == 0)
            operation.status = .completed
        else if (operation.successful_outputs == 0)
            operation.status = .failed
        else
            operation.status = .partial;
        operation.terminal = true;
        self.wake();
        self.maybeDestroyOperationByPointer(operation);
    }

    fn maybeDestroyOperationByPointer(self: *Service, operation: *Operation) void {
        if (!operation.poll_consumed or !operation.release_requested or !operation.native_finished)
            return;
        const id = operationIdForPointer(self, operation) orelse return;
        self.maybeDestroyOperation(id);
    }

    fn maybeDestroyOperation(self: *Service, id: handles.PromisedFileOperationId) void {
        const operation = self.operations.get(id) orelse return;
        if (!operation.release_requested or !operation.poll_consumed or !operation.native_finished) return;
        const value = self.operations.remove(id) orelse return;
        var removed = value;
        removed.deinit(self.state);
        if (self.batches.get(removed.batch)) |batch| {
            batch.operation_refs -|= 1;
            self.maybeDestroyBatch(removed.batch);
        }
    }

    fn maybeDestroyBatch(self: *Service, id: handles.PromisedFileBatchId) void {
        const batch = self.batches.get(id) orelse return;
        if (!batch.released or batch.operation_refs != 0) return;
        const value = self.batches.remove(id) orelse return;
        var removed = value;
        self.retained_bytes -|= removed.bytes;
        self.state.releaseBytes(removed.bytes);
        removed.deinit();
    }

    fn operationIdForPointer(self: *Service, target: *Operation) ?handles.PromisedFileOperationId {
        var iterator = self.operations.iterator();
        while (iterator.next()) |entry| if (entry.value == target) return entry.id;
        return null;
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

fn retainCallbackContext(raw: ?*anyopaque) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    callback.retain();
}

fn releaseCallbackContext(raw: ?*anyopaque) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    callback.release();
}

fn queueFailure(callback: *CallbackContext) void {
    callback.retain();
    _ = callback.state.pending_main_callbacks.fetchAdd(1, .acq_rel);
    dispatch_async_f(&_dispatch_main_q, callback, deliverFailure);
}

fn promiseReaderCallback(raw: ?*anyopaque, url: objc.Id, error_object: objc.Id) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    // The Objective-C bridge owns one reference for every copied reader
    // block.  Retain once more while this callback is executing because a
    // provider may release its copy concurrently with delivery.
    callback.retain();
    defer callback.release();
    const state = callback.state;
    if (state.context.load(.acquire) == 0) return;
    // Claim before copying any provider-controlled path or error text. Excess
    // callbacks are rejected at the native ingress and reported when the
    // serial completion barrier reaches the main queue.
    if (!callback.ingress.claim()) return;
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const path_text = if (url) |value| objc.utf8(objc.send(objc.Id, value, "path", .{})) else "";
    const error_text = if (error_object) |value| objc.utf8(objc.send(objc.Id, value, "localizedDescription", .{})) else "";
    const path_len = if (path_text.len != 0 and validText(path_text) and path_text.len <= state.maximum_bytes) path_text.len else 0;
    const description_len = if (error_text.len != 0 and validText(error_text) and error_text.len <= max_error_bytes) error_text.len else 0;
    const reserved_bytes = std.math.add(usize, path_len, description_len) catch 0;
    if (reserved_bytes == 0) {
        queueFailure(callback);
        return;
    }
    if (!state.reserveBytes(reserved_bytes)) {
        queueFailure(callback);
        return;
    }
    const path: ?[]u8 = if (path_len != 0) state.allocator.dupe(u8, path_text) catch {
        state.releaseBytes(reserved_bytes);
        queueFailure(callback);
        return;
    } else null;
    const description: ?[]u8 = if (description_len != 0) state.allocator.dupe(u8, error_text) catch {
        if (path) |value| state.allocator.free(value);
        state.releaseBytes(reserved_bytes);
        queueFailure(callback);
        return;
    } else null;
    const payload = state.allocator.create(CallbackPayload) catch {
        if (path) |value| state.allocator.free(value);
        if (description) |value| state.allocator.free(value);
        state.releaseBytes(reserved_bytes);
        queueFailure(callback);
        return;
    };
    payload.* = .{
        .callback = callback,
        .path = path,
        .error_description = description,
        .reserved_bytes = reserved_bytes,
    };
    callback.retain();
    _ = state.pending_main_callbacks.fetchAdd(1, .acq_rel);
    dispatch_async_f(&_dispatch_main_q, payload, deliverPayload);
}

fn deliverPayload(raw: ?*anyopaque) callconv(.c) void {
    const payload = @as(*CallbackPayload, @ptrCast(@alignCast(raw orelse return)));
    const callback = payload.callback;
    const state = callback.state;
    const path = payload.path;
    const description = payload.error_description;
    const reserved_bytes = payload.reserved_bytes;
    state.allocator.destroy(payload);
    defer callback.release();
    defer _ = state.pending_main_callbacks.fetchSub(1, .acq_rel);
    const address = state.context.load(.acquire);
    if (address == 0) {
        if (path) |value| state.allocator.free(value);
        if (description) |value| state.allocator.free(value);
        state.releaseBytes(reserved_bytes);
        return;
    }
    const service = @as(*Service, @ptrFromInt(address));
    service.deliver(callback, path, description);
}

fn deliverFailure(raw: ?*anyopaque) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    defer callback.release();
    defer _ = callback.state.pending_main_callbacks.fetchSub(1, .acq_rel);
    const address = callback.state.context.load(.acquire);
    if (address == 0) return;
    const service = @as(*Service, @ptrFromInt(address));
    service.deliver(callback, null, null);
}

fn promiseQueueFinished(raw: ?*anyopaque) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    callback.retain();
    _ = callback.state.pending_main_callbacks.fetchAdd(1, .acq_rel);
    dispatch_async_f(&_dispatch_main_q, callback, deliverQueueFinished);
}

fn deliverQueueFinished(raw: ?*anyopaque) callconv(.c) void {
    const callback = @as(*CallbackContext, @ptrCast(@alignCast(raw orelse return)));
    defer callback.release();
    defer _ = callback.state.pending_main_callbacks.fetchSub(1, .acq_rel);
    const address = callback.state.context.load(.acquire);
    if (address == 0) return;
    const service = @as(*Service, @ptrFromInt(address));
    service.nativeFinished(callback.operation);
}

fn advertisedReceiverCount(name_count: usize) usize {
    return @max(1, name_count);
}

fn validText(value: []const u8) bool {
    return value.len != 0 and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn cancelAndDrainQueue(queue: objc.Id) void {
    objc.send(void, queue, "cancelAllOperations", .{});
    // The reader block is retained by the native receive operation. Waiting
    // for this private queue to finish is the provider-side callback barrier;
    // only after it returns may callback contexts and reader blocks be freed.
    objc.send(void, queue, "waitUntilAllOperationsAreFinished", .{});
}

fn createPrivateOperationQueue() ?objc.Id {
    const queue = objc.send(objc.Id, objc.class("NSOperationQueue"), "new", .{}) orelse return null;
    // Promise receivers perform provider work through this queue.  Keep the
    // queue private and bounded so canceling one receive cannot affect
    // unrelated AppKit/main-queue work.
    objc.send(void, queue, "setMaxConcurrentOperationCount:", .{@as(isize, 1)});
    return queue;
}

fn fileUrl(path: []const u8) objc.Id {
    return objc.send(objc.Id, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
}

test "promise service rejects empty and oversized receiver budgets" {
    try std.testing.expect(!validText(""));
    try std.testing.expect(!validText("bad\x00path"));
    try std.testing.expect(validText("/tmp/promised"));
}

test "promise preflight never treats type metadata as file cardinality" {
    try std.testing.expectEqual(@as(usize, 1), advertisedReceiverCount(0));
    try std.testing.expectEqual(@as(usize, 4), advertisedReceiverCount(4));
}

test "promise callback ingress rejects work beyond the file budget" {
    var ingress: OperationIngress = .{ .maximum_files = 2 };
    try std.testing.expect(ingress.claim());
    try std.testing.expect(ingress.claim());
    try std.testing.expect(!ingress.claim());
    try std.testing.expect(ingress.budget_exceeded.load(.acquire));
}

test "macOS promised receives do not share the global main operation queue" {
    var pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const main_queue = objc.send(objc.Id, objc.class("NSOperationQueue"), "mainQueue", .{}) orelse
        return error.PlatformFailure;
    const receive_queue = createPrivateOperationQueue() orelse return error.PlatformFailure;
    defer objc.release(receive_queue);
    try std.testing.expect(receive_queue != main_queue);
    try std.testing.expectEqual(@as(isize, 1), objc.send(isize, receive_queue, "maxConcurrentOperationCount", .{}));
}

const BridgeProbe = struct {
    success_calls: usize = 0,
    failure_calls: usize = 0,
    finished_calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
};

fn bridgeProbeFinished(raw: ?*anyopaque) callconv(.c) void {
    const probe = @as(*BridgeProbe, @ptrCast(@alignCast(raw orelse return)));
    _ = probe.finished_calls.fetchAdd(1, .acq_rel);
}

fn bridgeProbeCallback(raw: ?*anyopaque, _: objc.Id, error_object: objc.Id) callconv(.c) void {
    const probe = @as(*BridgeProbe, @ptrCast(@alignCast(raw orelse return)));
    if (error_object == null) probe.success_calls += 1 else probe.failure_calls += 1;
}

fn bridgeProbeRetain(raw: ?*anyopaque) callconv(.c) void {
    const probe = @as(*BridgeProbe, @ptrCast(@alignCast(raw orelse return)));
    _ = probe.references.fetchAdd(1, .monotonic);
}

fn bridgeProbeRelease(raw: ?*anyopaque) callconv(.c) void {
    const probe = @as(*BridgeProbe, @ptrCast(@alignCast(raw orelse return)));
    _ = probe.references.fetchSub(1, .acq_rel);
}

test "macOS promise reader uses the Objective-C block ABI for success and failure" {
    var probe: BridgeProbe = .{};
    const reader = zigui_promise_make_reader(
        &probe,
        bridgeProbeCallback,
        bridgeProbeRetain,
        bridgeProbeRelease,
    ) orelse return error.PlatformFailure;
    defer zigui_promise_release_reader(reader);
    zigui_promise_test_invoke_reader(reader);
    zigui_promise_test_invoke_failure(reader);
    try std.testing.expectEqual(@as(usize, 1), probe.success_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.failure_calls);
}

test "macOS promise reader retains callback context through block lifetime" {
    var probe: BridgeProbe = .{};
    const reader = zigui_promise_make_reader(
        &probe,
        bridgeProbeCallback,
        bridgeProbeRetain,
        bridgeProbeRelease,
    ) orelse return error.PlatformFailure;
    try std.testing.expectEqual(@as(usize, 2), probe.references.load(.acquire));
    zigui_promise_release_reader(reader);
    try std.testing.expectEqual(@as(usize, 1), probe.references.load(.acquire));
}

test "macOS promise completion barrier runs after queued provider work" {
    var probe: BridgeProbe = .{};
    const queue = createPrivateOperationQueue() orelse return error.PlatformFailure;
    try std.testing.expect(zigui_promise_queue_finished(
        queue,
        &probe,
        bridgeProbeFinished,
        bridgeProbeRetain,
        bridgeProbeRelease,
    ));
    objc.send(void, queue, "waitUntilAllOperationsAreFinished", .{});
    try std.testing.expectEqual(@as(usize, 1), probe.finished_calls.load(.acquire));
    objc.release(queue);
}
