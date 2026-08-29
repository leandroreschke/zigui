const std = @import("std");

pub const Id = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Imp = *const anyopaque;
pub const Ivar = ?*anyopaque;
pub const Protocol = ?*anyopaque;

pub const Super = extern struct {
    receiver: Id,
    super_class: Class,
};

pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn class_addMethod(cls: Class, name: Sel, implementation: Imp, types: [*:0]const u8) bool;
pub extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) bool;
pub extern "c" fn class_addProtocol(cls: Class, protocol: Protocol) bool;
pub extern "c" fn class_getSuperclass(cls: Class) Class;
pub extern "c" fn object_getClass(object: Id) Class;
pub extern "c" fn object_setIvar(object: Id, ivar: Ivar, value: Id) void;
pub extern "c" fn object_getIvar(object: Id, ivar: Ivar) Id;
pub extern "c" fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) Ivar;
pub extern "c" fn ivar_getOffset(ivar: Ivar) isize;
pub extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
pub extern "c" fn objc_getProtocol(name: [*:0]const u8) Protocol;

pub fn class(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

pub fn selector(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

pub fn send(comptime Return: type, receiver: Id, selector_name: [*:0]const u8, arguments: anytype) Return {
    const function = messageFunction(Return, @TypeOf(arguments));
    return @call(.auto, function, .{ receiver, selector(selector_name) } ++ arguments);
}

pub fn sendSel(comptime Return: type, receiver: Id, selected: Sel, arguments: anytype) Return {
    const function = messageFunction(Return, @TypeOf(arguments));
    return @call(.auto, function, .{ receiver, selected } ++ arguments);
}

pub fn sendSuper(comptime Return: type, receiver: Id, superclass: Class, selector_name: [*:0]const u8, arguments: anytype) Return {
    var description: Super = .{ .receiver = receiver, .super_class = superclass };
    const Function = messageFunctionType(*Super, Return, @TypeOf(arguments));
    const function: Function = if (comptime usesStructReturn(Return))
        @extern(Function, .{ .name = "objc_msgSendSuper_stret" })
    else
        @extern(Function, .{ .name = "objc_msgSendSuper" });
    return @call(.auto, function, .{ &description, selector(selector_name) } ++ arguments);
}

pub fn nsString(bytes: []const u8) Id {
    const string_class = class("NSString");
    return send(Id, string_class, "stringWithBytes:length:encoding:", .{ bytes.ptr, bytes.len, @as(usize, 4) });
}

pub fn utf8(string: Id) []const u8 {
    if (string == null) return "";
    const pointer = send(?[*:0]const u8, string, "UTF8String", .{}) orelse return "";
    return std.mem.span(pointer);
}

pub fn retain(value: Id) Id {
    if (value == null) return null;
    return send(Id, value, "retain", .{});
}

pub fn release(value: Id) void {
    if (value != null) send(void, value, "release", .{});
}

pub fn autorelease(value: Id) Id {
    if (value == null) return null;
    return send(Id, value, "autorelease", .{});
}

pub fn arrayWithObject(value: Id) Id {
    return send(Id, class("NSArray"), "arrayWithObject:", .{value});
}

/// Builds an NSArray through the fixed-arity count API. The convenient
/// `arrayWithObjects:` selector is variadic; dispatching it through a typed
/// objc_msgSend function pointer is not ABI-safe on every macOS build.
pub fn arrayWithObjects(objects: []const Id) Id {
    return send(Id, class("NSArray"), "arrayWithObjects:count:", .{ objects.ptr, objects.len });
}

pub fn setIvar(comptime T: type, object: Id, name: [*:0]const u8, value: T) bool {
    const raw_object = object orelse return false;
    const target_class = object_getClass(object) orelse return false;
    const ivar = class_getInstanceVariable(target_class, name) orelse return false;
    const base: [*]u8 = @ptrCast(raw_object);
    const pointer: *T = @ptrCast(@alignCast(base + @as(usize, @intCast(ivar_getOffset(ivar)))));
    pointer.* = value;
    return true;
}

pub fn getIvar(comptime T: type, object: Id, name: [*:0]const u8) ?T {
    const raw_object = object orelse return null;
    const target_class = object_getClass(object) orelse return null;
    const ivar = class_getInstanceVariable(target_class, name) orelse return null;
    const base: [*]const u8 = @ptrCast(raw_object);
    const pointer: *const T = @ptrCast(@alignCast(base + @as(usize, @intCast(ivar_getOffset(ivar)))));
    return pointer.*;
}

pub fn addIvar(comptime T: type, target: Class, name: [*:0]const u8, encoding: [*:0]const u8) bool {
    const alignment: u8 = @intCast(@ctz(@as(usize, @alignOf(T))));
    return class_addIvar(target, name, @sizeOf(T), alignment, encoding);
}

pub const AutoreleasePool = struct {
    value: Id,

    pub fn init() AutoreleasePool {
        return .{ .value = send(Id, send(Id, class("NSAutoreleasePool"), "alloc", .{}), "init", .{}) };
    }

    pub fn deinit(self: *AutoreleasePool) void {
        send(void, self.value, "drain", .{});
        self.* = undefined;
    }
};

fn messageFunction(comptime Return: type, comptime Arguments: type) messageFunctionType(Id, Return, Arguments) {
    const Function = messageFunctionType(Id, Return, Arguments);
    return if (comptime usesStructReturn(Return))
        @extern(Function, .{ .name = "objc_msgSend_stret" })
    else
        @extern(Function, .{ .name = "objc_msgSend" });
}

fn messageFunctionType(comptime Receiver: type, comptime Return: type, comptime Arguments: type) type {
    const argument_info = @typeInfo(Arguments).@"struct";
    const ParamAttributes = @TypeOf(@typeInfo(fn (usize) void).@"fn".param_attrs[0]);
    var parameter_types: [argument_info.field_types.len + 2]type = undefined;
    var parameter_attributes: [parameter_types.len]ParamAttributes = @splat(.{});
    parameter_types[0] = Receiver;
    parameter_types[1] = Sel;
    inline for (argument_info.field_types, 0..) |Argument, index| {
        parameter_types[index + 2] = parameterType(Argument);
    }
    const Function = @Fn(
        &parameter_types,
        &parameter_attributes,
        Return,
        .{ .@"callconv" = .c, .varargs = false },
    );
    return *const Function;
}

fn parameterType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .null => Id,
        .comptime_int => usize,
        .comptime_float => f64,
        else => T,
    };
}

fn usesStructReturn(comptime Return: type) bool {
    if (@import("builtin").target.cpu.arch == .aarch64) return false;
    return switch (@typeInfo(Return)) {
        .@"struct", .@"union" => @sizeOf(Return) > 16,
        else => false,
    };
}

test "macOS object arrays use fixed-arity Objective-C dispatch" {
    var pool = AutoreleasePool.init();
    defer pool.deinit();

    const values = [_]Id{ nsString("first"), nsString("second") };
    const array = arrayWithObjects(values[0..]) orelse return error.PlatformFailure;
    try std.testing.expectEqual(@as(usize, values.len), send(usize, array, "count", .{}));
}
