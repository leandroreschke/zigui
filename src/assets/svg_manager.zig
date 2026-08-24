const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const layout = @import("../layout/style.zig");
const custom = @import("../compose/custom.zig");
const scene = @import("../scene/scene.zig");
const svg = @import("svg.zig");

const Entry = struct {
    document: svg.Document,
    references: usize = 1,
};

/// Owns parsed SVG documents and deduplicates identical source bytes. No GPU
/// object is retained: documents emit the same backend-neutral scene commands
/// as native ZigUI elements and therefore survive device loss automatically.
pub const Manager = struct {
    const Pool = handles.SlotPool(Entry, handles.SvgId);

    allocator: std.mem.Allocator,
    documents: Pool,
    by_source: std.StringHashMap(handles.SvgId),
    limits: svg.Limits,
    maximum_resident_bytes: usize,
    maximum_documents: usize,
    resident_bytes: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        limits: svg.Limits,
        maximum_resident_bytes: usize,
        maximum_documents: usize,
    ) Manager {
        return .{
            .allocator = allocator,
            .documents = Pool.init(allocator),
            .by_source = std.StringHashMap(handles.SvgId).init(allocator),
            .limits = limits,
            .maximum_resident_bytes = maximum_resident_bytes,
            .maximum_documents = maximum_documents,
        };
    }

    pub fn deinit(self: *Manager) void {
        var iterator = self.documents.iterator();
        while (iterator.next()) |entry| entry.value.document.deinit();
        self.by_source.deinit();
        self.documents.deinit();
        self.* = undefined;
    }

    pub fn load(self: *Manager, bytes: []const u8) Error!handles.SvgId {
        if (self.by_source.get(bytes)) |id| {
            try self.retain(id);
            return id;
        }
        if (self.documents.live_count >= self.maximum_documents) return error.BudgetExceeded;
        var document = try svg.Document.parse(self.allocator, bytes, self.limits);
        var document_owned = true;
        errdefer if (document_owned) document.deinit();
        const bytes_used = document.residentBytes();
        if (bytes_used > self.maximum_resident_bytes -| self.resident_bytes) return error.BudgetExceeded;

        const id = try self.documents.insert(.{ .document = document });
        document_owned = false;
        errdefer {
            var removed = self.documents.remove(id).?;
            removed.document.deinit();
        }
        const stored = self.documents.get(id).?;
        try self.by_source.put(stored.document.source, id);
        self.resident_bytes += bytes_used;
        return id;
    }

    pub fn retain(self: *Manager, id: handles.SvgId) Error!void {
        const entry = self.documents.get(id) orelse return error.InvalidHandle;
        if (entry.references == std.math.maxInt(usize)) return error.BudgetExceeded;
        entry.references += 1;
    }

    pub fn release(self: *Manager, id: handles.SvgId) Error!void {
        const entry = self.documents.get(id) orelse return error.InvalidHandle;
        if (entry.references > 1) {
            entry.references -= 1;
            return;
        }
        _ = self.by_source.remove(entry.document.source);
        var removed = self.documents.remove(id) orelse return error.InvalidHandle;
        self.resident_bytes -= removed.document.residentBytes();
        removed.document.deinit();
    }

    pub fn intrinsicSize(self: *const Manager, id: handles.SvgId) ?geometry.Size {
        const entry = self.documents.getConst(id) orelse return null;
        return entry.document.intrinsicSize();
    }

    pub fn paint(self: *const Manager, id: handles.SvgId, builder: *scene.Builder, bounds: geometry.Rect, fit: svg.Fit) Error!void {
        const entry = self.documents.getConst(id) orelse return error.InvalidHandle;
        try entry.document.paint(builder, bounds, fit);
    }

    pub fn services(self: *Manager) custom.SvgServices {
        return .{
            .context = self,
            .measure_fn = measureOpaque,
            .paint_fn = paintOpaque,
        };
    }

    fn measureOpaque(context: *anyopaque, id: handles.SvgId, constraints: layout.Constraints) Error!geometry.Size {
        const self: *Manager = @ptrCast(@alignCast(context));
        const size = self.intrinsicSize(id) orelse return error.InvalidHandle;
        return constraints.constrain(size);
    }

    fn paintOpaque(context: *anyopaque, scene_context: *anyopaque, id: handles.SvgId, bounds: geometry.Rect, fit_value: u8) Error!void {
        const self: *Manager = @ptrCast(@alignCast(context));
        const builder: *scene.Builder = @ptrCast(@alignCast(scene_context));
        const fit = std.enums.fromInt(svg.Fit, fit_value) orelse return error.InvalidSvg;
        try self.paint(id, builder, bounds, fit);
    }
};
