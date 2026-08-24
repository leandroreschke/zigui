const std = @import("std");
const Error = @import("../../../core/error.zig").Error;
const maximum_request_bytes: usize = std.math.maxInt(u16) * 4;

pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Writer) void {
        self.bytes.clearRetainingCapacity();
    }

    pub fn begin(self: *Writer, opcode: u8, data: u8) Error!usize {
        const start = self.bytes.items.len;
        try self.ensureAdditional(4);
        try self.bytes.appendSlice(self.allocator, &.{ opcode, data, 0, 0 });
        return start;
    }

    pub fn finish(self: *Writer, start: usize) Error![]const u8 {
        if (start > self.bytes.items.len or self.bytes.items.len - start < 4)
            return error.InvalidConfiguration;
        try self.pad(4);
        const length = self.bytes.items.len - start;
        if (length > maximum_request_bytes or length / 4 > std.math.maxInt(u16))
            return error.BudgetExceeded;
        std.mem.writeInt(u16, self.bytes.items[start + 2 ..][0..2], @intCast(length / 4), .little);
        return self.bytes.items[start..];
    }

    pub fn byte(self: *Writer, value: u8) Error!void {
        try self.ensureAdditional(1);
        try self.bytes.append(self.allocator, value);
    }

    pub fn @"u16"(self: *Writer, value: u16) Error!void {
        try self.ensureAdditional(2);
        var storage: [2]u8 = undefined;
        std.mem.writeInt(u16, &storage, value, .little);
        try self.bytes.appendSlice(self.allocator, &storage);
    }

    pub fn @"i16"(self: *Writer, value: i16) Error!void {
        try self.u16(@bitCast(value));
    }

    pub fn @"u32"(self: *Writer, value: u32) Error!void {
        try self.ensureAdditional(4);
        var storage: [4]u8 = undefined;
        std.mem.writeInt(u32, &storage, value, .little);
        try self.bytes.appendSlice(self.allocator, &storage);
    }

    pub fn @"i32"(self: *Writer, value: i32) Error!void {
        try self.u32(@bitCast(value));
    }

    pub fn append(self: *Writer, values: []const u8) Error!void {
        try self.ensureAdditional(values.len);
        try self.bytes.appendSlice(self.allocator, values);
    }

    pub fn zeros(self: *Writer, count: usize) Error!void {
        try self.ensureAdditional(count);
        try self.bytes.appendNTimes(self.allocator, 0, count);
    }

    pub fn pad(self: *Writer, alignment: usize) Error!void {
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidConfiguration;
        const rounded = std.math.add(usize, self.bytes.items.len, alignment - 1) catch
            return error.BudgetExceeded;
        const target = rounded & ~(alignment - 1);
        try self.zeros(target - self.bytes.items.len);
    }

    fn ensureAdditional(self: *const Writer, count: usize) Error!void {
        if (count > maximum_request_bytes -| self.bytes.items.len) return error.BudgetExceeded;
    }
};

pub const Reader = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn remaining(self: Reader) usize {
        return self.bytes.len -| self.cursor;
    }

    pub fn skip(self: *Reader, count: usize) Error!void {
        if (count > self.remaining()) return error.PlatformFailure;
        self.cursor += count;
    }

    pub fn byte(self: *Reader) Error!u8 {
        if (self.remaining() < 1) return error.PlatformFailure;
        defer self.cursor += 1;
        return self.bytes[self.cursor];
    }

    pub fn @"u16"(self: *Reader) Error!u16 {
        if (self.remaining() < 2) return error.PlatformFailure;
        defer self.cursor += 2;
        return std.mem.readInt(u16, self.bytes[self.cursor..][0..2], .little);
    }

    pub fn @"i16"(self: *Reader) Error!i16 {
        return @bitCast(try self.u16());
    }

    pub fn @"u32"(self: *Reader) Error!u32 {
        if (self.remaining() < 4) return error.PlatformFailure;
        defer self.cursor += 4;
        return std.mem.readInt(u32, self.bytes[self.cursor..][0..4], .little);
    }

    pub fn @"i32"(self: *Reader) Error!i32 {
        return @bitCast(try self.u32());
    }

    pub fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.remaining()) return error.PlatformFailure;
        defer self.cursor += count;
        return self.bytes[self.cursor..][0..count];
    }
};

pub fn readU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return error.PlatformFailure;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

pub fn readI16(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try readU16(bytes, offset));
}

pub fn readU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.PlatformFailure;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

pub fn readI32(bytes: []const u8, offset: usize) Error!i32 {
    return @bitCast(try readU32(bytes, offset));
}
