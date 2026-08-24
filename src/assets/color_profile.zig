const std = @import("std");
const Error = @import("../core/error.zig").Error;

const Curve = union(enum) {
    identity,
    gamma: f32,
    table: struct { offset: usize, count: usize },
    parametric: Parametric,
};

const Parametric = struct {
    kind: u16,
    values: [7]f32 = @splat(0),
};

/// Owned ICC RGB matrix/TRC transform. LUT-based and non-RGB profiles are
/// rejected explicitly: applying a profile-name heuristic would be silent
/// color corruption.
pub const Profile = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    matrix: [3][3]f32,
    curves: [3]Curve,

    pub fn initOwned(allocator: std.mem.Allocator, owned: []u8) Error!Profile {
        if (owned.len < 132 or !std.mem.eql(u8, owned[36..40], "acsp")) return error.InvalidImage;
        const declared_size: usize = readU32(owned, 0) orelse return error.InvalidImage;
        if (declared_size < 132 or declared_size > owned.len) return error.InvalidImage;
        const bytes = owned[0..declared_size];
        if (!std.mem.eql(u8, bytes[16..20], "RGB ") or !std.mem.eql(u8, bytes[20..24], "XYZ ")) return error.Unsupported;

        const tag_count: usize = readU32(bytes, 128) orelse return error.InvalidImage;
        if (tag_count > 4096) return error.BudgetExceeded;
        const table_bytes = std.math.mul(usize, tag_count, 12) catch return error.BudgetExceeded;
        const table_end = std.math.add(usize, 132, table_bytes) catch return error.BudgetExceeded;
        if (table_end > bytes.len) return error.InvalidImage;

        const red_xyz = try xyzTag(bytes, try findTag(bytes, tag_count, "rXYZ".*));
        const green_xyz = try xyzTag(bytes, try findTag(bytes, tag_count, "gXYZ".*));
        const blue_xyz = try xyzTag(bytes, try findTag(bytes, tag_count, "bXYZ".*));
        const curves = [3]Curve{
            try curveTag(bytes, try findTag(bytes, tag_count, "rTRC".*)),
            try curveTag(bytes, try findTag(bytes, tag_count, "gTRC".*)),
            try curveTag(bytes, try findTag(bytes, tag_count, "bTRC".*)),
        };
        const matrix: [3][3]f32 = .{
            .{ red_xyz[0], green_xyz[0], blue_xyz[0] },
            .{ red_xyz[1], green_xyz[1], blue_xyz[1] },
            .{ red_xyz[2], green_xyz[2], blue_xyz[2] },
        };
        for (matrix) |row| for (row) |value| if (!std.math.isFinite(value) or @abs(value) > 16) return error.InvalidImage;
        return .{ .allocator = allocator, .bytes = owned, .matrix = matrix, .curves = curves };
    }

    pub fn fromCompressed(
        allocator: std.mem.Allocator,
        compressed: []const u8,
        maximum_profile_bytes: usize,
    ) Error!Profile {
        if (compressed.len == 0) return error.InvalidImage;
        var source: std.Io.Reader = .fixed(compressed);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor: std.compress.flate.Decompress = .init(&source, .zlib, &window);
        var header: [128]u8 = undefined;
        decompressor.reader.readSliceAll(&header) catch return error.InvalidImage;
        const declared_size: usize = readU32(&header, 0) orelse return error.InvalidImage;
        if (declared_size < 132 or declared_size > maximum_profile_bytes) return error.BudgetExceeded;
        const owned = try allocator.alloc(u8, declared_size);
        errdefer allocator.free(owned);
        @memcpy(owned[0..header.len], &header);
        decompressor.reader.readSliceAll(owned[header.len..]) catch return error.InvalidImage;
        var extra: [1]u8 = undefined;
        if ((decompressor.reader.readSliceShort(&extra) catch 0) != 0) return error.InvalidImage;
        return initOwned(allocator, owned);
    }

    pub fn deinit(self: *Profile) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn applyToSrgb(self: *const Profile, pixels: []u8) void {
        var offset: usize = 0;
        while (offset + 4 <= pixels.len) : (offset += 4) {
            const source = [3]f32{
                evaluate(self.curves[0], self.bytes, normalized(pixels[offset])),
                evaluate(self.curves[1], self.bytes, normalized(pixels[offset + 1])),
                evaluate(self.curves[2], self.bytes, normalized(pixels[offset + 2])),
            };
            const xyz = multiply(self.matrix, source);
            // ICC matrix colorants are expressed in the D50 PCS. This is the
            // D50 XYZ -> linear-sRGB matrix (Bradford-adapted to D65).
            const linear = multiply(.{
                .{ 3.1338561, -1.6168667, -0.4906146 },
                .{ -0.9787684, 1.9161415, 0.0334540 },
                .{ 0.0719453, -0.2289914, 1.4052427 },
            }, xyz);
            pixels[offset] = encodeSrgb(linear[0]);
            pixels[offset + 1] = encodeSrgb(linear[1]);
            pixels[offset + 2] = encodeSrgb(linear[2]);
        }
    }
};

const Tag = struct { offset: usize, size: usize };

fn findTag(bytes: []const u8, count: usize, signature: [4]u8) Error!Tag {
    for (0..count) |index| {
        const entry = 132 + @as(usize, index) * 12;
        if (!std.mem.eql(u8, bytes[entry..][0..4], &signature)) continue;
        const offset: usize = readU32(bytes, entry + 4) orelse return error.InvalidImage;
        const size: usize = readU32(bytes, entry + 8) orelse return error.InvalidImage;
        const end = std.math.add(usize, offset, size) catch return error.BudgetExceeded;
        if (size < 8 or end > bytes.len) return error.InvalidImage;
        return .{ .offset = offset, .size = size };
    }
    return error.Unsupported;
}

