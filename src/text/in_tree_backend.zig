const std = @import("std");
const builtin = @import("builtin");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const api = @import("api.zig");
const opentype = @import("opentype.zig");
const ot_layout = @import("opentype_layout.zig");
const shaper = @import("opentype_shaper.zig");
const raster = @import("truetype_raster.zig");
const color_font = @import("color_font.zig");
const unicode = @import("unicode.zig");
const variation = @import("opentype_variation.zig");

const maximum_family_bytes = 4096;

pub const FontStorage = enum { resident, mapped };

pub const FontSource = struct {
    bytes: []const u8,
    storage: FontStorage,
    context: ?*anyopaque = null,
    deinit_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) void,

    pub fn resident(bytes: []u8) FontSource {
        return .{
            .bytes = bytes,
            .storage = .resident,
            .deinit_fn = deinitResidentSource,
        };
    }

    pub fn deinit(self: *FontSource, allocator: std.mem.Allocator) void {
        self.deinit_fn(self.context, allocator, self.bytes);
        self.* = undefined;
    }
};

fn deinitResidentSource(_: ?*anyopaque, allocator: std.mem.Allocator, bytes: []const u8) void {
    allocator.free(@constCast(bytes));
}

pub const VariationAxes = packed struct(u8) {
    weight: bool = false,
    width: bool = false,
    italic: bool = false,
    slant: bool = false,
    _reserved: u4 = 0,
};

const FaceData = struct {
    source: FontSource,
    font: opentype.Font,
    family: []u8,
    axes: VariationAxes,
};

const FontEntry = struct {
    face: *FaceData,
    font: opentype.Font,
    coordinates: []i16,
    weight: api.FontWeight,
    style: api.FontStyle,
    stretch: u16,
};

pub const FileLoader = struct {
    context: ?*anyopaque = null,
    storage: FontStorage,
    load_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, usize) Error!FontSource,

    pub fn load(self: FileLoader, allocator: std.mem.Allocator, path: []const u8, maximum_bytes: usize) Error!FontSource {
        var source = try self.load_fn(self.context, allocator, path, maximum_bytes);
        errdefer source.deinit(allocator);
        if (source.storage != self.storage or source.bytes.len == 0 or source.bytes.len > maximum_bytes)
            return error.BudgetExceeded;
        return source;
    }
};

const CatalogEntry = struct {
    path: []u8,
    face_index: u32,
    family: []u8,
    weight: api.FontWeight,
    style: api.FontStyle,
    stretch: u16,
    axes: VariationAxes,
    coverage: opentype.Coverage,
    loader: FileLoader,
    loaded: handles.FontId = .invalid,
    face: ?*FaceData = null,

    fn deinit(self: *CatalogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.family);
        self.* = undefined;
    }
};

