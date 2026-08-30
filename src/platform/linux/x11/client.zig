const std = @import("std");
const config = @import("../../../config.zig");
const Error = @import("../../../core/error.zig").Error;
const sys = @import("../sys.zig");
const auth = @import("auth.zig");
const wire = @import("wire.zig");

const environment_bytes = 256 * 1024;
const maximum_setup_bytes = 16 * 1024 * 1024;
const maximum_packet_bytes = 64 * 1024 * 1024;
const receive_chunk_bytes = 64 * 1024;
const maximum_buffered_input_bytes = maximum_packet_bytes + receive_chunk_bytes;

pub const PixmapFormat = struct {
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
};

pub const Setup = struct {
    resource_base: u32,
    resource_mask: u32,
    maximum_request_words: u16,
    root: u32,
    root_visual: u32,
    root_depth: u8,
    white_pixel: u32,
    black_pixel: u32,
    width_pixels: u16,
    height_pixels: u16,
    minimum_keycode: u8,
    maximum_keycode: u8,
    root_format: PixmapFormat,
    presentation_visual: u32,
    presentation_depth: u8,
    presentation_format: PixmapFormat,
    presentation_has_alpha: bool,
};

pub const PacketKind = enum { error_packet, reply, event };

pub const Packet = struct {
    allocator: std.mem.Allocator,
    kind: PacketKind,
    bytes: []u8,

    pub fn sequence(self: Packet) u16 {
        return wire.readU16(self.bytes, 2) catch 0;
    }

    pub fn responseType(self: Packet) u8 {
        return if (self.bytes.len == 0) 0 else self.bytes[0] & 0x7f;
    }

    pub fn deinit(self: *Packet) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Endpoint = struct {
    socket_path: []u8,
    display_number: []u8,

    fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.socket_path);
        allocator.free(self.display_number);
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket: sys.fd_t,
    setup: Setup,
    sequence_value: u16 = 0,
    resource_cursor: u32,
    resource_increment: u32,
    input: std.ArrayList(u8) = .empty,
    input_cursor: usize = 0,
    pending_events: std.ArrayList(Packet) = .empty,
    pending_cursor: usize = 0,
    pending_bytes: usize = 0,
    maximum_pending_events: usize,
    maximum_pending_bytes: usize,
    broken: bool = false,

    pub fn connect(
        allocator: std.mem.Allocator,
        linux_config: config.LinuxConfig,
        maximum_pending_events: usize,
        maximum_pending_bytes: usize,
    ) Error!Client {
        if (maximum_pending_events == 0 or maximum_pending_bytes == 0)
            return error.InvalidConfiguration;
        var endpoint = try resolveEndpoint(allocator, linux_config.x11_display);
        defer endpoint.deinit(allocator);
        var credential = try auth.load(allocator, endpoint.display_number);
        defer credential.deinit();
        const socket = try sys.connectUnix(endpoint.socket_path);
        errdefer sys.close(socket);
        try sendSetup(socket, credential);
        const setup_bytes = try receiveSetup(allocator, socket);
        defer allocator.free(setup_bytes);
        const parsed = try parseSetup(setup_bytes);
        if (parsed.resource_mask == 0) return error.PlatformFailure;
        const increment = @as(u32, 1) << @intCast(@ctz(parsed.resource_mask));
        return .{
            .allocator = allocator,
            .socket = socket,
            .setup = parsed,
            .resource_cursor = increment,
            .resource_increment = increment,
            .maximum_pending_events = maximum_pending_events,
            .maximum_pending_bytes = maximum_pending_bytes,
        };
    }

    pub fn descriptor(self: *const Client) sys.fd_t {
        return self.socket;
    }

    pub fn maximumRequestBytes(self: *const Client) usize {
        return @as(usize, self.setup.maximum_request_words) * 4;
    }

    pub fn isBroken(self: *const Client) bool {
        return self.broken;
    }

    pub fn allocateId(self: *Client) Error!u32 {
        if (self.resource_cursor == 0 or self.resource_cursor & ~self.setup.resource_mask != 0) return error.OutOfSlots;
        const result = self.setup.resource_base | self.resource_cursor;
        self.resource_cursor = std.math.add(u32, self.resource_cursor, self.resource_increment) catch 0;
        return result;
    }

    pub fn send(self: *Client, request: []const u8, transferred_fd: ?sys.fd_t) Error!u16 {
        if (self.broken) return error.PlatformFailure;
        if (request.len < 4 or request.len & 3 != 0 or request.len > self.maximumRequestBytes()) return error.BudgetExceeded;
        const declared = try wire.readU16(request, 2);
        if (@as(usize, declared) * 4 != request.len) return error.InvalidConfiguration;
        if (transferred_fd) |fd| {
            sys.writeAllWithFd(self.socket, request, fd) catch |err| {
                self.broken = true;
                return err;
            };
        } else {
            sys.writeAll(self.socket, request) catch |err| {
                self.broken = true;
                return err;
            };
        }
        self.sequence_value +%= 1;
        return self.sequence_value;
    }

    pub fn waitReply(self: *Client, sequence: u16) Error!Packet {
        return self.waitReplyLimited(sequence, maximum_packet_bytes);
    }

    /// Waits for one reply while enforcing a request-specific cap from the
    /// 32-byte X11 header, before the declared body is read or duplicated.
    pub fn waitReplyLimited(self: *Client, sequence: u16, maximum_reply_bytes: usize) Error!Packet {
        if (self.broken) return error.PlatformFailure;
        if (maximum_reply_bytes < 32) return error.InvalidConfiguration;
        while (true) {
            var packet = (self.receivePacketWithReplyLimit(true, @min(maximum_reply_bytes, maximum_packet_bytes)) catch |err| {
                self.broken = true;
                return err;
            }) orelse
                return error.PlatformFailure;
            if (packet.kind == .event) {
                self.enqueuePending(packet) catch |err| {
                    self.broken = true;
                    return err;
                };
                continue;
            }
            if (packet.sequence() != sequence) {
                packet.deinit();
                self.broken = true;
                return error.PlatformFailure;
            }
            if (packet.kind == .error_packet) {
                packet.deinit();
                self.broken = true;
                return error.PlatformFailure;
            }
            return packet;
        }
    }

    pub fn nextEvent(self: *Client, wait: bool) Error!?Packet {
        if (self.broken) return error.PlatformFailure;
        if (self.pending_cursor < self.pending_events.items.len) {
            const result = self.pending_events.items[self.pending_cursor];
            self.pending_cursor += 1;
            self.pending_bytes -= result.bytes.len;
            self.compactPending();
            return result;
        }
        while (try self.receivePacket(wait)) |packet_value| {
            var packet = packet_value;
            switch (packet.kind) {
                .event => return packet,
                .error_packet => {
                    packet.deinit();
                    self.broken = true;
                    return error.PlatformFailure;
                },
                .reply => packet.deinit(),
            }
            if (!wait) return null;
        }
        return null;
    }

    pub fn deinit(self: *Client) void {
        for (self.pending_events.items[self.pending_cursor..]) |*packet| packet.deinit();
        self.pending_events.deinit(self.allocator);
        self.input.deinit(self.allocator);
        sys.close(self.socket);
        self.* = undefined;
    }

    fn receivePacket(self: *Client, wait: bool) Error!?Packet {
        return self.receivePacketWithReplyLimit(wait, maximum_packet_bytes);
    }

    fn receivePacketWithReplyLimit(self: *Client, wait: bool, maximum_reply_bytes: usize) Error!?Packet {
        while (self.available() < 32) {
            if (!try self.fill(wait)) return null;
        }
        const header = self.input.items[self.input_cursor..][0..32];
        const response_type = header[0];
        const extra_words: u32 = if (response_type == 1 or (response_type & 0x7f) == 35)
            try wire.readU32(header, 4)
        else
            0;
        const extra = std.math.mul(usize, extra_words, 4) catch return error.BudgetExceeded;
        const length = std.math.add(usize, 32, extra) catch return error.BudgetExceeded;
        if (length > maximum_packet_bytes) return error.BudgetExceeded;
        if (response_type == 1 and length > maximum_reply_bytes) return error.BudgetExceeded;
        while (self.available() < length) _ = try self.fill(true);
        const bytes = try self.allocator.dupe(u8, self.input.items[self.input_cursor..][0..length]);
        self.input_cursor += length;
        self.compactInput();
        return .{
            .allocator = self.allocator,
            .kind = if (response_type == 0) .error_packet else if (response_type == 1) .reply else .event,
            .bytes = bytes,
        };
    }

    fn enqueuePending(self: *Client, packet_source: Packet) Error!void {
        var packet = packet_source;
        if (self.pending_events.items.len - self.pending_cursor >= self.maximum_pending_events or
            packet.bytes.len > self.maximum_pending_bytes -| self.pending_bytes)
        {
            packet.deinit();
            return error.BudgetExceeded;
        }
        self.pending_events.append(self.allocator, packet) catch |err| {
            packet.deinit();
            return err;
        };
        self.pending_bytes += packet.bytes.len;
    }

    fn fill(self: *Client, wait: bool) Error!bool {
        if (wait) {
            var descriptors = [_]sys.linux.pollfd{.{ .fd = self.socket, .events = sys.linux.POLL.IN, .revents = 0 }};
            _ = sys.poll(&descriptors, -1) catch |err| {
                self.broken = true;
                return err;
            };
            if (descriptors[0].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0) {
                self.broken = true;
                return error.PlatformFailure;
            }
        }
        if (self.input.items.len > maximum_buffered_input_bytes - receive_chunk_bytes) {
            self.broken = true;
            return error.BudgetExceeded;
        }
        var temporary: [receive_chunk_bytes]u8 = undefined;
        const read_result = sys.readNonBlocking(self.socket, &temporary) catch |err| {
            self.broken = true;
            return err;
        };
        switch (read_result) {
            .would_block => return false,
            .end_of_file => {
                self.broken = true;
                return error.PlatformFailure;
            },
            .bytes => |count| {
                try self.input.appendSlice(self.allocator, temporary[0..count]);
                return true;
            },
        }
    }

    fn available(self: *const Client) usize {
        return self.input.items.len -| self.input_cursor;
    }

    fn compactInput(self: *Client) void {
        if (self.input_cursor == 0) return;
        if (self.input_cursor < 64 * 1024 and self.input_cursor * 2 < self.input.items.len) return;
        const remaining = self.available();
        std.mem.copyForwards(u8, self.input.items[0..remaining], self.input.items[self.input_cursor..]);
        self.input.items.len = remaining;
        self.input_cursor = 0;
    }

    fn compactPending(self: *Client) void {
        if (self.pending_cursor == self.pending_events.items.len) {
            self.pending_events.clearRetainingCapacity();
            self.pending_cursor = 0;
        } else if (self.pending_cursor > 256 and self.pending_cursor * 2 >= self.pending_events.items.len) {
            const remaining = self.pending_events.items.len - self.pending_cursor;
            std.mem.copyForwards(Packet, self.pending_events.items[0..remaining], self.pending_events.items[self.pending_cursor..]);
            self.pending_events.items.len = remaining;
            self.pending_cursor = 0;
        }
    }
};

