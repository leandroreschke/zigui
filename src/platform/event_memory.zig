const std = @import("std");
const Error = @import("../core/error.zig").Error;

/// Exact allocator-owned payload retained by one queued native event. The
/// platform queue owns both the path slice descriptors and every path byte.
pub fn ownedPayloadBytes(text: ?[]const u8, paths: ?[]const []const u8) Error!usize {
    var total: usize = 0;
    if (text) |value|
        total = std.math.add(usize, total, value.len) catch return error.BudgetExceeded;
    if (paths) |values| {
        total = std.math.add(
            usize,
            total,
            std.math.mul(usize, values.len, @sizeOf([]const u8)) catch return error.BudgetExceeded,
        ) catch return error.BudgetExceeded;
        for (values) |value|
            total = std.math.add(usize, total, value.len) catch return error.BudgetExceeded;
    }
    return total;
}

pub fn ensureFits(
    text: ?[]const u8,
    paths: ?[]const []const u8,
    used: usize,
    maximum: usize,
) Error!usize {
    const amount = try ownedPayloadBytes(text, paths);
    if (amount > maximum -| used) return error.BudgetExceeded;
    return amount;
}

/// Tracks exact allocator-owned strings retained by a platform context. A
/// replacement allocates before releasing the previous value, but the logical
/// budget is charged against the post-commit state so updates retain a strong
/// failure guarantee without requiring double steady-state capacity.
pub const RetainedTextBudget = struct {
    maximum_bytes: usize,
    used_bytes: usize = 0,

    pub fn init(maximum_bytes: usize) Error!RetainedTextBudget {
        if (maximum_bytes == 0) return error.InvalidConfiguration;
        return .{ .maximum_bytes = maximum_bytes };
    }

    pub fn duplicate(
        self: *RetainedTextBudget,
        allocator: std.mem.Allocator,
        source: []const u8,
    ) Error![]u8 {
        if (source.len > self.maximum_bytes -| self.used_bytes)
            return error.BudgetExceeded;
        const owned = try allocator.dupe(u8, source);
        self.used_bytes += owned.len;
        return owned;
    }

    pub fn replace(
        self: *RetainedTextBudget,
        allocator: std.mem.Allocator,
        destination: *?[]u8,
        source: []const u8,
    ) Error!void {
        const old_bytes = if (destination.*) |value| value.len else 0;
        std.debug.assert(old_bytes <= self.used_bytes);
        const retained_without_old = self.used_bytes - old_bytes;
        if (source.len > self.maximum_bytes -| retained_without_old)
            return error.BudgetExceeded;
        const replacement = try allocator.dupe(u8, source);
        if (destination.*) |existing| allocator.free(existing);
        destination.* = replacement;
        self.used_bytes = retained_without_old + replacement.len;
    }

    /// Adopts an already allocated replacement after the caller has finished
    /// fallible population or validation of its bytes.
    pub fn adoptReplacement(
        self: *RetainedTextBudget,
        allocator: std.mem.Allocator,
        destination: *?[]u8,
        replacement: []u8,
    ) Error!void {
        const old_bytes = if (destination.*) |value| value.len else 0;
        std.debug.assert(old_bytes <= self.used_bytes);
        const retained_without_old = self.used_bytes - old_bytes;
        if (replacement.len > self.maximum_bytes -| retained_without_old)
            return error.BudgetExceeded;
        if (destination.*) |existing| allocator.free(existing);
        destination.* = replacement;
        self.used_bytes = retained_without_old + replacement.len;
    }

    pub fn release(
        self: *RetainedTextBudget,
        allocator: std.mem.Allocator,
        destination: *?[]u8,
    ) void {
        const value = destination.* orelse return;
        std.debug.assert(value.len <= self.used_bytes);
        self.used_bytes -= value.len;
        allocator.free(value);
        destination.* = null;
    }
};
