const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const api = @import("api.zig");
const opentype = @import("opentype.zig");
const variation = @import("opentype_variation.zig");

const maximum_graph_depth = 64;
const maximum_graph_nodes = 65_536;
const maximum_raster_dimension = 8192;
const maximum_raster_pixels = 1024 * 1024;
const maximum_live_surface_pixels = maximum_raster_pixels * 8;
const maximum_raster_segments = 1_048_576;
const maximum_text_size: f32 = 1_000_000;
const maximum_scale_factor: f32 = 64;

pub fn hasGlyph(font: opentype.Font, glyph: u16) bool {
    const table = font.optionalTable("COLR".*) orelse return false;
    return rootPaint(table, glyph) catch null != null;
}

pub fn usesForeground(font: opentype.Font, glyph: u16) bool {
    const table = font.optionalTable("COLR".*) orelse return false;
    const root_optional = rootPaint(table, glyph) catch return false;
    const root = root_optional orelse return false;
    var graph: Graph = .{
        .allocator = std.heap.page_allocator,
        .font = font,
        .table = table,
        .base_list = requiredOffset(table, 14) catch return false,
        .layer_list = optionalOffset(table, 18) catch return false,
        .variation_map = optionalOffset(table, 26) catch return false,
        .variation_store = optionalOffset(table, 30) catch return false,
    };
    var stack: [maximum_graph_depth]usize = undefined;
    return graph.paintUsesForeground(root, &stack, 0) catch false;
}

pub fn rasterize(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    glyph: u16,
    size: f32,
    scale_factor: f32,
    foreground: geometry.Color,
) Error!api.RasterizedGlyph {
    if (!(size > 0) or size > maximum_text_size or !(scale_factor > 0) or scale_factor > maximum_scale_factor or
        !std.math.isFinite(size) or !std.math.isFinite(scale_factor)) return error.InvalidConfiguration;
    const table = font.optionalTable("COLR".*) orelse return error.Unsupported;
    if (glyph >= try font.glyphCount()) return error.InvalidFont;
    const root = try rootPaint(table, glyph) orelse return error.Unsupported;
    const units = try font.unitsPerEm();
    if (units == 0) return error.InvalidFont;
    const device_scale = size * scale_factor / @as(f32, @floatFromInt(units));
    if (!std.math.isFinite(device_scale)) return error.InvalidConfiguration;
    var graph: Graph = .{
        .allocator = allocator,
        .font = font,
        .table = table,
        .base_list = try requiredOffset(table, 14),
        .layer_list = try optionalOffset(table, 18),
        .clip_list = try optionalOffset(table, 22),
        .variation_map = try optionalOffset(table, 26),
        .variation_store = try optionalOffset(table, 30),
        .foreground = foregroundPixel(foreground),
    };
    var stack: [maximum_graph_depth]usize = undefined;
    const root_transform = geometry.Affine2D.scale(device_scale, device_scale);
    const paint_extent = try graph.bounds(root, root_transform, &stack, 0);
    const extent = if (try graph.clipBounds(glyph, root_transform)) |clip_extent|
        intersect(paint_extent, clip_extent)
    else
        paint_extent;
    const finite = switch (extent) {
        .empty => return empty(allocator),
        .unbounded => return error.InvalidFont,
        .finite => |value| value,
    };
    if (!finiteBounds(finite)) return error.InvalidFont;
    const left = @floor(finite.minimum.x) - 1;
    const right = @ceil(finite.maximum.x) + 1;
    const bottom = @floor(finite.minimum.y) - 1;
    const top = @ceil(finite.maximum.y) + 1;
    if (!(right > left) or !(top > bottom)) return empty(allocator);
    const width_value = right - left;
    const height_value = top - bottom;
    if (!std.math.isFinite(width_value) or !std.math.isFinite(height_value)) return error.InvalidFont;
    if (width_value > maximum_raster_dimension or height_value > maximum_raster_dimension) return error.BudgetExceeded;
    const width: usize = @intFromFloat(width_value);
    const height: usize = @intFromFloat(height_value);
    const pixel_count = std.math.mul(usize, width, height) catch return error.BudgetExceeded;
    if (pixel_count > maximum_raster_pixels) return error.BudgetExceeded;

    graph.canvas = .{ .left = left, .top = top, .width = width, .height = height };
    graph.nodes_seen = 0;
    var surface = try graph.render(root, root_transform, &stack, 0);
    defer surface.deinit(allocator);
    std.debug.assert(graph.live_surface_pixels == surface.pixels.len);
    const stride = std.math.mul(usize, width, 4) catch return error.BudgetExceeded;
    const output = try allocator.alloc(u8, std.math.mul(usize, stride, height) catch return error.BudgetExceeded);
    errdefer allocator.free(output);
    for (surface.pixels, 0..) |pixel, index| {
        if (!finitePixel(pixel)) return error.InvalidFont;
        const alpha = std.math.clamp(pixel.a, 0, 1);
        const reciprocal = if (alpha > 0.000001) 1 / alpha else 0;
        output[index * 4] = toByte(linearToSrgb(std.math.clamp(pixel.r * reciprocal, 0, 1)));
        output[index * 4 + 1] = toByte(linearToSrgb(std.math.clamp(pixel.g * reciprocal, 0, 1)));
        output[index * 4 + 2] = toByte(linearToSrgb(std.math.clamp(pixel.b * reciprocal, 0, 1)));
        output[index * 4 + 3] = toByte(alpha);
    }
    return .{
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        .origin = .{ .x = left, .y = -top },
        .stride = stride,
        .pixels = output,
        .mode = .color,
    };
}

const Pixel = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    fn scaled(self: Pixel, amount: f32) Pixel {
        return .{ .r = self.r * amount, .g = self.g * amount, .b = self.b * amount, .a = self.a * amount };
    }
};