fn resolveEndpoint(allocator: std.mem.Allocator, configured: ?[]const u8) Error!Endpoint {
    var environment: [environment_bytes]u8 = undefined;
    const display = configured orelse (try sys.initialEnvironment("DISPLAY", &environment)) orelse return error.MissingCapability;
    const colon = std.mem.lastIndexOfScalar(u8, display, ':') orelse return error.InvalidConfiguration;
    const host = display[0..colon];
    if (host.len != 0 and !std.mem.eql(u8, host, "unix") and !std.mem.eql(u8, host, "localhost") and
        !std.mem.endsWith(u8, host, "/unix")) return error.Unsupported;
    const suffix = display[colon + 1 ..];
    const dot = std.mem.indexOfScalar(u8, suffix, '.') orelse suffix.len;
    const number = suffix[0..dot];
    if (number.len == 0 or number.len > 10) return error.InvalidConfiguration;
    for (number) |character| if (!std.ascii.isDigit(character)) return error.InvalidConfiguration;
    const socket_path = try std.fmt.allocPrint(allocator, "/tmp/.X11-unix/X{s}", .{number});
    errdefer allocator.free(socket_path);
    return .{ .socket_path = socket_path, .display_number = try allocator.dupe(u8, number) };
}

fn sendSetup(socket: sys.fd_t, credential: auth.Credential) Error!void {
    if (credential.name.len > std.math.maxInt(u16) or credential.data.len > std.math.maxInt(u16)) return error.BudgetExceeded;
    var fixed: [12]u8 = @splat(0);
    fixed[0] = 'l';
    std.mem.writeInt(u16, fixed[2..4], 11, .little);
    std.mem.writeInt(u16, fixed[6..8], @intCast(credential.name.len), .little);
    std.mem.writeInt(u16, fixed[8..10], @intCast(credential.data.len), .little);
    try sys.writeAll(socket, &fixed);
    try sys.writeAll(socket, credential.name);
    const padding: [4]u8 = @splat(0);
    const name_padding = (4 - credential.name.len % 4) % 4;
    if (name_padding != 0) try sys.writeAll(socket, padding[0..name_padding]);
    try sys.writeAll(socket, credential.data);
    const data_padding = (4 - credential.data.len % 4) % 4;
    if (data_padding != 0) try sys.writeAll(socket, padding[0..data_padding]);
}

