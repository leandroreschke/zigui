const std = @import("std");
const a11y = @import("../a11y/api.zig");
const clock = @import("../core/clock.zig");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const appearance = @import("../core/appearance.zig");
const handles = @import("../core/handle.zig");
const native_media_placement = @import("../core/native_media.zig");
const input = @import("../input/event.zig");
const render = @import("../render/api.zig");
const text = @import("../text/api.zig");

pub const NativeHandle = struct {
    kind: Kind,
    value: usize,

    pub const Kind = enum { none, appkit, win32, wayland, x11, headless };
};

pub const WindowSnapshotFormat = enum { png_srgb8 };

/// An owned snapshot of a native window. The bytes are a PNG whose pixels
/// have been converted to 8-bit sRGB by the platform provider. The provider
/// owns the bytes through `allocator`; callers must release them with
/// `deinit` after loading or retaining the snapshot.
pub const OwnedWindowSnapshot = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    format: WindowSnapshotFormat,
    width: u32,
    height: u32,
    scale_factor: geometry.ScaleFactor,

    pub fn deinit(self: *OwnedWindowSnapshot) void {
        self.allocator.free(@constCast(self.bytes));
        self.* = undefined;
    }
};

/// Opaque identity for one asynchronous LinkPresentation page-capture
/// request.  The native provider and any App registry retain their own
/// operation state; consumers never receive Foundation or AppKit objects.
pub const PageCaptureRequestId = handles.PageCaptureRequestId;

pub const PageCaptureOptions = struct {
    /// Only HTTP and HTTPS URLs are accepted.  The provider owns all URL
    /// parsing and networking after this bounded UTF-8 value is copied.
    url: []const u8,
    /// Logical points requested from the native LinkPresentation renderer.
    /// The returned PNG dimensions are provider-reported pixel dimensions.
    size: geometry.Size = .{ .width = 1280, .height = 800 },
    /// Monotonic timeout requested from the provider, in nanoseconds.
    timeout_ns: u64 = 12 * std.time.ns_per_s,
};

pub const PageCaptureTerminalStatus = enum {
    completed,
    failed,
    canceled,
};

/// Allocator-owned PNG produced by a page-capture provider.  `bytes` remains
/// valid until `deinit`; it is never backed by an Objective-C object.
pub const OwnedPageCapture = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    width: u32,
    height: u32,

    pub fn deinit(self: *OwnedPageCapture) void {
        self.allocator.free(@constCast(self.bytes));
        self.* = undefined;
    }
};

pub const PageCaptureCompletion = struct {
    allocator: std.mem.Allocator,
    request: PageCaptureRequestId,
    status: PageCaptureTerminalStatus,
    result: ?OwnedPageCapture = null,
    error_description: ?[]const u8 = null,

    pub fn deinit(self: *PageCaptureCompletion) void {
        if (self.result) |*result| result.deinit();
        if (self.error_description) |description| self.allocator.free(@constCast(description));
        self.* = undefined;
    }
};

pub const PageCapturePoll = union(enum) {
    pending,
    terminal: PageCaptureCompletion,
};

pub const PageCaptureLimits = struct {
    maximum_requests: usize = 32,
    maximum_url_bytes: usize = 16 * 1024 * 1024,
    maximum_result_bytes: usize = 64 * 1024 * 1024,
    maximum_pixels: usize = 16 * 1024 * 1024,
    maximum_dimension: f64 = 16_384,
    maximum_timeout_ns: u64 = 60 * std.time.ns_per_s,
};

/// Native LinkPresentation-backed page capture.  This is intentionally a
/// small opaque async service rather than a UI element or a filesystem API:
/// applications receive an owned PNG and decide how/where to persist it.
pub const PageCapture = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque, PageCaptureOptions) Error!PageCaptureRequestId,
    poll_fn: *const fn (*anyopaque, PageCaptureRequestId, std.mem.Allocator) Error!PageCapturePoll,
    cancel_fn: *const fn (*anyopaque, PageCaptureRequestId) Error!void,
    release_fn: *const fn (*anyopaque, PageCaptureRequestId) Error!void,
    limits: PageCaptureLimits = .{},

    pub fn begin(self: PageCapture, options: PageCaptureOptions) Error!PageCaptureRequestId {
        try validatePageCaptureOptions(options, self.limits);
        const request = try self.begin_fn(self.context, options);
        if (!request.isValid()) return error.PlatformFailure;
        return request;
    }

    pub fn poll(
        self: PageCapture,
        request: PageCaptureRequestId,
        allocator: std.mem.Allocator,
    ) Error!PageCapturePoll {
        if (!request.isValid()) return error.InvalidHandle;
        var result = try self.poll_fn(self.context, request, allocator);
        switch (result) {
            .pending => {},
            .terminal => |*completion| {
                if (!completion.request.eql(request)) {
                    completion.deinit();
                    return error.PlatformFailure;
                }
                validatePageCaptureCompletion(completion.*, self.limits) catch |err| {
                    completion.deinit();
                    return err;
                };
            },
        }
        return result;
    }

    pub fn cancel(self: PageCapture, request: PageCaptureRequestId) Error!void {
        if (!request.isValid()) return error.InvalidHandle;
        try self.cancel_fn(self.context, request);
    }

    /// Releases a terminal request after its one-shot terminal poll has been
    /// consumed.  Providers may keep callback/native barriers until this
    /// point, but no native object is exposed to the caller.
    pub fn release(self: PageCapture, request: PageCaptureRequestId) Error!void {
        if (!request.isValid()) return error.InvalidHandle;
        try self.release_fn(self.context, request);
    }
};

pub const WindowState = render.SurfaceState;

pub const WindowMode = enum {
    normal,
    minimized,
    maximized,
    fullscreen,
};

pub const WindowCommand = union(enum) {
    move: geometry.Point,
    resize: geometry.Size,
    mode: WindowMode,
    always_on_top: bool,
};

pub const WindowOptions = struct {
    title: []const u8,
    size: geometry.Size = .{ .width = 1024, .height = 768 },
    minimum_size: geometry.Size = .{},
    maximum_size: geometry.Size = .unbounded,
    position: ?geometry.Point = null,
    visible: bool = true,
    decorated: bool = true,
    resizable: bool = true,
    transparent: bool = false,
    always_on_top: bool = false,
};

pub const WindowEvent = union(enum) {
    created: NativeHandle,
    configured: struct { logical_size: geometry.Size, scale_factor: geometry.ScaleFactor },
    moved: geometry.Point,
    resized: geometry.Size,
    scale_changed: geometry.ScaleFactor,
    /// The platform's resolved window mode after a native transition. Native
    /// menu commands and system shortcuts publish this just like
    /// programmatic mode commands.
    mode_changed: WindowMode,
    focused: bool,
    occluded: bool,
    appearance_changed: Appearance,
    input: input.Event,
    menu_action: MenuInvocation,
    accessibility_action: a11y.ActionRequest,
    frame_requested: u64,
    close_requested,
    closed,
    surface_lost,
    device_lost,
};

/// Compatibility export. The contract is owned by the platform-neutral core
/// module so consumers do not need to depend on platform APIs for appearance.
pub const Appearance = appearance.Appearance;

pub const Cursor = enum {
    default,
    pointer,
    text,
    crosshair,
    grab,
    grabbing,
    resize_horizontal,
    resize_vertical,
    resize_diagonal_nw_se,
    resize_diagonal_ne_sw,
    not_allowed,
    hidden,
};