const Surface = struct {
    pixels: []Pixel,
    live_pixels: *usize,

    fn init(allocator: std.mem.Allocator, count: usize, live_pixels: *usize) Error!Surface {
        const next = std.math.add(usize, live_pixels.*, count) catch return error.BudgetExceeded;
        if (next > maximum_live_surface_pixels) return error.BudgetExceeded;
        const pixels = try allocator.alloc(Pixel, count);
        @memset(pixels, .{});
        live_pixels.* = next;
        return .{ .pixels = pixels, .live_pixels = live_pixels };
    }

    fn deinit(self: *Surface, allocator: std.mem.Allocator) void {
        std.debug.assert(self.live_pixels.* >= self.pixels.len);
        self.live_pixels.* -= self.pixels.len;
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

const Canvas = struct {
    left: f32 = 0,
    top: f32 = 0,
    width: usize = 0,
    height: usize = 0,

    fn point(self: Canvas, index: usize) geometry.Point {
        const x = index % self.width;
        const y = index / self.width;
        return .{
            .x = self.left + @as(f32, @floatFromInt(x)) + 0.5,
            .y = self.top - @as(f32, @floatFromInt(y)) - 0.5,
        };
    }
};

const Bounds = struct {
    minimum: geometry.Point,
    maximum: geometry.Point,
};

const Extent = union(enum) {
    empty,
    finite: Bounds,
    unbounded,
};

const Graph = struct {
    allocator: std.mem.Allocator,
    font: opentype.Font,
    table: []const u8,
    base_list: usize,
    layer_list: ?usize,
    clip_list: ?usize = null,
    variation_map: ?usize = null,
    variation_store: ?usize = null,
    foreground: Pixel = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    canvas: Canvas = .{},
    nodes_seen: usize = 0,
    live_surface_pixels: usize = 0,

    fn surface(self: *Graph) Error!Surface {
        const count = std.math.mul(usize, self.canvas.width, self.canvas.height) catch return error.BudgetExceeded;
        return Surface.init(self.allocator, count, &self.live_surface_pixels);
    }

    fn variationDelta(self: *const Graph, base: u32, sequence: u32) Error!f32 {
        const store_offset = self.variation_store orelse return error.InvalidFont;
        if (base == 0xffff_ffff) return 0;
        const item = std.math.add(u32, base, sequence) catch return error.InvalidFont;
        const index: variation.DeltaSetIndex = if (self.variation_map) |map_offset|
            try variation.deltaSetIndex(self.table[map_offset..], item)
        else
            .{ .outer = @truncate(item >> 16), .inner = @truncate(item) };
        return variation.itemDelta(self.table[store_offset..], self.font.variation_coordinates, index);
    }

    fn variableFword(self: *const Graph, offset: usize, base: u32, sequence: u32) Error!f32 {
        return @as(f32, @floatFromInt(try i16be(self.table, offset))) + try self.variationDelta(base, sequence);
    }

    fn variableUfword(self: *const Graph, offset: usize, base: u32, sequence: u32) Error!f32 {
        return @max(0, @as(f32, @floatFromInt(try u16be(self.table, offset))) + try self.variationDelta(base, sequence));
    }

    fn variableF2Dot14(self: *const Graph, offset: usize, base: u32, sequence: u32) Error!f32 {
        return (@as(f32, @floatFromInt(try i16be(self.table, offset))) + try self.variationDelta(base, sequence)) / 16384.0;
    }

    fn variableFixed(self: *const Graph, offset: usize, base: u32, sequence: u32) Error!f32 {
        return (@as(f32, @floatFromInt(try i32be(self.table, offset))) + try self.variationDelta(base, sequence)) / 65536.0;
    }

    fn clipBounds(self: *const Graph, glyph: u16, transform: geometry.Affine2D) Error!?Extent {
        const list_offset = self.clip_list orelse return null;
        if (!rangeFits(self.table.len, list_offset, 5) or self.table[list_offset] != 1) return error.InvalidFont;
        const count = try u32be(self.table, list_offset + 1);
        if (count > 1_000_000 or !rangeFits(self.table.len, list_offset, 5 + @as(usize, count) * 7)) return error.InvalidFont;
        var low: usize = 0;
        var high: usize = @intCast(count);
        while (low < high) {
            const middle = low + (high - low) / 2;
            const record = list_offset + 5 + middle * 7;
            if (try u16be(self.table, record + 2) < glyph) low = middle + 1 else high = middle;
        }
        if (low >= @as(usize, count)) return null;
        const record = list_offset + 5 + low * 7;
        const first = try u16be(self.table, record);
        const last = try u16be(self.table, record + 2);
        if (first > last) return error.InvalidFont;
        if (glyph < first or glyph > last) return null;
        const box_offset = try addOffset(self.table, list_offset, try u24be(self.table, record + 4));
        const format = self.table[box_offset];
        if (format != 1 and format != 2) return error.InvalidFont;
        const variable = format == 2;
        const base = if (variable) try u32be(self.table, box_offset + 9) else 0;
        const minimum = geometry.Point{
            .x = @floor(if (variable) try self.variableFword(box_offset + 1, base, 0) else @as(f32, @floatFromInt(try i16be(self.table, box_offset + 1)))),
            .y = @floor(if (variable) try self.variableFword(box_offset + 3, base, 1) else @as(f32, @floatFromInt(try i16be(self.table, box_offset + 3)))),
        };
        const maximum = geometry.Point{
            .x = @ceil(if (variable) try self.variableFword(box_offset + 5, base, 2) else @as(f32, @floatFromInt(try i16be(self.table, box_offset + 5)))),
            .y = @ceil(if (variable) try self.variableFword(box_offset + 7, base, 3) else @as(f32, @floatFromInt(try i16be(self.table, box_offset + 7)))),
        };
        if (minimum.x > maximum.x or minimum.y > maximum.y) return .empty;
        const corners = [_]geometry.Point{
            transform.transformPoint(minimum),
            transform.transformPoint(.{ .x = maximum.x, .y = minimum.y }),
            transform.transformPoint(maximum),
            transform.transformPoint(.{ .x = minimum.x, .y = maximum.y }),
        };
        var transformed_minimum = corners[0];
        var transformed_maximum = corners[0];
        for (corners[1..]) |corner| {
            transformed_minimum.x = @min(transformed_minimum.x, corner.x);
            transformed_minimum.y = @min(transformed_minimum.y, corner.y);
            transformed_maximum.x = @max(transformed_maximum.x, corner.x);
            transformed_maximum.y = @max(transformed_maximum.y, corner.y);
        }
        return .{ .finite = .{ .minimum = transformed_minimum, .maximum = transformed_maximum } };
    }

    fn visit(self: *Graph, offset: usize, stack: *[maximum_graph_depth]usize, depth: usize) Error!void {
        if (offset >= self.table.len or depth >= maximum_graph_depth) return error.InvalidFont;
        for (stack[0..depth]) |ancestor| if (ancestor == offset) return error.InvalidFont;
        stack[depth] = offset;
        self.nodes_seen += 1;
        if (self.nodes_seen > maximum_graph_nodes) return error.BudgetExceeded;
    }

    fn bounds(
        self: *Graph,
        offset: usize,
        transform: geometry.Affine2D,
        stack: *[maximum_graph_depth]usize,
        depth: usize,
    ) Error!Extent {
        if (!finiteTransform(transform)) return error.InvalidFont;
        try self.visit(offset, stack, depth);
        const format = self.table[offset];
        return switch (format) {
            1 => self.layerBounds(offset, transform, stack, depth + 1),
            2...9 => .unbounded,
            10 => self.glyphBounds(try u16be(self.table, offset + 4), transform),
            11 => blk: {
                const child = try self.colrGlyphRoot(try u16be(self.table, offset + 1));
                break :blk try self.bounds(child, transform, stack, depth + 1);
            },
            12...31 => blk: {
                const transformed = try self.transformNode(offset, format);
                break :blk try self.bounds(
                    transformed.child,
                    geometry.Affine2D.mul(transform, transformed.matrix),
                    stack,
                    depth + 1,
                );
            },
            32 => blk: {
                const source = try addOffset(self.table, offset, try u24be(self.table, offset + 1));
                const backdrop = try addOffset(self.table, offset, try u24be(self.table, offset + 5));
                break :blk combine(
                    try self.bounds(source, transform, stack, depth + 1),
                    try self.bounds(backdrop, transform, stack, depth + 1),
                );
            },
            else => error.InvalidFont,
        };
    }

    fn paintUsesForeground(
        self: *Graph,
        offset: usize,
        stack: *[maximum_graph_depth]usize,
        depth: usize,
    ) Error!bool {
        try self.visit(offset, stack, depth);
        const format = self.table[offset];
        return switch (format) {
            1 => blk: {
                const layer_list = self.layer_list orelse return error.InvalidFont;
                const total = try u32be(self.table, layer_list);
                const count = self.table[offset + 1];
                const first = try u32be(self.table, offset + 2);
                if (@as(usize, first) + @as(usize, count) > @as(usize, total)) return error.InvalidFont;
                for (0..count) |index| {
                    const relative = try u32be(self.table, layer_list + 4 + (@as(usize, first) + index) * 4);
                    const child = try addOffset(self.table, layer_list, relative);
                    if (try self.paintUsesForeground(child, stack, depth + 1)) break :blk true;
                }
                break :blk false;
            },
            2, 3 => try u16be(self.table, offset + 1) == 0xffff,
            4...9 => blk: {
                const line_offset = try addOffset(self.table, offset, try u24be(self.table, offset + 1));
                break :blk try colorLineUsesForeground(self.table, line_offset, format == 5 or format == 7 or format == 9);
            },
            10 => self.paintUsesForeground(
                try addOffset(self.table, offset, try u24be(self.table, offset + 1)),
                stack,
                depth + 1,
            ),
            11 => blk: {
                const child = try self.colrGlyphRoot(try u16be(self.table, offset + 1));
                break :blk try self.paintUsesForeground(child, stack, depth + 1);
            },
            12...31 => self.paintUsesForeground(
                try addOffset(self.table, offset, try u24be(self.table, offset + 1)),
                stack,
                depth + 1,
            ),
            32 => (try self.paintUsesForeground(
                try addOffset(self.table, offset, try u24be(self.table, offset + 1)),
                stack,
                depth + 1,
            )) or (try self.paintUsesForeground(
                try addOffset(self.table, offset, try u24be(self.table, offset + 5)),
                stack,
                depth + 1,
            )),
            else => error.InvalidFont,
        };
    }

    fn layerBounds(
        self: *Graph,
        offset: usize,
        transform: geometry.Affine2D,
        stack: *[maximum_graph_depth]usize,
        depth: usize,
    ) Error!Extent {
        const layer_list = self.layer_list orelse return error.InvalidFont;
        const layer_count = try u32be(self.table, layer_list);
        const count = self.table[offset + 1];
        const first = try u32be(self.table, offset + 2);
        if (@as(usize, first) + @as(usize, count) > @as(usize, layer_count)) return error.InvalidFont;
        var result: Extent = .empty;
        for (0..count) |index| {
            const relative = try u32be(self.table, layer_list + 4 + (@as(usize, first) + index) * 4);
            const child = try addOffset(self.table, layer_list, relative);
            result = combine(result, try self.bounds(child, transform, stack, depth));
        }
        return result;
    }

    fn glyphBounds(self: *Graph, glyph: u16, transform: geometry.Affine2D) Error!Extent {
        if (!finiteTransform(transform)) return error.InvalidFont;
        var outline = try self.font.outline(self.allocator, glyph);
        defer outline.deinit(self.allocator);
        if (outline.points.len == 0) return .empty;
        var minimum = geometry.Point{ .x = std.math.inf(f32), .y = std.math.inf(f32) };
        var maximum = geometry.Point{ .x = -std.math.inf(f32), .y = -std.math.inf(f32) };
        for (outline.points) |point| {
            if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidFont;
            const value = transform.transformPoint(.{ .x = point.x, .y = point.y });
            if (!finitePoint(value)) return error.InvalidFont;
            minimum.x = @min(minimum.x, value.x);
            minimum.y = @min(minimum.y, value.y);
            maximum.x = @max(maximum.x, value.x);
            maximum.y = @max(maximum.y, value.y);
        }
        if (!std.math.isFinite(minimum.x)) return .empty;
        return .{ .finite = .{ .minimum = minimum, .maximum = maximum } };
    }

    fn render(
        self: *Graph,
        offset: usize,
        transform: geometry.Affine2D,
        stack: *[maximum_graph_depth]usize,
        depth: usize,
    ) Error!Surface {
        if (!finiteTransform(transform)) return error.InvalidFont;
        try self.visit(offset, stack, depth);
        const format = self.table[offset];
        return switch (format) {
            1 => self.renderLayers(offset, transform, stack, depth + 1),
            2, 3 => self.renderSolid(offset),
            4, 5 => self.renderLinear(offset, format, transform),
            6, 7 => self.renderRadial(offset, format, transform),
            8, 9 => self.renderSweep(offset, format, transform),
            10 => self.renderGlyph(offset, transform, stack, depth + 1),
            11 => blk: {
                const child = try self.colrGlyphRoot(try u16be(self.table, offset + 1));
                break :blk self.render(child, transform, stack, depth + 1);
            },
            12...31 => blk: {
                const transformed = try self.transformNode(offset, format);
                break :blk self.render(transformed.child, geometry.Affine2D.mul(transform, transformed.matrix), stack, depth + 1);
            },
            32 => self.renderComposite(offset, transform, stack, depth + 1),
            else => error.InvalidFont,
        };
    }

    fn renderLayers(
        self: *Graph,
        offset: usize,
        transform: geometry.Affine2D,
        stack: *[maximum_graph_depth]usize,
        depth: usize,
    ) Error!Surface {
        const layer_list = self.layer_list orelse return error.InvalidFont;
        const total = try u32be(self.table, layer_list);
        const count = self.table[offset + 1];
        const first = try u32be(self.table, offset + 2);
        if (@as(usize, first) + @as(usize, count) > @as(usize, total)) return error.InvalidFont;
        var result = try self.surface();
        errdefer result.deinit(self.allocator);
        for (0..count) |index| {
            const relative = try u32be(self.table, layer_list + 4 + (@as(usize, first) + index) * 4);
            const child_offset = try addOffset(self.table, layer_list, relative);
            var child = try self.render(child_offset, transform, stack, depth);
            for (result.pixels, child.pixels) |*destination, source| destination.* = sourceOver(source, destination.*);
            child.deinit(self.allocator);
        }
        return result;
    }

    fn renderSolid(self: *Graph, offset: usize) Error!Surface {
        const variable = self.table[offset] == 3;
        const palette_index = try u16be(self.table, offset + 1);
        const alpha = std.math.clamp(if (variable)
            try self.variableF2Dot14(offset + 3, try u32be(self.table, offset + 5), 0)
        else
            try f2dot14(self.table, offset + 3), 0, 1);
        const color = (try palettePixel(self.font, palette_index, self.foreground)).scaled(alpha);
        const result = try self.surface();
        @memset(result.pixels, color);
        return result;
    }

    fn renderLinear(self: *Graph, offset: usize, format: u8, transform: geometry.Affine2D) Error!Surface {
        const line_offset = try addOffset(self.table, offset, try u24be(self.table, offset + 1));
        var line = try ColorLine.parse(self.allocator, self, line_offset, format == 5);
        defer line.deinit(self.allocator);
        const variable = format == 5;
        const base = if (variable) try u32be(self.table, offset + 16) else 0;
        const p0 = geometry.Point{
            .x = if (variable) try self.variableFword(offset + 4, base, 0) else @floatFromInt(try i16be(self.table, offset + 4)),
            .y = if (variable) try self.variableFword(offset + 6, base, 1) else @floatFromInt(try i16be(self.table, offset + 6)),
        };
        const p1 = geometry.Point{
            .x = if (variable) try self.variableFword(offset + 8, base, 2) else @floatFromInt(try i16be(self.table, offset + 8)),
            .y = if (variable) try self.variableFword(offset + 10, base, 3) else @floatFromInt(try i16be(self.table, offset + 10)),
        };
        const p2 = geometry.Point{
            .x = if (variable) try self.variableFword(offset + 12, base, 4) else @floatFromInt(try i16be(self.table, offset + 12)),
            .y = if (variable) try self.variableFword(offset + 14, base, 5) else @floatFromInt(try i16be(self.table, offset + 14)),
        };
        const gradient_axis = p2.sub(p0);
        const perpendicular = geometry.Point{ .x = -gradient_axis.y, .y = gradient_axis.x };
        const denominator = dot(p1.sub(p0), perpendicular);
        const result = try self.surface();
        errdefer result.deinit(self.allocator);
        if (@abs(denominator) <= 0.00001) return result;
        const inverse = transform.inverse() orelse return result;
        for (result.pixels, 0..) |*pixel, index| {
            const local = inverse.transformPoint(self.canvas.point(index));
            pixel.* = line.sample(dot(local.sub(p0), perpendicular) / denominator);
        }
        return result;
    }

    fn renderRadial(self: *Graph, offset: usize, format: u8, transform: geometry.Affine2D) Error!Surface {
        const line_offset = try addOffset(self.table, offset, try u24be(self.table, offset + 1));
        var line = try ColorLine.parse(self.allocator, self, line_offset, format == 7);
        defer line.deinit(self.allocator);
        const variable = format == 7;
        const base = if (variable) try u32be(self.table, offset + 16) else 0;
        const c0 = geometry.Point{
            .x = if (variable) try self.variableFword(offset + 4, base, 0) else @floatFromInt(try i16be(self.table, offset + 4)),
            .y = if (variable) try self.variableFword(offset + 6, base, 1) else @floatFromInt(try i16be(self.table, offset + 6)),
        };
        const r0: f32 = if (variable) try self.variableUfword(offset + 8, base, 2) else @floatFromInt(try u16be(self.table, offset + 8));
        const c1 = geometry.Point{
            .x = if (variable) try self.variableFword(offset + 10, base, 3) else @floatFromInt(try i16be(self.table, offset + 10)),
            .y = if (variable) try self.variableFword(offset + 12, base, 4) else @floatFromInt(try i16be(self.table, offset + 12)),
        };
        const r1: f32 = if (variable) try self.variableUfword(offset + 14, base, 5) else @floatFromInt(try u16be(self.table, offset + 14));
        var result = try self.surface();
        errdefer result.deinit(self.allocator);
        if (samePoint(c0, c1) and @abs(r0 - r1) <= 0.00001) return result;
        const inverse = transform.inverse() orelse return result;
        for (result.pixels, 0..) |*pixel, index| {
            const local = inverse.transformPoint(self.canvas.point(index));
            if (radialParameter(local, c0, r0, c1, r1)) |parameter| pixel.* = line.sample(parameter);
        }
        return result;
    }

    fn renderSweep(self: *Graph, offset: usize, format: u8, transform: geometry.Affine2D) Error!Surface {
        const line_offset = try addOffset(self.table, offset, try u24be(self.table, offset + 1));
        var line = try ColorLine.parse(self.allocator, self, line_offset, format == 9);
        defer line.deinit(self.allocator);
        const variable = format == 9;
        const base = if (variable) try u32be(self.table, offset + 12) else 0;
        const center = geometry.Point{
            .x = if (variable) try self.variableFword(offset + 4, base, 0) else @floatFromInt(try i16be(self.table, offset + 4)),
            .y = if (variable) try self.variableFword(offset + 6, base, 1) else @floatFromInt(try i16be(self.table, offset + 6)),
        };
        const start_value = if (variable) try self.variableF2Dot14(offset + 8, base, 2) else try f2dot14(self.table, offset + 8);
        const finish_value = if (variable) try self.variableF2Dot14(offset + 10, base, 3) else try f2dot14(self.table, offset + 10);
        const start = (start_value + 1) * std.math.pi;
        const finish = (finish_value + 1) * std.math.pi;
        var result = try self.surface();
        errdefer result.deinit(self.allocator);
        const span = finish - start;
        if (@abs(span) <= 0.000001 and line.extend != .pad) return result;
        const inverse = transform.inverse() orelse return result;
        for (result.pixels, 0..) |*pixel, index| {
            const local = inverse.transformPoint(self.canvas.point(index));
            var angle = std.math.atan2(local.y - center.y, local.x - center.x);
            if (angle < 0) angle += std.math.tau;
            pixel.* = line.sample(if (@abs(span) <= 0.000001) 0 else (angle - start) / span);
        }
        return result;
    }

    fn renderGlyph(
        self: *Graph,
        offset: usize,
        transform: geometry.Affine2D,
        stack: *[maximum_graph_depth]usize,
        depth: usize,
    ) Error!Surface {
        const child_offset = try addOffset(self.table, offset, try u24be(self.table, offset + 1));
        const glyph = try u16be(self.table, offset + 4);
        var result = try self.render(child_offset, transform, stack, depth);
        errdefer result.deinit(self.allocator);
        const mask = try self.rasterGlyphMask(glyph, transform);
        defer self.allocator.free(mask);
        for (result.pixels, mask) |*pixel, coverage| pixel.* = pixel.scaled(coverage);
        return result;
    }

    fn renderComposite(
        self: *Graph,
        offset: usize,
        transform: geometry.Affine2D,
        stack: *[maximum_graph_depth]usize,
        depth: usize,
    ) Error!Surface {
        const source_offset = try addOffset(self.table, offset, try u24be(self.table, offset + 1));
        const mode = self.table[offset + 4];
        if (mode > 27) return error.InvalidFont;
        const backdrop_offset = try addOffset(self.table, offset, try u24be(self.table, offset + 5));
        var backdrop = try self.render(backdrop_offset, transform, stack, depth);
        errdefer backdrop.deinit(self.allocator);
        var source = try self.render(source_offset, transform, stack, depth);
        defer source.deinit(self.allocator);
        for (backdrop.pixels, source.pixels) |*destination, source_pixel| destination.* = composite(source_pixel, destination.*, mode);
        return backdrop;
    }

    const TransformedNode = struct { child: usize, matrix: geometry.Affine2D };

    fn transformNode(self: *Graph, offset: usize, format: u8) Error!TransformedNode {
        const child = try addOffset(self.table, offset, try u24be(self.table, offset + 1));
        const matrix: geometry.Affine2D = switch (format) {
            12, 13 => blk: {
                const transform_offset = try addOffset(self.table, offset, try u24be(self.table, offset + 4));
                const variable = format == 13;
                const base = if (variable) try u32be(self.table, transform_offset + 24) else 0;
                break :blk .{
                    .m11 = if (variable) try self.variableFixed(transform_offset, base, 0) else try fixed(self.table, transform_offset),
                    .m12 = if (variable) try self.variableFixed(transform_offset + 4, base, 1) else try fixed(self.table, transform_offset + 4),
                    .m21 = if (variable) try self.variableFixed(transform_offset + 8, base, 2) else try fixed(self.table, transform_offset + 8),
                    .m22 = if (variable) try self.variableFixed(transform_offset + 12, base, 3) else try fixed(self.table, transform_offset + 12),
                    .tx = if (variable) try self.variableFixed(transform_offset + 16, base, 4) else try fixed(self.table, transform_offset + 16),
                    .ty = if (variable) try self.variableFixed(transform_offset + 20, base, 5) else try fixed(self.table, transform_offset + 20),
                };
            },
            14, 15 => blk: {
                const variable = format == 15;
                const base = if (variable) try u32be(self.table, offset + 8) else 0;
                break :blk geometry.Affine2D.translation(.{
                    .x = if (variable) try self.variableFword(offset + 4, base, 0) else @floatFromInt(try i16be(self.table, offset + 4)),
                    .y = if (variable) try self.variableFword(offset + 6, base, 1) else @floatFromInt(try i16be(self.table, offset + 6)),
                });
            },
            16, 17 => blk: {
                const variable = format == 17;
                const base = if (variable) try u32be(self.table, offset + 8) else 0;
                break :blk geometry.Affine2D.scale(
                    if (variable) try self.variableF2Dot14(offset + 4, base, 0) else try f2dot14(self.table, offset + 4),
                    if (variable) try self.variableF2Dot14(offset + 6, base, 1) else try f2dot14(self.table, offset + 6),
                );
            },
            18, 19 => blk: {
                const variable = format == 19;
                const base = if (variable) try u32be(self.table, offset + 12) else 0;
                break :blk around(
                    geometry.Affine2D.scale(
                        if (variable) try self.variableF2Dot14(offset + 4, base, 0) else try f2dot14(self.table, offset + 4),
                        if (variable) try self.variableF2Dot14(offset + 6, base, 1) else try f2dot14(self.table, offset + 6),
                    ),
                    .{
                        .x = if (variable) try self.variableFword(offset + 8, base, 2) else @floatFromInt(try i16be(self.table, offset + 8)),
                        .y = if (variable) try self.variableFword(offset + 10, base, 3) else @floatFromInt(try i16be(self.table, offset + 10)),
                    },
                );
            },
            20, 21 => blk: {
                const variable = format == 21;
                const base = if (variable) try u32be(self.table, offset + 6) else 0;
                const scale = if (variable) try self.variableF2Dot14(offset + 4, base, 0) else try f2dot14(self.table, offset + 4);
                break :blk geometry.Affine2D.scale(scale, scale);
            },
            22, 23 => blk: {
                const variable = format == 23;
                const base = if (variable) try u32be(self.table, offset + 10) else 0;
                const scale = if (variable) try self.variableF2Dot14(offset + 4, base, 0) else try f2dot14(self.table, offset + 4);
                break :blk around(
                    geometry.Affine2D.scale(scale, scale),
                    .{
                        .x = if (variable) try self.variableFword(offset + 6, base, 1) else @floatFromInt(try i16be(self.table, offset + 6)),
                        .y = if (variable) try self.variableFword(offset + 8, base, 2) else @floatFromInt(try i16be(self.table, offset + 8)),
                    },
                );
            },
            24, 25 => blk: {
                const variable = format == 25;
                const base = if (variable) try u32be(self.table, offset + 6) else 0;
                const angle = if (variable) try self.variableF2Dot14(offset + 4, base, 0) else try f2dot14(self.table, offset + 4);
                break :blk rotation(angle * std.math.pi);
            },
            26, 27 => blk: {
                const variable = format == 27;
                const base = if (variable) try u32be(self.table, offset + 10) else 0;
                const angle = if (variable) try self.variableF2Dot14(offset + 4, base, 0) else try f2dot14(self.table, offset + 4);
                break :blk around(
                    rotation(angle * std.math.pi),
                    .{
                        .x = if (variable) try self.variableFword(offset + 6, base, 1) else @floatFromInt(try i16be(self.table, offset + 6)),
                        .y = if (variable) try self.variableFword(offset + 8, base, 2) else @floatFromInt(try i16be(self.table, offset + 8)),
                    },
                );
            },
            28, 29 => blk: {
                const variable = format == 29;
                const base = if (variable) try u32be(self.table, offset + 8) else 0;
                const x_angle = if (variable) try self.variableF2Dot14(offset + 4, base, 0) else try f2dot14(self.table, offset + 4);
                const y_angle = if (variable) try self.variableF2Dot14(offset + 6, base, 1) else try f2dot14(self.table, offset + 6);
                break :blk skew(x_angle * std.math.pi, y_angle * std.math.pi);
            },
            30, 31 => blk: {
                const variable = format == 31;
                const base = if (variable) try u32be(self.table, offset + 12) else 0;
                const x_angle = if (variable) try self.variableF2Dot14(offset + 4, base, 0) else try f2dot14(self.table, offset + 4);
                const y_angle = if (variable) try self.variableF2Dot14(offset + 6, base, 1) else try f2dot14(self.table, offset + 6);
                break :blk around(
                    skew(x_angle * std.math.pi, y_angle * std.math.pi),
                    .{
                        .x = if (variable) try self.variableFword(offset + 8, base, 2) else @floatFromInt(try i16be(self.table, offset + 8)),
                        .y = if (variable) try self.variableFword(offset + 10, base, 3) else @floatFromInt(try i16be(self.table, offset + 10)),
                    },
                );
            },
            else => return error.InvalidFont,
        };
        if (!finiteTransform(matrix)) return error.InvalidFont;
        return .{ .child = child, .matrix = matrix };
    }

    fn rasterGlyphMask(self: *Graph, glyph: u16, transform: geometry.Affine2D) Error![]f32 {
        if (!finiteTransform(transform)) return error.InvalidFont;
        var outline = try self.font.outline(self.allocator, glyph);
        defer outline.deinit(self.allocator);
        const mask_length = std.math.mul(usize, self.canvas.width, self.canvas.height) catch return error.BudgetExceeded;
        if (mask_length > maximum_raster_pixels) return error.BudgetExceeded;
        const mask = try self.allocator.alloc(f32, mask_length);
        errdefer self.allocator.free(mask);
        @memset(mask, 0);
        if (outline.points.len == 0) return mask;
        var segments: std.ArrayList(Segment) = .empty;
        defer segments.deinit(self.allocator);
        try flattenOutline(self.allocator, outline, transform, &segments);
        const samples: usize = 4;
        for (mask, 0..) |*coverage, index| {
            const x = index % self.canvas.width;
            const y = index / self.canvas.width;
            var inside_count: usize = 0;
            for (0..samples) |sample_y| for (0..samples) |sample_x| {
                const point: geometry.Point = .{
                    .x = self.canvas.left + @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sample_x)) + 0.5) / samples,
                    .y = self.canvas.top - @as(f32, @floatFromInt(y)) - (@as(f32, @floatFromInt(sample_y)) + 0.5) / samples,
                };
                if (inside(segments.items, point)) inside_count += 1;
            };
            coverage.* = @as(f32, @floatFromInt(inside_count)) / @as(f32, @floatFromInt(samples * samples));
        }
        return mask;
    }

    fn colrGlyphRoot(self: *const Graph, glyph: u16) Error!usize {
        if (glyph >= try self.font.glyphCount()) return error.InvalidFont;
        return (try rootPaintFromList(self.table, self.base_list, glyph)) orelse return error.InvalidFont;
    }
};