const FallbackMissKey = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub const Backend = struct {
    const Pool = handles.SlotPool(FontEntry, handles.FontId);

    allocator: std.mem.Allocator,
    fonts: Pool,
    faces: std.ArrayList(*FaceData) = .empty,
    catalog: std.ArrayList(CatalogEntry) = .empty,
    default_font: handles.FontId = .invalid,
    default_catalog: ?usize = null,
    loaded_font_bytes: usize = 0,
    mapped_font_bytes: usize = 0,
    maximum_font_bytes: usize,
    maximum_mapped_font_bytes: usize,
    maximum_font_instances: usize,
    catalog_bytes: usize = 0,
    maximum_catalog_entries: usize,
    maximum_catalog_bytes: usize,
    fallback_misses: std.AutoHashMap(FallbackMissKey, void),
    maximum_fallback_misses: usize,

    pub fn create(allocator: std.mem.Allocator) Error!api.Backend {
        return (try createInstance(
            allocator,
            256 * 1024 * 1024,
            1024 * 1024 * 1024,
            65_536,
            32 * 1024,
            32 * 1024 * 1024,
        )).interface();
    }

    pub fn createInstance(
        allocator: std.mem.Allocator,
        maximum_font_bytes: usize,
        maximum_mapped_font_bytes: usize,
        maximum_font_instances: usize,
        maximum_catalog_entries: usize,
        maximum_catalog_bytes: usize,
    ) Error!*Backend {
        if (maximum_font_bytes == 0 or maximum_mapped_font_bytes == 0 or
            maximum_font_instances == 0 or maximum_font_instances > std.math.maxInt(u32) or
            maximum_catalog_entries == 0 or
            maximum_catalog_entries > std.math.maxInt(u32) or maximum_catalog_bytes == 0)
            return error.InvalidConfiguration;
        const self = try allocator.create(Backend);
        self.* = .{
            .allocator = allocator,
            .fonts = Pool.init(allocator),
            .maximum_font_bytes = maximum_font_bytes,
            .maximum_mapped_font_bytes = maximum_mapped_font_bytes,
            .maximum_font_instances = maximum_font_instances,
            .maximum_catalog_entries = maximum_catalog_entries,
            .maximum_catalog_bytes = maximum_catalog_bytes,
            .fallback_misses = std.AutoHashMap(FallbackMissKey, void).init(allocator),
            .maximum_fallback_misses = @min(maximum_catalog_entries *| 64, 262_144),
        };
        return self;
    }

    pub fn interface(self: *Backend) api.Backend {
        return .{
            .context = self,
            .resolve_font_fn = resolveFontOpaque,
            .metrics_fn = metricsOpaque,
            .shape_fn = shapeOpaque,
            .color_glyph_fn = colorGlyphOpaque,
            .rasterize_fn = rasterizeOpaque,
            .deinit_fn = deinitOpaque,
        };
    }

    pub fn addCatalogFile(
        self: *Backend,
        path: []const u8,
        face_index: u32,
        family: []const u8,
        weight: api.FontWeight,
        font_style: api.FontStyle,
        stretch: u16,
        axes: VariationAxes,
        coverage: opentype.Coverage,
        loader: FileLoader,
    ) Error!usize {
        if (path.len == 0 or family.len == 0 or !std.unicode.utf8ValidateSlice(family) or
            std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, family, 0) != null)
            return error.InvalidConfiguration;
        const retained = std.math.add(usize, path.len, family.len) catch return error.BudgetExceeded;
        if (!self.catalogHasCapacity(path.len, family.len)) return error.BudgetExceeded;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_family = try self.allocator.dupe(u8, family);
        errdefer self.allocator.free(owned_family);
        try self.catalog.append(self.allocator, .{
            .path = owned_path,
            .face_index = face_index,
            .family = owned_family,
            .weight = weight,
            .style = font_style,
            .stretch = stretch,
            .axes = axes,
            .coverage = coverage,
            .loader = loader,
        });
        self.catalog_bytes += retained;
        return self.catalog.items.len - 1;
    }

    pub fn setDefaultCatalog(self: *Backend, index: usize) Error!void {
        if (index >= self.catalog.items.len) return error.InvalidHandle;
        self.default_catalog = index;
        if (self.catalog.items[index].loaded.isValid()) self.default_font = self.catalog.items[index].loaded;
    }

    pub fn catalogCount(self: *const Backend) usize {
        return self.catalog.items.len;
    }

    pub fn catalogHasCapacity(self: *const Backend, path_bytes: usize, family_bytes: usize) bool {
        if (self.catalog.items.len >= self.maximum_catalog_entries) return false;
        const retained = std.math.add(usize, path_bytes, family_bytes) catch return false;
        return retained <= self.maximum_catalog_bytes -| self.catalog_bytes;
    }

    pub fn maximumCatalogBytes(self: *const Backend) usize {
        return self.maximum_catalog_bytes;
    }

    pub fn maximumFontBytes(self: *const Backend) usize {
        return self.maximum_font_bytes;
    }

    pub fn maximumMappedFontBytes(self: *const Backend) usize {
        return self.maximum_mapped_font_bytes;
    }

    pub fn registerCopy(self: *Backend, bytes: []const u8, face_index: u32, weight: api.FontWeight, font_style: api.FontStyle) Error!handles.FontId {
        if (bytes.len > self.maximum_font_bytes -| self.loaded_font_bytes) return error.BudgetExceeded;
        return self.registerOwned(try self.allocator.dupe(u8, bytes), face_index, weight, font_style);
    }

    pub fn registerOwned(self: *Backend, bytes: []u8, face_index: u32, weight: api.FontWeight, font_style: api.FontStyle) Error!handles.FontId {
        return self.registerSourceInternal(FontSource.resident(bytes), face_index, weight, font_style, true);
    }

    fn registerSourceInternal(self: *Backend, source: FontSource, face_index: u32, weight: api.FontWeight, font_style: api.FontStyle, make_default: bool) Error!handles.FontId {
        const face = try self.addSource(source, face_index);
        errdefer self.rollbackLastFace(face);
        const families = [_][]const u8{face.family};
        const id = try self.instanceForFace(face, .{
            .families = &families,
            .weight = weight,
            .style = font_style,
            .stretch = 100,
        });
        if (make_default and !self.default_font.isValid()) self.default_font = id;
        return id;
    }

    fn addSource(self: *Backend, initial_source: FontSource, face_index: u32) Error!*FaceData {
        var source = initial_source;
        errdefer source.deinit(self.allocator);
        const available = switch (source.storage) {
            .resident => self.maximum_font_bytes -| self.loaded_font_bytes,
            .mapped => self.maximum_mapped_font_bytes -| self.mapped_font_bytes,
        };
        if (source.bytes.len > available) return error.BudgetExceeded;
        const font = try opentype.Font.init(source.bytes, face_index);
        const family = try font.familyName(self.allocator);
        errdefer self.allocator.free(family);
        if (family.len == 0 or family.len > maximum_family_bytes or !std.unicode.utf8ValidateSlice(family) or
            std.mem.indexOfScalar(u8, family, 0) != null) return error.InvalidFont;
        const face = try self.allocator.create(FaceData);
        errdefer self.allocator.destroy(face);
        face.* = .{
            .source = source,
            .font = font,
            .family = family,
            .axes = axesForFont(font),
        };
        try self.faces.append(self.allocator, face);
        switch (source.storage) {
            .resident => self.loaded_font_bytes += source.bytes.len,
            .mapped => self.mapped_font_bytes += source.bytes.len,
        }
        return face;
    }

    fn rollbackLastFace(self: *Backend, face: *FaceData) void {
        if (self.faces.items.len == 0 or self.faces.items[self.faces.items.len - 1] != face) return;
        _ = self.faces.pop();
        switch (face.source.storage) {
            .resident => self.loaded_font_bytes -|= face.source.bytes.len,
            .mapped => self.mapped_font_bytes -|= face.source.bytes.len,
        }
        self.allocator.free(face.family);
        face.source.deinit(self.allocator);
        self.allocator.destroy(face);
    }

    pub fn setDefault(self: *Backend, id: handles.FontId) Error!void {
        if (!self.fonts.contains(id)) return error.InvalidHandle;
        self.default_font = id;
    }

    fn resolveFont(self: *Backend, descriptor: api.FontDescriptor) Error!handles.FontId {
        if (descriptor.stretch == 0 or descriptor.stretch > 1000) return error.InvalidConfiguration;
        for (descriptor.families) |requested| {
            if (requested.len == 0 or !std.unicode.utf8ValidateSlice(requested)) return error.InvalidConfiguration;
            if (std.ascii.eqlIgnoreCase(requested, "system-ui")) {
                if (self.default_catalog) |index| return self.loadCatalog(index, descriptor);
                continue;
            }
            var catalog_best: ?usize = null;
            var best_score: u32 = std.math.maxInt(u32);
            for (self.catalog.items, 0..) |catalog, index| {
                if (!std.ascii.eqlIgnoreCase(requested, catalog.family)) continue;
                const score = catalogMatchScore(descriptor, catalog);
                if (score < best_score) {
                    catalog_best = index;
                    best_score = score;
                }
            }
            if (catalog_best) |index| return self.loadCatalog(index, descriptor);

            var loaded_best: ?handles.FontId = null;
            var loaded_score: u32 = std.math.maxInt(u32);
            var iterator = self.fonts.iterator();
            while (iterator.next()) |entry| {
                if (!std.ascii.eqlIgnoreCase(requested, entry.value.face.family)) continue;
                const score = instanceMatchScore(descriptor, entry.value.*);
                if (score < loaded_score) {
                    loaded_best = entry.id;
                    loaded_score = score;
                }
            }
            if (loaded_best) |id| {
                const entry = self.fonts.get(id).?;
                if (entry.face.font.isVariable()) return self.instanceForFace(entry.face, descriptor);
                return id;
            }
        }

        for (descriptor.families) |requested| {
            var catalog_best: ?usize = null;
            var best_score: u32 = std.math.maxInt(u32);
            for (self.catalog.items, 0..) |catalog, index| {
                const family_score = genericFamilyScore(requested, catalog.family) orelse continue;
                const score = family_score +| catalogMatchScore(descriptor, catalog);
                if (score < best_score) {
                    catalog_best = index;
                    best_score = score;
                }
            }
            if (catalog_best) |index| return self.loadCatalog(index, descriptor);
        }
        if (self.default_catalog) |index| return self.loadCatalog(index, descriptor);
        if (self.default_font.isValid()) return self.default_font;
        if (self.catalog.items.len != 0) return self.loadCatalog(0, descriptor);
        return error.TextUnavailable;
    }

    fn loadCatalog(self: *Backend, index: usize, descriptor: api.FontDescriptor) Error!handles.FontId {
        if (index >= self.catalog.items.len) return error.InvalidHandle;
        const catalog = &self.catalog.items[index];
        var newly_loaded = false;
        const face = catalog.face orelse blk: {
            const maximum_bytes = switch (catalog.loader.storage) {
                .resident => self.maximum_font_bytes -| self.loaded_font_bytes,
                .mapped => self.maximum_mapped_font_bytes -| self.mapped_font_bytes,
            };
            const source = try catalog.loader.load(self.allocator, catalog.path, maximum_bytes);
            const loaded_face = try self.addSource(source, catalog.face_index);
            newly_loaded = true;
            break :blk loaded_face;
        };
        errdefer if (newly_loaded) self.rollbackLastFace(face);
        const id = try self.instanceForFace(face, descriptor);
        if (newly_loaded) catalog.face = face;
        if (!catalog.loaded.isValid()) catalog.loaded = id;
        if (self.default_catalog == index) self.default_font = id;
        return id;
    }

    fn instanceForFace(self: *Backend, face: *FaceData, descriptor: api.FontDescriptor) Error!handles.FontId {
        var settings: std.ArrayList(variation.Setting) = .empty;
        defer settings.deinit(self.allocator);
        try settings.append(self.allocator, .{ .tag = "wght".*, .value = @floatFromInt(@backingInt(descriptor.weight)) });
        try settings.append(self.allocator, .{ .tag = "wdth".*, .value = @floatFromInt(descriptor.stretch) });
        const italic_value: f32 = if (descriptor.style == .italic or (descriptor.style == .oblique and !face.axes.slant)) 1 else 0;
        const slant_value: f32 = if (descriptor.style == .oblique or (descriptor.style == .italic and !face.axes.italic and face.axes.slant)) -12 else 0;
        try settings.append(self.allocator, .{ .tag = "ital".*, .value = italic_value });
        try settings.append(self.allocator, .{ .tag = "slnt".*, .value = slant_value });
        if (face.font.optionalTable("fvar".*)) |fvar| for (descriptor.variations) |setting| {
            if (!variation.hasAxis(fvar, setting.tag)) return error.Unsupported;
        } else if (descriptor.variations.len != 0) return error.Unsupported;
        try settings.appendSlice(self.allocator, descriptor.variations);

        const coordinates = if (face.font.optionalTable("fvar".*)) |fvar|
            try variation.normalize(self.allocator, fvar, face.font.optionalTable("avar".*), settings.items)
        else blk: {
            if (descriptor.variations.len != 0) return error.Unsupported;
            break :blk try self.allocator.alloc(i16, 0);
        };
        errdefer self.allocator.free(coordinates);
        var iterator = self.fonts.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.face != face or !variation.coordinatesEqual(entry.value.coordinates, coordinates)) continue;
            self.allocator.free(coordinates);
            return entry.id;
        }
        if (self.fonts.live_count >= self.maximum_font_instances) return error.BudgetExceeded;
        const font = try face.font.withVariation(coordinates);
        return self.fonts.insert(.{
            .face = face,
            .font = font,
            .coordinates = coordinates,
            .weight = descriptor.weight,
            .style = descriptor.style,
            .stretch = descriptor.stretch,
        });
    }

    fn metrics(self: *Backend, id: handles.FontId, size: f32) Error!api.FontMetrics {
        if (!std.math.isFinite(size) or size <= 0 or size > 1_000_000) return error.InvalidConfiguration;
        const entry = self.fonts.get(id) orelse return error.InvalidHandle;
        const units = try entry.font.unitsPerEm();
        const scale = size / @as(f32, @floatFromInt(units));
        const ascent = (try entry.font.ascender()) * scale;
        const descent = (try entry.font.descender()) * scale;
        const leading = (try entry.font.lineGap()) * scale;
        const x_height = (try entry.font.xHeight() orelse (try entry.font.ascender()) * 0.52) * scale;
        const cap_height = (try entry.font.capHeight() orelse (try entry.font.ascender()) * 0.72) * scale;
        const underline_position = (entry.font.underlinePosition() catch (try entry.font.descender()) * 0.5) * scale;
        const underline_thickness = @max(1, (entry.font.underlineThickness() catch @as(f32, @floatFromInt(units)) / 16) * scale);
        return .{
            .ascent = ascent,
            .descent = descent,
            .leading = leading,
            .x_height = x_height,
            .cap_height = cap_height,
            .underline_position = underline_position,
            .underline_thickness = underline_thickness,
        };
    }

    fn shape(self: *Backend, request: api.ShapeRequest, allocator: std.mem.Allocator) Error!api.ShapedRun {
        _ = self.fonts.get(request.font) orelse return error.InvalidHandle;
        if (!std.math.isFinite(request.size) or request.size <= 0 or request.size > 1_000_000 or
            !std.math.isFinite(request.scale_factor) or request.scale_factor <= 0 or request.scale_factor > 64) return error.InvalidConfiguration;
        if (request.text.len > ot_layout.maximum_buffer_glyphs * 4) return error.BudgetExceeded;
        var scalars: std.ArrayList(ScalarRecord) = .empty;
        defer scalars.deinit(allocator);
        var scalar_values: std.ArrayList(u21) = .empty;
        defer scalar_values.deinit(allocator);
        var iterator: unicode.Iterator = .{ .bytes = request.text };
        while (try iterator.next()) |scalar| {
            try scalars.append(allocator, .{
                .scalar = scalar.value,
                .cluster_utf8 = @intCast(scalar.start),
                .font = request.font,
                .script = unicode.script(scalar.value),
            });
            try scalar_values.append(allocator, scalar.value);
        }
        resolveScripts(scalars.items);
        try self.assignFallbackFonts(request.font, request.text, scalars.items);
        const requested_rtl: ?bool = switch (request.direction) {
            .auto => null,
            .left_to_right => false,
            .right_to_left => true,
        };
        var bidi_result = try unicode.resolveBidi(allocator, scalar_values.items, requested_rtl);
        defer bidi_result.deinit(allocator);
        var runs: std.ArrayList(ShapeRun) = .empty;
        defer runs.deinit(allocator);
        const run_for_scalar = try allocator.alloc(usize, scalars.items.len);
        defer allocator.free(run_for_scalar);
        try buildRuns(allocator, scalars.items, bidi_result.levels, &runs, run_for_scalar);

        var visual_runs: std.ArrayList(usize) = .empty;
        defer visual_runs.deinit(allocator);
        var last_run: ?usize = null;
        for (bidi_result.visual_to_logical) |logical| {
            const run_index = run_for_scalar[logical];
            if (last_run == null or last_run.? != run_index) {
                try visual_runs.append(allocator, run_index);
                last_run = run_index;
            }
        }

        var output_glyphs: std.ArrayList(api.Glyph) = .empty;
        errdefer output_glyphs.deinit(allocator);
        var output_fonts: std.ArrayList(handles.FontId) = .empty;
        errdefer output_fonts.deinit(allocator);
        var width: f32 = 0;
        var combined_metrics = try self.metrics(request.font, request.size);
        for (visual_runs.items) |run_index| {
            const run = runs.items[run_index];
            const entry = self.fonts.get(run.font) orelse return error.InvalidHandle;
            const inputs = try allocator.alloc(shaper.Input, run.end - run.start);
            defer allocator.free(inputs);
            for (scalars.items[run.start..run.end], 0..) |scalar, input_index| inputs[input_index] = .{
                .scalar = scalar.scalar,
                .cluster_utf8 = scalar.cluster_utf8,
            };
            var shaped = try shaper.shape(allocator, entry.font, inputs, .{
                .script = ot_layout.scriptTag(run.script),
                .language = ot_layout.languageTag(request.locale),
                .direction = if (run.level & 1 == 0) .left_to_right else .right_to_left,
                .ppem = @intFromFloat(std.math.clamp(@round(request.size * request.scale_factor), 1, std.math.maxInt(u16))),
                .features = request.features,
            });
            defer shaped.deinit(allocator);
            const units = try entry.font.unitsPerEm();
            if (units == 0) return error.InvalidFont;
            const scale = request.size / @as(f32, @floatFromInt(units));
            const font_index = try appendUniqueFont(allocator, &output_fonts, run.font);
            for (shaped.glyphs.items) |glyph| {
                if (output_glyphs.items.len == ot_layout.maximum_buffer_glyphs) return error.BudgetExceeded;
                const advance_x = @as(f32, @floatFromInt(glyph.advance_x)) * scale;
                try output_glyphs.append(allocator, .{
                    .glyph_id = glyph.id,
                    .cluster_utf8 = glyph.cluster_utf8,
                    .advance_x = advance_x,
                    .advance_y = @as(f32, @floatFromInt(glyph.advance_y)) * scale,
                    .offset_x = @as(f32, @floatFromInt(glyph.offset_x)) * scale,
                    .offset_y = @as(f32, @floatFromInt(glyph.offset_y)) * scale,
                    .font_index = font_index,
                });
                width += advance_x;
            }
            const run_metrics = try self.metrics(run.font, request.size);
            combined_metrics.ascent = @max(combined_metrics.ascent, run_metrics.ascent);
            combined_metrics.descent = @min(combined_metrics.descent, run_metrics.descent);
            combined_metrics.leading = @max(combined_metrics.leading, run_metrics.leading);
            combined_metrics.x_height = @max(combined_metrics.x_height, run_metrics.x_height);
            combined_metrics.cap_height = @max(combined_metrics.cap_height, run_metrics.cap_height);
        }
        if (output_fonts.items.len == 0) try output_fonts.append(allocator, request.font);
        const owned_glyphs = try output_glyphs.toOwnedSlice(allocator);
        errdefer allocator.free(owned_glyphs);
        const owned_fonts = try output_fonts.toOwnedSlice(allocator);
        return .{
            .text_utf8 = request.text,
            .glyphs = owned_glyphs,
            .fonts = owned_fonts,
            .direction = if (bidi_result.paragraph_level & 1 == 0) .left_to_right else .right_to_left,
            .width = width,
            .metrics = combined_metrics,
        };
    }

    fn assignFallbackFonts(self: *Backend, primary: handles.FontId, text: []const u8, scalars: []ScalarRecord) Error!void {
        var graphemes: unicode.GraphemeIterator = .{ .bytes = text };
        var scalar_start: usize = 0;
        while (try graphemes.next()) |cluster| {
            const cluster_start = @intFromPtr(cluster.ptr) - @intFromPtr(text.ptr);
            const cluster_end = cluster_start + cluster.len;
            while (scalar_start < scalars.len and scalars[scalar_start].cluster_utf8 < cluster_start) scalar_start += 1;
            var scalar_end = scalar_start;
            while (scalar_end < scalars.len and scalars[scalar_end].cluster_utf8 < cluster_end) scalar_end += 1;
            if (scalar_start == scalar_end) continue;
            const selected = try self.findClusterFont(primary, scalars[scalar_start..scalar_end]);
            for (scalars[scalar_start..scalar_end]) |*scalar| scalar.font = selected;
            scalar_start = scalar_end;
        }
    }

    fn findClusterFont(self: *Backend, primary: handles.FontId, scalars: []const ScalarRecord) Error!handles.FontId {
        if (try self.fontCovers(primary, scalars)) return primary;
        const primary_entry = self.fonts.get(primary) orelse return error.InvalidHandle;
        const descriptor: api.FontDescriptor = .{
            .families = &.{},
            .weight = primary_entry.weight,
            .style = primary_entry.style,
            .stretch = primary_entry.stretch,
        };
        var iterator = self.fonts.iterator();
        while (iterator.next()) |entry| if (!entry.id.eql(primary) and try covers(entry.value.font, scalars)) return entry.id;
        var catalog_index: usize = 0;
        while (catalog_index < self.catalog.items.len) : (catalog_index += 1) {
            const catalog = &self.catalog.items[catalog_index];
            if (isLastResortFamily(catalog.family)) continue;
            if (!coverageMayContainAll(&catalog.coverage, scalars)) continue;
            const miss_key = fallbackMissKey(catalog_index, scalars);
            if (self.fallback_misses.contains(miss_key)) continue;
            const id = self.loadCatalogForFallback(catalog_index, descriptor, scalars) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            } orelse continue;
            if (!id.eql(primary)) return id;
        }
        return primary;
    }

    /// Probe a catalog face against the exact scalar cluster before retaining
    /// its mapped source. The coarse catalog coverage bitmap is intentionally
    /// conservative and can produce many false positives for symbol blocks;
    /// retaining every rejected probe would exhaust the mapped-font budget
    /// while resolving one missing glyph.
    fn loadCatalogForFallback(
        self: *Backend,
        index: usize,
        descriptor: api.FontDescriptor,
        scalars: []const ScalarRecord,
    ) Error!?handles.FontId {
        if (index >= self.catalog.items.len) return error.InvalidHandle;
        const catalog = &self.catalog.items[index];
        if (catalog.face) |face| {
            if (!try covers(face.font, scalars)) {
                try self.rememberFallbackMiss(index, scalars);
                return null;
            }
            const id = try self.instanceForFace(face, descriptor);
            if (!catalog.loaded.isValid()) catalog.loaded = id;
            return id;
        }

        const maximum_bytes = switch (catalog.loader.storage) {
            .resident => self.maximum_font_bytes -| self.loaded_font_bytes,
            .mapped => self.maximum_mapped_font_bytes -| self.mapped_font_bytes,
        };
        var source = catalog.loader.load(self.allocator, catalog.path, maximum_bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        var source_transferred = false;
        defer if (!source_transferred) source.deinit(self.allocator);

        const candidate = opentype.Font.init(source.bytes, catalog.face_index) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (!try covers(candidate, scalars)) {
            try self.rememberFallbackMiss(index, scalars);
            return null;
        }

        // addSource owns and cleans up the source on its own error path. Mark
        // the value transferred before the call so our defer cannot double
        // release a loader-owned mapping if allocation fails there.
        source_transferred = true;
        const face = try self.addSource(source, catalog.face_index);
        errdefer self.rollbackLastFace(face);
        const id = try self.instanceForFace(face, descriptor);
        catalog.face = face;
        if (!catalog.loaded.isValid()) catalog.loaded = id;
        return id;
    }

    fn rememberFallbackMiss(self: *Backend, catalog_index: usize, scalars: []const ScalarRecord) Error!void {
        if (self.fallback_misses.count() >= self.maximum_fallback_misses) return;
        try self.fallback_misses.put(fallbackMissKey(catalog_index, scalars), {});
    }

    fn fontCovers(self: *Backend, id: handles.FontId, scalars: []const ScalarRecord) Error!bool {
        const entry = self.fonts.get(id) orelse return error.InvalidHandle;
        return covers(entry.font, scalars);
    }

    fn rasterizeGlyph(self: *Backend, request: api.RasterRequest, allocator: std.mem.Allocator) Error!api.RasterizedGlyph {
        const entry = self.fonts.get(request.font) orelse return error.InvalidHandle;
        if (!std.math.isFinite(request.size) or request.size <= 0 or request.size > 1_000_000 or !std.math.isFinite(request.scale_factor) or request.scale_factor <= 0 or request.scale_factor > 64) return error.InvalidConfiguration;
        if (request.glyph_id > std.math.maxInt(u16)) return error.InvalidFont;
        if (request.mode == .color)
            return color_font.rasterize(allocator, entry.font, @intCast(request.glyph_id), request.size, request.scale_factor, request.foreground);
        if (request.mode == .subpixel) return error.Unsupported;
        return raster.rasterize(allocator, entry.font, @intCast(request.glyph_id), request.size, request.scale_factor);
    }

    fn colorGlyphKind(self: *Backend, font: handles.FontId, glyph_id: u32) api.ColorGlyphKind {
        const entry = self.fonts.get(font) orelse return .none;
        if (glyph_id > std.math.maxInt(u16)) return .none;
        return color_font.glyphKind(entry.font, @intCast(glyph_id));
    }

    fn destroy(self: *Backend) void {
        var iterator = self.fonts.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.value.coordinates);
        self.fonts.deinit();
        for (self.faces.items) |face| {
            switch (face.source.storage) {
                .resident => self.loaded_font_bytes -|= face.source.bytes.len,
                .mapped => self.mapped_font_bytes -|= face.source.bytes.len,
            }
            self.allocator.free(face.family);
            face.source.deinit(self.allocator);
            self.allocator.destroy(face);
        }
        self.faces.deinit(self.allocator);
        for (self.catalog.items) |*entry| entry.deinit(self.allocator);
        self.catalog.deinit(self.allocator);
        self.fallback_misses.deinit();
        self.catalog_bytes = 0;
        self.* = undefined;
    }

    fn cast(context: *anyopaque) *Backend {
        return @ptrCast(@alignCast(context));
    }

    fn resolveFontOpaque(context: *anyopaque, descriptor: api.FontDescriptor) Error!handles.FontId {
        return cast(context).resolveFont(descriptor);
    }

    fn metricsOpaque(context: *anyopaque, font: handles.FontId, size: f32) Error!api.FontMetrics {
        return cast(context).metrics(font, size);
    }

    fn shapeOpaque(context: *anyopaque, request: api.ShapeRequest, allocator: std.mem.Allocator) Error!api.ShapedRun {
        return cast(context).shape(request, allocator);
    }

    fn rasterizeOpaque(context: *anyopaque, request: api.RasterRequest, allocator: std.mem.Allocator) Error!api.RasterizedGlyph {
        return cast(context).rasterizeGlyph(request, allocator);
    }

    fn colorGlyphOpaque(context: *anyopaque, font: handles.FontId, glyph_id: u32) api.ColorGlyphKind {
        return cast(context).colorGlyphKind(font, glyph_id);
    }

    fn deinitOpaque(context: *anyopaque) void {
        const self = cast(context);
        const allocator = self.allocator;
        self.destroy();
        allocator.destroy(self);
    }
};