pub const EventSink = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, handles.WindowId, *const WindowEvent) void,
    /// Invoked by native `run` loops after every wait/dispatch iteration,
    /// including iterations woken without a window event. App uses it to drain
    /// bounded worker completions on the UI thread.
    pump_callback: *const fn (*anyopaque) void = ignorePump,

    pub fn send(self: EventSink, window: handles.WindowId, event: *const WindowEvent) void {
        self.callback(self.context, window, event);
    }

    pub fn pump(self: EventSink) void {
        self.pump_callback(self.context);
    }
};

pub const EventLoop = struct {
    context: *anyopaque,
    run_fn: *const fn (*anyopaque, EventSink) Error!void,
    step_fn: *const fn (*anyopaque, EventSink, bool) Error!bool,
    wake_fn: *const fn (*anyopaque) void,
    schedule_wake_fn: *const fn (*anyopaque, clock.Timestamp) Error!void = unsupportedScheduledWake,
    request_quit_fn: *const fn (*anyopaque) void,
    clock: clock.Clock,

    pub fn run(self: EventLoop, sink: EventSink) Error!void {
        try self.run_fn(self.context, sink);
    }

    pub fn step(self: EventLoop, sink: EventSink, wait: bool) Error!bool {
        return self.step_fn(self.context, sink, wait);
    }

    pub fn wake(self: EventLoop) void {
        self.wake_fn(self.context);
    }

    pub fn scheduleWake(self: EventLoop, deadline_ns: clock.Timestamp) Error!void {
        try self.schedule_wake_fn(self.context, deadline_ns);
    }

    pub fn requestQuit(self: EventLoop) void {
        self.request_quit_fn(self.context);
    }
};

fn unsupportedScheduledWake(_: *anyopaque, _: clock.Timestamp) Error!void {
    return error.MissingCapability;
}

pub const WindowSystem = struct {
    context: *anyopaque,
    create_fn: *const fn (*anyopaque, handles.WindowId, WindowOptions) Error!NativeHandle,
    destroy_fn: *const fn (*anyopaque, handles.WindowId) void,
    show_fn: *const fn (*anyopaque, handles.WindowId, bool) Error!void,
    title_fn: *const fn (*anyopaque, handles.WindowId, []const u8) Error!void,
    request_frame_fn: *const fn (*anyopaque, handles.WindowId) Error!void,
    set_cursor_fn: *const fn (*anyopaque, handles.WindowId, Cursor) Error!void,
    command_fn: *const fn (*anyopaque, handles.WindowId, WindowCommand) Error!void,
    native_handle_fn: *const fn (*anyopaque, handles.WindowId) ?NativeHandle,
    /// Optional native whole-window capture. Providers must return an owned
    /// 8-bit sRGB PNG snapshot, or `MissingCapability` when unavailable.
    capture_window_fn: ?*const fn (*anyopaque, handles.WindowId, geometry.Size, std.mem.Allocator) Error!OwnedWindowSnapshot = null,
    maximum_text_bytes: usize = 16 * 1024 * 1024,
    maximum_snapshot_pixels: usize = 64 * 1024 * 1024,
    maximum_snapshot_bytes: usize = 256 * 1024 * 1024,

    pub fn create(self: WindowSystem, id: handles.WindowId, options: WindowOptions) Error!NativeHandle {
        if (!id.isValid()) return error.InvalidHandle;
        if (!validWindowOptions(options) or self.maximum_text_bytes == 0) return error.InvalidConfiguration;
        if (options.title.len > self.maximum_text_bytes) return error.BudgetExceeded;
        const native = try self.create_fn(self.context, id, options);
        if (native.kind == .none or native.value == 0) return error.PlatformFailure;
        return native;
    }

    pub fn destroy(self: WindowSystem, id: handles.WindowId) void {
        if (!id.isValid()) return;
        self.destroy_fn(self.context, id);
    }

    pub fn show(self: WindowSystem, id: handles.WindowId, visible: bool) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        return self.show_fn(self.context, id, visible);
    }

    pub fn setTitle(self: WindowSystem, id: handles.WindowId, title: []const u8) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        if (!validUtf8Text(title)) return error.InvalidUtf8;
        if (title.len > self.maximum_text_bytes) return error.BudgetExceeded;
        return self.title_fn(self.context, id, title);
    }

    pub fn requestFrame(self: WindowSystem, id: handles.WindowId) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        return self.request_frame_fn(self.context, id);
    }

    pub fn setCursor(self: WindowSystem, id: handles.WindowId, cursor: Cursor) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.set_cursor_fn(self.context, id, cursor);
    }

    pub fn command(self: WindowSystem, id: handles.WindowId, value: WindowCommand) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        switch (value) {
            .move => |point| if (!finitePoint(point)) return error.InvalidConfiguration,
            .resize => |size| if (!finitePositiveSize(size)) return error.InvalidConfiguration,
            .mode => {},
            .always_on_top => {},
        }
        try self.command_fn(self.context, id, value);
    }

    pub fn nativeHandle(self: WindowSystem, id: handles.WindowId) ?NativeHandle {
        if (!id.isValid()) return null;
        const native = self.native_handle_fn(self.context, id) orelse return null;
        if (native.kind == .none or native.value == 0) return null;
        return native;
    }

    /// Captures the native window at the requested logical aspect ratio. This
    /// is a synchronous, UI-thread operation; App exposes the mutation-phase
    /// guarded entry point for application code.
    pub fn captureWindow(
        self: WindowSystem,
        id: handles.WindowId,
        target: geometry.Size,
        allocator: std.mem.Allocator,
    ) Error!OwnedWindowSnapshot {
        if (!id.isValid()) return error.InvalidHandle;
        if (!finitePositiveSize(target)) return error.InvalidConfiguration;
        if (self.maximum_snapshot_pixels == 0 or self.maximum_snapshot_bytes == 0)
            return error.InvalidConfiguration;
        const target_pixels = target.width * target.height;
        if (!std.math.isFinite(target_pixels) or target_pixels > @as(f64, @floatFromInt(self.maximum_snapshot_pixels)))
            return error.BudgetExceeded;
        const callback = self.capture_window_fn orelse return error.MissingCapability;
        var result = try callback(self.context, id, target, allocator);
        errdefer result.deinit();
        if (result.format != .png_srgb8 or result.bytes.len == 0 or result.width == 0 or result.height == 0)
            return error.InvalidImage;
        const pixels = std.math.mul(usize, result.width, result.height) catch return error.BudgetExceeded;
        if (pixels > self.maximum_snapshot_pixels or result.bytes.len > self.maximum_snapshot_bytes)
            return error.BudgetExceeded;
        if (!std.math.isFinite(result.scale_factor.value) or result.scale_factor.value <= 0)
            return error.InvalidScaleFactor;
        if (result.bytes.len < 8 or !std.mem.eql(u8, result.bytes[0..8], "\x89PNG\r\n\x1a\n"))
            return error.InvalidImage;
        return result;
    }
};

