const std = @import("std");
const Error = @import("../core/error.zig").Error;
const image = @import("image.zig");
const animation = @import("animation_api.zig");

const ColorTable = struct {
    values: [256][4]u8 = undefined,
    count: usize = 0,
};

pub const Looping = animation.Looping;
pub const Frame = animation.Frame;

const GraphicControl = struct {
    disposal: u3 = 0,
    delay_centiseconds: u16 = 0,
    transparent_index: ?u8 = null,
};

const PreviousFrame = struct {
    left: u16,
    top: u16,
    width: u16,
    height: u16,
    disposal: u3,
};

/// Sequential GIF decoder. It retains only a compositing canvas and, for the
/// restore-previous disposal mode, one bounded backup canvas. The encoded
/// bytes remain caller-owned for the decoder's lifetime.
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: image.Limits,
    width: u16,
    height: u16,
    background_index: u8,
    global: ColorTable,
    data_offset: usize,
    offset: usize,
    canvas: []u8,
    restore_canvas: ?[]u8 = null,
    pending_control: GraphicControl = .{},
    previous: ?PreviousFrame = null,
    frame_index: usize = 0,
    looping: Looping = .once,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!Decoder {
        if (bytes.len < 13 or !(std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return error.InvalidImage;
        if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
        const width = readU16(bytes, 6) orelse return error.InvalidImage;
        const height = readU16(bytes, 8) orelse return error.InvalidImage;
        const count = try image.validateDimensions(width, height, limits);
        const canvas_bytes = std.math.mul(usize, count, 4) catch return error.BudgetExceeded;
        if (canvas_bytes > limits.maximum_animation_canvas_bytes) return error.BudgetExceeded;
        const packed_fields = bytes[10];
        var offset: usize = 13;
        var global: ColorTable = .{};
        if (packed_fields & 0x80 != 0) {
            global.count = @as(usize, 1) << @intCast((packed_fields & 0x07) + 1);
            try readColorTable(bytes, &offset, &global);
        }
        const canvas = try allocator.alloc(u8, canvas_bytes);
        errdefer allocator.free(canvas);
        @memset(canvas, 0);
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .limits = limits,
            .width = width,
            .height = height,
            .background_index = bytes[11],
            .global = global,
            .data_offset = offset,
            .offset = offset,
            .canvas = canvas,
        };
    }

    pub fn deinit(self: *Decoder) void {
        if (self.restore_canvas) |value| self.allocator.free(value);
        if (self.canvas.len != 0) self.allocator.free(self.canvas);
        self.* = undefined;
    }

    pub fn reset(self: *Decoder) void {
        self.offset = self.data_offset;
        self.pending_control = .{};
        self.previous = null;
        self.frame_index = 0;
        self.looping = .once;
        self.finished = false;
        @memset(self.canvas, 0);
        if (self.restore_canvas) |value| @memset(value, 0);
    }

    pub fn next(self: *Decoder) Error!?Frame {
        if (self.finished) return null;
        self.applyPreviousDisposal();
        while (self.offset < self.bytes.len) {
            const introducer = self.bytes[self.offset];
            self.offset += 1;
            switch (introducer) {
                0x3b => {
                    if (self.offset != self.bytes.len) return error.InvalidImage;
                    self.finished = true;
                    return null;
                },
                0x21 => try self.readExtension(),
                0x2c => return try self.readFrame(),
                else => return error.InvalidImage,
            }
        }
        return error.InvalidImage;
    }

    fn readExtension(self: *Decoder) Error!void {
        if (self.offset >= self.bytes.len) return error.InvalidImage;
        const label = self.bytes[self.offset];
        self.offset += 1;
        switch (label) {
            0xf9 => {
                if (self.offset + 6 > self.bytes.len or self.bytes[self.offset] != 4 or self.bytes[self.offset + 5] != 0) return error.InvalidImage;
                const packed_fields = self.bytes[self.offset + 1];
                const disposal: u3 = @intCast((packed_fields >> 2) & 0x07);
                if (disposal > 3) return error.InvalidImage;
                self.pending_control = .{
                    .disposal = disposal,
                    .delay_centiseconds = readU16(self.bytes, self.offset + 2) orelse return error.InvalidImage,
                    .transparent_index = if (packed_fields & 1 != 0) self.bytes[self.offset + 4] else null,
                };
                self.offset += 6;
            },
            0xff => {
                if (self.offset >= self.bytes.len) return error.InvalidImage;
                const length = self.bytes[self.offset];
                self.offset += 1;
                if (self.offset + length > self.bytes.len) return error.InvalidImage;
                const identifier = self.bytes[self.offset .. self.offset + length];
                self.offset += length;
                if (std.mem.eql(u8, identifier, "NETSCAPE2.0") or std.mem.eql(u8, identifier, "ANIMEXTS1.0")) {
                    if (self.offset + 5 > self.bytes.len or self.bytes[self.offset] != 3 or self.bytes[self.offset + 1] != 1 or self.bytes[self.offset + 4] != 0)
                        return error.InvalidImage;
                    const repetitions = readU16(self.bytes, self.offset + 2) orelse return error.InvalidImage;
                    self.looping = if (repetitions == 0) .infinite else .{ .repetitions = @as(u32, repetitions) };
                    self.offset += 5;
                } else try skipSubBlocks(self.bytes, &self.offset);
            },
            // A Graphic Control Extension applies to the next graphic
            // rendering block, including a Plain Text Extension. ZigUI does
            // not render legacy GIF text, but it must still consume the
            // pending control rather than leak it into the following image.
            0x01 => {
                try skipSubBlocks(self.bytes, &self.offset);
                self.pending_control = .{};
            },
            else => try skipSubBlocks(self.bytes, &self.offset),
        }
    }

    fn readFrame(self: *Decoder) Error!Frame {
        if (self.frame_index >= self.limits.maximum_animation_frames) return error.BudgetExceeded;
        if (self.offset + 9 > self.bytes.len) return error.InvalidImage;
        const left = readU16(self.bytes, self.offset) orelse return error.InvalidImage;
        const top = readU16(self.bytes, self.offset + 2) orelse return error.InvalidImage;
        const frame_width = readU16(self.bytes, self.offset + 4) orelse return error.InvalidImage;
        const frame_height = readU16(self.bytes, self.offset + 6) orelse return error.InvalidImage;
        const descriptor = self.bytes[self.offset + 8];
        self.offset += 9;
        if (frame_width == 0 or frame_height == 0 or @as(u32, left) + frame_width > self.width or @as(u32, top) + frame_height > self.height)
            return error.InvalidImage;
        var colors = self.global;
        if (descriptor & 0x80 != 0) {
            colors.count = @as(usize, 1) << @intCast((descriptor & 0x07) + 1);
            try readColorTable(self.bytes, &self.offset, &colors);
        }
        if (colors.count == 0 or self.offset >= self.bytes.len) return error.InvalidImage;
        const minimum_code_size = self.bytes[self.offset];
        self.offset += 1;
        if (minimum_code_size < 2 or minimum_code_size > 8) return error.InvalidImage;
        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(self.allocator);
        try readSubBlocks(self.allocator, self.bytes, &self.offset, &compressed, self.limits.maximum_compressed_bytes);
        const frame_pixels = std.math.mul(usize, frame_width, frame_height) catch return error.BudgetExceeded;
        const persistent_bytes = std.math.add(usize, self.canvas.len, if (self.restore_canvas) |value| value.len else 0) catch return error.BudgetExceeded;
        if (persistent_bytes > self.limits.maximum_decoded_bytes -| frame_pixels) return error.BudgetExceeded;
        const indices = try self.allocator.alloc(u8, frame_pixels);
        defer self.allocator.free(indices);
        try lzwDecode(compressed.items, minimum_code_size, indices);

        const control = self.pending_control;
        self.pending_control = .{};
        if (control.disposal == 3) {
            if (self.restore_canvas == null) {
                if (self.canvas.len > self.limits.maximum_animation_canvas_bytes -| self.canvas.len) return error.BudgetExceeded;
                if (self.canvas.len > self.limits.maximum_decoded_bytes -| (self.canvas.len + frame_pixels)) return error.BudgetExceeded;
                self.restore_canvas = try self.allocator.alloc(u8, self.canvas.len);
            }
            @memcpy(self.restore_canvas.?, self.canvas);
        }
        var source_row: usize = 0;
        var pass: usize = 0;
        const starts = [_]usize{ 0, 4, 2, 1 };
        const steps = [_]usize{ 8, 8, 4, 2 };
        while (source_row < frame_height) : (source_row += 1) {
            var destination_row = source_row;
            if (descriptor & 0x40 != 0) {
                while (pass < starts.len and source_row >= cumulativeRows(frame_height, starts, steps, pass + 1)) pass += 1;
                if (pass >= starts.len) return error.InvalidImage;
                const before = cumulativeRows(frame_height, starts, steps, pass);
                destination_row = starts[pass] + (source_row - before) * steps[pass];
            }
            for (0..frame_width) |x| {
                const color_index = indices[source_row * frame_width + x];
                if (control.transparent_index != null and color_index == control.transparent_index.?) continue;
                if (color_index >= colors.count) return error.InvalidImage;
                const destination = ((@as(usize, top) + destination_row) * self.width + @as(usize, left) + x) * 4;
                @memcpy(self.canvas[destination..][0..4], &colors.values[color_index]);
            }
        }
        self.previous = .{ .left = left, .top = top, .width = frame_width, .height = frame_height, .disposal = control.disposal };
        const index = self.frame_index;
        self.frame_index += 1;
        const centiseconds: u64 = @max(control.delay_centiseconds, 1);
        return .{
            .pixels = self.canvas,
            .width = self.width,
            .height = self.height,
            .stride = @as(usize, self.width) * 4,
            .duration_ns = centiseconds * 10 * std.time.ns_per_ms,
            .index = index,
        };
    }

    fn applyPreviousDisposal(self: *Decoder) void {
        const previous = self.previous orelse return;
        switch (previous.disposal) {
            2 => {
                var clear: [4]u8 = .{ 0, 0, 0, 0 };
                if (self.background_index < self.global.count)
                    clear = self.global.values[self.background_index];
                for (0..previous.height) |row| for (0..previous.width) |column| {
                    const destination = ((@as(usize, previous.top) + row) * self.width + @as(usize, previous.left) + column) * 4;
                    @memcpy(self.canvas[destination..][0..4], &clear);
                };
            },
            3 => if (self.restore_canvas) |value| @memcpy(self.canvas, value),
            else => {},
        }
        self.previous = null;
    }
};