const Extend = enum(u8) { pad = 0, repeat = 1, reflect = 2 };

const ColorStop = struct {
    offset: f32,
    color: Pixel,
};

const ColorLine = struct {
    extend: Extend,
    stops: []ColorStop,

    fn parse(
        allocator: std.mem.Allocator,
        graph: *const Graph,
        offset: usize,
        variable: bool,
    ) Error!ColorLine {
        const table = graph.table;
        if (!rangeFits(table.len, offset, 3)) return error.InvalidFont;
        const extend = std.enums.fromInt(Extend, table[offset]) orelse return error.InvalidFont;
        const count = try u16be(table, offset + 1);
        if (count > 4096) return error.BudgetExceeded;
        const record_size: usize = if (variable) 10 else 6;
        if (!rangeFits(table.len, offset, 3 + @as(usize, count) * record_size)) return error.InvalidFont;
        const stops = try allocator.alloc(ColorStop, count);
        errdefer allocator.free(stops);
        var previous_offset: f32 = -std.math.inf(f32);
        for (stops, 0..) |*stop, index| {
            const record = offset + 3 + index * record_size;
            const base = if (variable) try u32be(table, record + 6) else 0;
            const stop_offset = if (variable)
                try graph.variableF2Dot14(record, base, 0)
            else
                try f2dot14(table, record);
            if (!std.math.isFinite(stop_offset) or stop_offset < previous_offset) return error.InvalidFont;
            previous_offset = stop_offset;
            const alpha = std.math.clamp(if (variable)
                try graph.variableF2Dot14(record + 4, base, 1)
            else
                try f2dot14(table, record + 4), 0, 1);
            stop.* = .{
                .offset = stop_offset,
                .color = (try palettePixel(graph.font, try u16be(table, record + 2), graph.foreground)).scaled(alpha),
            };
        }
        return .{ .extend = extend, .stops = stops };
    }

    fn deinit(self: *ColorLine, allocator: std.mem.Allocator) void {
        allocator.free(self.stops);
        self.* = undefined;
    }

    fn sample(self: ColorLine, raw: f32) Pixel {
        if (self.stops.len == 0 or !std.math.isFinite(raw)) return .{};
        if (self.stops.len == 1) return self.stops[0].color;
        const minimum = self.stops[0].offset;
        const maximum = self.stops[self.stops.len - 1].offset;
        const span = maximum - minimum;
        if (!(span > 0)) return if (raw < minimum) self.stops[0].color else self.stops[self.stops.len - 1].color;
        var value = raw;
        switch (self.extend) {
            .pad => value = std.math.clamp(value, minimum, maximum),
            .repeat => value = minimum + positiveMod(value - minimum, span),
            .reflect => {
                const position = positiveMod(value - minimum, span * 2);
                value = if (position <= span) minimum + position else maximum - (position - span);
            },
        }
        if (value <= minimum) {
            if (value == minimum) {
                var index: usize = 0;
                while (index + 1 < self.stops.len and self.stops[index + 1].offset == minimum) index += 1;
                return self.stops[index].color;
            }
            return self.stops[0].color;
        }
        var index: usize = 1;
        while (index < self.stops.len) : (index += 1) {
            const next = self.stops[index];
            if (value > next.offset) continue;
            if (value == next.offset) {
                var last = index;
                while (last + 1 < self.stops.len and self.stops[last + 1].offset == next.offset) last += 1;
                return self.stops[last].color;
            }
            const previous_index = index - 1;
            const previous = self.stops[previous_index];
            const amount = (value - previous.offset) / @max(next.offset - previous.offset, 0.000001);
            return mixPixel(previous.color, next.color, amount);
        }
        return self.stops[self.stops.len - 1].color;
    }
};