pub const Display = struct {
    /// Stable for the lifetime of the current native display connection.
    id: u64,
    name: []const u8,
    /// Desktop coordinates in the same coordinate space accepted by
    /// `WindowCommand.move` on this platform.
    bounds: geometry.Rect,
    work_area: geometry.Rect,
    scale_factor: geometry.ScaleFactor,
    refresh_millihertz: u32 = 0,
    physical_size_mm: geometry.Size = .{},
    primary: bool = false,
};

pub const OwnedDisplays = struct {
    allocator: std.mem.Allocator,
    values: []Display,

    pub fn deinit(self: *OwnedDisplays) void {
        for (self.values) |display| self.allocator.free(@constCast(display.name));
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub const Displays = struct {
    context: *anyopaque,
    list_fn: *const fn (*anyopaque, std.mem.Allocator) Error!OwnedDisplays,
    maximum_count: usize = 256,
    maximum_text_bytes: usize = 16 * 1024 * 1024,

    pub fn list(self: Displays, allocator: std.mem.Allocator) Error!OwnedDisplays {
        var result = try self.list_fn(self.context, allocator);
        validateDisplays(result.values, self.maximum_count, self.maximum_text_bytes) catch |err| {
            result.deinit();
            return err;
        };
        return result;
    }
};

pub const Clipboard = struct {
    context: *anyopaque,
    read_text_fn: *const fn (*anyopaque, std.mem.Allocator) Error!?[]u8,
    write_text_fn: *const fn (*anyopaque, []const u8) Error!void,
    read_contents_fn: ?*const fn (*anyopaque, std.mem.Allocator) Error!ClipboardContents = null,
    write_paths_fn: ?*const fn (*anyopaque, []const []const u8) Error!void = null,
    write_image_fn: ?*const fn (*anyopaque, ClipboardImage) Error!void = null,
    maximum_bytes: usize = 64 * 1024 * 1024,
    maximum_paths: usize = 4_096,

    pub fn readText(self: Clipboard, allocator: std.mem.Allocator) Error!?[]u8 {
        const result = try self.read_text_fn(self.context, allocator);
        if (result) |value| {
            if (value.len > self.maximum_bytes) {
                allocator.free(value);
                return error.BudgetExceeded;
            }
            if (!validUtf8Text(value)) {
                allocator.free(value);
                return error.InvalidUtf8;
            }
        }
        return result;
    }

    pub fn writeText(self: Clipboard, value: []const u8) Error!void {
        if (!validUtf8Text(value)) return error.InvalidUtf8;
        if (value.len > self.maximum_bytes) return error.BudgetExceeded;
        try self.write_text_fn(self.context, value);
    }

    pub fn readContents(self: Clipboard, allocator: std.mem.Allocator) Error!ClipboardContents {
        const callback = self.read_contents_fn orelse return error.MissingCapability;
        var result = try callback(self.context, allocator);
        validateClipboardContents(result, self.maximum_bytes, self.maximum_paths) catch |err| {
            result.deinit();
            return err;
        };
        return result;
    }

    pub fn writePaths(self: Clipboard, paths: []const []const u8) Error!void {
        if (paths.len == 0) return error.InvalidConfiguration;
        if (paths.len > self.maximum_paths) return error.BudgetExceeded;
        var used: usize = 0;
        for (paths) |path| {
            try validatePath(path, self.maximum_bytes);
            used = std.math.add(usize, used, path.len) catch return error.BudgetExceeded;
            if (used > self.maximum_bytes) return error.BudgetExceeded;
        }
        const callback = self.write_paths_fn orelse return error.MissingCapability;
        try callback(self.context, paths);
    }

    pub fn writeImage(self: Clipboard, image: ClipboardImage) Error!void {
        if (image.format != .png or image.bytes.len == 0) return error.InvalidConfiguration;
        if (image.bytes.len > self.maximum_bytes) return error.BudgetExceeded;
        const callback = self.write_image_fn orelse return error.MissingCapability;
        try callback(self.context, image);
    }

    pub fn bridge(self: Clipboard) input.NativeClipboard {
        return .{
            .context = self.context,
            .read_text_fn = self.read_text_fn,
            .write_text_fn = self.write_text_fn,
            .maximum_bytes = self.maximum_bytes,
        };
    }
};

pub const ClipboardImageFormat = enum { png };

pub const ClipboardImage = struct {
    format: ClipboardImageFormat,
    bytes: []const u8,
};

/// Opaque identity for a native file-promise receive snapshot. The provider
/// retains the native receivers behind this handle; applications only see
/// bounded, owned descriptors and paths.
pub const PromisedFileBatchId = handles.PromisedFileBatchId;
pub const PromisedFileOperationId = handles.PromisedFileOperationId;

pub const PromisedFileDescriptor = struct {
    /// Before receiving, platforms may expose one provisional descriptor for
    /// a native receiver whose exact multi-file output is not yet known.
    /// Provider-supplied display name. This is metadata, not a filesystem
    /// path, and is always UTF-8 owned by `OwnedPromisedFileDescriptors`.
    suggested_name: []const u8,
    /// Provider-supplied UTI/MIME-like type identifier. Empty means unknown.
    content_type: []const u8 = "",
};

pub const OwnedPromisedFileDescriptors = struct {
    allocator: std.mem.Allocator,
    batch: PromisedFileBatchId,
    values: []PromisedFileDescriptor,

    pub fn deinit(self: *OwnedPromisedFileDescriptors) void {
        for (self.values) |descriptor| {
            self.allocator.free(@constCast(descriptor.suggested_name));
            if (descriptor.content_type.len != 0) self.allocator.free(@constCast(descriptor.content_type));
        }
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

pub const PromisedFileTerminalStatus = enum {
    completed,
    partial,
    failed,
    canceled,
};

pub const PromisedFileOutput = struct {
    /// A legacy native receiver may advertise one descriptor and materialize
    /// several files. In that case multiple outputs intentionally refer to
    /// the same descriptor index.
    descriptor_index: usize,
    /// A materialized local path, owned by the completion value, or null when
    /// the provider reported an error for this descriptor.
    path: ?[]const u8 = null,
    /// A bounded provider error for this descriptor. It is optional even for
    /// failed output because some native providers expose no localized detail.
    error_description: ?[]const u8 = null,
};

pub const PromisedFileCompletion = struct {
    allocator: std.mem.Allocator,
    operation: PromisedFileOperationId,
    status: PromisedFileTerminalStatus,
    outputs: []PromisedFileOutput,
    error_description: ?[]const u8 = null,

    pub fn deinit(self: *PromisedFileCompletion) void {
        for (self.outputs) |output| {
            if (output.path) |path| self.allocator.free(@constCast(path));
            if (output.error_description) |description| self.allocator.free(@constCast(description));
        }
        self.allocator.free(self.outputs);
        if (self.error_description) |description| self.allocator.free(@constCast(description));
        self.* = undefined;
    }
};

pub const PromisedFilePoll = union(enum) {
    pending,
    terminal: PromisedFileCompletion,
};

pub const PromisedFileLimits = struct {
    maximum_batches: usize = 1_024,
    maximum_operations: usize = 1_024,
    maximum_files: usize = 4_096,
    /// Aggregate bytes for descriptor metadata, destination paths, and
    /// provider callback results retained by one service.
    maximum_bytes: usize = 16 * 1024 * 1024,
};

/// Native file-promise materialization. The public contract intentionally
/// contains no AppKit, Foundation, or platform receiver types. A batch is
/// produced by a native clipboard/drag provider, described here, and can be
/// received exactly once into one shared destination directory.
pub const PromisedFiles = struct {
    context: *anyopaque,
    describe_batch_fn: *const fn (*anyopaque, PromisedFileBatchId, std.mem.Allocator) Error!OwnedPromisedFileDescriptors,
    begin_fn: *const fn (*anyopaque, PromisedFileBatchId, []const u8) Error!PromisedFileOperationId,
    poll_fn: *const fn (*anyopaque, PromisedFileOperationId, std.mem.Allocator) Error!PromisedFilePoll,
    cancel_fn: *const fn (*anyopaque, PromisedFileOperationId) Error!void,
    release_batch_fn: *const fn (*anyopaque, PromisedFileBatchId) Error!void,
    release_operation_fn: *const fn (*anyopaque, PromisedFileOperationId) Error!void,
    limits: PromisedFileLimits = .{},

    pub fn describe(self: PromisedFiles, batch: PromisedFileBatchId, allocator: std.mem.Allocator) Error!OwnedPromisedFileDescriptors {
        if (!batch.isValid()) return error.InvalidHandle;
        var result = try self.describe_batch_fn(self.context, batch, allocator);
        validatePromisedDescriptors(result, self.limits) catch |err| {
            result.deinit();
            return err;
        };
        return result;
    }

    pub fn begin(self: PromisedFiles, batch: PromisedFileBatchId, destination: []const u8) Error!PromisedFileOperationId {
        if (!batch.isValid()) return error.InvalidHandle;
        try validateServiceText(destination, self.limits.maximum_bytes);
        const operation = try self.begin_fn(self.context, batch, destination);
        if (!operation.isValid()) return error.PlatformFailure;
        return operation;
    }

    pub fn poll(self: PromisedFiles, operation: PromisedFileOperationId, allocator: std.mem.Allocator) Error!PromisedFilePoll {
        if (!operation.isValid()) return error.InvalidHandle;
        var result = try self.poll_fn(self.context, operation, allocator);
        switch (result) {
            .pending => {},
            .terminal => |*completion| {
                if (!completion.operation.eql(operation)) {
                    completion.deinit();
                    return error.PlatformFailure;
                }
                validatePromisedCompletion(completion.*, self.limits) catch |err| {
                    completion.deinit();
                    return err;
                };
            },
        }
        return result;
    }

    pub fn cancel(self: PromisedFiles, operation: PromisedFileOperationId) Error!void {
        if (!operation.isValid()) return error.InvalidHandle;
        try self.cancel_fn(self.context, operation);
    }

    /// Releases the caller's reference to a batch. A batch may be released
    /// immediately after `begin`; the provider keeps an internal operation
    /// reference until all callbacks and shared-destination cleanup finish.
    pub fn releaseBatch(self: PromisedFiles, batch: PromisedFileBatchId) Error!void {
        if (!batch.isValid()) return error.InvalidHandle;
        try self.release_batch_fn(self.context, batch);
    }

    /// Releases a terminal operation after its completion value has been
    /// consumed. Providers may retain callback barriers until this call.
    pub fn releaseOperation(self: PromisedFiles, operation: PromisedFileOperationId) Error!void {
        if (!operation.isValid()) return error.InvalidHandle;
        try self.release_operation_fn(self.context, operation);
    }
};

/// One allocator-owned native clipboard snapshot. File URLs are exposed as
/// filesystem paths rather than URL strings. Image bytes are encoded PNG so
/// consumers can pass them directly to ZigUI's image capability.
pub const ClipboardContents = struct {
    allocator: std.mem.Allocator,
    text: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
    image: ?ClipboardImage = null,
    contains_promised_files: bool = false,
    /// Number of currently advertised promised-file entries in this snapshot.
    /// A native receiver may later materialize multiple outputs when its
    /// pre-receive metadata cannot expose exact cardinality. When a provider
    /// can retain the receivers, `promised_batch` is non-null and owns the
    /// corresponding receive snapshot; otherwise this remains detection-only.
    promised_file_count: usize = 0,
    /// When non-null, the provider retained the native receivers and exposes
    /// them through `Bundle.promised_files`. Call `releaseBatch` when the
    /// application no longer needs the batch, even if it is not received.
    /// Mixed clipboard representations have stable consumer ordering:
    /// `paths`, `promised_batch`, `image`, then `text`.
    promised_batch: ?PromisedFileBatchId = null,

    pub fn deinit(self: *ClipboardContents) void {
        if (self.text) |value| self.allocator.free(@constCast(value));
        for (self.paths) |value| self.allocator.free(@constCast(value));
        if (self.paths.len != 0) self.allocator.free(@constCast(self.paths));
        if (self.image) |value| self.allocator.free(@constCast(value.bytes));
        self.* = undefined;
    }
};

pub const MenuInvocation = struct {
    action: handles.ActionId,
    /// Opaque application-owned context copied into the resulting action
    /// event. This lets a context menu identify its originating item without
    /// a global action-to-selection side channel.
    payload: u64 = 0,
};

/// Platform-neutral keyboard equivalent displayed by native application
/// menus. Dispatch still follows the registered action; this only describes
/// the native menu accelerator and must match the binding installed by the
/// application.
pub const MenuShortcut = struct {
    key: input.Key,
    modifiers: input.Modifiers = .{},
};

/// Native responder/application actions that do not belong to an
/// application-owned action registry. These preserve platform menu behavior
/// such as Services, the standard Edit responder chain, and window commands.
pub const SystemMenuAction = enum {
    about_application,
    services,
    hide_application,
    hide_other_applications,
    show_all_applications,
    quit_application,
    close_window,
    minimize_window,
    zoom_window,
    enter_fullscreen,
    bring_all_to_front,
    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,
};

pub const MenuItem = union(enum) {
    action: struct {
        label: []const u8,
        action: handles.ActionId,
        payload: u64 = 0,
        enabled: bool = true,
        checked: bool = false,
        shortcut: ?MenuShortcut = null,
    },
    submenu: struct { label: []const u8, items: []const MenuItem },
    /// Items in this group are installed in the platform application menu.
    /// Platforms without a distinct application menu may render them as an
    /// ordinary top-level submenu.
    application: struct { items: []const MenuItem },
    system_action: struct { label: []const u8, action: SystemMenuAction },
    separator,
};

pub const MenuLimits = struct {
    maximum_items: usize = 16_384,
    maximum_depth: usize = 64,
    maximum_text_bytes: usize = 8 * 1024 * 1024,
};

pub const Menus = struct {
    context: *anyopaque,
    set_application_menu_fn: *const fn (*anyopaque, []const MenuItem) Error!void,
    show_context_menu_fn: *const fn (*anyopaque, handles.WindowId, geometry.Point, []const MenuItem) Error!void,
    limits: MenuLimits = .{},

    pub fn setApplicationMenu(self: Menus, items: []const MenuItem) Error!void {
        try validateMenu(items, self.limits);
        try self.set_application_menu_fn(self.context, items);
    }

    pub fn showContextMenu(self: Menus, window: handles.WindowId, point: geometry.Point, items: []const MenuItem) Error!void {
        if (!window.isValid()) return error.InvalidHandle;
        if (!finitePoint(point)) return error.InvalidConfiguration;
        try validateMenu(items, self.limits);
        try self.show_context_menu_fn(self.context, window, point, items);
    }
};

pub const Dialogs = struct {
    context: *anyopaque,
    open_files_fn: *const fn (*anyopaque, handles.WindowId, bool, std.mem.Allocator) Error!OwnedPaths,
    save_file_fn: *const fn (*anyopaque, handles.WindowId, []const u8, std.mem.Allocator) Error!?OwnedPath,
    /// Optional single-directory picker. A missing callback reports
    /// `MissingCapability`, allowing platforms to expose only the dialog
    /// operations they can implement.
    open_directory_fn: ?*const fn (*anyopaque, handles.WindowId, std.mem.Allocator) Error!?OwnedPath = null,
    limits: DialogLimits = .{},

    pub fn openFiles(self: Dialogs, window: handles.WindowId, multiple: bool, allocator: std.mem.Allocator) Error!OwnedPaths {
        if (!window.isValid()) return error.InvalidHandle;
        var result = try self.open_files_fn(self.context, window, multiple, allocator);
        validatePaths(result.values, self.limits) catch |err| {
            result.deinit();
            return err;
        };
        if (!multiple and result.values.len > 1) {
            result.deinit();
            return error.PlatformFailure;
        }
        return result;
    }

    pub fn saveFile(self: Dialogs, window: handles.WindowId, suggested_name: []const u8, allocator: std.mem.Allocator) Error!?OwnedPath {
        if (!window.isValid()) return error.InvalidHandle;
        if (!validUtf8Text(suggested_name)) return error.InvalidUtf8;
        if (suggested_name.len > self.limits.maximum_suggested_name_bytes) return error.BudgetExceeded;
        var result = try self.save_file_fn(self.context, window, suggested_name, allocator);
        if (result) |*path| {
            validatePath(path.value, self.limits.maximum_path_bytes) catch |err| {
                path.deinit();
                return err;
            };
        }
        return result;
    }

    pub fn openDirectory(self: Dialogs, window: handles.WindowId, allocator: std.mem.Allocator) Error!?OwnedPath {
        if (!window.isValid()) return error.InvalidHandle;
        const callback = self.open_directory_fn orelse return error.MissingCapability;
        var result = try callback(self.context, window, allocator);
        if (result) |*path| {
            validatePath(path.value, self.limits.maximum_path_bytes) catch |err| {
                path.deinit();
                return err;
            };
        }
        return result;
    }
};

/// Native application services which deliberately sit outside window and
/// dialog ownership. Platforms may omit this capability when their desktop
/// environment has no authoritative implementation.
pub const ApplicationServices = struct {
    context: *anyopaque,
    open_url_fn: *const fn (*anyopaque, []const u8) Error!void,
    open_path_fn: *const fn (*anyopaque, []const u8) Error!void,
    reveal_path_fn: *const fn (*anyopaque, []const u8) Error!void,
    print_path_fn: *const fn (*anyopaque, []const u8) Error!void,
    maximum_text_bytes: usize = 16 * 1024 * 1024,

    pub fn openUrl(self: ApplicationServices, url: []const u8) Error!void {
        try validateServiceText(url, self.maximum_text_bytes);
        try self.open_url_fn(self.context, url);
    }
    pub fn openPath(self: ApplicationServices, path: []const u8) Error!void {
        try validateServiceText(path, self.maximum_text_bytes);
        try self.open_path_fn(self.context, path);
    }
    pub fn revealPath(self: ApplicationServices, path: []const u8) Error!void {
        try validateServiceText(path, self.maximum_text_bytes);
        try self.reveal_path_fn(self.context, path);
    }
    pub fn printPath(self: ApplicationServices, path: []const u8) Error!void {
        try validateServiceText(path, self.maximum_text_bytes);
        try self.print_path_fn(self.context, path);
    }
};

pub const NativeMediaSource = union(enum) {
    file: []const u8,
    url: []const u8,
};

pub const NativeMediaOptions = struct {
    source: NativeMediaSource,
    frame: geometry.Rect,
    autoplay: bool = true,
    volume: f32 = 1,
    muted: bool = false,
};

pub const NativeMediaStatus = enum {
    loading,
    ready,
    failed,
};

/// Bounded inline-owned text associated with a failed native media state.
/// The alias keeps the platform-facing API discoverable while the storage and
/// validation contract remains platform-neutral in core/native_media.zig.
pub const NativeMediaErrorDescription = native_media_placement.ErrorDescription;

pub const NativeMediaState = struct {
    status: NativeMediaStatus = .loading,
    /// True after the native player has presented at least one decoded video
    /// frame. This is independent of `playing`: a paused or seeking player
    /// may still own the current frame and should not fall back to an import
    /// thumbnail merely because its rate is zero.
    has_presented_frame: bool = false,
    /// Present when a provider can expose a safe localized failure detail.
    /// This is a value copy; callers do not retain platform objects or an
    /// allocator and may read it until this state snapshot is discarded.
    error_description: ?NativeMediaErrorDescription = null,
    playing: bool,
    position_ns: u64,
    duration_ns: ?u64,
    volume: f32,
    muted: bool,
};

/// Optional native player/layer adapter. The platform owns playback and audio;
/// ZigUI owns the bounded handle and window-relative presentation geometry.
/// Consumers must destroy the handle before discarding application state.
pub const NativeMedia = struct {
    context: *anyopaque,
    create_fn: *const fn (*anyopaque, handles.WindowId, NativeMediaOptions) Error!handles.NativeMediaId,
    set_frame_fn: *const fn (*anyopaque, handles.NativeMediaId, geometry.Rect) Error!void,
    synchronize_fn: *const fn (*anyopaque, handles.WindowId, []const native_media_placement.Placement) Error!void,
    play_fn: *const fn (*anyopaque, handles.NativeMediaId) Error!void,
    pause_fn: *const fn (*anyopaque, handles.NativeMediaId) Error!void,
    seek_fn: *const fn (*anyopaque, handles.NativeMediaId, u64) Error!void,
    set_volume_fn: *const fn (*anyopaque, handles.NativeMediaId, f32) Error!void,
    set_muted_fn: *const fn (*anyopaque, handles.NativeMediaId, bool) Error!void,
    state_fn: *const fn (*anyopaque, handles.NativeMediaId) Error!NativeMediaState,
    destroy_fn: *const fn (*anyopaque, handles.NativeMediaId) Error!void,
    maximum_source_bytes: usize = 16 * 1024 * 1024,
    maximum_placements: usize = 4_096,

    pub fn create(self: NativeMedia, window: handles.WindowId, options: NativeMediaOptions) Error!handles.NativeMediaId {
        if (!window.isValid()) return error.InvalidHandle;
        const source = switch (options.source) {
            .file => |value| value,
            .url => |value| value,
        };
        try validateServiceText(source, self.maximum_source_bytes);
        if (!finiteRect(options.frame) or options.frame.size.width <= 0 or options.frame.size.height <= 0 or
            !std.math.isFinite(options.volume) or options.volume < 0 or options.volume > 1)
            return error.InvalidConfiguration;
        const id = try self.create_fn(self.context, window, options);
        if (!id.isValid()) return error.PlatformFailure;
        return id;
    }
    pub fn setFrame(self: NativeMedia, id: handles.NativeMediaId, frame: geometry.Rect) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        if (!finiteRect(frame) or frame.size.width <= 0 or frame.size.height <= 0) return error.InvalidConfiguration;
        try self.set_frame_fn(self.context, id, frame);
    }
    pub fn synchronize(self: NativeMedia, window: handles.WindowId, placements: []const native_media_placement.Placement) Error!void {
        if (!window.isValid()) return error.InvalidHandle;
        if (placements.len > self.maximum_placements) return error.BudgetExceeded;
        for (placements, 0..) |placement, index| {
            if (!placement.id.isValid()) return error.InvalidHandle;
            if (!finiteRect(placement.bounds) or placement.bounds.size.width <= 0 or placement.bounds.size.height <= 0)
                return error.InvalidConfiguration;
            for (placements[0..index]) |previous| if (previous.id.eql(placement.id)) return error.InvalidConfiguration;
        }
        try self.synchronize_fn(self.context, window, placements);
    }
    pub fn play(self: NativeMedia, id: handles.NativeMediaId) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.play_fn(self.context, id);
    }
    pub fn pause(self: NativeMedia, id: handles.NativeMediaId) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.pause_fn(self.context, id);
    }
    pub fn seek(self: NativeMedia, id: handles.NativeMediaId, position_ns: u64) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.seek_fn(self.context, id, position_ns);
    }
    pub fn setVolume(self: NativeMedia, id: handles.NativeMediaId, volume: f32) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        if (!std.math.isFinite(volume) or volume < 0 or volume > 1) return error.InvalidConfiguration;
        try self.set_volume_fn(self.context, id, volume);
    }
    pub fn setMuted(self: NativeMedia, id: handles.NativeMediaId, muted: bool) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.set_muted_fn(self.context, id, muted);
    }
    pub fn state(self: NativeMedia, id: handles.NativeMediaId) Error!NativeMediaState {
        if (!id.isValid()) return error.InvalidHandle;
        const value = try self.state_fn(self.context, id);
        if (!std.math.isFinite(value.volume) or value.volume < 0 or value.volume > 1) return error.PlatformFailure;
        if (value.error_description) |description| description.validate() catch return error.PlatformFailure;
        return value;
    }
    pub fn destroy(self: NativeMedia, id: handles.NativeMediaId) Error!void {
        if (!id.isValid()) return error.InvalidHandle;
        try self.destroy_fn(self.context, id);
    }
};

