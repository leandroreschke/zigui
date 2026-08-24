const std = @import("std");

pub const Scalar = f32;

pub const Point = extern struct {
    x: Scalar = 0,
    y: Scalar = 0,

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
};

pub const Size = extern struct {
    width: Scalar = 0,
    height: Scalar = 0,

    pub const zero: Size = .{};
    pub const unbounded: Size = .{
        .width = std.math.inf(Scalar),
        .height = std.math.inf(Scalar),
    };

    pub fn clamp(self: Size, minimum: Size, maximum: Size) Size {
        return .{
            .width = @min(@max(self.width, minimum.width), maximum.width),
            .height = @min(@max(self.height, minimum.height), maximum.height),
        };
    }
};

pub const Insets = extern struct {
    top: Scalar = 0,
    right: Scalar = 0,
    bottom: Scalar = 0,
    left: Scalar = 0,

    pub fn all(value: Scalar) Insets {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }

    pub fn symmetric(horizontal_value: Scalar, vertical_value: Scalar) Insets {
        return .{
            .top = vertical_value,
            .right = horizontal_value,
            .bottom = vertical_value,
            .left = horizontal_value,
        };
    }

    pub fn horizontal(self: Insets) Scalar {
        return self.left + self.right;
    }

    pub fn vertical(self: Insets) Scalar {
        return self.top + self.bottom;
    }
};

pub const Rect = extern struct {
    origin: Point = .{},
    size: Size = .{},

    pub fn fromXYWH(x: Scalar, y: Scalar, width: Scalar, height: Scalar) Rect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
    }

    pub fn minX(self: Rect) Scalar {
        return self.origin.x;
    }

    pub fn minY(self: Rect) Scalar {
        return self.origin.y;
    }

    pub fn maxX(self: Rect) Scalar {
        return self.origin.x + self.size.width;
    }

    pub fn maxY(self: Rect) Scalar {
        return self.origin.y + self.size.height;
    }

    pub fn isEmpty(self: Rect) bool {
        return self.size.width <= 0 or self.size.height <= 0;
    }

    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.minX() and point.x < self.maxX() and
            point.y >= self.minY() and point.y < self.maxY();
    }

    pub fn intersection(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.minX(), b.minX());
        const y0 = @max(a.minY(), b.minY());
        const x1 = @min(a.maxX(), b.maxX());
        const y1 = @min(a.maxY(), b.maxY());
        if (x1 <= x0 or y1 <= y0) return null;
        return Rect.fromXYWH(x0, y0, x1 - x0, y1 - y0);
    }

    pub fn inset(self: Rect, insets: Insets) Rect {
        return .{
            .origin = .{
                .x = self.origin.x + insets.left,
                .y = self.origin.y + insets.top,
            },
            .size = .{
                .width = @max(0, self.size.width - insets.horizontal()),
                .height = @max(0, self.size.height - insets.vertical()),
            },
        };
    }

    pub fn translated(self: Rect, offset: Point) Rect {
        return .{ .origin = self.origin.add(offset), .size = self.size };
    }
};

pub const CornerRadii = extern struct {
    top_left: Scalar = 0,
    top_right: Scalar = 0,
    bottom_right: Scalar = 0,
    bottom_left: Scalar = 0,

    pub fn all(value: Scalar) CornerRadii {
        return .{
            .top_left = value,
            .top_right = value,
            .bottom_right = value,
            .bottom_left = value,
        };
    }
};

pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub const transparent: Color = .{ .a = 0 };
    pub const black: Color = .{};
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
        const scale = 1.0 / 255.0;
        return .{
            .r = srgbToLinear(@as(f32, @floatFromInt(r)) * scale),
            .g = srgbToLinear(@as(f32, @floatFromInt(g)) * scale),
            .b = srgbToLinear(@as(f32, @floatFromInt(b)) * scale),
            .a = @as(f32, @floatFromInt(a)) * scale,
        };
    }

    pub fn premultiplied(self: Color) Color {
        return .{ .r = self.r * self.a, .g = self.g * self.a, .b = self.b * self.a, .a = self.a };
    }
};

