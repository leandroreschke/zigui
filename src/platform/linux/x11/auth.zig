//! Bounded Xauthority parser. Authentication bytes are consumed only by the
//! X11 setup handshake and are never logged, retained by the platform after
//! connection, or exposed through ZigUI APIs.

const std = @import("std");
const Error = @import("../../../core/error.zig").Error;
const sys = @import("../sys.zig");

const environment_bytes = 256 * 1024;
const maximum_file_bytes = 4 * 1024 * 1024;
const family_local: u16 = 256;
const family_wild: u16 = 65535;
var empty_storage: [0]u8 = .{};

pub const Credential = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    data: []u8,

    pub fn empty(allocator: std.mem.Allocator) Credential {
        return .{ .allocator = allocator, .name = empty_storage[0..], .data = empty_storage[0..] };
    }

    pub fn deinit(self: *Credential) void {
        if (self.name.len != 0) {
            @memset(self.name, 0);
            self.allocator.free(self.name);
        }
        if (self.data.len != 0) {
            @memset(self.data, 0);
            self.allocator.free(self.data);
        }
        self.* = undefined;
    }
};

pub fn load(allocator: std.mem.Allocator, display_number: []const u8) Error!Credential {
    const path = try authorityPath(allocator);
    defer if (path) |value| allocator.free(value);
    const selected_path = path orelse return Credential.empty(allocator);
    const bytes = sys.readFileAlloc(allocator, selected_path, maximum_file_bytes) catch return Credential.empty(allocator);
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }

    var cursor: usize = 0;
    var best: ?struct { name: []const u8, data: []const u8, score: u8 } = null;
    while (cursor < bytes.len) {
        const family = readU16Be(bytes, &cursor) catch break;
        const address = readField(bytes, &cursor) catch break;
        _ = address;
        const number = readField(bytes, &cursor) catch break;
        const name = readField(bytes, &cursor) catch break;
        const data = readField(bytes, &cursor) catch break;
        if (!std.mem.eql(u8, number, display_number)) continue;
        if (!std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1")) continue;
        const score: u8 = switch (family) {
            family_local => 2,
            family_wild => 1,
            else => 0,
        };
        if (score == 0 or (best != null and best.?.score >= score)) continue;
        best = .{ .name = name, .data = data, .score = score };
    }
    const value = best orelse return Credential.empty(allocator);
    const name = try allocator.dupe(u8, value.name);
    errdefer allocator.free(name);
    const data = try allocator.dupe(u8, value.data);
    return .{ .allocator = allocator, .name = name, .data = data };
}

fn authorityPath(allocator: std.mem.Allocator) Error!?[]u8 {
    var environment: [environment_bytes]u8 = undefined;
    if (try sys.initialEnvironment("XAUTHORITY", &environment)) |value| {
        if (value.len != 0 and std.fs.path.isAbsolute(value)) return try allocator.dupe(u8, value);
    }
    var home_environment: [environment_bytes]u8 = undefined;
    const home = (try sys.initialEnvironment("HOME", &home_environment)) orelse return null;
    if (!std.fs.path.isAbsolute(home)) return null;
    return try std.fs.path.join(allocator, &.{ home, ".Xauthority" });
}

fn readField(bytes: []const u8, cursor: *usize) Error![]const u8 {
    const length = try readU16Be(bytes, cursor);
    if (@as(usize, length) > bytes.len -| cursor.*) return error.PlatformFailure;
    defer cursor.* += length;
    return bytes[cursor.*..][0..length];
}

fn readU16Be(bytes: []const u8, cursor: *usize) Error!u16 {
    if (bytes.len -| cursor.* < 2) return error.PlatformFailure;
    defer cursor.* += 2;
    return std.mem.readInt(u16, bytes[cursor.*..][0..2], .big);
}
