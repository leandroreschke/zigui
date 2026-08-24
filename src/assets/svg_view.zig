const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const component = @import("../compose/component.zig");
const custom = @import("../compose/custom.zig");
const node = @import("../compose/node.zig");
const layout = @import("../layout/style.zig");
const svg = @import("svg.zig");

/// Source-only vector element. Applications import this type only when they
/// render SVG assets; the element resolves its generational handle through the
/// owning App rather than borrowing document memory.
pub const View = struct {
    asset: handles.SvgId,
    fit: svg.Fit = .contain,
    label: []const u8 = "",

    pub fn build(self: *View, _: *component.BuildContext) Error!node.Spec {
        return .{
            .kind = .{ .custom = custom.Node.from(View, self) },
            .semantics = .{ .role = .image, .label = self.label },
        };
    }

    pub fn measure(self: *View, context: *custom.MeasureContext, constraints: layout.Constraints) Error!geometry.Size {
        const services = context.svg orelse return error.MissingCapability;
        return services.measure(self.asset, constraints);
    }

    pub fn paint(self: *View, context: *custom.PaintContext, bounds: geometry.Rect) Error!void {
        const services = context.svg orelse return error.MissingCapability;
        try services.paint(context.scene_context, self.asset, bounds, @backingInt(self.fit));
    }
};