pub const DialogLimits = struct {
    maximum_paths: usize = 4_096,
    maximum_path_bytes: usize = 16 * 1024 * 1024,
    maximum_suggested_name_bytes: usize = 16 * 1024 * 1024,
};

pub const OwnedPath = struct {
    allocator: std.mem.Allocator,
    value: []const u8,

    pub fn deinit(self: *OwnedPath) void {
        self.allocator.free(@constCast(self.value));
        self.* = undefined;
    }
};

pub const OwnedPaths = struct {
    allocator: std.mem.Allocator,
    values: []const []const u8,

    pub fn deinit(self: *OwnedPaths) void {
        for (self.values) |value| self.allocator.free(@constCast(value));
        self.allocator.free(@constCast(self.values));
        self.* = undefined;
    }
};

pub const TextInput = struct {
    context: *anyopaque,
    set_active_fn: *const fn (*anyopaque, handles.WindowId, bool) Error!void,
    set_candidate_rect_fn: *const fn (*anyopaque, handles.WindowId, geometry.Rect) Error!void,
    set_surrounding_text_fn: *const fn (*anyopaque, handles.WindowId, []const u8, input.TextRange) Error!void,
    maximum_surrounding_text_bytes: usize = 16 * 1024 * 1024,

    pub fn bridge(self: TextInput) input.NativeTextInput {
        return .{
            .context = self.context,
            .set_active_fn = self.set_active_fn,
            .set_candidate_rect_fn = self.set_candidate_rect_fn,
            .set_surrounding_text_fn = self.set_surrounding_text_fn,
            .maximum_surrounding_text_bytes = self.maximum_surrounding_text_bytes,
        };
    }
};

