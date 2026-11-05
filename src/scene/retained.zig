const std = @import("std");
const handles = @import("../core/handle.zig");
const geometry = @import("../core/geometry.zig");
const memory = @import("../core/memory.zig");
const metrics = @import("../core/metrics.zig");
const TrackedAllocator = @import("../core/tracked_allocator.zig").TrackedAllocator;
const layout = @import("../layout/style.zig");
const scene = @import("scene.zig");

pub const GlyphUse = struct { tile: handles.AtlasTileId, color: bool };

pub const Key = struct {
    revision: u64,
    store_generation: u64,
    layout_result: layout.LayoutResult,
    scale: geometry.ScaleFactor,
    device_generation: u32,

    pub fn eql(a: Key, b: Key) bool {
        return std.meta.eql(a, b);
    }
};

pub const Entry = struct {
    key: Key,
    valid: bool = false,
    budget_blocked: bool = false,
    blocked_usage: usize = 0,
    stable_frames: u8 = 1,
    seen: u64,
    scene: scene.Scene,
    glyphs: std.ArrayList(GlyphUse) = .empty,

    fn deinit(self: *Entry) void {
        self.glyphs.deinit(self.scene.allocator);
        self.scene.deinit();
    }
};

/// A cache owns only self-contained built-in component scenes. Its allocator
/// bounds metadata, scene capacity, and glyph references together. Mutable
/// custom elements and portals are kept on the ordinary paint path.
pub const Cache = struct {
    backing: std.mem.Allocator,
    budget: memory.Budget,
    allocation_counts: metrics.Counters = .{},
    tracked: TrackedAllocator = undefined,
    bound: bool = false,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
    frame: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, maximum_bytes: usize) Cache {
        return .{ .backing = allocator, .budget = .{ .limit = maximum_bytes } };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| entry.deinit();
        if (self.bound) self.entries.deinit(self.tracked.allocator());
        std.debug.assert(self.budget.used == 0);
    }

    pub fn beginFrame(self: *Cache) void {
        if (!self.bound) {
            self.tracked = TrackedAllocator.init(self.backing, &self.allocation_counts, &self.budget);
            self.bound = true;
        }
        self.frame +%= 1;
        // Keep nested entries through a parent cache hit. They can be useful
        // again when the parent next changes; the aggregate budget stays fixed.
        var it = self.entries.iterator();
        while (it.next()) |item| {
            if (self.frame -% item.value_ptr.seen <= 120) continue;
            item.value_ptr.deinit();
            self.entries.removeByPtr(item.key_ptr);
        }
    }

    pub const Lookup = struct { entry: *Entry, admit: bool };

    pub fn lookup(self: *Cache, id: handles.NodeId, key: Key, counters: *metrics.Counters) ?Lookup {
        if (self.budget.limit == 0) return null;
        const result = self.entries.getOrPut(self.tracked.allocator(), id.encode()) catch {
            counters.retained_scene_budget_skips +|= 1;
            return null;
        };
        if (!result.found_existing) {
            result.value_ptr.* = .{
                .key = key,
                .seen = self.frame,
                .scene = scene.Scene.init(self.tracked.allocator()),
            };
            counters.retained_scene_misses +|= 1;
            return .{ .entry = result.value_ptr, .admit = false };
        }
        const entry = result.value_ptr;
        entry.seen = self.frame;
        if (!entry.key.eql(key)) {
            entry.key = key;
            entry.valid = false;
            entry.budget_blocked = false;
            entry.stable_frames = 1;
            counters.retained_scene_misses +|= 1;
            return .{ .entry = entry, .admit = false };
        }
        // A component that changes every other frame cannot reuse a cache
        // built on its second frame. Require one more stable observation.
        entry.stable_frames +|= 1;
        if (entry.budget_blocked and self.budget.used < entry.blocked_usage)
            entry.budget_blocked = false;
        return .{ .entry = entry, .admit = entry.stable_frames >= 3 and !entry.budget_blocked };
    }

    pub fn discard(self: *Cache, entry: *Entry) void {
        const allocator = entry.scene.allocator;
        entry.deinit();
        entry.scene = scene.Scene.init(allocator);
        entry.glyphs = .empty;
        entry.valid = false;
        entry.budget_blocked = true;
        // Retry only after another entry releases capacity. An oversized
        // scene should not allocate and fail again on every unchanged frame.
        entry.blocked_usage = self.budget.used;
    }
};