pub fn decodeFirstFrame(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    var decoder = try Decoder.init(allocator, bytes, limits);
    defer decoder.deinit();
    const frame = (try decoder.next()) orelse return error.InvalidImage;
    const pixels = decoder.canvas;
    decoder.canvas = &.{};
    return .{ .width = frame.width, .height = frame.height, .stride = frame.stride, .pixels = pixels };
}

fn cumulativeRows(height: usize, starts: [4]usize, steps: [4]usize, count: usize) usize {
    var result: usize = 0;
    for (0..@min(count, starts.len)) |index| result += countPassRows(height, starts[index], steps[index]);
    return result;
}

fn lzwDecode(source: []const u8, minimum: u8, output: []u8) Error!void {
    var prefixes: [4096]u16 = undefined;
    var suffixes: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;
    const clear: u16 = @as(u16, 1) << @intCast(minimum);
    const end = clear + 1;
    var code_size: u5 = @intCast(minimum + 1);
    var next_code: u16 = end + 1;
    for (0..clear) |index| suffixes[index] = @intCast(index);
    var bits: usize = 0;
    var previous: ?u16 = null;
    var first: u8 = 0;
    var written: usize = 0;
    var first_code = true;
    while (true) {
        const code = readBits(source, &bits, code_size) orelse return error.InvalidImage;
        if (first_code and code != clear) return error.InvalidImage;
        first_code = false;
        if (code == clear) {
            code_size = @intCast(minimum + 1);
            next_code = end + 1;
            previous = null;
            continue;
        }
        if (code == end) break;
        var current = code;
        var stack_length: usize = 0;
        if (current > next_code) return error.InvalidImage;
        if (current == next_code) {
            const prior = previous orelse return error.InvalidImage;
            stack[stack_length] = first;
            stack_length += 1;
            current = prior;
        }
        while (current >= clear) {
            if (current >= next_code or stack_length >= stack.len) return error.InvalidImage;
            stack[stack_length] = suffixes[current];
            stack_length += 1;
            current = prefixes[current];
        }
        first = @intCast(current);
        stack[stack_length] = first;
        stack_length += 1;
        while (stack_length != 0) {
            stack_length -= 1;
            if (written >= output.len) return error.InvalidImage;
            output[written] = stack[stack_length];
            written += 1;
        }
        if (previous) |prior| if (next_code < 4096) {
            prefixes[next_code] = prior;
            suffixes[next_code] = first;
            next_code += 1;
            if (next_code == (@as(u16, 1) << @as(u4, @intCast(code_size))) and code_size < 12) code_size += 1;
        };
        previous = code;
    }
    if (written != output.len) return error.InvalidImage;
}

