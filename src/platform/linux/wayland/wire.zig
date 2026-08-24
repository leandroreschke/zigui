const std = @import("std");
const builtin = @import("builtin");
const Error = @import("../../../core/error.zig").Error;
const sys = @import("../sys.zig");

const linux = sys.linux;
const maximum_message_bytes = std.math.maxInt(u16);
const receive_chunk_bytes = 64 * 1024;
const maximum_fds_per_receive = 64;
const maximum_pending_bytes = maximum_message_bytes + receive_chunk_bytes;
const maximum_pending_fds = maximum_fds_per_receive * 2;
const native_endian = builtin.cpu.arch.endian();

pub const ObjectId = u32;

pub const Message = struct {
    object: ObjectId,
    opcode: u16,
    payload: []const u8,
};

pub const Header = struct {
    object: ObjectId,
    opcode: u16,
    size: u16,
};

pub const Builder = struct {
    bytes: std.ArrayList(u8) = .empty,
    fds: std.ArrayList(sys.fd_t) = .empty,

    pub fn begin(self: *Builder, allocator: std.mem.Allocator, object_id: ObjectId, opcode: u16) Error!void {
        if (object_id == 0) return error.InvalidConfiguration;
        self.bytes.clearRetainingCapacity();
        self.fds.clearRetainingCapacity();
        try self.bytes.ensureTotalCapacity(allocator, 8);
        try self.u32(allocator, object_id);
        try self.u32(allocator, opcode);
    }

    pub fn int(self: *Builder, allocator: std.mem.Allocator, value: i32) Error!void {
        try self.u32(allocator, @bitCast(value));
    }

    pub fn object(self: *Builder, allocator: std.mem.Allocator, value: ObjectId) Error!void {
        if (value == 0) return error.InvalidConfiguration;
        try self.u32(allocator, value);
    }

    pub fn nullableObject(self: *Builder, allocator: std.mem.Allocator, value: ?ObjectId) Error!void {
        try self.u32(allocator, value orelse 0);
    }

    pub fn newId(self: *Builder, allocator: std.mem.Allocator, value: ObjectId) Error!void {
        if (value == 0) return error.InvalidConfiguration;
        try self.u32(allocator, value);
    }

    pub fn @"u32"(self: *Builder, allocator: std.mem.Allocator, value: u32) Error!void {
        try self.ensureAdditional(4);
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, value, native_endian);
        try self.bytes.appendSlice(allocator, &encoded);
    }

    pub fn fixed(self: *Builder, allocator: std.mem.Allocator, value: f32) Error!void {
        if (!std.math.isFinite(value)) return error.InvalidConfiguration;
        const scaled = @round(@as(f64, value) * 256.0);
        if (scaled < @as(f64, std.math.minInt(i32)) or scaled > @as(f64, std.math.maxInt(i32)))
            return error.InvalidConfiguration;
        try self.int(allocator, @intFromFloat(scaled));
    }

    pub fn string(self: *Builder, allocator: std.mem.Allocator, value: []const u8) Error!void {
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
            return error.InvalidUtf8;
        if (value.len >= std.math.maxInt(u32)) return error.BudgetExceeded;
        const body = std.math.add(usize, value.len, 1) catch return error.BudgetExceeded;
        const padding = (4 - body % 4) % 4;
        const with_length = std.math.add(usize, 4, body) catch return error.BudgetExceeded;
        try self.ensureAdditional(std.math.add(usize, with_length, padding) catch return error.BudgetExceeded);
        try self.u32(allocator, @intCast(value.len + 1));
        try self.bytes.appendSlice(allocator, value);
        try self.bytes.append(allocator, 0);
        try self.pad(allocator);
    }

    pub fn nullableString(self: *Builder, allocator: std.mem.Allocator, value: ?[]const u8) Error!void {
        const resolved = value orelse {
            try self.u32(allocator, 0);
            return;
        };
        try self.string(allocator, resolved);
    }

    pub fn array(self: *Builder, allocator: std.mem.Allocator, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(u32)) return error.BudgetExceeded;
        const padding = (4 - value.len % 4) % 4;
        const with_length = std.math.add(usize, 4, value.len) catch return error.BudgetExceeded;
        try self.ensureAdditional(std.math.add(usize, with_length, padding) catch return error.BudgetExceeded);
        try self.u32(allocator, @intCast(value.len));
        try self.bytes.appendSlice(allocator, value);
        try self.pad(allocator);
    }

    pub fn fd(self: *Builder, allocator: std.mem.Allocator, descriptor: sys.fd_t) Error!void {
        if (self.fds.items.len >= maximum_fds_per_receive) return error.BudgetExceeded;
        try self.fds.append(allocator, descriptor);
    }

    pub fn finish(self: *Builder) Error!void {
        if (self.bytes.items.len < 8 or self.bytes.items.len > maximum_message_bytes or self.bytes.items.len % 4 != 0)
            return error.InvalidConfiguration;
        const opcode = std.mem.readInt(u32, self.bytes.items[4..8], native_endian) & 0xffff;
        const header = (@as(u32, @intCast(self.bytes.items.len)) << 16) | opcode;
        std.mem.writeInt(u32, self.bytes.items[4..8], header, native_endian);
    }

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.fds.deinit(allocator);
        self.* = .{};
    }

    fn pad(self: *Builder, allocator: std.mem.Allocator) Error!void {
        const padding = (4 - self.bytes.items.len % 4) % 4;
        try self.ensureAdditional(padding);
        try self.bytes.appendNTimes(allocator, 0, padding);
    }

    fn ensureAdditional(self: *const Builder, additional: usize) Error!void {
        if (additional > maximum_message_bytes -| self.bytes.items.len) return error.BudgetExceeded;
    }
};

