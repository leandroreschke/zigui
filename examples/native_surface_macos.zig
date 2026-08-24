//! Native Metal texture provider used by `surface_lab`.
//!
//! This deliberately lives in the proof application rather than ZigUI's
//! engine. Applications and media providers own external images; ZigUI only
//! borrows, retains, samples, and submission-retires the supplied handle.

const std = @import("std");
const ui = @import("zigui");

const Id = ?*anyopaque;
const Sel = ?*anyopaque;

extern "c" fn MTLCreateSystemDefaultDevice() Id;
extern "c" fn objc_getClass(name: [*:0]const u8) Id;
extern "c" fn sel_registerName(name: [*:0]const u8) Sel;

const Origin = extern struct { x: usize, y: usize, z: usize };
const Extent = extern struct { width: usize, height: usize, depth: usize };
const Region = extern struct { origin: Origin, size: Extent };

pub const Owned = struct {
    texture: Id,
    width: u32,
    height: u32,

    pub fn create(allocator: std.mem.Allocator, width: u32, height: u32) ui.Error!Owned {
        if (width == 0 or height == 0) return error.InvalidConfiguration;
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoGpuDevice;
        defer release(device);

        const texture_descriptor = send(
            Id,
            objc_getClass("MTLTextureDescriptor"),
            "texture2DDescriptorWithPixelFormat:width:height:mipmapped:",
            .{ @as(usize, 81), @as(usize, width), @as(usize, height), false },
        ) orelse return error.NoGpuDevice;
        send(void, texture_descriptor, "setUsage:", .{@as(usize, 1)});
        send(void, texture_descriptor, "setStorageMode:", .{@as(usize, 0)});
        const texture = send(Id, device, "newTextureWithDescriptor:", .{texture_descriptor}) orelse return error.NoGpuDevice;
        errdefer release(texture);

        const pixel_width: usize = @intCast(width);
        const pixel_height: usize = @intCast(height);
        const pixel_count = std.math.mul(usize, pixel_width, pixel_height) catch return error.BudgetExceeded;
        const byte_count = std.math.mul(usize, pixel_count, 4) catch return error.BudgetExceeded;
        const pixels = try allocator.alloc(u8, byte_count);
        defer allocator.free(pixels);
        for (0..pixel_height) |y| for (0..pixel_width) |x| {
            const offset = (y * pixel_width + x) * 4;
            const checker = (x / 8 + y / 8) % 2 == 0;
            pixels[offset + 0] = @intCast(72 + (y * 151) / @max(@as(usize, 1), pixel_height -| 1));
            pixels[offset + 1] = if (checker) 214 else 92;
            pixels[offset + 2] = @intCast(66 + (x * 171) / @max(@as(usize, 1), pixel_width -| 1));
            pixels[offset + 3] = 255;
        };
        send(void, texture, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .size = .{ .width = pixel_width, .height = pixel_height, .depth = 1 },
            },
            @as(usize, 0),
            pixels.ptr,
            pixel_width * 4,
        });
        return .{ .texture = texture, .width = width, .height = height };
    }

    pub fn descriptor(self: *const Owned) ui.render.ExternalSurfaceDescriptor {
        return .{
            .width = self.width,
            .height = self.height,
            .format = .bgra8_srgb,
            .color_space = .srgb,
            .native = .{ .metal_texture = @intFromPtr(self.texture.?) },
        };
    }

    pub fn deinit(self: *Owned) void {
        release(self.texture);
        self.* = undefined;
    }
};

fn send(comptime Return: type, receiver: Id, selector_name: [*:0]const u8, arguments: anytype) Return {
    const function = messageFunction(Return, @TypeOf(arguments));
    return @call(.auto, function, .{ receiver, sel_registerName(selector_name) } ++ arguments);
}

fn release(value: Id) void {
    if (value != null) send(void, value, "release", .{});
}

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
    inline for (argument_info.field_types, 0..) |Argument, index| parameter_types[index + 2] = parameterType(Argument);
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
