const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const compose_store = @import("../compose/store.zig");
const compose_style = @import("../compose/style.zig");
const custom = @import("../compose/custom.zig");
const image_fit = @import("../compose/image_fit.zig");
const layout = @import("../layout/style.zig");
const abi = @import("abi.zig");
const scene = @import("scene.zig");
const text_api = @import("../text/api.zig");

pub const TextPainter = struct {
    context: *anyopaque,
    paint_fn: *const fn (*anyopaque, *scene.Builder, []const u8, compose_style.TextStyle, geometry.Rect) Error!void,
    paint_custom_fn: *const fn (*anyopaque, *anyopaque, []const u8, compose_style.TextStyle, geometry.Rect) Error!void,
    measure_fn: *const fn (*anyopaque, []const u8, compose_style.TextStyle, layout.Constraints) Error!geometry.Size,
    hit_test_fn: *const fn (*anyopaque, []const u8, compose_style.TextStyle, f32, geometry.Point) Error!text_api.Hit,
    caret_rect_fn: *const fn (*anyopaque, []const u8, compose_style.TextStyle, f32, usize, text_api.CaretAffinity) Error!geometry.Rect,
    selection_rects_fn: *const fn (
        *anyopaque,
        []const u8,
        compose_style.TextStyle,
        f32,
        usize,
        usize,
        *std.ArrayList(geometry.Rect),
        std.mem.Allocator,
    ) Error!void,

    pub fn paint(
        self: TextPainter,
        builder: *scene.Builder,
        value: []const u8,
        text_style: compose_style.TextStyle,
        bounds: geometry.Rect,
    ) Error!void {
        try self.paint_fn(self.context, builder, value, text_style, bounds);
    }

    pub fn services(self: TextPainter) custom.TextServices {
        return .{
            .context = self.context,
            .measure_fn = self.measure_fn,
            .paint_fn = self.paint_custom_fn,
            .hit_test_fn = self.hit_test_fn,
            .caret_rect_fn = self.caret_rect_fn,
            .selection_rects_fn = self.selection_rects_fn,
        };
    }
};

