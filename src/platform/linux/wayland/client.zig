const std = @import("std");
const Error = @import("../../../core/error.zig").Error;
const sys = @import("../sys.zig");
const protocol = @import("protocol.zig");
const wire = @import("wire.zig");

const server_id_start: u32 = 0xff000000;

pub const ObjectState = enum { live, retired };

pub const Object = struct {
    interface: protocol.Interface,
    version: u32,
    owner: usize = 0,
    state: ObjectState = .live,
};

pub const ObjectTable = struct {
    allocator: std.mem.Allocator,
    objects: std.AutoHashMap(u32, Object),
    free_ids: std.ArrayList(u32) = .empty,
    next_id: u32 = 2,
    maximum_objects: usize,

    pub fn init(allocator: std.mem.Allocator, maximum_objects: usize) Error!ObjectTable {
        if (maximum_objects < 2) return error.InvalidConfiguration;
        var self: ObjectTable = .{
            .allocator = allocator,
            .objects = std.AutoHashMap(u32, Object).init(allocator),
            .maximum_objects = maximum_objects,
        };
        errdefer self.deinit();
        try self.objects.put(1, .{ .interface = .wl_display, .version = 1 });
        return self;
    }

    pub fn allocate(self: *ObjectTable, interface: protocol.Interface, version: u32, owner: usize) Error!u32 {
        if (version == 0 or version > interface.maximumVersion()) return error.InvalidConfiguration;
        if (self.objects.count() >= self.maximum_objects) return error.BudgetExceeded;
        const id = self.free_ids.pop() orelse blk: {
            if (self.next_id >= server_id_start) return error.OutOfSlots;
            const value = self.next_id;
            self.next_id += 1;
            break :blk value;
        };
        errdefer self.free_ids.append(self.allocator, id) catch {};
        try self.objects.putNoClobber(id, .{ .interface = interface, .version = version, .owner = owner });
        return id;
    }

    pub fn registerServer(self: *ObjectTable, id: u32, interface: protocol.Interface, version: u32, owner: usize) Error!void {
        if (id < server_id_start or version == 0 or version > interface.maximumVersion()) return error.PlatformFailure;
        if (self.objects.count() >= self.maximum_objects) return error.BudgetExceeded;
        try self.objects.putNoClobber(id, .{ .interface = interface, .version = version, .owner = owner });
    }

    pub fn get(self: *const ObjectTable, id: u32) ?Object {
        return self.objects.get(id);
    }

    pub fn getPtr(self: *ObjectTable, id: u32) ?*Object {
        return self.objects.getPtr(id);
    }

    pub fn retire(self: *ObjectTable, id: u32) Error!void {
        const object = self.objects.getPtr(id) orelse return error.InvalidHandle;
        if (object.state == .retired) return error.ResourceBusy;
        object.owner = 0;
        object.state = .retired;
    }

    pub fn abandon(self: *ObjectTable, id: u32) void {
        const removed = self.objects.fetchRemove(id) orelse return;
        if (id < server_id_start and id != 1) self.free_ids.append(self.allocator, id) catch {};
        _ = removed;
    }

    pub fn deleteId(self: *ObjectTable, id: u32) Error!void {
        if (id == 0 or id == 1 or id >= server_id_start) return error.PlatformFailure;
        _ = self.objects.fetchRemove(id) orelse return error.PlatformFailure;
        try self.free_ids.append(self.allocator, id);
    }

    pub fn removeServer(self: *ObjectTable, id: u32) Error!void {
        if (id < server_id_start) return error.PlatformFailure;
        _ = self.objects.fetchRemove(id) orelse return error.PlatformFailure;
    }

    pub fn deinit(self: *ObjectTable) void {
        self.free_ids.deinit(self.allocator);
        self.objects.deinit();
        self.* = undefined;
    }
};

pub const Global = struct {
    name: u32,
    interface: protocol.Interface,
    version: u32,
};

