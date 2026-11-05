const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const metrics = @import("../core/metrics.zig");
const compose_style = @import("../compose/style.zig");
const compose_store = @import("../compose/store.zig");
const layout_style = @import("../layout/style.zig");
const layout_engine = @import("../layout/engine.zig");
const render = @import("../render/api.zig");
const resource = @import("../render/resource.zig");
const atlas_mod = @import("../render/atlas.zig");
const scene = @import("../scene/scene.zig");
const scene_abi = @import("../scene/abi.zig");
const scene_painter = @import("../scene/painter.zig");
const api = @import("api.zig");
const unicode = @import("unicode.zig");

const PositionedGlyph = struct {
    font: handles.FontId,
    glyph_id: u32,
    cluster_utf8: u32,
    x: f32,
    baseline_y: f32,
    offset_x: f32,
    offset_y: f32,
    advance: f32,
};

const Line = struct {
    glyph_start: u32,
    glyph_count: u32,
    segment_start: u32,
    segment_count: u32,
    utf8_start: u32,
    utf8_end: u32,
    width: f32,
    baseline_y: f32,
};

/// One visually contiguous grapheme cell. The logical offsets can run in
/// either direction, which preserves caret and selection behavior inside RTL
/// and mixed-direction lines without imposing logical ordering on painting.
const TextSegment = struct {
    utf8_start: u32,
    utf8_end: u32,
    x_start: f32,
    x_end: f32,
    line: u32,
};

const Layout = struct {
    hash: u64,
    text: []u8,
    font: handles.FontId,
    font_size: f32,
    scale_factor: f32,
    line_height: f32,
    letter_spacing: f32,
    maximum_width: f32,
    direction: api.TextDirection,
    wrap: api.WrapMode,
    maximum_lines: ?u32,
    glyphs: []PositionedGlyph,
    lines: []Line,
    segments: []TextSegment,
    size: geometry.Size,
    last_used_frame: u64,
    estimated_bytes: usize,

    fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.glyphs);
        allocator.free(self.lines);
        allocator.free(self.segments);
        self.* = undefined;
    }
};

const GlyphKey = struct {
    font: handles.FontId,
    glyph_id: u32,
    size_bits: u32,
    scale_bits: u32,
    foreground_bits: [4]u32,
};

const GlyphEntry = struct {
    tile: handles.AtlasTileId,
    page_texture: handles.TextureId,
    rect: atlas_mod.RectU16,
    size: geometry.Size,
    origin: geometry.Point,
    scale_factor: f32,
    last_used_frame: u64,
    mode: api.RasterMode,
};

const UsedGlyph = @import("../scene/retained.zig").GlyphUse;

const GlyphContext = struct {
    pub fn hash(_: @This(), key: GlyphKey) u64 {
        var hasher = std.hash.Wyhash.init(0x746578745f676c79);
        hasher.update(std.mem.asBytes(&key.font));
        hasher.update(std.mem.asBytes(&key.glyph_id));
        hasher.update(std.mem.asBytes(&key.size_bits));
        hasher.update(std.mem.asBytes(&key.scale_bits));
        hasher.update(std.mem.asBytes(&key.foreground_bits));
        return hasher.final();
    }

    pub fn eql(_: @This(), a: GlyphKey, b: GlyphKey) bool {
        return a.font.eql(b.font) and a.glyph_id == b.glyph_id and a.size_bits == b.size_bits and
            a.scale_bits == b.scale_bits and std.mem.eql(u32, &a.foreground_bits, &b.foreground_bits);
    }
};

