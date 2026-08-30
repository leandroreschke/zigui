//! D-Bus marshaling primitives. All alignment and bounds checks are explicit;
//! callers build only the signatures they actually expose.

const std = @import("std");
const Error = @import("../../../core/error.zig").Error;
const maximum_marshaled_bytes = 128 * 1024 * 1024;
const maximum_signature_depth = 32;

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

    pub fn alignTo(self: *Writer, alignment: usize) Error!void {
        if (alignment == 0 or alignment > 8 or !std.math.isPowerOfTwo(alignment))
            return error.InvalidConfiguration;
        const rounded = std.math.add(usize, self.bytes.items.len, alignment - 1) catch
            return error.BudgetExceeded;
        const aligned = rounded & ~(alignment - 1);
        try self.zeros(aligned - self.bytes.items.len);
    }

    pub fn byte(self: *Writer, value: u8) Error!void {
        try self.ensureAdditional(1);
        try self.bytes.append(self.allocator, value);
    }

    pub fn boolean(self: *Writer, value: bool) Error!void {
        try self.u32(@intFromBool(value));
    }

    pub fn @"u16"(self: *Writer, value: u16) Error!void {
        try self.alignTo(2);
        const start = self.bytes.items.len;
        try self.zeros(2);
        std.mem.writeInt(u16, self.bytes.items[start..][0..2], value, .little);
    }

    pub fn @"i16"(self: *Writer, value: i16) Error!void {
        try self.u16(@bitCast(value));
    }

    pub fn @"u32"(self: *Writer, value: u32) Error!void {
        try self.alignTo(4);
        const start = self.bytes.items.len;
        try self.zeros(4);
        std.mem.writeInt(u32, self.bytes.items[start..][0..4], value, .little);
    }

    pub fn @"i32"(self: *Writer, value: i32) Error!void {
        try self.u32(@bitCast(value));
    }

    pub fn @"u64"(self: *Writer, value: u64) Error!void {
        try self.alignTo(8);
        const start = self.bytes.items.len;
        try self.zeros(8);
        std.mem.writeInt(u64, self.bytes.items[start..][0..8], value, .little);
    }

    pub fn @"i64"(self: *Writer, value: i64) Error!void {
        try self.u64(@bitCast(value));
    }

    pub fn @"f64"(self: *Writer, value: f64) Error!void {
        try self.u64(@bitCast(value));
    }

    pub fn string(self: *Writer, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(u32)) return error.BudgetExceeded;
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
            return error.InvalidUtf8;
        try self.u32(@intCast(value.len));
        try self.append(value);
        try self.byte(0);
    }

    pub fn objectPath(self: *Writer, value: []const u8) Error!void {
        if (!validObjectPath(value)) return error.InvalidConfiguration;
        try self.string(value);
    }

    pub fn signature(self: *Writer, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(u8) or !validSignature(value)) return error.InvalidConfiguration;
        try self.byte(@intCast(value.len));
        try self.append(value);
        try self.byte(0);
    }

    pub fn variantHeader(self: *Writer, signature_value: []const u8) Error!void {
        if (!validSingleSignature(signature_value)) return error.InvalidConfiguration;
        try self.signature(signature_value);
        try self.alignTo(try alignmentFor(signature_value));
    }

    pub fn beginArray(self: *Writer, element_alignment: usize) Error!ArrayToken {
        if (element_alignment == 0 or element_alignment > 8 or !std.math.isPowerOfTwo(element_alignment))
            return error.InvalidConfiguration;
        try self.alignTo(4);
        const length_offset = self.bytes.items.len;
        try self.zeros(4);
        try self.alignTo(element_alignment);
        return .{ .length_offset = length_offset, .payload_offset = self.bytes.items.len };
    }

    pub fn endArray(self: *Writer, token: ArrayToken) Error!void {
        if (token.length_offset > self.bytes.items.len or
            self.bytes.items.len - token.length_offset < 4 or
            token.payload_offset > self.bytes.items.len)
            return error.InvalidConfiguration;
        const length = self.bytes.items.len - token.payload_offset;
        if (length > std.math.maxInt(u32)) return error.BudgetExceeded;
        std.mem.writeInt(u32, self.bytes.items[token.length_offset..][0..4], @intCast(length), .little);
    }

    pub fn beginStruct(self: *Writer) Error!void {
        try self.alignTo(8);
    }

    pub fn append(self: *Writer, value: []const u8) Error!void {
        try self.ensureAdditional(value.len);
        try self.bytes.appendSlice(self.allocator, value);
    }

    pub fn zeros(self: *Writer, count: usize) Error!void {
        try self.ensureAdditional(count);
        try self.bytes.appendNTimes(self.allocator, 0, count);
    }

    fn ensureAdditional(self: *const Writer, count: usize) Error!void {
        if (count > maximum_marshaled_bytes -| self.bytes.items.len) return error.BudgetExceeded;
    }
};

