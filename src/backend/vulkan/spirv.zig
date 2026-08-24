//! Small, deterministic SPIR-V 1.5 module writer.
//!
//! ZigUI owns this writer so Linux builds never invoke a shader compiler.  It
//! emits only the instruction subset used by the framework shaders and keeps
//! the usual SPIR-V logical sections separate until `finish` serializes them.

const std = @import("std");
const Error = @import("../../core/error.zig").Error;

pub const Id = u32;
pub const magic: u32 = 0x0723_0203;
pub const version_1_5: u32 = 0x0001_0500;
pub const generator: u32 = 0x5a49_4701; // "ZIG" plus writer revision.

pub const Op = enum(u16) {
    nop = 0,
    name = 5,
    member_name = 6,
    extension = 10,
    ext_inst_import = 11,
    ext_inst = 12,
    memory_model = 14,
    entry_point = 15,
    execution_mode = 16,
    capability = 17,
    type_void = 19,
    type_bool = 20,
    type_int = 21,
    type_float = 22,
    type_vector = 23,
    type_matrix = 24,
    type_image = 25,
    type_sampled_image = 27,
    type_array = 28,
    type_runtime_array = 29,
    type_struct = 30,
    type_pointer = 32,
    type_function = 33,
    constant_true = 41,
    constant_false = 42,
    constant = 43,
    constant_composite = 44,
    function = 54,
    function_parameter = 55,
    function_end = 56,
    function_call = 57,
    variable = 59,
    load = 61,
    store = 62,
    access_chain = 65,
    decorate = 71,
    member_decorate = 72,
    vector_shuffle = 79,
    composite_construct = 80,
    composite_extract = 81,
    sampled_image = 86,
    image_sample_implicit_lod = 87,
    convert_f_to_u = 109,
    convert_f_to_s = 110,
    convert_s_to_f = 111,
    convert_u_to_f = 112,
    u_convert = 113,
    s_convert = 114,
    f_convert = 115,
    bitcast = 124,
    s_negate = 126,
    f_negate = 127,
    i_add = 128,
    f_add = 129,
    i_sub = 130,
    f_sub = 131,
    i_mul = 132,
    f_mul = 133,
    u_div = 134,
    s_div = 135,
    f_div = 136,
    vector_times_scalar = 142,
    matrix_times_vector = 145,
    dot = 148,
    any = 154,
    all = 155,
    logical_equal = 164,
    logical_not_equal = 165,
    logical_or = 166,
    logical_and = 167,
    logical_not = 168,
    select = 169,
    i_equal = 170,
    i_not_equal = 171,
    u_greater_than = 172,
    s_greater_than = 173,
    u_greater_than_equal = 174,
    s_greater_than_equal = 175,
    u_less_than = 176,
    s_less_than = 177,
    u_less_than_equal = 178,
    s_less_than_equal = 179,
    f_ord_equal = 180,
    f_ord_not_equal = 182,
    f_ord_less_than = 184,
    f_ord_greater_than = 186,
    f_ord_less_than_equal = 188,
    f_ord_greater_than_equal = 190,
    shift_right_logical = 194,
    shift_left_logical = 196,
    bitwise_or = 197,
    bitwise_xor = 198,
    bitwise_and = 199,
    dpdx = 207,
    dpdy = 208,
    fwidth = 209,
    phi = 245,
    loop_merge = 246,
    selection_merge = 247,
    label = 248,
    branch = 249,
    branch_conditional = 250,
    switch_ = 251,
    kill = 252,
    return_ = 253,
    return_value = 254,
};

pub const Section = enum {
    capabilities,
    extensions,
    imports,
    memory_model,
    entry_points,
    execution_modes,
    debug,
    annotations,
    declarations,
    functions,
};