pub const System = struct {
    const LayoutPool = handles.SlotPool(Layout, handles.TextLayoutId);
    const GlyphMap = std.HashMap(GlyphKey, GlyphEntry, GlyphContext, 80);

    allocator: std.mem.Allocator,
    backend: api.Backend,
    renderer: render.Renderer,
    resources: *resource.Manager,
    counters: *metrics.Counters,
    glyph_atlas: atlas_mod.Atlas,
    color_glyph_atlas: atlas_mod.Atlas,
    layouts: LayoutPool,
    layout_index: std.AutoHashMap(u64, handles.TextLayoutId),
    glyphs: GlyphMap,
    glyph_keys: std.AutoHashMap(UsedGlyph, GlyphKey),
    layout_budget: usize,
    layout_bytes: usize = 0,
    frame: u64 = 0,
    scale_factor: geometry.ScaleFactor,
    used_glyphs: std.ArrayList(UsedGlyph) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        backend: api.Backend,
        renderer: render.Renderer,
        resources: *resource.Manager,
        scale_factor: geometry.ScaleFactor,
        layout_budget: usize,
        atlas_budget: usize,
        atlas_tile_limit: usize,
        counters: *metrics.Counters,
    ) Error!System {
        const page_size: u16 = 1024;
        const page_bytes = @as(usize, page_size) * page_size;
        const color_page_bytes = page_bytes * 4;
        if (atlas_budget < page_bytes + color_page_bytes) return error.BudgetExceeded;
        const monochrome_budget = atlas_budget * 3 / 4;
        const color_budget = atlas_budget - monochrome_budget;
        const maximum_pages: u16 = @intCast(@max(1, @min(monochrome_budget / page_bytes, std.math.maxInt(u16))));
        const maximum_color_pages: u16 = @intCast(@max(1, @min(color_budget / color_page_bytes, std.math.maxInt(u16))));
        var glyph_atlas = try atlas_mod.Atlas.initWithLimit(
            allocator,
            resources,
            page_size,
            maximum_pages,
            .a8,
            atlas_tile_limit,
        );
        errdefer glyph_atlas.deinit();
        return .{
            .allocator = allocator,
            .backend = backend,
            .renderer = renderer,
            .resources = resources,
            .counters = counters,
            .glyph_atlas = glyph_atlas,
            .color_glyph_atlas = try atlas_mod.Atlas.initWithLimit(
                allocator,
                resources,
                page_size,
                maximum_color_pages,
                .rgba8_srgb,
                atlas_tile_limit,
            ),
            .layouts = LayoutPool.init(allocator),
            .layout_index = std.AutoHashMap(u64, handles.TextLayoutId).init(allocator),
            .glyphs = GlyphMap.init(allocator),
            .glyph_keys = std.AutoHashMap(UsedGlyph, GlyphKey).init(allocator),
            .layout_budget = layout_budget,
            .scale_factor = scale_factor,
        };
    }

    pub fn deinit(self: *System) void {
        var iterator = self.layouts.iterator();
        while (iterator.next()) |entry| entry.value.deinit(self.allocator);
        self.layouts.deinit();
        self.layout_index.deinit();
        self.glyphs.deinit();
        self.glyph_keys.deinit();
        self.glyph_atlas.deinit();
        self.color_glyph_atlas.deinit();
        self.used_glyphs.deinit(self.allocator);
        self.backend.deinit();
        self.* = undefined;
    }

    pub fn beginFrame(self: *System, frame: u64, scale_factor: geometry.ScaleFactor) void {
        self.frame = frame;
        self.scale_factor = scale_factor;
        self.glyph_atlas.collect(self.renderer.completedEpoch());
        self.color_glyph_atlas.collect(self.renderer.completedEpoch());
        self.resources.collect(self.renderer.completedEpoch());
        self.used_glyphs.clearRetainingCapacity();
    }

    pub fn measureProvider(self: *System) layout_engine.MeasureProvider {
        return .{ .context = self, .text_fn = measureOpaque, .custom_measure_fn = measureCustomOpaque };
    }

    pub fn painter(self: *System) scene_painter.TextPainter {
        return .{
            .context = self,
            .glyph_uses_fn = glyphUses,
            .reuse_glyphs_fn = reuseGlyphs,
            .paint_fn = paintOpaque,
            .paint_custom_fn = paintCustomOpaque,
            .measure_fn = measureCustomOpaque,
            .hit_test_fn = hitTestOpaque,
            .caret_rect_fn = caretRectOpaque,
            .selection_rects_fn = selectionRectsOpaque,
        };
    }

    fn glyphUses(raw: *anyopaque) []const UsedGlyph {
        const self: *System = @ptrCast(@alignCast(raw));
        return self.used_glyphs.items;
    }

    fn reuseGlyphs(raw: *anyopaque, glyphs: []const UsedGlyph) Error!bool {
        const self: *System = @ptrCast(@alignCast(raw));
        // An atlas page can survive while a rectangle within it is recycled.
        // Validate tile identities before replaying any cached sprite UVs.
        for (glyphs) |used| {
            const atlas = if (used.color) &self.color_glyph_atlas else &self.glyph_atlas;
            if (atlas.get(used.tile) == null) return false;
        }
        try self.used_glyphs.ensureUnusedCapacity(self.allocator, glyphs.len);
        for (glyphs) |used| {
            const atlas = if (used.color) &self.color_glyph_atlas else &self.glyph_atlas;
            try atlas.touch(used.tile, self.frame);
            self.used_glyphs.appendAssumeCapacity(used);
        }
        return true;
    }

    pub fn measure(
        self: *System,
        text_value: []const u8,
        style: compose_style.TextStyle,
        constraints: layout_style.Constraints,
    ) Error!layout_engine.TextMeasure {
        if (!validConstraints(constraints)) return error.InvalidLayout;
        const id = try self.layout(text_value, style, constraints.maximum.width);
        const value = self.layouts.get(id) orelse return error.InvalidHandle;
        value.last_used_frame = self.frame;
        return .{
            .size = constraints.constrain(value.size),
            .baseline = if (value.lines.len == 0) null else value.lines[0].baseline_y,
        };
    }

    pub fn prepare(
        self: *System,
        text_value: []const u8,
        style: compose_style.TextStyle,
        maximum_width: f32,
    ) Error!handles.TextLayoutId {
        const id = try self.layout(text_value, style, maximum_width);
        const value = self.layouts.get(id) orelse return error.InvalidHandle;
        for (value.glyphs) |glyph| _ = try self.ensureGlyph(glyph.font, glyph.glyph_id, value.font_size, style.color);
        return id;
    }

    pub fn prepareTree(self: *System, nodes: *const compose_store.Store, root: handles.NodeId) Error!void {
        const record = nodes.getConst(root) orelse return error.InvalidHandle;
        if (record.borrowedStyle().layout.display == .none) return;
        switch (record.kind) {
            .text => |value| _ = try self.prepare(value, record.borrowedStyle().text, record.layout.content_bounds.size.width),
            else => {},
        }
        for (record.children.items) |child| try self.prepareTree(nodes, child);
    }

    pub fn paint(
        self: *System,
        builder: *scene.Builder,
        text_value: []const u8,
        style: compose_style.TextStyle,
        bounds: geometry.Rect,
    ) Error!void {
        if (!validRect(bounds)) return error.InvalidLayout;
        const id = try self.prepare(text_value, style, bounds.size.width);
        const value = self.layouts.get(id) orelse return error.InvalidHandle;
        for (value.glyphs) |glyph| {
            const cached = try self.ensureGlyph(glyph.font, glyph.glyph_id, value.font_size, style.color);
            if (cached.size.width <= 0 or cached.size.height <= 0 or !cached.tile.isValid()) continue;
            const logical_size: geometry.Size = .{
                .width = cached.size.width / cached.scale_factor,
                .height = cached.size.height / cached.scale_factor,
            };
            const glyph_bounds: geometry.Rect = .{
                .origin = .{
                    .x = bounds.origin.x + glyph.x + glyph.offset_x + cached.origin.x / cached.scale_factor,
                    .y = bounds.origin.y + glyph.baseline_y - glyph.offset_y + cached.origin.y / cached.scale_factor,
                },
                .size = logical_size,
            };
            const color_glyph = cached.mode == .color;
            const active_atlas = if (color_glyph) &self.color_glyph_atlas else &self.glyph_atlas;
            const page_size: f32 = @floatFromInt(active_atlas.page_size);
            const sprite: scene_abi.Sprite = .{
                .bounds = glyph_bounds,
                .uv_bounds = geometry.Rect.fromXYWH(
                    @as(f32, @floatFromInt(cached.rect.x)) / page_size,
                    @as(f32, @floatFromInt(cached.rect.y)) / page_size,
                    @as(f32, @floatFromInt(cached.rect.width)) / page_size,
                    @as(f32, @floatFromInt(cached.rect.height)) / page_size,
                ),
                .color = if (color_glyph) .white else style.color,
                .texture = cached.page_texture.encode(),
                .tile_generation = cached.tile.generation,
                .format = @backingInt(if (color_glyph) scene_abi.TextureFormat.rgba8 else scene_abi.TextureFormat.a8),
            };
            if (color_glyph) try builder.colorSprite(sprite) else try builder.monochromeSprite(sprite);
            try self.used_glyphs.append(self.allocator, .{ .tile = cached.tile, .color = color_glyph });
        }
    }

    pub fn markSubmitted(self: *System, submission: render.SubmissionEpoch) Error!void {
        for (self.used_glyphs.items) |used| {
            const active_atlas = if (used.color) &self.color_glyph_atlas else &self.glyph_atlas;
            try active_atlas.markUsed(used.tile, self.frame, submission);
        }
    }

    pub fn deviceLost(self: *System) Error!void {
        self.glyphs.clearRetainingCapacity();
        self.glyph_keys.clearRetainingCapacity();
        try self.glyph_atlas.deviceLost();
        try self.color_glyph_atlas.deviceLost();
    }

    fn layout(self: *System, text_value: []const u8, style: compose_style.TextStyle, maximum_width: f32) Error!handles.TextLayoutId {
        try validateLayoutRequest(text_value, style, maximum_width);
        const hash = layoutHash(text_value, style, maximum_width, self.scale_factor.value);
        const font = try self.backend.resolveFont(.{
            .families = style.font_families,
            .weight = style.font_weight,
            .style = style.font_style,
            .stretch = style.font_stretch,
            .variations = style.font_variations,
        });
        if (self.layout_index.get(hash)) |id| {
            if (self.layouts.get(id)) |cached| {
                if (layoutMatches(cached, text_value, style, maximum_width, self.scale_factor.value, font)) {
                    cached.last_used_frame = self.frame;
                    self.counters.cache_hits +|= 1;
                    return id;
                }
            }
            _ = self.layout_index.remove(hash);
        }
        self.counters.cache_misses +|= 1;
        var result = try self.buildLayout(hash, text_value, style, maximum_width, font);
        errdefer result.deinit(self.allocator);
        try self.makeLayoutRoom(result.estimated_bytes);
        const id = try self.layouts.insert(result);
        errdefer _ = self.layouts.remove(id);
        try self.layout_index.put(hash, id);
        self.layout_bytes += result.estimated_bytes;
        return id;
    }

    fn buildLayout(
        self: *System,
        hash: u64,
        text_value: []const u8,
        style: compose_style.TextStyle,
        maximum_width: f32,
        font: handles.FontId,
    ) Error!Layout {
        const font_metrics = try self.backend.metrics(font, style.font_size);
        const line_height = style.line_height orelse font_metrics.ascent - font_metrics.descent + font_metrics.leading;
        if (!std.math.isFinite(line_height) or line_height <= 0) return error.PlatformFailure;
        var positioned: std.ArrayList(PositionedGlyph) = .empty;
        errdefer positioned.deinit(self.allocator);
        var lines: std.ArrayList(Line) = .empty;
        errdefer lines.deinit(self.allocator);
        var segments: std.ArrayList(TextSegment) = .empty;
        errdefer segments.deinit(self.allocator);
        var paragraph_start: usize = 0;
        while (paragraph_start <= text_value.len) {
            const newline = std.mem.indexOfScalarPos(u8, text_value, paragraph_start, '\n') orelse text_value.len;
            const paragraph = text_value[paragraph_start..newline];
            try self.appendWrappedParagraph(
                &positioned,
                &lines,
                &segments,
                paragraph,
                paragraph_start,
                font,
                style,
                maximum_width,
                line_height,
                font_metrics.ascent,
            );
            if (maximumReached(style.maximum_lines, lines.items.len)) break;
            if (newline == text_value.len) break;
            paragraph_start = newline + 1;
        }
        if (lines.items.len == 0) try lines.append(self.allocator, .{
            .glyph_start = 0,
            .glyph_count = 0,
            .segment_start = 0,
            .segment_count = 0,
            .utf8_start = 0,
            .utf8_end = 0,
            .width = 0,
            .baseline_y = font_metrics.ascent,
        });
        var width: f32 = 0;
        for (lines.items) |line| width = @max(width, line.width);
        const height = @max(line_height, @as(f32, @floatFromInt(lines.items.len)) * line_height);
        const glyph_slice = try positioned.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(glyph_slice);
        const line_slice = try lines.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(line_slice);
        const segment_slice = try segments.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(segment_slice);
        const owned_text = try self.allocator.dupe(u8, text_value);
        const estimated = owned_text.len + glyph_slice.len * @sizeOf(PositionedGlyph) + line_slice.len * @sizeOf(Line) +
            segment_slice.len * @sizeOf(TextSegment) + @sizeOf(Layout);
        return .{
            .hash = hash,
            .text = owned_text,
            .font = font,
            .font_size = style.font_size,
            .scale_factor = self.scale_factor.value,
            .line_height = line_height,
            .letter_spacing = style.letter_spacing,
            .maximum_width = maximum_width,
            .direction = style.direction,
            .wrap = style.wrap,
            .maximum_lines = style.maximum_lines,
            .glyphs = glyph_slice,
            .lines = line_slice,
            .segments = segment_slice,
            .size = .{ .width = width, .height = height },
            .last_used_frame = self.frame,
            .estimated_bytes = estimated,
        };
    }

    fn appendWrappedParagraph(
        self: *System,
        positioned: *std.ArrayList(PositionedGlyph),
        lines: *std.ArrayList(Line),
        segments: *std.ArrayList(TextSegment),
        paragraph: []const u8,
        paragraph_offset: usize,
        font: handles.FontId,
        style: compose_style.TextStyle,
        maximum_width: f32,
        line_height: f32,
        ascent: f32,
    ) Error!void {
        if (maximumReached(style.maximum_lines, lines.items.len)) return;
        if (paragraph.len == 0) {
            try lines.append(self.allocator, .{
                .glyph_start = @intCast(positioned.items.len),
                .glyph_count = 0,
                .segment_start = @intCast(segments.items.len),
                .segment_count = 0,
                .utf8_start = @intCast(paragraph_offset),
                .utf8_end = @intCast(paragraph_offset),
                .width = 0,
                .baseline_y = ascent + @as(f32, @floatFromInt(lines.items.len)) * line_height,
            });
            return;
        }
        if (style.wrap == .none or !std.math.isFinite(maximum_width)) {
            try self.appendShapedLine(positioned, lines, segments, paragraph, paragraph_offset, font, style, line_height, ascent);
            return;
        }

        var measured = try self.backend.shape(.{
            .text = paragraph,
            .font = font,
            .size = style.font_size,
            .scale_factor = self.scale_factor.value,
            .direction = style.direction,
        }, self.allocator);
        defer measured.deinit(self.allocator);
        var preferred: std.ArrayList(usize) = .empty;
        defer preferred.deinit(self.allocator);
        var grapheme_boundaries: std.ArrayList(usize) = .empty;
        defer grapheme_boundaries.deinit(self.allocator);
        var graphemes: unicode.GraphemeIterator = .{ .bytes = paragraph };
        var byte_offset: usize = 0;
        while (try graphemes.next()) |cluster| {
            byte_offset += cluster.len;
            try grapheme_boundaries.append(self.allocator, byte_offset);
        }
        if (style.wrap == .word) {
            var breaks = try unicode.analyzeLineBreaks(self.allocator, paragraph);
            defer breaks.deinit(self.allocator);
            for (breaks.boundaries) |boundary| if (boundary.utf8_offset != 0 and boundary.opportunity != .prohibited)
                try preferred.append(self.allocator, boundary.utf8_offset);
        } else {
            try preferred.appendSlice(self.allocator, grapheme_boundaries.items);
        }
        if (preferred.items.len == 0 or preferred.items[preferred.items.len - 1] != paragraph.len) try preferred.append(self.allocator, paragraph.len);

        var line_start: usize = 0;
        while (line_start < paragraph.len and !maximumReached(style.maximum_lines, lines.items.len)) {
            var line_end = chooseLineEnd(measured, line_start, preferred.items, maximum_width, style.letter_spacing);
            if (line_end == line_start)
                line_end = chooseLineEnd(measured, line_start, grapheme_boundaries.items, maximum_width, style.letter_spacing);
            if (line_end == line_start) line_end = firstBoundaryAfter(grapheme_boundaries.items, line_start) orelse paragraph.len;
            try self.appendShapedLine(positioned, lines, segments, paragraph[line_start..line_end], paragraph_offset + line_start, font, style, line_height, ascent);
            line_start = line_end;
        }
    }

    fn appendShapedLine(
        self: *System,
        output: *std.ArrayList(PositionedGlyph),
        lines: *std.ArrayList(Line),
        segments: *std.ArrayList(TextSegment),
        text: []const u8,
        text_offset: usize,
        font: handles.FontId,
        style: compose_style.TextStyle,
        line_height: f32,
        ascent: f32,
    ) Error!void {
        var shaped = try self.backend.shape(.{
            .text = text,
            .font = font,
            .size = style.font_size,
            .scale_factor = self.scale_factor.value,
            .direction = style.direction,
        }, self.allocator);
        defer shaped.deinit(self.allocator);
        const glyph_start = output.items.len;
        const segment_start = segments.items.len;
        const line_index: u32 = @intCast(lines.items.len);
        const baseline = ascent + @as(f32, @floatFromInt(lines.items.len)) * line_height;
        var x: f32 = 0;
        for (shaped.glyphs) |glyph| {
            if (glyph.font_index >= shaped.fonts.len) return error.InvalidFont;
            try output.append(self.allocator, .{
                .font = shaped.fonts[glyph.font_index],
                .glyph_id = glyph.glyph_id,
                .cluster_utf8 = @intCast(text_offset + glyph.cluster_utf8),
                .x = x,
                .baseline_y = baseline,
                .offset_x = glyph.offset_x,
                .offset_y = glyph.offset_y,
                .advance = glyph.advance_x + style.letter_spacing,
            });
            x += glyph.advance_x + style.letter_spacing;
        }
        try appendTextSegments(
            self.allocator,
            segments,
            text,
            text_offset,
            output.items[glyph_start..],
            shaped.direction,
            line_index,
        );
        try lines.append(self.allocator, .{
            .glyph_start = @intCast(glyph_start),
            .glyph_count = @intCast(output.items.len - glyph_start),
            .segment_start = @intCast(segment_start),
            .segment_count = @intCast(segments.items.len - segment_start),
            .utf8_start = @intCast(text_offset),
            .utf8_end = @intCast(text_offset + text.len),
            .width = x,
            .baseline_y = baseline,
        });
    }

    fn ensureGlyph(self: *System, font: handles.FontId, glyph_id: u32, size: f32, requested_foreground: geometry.Color) Error!GlyphEntry {
        const color_kind = try self.backend.colorGlyphKind(font, glyph_id);
        const foreground = if (color_kind == .foreground) canonicalColor(requested_foreground) else geometry.Color.white;
        const key: GlyphKey = .{
            .font = font,
            .glyph_id = glyph_id,
            .size_bits = @bitCast(size),
            .scale_bits = @bitCast(self.scale_factor.value),
            .foreground_bits = .{
                @bitCast(foreground.r),
                @bitCast(foreground.g),
                @bitCast(foreground.b),
                @bitCast(foreground.a),
            },
        };
        if (self.glyphs.getPtr(key)) |cached| {
            const active_atlas = if (cached.mode == .color) &self.color_glyph_atlas else &self.glyph_atlas;
            if (active_atlas.get(cached.tile) != null) {
                try active_atlas.touch(cached.tile, self.frame);
                cached.last_used_frame = self.frame;
                self.counters.cache_hits +|= 1;
                return cached.*;
            }
            _ = self.glyph_keys.remove(.{ .tile = cached.tile, .color = cached.mode == .color });
            _ = self.glyphs.remove(key);
        }
        self.counters.cache_misses +|= 1;
        const requested_mode: api.RasterMode = if (color_kind != .none) .color else .grayscale;
        var rasterized = try self.backend.rasterize(.{
            .font = font,
            .glyph_id = glyph_id,
            .size = size,
            .scale_factor = self.scale_factor.value,
            .mode = requested_mode,
            .foreground = foreground,
        }, self.allocator);
        defer rasterized.deinit(self.allocator);
        if (rasterized.size.width <= 0 or rasterized.size.height <= 0) return .{
            .tile = .invalid,
            .page_texture = .invalid,
            .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .size = .zero,
            .origin = rasterized.origin,
            .scale_factor = self.scale_factor.value,
            .last_used_frame = self.frame,
            .mode = rasterized.mode,
        };
        const width: u16 = @intFromFloat(@ceil(rasterized.size.width));
        const height: u16 = @intFromFloat(@ceil(rasterized.size.height));
        const color_glyph = rasterized.mode == .color;
        const active_atlas = if (color_glyph) &self.color_glyph_atlas else &self.glyph_atlas;
        try self.glyphs.ensureUnusedCapacity(1);
        try self.glyph_keys.ensureUnusedCapacity(1);
        var eviction = GlyphEviction{ .system = self, .color = color_glyph };
        const tile = try active_atlas.allocateNotifying(width, height, self.frame, self.renderer.completedEpoch(), .{
            .context = &eviction,
            .evicted = GlyphEviction.remove,
        });
        errdefer active_atlas.release(tile) catch {};
        const atlas_tile = active_atlas.get(tile) orelse return error.InvalidHandle;
        const page_texture = active_atlas.pageTexture(atlas_tile.page) orelse return error.InvalidHandle;
        try self.resources.realize(self.renderer, page_texture);
        try self.resources.upload(self.renderer, page_texture, .{
            .x = atlas_tile.rect.x,
            .y = atlas_tile.rect.y,
            .width = atlas_tile.rect.width,
            .height = atlas_tile.rect.height,
        }, rasterized.pixels, rasterized.stride);
        const entry: GlyphEntry = .{
            .tile = tile,
            .page_texture = page_texture,
            .rect = atlas_tile.rect,
            .size = rasterized.size,
            .origin = rasterized.origin,
            .scale_factor = self.scale_factor.value,
            .last_used_frame = self.frame,
            .mode = rasterized.mode,
        };
        self.glyphs.putAssumeCapacity(key, entry);
        self.glyph_keys.putAssumeCapacity(.{ .tile = tile, .color = color_glyph }, key);
        return entry;
    }

    const GlyphEviction = struct {
        system: *System,
        color: bool,

        fn remove(context: *anyopaque, tile: handles.AtlasTileId) void {
            const self: *GlyphEviction = @ptrCast(@alignCast(context));
            if (self.system.glyph_keys.fetchRemove(.{ .tile = tile, .color = self.color })) |removed|
                _ = self.system.glyphs.remove(removed.value);
        }
    };

    fn makeLayoutRoom(self: *System, requested: usize) Error!void {
        if (requested > self.layout_budget) return error.BudgetExceeded;
        while (self.layout_bytes > self.layout_budget - requested) {
            var oldest_id: ?handles.TextLayoutId = null;
            var oldest_frame: u64 = std.math.maxInt(u64);
            var iterator = self.layouts.iterator();
            while (iterator.next()) |entry| if (entry.value.last_used_frame < oldest_frame) {
                oldest_frame = entry.value.last_used_frame;
                oldest_id = entry.id;
            };
            const id = oldest_id orelse return error.BudgetExceeded;
            var removed = self.layouts.remove(id).?;
            _ = self.layout_index.remove(removed.hash);
            self.layout_bytes -|= removed.estimated_bytes;
            removed.deinit(self.allocator);
        }
    }

    fn measureOpaque(context: *anyopaque, value: []const u8, style: compose_style.TextStyle, constraints: layout_style.Constraints) Error!layout_engine.TextMeasure {
        const self: *System = @ptrCast(@alignCast(context));
        return self.measure(value, style, constraints);
    }

    fn measureCustomOpaque(context: *anyopaque, value: []const u8, style: compose_style.TextStyle, constraints: layout_style.Constraints) Error!geometry.Size {
        const self: *System = @ptrCast(@alignCast(context));
        return (try self.measure(value, style, constraints)).size;
    }

    fn paintOpaque(context: *anyopaque, builder: *scene.Builder, value: []const u8, style: compose_style.TextStyle, bounds: geometry.Rect) Error!void {
        const self: *System = @ptrCast(@alignCast(context));
        try self.paint(builder, value, style, bounds);
    }

    fn paintCustomOpaque(context: *anyopaque, scene_context: *anyopaque, value: []const u8, style: compose_style.TextStyle, bounds: geometry.Rect) Error!void {
        const self: *System = @ptrCast(@alignCast(context));
        const builder: *scene.Builder = @ptrCast(@alignCast(scene_context));
        try self.paint(builder, value, style, bounds);
    }

    fn hitTestOpaque(context: *anyopaque, value: []const u8, style: compose_style.TextStyle, maximum_width: f32, point: geometry.Point) Error!api.Hit {
        const self: *System = @ptrCast(@alignCast(context));
        return self.hitTest(value, style, maximum_width, point);
    }

    fn caretRectOpaque(context: *anyopaque, value: []const u8, style: compose_style.TextStyle, maximum_width: f32, utf8_offset: usize, affinity: api.CaretAffinity) Error!geometry.Rect {
        const self: *System = @ptrCast(@alignCast(context));
        return self.caretRect(value, style, maximum_width, utf8_offset, affinity);
    }

    fn selectionRectsOpaque(
        context: *anyopaque,
        value: []const u8,
        style: compose_style.TextStyle,
        maximum_width: f32,
        start: usize,
        end: usize,
        output: *std.ArrayList(geometry.Rect),
        allocator: std.mem.Allocator,
    ) Error!void {
        const self: *System = @ptrCast(@alignCast(context));
        try self.selectionRects(value, style, maximum_width, start, end, output, allocator);
    }

    /// Returns the closest legal grapheme caret in the cached shaped layout.
    /// `point` is local to the text bounds supplied to `paint`.
    pub fn hitTest(
        self: *System,
        text_value: []const u8,
        style: compose_style.TextStyle,
        maximum_width: f32,
        point: geometry.Point,
    ) Error!api.Hit {
        if (!validPoint(point)) return error.InvalidLayout;
        const id = try self.layout(text_value, style, maximum_width);
        const value = self.layouts.get(id) orelse return error.InvalidHandle;
        value.last_used_frame = self.frame;
        const line_index = lineForY(value, point.y);
        const line = value.lines[line_index];
        const segments = value.segments[line.segment_start..][0..line.segment_count];
        if (segments.len == 0) return .{ .utf8_offset = line.utf8_start, .line = @intCast(line_index) };

        var best = api.Hit{ .utf8_offset = line.utf8_start, .line = @intCast(line_index) };
        var best_distance = std.math.inf(f32);
        for (segments) |segment| {
            const candidates = [_]struct { x: f32, offset: u32, affinity: api.CaretAffinity }{
                .{ .x = segment.x_start, .offset = segment.utf8_start, .affinity = .downstream },
                .{ .x = segment.x_end, .offset = segment.utf8_end, .affinity = .upstream },
            };
            for (candidates) |candidate| {
                const distance = @abs(point.x - candidate.x);
                if (distance < best_distance) {
                    best_distance = distance;
                    best = .{ .utf8_offset = candidate.offset, .affinity = candidate.affinity, .line = @intCast(line_index) };
                }
            }
        }
        return best;
    }

    pub fn caretRect(
        self: *System,
        text_value: []const u8,
        style: compose_style.TextStyle,
        maximum_width: f32,
        utf8_offset: usize,
        affinity: api.CaretAffinity,
    ) Error!geometry.Rect {
        const id = try self.layout(text_value, style, maximum_width);
        const value = self.layouts.get(id) orelse return error.InvalidHandle;
        value.last_used_frame = self.frame;
        const requested: u32 = @intCast(@min(utf8_offset, text_value.len));
        var fallback_line: usize = 0;
        for (value.lines, 0..) |line, line_index| {
            if (requested < line.utf8_start or requested > line.utf8_end) continue;
            fallback_line = line_index;
            const segments = value.segments[line.segment_start..][0..line.segment_count];
            for (segments) |segment| {
                if (affinity == .downstream and segment.utf8_start == requested)
                    return caretFor(value, line_index, segment.x_start);
                if (affinity == .upstream and segment.utf8_end == requested)
                    return caretFor(value, line_index, segment.x_end);
            }
            for (segments) |segment| {
                if (segment.utf8_start == requested) return caretFor(value, line_index, segment.x_start);
                if (segment.utf8_end == requested) return caretFor(value, line_index, segment.x_end);
            }
        }
        const line = value.lines[fallback_line];
        return caretFor(value, fallback_line, if (requested <= line.utf8_start) 0 else line.width);
    }

    /// Appends visual selection rectangles into caller-owned storage so the
    /// steady-state frame can use its resettable scratch arena.
    pub fn selectionRects(
        self: *System,
        text_value: []const u8,
        style: compose_style.TextStyle,
        maximum_width: f32,
        selection_start: usize,
        selection_end: usize,
        output: *std.ArrayList(geometry.Rect),
        allocator: std.mem.Allocator,
    ) Error!void {
        const id = try self.layout(text_value, style, maximum_width);
        const value = self.layouts.get(id) orelse return error.InvalidHandle;
        value.last_used_frame = self.frame;
        const start: u32 = @intCast(@min(@min(selection_start, selection_end), text_value.len));
        const end: u32 = @intCast(@min(@max(selection_start, selection_end), text_value.len));
        if (start == end) return;
        for (value.lines, 0..) |line, line_index| {
            const segments = value.segments[line.segment_start..][0..line.segment_count];
            var active: ?geometry.Rect = null;
            for (segments) |segment| {
                const logical_start = @min(segment.utf8_start, segment.utf8_end);
                const logical_end = @max(segment.utf8_start, segment.utf8_end);
                const selected = logical_start < end and logical_end > start;
                const left = @min(segment.x_start, segment.x_end);
                const right = @max(segment.x_start, segment.x_end);
                if (selected) {
                    const rect = geometry.Rect.fromXYWH(left, @as(f32, @floatFromInt(line_index)) * value.line_height, right - left, value.line_height);
                    if (active) |*current| {
                        if (@abs(current.maxX() - rect.origin.x) <= 0.5) {
                            current.size.width = rect.maxX() - current.origin.x;
                        } else {
                            try output.append(allocator, current.*);
                            current.* = rect;
                        }
                    } else active = rect;
                } else if (active) |current| {
                    try output.append(allocator, current);
                    active = null;
                }
            }
            if (active) |current| try output.append(allocator, current);
        }
    }
};

