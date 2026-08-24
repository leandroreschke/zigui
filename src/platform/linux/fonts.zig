//! Native Linux font discovery without Fontconfig, FreeType, or subprocesses.
//! Font files are mapped only while their compact catalog metadata is read;
//! the in-tree text backend loads a selected face lazily and enforces its own
//! resident-byte budget.

const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const text = @import("../../text/api.zig");
const in_tree = @import("../../text/in_tree_backend.zig");
const opentype = @import("../../text/opentype.zig");
const variation = @import("../../text/opentype_variation.zig");
const sys = @import("sys.zig");

const maximum_font_file_bytes = 256 * 1024 * 1024;
const maximum_catalog_faces = 32 * 1024;
const maximum_depth = 32;
const directory_buffer_bytes = 64 * 1024;
const environment_bytes = 256 * 1024;

pub const Result = struct {
    faces: usize,
    files: usize,
};

const Discovery = struct {
    allocator: std.mem.Allocator,
    backend: *in_tree.Backend,
    files: usize = 0,
    best_default: ?usize = null,
    best_default_score: u32 = std.math.maxInt(u32),
    budget_full: bool = false,

    fn scanRoot(self: *Discovery, path: []const u8) Error!void {
        if (self.budget_full) return;
        self.scanDirectory(path, 0) catch |err| switch (err) {
            error.MissingCapability => {},
            else => return err,
        };
    }

    fn scanDirectory(self: *Discovery, path: []const u8, depth: u8) Error!void {
        if (depth > maximum_depth or self.budget_full or self.backend.catalogCount() >= maximum_catalog_faces) return;
        const descriptor = try sys.openDirectory(path);
        defer sys.close(descriptor);
        var buffer: [directory_buffer_bytes]u8 align(@alignOf(sys.linux.dirent64)) = undefined;
        while (true) {
            const result = sys.linux.getdents64(descriptor, &buffer, buffer.len);
            switch (sys.linux.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                .NOENT => return,
                .NOMEM => return error.OutOfMemory,
                else => return error.PlatformFailure,
            }
            if (result == 0) return;
            var offset: usize = 0;
            while (offset < result) {
                if (result - offset < @offsetOf(sys.linux.dirent64, "name")) return error.PlatformFailure;
                const entry: *align(1) const sys.linux.dirent64 = @ptrCast(&buffer[offset]);
                const record_length: usize = entry.reclen;
                if (record_length < @offsetOf(sys.linux.dirent64, "name") + 1 or record_length > result - offset)
                    return error.PlatformFailure;
                const name_pointer: [*]const u8 = &entry.name;
                const padded = name_pointer[0 .. record_length - @offsetOf(sys.linux.dirent64, "name")];
                const name_length = std.mem.indexOfScalar(u8, padded, 0) orelse return error.PlatformFailure;
                const name = padded[0..name_length];
                offset += record_length;
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                const child = try joinPath(self.allocator, path, name);
                defer self.allocator.free(child);
                if (entry.type == sys.linux.DT.DIR) {
                    try self.scanDirectory(child, depth + 1);
                    continue;
                }
                if (entry.type != sys.linux.DT.REG and entry.type != sys.linux.DT.UNKNOWN) continue;
                if (!isFontPath(name)) continue;
                try self.inspectFile(child);
                if (self.budget_full or self.backend.catalogCount() >= maximum_catalog_faces) return;
            }
        }
    }

    fn inspectFile(self: *Discovery, path: []const u8) Error!void {
        var mapping = sys.mapFileReadOnly(path, @min(maximum_font_file_bytes, self.backend.maximumMappedFontBytes())) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer mapping.deinit();
        const face_count = opentype.Font.faceCount(mapping.bytes) catch return;
        var face_index: u32 = 0;
        var accepted = false;
        while (face_index < face_count and self.backend.catalogCount() < maximum_catalog_faces) : (face_index += 1) {
            const font = opentype.Font.init(mapping.bytes, face_index) catch continue;
            const family = font.familyName(self.allocator) catch continue;
            defer self.allocator.free(family);
            if (!std.unicode.utf8ValidateSlice(family) or family.len == 0 or family.len > 4096 or
                std.mem.indexOfScalar(u8, family, 0) != null) continue;
            const weight = normalizedWeight(font.weightClass());
            const style: text.FontStyle = if (font.isItalic()) .italic else .normal;
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
            const score = defaultScore(family, weight, style);
            if (score < self.best_default_score) {
                self.best_default_score = score;
                self.best_default = catalog_index;
            }
            accepted = true;
        }
        if (accepted) self.files += 1;
    }
};