pub const Reader = struct {
    payload: []const u8,
    cursor: usize = 0,
    fds: []const sys.fd_t = &.{},
    fd_cursor: usize = 0,

    pub fn int(self: *Reader) Error!i32 {
        return @bitCast(try self.u32());
    }

    pub fn object(self: *Reader) Error!ObjectId {
        const value = try self.u32();
        if (value == 0) return error.PlatformFailure;
        return value;
    }

    pub fn nullableObject(self: *Reader) Error!?ObjectId {
        const value = try self.u32();
        return if (value == 0) null else value;
    }

    pub fn @"u32"(self: *Reader) Error!u32 {
        if (self.cursor > self.payload.len or self.payload.len - self.cursor < 4)
            return error.PlatformFailure;
        const value = std.mem.readInt(u32, self.payload[self.cursor..][0..4], native_endian);
        self.cursor += 4;
        return value;
    }

    pub fn fixed(self: *Reader) Error!f32 {
        return @as(f32, @floatFromInt(try self.int())) / 256.0;
    }

    pub fn string(self: *Reader) Error![]const u8 {
        const length: usize = @intCast(try self.u32());
        if (length == 0 or self.cursor > self.payload.len or length > self.payload.len - self.cursor or
            self.payload[self.cursor + length - 1] != 0)
            return error.PlatformFailure;
        const value = self.payload[self.cursor .. self.cursor + length - 1];
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
            return error.PlatformFailure;
        self.cursor = align4(self.cursor + length);
        if (self.cursor > self.payload.len) return error.PlatformFailure;
        return value;
    }

    pub fn nullableString(self: *Reader) Error!?[]const u8 {
        if (self.cursor > self.payload.len or self.payload.len - self.cursor < 4)
            return error.PlatformFailure;
        const length = std.mem.readInt(u32, self.payload[self.cursor..][0..4], native_endian);
        if (length == 0) {
            self.cursor += 4;
            return null;
        }
        return try self.string();
    }

    pub fn array(self: *Reader) Error![]const u8 {
        const length: usize = @intCast(try self.u32());
        if (self.cursor > self.payload.len or length > self.payload.len - self.cursor)
            return error.PlatformFailure;
        const value = self.payload[self.cursor .. self.cursor + length];
        self.cursor = align4(self.cursor + length);
        if (self.cursor > self.payload.len) return error.PlatformFailure;
        return value;
    }

    pub fn fd(self: *Reader) Error!sys.fd_t {
        if (self.fd_cursor >= self.fds.len) return error.PlatformFailure;
        defer self.fd_cursor += 1;
        return self.fds[self.fd_cursor];
    }

    pub fn finish(self: Reader) Error!void {
        if (self.cursor != self.payload.len or self.fd_cursor != self.fds.len) return error.PlatformFailure;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    descriptor: sys.fd_t,
    broken: bool = false,
    outgoing: Builder = .{},
    incoming: std.ArrayList(u8) = .empty,
    incoming_cursor: usize = 0,
    received_fds: std.ArrayList(sys.fd_t) = .empty,
    fd_cursor: usize = 0,

    pub fn connect(allocator: std.mem.Allocator, path: []const u8) Error!Connection {
        return .{ .allocator = allocator, .descriptor = try sys.connectUnix(path) };
    }

    pub fn begin(self: *Connection, object: ObjectId, opcode: u16) Error!*Builder {
        if (self.broken) return error.PlatformFailure;
        try self.outgoing.begin(self.allocator, object, opcode);
        return &self.outgoing;
    }

    pub fn prepareOutgoing(self: *Connection, byte_capacity: usize, fd_capacity: usize) Error!void {
        if (self.broken) return error.PlatformFailure;
        if (byte_capacity < 8 or byte_capacity > maximum_message_bytes or
            fd_capacity > maximum_fds_per_receive)
            return error.InvalidConfiguration;
        try self.outgoing.bytes.ensureTotalCapacity(self.allocator, byte_capacity);
        try self.outgoing.fds.ensureTotalCapacity(self.allocator, fd_capacity);
    }

    pub fn send(self: *Connection) Error!void {
        if (self.broken) return error.PlatformFailure;
        try self.outgoing.finish();
        sendMessage(self.descriptor, self.outgoing.bytes.items, self.outgoing.fds.items) catch |err| {
            self.broken = true;
            return err;
        };
    }

    pub fn isBroken(self: *const Connection) bool {
        return self.broken;
    }

    pub fn markBroken(self: *Connection) void {
        self.broken = true;
    }

    /// Inspects the next complete wire message without consuming it. The
    /// returned fields do not borrow storage from the connection.
    pub fn peek(self: *const Connection) Error!?Header {
        if (self.incoming.items.len - self.incoming_cursor < 8) return null;
        const header = self.incoming.items[self.incoming_cursor..][0..8];
        const object = std.mem.readInt(u32, header[0..4], native_endian);
        const size_opcode = std.mem.readInt(u32, header[4..8], native_endian);
        const size: usize = size_opcode >> 16;
        if (object == 0 or size < 8 or size % 4 != 0 or size > maximum_message_bytes)
            return error.PlatformFailure;
        if (self.incoming.items.len - self.incoming_cursor < size) return null;
        return .{ .object = object, .opcode = @truncate(size_opcode), .size = @intCast(size) };
    }

    /// Returns the next complete message. `fd_count` is supplied by the typed
    /// protocol dispatcher because file descriptors are ordered out-of-band.
    /// Payload and descriptor slices are borrowed until the next `receive`.
    /// Descriptor ownership transfers to the caller when this function returns.
    pub fn next(self: *Connection, fd_count: usize) Error!?struct { message: Message, fds: []const sys.fd_t } {
        if (fd_count > maximum_fds_per_receive) return error.BudgetExceeded;
        const header = try self.peek() orelse return null;
        const size: usize = header.size;
        if (self.received_fds.items.len - self.fd_cursor < fd_count) return null;
        const message = Message{
            .object = header.object,
            .opcode = header.opcode,
            .payload = self.incoming.items[self.incoming_cursor + 8 .. self.incoming_cursor + size],
        };
        const fds = self.received_fds.items[self.fd_cursor .. self.fd_cursor + fd_count];
        self.incoming_cursor += size;
        self.fd_cursor += fd_count;
        return .{ .message = message, .fds = fds };
    }

    pub fn receive(self: *Connection) Error!bool {
        if (self.broken) return error.PlatformFailure;
        self.compact();
        if (self.incoming.items.len > maximum_pending_bytes - receive_chunk_bytes or
            self.received_fds.items.len > maximum_pending_fds - maximum_fds_per_receive)
        {
            self.broken = true;
            return error.BudgetExceeded;
        }
        // Reserve before recvmsg. Once the kernel has transferred descriptors,
        // an allocator failure must not make them unreachable and leak them.
        try self.incoming.ensureUnusedCapacity(self.allocator, receive_chunk_bytes);
        try self.received_fds.ensureUnusedCapacity(self.allocator, maximum_fds_per_receive);
        var bytes: [receive_chunk_bytes]u8 = undefined;
        var control: [cmsgSpace(maximum_fds_per_receive * @sizeOf(sys.fd_t))]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        var vector: [1]std.posix.iovec = .{.{ .base = bytes[0..].ptr, .len = bytes.len }};
        var message: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &vector,
            .iovlen = vector.len,
            .control = control[0..].ptr,
            .controllen = control.len,
            .flags = 0,
        };
        const result = while (true) {
            const received = linux.recvmsg(self.descriptor, &message, linux.MSG.CMSG_CLOEXEC);
            switch (linux.errno(received)) {
                .SUCCESS => break received,
                .INTR => continue,
                .AGAIN => return false,
                else => {
                    self.broken = true;
                    return error.PlatformFailure;
                },
            }
        };
        if (result == 0) {
            self.broken = true;
            return error.PlatformFailure;
        }

        const previous_bytes = self.incoming.items.len;
        const previous_fds = self.received_fds.items.len;
        errdefer {
            self.incoming.items.len = previous_bytes;
            for (self.received_fds.items[previous_fds..]) |descriptor| sys.close(descriptor);
            self.received_fds.items.len = previous_fds;
        }
        self.incoming.appendSliceAssumeCapacity(bytes[0..result]);
        appendReceivedFds(&self.received_fds, control[0..message.controllen]) catch |err| {
            self.broken = true;
            return err;
        };
        if (message.flags & linux.MSG.CTRUNC != 0) {
            self.broken = true;
            return error.PlatformFailure;
        }
        return true;
    }

    pub fn deinit(self: *Connection) void {
        for (self.received_fds.items[self.fd_cursor..]) |descriptor| sys.close(descriptor);
        self.received_fds.deinit(self.allocator);
        self.incoming.deinit(self.allocator);
        self.outgoing.deinit(self.allocator);
        sys.close(self.descriptor);
        self.* = undefined;
    }

    fn compact(self: *Connection) void {
        if (self.incoming_cursor != 0) {
            const remaining = self.incoming.items.len - self.incoming_cursor;
            if (remaining != 0) std.mem.copyForwards(u8, self.incoming.items[0..remaining], self.incoming.items[self.incoming_cursor..]);
            self.incoming.items.len = remaining;
            self.incoming_cursor = 0;
        }
        if (self.fd_cursor != 0) {
            const remaining = self.received_fds.items.len - self.fd_cursor;
            if (remaining != 0) std.mem.copyForwards(sys.fd_t, self.received_fds.items[0..remaining], self.received_fds.items[self.fd_cursor..]);
            self.received_fds.items.len = remaining;
            self.fd_cursor = 0;
        }
    }
};