fn maximumReached(maximum: ?u32, current: usize) bool {
    return if (maximum) |value| current >= @as(usize, value) else false;
}

fn appendTextSegments(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(TextSegment),
    line_text: []const u8,
    text_offset: usize,
    glyphs: []const PositionedGlyph,
    paragraph_direction: api.TextDirection,
    line_index: u32,
) Error!void {
    var glyph_index: usize = 0;
    while (glyph_index < glyphs.len) {
        const group_start = glyph_index;
        const cluster = glyphs[glyph_index].cluster_utf8;
        var x_end = glyphs[glyph_index].x + glyphs[glyph_index].advance;
        glyph_index += 1;
        while (glyph_index < glyphs.len and glyphs[glyph_index].cluster_utf8 == cluster) : (glyph_index += 1)
            x_end = @max(x_end, glyphs[glyph_index].x + glyphs[glyph_index].advance);
        const x_start = glyphs[group_start].x;
        var logical_end: u32 = @intCast(text_offset + line_text.len);
        for (glyphs) |candidate| {
            if (candidate.cluster_utf8 > cluster and candidate.cluster_utf8 < logical_end)
                logical_end = candidate.cluster_utf8;
        }
        if (logical_end <= cluster) continue;

        var rtl = paragraph_direction == .right_to_left;
        if (glyph_index < glyphs.len and glyphs[glyph_index].cluster_utf8 != cluster)
            rtl = glyphs[glyph_index].cluster_utf8 < cluster
        else if (group_start > 0 and glyphs[group_start - 1].cluster_utf8 != cluster)
            rtl = cluster < glyphs[group_start - 1].cluster_utf8;

        const local_start = @as(usize, cluster) - text_offset;
        const local_end = @as(usize, logical_end) - text_offset;
        if (local_start > local_end or local_end > line_text.len) return error.InvalidUtf8;
        var boundaries: std.ArrayList(usize) = .empty;
        defer boundaries.deinit(allocator);
        try boundaries.append(allocator, local_start);
        var iterator: unicode.GraphemeIterator = .{ .bytes = line_text[local_start..local_end] };
        var cursor = local_start;
        while (try iterator.next()) |cluster_bytes| {
            cursor += cluster_bytes.len;
            try boundaries.append(allocator, cursor);
        }
        if (boundaries.items[boundaries.items.len - 1] != local_end) try boundaries.append(allocator, local_end);
        const count = boundaries.items.len - 1;
        if (count == 0) continue;
        const advance = x_end - x_start;
        for (0..count) |index| {
            const first = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count));
            const second = @as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(count));
            try output.append(allocator, .{
                .utf8_start = @intCast(text_offset + boundaries.items[index]),
                .utf8_end = @intCast(text_offset + boundaries.items[index + 1]),
                .x_start = if (rtl) x_end - advance * first else x_start + advance * first,
                .x_end = if (rtl) x_end - advance * second else x_start + advance * second,
                .line = line_index,
            });
        }
    }
}