fn xyzTag(bytes: []const u8, tag: Tag) Error![3]f32 {
    if (tag.size < 20 or !std.mem.eql(u8, bytes[tag.offset..][0..4], "XYZ ")) return error.Unsupported;
    return .{
        readFixed(bytes, tag.offset + 8) orelse return error.InvalidImage,
        readFixed(bytes, tag.offset + 12) orelse return error.InvalidImage,
        readFixed(bytes, tag.offset + 16) orelse return error.InvalidImage,
    };
}

fn curveTag(bytes: []const u8, tag: Tag) Error!Curve {
    const signature = bytes[tag.offset..][0..4];
    if (std.mem.eql(u8, signature, "curv")) {
        if (tag.size < 12) return error.InvalidImage;
        const count: usize = readU32(bytes, tag.offset + 8) orelse return error.InvalidImage;
        if (count == 0) return .identity;
        const values_bytes = std.math.mul(usize, count, 2) catch return error.BudgetExceeded;
        const required = std.math.add(usize, 12, values_bytes) catch return error.BudgetExceeded;
        if (required > tag.size) return error.InvalidImage;
        if (count == 1) {
            const raw = readU16(bytes, tag.offset + 12) orelse return error.InvalidImage;
            const gamma = @as(f32, @floatFromInt(raw)) / 256;
            if (!(gamma > 0) or !std.math.isFinite(gamma)) return error.InvalidImage;
            return .{ .gamma = gamma };
        }
        return .{ .table = .{ .offset = tag.offset + 12, .count = count } };
    }
    if (!std.mem.eql(u8, signature, "para") or tag.size < 16) return error.Unsupported;
    const kind = readU16(bytes, tag.offset + 8) orelse return error.InvalidImage;
    const parameter_count: usize = switch (kind) {
        0 => 1,
        1 => 3,
        2 => 4,
        3 => 5,
        4 => 7,
        else => return error.Unsupported,
    };
    if (12 + parameter_count * 4 > tag.size) return error.InvalidImage;
    var result: Parametric = .{ .kind = kind };
    for (0..parameter_count) |index| {
        result.values[index] = readFixed(bytes, tag.offset + 12 + index * 4) orelse return error.InvalidImage;
        if (!std.math.isFinite(result.values[index]) or @abs(result.values[index]) > 1024) return error.InvalidImage;
    }
    if (!(result.values[0] > 0)) return error.InvalidImage;
    if (kind != 0 and !(result.values[1] > 0)) return error.InvalidImage;
    if ((kind == 3 or kind == 4) and result.values[1] * result.values[4] + result.values[2] < 0) return error.InvalidImage;
    return .{ .parametric = result };
}

fn evaluate(curve: Curve, bytes: []const u8, input: f32) f32 {
    const x = std.math.clamp(input, 0, 1);
    return switch (curve) {
        .identity => x,
        .gamma => |gamma| std.math.pow(f32, x, gamma),
        .table => |table| blk: {
            const scaled = x * @as(f32, @floatFromInt(table.count - 1));
            const lower: usize = @intFromFloat(@floor(scaled));
            const upper = @min(lower + 1, table.count - 1);
            const first = @as(f32, @floatFromInt(readU16(bytes, table.offset + lower * 2).?)) / 65535;
            const second = @as(f32, @floatFromInt(readU16(bytes, table.offset + upper * 2).?)) / 65535;
            break :blk first + (second - first) * (scaled - @as(f32, @floatFromInt(lower)));
        },
        .parametric => |value| evaluateParametric(value, x),
    };
}

fn evaluateParametric(value: Parametric, x: f32) f32 {
    const p = value.values;
    return switch (value.kind) {
        0 => std.math.pow(f32, x, p[0]),
        1 => if (x >= -p[2] / p[1]) std.math.pow(f32, p[1] * x + p[2], p[0]) else 0,
        2 => if (x >= -p[2] / p[1]) std.math.pow(f32, p[1] * x + p[2], p[0]) + p[3] else p[3],
        3 => if (x >= p[4]) std.math.pow(f32, p[1] * x + p[2], p[0]) else p[3] * x,
        4 => if (x >= p[4]) std.math.pow(f32, p[1] * x + p[2], p[0]) + p[5] else p[3] * x + p[6],
        else => unreachable,
    };
}

fn multiply(matrix: [3][3]f32, value: [3]f32) [3]f32 {
    return .{
        matrix[0][0] * value[0] + matrix[0][1] * value[1] + matrix[0][2] * value[2],
        matrix[1][0] * value[0] + matrix[1][1] * value[1] + matrix[1][2] * value[2],
        matrix[2][0] * value[0] + matrix[2][1] * value[1] + matrix[2][2] * value[2],
    };
}

fn normalized(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255;
}

fn encodeSrgb(value: f32) u8 {
    const clamped = std.math.clamp(value, 0, 1);
    const encoded = if (clamped <= 0.0031308) clamped * 12.92 else 1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(encoded * 255));
}

fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readU32(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}

fn readFixed(bytes: []const u8, offset: usize) ?f32 {
    const raw: i32 = @bitCast(readU32(bytes, offset) orelse return null);
    return @as(f32, @floatFromInt(raw)) / 65536;
}
