const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");

pub const DeviceGeneration = u32;
pub const SubmissionEpoch = u64;

pub const DepthFormat = enum(u32) {
    depth32_float,
};

/// Framework-owned depth storage requested by an extension. The attachment is
/// cleared by default and is borrowed only for that encode. Set load_flag to
/// preserve depth from an earlier pass on the same target in this frame.
pub const DepthRequest = struct {
    format: DepthFormat = .depth32_float,
    clear_depth: f32 = 1,
    /// When set, a pass whose flags contain this bit loads the depth target
    /// left by the previous pass for this frame. This lets a single extension
    /// submit an opaque pass followed by a water pass without clearing away
    /// the scene depth between them.
    load_flag: ?u32 = null,
};

pub const SnapshotRequest = struct {
    color: bool = true,
    depth: bool = false,
    /// Restrict capture to passes carrying this flag. This is useful when an
    /// extension uses one descriptor for an opaque prepass followed by a
    /// sampling pass: the first pass must not receive an uninitialized
    /// snapshot of its own attachments.
    when_flag: ?u32 = null,
};

pub const Requirements = struct {
    depth: ?DepthRequest = null,
    snapshot: ?SnapshotRequest = null,
};

pub const DepthAttachment = struct {
    texture: usize,
    format: DepthFormat,
};

/// Immutable copies of the target before this pass. Borrowed during encode;
/// depth requires an earlier depth-writing pass on the same target this frame.
pub const SnapshotAttachments = struct {
    color: ?usize = null,
    depth: ?usize = null,
};

pub const Backend = enum { null, metal, d3d11, vulkan };

pub const Device = union(Backend) {
    null: void,
    metal: struct { device: usize, command_queue: usize },
    d3d11: struct { device: usize, immediate_context: usize },
    vulkan: struct {
        instance: usize,
        physical_device: usize,
        device: usize,
        graphics_queue: usize,
        queue_family: u32,
        device_dispatch: *const anyopaque,
    },
};

pub const Geometry = struct {
    window: handles.WindowId,
    logical_size: geometry.Size,
    drawable_width: u32,
    drawable_height: u32,
    scale_factor: geometry.ScaleFactor,
    clear_color: geometry.Color,
    bounds: geometry.Rect,
    clip: geometry.Rect,
    transform: geometry.Affine2D,
    opacity: f32,
    target_origin: geometry.Point,
    target_width: u32,
    target_height: u32,
};

/// Native command state borrowed only for the duration of `encode`. An
/// extension must not end the active Metal encoder or Vulkan dynamic-rendering
/// scope, release borrowed objects, replace the D3D render target, submit the
/// command buffer, or retain pointers from this value.
pub const Pass = union(Backend) {
    null: struct {
        pixels: []u8,
        stride: usize,
        format: u32,
        geometry: Geometry,
    },
    metal: struct {
        device: usize,
        command_buffer: usize,
        render_encoder: usize,
        target_texture: usize,
        depth: ?DepthAttachment = null,
        snapshot: ?SnapshotAttachments = null,
        geometry: Geometry,
    },
    d3d11: struct {
        device: usize,
        immediate_context: usize,
        render_target_view: usize,
        target_texture: usize,
        geometry: Geometry,
    },
    vulkan: struct {
        device: usize,
        command_buffer: usize,
        target_image: usize,
        target_image_view: usize,
        target_format: u32,
        device_dispatch: *const anyopaque,
        geometry: Geometry,
    },

    pub fn geometry(self: *const Pass) *const Geometry {
        return switch (self.*) {
            inline else => |*value| &value.geometry,
        };
    }
};

pub const Descriptor = struct {
    context: *anyopaque,
    vtable: *const VTable,
    label: []const u8 = "",
    requirements: Requirements = .{},

    pub const VTable = struct {
        prepare: *const fn (*anyopaque, Device, DeviceGeneration) Error!void,
        /// `payload` and `flags` are the exact bounded values emitted by the
        /// custom node for this pass. They are borrowed for this call only.
        encode: *const fn (*anyopaque, Pass, []const u8, u32) Error!void,
        device_lost: *const fn (*anyopaque, DeviceGeneration) void,
        deinit: *const fn (*anyopaque) void,
    };
};

const Entry = struct {
    descriptor: Descriptor,
    prepared_generation: DeviceGeneration = 0,
    last_submission: SubmissionEpoch = 0,
};

const Retired = struct {
    entry: Entry,
    release_after: SubmissionEpoch,
};