fn receiveSetup(allocator: std.mem.Allocator, socket: sys.fd_t) Error![]u8 {
    var prefix: [8]u8 = undefined;
    try readExact(socket, &prefix);
    const words = std.mem.readInt(u16, prefix[6..8], .little);
    const extra = std.math.mul(usize, words, 4) catch return error.BudgetExceeded;
    const total = std.math.add(usize, prefix.len, extra) catch return error.BudgetExceeded;
    if (total > maximum_setup_bytes) return error.BudgetExceeded;
    const result = try allocator.alloc(u8, total);
    errdefer allocator.free(result);
    @memcpy(result[0..8], &prefix);
    try readExact(socket, result[8..]);
    if (result[0] != 1) return error.PlatformFailure;
    return result;
}

fn readExact(socket: sys.fd_t, destination: []u8) Error!void {
    var cursor: usize = 0;
    while (cursor < destination.len) switch (try sys.readNonBlocking(socket, destination[cursor..])) {
        .bytes => |count| cursor += count,
        .would_block => {
            var descriptors = [_]sys.linux.pollfd{.{ .fd = socket, .events = sys.linux.POLL.IN, .revents = 0 }};
            _ = try sys.poll(&descriptors, -1);
            if (descriptors[0].revents & (sys.linux.POLL.ERR | sys.linux.POLL.HUP | sys.linux.POLL.NVAL) != 0)
                return error.PlatformFailure;
        },
        .end_of_file => return error.PlatformFailure,
    };
}

