const std = @import("std");
const builtin = @import("builtin");
const Error = @import("../../../core/error.zig").Error;
const sys = @import("../sys.zig");
const surface = @import("../surface.zig");
const wire = @import("wire.zig");

const native_endian = builtin.cpu.arch.endian();
const maximum_format_table_bytes = 8 * 1024 * 1024;

const TableEntry = struct {
    fourcc: u32,
    modifier: u64,
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    table: std.ArrayList(TableEntry) = .empty,
    formats: std.ArrayList(surface.Format) = .empty,
    tranche_indices: std.ArrayList(u16) = .empty,
    tranche_scanout: bool = false,
    main_device: u64 = 0,
    target_device: u64 = 0,
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }

    pub fn handle(self: *Collector, opcode: u16, reader: *wire.Reader) Error!void {
        switch (opcode) {
            0 => {
                self.complete = true;
                try self.deduplicate();
            },
            1 => try self.readTable(try reader.fd(), try reader.u32()),
            2 => self.main_device = try decodeDevice(try reader.array()),
            3 => try self.finishTranche(),
            4 => self.target_device = try decodeDevice(try reader.array()),
            5 => try self.readIndices(try reader.array()),
            6 => self.tranche_scanout = (try reader.u32()) & 1 != 0,
            else => return error.PlatformFailure,
        }
    }

    pub fn view(self: *const Collector) []const surface.Format {
        return if (self.complete) self.formats.items else &.{};
    }

    pub fn deinit(self: *Collector) void {
        self.tranche_indices.deinit(self.allocator);
        self.formats.deinit(self.allocator);
        self.table.deinit(self.allocator);
        self.* = undefined;
    }

    fn readTable(self: *Collector, descriptor: sys.fd_t, byte_count_u32: u32) Error!void {
        defer sys.close(descriptor);
        const byte_count: usize = byte_count_u32;
        if (byte_count == 0 or byte_count > maximum_format_table_bytes or byte_count % 16 != 0)
            return error.PlatformFailure;
        const bytes = try self.allocator.alloc(u8, byte_count);
        defer self.allocator.free(bytes);
        try sys.preadAll(descriptor, bytes, 0);

        self.table.clearRetainingCapacity();
        self.formats.clearRetainingCapacity();
        self.tranche_indices.clearRetainingCapacity();
        self.complete = false;
        try self.table.ensureTotalCapacity(self.allocator, byte_count / 16);
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 16) self.table.appendAssumeCapacity(.{
            .fourcc = std.mem.readInt(u32, bytes[offset..][0..4], native_endian),
            .modifier = std.mem.readInt(u64, bytes[offset + 8 ..][0..8], native_endian),
        });
    }

    fn readIndices(self: *Collector, bytes: []const u8) Error!void {
        if (bytes.len % 2 != 0) return error.PlatformFailure;
        try self.tranche_indices.ensureUnusedCapacity(self.allocator, bytes.len / 2);
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 2)
            self.tranche_indices.appendAssumeCapacity(std.mem.readInt(u16, bytes[offset..][0..2], native_endian));
    }

    fn finishTranche(self: *Collector) Error!void {
        try self.formats.ensureUnusedCapacity(self.allocator, self.tranche_indices.items.len);
        for (self.tranche_indices.items) |index| {
            const table_index: usize = index;
            if (table_index >= self.table.items.len) return error.PlatformFailure;
            const entry = self.table.items[table_index];
            self.formats.appendAssumeCapacity(.{
                .fourcc = entry.fourcc,
                .modifier = entry.modifier,
                .scanout = self.tranche_scanout,
            });
        }
        self.tranche_indices.clearRetainingCapacity();
        self.tranche_scanout = false;
    }

    fn deduplicate(self: *Collector) Error!void {
        var write: usize = 0;
        for (self.formats.items, 0..) |candidate, index| {
            var existing: ?usize = null;
            for (self.formats.items[0..write], 0..) |known, known_index| {
                if (known.fourcc == candidate.fourcc and known.modifier == candidate.modifier) {
                    existing = known_index;
                    break;
                }
            }
            if (existing) |known_index| {
                self.formats.items[known_index].scanout = self.formats.items[known_index].scanout or candidate.scanout;
            } else {
                if (write != index) self.formats.items[write] = candidate;
                write += 1;
            }
        }
        self.formats.items.len = write;
    }
};

fn decodeDevice(bytes: []const u8) Error!u64 {
    if (bytes.len == 0 or bytes.len > @sizeOf(u64)) return error.PlatformFailure;
    var padded: [8]u8 = @splat(0);
    @memcpy(padded[0..bytes.len], bytes);
    return std.mem.readInt(u64, &padded, native_endian);
}
