const std = @import("std");
const a11y = @import("../a11y/api.zig");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const input = @import("../input/event.zig");
const layout = @import("../layout/style.zig");
const scene_abi = @import("../scene/abi.zig");
const compose_style = @import("style.zig");
const text_api = @import("../text/api.zig");

/// A narrow view of the text engine made available to custom elements. It
/// exposes shaped geometry and painting without giving elements ownership of
/// font caches, atlases, renderer resources, or the UI runtime.
pub const TextServices = struct {
    context: *anyopaque,
    measure_fn: *const fn (*anyopaque, []const u8, compose_style.TextStyle, layout.Constraints) Error!geometry.Size,
    paint_fn: ?*const fn (*anyopaque, *anyopaque, []const u8, compose_style.TextStyle, geometry.Rect) Error!void = null,
    hit_test_fn: ?*const fn (*anyopaque, []const u8, compose_style.TextStyle, f32, geometry.Point) Error!text_api.Hit = null,
    caret_rect_fn: ?*const fn (*anyopaque, []const u8, compose_style.TextStyle, f32, usize, text_api.CaretAffinity) Error!geometry.Rect = null,
    selection_rects_fn: ?*const fn (
        *anyopaque,
        []const u8,
        compose_style.TextStyle,
        f32,
        usize,
        usize,
        *std.ArrayList(geometry.Rect),
        std.mem.Allocator,
    ) Error!void = null,

    pub fn measure(self: TextServices, value: []const u8, style: compose_style.TextStyle, constraints: layout.Constraints) Error!geometry.Size {
        try validateTextRequest(value, style);
        if (!validConstraints(constraints)) return error.InvalidLayout;
        const result = try self.measure_fn(self.context, value, style, constraints);
        if (!validSize(result)) return error.InvalidLayout;
        return result;
    }

    pub fn paint(self: TextServices, scene_context: *anyopaque, value: []const u8, style: compose_style.TextStyle, bounds: geometry.Rect) Error!void {
        try validateTextRequest(value, style);
        if (!validRect(bounds)) return error.InvalidLayout;
        const callback = self.paint_fn orelse return error.TextUnavailable;
        try callback(self.context, scene_context, value, style, bounds);
    }

    pub fn hitTest(self: TextServices, value: []const u8, style: compose_style.TextStyle, maximum_width: f32, point: geometry.Point) Error!text_api.Hit {
        try validateTextRequest(value, style);
        if (!validMaximum(maximum_width) or !validPoint(point)) return error.InvalidLayout;
        const callback = self.hit_test_fn orelse return error.TextUnavailable;
        const result = try callback(self.context, value, style, maximum_width, point);
        if (!utf8Boundary(value, result.utf8_offset)) return error.InvalidUtf8;
        return result;
    }

    pub fn caretRect(
        self: TextServices,
        value: []const u8,
        style: compose_style.TextStyle,
        maximum_width: f32,
        utf8_offset: usize,
        affinity: text_api.CaretAffinity,
    ) Error!geometry.Rect {
        try validateTextRequest(value, style);
        if (!validMaximum(maximum_width) or !utf8Boundary(value, utf8_offset))
            return error.InvalidLayout;
        const callback = self.caret_rect_fn orelse return error.TextUnavailable;
        const result = try callback(self.context, value, style, maximum_width, utf8_offset, affinity);
        if (!validRect(result)) return error.InvalidLayout;
        return result;
    }

    pub fn selectionRects(
        self: TextServices,
        value: []const u8,
        style: compose_style.TextStyle,
        maximum_width: f32,
        start: usize,
        end: usize,
        output: *std.ArrayList(geometry.Rect),
        allocator: std.mem.Allocator,
    ) Error!void {
        try validateTextRequest(value, style);
        if (!validMaximum(maximum_width) or start > end or
            !utf8Boundary(value, start) or !utf8Boundary(value, end))
            return error.InvalidLayout;
        const callback = self.selection_rects_fn orelse return error.TextUnavailable;
        // Isolate callback-owned writes so a malformed provider cannot mutate
        // or truncate rectangles already committed by the caller.
        var staging: std.ArrayList(geometry.Rect) = .empty;
        defer staging.deinit(allocator);
        try callback(self.context, value, style, maximum_width, start, end, &staging, allocator);
        const maximum_rects = std.math.add(usize, value.len, 1) catch std.math.maxInt(usize);
        if (staging.items.len > maximum_rects) return error.BudgetExceeded;
        for (staging.items) |rect| if (!validRect(rect)) return error.InvalidLayout;
        try output.appendSlice(allocator, staging.items);
    }
};

