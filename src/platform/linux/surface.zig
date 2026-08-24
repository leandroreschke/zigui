const Error = @import("../../core/error.zig").Error;
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const sys = @import("sys.zig");

pub const BufferHandle = u64;
pub const TimelineHandle = u64;

pub const DmabufPlane = struct {
    descriptor: sys.fd_t,
    offset: u32,
    stride: u32,
    modifier: u64,
};

pub const DmabufDescriptor = struct {
    width: u32,
    height: u32,
    fourcc: u32,
    flags: u32 = 0,
    planes: []const DmabufPlane,
};

pub const TimelinePoint = struct {
    timeline: TimelineHandle,
    value: u64,
};

pub const Format = struct {
    fourcc: u32,
    modifier: u64,
    scanout: bool = false,
};

pub const Presentation = struct {
    window: handles.WindowId,
    buffer: BufferHandle,
    damage: geometry.Rect,
    acquire: ?TimelinePoint = null,
    release: ?TimelinePoint = null,
};

pub const Provider = struct {
    context: *anyopaque,
    explicit_sync_fn: *const fn (*anyopaque) bool,
    formats_fn: *const fn (*anyopaque) []const Format,
    import_buffer_fn: *const fn (*anyopaque, DmabufDescriptor) Error!BufferHandle,
    destroy_buffer_fn: *const fn (*anyopaque, BufferHandle) void,
    buffer_released_fn: *const fn (*anyopaque, BufferHandle) bool,
    import_timeline_fn: *const fn (*anyopaque, sys.fd_t) Error!TimelineHandle,
    destroy_timeline_fn: *const fn (*anyopaque, TimelineHandle) void,
    present_fn: *const fn (*anyopaque, Presentation) Error!void,

    pub fn explicitSync(self: Provider) bool {
        return self.explicit_sync_fn(self.context);
    }

    pub fn formats(self: Provider) []const Format {
        return self.formats_fn(self.context);
    }

    pub fn importBuffer(self: Provider, descriptor: DmabufDescriptor) Error!BufferHandle {
        return self.import_buffer_fn(self.context, descriptor);
    }

    pub fn destroyBuffer(self: Provider, handle: BufferHandle) void {
        self.destroy_buffer_fn(self.context, handle);
    }

    pub fn bufferReleased(self: Provider, handle: BufferHandle) bool {
        return self.buffer_released_fn(self.context, handle);
    }

    pub fn importTimeline(self: Provider, descriptor: sys.fd_t) Error!TimelineHandle {
        return self.import_timeline_fn(self.context, descriptor);
    }

    pub fn destroyTimeline(self: Provider, handle: TimelineHandle) void {
        self.destroy_timeline_fn(self.context, handle);
    }

    pub fn present(self: Provider, presentation: Presentation) Error!void {
        try self.present_fn(self.context, presentation);
    }
};