pub fn discover(allocator: std.mem.Allocator, backend: *in_tree.Backend) Error!Result {
    var discovery: Discovery = .{ .allocator = allocator, .backend = backend };
    try discovery.scanRoot("/usr/share/fonts");
    try discovery.scanRoot("/usr/local/share/fonts");

    var home_storage: [environment_bytes]u8 = undefined;
    if (try sys.initialEnvironment("HOME", &home_storage)) |home| {
        if (home.len != 0 and home[0] == '/') {
            const legacy = try joinPath(allocator, home, ".fonts");
            defer allocator.free(legacy);
            try discovery.scanRoot(legacy);
            const local = try joinPath(allocator, home, ".local/share/fonts");
            defer allocator.free(local);
            try discovery.scanRoot(local);
        }
    }

    var data_home_storage: [environment_bytes]u8 = undefined;
    if (try sys.initialEnvironment("XDG_DATA_HOME", &data_home_storage)) |data_home| {
        if (data_home.len != 0 and data_home[0] == '/') {
            const root = try joinPath(allocator, data_home, "fonts");
            defer allocator.free(root);
            try discovery.scanRoot(root);
        }
    }

    var data_dirs_storage: [environment_bytes]u8 = undefined;
    const data_dirs = (try sys.initialEnvironment("XDG_DATA_DIRS", &data_dirs_storage)) orelse "/usr/local/share:/usr/share";
    var directories = std.mem.splitScalar(u8, data_dirs, ':');
    while (directories.next()) |directory| {
        if (directory.len == 0 or directory[0] != '/') continue;
        const root = try joinPath(allocator, directory, "fonts");
        defer allocator.free(root);
        try discovery.scanRoot(root);
    }

    const selected = discovery.best_default orelse return error.TextUnavailable;
    try backend.setDefaultCatalog(selected);
    return .{ .faces = backend.catalogCount(), .files = discovery.files };
}

fn loadFile(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, maximum_bytes: usize) Error!in_tree.FontSource {
    const state = try allocator.create(sys.MappedFile);
    errdefer allocator.destroy(state);
    state.* = try sys.mapFileReadOnly(path, @min(maximum_bytes, maximum_font_file_bytes));
    return .{
        .bytes = state.bytes,
        .storage = .mapped,
        .context = state,
        .deinit_fn = deinitMappedSource,
    };
}

fn deinitMappedSource(context: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8) void {
    const state: *sys.MappedFile = @ptrCast(@alignCast(context orelse return));
    state.deinit();
    allocator.destroy(state);
}

fn joinPath(allocator: std.mem.Allocator, parent: []const u8, child: []const u8) Error![]u8 {
    if (parent.len == 0 or child.len == 0 or std.mem.indexOfScalar(u8, child, 0) != null) return error.InvalidConfiguration;
    const separator = if (parent[parent.len - 1] == '/') "" else "/";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ parent, separator, child });
}

fn isFontPath(name: []const u8) bool {
    const extension = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const suffix = name[extension..];
    return std.ascii.eqlIgnoreCase(suffix, ".ttf") or std.ascii.eqlIgnoreCase(suffix, ".otf") or
        std.ascii.eqlIgnoreCase(suffix, ".ttc") or std.ascii.eqlIgnoreCase(suffix, ".otc");
}

fn normalizedWeight(value: u16) text.FontWeight {
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

fn defaultScore(family: []const u8, weight: text.FontWeight, style: text.FontStyle) u32 {
    const families = [_][]const u8{
        "Inter", "Noto Sans", "DejaVu Sans", "Liberation Sans", "Ubuntu", "Cantarell", "Arial", "FreeSans",
    };
    var family_score: u32 = 10_000;
    for (families, 0..) |candidate, index| if (std.ascii.eqlIgnoreCase(family, candidate)) {
        family_score = @intCast(index * 100);
        break;
    };
    const style_score: u32 = if (style == .normal) 0 else 1_000;
    return family_score + style_score + weightDistance(weight, .regular);
}

fn weightDistance(left: text.FontWeight, right: text.FontWeight) u32 {
    const a: i32 = @backingInt(left);
    const b: i32 = @backingInt(right);
    return @intCast(@abs(a - b));
}