fn fallbackMissKey(catalog_index: usize, scalars: []const ScalarRecord) FallbackMissKey {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(std.mem.asBytes(&catalog_index));
    for (scalars) |scalar| hasher.update(std.mem.asBytes(&scalar.scalar));
    var result: FallbackMissKey = undefined;
    hasher.final(&result);
    return result;
}

const ScalarRecord = struct {
    scalar: u21,
    cluster_utf8: u32,
    font: handles.FontId,
    script: unicode.Script,
};

const ShapeRun = struct {
    start: usize,
    end: usize,
    font: handles.FontId,
    script: unicode.Script,
    level: u8,
};

fn covers(font: opentype.Font, scalars: []const ScalarRecord) Error!bool {
    for (scalars) |scalar| {
        const property = unicode.properties(scalar.scalar);
        if (property.defaultIgnorable()) continue;
        if (try font.glyphIndex(scalar.scalar) == 0) return false;
    }
    return true;
}

fn coverageMayContainAll(coverage: *const opentype.Coverage, scalars: []const ScalarRecord) bool {
    for (scalars) |scalar| {
        const property = unicode.properties(scalar.scalar);
        if (property.defaultIgnorable()) continue;
        if (!coverage.mayContain(scalar.scalar)) return false;
    }
    return true;
}