fn rootPaint(table: []const u8, glyph: u16) Error!?usize {
    if (table.len < 34 or try u16be(table, 0) != 1) return null;
    const base_list = try requiredOffset(table, 14);
    return rootPaintFromList(table, base_list, glyph);
}

fn rootPaintFromList(table: []const u8, base_list: usize, glyph: u16) Error!?usize {
    const count = try u32be(table, base_list);
    if (count > 1_000_000 or !rangeFits(table.len, base_list, 4 + @as(usize, count) * 6)) return error.InvalidFont;
    var low: usize = 0;
    var high: usize = @intCast(count);
    while (low < high) {
        const middle = (low + high) / 2;
        const candidate = try u16be(table, base_list + 4 + middle * 6);
        if (candidate < glyph) low = middle + 1 else high = middle;
    }
    if (low >= @as(usize, count) or try u16be(table, base_list + 4 + low * 6) != glyph) return null;
    const relative = try u32be(table, base_list + 4 + low * 6 + 2);
    return try addOffset(table, base_list, relative);
}

fn requiredOffset(table: []const u8, field: usize) Error!usize {
    return (try optionalOffset(table, field)) orelse return error.InvalidFont;
}

fn optionalOffset(table: []const u8, field: usize) Error!?usize {
    const value = try u32be(table, field);
    if (value == 0) return null;
    if (@as(usize, value) >= table.len) return error.InvalidFont;
    return @intCast(value);
}

