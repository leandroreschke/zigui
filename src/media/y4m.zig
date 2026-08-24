const std = @import("std");
const Error = @import("../core/error.zig").Error;
const api = @import("api.zig");

const Chroma = enum { mono, c420, c422, c444 };
const Matrix = enum { bt601, bt709 };

pub const Source = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    width: u32,
    height: u32,
    fps_numerator: u32,
    fps_denominator: u32,
    chroma: Chroma,
    full_range: bool,
    matrix: Matrix,
    frame_bytes: usize,
    frame_offsets: std.ArrayList(usize) = .empty,
    rgba: []u8,
    last_frame: ?usize = null,

    pub fn create(
        allocator: std.mem.Allocator,
        encoded: []const u8,
        maximum_frames: usize,
        maximum_bytes: usize,
        maximum_decoded_bytes: usize,
    ) Error!api.Source {
        if (maximum_frames == 0 or maximum_bytes == 0 or maximum_decoded_bytes == 0)
            return error.InvalidConfiguration;
        if (encoded.len > maximum_bytes) return error.BudgetExceeded;
        const self = try allocator.create(Source);
        errdefer allocator.destroy(self);
        const bytes = try allocator.dupe(u8, encoded);
        self.* = .{
            .allocator = allocator,
            .bytes = bytes,
            .width = 0,
            .height = 0,
            .fps_numerator = 0,
            .fps_denominator = 1,
            .chroma = .c420,
            .full_range = false,
            .matrix = .bt601,
            .frame_bytes = 0,
            .rgba = &.{},
        };
        errdefer self.deinitInner();
        try self.parse(maximum_frames, maximum_decoded_bytes);
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable: api.Source.VTable = .{
        .info = infoOpaque,
        .poll = pollOpaque,
        .seek = seekOpaque,
        .deinit = deinitOpaque,
    };

    fn cast(raw: *anyopaque) *Source {
        return @ptrCast(@alignCast(raw));
    }

    fn infoOpaque(raw: *anyopaque) api.Info {
        const self = cast(raw);
        return .{
            .width = self.width,
            .height = self.height,
            .duration_ns = self.duration(),
            .frame_rate_numerator = self.fps_numerator,
            .frame_rate_denominator = self.fps_denominator,
            .seekable = true,
        };
    }

    fn pollOpaque(raw: *anyopaque, target_ns: u64) Error!api.Poll {
        const self = cast(raw);
        if (self.frame_offsets.items.len == 0) return .ended;
        const denominator = std.math.mul(u128, self.fps_denominator, std.time.ns_per_s) catch return error.BudgetExceeded;
        const scaled = std.math.mul(u128, target_ns, self.fps_numerator) catch std.math.maxInt(u128);
        const wanted_u128 = scaled / denominator;
        if (wanted_u128 >= self.frame_offsets.items.len) return .ended;
        const wanted: usize = @intCast(wanted_u128);
        if (self.last_frame != null and self.last_frame.? == wanted) return .unchanged;
        try self.decodeFrame(wanted);
        self.last_frame = wanted;
        const frame_duration = self.frameDuration();
        return .{ .frame = .{
            .presentation_time_ns = @as(u64, @intCast(wanted)) *| frame_duration,
            .duration_ns = frame_duration,
            .content = .{ .cpu = .{
                .width = self.width,
                .height = self.height,
                .stride = @as(usize, self.width) * 4,
                .format = .rgba8_srgb,
                .pixels = self.rgba,
            } },
        } };
    }

    fn seekOpaque(raw: *anyopaque, _: u64) Error!void {
        cast(raw).last_frame = null;
    }

    fn deinitOpaque(raw: *anyopaque) void {
        const self = cast(raw);
        const allocator = self.allocator;
        self.deinitInner();
        allocator.destroy(self);
    }

    fn deinitInner(self: *Source) void {
        if (self.rgba.len != 0) self.allocator.free(self.rgba);
        self.frame_offsets.deinit(self.allocator);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn parse(self: *Source, maximum_frames: usize, maximum_decoded_bytes: usize) Error!void {
        const header_end = std.mem.indexOfScalar(u8, self.bytes, '\n') orelse return error.InvalidMedia;
        const header = self.bytes[0..header_end];
        if (!std.mem.startsWith(u8, header, "YUV4MPEG2")) return error.InvalidMedia;
        var tokens = std.mem.tokenizeScalar(u8, header["YUV4MPEG2".len..], ' ');
        while (tokens.next()) |token| {
            if (token.len < 2) continue;
            switch (token[0]) {
                'W' => self.width = std.fmt.parseUnsigned(u32, token[1..], 10) catch return error.InvalidMedia,
                'H' => self.height = std.fmt.parseUnsigned(u32, token[1..], 10) catch return error.InvalidMedia,
                'F' => try parseRatio(token[1..], &self.fps_numerator, &self.fps_denominator),
                'I' => if (token[1] != 'p' and token[1] != '?') return error.Unsupported,
                'C' => self.chroma = parseChroma(token[1..]) orelse return error.Unsupported,
                'X' => {
                    if (std.mem.eql(u8, token[1..], "COLORRANGE=FULL")) self.full_range = true;
                    if (std.mem.eql(u8, token[1..], "COLORRANGE=LIMITED")) self.full_range = false;
                    if (std.mem.eql(u8, token[1..], "COLORMATRIX=BT709")) self.matrix = .bt709;
                    if (std.mem.eql(u8, token[1..], "COLORMATRIX=BT601")) self.matrix = .bt601;
                },
                else => {},
            }
        }
        if (self.width == 0 or self.height == 0 or self.fps_numerator == 0 or self.fps_denominator == 0) return error.InvalidMedia;
        const pixels = std.math.mul(usize, self.width, self.height) catch return error.BudgetExceeded;
        const half_width = std.math.add(usize, self.width, 1) catch return error.BudgetExceeded;
        const half_height = std.math.add(usize, self.height, 1) catch return error.BudgetExceeded;
        const subsampled_width = half_width / 2;
        const subsampled_height = half_height / 2;
        const chroma_pixels = switch (self.chroma) {
            .mono => 0,
            .c420 => std.math.mul(usize, 2, std.math.mul(usize, subsampled_width, subsampled_height) catch return error.BudgetExceeded) catch return error.BudgetExceeded,
            .c422 => std.math.mul(usize, 2, std.math.mul(usize, subsampled_width, self.height) catch return error.BudgetExceeded) catch return error.BudgetExceeded,
            .c444 => std.math.mul(usize, 2, pixels) catch return error.BudgetExceeded,
        };
        self.frame_bytes = std.math.add(usize, pixels, chroma_pixels) catch return error.BudgetExceeded;
        const rgba_bytes = std.math.mul(usize, pixels, 4) catch return error.BudgetExceeded;
        if (rgba_bytes > maximum_decoded_bytes) return error.BudgetExceeded;
        if (self.frameDuration() == 0) return error.InvalidMedia;
        self.rgba = try self.allocator.alloc(u8, rgba_bytes);
        var offset = header_end + 1;
        while (offset < self.bytes.len) {
            if (self.frame_offsets.items.len >= maximum_frames) return error.BudgetExceeded;
            const marker_end_relative = std.mem.indexOfScalar(u8, self.bytes[offset..], '\n') orelse return error.InvalidMedia;
            const marker_end = offset + marker_end_relative;
            if (!std.mem.startsWith(u8, self.bytes[offset..marker_end], "FRAME")) return error.InvalidMedia;
            const data_offset = marker_end + 1;
            if (data_offset > self.bytes.len or self.frame_bytes > self.bytes.len - data_offset)
                return error.InvalidMedia;
            try self.frame_offsets.append(self.allocator, data_offset);
            offset = data_offset + self.frame_bytes;
        }
        if (self.frame_offsets.items.len == 0) return error.InvalidMedia;
        if (self.matrix == .bt601 and self.width >= 1280) self.matrix = .bt709;
    }

    fn decodeFrame(self: *Source, index: usize) Error!void {
        const offset = self.frame_offsets.items[index];
        const luma_length = @as(usize, self.width) * self.height;
        const y_plane = self.bytes[offset..][0..luma_length];
        const chroma_width: usize = switch (self.chroma) {
            .mono, .c444 => self.width,
            .c420, .c422 => (@as(usize, self.width) + 1) / 2,
        };
        const chroma_height: usize = switch (self.chroma) {
            .mono, .c422, .c444 => self.height,
            .c420 => (@as(usize, self.height) + 1) / 2,
        };
        const chroma_length = if (self.chroma == .mono) 0 else chroma_width * chroma_height;
        const u_plane = self.bytes[offset + luma_length ..][0..chroma_length];
        const v_plane = self.bytes[offset + luma_length + chroma_length ..][0..chroma_length];
        for (0..self.height) |y| for (0..self.width) |x| {
            const luma = y_plane[y * self.width + x];
            const chroma_x = switch (self.chroma) {
                .c420, .c422 => x / 2,
                else => x,
            };
            const chroma_y = switch (self.chroma) {
                .c420 => y / 2,
                else => y,
            };
            const chroma_index = chroma_y * chroma_width + chroma_x;
            const cb: u8 = if (self.chroma == .mono) 128 else u_plane[chroma_index];
            const cr: u8 = if (self.chroma == .mono) 128 else v_plane[chroma_index];
            const converted = yuvToRgb(luma, cb, cr, self.full_range, self.matrix);
            const destination = (y * self.width + x) * 4;
            self.rgba[destination] = converted[0];
            self.rgba[destination + 1] = converted[1];
            self.rgba[destination + 2] = converted[2];
            self.rgba[destination + 3] = 255;
        };
    }

    fn frameDuration(self: *const Source) u64 {
        return @intCast((@as(u128, self.fps_denominator) * std.time.ns_per_s) / self.fps_numerator);
    }

    fn duration(self: *const Source) u64 {
        return @as(u64, @intCast(self.frame_offsets.items.len)) *| self.frameDuration();
    }
};

fn parseRatio(value: []const u8, numerator: *u32, denominator: *u32) Error!void {
    const separator = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidMedia;
    numerator.* = std.fmt.parseUnsigned(u32, value[0..separator], 10) catch return error.InvalidMedia;
    denominator.* = std.fmt.parseUnsigned(u32, value[separator + 1 ..], 10) catch return error.InvalidMedia;
}

fn parseChroma(value: []const u8) ?Chroma {
    if (std.mem.startsWith(u8, value, "mono")) return .mono;
    if (std.mem.startsWith(u8, value, "420")) return .c420;
    if (std.mem.startsWith(u8, value, "422")) return .c422;
    if (std.mem.startsWith(u8, value, "444") and !std.mem.startsWith(u8, value, "444alpha")) return .c444;
    return null;
}

fn yuvToRgb(y: u8, cb: u8, cr: u8, full: bool, matrix: Matrix) [3]u8 {
    const yf: f32 = if (full) @floatFromInt(y) else (@as(f32, @floatFromInt(y)) - 16) * (255.0 / 219.0);
    const chroma_scale: f32 = if (full) 1.0 else 255.0 / 224.0;
    const uf: f32 = (@as(f32, @floatFromInt(cb)) - 128) * chroma_scale;
    const vf: f32 = (@as(f32, @floatFromInt(cr)) - 128) * chroma_scale;
    const rgb: [3]f32 = switch (matrix) {
        .bt601 => .{ yf + 1.402 * vf, yf - 0.344136 * uf - 0.714136 * vf, yf + 1.772 * uf },
        .bt709 => .{ yf + 1.5748 * vf, yf - 0.187324 * uf - 0.468124 * vf, yf + 1.8556 * uf },
    };
    return .{ byte(rgb[0]), byte(rgb[1]), byte(rgb[2]) };
}

fn byte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}
