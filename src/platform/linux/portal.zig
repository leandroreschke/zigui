//! XDG Desktop Portal client implemented directly over the in-tree D-Bus
//! transport. It provides desktop-consistent file dialogs without GTK, Qt,
//! libportal, or a helper subprocess.

const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const handles = @import("../../core/handle.zig");
const api = @import("../api.zig");
const uri = @import("uri.zig");
const dbus = @import("dbus/client.zig");
const wire = dbus.wire;
const sys = @import("sys.zig");

const destination = "org.freedesktop.portal.Desktop";
const desktop_path = "/org/freedesktop/portal/desktop";
const file_chooser = "org.freedesktop.portal.FileChooser";
const request_interface = "org.freedesktop.portal.Request";
const maximum_result_uris = 16 * 1024;

pub const Portal = struct {
    pub const ParentProvider = struct {
        context: *anyopaque,
        identifier_fn: *const fn (*anyopaque, handles.WindowId, std.mem.Allocator) Error![]u8,

        fn identifier(self: ParentProvider, window: handles.WindowId, allocator: std.mem.Allocator) Error![]u8 {
            return self.identifier_fn(self.context, window, allocator);
        }
    };

    allocator: std.mem.Allocator,
    bus: dbus.Client,
    parent: ParentProvider,
    next_token: u64 = 1,
    response_match_installed: bool = false,

    pub fn create(allocator: std.mem.Allocator, parent: ParentProvider) Error!*Portal {
        const self = try allocator.create(Portal);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .bus = try dbus.Client.connectSession(allocator),
            .parent = parent,
        };
        return self;
    }

    pub fn deinit(self: *Portal) void {
        self.bus.deinit();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn dialogs(self: *Portal) api.Dialogs {
        return .{
            .context = self,
            .open_files_fn = openFilesOpaque,
            .save_file_fn = saveFileOpaque,
        };
    }

    fn openFiles(self: *Portal, window: handles.WindowId, multiple: bool, allocator: std.mem.Allocator) Error!api.OwnedPaths {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        const parent = try self.parentIdentifier(window);
        defer self.allocator.free(parent);
        const token = try self.requestToken();
        defer self.allocator.free(token);
        try body.string(parent);
        try body.string("Open File");
        const options = try body.beginArray(8);
        try appendStringOption(&body, "handle_token", token);
        try appendBooleanOption(&body, "multiple", multiple);
        try appendBooleanOption(&body, "directory", false);
        try body.endArray(options);
        const uris = try self.performRequest("OpenFile", token, body.bytes.items);
        defer {
            for (uris) |value| self.allocator.free(@constCast(value));
            self.allocator.free(uris);
        }
        return pathsFromUris(allocator, uris);
    }

    fn saveFile(self: *Portal, window: handles.WindowId, suggested_name: []const u8, allocator: std.mem.Allocator) Error!?api.OwnedPath {
        if (!std.unicode.utf8ValidateSlice(suggested_name)) return error.InvalidUtf8;
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        const parent = try self.parentIdentifier(window);
        defer self.allocator.free(parent);
        const token = try self.requestToken();
        defer self.allocator.free(token);
        try body.string(parent);
        try body.string("Save File");
        const options = try body.beginArray(8);
        try appendStringOption(&body, "handle_token", token);
        if (suggested_name.len != 0) try appendStringOption(&body, "current_name", suggested_name);
        try body.endArray(options);
        const uris = try self.performRequest("SaveFile", token, body.bytes.items);
        defer {
            for (uris) |value| self.allocator.free(@constCast(value));
            self.allocator.free(uris);
        }
        for (uris) |value| if (try uri.decodeFileUri(allocator, value)) |path| return .{ .allocator = allocator, .value = path };
        return null;
    }

    fn performRequest(self: *Portal, member: []const u8, token: []const u8, body: []const u8) Error![][]const u8 {
        if (!self.response_match_installed) {
            try self.bus.addMatch("type='signal',interface='org.freedesktop.portal.Request',member='Response'");
            self.response_match_installed = true;
        }
        var reply = try self.bus.call(destination, desktop_path, file_chooser, member, "ssa{sv}", body);
        defer reply.deinit();
        var reply_reader = reply.bodyReader();
        const request_path = try reply_reader.objectPath();
        _ = token;
        var response = try self.bus.waitSignal(request_path, request_interface, "Response");
        defer response.deinit();
        var reader = response.bodyReader();
        const result = try reader.u32();
        if (result == 1) return self.allocator.alloc([]const u8, 0);
        if (result != 0) return error.PlatformFailure;
        return readUris(self.allocator, &reader);
    }

    fn parentIdentifier(self: *Portal, window: handles.WindowId) Error![]u8 {
        return self.parent.identifier(window, self.allocator);
    }

    fn requestToken(self: *Portal) Error![]u8 {
        const value = self.next_token;
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        return std.fmt.allocPrint(self.allocator, "zigui_{d}_{d}", .{ sys.linux.getpid(), value });
    }

    fn cast(raw: *anyopaque) *Portal {
        return @ptrCast(@alignCast(raw));
    }

    fn openFilesOpaque(raw: *anyopaque, window: handles.WindowId, multiple: bool, allocator: std.mem.Allocator) Error!api.OwnedPaths {
        return cast(raw).openFiles(window, multiple, allocator);
    }

    fn saveFileOpaque(raw: *anyopaque, window: handles.WindowId, suggested_name: []const u8, allocator: std.mem.Allocator) Error!?api.OwnedPath {
        return cast(raw).saveFile(window, suggested_name, allocator);
    }
};

fn appendStringOption(writer: *wire.Writer, key: []const u8, value: []const u8) Error!void {
    try writer.beginStruct();
    try writer.string(key);
    try writer.variantHeader("s");
    try writer.string(value);
}

fn appendBooleanOption(writer: *wire.Writer, key: []const u8, value: bool) Error!void {
    try writer.beginStruct();
    try writer.string(key);
    try writer.variantHeader("b");
    try writer.boolean(value);
}

fn readUris(allocator: std.mem.Allocator, reader: *wire.Reader) Error![][]const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(@constCast(value));
        values.deinit(allocator);
    }
    const dictionary_end = try reader.beginArray(8);
    while (reader.offset < dictionary_end) {
        try reader.beginStruct();
        const key = try reader.string();
        const signature = try reader.variantHeader();
        if (std.mem.eql(u8, key, "uris") and std.mem.eql(u8, signature, "as")) {
            const array_end = try reader.beginArray(4);
            while (reader.offset < array_end) {
                if (values.items.len >= maximum_result_uris) return error.BudgetExceeded;
                try values.append(allocator, try allocator.dupe(u8, try reader.string()));
            }
            if (reader.offset != array_end) return error.PlatformFailure;
        } else try wire.skipValue(reader, signature);
    }
    if (reader.offset != dictionary_end) return error.PlatformFailure;
    return values.toOwnedSlice(allocator);
}

fn pathsFromUris(allocator: std.mem.Allocator, uris: []const []const u8) Error!api.OwnedPaths {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(@constCast(path));
        paths.deinit(allocator);
    }
    for (uris) |value| if (try uri.decodeFileUri(allocator, value)) |path| {
        errdefer allocator.free(path);
        try paths.append(allocator, path);
    };
    return .{ .allocator = allocator, .values = try paths.toOwnedSlice(allocator) };
}
