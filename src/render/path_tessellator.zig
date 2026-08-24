const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const abi = @import("../scene/abi.zig");

pub const Vertex = extern struct {
    position: geometry.Point,
    color: geometry.Color,
};

const Edge = struct {
    a: geometry.Point,
    b: geometry.Point,
    winding: i8,
};

const Crossing = struct {
    edge: usize,
    middle_x: f32,
    lower_x: f32,
    upper_x: f32,
    winding: i8,
};

const CacheKey = extern struct {
    fill_rule: u32,
    tolerance_bits: u32,
    color: geometry.Color,
};

const CacheEntry = struct {
    hash: u64,
    key: CacheKey,
    commands: []abi.PathVertex,
    vertices: []Vertex,
    bytes: usize,
    last_used: u64,
};

pub const Limits = struct {
    maximum_edges: usize,
    maximum_work_units: usize,
    maximum_output_vertices: usize,
    maximum_cache_bytes: usize,
};

/// Deterministic in-tree scan-conversion tessellator. It handles concave
/// contours, holes, both fill rules, quadratic curves, and self-intersections
/// without importing a geometry package. Storage is retained across frames.
pub const Tessellator = struct {
    allocator: std.mem.Allocator,
    edges: std.ArrayList(Edge) = .empty,
    bands: std.ArrayList(f32) = .empty,
    crossings: std.ArrayList(Crossing) = .empty,
    intersection_order: std.ArrayList(usize) = .empty,
    maximum_edges: usize,
    maximum_work_units: usize,
    maximum_output_vertices: usize,
    remaining_edges: usize,
    remaining_work_units: usize,
    remaining_output_vertices: usize,
    cache: std.ArrayList(CacheEntry) = .empty,
    cache_index: std.AutoHashMap(u64, usize),
    maximum_cache_bytes: usize,
    cached_bytes: usize = 0,
    cache_clock: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Tessellator {
        return .{
            .allocator = allocator,
            .maximum_edges = limits.maximum_edges,
            .maximum_work_units = limits.maximum_work_units,
            .maximum_output_vertices = limits.maximum_output_vertices,
            .remaining_edges = limits.maximum_edges,
            .remaining_work_units = limits.maximum_work_units,
            .remaining_output_vertices = limits.maximum_output_vertices,
            .cache_index = std.AutoHashMap(u64, usize).init(allocator),
            .maximum_cache_bytes = limits.maximum_cache_bytes,
        };
    }

    /// Starts one bounded scene/offscreen render batch. Cached geometry still
    /// consumes output capacity, but does not consume flattening work.
    pub fn beginBatch(self: *Tessellator) void {
        self.remaining_edges = self.maximum_edges;
        self.remaining_work_units = self.maximum_work_units;
        self.remaining_output_vertices = self.maximum_output_vertices;
    }

    pub fn deinit(self: *Tessellator) void {
        self.edges.deinit(self.allocator);
        self.bands.deinit(self.allocator);
        self.crossings.deinit(self.allocator);
        self.intersection_order.deinit(self.allocator);
        for (self.cache.items) |entry| {
            self.allocator.free(entry.commands);
            self.allocator.free(entry.vertices);
        }
        self.cache.deinit(self.allocator);
        self.cache_index.deinit();
        self.* = undefined;
    }

    pub fn tessellate(
        self: *Tessellator,
        path: abi.Path,
        commands: []const abi.PathVertex,
        tolerance: f32,
        output: *std.ArrayList(Vertex),
    ) Error!void {
        const key: CacheKey = .{
            .fill_rule = path.fill_rule,
            .tolerance_bits = @bitCast(tolerance),
            .color = path.color,
        };
        const hash = cacheHash(key, commands);
        if (self.cached(hash, key, commands)) |vertices| {
            try self.consumeOutput(vertices.len);
            try output.appendSlice(self.allocator, vertices);
            return;
        }
        const output_start = output.items.len;
        self.edges.clearRetainingCapacity();
        self.bands.clearRetainingCapacity();
        self.crossings.clearRetainingCapacity();
        if (commands.len == 0) return;
        try self.flatten(commands, @max(tolerance, 0.01));
        if (self.edges.items.len == 0) return;
        try self.addIntersectionBands();
        std.mem.sort(f32, self.bands.items, {}, lessFloat);
        deduplicateSorted(&self.bands);
        const rule = std.enums.fromInt(abi.FillRule, path.fill_rule) orelse return error.InvalidScene;
        var band_index: usize = 1;
        while (band_index < self.bands.items.len) : (band_index += 1) {
            const y0 = self.bands.items[band_index - 1];
            const y1 = self.bands.items[band_index];
            if (!(y1 > y0 + 0.00001)) continue;
            const middle = (y0 + y1) * 0.5;
            self.crossings.clearRetainingCapacity();
            for (self.edges.items, 0..) |edge, edge_index| {
                try self.consumeWork(1);
                const minimum = @min(edge.a.y, edge.b.y);
                const maximum = @max(edge.a.y, edge.b.y);
                if (middle < minimum or middle >= maximum) continue;
                try self.crossings.append(self.allocator, .{
                    .edge = edge_index,
                    .middle_x = xAt(edge, middle),
                    .lower_x = xAt(edge, y0),
                    .upper_x = xAt(edge, y1),
                    .winding = edge.winding,
                });
            }
            std.mem.sort(Crossing, self.crossings.items, {}, lessCrossing);
            switch (rule) {
                .even_odd => {
                    var index: usize = 0;
                    while (index + 1 < self.crossings.items.len) : (index += 2) {
                        try self.appendTrapezoid(output, self.crossings.items[index], self.crossings.items[index + 1], y0, y1, path.color);
                    }
                },
                .non_zero => {
                    var winding: i32 = 0;
                    var start: ?Crossing = null;
                    for (self.crossings.items) |crossing| {
                        const before = winding;
                        winding += crossing.winding;
                        if (before == 0 and winding != 0) start = crossing;
                        if (before != 0 and winding == 0) {
                            if (start) |left| try self.appendTrapezoid(output, left, crossing, y0, y1, path.color);
                            start = null;
                        }
                    }
                },
            }
        }
        self.cacheResult(hash, key, commands, output.items[output_start..]);
    }

    fn cached(
        self: *Tessellator,
        hash: u64,
        key: CacheKey,
        commands: []const abi.PathVertex,
    ) ?[]const Vertex {
        const index = self.cache_index.get(hash) orelse return null;
        const entry = &self.cache.items[index];
        if (!std.meta.eql(entry.key, key) or
            !std.mem.eql(u8, std.mem.sliceAsBytes(entry.commands), std.mem.sliceAsBytes(commands))) return null;
        entry.last_used = self.nextCacheClock();
        return entry.vertices;
    }

    fn cacheResult(
        self: *Tessellator,
        hash: u64,
        key: CacheKey,
        commands: []const abi.PathVertex,
        vertices: []const Vertex,
    ) void {
        if (self.maximum_cache_bytes == 0 or self.cache_index.contains(hash)) return;
        const command_bytes = std.math.mul(usize, commands.len, @sizeOf(abi.PathVertex)) catch return;
        const vertex_bytes = std.math.mul(usize, vertices.len, @sizeOf(Vertex)) catch return;
        const bytes = std.math.add(usize, command_bytes, vertex_bytes) catch return;
        if (bytes == 0 or bytes > self.maximum_cache_bytes) return;
        while (bytes > self.maximum_cache_bytes -| self.cached_bytes) self.evictOldest();
        self.cache.ensureUnusedCapacity(self.allocator, 1) catch return;
        self.cache_index.ensureUnusedCapacity(1) catch return;
        const command_copy = self.allocator.dupe(abi.PathVertex, commands) catch return;
        const vertex_copy = self.allocator.dupe(Vertex, vertices) catch {
            self.allocator.free(command_copy);
            return;
        };
        const index = self.cache.items.len;
        self.cache.appendAssumeCapacity(.{
            .hash = hash,
            .key = key,
            .commands = command_copy,
            .vertices = vertex_copy,
            .bytes = bytes,
            .last_used = self.nextCacheClock(),
        });
        self.cache_index.putAssumeCapacity(hash, index);
        self.cached_bytes += bytes;
    }

    fn evictOldest(self: *Tessellator) void {
        if (self.cache.items.len == 0) return;
        var oldest: usize = 0;
        for (self.cache.items[1..], 1..) |entry, index| {
            if (entry.last_used < self.cache.items[oldest].last_used) oldest = index;
        }
        const removed = self.cache.swapRemove(oldest);
        _ = self.cache_index.remove(removed.hash);
        self.cached_bytes -= removed.bytes;
        self.allocator.free(removed.commands);
        self.allocator.free(removed.vertices);
        if (oldest < self.cache.items.len) {
            const moved = self.cache.items[oldest];
            self.cache_index.getPtr(moved.hash).?.* = oldest;
        }
    }

    fn nextCacheClock(self: *Tessellator) u64 {
        const result = self.cache_clock;
        self.cache_clock +%= 1;
        if (self.cache_clock == 0) {
            self.cache_clock = 1;
            for (self.cache.items) |*entry| entry.last_used = 0;
        }
        return result;
    }

    fn flatten(self: *Tessellator, commands: []const abi.PathVertex, tolerance: f32) Error!void {
        var current: ?geometry.Point = null;
        var contour_start: geometry.Point = .{};
        for (commands) |command| {
            const kind = std.enums.fromInt(abi.PathCommand, command.kind) orelse return error.InvalidScene;
            switch (kind) {
                .move_to => {
                    if (current) |end| if (!pointsEqual(end, contour_start)) try self.addEdge(end, contour_start);
                    current = command.position;
                    contour_start = command.position;
                    try self.bands.append(self.allocator, command.position.y);
                },
                .line_to => {
                    const start = current orelse command.position;
                    try self.addEdge(start, command.position);
                    current = command.position;
                },
                .quadratic_to => {
                    const start = current orelse command.position;
                    try self.flattenQuadratic(start, command.control, command.position, tolerance, 0);
                    current = command.position;
                },
                .close => if (current) |start| {
                    try self.addEdge(start, contour_start);
                    current = contour_start;
                },
            }
        }
        if (current) |end| if (!pointsEqual(end, contour_start)) try self.addEdge(end, contour_start);
    }

    fn flattenQuadratic(
        self: *Tessellator,
        start: geometry.Point,
        control: geometry.Point,
        end: geometry.Point,
        tolerance: f32,
        depth: u8,
    ) Error!void {
        const chord = end.sub(start);
        const length = @max(@sqrt(chord.x * chord.x + chord.y * chord.y), 0.00001);
        const distance = @abs(chord.y * control.x - chord.x * control.y + end.x * start.y - end.y * start.x) / length;
        if (distance <= tolerance or depth >= 16) return self.addEdge(start, end);
        const a = midpoint(start, control);
        const b = midpoint(control, end);
        const center = midpoint(a, b);
        try self.flattenQuadratic(start, a, center, tolerance, depth + 1);
        try self.flattenQuadratic(center, b, end, tolerance, depth + 1);
    }

    fn addEdge(self: *Tessellator, a: geometry.Point, b: geometry.Point) Error!void {
        if (pointsEqual(a, b)) return;
        try self.bands.append(self.allocator, a.y);
        try self.bands.append(self.allocator, b.y);
        if (@abs(a.y - b.y) <= 0.000001) return;
        if (self.edges.items.len >= self.maximum_edges or self.remaining_edges == 0) return error.BudgetExceeded;
        self.remaining_edges -= 1;
        try self.edges.append(self.allocator, .{ .a = a, .b = b, .winding = if (b.y > a.y) 1 else -1 });
    }

    fn addIntersectionBands(self: *Tessellator) Error!void {
        self.intersection_order.clearRetainingCapacity();
        try self.intersection_order.ensureTotalCapacity(self.allocator, self.edges.items.len);
        for (0..self.edges.items.len) |index| self.intersection_order.appendAssumeCapacity(index);
        std.mem.sort(usize, self.intersection_order.items, self.edges.items, lessEdgeByMinimumY);
        for (self.intersection_order.items, 0..) |left_index, order_index| {
            const left = self.edges.items[left_index];
            const left_max_y = @max(left.a.y, left.b.y);
            const left_min_x = @min(left.a.x, left.b.x);
            const left_max_x = @max(left.a.x, left.b.x);
            for (self.intersection_order.items[order_index + 1 ..]) |right_index| {
                const right = self.edges.items[right_index];
                if (@min(right.a.y, right.b.y) >= left_max_y) break;
                try self.consumeWork(1);
                const right_min_x = @min(right.a.x, right.b.x);
                const right_max_x = @max(right.a.x, right.b.x);
                if (right_min_x >= left_max_x or right_max_x <= left_min_x) continue;
                const denominator = cross(left.b.sub(left.a), right.b.sub(right.a));
                if (@abs(denominator) <= 0.000001) continue;
                const delta = right.a.sub(left.a);
                const t = cross(delta, right.b.sub(right.a)) / denominator;
                const u = cross(delta, left.b.sub(left.a)) / denominator;
                if (t <= 0.000001 or t >= 0.999999 or u <= 0.000001 or u >= 0.999999) continue;
                try self.bands.append(self.allocator, left.a.y + (left.b.y - left.a.y) * t);
            }
        }
    }

    fn consumeWork(self: *Tessellator, count: usize) Error!void {
        if (count > self.remaining_work_units) return error.BudgetExceeded;
        self.remaining_work_units -= count;
    }

    fn consumeOutput(self: *Tessellator, count: usize) Error!void {
        if (count > self.remaining_output_vertices) return error.BudgetExceeded;
        self.remaining_output_vertices -= count;
    }

    fn appendTrapezoid(
        self: *Tessellator,
        output: *std.ArrayList(Vertex),
        left: Crossing,
        right: Crossing,
        y0: f32,
        y1: f32,
        color: geometry.Color,
    ) Error!void {
        if (right.middle_x <= left.middle_x + 0.000001) return;
        try self.consumeOutput(6);
        const a: Vertex = .{ .position = .{ .x = left.lower_x, .y = y0 }, .color = color };
        const b: Vertex = .{ .position = .{ .x = right.lower_x, .y = y0 }, .color = color };
        const c: Vertex = .{ .position = .{ .x = right.upper_x, .y = y1 }, .color = color };
        const d: Vertex = .{ .position = .{ .x = left.upper_x, .y = y1 }, .color = color };
        try output.appendSlice(self.allocator, &.{ a, b, c, a, c, d });
    }
};

