//! Cross-platform installed-font discovery for the in-tree text engine.
//!
//! This module deliberately uses only Zig's standard I/O implementation.  It
//! does not invoke Fontconfig, CoreText, DirectWrite, a subprocess, or a
//! package dependency. Platform adapters provide the native font roots; this
//! scanner reads only enough OpenType metadata to build a lazy catalog.

const std = @import("std");
const builtin = @import("builtin");
const Error = @import("../core/error.zig").Error;
const api = @import("api.zig");
const in_tree = @import("in_tree_backend.zig");
const opentype = @import("opentype.zig");
const variation = @import("opentype_variation.zig");

const maximum_font_file_bytes = 256 * 1024 * 1024;
const maximum_catalog_faces = 32 * 1024;
const maximum_catalog_files = 64 * 1024;
const maximum_depth = 32;

pub const Result = struct {
    faces: usize,
    files: usize,
};

pub const Options = struct {
    preferred_families: []const []const u8,
};

const Discovery = struct {
    allocator: std.mem.Allocator,
    backend: *in_tree.Backend,
    preferred_families: []const []const u8,
    files: usize = 0,
    best_default: ?usize = null,
    best_default_score: u32 = std.math.maxInt(u32),
    budget_full: bool = false,

    fn scanRoot(self: *Discovery, root: []const u8) Error!void {
        if (self.budget_full) return;
        if (root.len == 0 or !std.Io.Dir.path.isAbsolute(root)) return;
        const io = std.Io.Threaded.global_single_threaded.io();
        const directory = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true, .follow_symlinks = true }) catch return;
        defer directory.close(io);
        var walker = try directory.walk(self.allocator);
        defer walker.deinit();
        var paths: std.ArrayList([]u8) = .empty;
        var path_bytes: usize = 0;
        defer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }
        while (walker.next(io) catch return) |entry| {
            if (entry.depth() > maximum_depth) {
                if (entry.kind == .directory) walker.leave(io);
                continue;
            }
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (!isFontPath(entry.basename)) continue;
            const path = try std.Io.Dir.path.join(self.allocator, &.{ root, entry.path });
            errdefer self.allocator.free(path);
            const next_path_bytes = std.math.add(usize, path_bytes, path.len) catch {
                self.allocator.free(path);
                break;
            };
            if (next_path_bytes > self.backend.maximumCatalogBytes()) {
                self.allocator.free(path);
                break;
            }
            try paths.append(self.allocator, path);
            path_bytes = next_path_bytes;
            if (paths.items.len == maximum_catalog_files) break;
        }
        std.mem.sort([]u8, paths.items, {}, struct {
            fn lessThan(_: void, left: []u8, right: []u8) bool {
                return std.mem.order(u8, left, right) == .lt;
            }
        }.lessThan);
        for (paths.items) |path| {
            try self.inspectFile(path);
            if (self.budget_full or self.backend.catalogCount() >= maximum_catalog_faces) return;
        }
    }

    fn inspectFile(self: *Discovery, path: []const u8) Error!void {
        var source = loadFile(
            null,
            self.allocator,
            path,
            @min(maximum_font_file_bytes, self.backend.maximumMappedFontBytes()),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        defer source.deinit(self.allocator);
        const face_count = opentype.Font.faceCount(source.bytes) catch return;
        var face_index: u32 = 0;
        var accepted = false;
        while (face_index < face_count and self.backend.catalogCount() < maximum_catalog_faces) : (face_index += 1) {
            const font = opentype.Font.init(source.bytes, face_index) catch continue;
            const family = font.familyName(self.allocator) catch continue;
            defer self.allocator.free(family);
            if (family.len == 0 or family.len > 4096 or !std.unicode.utf8ValidateSlice(family) or
                std.mem.indexOfScalar(u8, family, 0) != null) continue;
            // Last-resort faces deliberately map essentially every scalar to
            // a visible missing-glyph box. Treating that cmap as real coverage
            // prevents fallback from ever reaching an actual script font.
            if (isLastResortFamily(family)) continue;
            const weight = normalizedWeight(font.weightClass());
            const style: api.FontStyle = if (font.isItalic()) .italic else .normal;
            const stretch = normalizedStretch(font.widthClass());
            const fvar = font.optionalTable("fvar".*);
            const axes: in_tree.VariationAxes = if (fvar) |table| .{
                .weight = variation.hasAxis(table, "wght".*),
                .width = variation.hasAxis(table, "wdth".*),
                .italic = variation.hasAxis(table, "ital".*),
                .slant = variation.hasAxis(table, "slnt".*),
            } else .{};
            const coverage = font.coverage() catch continue;
            if (!self.backend.catalogHasCapacity(path.len, family.len)) {
                self.budget_full = true;
                return;
            }
            const catalog_index = try self.backend.addCatalogFile(
                path,
                face_index,
                family,
                weight,
                style,
                stretch,
                axes,
                coverage,
                .{ .storage = .mapped, .load_fn = loadFile },
            );
            const score = self.defaultScore(family, weight, style);
            if (score < self.best_default_score) {
                self.best_default_score = score;
                self.best_default = catalog_index;
            }
            accepted = true;
        }
        if (accepted) self.files += 1;
    }

    fn defaultScore(self: *const Discovery, family: []const u8, weight: api.FontWeight, style: api.FontStyle) u32 {
        var family_score: u32 = 100_000;
        for (self.preferred_families, 0..) |candidate, index| {
            if (!std.ascii.eqlIgnoreCase(family, candidate)) continue;
            family_score = @intCast(@min(index * 1_000, std.math.maxInt(u32)));
            break;
        }
        const style_score: u32 = if (style == .normal) 0 else 10_000;
        return family_score + style_score + weightDistance(weight, .regular);
    }
};

