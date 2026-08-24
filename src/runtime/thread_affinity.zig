const std = @import("std");

pub const ThreadAffinity = struct {
    owner: std.Thread.Id,

    pub fn capture() ThreadAffinity {
        return .{ .owner = std.Thread.getCurrentId() };
    }

    pub fn isCurrent(self: ThreadAffinity) bool {
        return self.owner == std.Thread.getCurrentId();
    }

    pub fn assertCurrent(self: ThreadAffinity) error{ThreadAffinity}!void {
        if (!self.isCurrent()) return error.ThreadAffinity;
    }
};
