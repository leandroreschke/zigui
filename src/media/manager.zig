const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const render = @import("../render/api.zig");
const resource = @import("../render/resource.zig");
const surface_resource = @import("../render/surface_resource.zig");
const api = @import("api.zig");
const player_mod = @import("player.zig");

const Entry = struct {
    player: player_mod.Player,
    references: usize = 1,
};

pub const Manager = struct {
    const Pool = handles.SlotPool(Entry, handles.MediaId);

    allocator: std.mem.Allocator,
    renderer: render.Renderer,
    resources: *resource.Manager,
    surfaces: *surface_resource.Manager,
    players: Pool,
    maximum_players: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        renderer: render.Renderer,
        resources: *resource.Manager,
        surfaces: *surface_resource.Manager,
    ) Manager {
        return initWithLimit(allocator, renderer, resources, surfaces, 4_096);
    }

    pub fn initWithLimit(
        allocator: std.mem.Allocator,
        renderer: render.Renderer,
        resources: *resource.Manager,
        surfaces: *surface_resource.Manager,
        maximum_players: usize,
    ) Manager {
        return .{
            .allocator = allocator,
            .renderer = renderer,
            .resources = resources,
            .surfaces = surfaces,
            .players = Pool.init(allocator),
            .maximum_players = maximum_players,
        };
    }

    pub fn deinit(self: *Manager) void {
        var iterator = self.players.iterator();
        while (iterator.next()) |entry| entry.value.player.deinit();
        self.players.deinit();
        self.* = undefined;
    }

    pub fn create(self: *Manager, source: api.Source, now_ns: u64) Error!handles.MediaId {
        if (self.players.live_count >= self.maximum_players) {
            source.deinit();
            return error.BudgetExceeded;
        }
        _ = source.info() catch |err| {
            source.deinit();
            return err;
        };
        var player = player_mod.Player.init(source, self.renderer, self.resources, self.surfaces, now_ns);
        const id = self.players.insert(.{ .player = player }) catch |err| {
            player.deinit();
            return err;
        };
        errdefer {
            var removed = self.players.remove(id).?;
            removed.player.deinit();
        }
        _ = try self.players.get(id).?.player.tick(now_ns);
        return id;
    }

    pub fn retain(self: *Manager, id: handles.MediaId) Error!void {
        const entry = self.players.get(id) orelse return error.InvalidHandle;
        if (entry.references == std.math.maxInt(usize)) return error.BudgetExceeded;
        entry.references += 1;
    }

    pub fn release(self: *Manager, id: handles.MediaId) Error!void {
        const entry = self.players.get(id) orelse return error.InvalidHandle;
        if (entry.references > 1) {
            entry.references -= 1;
            return;
        }
        var removed = self.players.remove(id) orelse return error.InvalidHandle;
        removed.player.deinit();
    }

    pub fn visual(self: *const Manager, id: handles.MediaId) ?api.Visual {
        const entry = self.players.getConst(id) orelse return null;
        return entry.player.visual;
    }

    pub fn state(self: *const Manager, id: handles.MediaId) ?api.State {
        const entry = self.players.getConst(id) orelse return null;
        return entry.player.state;
    }

    pub fn play(self: *Manager, id: handles.MediaId, now_ns: u64) Error!void {
        const entry = self.players.get(id) orelse return error.InvalidHandle;
        entry.player.play(now_ns);
    }

    pub fn pause(self: *Manager, id: handles.MediaId, now_ns: u64) Error!void {
        const entry = self.players.get(id) orelse return error.InvalidHandle;
        entry.player.pause(now_ns);
    }

    pub fn seek(self: *Manager, id: handles.MediaId, media_ns: u64, now_ns: u64) Error!void {
        const entry = self.players.get(id) orelse return error.InvalidHandle;
        try entry.player.seek(media_ns, now_ns);
        _ = try entry.player.tick(now_ns);
    }

    pub fn tick(self: *Manager, id: handles.MediaId, now_ns: u64) Error!bool {
        const entry = self.players.get(id) orelse return error.InvalidHandle;
        return entry.player.tick(now_ns);
    }

    pub fn tickTexture(self: *Manager, id: handles.TextureId, now_ns: u64) Error!bool {
        var iterator = self.players.iterator();
        while (iterator.next()) |entry| if (entry.value.player.visual) |visual_value| switch (visual_value) {
            .texture => |value| if (value.id.eql(id)) return entry.value.player.tick(now_ns),
            else => {},
        };
        return false;
    }

    pub fn tickSurface(self: *Manager, id: handles.SurfaceId, now_ns: u64) Error!bool {
        var iterator = self.players.iterator();
        while (iterator.next()) |entry| if (entry.value.player.visual) |visual_value| switch (visual_value) {
            .surface => |value| if (value.id.eql(id)) return entry.value.player.tick(now_ns),
            else => {},
        };
        return false;
    }

    pub fn isPlayingTexture(self: *Manager, id: handles.TextureId) bool {
        var iterator = self.players.iterator();
        while (iterator.next()) |entry| if (entry.value.player.visual) |visual_value| switch (visual_value) {
            .texture => |value| if (value.id.eql(id)) return entry.value.player.state == .playing,
            else => {},
        };
        return false;
    }

    pub fn isPlayingSurface(self: *Manager, id: handles.SurfaceId) bool {
        var iterator = self.players.iterator();
        while (iterator.next()) |entry| if (entry.value.player.visual) |visual_value| switch (visual_value) {
            .surface => |value| if (value.id.eql(id)) return entry.value.player.state == .playing,
            else => {},
        };
        return false;
    }

    pub fn deviceLost(self: *Manager, now_ns: u64) Error!void {
        var iterator = self.players.iterator();
        while (iterator.next()) |entry| try entry.value.player.deviceLost(now_ns);
    }
};
