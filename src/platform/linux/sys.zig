const std = @import("std");
const Error = @import("../../core/error.zig").Error;

pub const linux = std.os.linux;
pub const fd_t = linux.fd_t;
const maximum_path_bytes = 4095;

const SockAddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

pub fn connectUnix(path: []const u8) Error!fd_t {
    if (path.len == 0 or path.len >= @sizeOf(SockAddrUn) - @offsetOf(SockAddrUn, "path"))
        return error.InvalidConfiguration;
    const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.PlatformFailure;
    const descriptor: fd_t = @intCast(result);
    errdefer close(descriptor);
    var address: SockAddrUn = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(address.path[0..path.len], path);
    const address_length: linux.socklen_t = @intCast(@offsetOf(SockAddrUn, "path") + path.len + 1);
    const status = linux.connect(descriptor, &address, address_length);
    if (linux.errno(status) != .SUCCESS) return error.PlatformFailure;
    try setNonBlocking(descriptor);
    return descriptor;
}

pub fn connectUnixAbstract(name: []const u8) Error!fd_t {
    if (name.len == 0 or name.len + 1 > @sizeOf(SockAddrUn) - @offsetOf(SockAddrUn, "path"))
        return error.InvalidConfiguration;
    const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.PlatformFailure;
    const descriptor: fd_t = @intCast(result);
    errdefer close(descriptor);
    var address: SockAddrUn = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    @memcpy(address.path[1..][0..name.len], name);
    const address_length: linux.socklen_t = @intCast(@offsetOf(SockAddrUn, "path") + 1 + name.len);
    const status = linux.connect(descriptor, &address, address_length);
    if (linux.errno(status) != .SUCCESS) return error.PlatformFailure;
    try setNonBlocking(descriptor);
    return descriptor;
}

pub fn setNonBlocking(descriptor: fd_t) Error!void {
    const current = linux.fcntl(descriptor, linux.F.GETFL, 0);
    if (linux.errno(current) != .SUCCESS) return error.PlatformFailure;
    var flags: linux.O = @bitCast(@as(u32, @truncate(current)));
    flags.NONBLOCK = true;
    const status = linux.fcntl(descriptor, linux.F.SETFL, @as(u32, @bitCast(flags)));
    if (linux.errno(status) != .SUCCESS) return error.PlatformFailure;
}

pub fn close(descriptor: fd_t) void {
    _ = linux.close(descriptor);
}

pub fn openReadOnly(path: []const u8) Error!fd_t {
    var flags: linux.O = .{};
    flags.CLOEXEC = true;
    return openPath(path, flags);
}

pub fn openDirectory(path: []const u8) Error!fd_t {
    var flags: linux.O = .{};
    flags.CLOEXEC = true;
    flags.DIRECTORY = true;
    return openPath(path, flags);
}

fn openPath(path: []const u8, flags: linux.O) Error!fd_t {
    if (path.len == 0 or path.len > maximum_path_bytes or path[0] != '/') return error.InvalidConfiguration;
    var terminated: [maximum_path_bytes + 1]u8 = undefined;
    @memcpy(terminated[0..path.len], path);
    terminated[path.len] = 0;
    const result = linux.open(@ptrCast(&terminated), flags, 0);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .NOENT, .NOTDIR, .ACCES, .PERM => error.MissingCapability,
        .NOMEM => error.OutOfMemory,
        else => error.PlatformFailure,
    };
}

pub fn fileSize(descriptor: fd_t) Error!usize {
    const result = linux.lseek(descriptor, 0, linux.SEEK.END);
    return switch (linux.errno(result)) {
        .SUCCESS => std.math.cast(usize, result) orelse error.BudgetExceeded,
        .NOMEM => error.OutOfMemory,
        else => error.PlatformFailure,
    };
}

pub const MappedFile = struct {
    bytes: []const u8,

    pub fn deinit(self: *MappedFile) void {
        if (self.bytes.len != 0) _ = linux.munmap(self.bytes.ptr, self.bytes.len);
        self.* = undefined;
    }
};

