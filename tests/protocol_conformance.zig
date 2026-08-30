const std = @import("std");
const ui = @import("zigui");
const wayland = ui.internal_protocol_test.wayland_wire;
const dbus = ui.internal_protocol_test.dbus_wire;
const x11 = ui.internal_protocol_test.x11_wire;
const x11_protocol = ui.internal_protocol_test.x11_protocol;

const testing = std.testing;

test "Wayland builders reject invalid identities strings and oversized messages" {
    var builder: wayland.Builder = .{};
    defer builder.deinit(testing.allocator);

    try testing.expectError(error.InvalidConfiguration, builder.begin(testing.allocator, 0, 1));
    try builder.begin(testing.allocator, 1, 2);
    try testing.expectError(error.InvalidConfiguration, builder.object(testing.allocator, 0));
    try testing.expectError(error.InvalidConfiguration, builder.newId(testing.allocator, 0));
    try testing.expectError(error.InvalidUtf8, builder.string(testing.allocator, "a\x00b"));
    try testing.expectError(error.InvalidConfiguration, builder.fixed(testing.allocator, 20_000_000));

    const oversized = try testing.allocator.alloc(u8, 65_528);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try testing.expectError(error.BudgetExceeded, builder.string(testing.allocator, oversized));
}

test "Wayland readers reject hostile cursors and embedded string terminators" {
    var hostile: wayland.Reader = .{ .payload = &.{}, .cursor = std.math.maxInt(usize) };
    try testing.expectError(error.PlatformFailure, hostile.u32());

    var builder: wayland.Builder = .{};
    defer builder.deinit(testing.allocator);
    try builder.begin(testing.allocator, 1, 0);
    try builder.string(testing.allocator, "ab");
    try builder.finish();
    builder.bytes.items[13] = 0;
    var reader: wayland.Reader = .{ .payload = builder.bytes.items[8..] };
    try testing.expectError(error.PlatformFailure, reader.string());

    var zero_object_bytes: [4]u8 = @splat(0);
    var object_reader: wayland.Reader = .{ .payload = &zero_object_bytes };
    try testing.expectError(error.PlatformFailure, object_reader.object());
}

test "D-Bus signatures accept complete grammar and reject malformed nesting" {
    try testing.expect(dbus.validSignature("a{sv}(is)"));
    try testing.expect(dbus.validSingleSignature("a{sv}"));
    try testing.expect(!dbus.validSingleSignature(""));
    try testing.expect(!dbus.validSignature("{sv}"));
    try testing.expect(!dbus.validSignature("()"));
    try testing.expect(!dbus.validSignature("a"));
    try testing.expect(!dbus.validSingleSignature("uu"));

    var too_deep: [40]u8 = @splat('a');
    too_deep[too_deep.len - 1] = 'u';
    try testing.expect(!dbus.validSingleSignature(&too_deep));
}

test "D-Bus readers reject hostile cursors without arithmetic traps" {
    var reader: dbus.Reader = .{ .bytes = &.{}, .offset = std.math.maxInt(usize) };
    try testing.expectError(error.BudgetExceeded, reader.alignTo(8));
    try testing.expectError(error.BudgetExceeded, reader.u32());
    var out_of_range: dbus.Reader = .{ .bytes = &.{}, .offset = 4 };
    try testing.expectError(error.PlatformFailure, out_of_range.u32());
}

test "D-Bus value skipping enforces aggregate nested-variant depth" {
    var shallow = dbus.Writer.init(testing.allocator);
    defer shallow.deinit();
    for (0..4) |_| try shallow.variantHeader("v");
    try shallow.variantHeader("u");
    try shallow.u32(7);
    var shallow_reader: dbus.Reader = .{ .bytes = shallow.bytes.items };
    try dbus.skipValue(&shallow_reader, "v");
    try testing.expectEqual(shallow.bytes.items.len, shallow_reader.offset);

    var hostile = dbus.Writer.init(testing.allocator);
    defer hostile.deinit();
    for (0..34) |_| try hostile.variantHeader("v");
    try hostile.variantHeader("u");
    try hostile.u32(7);
    var hostile_reader: dbus.Reader = .{ .bytes = hostile.bytes.items };
    try testing.expectError(error.BudgetExceeded, dbus.skipValue(&hostile_reader, "v"));
}

test "X11 request construction is bounded before allocation" {
    var writer = x11.Writer.init(testing.allocator);
    defer writer.deinit();
    const start = try writer.begin(1, 0);

    const oversized = try testing.allocator.alloc(u8, 262_141);
    defer testing.allocator.free(oversized);
    @memset(oversized, 0);
    try testing.expectError(error.BudgetExceeded, writer.append(oversized));
    try testing.expectError(error.InvalidConfiguration, writer.finish(std.math.maxInt(usize)));

    try writer.u32(7);
    const request = try writer.finish(start);
    try testing.expectEqual(@as(usize, 8), request.len);
}

test "X11 readers reject hostile cursors without arithmetic traps" {
    var reader: x11.Reader = .{ .bytes = &.{}, .cursor = std.math.maxInt(usize) };
    try testing.expectError(error.PlatformFailure, reader.u32());
}

test "X11 PresentPixmap request has the fixed Present 1.4 wire size" {
    var writer = x11.Writer.init(testing.allocator);
    defer writer.deinit();
    const request = try x11_protocol.buildPresentPixmap(&writer, .{
        .present = true,
        .opcode = 146,
        .first_event = 0,
        .first_error = 0,
    }, 0x100, 0x200, 7);

    try testing.expectEqual(@as(usize, 72), request.len);
    try testing.expectEqual(@as(u8, 146), request[0]);
    try testing.expectEqual(@as(u8, 1), request[1]);
    try testing.expectEqual(@as(u16, 18), try x11.readU16(request, 2));
}

test "X11 property replies cannot exceed the requested long count" {
    try testing.expectEqual(@as(usize, 16), try x11_protocol.propertyReplyByteLength(8, 16, 4));
    try testing.expectEqual(@as(usize, 16), try x11_protocol.propertyReplyByteLength(16, 8, 4));
    try testing.expectEqual(@as(usize, 16), try x11_protocol.propertyReplyByteLength(32, 4, 4));
    try testing.expectError(error.BudgetExceeded, x11_protocol.propertyReplyByteLength(8, 17, 4));
    try testing.expectError(error.BudgetExceeded, x11_protocol.propertyReplyByteLength(16, 9, 4));
    try testing.expectError(error.BudgetExceeded, x11_protocol.propertyReplyByteLength(32, 5, 4));
    try testing.expectError(error.PlatformFailure, x11_protocol.propertyReplyByteLength(24, 1, 1));
}
