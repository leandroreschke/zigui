//! Native AT-SPI2 adapter. ZigUI owns the semantic snapshot and speaks both
//! D-Bus and the AT-SPI object protocols directly; no GLib, libdbus, ATK, or
//! at-spi client library is linked into applications.

const std = @import("std");
const config = @import("../../config.zig");
const Error = @import("../../core/error.zig").Error;
const geometry = @import("../../core/geometry.zig");
const handles = @import("../../core/handle.zig");
const api = @import("../../a11y/api.zig");
const sys = @import("sys.zig");
const dbus = @import("dbus/client.zig");
const wire = dbus.wire;

const root_path = "/org/a11y/atspi/accessible/root";
const cache_path = "/org/a11y/atspi/cache";
const null_path = "/org/a11y/atspi/null";
const registry_destination = "org.a11y.atspi.Registry";
const registry_path = "/org/a11y/atspi/accessible/root";

const accessible_interface = "org.a11y.atspi.Accessible";
const action_interface = "org.a11y.atspi.Action";
const application_interface = "org.a11y.atspi.Application";
const cache_interface = "org.a11y.atspi.Cache";
const component_interface = "org.a11y.atspi.Component";
const text_interface = "org.a11y.atspi.Text";
const value_interface = "org.a11y.atspi.Value";
const object_event_interface = "org.a11y.atspi.Event.Object";
const window_event_interface = "org.a11y.atspi.Event.Window";
const properties_interface = "org.freedesktop.DBus.Properties";
const introspect_interface = "org.freedesktop.DBus.Introspectable";
const peer_interface = "org.freedesktop.DBus.Peer";

fn readMachineId(allocator: std.mem.Allocator) Error![32]u8 {
    for ([_][]const u8{ "/etc/machine-id", "/var/lib/dbus/machine-id" }) |path| {
        const bytes = sys.readFileAlloc(allocator, path, 4096) catch continue;
        defer allocator.free(bytes);
        var result: [32]u8 = undefined;
        var count: usize = 0;
        for (bytes) |byte| {
            if (std.ascii.isWhitespace(byte)) continue;
            if (!std.ascii.isHex(byte) or count == result.len) {
                count = 0;
                break;
            }
            result[count] = std.ascii.toLower(byte);
            count += 1;
        }
        if (count == result.len) return result;
    }
    return error.MissingCapability;
}

pub const ActionSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, api.ActionRequest) void,

    fn emit(self: ActionSink, request: api.ActionRequest) void {
        self.emit_fn(self.context, request);
    }
};

pub const Host = struct {
    context: *anyopaque,
    screen_rect_fn: *const fn (*anyopaque, handles.WindowId, geometry.Rect) geometry.Rect,
    detach_fn: *const fn (*anyopaque, *Adapter) void,

    fn screenRect(self: Host, window: handles.WindowId, rect: geometry.Rect) geometry.Rect {
        return self.screen_rect_fn(self.context, window, rect);
    }

    fn detach(self: Host, adapter: *Adapter) void {
        self.detach_fn(self.context, adapter);
    }
};

const OwnedNode = struct {
    id: handles.SemanticId,
    parent: handles.SemanticId,
    role: api.Role,
    label: []u8,
    description: []u8,
    value: []u8,
    bounds: geometry.Rect,
    children: []handles.SemanticId,
    actions: []api.Action,
    selection: ?api.Selection,
    range_min: ?f64,
    range_max: ?f64,
    range_value: ?f64,
    disabled: bool,
    hidden: bool,
    focused: bool,
    selected: bool,
    checked: ?bool,
    expanded: ?bool,
    multiline: bool,
    password: bool,

    fn init(allocator: std.mem.Allocator, source: api.Node) Error!OwnedNode {
        if (!source.id.isValid()) return error.InvalidLayout;
        if (!std.unicode.utf8ValidateSlice(source.label) or !std.unicode.utf8ValidateSlice(source.description) or
            !std.unicode.utf8ValidateSlice(source.value))
            return error.InvalidUtf8;
        const label = try allocator.dupe(u8, source.label);
        errdefer allocator.free(label);
        const description = try allocator.dupe(u8, source.description);
        errdefer allocator.free(description);
        const value = try duplicateAccessibleValue(allocator, source.value, source.password);
        errdefer allocator.free(value);
        const children = try allocator.dupe(handles.SemanticId, source.children);
        errdefer allocator.free(children);
        const actions = try allocator.dupe(api.Action, source.actions);
        return .{
            .id = source.id,
            .parent = source.parent,
            .role = source.role,
            .label = label,
            .description = description,
            .value = value,
            .bounds = source.bounds,
            .children = children,
            .actions = actions,
            .selection = if (source.password) null else source.selection,
            .range_min = source.range_min,
            .range_max = source.range_max,
            .range_value = source.range_value,
            .disabled = source.disabled,
            .hidden = source.hidden,
            .focused = source.focused,
            .selected = source.selected,
            .checked = source.checked,
            .expanded = source.expanded,
            .multiline = source.multiline,
            .password = source.password,
        };
    }

    fn deinit(self: *OwnedNode, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.description);
        allocator.free(self.value);
        allocator.free(self.children);
        allocator.free(self.actions);
        self.* = undefined;
    }
};

const WindowState = struct {
    allocator: std.mem.Allocator,
    window: handles.WindowId,
    root: handles.SemanticId,
    generation: u64,
    nodes: std.AutoHashMap(u64, OwnedNode),

    fn init(allocator: std.mem.Allocator, tree: *const api.Tree, maximum_nodes: usize, maximum_bytes: usize) Error!WindowState {
        if (!tree.window.isValid() or !tree.root.isValid() or tree.generation == 0 or
            tree.nodes.len == 0)
            return error.InvalidLayout;
        if (tree.nodes.len > maximum_nodes or tree.nodes.len > std.math.maxInt(u32))
            return error.BudgetExceeded;
        var self: WindowState = .{
            .allocator = allocator,
            .window = tree.window,
            .root = tree.root,
            .generation = tree.generation,
            .nodes = std.AutoHashMap(u64, OwnedNode).init(allocator),
        };
        errdefer self.deinit();
        var accounted = std.math.mul(usize, tree.nodes.len, @sizeOf(api.Node)) catch
            return error.BudgetExceeded;
        try self.nodes.ensureTotalCapacity(@intCast(tree.nodes.len));
        for (tree.nodes) |source| {
            try api.validateNode(source);
            accounted = std.math.add(usize, accounted, try api.nodePayloadBytes(source)) catch
                return error.BudgetExceeded;
            if (accounted > maximum_bytes) return error.BudgetExceeded;
            if (self.nodes.contains(source.id.encode())) return error.InvalidLayout;
            var owned = try OwnedNode.init(allocator, source);
            self.nodes.putNoClobber(source.id.encode(), owned) catch |err| {
                owned.deinit(allocator);
                return err;
            };
        }
        return self;
    }

    fn deinit(self: *WindowState) void {
        var iterator = self.nodes.valueIterator();
        while (iterator.next()) |node| node.deinit(self.allocator);
        self.nodes.deinit();
        self.* = undefined;
    }
};

const NodeQuery = struct {
    window: *WindowState,
    value: *OwnedNode,
};

