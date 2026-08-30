const std = @import("std");
const Error = @import("../../../core/error.zig").Error;
const client_mod = @import("client.zig");
const sys = @import("../sys.zig");
const wire = @import("wire.zig");

pub const none: u32 = 0;
pub const current_time: u32 = 0;
pub const copy_from_parent: u32 = 0;

pub const EventType = struct {
    pub const key_press: u8 = 2;
    pub const key_release: u8 = 3;
    pub const button_press: u8 = 4;
    pub const button_release: u8 = 5;
    pub const motion_notify: u8 = 6;
    pub const enter_notify: u8 = 7;
    pub const leave_notify: u8 = 8;
    pub const focus_in: u8 = 9;
    pub const focus_out: u8 = 10;
    pub const expose: u8 = 12;
    pub const visibility_notify: u8 = 15;
    pub const destroy_notify: u8 = 17;
    pub const unmap_notify: u8 = 18;
    pub const map_notify: u8 = 19;
    pub const configure_notify: u8 = 22;
    pub const property_notify: u8 = 28;
    pub const selection_clear: u8 = 29;
    pub const selection_request: u8 = 30;
    pub const selection_notify: u8 = 31;
    pub const client_message: u8 = 33;
    pub const mapping_notify: u8 = 34;
    pub const generic_event: u8 = 35;
};

pub const EventMask = struct {
    pub const key_press: u32 = 1 << 0;
    pub const key_release: u32 = 1 << 1;
    pub const button_press: u32 = 1 << 2;
    pub const button_release: u32 = 1 << 3;
    pub const enter_window: u32 = 1 << 4;
    pub const leave_window: u32 = 1 << 5;
    pub const pointer_motion: u32 = 1 << 6;
    pub const button_motion: u32 = 1 << 13;
    pub const exposure: u32 = 1 << 15;
    pub const visibility_change: u32 = 1 << 16;
    pub const structure_notify: u32 = 1 << 17;
    pub const substructure_notify: u32 = 1 << 19;
    pub const substructure_redirect: u32 = 1 << 20;
    pub const focus_change: u32 = 1 << 21;
    pub const property_change: u32 = 1 << 22;
};

pub const WindowValueMask = struct {
    pub const background_pixel: u32 = 1 << 1;
    pub const border_pixel: u32 = 1 << 3;
    pub const event_mask: u32 = 1 << 11;
    pub const override_redirect: u32 = 1 << 9;
    pub const cursor: u32 = 1 << 14;
    pub const colormap: u32 = 1 << 13;
};

pub const ConfigureMask = struct {
    pub const x: u16 = 1 << 0;
    pub const y: u16 = 1 << 1;
    pub const width: u16 = 1 << 2;
    pub const height: u16 = 1 << 3;
    pub const sibling: u16 = 1 << 5;
    pub const stack_mode: u16 = 1 << 6;
};

pub const PropertyMode = enum(u8) { replace = 0, prepend = 1, append = 2 };
pub const WindowClass = enum(u16) { copy = 0, input_output = 1, input_only = 2 };

pub const Extension = struct {
    present: bool,
    opcode: u8,
    first_event: u8,
    first_error: u8,
};

pub fn queryExtension(client: *client_mod.Client, writer: *wire.Writer, name: []const u8) Error!Extension {
    if (name.len > std.math.maxInt(u16)) return error.BudgetExceeded;
    writer.reset();
    const start = try writer.begin(98, 0);
    try writer.u16(@intCast(name.len));
    try writer.zeros(2);
    try writer.append(name);
    const sequence = try client.send(try writer.finish(start), null);
    var reply = try client.waitReply(sequence);
    defer reply.deinit();
    if (reply.bytes.len < 32) return error.PlatformFailure;
    return .{
        .present = reply.bytes[8] != 0,
        .opcode = reply.bytes[9],
        .first_event = reply.bytes[10],
        .first_error = reply.bytes[11],
    };
}