pub const ArrayToken = struct {
    length_offset: usize,
    payload_offset: usize,
};

pub const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,
    endian: std.builtin.Endian = .little,

    pub fn remaining(self: Reader) usize {
        return self.bytes.len -| self.offset;
    }

    pub fn alignTo(self: *Reader, alignment: usize) Error!void {
        if (alignment == 0 or alignment > 8 or !std.math.isPowerOfTwo(alignment))
            return error.InvalidConfiguration;
        const rounded = std.math.add(usize, self.offset, alignment - 1) catch
            return error.BudgetExceeded;
        const aligned = rounded & ~(alignment - 1);
        if (aligned > self.bytes.len) return error.PlatformFailure;
        self.offset = aligned;
    }

    pub fn byte(self: *Reader) Error!u8 {
        if (self.offset >= self.bytes.len) return error.PlatformFailure;
        defer self.offset += 1;
        return self.bytes[self.offset];
    }

    pub fn boolean(self: *Reader) Error!bool {
        return switch (try self.u32()) {
            0 => false,
            1 => true,
            else => error.PlatformFailure,
        };
    }

    pub fn @"u16"(self: *Reader) Error!u16 {
        try self.alignTo(2);
        if (self.remaining() < 2) return error.PlatformFailure;
        defer self.offset += 2;
        return std.mem.readInt(u16, self.bytes[self.offset..][0..2], self.endian);
    }

    pub fn @"i16"(self: *Reader) Error!i16 {
        return @bitCast(try self.u16());
    }

    pub fn @"u32"(self: *Reader) Error!u32 {
        try self.alignTo(4);
        if (self.remaining() < 4) return error.PlatformFailure;
        defer self.offset += 4;
        return std.mem.readInt(u32, self.bytes[self.offset..][0..4], self.endian);
    }

    pub fn @"i32"(self: *Reader) Error!i32 {
        return @bitCast(try self.u32());
    }

    pub fn @"u64"(self: *Reader) Error!u64 {
        try self.alignTo(8);
        if (self.remaining() < 8) return error.PlatformFailure;
        defer self.offset += 8;
        return std.mem.readInt(u64, self.bytes[self.offset..][0..8], self.endian);
    }

    pub fn @"i64"(self: *Reader) Error!i64 {
        return @bitCast(try self.u64());
    }

    pub fn @"f64"(self: *Reader) Error!f64 {
        return @bitCast(try self.u64());
    }

    pub fn string(self: *Reader) Error![]const u8 {
        const length = try self.u32();
        if (@as(usize, length) >= self.remaining()) return error.PlatformFailure;
        const result = self.bytes[self.offset..][0..length];
        self.offset += @as(usize, length) + 1;
        if (self.bytes[self.offset - 1] != 0 or !std.unicode.utf8ValidateSlice(result)) return error.PlatformFailure;
        return result;
    }

    pub fn objectPath(self: *Reader) Error![]const u8 {
        const value = try self.string();
        if (!validObjectPath(value)) return error.PlatformFailure;
        return value;
    }

    pub fn signature(self: *Reader) Error![]const u8 {
        const length = try self.byte();
        if (@as(usize, length) >= self.remaining()) return error.PlatformFailure;
        const result = self.bytes[self.offset..][0..length];
        self.offset += @as(usize, length) + 1;
        if (self.bytes[self.offset - 1] != 0 or !validSignature(result)) return error.PlatformFailure;
        return result;
    }

    pub fn variantHeader(self: *Reader) Error![]const u8 {
        const value = try self.signature();
        if (!validSingleSignature(value)) return error.PlatformFailure;
        try self.alignTo(try alignmentFor(value));
        return value;
    }

    pub fn beginArray(self: *Reader, element_alignment: usize) Error!usize {
        const length = try self.u32();
        try self.alignTo(element_alignment);
        const end = std.math.add(usize, self.offset, length) catch return error.BudgetExceeded;
        if (end > self.bytes.len) return error.PlatformFailure;
        return end;
    }

    pub fn beginStruct(self: *Reader) Error!void {
        try self.alignTo(8);
    }
};

pub fn alignmentFor(signature_value: []const u8) Error!usize {
    if (signature_value.len == 0) return error.InvalidConfiguration;
    return switch (signature_value[0]) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 'h', 's', 'o', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => error.InvalidConfiguration,
    };
}

