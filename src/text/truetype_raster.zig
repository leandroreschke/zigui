const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const api = @import("api.zig");
const opentype = @import("opentype.zig");

const Segment = struct {
    a: geometry.Point,
    b: geometry.Point,
};

const maximum_raster_dimension = 8192;
const maximum_raster_pixels = 4 * 1024 * 1024;
const maximum_raster_segments = 1_048_576;
const maximum_raster_work_units = 128 * 1024 * 1024;
const maximum_text_size: f32 = 1_000_000;
const maximum_scale_factor: f32 = 64;

pub fn rasterize(
    allocator: std.mem.Allocator,
    font: opentype.Font,
    glyph_id: u16,
    size: f32,
    scale_factor: f32,
) Error!api.RasterizedGlyph {
    if (!(size > 0) or size > maximum_text_size or !(scale_factor > 0) or scale_factor > maximum_scale_factor or
        !std.math.isFinite(size) or !std.math.isFinite(scale_factor)) return error.InvalidConfiguration;
    var outline = try font.outline(allocator, glyph_id);
    defer outline.deinit(allocator);
    if (outline.points.len == 0) return .{
        .size = .zero,
        .origin = .{},
        .stride = 0,
        .pixels = try allocator.alloc(u8, 0),
        .mode = .grayscale,
    };

    const units = try font.unitsPerEm();
    if (units == 0) return error.InvalidFont;
    const scale = size * scale_factor / @as(f32, @floatFromInt(units));
    if (!std.math.isFinite(scale)) return error.InvalidConfiguration;
    for (outline.points) |point| {
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y) or
            !std.math.isFinite(point.x * scale) or !std.math.isFinite(point.y * scale)) return error.InvalidFont;
    }
    var segments: std.ArrayList(Segment) = .empty;
    defer segments.deinit(allocator);
    try flattenOutline(allocator, outline, scale, &segments);

    var minimum_x = std.math.inf(f32);
    var minimum_y = std.math.inf(f32);
    var maximum_x = -std.math.inf(f32);
    var maximum_y = -std.math.inf(f32);
    for (outline.points) |point| {
        minimum_x = @min(minimum_x, point.x * scale);
        minimum_y = @min(minimum_y, point.y * scale);
        maximum_x = @max(maximum_x, point.x * scale);
        maximum_y = @max(maximum_y, point.y * scale);
    }
    const left = @floor(minimum_x) - 1;
    const right = @ceil(maximum_x) + 1;
    const bottom = @floor(minimum_y) - 1;
    const top = @ceil(maximum_y) + 1;
    if (!std.math.isFinite(left) or !std.math.isFinite(right) or !std.math.isFinite(bottom) or !std.math.isFinite(top)) return error.InvalidFont;
    const width_value = right - left;
    const height_value = top - bottom;
    if (!std.math.isFinite(width_value) or !std.math.isFinite(height_value)) return error.InvalidFont;
    if (width_value > maximum_raster_dimension or height_value > maximum_raster_dimension) return error.BudgetExceeded;
    const width: usize = @intFromFloat(@max(0, width_value));
    const height: usize = @intFromFloat(@max(0, height_value));
    const length = std.math.mul(usize, width, height) catch return error.BudgetExceeded;
    if (length > maximum_raster_pixels) return error.BudgetExceeded;
    const samples: usize = 4;
    const work = std.math.mul(usize, length, segments.items.len) catch return error.BudgetExceeded;
    const sampled_work = std.math.mul(usize, work, samples * samples) catch return error.BudgetExceeded;
    if (sampled_work > maximum_raster_work_units) return error.BudgetExceeded;
    const pixels = try allocator.alloc(u8, length);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            var coverage: usize = 0;
            var sample_y: usize = 0;
            while (sample_y < samples) : (sample_y += 1) {
                var sample_x: usize = 0;
                while (sample_x < samples) : (sample_x += 1) {
                    const point: geometry.Point = .{
                        .x = left + @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sample_x)) + 0.5) / samples,
                        .y = top - @as(f32, @floatFromInt(y)) - (@as(f32, @floatFromInt(sample_y)) + 0.5) / samples,
                    };
                    if (inside(segments.items, point)) coverage += 1;
                }
            }
            pixels[y * width + x] = @intCast((coverage * 255 + samples * samples / 2) / (samples * samples));
        }
    }
    return .{
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        .origin = .{ .x = left, .y = -top },
        .stride = width,
        .pixels = pixels,
        .mode = .grayscale,
    };
}

fn flattenOutline(
    allocator: std.mem.Allocator,
    outline: opentype.Outline,
    scale: f32,
    segments: *std.ArrayList(Segment),
) Error!void {
    var contour_start: usize = 0;
    for (outline.contour_ends) |end_value| {
        const contour_end: usize = end_value;
        if (contour_end < contour_start or contour_end >= outline.points.len) return error.InvalidFont;
        switch (outline.curve_kind) {
            .quadratic => try flattenQuadraticContour(allocator, outline.points[contour_start .. contour_end + 1], scale, segments),
            .cubic => try flattenCubicContour(allocator, outline.points[contour_start .. contour_end + 1], scale, segments),
        }
        contour_start = contour_end + 1;
    }
}

