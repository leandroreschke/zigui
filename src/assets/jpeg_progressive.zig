const std = @import("std");
const Error = @import("../core/error.zig").Error;
const image = @import("image.zig");

const zigzag = [_]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

const Huffman = struct {
    counts: [16]u8 = @splat(0),
    symbols: [256]u8 = undefined,
    valid: bool = false,

    fn decode(self: *const Huffman, bits: *BitReader) Error!u8 {
        if (!self.valid) return error.InvalidImage;
        var code: u32 = 0;
        var first: u32 = 0;
        var symbol: usize = 0;
        for (self.counts) |count| {
            code = (code << 1) | try bits.readBit();
            if (code >= first and code < first + count) return self.symbols[symbol + code - first];
            symbol += count;
            first = (first + count) << 1;
        }
        return error.InvalidImage;
    }
};

const Component = struct {
    id: u8,
    horizontal: u8,
    vertical: u8,
    quant_table: u8,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    dc_prediction: i32 = 0,
    block_width: usize = 0,
    block_height: usize = 0,
    coefficients: []i32 = &.{},
    plane: []u8 = &.{},
    sequential_scanned: bool = false,
    progressive_bits: [64]i8 = @splat(-1),
};

const Scan = struct {
    components: [4]usize = undefined,
    count: usize,
    spectral_start: u8,
    spectral_end: u8,
    successive_high: u8,
    successive_low: u8,
};