pub fn validObjectPath(value: []const u8) bool {
    if (value.len == 0 or value[0] != '/' or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    if (value.len == 1) return true;
    if (value[value.len - 1] == '/') return false;
    var components = std.mem.splitScalar(u8, value[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0) return false;
        for (component) |character| if (!std.ascii.isAlphanumeric(character) and character != '_') return false;
    }
    return true;
}

pub fn validSignature(value: []const u8) bool {
    if (value.len > 255 or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    var offset: usize = 0;
    while (offset < value.len) if (!parseCompleteType(value, &offset, 0, false)) return false;
    return true;
}

pub fn validSingleSignature(value: []const u8) bool {
    if (value.len == 0 or value.len > 255 or std.mem.indexOfScalar(u8, value, 0) != null)
        return false;
    var offset: usize = 0;
    return parseCompleteType(value, &offset, 0, false) and offset == value.len;
}

fn parseCompleteType(value: []const u8, offset: *usize, depth: usize, dictionary_allowed: bool) bool {
    if (offset.* >= value.len or depth > maximum_signature_depth) return false;
    const token = value[offset.*];
    offset.* += 1;
    switch (token) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'v', 'h' => return true,
        'a' => return parseCompleteType(value, offset, depth + 1, true),
        '(' => {
            var fields: usize = 0;
            while (offset.* < value.len and value[offset.*] != ')') {
                if (!parseCompleteType(value, offset, depth + 1, false)) return false;
                fields += 1;
            }
            if (fields == 0 or offset.* >= value.len or value[offset.*] != ')') return false;
            offset.* += 1;
            return true;
        },
        '{' => {
            if (!dictionary_allowed or offset.* >= value.len or !isBasicType(value[offset.*]))
                return false;
            offset.* += 1;
            if (!parseCompleteType(value, offset, depth + 1, false) or
                offset.* >= value.len or value[offset.*] != '}')
                return false;
            offset.* += 1;
            return true;
        },
        else => return false,
    }
}

fn isBasicType(token: u8) bool {
    return switch (token) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h' => true,
        else => false,
    };
}

pub fn skipValue(reader: *Reader, signature_value: []const u8) Error!void {
    return skipValueDepth(reader, signature_value, 0);
}

fn skipValueDepth(reader: *Reader, signature_value: []const u8, depth: usize) Error!void {
    if (depth > maximum_signature_depth) return error.BudgetExceeded;
    var signature_offset: usize = 0;
    try skipType(reader, signature_value, &signature_offset, depth);
    if (signature_offset != signature_value.len) return error.PlatformFailure;
}

fn skipType(reader: *Reader, signature_value: []const u8, signature_offset: *usize, depth: usize) Error!void {
    if (depth > maximum_signature_depth) return error.BudgetExceeded;
    if (signature_offset.* >= signature_value.len) return error.PlatformFailure;
    const token = signature_value[signature_offset.*];
    signature_offset.* += 1;
    switch (token) {
        'y' => _ = try reader.byte(),
        'b', 'u', 'i', 'h' => _ = try reader.u32(),
        'n', 'q' => _ = try reader.u16(),
        'x', 't', 'd' => _ = try reader.u64(),
        's' => _ = try reader.string(),
        'o' => _ = try reader.objectPath(),
        'g' => _ = try reader.signature(),
        'v' => {
            const nested = try reader.variantHeader();
            try skipValueDepth(reader, nested, depth + 1);
        },
        'a' => {
            const element_start = signature_offset.*;
            const element_end = try typeEnd(signature_value, element_start);
            const end = try reader.beginArray(try alignmentFor(signature_value[element_start..element_end]));
            reader.offset = end;
            signature_offset.* = element_end;
        },
        '(' => {
            try reader.beginStruct();
            while (true) {
                if (signature_offset.* >= signature_value.len) return error.PlatformFailure;
                if (signature_value[signature_offset.*] == ')') {
                    signature_offset.* += 1;
                    break;
                }
                try skipType(reader, signature_value, signature_offset, depth + 1);
            }
        },
        '{' => {
            try reader.beginStruct();
            while (true) {
                if (signature_offset.* >= signature_value.len) return error.PlatformFailure;
                if (signature_value[signature_offset.*] == '}') {
                    signature_offset.* += 1;
                    break;
                }
                try skipType(reader, signature_value, signature_offset, depth + 1);
            }
        },
        else => return error.PlatformFailure,
    }
}

fn typeEnd(signature_value: []const u8, start: usize) Error!usize {
    if (start >= signature_value.len) return error.PlatformFailure;
    return switch (signature_value[start]) {
        'a' => typeEnd(signature_value, start + 1),
        '(' => compoundEnd(signature_value, start + 1, ')'),
        '{' => compoundEnd(signature_value, start + 1, '}'),
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'v', 'h' => start + 1,
        else => error.PlatformFailure,
    };
}

fn compoundEnd(signature_value: []const u8, start: usize, terminator: u8) Error!usize {
    var offset = start;
    while (offset < signature_value.len and signature_value[offset] != terminator) offset = try typeEnd(signature_value, offset);
    if (offset >= signature_value.len) return error.PlatformFailure;
    return offset + 1;
}
