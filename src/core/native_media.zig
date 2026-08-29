const std = @import("std");
const Error = @import("error.zig").Error;
const geometry = @import("geometry.zig");
const handles = @import("handle.zig");

/// A bounded, inline-owned user-presentable error string returned with a
/// native media state snapshot. The bytes are copied from the platform
/// provider and remain valid for the lifetime of the value containing this
/// description; no platform object or allocator is retained.
pub const ErrorDescription = struct {
    pub const maximum_bytes: usize = 512;

    bytes: [maximum_bytes]u8 = undefined,
    length: u16 = 0,

    /// Copies a valid UTF-8 description, truncating only at a code-point
    /// boundary when a platform supplies more than the public budget.
    pub fn init(value: []const u8) Error!ErrorDescription {
        if (!validText(value)) return error.InvalidUtf8;
        const length = boundedPrefixLength(value, maximum_bytes);
        var result: ErrorDescription = .{ .length = @intCast(length) };
        @memset(result.bytes[0..], 0);
        if (length != 0) @memcpy(result.bytes[0..length], value[0..length]);
        return result;
    }

    pub fn slice(self: *const ErrorDescription) []const u8 {
        return self.bytes[0..self.length];
    }

    pub fn isEmpty(self: *const ErrorDescription) bool {
        return self.length == 0;
    }

    pub fn validate(self: ErrorDescription) Error!void {
        if (self.length > maximum_bytes) return error.InvalidMedia;
        if (!validText(self.bytes[0..self.length])) return error.InvalidUtf8;
    }
};

/// One final window-space placement for a platform-owned native media layer.
pub const Placement = struct {
    id: handles.NativeMediaId,
    bounds: geometry.Rect,
    visible: bool = true,
};

fn validText(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn boundedPrefixLength(value: []const u8, maximum: usize) usize {
    var length = @min(value.len, maximum);
    while (length != 0 and !std.unicode.utf8ValidateSlice(value[0..length])) : (length -= 1) {}
    return length;
}

test "native media error descriptions are inline, bounded, and valid UTF-8" {
    const testing = std.testing;

    var description = try ErrorDescription.init("The media could not be decoded: café");
    try description.validate();
    try testing.expectEqualStrings("The media could not be decoded: café", description.slice());

    var oversized: [ErrorDescription.maximum_bytes + 2]u8 = undefined;
    @memset(oversized[0 .. ErrorDescription.maximum_bytes - 1], 'a');
    oversized[ErrorDescription.maximum_bytes - 1] = 0xc3;
    oversized[ErrorDescription.maximum_bytes] = 0xa9;
    oversized[ErrorDescription.maximum_bytes + 1] = '!';
    description = try ErrorDescription.init(&oversized);
    try testing.expectEqual(@as(usize, ErrorDescription.maximum_bytes - 1), description.slice().len);
    try testing.expect(std.unicode.utf8ValidateSlice(description.slice()));
    try description.validate();
}

test "native media error descriptions reject malformed text" {
    try std.testing.expectError(error.InvalidUtf8, ErrorDescription.init("bad\x00message"));
    try std.testing.expectError(error.InvalidUtf8, ErrorDescription.init("bad\xffmessage"));

    var malformed: ErrorDescription = .{ .length = 1 };
    malformed.bytes[0] = 0xff;
    try std.testing.expectError(error.InvalidUtf8, malformed.validate());
}