const Decoder = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: image.Limits,
    progressive: bool,
    width: u16 = 0,
    height: u16 = 0,
    components: [4]Component = undefined,
    component_count: usize = 0,
    maximum_horizontal: u8 = 0,
    maximum_vertical: u8 = 0,
    mcu_columns: usize = 0,
    mcu_rows: usize = 0,
    quantization: [4][64]u16 = @splat(@splat(0)),
    quant_valid: [4]bool = @splat(false),
    dc_tables: [4]Huffman = @splat(.{}),
    ac_tables: [4]Huffman = @splat(.{}),
    restart_interval: u16 = 0,
    adobe_transform: ?u8 = null,
    saw_frame: bool = false,
    saw_scan: bool = false,
    saw_end: bool = false,
    working_bytes: usize = 0,

    fn parseAndDecode(self: *Decoder) Error!void {
        if (self.bytes.len < 4 or self.bytes[0] != 0xff or self.bytes[1] != 0xd8) return error.InvalidImage;
        var offset: usize = 2;
        while (offset < self.bytes.len) {
            const marker_info = try nextMarker(self.bytes, offset);
            const marker = marker_info.marker;
            offset = marker_info.after;
            if (marker == 0xd9) {
                self.saw_end = true;
                break;
            }
            if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
            const length = readU16(self.bytes, offset) orelse return error.InvalidImage;
            if (length < 2 or offset + length > self.bytes.len) return error.InvalidImage;
            const payload = self.bytes[offset + 2 .. offset + length];
            switch (marker) {
                0xc2 => {
                    if (!self.progressive) return error.InvalidImage;
                    try self.parseFrame(payload);
                },
                0xc0, 0xc1 => {
                    if (self.progressive) return error.InvalidImage;
                    try self.parseFrame(payload);
                },
                0xc4 => try self.parseHuffman(payload),
                0xdb => try self.parseQuantization(payload),
                0xdd => {
                    if (payload.len != 2) return error.InvalidImage;
                    self.restart_interval = readU16(payload, 0) orelse return error.InvalidImage;
                },
                0xee => {
                    if (payload.len >= 12 and std.mem.eql(u8, payload[0..5], "Adobe")) self.adobe_transform = payload[11];
                },
                0xda => {
                    if (!self.saw_frame) return error.InvalidImage;
                    const scan = try self.parseScan(payload);
                    const entropy_start = offset + length;
                    const entropy_end = findEntropyEnd(self.bytes, entropy_start) orelse return error.InvalidImage;
                    try self.decodeScan(scan, self.bytes[entropy_start..entropy_end]);
                    self.saw_scan = true;
                    offset = entropy_end;
                    continue;
                },
                else => {},
            }
            offset += length;
        }
        if (!self.saw_scan or !self.saw_end) return error.InvalidImage;
        if (!self.progressive) for (self.components[0..self.component_count]) |component|
            if (!component.sequential_scanned) return error.InvalidImage;
    }

    fn parseFrame(self: *Decoder, data: []const u8) Error!void {
        if (self.saw_frame or data.len < 6 or data[0] != 8) return error.InvalidImage;
        self.height = readU16(data, 1) orelse return error.InvalidImage;
        self.width = readU16(data, 3) orelse return error.InvalidImage;
        self.component_count = data[5];
        _ = try image.validateDimensions(self.width, self.height, self.limits);
        if (self.component_count == 0 or self.component_count > 4 or data.len != 6 + self.component_count * 3) return error.InvalidImage;
        var blocks_per_mcu: usize = 0;
        for (0..self.component_count) |index| {
            const sampling = data[7 + index * 3];
            const horizontal = sampling >> 4;
            const vertical = sampling & 0xf;
            const quant = data[8 + index * 3];
            if (horizontal == 0 or vertical == 0 or horizontal > 4 or vertical > 4 or quant > 3) return error.InvalidImage;
            for (self.components[0..index]) |existing| if (existing.id == data[6 + index * 3]) return error.InvalidImage;
            self.components[index] = .{ .id = data[6 + index * 3], .horizontal = horizontal, .vertical = vertical, .quant_table = quant };
            self.maximum_horizontal = @max(self.maximum_horizontal, horizontal);
            self.maximum_vertical = @max(self.maximum_vertical, vertical);
            blocks_per_mcu += @as(usize, horizontal) * vertical;
        }
        if (blocks_per_mcu > 10) return error.InvalidImage;
        self.mcu_columns = (@as(usize, self.width) + self.maximum_horizontal * 8 - 1) / (self.maximum_horizontal * 8);
        self.mcu_rows = (@as(usize, self.height) + self.maximum_vertical * 8 - 1) / (self.maximum_vertical * 8);
        self.saw_frame = true;
        for (self.components[0..self.component_count]) |*component| {
            component.block_width = std.math.mul(usize, self.mcu_columns, component.horizontal) catch return error.BudgetExceeded;
            component.block_height = std.math.mul(usize, self.mcu_rows, component.vertical) catch return error.BudgetExceeded;
            const block_count = std.math.mul(usize, component.block_width, component.block_height) catch return error.BudgetExceeded;
            const coefficient_count = std.math.mul(usize, block_count, 64) catch return error.BudgetExceeded;
            const coefficient_bytes = std.math.mul(usize, coefficient_count, @sizeOf(i32)) catch return error.BudgetExceeded;
            self.working_bytes = std.math.add(usize, self.working_bytes, coefficient_bytes) catch return error.BudgetExceeded;
            if (self.working_bytes > self.limits.maximum_decoded_bytes) return error.BudgetExceeded;
            component.coefficients = try self.allocator.alloc(i32, coefficient_count);
            @memset(component.coefficients, 0);
        }
    }

    fn parseHuffman(self: *Decoder, data: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < data.len) {
            const info = data[offset];
            offset += 1;
            const class = info >> 4;
            const table_index = info & 0xf;
            if (class > 1 or table_index > 3 or offset + 16 > data.len) return error.InvalidImage;
            const table = if (class == 0) &self.dc_tables[table_index] else &self.ac_tables[table_index];
            @memcpy(&table.counts, data[offset..][0..16]);
            offset += 16;
            var count: usize = 0;
            for (table.counts) |value| count += value;
            if (count == 0 or count > table.symbols.len or offset + count > data.len) return error.InvalidImage;
            var available: i32 = 1;
            for (table.counts) |value| {
                available = available * 2 - value;
                if (available < 0) return error.InvalidImage;
            }
            @memcpy(table.symbols[0..count], data[offset..][0..count]);
            offset += count;
            table.valid = true;
        }
    }

    fn parseQuantization(self: *Decoder, data: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < data.len) {
            const info = data[offset];
            offset += 1;
            const precision = info >> 4;
            const table_index = info & 0xf;
            if (precision > 1 or table_index > 3) return error.InvalidImage;
            for (0..64) |index| {
                const value = if (precision == 0) blk: {
                    if (offset >= data.len) return error.InvalidImage;
                    const byte = data[offset];
                    offset += 1;
                    break :blk @as(u16, byte);
                } else blk: {
                    const word = readU16(data, offset) orelse return error.InvalidImage;
                    offset += 2;
                    break :blk word;
                };
                if (value == 0) return error.InvalidImage;
                self.quantization[table_index][zigzag[index]] = value;
            }
            self.quant_valid[table_index] = true;
        }
    }

    fn parseScan(self: *Decoder, data: []const u8) Error!Scan {
        if (data.len < 4) return error.InvalidImage;
        const count = data[0];
        if (count == 0 or count > 4 or data.len != 1 + @as(usize, count) * 2 + 3) return error.InvalidImage;
        var result: Scan = .{
            .count = count,
            .spectral_start = data[1 + @as(usize, count) * 2],
            .spectral_end = data[2 + @as(usize, count) * 2],
            .successive_high = data[3 + @as(usize, count) * 2] >> 4,
            .successive_low = data[3 + @as(usize, count) * 2] & 0xf,
        };
        if (result.spectral_start > result.spectral_end or result.spectral_end > 63 or result.successive_high > 13 or result.successive_low > 13) return error.InvalidImage;
        if (self.progressive) {
            if (result.spectral_start != 0 and count != 1) return error.InvalidImage;
            if (result.spectral_start == 0 and result.spectral_end != 0) return error.InvalidImage;
            if (result.successive_high != 0 and result.successive_low + 1 != result.successive_high) return error.InvalidImage;
        } else if (result.spectral_start != 0 or result.spectral_end != 63 or
            result.successive_high != 0 or result.successive_low != 0) return error.InvalidImage;
        var selected: [4]bool = .{ false, false, false, false };
        for (0..count) |scan_index| {
            const component_index = self.findComponent(data[1 + scan_index * 2]) orelse return error.InvalidImage;
            if (selected[component_index] or (!self.progressive and self.components[component_index].sequential_scanned)) return error.InvalidImage;
            selected[component_index] = true;
            const tables = data[2 + scan_index * 2];
            if (tables >> 4 > 3 or tables & 0xf > 3) return error.InvalidImage;
            self.components[component_index].dc_table = tables >> 4;
            self.components[component_index].ac_table = tables & 0xf;
            result.components[scan_index] = component_index;
        }
        if (self.progressive) for (result.components[0..result.count]) |component_index| {
            const component = &self.components[component_index];
            var coefficient: usize = result.spectral_start;
            while (coefficient <= result.spectral_end) : (coefficient += 1) {
                const previous = component.progressive_bits[coefficient];
                if (result.successive_high == 0) {
                    if (previous != -1) return error.InvalidImage;
                } else if (previous != result.successive_high) return error.InvalidImage;
            }
        };
        return result;
    }

    fn decodeScan(self: *Decoder, scan: Scan, entropy: []const u8) Error!void {
        for (self.components[0..self.component_count]) |*component| component.dc_prediction = 0;
        var bits: BitReader = .{ .bytes = entropy };
        var eob_run: u32 = 0;
        var expected_restart: u8 = 0;
        const interleaved = scan.count > 1;
        const mcu_columns = if (interleaved) self.mcu_columns else self.components[scan.components[0]].block_width;
        const mcu_rows = if (interleaved) self.mcu_rows else self.components[scan.components[0]].block_height;
        var mcu_index: usize = 0;
        for (0..mcu_rows) |mcu_y| for (0..mcu_columns) |mcu_x| {
            for (scan.components[0..scan.count]) |component_index| {
                const component = &self.components[component_index];
                const horizontal: usize = if (interleaved) component.horizontal else 1;
                const vertical: usize = if (interleaved) component.vertical else 1;
                for (0..vertical) |block_y| for (0..horizontal) |block_x| {
                    const x = if (interleaved) mcu_x * horizontal + block_x else mcu_x;
                    const y = if (interleaved) mcu_y * vertical + block_y else mcu_y;
                    if (x >= component.block_width or y >= component.block_height) continue;
                    const block = component.coefficients[(y * component.block_width + x) * 64 ..][0..64];
                    if (self.progressive)
                        try decodeProgressiveBlock(&bits, component, scan, block, &eob_run, &self.dc_tables, &self.ac_tables)
                    else
                        try decodeSequentialBlock(&bits, component, block, &self.dc_tables, &self.ac_tables);
                };
            }
            mcu_index += 1;
            if (self.restart_interval != 0 and mcu_index % self.restart_interval == 0 and mcu_index != mcu_columns * mcu_rows) {
                try bits.consumeRestart(expected_restart);
                expected_restart = (expected_restart + 1) & 7;
                for (self.components[0..self.component_count]) |*component| component.dc_prediction = 0;
                eob_run = 0;
            }
        };
        if (eob_run != 0) return error.InvalidImage;
        if (!self.progressive) {
            for (scan.components[0..scan.count]) |component_index| {
                self.components[component_index].sequential_scanned = true;
            }
        }
        if (self.progressive) for (scan.components[0..scan.count]) |component_index| {
            var coefficient: usize = scan.spectral_start;
            while (coefficient <= scan.spectral_end) : (coefficient += 1)
                self.components[component_index].progressive_bits[coefficient] = @intCast(scan.successive_low);
        };
    }

    fn makeImage(self: *Decoder, limits: image.Limits) Error!image.Image {
        const pixel_count = try image.validateDimensions(self.width, self.height, limits);
        for (self.components[0..self.component_count]) |*component| {
            if (!self.quant_valid[component.quant_table]) return error.InvalidImage;
            const plane_width = std.math.mul(usize, component.block_width, 8) catch return error.BudgetExceeded;
            const plane_height = std.math.mul(usize, component.block_height, 8) catch return error.BudgetExceeded;
            const plane_bytes = std.math.mul(usize, plane_width, plane_height) catch return error.BudgetExceeded;
            self.working_bytes = std.math.add(usize, self.working_bytes, plane_bytes) catch return error.BudgetExceeded;
            if (self.working_bytes > self.limits.maximum_decoded_bytes) return error.BudgetExceeded;
            component.plane = try self.allocator.alloc(u8, plane_bytes);
            @memset(component.plane, 0);
            for (0..component.block_height) |block_y| for (0..component.block_width) |block_x| {
                const coefficients: *const [64]i32 = @ptrCast(component.coefficients[(block_y * component.block_width + block_x) * 64 ..][0..64].ptr);
                idctBlock(coefficients.*, self.quantization[component.quant_table], component.plane, plane_width, block_x * 8, block_y * 8);
            };
        }
        const output_bytes = std.math.mul(usize, pixel_count, 4) catch return error.BudgetExceeded;
        if (self.working_bytes > self.limits.maximum_decoded_bytes -| output_bytes) return error.BudgetExceeded;
        const output = try self.allocator.alloc(u8, output_bytes);
        errdefer self.allocator.free(output);
        for (0..self.height) |y| for (0..self.width) |x| {
            var samples: [4]u8 = .{ 0, 128, 128, 0 };
            for (self.components[0..self.component_count], 0..) |component, component_index| {
                const plane_width = component.block_width * 8;
                const sample_x = x * component.horizontal / self.maximum_horizontal;
                const sample_y = y * component.vertical / self.maximum_vertical;
                samples[component_index] = component.plane[sample_y * plane_width + sample_x];
            }
            const rgba = self.convert(samples);
            @memcpy(output[(y * self.width + x) * 4 ..][0..4], &rgba);
        };
        return .{ .width = self.width, .height = self.height, .stride = @as(usize, self.width) * 4, .pixels = output };
    }

    fn convert(self: *const Decoder, values: [4]u8) [4]u8 {
        if (self.component_count == 1) return .{ values[0], values[0], values[0], 255 };
        if (self.component_count == 3) {
            if (self.components[0].id == 'R' and self.components[1].id == 'G' and self.components[2].id == 'B') return .{ values[0], values[1], values[2], 255 };
            return ycbcr(values[0], values[1], values[2]);
        }
        if (self.component_count == 4) {
            var c = values[0];
            var m = values[1];
            var y = values[2];
            const k = values[3];
            if (self.adobe_transform == 2) {
                const converted = ycbcr(values[0], values[1], values[2]);
                c = 255 - converted[0];
                m = 255 - converted[1];
                y = 255 - converted[2];
            }
            return .{
                @intCast((@as(u32, 255 - c) * (255 - k) + 127) / 255),
                @intCast((@as(u32, 255 - m) * (255 - k) + 127) / 255),
                @intCast((@as(u32, 255 - y) * (255 - k) + 127) / 255),
                255,
            };
        }
        return .{ 0, 0, 0, 255 };
    }

    fn findComponent(self: *const Decoder, id: u8) ?usize {
        for (self.components[0..self.component_count], 0..) |component, index| if (component.id == id) return index;
        return null;
    }

    fn deinit(self: *Decoder) void {
        if (!self.saw_frame) return;
        for (self.components[0..self.component_count]) |component| {
            if (component.coefficients.len != 0) self.allocator.free(component.coefficients);
            if (component.plane.len != 0) self.allocator.free(component.plane);
        }
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
    var decoder: Decoder = .{ .allocator = allocator, .bytes = bytes, .limits = limits, .progressive = true };
    defer decoder.deinit();
    try decoder.parseAndDecode();
    return decoder.makeImage(limits);
}