pub fn internAtom(client: *client_mod.Client, writer: *wire.Writer, name: []const u8, only_if_exists: bool) Error!u32 {
    if (name.len > std.math.maxInt(u16)) return error.BudgetExceeded;
    writer.reset();
    const start = try writer.begin(16, @intFromBool(only_if_exists));
    try writer.u16(@intCast(name.len));
    try writer.zeros(2);
    try writer.append(name);
    const sequence = try client.send(try writer.finish(start), null);
    var reply = try client.waitReply(sequence);
    defer reply.deinit();
    return wire.readU32(reply.bytes, 8);
}

pub fn getAtomName(
    client: *client_mod.Client,
    writer: *wire.Writer,
    allocator: std.mem.Allocator,
    atom: u32,
) Error![]u8 {
    if (atom == none) return error.InvalidConfiguration;
    writer.reset();
    const start = try writer.begin(17, 0);
    try writer.u32(atom);
    const sequence = try client.send(try writer.finish(start), null);
    var reply = try client.waitReply(sequence);
    defer reply.deinit();
    if (reply.bytes.len < 32) return error.PlatformFailure;
    const name_length = try wire.readU16(reply.bytes, 8);
    if (32 + @as(usize, name_length) > reply.bytes.len) return error.PlatformFailure;
    return allocator.dupe(u8, reply.bytes[32..][0..name_length]);
}

pub const RandrVersion = struct { major: u32, minor: u32 };

pub fn randrQueryVersion(
    client: *client_mod.Client,
    writer: *wire.Writer,
    extension: Extension,
) Error!RandrVersion {
    if (!extension.present) return error.MissingCapability;
    writer.reset();
    const start = try writer.begin(extension.opcode, 0);
    try writer.u32(1);
    try writer.u32(5);
    const sequence = try client.send(try writer.finish(start), null);
    var reply = try client.waitReply(sequence);
    defer reply.deinit();
    if (reply.bytes.len < 32) return error.PlatformFailure;
    return .{ .major = try wire.readU32(reply.bytes, 8), .minor = try wire.readU32(reply.bytes, 12) };
}

pub const RandrMonitor = struct {
    name_atom: u32,
    first_output: u32,
    primary: bool,
    automatic: bool,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    width_mm: u32,
    height_mm: u32,
};

