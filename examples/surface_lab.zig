const std = @import("std");
const ui = @import("zigui");
const native_surface_macos = @import("native_surface_macos.zig");

const NativeSurfaceOwner = if (ui.config.compiled_renderer == .metal) native_surface_macos.Owned else void;
const extension_payload = "zigui-surface-lab-extension-v1";

const ExtensionProbe = struct {
    allocator: std.mem.Allocator,
    prepares: usize = 0,
    encodes: usize = 0,
    device_losses: usize = 0,
    generation: ui.render_extension.DeviceGeneration = 0,

    fn descriptor(self: *ExtensionProbe) ui.render_extension.Descriptor {
        return .{ .context = self, .vtable = &vtable, .label = "surface-lab portable pass" };
    }

    const vtable: ui.render_extension.Descriptor.VTable = .{
        .prepare = prepare,
        .encode = encode,
        .device_lost = deviceLost,
        .deinit = deinit,
    };

    fn cast(raw: *anyopaque) *ExtensionProbe {
        return @ptrCast(@alignCast(raw));
    }

    fn prepare(raw: *anyopaque, device: ui.render_extension.Device, generation: ui.render_extension.DeviceGeneration) ui.Error!void {
        if (std.meta.activeTag(device) != expectedBackend()) return error.InvalidConfiguration;
        const self = cast(raw);
        self.prepares +|= 1;
        self.generation = generation;
    }

    fn encode(raw: *anyopaque, pass: ui.render_extension.Pass, payload: []const u8, flags: u32) ui.Error!void {
        if (std.meta.activeTag(pass) != expectedBackend() or !std.mem.eql(u8, payload, extension_payload) or flags != 0x5a49_4755)
            return error.InvalidConfiguration;
        const frame = pass.geometry();
        if (!frame.window.isValid() or frame.drawable_width == 0 or frame.drawable_height == 0 or
            !std.math.isFinite(frame.bounds.origin.x) or !std.math.isFinite(frame.bounds.origin.y) or
            !std.math.isFinite(frame.bounds.size.width) or !std.math.isFinite(frame.bounds.size.height) or
            frame.bounds.size.width < 0 or frame.bounds.size.height < 0)
            return error.InvalidScene;
        cast(raw).encodes +|= 1;
    }

    fn deviceLost(raw: *anyopaque, generation: ui.render_extension.DeviceGeneration) void {
        const self = cast(raw);
        self.device_losses +|= 1;
        self.generation = generation;
    }

    fn deinit(raw: *anyopaque) void {
        const self = cast(raw);
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn expectedBackend() ui.render_extension.Backend {
    return switch (ui.config.compiled_renderer) {
        .null => .null,
        .metal => .metal,
        .d3d11 => .d3d11,
        .vulkan => .vulkan,
        .auto => unreachable,
    };
}

const ExtensionView = struct {
    owner: *Model,

    pub fn measure(_: *ExtensionView, _: *ui.custom.MeasureContext, constraints: ui.layout.Constraints) ui.Error!ui.Size {
        return constraints.constrain(.{ .width = 320, .height = 185 });
    }

    pub fn paint(self: *ExtensionView, ctx: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        try ctx.quad(.{
            .bounds = bounds,
            .background = ui.Color.rgba8(19, 27, 43, 255),
            .border_color = ui.Color.rgba8(83, 111, 166, 255),
            .border_widths = ui.Insets.all(1),
            .radii = ui.CornerRadii.all(8),
        });
        try ctx.gpuPass(self.owner.extension_id, bounds.inset(ui.Insets.all(8)), extension_payload, 0x5a49_4755);
    }
};

const ExternalSurfaceView = struct {
    surface: ui.core.handles.SurfaceId,
    width: u32,
    height: u32,

    pub fn measure(self: *ExternalSurfaceView, _: *ui.custom.MeasureContext, constraints: ui.layout.Constraints) ui.Error!ui.Size {
        return constraints.constrain(.{ .width = @floatFromInt(self.width), .height = @floatFromInt(self.height) });
    }

    pub fn paint(self: *ExternalSurfaceView, ctx: *ui.custom.PaintContext, bounds: ui.Rect) ui.Error!void {
        if (!self.surface.isValid()) return error.InvalidHandle;
        try ctx.emit(.{ .external_surface = .{
            .bounds = bounds,
            .uv_bounds = ui.Rect.fromXYWH(0, 0, 1, 1),
            .surface = self.surface.encode(),
            .generation = self.surface.generation,
            .color_space = @backingInt(ui.render.ColorSpace.srgb),
            .opacity = 1,
        } });
    }
};

const Model = struct {
    const MediaView = if (ui.config.media_enabled) ui.media.View else void;

    allocator: std.mem.Allocator,
    app: *ui.App,
    texture: ui.core.handles.TextureId = .invalid,
    media_id: ?ui.core.handles.MediaId = null,
    media_view: MediaView = if (ui.config.media_enabled) undefined else {},
    native_surface_owner: NativeSurfaceOwner = if (ui.config.compiled_renderer == .metal) undefined else {},
    native_surface_ready: bool = false,
    external_surface_id: ui.core.handles.SurfaceId = .invalid,
    external_view: ExternalSurfaceView = undefined,
    extension_id: ui.core.handles.RenderExtensionId = .invalid,
    extension_probe: ?*ExtensionProbe = null,
    extension_view: ExtensionView = undefined,
    status: []const u8 = if (ui.config.images_enabled) "GPU texture resident" else "Enable -Dimages=true for the generated texture proof",
    play_button: ui.widgets.Button = undefined,
    pause_button: ui.widgets.Button = undefined,
    restart_button: ui.widgets.Button = undefined,

    fn init(allocator: std.mem.Allocator, app: *ui.App) ui.Error!Model {
        var result: Model = .{ .allocator = allocator, .app = app };
        errdefer {
            if (result.extension_id.isValid()) app.destroyRenderExtension(result.extension_id) catch {} else if (result.extension_probe) |probe| allocator.destroy(probe);
            if (result.external_surface_id.isValid()) app.destroyExternalSurface(result.external_surface_id) catch {};
            if (comptime ui.config.compiled_renderer == .metal) if (result.native_surface_ready) result.native_surface_owner.deinit();
            if (result.media_id) |id| app.releaseMedia(id) catch {};
            if (result.texture.isValid()) app.releaseImage(result.texture) catch {};
        }
        if (comptime ui.config.images_enabled) {
            const encoded = try makeQoi(allocator, 48, 48);
            defer allocator.free(encoded);
            result.texture = try app.loadImage(encoded);
        }
        if (comptime ui.config.media_enabled) {
            const encoded = try makeY4m(allocator, 64, 64, 24);
            defer allocator.free(encoded);
            result.media_id = try app.createY4mMedia(encoded);
            result.media_view = .{ .visual = try app.mediaVisual(result.media_id.?), .label = "Generated Y4M media surface" };
        }
        if (comptime ui.config.compiled_renderer == .metal) {
            result.native_surface_owner = try native_surface_macos.Owned.create(allocator, 96, 96);
            result.native_surface_ready = true;
            result.external_surface_id = try app.importExternalSurface(result.native_surface_owner.descriptor());
            result.status = "Real application-owned Metal texture imported through ZigUI's submission-retired external-surface path";
        }
        const probe = try allocator.create(ExtensionProbe);
        probe.* = .{ .allocator = allocator };
        result.extension_probe = probe;
        result.extension_id = try app.registerRenderExtension(probe.descriptor());
        result.repairPointers();
        return result;
    }

    fn repairPointers(self: *Model) void {
        self.play_button = .{ .label = "Play", .on_activate = ui.widgets.Callback.from(Model, self, "play"), .disabled = self.media_id == null };
        self.pause_button = .{ .label = "Pause", .on_activate = ui.widgets.Callback.from(Model, self, "pause"), .disabled = self.media_id == null };
        self.restart_button = .{ .label = "Restart", .on_activate = ui.widgets.Callback.from(Model, self, "restart"), .disabled = self.media_id == null };
        self.extension_view = .{ .owner = self };
        self.external_view = .{ .surface = self.external_surface_id, .width = 96, .height = 96 };
    }

    fn deinit(self: *Model) void {
        if (self.extension_id.isValid()) self.app.destroyRenderExtension(self.extension_id) catch {};
        self.extension_id = .invalid;
        self.extension_probe = null;
        if (self.external_surface_id.isValid()) self.app.destroyExternalSurface(self.external_surface_id) catch {};
        self.external_surface_id = .invalid;
        if (comptime ui.config.compiled_renderer == .metal) if (self.native_surface_ready) self.native_surface_owner.deinit();
        if (self.media_id) |id| self.app.releaseMedia(id) catch {};
        if (self.texture.isValid()) self.app.releaseImage(self.texture) catch {};
        self.* = undefined;
    }

    pub fn play(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        const id = self.media_id orelse return;
        self.app.playMedia(id) catch |err| {
            self.status = @errorName(err);
            try ctx.invalidate(.{});
            return;
        };
        self.status = "Playing generated media through the bounded texture path";
        try ctx.invalidate(.{});
    }

    pub fn pause(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        const id = self.media_id orelse return;
        self.app.pauseMedia(id) catch |err| {
            self.status = @errorName(err);
            try ctx.invalidate(.{});
            return;
        };
        self.status = "Media paused without releasing its retained GPU resource";
        try ctx.invalidate(.{});
    }

    pub fn restart(self: *Model, ctx: *ui.input.Context) ui.Error!void {
        const id = self.media_id orelse return;
        self.app.seekMedia(id, 0) catch |err| {
            self.status = @errorName(err);
            try ctx.invalidate(.{});
            return;
        };
        try self.app.playMedia(id);
        self.status = "Media seeked to its first frame";
        try ctx.invalidate(.{});
    }

    pub fn build(self: *Model, ctx: *ui.Component.BuildContext) ui.Error!ui.NodeSpec {
        const capabilities = try self.app.rendererCapabilities();
        var capability_buffer: [256]u8 = undefined;
        const capability_text = std.fmt.bufPrint(&capability_buffer, "backend={s} · device generation {d} · external surfaces={s} · HDR={s} · custom GPU passes={s}", .{
            @tagName(ui.config.compiled_renderer),
            try self.app.deviceGeneration(),
            if (capabilities.external_surfaces) "yes" else "no",
            if (capabilities.hdr) "yes" else "no",
            if (capabilities.custom_materials) "yes" else "no",
        }) catch return error.BudgetExceeded;

        var cards: std.ArrayList(ui.NodeSpec) = .empty;
        if (self.texture.isValid()) {
            try cards.append(ctx.allocator, try imageCard(ctx, self.texture, .contain, "Contain: decoded QOI → retained GPU texture"));
            try cards.append(ctx.allocator, try imageCard(ctx, self.texture, .cover, "Cover: same handle, no duplicate upload"));
        }
        if (self.external_surface_id.isValid()) {
            try cards.append(ctx.allocator, try customCard(
                ctx,
                ui.custom.Node.from(ExternalSurfaceView, &self.external_view),
                "Application-owned Metal texture → retained external surface",
            ));
        }
        try cards.append(ctx.allocator, try customCard(
            ctx,
            ui.custom.Node.from(ExtensionView, &self.extension_view),
            "Portable custom GPU pass → active native renderer extension",
        ));
        if (comptime ui.config.media_enabled) {
            if (self.media_id) |id| {
                self.media_view.visual = try self.app.mediaVisual(id);
                self.media_view.fit = .contain;
                var media_spec = try self.media_view.build(ctx);
                media_spec.style = cardStyle();
                media_spec.style.layout.height = .{ .points = 240 };
                try cards.append(ctx.allocator, media_spec);
            }
        }

        const buttons = try ctx.allocator.alloc(ui.NodeSpec, 3);
        buttons[0] = try self.play_button.build(ctx);
        buttons[1] = try self.pause_button.build(ctx);
        buttons[2] = try self.restart_button.build(ctx);
        const children = try ctx.allocator.alloc(ui.NodeSpec, 6);
        children[0] = .{
            .kind = .{ .text = "GPU resources, textures, media, and native surfaces" },
            .style = .{ .text = .{ .font_size = 26, .font_weight = .bold, .color = ui.Color.white } },
            .semantics = .{ .role = .heading, .label = "GPU resources, textures, media, and native surfaces" },
        };
        children[1] = .{
            .kind = .{ .text = try ctx.allocator.dupe(u8, capability_text) },
            .style = .{ .text = .{ .font_size = 13, .color = ui.Color.rgba8(139, 163, 203, 255) } },
        };
        children[2] = .{
            .kind = .{ .text = "The images below are generated in memory and decoded by ZigUI. Enable -Dmedia=true to add the in-tree Y4M player. Application-owned Metal, D3D11, Vulkan, and DMA-BUF images use the explicit external-surface API." },
            .style = .{ .text = .{ .font_size = 14, .color = ui.Color.rgba8(185, 196, 217, 255) } },
        };
        children[3] = .{
            .kind = .container,
            .style = .{ .layout = .{ .direction = .row, .wrap = .wrap, .gap = .{ .width = 14, .height = 14 } } },
            .children = try cards.toOwnedSlice(ctx.allocator),
        };
        children[4] = .{
            .kind = .container,
            .style = .{ .layout = .{ .direction = .row, .gap = .{ .width = 9 } } },
            .children = buttons,
        };
        children[5] = .{
            .kind = .{ .text = self.status },
            .style = .{ .text = .{ .font_size = 13, .color = ui.Color.rgba8(115, 221, 176, 255) } },
            .semantics = .{ .role = .static_text, .label = self.status },
        };
        return .{
            .kind = .{ .scroll = .{ .vertical = true } },
            .style = .{
                .layout = .{
                    .width = .{ .percent = 1 },
                    .height = .{ .percent = 1 },
                    .padding = .{
                        .top = .{ .points = 30 },
                        .right = .{ .points = 30 },
                        .bottom = .{ .points = 40 },
                        .left = .{ .points = 30 },
                    },
                    .gap = .{ .height = 17 },
                    .overflow_y = .scroll,
                },
                .paint = .{ .background = .{ .solid = ui.Color.rgba8(12, 16, 24, 255) } },
            },
            .children = children,
        };
    }
};

fn imageCard(ctx: *ui.Component.BuildContext, texture: ui.core.handles.TextureId, fit: ui.node.Image.Fit, label: []const u8) ui.Error!ui.NodeSpec {
    const children = try ctx.allocator.alloc(ui.NodeSpec, 2);
    children[0] = .{
        .kind = .{ .image = .{ .texture = texture, .source_width = 48, .source_height = 48, .fit = fit } },
        .style = .{ .layout = .{ .width = .{ .percent = 1 }, .height = .{ .points = 185 } } },
        .semantics = .{ .role = .image, .label = label },
    };
    children[1] = .{
        .kind = .{ .text = label },
        .style = .{ .text = .{ .font_size = 12, .color = ui.Color.rgba8(200, 209, 227, 255) } },
    };
    return .{ .kind = .container, .style = cardStyle(), .children = children };
}

fn customCard(ctx: *ui.Component.BuildContext, custom_node: ui.custom.Node, label: []const u8) ui.Error!ui.NodeSpec {
    const children = try ctx.allocator.alloc(ui.NodeSpec, 2);
    children[0] = .{
        .kind = .{ .custom = custom_node },
        .style = .{ .layout = .{ .width = .{ .percent = 1 }, .height = .{ .points = 185 } } },
        .semantics = .{ .role = .image, .label = label },
    };
    children[1] = .{
        .kind = .{ .text = label },
        .style = .{ .text = .{ .font_size = 12, .color = ui.Color.rgba8(200, 209, 227, 255) } },
    };
    return .{ .kind = .container, .style = cardStyle(), .children = children };
}

fn cardStyle() ui.style.Style {
    return .{
        .layout = .{
            .width = .{ .points = 320 },
            .padding = .{
                .top = .{ .points = 12 },
                .right = .{ .points = 12 },
                .bottom = .{ .points = 12 },
                .left = .{ .points = 12 },
            },
            .gap = .{ .height = 10 },
        },
        .paint = .{
            .background = .{ .solid = ui.Color.rgba8(22, 28, 40, 255) },
            .border = .{ .widths = ui.Insets.all(1), .color = ui.Color.rgba8(55, 68, 91, 255) },
            .radii = ui.CornerRadii.all(11),
        },
    };
}

fn makeQoi(allocator: std.mem.Allocator, width: u32, height: u32) ui.Error![]u8 {
    const pixel_width: usize = @intCast(width);
    const pixel_height: usize = @intCast(height);
    const width_denominator = @max(@as(usize, 1), pixel_width -| 1);
    const height_denominator = @max(@as(usize, 1), pixel_height -| 1);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "qoif");
    var dimension: [4]u8 = undefined;
    std.mem.writeInt(u32, &dimension, width, .big);
    try output.appendSlice(allocator, &dimension);
    std.mem.writeInt(u32, &dimension, height, .big);
    try output.appendSlice(allocator, &dimension);
    try output.appendSlice(allocator, &.{ 4, 0 });
    for (0..pixel_height) |y| for (0..pixel_width) |x| {
        const checker = (x / 6 + y / 6) % 2 == 0;
        try output.appendSlice(allocator, &.{
            0xff,
            if (checker) 88 else 222,
            @intCast(70 + (x * 155) / width_denominator),
            @intCast(90 + (y * 145) / height_denominator),
            255,
        });
    };
    try output.appendSlice(allocator, &.{ 0, 0, 0, 0, 0, 0, 0, 1 });
    return output.toOwnedSlice(allocator);
}

fn makeY4m(allocator: std.mem.Allocator, width: u32, height: u32, frames: usize) ui.Error![]u8 {
    const pixel_width: usize = @intCast(width);
    const pixel_height: usize = @intCast(height);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.print(allocator, "YUV4MPEG2 W{d} H{d} F12:1 Ip Cmono XCOLORRANGE=FULL\n", .{ width, height });
    for (0..frames) |frame| {
        try output.appendSlice(allocator, "FRAME\n");
        for (0..pixel_height) |y| for (0..pixel_width) |x| {
            const wave = (x + y + frame * 7) % 64;
            try output.append(allocator, @intCast(35 + wave * 3));
        };
    }
    return output.toOwnedSlice(allocator);
}

pub fn main() !void {
    var general = std.heap.DebugAllocator(.{}){};
    defer _ = general.deinit();
    const allocator = general.allocator();
    const app = try ui.App.create(allocator, .{ .application_name = "ZigUI Surface Lab" });
    var model = try Model.init(allocator, app);
    model.repairPointers();
    defer {
        model.deinit();
        app.destroy() catch {};
    }
    _ = try app.openWindow(.{
        .platform = .{ .title = "Surface Lab", .size = .{ .width = 980, .height = 760 } },
        .clear_color = ui.Color.rgba8(12, 16, 24, 255),
    }, ui.Component.Descriptor.from(Model, &model));
    try app.run();
}