pub fn discover(
    allocator: std.mem.Allocator,
    backend: *in_tree.Backend,
    roots: []const []const u8,
    options: Options,
) Error!Result {
    var discovery: Discovery = .{
        .allocator = allocator,
        .backend = backend,
        .preferred_families = options.preferred_families,
    };
    for (roots) |root| try discovery.scanRoot(root);
    const selected = discovery.best_default orelse return error.TextUnavailable;
    try backend.setDefaultCatalog(selected);
    return .{ .faces = backend.catalogCount(), .files = discovery.files };
}

const MappedSource = struct {
    io: std.Io,
    file: std.Io.File,
    mapping: std.Io.File.MemoryMap,
};

fn loadFile(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, maximum_bytes: usize) Error!in_tree.FontSource {
    if (maximum_bytes == 0 or path.len == 0 or !std.Io.Dir.path.isAbsolute(path)) return error.BudgetExceeded;
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.TextUnavailable;
    errdefer file.close(io);
    const metadata = file.stat(io) catch return error.TextUnavailable;
    const size = std.math.cast(usize, metadata.size) orelse return error.BudgetExceeded;
    if (size == 0 or size > @min(maximum_bytes, maximum_font_file_bytes)) return error.BudgetExceeded;
    var mapping = file.createMemoryMap(io, .{
        .len = size,
        .protection = .{ .read = true, .write = false },
        // Zig 0.17's Windows NtCreateSection path otherwise supplies no
        // section allocation attribute and fails with INVALID_PARAMETER_6.
        .populate = builtin.os.tag == .windows,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TextUnavailable,
    };
    errdefer mapping.destroy(io);
    const state = try allocator.create(MappedSource);
    state.* = .{ .io = io, .file = file, .mapping = mapping };
    return .{
        .bytes = state.mapping.memory,
        .storage = .mapped,
        .context = state,
        .deinit_fn = deinitMappedSource,
    };
}

fn deinitMappedSource(context: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8) void {
    const state: *MappedSource = @ptrCast(@alignCast(context orelse return));
    state.mapping.destroy(state.io);
    state.file.close(state.io);
    allocator.destroy(state);
}

test "bounded font source maps a real file" {
    const testing = std.testing;
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "font.bin", .data = "font-map-regression" });

    var directory_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const directory_path_length = try temporary.dir.realPath(io, &directory_path_buffer);
    const path = try std.Io.Dir.path.join(testing.allocator, &.{ directory_path_buffer[0..directory_path_length], "font.bin" });
    defer testing.allocator.free(path);

    var source = try loadFile(null, testing.allocator, path, 1024);
    defer source.deinit(testing.allocator);
    try testing.expectEqualStrings("font-map-regression", source.bytes);
}

fn isFontPath(name: []const u8) bool {
    const extension = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const suffix = name[extension..];
    return std.ascii.eqlIgnoreCase(suffix, ".ttf") or
        std.ascii.eqlIgnoreCase(suffix, ".otf") or
        std.ascii.eqlIgnoreCase(suffix, ".ttc") or
        std.ascii.eqlIgnoreCase(suffix, ".otc");
}

fn normalizedWeight(value: u16) api.FontWeight {
    return switch (value) {
        0...150 => .thin,
        151...250 => .extra_light,
        251...350 => .light,
        351...450 => .regular,
        451...550 => .medium,
        551...650 => .semibold,
        651...750 => .bold,
        751...850 => .extra_bold,
        else => .black,
    };
}

fn normalizedStretch(width_class: u16) u16 {
    return switch (width_class) {
        1 => 50,
        2 => 63,
        3 => 75,
        4 => 88,
        5 => 100,
        6 => 113,
        7 => 125,
        8 => 150,
        9 => 200,
        else => 100,
    };
}

fn weightDistance(left: api.FontWeight, right: api.FontWeight) u32 {
    const a: i32 = @backingInt(left);
    const b: i32 = @backingInt(right);
    return @intCast(@abs(a - b));
}

fn isLastResortFamily(family: []const u8) bool {
    return std.ascii.eqlIgnoreCase(family, "LastResort") or
        std.ascii.eqlIgnoreCase(family, "Last Resort") or
        std.ascii.eqlIgnoreCase(family, ".LastResort");
}

test "synthetic last-resort faces are excluded from fallback catalogs" {
    try std.testing.expect(isLastResortFamily("LastResort"));
    try std.testing.expect(isLastResortFamily("last resort"));
    try std.testing.expect(isLastResortFamily(".LASTRESORT"));
    try std.testing.expect(!isLastResortFamily("Noto Sans Symbols"));
}