pub const RandrMonitors = struct {
    allocator: std.mem.Allocator,
    values: []RandrMonitor,

    pub fn deinit(self: *RandrMonitors) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn randrGetMonitors(
    client: *client_mod.Client,
    writer: *wire.Writer,
    allocator: std.mem.Allocator,
    extension: Extension,
    window: u32,
    maximum_monitors: usize,
) Error!RandrMonitors {
    if (!extension.present) return error.MissingCapability;
    if (maximum_monitors == 0) return error.InvalidConfiguration;
    writer.reset();
    const start = try writer.begin(extension.opcode, 42);
    try writer.u32(window);
    try writer.byte(1);
    try writer.zeros(3);
    const sequence = try client.send(try writer.finish(start), null);
    var reply = try client.waitReply(sequence);
    defer reply.deinit();
    if (reply.bytes.len < 32) return error.PlatformFailure;
    const monitor_count_u32 = try wire.readU32(reply.bytes, 12);
    const output_count_u32 = try wire.readU32(reply.bytes, 16);
    const monitor_count: usize = @intCast(monitor_count_u32);
    const output_count: usize = @intCast(output_count_u32);
    if (monitor_count > maximum_monitors or output_count > maximum_monitors)
        return error.BudgetExceeded;
    if (monitor_count > (reply.bytes.len - 32) / 24) return error.PlatformFailure;
    const minimum_bytes = std.math.add(
        usize,
        std.math.mul(usize, monitor_count, 24) catch return error.BudgetExceeded,
        std.math.mul(usize, output_count, 4) catch return error.BudgetExceeded,
    ) catch return error.BudgetExceeded;
    if (minimum_bytes > reply.bytes.len - 32) return error.PlatformFailure;
    const values = try allocator.alloc(RandrMonitor, monitor_count);
    errdefer allocator.free(values);
    var cursor: usize = 32;
    var outputs_seen: usize = 0;
    for (values) |*monitor| {
        if (cursor + 24 > reply.bytes.len) return error.PlatformFailure;
        const monitor_output_count = try wire.readU16(reply.bytes, cursor + 6);
        const output_bytes = std.math.mul(usize, monitor_output_count, 4) catch return error.BudgetExceeded;
        if (cursor + 24 + output_bytes > reply.bytes.len) return error.PlatformFailure;
        monitor.* = .{
            .name_atom = try wire.readU32(reply.bytes, cursor),
            .first_output = if (monitor_output_count == 0) none else try wire.readU32(reply.bytes, cursor + 24),
            .primary = reply.bytes[cursor + 4] != 0,
            .automatic = reply.bytes[cursor + 5] != 0,
            .x = try wire.readI16(reply.bytes, cursor + 8),
            .y = try wire.readI16(reply.bytes, cursor + 10),
            .width = try wire.readU16(reply.bytes, cursor + 12),
            .height = try wire.readU16(reply.bytes, cursor + 14),
            .width_mm = try wire.readU32(reply.bytes, cursor + 16),
            .height_mm = try wire.readU32(reply.bytes, cursor + 20),
        };
        outputs_seen = std.math.add(usize, outputs_seen, monitor_output_count) catch return error.BudgetExceeded;
        cursor += 24 + output_bytes;
    }
    if (outputs_seen != output_count) return error.PlatformFailure;
    return .{ .allocator = allocator, .values = values };
}

pub fn createWindow(
    client: *client_mod.Client,
    writer: *wire.Writer,
    depth: u8,
    id: u32,
    parent: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    visual: u32,
    value_mask: u32,
    values: []const u32,
) Error!void {
    if (@popCount(value_mask) != values.len) return error.InvalidConfiguration;
    writer.reset();
    const start = try writer.begin(1, depth);
    try writer.u32(id);
    try writer.u32(parent);
    try writer.i16(x);
    try writer.i16(y);
    try writer.u16(width);
    try writer.u16(height);
    try writer.u16(0);
    try writer.u16(@backingInt(WindowClass.input_output));
    try writer.u32(visual);
    try writer.u32(value_mask);
    for (values) |value| try writer.u32(value);
    _ = try client.send(try writer.finish(start), null);
}

pub fn changeWindowAttributes(client: *client_mod.Client, writer: *wire.Writer, window: u32, mask: u32, values: []const u32) Error!void {
    if (@popCount(mask) != values.len) return error.InvalidConfiguration;
    writer.reset();
    const start = try writer.begin(2, 0);
    try writer.u32(window);
    try writer.u32(mask);
    for (values) |value| try writer.u32(value);
    _ = try client.send(try writer.finish(start), null);
}

pub fn destroyWindow(client: *client_mod.Client, writer: *wire.Writer, window: u32) Error!void {
    try resourceRequest(client, writer, 4, window);
}

pub fn mapWindow(client: *client_mod.Client, writer: *wire.Writer, window: u32) Error!void {
    try resourceRequest(client, writer, 8, window);
}

pub fn unmapWindow(client: *client_mod.Client, writer: *wire.Writer, window: u32) Error!void {
    try resourceRequest(client, writer, 10, window);
}

pub fn configureWindow(client: *client_mod.Client, writer: *wire.Writer, window: u32, mask: u16, values: []const u32) Error!void {
    if (@popCount(mask) != values.len) return error.InvalidConfiguration;
    writer.reset();
    const start = try writer.begin(12, 0);
    try writer.u32(window);
    try writer.u16(mask);
    try writer.zeros(2);
    for (values) |value| try writer.u32(value);
    _ = try client.send(try writer.finish(start), null);
}

pub fn changeProperty(
    client: *client_mod.Client,
    writer: *wire.Writer,
    mode: PropertyMode,
    window: u32,
    property: u32,
    property_type: u32,
    format: u8,
    data: []const u8,
) Error!void {
    if (format != 8 and format != 16 and format != 32) return error.InvalidConfiguration;
    const bytes_per_item: usize = format / 8;
    if (data.len % bytes_per_item != 0) return error.InvalidConfiguration;
    const count = data.len / bytes_per_item;
    if (count > std.math.maxInt(u32)) return error.BudgetExceeded;
    writer.reset();
    const start = try writer.begin(18, @backingInt(mode));
    try writer.u32(window);
    try writer.u32(property);
    try writer.u32(property_type);
    try writer.byte(format);
    try writer.zeros(3);
    try writer.u32(@intCast(count));
    try writer.append(data);
    _ = try client.send(try writer.finish(start), null);
}

pub fn deleteProperty(client: *client_mod.Client, writer: *wire.Writer, window: u32, property: u32) Error!void {
    writer.reset();
    const start = try writer.begin(19, 0);
    try writer.u32(window);
    try writer.u32(property);
    _ = try client.send(try writer.finish(start), null);
}

pub const Property = struct {
    allocator: std.mem.Allocator,
    property_type: u32,
    format: u8,
    bytes_after: u32,
    value: []u8,

    pub fn deinit(self: *Property) void {
        self.allocator.free(self.value);
        self.* = undefined;
    }
};

pub fn getProperty(
    client: *client_mod.Client,
    writer: *wire.Writer,
    allocator: std.mem.Allocator,
    delete: bool,
    window: u32,
    property: u32,
    property_type: u32,
    long_offset: u32,
    long_length: u32,
) Error!Property {
    writer.reset();
    const start = try writer.begin(20, @intFromBool(delete));
    try writer.u32(window);
    try writer.u32(property);
    try writer.u32(property_type);
    try writer.u32(long_offset);
    try writer.u32(long_length);
    const sequence = try client.send(try writer.finish(start), null);
    const requested_value_bytes = std.math.mul(usize, long_length, 4) catch return error.BudgetExceeded;
    const maximum_reply_bytes = std.math.add(usize, 32, requested_value_bytes) catch return error.BudgetExceeded;
    var reply = try client.waitReplyLimited(sequence, maximum_reply_bytes);
    defer reply.deinit();
    if (reply.bytes.len < 32) return error.PlatformFailure;
    const format = reply.bytes[1];
    const count = try wire.readU32(reply.bytes, 16);
    const byte_length = try propertyReplyByteLength(format, count, long_length);
    if (32 + byte_length > reply.bytes.len) return error.PlatformFailure;
    return .{
        .allocator = allocator,
        .property_type = try wire.readU32(reply.bytes, 8),
        .format = format,
        .bytes_after = try wire.readU32(reply.bytes, 12),
        .value = try allocator.dupe(u8, reply.bytes[32..][0..byte_length]),
    };
}

pub fn propertyReplyByteLength(format: u8, item_count: u32, requested_longs: u32) Error!usize {
    const bytes_per_item: usize = switch (format) {
        0 => 0,
        8 => 1,
        16 => 2,
        32 => 4,
        else => return error.PlatformFailure,
    };
    const byte_length = std.math.mul(usize, item_count, bytes_per_item) catch return error.BudgetExceeded;
    const requested_bytes = std.math.mul(usize, requested_longs, 4) catch return error.BudgetExceeded;
    if (byte_length > requested_bytes) return error.BudgetExceeded;
    return byte_length;
}

pub fn setSelectionOwner(client: *client_mod.Client, writer: *wire.Writer, owner: u32, selection: u32, time: u32) Error!void {
    writer.reset();
    const start = try writer.begin(22, 0);
    try writer.u32(owner);
    try writer.u32(selection);
    try writer.u32(time);
    _ = try client.send(try writer.finish(start), null);
}

pub fn convertSelection(
    client: *client_mod.Client,
    writer: *wire.Writer,
    requestor: u32,
    selection: u32,
    target: u32,
    property: u32,
    time: u32,
) Error!void {
    writer.reset();
    const start = try writer.begin(24, 0);
    try writer.u32(requestor);
    try writer.u32(selection);
    try writer.u32(target);
    try writer.u32(property);
    try writer.u32(time);
    _ = try client.send(try writer.finish(start), null);
}

pub fn sendEvent(client: *client_mod.Client, writer: *wire.Writer, propagate: bool, destination: u32, event_mask: u32, event: *const [32]u8) Error!void {
    writer.reset();
    const start = try writer.begin(25, @intFromBool(propagate));
    try writer.u32(destination);
    try writer.u32(event_mask);
    try writer.append(event);
    _ = try client.send(try writer.finish(start), null);
}

pub fn openFont(client: *client_mod.Client, writer: *wire.Writer, font: u32, name: []const u8) Error!void {
    if (name.len > std.math.maxInt(u16)) return error.BudgetExceeded;
    writer.reset();
    const start = try writer.begin(45, 0);
    try writer.u32(font);
    try writer.u16(@intCast(name.len));
    try writer.zeros(2);
    try writer.append(name);
    _ = try client.send(try writer.finish(start), null);
}

pub fn createPixmap(client: *client_mod.Client, writer: *wire.Writer, depth: u8, pixmap: u32, drawable: u32, width: u16, height: u16) Error!void {
    writer.reset();
    const start = try writer.begin(53, depth);
    try writer.u32(pixmap);
    try writer.u32(drawable);
    try writer.u16(width);
    try writer.u16(height);
    _ = try client.send(try writer.finish(start), null);
}

pub fn createGc(client: *client_mod.Client, writer: *wire.Writer, gc: u32, drawable: u32, mask: u32, values: []const u32) Error!void {
    if (@popCount(mask) != values.len) return error.InvalidConfiguration;
    writer.reset();
    const start = try writer.begin(55, 0);
    try writer.u32(gc);
    try writer.u32(drawable);
    try writer.u32(mask);
    for (values) |value| try writer.u32(value);
    _ = try client.send(try writer.finish(start), null);
}

pub fn freeGc(client: *client_mod.Client, writer: *wire.Writer, gc: u32) Error!void {
    try resourceRequest(client, writer, 60, gc);
}

pub fn fillRectangle(client: *client_mod.Client, writer: *wire.Writer, drawable: u32, gc: u32, x: i16, y: i16, width: u16, height: u16) Error!void {
    writer.reset();
    const start = try writer.begin(70, 0);
    try writer.u32(drawable);
    try writer.u32(gc);
    try writer.i16(x);
    try writer.i16(y);
    try writer.u16(width);
    try writer.u16(height);
    _ = try client.send(try writer.finish(start), null);
}

pub fn createCursor(
    client: *client_mod.Client,
    writer: *wire.Writer,
    cursor: u32,
    source: u32,
    mask: u32,
    hot_x: u16,
    hot_y: u16,
) Error!void {
    writer.reset();
    const start = try writer.begin(93, 0);
    try writer.u32(cursor);
    try writer.u32(source);
    try writer.u32(mask);
    try writer.zeros(12);
    try writer.u16(hot_x);
    try writer.u16(hot_y);
    _ = try client.send(try writer.finish(start), null);
}

pub fn closeFont(client: *client_mod.Client, writer: *wire.Writer, font: u32) Error!void {
    try resourceRequest(client, writer, 46, font);
}

pub fn createGlyphCursor(client: *client_mod.Client, writer: *wire.Writer, cursor: u32, font: u32, source: u16, mask: u16) Error!void {
    writer.reset();
    const start = try writer.begin(94, 0);
    try writer.u32(cursor);
    try writer.u32(font);
    try writer.u32(font);
    try writer.u16(source);
    try writer.u16(mask);
    try writer.u16(0);
    try writer.u16(0);
    try writer.u16(0);
    try writer.u16(std.math.maxInt(u16));
    try writer.u16(std.math.maxInt(u16));
    try writer.u16(std.math.maxInt(u16));
    _ = try client.send(try writer.finish(start), null);
}

pub fn freeCursor(client: *client_mod.Client, writer: *wire.Writer, cursor: u32) Error!void {
    try resourceRequest(client, writer, 95, cursor);
}

pub fn getKeyboardMapping(client: *client_mod.Client, writer: *wire.Writer, first: u8, count: u8) Error!client_mod.Packet {
    writer.reset();
    const start = try writer.begin(101, 0);
    try writer.byte(first);
    try writer.byte(count);
    try writer.zeros(2);
    const sequence = try client.send(try writer.finish(start), null);
    return client.waitReply(sequence);
}

pub fn getModifierMapping(client: *client_mod.Client, writer: *wire.Writer) Error!client_mod.Packet {
    writer.reset();
    const start = try writer.begin(119, 0);
    const sequence = try client.send(try writer.finish(start), null);
    return client.waitReply(sequence);
}

pub fn setInputFocus(client: *client_mod.Client, writer: *wire.Writer, window: u32, time: u32) Error!void {
    writer.reset();
    const start = try writer.begin(42, 1);
    try writer.u32(window);
    try writer.u32(time);
    _ = try client.send(try writer.finish(start), null);
}

pub fn createColormap(client: *client_mod.Client, writer: *wire.Writer, colormap: u32, window: u32, visual: u32) Error!void {
    writer.reset();
    const start = try writer.begin(78, 0);
    try writer.u32(colormap);
    try writer.u32(window);
    try writer.u32(visual);
    _ = try client.send(try writer.finish(start), null);
}

pub fn freeColormap(client: *client_mod.Client, writer: *wire.Writer, colormap: u32) Error!void {
    try resourceRequest(client, writer, 79, colormap);
}

pub fn dri3QueryVersion(client: *client_mod.Client, writer: *wire.Writer, extension: Extension) Error!struct { major: u32, minor: u32 } {
    writer.reset();
    const start = try writer.begin(extension.opcode, 0);
    try writer.u32(1);
    try writer.u32(4);
    const sequence = try client.send(try writer.finish(start), null);
    var reply = try client.waitReply(sequence);
    defer reply.deinit();
    return .{ .major = try wire.readU32(reply.bytes, 8), .minor = try wire.readU32(reply.bytes, 12) };
}

pub const ModifierList = struct {
    allocator: std.mem.Allocator,
    values: []u64,

    pub fn deinit(self: *ModifierList) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn dri3GetSupportedModifiers(
    client: *client_mod.Client,
    writer: *wire.Writer,
    allocator: std.mem.Allocator,
    extension: Extension,
    window: u32,
    depth: u8,
    bpp: u8,
    maximum_values: usize,
) Error!ModifierList {
    if (maximum_values == 0) return error.InvalidConfiguration;
    writer.reset();
    const start = try writer.begin(extension.opcode, 6);
    try writer.u32(window);
    try writer.byte(depth);
    try writer.byte(bpp);
    try writer.zeros(2);
    const sequence = try client.send(try writer.finish(start), null);
    var reply = try client.waitReply(sequence);
    defer reply.deinit();
    const window_count = try wire.readU32(reply.bytes, 8);
    const screen_count = try wire.readU32(reply.bytes, 12);
    const total = std.math.add(usize, window_count, screen_count) catch return error.BudgetExceeded;
    if (total > maximum_values) return error.BudgetExceeded;
    const values_bytes = std.math.mul(usize, total, 8) catch return error.BudgetExceeded;
    const required = std.math.add(usize, 32, values_bytes) catch return error.BudgetExceeded;
    if (required > reply.bytes.len) return error.PlatformFailure;
    var values: std.ArrayList(u64) = .empty;
    errdefer values.deinit(allocator);
    var index: usize = 0;
    while (index < total) : (index += 1) {
        const low = try wire.readU32(reply.bytes, 32 + index * 8);
        const high = try wire.readU32(reply.bytes, 36 + index * 8);
        const modifier = @as(u64, high) << 32 | low;
        var duplicate = false;
        for (values.items) |existing| if (existing == modifier) {
            duplicate = true;
            break;
        };
        if (!duplicate) try values.append(allocator, modifier);
    }
    return .{ .allocator = allocator, .values = try values.toOwnedSlice(allocator) };
}

pub fn dri3PixmapFromBuffers(
    client: *client_mod.Client,
    writer: *wire.Writer,
    extension: Extension,
    pixmap: u32,
    window: u32,
    width: u16,
    height: u16,
    stride: u32,
    offset: u32,
    depth: u8,
    bpp: u8,
    modifier: u64,
    descriptor: sys.fd_t,
) Error!void {
    writer.reset();
    const start = try writer.begin(extension.opcode, 7);
    try writer.u32(pixmap);
    try writer.u32(window);
    try writer.byte(1);
    try writer.zeros(3);
    try writer.u16(width);
    try writer.u16(height);
    try writer.u32(stride);
    try writer.u32(offset);
    try writer.zeros(24);
    try writer.byte(depth);
    try writer.byte(bpp);
    try writer.zeros(2);
    try writer.u32(@truncate(modifier));
    try writer.u32(@truncate(modifier >> 32));
    _ = try client.send(try writer.finish(start), descriptor);
}

pub fn presentQueryVersion(client: *client_mod.Client, writer: *wire.Writer, extension: Extension) Error!struct { major: u32, minor: u32 } {
    writer.reset();
    const start = try writer.begin(extension.opcode, 0);
    try writer.u32(1);
    try writer.u32(4);
    const sequence = try client.send(try writer.finish(start), null);
    var reply = try client.waitReply(sequence);
    defer reply.deinit();
    return .{ .major = try wire.readU32(reply.bytes, 8), .minor = try wire.readU32(reply.bytes, 12) };
}

pub fn presentSelectInput(client: *client_mod.Client, writer: *wire.Writer, extension: Extension, event_id: u32, window: u32, mask: u32) Error!void {
    writer.reset();
    const start = try writer.begin(extension.opcode, 3);
    try writer.u32(event_id);
    try writer.u32(window);
    try writer.u32(mask);
    _ = try client.send(try writer.finish(start), null);
}

pub fn presentPixmap(
    client: *client_mod.Client,
    writer: *wire.Writer,
    extension: Extension,
    window: u32,
    pixmap: u32,
    serial: u32,
) Error!void {
    _ = try client.send(try buildPresentPixmap(writer, extension, window, pixmap, serial), null);
}

pub fn buildPresentPixmap(
    writer: *wire.Writer,
    extension: Extension,
    window: u32,
    pixmap: u32,
    serial: u32,
) Error![]const u8 {
    writer.reset();
    const start = try writer.begin(extension.opcode, 1);
    try writer.u32(window);
    try writer.u32(pixmap);
    try writer.u32(serial);
    try writer.u32(none);
    try writer.u32(none);
    try writer.i16(0);
    try writer.i16(0);
    try writer.u32(none);
    try writer.u32(none);
    try writer.u32(none);
    try writer.u32(0);
    try writer.u32(0);
    try writer.u32(0);
    try writer.u32(0);
    try writer.u32(0);
    try writer.u32(0);
    try writer.u32(0);
    try writer.u32(0);
    return writer.finish(start);
}

pub fn freePixmap(client: *client_mod.Client, writer: *wire.Writer, pixmap: u32) Error!void {
    try resourceRequest(client, writer, 54, pixmap);
}

fn resourceRequest(client: *client_mod.Client, writer: *wire.Writer, opcode: u8, resource: u32) Error!void {
    writer.reset();
    const start = try writer.begin(opcode, 0);
    try writer.u32(resource);
    _ = try client.send(try writer.finish(start), null);
}