fn addOffset(table: []const u8, base: usize, relative: anytype) Error!usize {
    const result = std.math.add(usize, base, @as(usize, @intCast(relative))) catch return error.InvalidFont;
    if (result >= table.len) return error.InvalidFont;
    return result;
}

fn combine(a: Extent, b: Extent) Extent {
    if (std.meta.activeTag(a) == .unbounded or std.meta.activeTag(b) == .unbounded) return .unbounded;
    if (std.meta.activeTag(a) == .empty) return b;
    if (std.meta.activeTag(b) == .empty) return a;
    const first = a.finite;
    const second = b.finite;
    return .{ .finite = .{
        .minimum = .{ .x = @min(first.minimum.x, second.minimum.x), .y = @min(first.minimum.y, second.minimum.y) },
        .maximum = .{ .x = @max(first.maximum.x, second.maximum.x), .y = @max(first.maximum.y, second.maximum.y) },
    } };
}

fn intersect(a: Extent, b: Extent) Extent {
    if (std.meta.activeTag(a) == .empty or std.meta.activeTag(b) == .empty) return .empty;
    if (std.meta.activeTag(a) == .unbounded) return b;
    if (std.meta.activeTag(b) == .unbounded) return a;
    const minimum = geometry.Point{
        .x = @max(a.finite.minimum.x, b.finite.minimum.x),
        .y = @max(a.finite.minimum.y, b.finite.minimum.y),
    };
    const maximum = geometry.Point{
        .x = @min(a.finite.maximum.x, b.finite.maximum.x),
        .y = @min(a.finite.maximum.y, b.finite.maximum.y),
    };
    if (minimum.x >= maximum.x or minimum.y >= maximum.y) return .empty;
    return .{ .finite = .{ .minimum = minimum, .maximum = maximum } };
}

