const std = @import("std");
const Error = @import("../../../core/error.zig").Error;
const sys = @import("../sys.zig");
const wire = @import("wire.zig");

pub const Interface = enum {
    wl_display,
    wl_registry,
    wl_callback,
    wl_compositor,
    wl_surface,
    wl_region,
    wl_buffer,
    wl_seat,
    wl_pointer,
    wl_keyboard,
    wl_touch,
    wl_output,
    wl_data_offer,
    wl_data_source,
    wl_data_device,
    wl_data_device_manager,
    xdg_wm_base,
    xdg_positioner,
    xdg_surface,
    xdg_toplevel,
    xdg_popup,
    wp_viewporter,
    wp_viewport,
    wp_fractional_scale_manager_v1,
    wp_fractional_scale_v1,
    wp_cursor_shape_manager_v1,
    wp_cursor_shape_device_v1,
    zwp_text_input_manager_v3,
    zwp_text_input_v3,
    zwp_linux_dmabuf_v1,
    zwp_linux_buffer_params_v1,
    zwp_linux_dmabuf_feedback_v1,
    wp_presentation,
    wp_presentation_feedback,
    zxdg_decoration_manager_v1,
    zxdg_toplevel_decoration_v1,
    zxdg_exporter_v2,
    zxdg_exported_v2,
    wp_linux_drm_syncobj_manager_v1,
    wp_linux_drm_syncobj_timeline_v1,
    wp_linux_drm_syncobj_surface_v1,

    pub fn name(self: Interface) []const u8 {
        return @tagName(self);
    }

    pub fn maximumVersion(self: Interface) u32 {
        return switch (self) {
            .wl_display, .wl_registry, .wl_callback, .wl_buffer => 1,
            .wl_compositor, .wl_surface, .wl_region => 7,
            .wl_seat, .wl_pointer, .wl_keyboard, .wl_touch => 11,
            .wl_output => 4,
            .wl_data_offer, .wl_data_source, .wl_data_device, .wl_data_device_manager => 4,
            .xdg_wm_base, .xdg_positioner, .xdg_surface, .xdg_toplevel, .xdg_popup => 7,
            .wp_cursor_shape_manager_v1, .wp_cursor_shape_device_v1 => 2,
            .zwp_text_input_manager_v3, .zwp_text_input_v3 => 2,
            .zwp_linux_dmabuf_v1, .zwp_linux_buffer_params_v1, .zwp_linux_dmabuf_feedback_v1 => 5,
            .wp_presentation, .wp_presentation_feedback => 2,
            .zxdg_decoration_manager_v1, .zxdg_toplevel_decoration_v1 => 2,
            .wp_viewporter,
            .wp_viewport,
            .wp_fractional_scale_manager_v1,
            .wp_fractional_scale_v1,
            .wp_linux_drm_syncobj_manager_v1,
            .wp_linux_drm_syncobj_timeline_v1,
            .wp_linux_drm_syncobj_surface_v1,
            .zxdg_exporter_v2,
            .zxdg_exported_v2,
            => 1,
        };
    }

    pub fn parse(value: []const u8) ?Interface {
        const info = @typeInfo(Interface).@"enum";
        inline for (info.field_names, info.field_values) |field_name, field_value| {
            if (std.mem.eql(u8, value, field_name)) return @fromBackingInt(@intCast(field_value));
        }
        return null;
    }
};

pub const SeatCapability = struct {
    pub const pointer: u32 = 1;
    pub const keyboard: u32 = 2;
    pub const touch: u32 = 4;
};

pub const PointerButtonState = enum(u32) { released = 0, pressed = 1 };
pub const KeyboardKeyState = enum(u32) { released = 0, pressed = 1, repeated = 2 };
pub const PointerAxis = enum(u32) { vertical = 0, horizontal = 1 };
pub const PointerAxisSource = enum(u32) { wheel = 0, finger = 1, continuous = 2, wheel_tilt = 3 };

