//! Minimal complete D-Bus peer used by portals and AT-SPI. It speaks the bus
//! protocol directly over AF_UNIX and deliberately exposes typed messages,
//! not a dependency-shaped imitation of libdbus.

const std = @import("std");
const Error = @import("../../../core/error.zig").Error;
const sys = @import("../sys.zig");
pub const wire = @import("wire.zig");

const maximum_environment_bytes = 256 * 1024;
const maximum_auth_line_bytes = 16 * 1024;
const maximum_message_bytes = 128 * 1024 * 1024;
const maximum_pending_messages = 4096;
const maximum_pending_bytes = 128 * 1024 * 1024;

pub const Kind = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
};

pub const Fields = struct {
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
    unix_fds: u32 = 0,
};

pub const Message = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    kind: Kind,
    flags: u8,
    serial: u32,
    endian: std.builtin.Endian,
    body_offset: usize,
    body_length: usize,
    fields: Fields,

    pub fn bodyReader(self: *const Message) wire.Reader {
        return .{ .bytes = self.bytes[self.body_offset..][0..self.body_length], .endian = self.endian };
    }

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const MethodHandler = struct {
    context: *anyopaque,
    handle_fn: *const fn (*anyopaque, *Client, *const Message) Error!bool,

    fn handle(self: MethodHandler, client: *Client, message: *const Message) Error!bool {
        return self.handle_fn(self.context, client, message);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket: sys.fd_t,
    receive: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(Message) = .empty,
    pending_bytes: usize = 0,
    next_serial: u32 = 1,
    unique_name: ?[]u8 = null,
    method_handler: ?MethodHandler = null,
    broken: bool = false,

    pub fn connectSession(allocator: std.mem.Allocator) Error!Client {
        var environment: [maximum_environment_bytes]u8 = undefined;
        if (try sys.initialEnvironment("DBUS_SESSION_BUS_ADDRESS", &environment)) |address|
            return connectAddress(allocator, address, true);
        var fallback_buffer: [128]u8 = undefined;
        const fallback = std.fmt.bufPrint(&fallback_buffer, "unix:path=/run/user/{d}/bus", .{sys.linux.getuid()}) catch
            return error.PlatformFailure;
        return connectAddress(allocator, fallback, true);
    }

    pub fn connectAddress(allocator: std.mem.Allocator, address: []const u8, register_with_bus: bool) Error!Client {
        const socket = try connectFirstSupported(allocator, address);
        errdefer sys.close(socket);
        try authenticate(allocator, socket);
        var self: Client = .{ .allocator = allocator, .socket = socket };
        errdefer self.deinit();
        if (register_with_bus) {
            var body = wire.Writer.init(allocator);
            defer body.deinit();
            var reply = try self.call(
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
                "Hello",
                "",
                body.bytes.items,
            );
            defer reply.deinit();
            var reader = reply.bodyReader();
            const unique_name = try reader.string();
            if (unique_name.len == 0 or unique_name.len > 255) return error.PlatformFailure;
            self.unique_name = try allocator.dupe(u8, unique_name);
        }
        return self;
    }

    pub fn deinit(self: *Client) void {
        for (self.pending.items) |*message| message.deinit();
        self.pending.deinit(self.allocator);
        self.receive.deinit(self.allocator);
        if (self.unique_name) |value| self.allocator.free(value);
        sys.close(self.socket);
        self.* = undefined;
    }

    pub fn call(
        self: *Client,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
    ) Error!Message {
        const serial = try self.sendMethodCall(destination, path, interface, member, signature, body);
        return self.waitReply(serial);
    }

    pub fn sendMethodCall(
        self: *Client,
        destination: []const u8,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        signature: []const u8,
        body: []const u8,
    ) Error!u32 {
        var fields = wire.Writer.init(self.allocator);
        defer fields.deinit();
        try appendStringField(&fields, 1, "o", path);
        try appendStringField(&fields, 2, "s", interface);
        try appendStringField(&fields, 3, "s", member);
        try appendStringField(&fields, 6, "s", destination);
        if (signature.len != 0) try appendStringField(&fields, 8, "g", signature);
        const serial = self.allocateSerial();
        try self.sendMessage(.method_call, 0, serial, fields.bytes.items, body);
        return serial;
    }

    pub fn sendMethodReturn(self: *Client, reply_serial: u32, destination: ?[]const u8, signature: []const u8, body: []const u8) Error!void {
        var fields = wire.Writer.init(self.allocator);
        defer fields.deinit();
        try appendU32Field(&fields, 5, reply_serial);
        if (destination) |value| try appendStringField(&fields, 6, "s", value);
        if (signature.len != 0) try appendStringField(&fields, 8, "g", signature);
        try self.sendMessage(.method_return, 0, self.allocateSerial(), fields.bytes.items, body);
    }

    pub fn sendError(self: *Client, reply_serial: u32, destination: ?[]const u8, error_name: []const u8, message: []const u8) Error!void {
        var fields = wire.Writer.init(self.allocator);
        defer fields.deinit();
        try appendStringField(&fields, 4, "s", error_name);
        try appendU32Field(&fields, 5, reply_serial);
        if (destination) |value| try appendStringField(&fields, 6, "s", value);
        try appendStringField(&fields, 8, "g", "s");
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.string(message);
        try self.sendMessage(.error_reply, 0, self.allocateSerial(), fields.bytes.items, body.bytes.items);
    }

    pub fn sendSignal(self: *Client, path: []const u8, interface: []const u8, member: []const u8, signature: []const u8, body: []const u8) Error!void {
        var fields = wire.Writer.init(self.allocator);
        defer fields.deinit();
        try appendStringField(&fields, 1, "o", path);
        try appendStringField(&fields, 2, "s", interface);
        try appendStringField(&fields, 3, "s", member);
        if (signature.len != 0) try appendStringField(&fields, 8, "g", signature);
        try self.sendMessage(.signal, 0, self.allocateSerial(), fields.bytes.items, body);
    }

    pub fn addMatch(self: *Client, rule: []const u8) Error!void {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.string(rule);
        var reply = try self.call(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "AddMatch",
            "s",
            body.bytes.items,
        );
        reply.deinit();
    }

    pub fn setMethodHandler(self: *Client, handler: ?MethodHandler) void {
        self.method_handler = handler;
    }

    pub fn descriptor(self: *const Client) sys.fd_t {
        return self.socket;
    }

    pub fn isBroken(self: *const Client) bool {
        return self.broken;
    }

    pub fn busName(self: *const Client) []const u8 {
        return self.unique_name orelse "";
    }

    /// Services use this after registration to answer one incoming method
    /// call without retaining unrelated bus traffic. Synchronous clients use
    /// `call`, `waitSignal`, and `next` instead.
    pub fn dispatchIncoming(self: *Client, wait: bool) Error!bool {
        if (self.broken) return error.PlatformFailure;
        var message = (try self.nextWireMessage(wait)) orelse return false;
        defer message.deinit();
        if (message.kind == .method_call) self.dispatchMethod(&message) catch |err| {
            self.broken = true;
            return err;
        };
        return true;
    }

    pub fn next(self: *Client, wait: bool) Error!?Message {
        if (self.broken) return error.PlatformFailure;
        if (self.pending.items.len != 0) {
            const result = self.pending.orderedRemove(0);
            self.pending_bytes -= result.bytes.len;
            return result;
        }
        return self.nextWireMessage(wait);
    }

    pub fn waitSignal(self: *Client, path: []const u8, interface: []const u8, member: []const u8) Error!Message {
        if (self.broken) return error.PlatformFailure;
        var pending_index: usize = 0;
        while (pending_index < self.pending.items.len) : (pending_index += 1) {
            const message = &self.pending.items[pending_index];
            if (message.kind == .signal and optionalEqual(message.fields.path, path) and
                optionalEqual(message.fields.interface, interface) and optionalEqual(message.fields.member, member))
            {
                const result = self.pending.orderedRemove(pending_index);
                self.pending_bytes -= result.bytes.len;
                return result;
            }
        }
        while (true) {
            var message = (try self.nextWireMessage(true)) orelse continue;
            if (message.kind == .method_call) {
                self.dispatchMethod(&message) catch |err| {
                    message.deinit();
                    self.broken = true;
                    return err;
                };
                message.deinit();
                continue;
            }
            if (message.kind == .signal and optionalEqual(message.fields.path, path) and
                optionalEqual(message.fields.interface, interface) and optionalEqual(message.fields.member, member)) return message;
            try self.enqueuePending(message);
        }
    }

    fn waitReply(self: *Client, serial: u32) Error!Message {
        if (self.broken) return error.PlatformFailure;
        var index: usize = 0;
        while (index < self.pending.items.len) : (index += 1) {
            const message = &self.pending.items[index];
            if ((message.kind == .method_return or message.kind == .error_reply) and message.fields.reply_serial == serial) {
                var result = self.pending.orderedRemove(index);
                self.pending_bytes -= result.bytes.len;
                if (result.kind == .error_reply) {
                    result.deinit();
                    return error.PlatformFailure;
                }
                return result;
            }
        }
        while (true) {
            var message = (try self.nextWireMessage(true)) orelse continue;
            if (message.kind == .method_call) {
                self.dispatchMethod(&message) catch |err| {
                    message.deinit();
                    self.broken = true;
                    return err;
                };
                message.deinit();
                continue;
            }
            if ((message.kind == .method_return or message.kind == .error_reply) and message.fields.reply_serial == serial) {
                if (message.kind == .error_reply) {
                    message.deinit();
                    return error.PlatformFailure;
                }
                return message;
            }
            try self.enqueuePending(message);
        }
    }

    fn enqueuePending(self: *Client, message: Message) Error!void {
        if (self.pending.items.len >= maximum_pending_messages or
            message.bytes.len > maximum_pending_bytes -| self.pending_bytes)
        {
            var owned = message;
            owned.deinit();
            self.broken = true;
            return error.QueueFull;
        }
        self.pending.append(self.allocator, message) catch |err| {
            var owned = message;
            owned.deinit();
            self.broken = true;
            return err;
        };
        self.pending_bytes += message.bytes.len;
    }

    fn dispatchMethod(self: *Client, message: *const Message) Error!void {
        const handled = if (self.method_handler) |handler| try handler.handle(self, message) else false;
        if (!handled) try self.sendError(
            message.serial,
            message.fields.sender,
            "org.freedesktop.DBus.Error.UnknownMethod",
            "The requested object, interface, or method is not implemented",
        );
    }

    fn sendMessage(self: *Client, kind: Kind, flags: u8, serial: u32, fields: []const u8, body: []const u8) Error!void {
        if (self.broken) return error.PlatformFailure;
        if (fields.len > std.math.maxInt(u32) or body.len > std.math.maxInt(u32)) return error.BudgetExceeded;
        const fields_end = std.math.add(usize, 16, fields.len) catch return error.BudgetExceeded;
        const body_offset = try align8(fields_end);
        const total = std.math.add(usize, body_offset, body.len) catch return error.BudgetExceeded;
        if (total > maximum_message_bytes) return error.BudgetExceeded;
        const bytes = try self.allocator.alloc(u8, total);
        defer self.allocator.free(bytes);
        @memset(bytes, 0);
        bytes[0] = 'l';
        bytes[1] = @backingInt(kind);
        bytes[2] = flags;
        bytes[3] = 1;
        std.mem.writeInt(u32, bytes[4..8], @intCast(body.len), .little);
        std.mem.writeInt(u32, bytes[8..12], serial, .little);
        std.mem.writeInt(u32, bytes[12..16], @intCast(fields.len), .little);
        @memcpy(bytes[16..][0..fields.len], fields);
        @memcpy(bytes[body_offset..][0..body.len], body);
        sys.writeAll(self.socket, bytes) catch |err| {
            self.broken = true;
            return err;
        };
    }

    fn nextWireMessage(self: *Client, wait: bool) Error!?Message {
        if (self.broken) return error.PlatformFailure;
        while (true) {
            const extracted = extractMessage(self) catch |err| {
                self.broken = true;
                return err;
            };
            if (extracted) |message| return message;
            const status = try readMore(self, wait);
            switch (status) {
                .read => {},
                .would_block => return null,
                .end_of_file => {
                    self.broken = true;
                    return error.PlatformFailure;
                },
            }
        }
    }

    fn allocateSerial(self: *Client) u32 {
        const result = self.next_serial;
        self.next_serial +%= 1;
        if (self.next_serial == 0) self.next_serial = 1;
        return result;
    }
};

const ReadMore = enum { read, would_block, end_of_file };

fn readMore(self: *Client, wait: bool) Error!ReadMore {
    var temporary: [64 * 1024]u8 = undefined;
    while (true) {
        const remaining = maximum_message_bytes -| self.receive.items.len;
        if (remaining == 0) {
            self.broken = true;
            return error.BudgetExceeded;
        }
        const read_capacity = @min(temporary.len, remaining);
        try self.receive.ensureUnusedCapacity(self.allocator, read_capacity);
        const read_result = sys.readNonBlocking(self.socket, temporary[0..read_capacity]) catch |err| {
            self.broken = true;
            return err;
        };
        switch (read_result) {
            .bytes => |count| {
                self.receive.appendSliceAssumeCapacity(temporary[0..count]);
                return .read;
            },
            .end_of_file => {
                self.broken = true;
                return .end_of_file;
            },
            .would_block => if (!wait) return .would_block,
        }
        var descriptors = [_]sys.linux.pollfd{.{ .fd = self.socket, .events = sys.linux.POLL.IN, .revents = 0 }};
        _ = sys.poll(&descriptors, -1) catch |err| {
            self.broken = true;
            return err;
        };
        if (descriptors[0].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0) {
            self.broken = true;
            return .end_of_file;
        }
    }
}

fn extractMessage(self: *Client) Error!?Message {
    if (self.receive.items.len < 16) return null;
    const bytes = self.receive.items;
    const endian: std.builtin.Endian = switch (bytes[0]) {
        'l' => .little,
        'B' => .big,
        else => return error.PlatformFailure,
    };
    if (bytes[3] != 1) return error.PlatformFailure;
    const body_length = std.mem.readInt(u32, bytes[4..8], endian);
    const fields_length = std.mem.readInt(u32, bytes[12..16], endian);
    const fields_end = std.math.add(usize, 16, fields_length) catch return error.BudgetExceeded;
    const body_offset = try align8(fields_end);
    const total = std.math.add(usize, body_offset, body_length) catch return error.BudgetExceeded;
    if (total > maximum_message_bytes) return error.BudgetExceeded;
    if (bytes.len < total) return null;
    const owned = try self.allocator.dupe(u8, bytes[0..total]);
    const parsed = try parseMessage(self.allocator, owned, body_offset, body_length, fields_length);
    const remaining = bytes.len - total;
    if (remaining != 0) std.mem.copyForwards(u8, self.receive.items[0..remaining], self.receive.items[total..]);
    self.receive.items.len = remaining;
    return parsed;
}

fn parseMessage(allocator: std.mem.Allocator, bytes: []u8, body_offset: usize, body_length: usize, fields_length: usize) Error!Message {
    errdefer allocator.free(bytes);
    const kind = std.enums.fromInt(Kind, bytes[1]) orelse return error.PlatformFailure;
    const endian: std.builtin.Endian = if (bytes[0] == 'l') .little else .big;
    const serial = std.mem.readInt(u32, bytes[8..12], endian);
    if (serial == 0 or fields_length > bytes.len -| 16 or
        body_offset > bytes.len or body_length > bytes.len - body_offset)
        return error.PlatformFailure;
    var fields: Fields = .{};
    var known_fields: u16 = 0;
    var reader: wire.Reader = .{ .bytes = bytes[16..][0..fields_length], .endian = endian };
    while (reader.offset < reader.bytes.len) {
        try reader.beginStruct();
        if (reader.offset >= reader.bytes.len) break;
        const code = try reader.byte();
        const signature = try reader.variantHeader();
        if (code >= 1 and code <= 9) {
            const mask = @as(u16, 1) << @intCast(code - 1);
            if (known_fields & mask != 0) return error.PlatformFailure;
            known_fields |= mask;
        }
        switch (code) {
            1 => fields.path = try expectObjectPath(&reader, signature),
            2 => fields.interface = try expectString(&reader, signature),
            3 => fields.member = try expectString(&reader, signature),
            4 => fields.error_name = try expectString(&reader, signature),
            5 => fields.reply_serial = try expectU32(&reader, signature),
            6 => fields.destination = try expectString(&reader, signature),
            7 => fields.sender = try expectString(&reader, signature),
            8 => fields.signature = try expectSignature(&reader, signature),
            9 => fields.unix_fds = try expectU32(&reader, signature),
            else => try wire.skipValue(&reader, signature),
        }
    }
    if (fields.unix_fds != 0) return error.Unsupported;
    if (body_length != 0 and fields.signature.len == 0) return error.PlatformFailure;
    switch (kind) {
        .method_call => if (fields.path == null or fields.member == null) return error.PlatformFailure,
        .method_return => if (fields.reply_serial == null) return error.PlatformFailure,
        .error_reply => if (fields.error_name == null or fields.reply_serial == null) return error.PlatformFailure,
        .signal => if (fields.path == null or fields.interface == null or fields.member == null) return error.PlatformFailure,
    }
    return .{
        .allocator = allocator,
        .bytes = bytes,
        .kind = kind,
        .flags = bytes[2],
        .serial = serial,
        .endian = endian,
        .body_offset = body_offset,
        .body_length = body_length,
        .fields = fields,
    };
}

fn align8(value: usize) Error!usize {
    const rounded = std.math.add(usize, value, 7) catch return error.BudgetExceeded;
    return rounded & ~@as(usize, 7);
}

fn appendStringField(writer: *wire.Writer, code: u8, signature: []const u8, value: []const u8) Error!void {
    try writer.beginStruct();
    try writer.byte(code);
    try writer.variantHeader(signature);
    if (std.mem.eql(u8, signature, "o")) try writer.objectPath(value) else if (std.mem.eql(u8, signature, "g"))
        try writer.signature(value)
    else
        try writer.string(value);
}

fn appendU32Field(writer: *wire.Writer, code: u8, value: u32) Error!void {
    try writer.beginStruct();
    try writer.byte(code);
    try writer.variantHeader("u");
    try writer.u32(value);
}

fn expectString(reader: *wire.Reader, signature: []const u8) Error![]const u8 {
    if (!std.mem.eql(u8, signature, "s")) return error.PlatformFailure;
    return reader.string();
}

fn expectObjectPath(reader: *wire.Reader, signature: []const u8) Error![]const u8 {
    if (!std.mem.eql(u8, signature, "o")) return error.PlatformFailure;
    return reader.objectPath();
}

fn expectSignature(reader: *wire.Reader, signature: []const u8) Error![]const u8 {
    if (!std.mem.eql(u8, signature, "g")) return error.PlatformFailure;
    return reader.signature();
}

fn expectU32(reader: *wire.Reader, signature: []const u8) Error!u32 {
    if (!std.mem.eql(u8, signature, "u")) return error.PlatformFailure;
    return reader.u32();
}

fn optionalEqual(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |actual| std.mem.eql(u8, actual, expected) else false;
}

fn connectFirstSupported(allocator: std.mem.Allocator, addresses: []const u8) Error!sys.fd_t {
    var entries = std.mem.splitScalar(u8, addresses, ';');
    while (entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "unix:")) continue;
        var fields = std.mem.splitScalar(u8, entry[5..], ',');
        while (fields.next()) |field| {
            const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
            const key = field[0..equals];
            const encoded = field[equals + 1 ..];
            if (!std.mem.eql(u8, key, "path") and !std.mem.eql(u8, key, "abstract")) continue;
            const decoded = try decodeAddressValue(allocator, encoded);
            defer allocator.free(decoded);
            const result = if (std.mem.eql(u8, key, "path")) sys.connectUnix(decoded) else sys.connectUnixAbstract(decoded);
            const descriptor = result catch continue;
            return descriptor;
        }
    }
    return error.MissingCapability;
}

