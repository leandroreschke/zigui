const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const Error = @import("../core/error.zig").Error;

pub const FontWeight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    regular = 400,
    medium = 500,
    semibold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
};

pub const FontStyle = enum { normal, italic, oblique };
pub const TextDirection = enum { auto, left_to_right, right_to_left };
pub const WrapMode = enum { none, word, character };
pub const RasterMode = enum { monochrome, grayscale, subpixel, color };
pub const ColorGlyphKind = enum { none, fixed, foreground };

/// Resolves the ambiguous visual position at a bidirectional boundary. A
/// downstream caret belongs to the following logical grapheme; an upstream
/// caret belongs to the preceding one.
pub const CaretAffinity = enum { upstream, downstream };
pub const FontVariation = struct {
    tag: [4]u8,
    value: f32,
};

pub const Hit = struct {
    utf8_offset: usize,
    affinity: CaretAffinity = .downstream,
    line: u32 = 0,
};

pub const FontDescriptor = struct {
    families: []const []const u8,
    weight: FontWeight = .regular,
    style: FontStyle = .normal,
    stretch: u16 = 100,
    /// Explicit OpenType user-space axis values. These are applied after the
    /// semantic weight/style/stretch settings, so callers can override them.
    variations: []const FontVariation = &.{},
};

pub const FontMetrics = struct {
    ascent: f32,
    descent: f32,
    leading: f32,
    x_height: f32,
    cap_height: f32,
    underline_position: f32,
    underline_thickness: f32,
};

pub const Feature = struct {
    tag: [4]u8,
    value: u32,
    start_utf8: usize = 0,
    end_utf8: usize = std.math.maxInt(usize),
};

const std = @import("std");

pub const ShapeRequest = struct {
    text: []const u8,
    font: handles.FontId,
    size: f32,
    /// Physical pixels per logical pixel. OpenType Device tables use this to
    /// select their ppem-specific deltas; layout results therefore include it
    /// in their cache identity.
    scale_factor: f32 = 1,
    direction: TextDirection = .auto,
    locale: []const u8 = "",
    features: []const Feature = &.{},
};

pub const Glyph = extern struct {
    glyph_id: u32,
    cluster_utf8: u32,
    advance_x: f32,
    advance_y: f32,
    offset_x: f32,
    offset_y: f32,
    font_index: u32,
};

pub const ShapedRun = struct {
    text_utf8: []const u8,
    glyphs: []const Glyph,
    fonts: []const handles.FontId,
    direction: TextDirection,
    width: f32,
    metrics: FontMetrics,

    pub fn deinit(self: *ShapedRun, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.glyphs));
        allocator.free(@constCast(self.fonts));
        self.* = undefined;
    }
};

pub const RasterRequest = struct {
    font: handles.FontId,
    glyph_id: u32,
    size: f32,
    scale_factor: f32,
    subpixel_x: u8 = 0,
    subpixel_y: u8 = 0,
    mode: RasterMode = .grayscale,
    foreground: geometry.Color = .white,
};

pub const RasterizedGlyph = struct {
    size: geometry.Size,
    origin: geometry.Point,
    stride: usize,
    pixels: []const u8,
    mode: RasterMode,

    pub fn deinit(self: *RasterizedGlyph, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.pixels));
        self.* = undefined;
    }
};