pub fn decodeSequential(allocator: std.mem.Allocator, bytes: []const u8, limits: image.Limits) Error!image.Image {
    if (bytes.len > limits.maximum_compressed_bytes) return error.BudgetExceeded;
    var decoder: Decoder = .{ .allocator = allocator, .bytes = bytes, .limits = limits, .progressive = false };
    defer decoder.deinit();
    try decoder.parseAndDecode();
    return decoder.makeImage(limits);
}

fn decodeSequentialBlock(
    bits: *BitReader,
    component: *Component,
    block: []i32,
    dc_tables: *const [4]Huffman,
    ac_tables: *const [4]Huffman,
) Error!void {
    const category = try dc_tables[component.dc_table].decode(bits);
    if (category > 11) return error.InvalidImage;
    component.dc_prediction = std.math.add(i32, component.dc_prediction, try receiveExtend(bits, category)) catch return error.InvalidImage;
    block[0] = component.dc_prediction;
    var coefficient: usize = 1;
    while (coefficient < 64) {
        const symbol = try ac_tables[component.ac_table].decode(bits);
        const run = symbol >> 4;
        const size = symbol & 0xf;
        if (size > 10) return error.InvalidImage;
        if (size == 0) {
            if (run == 0) break;
            if (run != 15) return error.InvalidImage;
            coefficient += 16;
            if (coefficient > 64) return error.InvalidImage;
            continue;
        }
        coefficient += run;
        if (coefficient >= 64) return error.InvalidImage;
        block[zigzag[coefficient]] = try receiveExtend(bits, size);
        coefficient += 1;
    }
}