fn decodeAddressValue(allocator: std.mem.Allocator, value: []const u8) Error![]u8 {
    const result = try allocator.alloc(u8, value.len);
    errdefer allocator.free(result);
    var source: usize = 0;
    var destination: usize = 0;
    while (source < value.len) {
        if (value[source] == '%') {
            if (source + 2 >= value.len) return error.InvalidConfiguration;
            const upper = hexNibble(value[source + 1]) orelse return error.InvalidConfiguration;
            const lower = hexNibble(value[source + 2]) orelse return error.InvalidConfiguration;
            result[destination] = (@as(u8, upper) << 4) | lower;
            source += 3;
        } else {
            result[destination] = value[source];
            source += 1;
        }
        if (result[destination] == 0) return error.InvalidConfiguration;
        destination += 1;
    }
    return allocator.realloc(result, destination);
}

fn authenticate(allocator: std.mem.Allocator, socket: sys.fd_t) Error!void {
    try sys.writeAll(socket, &[_]u8{0});
    var decimal_buffer: [32]u8 = undefined;
    const decimal = std.fmt.bufPrint(&decimal_buffer, "{d}", .{sys.linux.getuid()}) catch return error.PlatformFailure;
    var command: std.ArrayList(u8) = .empty;
    defer command.deinit(allocator);
    try command.appendSlice(allocator, "AUTH EXTERNAL ");
    const alphabet = "0123456789ABCDEF";
    for (decimal) |character| {
        try command.append(allocator, alphabet[character >> 4]);
        try command.append(allocator, alphabet[character & 0x0f]);
    }
    try command.appendSlice(allocator, "\r\n");
    try sys.writeAll(socket, command.items);
    const response = try readAuthLine(allocator, socket);
    defer allocator.free(response);
    if (!std.mem.startsWith(u8, response, "OK ") and !std.mem.eql(u8, response, "OK")) return error.PlatformFailure;
    try sys.writeAll(socket, "BEGIN\r\n");
}