fn axesForFont(font: opentype.Font) VariationAxes {
    const fvar = font.optionalTable("fvar".*) orelse return .{};
    return .{
        .weight = variation.hasAxis(fvar, "wght".*),
        .width = variation.hasAxis(fvar, "wdth".*),
        .italic = variation.hasAxis(fvar, "ital".*),
        .slant = variation.hasAxis(fvar, "slnt".*),
    };
}

fn catalogMatchScore(descriptor: api.FontDescriptor, catalog: CatalogEntry) u32 {
    const weight_score = if (catalog.axes.weight) @as(u32, 0) else weightDistance(descriptor.weight, catalog.weight);
    const style_score = if (catalog.axes.italic or catalog.axes.slant or descriptor.style == catalog.style) @as(u32, 0) else 1000;
    const stretch_score = if (catalog.axes.width) @as(u32, 0) else stretchDistance(descriptor.stretch, catalog.stretch);
    return weight_score +| style_score +| stretch_score;
}

fn instanceMatchScore(descriptor: api.FontDescriptor, entry: FontEntry) u32 {
    return weightDistance(descriptor.weight, entry.weight) +|
        (if (descriptor.style == entry.style) @as(u32, 0) else 1000) +|
        stretchDistance(descriptor.stretch, entry.stretch);
}