pub const Handler = struct {
    context: *anyopaque,
    event_fn: *const fn (*anyopaque, *Client, u32, Object, u16, *wire.Reader) Error!void,
    removed_fn: *const fn (*anyopaque, *Client, u32, Object) Error!void = ignoreRemoved,

    pub fn event(self: Handler, client: *Client, id: u32, object: Object, opcode: u16, reader: *wire.Reader) Error!void {
        try self.event_fn(self.context, client, id, object, opcode, reader);
    }

    pub fn removed(self: Handler, client: *Client, id: u32, object: Object) Error!void {
        try self.removed_fn(self.context, client, id, object);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    connection: wire.Connection,
    objects: ObjectTable,
    globals: std.AutoHashMap(u32, Global),
    registry: u32,
    maximum_globals: usize,

    pub fn connect(allocator: std.mem.Allocator, socket_path: []const u8, maximum_objects: usize) Error!Client {
        var connection = try wire.Connection.connect(allocator, socket_path);
        var connection_owned = true;
        errdefer if (connection_owned) connection.deinit();
        var objects = try ObjectTable.init(allocator, maximum_objects);
        var objects_owned = true;
        errdefer if (objects_owned) objects.deinit();
        const registry = try objects.allocate(.wl_registry, 1, 0);
        errdefer objects.abandon(registry);
        try protocol.displayGetRegistry(&connection, registry);
        var self: Client = .{
            .allocator = allocator,
            .connection = connection,
            .objects = objects,
            .globals = std.AutoHashMap(u32, Global).init(allocator),
            .registry = registry,
            .maximum_globals = maximum_objects,
        };
        connection_owned = false;
        objects_owned = false;
        errdefer self.deinit();
        try self.roundtrip();
        return self;
    }

    pub fn descriptor(self: *const Client) sys.fd_t {
        return self.connection.descriptor;
    }

    pub fn createObject(self: *Client, interface: protocol.Interface, version: u32, owner: usize) Error!u32 {
        return self.objects.allocate(interface, version, owner);
    }

    pub fn registerServerObject(self: *Client, id: u32, interface: protocol.Interface, version: u32, owner: usize) Error!void {
        try self.objects.registerServer(id, interface, version, owner);
    }

    pub fn bind(self: *Client, global: Global, owner: usize) Error!u32 {
        const version = @min(global.version, global.interface.maximumVersion());
        const id = try self.objects.allocate(global.interface, version, owner);
        errdefer self.objects.abandon(id);
        try protocol.registryBind(&self.connection, self.registry, global.name, global.interface, version, id);
        return id;
    }

    pub fn bindFirst(self: *Client, interface: protocol.Interface, owner: usize) Error!?u32 {
        var iterator = self.globals.valueIterator();
        while (iterator.next()) |global| if (global.interface == interface) return try self.bind(global.*, owner);
        return null;
    }

    pub fn findFirstGlobal(self: *const Client, interface: protocol.Interface) ?Global {
        var iterator = self.globals.valueIterator();
        while (iterator.next()) |global| if (global.interface == interface) return global.*;
        return null;
    }

    pub fn receive(self: *Client) Error!bool {
        return self.connection.receive();
    }

    pub fn dispatchBuffered(self: *Client, handler: Handler) Error!bool {
        if (self.connection.isBroken()) return error.PlatformFailure;
        const header = self.connection.peek() catch |err| {
            self.connection.markBroken();
            return err;
        } orelse return false;
        const object = self.objects.get(header.object) orelse {
            self.connection.markBroken();
            return error.PlatformFailure;
        };
        if (object.state == .retired) {
            self.connection.markBroken();
            return error.PlatformFailure;
        }
        const fd_count = protocol.eventFdCount(object.interface, header.opcode) catch |err| {
            self.connection.markBroken();
            return err;
        };
        const incoming = self.connection.next(fd_count) catch |err| {
            self.connection.markBroken();
            return err;
        } orelse return false;
        var reader: wire.Reader = .{ .payload = incoming.message.payload, .fds = incoming.fds };
        defer for (reader.fds[reader.fd_cursor..]) |fd| sys.close(fd);

        self.dispatchMessage(handler, header, object, &reader) catch |err| {
            self.connection.markBroken();
            return err;
        };
        return true;
    }

    fn dispatchMessage(
        self: *Client,
        handler: Handler,
        header: wire.Header,
        object: Object,
        reader: *wire.Reader,
    ) Error!void {
        switch (object.interface) {
            .wl_display => try self.handleDisplay(header.opcode, reader, handler),
            .wl_registry => {
                var internal = reader.*;
                try self.handleRegistry(header.opcode, &internal);
                try internal.finish();
                try handler.event(self, header.object, object, header.opcode, reader);
            },
            else => try handler.event(self, header.object, object, header.opcode, reader),
        }
        try reader.finish();
        if ((object.interface == .wl_callback and header.opcode == 0) or
            (object.interface == .wp_presentation_feedback and (header.opcode == 1 or header.opcode == 2)))
        {
            try self.objects.retire(header.object);
        }
    }

    pub fn drainBuffered(self: *Client, handler: Handler) Error!usize {
        var count: usize = 0;
        while (try self.dispatchBuffered(handler)) count += 1;
        return count;
    }

    pub fn roundtrip(self: *Client) Error!void {
        try self.roundtripWith(.{ .context = @ptrFromInt(1), .event_fn = discardEvent });
    }

    pub fn roundtripWith(self: *Client, delegate: Handler) Error!void {
        const callback = try self.objects.allocate(.wl_callback, 1, 0);
        var published = false;
        errdefer if (!published) self.objects.abandon(callback);
        try protocol.displaySync(&self.connection, callback);
        published = true;
        var state: Roundtrip = .{ .callback = callback, .delegate = delegate };
        const handler: Handler = .{ .context = &state, .event_fn = roundtripEvent };
        while (!state.done) {
            if (try self.dispatchBuffered(handler)) continue;
            if (!try self.receive()) {
                var descriptors = [_]sys.linux.pollfd{.{ .fd = self.descriptor(), .events = sys.linux.POLL.IN, .revents = 0 }};
                _ = try sys.poll(&descriptors, -1);
            }
        }
    }

    pub fn deinit(self: *Client) void {
        self.globals.deinit();
        self.objects.deinit();
        self.connection.deinit();
        self.* = undefined;
    }

    fn handleDisplay(self: *Client, opcode: u16, reader: *wire.Reader, handler: Handler) Error!void {
        switch (opcode) {
            0 => {
                _ = try reader.object();
                _ = try reader.u32();
                _ = try reader.string();
                return error.PlatformFailure;
            },
            1 => {
                const id = try reader.u32();
                const removed = self.objects.get(id) orelse return error.PlatformFailure;
                handler.removed(self, id, removed) catch |err| {
                    try self.objects.deleteId(id);
                    return err;
                };
                try self.objects.deleteId(id);
            },
            else => return error.PlatformFailure,
        }
    }

    fn handleRegistry(self: *Client, opcode: u16, reader: *wire.Reader) Error!void {
        switch (opcode) {
            0 => {
                const name = try reader.u32();
                const interface_name = try reader.string();
                const version = try reader.u32();
                const interface = protocol.Interface.parse(interface_name) orelse return;
                if (!self.globals.contains(name) and self.globals.count() >= self.maximum_globals)
                    return error.BudgetExceeded;
                try self.globals.put(name, .{ .name = name, .interface = interface, .version = version });
            },
            1 => {
                _ = self.globals.remove(try reader.u32());
            },
            else => return error.PlatformFailure,
        }
    }
};

const Roundtrip = struct {
    callback: u32,
    delegate: Handler,
    done: bool = false,
};

fn roundtripEvent(raw: *anyopaque, client_value: *Client, id: u32, object: Object, opcode: u16, reader: *wire.Reader) Error!void {
    const state: *Roundtrip = @ptrCast(@alignCast(raw));
    if (object.interface == .wl_callback and id == state.callback) {
        if (opcode != 0) return error.PlatformFailure;
        _ = try reader.u32();
        state.done = true;
        return;
    }
    try state.delegate.event(client_value, id, object, opcode, reader);
}

fn discardEvent(_: *anyopaque, _: *Client, _: u32, object: Object, opcode: u16, reader: *wire.Reader) Error!void {
    if (object.interface != .wl_registry) return error.PlatformFailure;
    switch (opcode) {
        0 => {
            _ = try reader.u32();
            _ = try reader.string();
            _ = try reader.u32();
        },
        1 => _ = try reader.u32(),
        else => return error.PlatformFailure,
    }
}

fn ignoreRemoved(_: *anyopaque, _: *Client, _: u32, _: Object) Error!void {}