pub const ExecutionModel = struct {
    pub const vertex: u32 = 0;
    pub const fragment: u32 = 4;
};
pub const ExecutionMode = struct {
    pub const origin_upper_left: u32 = 7;
};
pub const StorageClass = struct {
    pub const uniform_constant: u32 = 0;
    pub const input: u32 = 1;
    pub const uniform: u32 = 2;
    pub const output: u32 = 3;
    pub const function: u32 = 7;
    pub const push_constant: u32 = 9;
    pub const storage_buffer: u32 = 12;
};
pub const Decoration = struct {
    pub const block: u32 = 2;
    pub const array_stride: u32 = 6;
    pub const built_in: u32 = 11;
    pub const flat: u32 = 14;
    pub const non_writable: u32 = 24;
    pub const location: u32 = 30;
    pub const binding: u32 = 33;
    pub const descriptor_set: u32 = 34;
    pub const offset: u32 = 35;
};
pub const BuiltIn = struct {
    pub const position: u32 = 0;
    pub const vertex_index: u32 = 42;
    pub const instance_index: u32 = 43;
};
pub const Capability = struct {
    pub const shader: u32 = 1;
};
pub const AddressingModel = struct {
    pub const logical: u32 = 0;
};
pub const MemoryModel = struct {
    pub const glsl_450: u32 = 1;
};
pub const Dim = struct {
    pub const two_d: u32 = 1;
};
pub const ImageFormat = struct {
    pub const unknown: u32 = 0;
};
pub const FunctionControl = struct {
    pub const none: u32 = 0;
};
pub const SelectionControl = struct {
    pub const none: u32 = 0;
};
pub const LoopControl = struct {
    pub const none: u32 = 0;
};

pub const Glsl450 = struct {
    pub const round: u32 = 1;
    pub const trunc: u32 = 3;
    pub const abs: u32 = 4;
    pub const floor: u32 = 8;
    pub const ceil: u32 = 9;
    pub const fract: u32 = 10;
    pub const sin: u32 = 13;
    pub const cos: u32 = 14;
    pub const pow: u32 = 26;
    pub const exp: u32 = 27;
    pub const sqrt: u32 = 31;
    pub const min: u32 = 37;
    pub const max: u32 = 40;
    pub const clamp: u32 = 43;
    pub const mix: u32 = 46;
    pub const step: u32 = 48;
    pub const smooth_step: u32 = 49;
    pub const length: u32 = 66;
};