fn stretchDistance(left: u16, right: u16) u32 {
    const a: i32 = left;
    const b: i32 = right;
    return @intCast(@abs(a - b));
}

fn genericFamilyScore(requested: []const u8, family: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(requested, "sans-serif") or std.ascii.eqlIgnoreCase(requested, "ui-sans-serif")) {
        return if (containsIgnoreCase(family, "sans") or containsIgnoreCase(family, "arial") or
            containsIgnoreCase(family, "helvetica") or containsIgnoreCase(family, "segoe")) 0 else null;
    }
    if (std.ascii.eqlIgnoreCase(requested, "serif") or std.ascii.eqlIgnoreCase(requested, "ui-serif")) {
        return if (containsIgnoreCase(family, "serif") or containsIgnoreCase(family, "times") or
            containsIgnoreCase(family, "georgia")) 0 else null;
    }
    if (std.ascii.eqlIgnoreCase(requested, "monospace") or std.ascii.eqlIgnoreCase(requested, "ui-monospace")) {
        return if (containsIgnoreCase(family, "mono") or containsIgnoreCase(family, "code") or
            containsIgnoreCase(family, "console") or containsIgnoreCase(family, "courier")) 0 else null;
    }
    if (std.ascii.eqlIgnoreCase(requested, "emoji")) return if (containsIgnoreCase(family, "emoji")) 0 else null;
    if (std.ascii.eqlIgnoreCase(requested, "math")) return if (containsIgnoreCase(family, "math")) 0 else null;
    if (std.ascii.eqlIgnoreCase(requested, "cursive")) {
        return if (containsIgnoreCase(family, "script") or containsIgnoreCase(family, "hand") or
            containsIgnoreCase(family, "cursive")) 0 else null;
    }
    return null;
}