fn decodeProgressiveBlock(
    bits: *BitReader,
    component: *Component,
    scan: Scan,
    block: []i32,
    eob_run: *u32,
    dc_tables: *const [4]Huffman,
    ac_tables: *const [4]Huffman,
) Error!void {
    if (scan.spectral_start == 0) {
        if (scan.successive_high == 0) {
            const category = try dc_tables[component.dc_table].decode(bits);
            if (category > 11) return error.InvalidImage;
            component.dc_prediction = std.math.add(i32, component.dc_prediction, try receiveExtend(bits, category)) catch return error.InvalidImage;
            block[0] = try scaleCoefficient(component.dc_prediction, scan.successive_low);
        } else if (try bits.readBit() != 0) {
            const refinement = @as(i32, 1) << @intCast(scan.successive_low);
            block[0] = std.math.add(i32, block[0], if (block[0] >= 0) refinement else -refinement) catch return error.InvalidImage;
        }
        return;
    }
    if (scan.successive_high == 0)
        try decodeAcFirst(bits, &ac_tables[component.ac_table], scan, block, eob_run)
    else
        try decodeAcRefine(bits, &ac_tables[component.ac_table], scan, block, eob_run);
}

fn decodeAcFirst(bits: *BitReader, table: *const Huffman, scan: Scan, block: []i32, eob_run: *u32) Error!void {
    if (eob_run.* != 0) {
        eob_run.* -= 1;
        return;
    }
    var k: usize = scan.spectral_start;
    while (k <= scan.spectral_end) {
        const symbol = try table.decode(bits);
        const run = symbol >> 4;
        const size = symbol & 0xf;
        if (size > 10) return error.InvalidImage;
        if (size == 0) {
            if (run == 15) {
                k += 16;
                continue;
            }
            eob_run.* = (@as(u32, 1) << @intCast(run)) + if (run == 0) 0 else try bits.readBits(@intCast(run));
            eob_run.* -= 1;
            break;
        }
        k += run;
        if (k > scan.spectral_end) return error.InvalidImage;
        block[zigzag[k]] = try scaleCoefficient(try receiveExtend(bits, size), scan.successive_low);
        k += 1;
    }
}

