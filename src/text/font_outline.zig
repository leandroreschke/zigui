const std = @import("std");

pub const Bounds = struct {
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
};

pub const CurveKind = enum { quadratic, cubic };

pub const Point = struct {
    x: f32,
    y: f32,
    on_curve: bool,
};

pub const Outline = struct {
    points: []Point,
    contour_ends: []u32,
    bounds: Bounds,
    curve_kind: CurveKind = .quadratic,

    pub fn deinit(self: *Outline, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.contour_ends);
        self.* = undefined;
    }
};