pub const Painter = struct {
    builder: *scene.Builder,
    text: ?TextPainter = null,
    svg: ?custom.SvgServices = null,
    scratch: std.mem.Allocator,
    scale_factor: geometry.ScaleFactor,

    pub fn paint(self: *Painter, nodes: *const compose_store.Store, root: handles.NodeId) Error!void {
        var portals: std.ArrayList(PortalCandidate) = .empty;
        defer portals.deinit(self.scratch);
        try self.paintNode(nodes, root, false, &portals);
        try self.paintPortalContext(nodes, portals.items);
    }

    fn paintPortalContext(
        self: *Painter,
        nodes: *const compose_store.Store,
        source: []PortalCandidate,
    ) Error!void {
        if (source.len == 0) return;
        const ordered = try self.scratch.dupe(PortalCandidate, source);
        std.mem.sort(PortalCandidate, ordered, {}, PortalCandidate.lessThan);
        for (ordered) |candidate| {
            var nested: std.ArrayList(PortalCandidate) = .empty;
            defer nested.deinit(self.scratch);
            try self.paintNode(nodes, candidate.id, true, &nested);
            try self.paintPortalContext(nodes, nested.items);
        }
    }

    fn paintNode(
        self: *Painter,
        nodes: *const compose_store.Store,
        id: handles.NodeId,
        portal_root: bool,
        portals: *std.ArrayList(PortalCandidate),
    ) Error!void {
        const record = nodes.getConst(id) orelse return error.InvalidHandle;
        const borrowed = record.borrowedStyle();
        if (borrowed.layout.display == .none or record.layout.bounds.isEmpty()) return;
        if (borrowed.layout.portal.target != .none and !portal_root) {
            try portals.append(self.scratch, .{
                .id = id,
                .order = borrowed.layout.portal.order,
                .sequence = portals.items.len,
            });
            return;
        }

        const has_transform = !std.meta.eql(borrowed.paint.transform, geometry.Affine2D.identity);
        const has_layer = has_transform or borrowed.paint.opacity < 0.9999;
        if (has_layer) _ = try self.builder.pushLayer(borrowed.paint.opacity, .normal, borrowed.paint.transform.around(record.layout.bounds.origin));

        for (borrowed.paint.shadows.values[0..borrowed.paint.shadows.count]) |shadow| {
            if (shadow.color.a <= 0) continue;
            try self.builder.shadow(.{
                .bounds = record.layout.bounds,
                .color = shadow.color,
                .radii = borrowed.paint.radii,
                .offset = shadow.offset,
                .blur_radius = @max(0, shadow.blur_radius),
                .spread = shadow.spread,
            });
        }

        const material = try self.materialForBrush(borrowed.paint.background, record.layout.bounds);
        const background = switch (borrowed.paint.background) {
            .solid => |color| color,
            else => geometry.Color.transparent,
        };
        const has_border = borrowed.paint.border.widths.horizontal() > 0 or borrowed.paint.border.widths.vertical() > 0;
        if (material != null or background.a > 0 or has_border) {
            try self.builder.quad(.{
                .bounds = record.layout.bounds,
                .background = background,
                .border_color = borrowed.paint.border.color,
                .border_widths = borrowed.paint.border.widths,
                .radii = borrowed.paint.radii,
            }, material);
        }

        const clips = clipsContents(borrowed.layout);
        if (clips) _ = try self.builder.pushClip(record.layout.bounds, borrowed.paint.radii);

        switch (record.kind) {
            .text => |value| {
                const text_painter = self.text orelse return error.TextUnavailable;
                try text_painter.paint(self.builder, value, borrowed.text, record.layout.content_bounds);
            },
            .image => |image| {
                const placement = image_fit.place(record.layout.content_bounds, image.source_width, image.source_height, image.fit);
                try self.builder.colorSprite(.{
                    .bounds = placement.bounds,
                    .uv_bounds = placement.uv_bounds,
                    .color = geometry.Color.white,
                    .texture = image.texture.encode(),
                    .tile_generation = image.texture.generation,
                    .format = @backingInt(abi.TextureFormat.rgba8),
                });
            },
            .custom => |custom_node| {
                const checkpoint = try self.builder.beginCustom();
                var context: custom.PaintContext = .{
                    .scene_context = self.builder,
                    .emit_fn = scene.Builder.emitCustom,
                    .scratch = self.scratch,
                    .scale_factor = self.scale_factor,
                    .text = if (self.text) |text_painter| text_painter.services() else null,
                    .svg = self.svg,
                };
                try custom_node.vtable.paint(custom_node.context, &context, record.layout.bounds);
                try self.builder.endCustom(checkpoint);
            },
            else => {},
        }

        var scroll_layer = false;
        switch (record.kind) {
            .scroll => |scroll| if (scroll.offset_x != 0 or scroll.offset_y != 0) {
                _ = try self.builder.pushLayer(1, .normal, geometry.Affine2D.translation(.{
                    .x = -scroll.offset_x,
                    .y = -scroll.offset_y,
                }));
                scroll_layer = true;
            },
            else => {},
        }
        for (record.children.items) |child| try self.paintNode(nodes, child, false, portals);
        if (scroll_layer) try self.builder.popLayer();
        if (clips) try self.builder.popClip();
        if (has_layer) try self.builder.popLayer();
    }

    fn materialForBrush(self: *Painter, brush: compose_style.Brush, bounds: geometry.Rect) Error!?u32 {
        return switch (brush) {
            .none => null,
            .solid => |color| try self.builder.solidMaterial(color),
            .linear_gradient => |gradient| blk: {
                if (gradient.stop_count == 0) break :blk null;
                var stops: [8]abi.GradientStop = undefined;
                for (gradient.stops[0..gradient.stop_count], 0..) |stop, index| {
                    stops[index] = .{ .offset = std.math.clamp(stop.offset, 0, 1), .color = stop.color };
                }
                const center: geometry.Point = .{
                    .x = bounds.origin.x + bounds.size.width / 2,
                    .y = bounds.origin.y + bounds.size.height / 2,
                };
                const direction: geometry.Point = .{
                    .x = @cos(gradient.angle_radians),
                    .y = @sin(gradient.angle_radians),
                };
                const half = (@abs(direction.x) * bounds.size.width + @abs(direction.y) * bounds.size.height) / 2;
                break :blk try self.builder.linearGradientMaterial(
                    .{ .x = center.x - direction.x * half, .y = center.y - direction.y * half },
                    .{ .x = center.x + direction.x * half, .y = center.y + direction.y * half },
                    stops[0..gradient.stop_count],
                );
            },
        };
    }
};

const PortalCandidate = struct {
    id: handles.NodeId,
    order: i32,
    sequence: usize,

    fn lessThan(_: void, left: PortalCandidate, right: PortalCandidate) bool {
        if (left.order != right.order) return left.order < right.order;
        return left.sequence < right.sequence;
    }
};

pub const Preparer = struct {
    scratch: std.mem.Allocator,
    scale_factor: geometry.ScaleFactor,
    device_generation: u32,

    pub fn prepare(self: *Preparer, nodes: *const compose_store.Store, root: handles.NodeId) Error!void {
        const record = nodes.getConst(root) orelse return error.InvalidHandle;
        if (record.borrowedStyle().layout.display == .none) return;
        switch (record.kind) {
            .custom => |custom_node| if (custom_node.vtable.prepare) |callback| {
                var context: custom.PrepareContext = .{
                    .allocator = self.scratch,
                    .scale_factor = self.scale_factor,
                    .device_generation = self.device_generation,
                };
                try callback(custom_node.context, &context, record.layout.bounds);
            },
            else => {},
        }
        for (record.children.items) |child| try self.prepare(nodes, child);
    }
};

fn clipsContents(value: layout.LayoutStyle) bool {
    return value.overflow_x == .hidden or value.overflow_x == .clip or value.overflow_x == .scroll or
        value.overflow_y == .hidden or value.overflow_y == .clip or value.overflow_y == .scroll;
}