pub const Backend = struct {
    context: *anyopaque,
    resolve_font_fn: *const fn (*anyopaque, FontDescriptor) Error!handles.FontId,
    metrics_fn: *const fn (*anyopaque, handles.FontId, f32) Error!FontMetrics,
    shape_fn: *const fn (*anyopaque, ShapeRequest, std.mem.Allocator) Error!ShapedRun,
    color_glyph_fn: *const fn (*anyopaque, handles.FontId, u32) ColorGlyphKind,
    rasterize_fn: *const fn (*anyopaque, RasterRequest, std.mem.Allocator) Error!RasterizedGlyph,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn resolveFont(self: Backend, descriptor: FontDescriptor) Error!handles.FontId {
        try validateFontDescriptor(descriptor);
        const result = try self.resolve_font_fn(self.context, descriptor);
        if (!result.isValid()) return error.PlatformFailure;
        return result;
    }

    pub fn metrics(self: Backend, font: handles.FontId, size: f32) Error!FontMetrics {
        if (!font.isValid()) return error.InvalidHandle;
        try validateTextSize(size);
        const result = try self.metrics_fn(self.context, font, size);
        try validateMetrics(result);
        return result;
    }

    pub fn shape(self: Backend, request: ShapeRequest, allocator: std.mem.Allocator) Error!ShapedRun {
        try validateShapeRequest(request);
        var result = try self.shape_fn(self.context, request, allocator);
        errdefer result.deinit(allocator);
        try validateShapedRun(request, result);
        return result;
    }

    pub fn rasterize(self: Backend, request: RasterRequest, allocator: std.mem.Allocator) Error!RasterizedGlyph {
        try validateRasterRequest(request);
        var result = try self.rasterize_fn(self.context, request, allocator);
        errdefer result.deinit(allocator);
        try validateRasterizedGlyph(result);
        return result;
    }

    pub fn colorGlyphKind(self: Backend, font: handles.FontId, glyph_id: u32) Error!ColorGlyphKind {
        if (!font.isValid()) return error.InvalidHandle;
        return self.color_glyph_fn(self.context, font, glyph_id);
    }

    pub fn isColorGlyph(self: Backend, font: handles.FontId, glyph_id: u32) Error!bool {
        return try self.colorGlyphKind(font, glyph_id) != .none;
    }

    pub fn deinit(self: Backend) void {
        self.deinit_fn(self.context);
    }
};

const maximum_font_families = 64;
const maximum_font_family_bytes = 4096;
const maximum_font_variations = 64;
const maximum_features = 4096;
const maximum_locale_bytes = 256;
const maximum_text_size: f32 = 1_000_000;
const maximum_scale_factor: f32 = 64;

fn validateFontDescriptor(descriptor: FontDescriptor) Error!void {
    if (descriptor.families.len > maximum_font_families or descriptor.variations.len > maximum_font_variations or
        descriptor.stretch == 0 or descriptor.stretch > 1000) return error.InvalidConfiguration;
    var family_bytes: usize = 0;
    for (descriptor.families) |family| {
        if (family.len == 0 or !std.unicode.utf8ValidateSlice(family) or
            std.mem.indexOfScalar(u8, family, 0) != null) return error.InvalidConfiguration;
        family_bytes = std.math.add(usize, family_bytes, family.len) catch return error.BudgetExceeded;
        if (family_bytes > maximum_font_family_bytes) return error.BudgetExceeded;
    }
    for (descriptor.variations) |variation| if (!std.math.isFinite(variation.value))
        return error.InvalidConfiguration;
}

fn validateShapeRequest(request: ShapeRequest) Error!void {
    if (!request.font.isValid()) return error.InvalidHandle;
    try validateTextSize(request.size);
    try validateScaleFactor(request.scale_factor);
    if (!std.unicode.utf8ValidateSlice(request.text)) return error.InvalidUtf8;
    if (request.text.len > std.math.maxInt(u32) or request.features.len > maximum_features)
        return error.BudgetExceeded;
    if (request.locale.len > maximum_locale_bytes) return error.BudgetExceeded;
    if (!std.unicode.utf8ValidateSlice(request.locale) or std.mem.indexOfScalar(u8, request.locale, 0) != null)
        return error.InvalidUtf8;
    for (request.features) |feature| {
        const end = @min(feature.end_utf8, request.text.len);
        if (feature.start_utf8 > end or !utf8Boundary(request.text, feature.start_utf8) or
            !utf8Boundary(request.text, end)) return error.InvalidConfiguration;
    }
}

fn validateRasterRequest(request: RasterRequest) Error!void {
    if (!request.font.isValid()) return error.InvalidHandle;
    try validateTextSize(request.size);
    try validateScaleFactor(request.scale_factor);
    if (!validColor(request.foreground)) return error.InvalidConfiguration;
}