fn palettePixel(font: opentype.Font, index: u16, foreground: Pixel) Error!Pixel {
    if (index == 0xffff) return foreground;
    const table = font.optionalTable("CPAL".*) orelse return error.InvalidFont;
    if (table.len < 14) return error.InvalidFont;
    const entries = try u16be(table, 2);
    const palettes = try u16be(table, 4);
    const records = try u16be(table, 6);
    const records_offset = try u32be(table, 8);
    if (palettes == 0 or index >= entries) return error.InvalidFont;
    const first = try u16be(table, 12);
    const record_index = @as(usize, first) + index;
    if (record_index >= records) return error.InvalidFont;
    const offset = std.math.add(usize, @as(usize, records_offset), record_index * 4) catch return error.InvalidFont;
    if (!rangeFits(table.len, offset, 4)) return error.InvalidFont;
    return premultipliedLinear(table[offset + 2], table[offset + 1], table[offset], table[offset + 3]);
}

fn colorLineUsesForeground(table: []const u8, offset: usize, variable: bool) Error!bool {
    if (!rangeFits(table.len, offset, 3)) return error.InvalidFont;
    const count = try u16be(table, offset + 1);
    if (count > 4096) return error.BudgetExceeded;
    const record_size: usize = if (variable) 10 else 6;
    if (!rangeFits(table.len, offset, 3 + @as(usize, count) * record_size)) return error.InvalidFont;
    for (0..count) |index| if (try u16be(table, offset + 3 + index * record_size + 2) == 0xffff) return true;
    return false;
}

fn foregroundPixel(color: geometry.Color) Pixel {
    const alpha = finiteUnit(color.a);
    return .{
        .r = finiteUnit(color.r) * alpha,
        .g = finiteUnit(color.g) * alpha,
        .b = finiteUnit(color.b) * alpha,
        .a = alpha,
    };
}

fn finiteUnit(value: f32) f32 {
    return if (std.math.isFinite(value)) std.math.clamp(value, 0, 1) else 0;
}

fn premultipliedLinear(r: u8, g: u8, b: u8, a: u8) Pixel {
    const alpha = @as(f32, @floatFromInt(a)) / 255;
    return .{
        .r = srgbToLinear(@as(f32, @floatFromInt(r)) / 255) * alpha,
        .g = srgbToLinear(@as(f32, @floatFromInt(g)) / 255) * alpha,
        .b = srgbToLinear(@as(f32, @floatFromInt(b)) / 255) * alpha,
        .a = alpha,
    };
}

fn sourceOver(source: Pixel, backdrop: Pixel) Pixel {
    const inverse = 1 - source.a;
    return .{
        .r = source.r + backdrop.r * inverse,
        .g = source.g + backdrop.g * inverse,
        .b = source.b + backdrop.b * inverse,
        .a = source.a + backdrop.a * inverse,
    };
}

fn composite(source: Pixel, backdrop: Pixel, mode: u8) Pixel {
    return switch (mode) {
        0 => .{},
        1 => source,
        2 => backdrop,
        3 => sourceOver(source, backdrop),
        4 => sourceOver(backdrop, source),
        5 => porterDuff(source, backdrop, backdrop.a, 0),
        6 => porterDuff(source, backdrop, 0, source.a),
        7 => porterDuff(source, backdrop, 1 - backdrop.a, 0),
        8 => porterDuff(source, backdrop, 0, 1 - source.a),
        9 => porterDuff(source, backdrop, backdrop.a, 1 - source.a),
        10 => porterDuff(source, backdrop, 1 - backdrop.a, source.a),
        11 => porterDuff(source, backdrop, 1 - backdrop.a, 1 - source.a),
        12 => .{
            .r = @min(1, source.r + backdrop.r),
            .g = @min(1, source.g + backdrop.g),
            .b = @min(1, source.b + backdrop.b),
            .a = @min(1, source.a + backdrop.a),
        },
        13...27 => blendComposite(source, backdrop, mode),
        else => .{},
    };
}

fn porterDuff(source: Pixel, backdrop: Pixel, source_factor: f32, backdrop_factor: f32) Pixel {
    return .{
        .r = source.r * source_factor + backdrop.r * backdrop_factor,
        .g = source.g * source_factor + backdrop.g * backdrop_factor,
        .b = source.b * source_factor + backdrop.b * backdrop_factor,
        .a = source.a * source_factor + backdrop.a * backdrop_factor,
    };
}

const Rgb = struct { r: f32, g: f32, b: f32 };

fn blendComposite(source: Pixel, backdrop: Pixel, mode: u8) Pixel {
    const source_color = unpremultiplied(source);
    const backdrop_color = unpremultiplied(backdrop);
    const blended = if (mode <= 23)
        Rgb{
            .r = blendChannel(source_color.r, backdrop_color.r, mode),
            .g = blendChannel(source_color.g, backdrop_color.g, mode),
            .b = blendChannel(source_color.b, backdrop_color.b, mode),
        }
    else
        blendNonSeparable(source_color, backdrop_color, mode);
    const product = source.a * backdrop.a;
    return .{
        .r = source.r * (1 - backdrop.a) + backdrop.r * (1 - source.a) + blended.r * product,
        .g = source.g * (1 - backdrop.a) + backdrop.g * (1 - source.a) + blended.g * product,
        .b = source.b * (1 - backdrop.a) + backdrop.b * (1 - source.a) + blended.b * product,
        .a = source.a + backdrop.a - product,
    };
}

