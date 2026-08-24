const std = @import("std");
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const Error = @import("../core/error.zig").Error;
const a11y = @import("../a11y/api.zig");
const layout = @import("../layout/style.zig");
const coordinator_mod = @import("../runtime/coordinator.zig");
const state = @import("../runtime/state.zig");

pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    command: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    function: bool = false,
    _padding: u1 = 0,
};

pub const KeyLocation = enum { standard, left, right, numpad };

pub const Key = union(enum) {
    character: u21,
    enter,
    escape,
    tab,
    backspace,
    delete,
    insert,
    home,
    end,
    page_up,
    page_down,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    space,
    function: u8,
    native: u32,
};

pub const KeyEvent = struct {
    key: Key,
    physical_code: u32,
    location: KeyLocation = .standard,
    modifiers: Modifiers = .{},
    repeat: bool = false,
    composing: bool = false,
    timestamp_ns: u64 = 0,
};

pub const MouseButton = enum(u8) { primary, secondary, middle, back, forward, other };
pub const PointerKind = enum { mouse, touch, pen, eraser };

pub const PointerEvent = struct {
    pointer_id: u64 = 0,
    kind: PointerKind = .mouse,
    position: geometry.Point,
    delta: geometry.Point = .{},
    button: ?MouseButton = null,
    buttons: u32 = 0,
    pressure: f32 = 0,
    tilt: geometry.Point = .{},
    modifiers: Modifiers = .{},
    click_count: u8 = 0,
    timestamp_ns: u64 = 0,
};

pub const ScrollPhase = enum { none, began, changed, ended, cancelled, momentum_began, momentum_ended };

pub const ScrollEvent = struct {
    position: geometry.Point,
    delta: geometry.Point,
    precise: bool,
    phase: ScrollPhase = .none,
    modifiers: Modifiers = .{},
    timestamp_ns: u64 = 0,
};

pub const TextRange = struct {
    start: usize = 0,
    end: usize = 0,

    pub fn normalized(self: TextRange) TextRange {
        if (self.start <= self.end) return self;
        return .{ .start = self.end, .end = self.start };
    }
};

pub const ImeEvent = union(enum) {
    set_marked_text: struct {
        text: []const u8,
        selected_utf8: TextRange,
        replacement_utf8: ?TextRange,
    },
    commit_text: struct {
        text: []const u8,
        replacement_utf8: ?TextRange,
    },
    unmark_text,
    cancel_composition,
    request_surrounding_text,
};

pub const FileDrop = struct {
    paths: []const []const u8,
    position: geometry.Point,
};

/// Platform-neutral representation of an action initiated by a native
/// accessibility client. The platform adapter identifies the semantic node;
/// App resolves that stable identity back to a retained node before dispatch.
pub const AccessibilityEvent = struct {
    /// The stable semantic node that originated the request. For ordinary
    /// controls this maps to the retained owner. Custom elements can compare
    /// it with IDs returned by `SemanticsWriter.append` to address a virtual
    /// semantic descendant precisely.
    target: handles.SemanticId,
    action: a11y.Action,
    value: ?[]const u8 = null,
    selection: ?a11y.Selection = null,
};

pub const Event = union(enum) {
    pointer_down: PointerEvent,
    pointer_up: PointerEvent,
    pointer_move: PointerEvent,
    pointer_enter: PointerEvent,
    pointer_leave: PointerEvent,
    pointer_cancel: PointerEvent,
    scroll: ScrollEvent,
    key_down: KeyEvent,
    key_up: KeyEvent,
    ime: ImeEvent,
    accessibility: AccessibilityEvent,
    focus_in,
    focus_out,
    file_drop_entered: FileDrop,
    file_drop_updated: FileDrop,
    file_drop_exited,
    file_drop_performed: FileDrop,
};

pub const ValidationLimits = struct {
    maximum_payload_bytes: usize = 16 * 1024 * 1024,
    maximum_file_paths: usize = 4_096,
};

