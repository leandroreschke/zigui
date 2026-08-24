const input = @import("../input/event.zig");
const Error = @import("../core/error.zig").Error;

pub const Callback = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, *input.Context) Error!void,

    pub fn call(self: Callback, event_context: *input.Context) Error!void {
        try self.callback(self.context, event_context);
    }

    pub fn from(comptime T: type, value: *T, comptime method_name: []const u8) Callback {
        return .{
            .context = value,
            .callback = struct {
                fn invoke(context: *anyopaque, event_context: *input.Context) Error!void {
                    const target: *T = @ptrCast(@alignCast(context));
                    const Method = @TypeOf(@field(T, method_name));
                    const Return = @typeInfo(Method).@"fn".return_type.?;
                    if (comptime Return == void) {
                        @field(T, method_name)(target, event_context);
                    } else {
                        try @field(T, method_name)(target, event_context);
                    }
                }
            }.invoke,
        };
    }
};