fn blendChannel(source: f32, backdrop: f32, mode: u8) f32 {
    return std.math.clamp(switch (mode) {
        13 => source + backdrop - source * backdrop,
        14 => if (backdrop <= 0.5) 2 * source * backdrop else 1 - 2 * (1 - source) * (1 - backdrop),
        15 => @min(source, backdrop),
        16 => @max(source, backdrop),
        17 => if (source >= 1) 1 else @min(1, backdrop / @max(1 - source, 0.000001)),
        18 => if (source <= 0) 0 else 1 - @min(1, (1 - backdrop) / @max(source, 0.000001)),
        19 => if (source <= 0.5) 2 * source * backdrop else 1 - 2 * (1 - source) * (1 - backdrop),
        20 => softLight(source, backdrop),
        21 => @abs(backdrop - source),
        22 => backdrop + source - 2 * backdrop * source,
        23 => backdrop * source,
        else => source,
    }, 0, 1);
}

fn softLight(source: f32, backdrop: f32) f32 {
    if (source <= 0.5) return backdrop - (1 - 2 * source) * backdrop * (1 - backdrop);
    const d = if (backdrop <= 0.25)
        ((16 * backdrop - 12) * backdrop + 4) * backdrop
    else
        @sqrt(backdrop);
    return backdrop + (2 * source - 1) * (d - backdrop);
}

fn blendNonSeparable(source: Rgb, backdrop: Rgb, mode: u8) Rgb {
    return switch (mode) {
        24 => setLum(setSat(source, saturation(backdrop)), luminance(backdrop)),
        25 => setLum(setSat(backdrop, saturation(source)), luminance(backdrop)),
        26 => setLum(source, luminance(backdrop)),
        27 => setLum(backdrop, luminance(source)),
        else => source,
    };
}

fn luminance(color: Rgb) f32 {
    return 0.3 * color.r + 0.59 * color.g + 0.11 * color.b;
}

fn saturation(color: Rgb) f32 {
    return @max(color.r, @max(color.g, color.b)) - @min(color.r, @min(color.g, color.b));
}

fn setLum(color: Rgb, target: f32) Rgb {
    const delta = target - luminance(color);
    return clipColor(.{ .r = color.r + delta, .g = color.g + delta, .b = color.b + delta });
}

fn clipColor(input: Rgb) Rgb {
    var color = input;
    const lum = luminance(color);
    const minimum = @min(color.r, @min(color.g, color.b));
    const maximum = @max(color.r, @max(color.g, color.b));
    if (minimum < 0) {
        const denominator = lum - minimum;
        if (@abs(denominator) > 0.000001) {
            color.r = lum + (color.r - lum) * lum / denominator;
            color.g = lum + (color.g - lum) * lum / denominator;
            color.b = lum + (color.b - lum) * lum / denominator;
        }
    }
    if (maximum > 1) {
        const denominator = maximum - lum;
        if (@abs(denominator) > 0.000001) {
            color.r = lum + (color.r - lum) * (1 - lum) / denominator;
            color.g = lum + (color.g - lum) * (1 - lum) / denominator;
            color.b = lum + (color.b - lum) * (1 - lum) / denominator;
        }
    }
    return .{
        .r = std.math.clamp(color.r, 0, 1),
        .g = std.math.clamp(color.g, 0, 1),
        .b = std.math.clamp(color.b, 0, 1),
    };
}

const SaturationChannel = struct { value: f32, channel: u2 };

fn setSat(input: Rgb, target: f32) Rgb {
    var values = [_]SaturationChannel{
        .{ .value = input.r, .channel = 0 },
        .{ .value = input.g, .channel = 1 },
        .{ .value = input.b, .channel = 2 },
    };
    std.mem.sort(SaturationChannel, &values, {}, struct {
        fn less(_: void, a: SaturationChannel, b: SaturationChannel) bool {
            return a.value < b.value;
        }
    }.less);
    var output = [_]f32{ 0, 0, 0 };
    const span = values[2].value - values[0].value;
    if (span > 0.000001) {
        output[values[1].channel] = (values[1].value - values[0].value) * target / span;
        output[values[2].channel] = target;
    }
    return .{ .r = output[0], .g = output[1], .b = output[2] };
}

fn unpremultiplied(pixel: Pixel) Rgb {
    if (pixel.a <= 0.000001) return .{ .r = 0, .g = 0, .b = 0 };
    return .{ .r = pixel.r / pixel.a, .g = pixel.g / pixel.a, .b = pixel.b / pixel.a };
}

fn mixPixel(a: Pixel, b: Pixel, amount_raw: f32) Pixel {
    const amount = std.math.clamp(amount_raw, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * amount,
        .g = a.g + (b.g - a.g) * amount,
        .b = a.b + (b.b - a.b) * amount,
        .a = a.a + (b.a - a.a) * amount,
    };
}

fn radialParameter(point: geometry.Point, c0: geometry.Point, r0: f32, c1: geometry.Point, r1: f32) ?f32 {
    const centers = c1.sub(c0);
    const relative = point.sub(c0);
    const radius_delta = r1 - r0;
    const a = dot(centers, centers) - radius_delta * radius_delta;
    const b = -2 * (dot(relative, centers) + r0 * radius_delta);
    const c = dot(relative, relative) - r0 * r0;
    if (@abs(a) <= 0.000001) {
        if (@abs(b) <= 0.000001) return null;
        const value = -c / b;
        return if (r0 + radius_delta * value > 0) value else null;
    }
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return null;
    const root = @sqrt(@max(0, discriminant));
    const first = (-b - root) / (2 * a);
    const second = (-b + root) / (2 * a);
    var result: ?f32 = null;
    if (r0 + radius_delta * first > 0) result = first;
    if (r0 + radius_delta * second > 0 and (result == null or second > result.?)) result = second;
    return result;
}

fn around(matrix: geometry.Affine2D, center: geometry.Point) geometry.Affine2D {
    return geometry.Affine2D.mul(
        geometry.Affine2D.translation(center),
        geometry.Affine2D.mul(matrix, geometry.Affine2D.translation(.{ .x = -center.x, .y = -center.y })),
    );
}

fn rotation(angle: f32) geometry.Affine2D {
    return .{ .m11 = @cos(angle), .m12 = @sin(angle), .m21 = -@sin(angle), .m22 = @cos(angle) };
}

fn skew(x_angle: f32, y_angle: f32) geometry.Affine2D {
    return .{ .m11 = 1, .m12 = @tan(y_angle), .m21 = -@tan(x_angle), .m22 = 1 };
}

fn positiveMod(value: f32, modulus: f32) f32 {
    const result = value - @floor(value / modulus) * modulus;
    return if (result < 0) result + modulus else result;
}

fn dot(a: geometry.Point, b: geometry.Point) f32 {
    return a.x * b.x + a.y * b.y;
}

fn samePoint(a: geometry.Point, b: geometry.Point) bool {
    return @abs(a.x - b.x) <= 0.00001 and @abs(a.y - b.y) <= 0.00001;
}

fn finiteBounds(value: Bounds) bool {
    return finitePoint(value.minimum) and finitePoint(value.maximum) and
        value.minimum.x <= value.maximum.x and value.minimum.y <= value.maximum.y;
}

fn finitePoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}

fn finiteTransform(value: geometry.Affine2D) bool {
    return std.math.isFinite(value.m11) and std.math.isFinite(value.m12) and
        std.math.isFinite(value.m21) and std.math.isFinite(value.m22) and
        std.math.isFinite(value.tx) and std.math.isFinite(value.ty);
}

fn finitePixel(value: Pixel) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and
        std.math.isFinite(value.b) and std.math.isFinite(value.a);
}