fn isLastResortFamily(family: []const u8) bool {
    return std.ascii.eqlIgnoreCase(family, "LastResort") or
        std.ascii.eqlIgnoreCase(family, "Last Resort") or
        std.ascii.eqlIgnoreCase(family, ".LastResort");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var equal = true;
        for (needle, 0..) |character, needle_index| {
            if (std.ascii.toLower(haystack[index + needle_index]) == std.ascii.toLower(character)) continue;
            equal = false;
            break;
        }
        if (equal) return true;
    }
    return false;
}

fn resolveScripts(scalars: []ScalarRecord) void {
    var previous: ?unicode.Script = null;
    for (scalars) |*scalar| {
        if (!isNeutralScript(scalar.script)) {
            previous = scalar.script;
            continue;
        }
        if (previous) |candidate| {
            if (allowsScript(scalar.scalar, candidate)) scalar.script = candidate;
        }
    }
    var next: ?unicode.Script = null;
    var index = scalars.len;
    while (index > 0) {
        index -= 1;
        if (!isNeutralScript(scalars[index].script)) {
            next = scalars[index].script;
            continue;
        }
        if (next) |candidate| {
            if (allowsScript(scalars[index].scalar, candidate)) scalars[index].script = candidate;
        }
        if (isNeutralScript(scalars[index].script)) scalars[index].script = .common;
    }
}

