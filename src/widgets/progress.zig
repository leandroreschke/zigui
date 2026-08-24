const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const Theme = @import("theme.zig").Theme;

pub const Progress = struct {
    value: ?f64,
    theme: *const Theme = &Theme.dark,
    label: []const u8 = "",

    pub fn build(self: *const Progress, ctx: *component.BuildContext) Error!node.Spec {
        if (self.value) |value| if (!std.math.isFinite(value)) return error.InvalidConfiguration;
        const clamped_value = std.math.clamp(self.value orelse 0, 0, 1);
        const fraction: f32 = @floatCast(clamped_value);
        var value_buffer: [32]u8 = undefined;
        const semantic_value = if (self.value != null) std.fmt.bufPrint(&value_buffer, "{d:.0}%", .{clamped_value * 100}) catch "" else "Loading";
        const child = try ctx.allocator.alloc(node.Spec, 1);
        child[0] = .{
            .kind = .container,
            .style = .{
                .layout = .{ .width = .{ .percent = fraction }, .height = .{ .percent = 1 } },
                .paint = .{ .background = .{ .solid = self.theme.accent }, .radii = geometry.CornerRadii.all(3) },
            },
        };
        return .{
            .kind = .container,
            .style = .{
                .layout = .{ .width = .{ .percent = 1 }, .height = .{ .points = 6 }, .overflow_x = .hidden },
                .paint = .{ .background = .{ .solid = self.theme.surface_pressed }, .radii = geometry.CornerRadii.all(3) },
            },
            .semantics = .{ .role = .progress_indicator, .label = self.label, .value = try ctx.allocator.dupe(u8, semantic_value) },
            .children = child,
        };
    }
};