fn decodeAcRefine(bits: *BitReader, table: *const Huffman, scan: Scan, block: []i32, eob_run: *u32) Error!void {
    const bit_value: i32 = @as(i32, 1) << @intCast(scan.successive_low);
    var k: usize = scan.spectral_start;
    if (eob_run.* == 0) {
        while (k <= scan.spectral_end) {
            const symbol = try table.decode(bits);
            var run: usize = symbol >> 4;
            const size = symbol & 0xf;
            var new_value: i32 = 0;
            if (size == 0) {
                if (run != 15) {
                    eob_run.* = (@as(u32, 1) << @intCast(run)) + if (run == 0) 0 else try bits.readBits(@intCast(run));
                    break;
                }
                run = 16;
            } else {
                if (size != 1) return error.InvalidImage;
                new_value = if (try bits.readBit() != 0) bit_value else -bit_value;
            }
            while (k <= scan.spectral_end) : (k += 1) {
                const coefficient = &block[zigzag[k]];
                if (coefficient.* != 0) {
                    try refineCoefficient(bits, coefficient, bit_value);
                } else if (run == 0) {
                    if (size != 0) {
                        coefficient.* = new_value;
                        k += 1;
                    }
                    break;
                } else run -= 1;
            }
        }
    }
    if (eob_run.* != 0) {
        while (k <= scan.spectral_end) : (k += 1) if (block[zigzag[k]] != 0) try refineCoefficient(bits, &block[zigzag[k]], bit_value);
        eob_run.* -= 1;
    }
}