fn readAuthLine(allocator: std.mem.Allocator, socket: sys.fd_t) Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var byte_buffer: [256]u8 = undefined;
    while (result.items.len < maximum_auth_line_bytes) {
        const remaining = maximum_auth_line_bytes - result.items.len;
        switch (try sys.readNonBlocking(socket, byte_buffer[0..@min(byte_buffer.len, remaining)])) {
            .bytes => |count| {
                try result.appendSlice(allocator, byte_buffer[0..count]);
                if (std.mem.indexOf(u8, result.items, "\r\n")) |end| {
                    result.items.len = end;
                    return result.toOwnedSlice(allocator);
                }
            },
            .end_of_file => return error.PlatformFailure,
            .would_block => {
                var descriptors = [_]sys.linux.pollfd{.{ .fd = socket, .events = sys.linux.POLL.IN, .revents = 0 }};
                _ = try sys.poll(&descriptors, -1);
                if (descriptors[0].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0)
                    return error.PlatformFailure;
            },
        }
    }
    return error.BudgetExceeded;
}

fn hexNibble(value: u8) ?u4 {
    return switch (value) {
        '0'...'9' => @intCast(value - '0'),
        'a'...'f' => @intCast(value - 'a' + 10),
        'A'...'F' => @intCast(value - 'A' + 10),
        else => null,
    };
}