const Segment = struct { a: geometry.Point, b: geometry.Point };

fn flattenOutline(
    allocator: std.mem.Allocator,
    outline: opentype.Outline,
    transform: geometry.Affine2D,
    segments: *std.ArrayList(Segment),
) Error!void {
    var contour_start: usize = 0;
    for (outline.contour_ends) |end_value| {
        const contour_end: usize = end_value;
        if (contour_end < contour_start or contour_end >= outline.points.len) return error.InvalidFont;
        const points = outline.points[contour_start .. contour_end + 1];
        switch (outline.curve_kind) {
            .quadratic => try flattenQuadraticContour(allocator, points, transform, segments),
            .cubic => try flattenCubicContour(allocator, points, transform, segments),
        }
        contour_start = contour_end + 1;
    }
    if (contour_start != outline.points.len) return error.InvalidFont;
}

fn flattenQuadraticContour(
    allocator: std.mem.Allocator,
    points: []const opentype.OutlinePoint,
    transform: geometry.Affine2D,
    segments: *std.ArrayList(Segment),
) Error!void {
    if (points.len == 0) return;
    const first = transformedPoint(points[0], transform);
    const last = transformedPoint(points[points.len - 1], transform);
    var start = if (points[0].on_curve) first else if (points[points.len - 1].on_curve) last else midpoint(first, last);
    const first_point = start;
    var index: usize = 0;
    while (index < points.len) {
        const raw = points[index];
        const point = transformedPoint(raw, transform);
        if (raw.on_curve) {
            if (!samePoint(start, point)) try appendSegment(allocator, segments, start, point);
            start = point;
            index += 1;
            continue;
        }
        const next_index = (index + 1) % points.len;
        const next_raw = points[next_index];
        const next = transformedPoint(next_raw, transform);
        const end = if (next_raw.on_curve) next else midpoint(point, next);
        try flattenQuadratic(allocator, segments, start, point, end, 0);
        start = end;
        index += if (next_raw.on_curve) 2 else 1;
    }
    if (!samePoint(start, first_point)) try appendSegment(allocator, segments, start, first_point);
}

fn flattenCubicContour(
    allocator: std.mem.Allocator,
    points: []const opentype.OutlinePoint,
    transform: geometry.Affine2D,
    segments: *std.ArrayList(Segment),
) Error!void {
    if (points.len == 0 or !points[0].on_curve) return error.InvalidFont;
    const contour_start = transformedPoint(points[0], transform);
    var start = contour_start;
    var index: usize = 1;
    while (index < points.len) {
        const point = transformedPoint(points[index], transform);
        if (points[index].on_curve) {
            if (!samePoint(start, point)) try appendSegment(allocator, segments, start, point);
            start = point;
            index += 1;
            continue;
        }
        if (index + 2 >= points.len or points[index + 1].on_curve or !points[index + 2].on_curve) return error.InvalidFont;
        const second = transformedPoint(points[index + 1], transform);
        const end = transformedPoint(points[index + 2], transform);
        try flattenCubic(allocator, segments, start, point, second, end, 0);
        start = end;
        index += 3;
    }
    if (!samePoint(start, contour_start)) try appendSegment(allocator, segments, start, contour_start);
}

fn flattenQuadratic(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(Segment),
    start: geometry.Point,
    control: geometry.Point,
    end: geometry.Point,
    depth: u8,
) Error!void {
    const distance = pointLineDistance(control, start, end);
    if (!std.math.isFinite(distance)) return error.InvalidFont;
    if (depth >= 12 or distance <= 0.2) {
        try appendSegment(allocator, segments, start, end);
        return;
    }
    const left = midpoint(start, control);
    const right = midpoint(control, end);
    const center = midpoint(left, right);
    try flattenQuadratic(allocator, segments, start, left, center, depth + 1);
    try flattenQuadratic(allocator, segments, center, right, end, depth + 1);
}

fn flattenCubic(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(Segment),
    start: geometry.Point,
    control1: geometry.Point,
    control2: geometry.Point,
    end: geometry.Point,
    depth: u8,
) Error!void {
    const flatness = @max(pointLineDistance(control1, start, end), pointLineDistance(control2, start, end));
    if (!std.math.isFinite(flatness)) return error.InvalidFont;
    if (depth >= 14 or flatness <= 0.2) {
        try appendSegment(allocator, segments, start, end);
        return;
    }
    const p01 = midpoint(start, control1);
    const p12 = midpoint(control1, control2);
    const p23 = midpoint(control2, end);
    const p012 = midpoint(p01, p12);
    const p123 = midpoint(p12, p23);
    const center = midpoint(p012, p123);
    try flattenCubic(allocator, segments, start, p01, p012, center, depth + 1);
    try flattenCubic(allocator, segments, center, p123, p23, end, depth + 1);
}

fn appendSegment(
    allocator: std.mem.Allocator,
    segments: *std.ArrayList(Segment),
    start: geometry.Point,
    end: geometry.Point,
) Error!void {
    if (!finitePoint(start) or !finitePoint(end)) return error.InvalidFont;
    if (segments.items.len >= maximum_raster_segments) return error.BudgetExceeded;
    try segments.append(allocator, .{ .a = start, .b = end });
}

fn transformedPoint(point: opentype.OutlinePoint, transform: geometry.Affine2D) geometry.Point {
    return transform.transformPoint(.{ .x = point.x, .y = point.y });
}

fn midpoint(a: geometry.Point, b: geometry.Point) geometry.Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

fn pointLineDistance(point: geometry.Point, start: geometry.Point, end: geometry.Point) f32 {
    const delta = end.sub(start);
    const denominator = @sqrt(delta.x * delta.x + delta.y * delta.y);
    if (denominator <= 0.00001) return @sqrt(dot(point.sub(start), point.sub(start)));
    return @abs(delta.y * point.x - delta.x * point.y + end.x * start.y - end.y * start.x) / denominator;
}

fn inside(segments: []const Segment, point: geometry.Point) bool {
    var winding: i32 = 0;
    for (segments) |segment| {
        if (segment.a.y <= point.y) {
            if (segment.b.y > point.y and cross(segment.b.sub(segment.a), point.sub(segment.a)) > 0) winding += 1;
        } else if (segment.b.y <= point.y and cross(segment.b.sub(segment.a), point.sub(segment.a)) < 0) {
            winding -= 1;
        }
    }
    return winding != 0;
}

fn cross(a: geometry.Point, b: geometry.Point) f32 {
    return a.x * b.y - a.y * b.x;
}

fn srgbToLinear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(value: f32) f32 {
    return if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
}

fn toByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

fn empty(allocator: std.mem.Allocator) Error!api.RasterizedGlyph {
    return .{ .size = .zero, .origin = .{}, .stride = 0, .pixels = try allocator.alloc(u8, 0), .mode = .color };
}

fn rangeFits(total: usize, offset: anytype, length: anytype) bool {
    const start: usize = @intCast(offset);
    const count: usize = @intCast(length);
    return start <= total and count <= total - start;
}

fn u16be(bytes: []const u8, offset: usize) Error!u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return error.InvalidFont;
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn i16be(bytes: []const u8, offset: usize) Error!i16 {
    return @bitCast(try u16be(bytes, offset));
}

fn u24be(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or bytes.len - offset < 3) return error.InvalidFont;
    return (@as(u32, bytes[offset]) << 16) | (@as(u32, bytes[offset + 1]) << 8) | bytes[offset + 2];
}

fn u32be(bytes: []const u8, offset: usize) Error!u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.InvalidFont;
    return (@as(u32, bytes[offset]) << 24) | (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) | bytes[offset + 3];
}

fn i32be(bytes: []const u8, offset: usize) Error!i32 {
    return @bitCast(try u32be(bytes, offset));
}

fn f2dot14(bytes: []const u8, offset: usize) Error!f32 {
    return @as(f32, @floatFromInt(try i16be(bytes, offset))) / 16384;
}

fn fixed(bytes: []const u8, offset: usize) Error!f32 {
    return @as(f32, @floatFromInt(try i32be(bytes, offset))) / 65536;
}