fn validateShapedRun(request: ShapeRequest, result: ShapedRun) Error!void {
    if (result.text_utf8.len != request.text.len or
        (request.text.len != 0 and result.text_utf8.ptr != request.text.ptr) or
        result.fonts.len == 0 or result.fonts.len > std.math.maxInt(u32) or
        result.glyphs.len > std.math.maxInt(u32) or
        result.direction == .auto or !std.math.isFinite(result.width) or result.width < 0)
        return error.PlatformFailure;
    if (request.direction != .auto and result.direction != request.direction)
        return error.PlatformFailure;
    const proportional_limit = std.math.mul(usize, request.text.len, 16) catch std.math.maxInt(usize);
    const maximum_glyphs = std.math.add(usize, proportional_limit, 64) catch std.math.maxInt(usize);
    if (result.glyphs.len > maximum_glyphs or result.fonts.len > @max(result.glyphs.len, 1))
        return error.PlatformFailure;
    try validateMetrics(result.metrics);
    for (result.fonts) |font| if (!font.isValid()) return error.PlatformFailure;
    for (result.glyphs) |glyph| {
        const cluster: usize = @intCast(glyph.cluster_utf8);
        if (cluster > request.text.len or !utf8Boundary(request.text, cluster) or
            glyph.font_index >= result.fonts.len or !std.math.isFinite(glyph.advance_x) or
            !std.math.isFinite(glyph.advance_y) or !std.math.isFinite(glyph.offset_x) or
            !std.math.isFinite(glyph.offset_y)) return error.PlatformFailure;
    }
}

fn validateRasterizedGlyph(result: RasterizedGlyph) Error!void {
    if (!validSize(result.size) or !validPoint(result.origin)) return error.PlatformFailure;
    if (@trunc(result.size.width) != result.size.width or @trunc(result.size.height) != result.size.height)
        return error.PlatformFailure;
    if (result.size.width > std.math.maxInt(u16) or result.size.height > std.math.maxInt(u16))
        return error.BudgetExceeded;
    const width: usize = @intFromFloat(result.size.width);
    const height: usize = @intFromFloat(result.size.height);
    if (width == 0 or height == 0) {
        if (width != 0 or height != 0 or result.stride != 0 or result.pixels.len != 0)
            return error.PlatformFailure;
        return;
    }
    const bytes_per_pixel: usize = switch (result.mode) {
        .monochrome, .grayscale => 1,
        .subpixel => 3,
        .color => 4,
    };
    const row_bytes = std.math.mul(usize, width, bytes_per_pixel) catch return error.PlatformFailure;
    if (result.stride < row_bytes) return error.PlatformFailure;
    const required = std.math.mul(usize, result.stride, height) catch return error.PlatformFailure;
    if (result.pixels.len < required) return error.PlatformFailure;
}

fn validateMetrics(metrics_value: FontMetrics) Error!void {
    inline for (@typeInfo(FontMetrics).@"struct".field_names) |field_name| if (!std.math.isFinite(@field(metrics_value, field_name)))
        return error.PlatformFailure;
    if (metrics_value.underline_thickness < 0) return error.PlatformFailure;
}

fn validateTextSize(value: f32) Error!void {
    if (!std.math.isFinite(value) or value <= 0 or value > maximum_text_size)
        return error.InvalidConfiguration;
}

fn validateScaleFactor(value: f32) Error!void {
    if (!std.math.isFinite(value) or value <= 0 or value > maximum_scale_factor)
        return error.InvalidConfiguration;
}

fn validPoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}

fn validSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and
        value.width >= 0 and value.height >= 0;
}

fn validColor(value: geometry.Color) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and
        std.math.isFinite(value.b) and std.math.isFinite(value.a) and
        value.a >= 0 and value.a <= 1;
}

fn utf8Boundary(bytes: []const u8, offset: usize) bool {
    return offset <= bytes.len and (offset == bytes.len or bytes[offset] & 0xc0 != 0x80);
}