pub const Bundle = struct {
    event_loop: EventLoop,
    windows: WindowSystem,
    displays: Displays,
    renderer: render.Renderer,
    text_backend: ?text.Backend = null,
    text_input: ?TextInput = null,
    accessibility: ?a11y.Adapter = null,
    clipboard: ?Clipboard = null,
    promised_files: ?PromisedFiles = null,
    page_capture: ?PageCapture = null,
    menus: ?Menus = null,
    dialogs: ?Dialogs = null,
    application_services: ?ApplicationServices = null,
    native_media: ?NativeMedia = null,
    deinit_context: *anyopaque,
    deinit_fn: *const fn (*anyopaque) void,

    pub fn deinit(self: Bundle) void {
        self.deinit_fn(self.deinit_context);
    }
};

pub fn validateWindowEvent(value: *const WindowEvent) Error!void {
    switch (value.*) {
        .created => |native| if (native.kind == .none or native.value == 0)
            return error.PlatformFailure,
        .configured => |configured| {
            if (!finiteNonNegativeSize(configured.logical_size) or
                !std.math.isFinite(configured.scale_factor.value) or configured.scale_factor.value <= 0)
                return error.InvalidConfiguration;
        },
        .moved => |point| if (!finitePoint(point)) return error.InvalidConfiguration,
        .resized => |size| if (!finiteNonNegativeSize(size)) return error.InvalidConfiguration,
        .scale_changed => |scale_factor| if (!std.math.isFinite(scale_factor.value) or scale_factor.value <= 0)
            return error.InvalidScaleFactor,
        .mode_changed => {},
        .menu_action => |invocation| if (!invocation.action.isValid()) return error.InvalidHandle,
        .accessibility_action => |request| {
            if (!request.window.isValid() or !request.target.isValid()) return error.InvalidHandle;
            if (request.value) |text_value| if (!validUtf8Text(text_value)) return error.InvalidUtf8;
        },
        .input,
        .focused,
        .occluded,
        .appearance_changed,
        .frame_requested,
        .close_requested,
        .closed,
        .surface_lost,
        .device_lost,
        => {},
    }
}