pub fn validate(value: *const Event, limits: ValidationLimits) Error!void {
    switch (value.*) {
        .pointer_down, .pointer_up, .pointer_move, .pointer_enter, .pointer_leave, .pointer_cancel => |pointer| {
            if (!finitePoint(pointer.position) or !finitePoint(pointer.delta) or !finitePoint(pointer.tilt) or
                !std.math.isFinite(pointer.pressure) or pointer.pressure < 0 or pointer.pressure > 1)
                return error.InvalidConfiguration;
        },
        .scroll => |scroll| if (!finitePoint(scroll.position) or !finitePoint(scroll.delta))
            return error.InvalidConfiguration,
        .key_down, .key_up => |key| switch (key.key) {
            .character => |codepoint| if (!validCodepoint(codepoint)) return error.InvalidConfiguration,
            else => {},
        },
        .ime => |ime| switch (ime) {
            .set_marked_text => |marked| {
                try validatePayload(marked.text, limits.maximum_payload_bytes);
                try validateRange(marked.text, marked.selected_utf8);
                if (marked.replacement_utf8) |replacement| try validateUnboundRange(replacement, limits.maximum_payload_bytes);
            },
            .commit_text => |commit| {
                try validatePayload(commit.text, limits.maximum_payload_bytes);
                if (commit.replacement_utf8) |replacement| try validateUnboundRange(replacement, limits.maximum_payload_bytes);
            },
            else => {},
        },
        .accessibility => |request| {
            if (!request.target.isValid()) return error.InvalidHandle;
            if (request.value) |text| try validatePayload(text, limits.maximum_payload_bytes);
            if (request.selection) |selection| {
                if (request.value) |text| {
                    try validateRange(text, (TextRange{ .start = selection.anchor, .end = selection.focus }).normalized());
                } else if (selection.anchor > limits.maximum_payload_bytes or selection.focus > limits.maximum_payload_bytes) {
                    return error.BudgetExceeded;
                }
            }
        },
        .file_drop_entered, .file_drop_updated, .file_drop_performed => |drop| {
            if (!finitePoint(drop.position)) return error.InvalidConfiguration;
            if (drop.paths.len > limits.maximum_file_paths) return error.BudgetExceeded;
            var total: usize = 0;
            for (drop.paths) |path| {
                if (path.len == 0) return error.InvalidConfiguration;
                try validatePayload(path, limits.maximum_payload_bytes);
                total = std.math.add(usize, total, path.len) catch return error.BudgetExceeded;
                if (total > limits.maximum_payload_bytes) return error.BudgetExceeded;
            }
        },
        .focus_in, .focus_out, .file_drop_exited => {},
    }
}

/// A deliberately small bridge from focused editable elements to the native
/// text input system. It lives in the input layer so controls do not depend on
/// AppKit, Win32, Wayland, X11, or the platform bundle.
pub const NativeTextInput = struct {
    context: *anyopaque,
    set_active_fn: *const fn (*anyopaque, handles.WindowId, bool) Error!void,
    set_candidate_rect_fn: *const fn (*anyopaque, handles.WindowId, geometry.Rect) Error!void,
    set_surrounding_text_fn: *const fn (*anyopaque, handles.WindowId, []const u8, TextRange) Error!void,
    maximum_surrounding_text_bytes: usize = 16 * 1024 * 1024,

    pub fn setActive(self: NativeTextInput, window: handles.WindowId, active: bool) Error!void {
        if (!window.isValid()) return error.InvalidHandle;
        try self.set_active_fn(self.context, window, active);
    }

    pub fn setCandidateRect(self: NativeTextInput, window: handles.WindowId, rect: geometry.Rect) Error!void {
        if (!window.isValid()) return error.InvalidHandle;
        if (!finiteRect(rect)) return error.InvalidConfiguration;
        try self.set_candidate_rect_fn(self.context, window, rect);
    }

    pub fn setSurroundingText(self: NativeTextInput, window: handles.WindowId, text: []const u8, selection: TextRange) Error!void {
        if (!window.isValid()) return error.InvalidHandle;
        if (text.len > self.maximum_surrounding_text_bytes) return error.BudgetExceeded;
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null or
            selection.start > selection.end or selection.end > text.len or
            !utf8Boundary(text, selection.start) or !utf8Boundary(text, selection.end))
            return error.InvalidConfiguration;
        try self.set_surrounding_text_fn(self.context, window, text, selection);
    }
};

/// Narrow, allocator-explicit clipboard service available to standard and
/// custom editable elements during serialized input dispatch. Returned text is
/// always owned by the allocator supplied by the caller.
pub const NativeClipboard = struct {
    context: *anyopaque,
    read_text_fn: *const fn (*anyopaque, std.mem.Allocator) Error!?[]u8,
    write_text_fn: *const fn (*anyopaque, []const u8) Error!void,
    maximum_bytes: usize = 64 * 1024 * 1024,

    pub fn readText(self: NativeClipboard, allocator: std.mem.Allocator) Error!?[]u8 {
        if (self.maximum_bytes == 0) return error.InvalidConfiguration;
        const result = try self.read_text_fn(self.context, allocator);
        if (result) |value| {
            if (value.len > self.maximum_bytes) {
                allocator.free(value);
                return error.BudgetExceeded;
            }
            validatePayload(value, self.maximum_bytes) catch |err| {
                allocator.free(value);
                return err;
            };
        }
        return result;
    }

    pub fn writeText(self: NativeClipboard, value: []const u8) Error!void {
        if (self.maximum_bytes == 0) return error.InvalidConfiguration;
        try validatePayload(value, self.maximum_bytes);
        try self.write_text_fn(self.context, value);
    }
};

fn finiteRect(value: geometry.Rect) bool {
    return std.math.isFinite(value.origin.x) and std.math.isFinite(value.origin.y) and
        std.math.isFinite(value.size.width) and std.math.isFinite(value.size.height) and
        value.size.width >= 0 and value.size.height >= 0;
}

fn utf8Boundary(value: []const u8, index: usize) bool {
    return index == value.len or (index < value.len and value[index] & 0xc0 != 0x80);
}

fn finitePoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}

fn validatePayload(value: []const u8, maximum: usize) Error!void {
    if (value.len > maximum) return error.BudgetExceeded;
    if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
        return error.InvalidUtf8;
}