fn lineForY(value: *const Layout, y: f32) usize {
    if (value.lines.len <= 1) return 0;
    if (y <= 0) return 0;
    const last = value.lines.len - 1;
    const last_start = @as(f64, @floatFromInt(last)) * @as(f64, value.line_height);
    if (@as(f64, y) >= last_start) return last;
    return @intFromFloat(@floor(@as(f64, y) / @as(f64, value.line_height)));
}

fn caretFor(value: *const Layout, line_index: usize, x: f32) geometry.Rect {
    return geometry.Rect.fromXYWH(x, @as(f32, @floatFromInt(line_index)) * value.line_height, 1, value.line_height);
}

fn chooseLineEnd(
    shaped: api.ShapedRun,
    line_start: usize,
    candidates: []const usize,
    maximum_width: f32,
    letter_spacing: f32,
) usize {
    var selected = line_start;
    for (candidates) |candidate| {
        if (candidate <= line_start) continue;
        const width = shapedSpanWidth(shaped, line_start, candidate, letter_spacing);
        if (width > maximum_width and selected != line_start) break;
        if (width > maximum_width) break;
        selected = candidate;
    }
    return selected;
}

fn shapedSpanWidth(shaped: api.ShapedRun, start: usize, end: usize, letter_spacing: f32) f32 {
    var width: f32 = 0;
    for (shaped.glyphs) |glyph| {
        const cluster: usize = glyph.cluster_utf8;
        if (cluster >= start and cluster < end) width += glyph.advance_x + letter_spacing;
    }
    return width;
}

