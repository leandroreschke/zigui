const std = @import("std");
const Error = @import("../core/error.zig").Error;
const Mutex = @import("../core/mutex.zig").Mutex;

pub fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        storage: []T,
        read_index: usize = 0,
        write_index: usize = 0,
        length: usize = 0,
        closed: bool = false,
        mutex: Mutex = .{},

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!Self {
            if (capacity == 0) return error.InvalidConfiguration;
            return .{
                .allocator = allocator,
                .storage = try allocator.alloc(T, capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.storage);
            self.* = undefined;
        }

        pub fn tryPush(self: *Self, value: T) error{ QueueFull, Shutdown }!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Shutdown;
            if (self.length == self.storage.len) return error.QueueFull;
            self.storage[self.write_index] = value;
            self.write_index = (self.write_index + 1) % self.storage.len;
            self.length += 1;
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.length == 0) return null;
            const value = self.storage[self.read_index];
            self.storage[self.read_index] = undefined;
            self.read_index = (self.read_index + 1) % self.storage.len;
            self.length -= 1;
            return value;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.length;
        }
    };
}
