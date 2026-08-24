const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");

pub const DependencySink = struct {
    context: *anyopaque,
    record_fn: *const fn (*anyopaque, handles.StateId, u64) void,

    pub fn record(self: DependencySink, id: handles.StateId, version: u64) void {
        self.record_fn(self.context, id, version);
    }
};

pub const ChangeSink = struct {
    context: *anyopaque,
    changed_fn: *const fn (*anyopaque, handles.StateId, u64) void,

    pub fn changed(self: ChangeSink, id: handles.StateId, version: u64) void {
        self.changed_fn(self.context, id, version);
    }
};

pub const LifecycleSink = struct {
    context: *anyopaque,
    destroyed_fn: *const fn (*anyopaque, handles.StateId) void,

    pub fn destroyed(self: LifecycleSink, id: handles.StateId) void {
        self.destroyed_fn(self.context, id);
    }
};

pub fn Handle(comptime T: type) type {
    return struct {
        id: handles.StateId,

        pub const Value = T;
    };
}

const StateSlot = struct {
    pointer: *anyopaque,
    type_token: *const anyopaque,
    destroy_fn: *const fn (std.mem.Allocator, *anyopaque) void,
    owner: handles.ComponentId,
    version: u64 = 1,
};

pub const Store = struct {
    const Pool = handles.SlotPool(StateSlot, handles.StateId);

    allocator: std.mem.Allocator,
    pool: Pool,
    change_sink: ?ChangeSink = null,
    lifecycle_sink: ?LifecycleSink = null,
    maximum_states: usize,

    pub fn init(allocator: std.mem.Allocator) Store {
        return initWithLimit(allocator, 1_000_000);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, maximum_states: usize) Store {
        return .{
            .allocator = allocator,
            .pool = Pool.init(allocator),
            .maximum_states = maximum_states,
        };
    }

    pub fn deinit(self: *Store) void {
        var iterator = self.pool.iterator();
        while (iterator.next()) |entry| {
            entry.value.destroy_fn(self.allocator, entry.value.pointer);
        }
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn setChangeSink(self: *Store, sink: ?ChangeSink) void {
        self.change_sink = sink;
    }

    pub fn setLifecycleSink(self: *Store, sink: ?LifecycleSink) void {
        self.lifecycle_sink = sink;
    }

    pub fn create(
        self: *Store,
        comptime T: type,
        owner_id: handles.ComponentId,
        initial: T,
    ) Error!Handle(T) {
        if (self.pool.live_count >= self.maximum_states) return error.BudgetExceeded;
        const pointer = try self.allocator.create(T);
        errdefer self.allocator.destroy(pointer);
        pointer.* = initial;
        const id = try self.pool.insert(.{
            .pointer = pointer,
            .type_token = typeToken(T),
            .destroy_fn = destroyValue(T),
            .owner = owner_id,
        });
        return .{ .id = id };
    }

    pub fn destroy(self: *Store, comptime T: type, handle: Handle(T)) Error!void {
        const slot = self.pool.get(handle.id) orelse return error.InvalidHandle;
        if (slot.type_token != typeToken(T)) return error.InvalidHandle;
        const removed = self.pool.remove(handle.id) orelse return error.InvalidHandle;
        if (self.lifecycle_sink) |sink| sink.destroyed(handle.id);
        removed.destroy_fn(self.allocator, removed.pointer);
    }

    pub fn destroyUntyped(self: *Store, id: handles.StateId) Error!void {
        const removed = self.pool.remove(id) orelse return error.InvalidHandle;
        if (self.lifecycle_sink) |sink| sink.destroyed(id);
        removed.destroy_fn(self.allocator, removed.pointer);
    }

    pub fn destroyOwner(self: *Store, owner_id: handles.ComponentId) void {
        var iterator = self.pool.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value.owner.eql(owner_id)) continue;
            const removed = self.pool.remove(entry.id) orelse continue;
            if (self.lifecycle_sink) |sink| sink.destroyed(entry.id);
            removed.destroy_fn(self.allocator, removed.pointer);
        }
    }

    pub fn read(
        self: *const Store,
        comptime T: type,
        handle: Handle(T),
        dependencies: ?DependencySink,
    ) Error!*const T {
        const slot = self.pool.getConst(handle.id) orelse return error.InvalidHandle;
        if (slot.type_token != typeToken(T)) return error.InvalidHandle;
        if (dependencies) |sink| sink.record(handle.id, slot.version);
        return @ptrCast(@alignCast(slot.pointer));
    }

    pub fn beginWrite(self: *Store, comptime T: type, handle: Handle(T)) Error!WriteGuard(T) {
        const slot = self.pool.get(handle.id) orelse return error.InvalidHandle;
        if (slot.type_token != typeToken(T)) return error.InvalidHandle;
        return .{
            .store = self,
            .id = handle.id,
            .pointer = @ptrCast(@alignCast(slot.pointer)),
        };
    }

    pub fn version(self: *const Store, id: handles.StateId) Error!u64 {
        const slot = self.pool.getConst(id) orelse return error.InvalidHandle;
        return slot.version;
    }

    pub fn owner(self: *const Store, id: handles.StateId) Error!handles.ComponentId {
        const slot = self.pool.getConst(id) orelse return error.InvalidHandle;
        return slot.owner;
    }

    fn commit(self: *Store, id: handles.StateId) void {
        const slot = self.pool.get(id) orelse return;
        slot.version +%= 1;
        if (slot.version == 0) slot.version = 1;
        if (self.change_sink) |sink| sink.changed(id, slot.version);
    }
};

pub fn WriteGuard(comptime T: type) type {
    return struct {
        store: *Store,
        id: handles.StateId,
        pointer: *T,
        active: bool = true,

        const Self = @This();

        pub fn value(self: *Self) *T {
            std.debug.assert(self.active);
            return self.pointer;
        }

        pub fn deinit(self: *Self) void {
            if (!self.active) return;
            self.active = false;
            self.store.commit(self.id);
        }
    };
}

fn typeToken(comptime T: type) *const anyopaque {
    return &struct {
        var value: u8 = 0;
        const Type = T;
    }.value;
}

fn destroyValue(comptime T: type) *const fn (std.mem.Allocator, *anyopaque) void {
    return struct {
        fn destroy(allocator: std.mem.Allocator, erased: *anyopaque) void {
            const pointer: *T = @ptrCast(@alignCast(erased));
            switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => if (@hasDecl(T, "deinit")) pointer.deinit(),
                else => {},
            }
            allocator.destroy(pointer);
        }
    }.destroy;
}