fn finitePoint(point: geometry.Point) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn finiteRect(rect: geometry.Rect) bool {
    return finitePoint(rect.origin) and finiteNonNegativeSize(rect.size);
}

fn ignorePump(_: *anyopaque) void {}

fn finitePositiveSize(size: geometry.Size) bool {
    return std.math.isFinite(size.width) and std.math.isFinite(size.height) and
        size.width > 0 and size.height > 0;
}

fn validWindowOptions(options: WindowOptions) bool {
    if (!validUtf8Text(options.title) or !finitePositiveSize(options.size) or
        !finiteNonNegativeSize(options.minimum_size) or !validMaximumSize(options.maximum_size))
        return false;
    if (options.minimum_size.width > options.maximum_size.width or options.minimum_size.height > options.maximum_size.height)
        return false;
    if (options.size.width < options.minimum_size.width or options.size.height < options.minimum_size.height or
        options.size.width > options.maximum_size.width or options.size.height > options.maximum_size.height)
        return false;
    if (options.position) |position| if (!finitePoint(position)) return false;
    return true;
}

fn finiteNonNegativeSize(size: geometry.Size) bool {
    return std.math.isFinite(size.width) and std.math.isFinite(size.height) and
        size.width >= 0 and size.height >= 0;
}

fn validMaximumSize(size: geometry.Size) bool {
    inline for (.{ size.width, size.height }) |amount| {
        if (std.math.isNan(amount) or amount <= 0) return false;
    }
    return true;
}

