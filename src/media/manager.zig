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
    texture_players: std.AutoHashMap(u64, handles.MediaId),
    surface_players: std.AutoHashMap(u64, handles.MediaId),
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
            .texture_players = std.AutoHashMap(u64, handles.MediaId).init(allocator),
            .surface_players = std.AutoHashMap(u64, handles.MediaId).init(allocator),
            .maximum_players = maximum_players,
        };
    }

    pub fn deinit(self: *Manager) void {
        var iterator = self.players.iterator();
        while (iterator.next()) |entry| entry.value.player.deinit();
        self.players.deinit();
        self.texture_players.deinit();
        self.surface_players.deinit();
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
        self.texture_players.ensureUnusedCapacity(1) catch |err| {
            source.deinit();
            return err;
        };
        self.surface_players.ensureUnusedCapacity(1) catch |err| {
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
        const entry = self.players.get(id).?;
        _ = try entry.player.tick(now_ns);
        self.syncVisual(id, null, entry.player.visual);
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
        self.removeVisual(id, removed.player.visual);
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
        const previous = entry.player.visual;
        try entry.player.seek(media_ns, now_ns);
        _ = try entry.player.tick(now_ns);
        self.syncVisual(id, previous, entry.player.visual);
    }

    pub fn tick(self: *Manager, id: handles.MediaId, now_ns: u64) Error!bool {
        const entry = self.players.get(id) orelse return error.InvalidHandle;
        const previous = entry.player.visual;
        const changed = try entry.player.tick(now_ns);
        self.syncVisual(id, previous, entry.player.visual);
        return changed;
    }

    pub fn tickTexture(self: *Manager, id: handles.TextureId, now_ns: u64) Error!bool {
        const media_id = self.texture_players.get(id.encode()) orelse return false;
        return self.tick(media_id, now_ns);
    }

    pub fn tickSurface(self: *Manager, id: handles.SurfaceId, now_ns: u64) Error!bool {
        const media_id = self.surface_players.get(id.encode()) orelse return false;
        return self.tick(media_id, now_ns);
    }

    pub fn isPlayingTexture(self: *Manager, id: handles.TextureId) bool {
        const media_id = self.texture_players.get(id.encode()) orelse return false;
        const entry = self.players.get(media_id) orelse return false;
        return entry.player.state == .playing;
    }

    pub fn isPlayingSurface(self: *Manager, id: handles.SurfaceId) bool {
        const media_id = self.surface_players.get(id.encode()) orelse return false;
        const entry = self.players.get(media_id) orelse return false;
        return entry.player.state == .playing;
    }

    pub fn deviceLost(self: *Manager, now_ns: u64) Error!void {
        var iterator = self.players.iterator();
        while (iterator.next()) |entry| {
            const previous = entry.value.player.visual;
            entry.value.player.deviceLost(now_ns) catch |err| {
                self.syncVisual(entry.id, previous, entry.value.player.visual);
                return err;
            };
            self.syncVisual(entry.id, previous, entry.value.player.visual);
        }
    }

    fn syncVisual(self: *Manager, id: handles.MediaId, previous: ?api.Visual, next: ?api.Visual) void {
        self.removeVisual(id, previous);
        if (next) |next_visual| switch (next_visual) {
            .texture => |value| self.texture_players.putAssumeCapacity(value.id.encode(), id),
            .surface => |value| self.surface_players.putAssumeCapacity(value.id.encode(), id),
        };
    }

    fn removeVisual(self: *Manager, id: handles.MediaId, previous_visual: ?api.Visual) void {
        const value = previous_visual orelse return;
        switch (value) {
            .texture => |texture| if (self.texture_players.get(texture.id.encode())) |owner| {
                if (owner.eql(id)) _ = self.texture_players.remove(texture.id.encode());
            },
            .surface => |surface| if (self.surface_players.get(surface.id.encode())) |owner| {
                if (owner.eql(id)) _ = self.surface_players.remove(surface.id.encode());
            },
        }
    }
};
