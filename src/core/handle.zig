const std = @import("std");

pub fn Handle(comptime Tag: type) type {
    _ = Tag;
    return extern struct {
        index: u32,
        generation: u32,

        const Self = @This();
        pub const invalid: Self = .{
            .index = std.math.maxInt(u32),
            .generation = 0,
        };

        pub fn init(index: u32, generation: u32) Self {
            return .{ .index = index, .generation = generation };
        }

        pub fn isValid(self: Self) bool {
            return self.index != std.math.maxInt(u32) and self.generation != 0;
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.index == b.index and a.generation == b.generation;
        }

        pub fn encode(self: Self) u64 {
            return (@as(u64, self.generation) << 32) | self.index;
        }
    };
}

pub const AppId = Handle(struct {
    const name = "App";
});
pub const WindowId = Handle(struct {
    const name = "Window";
});
pub const ComponentId = Handle(struct {
    const name = "Component";
});
pub const NodeId = Handle(struct {
    const name = "Node";
});
pub const StateId = Handle(struct {
    const name = "State";
});
pub const TextureId = Handle(struct {
    const name = "Texture";
});
pub const AnimationId = Handle(struct {
    const name = "Animation";
});
pub const SvgId = Handle(struct {
    const name = "Svg";
});
pub const MediaId = Handle(struct {
    const name = "Media";
});
pub const NativeMediaId = Handle(struct {
    const name = "NativeMedia";
});
pub const RenderExtensionId = Handle(struct {
    const name = "RenderExtension";
});
pub const AtlasTileId = Handle(struct {
    const name = "AtlasTile";
});
pub const SurfaceId = Handle(struct {
    const name = "Surface";
});
pub const FontId = Handle(struct {
    const name = "Font";
});
pub const TextLayoutId = Handle(struct {
    const name = "TextLayout";
});
pub const SemanticId = Handle(struct {
    const name = "Semantic";
});
pub const TaskId = Handle(struct {
    const name = "Task";
});
pub const SubscriptionId = Handle(struct {
    const name = "Subscription";
});
pub const ActionId = Handle(struct {
    const name = "Action";
});

pub fn SlotPool(comptime T: type, comptime Id: type) type {
    return struct {
        const Self = @This();
        const none = std.math.maxInt(u32);

        const Slot = struct {
            generation: u32 = 1,
            next_free: u32 = none,
            occupied: bool = false,
            value: T = undefined,
        };

        allocator: std.mem.Allocator,
        slots: std.ArrayList(Slot) = .empty,
        free_head: u32 = none,
        live_count: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn insert(self: *Self, value: T) (std.mem.Allocator.Error || error{OutOfSlots})!Id {
            if (self.free_head != none) {
                const index = self.free_head;
                const slot = &self.slots.items[index];
                self.free_head = slot.next_free;
                slot.next_free = none;
                slot.occupied = true;
                slot.value = value;
                self.live_count += 1;
                return Id.init(index, slot.generation);
            }

            if (self.slots.items.len >= std.math.maxInt(u32)) return error.OutOfSlots;
            const index: u32 = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{
                .occupied = true,
                .value = value,
            });
            self.live_count += 1;
            return Id.init(index, 1);
        }

        pub fn contains(self: *const Self, id: Id) bool {
            if (!id.isValid() or id.index >= self.slots.items.len) return false;
            const slot = &self.slots.items[id.index];
            return slot.occupied and slot.generation == id.generation;
        }

        pub fn get(self: *Self, id: Id) ?*T {
            if (!self.contains(id)) return null;
            return &self.slots.items[id.index].value;
        }

        pub fn getConst(self: *const Self, id: Id) ?*const T {
            if (!self.contains(id)) return null;
            return &self.slots.items[id.index].value;
        }

        pub fn remove(self: *Self, id: Id) ?T {
            if (!self.contains(id)) return null;
            const slot = &self.slots.items[id.index];
            const value = slot.value;
            slot.value = undefined;
            slot.occupied = false;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.next_free = self.free_head;
            self.free_head = id.index;
            self.live_count -= 1;
            return value;
        }

        pub const Entry = struct {
            id: Id,
            value: *T,
        };

        pub const Iterator = struct {
            pool: *Self,
            index: usize = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.pool.slots.items.len) {
                    const index = self.index;
                    self.index += 1;
                    const slot = &self.pool.slots.items[index];
                    if (!slot.occupied) continue;
                    return .{
                        .id = Id.init(@intCast(index), slot.generation),
                        .value = &slot.value,
                    };
                }
                return null;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .pool = self };
        }
    };
}