fn refineCoefficient(bits: *BitReader, coefficient: *i32, bit_value: i32) Error!void {
    if (try bits.readBit() == 0 or @as(u32, @intCast(@abs(coefficient.*))) & @as(u32, @intCast(bit_value)) != 0) return;
    coefficient.* = std.math.add(i32, coefficient.*, if (coefficient.* > 0) bit_value else -bit_value) catch return error.InvalidImage;
}

fn scaleCoefficient(value: i32, shift: u8) Error!i32 {
    const scaled = @as(i64, value) * (@as(i64, 1) << @intCast(shift));
    if (scaled < std.math.minInt(i32) or scaled > std.math.maxInt(i32)) return error.InvalidImage;
    return @intCast(scaled);
}

const Marker = struct { marker: u8, after: usize };

fn nextMarker(bytes: []const u8, start: usize) Error!Marker {
    var offset = start;
    while (offset < bytes.len and bytes[offset] != 0xff) offset += 1;
    while (offset < bytes.len and bytes[offset] == 0xff) offset += 1;
    if (offset >= bytes.len or bytes[offset] == 0) return error.InvalidImage;
    return .{ .marker = bytes[offset], .after = offset + 1 };
}

fn findEntropyEnd(bytes: []const u8, start: usize) ?usize {
    var offset = start;
    while (offset + 1 < bytes.len) {
        if (bytes[offset] != 0xff) {
            offset += 1;
            continue;
        }
        var marker = offset + 1;
        while (marker < bytes.len and bytes[marker] == 0xff) marker += 1;
        if (marker >= bytes.len) return null;
        if (bytes[marker] == 0 or (bytes[marker] >= 0xd0 and bytes[marker] <= 0xd7)) {
            offset = marker + 1;
            continue;
        }
        return offset;
    }
    return null;
}