const Object = union(enum) {
    application,
    cache,
    node: NodeQuery,
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    sink: ActionSink,
    host: Host,
    app_config: config.AppConfig,
    bus: dbus.Client,
    windows: std.AutoHashMap(u64, WindowState),
    app_id: i32 = 0,
    machine_id: [32]u8,
    registry_name: []u8,
    registry_object: []u8,
    updating: bool = false,
    failure: ?Error = null,

    pub fn create(allocator: std.mem.Allocator, app_config: config.AppConfig, sink: ActionSink, host: Host) Error!api.Adapter {
        var session = try dbus.Client.connectSession(allocator);
        defer session.deinit();
        var empty = wire.Writer.init(allocator);
        defer empty.deinit();
        var address_reply = try session.call(
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.a11y.Bus",
            "GetAddress",
            "",
            empty.bytes.items,
        );
        defer address_reply.deinit();
        var address_reader = address_reply.bodyReader();
        const address = try allocator.dupe(u8, try address_reader.string());
        defer allocator.free(address);

        var bus = try dbus.Client.connectAddress(allocator, address, true);
        var bus_owned = true;
        errdefer if (bus_owned) bus.deinit();
        const self = try allocator.create(Adapter);
        var self_initialized = false;
        errdefer if (!self_initialized) allocator.destroy(self);
        const initial_registry_name = try allocator.dupe(u8, "");
        var registry_name_owned = true;
        errdefer if (registry_name_owned) allocator.free(initial_registry_name);
        const initial_registry_object = try allocator.dupe(u8, null_path);
        var registry_object_owned = true;
        errdefer if (registry_object_owned) allocator.free(initial_registry_object);
        self.* = .{
            .allocator = allocator,
            .sink = sink,
            .host = host,
            .app_config = app_config,
            .bus = bus,
            .windows = std.AutoHashMap(u64, WindowState).init(allocator),
            .machine_id = try readMachineId(allocator),
            .registry_name = initial_registry_name,
            .registry_object = initial_registry_object,
        };
        bus_owned = false;
        registry_name_owned = false;
        registry_object_owned = false;
        self_initialized = true;
        errdefer self.deinitUnattached();
        self.bus.setMethodHandler(.{ .context = self, .handle_fn = handleMethodOpaque });
        try self.embed();
        return .{
            .context = self,
            .update_fn = updateOpaque,
            .focus_fn = focusOpaque,
            .remove_window_fn = removeWindowOpaque,
            .deinit_fn = deinitOpaque,
        };
    }

    pub fn fromApi(adapter: api.Adapter) *Adapter {
        return @ptrCast(@alignCast(adapter.context));
    }

    pub fn descriptor(self: *const Adapter) sys.fd_t {
        return self.bus.descriptor();
    }

    pub fn dispatch(self: *Adapter) Error!bool {
        if (self.failure) |failure| return failure;
        return self.bus.dispatchIncoming(false);
    }

    fn embed(self: *Adapter) Error!void {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try appendReference(&body, self.bus.busName(), root_path);
        var reply = try self.bus.call(
            registry_destination,
            registry_path,
            "org.a11y.atspi.Socket",
            "Embed",
            "(so)",
            body.bytes.items,
        );
        defer reply.deinit();
        var reader = reply.bodyReader();
        try reader.beginStruct();
        const registry_name = try self.allocator.dupe(u8, try reader.string());
        errdefer self.allocator.free(registry_name);
        const registry_object = try self.allocator.dupe(u8, try reader.objectPath());
        self.allocator.free(self.registry_name);
        self.allocator.free(self.registry_object);
        self.registry_name = registry_name;
        self.registry_object = registry_object;
    }

    fn update(self: *Adapter, tree: *const api.Tree) Error!void {
        if (self.failure) |failure| return failure;
        if (self.updating) return error.CallbackReentrancy;
        self.updating = true;
        defer self.updating = false;
        try api.validateTree(self.allocator, tree, .{
            .maximum_nodes = self.app_config.memory.accessibility_node_count,
            .maximum_bytes = self.app_config.memory.accessibility_tree_bytes,
        });
        if (self.windows.getPtr(tree.window.encode())) |previous|
            if (!api.generationFollows(tree.generation, previous.generation)) return error.InvalidLayout;
        if (!self.windows.contains(tree.window.encode()) and
            self.windows.count() >= self.app_config.memory.window_count) return error.BudgetExceeded;
        var replacement = try WindowState.init(
            self.allocator,
            tree,
            self.app_config.memory.accessibility_node_count,
            self.app_config.memory.accessibility_tree_bytes,
        );
        var replacement_owned = true;
        errdefer if (replacement_owned) replacement.deinit();
        if (self.windows.getPtr(tree.window.encode())) |previous| {
            self.emitDifferences(previous, &replacement) catch |err| {
                self.fail(err);
                return err;
            };
            var removed = self.windows.fetchRemove(tree.window.encode()).?.value;
            removed.deinit();
            self.windows.putAssumeCapacity(tree.window.encode(), replacement);
        } else {
            try self.windows.ensureUnusedCapacity(1);
            self.emitWindowAdded(&replacement) catch |err| {
                self.fail(err);
                return err;
            };
            self.windows.putAssumeCapacity(tree.window.encode(), replacement);
        }
        replacement_owned = false;
    }

    fn focus(self: *Adapter, id: handles.SemanticId) Error!void {
        if (self.failure) |failure| return failure;
        var iterator = self.windows.valueIterator();
        while (iterator.next()) |window| if (window.nodes.getPtr(id.encode())) |node| {
            self.emitState(window, node, "focused", true) catch |err| {
                self.fail(err);
                return err;
            };
            return;
        };
        return error.InvalidHandle;
    }

    fn handleMethod(self: *Adapter, message: *const dbus.Message) Error!bool {
        const path = message.fields.path orelse return false;
        const interface = message.fields.interface orelse return false;
        const member = message.fields.member orelse return false;
        const object = self.resolve(path) orelse {
            try self.bus.sendError(
                message.serial,
                message.fields.sender,
                "org.freedesktop.DBus.Error.UnknownObject",
                "The requested accessibility object no longer exists",
            );
            return true;
        };
        if (std.mem.eql(u8, interface, properties_interface)) return self.handleProperties(message, object, member);
        if (std.mem.eql(u8, interface, introspect_interface) and std.mem.eql(u8, member, "Introspect"))
            return self.replyString(message, introspectionFor(object));
        if (std.mem.eql(u8, interface, peer_interface)) return self.handlePeer(message, member);
        return switch (object) {
            .application => if (std.mem.eql(u8, interface, accessible_interface))
                self.handleAccessible(message, object, member)
            else if (std.mem.eql(u8, interface, application_interface))
                self.handleApplication(message, member)
            else
                false,
            .cache => if (std.mem.eql(u8, interface, cache_interface)) self.handleCache(message, member) else false,
            .node => if (std.mem.eql(u8, interface, accessible_interface))
                self.handleAccessible(message, object, member)
            else if (std.mem.eql(u8, interface, action_interface))
                self.handleAction(message, object, member)
            else if (std.mem.eql(u8, interface, component_interface))
                self.handleComponent(message, object, member)
            else if (std.mem.eql(u8, interface, text_interface))
                self.handleText(message, object, member)
            else if (std.mem.eql(u8, interface, value_interface))
                self.handleValue(message, object, member)
            else
                false,
        };
    }

    fn resolve(self: *Adapter, path: []const u8) ?Object {
        if (std.mem.eql(u8, path, root_path)) return .application;
        if (std.mem.eql(u8, path, cache_path)) return .cache;
        const prefix = "/org/a11y/atspi/accessible/w_";
        if (!std.mem.startsWith(u8, path, prefix)) return null;
        const separator = std.mem.indexOf(u8, path[prefix.len..], "/n_") orelse return null;
        const window_text = path[prefix.len..][0..separator];
        const node_text = path[prefix.len + separator + 3 ..];
        if (window_text.len == 0 or node_text.len == 0) return null;
        const window_encoded = std.fmt.parseInt(u64, window_text, 16) catch return null;
        const node_encoded = std.fmt.parseInt(u64, node_text, 16) catch return null;
        const window = self.windows.getPtr(window_encoded) orelse return null;
        const node = window.nodes.getPtr(node_encoded) orelse return null;
        return .{ .node = .{ .window = window, .value = node } };
    }

    fn emitWindowAdded(self: *Adapter, state: *WindowState) Error!void {
        var iterator = state.nodes.valueIterator();
        while (iterator.next()) |node| try self.emitCacheAdded(state, node);
        var root_buffer: [160]u8 = undefined;
        const path = try nodePath(&root_buffer, state.window, state.root);
        try self.emitEvent(path, window_event_interface, "Create", "", 0, 0, .none);
        try self.emitEvent(root_path, object_event_interface, "ChildrenChanged", "add", self.windowIndex(state.window), 0, .{ .reference = .{
            .name = self.bus.busName(),
            .path = path,
        } });
    }

    fn emitWindowRemoved(self: *Adapter, state: *WindowState) Error!void {
        var iterator = state.nodes.valueIterator();
        while (iterator.next()) |node| try self.emitCacheRemoved(state, node.id);
        var root_buffer: [160]u8 = undefined;
        const path = try nodePath(&root_buffer, state.window, state.root);
        try self.emitEvent(path, window_event_interface, "Destroy", "", 0, 0, .none);
        try self.emitEvent(root_path, object_event_interface, "ChildrenChanged", "remove", -1, 0, .{ .reference = .{
            .name = self.bus.busName(),
            .path = path,
        } });
    }

    fn emitDifferences(self: *Adapter, previous: *WindowState, next: *WindowState) Error!void {
        var previous_iterator = previous.nodes.valueIterator();
        while (previous_iterator.next()) |old| if (!next.nodes.contains(old.id.encode())) try self.emitCacheRemoved(previous, old.id);
        var next_iterator = next.nodes.valueIterator();
        while (next_iterator.next()) |node| {
            const old = previous.nodes.getPtr(node.id.encode()) orelse {
                try self.emitCacheAdded(next, node);
                continue;
            };
            var path_buffer: [160]u8 = undefined;
            const path = try nodePath(&path_buffer, next.window, node.id);
            if (!std.mem.eql(u8, old.label, node.label)) try self.emitEvent(path, object_event_interface, "PropertyChange", "accessible-name", 0, 0, .{ .string = node.label });
            if (!std.mem.eql(u8, old.description, node.description)) try self.emitEvent(path, object_event_interface, "PropertyChange", "accessible-description", 0, 0, .{ .string = node.description });
            if (!std.mem.eql(u8, old.value, node.value)) try self.emitEvent(path, object_event_interface, "PropertyChange", "accessible-value", 0, 0, .{ .string = node.value });
            if (!std.meta.eql(old.bounds, node.bounds)) try self.emitEvent(path, object_event_interface, "BoundsChanged", "", 0, 0, .{ .rect = self.host.screenRect(next.window, node.bounds) });
            if (old.focused != node.focused) try self.emitState(next, node, "focused", node.focused);
            if (old.selected != node.selected) try self.emitState(next, node, "selected", node.selected);
            if (!std.meta.eql(old.checked, node.checked)) try self.emitState(next, node, "checked", node.checked orelse false);
            if (!std.meta.eql(old.expanded, node.expanded)) try self.emitState(next, node, "expanded", node.expanded orelse false);
            if (old.disabled != node.disabled) try self.emitState(next, node, "enabled", !node.disabled);
            if (old.hidden != node.hidden) {
                try self.emitState(next, node, "visible", !node.hidden);
                try self.emitState(next, node, "showing", !node.hidden);
            }
            if (!sameIds(old.children, node.children)) try self.emitEvent(path, object_event_interface, "ChildrenChanged", "invalidate", -1, 0, .none);
            if (!std.meta.eql(old.selection, node.selection)) try self.emitEvent(path, object_event_interface, "TextSelectionChanged", "", 0, 0, .none);
        }
    }

    fn emitState(self: *Adapter, window: *WindowState, node: *OwnedNode, name: []const u8, enabled: bool) Error!void {
        var path_buffer: [160]u8 = undefined;
        const path = try nodePath(&path_buffer, window.window, node.id);
        try self.emitEvent(path, object_event_interface, "StateChanged", name, @intFromBool(enabled), 0, .{ .boolean = enabled });
    }

    fn windowIndex(self: *Adapter, id: handles.WindowId) i32 {
        var index: i32 = 0;
        var iterator = self.windows.keyIterator();
        while (iterator.next()) |encoded| : (index += 1) if (encoded.* == id.encode()) return index;
        return index;
    }

    fn handlePeer(self: *Adapter, message: *const dbus.Message, member: []const u8) Error!bool {
        if (std.mem.eql(u8, member, "Ping")) return self.replyEmpty(message);
        if (std.mem.eql(u8, member, "GetMachineId")) return self.replyString(message, &self.machine_id);
        return false;
    }

    fn handleProperties(self: *Adapter, message: *const dbus.Message, object: Object, member: []const u8) Error!bool {
        var reader = message.bodyReader();
        if (std.mem.eql(u8, member, "Get")) {
            if (!signatureIs(message, "ss")) return self.invalidArgs(message);
            const interface = try reader.string();
            const name = try reader.string();
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            if (!try self.appendProperty(&body, object, interface, name, false)) return self.unknownProperty(message);
            try self.sendReturn(message, "v", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetAll")) {
            if (!signatureIs(message, "s")) return self.invalidArgs(message);
            const interface = try reader.string();
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            const array = try body.beginArray(8);
            if (!try self.appendAllProperties(&body, object, interface)) return self.unknownProperty(message);
            try body.endArray(array);
            try self.sendReturn(message, "a{sv}", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "Set")) {
            if (!signatureIs(message, "ssv")) return self.invalidArgs(message);
            const interface = try reader.string();
            const name = try reader.string();
            const value_signature = try reader.variantHeader();
            if (objectIs(object, .application) and std.mem.eql(u8, interface, application_interface) and std.mem.eql(u8, name, "Id") and std.mem.eql(u8, value_signature, "i")) {
                self.app_id = try reader.i32();
                return self.replyEmpty(message);
            }
            if (objectIs(object, .node) and std.mem.eql(u8, interface, value_interface) and std.mem.eql(u8, name, "CurrentValue") and std.mem.eql(u8, value_signature, "d")) {
                const number = try reader.f64();
                const query = object.node;
                if (!supportsAction(query.value, .set_value)) return self.notSupported(message);
                var number_buffer: [64]u8 = undefined;
                const value = std.fmt.bufPrint(&number_buffer, "{d}", .{number}) catch return error.PlatformFailure;
                self.sink.emit(.{ .window = query.window.window, .target = query.value.id, .action = .set_value, .value = value });
                return self.replyEmpty(message);
            }
            return self.readOnlyProperty(message);
        }
        return false;
    }

    fn appendAllProperties(self: *Adapter, writer: *wire.Writer, object: Object, interface: []const u8) Error!bool {
        if (std.mem.eql(u8, interface, accessible_interface)) {
            inline for (.{ "version", "Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId", "HelpText" }) |name|
                if (!try self.appendProperty(writer, object, interface, name, true)) return false;
            return !objectIs(object, .cache);
        }
        if (std.mem.eql(u8, interface, application_interface)) {
            inline for (.{ "ToolkitName", "Version", "ToolkitVersion", "AtspiVersion", "InterfaceVersion", "Id" }) |name|
                if (!try self.appendProperty(writer, object, interface, name, true)) return false;
            return objectIs(object, .application);
        }
        if (std.mem.eql(u8, interface, action_interface)) {
            inline for (.{ "version", "NActions" }) |name| if (!try self.appendProperty(writer, object, interface, name, true)) return false;
            return true;
        }
        if (std.mem.eql(u8, interface, component_interface)) return self.appendProperty(writer, object, interface, "version", true);
        if (std.mem.eql(u8, interface, text_interface)) {
            inline for (.{ "version", "CharacterCount", "CaretOffset" }) |name| if (!try self.appendProperty(writer, object, interface, name, true)) return false;
            return true;
        }
        if (std.mem.eql(u8, interface, value_interface)) {
            inline for (.{ "version", "MinimumValue", "MaximumValue", "MinimumIncrement", "CurrentValue", "Text" }) |name|
                if (!try self.appendProperty(writer, object, interface, name, true)) return false;
            return true;
        }
        if (std.mem.eql(u8, interface, cache_interface)) return self.appendProperty(writer, object, interface, "version", true);
        return false;
    }

    fn appendProperty(self: *Adapter, writer: *wire.Writer, object: Object, interface: []const u8, name: []const u8, include_key: bool) Error!bool {
        if (include_key) {
            try writer.beginStruct();
            try writer.string(name);
        }
        if (std.mem.eql(u8, interface, accessible_interface) and !objectIs(object, .cache)) {
            if (std.mem.eql(u8, name, "version")) return appendVariantU32(writer, 1);
            if (std.mem.eql(u8, name, "Name")) return appendVariantString(writer, objectName(self, object));
            if (std.mem.eql(u8, name, "Description")) return appendVariantString(writer, objectDescription(object));
            if (std.mem.eql(u8, name, "Parent")) {
                try writer.variantHeader("(so)");
                try self.appendParentReference(writer, object);
                return true;
            }
            if (std.mem.eql(u8, name, "ChildCount")) return appendVariantI32(writer, childCount(self, object));
            if (std.mem.eql(u8, name, "Locale")) return appendVariantString(writer, "C");
            if (std.mem.eql(u8, name, "AccessibleId")) {
                var buffer: [64]u8 = undefined;
                const id = switch (object) {
                    .application => "zigui-application",
                    .node => |query| std.fmt.bufPrint(&buffer, "zigui-{x}-{x}", .{ query.window.window.encode(), query.value.id.encode() }) catch return error.PlatformFailure,
                    .cache => unreachable,
                };
                return appendVariantString(writer, id);
            }
            if (std.mem.eql(u8, name, "HelpText")) return appendVariantString(writer, objectDescription(object));
            return false;
        }
        if (std.mem.eql(u8, interface, application_interface) and objectIs(object, .application)) {
            if (std.mem.eql(u8, name, "ToolkitName")) return appendVariantString(writer, "ZigUI");
            if (std.mem.eql(u8, name, "Version") or std.mem.eql(u8, name, "ToolkitVersion")) return appendVariantString(writer, self.app_config.application_version);
            if (std.mem.eql(u8, name, "AtspiVersion")) return appendVariantString(writer, "2.1");
            if (std.mem.eql(u8, name, "InterfaceVersion")) return appendVariantU32(writer, 1);
            if (std.mem.eql(u8, name, "Id")) return appendVariantI32(writer, self.app_id);
            return false;
        }
        if (std.mem.eql(u8, interface, action_interface) and objectIs(object, .node) and supportsInterface(object.node.value, .action)) {
            if (std.mem.eql(u8, name, "version")) return appendVariantU32(writer, 1);
            if (std.mem.eql(u8, name, "NActions")) return appendVariantI32(writer, saturatingI32(object.node.value.actions.len));
            return false;
        }
        if (std.mem.eql(u8, interface, component_interface) and objectIs(object, .node)) {
            if (std.mem.eql(u8, name, "version")) return appendVariantU32(writer, 1);
            return false;
        }
        if (std.mem.eql(u8, interface, text_interface) and objectIs(object, .node) and supportsInterface(object.node.value, .text)) {
            const node = object.node.value;
            if (std.mem.eql(u8, name, "version")) return appendVariantU32(writer, 1);
            if (std.mem.eql(u8, name, "CharacterCount")) return appendVariantI32(writer, saturatingI32(scalarCount(textContent(node))));
            if (std.mem.eql(u8, name, "CaretOffset")) {
                const selection = node.selection orelse return appendVariantI32(writer, 0);
                return appendVariantI32(writer, saturatingI32(scalarOffsetForByte(textContent(node), selection.focus)));
            }
            return false;
        }
        if (std.mem.eql(u8, interface, value_interface) and objectIs(object, .node) and supportsInterface(object.node.value, .value)) {
            const node = object.node.value;
            if (std.mem.eql(u8, name, "version")) return appendVariantU32(writer, 1);
            if (std.mem.eql(u8, name, "MinimumValue")) return appendVariantF64(writer, node.range_min orelse 0);
            if (std.mem.eql(u8, name, "MaximumValue")) return appendVariantF64(writer, node.range_max orelse 0);
            if (std.mem.eql(u8, name, "MinimumIncrement")) return appendVariantF64(writer, rangeIncrement(node));
            if (std.mem.eql(u8, name, "CurrentValue")) return appendVariantF64(writer, node.range_value orelse 0);
            if (std.mem.eql(u8, name, "Text")) return appendVariantString(writer, node.value);
            return false;
        }
        if (std.mem.eql(u8, interface, cache_interface) and objectIs(object, .cache) and std.mem.eql(u8, name, "version"))
            return appendVariantU32(writer, 1);
        return false;
    }

    fn handleAccessible(self: *Adapter, message: *const dbus.Message, object: Object, member: []const u8) Error!bool {
        if (std.mem.eql(u8, member, "GetChildAtIndex")) {
            if (!signatureIs(message, "i")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const index = try reader.i32();
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            if (index < 0 or !try self.appendChildReference(&body, object, @intCast(index))) try appendReference(&body, "", null_path);
            try self.sendReturn(message, "(so)", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetChildren")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            const array = try body.beginArray(8);
            var index: usize = 0;
            while (index < @as(usize, @intCast(@max(childCount(self, object), 0)))) : (index += 1)
                _ = try self.appendChildReference(&body, object, index);
            try body.endArray(array);
            try self.sendReturn(message, "a(so)", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetIndexInParent")) return self.replyI32(message, self.indexInParent(object));
        if (std.mem.eql(u8, member, "GetRelationSet")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            const array = try body.beginArray(8);
            try body.endArray(array);
            try self.sendReturn(message, "a(ua(so))", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetRole")) return self.replyU32(message, objectRole(object));
        if (std.mem.eql(u8, member, "GetRoleName") or std.mem.eql(u8, member, "GetLocalizedRoleName")) return self.replyString(message, roleName(objectRoleValue(object)));
        if (std.mem.eql(u8, member, "GetState")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try appendStateSet(&body, objectNode(object));
            try self.sendReturn(message, "au", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetAttributes")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try appendAttributes(&body, objectNode(object));
            try self.sendReturn(message, "a{ss}", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetApplication")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try appendReference(&body, self.bus.busName(), root_path);
            try self.sendReturn(message, "(so)", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetInterfaces")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try appendInterfaces(&body, object);
            try self.sendReturn(message, "as", body.bytes.items);
            return true;
        }
        return false;
    }

    fn handleApplication(self: *Adapter, message: *const dbus.Message, member: []const u8) Error!bool {
        if (std.mem.eql(u8, member, "GetLocale")) {
            if (!signatureIs(message, "u")) return self.invalidArgs(message);
            return self.replyString(message, "C");
        }
        if (std.mem.eql(u8, member, "GetApplicationBusAddress")) return self.notSupported(message);
        return false;
    }

    fn handleAction(self: *Adapter, message: *const dbus.Message, object: Object, member: []const u8) Error!bool {
        if (!objectIs(object, .node) or !supportsInterface(object.node.value, .action)) return false;
        const query = object.node;
        if (std.mem.eql(u8, member, "GetActions")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            const array = try body.beginArray(8);
            for (query.value.actions) |action| {
                try body.beginStruct();
                try body.string(actionLocalizedName(action));
                try body.string(actionDescription(action));
                try body.string("");
            }
            try body.endArray(array);
            try self.sendReturn(message, "a(sss)", body.bytes.items);
            return true;
        }
        if (!signatureIs(message, "i")) return self.invalidArgs(message);
        var reader = message.bodyReader();
        const index = try reader.i32();
        const action = actionAt(query.value, index) orelse {
            if (std.mem.eql(u8, member, "DoAction")) return self.replyBool(message, false);
            return self.invalidArgs(message);
        };
        if (std.mem.eql(u8, member, "GetDescription")) return self.replyString(message, actionDescription(action));
        if (std.mem.eql(u8, member, "GetName")) return self.replyString(message, actionName(action));
        if (std.mem.eql(u8, member, "GetLocalizedName")) return self.replyString(message, actionLocalizedName(action));
        if (std.mem.eql(u8, member, "GetKeyBinding")) return self.replyString(message, "");
        if (std.mem.eql(u8, member, "DoAction")) {
            if (query.value.disabled) return self.replyBool(message, false);
            self.sink.emit(.{ .window = query.window.window, .target = query.value.id, .action = action });
            return self.replyBool(message, true);
        }
        return false;
    }

    fn handleComponent(self: *Adapter, message: *const dbus.Message, object: Object, member: []const u8) Error!bool {
        if (!objectIs(object, .node)) return false;
        const query = object.node;
        if (std.mem.eql(u8, member, "Contains")) {
            if (!signatureIs(message, "iiu")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const x = try reader.i32();
            const y = try reader.i32();
            const coordinates = try reader.u32();
            const rect = self.componentRect(query, coordinates);
            return self.replyBool(message, rect.contains(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) }));
        }
        if (std.mem.eql(u8, member, "GetAccessibleAtPoint")) {
            if (!signatureIs(message, "iiu")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const x = try reader.i32();
            const y = try reader.i32();
            const coordinates = try reader.u32();
            const found = self.deepestAt(query.window, query.value, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) }, coordinates);
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            if (found) |node| try self.appendNodeReference(&body, query.window, node.id) else try appendReference(&body, "", null_path);
            try self.sendReturn(message, "(so)", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetExtents")) {
            if (!signatureIs(message, "u")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const rect = self.componentRect(query, try reader.u32());
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try body.beginStruct();
            try body.i32(roundI32(rect.origin.x));
            try body.i32(roundI32(rect.origin.y));
            try body.i32(roundI32(rect.size.width));
            try body.i32(roundI32(rect.size.height));
            try self.sendReturn(message, "(iiii)", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetPosition")) {
            if (!signatureIs(message, "u")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const rect = self.componentRect(query, try reader.u32());
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try body.i32(roundI32(rect.origin.x));
            try body.i32(roundI32(rect.origin.y));
            try self.sendReturn(message, "ii", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetSize")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try body.i32(roundI32(query.value.bounds.size.width));
            try body.i32(roundI32(query.value.bounds.size.height));
            try self.sendReturn(message, "ii", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetLayer")) return self.replyU32(message, if (query.value.role == .window or query.value.role == .dialog) 7 else 3);
        if (std.mem.eql(u8, member, "GetMDIZOrder")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try body.i16(-1);
            try self.sendReturn(message, "n", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GrabFocus")) {
            if (!supportsAction(query.value, .focus) or query.value.disabled) return self.replyBool(message, false);
            self.sink.emit(.{ .window = query.window.window, .target = query.value.id, .action = .focus });
            return self.replyBool(message, true);
        }
        if (std.mem.eql(u8, member, "GetAlpha")) return self.replyF64(message, if (query.value.hidden) 0 else 1);
        if (std.mem.eql(u8, member, "SetExtents") or std.mem.eql(u8, member, "SetPosition") or std.mem.eql(u8, member, "SetSize"))
            return self.replyBool(message, false);
        if (std.mem.eql(u8, member, "ScrollTo")) {
            if (!signatureIs(message, "u")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const scroll_type = try reader.u32();
            const action: api.Action = switch (scroll_type) {
                0, 2 => .scroll_up,
                1, 3 => .scroll_down,
                4 => .scroll_left,
                5 => .scroll_right,
                else => if (supportsAction(query.value, .scroll_down)) .scroll_down else .scroll_up,
            };
            if (!supportsAction(query.value, action)) return self.replyBool(message, false);
            self.sink.emit(.{ .window = query.window.window, .target = query.value.id, .action = action });
            return self.replyBool(message, true);
        }
        if (std.mem.eql(u8, member, "ScrollToPoint")) {
            if (!signatureIs(message, "uii")) return self.invalidArgs(message);
            const action: api.Action = if (supportsAction(query.value, .scroll_down)) .scroll_down else .scroll_up;
            if (!supportsAction(query.value, action)) return self.replyBool(message, false);
            self.sink.emit(.{ .window = query.window.window, .target = query.value.id, .action = action });
            return self.replyBool(message, true);
        }
        return false;
    }

    fn componentRect(self: *Adapter, query: NodeQuery, coordinates: u32) geometry.Rect {
        return switch (coordinates) {
            0 => self.host.screenRect(query.window.window, query.value.bounds),
            2 => if (query.window.nodes.getPtr(query.value.parent.encode())) |parent|
                query.value.bounds.translated(.{ .x = -parent.bounds.origin.x, .y = -parent.bounds.origin.y })
            else
                query.value.bounds,
            else => query.value.bounds,
        };
    }

    fn deepestAt(self: *Adapter, window: *WindowState, node: *OwnedNode, point: geometry.Point, coordinates: u32) ?*OwnedNode {
        const query: NodeQuery = .{ .window = window, .value = node };
        if (node.hidden or !self.componentRect(query, coordinates).contains(point)) return null;
        var index = node.children.len;
        while (index != 0) {
            index -= 1;
            const child = window.nodes.getPtr(node.children[index].encode()) orelse continue;
            if (self.deepestAt(window, child, point, coordinates)) |result| return result;
        }
        return node;
    }

    fn handleText(self: *Adapter, message: *const dbus.Message, object: Object, member: []const u8) Error!bool {
        if (!objectIs(object, .node) or !supportsInterface(object.node.value, .text)) return false;
        const query = object.node;
        const value = textContent(query.value);
        const count = scalarCount(value);
        if (std.mem.eql(u8, member, "GetStringAtOffset")) {
            if (!signatureIs(message, "iu")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const offset = try reader.i32();
            const granularity = try reader.u32();
            const range = textRangeAt(value, offset, granularity);
            return self.replyTextRange(message, value, range);
        }
        if (std.mem.eql(u8, member, "GetText")) {
            if (!signatureIs(message, "ii")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const start = try reader.i32();
            const end = try reader.i32();
            const range = normalizedScalarRange(value, start, end);
            return self.replyString(message, value[range.byte_start..range.byte_end]);
        }
        if (std.mem.eql(u8, member, "SetCaretOffset")) {
            if (!signatureIs(message, "i")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const offset = try reader.i32();
            if (offset < 0 or @as(usize, @intCast(offset)) > count or !supportsAction(query.value, .set_selection)) return self.replyBool(message, false);
            const byte_offset = byteOffsetForScalar(value, @intCast(offset));
            self.sink.emit(.{ .window = query.window.window, .target = query.value.id, .action = .set_selection, .selection = .{
                .anchor = byte_offset,
                .focus = byte_offset,
            } });
            return self.replyBool(message, true);
        }
        if (std.mem.eql(u8, member, "GetTextBeforeOffset") or std.mem.eql(u8, member, "GetTextAtOffset") or std.mem.eql(u8, member, "GetTextAfterOffset")) {
            if (!signatureIs(message, "iu")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const offset = try reader.i32();
            const boundary = try reader.u32();
            var range = textRangeAt(value, offset, legacyBoundaryGranularity(boundary));
            if (std.mem.eql(u8, member, "GetTextBeforeOffset")) range = textRangeAt(
                value,
                if (range.scalar_start == 0) -1 else @intCast(range.scalar_start - 1),
                legacyBoundaryGranularity(boundary),
            );
            if (std.mem.eql(u8, member, "GetTextAfterOffset")) range = textRangeAt(value, saturatingI32(range.scalar_end), legacyBoundaryGranularity(boundary));
            return self.replyTextRange(message, value, range);
        }
        if (std.mem.eql(u8, member, "GetCharacterAtOffset")) {
            if (!signatureIs(message, "i")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const offset = try reader.i32();
            const scalar: i32 = if (offset < 0) -1 else @bitCast(scalarAt(value, @intCast(offset)) orelse std.math.maxInt(u32));
            return self.replyI32(message, scalar);
        }
        if (std.mem.eql(u8, member, "GetAttributeValue")) return self.replyString(message, "");
        if (std.mem.eql(u8, member, "GetAttributes") or std.mem.eql(u8, member, "GetAttributeRun")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try appendEmptyStringMap(&body);
            try body.i32(0);
            try body.i32(saturatingI32(count));
            try self.sendReturn(message, "a{ss}ii", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetDefaultAttributes") or std.mem.eql(u8, member, "GetDefaultAttributeSet")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try appendEmptyStringMap(&body);
            try self.sendReturn(message, "a{ss}", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "GetCharacterExtents")) {
            if (!signatureIs(message, "iu")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const offset = try reader.i32();
            const coordinates = try reader.u32();
            const rect = self.textExtents(query, offset, if (offset < 0) 0 else offset + 1, coordinates);
            return self.replyRectFields(message, rect);
        }
        if (std.mem.eql(u8, member, "GetOffsetAtPoint")) {
            if (!signatureIs(message, "iiu")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const x = try reader.i32();
            _ = try reader.i32();
            const coordinates = try reader.u32();
            const rect = self.componentRect(query, coordinates);
            const fraction = if (rect.size.width <= 0) 0 else std.math.clamp((@as(f32, @floatFromInt(x)) - rect.origin.x) / rect.size.width, 0, 1);
            return self.replyI32(message, saturatingI32(@as(usize, @intFromFloat(@round(fraction * @as(f32, @floatFromInt(count)))))));
        }
        if (std.mem.eql(u8, member, "GetNSelections")) return self.replyI32(message, if (query.value.selection != null) 1 else 0);
        if (std.mem.eql(u8, member, "GetSelection")) {
            if (!signatureIs(message, "i")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const selection_index = try reader.i32();
            const selection = query.value.selection orelse return self.invalidArgs(message);
            if (selection_index != 0) return self.invalidArgs(message);
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            try body.i32(saturatingI32(scalarOffsetForByte(value, selection.anchor)));
            try body.i32(saturatingI32(scalarOffsetForByte(value, selection.focus)));
            try self.sendReturn(message, "ii", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "AddSelection")) return self.setTextSelection(message, query, false);
        if (std.mem.eql(u8, member, "SetSelection")) return self.setTextSelection(message, query, true);
        if (std.mem.eql(u8, member, "RemoveSelection")) {
            if (!supportsAction(query.value, .set_selection)) return self.replyBool(message, false);
            self.sink.emit(.{ .window = query.window.window, .target = query.value.id, .action = .set_selection, .selection = .{ .anchor = 0, .focus = 0 } });
            return self.replyBool(message, true);
        }
        if (std.mem.eql(u8, member, "GetRangeExtents")) {
            if (!signatureIs(message, "iiu")) return self.invalidArgs(message);
            var reader = message.bodyReader();
            const start = try reader.i32();
            const end = try reader.i32();
            const coordinates = try reader.u32();
            return self.replyRectFields(message, self.textExtents(query, start, end, coordinates));
        }
        if (std.mem.eql(u8, member, "GetBoundedRanges")) {
            var body = wire.Writer.init(self.allocator);
            defer body.deinit();
            const array = try body.beginArray(8);
            try body.beginStruct();
            try body.i32(0);
            try body.i32(saturatingI32(count));
            try body.string(value);
            try body.variantHeader("i");
            try body.i32(0);
            try body.endArray(array);
            try self.sendReturn(message, "a(iisv)", body.bytes.items);
            return true;
        }
        if (std.mem.eql(u8, member, "ScrollSubstringTo") or std.mem.eql(u8, member, "ScrollSubstringToPoint")) {
            const action: api.Action = if (supportsAction(query.value, .scroll_down)) .scroll_down else .scroll_up;
            if (!supportsAction(query.value, action)) return self.replyBool(message, false);
            self.sink.emit(.{ .window = query.window.window, .target = query.value.id, .action = action });
            return self.replyBool(message, true);
        }
        return false;
    }

    fn setTextSelection(self: *Adapter, message: *const dbus.Message, query: NodeQuery, has_index: bool) Error!bool {
        var reader = message.bodyReader();
        if (has_index) {
            if (!signatureIs(message, "iii")) return self.invalidArgs(message);
            if ((try reader.i32()) != 0) return self.replyBool(message, false);
        } else if (!signatureIs(message, "ii")) return self.invalidArgs(message);
        const start = try reader.i32();
        const end = try reader.i32();
        const value = textContent(query.value);
        const count = scalarCount(value);
        if (start < 0 or end < 0 or @as(usize, @intCast(start)) > count or @as(usize, @intCast(end)) > count or !supportsAction(query.value, .set_selection))
            return self.replyBool(message, false);
        self.sink.emit(.{
            .window = query.window.window,
            .target = query.value.id,
            .action = .set_selection,
            .selection = .{
                .anchor = byteOffsetForScalar(value, @intCast(start)),
                .focus = byteOffsetForScalar(value, @intCast(end)),
            },
        });
        return self.replyBool(message, true);
    }

    fn textExtents(self: *Adapter, query: NodeQuery, start_source: i32, end_source: i32, coordinates: u32) geometry.Rect {
        const value = textContent(query.value);
        const count = scalarCount(value);
        const start: usize = if (start_source < 0) 0 else @min(@as(usize, @intCast(start_source)), count);
        const end: usize = if (end_source < 0) count else @min(@as(usize, @intCast(end_source)), count);
        var rect = self.componentRect(query, coordinates);
        if (count == 0) return .{ .origin = rect.origin, .size = .{ .height = rect.size.height } };
        const unit = rect.size.width / @as(f32, @floatFromInt(count));
        rect.origin.x += unit * @as(f32, @floatFromInt(@min(start, end)));
        rect.size.width = unit * @as(f32, @floatFromInt(if (end >= start) end - start else start - end));
        return rect;
    }

    fn replyTextRange(self: *Adapter, message: *const dbus.Message, value: []const u8, range: ScalarRange) Error!bool {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.string(value[range.byte_start..range.byte_end]);
        try body.i32(saturatingI32(range.scalar_start));
        try body.i32(saturatingI32(range.scalar_end));
        try self.sendReturn(message, "sii", body.bytes.items);
        return true;
    }

    fn replyRectFields(self: *Adapter, message: *const dbus.Message, rect: geometry.Rect) Error!bool {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.i32(roundI32(rect.origin.x));
        try body.i32(roundI32(rect.origin.y));
        try body.i32(roundI32(rect.size.width));
        try body.i32(roundI32(rect.size.height));
        try self.sendReturn(message, "iiii", body.bytes.items);
        return true;
    }

    fn handleCache(self: *Adapter, message: *const dbus.Message, member: []const u8) Error!bool {
        if (!std.mem.eql(u8, member, "GetItems")) return false;
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        const array = try body.beginArray(8);
        try self.appendCacheItem(&body, .application);
        var windows = self.windows.valueIterator();
        while (windows.next()) |window| {
            var nodes = window.nodes.valueIterator();
            while (nodes.next()) |node| try self.appendCacheItem(&body, .{ .node = .{ .window = window, .value = node } });
        }
        try body.endArray(array);
        try self.sendReturn(message, "a((so)(so)(so)iiassusau)", body.bytes.items);
        return true;
    }

    fn appendCacheItem(self: *Adapter, writer: *wire.Writer, object: Object) Error!void {
        try writer.beginStruct();
        try self.appendObjectReference(writer, object);
        try appendReference(writer, self.bus.busName(), root_path);
        try self.appendParentReference(writer, object);
        try writer.i32(self.indexInParent(object));
        try writer.i32(childCount(self, object));
        try appendInterfaces(writer, object);
        try writer.string(objectName(self, object));
        try writer.u32(objectRole(object));
        try writer.string(objectDescription(object));
        try appendStateSet(writer, objectNode(object));
    }

    fn emitCacheAdded(self: *Adapter, window: *WindowState, node: *OwnedNode) Error!void {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try self.appendCacheItem(&body, .{ .node = .{ .window = window, .value = node } });
        try self.bus.sendSignal(cache_path, cache_interface, "AddAccessible", "((so)(so)(so)iiassusau)", body.bytes.items);
    }

    fn emitCacheRemoved(self: *Adapter, window: *WindowState, id: handles.SemanticId) Error!void {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try self.appendNodeReference(&body, window, id);
        try self.bus.sendSignal(cache_path, cache_interface, "RemoveAccessible", "(so)", body.bytes.items);
    }

    fn emitEvent(
        self: *Adapter,
        path: []const u8,
        interface: []const u8,
        member: []const u8,
        detail: []const u8,
        detail_one: i32,
        detail_two: i32,
        value: EventValue,
    ) Error!void {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.string(detail);
        try body.i32(detail_one);
        try body.i32(detail_two);
        switch (value) {
            .none => {
                try body.variantHeader("i");
                try body.i32(0);
            },
            .boolean => |boolean| {
                try body.variantHeader("b");
                try body.boolean(boolean);
            },
            .string => |string| {
                try body.variantHeader("s");
                try body.string(string);
            },
            .reference => |reference| {
                try body.variantHeader("(so)");
                try appendReference(&body, reference.name, reference.path);
            },
            .rect => |rect| {
                try body.variantHeader("(iiii)");
                try body.beginStruct();
                try body.i32(roundI32(rect.origin.x));
                try body.i32(roundI32(rect.origin.y));
                try body.i32(roundI32(rect.size.width));
                try body.i32(roundI32(rect.size.height));
            },
        }
        const properties = try body.beginArray(8);
        try body.endArray(properties);
        try self.bus.sendSignal(path, interface, member, "siiva{sv}", body.bytes.items);
    }

    fn appendObjectReference(self: *Adapter, writer: *wire.Writer, object: Object) Error!void {
        switch (object) {
            .application => try appendReference(writer, self.bus.busName(), root_path),
            .cache => try appendReference(writer, self.bus.busName(), cache_path),
            .node => |query| try self.appendNodeReference(writer, query.window, query.value.id),
        }
    }

    fn appendNodeReference(self: *Adapter, writer: *wire.Writer, window: *WindowState, id: handles.SemanticId) Error!void {
        var buffer: [160]u8 = undefined;
        try appendReference(writer, self.bus.busName(), try nodePath(&buffer, window.window, id));
    }

    fn appendParentReference(self: *Adapter, writer: *wire.Writer, object: Object) Error!void {
        switch (object) {
            .application => try appendReference(writer, self.registry_name, self.registry_object),
            .cache => try appendReference(writer, "", null_path),
            .node => |query| if (query.value.parent.isValid())
                try self.appendNodeReference(writer, query.window, query.value.parent)
            else
                try appendReference(writer, self.bus.busName(), root_path),
        }
    }

    fn appendChildReference(self: *Adapter, writer: *wire.Writer, object: Object, requested: usize) Error!bool {
        switch (object) {
            .application => {
                var index: usize = 0;
                var iterator = self.windows.valueIterator();
                while (iterator.next()) |window| : (index += 1) if (index == requested) {
                    try self.appendNodeReference(writer, window, window.root);
                    return true;
                };
                return false;
            },
            .node => |query| {
                if (requested >= query.value.children.len) return false;
                try self.appendNodeReference(writer, query.window, query.value.children[requested]);
                return true;
            },
            .cache => return false,
        }
    }

    fn indexInParent(self: *Adapter, object: Object) i32 {
        return switch (object) {
            .application, .cache => -1,
            .node => |query| if (query.value.parent.isValid()) blk: {
                const parent = query.window.nodes.getPtr(query.value.parent.encode()) orelse break :blk -1;
                for (parent.children, 0..) |child, index| if (child.eql(query.value.id)) break :blk saturatingI32(index);
                break :blk -1;
            } else blk: {
                var index: usize = 0;
                var iterator = self.windows.valueIterator();
                while (iterator.next()) |window| : (index += 1) if (window.window.eql(query.window.window)) break :blk saturatingI32(index);
                break :blk -1;
            },
        };
    }

    fn sendReturn(self: *Adapter, message: *const dbus.Message, signature: []const u8, body: []const u8) Error!void {
        try self.bus.sendMethodReturn(message.serial, message.fields.sender, signature, body);
    }

    fn replyEmpty(self: *Adapter, message: *const dbus.Message) Error!bool {
        try self.sendReturn(message, "", "");
        return true;
    }

    fn replyString(self: *Adapter, message: *const dbus.Message, value: []const u8) Error!bool {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.string(value);
        try self.sendReturn(message, "s", body.bytes.items);
        return true;
    }

    fn replyI32(self: *Adapter, message: *const dbus.Message, value: i32) Error!bool {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.i32(value);
        try self.sendReturn(message, "i", body.bytes.items);
        return true;
    }

    fn replyU32(self: *Adapter, message: *const dbus.Message, value: u32) Error!bool {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.u32(value);
        try self.sendReturn(message, "u", body.bytes.items);
        return true;
    }

    fn replyBool(self: *Adapter, message: *const dbus.Message, value: bool) Error!bool {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.boolean(value);
        try self.sendReturn(message, "b", body.bytes.items);
        return true;
    }

    fn replyF64(self: *Adapter, message: *const dbus.Message, value: f64) Error!bool {
        var body = wire.Writer.init(self.allocator);
        defer body.deinit();
        try body.f64(value);
        try self.sendReturn(message, "d", body.bytes.items);
        return true;
    }

    fn invalidArgs(self: *Adapter, message: *const dbus.Message) Error!bool {
        try self.bus.sendError(message.serial, message.fields.sender, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid accessibility method arguments");
        return true;
    }

    fn unknownProperty(self: *Adapter, message: *const dbus.Message) Error!bool {
        try self.bus.sendError(message.serial, message.fields.sender, "org.freedesktop.DBus.Error.UnknownProperty", "Unknown accessibility property");
        return true;
    }

    fn readOnlyProperty(self: *Adapter, message: *const dbus.Message) Error!bool {
        try self.bus.sendError(message.serial, message.fields.sender, "org.freedesktop.DBus.Error.PropertyReadOnly", "The accessibility property is read-only");
        return true;
    }

    fn notSupported(self: *Adapter, message: *const dbus.Message) Error!bool {
        try self.bus.sendError(message.serial, message.fields.sender, "org.a11y.atspi.Error.NotSupported", "The requested operation is not supported by this semantic node");
        return true;
    }

    fn handleValue(self: *Adapter, message: *const dbus.Message, object: Object, member: []const u8) Error!bool {
        _ = self;
        _ = message;
        _ = object;
        _ = member;
        return false;
    }

    pub fn removeWindow(self: *Adapter, id: handles.WindowId) void {
        const removed = self.windows.fetchRemove(id.encode()) orelse return;
        var state = removed.value;
        if (self.failure == null) self.emitWindowRemoved(&state) catch |err| self.fail(err);
        state.deinit();
    }

    fn fail(self: *Adapter, err: Error) void {
        if (self.failure == null) self.failure = err;
    }

    fn deinit(self: *Adapter) void {
        self.host.detach(self);
        self.deinitUnattached();
    }

    fn deinitUnattached(self: *Adapter) void {
        var iterator = self.windows.valueIterator();
        while (iterator.next()) |window| window.deinit();
        self.windows.deinit();
        self.allocator.free(self.registry_name);
        self.allocator.free(self.registry_object);
        self.bus.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

fn updateOpaque(raw: *anyopaque, tree: *const api.Tree) Error!void {
    try cast(raw).update(tree);
}

fn focusOpaque(raw: *anyopaque, id: handles.SemanticId) Error!void {
    try cast(raw).focus(id);
}

fn removeWindowOpaque(raw: *anyopaque, id: handles.WindowId) void {
    cast(raw).removeWindow(id);
}

fn deinitOpaque(raw: *anyopaque) void {
    cast(raw).deinit();
}

fn cast(raw: *anyopaque) *Adapter {
    return @ptrCast(@alignCast(raw));
}

fn handleMethodOpaque(raw: *anyopaque, client: *dbus.Client, message: *const dbus.Message) Error!bool {
    _ = client;
    return cast(raw).handleMethod(message);
}

const EventValue = union(enum) {
    none,
    boolean: bool,
    string: []const u8,
    reference: struct { name: []const u8, path: []const u8 },
    rect: geometry.Rect,
};

const InterfaceKind = enum { action, text, value };

const ObjectTag = std.meta.Tag(Object);

fn objectIs(object: Object, tag: ObjectTag) bool {
    return std.meta.activeTag(object) == tag;
}

fn duplicateAccessibleValue(allocator: std.mem.Allocator, value: []const u8, password: bool) Error![]u8 {
    if (!password) return allocator.dupe(u8, value);
    const count = scalarCount(value);
    const bytes = std.math.mul(usize, count, 3) catch return error.BudgetExceeded;
    const result = try allocator.alloc(u8, bytes);
    var offset: usize = 0;
    while (offset < result.len) : (offset += 3) @memcpy(result[offset..][0..3], "\xe2\x80\xa2");
    return result;
}

fn nodePath(buffer: []u8, window: handles.WindowId, node: handles.SemanticId) Error![]const u8 {
    return std.fmt.bufPrint(buffer, "/org/a11y/atspi/accessible/w_{x}/n_{x}", .{ window.encode(), node.encode() }) catch
        return error.BudgetExceeded;
}

fn appendReference(writer: *wire.Writer, name: []const u8, path: []const u8) Error!void {
    try writer.beginStruct();
    try writer.string(name);
    try writer.objectPath(path);
}

fn signatureIs(message: *const dbus.Message, expected: []const u8) bool {
    return std.mem.eql(u8, message.fields.signature, expected);
}

fn sameIds(left: []const handles.SemanticId, right: []const handles.SemanticId) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (!a.eql(b)) return false;
    return true;
}

fn appendVariantString(writer: *wire.Writer, value: []const u8) Error!bool {
    try writer.variantHeader("s");
    try writer.string(value);
    return true;
}

fn appendVariantI32(writer: *wire.Writer, value: i32) Error!bool {
    try writer.variantHeader("i");
    try writer.i32(value);
    return true;
}

fn appendVariantU32(writer: *wire.Writer, value: u32) Error!bool {
    try writer.variantHeader("u");
    try writer.u32(value);
    return true;
}

fn appendVariantF64(writer: *wire.Writer, value: f64) Error!bool {
    try writer.variantHeader("d");
    try writer.f64(value);
    return true;
}

fn objectName(adapter: *Adapter, object: Object) []const u8 {
    return switch (object) {
        .application => adapter.app_config.application_name,
        .cache => "",
        .node => |query| query.value.label,
    };
}

fn objectDescription(object: Object) []const u8 {
    return switch (object) {
        .application, .cache => "",
        .node => |query| query.value.description,
    };
}

fn objectNode(object: Object) ?*const OwnedNode {
    return switch (object) {
        .node => |query| query.value,
        else => null,
    };
}

fn childCount(adapter: *Adapter, object: Object) i32 {
    return switch (object) {
        .application => saturatingI32(adapter.windows.count()),
        .cache => 0,
        .node => |query| saturatingI32(query.value.children.len),
    };
}

fn objectRole(object: Object) u32 {
    return atspiRole(objectRoleValue(object));
}

fn objectRoleValue(object: Object) api.Role {
    return switch (object) {
        .application => .application,
        .cache => .none,
        .node => |query| query.value.role,
    };
}

fn atspiRole(role: api.Role) u32 {
    return switch (role) {
        .none => 67,
        .application => 75,
        .window => 23,
        .group => 99,
        .button => 43,
        .checkbox => 7,
        .radio => 44,
        .switch_control => 130,
        .slider => 51,
        .progress_indicator => 42,
        .text => 61,
        .text_field, .search_field => 79,
        .static_text => 116,
        .heading => 83,
        .link => 88,
        .image => 27,
        .list => 31,
        .list_item => 32,
        .tree => 65,
        .tree_item => 91,
        .grid => 55,
        .row => 90,
        .cell => 56,
        .menu => 33,
        .menu_item => 35,
        .menu_item_checkbox => 8,
        .menu_item_radio => 45,
        .tab_list => 38,
        .tab => 37,
        .tab_panel => 39,
        .toolbar => 63,
        .tooltip => 64,
        .dialog => 16,
        .alert => 2,
        .separator => 50,
        .scroll_view => 49,
        .canvas => 6,
    };
}

fn roleName(role: api.Role) []const u8 {
    return switch (role) {
        .none => "unknown",
        .application => "application",
        .window => "frame",
        .group => "grouping",
        .button => "push button",
        .checkbox => "check box",
        .radio => "radio button",
        .switch_control => "switch",
        .slider => "slider",
        .progress_indicator => "progress bar",
        .text => "text",
        .text_field, .search_field => "entry",
        .static_text => "static",
        .heading => "heading",
        .link => "link",
        .image => "image",
        .list => "list",
        .list_item => "list item",
        .tree => "tree",
        .tree_item => "tree item",
        .grid => "table",
        .row => "table row",
        .cell => "table cell",
        .menu => "menu",
        .menu_item => "menu item",
        .menu_item_checkbox => "check menu item",
        .menu_item_radio => "radio menu item",
        .tab_list => "page tab list",
        .tab => "page tab",
        .tab_panel => "panel",
        .toolbar => "tool bar",
        .tooltip => "tool tip",
        .dialog => "dialog",
        .alert => "alert",
        .separator => "separator",
        .scroll_view => "scroll pane",
        .canvas => "canvas",
    };
}

fn supportsInterface(node: *const OwnedNode, interface: InterfaceKind) bool {
    return switch (interface) {
        .action => node.actions.len != 0,
        .text => switch (node.role) {
            .text, .text_field, .search_field, .static_text, .heading, .link => true,
            else => node.selection != null,
        },
        .value => node.range_min != null or node.range_max != null or node.range_value != null,
    };
}

fn supportsAction(node: *const OwnedNode, requested: api.Action) bool {
    for (node.actions) |action| if (action == requested) return true;
    return false;
}

fn textContent(node: *const OwnedNode) []const u8 {
    return switch (node.role) {
        .text, .static_text, .heading => if (node.value.len != 0) node.value else node.label,
        else => node.value,
    };
}

fn rangeIncrement(node: *const OwnedNode) f64 {
    const minimum = node.range_min orelse return 0;
    const maximum = node.range_max orelse return 0;
    if (!std.math.isFinite(minimum) or !std.math.isFinite(maximum) or maximum <= minimum) return 0;
    return (maximum - minimum) / 100;
}

fn appendInterfaces(writer: *wire.Writer, object: Object) Error!void {
    const array = try writer.beginArray(4);
    switch (object) {
        .application => {
            try writer.string(accessible_interface);
            try writer.string(application_interface);
        },
        .cache => try writer.string(cache_interface),
        .node => |query| {
            try writer.string(accessible_interface);
            try writer.string(component_interface);
            if (supportsInterface(query.value, .action)) try writer.string(action_interface);
            if (supportsInterface(query.value, .text)) try writer.string(text_interface);
            if (supportsInterface(query.value, .value)) try writer.string(value_interface);
        },
    }
    try writer.endArray(array);
}

fn appendStateSet(writer: *wire.Writer, optional_node: ?*const OwnedNode) Error!void {
    var state: u64 = 0;
    if (optional_node) |node| {
        setState(&state, 8, !node.disabled);
        setState(&state, 24, !node.disabled);
        setState(&state, 25, !node.hidden);
        setState(&state, 30, !node.hidden);
        setState(&state, 4, node.checked orelse false);
        setState(&state, 41, node.checked != null);
        setState(&state, 5, if (node.expanded) |expanded| !expanded else false);
        setState(&state, 9, node.expanded != null);
        setState(&state, 10, node.expanded orelse false);
        setState(&state, 11, supportsAction(node, .focus));
        setState(&state, 12, node.focused);
        setState(&state, 17, node.multiline);
        setState(&state, 26, supportsInterface(node, .text) and !node.multiline);
        setState(&state, 22, node.role == .list_item or node.role == .tree_item or node.role == .tab or node.role == .row or node.role == .cell);
        setState(&state, 23, node.selected);
        setState(&state, 38, supportsInterface(node, .text));
        setState(&state, 42, supportsAction(node, .show_menu));
        setState(&state, 7, supportsAction(node, .set_value) and supportsInterface(node, .text));
        setState(&state, 43, (supportsInterface(node, .text) or supportsInterface(node, .value)) and !supportsAction(node, .set_value));
        setState(&state, 19, !node.hidden);
    } else {
        setState(&state, 1, true);
        setState(&state, 8, true);
        setState(&state, 24, true);
        setState(&state, 25, true);
        setState(&state, 30, true);
    }
    const array = try writer.beginArray(4);
    try writer.u32(@truncate(state));
    try writer.u32(@truncate(state >> 32));
    try writer.endArray(array);
}

fn setState(state: *u64, bit: u6, enabled: bool) void {
    if (enabled) state.* |= @as(u64, 1) << bit;
}

fn appendAttributes(writer: *wire.Writer, node: ?*const OwnedNode) Error!void {
    const array = try writer.beginArray(8);
    try writer.beginStruct();
    try writer.string("toolkit");
    try writer.string("zigui");
    if (node) |value| if (value.password) {
        try writer.beginStruct();
        try writer.string("password");
        try writer.string("true");
    };
    try writer.endArray(array);
}

fn appendEmptyStringMap(writer: *wire.Writer) Error!void {
    const array = try writer.beginArray(8);
    try writer.endArray(array);
}

fn actionAt(node: *const OwnedNode, index: i32) ?api.Action {
    if (index < 0 or @as(usize, @intCast(index)) >= node.actions.len) return null;
    return node.actions[@intCast(index)];
}

fn actionName(action: api.Action) []const u8 {
    return switch (action) {
        .focus => "focus",
        .blur => "blur",
        .activate => "click",
        .increment => "increment",
        .decrement => "decrement",
        .show_menu => "show-menu",
        .scroll_up => "scroll-up",
        .scroll_down => "scroll-down",
        .scroll_left => "scroll-left",
        .scroll_right => "scroll-right",
        .set_value => "set-value",
        .set_selection => "set-selection",
    };
}

fn actionLocalizedName(action: api.Action) []const u8 {
    return switch (action) {
        .activate => "Activate",
        .show_menu => "Show menu",
        .scroll_up => "Scroll up",
        .scroll_down => "Scroll down",
        .scroll_left => "Scroll left",
        .scroll_right => "Scroll right",
        .set_value => "Set value",
        .set_selection => "Set selection",
        else => actionName(action),
    };
}

fn actionDescription(action: api.Action) []const u8 {
    return switch (action) {
        .focus => "Moves keyboard focus to this element",
        .blur => "Moves keyboard focus away from this element",
        .activate => "Activates this element",
        .increment => "Increases this element's value",
        .decrement => "Decreases this element's value",
        .show_menu => "Shows this element's menu",
        .scroll_up => "Scrolls this element upward",
        .scroll_down => "Scrolls this element downward",
        .scroll_left => "Scrolls this element left",
        .scroll_right => "Scrolls this element right",
        .set_value => "Changes this element's value",
        .set_selection => "Changes this element's text selection",
    };
}

fn saturatingI32(value: anytype) i32 {
    const converted: u128 = @intCast(value);
    return @intCast(@min(converted, std.math.maxInt(i32)));
}

fn roundI32(value: f32) i32 {
    if (!std.math.isFinite(value)) return 0;
    const limited = std.math.clamp(value, @as(f32, @floatFromInt(std.math.minInt(i32))), @as(f32, @floatFromInt(std.math.maxInt(i32))));
    return @intFromFloat(@round(limited));
}

const ScalarRange = struct {
    byte_start: usize,
    byte_end: usize,
    scalar_start: usize,
    scalar_end: usize,
};

fn scalarCount(value: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset < value.len) : (count += 1) {
        const width = std.unicode.utf8ByteSequenceLength(value[offset]) catch return count;
        if (offset + width > value.len) return count;
        offset += width;
    }
    return count;
}

fn byteOffsetForScalar(value: []const u8, requested: usize) usize {
    var byte_offset: usize = 0;
    var scalar_offset: usize = 0;
    while (byte_offset < value.len and scalar_offset < requested) : (scalar_offset += 1) {
        const width = std.unicode.utf8ByteSequenceLength(value[byte_offset]) catch return byte_offset;
        if (byte_offset + width > value.len) return byte_offset;
        byte_offset += width;
    }
    return byte_offset;
}

fn scalarOffsetForByte(value: []const u8, requested: usize) usize {
    const limit = @min(requested, value.len);
    var byte_offset: usize = 0;
    var scalar_offset: usize = 0;
    while (byte_offset < limit) : (scalar_offset += 1) {
        const width = std.unicode.utf8ByteSequenceLength(value[byte_offset]) catch return scalar_offset;
        if (byte_offset + width > limit) return scalar_offset;
        byte_offset += width;
    }
    return scalar_offset;
}

fn scalarAt(value: []const u8, requested: usize) ?u32 {
    const offset = byteOffsetForScalar(value, requested);
    if (offset >= value.len) return null;
    const width = std.unicode.utf8ByteSequenceLength(value[offset]) catch return null;
    if (offset + width > value.len) return null;
    return std.unicode.utf8Decode(value[offset..][0..width]) catch null;
}

fn normalizedScalarRange(value: []const u8, start_source: i32, end_source: i32) ScalarRange {
    const count = scalarCount(value);
    const start: usize = if (start_source <= 0) 0 else @min(@as(usize, @intCast(start_source)), count);
    const end: usize = if (end_source < 0) count else @min(@as(usize, @intCast(end_source)), count);
    const low = @min(start, end);
    const high = @max(start, end);
    return .{
        .byte_start = byteOffsetForScalar(value, low),
        .byte_end = byteOffsetForScalar(value, high),
        .scalar_start = low,
        .scalar_end = high,
    };
}

fn legacyBoundaryGranularity(boundary: u32) u32 {
    return switch (boundary) {
        0 => 0,
        1, 2 => 1,
        3, 4 => 2,
        5, 6 => 3,
        else => 0,
    };
}

fn textRangeAt(value: []const u8, offset_source: i32, granularity: u32) ScalarRange {
    const count = scalarCount(value);
    if (offset_source < 0 or @as(usize, @intCast(offset_source)) >= count) {
        const edge = if (offset_source < 0) 0 else count;
        const byte = byteOffsetForScalar(value, edge);
        return .{ .byte_start = byte, .byte_end = byte, .scalar_start = edge, .scalar_end = edge };
    }
    const target: usize = @intCast(offset_source);
    if (granularity == 0) return normalizedScalarRange(value, offset_source, offset_source + 1);
    const target_byte = byteOffsetForScalar(value, target);
    var start = target_byte;
    var end = nextScalarOffset(value, target_byte);
    switch (granularity) {
        1 => {
            const target_class = wordClass(scalarAtByte(value, target_byte));
            while (start != 0) {
                const previous = previousScalarOffset(value, start);
                if (wordClass(scalarAtByte(value, previous)) != target_class) break;
                start = previous;
            }
            while (end < value.len and wordClass(scalarAtByte(value, end)) == target_class) end = nextScalarOffset(value, end);
        },
        2 => {
            while (start != 0) {
                const previous = previousScalarOffset(value, start);
                const scalar = scalarAtByte(value, previous);
                if (isSentenceBoundary(scalar)) break;
                start = previous;
            }
            while (end < value.len) {
                const scalar = scalarAtByte(value, end);
                end = nextScalarOffset(value, end);
                if (isSentenceBoundary(scalar)) break;
            }
        },
        3 => {
            while (start != 0) {
                const previous = previousScalarOffset(value, start);
                if (scalarAtByte(value, previous) == '\n') break;
                start = previous;
            }
            while (end < value.len) {
                const scalar = scalarAtByte(value, end);
                end = nextScalarOffset(value, end);
                if (scalar == '\n') break;
            }
        },
        else => {
            while (start != 0) {
                const previous = previousScalarOffset(value, start);
                if (scalarAtByte(value, previous) == '\n' and previous != 0 and scalarAtByte(value, previousScalarOffset(value, previous)) == '\n') break;
                start = previous;
            }
            while (end < value.len) {
                const scalar = scalarAtByte(value, end);
                end = nextScalarOffset(value, end);
                if (scalar == '\n' and end < value.len and scalarAtByte(value, end) == '\n') {
                    end = nextScalarOffset(value, end);
                    break;
                }
            }
        },
    }
    return .{
        .byte_start = start,
        .byte_end = end,
        .scalar_start = scalarOffsetForByte(value, start),
        .scalar_end = scalarOffsetForByte(value, end),
    };
}

fn scalarAtByte(value: []const u8, offset: usize) u21 {
    if (offset >= value.len) return 0;
    const width = std.unicode.utf8ByteSequenceLength(value[offset]) catch return 0;
    if (offset + width > value.len) return 0;
    return std.unicode.utf8Decode(value[offset..][0..width]) catch 0;
}

fn nextScalarOffset(value: []const u8, offset: usize) usize {
    if (offset >= value.len) return value.len;
    const width = std.unicode.utf8ByteSequenceLength(value[offset]) catch return value.len;
    return @min(value.len, offset + width);
}

fn previousScalarOffset(value: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var result = offset - 1;
    while (result != 0 and value[result] & 0xc0 == 0x80) result -= 1;
    return result;
}

const WordClass = enum { word, whitespace, punctuation };

fn wordClass(scalar: u21) WordClass {
    if (scalar == 0 or scalar == ' ' or scalar == '\t' or scalar == '\r' or scalar == '\n' or scalar == 0x00a0) return .whitespace;
    if ((scalar >= 'a' and scalar <= 'z') or (scalar >= 'A' and scalar <= 'Z') or (scalar >= '0' and scalar <= '9') or
        scalar == '_' or scalar >= 0x80) return .word;
    return .punctuation;
}

fn isSentenceBoundary(scalar: u21) bool {
    return scalar == '.' or scalar == '!' or scalar == '?' or scalar == '\n' or scalar == 0x2029;
}

fn introspectionFor(object: Object) []const u8 {
    return switch (object) {
        .application => application_introspection,
        .cache => cache_introspection,
        .node => node_introspection,
    };
}

const common_introspection =
    \\  <interface name="org.freedesktop.DBus.Properties">
    \\    <method name="Get"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="out" type="v"/></method>
    \\    <method name="GetAll"><arg direction="in" type="s"/><arg direction="out" type="a{sv}"/></method>
    \\    <method name="Set"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="in" type="v"/></method>
    \\  </interface>
    \\  <interface name="org.freedesktop.DBus.Introspectable"><method name="Introspect"><arg direction="out" type="s"/></method></interface>
    \\  <interface name="org.freedesktop.DBus.Peer"><method name="Ping"/><method name="GetMachineId"><arg direction="out" type="s"/></method></interface>
;

const accessible_introspection =
    \\  <interface name="org.a11y.atspi.Accessible">
    \\    <property name="version" type="u" access="read"/><property name="Name" type="s" access="read"/><property name="Description" type="s" access="read"/>
    \\    <property name="Parent" type="(so)" access="read"/><property name="ChildCount" type="i" access="read"/><property name="Locale" type="s" access="read"/>
    \\    <property name="AccessibleId" type="s" access="read"/><property name="HelpText" type="s" access="read"/>
    \\    <method name="GetChildAtIndex"><arg direction="in" type="i"/><arg direction="out" type="(so)"/></method>
    \\    <method name="GetChildren"><arg direction="out" type="a(so)"/></method><method name="GetIndexInParent"><arg direction="out" type="i"/></method>
    \\    <method name="GetRelationSet"><arg direction="out" type="a(ua(so))"/></method><method name="GetRole"><arg direction="out" type="u"/></method>
    \\    <method name="GetRoleName"><arg direction="out" type="s"/></method><method name="GetLocalizedRoleName"><arg direction="out" type="s"/></method>
    \\    <method name="GetState"><arg direction="out" type="au"/></method><method name="GetAttributes"><arg direction="out" type="a{ss}"/></method>
    \\    <method name="GetApplication"><arg direction="out" type="(so)"/></method><method name="GetInterfaces"><arg direction="out" type="as"/></method>
    \\  </interface>
;

const application_introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
++ common_introspection ++ accessible_introspection ++
    \\  <interface name="org.a11y.atspi.Application">
    \\    <property name="ToolkitName" type="s" access="read"/><property name="Version" type="s" access="read"/><property name="ToolkitVersion" type="s" access="read"/>
    \\    <property name="AtspiVersion" type="s" access="read"/><property name="InterfaceVersion" type="u" access="read"/><property name="Id" type="i" access="readwrite"/>
    \\    <method name="GetLocale"><arg direction="in" type="u"/><arg direction="out" type="s"/></method><method name="GetApplicationBusAddress"><arg direction="out" type="s"/></method>
    \\  </interface>
    \\</node>
;

const node_introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
++ common_introspection ++ accessible_introspection ++
    \\  <interface name="org.a11y.atspi.Action">
    \\    <property name="version" type="u" access="read"/><property name="NActions" type="i" access="read"/>
    \\    <method name="GetDescription"><arg direction="in" type="i"/><arg direction="out" type="s"/></method><method name="GetName"><arg direction="in" type="i"/><arg direction="out" type="s"/></method>
    \\    <method name="GetLocalizedName"><arg direction="in" type="i"/><arg direction="out" type="s"/></method><method name="GetKeyBinding"><arg direction="in" type="i"/><arg direction="out" type="s"/></method>
    \\    <method name="GetActions"><arg direction="out" type="a(sss)"/></method><method name="DoAction"><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Component">
    \\    <property name="version" type="u" access="read"/><method name="Contains"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="in" type="u"/><arg direction="out" type="b"/></method>
    \\    <method name="GetAccessibleAtPoint"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="in" type="u"/><arg direction="out" type="(so)"/></method>
    \\    <method name="GetExtents"><arg direction="in" type="u"/><arg direction="out" type="(iiii)"/></method><method name="GetPosition"><arg direction="in" type="u"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\    <method name="GetSize"><arg direction="out" type="i"/><arg direction="out" type="i"/></method><method name="GetLayer"><arg direction="out" type="u"/></method>
    \\    <method name="GetMDIZOrder"><arg direction="out" type="n"/></method><method name="GrabFocus"><arg direction="out" type="b"/></method><method name="GetAlpha"><arg direction="out" type="d"/></method>
    \\    <method name="ScrollTo"><arg direction="in" type="u"/><arg direction="out" type="b"/></method><method name="ScrollToPoint"><arg direction="in" type="u"/><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Text">
    \\    <property name="version" type="u" access="read"/><property name="CharacterCount" type="i" access="read"/><property name="CaretOffset" type="i" access="read"/>
    \\    <method name="GetStringAtOffset"><arg direction="in" type="i"/><arg direction="in" type="u"/><arg direction="out" type="s"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\    <method name="GetText"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="out" type="s"/></method><method name="SetCaretOffset"><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\    <method name="GetCharacterAtOffset"><arg direction="in" type="i"/><arg direction="out" type="i"/></method><method name="GetNSelections"><arg direction="out" type="i"/></method>
    \\    <method name="GetSelection"><arg direction="in" type="i"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\    <method name="AddSelection"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="out" type="b"/></method><method name="RemoveSelection"><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\    <method name="SetSelection"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="out" type="b"/></method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Value">
    \\    <property name="version" type="u" access="read"/><property name="MinimumValue" type="d" access="read"/><property name="MaximumValue" type="d" access="read"/>
    \\    <property name="MinimumIncrement" type="d" access="read"/><property name="CurrentValue" type="d" access="readwrite"/><property name="Text" type="s" access="read"/>
    \\  </interface>
    \\</node>
;

const cache_introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
++ common_introspection ++
    \\  <interface name="org.a11y.atspi.Cache"><property name="version" type="u" access="read"/><method name="GetItems"><arg direction="out" type="a((so)(so)(so)iiassusau)"/></method>
    \\    <signal name="AddAccessible"><arg type="((so)(so)(so)iiassusau)"/></signal><signal name="RemoveAccessible"><arg type="(so)"/></signal></interface>
    \\</node>
;