fn readColorTable(bytes: []const u8, offset: *usize, table: *ColorTable) Error!void {
    const length = table.count * 3;
    if (offset.* + length > bytes.len) return error.InvalidImage;
    for (0..table.count) |index| table.values[index] = .{ bytes[offset.* + index * 3], bytes[offset.* + index * 3 + 1], bytes[offset.* + index * 3 + 2], 255 };
    offset.* += length;
}
fn readSubBlocks(allocator: std.mem.Allocator, bytes: []const u8, offset: *usize, output: *std.ArrayList(u8), maximum: usize) Error!void {
    while (true) {
        if (offset.* >= bytes.len) return error.InvalidImage;
        const length = bytes[offset.*];
        offset.* += 1;
        if (length == 0) break;
        if (offset.* + length > bytes.len) return error.InvalidImage;
        if (output.items.len > maximum -| length) return error.BudgetExceeded;
        try output.appendSlice(allocator, bytes[offset.* .. offset.* + length]);
        offset.* += length;
    }
}
fn skipSubBlocks(bytes: []const u8, offset: *usize) Error!void {
    while (true) {
        if (offset.* >= bytes.len) return error.InvalidImage;
        const length = bytes[offset.*];
        offset.* += 1;
        if (length == 0) return;
        if (offset.* + length > bytes.len) return error.InvalidImage;
        offset.* += length;
    }
}
fn readBits(bytes: []const u8, bit_offset: *usize, count: u5) ?u16 {
    if (bit_offset.* + count > bytes.len * 8) return null;
    var value: u16 = 0;
    for (0..count) |index| {
        const bit = (bytes[(bit_offset.* + index) / 8] >> @intCast((bit_offset.* + index) % 8)) & 1;
        value |= @as(u16, bit) << @intCast(index);
    }
    bit_offset.* += count;
    return value;
}
fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}
fn countPassRows(height: usize, start: usize, step: usize) usize {
    return if (height <= start) 0 else (height - start + step - 1) / step;
}
