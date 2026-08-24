const std = @import("std");
const Error = @import("../../core/error.zig").Error;

pub const Limits = struct {
    maximum_bytes: usize = 64 * 1024 * 1024,
    maximum_path_bytes: usize = 1024 * 1024,
    maximum_paths: usize = 16_384,
};

pub fn parseFileUriList(allocator: std.mem.Allocator, bytes: []const u8) Error![][]const u8 {
    return parseFileUriListWithLimits(allocator, bytes, .{});
}

pub fn parseFileUriListWithLimits(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
) Error![][]const u8 {
    if (limits.maximum_bytes == 0 or limits.maximum_path_bytes == 0 or limits.maximum_paths == 0)
        return error.InvalidConfiguration;
    if (bytes.len > limits.maximum_bytes) return error.BudgetExceeded;
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(@constCast(path));
        paths.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len > limits.maximum_path_bytes or paths.items.len >= limits.maximum_paths)
            return error.BudgetExceeded;
        const path = (try decodeFileUriWithLimit(allocator, line, limits.maximum_path_bytes)) orelse continue;
        errdefer allocator.free(path);
        try paths.append(allocator, path);
    }
    return paths.toOwnedSlice(allocator);
}

pub fn decodeFileUri(allocator: std.mem.Allocator, uri: []const u8) Error!?[]u8 {
    return decodeFileUriWithLimit(allocator, uri, 64 * 1024 * 1024);
}

pub fn decodeFileUriWithLimit(allocator: std.mem.Allocator, uri: []const u8, maximum_bytes: usize) Error!?[]u8 {
    if (maximum_bytes == 0) return error.InvalidConfiguration;
    var encoded: []const u8 = undefined;
    if (std.mem.startsWith(u8, uri, "file://")) {
        const authority_and_path = uri[7..];
        if (authority_and_path.len == 0) return null;
        if (authority_and_path[0] == '/') {
            encoded = authority_and_path;
        } else {
            const slash = std.mem.indexOfScalar(u8, authority_and_path, '/') orelse return null;
            const authority = authority_and_path[0..slash];
            if (!std.ascii.eqlIgnoreCase(authority, "localhost")) return null;
            encoded = authority_and_path[slash..];
        }
    } else if (std.mem.startsWith(u8, uri, "file:/")) {
        encoded = uri[5..];
    } else return null;
    if (encoded.len == 0 or encoded[0] != '/') return null;
    if (encoded.len > maximum_bytes) return error.BudgetExceeded;
    const decoded = try percentDecode(allocator, encoded);
    errdefer allocator.free(decoded);
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidUtf8;
    return decoded;
}

fn percentDecode(allocator: std.mem.Allocator, encoded: []const u8) Error![]u8 {
    const decoded = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(decoded);
    var source: usize = 0;
    var destination: usize = 0;
    while (source < encoded.len) {
        if (encoded[source] == '%') {
            if (source + 2 >= encoded.len) return error.InvalidConfiguration;
            const upper = hexNibble(encoded[source + 1]) orelse return error.InvalidConfiguration;
            const lower = hexNibble(encoded[source + 2]) orelse return error.InvalidConfiguration;
            decoded[destination] = (@as(u8, upper) << 4) | lower;
            source += 3;
        } else {
            decoded[destination] = encoded[source];
            source += 1;
        }
        if (decoded[destination] == 0) return error.InvalidConfiguration;
        destination += 1;
    }
    return allocator.realloc(decoded, destination);
}

fn hexNibble(value: u8) ?u4 {
    return switch (value) {
        '0'...'9' => @intCast(value - '0'),
        'a'...'f' => @intCast(value - 'a' + 10),
        'A'...'F' => @intCast(value - 'A' + 10),
        else => null,
    };
}
