const std = @import("std");
const Error = @import("../../core/error.zig").Error;
const win = @import("../../platform/windows/abi.zig");
const abi = @import("abi.zig");

const library_name = std.unicode.utf8ToUtf16LeStringLiteral("d3dcompiler_47.dll");

const CompileFunction = *const fn (
    source: *const anyopaque,
    source_length: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entry: [*:0]const u8,
    target: [*:0]const u8,
    flags: u32,
    secondary_flags: u32,
    bytecode: *?*abi.Object,
    errors: *?*abi.Object,
) callconv(.winapi) win.HRESULT;

pub const Bytecode = struct {
    blob: *abi.Object,

    pub fn bytes(self: Bytecode) []const u8 {
        const PointerFunction = *const fn (*abi.Object) callconv(.winapi) ?*const anyopaque;
        const SizeFunction = *const fn (*abi.Object) callconv(.winapi) usize;
        const pointer = abi.com.method(PointerFunction, self.blob, 3)(self.blob) orelse return &.{};
        const length = abi.com.method(SizeFunction, self.blob, 4)(self.blob);
        return @as([*]const u8, @ptrCast(pointer))[0..length];
    }

    pub fn deinit(self: *Bytecode) void {
        abi.com.release(self.blob);
        self.* = undefined;
    }
};

pub const Compiler = struct {
    module: win.HMODULE,
    compile_fn: CompileFunction,

    pub fn load() Error!Compiler {
        const module = win.LoadLibraryW(library_name) orelse return error.ShaderInvalid;
        errdefer _ = win.FreeLibrary(module);
        const symbol = win.GetProcAddress(module, "D3DCompile") orelse return error.ShaderInvalid;
        return .{ .module = module, .compile_fn = @ptrCast(symbol) };
    }

    pub fn compile(self: Compiler, source: []const u8, entry: [*:0]const u8, target: [*:0]const u8) Error!Bytecode {
        var result: ?*abi.Object = null;
        var diagnostics: ?*abi.Object = null;
        defer abi.com.release(diagnostics);
        const strictness: u32 = 1 << 11;
        const optimization_level_3: u32 = 1 << 15;
        const status = self.compile_fn(
            source.ptr,
            source.len,
            "zigui.hlsl",
            null,
            null,
            entry,
            target,
            strictness | optimization_level_3,
            0,
            &result,
            &diagnostics,
        );
        if (status < 0) return error.ShaderInvalid;
        return .{ .blob = result orelse return error.ShaderInvalid };
    }

    pub fn deinit(self: *Compiler) void {
        if (self.module != null) _ = win.FreeLibrary(self.module);
        self.* = undefined;
    }
};
