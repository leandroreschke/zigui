const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const queue = @import("queue.zig");

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const Completion = struct {
    task: handles.TaskId,
    context: *anyopaque,
    apply_fn: *const fn (*anyopaque) void,
    drop_fn: *const fn (*anyopaque) void,

    pub fn apply(self: Completion) void {
        self.apply_fn(self.context);
    }

    pub fn drop(self: Completion) void {
        self.drop_fn(self.context);
    }
};

pub const CompletionQueue = queue.BoundedQueue(Completion);

pub const CompletionSink = struct {
    queue: *CompletionQueue,
    wake_context: *anyopaque,
    wake_fn: *const fn (*anyopaque) void,

    /// Consumes `completion` on both success and failure. Accepted work has
    /// exactly one terminal completion, which keeps the bounded queue capacity
    /// equal to the maximum number of registered tasks.
    pub fn submit(self: CompletionSink, completion: Completion) Error!void {
        self.queue.tryPush(completion) catch |err| {
            completion.drop();
            return err;
        };
        self.wake_fn(self.wake_context);
    }
};

pub const Work = struct {
    task: handles.TaskId,
    token: *CancellationToken,
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, *CancellationToken) void,
    apply_fn: *const fn (*anyopaque) void,
    drop_fn: *const fn (*anyopaque) void,

    /// Terminal path for work that begins execution. The sink consumes the
    /// resulting completion even if its bounded queue refuses publication.
    pub fn run(self: Work, sink: CompletionSink) void {
        self.run_fn(self.context, self.token);
        sink.submit(.{
            .task = self.task,
            .context = self.context,
            .apply_fn = self.apply_fn,
            .drop_fn = self.drop_fn,
        }) catch {};
    }

    /// Terminal path for accepted work cancelled before execution.
    pub fn drop(self: Work) void {
        self.drop_fn(self.context);
    }
};

pub const Host = struct {
    context: *anyopaque,
    start_fn: *const fn (*anyopaque, CompletionSink) Error!void,
    spawn_fn: *const fn (*anyopaque, Work) Error!void,
    shutdown_fn: *const fn (*anyopaque) void,

    /// Starts the host and installs the only completion sink it may use.
    /// Failure must leave the host stopped and must not retain `sink`.
    pub fn start(self: Host, sink: CompletionSink) Error!void {
        try self.start_fn(self.context, sink);
    }

    /// Consumes `work` only on success. On error the caller drops it.
    pub fn spawn(self: Host, work: Work) Error!void {
        try self.spawn_fn(self.context, work);
    }

    /// Every accepted Work must have reached exactly one `Work.run` or
    /// `Work.drop` call. Then shutdown joins every worker and returns only
    /// after no thread can access the completion sink or a Work token.
    pub fn shutdown(self: Host) void {
        self.shutdown_fn(self.context);
    }
};

const Entry = struct {
    owner_component: handles.ComponentId,
    owner_window: handles.WindowId,
    token: *CancellationToken,
};

pub const Registry = struct {
    const Pool = handles.SlotPool(Entry, handles.TaskId);

    allocator: std.mem.Allocator,
    pool: Pool,
    maximum_tasks: usize = std.math.maxInt(usize),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return initWithLimit(allocator, std.math.maxInt(usize));
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, maximum_tasks: usize) Registry {
        return .{
            .allocator = allocator,
            .pool = Pool.init(allocator),
            .maximum_tasks = maximum_tasks,
        };
    }

    pub fn deinit(self: *Registry) void {
        var iterator = self.pool.iterator();
        while (iterator.next()) |entry| {
            entry.value.token.cancel();
            self.allocator.destroy(entry.value.token);
        }
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn create(
        self: *Registry,
        owner_component: handles.ComponentId,
        owner_window: handles.WindowId,
    ) Error!struct { id: handles.TaskId, token: *CancellationToken } {
        if (self.pool.live_count >= self.maximum_tasks) return error.BudgetExceeded;
        const token = try self.allocator.create(CancellationToken);
        errdefer self.allocator.destroy(token);
        token.* = .{};
        const id = try self.pool.insert(.{
            .owner_component = owner_component,
            .owner_window = owner_window,
            .token = token,
        });
        return .{ .id = id, .token = token };
    }

    pub fn contains(self: *const Registry, id: handles.TaskId) bool {
        return self.pool.contains(id);
    }

    pub fn cancel(self: *Registry, id: handles.TaskId) void {
        const entry = self.pool.get(id) orelse return;
        entry.token.cancel();
    }

    pub fn setLimit(self: *Registry, maximum_tasks: usize) Error!void {
        if (maximum_tasks == 0 or self.pool.live_count > maximum_tasks) return error.InvalidConfiguration;
        self.maximum_tasks = maximum_tasks;
    }

    pub fn cancelAll(self: *Registry) void {
        var iterator = self.pool.iterator();
        while (iterator.next()) |entry| entry.value.token.cancel();
    }

    pub fn abandon(self: *Registry, id: handles.TaskId) void {
        const entry = self.pool.remove(id) orelse return;
        entry.token.cancel();
        self.allocator.destroy(entry.token);
    }

    pub fn cancelComponent(self: *Registry, component: handles.ComponentId) void {
        var iterator = self.pool.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.owner_component.eql(component)) entry.value.token.cancel();
        }
    }

    pub const Finish = union(enum) {
        applied: handles.WindowId,
        cancelled,
        stale,
    };

    pub fn finish(self: *Registry, completion: Completion) Finish {
        const entry = self.pool.remove(completion.task) orelse {
            completion.drop();
            return .stale;
        };
        defer self.allocator.destroy(entry.token);
        if (entry.token.isCancelled()) {
            completion.drop();
            return .cancelled;
        }
        completion.apply();
        completion.drop();
        return .{ .applied = entry.owner_window };
    }
};
