const std = @import("std");
const Error = @import("../core/error.zig").Error;
const handles = @import("../core/handle.zig");
const event = @import("event.zig");

pub const Context = u64;
pub const global_context: Context = 0;

pub fn context(comptime name: []const u8) Context {
    return comptime std.hash.Wyhash.hash(0x7a696775695f6374, name);
}

pub const Chord = struct {
    key: event.Key,
    modifiers: event.Modifiers = .{},

    pub fn matches(self: Chord, value: event.KeyEvent) bool {
        return std.meta.eql(self.key, value.key) and normalizedModifiers(self.modifiers) == normalizedModifiers(value.modifiers);
    }
};

pub const ActionEvent = struct {
    id: handles.ActionId,
    source: Source,
    key_event: ?event.KeyEvent = null,
    /// Opaque application-owned value supplied by a native menu item. It is
    /// zero for keyboard, accessibility, and ordinary application-menu
    /// dispatch unless the menu definition explicitly supplies a payload.
    menu_payload: u64 = 0,

    pub const Source = enum { keyboard, menu, accessibility, programmatic };
};

pub const Dispatch = struct {
    window: handles.WindowId,
    target: handles.NodeId,
    current: handles.NodeId,
    handled: bool = false,
    propagation_stopped: bool = false,

    pub fn stopPropagation(self: *Dispatch) void {
        self.propagation_stopped = true;
    }
};

pub const Handler = struct {
    action: handles.ActionId,
    context: Context = global_context,
    callback_context: *anyopaque,
    callback: *const fn (*anyopaque, *Dispatch, ActionEvent, *event.Context) Error!void,
};

const Definition = struct {
    name: []u8,
};

const Binding = struct {
    chord: Chord,
    action: handles.ActionId,
    context: Context,
    priority: i16,
    insertion: u64,
};

pub const Registry = struct {
    const Pool = handles.SlotPool(Definition, handles.ActionId);

    allocator: std.mem.Allocator,
    definitions: Pool,
    names: std.StringHashMap(handles.ActionId),
    bindings: std.ArrayList(Binding) = .empty,
    insertion: u64 = 0,
    maximum_actions: usize,
    maximum_bindings: usize,
    maximum_name_bytes: usize,
    name_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return initWithLimits(allocator, 65_536, 262_144);
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, maximum_actions: usize, maximum_bindings: usize) Registry {
        return initWithBudgets(allocator, maximum_actions, maximum_bindings, 8 * 1024 * 1024);
    }

    pub fn initWithBudgets(
        allocator: std.mem.Allocator,
        maximum_actions: usize,
        maximum_bindings: usize,
        maximum_name_bytes: usize,
    ) Registry {
        return .{
            .allocator = allocator,
            .definitions = Pool.init(allocator),
            .names = std.StringHashMap(handles.ActionId).init(allocator),
            .maximum_actions = maximum_actions,
            .maximum_bindings = maximum_bindings,
            .maximum_name_bytes = maximum_name_bytes,
        };
    }

    pub fn deinit(self: *Registry) void {
        var iterator = self.definitions.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.value.name);
        self.definitions.deinit();
        self.names.deinit();
        self.bindings.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, action_name: []const u8) Error!handles.ActionId {
        if (action_name.len == 0 or action_name.len > self.maximum_name_bytes or
            !std.unicode.utf8ValidateSlice(action_name) or std.mem.indexOfScalar(u8, action_name, 0) != null)
            return error.InvalidConfiguration;
        if (self.names.get(action_name)) |existing| return existing;
        if (self.definitions.live_count >= self.maximum_actions) return error.BudgetExceeded;
        if (action_name.len > self.maximum_name_bytes -| self.name_bytes) return error.BudgetExceeded;
        const owned = try self.allocator.dupe(u8, action_name);
        errdefer self.allocator.free(owned);
        const id = try self.definitions.insert(.{ .name = owned });
        errdefer _ = self.definitions.remove(id);
        try self.names.put(owned, id);
        self.name_bytes += owned.len;
        return id;
    }

    pub fn registeredNameBytes(self: *const Registry) usize {
        return self.name_bytes;
    }

    pub fn find(self: *const Registry, action_name: []const u8) ?handles.ActionId {
        return self.names.get(action_name);
    }

    pub fn name(self: *const Registry, id: handles.ActionId) ?[]const u8 {
        const definition = self.definitions.getConst(id) orelse return null;
        return definition.name;
    }

    pub fn contains(self: *const Registry, id: handles.ActionId) bool {
        return self.definitions.contains(id);
    }

    pub fn bind(self: *Registry, chord: Chord, action_id: handles.ActionId, binding_context: Context, priority: i16) Error!void {
        if (!self.definitions.contains(action_id)) return error.InvalidHandle;
        if (self.bindings.items.len >= self.maximum_bindings) return error.BudgetExceeded;
        const next_insertion = std.math.add(u64, self.insertion, 1) catch return error.BudgetExceeded;
        try self.bindings.append(self.allocator, .{
            .chord = chord,
            .action = action_id,
            .context = binding_context,
            .priority = priority,
            .insertion = next_insertion,
        });
        self.insertion = next_insertion;
    }

    pub fn resolve(self: *const Registry, key_event: event.KeyEvent, active_contexts: []const Context) ?handles.ActionId {
        var best: ?Binding = null;
        var best_specificity: usize = 0;
        for (self.bindings.items) |binding| {
            if (!binding.chord.matches(key_event)) continue;
            const specificity = contextSpecificity(binding.context, active_contexts) orelse continue;
            if (best == null or specificity > best_specificity or
                (specificity == best_specificity and binding.priority > best.?.priority) or
                (specificity == best_specificity and binding.priority == best.?.priority and binding.insertion > best.?.insertion))
            {
                best = binding;
                best_specificity = specificity;
            }
        }
        return if (best) |value| value.action else null;
    }
};

fn normalizedModifiers(value: event.Modifiers) u8 {
    var result: u8 = 0;
    if (value.shift) result |= 1 << 0;
    if (value.control) result |= 1 << 1;
    if (value.alt) result |= 1 << 2;
    if (value.command) result |= 1 << 3;
    if (value.function) result |= 1 << 4;
    return result;
}

pub fn contextSpecificity(binding_context: Context, active: []const Context) ?usize {
    if (binding_context == global_context) return 0;
    var index = active.len;
    while (index != 0) {
        index -= 1;
        if (active[index] == binding_context) return index + 1;
    }
    return null;
}
