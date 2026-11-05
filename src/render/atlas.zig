const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const api = @import("api.zig");
const resource = @import("resource.zig");

pub const RectU16 = extern struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const Tile = struct {
    page: u32,
    rect: RectU16,
    device_generation: api.DeviceGeneration,
    last_submission: api.SubmissionEpoch = 0,
    last_used_frame: u64 = 0,
    pinned: bool = false,
};

const RetiredTile = struct {
    tile: Tile,
    release_after: api.SubmissionEpoch,
};

const Page = struct {
    texture: handles.TextureId,
    free_rects: std.ArrayList(RectU16) = .empty,

    fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        self.free_rects.deinit(allocator);
    }
};

pub const Atlas = struct {
    const Pool = handles.SlotPool(Tile, handles.AtlasTileId);

    allocator: std.mem.Allocator,
    resources: *resource.Manager,
    tiles: Pool,
    retired: std.ArrayList(RetiredTile) = .empty,
    pages: std.ArrayList(Page) = .empty,
    page_size: u16,
    maximum_pages: u16,
    format: api.PixelFormat,
    device_generation: api.DeviceGeneration,
    maximum_tiles: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        resources: *resource.Manager,
        page_size: u16,
        maximum_pages: u16,
        format: api.PixelFormat,
    ) Error!Atlas {
        return initWithLimit(allocator, resources, page_size, maximum_pages, format, 1_048_576);
    }

    pub fn initWithLimit(
        allocator: std.mem.Allocator,
        resources: *resource.Manager,
        page_size: u16,
        maximum_pages: u16,
        format: api.PixelFormat,
        maximum_tiles: usize,
    ) Error!Atlas {
        if (page_size == 0 or maximum_pages == 0 or maximum_tiles == 0) return error.InvalidConfiguration;
        return .{
            .allocator = allocator,
            .resources = resources,
            .tiles = Pool.init(allocator),
            .page_size = page_size,
            .maximum_pages = maximum_pages,
            .format = format,
            .device_generation = resources.device_generation,
            .maximum_tiles = maximum_tiles,
        };
    }

    pub fn deinit(self: *Atlas) void {
        for (self.pages.items) |*page| {
            self.resources.destroyTexture(page.texture) catch {};
            page.deinit(self.allocator);
        }
        self.pages.deinit(self.allocator);
        self.tiles.deinit();
        self.retired.deinit(self.allocator);
        self.* = undefined;
    }

    pub const EvictionSink = struct {
        context: *anyopaque,
        evicted: *const fn (*anyopaque, handles.AtlasTileId) void,
    };

    pub fn allocate(self: *Atlas, width: u16, height: u16, frame: u64, completed: api.SubmissionEpoch) Error!handles.AtlasTileId {
        return self.allocateNotifying(width, height, frame, completed, null);
    }

    pub fn allocateNotifying(
        self: *Atlas,
        width: u16,
        height: u16,
        frame: u64,
        completed: api.SubmissionEpoch,
        eviction_sink: ?EvictionSink,
    ) Error!handles.AtlasTileId {
        if (width == 0 or height == 0 or width > self.page_size or height > self.page_size) return error.InvalidConfiguration;
        self.collect(completed);
        if (self.tiles.live_count +| self.retired.items.len < self.maximum_tiles) {
            if (try self.findSpace(width, height, frame)) |id| return id;
            if (self.pages.items.len < self.maximum_pages) {
                try self.addPage();
                if (try self.findSpace(width, height, frame)) |id| return id;
            }
        }
        if (try self.evictOne(completed, frame, eviction_sink)) {
            if (try self.findSpace(width, height, frame)) |id| return id;
        }
        if (self.tiles.live_count +| self.retired.items.len >= self.maximum_tiles) return error.BudgetExceeded;
        return error.AtlasFull;
    }

    pub fn get(self: *Atlas, id: handles.AtlasTileId) ?*Tile {
        const tile = self.tiles.get(id) orelse return null;
        if (tile.device_generation != self.device_generation) return null;
        return tile;
    }

    pub fn pageTexture(self: *const Atlas, page: u32) ?handles.TextureId {
        if (page >= self.pages.items.len) return null;
        return self.pages.items[page].texture;
    }

    pub fn markUsed(self: *Atlas, id: handles.AtlasTileId, frame: u64, submission: api.SubmissionEpoch) Error!void {
        const tile = self.get(id) orelse return error.InvalidHandle;
        tile.last_used_frame = frame;
        tile.last_submission = @max(tile.last_submission, submission);
        try self.resources.markUsed(self.pages.items[tile.page].texture, submission);
    }

    /// Protects a tile selected while constructing the current scene from
    /// eviction by later allocations in that same scene.
    pub fn touch(self: *Atlas, id: handles.AtlasTileId, frame: u64) Error!void {
        const tile = self.get(id) orelse return error.InvalidHandle;
        tile.last_used_frame = frame;
    }

    pub fn setPinned(self: *Atlas, id: handles.AtlasTileId, pinned: bool) Error!void {
        const tile = self.get(id) orelse return error.InvalidHandle;
        tile.pinned = pinned;
    }

    pub fn release(self: *Atlas, id: handles.AtlasTileId) Error!void {
        try self.retired.ensureUnusedCapacity(self.allocator, 1);
        const tile = self.tiles.remove(id) orelse return error.InvalidHandle;
        self.retired.appendAssumeCapacity(.{ .tile = tile, .release_after = tile.last_submission });
    }

    pub fn collect(self: *Atlas, completed: api.SubmissionEpoch) void {
        var write: usize = 0;
        for (self.retired.items) |entry| {
            if (entry.release_after <= completed and entry.tile.device_generation == self.device_generation) {
                self.returnRect(entry.tile.page, entry.tile.rect) catch {
                    self.retired.items[write] = entry;
                    write += 1;
                };
            } else if (entry.release_after > completed) {
                self.retired.items[write] = entry;
                write += 1;
            }
        }
        self.retired.items.len = write;
    }

    pub fn deviceLost(self: *Atlas) Error!void {
        self.device_generation = self.resources.device_generation;
        self.tiles = blk: {
            self.tiles.deinit();
            break :blk Pool.init(self.allocator);
        };
        self.retired.clearRetainingCapacity();
        for (self.pages.items) |*page| {
            page.free_rects.clearRetainingCapacity();
            try page.free_rects.append(self.allocator, .{ .x = 0, .y = 0, .width = self.page_size, .height = self.page_size });
        }
    }

    fn addPage(self: *Atlas) Error!void {
        const texture = try self.resources.createTexture(.{
            .width = self.page_size,
            .height = self.page_size,
            .format = self.format,
            .usage = .atlas,
        }, null, false);
        errdefer self.resources.destroyTexture(texture) catch {};
        var page: Page = .{ .texture = texture };
        errdefer page.deinit(self.allocator);
        try page.free_rects.append(self.allocator, .{ .x = 0, .y = 0, .width = self.page_size, .height = self.page_size });
        try self.pages.append(self.allocator, page);
    }

    fn findSpace(self: *Atlas, width: u16, height: u16, frame: u64) Error!?handles.AtlasTileId {
        var best_page: ?usize = null;
        var best_rect: ?usize = null;
        var best_waste: u64 = std.math.maxInt(u64);
        for (self.pages.items, 0..) |page, page_index| {
            for (page.free_rects.items, 0..) |free, rect_index| {
                if (width > free.width or height > free.height) continue;
                const waste = @as(u64, free.width) * free.height - @as(u64, width) * height;
                if (waste < best_waste) {
                    best_waste = waste;
                    best_page = page_index;
                    best_rect = rect_index;
                }
            }
        }
        const page_index = best_page orelse return null;
        const rect_index = best_rect.?;
        const page = &self.pages.items[page_index];
        try page.free_rects.ensureUnusedCapacity(self.allocator, 2);
        const allocated: RectU16 = .{
            .x = page.free_rects.items[rect_index].x,
            .y = page.free_rects.items[rect_index].y,
            .width = width,
            .height = height,
        };
        const id = try self.tiles.insert(.{
            .page = @intCast(page_index),
            .rect = allocated,
            .device_generation = self.device_generation,
            .last_used_frame = frame,
        });
        const free = page.free_rects.swapRemove(rect_index);
        if (free.width > width) page.free_rects.appendAssumeCapacity(.{
            .x = free.x + width,
            .y = free.y,
            .width = free.width - width,
            .height = height,
        });
        if (free.height > height) page.free_rects.appendAssumeCapacity(.{
            .x = free.x,
            .y = free.y + height,
            .width = free.width,
            .height = free.height - height,
        });
        return id;
    }

    fn evictOne(self: *Atlas, completed: api.SubmissionEpoch, frame: u64, sink: ?EvictionSink) Error!bool {
        var candidate: ?handles.AtlasTileId = null;
        var oldest: u64 = std.math.maxInt(u64);
        var iterator = self.tiles.iterator();
        while (iterator.next()) |entry| {
            if (entry.value.pinned or entry.value.last_submission > completed or entry.value.last_used_frame >= frame) continue;
            if (entry.value.last_used_frame < oldest) {
                oldest = entry.value.last_used_frame;
                candidate = entry.id;
            }
        }
        const id = candidate orelse return false;
        const candidate_tile = self.tiles.get(id) orelse return false;
        if (candidate_tile.page >= self.pages.items.len) return error.InvalidHandle;
        try self.pages.items[candidate_tile.page].free_rects.ensureUnusedCapacity(self.allocator, 1);
        const tile = self.tiles.remove(id).?;
        if (sink) |listener| listener.evicted(listener.context, id);
        try self.returnRect(tile.page, tile.rect);
        self.resources.recordAtlasEviction();
        return true;
    }

    fn returnRect(self: *Atlas, page_index: u32, rect: RectU16) Error!void {
        if (page_index >= self.pages.items.len) return error.InvalidHandle;
        const page = &self.pages.items[page_index];
        try page.free_rects.append(self.allocator, rect);
        coalesce(&page.free_rects);
    }
};