fn cacheHash(key: CacheKey, commands: []const abi.PathVertex) u64 {
    var hash = std.hash.Wyhash.init(0x5a49_4755_4950_4154);
    hash.update(std.mem.asBytes(&key));
    hash.update(std.mem.sliceAsBytes(commands));
    return hash.final();
}

fn xAt(edge: Edge, y: f32) f32 {
    const amount = (y - edge.a.y) / (edge.b.y - edge.a.y);
    return edge.a.x + (edge.b.x - edge.a.x) * amount;
}

fn midpoint(a: geometry.Point, b: geometry.Point) geometry.Point {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

fn cross(a: geometry.Point, b: geometry.Point) f32 {
    return a.x * b.y - a.y * b.x;
}
fn pointsEqual(a: geometry.Point, b: geometry.Point) bool {
    return @abs(a.x - b.x) <= 0.000001 and @abs(a.y - b.y) <= 0.000001;
}
fn lessFloat(_: void, a: f32, b: f32) bool {
    return a < b;
}
fn lessCrossing(_: void, a: Crossing, b: Crossing) bool {
    if (a.middle_x != b.middle_x) return a.middle_x < b.middle_x;
    return a.winding < b.winding;
}

fn lessEdgeByMinimumY(edges: []const Edge, left: usize, right: usize) bool {
    const left_y = @min(edges[left].a.y, edges[left].b.y);
    const right_y = @min(edges[right].a.y, edges[right].b.y);
    if (left_y != right_y) return left_y < right_y;
    return left < right;
}

fn deduplicateSorted(values: *std.ArrayList(f32)) void {
    if (values.items.len < 2) return;
    var write: usize = 1;
    for (values.items[1..]) |value| {
        if (@abs(value - values.items[write - 1]) <= 0.000001) continue;
        values.items[write] = value;
        write += 1;
    }
    values.items.len = write;
}