/// Optional vector-asset access exposed to custom elements. The service keeps
/// ownership, parsing caches, and scene internals inside the App; elements use
/// only a generational handle and cannot retain a stale Document pointer.
pub const SvgServices = struct {
    context: *anyopaque,
    measure_fn: *const fn (*anyopaque, handles.SvgId, layout.Constraints) Error!geometry.Size,
    paint_fn: *const fn (*anyopaque, *anyopaque, handles.SvgId, geometry.Rect, u8) Error!void,

    pub fn measure(self: SvgServices, id: handles.SvgId, constraints: layout.Constraints) Error!geometry.Size {
        if (!id.isValid()) return error.InvalidHandle;
        if (!validConstraints(constraints)) return error.InvalidLayout;
        const result = try self.measure_fn(self.context, id, constraints);
        if (!validSize(result)) return error.InvalidLayout;
        return result;
    }

    pub fn paint(self: SvgServices, scene_context: *anyopaque, id: handles.SvgId, bounds: geometry.Rect, fit: u8) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        if (!validRect(bounds)) return error.InvalidLayout;
        try self.paint_fn(self.context, scene_context, id, bounds, fit);
    }
};

pub const MeasureContext = struct {
    allocator: std.mem.Allocator,
    scale_factor: geometry.ScaleFactor,
    text: ?TextServices = null,
    svg: ?SvgServices = null,
};

pub const ArrangeContext = struct {
    allocator: std.mem.Allocator,
    scale_factor: geometry.ScaleFactor,
    component: handles.ComponentId = .invalid,
    /// Final containing-block geometry when the parent has completed its flow
    /// layout. Absolute observer nodes are arranged after that point and can
    /// use these values to synchronize bounded retained viewport state.
    containing_bounds: geometry.Rect = .{},
    containing_content_bounds: geometry.Rect = .{},
    containing_scroll_extent: geometry.Size = .{},
    feedback_context: ?*anyopaque = null,
    request_recompose_fn: ?*const fn (*anyopaque, handles.ComponentId) void = null,

    /// Requests another bounded compose/measure/arrange pass in the current
    /// frame after an element learns geometry that changes what it retains.
    /// Returns false in standalone layout engines that do not provide a
    /// stabilization host.
    pub fn requestRecompose(self: *ArrangeContext) bool {
        const callback = self.request_recompose_fn orelse return false;
        const context = self.feedback_context orelse return false;
        if (!self.component.isValid()) return false;
        callback(context, self.component);
        return true;
    }
};

pub const PrepareContext = struct {
    allocator: std.mem.Allocator,
    scale_factor: geometry.ScaleFactor,
    device_generation: u32,
};