fn validUtf8Text(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn validateDisplays(values: []const Display, maximum_count: usize, maximum_text_bytes: usize) Error!void {
    if (maximum_count == 0 or maximum_text_bytes == 0) return error.InvalidConfiguration;
    if (values.len > maximum_count) return error.BudgetExceeded;
    var text_bytes: usize = 0;
    for (values) |display| {
        if (!validUtf8Text(display.name) or display.name.len == 0) return error.InvalidUtf8;
        text_bytes = std.math.add(usize, text_bytes, display.name.len) catch return error.BudgetExceeded;
        if (text_bytes > maximum_text_bytes) return error.BudgetExceeded;
        if (!finiteRect(display.bounds) or !finiteRect(display.work_area) or
            !finiteNonNegativeSize(display.physical_size_mm) or
            !std.math.isFinite(display.scale_factor.value) or display.scale_factor.value <= 0)
            return error.InvalidConfiguration;
    }
}

fn validatePaths(values: []const []const u8, limits: DialogLimits) Error!void {
    if (limits.maximum_paths == 0 or limits.maximum_path_bytes == 0 or limits.maximum_suggested_name_bytes == 0)
        return error.InvalidConfiguration;
    if (values.len > limits.maximum_paths) return error.BudgetExceeded;
    var total: usize = 0;
    for (values) |value| {
        try validatePath(value, limits.maximum_path_bytes);
        total = std.math.add(usize, total, value.len) catch return error.BudgetExceeded;
        if (total > limits.maximum_path_bytes) return error.BudgetExceeded;
    }
}

fn validatePath(value: []const u8, maximum_bytes: usize) Error!void {
    if (value.len == 0) return error.InvalidConfiguration;
    if (value.len > maximum_bytes) return error.BudgetExceeded;
    if (!validUtf8Text(value)) return error.InvalidUtf8;
}

fn validateServiceText(value: []const u8, maximum_bytes: usize) Error!void {
    if (maximum_bytes == 0) return error.InvalidConfiguration;
    if (value.len == 0) return error.InvalidConfiguration;
    if (value.len > maximum_bytes) return error.BudgetExceeded;
    if (!validUtf8Text(value)) return error.InvalidUtf8;
}

fn validatePageCaptureOptions(value: PageCaptureOptions, limits: PageCaptureLimits) Error!void {
    if (limits.maximum_requests == 0 or limits.maximum_url_bytes == 0 or
        limits.maximum_result_bytes == 0 or limits.maximum_pixels == 0 or
        limits.maximum_dimension <= 0 or !std.math.isFinite(limits.maximum_dimension) or
        limits.maximum_timeout_ns == 0)
        return error.InvalidConfiguration;
    try validateServiceText(value.url, limits.maximum_url_bytes);
    if (!isHttpUrl(value.url)) return error.InvalidConfiguration;
    if (!finitePositiveSize(value.size) or value.size.width > limits.maximum_dimension or
        value.size.height > limits.maximum_dimension)
        return error.InvalidConfiguration;
    const pixels = value.size.width * value.size.height;
    if (!std.math.isFinite(pixels) or pixels > @as(f64, @floatFromInt(limits.maximum_pixels)))
        return error.BudgetExceeded;
    if (value.timeout_ns == 0 or value.timeout_ns > limits.maximum_timeout_ns)
        return error.InvalidConfiguration;
}

fn validatePageCaptureCompletion(value: PageCaptureCompletion, limits: PageCaptureLimits) Error!void {
    if (!value.request.isValid()) return error.InvalidHandle;
    if (value.error_description) |description| {
        if (!validUtf8Text(description) or description.len > limits.maximum_url_bytes)
            return error.InvalidUtf8;
    }
    switch (value.status) {
        .completed => {
            const result = value.result orelse return error.PlatformFailure;
            if (result.width == 0 or result.height == 0 or
                @as(f64, @floatFromInt(result.width)) > limits.maximum_dimension or
                @as(f64, @floatFromInt(result.height)) > limits.maximum_dimension or
                result.bytes.len < 8 or
                !std.mem.eql(u8, result.bytes[0..8], "\x89PNG\r\n\x1a\n"))
                return error.InvalidImage;
            const pixels = std.math.mul(usize, result.width, result.height) catch return error.BudgetExceeded;
            if (pixels > limits.maximum_pixels or result.bytes.len > limits.maximum_result_bytes)
                return error.BudgetExceeded;
        },
        .failed, .canceled => if (value.result != null) return error.InvalidConfiguration,
    }
}

fn isHttpUrl(value: []const u8) bool {
    const separator = std.mem.indexOf(u8, value, "://") orelse return false;
    if (separator == 0) return false;
    const scheme = value[0..separator];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    const authority_start = separator + 3;
    if (authority_start >= value.len) return false;
    const authority_end = std.mem.indexOfAnyPos(u8, value, authority_start, "/?#") orelse value.len;
    if (authority_end == authority_start) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn validateClipboardContents(value: ClipboardContents, maximum_bytes: usize, maximum_paths: usize) Error!void {
    if (maximum_bytes == 0 or maximum_paths == 0) return error.InvalidConfiguration;
    if (value.paths.len > maximum_paths) return error.BudgetExceeded;
    if (value.promised_file_count > maximum_paths) return error.BudgetExceeded;
    if (value.contains_promised_files != (value.promised_file_count != 0)) return error.InvalidConfiguration;
    if (value.promised_batch) |batch| if (!batch.isValid()) return error.InvalidHandle;
    if (value.promised_batch != null and value.promised_file_count == 0) return error.InvalidConfiguration;
    var used: usize = 0;
    if (value.text) |text_value| {
        if (!validUtf8Text(text_value)) return error.InvalidUtf8;
        used = std.math.add(usize, used, text_value.len) catch return error.BudgetExceeded;
    }
    for (value.paths) |path| {
        try validatePath(path, maximum_bytes);
        used = std.math.add(usize, used, path.len) catch return error.BudgetExceeded;
    }
    if (value.image) |image| {
        if (image.bytes.len == 0) return error.InvalidImage;
        used = std.math.add(usize, used, image.bytes.len) catch return error.BudgetExceeded;
    }
    if (used > maximum_bytes) return error.BudgetExceeded;
}

fn validatePromisedDescriptors(value: OwnedPromisedFileDescriptors, limits: PromisedFileLimits) Error!void {
    if (!value.batch.isValid()) return error.InvalidHandle;
    if (value.values.len == 0 or value.values.len > limits.maximum_files) return error.BudgetExceeded;
    var used: usize = 0;
    for (value.values) |descriptor| {
        if (!validUtf8Text(descriptor.suggested_name) or descriptor.suggested_name.len == 0)
            return error.InvalidUtf8;
        if (!validUtf8Text(descriptor.content_type)) return error.InvalidUtf8;
        used = std.math.add(usize, used, descriptor.suggested_name.len) catch return error.BudgetExceeded;
        used = std.math.add(usize, used, descriptor.content_type.len) catch return error.BudgetExceeded;
        if (used > limits.maximum_bytes) return error.BudgetExceeded;
    }
}

fn validatePromisedCompletion(value: PromisedFileCompletion, limits: PromisedFileLimits) Error!void {
    if (!value.operation.isValid()) return error.InvalidHandle;
    if (value.outputs.len > limits.maximum_files) return error.BudgetExceeded;
    var used: usize = 0;
    if (value.error_description) |description| {
        if (!validUtf8Text(description)) return error.InvalidUtf8;
        used = std.math.add(usize, used, description.len) catch return error.BudgetExceeded;
    }
    for (value.outputs) |output| {
        if (output.descriptor_index >= limits.maximum_files) return error.InvalidConfiguration;
        if (output.path) |path| {
            try validatePath(path, limits.maximum_bytes);
            used = std.math.add(usize, used, path.len) catch return error.BudgetExceeded;
        }
        if (output.error_description) |description| {
            if (!validUtf8Text(description)) return error.InvalidUtf8;
            used = std.math.add(usize, used, description.len) catch return error.BudgetExceeded;
        }
        if (used > limits.maximum_bytes) return error.BudgetExceeded;
    }
}

fn validateMenu(items: []const MenuItem, limits: MenuLimits) Error!void {
    if (limits.maximum_items == 0 or limits.maximum_depth == 0 or limits.maximum_text_bytes == 0)
        return error.InvalidConfiguration;
    var count: usize = 0;
    var text_bytes: usize = 0;
    try validateMenuLevel(items, limits, 1, &count, &text_bytes);
}

fn validateMenuLevel(
    items: []const MenuItem,
    limits: MenuLimits,
    depth: usize,
    count: *usize,
    text_bytes: *usize,
) Error!void {
    if (depth > limits.maximum_depth) return error.BudgetExceeded;
    for (items) |item| {
        count.* = std.math.add(usize, count.*, 1) catch return error.BudgetExceeded;
        if (count.* > limits.maximum_items) return error.BudgetExceeded;
        switch (item) {
            .separator => {},
            .action => |definition| {
                if (!definition.action.isValid()) return error.InvalidHandle;
                try chargeMenuText(definition.label, limits.maximum_text_bytes, text_bytes);
                if (definition.shortcut) |shortcut| try validateMenuShortcut(shortcut);
            },
            .submenu => |submenu| {
                try chargeMenuText(submenu.label, limits.maximum_text_bytes, text_bytes);
                try validateMenuLevel(submenu.items, limits, depth + 1, count, text_bytes);
            },
            .application => |application| try validateMenuLevel(application.items, limits, depth + 1, count, text_bytes),
            .system_action => |definition| try chargeMenuText(definition.label, limits.maximum_text_bytes, text_bytes),
        }
    }
}

fn validateMenuShortcut(shortcut: MenuShortcut) Error!void {
    switch (shortcut.key) {
        .character => |value| if (value == 0 or !std.unicode.utf8ValidCodepoint(value)) return error.InvalidConfiguration,
        .function => |number| if (number == 0 or number > 35) return error.InvalidConfiguration,
        .native => return error.Unsupported,
        else => {},
    }
}

fn chargeMenuText(value: []const u8, maximum: usize, used: *usize) Error!void {
    if (!validUtf8Text(value)) return error.InvalidUtf8;
    const next = std.math.add(usize, used.*, value.len) catch return error.BudgetExceeded;
    if (next > maximum) return error.BudgetExceeded;
    used.* = next;
}

const SnapshotProbe = struct {
    calls: usize = 0,
    format: WindowSnapshotFormat = .png_srgb8,
    width: u32 = 8,
    height: u32 = 4,
    byte_count: usize = 8,

    fn capture(raw: *anyopaque, _: handles.WindowId, _: geometry.Size, allocator: std.mem.Allocator) Error!OwnedWindowSnapshot {
        const self: *SnapshotProbe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        const bytes = try allocator.alloc(u8, self.byte_count);
        @memset(bytes, 0);
        if (bytes.len >= 8) @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
        return .{
            .allocator = allocator,
            .bytes = bytes,
            .format = self.format,
            .width = self.width,
            .height = self.height,
            .scale_factor = .{ .value = 2 },
        };
    }
};

fn snapshotStubCreate(_: *anyopaque, _: handles.WindowId, _: WindowOptions) Error!NativeHandle {
    return .{ .kind = .headless, .value = 1 };
}
fn snapshotStubDestroy(_: *anyopaque, _: handles.WindowId) void {}
fn snapshotStubShow(_: *anyopaque, _: handles.WindowId, _: bool) Error!void {}
fn snapshotStubTitle(_: *anyopaque, _: handles.WindowId, _: []const u8) Error!void {}
fn snapshotStubFrame(_: *anyopaque, _: handles.WindowId) Error!void {}
fn snapshotStubCursor(_: *anyopaque, _: handles.WindowId, _: Cursor) Error!void {}
fn snapshotStubCommand(_: *anyopaque, _: handles.WindowId, _: WindowCommand) Error!void {}
fn snapshotStubNative(_: *anyopaque, _: handles.WindowId) ?NativeHandle {
    return .{ .kind = .headless, .value = 1 };
}

fn snapshotWindowSystem(probe: *SnapshotProbe) WindowSystem {
    return .{
        .context = probe,
        .create_fn = snapshotStubCreate,
        .destroy_fn = snapshotStubDestroy,
        .show_fn = snapshotStubShow,
        .title_fn = snapshotStubTitle,
        .request_frame_fn = snapshotStubFrame,
        .set_cursor_fn = snapshotStubCursor,
        .command_fn = snapshotStubCommand,
        .native_handle_fn = snapshotStubNative,
        .capture_window_fn = SnapshotProbe.capture,
    };
}

test "window snapshot contract validates ownership and budgets" {
    const testing = std.testing;
    const id = handles.WindowId.init(1, 1);
    var probe: SnapshotProbe = .{};
    var windows = snapshotWindowSystem(&probe);
    var snapshot = try windows.captureWindow(id, .{ .width = 320, .height = 180 }, testing.allocator);
    defer snapshot.deinit();
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(WindowSnapshotFormat.png_srgb8, snapshot.format);
    try testing.expectEqual(@as(u32, 8), snapshot.width);
    try testing.expectEqual(@as(f32, 2), snapshot.scale_factor.value);

    windows.maximum_snapshot_bytes = 7;
    try testing.expectError(error.BudgetExceeded, windows.captureWindow(id, .{ .width = 320, .height = 180 }, testing.allocator));
    try testing.expectEqual(@as(usize, 2), probe.calls);

    windows.maximum_snapshot_bytes = 256;
    probe.byte_count = 7;
    try testing.expectError(error.InvalidImage, windows.captureWindow(id, .{ .width = 320, .height = 180 }, testing.allocator));
    probe.byte_count = 8;
    probe.format = .png_srgb8;
}

test "window snapshot contract rejects missing capability and invalid targets" {
    const testing = std.testing;
    const id = handles.WindowId.init(1, 1);
    var probe: SnapshotProbe = .{};
    var windows = snapshotWindowSystem(&probe);
    windows.capture_window_fn = null;
    try testing.expectError(error.MissingCapability, windows.captureWindow(id, .{ .width = 320, .height = 180 }, testing.allocator));
    windows.capture_window_fn = SnapshotProbe.capture;
    try testing.expectError(error.InvalidConfiguration, windows.captureWindow(id, .{ .width = 0, .height = 180 }, testing.allocator));
    try testing.expectEqual(@as(usize, 0), probe.calls);
}