fn flattenQuadraticContour(
    allocator: std.mem.Allocator,
    points: []const opentype.OutlinePoint,
    scale: f32,
    segments: *std.ArrayList(Segment),
) Error!void {
    if (points.len == 0) return;
    const first = scaled(points[0], scale);
    const last = scaled(points[points.len - 1], scale);
    var start: geometry.Point = if (points[0].on_curve) first else if (points[points.len - 1].on_curve) last else midpoint(first, last);
    const contour_start = start;
    var index: usize = 0;
    while (index < points.len) {
        const raw = points[index];
        const point = scaled(raw, scale);
        if (raw.on_curve) {
            if (!samePoint(start, point)) try appendSegment(allocator, segments, start, point);
            start = point;
            index += 1;
            continue;
        }
        const next_index = (index + 1) % points.len;
        const next_raw = points[next_index];
        const next_point = scaled(next_raw, scale);
        const end = if (next_raw.on_curve) next_point else midpoint(point, next_point);
        try flattenQuadratic(allocator, segments, start, point, end, 0);
        start = end;
        index += if (next_raw.on_curve) 2 else 1;
    }
    if (!samePoint(start, contour_start)) try appendSegment(allocator, segments, start, contour_start);
}

fn flattenCubicContour(
    allocator: std.mem.Allocator,
    points: []const opentype.OutlinePoint,
    scale: f32,
    segments: *std.ArrayList(Segment),
) Error!void {
    if (points.len == 0 or !points[0].on_curve) return error.InvalidFont;
    const contour_start = scaled(points[0], scale);
    var start = contour_start;
    var index: usize = 1;
    while (index < points.len) {
        const point = scaled(points[index], scale);
        if (points[index].on_curve) {
            if (!samePoint(start, point)) try appendSegment(allocator, segments, start, point);
            start = point;
            index += 1;
            continue;
        }
        if (index + 2 >= points.len or points[index + 1].on_curve or !points[index + 2].on_curve) return error.InvalidFont;
        const second = scaled(points[index + 1], scale);
        const end = scaled(points[index + 2], scale);
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
    if (distance <= 0.2 or depth >= 12) {
        try appendSegment(allocator, segments, start, end);
        return;
    }
    const left_control = midpoint(start, control);
    const right_control = midpoint(control, end);
    const center = midpoint(left_control, right_control);
    try flattenQuadratic(allocator, segments, start, left_control, center, depth + 1);
    try flattenQuadratic(allocator, segments, center, right_control, end, depth + 1);
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
    if (flatness <= 0.2 or depth >= 14) {
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

fn finitePoint(point: geometry.Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn inside(segments: []const Segment, point: geometry.Point) bool {
    // OpenType contours use the non-zero winding rule.  Even-odd parity
    // creates artificial holes when a variable glyph contains overlapping
    // component contours (SF Pro's large A/a are examples).
    var winding: i32 = 0;
    for (segments) |segment| {
        if (segment.a.y <= point.y) {
            if (segment.b.y <= point.y) continue;
            const cross = (segment.b.x - segment.a.x) * (point.y - segment.a.y) -
                (segment.b.y - segment.a.y) * (point.x - segment.a.x);
            if (cross > 0) winding += 1;
        } else {
            if (segment.b.y > point.y) continue;
            const cross = (segment.b.x - segment.a.x) * (point.y - segment.a.y) -
                (segment.b.y - segment.a.y) * (point.x - segment.a.x);
            if (cross < 0) winding -= 1;
        }
    }
    return winding != 0;
}

test "raster fill keeps overlapping same-direction contours" {
    const segments = [_]Segment{
        .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 10, .y = 0 } },
        .{ .a = .{ .x = 10, .y = 0 }, .b = .{ .x = 10, .y = 10 } },
        .{ .a = .{ .x = 10, .y = 10 }, .b = .{ .x = 0, .y = 10 } },
        .{ .a = .{ .x = 0, .y = 10 }, .b = .{ .x = 0, .y = 0 } },
        .{ .a = .{ .x = 2, .y = 2 }, .b = .{ .x = 8, .y = 2 } },
        .{ .a = .{ .x = 8, .y = 2 }, .b = .{ .x = 8, .y = 8 } },
        .{ .a = .{ .x = 8, .y = 8 }, .b = .{ .x = 2, .y = 8 } },
        .{ .a = .{ .x = 2, .y = 8 }, .b = .{ .x = 2, .y = 2 } },
    };
    try std.testing.expect(inside(&segments, .{ .x = 4, .y = 4 }));
    try std.testing.expect(!inside(&segments, .{ .x = 12, .y = 4 }));
}

fn scaled(point: opentype.OutlinePoint, scale: f32) geometry.Point {
    return .{ .x = point.x * scale, .y = point.y * scale };
}

fn midpoint(a: geometry.Point, b: geometry.Point) geometry.Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}

fn samePoint(a: geometry.Point, b: geometry.Point) bool {
    return @abs(a.x - b.x) < 0.0001 and @abs(a.y - b.y) < 0.0001;
}

fn pointLineDistance(point: geometry.Point, start: geometry.Point, end: geometry.Point) f32 {
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const denominator = @sqrt(dx * dx + dy * dy);
    if (denominator <= 0.00001) return @sqrt((point.x - start.x) * (point.x - start.x) + (point.y - start.y) * (point.y - start.y));
    return @abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x) / denominator;
}