fn sendMessage(descriptor: sys.fd_t, bytes: []const u8, fds: []const sys.fd_t) Error!void {
    if (fds.len == 0) return sys.writeAll(descriptor, bytes);
    if (fds.len > maximum_fds_per_receive) return error.BudgetExceeded;
    var vector: [1]std.posix.iovec_const = .{.{ .base = bytes.ptr, .len = bytes.len }};
    var control: [cmsgSpace(maximum_fds_per_receive * @sizeOf(sys.fd_t))]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const payload_bytes = fds.len * @sizeOf(sys.fd_t);
    const used = cmsgSpace(payload_bytes);
    @memset(control[0..used], 0);
    const header: *linux.cmsghdr = @ptrCast(@alignCast(control[0..].ptr));
    header.* = .{ .len = cmsgLength(payload_bytes), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
    const data_offset = cmsgAlign(@sizeOf(linux.cmsghdr));
    @memcpy(control[data_offset..][0..payload_bytes], std.mem.sliceAsBytes(fds));
    const message: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &vector,
        .iovlen = vector.len,
        .control = control[0..].ptr,
        .controllen = used,
        .flags = 0,
    };
    var offset: usize = 0;
    while (true) {
        const result = linux.sendmsg(descriptor, &message, linux.MSG.NOSIGNAL);
        switch (linux.errno(result)) {
            .SUCCESS => {
                offset = result;
                break;
            },
            .INTR => continue,
            .AGAIN => try sys.waitWritable(descriptor),
            else => return error.PlatformFailure,
        }
    }
    if (offset == 0) return error.PlatformFailure;
    if (offset < bytes.len) try sys.writeAll(descriptor, bytes[offset..]);
}