pub const CursorShape = enum(u32) {
    default = 1,
    context_menu = 2,
    help = 3,
    pointer = 4,
    progress = 5,
    wait = 6,
    cell = 7,
    crosshair = 8,
    text = 9,
    vertical_text = 10,
    alias = 11,
    copy = 12,
    move = 13,
    no_drop = 14,
    not_allowed = 15,
    grab = 16,
    grabbing = 17,
    e_resize = 18,
    n_resize = 19,
    ne_resize = 20,
    nw_resize = 21,
    s_resize = 22,
    se_resize = 23,
    sw_resize = 24,
    w_resize = 25,
    ew_resize = 26,
    ns_resize = 27,
    nesw_resize = 28,
    nwse_resize = 29,
    col_resize = 30,
    row_resize = 31,
    all_scroll = 32,
    zoom_in = 33,
    zoom_out = 34,
    dnd_ask = 35,
    all_resize = 36,
};

pub const DecorationMode = enum(u32) { client_side = 1, server_side = 2 };

pub const ResizeEdge = enum(u32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 4,
    top_left = 5,
    bottom_left = 6,
    right = 8,
    top_right = 9,
    bottom_right = 10,
};

pub const DataAction = struct {
    pub const none: u32 = 0;
    pub const copy: u32 = 1;
    pub const move: u32 = 2;
    pub const ask: u32 = 4;
};

pub const DmabufFlags = struct {
    pub const none: u32 = 0;
    pub const y_invert: u32 = 1;
    pub const interlaced: u32 = 2;
    pub const bottom_first: u32 = 4;
};

pub fn eventFdCount(interface: Interface, opcode: u16) Error!usize {
    return switch (interface) {
        .wl_keyboard => switch (opcode) {
            0 => 1,
            1...5 => 0,
            else => error.PlatformFailure,
        },
        .wl_data_source => switch (opcode) {
            0 => 0,
            1 => 1,
            2...5 => 0,
            else => error.PlatformFailure,
        },
        .zwp_linux_dmabuf_feedback_v1 => switch (opcode) {
            0 => 0,
            1 => 1,
            2...6 => 0,
            else => error.PlatformFailure,
        },
        else => 0,
    };
}

fn begin(connection: *wire.Connection, object: wire.ObjectId, opcode: u16) Error!*wire.Builder {
    return connection.begin(object, opcode);
}

fn done(connection: *wire.Connection) Error!void {
    try connection.send();
}

pub fn displaySync(connection: *wire.Connection, callback: wire.ObjectId) Error!void {
    const message = try begin(connection, 1, 0);
    try message.newId(connection.allocator, callback);
    try done(connection);
}

pub fn displayGetRegistry(connection: *wire.Connection, registry: wire.ObjectId) Error!void {
    const message = try begin(connection, 1, 1);
    try message.newId(connection.allocator, registry);
    try done(connection);
}

pub fn registryBind(
    connection: *wire.Connection,
    registry: wire.ObjectId,
    global_name: u32,
    interface: Interface,
    version: u32,
    id: wire.ObjectId,
) Error!void {
    const message = try begin(connection, registry, 0);
    try message.u32(connection.allocator, global_name);
    try message.string(connection.allocator, interface.name());
    try message.u32(connection.allocator, version);
    try message.newId(connection.allocator, id);
    try done(connection);
}

pub fn compositorCreateSurface(connection: *wire.Connection, compositor: wire.ObjectId, surface: wire.ObjectId) Error!void {
    const message = try begin(connection, compositor, 0);
    try message.newId(connection.allocator, surface);
    try done(connection);
}

pub fn compositorCreateRegion(connection: *wire.Connection, compositor: wire.ObjectId, region: wire.ObjectId) Error!void {
    const message = try begin(connection, compositor, 1);
    try message.newId(connection.allocator, region);
    try done(connection);
}

pub fn regionDestroy(connection: *wire.Connection, region: wire.ObjectId) Error!void {
    _ = try begin(connection, region, 0);
    try done(connection);
}