fn validateRange(value: []const u8, range: TextRange) Error!void {
    if (range.start > range.end or range.end > value.len or
        !utf8Boundary(value, range.start) or !utf8Boundary(value, range.end))
        return error.InvalidConfiguration;
}

fn validateUnboundRange(range: TextRange, maximum: usize) Error!void {
    if (range.start > range.end or range.end > maximum) return error.InvalidConfiguration;
}

fn validCodepoint(value: u21) bool {
    return value <= 0x10ffff and !(value >= 0xd800 and value <= 0xdfff);
}

pub const Phase = enum { capture, target, bubble };

pub const Dispatch = struct {
    window: handles.WindowId,
    target: handles.NodeId,
    current: handles.NodeId,
    phase: Phase,
    handled: bool = false,
    propagation_stopped: bool = false,
    default_prevented: bool = false,
    pointer_capture: ?handles.NodeId = null,
    release_pointer_capture: bool = false,
    requested_focus: ?handles.NodeId = null,
    requested_autofocus_after_reconcile: bool = false,

    pub fn stopPropagation(self: *Dispatch) void {
        self.propagation_stopped = true;
    }

    pub fn preventDefault(self: *Dispatch) void {
        self.default_prevented = true;
    }

    pub fn capturePointer(self: *Dispatch, node: handles.NodeId) void {
        self.pointer_capture = node;
        self.release_pointer_capture = false;
    }

    pub fn releasePointer(self: *Dispatch) void {
        self.pointer_capture = null;
        self.release_pointer_capture = true;
    }

    pub fn requestFocus(self: *Dispatch, node: handles.NodeId) void {
        self.requested_focus = node;
        self.requested_autofocus_after_reconcile = false;
    }

    /// Keeps the currently committed focus until the next successful frame,
    /// then transfers it to that frame's declarative autofocus identity. This
    /// is used by roving-focus controls whose destination is selected by key
    /// before its retained node becomes the sole sequential candidate.
    pub fn requestAutofocusAfterReconcile(self: *Dispatch) void {
        self.requested_focus = null;
        self.requested_autofocus_after_reconcile = true;
    }
};

pub const Handler = struct {
    context: *anyopaque,
    callback: *const fn (*anyopaque, *Dispatch, *const Event, *Context) Error!void,
    phase: Phase = .bubble,
};

pub const Context = struct {
    coordinator: *coordinator_mod.Coordinator,
    component: handles.ComponentId,
    window: handles.WindowId,
    /// Axis-aligned visual bounds in window coordinates.
    current_bounds: geometry.Rect = .{},
    /// Retained layout bounds before scroll and paint transforms.
    current_layout_bounds: geometry.Rect = .{},
    /// Laid-out content box and total scrollable extent for the current node.
    current_content_bounds: geometry.Rect = .{},
    current_scroll_extent: geometry.Size = .{},
    local_to_world: geometry.Affine2D = .identity,
    world_to_local: geometry.Affine2D = .identity,
    native_text_input: ?NativeTextInput = null,
    native_clipboard: ?NativeClipboard = null,

    pub fn localPoint(self: *const Context, point: geometry.Point) geometry.Point {
        return self.world_to_local.transformPoint(point);
    }

    pub fn worldPoint(self: *const Context, point: geometry.Point) geometry.Point {
        return self.local_to_world.transformPoint(point);
    }

    pub fn worldRect(self: *const Context, rect: geometry.Rect) geometry.Rect {
        return self.local_to_world.transformRectBounds(rect);
    }

    pub fn contains(self: *const Context, point: geometry.Point) bool {
        return self.current_layout_bounds.contains(self.localPoint(point));
    }

    pub fn beginStateWrite(self: *Context, comptime T: type, handle: state.Handle(T)) Error!state.WriteGuard(T) {
        return self.coordinator.states.beginWrite(T, handle);
    }

    pub fn invalidate(self: *Context, dirty: layout.Dirty) Error!void {
        try self.coordinator.invalidateComponent(self.component, dirty);
    }

    pub fn requestFrame(self: *Context) Error!void {
        _ = self.coordinator.invalidations.markWindow(self.window);
    }

    pub fn setTextInputActive(self: *Context, active: bool) Error!void {
        if (self.native_text_input) |bridge| try bridge.setActive(self.window, active);
    }

    pub fn updateTextInput(self: *Context, text: []const u8, selection: TextRange, candidate_rect: geometry.Rect) Error!void {
        if (self.native_text_input) |bridge| {
            try bridge.setSurroundingText(self.window, text, selection);
            try bridge.setCandidateRect(self.window, candidate_rect);
        }
    }

    pub fn hasClipboard(self: *const Context) bool {
        return self.native_clipboard != null;
    }

    pub fn readClipboardText(self: *Context, allocator: std.mem.Allocator) Error!?[]u8 {
        const bridge = self.native_clipboard orelse return error.MissingCapability;
        return bridge.readText(allocator);
    }

    pub fn writeClipboardText(self: *Context, value: []const u8) Error!void {
        const bridge = self.native_clipboard orelse return error.MissingCapability;
        try bridge.writeText(value);
    }
};