pub const Registry = struct {
    const Pool = handles.SlotPool(Entry, handles.RenderExtensionId);

    allocator: std.mem.Allocator,
    entries: Pool,
    retired: std.ArrayList(Retired) = .empty,
    maximum_entries: usize,
    callback_depth: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return initWithLimit(allocator, 1_024);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, maximum_entries: usize) Registry {
        return .{
            .allocator = allocator,
            .entries = Pool.init(allocator),
            .maximum_entries = maximum_entries,
        };
    }

    pub fn deinit(self: *Registry) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| self.deinitEntry(entry.value);
        for (self.retired.items) |*entry| self.deinitEntry(&entry.entry);
        self.entries.deinit();
        self.retired.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, descriptor: Descriptor) Error!handles.RenderExtensionId {
        if (self.callback_depth != 0) return error.CallbackReentrancy;
        if (descriptor.label.len > 4096 or !std.unicode.utf8ValidateSlice(descriptor.label) or
            std.mem.indexOfScalar(u8, descriptor.label, 0) != null)
            return error.InvalidConfiguration;
        try validateRequirements(descriptor.requirements);
        if (self.entries.live_count +| self.retired.items.len >= self.maximum_entries) return error.BudgetExceeded;
        const label = try self.allocator.dupe(u8, descriptor.label);
        errdefer self.allocator.free(label);
        var owned_descriptor = descriptor;
        owned_descriptor.label = label;
        return self.entries.insert(.{ .descriptor = owned_descriptor });
    }

    pub fn requirements(self: *const Registry, id: handles.RenderExtensionId) Error!Requirements {
        const entry = self.entries.getConst(id) orelse return error.InvalidHandle;
        return entry.descriptor.requirements;
    }

    pub fn callbacksActive(self: *const Registry) bool {
        return self.callback_depth != 0;
    }

    pub fn destroy(self: *Registry, id: handles.RenderExtensionId, release_after: SubmissionEpoch) Error!void {
        if (self.callback_depth != 0) return error.CallbackReentrancy;
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        const entry = self.entries.remove(id) orelse return error.InvalidHandle;
        self.retired.appendAssumeCapacity(.{
            .entry = entry,
            .release_after = @max(release_after, entry.last_submission),
        });
    }

    pub fn encode(
        self: *Registry,
        id: handles.RenderExtensionId,
        device: Device,
        pass: Pass,
        payload: []const u8,
        flags: u32,
        generation: DeviceGeneration,
        submission: SubmissionEpoch,
    ) Error!void {
        const entry = self.entries.get(id) orelse return error.InvalidHandle;
        // Attachment requirements are currently implemented by the Metal
        // host only. Reject them at the shared boundary on other backends so
        // an extension cannot accidentally render as if its depth/snapshot
        // inputs existed when they were silently omitted.
        switch (pass) {
            .metal => {},
            else => if (entry.descriptor.requirements.depth != null or entry.descriptor.requirements.snapshot != null)
                return error.Unsupported,
        }
        if (entry.prepared_generation != generation) {
            self.callback_depth += 1;
            defer self.callback_depth -= 1;
            try entry.descriptor.vtable.prepare(entry.descriptor.context, device, generation);
            entry.prepared_generation = generation;
        }
        self.callback_depth += 1;
        defer self.callback_depth -= 1;
        try entry.descriptor.vtable.encode(entry.descriptor.context, pass, payload, flags);
        entry.last_submission = @max(entry.last_submission, submission);
    }

    pub fn deviceLost(self: *Registry, new_generation: DeviceGeneration) void {
        // A device-lost hook may attempt to recover the renderer recursively.
        // The outer recovery owns the registry walk; a nested walk would
        // revisit the same borrowed entry and corrupt its lifecycle state.
        if (self.callback_depth != 0) return;
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            self.callback_depth += 1;
            entry.value.descriptor.vtable.device_lost(entry.value.descriptor.context, new_generation);
            self.callback_depth -= 1;
            entry.value.prepared_generation = 0;
            entry.value.last_submission = 0;
        }
        for (self.retired.items) |*entry| entry.release_after = 0;
    }

    pub fn collect(self: *Registry, completed: SubmissionEpoch) void {
        // Backend registration commonly collects completed retirements before
        // entering `register`. A deinit callback can take that same path, so
        // reject the nested collection and remove each item before invoking
        // user code. This makes the callback one-shot even under reentrancy.
        if (self.callback_depth != 0) return;
        var index: usize = 0;
        while (index < self.retired.items.len) {
            if (self.retired.items[index].release_after > completed) {
                index += 1;
                continue;
            }
            var retired = self.retired.orderedRemove(index).entry;
            self.deinitEntry(&retired);
        }
    }

    fn deinitEntry(self: *Registry, entry: *Entry) void {
        self.callback_depth += 1;
        defer self.callback_depth -= 1;
        entry.descriptor.vtable.deinit(entry.descriptor.context);
        self.allocator.free(entry.descriptor.label);
        entry.* = undefined;
    }
};

pub fn validateRequirements(requirements: Requirements) Error!void {
    if (requirements.depth) |depth| {
        if (!std.math.isFinite(depth.clear_depth) or depth.clear_depth < 0 or depth.clear_depth > 1)
            return error.InvalidConfiguration;
        if (depth.load_flag) |flag| if (flag == 0) return error.InvalidConfiguration;
    }
    if (requirements.snapshot) |snapshot| {
        if (!snapshot.color and !snapshot.depth) return error.InvalidConfiguration;
        if (snapshot.depth and requirements.depth == null) return error.InvalidConfiguration;
        if (snapshot.when_flag) |flag| if (flag == 0) return error.InvalidConfiguration;
    }
}

pub fn decodeId(encoded: u64) handles.RenderExtensionId {
    return .{ .index = @truncate(encoded), .generation = @truncate(encoded >> 32) };
}

comptime {
    std.debug.assert(@sizeOf(handles.RenderExtensionId) == 8);
}