const BitReader = struct {
    bytes: []const u8,
    offset: usize = 0,
    bits: u64 = 0,
    count: u7 = 0,
    restart_marker: ?u8 = null,

    fn readBit(self: *BitReader) Error!u1 {
        return @intCast(try self.readBits(1));
    }
    fn readBits(self: *BitReader, count: u6) Error!u32 {
        if (count == 0 or count > 32) return error.InvalidImage;
        while (self.count < count) {
            self.bits = (self.bits << 8) | try self.readByte();
            self.count += 8;
        }
        self.count -= count;
        const value: u32 = @truncate(self.bits >> @intCast(self.count));
        const mask = if (count == 32) std.math.maxInt(u32) else (@as(u32, 1) << @intCast(count)) - 1;
        return value & mask;
    }
    fn readByte(self: *BitReader) Error!u8 {
        if (self.offset >= self.bytes.len) return error.InvalidImage;
        const byte = self.bytes[self.offset];
        self.offset += 1;
        if (byte != 0xff) return byte;
        while (self.offset < self.bytes.len and self.bytes[self.offset] == 0xff) self.offset += 1;
        if (self.offset >= self.bytes.len) return error.InvalidImage;
        const marker = self.bytes[self.offset];
        self.offset += 1;
        if (marker == 0) return 0xff;
        if (marker >= 0xd0 and marker <= 0xd7) {
            self.restart_marker = marker;
            return error.InvalidImage;
        }
        return error.InvalidImage;
    }
    fn consumeRestart(self: *BitReader, expected: u8) Error!void {
        self.bits = 0;
        self.count = 0;
        if (self.restart_marker) |marker| {
            if (marker != 0xd0 + expected) return error.InvalidImage;
            self.restart_marker = null;
            return;
        }
        if (self.offset >= self.bytes.len or self.bytes[self.offset] != 0xff) return error.InvalidImage;
        while (self.offset < self.bytes.len and self.bytes[self.offset] == 0xff) self.offset += 1;
        if (self.offset >= self.bytes.len or self.bytes[self.offset] != 0xd0 + expected) return error.InvalidImage;
        self.offset += 1;
    }
};

test "bit reader returns only the requested high bits" {
    var bits: BitReader = .{ .bytes = &.{ 0b10110110, 0b01101001 } };
    try std.testing.expectEqual(@as(u32, 0b101), try bits.readBits(3));
    try std.testing.expectEqual(@as(u1, 1), try bits.readBit());
    try std.testing.expectEqual(@as(u32, 0b0110), try bits.readBits(4));
    try std.testing.expectEqual(@as(u32, 0b01101001), try bits.readBits(8));
    try std.testing.expectError(error.InvalidImage, bits.readBits(0));
}

fn receiveExtend(bits: *BitReader, count: u8) Error!i32 {
    if (count == 0) return 0;
    const value = try bits.readBits(@intCast(count));
    const threshold = @as(u32, 1) << @intCast(count - 1);
    if (value >= threshold) return @intCast(value);
    return @as(i32, @intCast(value)) - @as(i32, @intCast((@as(u32, 1) << @intCast(count)) - 1));
}

fn idctBlock(coefficients: [64]i32, quantization: [64]u16, plane: []u8, stride: usize, destination_x: usize, destination_y: usize) void {
    for (0..8) |y| for (0..8) |x| {
        var sum: f64 = 0;
        for (0..8) |v| for (0..8) |u| {
            const cu: f64 = if (u == 0) 0.7071067811865476 else 1;
            const cv: f64 = if (v == 0) 0.7071067811865476 else 1;
            const coefficient = @as(f64, @floatFromInt(coefficients[v * 8 + u])) * quantization[v * 8 + u];
            sum += cu * cv * coefficient * @cos((2 * @as(f64, @floatFromInt(x)) + 1) * @as(f64, @floatFromInt(u)) * std.math.pi / 16.0) *
                @cos((2 * @as(f64, @floatFromInt(y)) + 1) * @as(f64, @floatFromInt(v)) * std.math.pi / 16.0);
        };
        plane[(destination_y + y) * stride + destination_x + x] = @intFromFloat(std.math.clamp(@round(sum / 4 + 128), 0, 255));
    };
}

fn ycbcr(y: u8, cb: u8, cr: u8) [4]u8 {
    const yf: f32 = @floatFromInt(y);
    const cbf: f32 = @as(f32, @floatFromInt(cb)) - 128;
    const crf: f32 = @as(f32, @floatFromInt(cr)) - 128;
    return .{ clampByte(yf + 1.402 * crf), clampByte(yf - 0.344136 * cbf - 0.714136 * crf), clampByte(yf + 1.772 * cbf), 255 };
}

fn clampByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 255)));
}
fn readU16(bytes: []const u8, offset: usize) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}