pub fn mapFileReadOnly(path: []const u8, maximum_bytes: usize) Error!MappedFile {
    const descriptor = try openReadOnly(path);
    defer close(descriptor);
    const size = try fileSize(descriptor);
    if (size == 0 or size > maximum_bytes) return error.BudgetExceeded;
    const address = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, descriptor, 0);
    switch (linux.errno(address)) {
        .SUCCESS => {},
        .NOMEM => return error.OutOfMemory,
        else => return error.PlatformFailure,
    }
    const pointer: [*]align(std.heap.page_size_min) const u8 = @ptrFromInt(address);
    return .{ .bytes = pointer[0..size] };
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, maximum_bytes: usize) Error![]u8 {
    const descriptor = try openReadOnly(path);
    defer close(descriptor);
    const size = try fileSize(descriptor);
    if (size == 0 or size > maximum_bytes) return error.BudgetExceeded;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    try preadAll(descriptor, bytes, 0);
    return bytes;
}

pub fn duplicate(descriptor: fd_t) Error!fd_t {
    const result = linux.fcntl(descriptor, linux.F.DUPFD_CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.PlatformFailure;
    return @intCast(result);
}

pub fn writeAll(descriptor: fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = linux.write(descriptor, bytes[offset..].ptr, bytes.len - offset);
        switch (linux.errno(result)) {
            .SUCCESS => {
                const written: usize = result;
                if (written == 0) return error.PlatformFailure;
                offset += written;
            },
            .INTR => continue,
            .AGAIN => try waitWritable(descriptor),
            else => return error.PlatformFailure,
        }
    }
}

/// Sends a byte stream carrying one SCM_RIGHTS descriptor. The descriptor is
/// attached only to the first byte; any short remainder is completed as an
/// ordinary stream write so it cannot be duplicated at the receiver.
pub fn writeAllWithFd(descriptor: fd_t, bytes: []const u8, transferred: fd_t) Error!void {
    if (bytes.len == 0 or transferred < 0) return error.InvalidConfiguration;
    const header_bytes = @sizeOf(linux.cmsghdr);
    const payload_bytes = @sizeOf(fd_t);
    const alignment = @alignOf(usize);
    const control_bytes = std.mem.alignForward(usize, header_bytes + payload_bytes, alignment);
    var control: [std.mem.alignForward(usize, @sizeOf(linux.cmsghdr) + @sizeOf(fd_t), @alignOf(usize))]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    const header: *linux.cmsghdr = @ptrCast(@alignCast(&control));
    header.* = .{
        .len = header_bytes + payload_bytes,
        .level = linux.SOL.SOCKET,
        .type = linux.SCM.RIGHTS,
    };
    const descriptor_pointer: *fd_t = @ptrCast(@alignCast(control[header_bytes..].ptr));
    descriptor_pointer.* = transferred;
    const vectors = [1]std.posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    const message: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &vectors,
        .iovlen = vectors.len,
        .control = &control,
        .controllen = control_bytes,
        .flags = 0,
    };
    while (true) {
        const result = linux.sendmsg(descriptor, &message, linux.MSG.NOSIGNAL);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.PlatformFailure;
                if (result < bytes.len) try writeAll(descriptor, bytes[result..]);
                return;
            },
            .INTR => continue,
            .AGAIN => try waitWritable(descriptor),
            else => return error.PlatformFailure,
        }
    }
}

pub fn read(descriptor: fd_t, bytes: []u8) Error!usize {
    while (true) {
        const result = linux.read(descriptor, bytes.ptr, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS => return result,
            .INTR => continue,
            .AGAIN => return 0,
            else => return error.PlatformFailure,
        }
    }
}

pub const ReadStatus = union(enum) {
    bytes: usize,
    would_block,
    end_of_file,
};

pub fn readNonBlocking(descriptor: fd_t, bytes: []u8) Error!ReadStatus {
    while (true) {
        const result = linux.read(descriptor, bytes.ptr, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS => return if (result == 0) .end_of_file else .{ .bytes = result },
            .INTR => continue,
            .AGAIN => return .would_block,
            else => return error.PlatformFailure,
        }
    }
}