fn firstBoundaryAfter(boundaries: []const usize, start: usize) ?usize {
    for (boundaries) |boundary| if (boundary > start) return boundary;
    return null;
}

fn canonicalColor(value: geometry.Color) geometry.Color {
    return .{
        .r = finiteUnit(value.r),
        .g = finiteUnit(value.g),
        .b = finiteUnit(value.b),
        .a = finiteUnit(value.a),
    };
}

fn finiteUnit(value: f32) f32 {
    return if (std.math.isFinite(value)) std.math.clamp(value, 0, 1) else 0;
}

fn validateLayoutRequest(text_value: []const u8, style: compose_style.TextStyle, maximum_width: f32) Error!void {
    if (!std.unicode.utf8ValidateSlice(text_value)) return error.InvalidUtf8;
    if (text_value.len > std.math.maxInt(u32) or style.font_families.len > 64 or
        style.font_variations.len > 64) return error.BudgetExceeded;
    if (style.font_stretch == 0 or style.font_stretch > 1000 or
        !std.math.isFinite(style.font_size) or style.font_size <= 0 or style.font_size > 1_000_000 or
        !std.math.isFinite(style.letter_spacing) or @abs(style.letter_spacing) > 1_000_000 or
        std.math.isNan(maximum_width) or maximum_width < 0 or !validColor(style.color))
        return error.InvalidConfiguration;
    if (style.line_height) |line_height| if (!std.math.isFinite(line_height) or
        line_height <= 0 or line_height > 1_000_000) return error.InvalidConfiguration;
    if (style.maximum_lines) |maximum_lines| if (maximum_lines == 0) return error.InvalidConfiguration;
    var family_bytes: usize = 0;
    for (style.font_families) |family| {
        if (family.len == 0 or !std.unicode.utf8ValidateSlice(family) or
            std.mem.indexOfScalar(u8, family, 0) != null) return error.InvalidConfiguration;
        family_bytes = std.math.add(usize, family_bytes, family.len) catch return error.BudgetExceeded;
        if (family_bytes > 4096) return error.BudgetExceeded;
    }
    for (style.font_variations) |variation| if (!std.math.isFinite(variation.value))
        return error.InvalidConfiguration;
}