fn srgbToLinear(value: f32) f32 {
    @setEvalBranchQuota(10_000);
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

pub const Affine2D = extern struct {
    m11: f32 = 1,
    m12: f32 = 0,
    m21: f32 = 0,
    m22: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub const identity: Affine2D = .{};

    pub fn translation(offset: Point) Affine2D {
        return .{ .tx = offset.x, .ty = offset.y };
    }

    pub fn scale(x: f32, y: f32) Affine2D {
        return .{ .m11 = x, .m22 = y };
    }

    pub fn transformPoint(self: Affine2D, point: Point) Point {
        return .{
            .x = point.x * self.m11 + point.y * self.m21 + self.tx,
            .y = point.x * self.m12 + point.y * self.m22 + self.ty,
        };
    }

    pub fn mul(a: Affine2D, b: Affine2D) Affine2D {
        return .{
            .m11 = a.m11 * b.m11 + a.m21 * b.m12,
            .m12 = a.m12 * b.m11 + a.m22 * b.m12,
            .m21 = a.m11 * b.m21 + a.m21 * b.m22,
            .m22 = a.m12 * b.m21 + a.m22 * b.m22,
            .tx = a.m11 * b.tx + a.m21 * b.ty + a.tx,
            .ty = a.m12 * b.tx + a.m22 * b.ty + a.ty,
        };
    }

    pub fn determinant(self: Affine2D) f32 {
        return self.m11 * self.m22 - self.m12 * self.m21;
    }

    pub fn inverse(self: Affine2D) ?Affine2D {
        const determinant_value = self.determinant();
        if (!std.math.isFinite(determinant_value) or @abs(determinant_value) <= 0.0000001) return null;
        const reciprocal = 1.0 / determinant_value;
        const result: Affine2D = .{
            .m11 = self.m22 * reciprocal,
            .m12 = -self.m12 * reciprocal,
            .m21 = -self.m21 * reciprocal,
            .m22 = self.m11 * reciprocal,
        };
        return .{
            .m11 = result.m11,
            .m12 = result.m12,
            .m21 = result.m21,
            .m22 = result.m22,
            .tx = -(result.m11 * self.tx + result.m21 * self.ty),
            .ty = -(result.m12 * self.tx + result.m22 * self.ty),
        };
    }

    pub fn around(self: Affine2D, origin: Point) Affine2D {
        return Affine2D.mul(
            Affine2D.translation(origin),
            Affine2D.mul(self, Affine2D.translation(.{ .x = -origin.x, .y = -origin.y })),
        );
    }

    pub fn transformRectBounds(self: Affine2D, rect: Rect) Rect {
        const top_left = self.transformPoint(rect.origin);
        const top_right = self.transformPoint(.{ .x = rect.maxX(), .y = rect.minY() });
        const bottom_left = self.transformPoint(.{ .x = rect.minX(), .y = rect.maxY() });
        const bottom_right = self.transformPoint(.{ .x = rect.maxX(), .y = rect.maxY() });
        const minimum_x = @min(@min(top_left.x, top_right.x), @min(bottom_left.x, bottom_right.x));
        const minimum_y = @min(@min(top_left.y, top_right.y), @min(bottom_left.y, bottom_right.y));
        const maximum_x = @max(@max(top_left.x, top_right.x), @max(bottom_left.x, bottom_right.x));
        const maximum_y = @max(@max(top_left.y, top_right.y), @max(bottom_left.y, bottom_right.y));
        return Rect.fromXYWH(minimum_x, minimum_y, maximum_x - minimum_x, maximum_y - minimum_y);
    }
};

pub const ScaleFactor = struct {
    value: f32,

    pub fn init(value: f32) error{InvalidScaleFactor}!ScaleFactor {
        if (!std.math.isFinite(value) or value <= 0) return error.InvalidScaleFactor;
        return .{ .value = value };
    }

    pub fn logicalToDevice(self: ScaleFactor, value: f32) f32 {
        return value * self.value;
    }

    pub fn deviceToLogical(self: ScaleFactor, value: f32) f32 {
        return value / self.value;
    }
};

pub const PixelSnap = enum {
    nearest,
    floor,
    ceil,
    preserve_size,
};

pub fn snap(value: f32, scale_factor: ScaleFactor, policy: PixelSnap) f32 {
    const device = value * scale_factor.value;
    const snapped = switch (policy) {
        .nearest, .preserve_size => @round(device),
        .floor => @floor(device),
        .ceil => @ceil(device),
    };
    return snapped / scale_factor.value;
}

pub fn snapRect(rect: Rect, scale_factor: ScaleFactor, policy: PixelSnap) Rect {
    if (policy == .preserve_size) {
        return .{
            .origin = .{
                .x = snap(rect.origin.x, scale_factor, .nearest),
                .y = snap(rect.origin.y, scale_factor, .nearest),
            },
            .size = .{
                .width = snap(rect.size.width, scale_factor, .nearest),
                .height = snap(rect.size.height, scale_factor, .nearest),
            },
        };
    }
    const x0 = snap(rect.minX(), scale_factor, policy);
    const y0 = snap(rect.minY(), scale_factor, policy);
    const x1 = snap(rect.maxX(), scale_factor, policy);
    const y1 = snap(rect.maxY(), scale_factor, policy);
    return Rect.fromXYWH(x0, y0, @max(0, x1 - x0), @max(0, y1 - y0));
}
