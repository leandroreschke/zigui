const std = @import("std");
const geometry = @import("../core/geometry.zig");

pub const Length = union(enum) {
    auto,
    points: f32,
    percent: f32,
    fraction: f32,

    pub fn resolve(self: Length, available: f32) ?f32 {
        return switch (self) {
            .auto => null,
            .points => |value| value,
            .percent => |value| if (std.math.isFinite(available)) available * value else null,
            .fraction => null,
        };
    }
};

pub const Display = enum { flex, grid, none };
pub const Position = enum { relative, absolute };
pub const Axis = enum { horizontal, vertical };
pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum { no_wrap, wrap, wrap_reverse };
pub const Align = enum { auto, start, center, end, stretch, baseline };
pub const Justify = enum { start, center, end, space_between, space_around, space_evenly };
pub const Overflow = enum { visible, hidden, scroll, clip };

/// Moves a logically-owned subtree into a window-level visual stacking
/// context. Portals remain descendants for events, focus, and accessibility;
/// only layout containment, clipping, transforms, and paint order change.
pub const PortalTarget = enum { none, anchor, viewport };
pub const PortalPlacement = enum { inset, fill, above, below, left, right, center };
pub const PortalAlignment = enum { start, center, end };
pub const PortalAnchorSize = enum { none, minimum, exact };

pub const PortalStyle = struct {
    target: PortalTarget = .none,
    placement: PortalPlacement = .inset,
    alignment: PortalAlignment = .start,
    anchor_width: PortalAnchorSize = .none,
    anchor_height: PortalAnchorSize = .none,
    gap: f32 = 0,
    viewport_margin: f32 = 8,
    flip: bool = true,
    clamp_to_viewport: bool = true,
    /// Portals are sorted by this value inside their nearest portal stacking
    /// context. Equal values preserve logical document order.
    order: i32 = 0,

    pub const Order = struct {
        pub const popover: i32 = 100;
        pub const tooltip: i32 = 200;
        pub const modal: i32 = 300;
    };
};

pub const LengthEdges = struct {
    top: Length = .{ .points = 0 },
    right: Length = .{ .points = 0 },
    bottom: Length = .{ .points = 0 },
    left: Length = .{ .points = 0 },

    pub fn all(value: Length) LengthEdges {
        return .{ .top = value, .right = value, .bottom = value, .left = value };
    }
};

pub const GridTrack = union(enum) {
    auto,
    points: f32,
    percent: f32,
    fraction: f32,
    minmax: struct { min: Length, max: Length },
};

pub const LayoutStyle = struct {
    display: Display = .flex,
    position: Position = .relative,
    portal: PortalStyle = .{},
    direction: FlexDirection = .column,
    wrap: FlexWrap = .no_wrap,
    width: Length = .auto,
    height: Length = .auto,
    min_width: Length = .{ .points = 0 },
    min_height: Length = .{ .points = 0 },
    max_width: Length = .auto,
    max_height: Length = .auto,
    margin: LengthEdges = .{},
    padding: LengthEdges = .{},
    inset: LengthEdges = .{ .top = .auto, .right = .auto, .bottom = .auto, .left = .auto },
    gap: geometry.Size = .{},
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Length = .auto,
    align_items: Align = .stretch,
    align_content: Align = .stretch,
    align_self: Align = .auto,
    justify_content: Justify = .start,
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,
    aspect_ratio: ?f32 = null,
    grid_columns: []const GridTrack = &.{},
    grid_rows: []const GridTrack = &.{},
    grid_column: u16 = 0,
    grid_row: u16 = 0,
    grid_column_span: u16 = 1,
    grid_row_span: u16 = 1,
};

pub const Constraints = struct {
    minimum: geometry.Size = .zero,
    maximum: geometry.Size = .unbounded,

    pub fn constrain(self: Constraints, size: geometry.Size) geometry.Size {
        return size.clamp(self.minimum, self.maximum);
    }
};

pub const LayoutResult = struct {
    bounds: geometry.Rect = .{},
    content_bounds: geometry.Rect = .{},
    scroll_extent: geometry.Size = .{},
    baseline: ?f32 = null,
};

pub const Dirty = packed struct {
    compose: bool = true,
    layout: bool = true,
    paint: bool = true,
    hit_test: bool = true,
    semantics: bool = true,
    resources: bool = true,
    _padding: u2 = 0,

    pub fn any(self: Dirty) bool {
        return self.compose or self.layout or self.paint or self.hit_test or self.semantics or self.resources;
    }

    pub fn merge(self: *Dirty, other: Dirty) void {
        self.compose = self.compose or other.compose;
        self.layout = self.layout or other.layout;
        self.paint = self.paint or other.paint;
        self.hit_test = self.hit_test or other.hit_test;
        self.semantics = self.semantics or other.semantics;
        self.resources = self.resources or other.resources;
    }
};