fn appendReceivedFds(destination: *std.ArrayList(sys.fd_t), control: []const u8) Error!void {
    var offset: usize = 0;
    while (offset + @sizeOf(linux.cmsghdr) <= control.len) {
        const header: *const linux.cmsghdr = @ptrCast(@alignCast(control[offset..].ptr));
        if (header.len < cmsgLength(0) or header.len > control.len - offset) return error.PlatformFailure;
        if (header.level == linux.SOL.SOCKET and header.type == linux.SCM.RIGHTS) {
            const data_offset = offset + cmsgAlign(@sizeOf(linux.cmsghdr));
            if (data_offset > offset + header.len) return error.PlatformFailure;
            const byte_count = offset + header.len - data_offset;
            if (byte_count % @sizeOf(sys.fd_t) != 0) return error.PlatformFailure;
            const count = byte_count / @sizeOf(sys.fd_t);
            const descriptors: [*]const sys.fd_t = @ptrCast(@alignCast(control[data_offset..].ptr));
            if (count > maximum_fds_per_receive or
                count > maximum_pending_fds -| destination.items.len or
                destination.capacity - destination.items.len < count)
                return error.BudgetExceeded;
            destination.appendSliceAssumeCapacity(descriptors[0..count]);
        }
        offset += cmsgAlign(header.len);
    }
}

fn cmsgAlign(length: usize) usize {
    const alignment: usize = @sizeOf(usize);
    return (length + alignment - 1) & ~(alignment - 1);
}

fn cmsgLength(payload: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + payload;
}
fn cmsgSpace(payload: usize) usize {
    return cmsgAlign(@sizeOf(linux.cmsghdr)) + cmsgAlign(payload);
}
fn align4(value: usize) usize {
    return (value + 3) & ~@as(usize, 3);
}