pub fn regionAdd(connection: *wire.Connection, region: wire.ObjectId, x: i32, y: i32, width: i32, height: i32) Error!void {
    const message = try begin(connection, region, 1);
    try message.int(connection.allocator, x);
    try message.int(connection.allocator, y);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn surfaceDestroy(connection: *wire.Connection, surface: wire.ObjectId) Error!void {
    _ = try begin(connection, surface, 0);
    try done(connection);
}

pub fn surfaceAttach(connection: *wire.Connection, surface: wire.ObjectId, buffer: ?wire.ObjectId, x: i32, y: i32) Error!void {
    const message = try begin(connection, surface, 1);
    try message.nullableObject(connection.allocator, buffer);
    try message.int(connection.allocator, x);
    try message.int(connection.allocator, y);
    try done(connection);
}

pub fn surfaceDamage(connection: *wire.Connection, surface: wire.ObjectId, x: i32, y: i32, width: i32, height: i32) Error!void {
    const message = try begin(connection, surface, 2);
    try message.int(connection.allocator, x);
    try message.int(connection.allocator, y);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn surfaceFrame(connection: *wire.Connection, surface: wire.ObjectId, callback: wire.ObjectId) Error!void {
    const message = try begin(connection, surface, 3);
    try message.newId(connection.allocator, callback);
    try done(connection);
}

pub fn surfaceSetOpaqueRegion(connection: *wire.Connection, surface: wire.ObjectId, region: ?wire.ObjectId) Error!void {
    const message = try begin(connection, surface, 4);
    try message.nullableObject(connection.allocator, region);
    try done(connection);
}

pub fn surfaceSetInputRegion(connection: *wire.Connection, surface: wire.ObjectId, region: ?wire.ObjectId) Error!void {
    const message = try begin(connection, surface, 5);
    try message.nullableObject(connection.allocator, region);
    try done(connection);
}

pub fn surfaceCommit(connection: *wire.Connection, surface: wire.ObjectId) Error!void {
    _ = try begin(connection, surface, 6);
    try done(connection);
}

pub fn surfaceSetBufferScale(connection: *wire.Connection, surface: wire.ObjectId, scale: i32) Error!void {
    const message = try begin(connection, surface, 8);
    try message.int(connection.allocator, scale);
    try done(connection);
}

pub fn surfaceDamageBuffer(connection: *wire.Connection, surface: wire.ObjectId, x: i32, y: i32, width: i32, height: i32) Error!void {
    const message = try begin(connection, surface, 9);
    try message.int(connection.allocator, x);
    try message.int(connection.allocator, y);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn bufferDestroy(connection: *wire.Connection, buffer: wire.ObjectId) Error!void {
    _ = try begin(connection, buffer, 0);
    try done(connection);
}

pub fn seatGetPointer(connection: *wire.Connection, seat: wire.ObjectId, pointer: wire.ObjectId) Error!void {
    const message = try begin(connection, seat, 0);
    try message.newId(connection.allocator, pointer);
    try done(connection);
}

pub fn seatGetKeyboard(connection: *wire.Connection, seat: wire.ObjectId, keyboard: wire.ObjectId) Error!void {
    const message = try begin(connection, seat, 1);
    try message.newId(connection.allocator, keyboard);
    try done(connection);
}

pub fn seatGetTouch(connection: *wire.Connection, seat: wire.ObjectId, touch: wire.ObjectId) Error!void {
    const message = try begin(connection, seat, 2);
    try message.newId(connection.allocator, touch);
    try done(connection);
}

pub fn pointerSetCursor(connection: *wire.Connection, pointer: wire.ObjectId, serial: u32, surface: ?wire.ObjectId, hotspot_x: i32, hotspot_y: i32) Error!void {
    const message = try begin(connection, pointer, 0);
    try message.u32(connection.allocator, serial);
    try message.nullableObject(connection.allocator, surface);
    try message.int(connection.allocator, hotspot_x);
    try message.int(connection.allocator, hotspot_y);
    try done(connection);
}

pub fn dataDeviceManagerCreateSource(connection: *wire.Connection, manager: wire.ObjectId, source: wire.ObjectId) Error!void {
    const message = try begin(connection, manager, 0);
    try message.newId(connection.allocator, source);
    try done(connection);
}

pub fn dataDeviceManagerGetDevice(connection: *wire.Connection, manager: wire.ObjectId, device: wire.ObjectId, seat: wire.ObjectId) Error!void {
    const message = try begin(connection, manager, 1);
    try message.newId(connection.allocator, device);
    try message.object(connection.allocator, seat);
    try done(connection);
}

pub fn dataSourceOffer(connection: *wire.Connection, source: wire.ObjectId, mime: []const u8) Error!void {
    const message = try begin(connection, source, 0);
    try message.string(connection.allocator, mime);
    try done(connection);
}

pub fn dataSourceDestroy(connection: *wire.Connection, source: wire.ObjectId) Error!void {
    _ = try begin(connection, source, 1);
    try done(connection);
}

pub fn dataSourceSetActions(connection: *wire.Connection, source: wire.ObjectId, actions: u32) Error!void {
    const message = try begin(connection, source, 2);
    try message.u32(connection.allocator, actions);
    try done(connection);
}

pub fn dataDeviceSetSelection(connection: *wire.Connection, device: wire.ObjectId, source: ?wire.ObjectId, serial: u32) Error!void {
    const message = try begin(connection, device, 1);
    try message.nullableObject(connection.allocator, source);
    try message.u32(connection.allocator, serial);
    try done(connection);
}

pub fn dataOfferAccept(connection: *wire.Connection, offer: wire.ObjectId, serial: u32, mime: ?[]const u8) Error!void {
    const message = try begin(connection, offer, 0);
    try message.u32(connection.allocator, serial);
    try message.nullableString(connection.allocator, mime);
    try done(connection);
}

pub fn dataOfferReceive(connection: *wire.Connection, offer: wire.ObjectId, mime: []const u8, descriptor: sys.fd_t) Error!void {
    const message = try begin(connection, offer, 1);
    try message.string(connection.allocator, mime);
    try message.fd(connection.allocator, descriptor);
    try done(connection);
}

pub fn dataOfferSetActions(connection: *wire.Connection, offer: wire.ObjectId, actions: u32, preferred: u32) Error!void {
    const message = try begin(connection, offer, 4);
    try message.u32(connection.allocator, actions);
    try message.u32(connection.allocator, preferred);
    try done(connection);
}

pub fn dataOfferDestroy(connection: *wire.Connection, offer: wire.ObjectId) Error!void {
    _ = try begin(connection, offer, 2);
    try done(connection);
}

pub fn xdgWmBaseGetSurface(connection: *wire.Connection, base: wire.ObjectId, xdg_surface: wire.ObjectId, surface: wire.ObjectId) Error!void {
    const message = try begin(connection, base, 2);
    try message.newId(connection.allocator, xdg_surface);
    try message.object(connection.allocator, surface);
    try done(connection);
}

pub fn xdgWmBaseCreatePositioner(connection: *wire.Connection, base: wire.ObjectId, positioner: wire.ObjectId) Error!void {
    const message = try begin(connection, base, 1);
    try message.newId(connection.allocator, positioner);
    try done(connection);
}

pub fn xdgWmBasePong(connection: *wire.Connection, base: wire.ObjectId, serial: u32) Error!void {
    const message = try begin(connection, base, 3);
    try message.u32(connection.allocator, serial);
    try done(connection);
}

pub fn xdgSurfaceGetToplevel(connection: *wire.Connection, xdg_surface: wire.ObjectId, toplevel: wire.ObjectId) Error!void {
    const message = try begin(connection, xdg_surface, 1);
    try message.newId(connection.allocator, toplevel);
    try done(connection);
}

pub fn xdgSurfaceGetPopup(connection: *wire.Connection, xdg_surface: wire.ObjectId, popup: wire.ObjectId, parent: ?wire.ObjectId, positioner: wire.ObjectId) Error!void {
    const message = try begin(connection, xdg_surface, 2);
    try message.newId(connection.allocator, popup);
    try message.nullableObject(connection.allocator, parent);
    try message.object(connection.allocator, positioner);
    try done(connection);
}

pub fn xdgSurfaceSetWindowGeometry(connection: *wire.Connection, xdg_surface: wire.ObjectId, x: i32, y: i32, width: i32, height: i32) Error!void {
    const message = try begin(connection, xdg_surface, 3);
    try message.int(connection.allocator, x);
    try message.int(connection.allocator, y);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn xdgSurfaceAckConfigure(connection: *wire.Connection, xdg_surface: wire.ObjectId, serial: u32) Error!void {
    const message = try begin(connection, xdg_surface, 4);
    try message.u32(connection.allocator, serial);
    try done(connection);
}

pub fn xdgToplevelSetTitle(connection: *wire.Connection, toplevel: wire.ObjectId, title: []const u8) Error!void {
    const message = try begin(connection, toplevel, 2);
    try message.string(connection.allocator, title);
    try done(connection);
}

pub fn xdgToplevelSetAppId(connection: *wire.Connection, toplevel: wire.ObjectId, app_id: []const u8) Error!void {
    const message = try begin(connection, toplevel, 3);
    try message.string(connection.allocator, app_id);
    try done(connection);
}

pub fn xdgToplevelMove(connection: *wire.Connection, toplevel: wire.ObjectId, seat: wire.ObjectId, serial: u32) Error!void {
    const message = try begin(connection, toplevel, 5);
    try message.object(connection.allocator, seat);
    try message.u32(connection.allocator, serial);
    try done(connection);
}

pub fn xdgToplevelResize(connection: *wire.Connection, toplevel: wire.ObjectId, seat: wire.ObjectId, serial: u32, edge: ResizeEdge) Error!void {
    const message = try begin(connection, toplevel, 6);
    try message.object(connection.allocator, seat);
    try message.u32(connection.allocator, serial);
    try message.u32(connection.allocator, @backingInt(edge));
    try done(connection);
}

pub fn xdgToplevelSetMaximumSize(connection: *wire.Connection, toplevel: wire.ObjectId, width: i32, height: i32) Error!void {
    const message = try begin(connection, toplevel, 7);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn xdgToplevelSetMinimumSize(connection: *wire.Connection, toplevel: wire.ObjectId, width: i32, height: i32) Error!void {
    const message = try begin(connection, toplevel, 8);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn xdgToplevelSetMaximized(connection: *wire.Connection, toplevel: wire.ObjectId, enabled: bool) Error!void {
    _ = try begin(connection, toplevel, if (enabled) 9 else 10);
    try done(connection);
}

pub fn xdgToplevelSetFullscreen(connection: *wire.Connection, toplevel: wire.ObjectId, output: ?wire.ObjectId) Error!void {
    const message = try begin(connection, toplevel, 11);
    try message.nullableObject(connection.allocator, output);
    try done(connection);
}

pub fn xdgToplevelUnsetFullscreen(connection: *wire.Connection, toplevel: wire.ObjectId) Error!void {
    _ = try begin(connection, toplevel, 12);
    try done(connection);
}

pub fn xdgToplevelSetMinimized(connection: *wire.Connection, toplevel: wire.ObjectId) Error!void {
    _ = try begin(connection, toplevel, 13);
    try done(connection);
}

pub fn positionerSetSize(connection: *wire.Connection, positioner: wire.ObjectId, width: i32, height: i32) Error!void {
    const message = try begin(connection, positioner, 1);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn positionerSetAnchorRect(connection: *wire.Connection, positioner: wire.ObjectId, x: i32, y: i32, width: i32, height: i32) Error!void {
    const message = try begin(connection, positioner, 2);
    try message.int(connection.allocator, x);
    try message.int(connection.allocator, y);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn positionerSetAnchor(connection: *wire.Connection, positioner: wire.ObjectId, anchor: u32) Error!void {
    const message = try begin(connection, positioner, 3);
    try message.u32(connection.allocator, anchor);
    try done(connection);
}

pub fn positionerSetGravity(connection: *wire.Connection, positioner: wire.ObjectId, gravity: u32) Error!void {
    const message = try begin(connection, positioner, 4);
    try message.u32(connection.allocator, gravity);
    try done(connection);
}

pub fn positionerSetConstraintAdjustment(connection: *wire.Connection, positioner: wire.ObjectId, adjustment: u32) Error!void {
    const message = try begin(connection, positioner, 5);
    try message.u32(connection.allocator, adjustment);
    try done(connection);
}

pub fn positionerSetOffset(connection: *wire.Connection, positioner: wire.ObjectId, x: i32, y: i32) Error!void {
    const message = try begin(connection, positioner, 6);
    try message.int(connection.allocator, x);
    try message.int(connection.allocator, y);
    try done(connection);
}

pub fn popupGrab(connection: *wire.Connection, popup: wire.ObjectId, seat: wire.ObjectId, serial: u32) Error!void {
    const message = try begin(connection, popup, 1);
    try message.object(connection.allocator, seat);
    try message.u32(connection.allocator, serial);
    try done(connection);
}

pub fn viewporterGetViewport(connection: *wire.Connection, viewporter: wire.ObjectId, viewport: wire.ObjectId, surface: wire.ObjectId) Error!void {
    const message = try begin(connection, viewporter, 1);
    try message.newId(connection.allocator, viewport);
    try message.object(connection.allocator, surface);
    try done(connection);
}

pub fn viewportSetDestination(connection: *wire.Connection, viewport: wire.ObjectId, width: i32, height: i32) Error!void {
    const message = try begin(connection, viewport, 2);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn fractionalScaleGet(connection: *wire.Connection, manager: wire.ObjectId, scale: wire.ObjectId, surface: wire.ObjectId) Error!void {
    const message = try begin(connection, manager, 1);
    try message.newId(connection.allocator, scale);
    try message.object(connection.allocator, surface);
    try done(connection);
}

pub fn cursorShapeGetPointer(connection: *wire.Connection, manager: wire.ObjectId, device: wire.ObjectId, pointer: wire.ObjectId) Error!void {
    const message = try begin(connection, manager, 1);
    try message.newId(connection.allocator, device);
    try message.object(connection.allocator, pointer);
    try done(connection);
}

pub fn cursorShapeSet(connection: *wire.Connection, device: wire.ObjectId, serial: u32, shape: CursorShape) Error!void {
    const message = try begin(connection, device, 1);
    try message.u32(connection.allocator, serial);
    try message.u32(connection.allocator, @backingInt(shape));
    try done(connection);
}

pub fn textInputManagerGet(connection: *wire.Connection, manager: wire.ObjectId, text_input: wire.ObjectId, seat: wire.ObjectId) Error!void {
    const message = try begin(connection, manager, 1);
    try message.newId(connection.allocator, text_input);
    try message.object(connection.allocator, seat);
    try done(connection);
}

pub fn textInputEnable(connection: *wire.Connection, text_input: wire.ObjectId) Error!void {
    _ = try begin(connection, text_input, 1);
    try done(connection);
}

pub fn textInputDisable(connection: *wire.Connection, text_input: wire.ObjectId) Error!void {
    _ = try begin(connection, text_input, 2);
    try done(connection);
}

pub fn textInputSetSurrounding(connection: *wire.Connection, text_input: wire.ObjectId, text: []const u8, cursor: i32, anchor: i32) Error!void {
    const message = try begin(connection, text_input, 3);
    try message.string(connection.allocator, text);
    try message.int(connection.allocator, cursor);
    try message.int(connection.allocator, anchor);
    try done(connection);
}

pub fn textInputSetContentType(connection: *wire.Connection, text_input: wire.ObjectId, hints: u32, purpose: u32) Error!void {
    const message = try begin(connection, text_input, 5);
    try message.u32(connection.allocator, hints);
    try message.u32(connection.allocator, purpose);
    try done(connection);
}

pub fn textInputSetCursorRectangle(connection: *wire.Connection, text_input: wire.ObjectId, x: i32, y: i32, width: i32, height: i32) Error!void {
    const message = try begin(connection, text_input, 6);
    try message.int(connection.allocator, x);
    try message.int(connection.allocator, y);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try done(connection);
}

pub fn textInputCommit(connection: *wire.Connection, text_input: wire.ObjectId) Error!void {
    _ = try begin(connection, text_input, 7);
    try done(connection);
}

pub fn dmabufCreateParams(connection: *wire.Connection, dmabuf: wire.ObjectId, params: wire.ObjectId) Error!void {
    const message = try begin(connection, dmabuf, 1);
    try message.newId(connection.allocator, params);
    try done(connection);
}

pub fn dmabufGetDefaultFeedback(connection: *wire.Connection, dmabuf: wire.ObjectId, feedback: wire.ObjectId) Error!void {
    const message = try begin(connection, dmabuf, 2);
    try message.newId(connection.allocator, feedback);
    try done(connection);
}

pub fn dmabufGetSurfaceFeedback(connection: *wire.Connection, dmabuf: wire.ObjectId, feedback: wire.ObjectId, surface: wire.ObjectId) Error!void {
    const message = try begin(connection, dmabuf, 3);
    try message.newId(connection.allocator, feedback);
    try message.object(connection.allocator, surface);
    try done(connection);
}

pub fn dmabufParamsAdd(
    connection: *wire.Connection,
    params: wire.ObjectId,
    descriptor: sys.fd_t,
    plane: u32,
    offset: u32,
    stride: u32,
    modifier: u64,
) Error!void {
    const message = try begin(connection, params, 1);
    try message.fd(connection.allocator, descriptor);
    try message.u32(connection.allocator, plane);
    try message.u32(connection.allocator, offset);
    try message.u32(connection.allocator, stride);
    try message.u32(connection.allocator, @truncate(modifier >> 32));
    try message.u32(connection.allocator, @truncate(modifier));
    try done(connection);
}

pub fn dmabufParamsDestroy(connection: *wire.Connection, params: wire.ObjectId) Error!void {
    _ = try begin(connection, params, 0);
    try done(connection);
}

pub fn dmabufParamsCreateImmediate(
    connection: *wire.Connection,
    params: wire.ObjectId,
    buffer: wire.ObjectId,
    width: i32,
    height: i32,
    format: u32,
    flags: u32,
) Error!void {
    const message = try begin(connection, params, 3);
    try message.newId(connection.allocator, buffer);
    try message.int(connection.allocator, width);
    try message.int(connection.allocator, height);
    try message.u32(connection.allocator, format);
    try message.u32(connection.allocator, flags);
    try done(connection);
}

pub fn presentationFeedback(connection: *wire.Connection, presentation: wire.ObjectId, surface: wire.ObjectId, feedback: wire.ObjectId) Error!void {
    const message = try begin(connection, presentation, 1);
    try message.object(connection.allocator, surface);
    try message.newId(connection.allocator, feedback);
    try done(connection);
}

pub fn decorationGetToplevel(connection: *wire.Connection, manager: wire.ObjectId, decoration: wire.ObjectId, toplevel: wire.ObjectId) Error!void {
    const message = try begin(connection, manager, 1);
    try message.newId(connection.allocator, decoration);
    try message.object(connection.allocator, toplevel);
    try done(connection);
}

pub fn decorationSetMode(connection: *wire.Connection, decoration: wire.ObjectId, mode: DecorationMode) Error!void {
    const message = try begin(connection, decoration, 1);
    try message.u32(connection.allocator, @backingInt(mode));
    try done(connection);
}

pub fn foreignExporterExportToplevel(connection: *wire.Connection, exporter: wire.ObjectId, exported: wire.ObjectId, surface: wire.ObjectId) Error!void {
    const message = try begin(connection, exporter, 1);
    try message.newId(connection.allocator, exported);
    try message.object(connection.allocator, surface);
    try done(connection);
}

pub fn foreignExportedDestroy(connection: *wire.Connection, exported: wire.ObjectId) Error!void {
    _ = try begin(connection, exported, 0);
    try done(connection);
}

pub fn syncobjGetSurface(connection: *wire.Connection, manager: wire.ObjectId, sync_surface: wire.ObjectId, surface: wire.ObjectId) Error!void {
    const message = try begin(connection, manager, 1);
    try message.newId(connection.allocator, sync_surface);
    try message.object(connection.allocator, surface);
    try done(connection);
}

pub fn syncobjImportTimeline(connection: *wire.Connection, manager: wire.ObjectId, timeline: wire.ObjectId, descriptor: sys.fd_t) Error!void {
    const message = try begin(connection, manager, 2);
    try message.newId(connection.allocator, timeline);
    try message.fd(connection.allocator, descriptor);
    try done(connection);
}

pub fn syncobjSetAcquirePoint(connection: *wire.Connection, sync_surface: wire.ObjectId, timeline: wire.ObjectId, point: u64) Error!void {
    const message = try begin(connection, sync_surface, 1);
    try message.object(connection.allocator, timeline);
    try message.u32(connection.allocator, @truncate(point >> 32));
    try message.u32(connection.allocator, @truncate(point));
    try done(connection);
}

pub fn syncobjSetReleasePoint(connection: *wire.Connection, sync_surface: wire.ObjectId, timeline: wire.ObjectId, point: u64) Error!void {
    const message = try begin(connection, sync_surface, 2);
    try message.object(connection.allocator, timeline);
    try message.u32(connection.allocator, @truncate(point >> 32));
    try message.u32(connection.allocator, @truncate(point));
    try done(connection);
}