fn isNeutralScript(script: unicode.Script) bool {
    return script == .common or script == .inherited or script == .unknown;
}

fn allowsScript(scalar: u21, candidate: unicode.Script) bool {
    const extensions = unicode.data.scriptExtensions(scalar);
    if (extensions.len == 0) return true;
    for (extensions) |value| if (value == candidate) return true;
    return false;
}

fn buildRuns(
    allocator: std.mem.Allocator,
    scalars: []const ScalarRecord,
    levels: []const u8,
    output: *std.ArrayList(ShapeRun),
    run_for_scalar: []usize,
) Error!void {
    if (scalars.len != levels.len or scalars.len != run_for_scalar.len) return error.InvalidLayout;
    var start: usize = 0;
    while (start < scalars.len) {
        var end = start + 1;
        while (end < scalars.len and scalars[end].font.eql(scalars[start].font) and scalars[end].script == scalars[start].script and levels[end] == levels[start]) end += 1;
        const run_index = output.items.len;
        try output.append(allocator, .{
            .start = start,
            .end = end,
            .font = scalars[start].font,
            .script = scalars[start].script,
            .level = levels[start],
        });
        @memset(run_for_scalar[start..end], run_index);
        start = end;
    }
}

fn appendUniqueFont(allocator: std.mem.Allocator, fonts: *std.ArrayList(handles.FontId), font: handles.FontId) Error!u32 {
    for (fonts.items, 0..) |existing, index| if (existing.eql(font)) return @intCast(index);
    try fonts.append(allocator, font);
    return @intCast(fonts.items.len - 1);
}