pub const PaintContext = struct {
    scene_context: *anyopaque,
    emit_fn: *const fn (*anyopaque, PaintCommand) Error!void,
    scratch: std.mem.Allocator,
    scale_factor: geometry.ScaleFactor,
    text: ?TextServices = null,
    svg: ?SvgServices = null,

    pub fn emit(self: *PaintContext, command: PaintCommand) Error!void {
        try self.emit_fn(self.scene_context, command);
    }

    pub fn pushClip(self: *PaintContext, bounds: geometry.Rect, radii: geometry.CornerRadii) Error!void {
        try self.emit(.{ .push_clip = .{ .bounds = bounds, .radii = radii } });
    }

    pub fn popClip(self: *PaintContext) Error!void {
        try self.emit(.pop_clip);
    }

    pub fn pushLayer(
        self: *PaintContext,
        opacity: f32,
        blend_mode: scene_abi.BlendMode,
        transform: geometry.Affine2D,
    ) Error!void {
        try self.emit(.{ .push_layer = .{
            .opacity = opacity,
            .blend_mode = blend_mode,
            .transform = transform,
        } });
    }

    pub fn popLayer(self: *PaintContext) Error!void {
        try self.emit(.pop_layer);
    }

    /// Applies a screen-space backdrop filter before subsequent custom paint.
    /// The effect is evaluated against the current retained render target.
    pub fn backdropEffect(self: *PaintContext, value: scene_abi.BackdropEffect) Error!void {
        try self.emit(.{ .backdrop_effect = value });
    }

    pub fn quad(self: *PaintContext, value: scene_abi.Quad) Error!void {
        try self.emit(.{ .quad = value });
    }

    pub fn gradientQuad(
        self: *PaintContext,
        value: scene_abi.Quad,
        start: geometry.Point,
        end: geometry.Point,
        stops: []const scene_abi.GradientStop,
    ) Error!void {
        try self.emit(.{ .gradient_quad = .{
            .value = value,
            .start = start,
            .end = end,
            .stops = stops,
        } });
    }

    pub fn path(
        self: *PaintContext,
        value: scene_abi.Path,
        vertices: []const scene_abi.PathVertex,
    ) Error!void {
        try self.emit(.{ .path = .{ .value = value, .vertices = vertices } });
    }

    pub fn paintText(self: *PaintContext, value: []const u8, style: compose_style.TextStyle, bounds: geometry.Rect) Error!void {
        const services = self.text orelse return error.TextUnavailable;
        try services.paint(self.scene_context, value, style, bounds);
    }

    pub fn gpuPass(
        self: *PaintContext,
        extension: handles.RenderExtensionId,
        bounds: geometry.Rect,
        payload: []const u8,
        flags: u32,
    ) Error!void {
        try self.emit(.{ .custom_pass = .{
            .extension = extension,
            .bounds = bounds,
            .payload = payload,
            .flags = flags,
        } });
    }

    /// Declares the committed window-space placement of a native media layer.
    /// ZigUI applies it after the frame commits, outside compose and layout.
    pub fn nativeMedia(self: *PaintContext, id: handles.NativeMediaId, bounds: geometry.Rect) Error!void {
        try self.nativeMediaWithVisibility(id, bounds, true);
    }

    /// Declares both the layout bounds and committed visibility of a native
    /// media layer. Hidden placements remain scene-managed without requiring
    /// consumer-owned offscreen geometry.
    pub fn nativeMediaWithVisibility(self: *PaintContext, id: handles.NativeMediaId, bounds: geometry.Rect, visible: bool) Error!void {
        try self.emit(.{ .native_media = .{ .id = id, .bounds = bounds, .visible = visible } });
    }
};

pub const PaintCommand = union(enum) {
    push_clip: struct { bounds: geometry.Rect, radii: geometry.CornerRadii },
    pop_clip,
    push_layer: struct {
        opacity: f32,
        blend_mode: scene_abi.BlendMode,
        transform: geometry.Affine2D,
    },
    pop_layer,
    backdrop_effect: scene_abi.BackdropEffect,
    quad: scene_abi.Quad,
    gradient_quad: struct {
        value: scene_abi.Quad,
        start: geometry.Point,
        end: geometry.Point,
        stops: []const scene_abi.GradientStop,
    },
    path: struct { value: scene_abi.Path, vertices: []const scene_abi.PathVertex },
    shadow: scene_abi.Shadow,
    underline: scene_abi.Underline,
    monochrome_sprite: scene_abi.Sprite,
    color_sprite: scene_abi.Sprite,
    external_surface: scene_abi.ExternalSurface,
    native_media: struct { id: handles.NativeMediaId, bounds: geometry.Rect, visible: bool },
    custom_pass: struct {
        extension: handles.RenderExtensionId,
        bounds: geometry.Rect,
        payload: []const u8,
        flags: u32 = 0,
    },
};

pub const SemanticsWriter = struct {
    context: *anyopaque,
    append_fn: *const fn (*anyopaque, u64, a11y.Node) Error!@import("../core/handle.zig").SemanticId,

    /// Adds a semantic descendant whose identity is retained by ZigUI from the
    /// custom element's stable local key. Callers never fabricate handles.
    pub fn append(self: *SemanticsWriter, key: u64, node: a11y.Node) Error!@import("../core/handle.zig").SemanticId {
        return self.append_fn(self.context, key, node);
    }
};

pub const VTable = struct {
    measure: ?*const fn (*anyopaque, *MeasureContext, layout.Constraints) Error!geometry.Size = null,
    arrange: ?*const fn (*anyopaque, *ArrangeContext, geometry.Rect) Error!void = null,
    prepare: ?*const fn (*anyopaque, *PrepareContext, geometry.Rect) Error!void = null,
    paint: *const fn (*anyopaque, *PaintContext, geometry.Rect) Error!void,
    event: ?*const fn (*anyopaque, *input.Dispatch, *const input.Event, *input.Context) Error!void = null,
    semantics: ?*const fn (*anyopaque, *SemanticsWriter, geometry.Rect) Error!void = null,
};

pub const Node = struct {
    context: *anyopaque,
    vtable: *const VTable,
    type_token: *const anyopaque,

    pub fn from(comptime T: type, value: *T) Node {
        return .{
            .context = value,
            .vtable = generatedVTable(T),
            .type_token = typeToken(T),
        };
    }
};