pub fn preadAll(descriptor: fd_t, bytes: []u8, file_offset: u64) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const absolute = std.math.add(u64, file_offset, offset) catch return error.BudgetExceeded;
        if (absolute > @as(u64, @intCast(std.math.maxInt(linux.off_t)))) return error.BudgetExceeded;
        const result = linux.pread(descriptor, bytes[offset..].ptr, bytes.len - offset, @intCast(absolute));
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.PlatformFailure;
                offset += result;
            },
            .INTR => continue,
            else => return error.PlatformFailure,
        }
    }
}

pub fn createPipe() Error![2]fd_t {
    var descriptors: [2]fd_t = undefined;
    var flags: linux.O = .{};
    flags.CLOEXEC = true;
    flags.NONBLOCK = true;
    const result = linux.pipe2(&descriptors, flags);
    if (linux.errno(result) != .SUCCESS) return error.PlatformFailure;
    return descriptors;
}

pub fn monotonicNanoseconds() u64 {
    var value: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &value)) != .SUCCESS) return 0;
    if (value.sec < 0 or value.nsec < 0) return 0;
    const seconds: u128 = @intCast(value.sec);
    const nanoseconds: u128 = @intCast(value.nsec);
    return @intCast(@min(seconds * std.time.ns_per_s + nanoseconds, std.math.maxInt(u64)));
}

pub fn createWakeFd() Error!fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(result) != .SUCCESS) return error.PlatformFailure;
    return @intCast(result);
}

pub fn wake(descriptor: fd_t) void {
    const one: u64 = 1;
    const bytes = std.mem.asBytes(&one);
    while (true) {
        const result = linux.write(descriptor, bytes.ptr, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS, .AGAIN => return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn drainWake(descriptor: fd_t) void {
    var value: u64 = 0;
    const bytes = std.mem.asBytes(&value);
    while (true) {
        const result = linux.read(descriptor, bytes.ptr, bytes.len);
        switch (linux.errno(result)) {
            .SUCCESS => continue,
            .INTR => continue,
            .AGAIN => return,
            else => return,
        }
    }
}

pub fn poll(descriptors: []linux.pollfd, timeout_ms: i32) Error!usize {
    return std.posix.poll(descriptors, timeout_ms) catch return error.PlatformFailure;
}

pub fn waitWritable(descriptor: fd_t) Error!void {
    var descriptors = [_]linux.pollfd{.{ .fd = descriptor, .events = linux.POLL.OUT, .revents = 0 }};
    _ = try poll(&descriptors, -1);
    if (descriptors[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
        return error.PlatformFailure;
}

/// Reads the process's initial environment without libc. Linux exposes that
/// block through procfs; callers provide bounded storage and receive a slice
/// borrowing it.
pub fn initialEnvironment(name: []const u8, storage: []u8) Error!?[]const u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) return error.InvalidConfiguration;
    var flags: linux.O = .{};
    flags.CLOEXEC = true;
    const opened = linux.open("/proc/self/environ", flags, 0);
    if (linux.errno(opened) != .SUCCESS) return error.PlatformFailure;
    const descriptor: fd_t = @intCast(opened);
    defer close(descriptor);

    var length: usize = 0;
    while (length < storage.len) {
        const result = linux.read(descriptor, storage[length..].ptr, storage.len - length);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) break;
                length += result;
            },
            .INTR => continue,
            else => return error.PlatformFailure,
        }
    }
    if (length == storage.len) {
        var extra: [1]u8 = undefined;
        const result = linux.read(descriptor, extra[0..].ptr, 1);
        if (linux.errno(result) != .SUCCESS) return error.PlatformFailure;
        if (result != 0) return error.BudgetExceeded;
    }

    var cursor: usize = 0;
    while (cursor < length) {
        const terminator = if (std.mem.indexOfScalar(u8, storage[cursor..length], 0)) |relative| cursor + relative else length;
        const entry = storage[cursor..terminator];
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name))
            return entry[name.len + 1 ..];
        cursor = terminator + 1;
    }
    return null;
}