fn coalesce(rectangles: *std.ArrayList(RectU16)) void {
    var changed = true;
    while (changed) {
        changed = false;
        var left_index: usize = 0;
        while (left_index < rectangles.items.len) : (left_index += 1) {
            var right_index = left_index + 1;
            while (right_index < rectangles.items.len) {
                const merged = merge(rectangles.items[left_index], rectangles.items[right_index]) orelse {
                    right_index += 1;
                    continue;
                };
                rectangles.items[left_index] = merged;
                _ = rectangles.swapRemove(right_index);
                changed = true;
            }
        }
    }
}

fn merge(a: RectU16, b: RectU16) ?RectU16 {
    if (a.width == 0 or b.width == 0) return null;
    if (a.y == b.y and a.height == b.height) {
        if (a.x + a.width == b.x) return .{ .x = a.x, .y = a.y, .width = a.width + b.width, .height = a.height };
        if (b.x + b.width == a.x) return .{ .x = b.x, .y = a.y, .width = a.width + b.width, .height = a.height };
    }
    if (a.x == b.x and a.width == b.width) {
        if (a.y + a.height == b.y) return .{ .x = a.x, .y = a.y, .width = a.width, .height = a.height + b.height };
        if (b.y + b.height == a.y) return .{ .x = a.x, .y = b.y, .width = a.width, .height = a.height + b.height };
    }
    return null;
}