fn weightDistance(a: api.FontWeight, b: api.FontWeight) u32 {
    const left: i32 = @backingInt(a);
    const right: i32 = @backingInt(b);
    return @intCast(@abs(left - right));
}

fn resolveDirection(bytes: []const u8, requested: api.TextDirection) Error!api.TextDirection {
    if (requested != .auto) return requested;
    var iterator: unicode.Iterator = .{ .bytes = bytes };
    while (try iterator.next()) |scalar| switch (unicode.bidiClass(scalar.value)) {
        .r, .al => return .right_to_left,
        .l => return .left_to_right,
        else => {},
    };
    return .left_to_right;
}

fn loadTestResidentFont(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, maximum_bytes: usize) Error!FontSource {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.TextUnavailable;
    defer file.close(io);
    const metadata = file.stat(io) catch return error.TextUnavailable;
    const size = std.math.cast(usize, metadata.size) orelse return error.BudgetExceeded;
    if (size == 0 or size > maximum_bytes) return error.BudgetExceeded;
    const bytes = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    const read = file.readPositionalAll(io, bytes, 0) catch return error.TextUnavailable;
    if (read != bytes.len) return error.TextUnavailable;
    return FontSource.resident(bytes);
}

test "fallback probes release nonmatching catalog faces before retaining them" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const testing = std.testing;
    var backend = try Backend.createInstance(testing.allocator, 16 * 1024 * 1024, 16 * 1024 * 1024, 64, 8, 4096);
    defer {
        backend.destroy();
        testing.allocator.destroy(backend);
    }

    const path = "/System/Library/Fonts/Avenir.ttc";
    const catalog_index = try backend.addCatalogFile(
        path,
        0,
        "Test Font",
        .regular,
        .normal,
        100,
        .{},
        .{},
        .{ .storage = .resident, .load_fn = loadTestResidentFont },
    );
    var scalars = [_]ScalarRecord{.{
        .scalar = 0x10ffff,
        .cluster_utf8 = 0,
        .font = .invalid,
        .script = .common,
    }};
    const descriptor: api.FontDescriptor = .{ .families = &.{}, .weight = .regular, .style = .normal, .stretch = 100 };
    try testing.expect((try backend.loadCatalogForFallback(catalog_index, descriptor, &scalars)) == null);
    try testing.expectEqual(@as(usize, 0), backend.loaded_font_bytes);
    try testing.expectEqual(@as(usize, 0), backend.faces.items.len);
    try testing.expect(backend.catalog.items[catalog_index].face == null);
}