const Sections = struct {
    capabilities: std.ArrayList(u32) = .empty,
    extensions: std.ArrayList(u32) = .empty,
    imports: std.ArrayList(u32) = .empty,
    memory_model: std.ArrayList(u32) = .empty,
    entry_points: std.ArrayList(u32) = .empty,
    execution_modes: std.ArrayList(u32) = .empty,
    debug: std.ArrayList(u32) = .empty,
    annotations: std.ArrayList(u32) = .empty,
    declarations: std.ArrayList(u32) = .empty,
    functions: std.ArrayList(u32) = .empty,

    fn list(self: *Sections, section: Section) *std.ArrayList(u32) {
        return switch (section) {
            .capabilities => &self.capabilities,
            .extensions => &self.extensions,
            .imports => &self.imports,
            .memory_model => &self.memory_model,
            .entry_points => &self.entry_points,
            .execution_modes => &self.execution_modes,
            .debug => &self.debug,
            .annotations => &self.annotations,
            .declarations => &self.declarations,
            .functions => &self.functions,
        };
    }

    fn deinit(self: *Sections, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(Sections).@"struct".field_names) |field_name| @field(self, field_name).deinit(allocator);
        self.* = undefined;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    sections: Sections = .{},
    next_id: Id = 1,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        self.sections.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn id(self: *Builder) Error!Id {
        if (self.next_id == std.math.maxInt(Id)) return error.BudgetExceeded;
        defer self.next_id += 1;
        return self.next_id;
    }

    pub fn emit(self: *Builder, section: Section, op: Op, operands: []const u32) Error!void {
        const word_count = std.math.add(usize, operands.len, 1) catch return error.BudgetExceeded;
        if (word_count > std.math.maxInt(u16)) return error.BudgetExceeded;
        const first = (@as(u32, @intCast(word_count)) << 16) | @backingInt(op);
        const list = self.sections.list(section);
        try list.ensureUnusedCapacity(self.allocator, word_count);
        list.appendAssumeCapacity(first);
        list.appendSliceAssumeCapacity(operands);
    }

    pub fn emitString(
        self: *Builder,
        section: Section,
        op: Op,
        prefix: []const u32,
        value: []const u8,
        suffix: []const u32,
    ) Error!void {
        const string_words = (value.len + 1 + 3) / 4;
        const operand_count = std.math.add(usize, prefix.len, string_words) catch return error.BudgetExceeded;
        const total_operands = std.math.add(usize, operand_count, suffix.len) catch return error.BudgetExceeded;
        const word_count = std.math.add(usize, total_operands, 1) catch return error.BudgetExceeded;
        if (word_count > std.math.maxInt(u16)) return error.BudgetExceeded;
        const list = self.sections.list(section);
        try list.ensureUnusedCapacity(self.allocator, word_count);
        list.appendAssumeCapacity((@as(u32, @intCast(word_count)) << 16) | @backingInt(op));
        list.appendSliceAssumeCapacity(prefix);
        var word: u32 = 0;
        var byte_index: usize = 0;
        while (byte_index < string_words * 4) : (byte_index += 1) {
            if (byte_index < value.len) word |= @as(u32, value[byte_index]) << @intCast((byte_index & 3) * 8);
            if (byte_index & 3 == 3) {
                list.appendAssumeCapacity(word);
                word = 0;
            }
        }
        list.appendSliceAssumeCapacity(suffix);
    }

    pub fn capability(self: *Builder, value: u32) Error!void {
        try self.emit(.capabilities, .capability, &.{value});
    }

    pub fn memoryModel(self: *Builder) Error!void {
        try self.emit(.memory_model, .memory_model, &.{ AddressingModel.logical, MemoryModel.glsl_450 });
    }

    pub fn importGlsl450(self: *Builder) Error!Id {
        const result = try self.id();
        try self.emitString(.imports, .ext_inst_import, &.{result}, "GLSL.std.450", &.{});
        return result;
    }

    pub fn name(self: *Builder, target: Id, value: []const u8) Error!void {
        try self.emitString(.debug, .name, &.{target}, value, &.{});
    }

    pub fn memberName(self: *Builder, target: Id, member: u32, value: []const u8) Error!void {
        try self.emitString(.debug, .member_name, &.{ target, member }, value, &.{});
    }

    pub fn decorate(self: *Builder, target: Id, decoration: u32, literals: []const u32) Error!void {
        var small: [8]u32 = undefined;
        if (literals.len + 2 <= small.len) {
            small[0] = target;
            small[1] = decoration;
            @memcpy(small[2 .. 2 + literals.len], literals);
            return self.emit(.annotations, .decorate, small[0 .. 2 + literals.len]);
        }
        var values = try self.allocator.alloc(u32, literals.len + 2);
        defer self.allocator.free(values);
        values[0] = target;
        values[1] = decoration;
        @memcpy(values[2..], literals);
        try self.emit(.annotations, .decorate, values);
    }

    pub fn memberDecorate(self: *Builder, target: Id, member: u32, decoration: u32, literals: []const u32) Error!void {
        var small: [9]u32 = undefined;
        if (literals.len + 3 <= small.len) {
            small[0] = target;
            small[1] = member;
            small[2] = decoration;
            @memcpy(small[3 .. 3 + literals.len], literals);
            return self.emit(.annotations, .member_decorate, small[0 .. 3 + literals.len]);
        }
        var values = try self.allocator.alloc(u32, literals.len + 3);
        defer self.allocator.free(values);
        values[0] = target;
        values[1] = member;
        values[2] = decoration;
        @memcpy(values[3..], literals);
        try self.emit(.annotations, .member_decorate, values);
    }

    pub fn entryPoint(self: *Builder, model: u32, function: Id, name_value: []const u8, interfaces: []const Id) Error!void {
        try self.emitString(.entry_points, .entry_point, &.{ model, function }, name_value, interfaces);
    }

    pub fn executionMode(self: *Builder, function: Id, mode: u32, literals: []const u32) Error!void {
        var values = try self.allocator.alloc(u32, literals.len + 2);
        defer self.allocator.free(values);
        values[0] = function;
        values[1] = mode;
        @memcpy(values[2..], literals);
        try self.emit(.execution_modes, .execution_mode, values);
    }

    pub fn instruction(self: *Builder, section: Section, op: Op, operands: []const u32) Error!void {
        try self.emit(section, op, operands);
    }

    pub fn finish(self: *Builder, allocator: std.mem.Allocator) Error![]u32 {
        var total: usize = 5;
        inline for (@typeInfo(Sections).@"struct".field_names) |field_name|
            total = std.math.add(usize, total, @field(self.sections, field_name).items.len) catch return error.BudgetExceeded;
        const result = try allocator.alloc(u32, total);
        result[0] = magic;
        result[1] = version_1_5;
        result[2] = generator;
        result[3] = self.next_id;
        result[4] = 0;
        var cursor: usize = 5;
        inline for (@typeInfo(Sections).@"struct".field_names) |field_name| {
            const source = @field(self.sections, field_name).items;
            @memcpy(result[cursor .. cursor + source.len], source);
            cursor += source.len;
        }
        return result;
    }
};