fn parseSetup(bytes: []const u8) Error!Setup {
    if (bytes.len < 40 or bytes[0] != 1) return error.PlatformFailure;
    const resource_base = try wire.readU32(bytes, 12);
    const resource_mask = try wire.readU32(bytes, 16);
    const vendor_length = try wire.readU16(bytes, 24);
    const maximum_request_words = try wire.readU16(bytes, 26);
    const root_count = bytes[28];
    const format_count = bytes[29];
    if (root_count == 0) return error.MissingCapability;
    var cursor = std.mem.alignForward(usize, 40 + @as(usize, vendor_length), 4);
    const formats_length = std.math.mul(usize, format_count, 8) catch return error.BudgetExceeded;
    if (cursor + formats_length > bytes.len) return error.PlatformFailure;
    const format_bytes = bytes[cursor..][0..formats_length];
    cursor += formats_length;
    if (cursor + 40 > bytes.len) return error.PlatformFailure;
    const root_depth = bytes[cursor + 38];
    var root_format: ?PixmapFormat = null;
    var argb_format: ?PixmapFormat = null;
    var format_cursor: usize = 0;
    while (format_cursor < format_bytes.len) : (format_cursor += 8) {
        const value: PixmapFormat = .{
            .depth = format_bytes[format_cursor],
            .bits_per_pixel = format_bytes[format_cursor + 1],
            .scanline_pad = format_bytes[format_cursor + 2],
        };
        if (value.depth == root_depth) root_format = value;
        if (value.depth == 32 and value.bits_per_pixel == 32) argb_format = value;
    }
    var argb_visual: ?u32 = null;
    const allowed_depth_count = bytes[cursor + 39];
    var depth_cursor = cursor + 40;
    var depth_index: usize = 0;
    while (depth_index < allowed_depth_count) : (depth_index += 1) {
        if (depth_cursor + 8 > bytes.len) return error.PlatformFailure;
        const depth = bytes[depth_cursor];
        const visual_count = try wire.readU16(bytes, depth_cursor + 2);
        depth_cursor += 8;
        var visual_index: usize = 0;
        while (visual_index < visual_count) : (visual_index += 1) {
            if (depth_cursor + 24 > bytes.len) return error.PlatformFailure;
            const visual_class = bytes[depth_cursor + 4];
            const red_mask = try wire.readU32(bytes, depth_cursor + 8);
            const green_mask = try wire.readU32(bytes, depth_cursor + 12);
            const blue_mask = try wire.readU32(bytes, depth_cursor + 16);
            if (depth == 32 and visual_class == 4 and red_mask == 0x00ff0000 and green_mask == 0x0000ff00 and blue_mask == 0x000000ff)
                argb_visual = try wire.readU32(bytes, depth_cursor);
            depth_cursor += 24;
        }
    }
    const selected_root_format = root_format orelse return error.MissingCapability;
    const use_argb = argb_visual != null and argb_format != null;
    return .{
        .resource_base = resource_base,
        .resource_mask = resource_mask,
        .maximum_request_words = maximum_request_words,
        .root = try wire.readU32(bytes, cursor),
        .root_visual = try wire.readU32(bytes, cursor + 32),
        .root_depth = root_depth,
        .white_pixel = try wire.readU32(bytes, cursor + 8),
        .black_pixel = try wire.readU32(bytes, cursor + 12),
        .width_pixels = try wire.readU16(bytes, cursor + 20),
        .height_pixels = try wire.readU16(bytes, cursor + 22),
        .minimum_keycode = bytes[34],
        .maximum_keycode = bytes[35],
        .root_format = selected_root_format,
        .presentation_visual = if (use_argb) argb_visual.? else try wire.readU32(bytes, cursor + 32),
        .presentation_depth = if (use_argb) 32 else root_depth,
        .presentation_format = if (use_argb) argb_format.? else selected_root_format,
        .presentation_has_alpha = use_argb,
    };
}