fn validConstraints(value: layout_style.Constraints) bool {
    return validSize(value.minimum) and !std.math.isNan(value.maximum.width) and
        !std.math.isNan(value.maximum.height) and value.maximum.width >= 0 and
        value.maximum.height >= 0 and value.minimum.width <= value.maximum.width and
        value.minimum.height <= value.maximum.height;
}

fn validPoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}

fn validSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and
        value.width >= 0 and value.height >= 0;
}

fn validRect(value: geometry.Rect) bool {
    return validPoint(value.origin) and validSize(value.size);
}

fn validColor(value: geometry.Color) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and
        std.math.isFinite(value.b) and std.math.isFinite(value.a) and
        value.a >= 0 and value.a <= 1;
}

fn layoutHash(text_value: []const u8, style: compose_style.TextStyle, maximum_width: f32, scale_factor: f32) u64 {
    var hasher = std.hash.Wyhash.init(0x7a696775695f7478);
    hasher.update(text_value);
    for (style.font_families) |family| {
        hasher.update(family);
        hasher.update(&.{0});
    }
    const weight: u16 = @backingInt(style.font_weight);
    const font_style: u8 = @backingInt(style.font_style);
    const direction: u8 = @backingInt(style.direction);
    const wrap: u8 = @backingInt(style.wrap);
    hasher.update(std.mem.asBytes(&weight));
    hasher.update(std.mem.asBytes(&style.font_stretch));
    for (style.font_variations) |variation| {
        hasher.update(&variation.tag);
        hasher.update(std.mem.asBytes(&variation.value));
    }
    hasher.update(&.{ font_style, direction, wrap });
    hasher.update(std.mem.asBytes(&style.font_size));
    hasher.update(std.mem.asBytes(&style.line_height));
    hasher.update(std.mem.asBytes(&style.letter_spacing));
    hasher.update(std.mem.asBytes(&style.maximum_lines));
    hasher.update(std.mem.asBytes(&maximum_width));
    hasher.update(std.mem.asBytes(&scale_factor));
    return hasher.final();
}

fn layoutMatches(
    value: *const Layout,
    text_value: []const u8,
    style: compose_style.TextStyle,
    maximum_width: f32,
    scale_factor: f32,
    font: handles.FontId,
) bool {
    return value.font.eql(font) and std.mem.eql(u8, value.text, text_value) and value.font_size == style.font_size and value.line_height == (style.line_height orelse value.line_height) and
        value.scale_factor == scale_factor and value.letter_spacing == style.letter_spacing and value.maximum_width == maximum_width and value.direction == style.direction and
        value.wrap == style.wrap and value.maximum_lines == style.maximum_lines;
}