fn generatedVTable(comptime T: type) *const VTable {
    return &struct {
        const vtable_value: VTable = .{
            .measure = if (@hasDecl(T, "measure")) measure else null,
            .arrange = if (@hasDecl(T, "arrange")) arrange else null,
            .prepare = if (@hasDecl(T, "prepare")) prepare else null,
            .paint = paint,
            .event = if (@hasDecl(T, "event")) event else null,
            .semantics = if (@hasDecl(T, "semantics")) semantics else null,
        };

        fn cast(context: *anyopaque) *T {
            return @ptrCast(@alignCast(context));
        }

        fn measure(context: *anyopaque, ctx: *MeasureContext, constraints: layout.Constraints) Error!geometry.Size {
            return cast(context).measure(ctx, constraints);
        }

        fn arrange(context: *anyopaque, ctx: *ArrangeContext, bounds: geometry.Rect) Error!void {
            try cast(context).arrange(ctx, bounds);
        }

        fn prepare(context: *anyopaque, ctx: *PrepareContext, bounds: geometry.Rect) Error!void {
            try cast(context).prepare(ctx, bounds);
        }

        fn paint(context: *anyopaque, ctx: *PaintContext, bounds: geometry.Rect) Error!void {
            if (!@hasDecl(T, "paint")) @compileError(@typeName(T) ++ " must declare paint");
            try cast(context).paint(ctx, bounds);
        }

        fn event(context: *anyopaque, dispatch: *input.Dispatch, event_value: *const input.Event, event_context: *input.Context) Error!void {
            try cast(context).event(dispatch, event_value, event_context);
        }

        fn semantics(context: *anyopaque, writer: *SemanticsWriter, bounds: geometry.Rect) Error!void {
            try cast(context).semantics(writer, bounds);
        }
    }.vtable_value;
}

fn typeToken(comptime T: type) *const anyopaque {
    return &struct {
        var value: u8 = 0;
        const Type = T;
    }.value;
}

fn validateTextRequest(value: []const u8, text_style: compose_style.TextStyle) Error!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
    if (value.len > std.math.maxInt(u32) or text_style.font_families.len > 64 or
        text_style.font_variations.len > 64) return error.BudgetExceeded;
    if (text_style.font_stretch == 0 or text_style.font_stretch > 1000 or
        !std.math.isFinite(text_style.font_size) or text_style.font_size <= 0 or text_style.font_size > 1_000_000 or
        !std.math.isFinite(text_style.letter_spacing) or @abs(text_style.letter_spacing) > 1_000_000 or
        !validColor(text_style.color))
        return error.InvalidConfiguration;
    if (text_style.line_height) |line_height| if (!std.math.isFinite(line_height) or
        line_height <= 0 or line_height > 1_000_000)
        return error.InvalidConfiguration;
    if (text_style.maximum_lines) |maximum_lines| if (maximum_lines == 0) return error.InvalidConfiguration;
    var family_bytes: usize = 0;
    for (text_style.font_families) |family| {
        if (family.len == 0 or !std.unicode.utf8ValidateSlice(family) or std.mem.indexOfScalar(u8, family, 0) != null)
            return error.InvalidConfiguration;
        family_bytes = std.math.add(usize, family_bytes, family.len) catch return error.BudgetExceeded;
        if (family_bytes > 4096) return error.BudgetExceeded;
    }
    for (text_style.font_variations) |variation| if (!std.math.isFinite(variation.value))
        return error.InvalidConfiguration;
}

fn validConstraints(value: layout.Constraints) bool {
    return validSize(value.minimum) and
        !std.math.isNan(value.maximum.width) and !std.math.isNan(value.maximum.height) and
        value.maximum.width >= 0 and value.maximum.height >= 0 and
        value.minimum.width <= value.maximum.width and value.minimum.height <= value.maximum.height;
}

fn validSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and value.width >= 0 and value.height >= 0;
}

fn validMaximum(value: f32) bool {
    return !std.math.isNan(value) and value >= 0;
}

fn validPoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}

fn validRect(value: geometry.Rect) bool {
    return validPoint(value.origin) and validSize(value.size);
}

fn validColor(value: geometry.Color) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and std.math.isFinite(value.b) and
        std.math.isFinite(value.a) and value.a >= 0 and value.a <= 1;
}

fn utf8Boundary(value: []const u8, index: usize) bool {
    return index == value.len or (index < value.len and value[index] & 0xc0 != 0x80);
}
