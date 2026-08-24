const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const scene_abi = @import("../scene/abi.zig");
const scene = @import("../scene/scene.zig");

pub const Limits = struct {
    maximum_bytes: usize = 16 * 1024 * 1024,
    maximum_elements: usize = 250_000,
    maximum_path_commands: usize = 4_000_000,
    maximum_gradients: usize = 16_384,
    maximum_gradient_stops: usize = 131_072,
    maximum_dash_values: usize = 65_536,
    maximum_nesting: usize = 256,
};

pub const Fit = enum { contain, cover, fill, none };
pub const GradientUnits = enum { object_bounding_box, user_space };
pub const LineCap = enum { butt, round, square };
pub const LineJoin = enum { miter, round, bevel };

const Paint = union(enum) {
    none,
    color: geometry.Color,
    gradient: []const u8,
};

const State = struct {
    fill: Paint = .{ .color = .black },
    stroke: Paint = .none,
    color: geometry.Color = .black,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    opacity: f32 = 1,
    stroke_width: f32 = 1,
    line_cap: LineCap = .butt,
    line_join: LineJoin = .miter,
    miter_limit: f32 = 4,
    dash_array: []const f32 = &.{},
    dash_offset: f32 = 0,
    fill_rule: scene_abi.FillRule = .non_zero,
    transform: geometry.Affine2D = .identity,
    displayed: bool = true,
    visibility_visible: bool = true,
    paintable: bool = true,

    fn rendered(self: State) bool {
        return self.displayed and self.visibility_visible;
    }
};

const OpacityLayer = struct {
    scope: u32,
    instance: u32,
    opacity: f32,
};

const Shape = struct {
    commands: []const scene_abi.PathVertex,
    bounds: geometry.Rect,
    state: State,
    opacity_layers: []const OpacityLayer,
};

const Gradient = struct {
    id: []const u8,
    href: []const u8,
    kind: Kind,
    units: GradientUnits,
    units_specified: bool,
    transform: geometry.Affine2D,
    transform_specified: bool,
    coordinates: [6]f32,
    coordinate_mask: u8,
    coordinate_percent_mask: u8,
    stops: []const scene_abi.GradientStop,

    const Kind = enum { linear, radial };
};

const GradientBuilder = struct {
    id: []const u8 = "",
    href: []const u8 = "",
    kind: Gradient.Kind,
    units: GradientUnits = .object_bounding_box,
    units_specified: bool = false,
    transform: geometry.Affine2D = .identity,
    transform_specified: bool = false,
    coordinates: [6]f32,
    coordinate_mask: u8 = 0,
    coordinate_percent_mask: u8,
    stops: std.ArrayList(scene_abi.GradientStop) = .empty,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    resident_bytes: usize,
    width: f32,
    height: f32,
    view_box: geometry.Rect,
    shapes: []const Shape,
    gradients: []const Gradient,

    pub fn parse(backing_allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) Error!Document {
        if (bytes.len == 0 or bytes.len > limits.maximum_bytes or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidSvg;
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const source = try allocator.dupe(u8, bytes);
        var parser: Parser = .{ .source = source, .allocator = allocator, .limits = limits };
        const parsed = try parser.parse();
        const resident_bytes = arena.queryCapacity();
        return .{
            .arena = arena,
            .source = source,
            .resident_bytes = resident_bytes,
            .width = parsed.width,
            .height = parsed.height,
            .view_box = parsed.view_box,
            .shapes = parsed.shapes,
            .gradients = parsed.gradients,
        };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn intrinsicSize(self: *const Document) geometry.Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn residentBytes(self: *const Document) usize {
        return self.resident_bytes;
    }

    pub fn paint(self: *const Document, builder: *scene.Builder, bounds: geometry.Rect, fit: Fit) Error!void {
        if (bounds.isEmpty() or self.view_box.isEmpty()) return;
        const document_transform = fitTransform(self.view_box, bounds, fit);
        if (!finiteTransform(document_transform)) return error.InvalidSvg;
        var active_layers: []const OpacityLayer = &.{};
        var active_count: usize = 0;
        defer while (active_count != 0) {
            builder.popLayer() catch {};
            active_count -= 1;
        };
        for (self.shapes) |shape| {
            if (!shape.state.rendered() or shape.commands.len == 0) continue;
            var common: usize = 0;
            while (common < active_layers.len and common < shape.opacity_layers.len and sameOpacityLayer(active_layers[common], shape.opacity_layers[common])) : (common += 1) {}
            while (active_count > common) {
                try builder.popLayer();
                active_count -= 1;
            }
            for (shape.opacity_layers[common..]) |layer| {
                _ = try builder.pushLayer(layer.opacity, .normal, .identity);
                active_count += 1;
            }
            active_layers = shape.opacity_layers;
            const transform = geometry.Affine2D.mul(document_transform, shape.state.transform);
            if (!finiteTransform(transform)) return error.InvalidSvg;
            const vertices = try transformPath(builder.scene.allocator, shape.commands, transform);
            defer builder.scene.allocator.free(vertices);
            const transformed_bounds = transform.transformRectBounds(shape.bounds);
            if (!finiteRect(transformed_bounds)) return error.InvalidSvg;
            if (std.meta.activeTag(shape.state.fill) != .none) {
                const material_id = try self.material(builder, shape.state.fill, shape.bounds, transform, shape.state.fill_opacity);
                const fallback = paintColor(shape.state.fill, shape.state.fill_opacity);
                try builder.path(.{
                    .vertex_start = 0,
                    .vertex_count = 0,
                    .fill_rule = @backingInt(shape.state.fill_rule),
                    .color = fallback,
                    .bounds = transformed_bounds,
                }, vertices, material_id);
            }
            if (std.meta.activeTag(shape.state.stroke) != .none and shape.state.stroke_width > 0) {
                const scale = transformScale(transform);
                const stroke_width = shape.state.stroke_width * scale;
                const material_id = try self.material(builder, shape.state.stroke, shape.bounds, transform, shape.state.stroke_opacity);
                const fallback = paintColor(shape.state.stroke, shape.state.stroke_opacity);
                try strokePath(
                    builder,
                    vertices,
                    stroke_width,
                    shape.state.line_cap,
                    shape.state.line_join,
                    shape.state.miter_limit,
                    shape.state.dash_array,
                    shape.state.dash_offset,
                    scale,
                    fallback,
                    material_id,
                );
            }
        }
        while (active_count != 0) {
            try builder.popLayer();
            active_count -= 1;
        }
        active_layers = &.{};
    }

    fn material(
        self: *const Document,
        builder: *scene.Builder,
        paint_value: Paint,
        object_bounds: geometry.Rect,
        object_transform: geometry.Affine2D,
        opacity: f32,
    ) Error!?u32 {
        return switch (paint_value) {
            .none, .color => null,
            .gradient => |id| blk: {
                const gradient = self.findGradient(id) orelse return error.Unsupported;
                if (gradient.stops.len == 0) break :blk null;
                const stops = try builder.scene.allocator.alloc(scene_abi.GradientStop, gradient.stops.len);
                defer builder.scene.allocator.free(stops);
                for (gradient.stops, 0..) |stop, index| {
                    stops[index] = stop;
                    stops[index].color.a *= opacity;
                }
                const units_to_local = if (gradient.units == .object_bounding_box)
                    geometry.Affine2D.mul(
                        geometry.Affine2D.translation(object_bounds.origin),
                        geometry.Affine2D.scale(object_bounds.size.width, object_bounds.size.height),
                    )
                else
                    geometry.Affine2D.identity;
                const gradient_to_world = geometry.Affine2D.mul(
                    object_transform,
                    geometry.Affine2D.mul(units_to_local, gradient.transform),
                );
                if (!finiteTransform(gradient_to_world)) return error.InvalidSvg;
                var coordinates = gradient.coordinates;
                if (gradient.units == .user_space) {
                    const radius_base = normalizedDiagonal(self.view_box.size);
                    if (!std.math.isFinite(radius_base)) return error.InvalidSvg;
                    inline for (0..6) |index| if (gradient.coordinate_percent_mask & (@as(u8, 1) << index) != 0) {
                        coordinates[index] = if (gradient.kind == .radial and (index == 2 or index == 5))
                            coordinates[index] * radius_base
                        else switch (index) {
                            0, 2, 3 => self.view_box.origin.x + coordinates[index] * self.view_box.size.width,
                            1, 4 => self.view_box.origin.y + coordinates[index] * self.view_box.size.height,
                            5 => coordinates[index] * radius_base,
                            else => unreachable,
                        };
                    };
                }
                for (coordinates) |coordinate| if (!std.math.isFinite(coordinate))
                    return error.InvalidSvg;
                break :blk switch (gradient.kind) {
                    .linear => try builder.linearGradientMaterial(
                        gradient_to_world.transformPoint(.{ .x = coordinates[0], .y = coordinates[1] }),
                        gradient_to_world.transformPoint(.{ .x = coordinates[2], .y = coordinates[3] }),
                        stops,
                    ),
                    .radial => blk2: {
                        const inverse = gradient_to_world.inverse() orelse break :blk2 null;
                        const end_center: geometry.Point = .{ .x = coordinates[0], .y = coordinates[1] };
                        const end_radius = @max(coordinates[2], 0.0001);
                        var start_center: geometry.Point = .{ .x = coordinates[3], .y = coordinates[4] };
                        const start_radius = std.math.clamp(coordinates[5], 0, end_radius);
                        const center_delta = start_center.sub(end_center);
                        const distance = @sqrt(center_delta.x * center_delta.x + center_delta.y * center_delta.y);
                        const maximum_distance = @max(0, end_radius - start_radius) * 0.99999;
                        if (distance > maximum_distance and distance > 0.000001) {
                            const scale = maximum_distance / distance;
                            start_center = .{
                                .x = end_center.x + center_delta.x * scale,
                                .y = end_center.y + center_delta.y * scale,
                            };
                        }
                        break :blk2 try builder.conicalGradientMaterial(
                            start_center,
                            start_radius,
                            end_center,
                            end_radius,
                            inverse,
                            stops,
                        );
                    },
                };
            },
        };
    }

    fn findGradient(self: *const Document, id: []const u8) ?*const Gradient {
        for (self.gradients) |*gradient| if (std.mem.eql(u8, gradient.id, id)) return gradient;
        return null;
    }
};

const Parsed = struct {
    width: f32,
    height: f32,
    view_box: geometry.Rect,
    shapes: []const Shape,
    gradients: []const Gradient,
};

const Element = struct {
    name: []const u8,
    state: State,
    opacity_layers: []const OpacityLayer = &.{},
    definition_id: []const u8 = "",
    prototype_start: usize = 0,
    definition_parent_transform: geometry.Affine2D = .identity,
    definition_parent_layer_depth: usize = 0,
    symbol_viewport: ?SymbolViewport = null,
};

const Use = struct {
    href: []const u8,
    state: State,
    opacity_layers: []const OpacityLayer,
    offset: geometry.Point,
    width: ?f32,
    height: ?f32,
};

const OutputItem = union(enum) { shape: Shape, use: Use };

const Definition = struct {
    id: []const u8,
    prototype_start: usize,
    prototype_count: usize,
    inverse_parent_transform: ?geometry.Affine2D,
    parent_layer_depth: usize,
    symbol_viewport: ?SymbolViewport,
};

const SymbolViewport = struct {
    view_box: geometry.Rect,
    aspect: PreserveAspect = .{},
};

const PreserveAspect = struct {
    x: Alignment = .mid,
    y: Alignment = .mid,
    mode: Mode = .meet,
    stretch: bool = false,

    const Alignment = enum { min, mid, max };
    const Mode = enum { meet, slice };
};

const Parser = struct {
    source: []const u8,
    allocator: std.mem.Allocator,
    limits: Limits,
    cursor: usize = 0,
    elements_seen: usize = 0,
    commands_seen: usize = 0,
    stops_seen: usize = 0,
    dash_values_seen: usize = 0,
    width: f32 = 300,
    height: f32 = 150,
    view_box: ?geometry.Rect = null,
    root_seen: bool = false,
    next_opacity_scope: u32 = 1,
    next_opacity_instance: u32 = 1,

    fn parse(self: *Parser) Error!Parsed {
        var output_items: std.ArrayList(OutputItem) = .empty;
        var prototype_items: std.ArrayList(OutputItem) = .empty;
        var definitions: std.ArrayList(Definition) = .empty;
        var gradients: std.ArrayList(Gradient) = .empty;
        var stack: std.ArrayList(Element) = .empty;
        try stack.append(self.allocator, .{ .name = "", .state = .{} });
        var current_gradient: ?GradientBuilder = null;
        while (try self.nextTag()) |tag| {
            if (tag.closing) {
                if (stack.items.len <= 1 or !std.mem.eql(u8, stack.items[stack.items.len - 1].name, tag.name)) return error.InvalidSvg;
                if (current_gradient != null and (std.mem.eql(u8, tag.name, "linearGradient") or std.mem.eql(u8, tag.name, "radialGradient"))) {
                    try self.finishGradient(&gradients, &current_gradient.?);
                    current_gradient = null;
                }
                try self.finishDefinition(&definitions, stack.items[stack.items.len - 1], prototype_items.items.len);
                _ = stack.pop();
                continue;
            }
            self.elements_seen += 1;
            if (self.elements_seen > self.limits.maximum_elements) return error.BudgetExceeded;
            const parent = stack.items[stack.items.len - 1];
            const parent_state = parent.state;
            var state = parent_state;
            state.opacity = 1;
            try self.applyAttributes(&state, tag.attributes);
            if (isDefinitionContainer(tag.name)) state.paintable = false;
            const opacity_layers = try self.elementOpacityLayers(parent.opacity_layers, state.opacity);
            const definition_id = if (!std.mem.eql(u8, tag.name, "linearGradient") and !std.mem.eql(u8, tag.name, "radialGradient"))
                attribute(tag.attributes, "id") orelse ""
            else
                "";
            const symbol_viewport = if (std.mem.eql(u8, tag.name, "symbol"))
                try self.parseSymbolViewport(tag.attributes)
            else
                null;
            const element: Element = .{
                .name = tag.name,
                .state = state,
                .opacity_layers = opacity_layers,
                .definition_id = definition_id,
                .prototype_start = prototype_items.items.len,
                .definition_parent_transform = parent_state.transform,
                .definition_parent_layer_depth = parent.opacity_layers.len,
                .symbol_viewport = symbol_viewport,
            };
            if (std.mem.eql(u8, tag.name, "svg")) {
                if (self.root_seen or stack.items.len != 1) return error.Unsupported;
                self.root_seen = true;
                try self.parseRoot(tag.attributes);
            } else if (!self.root_seen) return error.InvalidSvg;
            if (std.mem.eql(u8, tag.name, "linearGradient") or std.mem.eql(u8, tag.name, "radialGradient")) {
                if (current_gradient != null) return error.InvalidSvg;
                current_gradient = try self.beginGradient(tag.name, tag.attributes);
            } else if (std.mem.eql(u8, tag.name, "stop")) {
                if (current_gradient) |*gradient| try self.appendStop(gradient, tag.attributes, state);
            } else if (state.rendered() and isShape(tag.name)) {
                if (try self.shape(tag.name, tag.attributes, state, opacity_layers)) |value| {
                    const item: OutputItem = .{ .shape = value };
                    try prototype_items.append(self.allocator, item);
                    if (state.paintable) try output_items.append(self.allocator, item);
                }
            } else if (state.rendered() and std.mem.eql(u8, tag.name, "use")) {
                const use = try self.parseUse(tag.attributes, state, opacity_layers);
                const item: OutputItem = .{ .use = use };
                try prototype_items.append(self.allocator, item);
                if (state.paintable) try output_items.append(self.allocator, item);
            } else if (state.rendered() and state.paintable and isUnsupportedVisualElement(tag.name)) {
                return error.Unsupported;
            }
            if (!tag.self_closing) {
                if (stack.items.len >= self.limits.maximum_nesting) return error.BudgetExceeded;
                try stack.append(self.allocator, element);
            } else {
                if (current_gradient != null and (std.mem.eql(u8, tag.name, "linearGradient") or std.mem.eql(u8, tag.name, "radialGradient"))) {
                    try self.finishGradient(&gradients, &current_gradient.?);
                    current_gradient = null;
                }
                try self.finishDefinition(&definitions, element, prototype_items.items.len);
            }
        }
        if (stack.items.len != 1) return error.InvalidSvg;
        if (!self.root_seen) return error.InvalidSvg;
        if (current_gradient) |*gradient| try self.finishGradient(&gradients, gradient);
        try self.resolveGradients(gradients.items);
        const shapes = try self.expandOutput(output_items.items, prototype_items.items, definitions.items);
        const view_box = self.view_box orelse geometry.Rect.fromXYWH(0, 0, self.width, self.height);
        if (view_box.isEmpty()) return error.InvalidSvg;
        return .{
            .width = if (self.width > 0) self.width else view_box.size.width,
            .height = if (self.height > 0) self.height else view_box.size.height,
            .view_box = view_box,
            .shapes = shapes,
            .gradients = try gradients.toOwnedSlice(self.allocator),
        };
    }

    fn elementOpacityLayers(self: *Parser, parent: []const OpacityLayer, opacity: f32) Error![]const OpacityLayer {
        if (opacity == 1) return parent;
        if (self.next_opacity_scope == std.math.maxInt(u32)) return error.BudgetExceeded;
        const result = try self.allocator.alloc(OpacityLayer, parent.len + 1);
        @memcpy(result[0..parent.len], parent);
        result[parent.len] = .{ .scope = self.next_opacity_scope, .instance = 0, .opacity = opacity };
        self.next_opacity_scope += 1;
        return result;
    }

    fn parseUse(self: *Parser, attributes: []const Attribute, state: State, opacity_layers: []const OpacityLayer) Error!Use {
        const raw = attribute(attributes, "href") orelse attribute(attributes, "xlink:href") orelse return error.InvalidSvg;
        const reference = std.mem.trim(u8, raw, " \t\r\n\"'");
        if (reference.len < 2 or reference[0] != '#') return error.Unsupported;
        const width = if (attribute(attributes, "width")) |value| try parseLength(value, self.width) else null;
        const height = if (attribute(attributes, "height")) |value| try parseLength(value, self.height) else null;
        if ((width != null and width.? < 0) or (height != null and height.? < 0)) return error.InvalidSvg;
        return .{
            .href = try self.allocator.dupe(u8, reference[1..]),
            .state = state,
            .opacity_layers = opacity_layers,
            .offset = .{
                .x = try parseLength(attribute(attributes, "x") orelse "0", self.width),
                .y = try parseLength(attribute(attributes, "y") orelse "0", self.height),
            },
            .width = width,
            .height = height,
        };
    }

    fn parseSymbolViewport(self: *Parser, attributes: []const Attribute) Error!?SymbolViewport {
        _ = self;
        const raw = attribute(attributes, "viewBox") orelse return null;
        return .{
            .view_box = try parseViewBox(raw),
            .aspect = if (attribute(attributes, "preserveAspectRatio")) |value| try parsePreserveAspect(value) else .{},
        };
    }

    fn finishDefinition(self: *Parser, definitions: *std.ArrayList(Definition), element: Element, prototype_end: usize) Error!void {
        if (element.definition_id.len == 0) return;
        if (prototype_end < element.prototype_start) return error.InvalidSvg;
        for (definitions.items) |definition| if (std.mem.eql(u8, definition.id, element.definition_id)) return error.InvalidSvg;
        try definitions.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, element.definition_id),
            .prototype_start = element.prototype_start,
            .prototype_count = prototype_end - element.prototype_start,
            .inverse_parent_transform = element.definition_parent_transform.inverse(),
            .parent_layer_depth = element.definition_parent_layer_depth,
            .symbol_viewport = element.symbol_viewport,
        });
    }

    fn expandOutput(
        self: *Parser,
        items: []const OutputItem,
        prototypes: []const OutputItem,
        definitions: []const Definition,
    ) Error![]const Shape {
        var output: std.ArrayList(Shape) = .empty;
        var ancestry: std.ArrayList(usize) = .empty;
        var instantiated_commands: usize = 0;
        for (items) |item| switch (item) {
            .shape => |shape_value| try self.appendDirectShape(&output, shape_value, &instantiated_commands),
            .use => |use| try self.expandUse(
                &output,
                prototypes,
                definitions,
                use,
                .identity,
                &.{},
                0,
                0,
                &ancestry,
                &instantiated_commands,
            ),
        };
        return output.toOwnedSlice(self.allocator);
    }

    fn appendDirectShape(
        self: *Parser,
        output: *std.ArrayList(Shape),
        source: Shape,
        instantiated_commands: *usize,
    ) Error!void {
        try self.accountInstantiatedShape(output.items.len, source.commands.len, instantiated_commands);
        try output.append(self.allocator, source);
    }

    fn expandUse(
        self: *Parser,
        output: *std.ArrayList(Shape),
        prototypes: []const OutputItem,
        definitions: []const Definition,
        use: Use,
        prefix: geometry.Affine2D,
        outer_layers: []const OpacityLayer,
        containing_parent_depth: usize,
        containing_instance: u32,
        ancestry: *std.ArrayList(usize),
        instantiated_commands: *usize,
    ) Error!void {
        if (!use.state.rendered()) return;
        var selected: ?usize = null;
        for (definitions, 0..) |definition, index| if (std.mem.eql(u8, definition.id, use.href)) {
            selected = index;
            break;
        };
        const definition_index = selected orelse return error.InvalidSvg;
        for (ancestry.items) |ancestor| if (ancestor == definition_index) return error.InvalidSvg;
        if (ancestry.items.len >= self.limits.maximum_nesting) return error.BudgetExceeded;
        try ancestry.append(self.allocator, definition_index);
        defer _ = ancestry.pop();

        const definition = definitions[definition_index];
        const inverse_parent = definition.inverse_parent_transform orelse return error.InvalidSvg;
        if (definition.prototype_start > prototypes.len or definition.prototype_count > prototypes.len - definition.prototype_start) return error.InvalidSvg;
        const use_layers = try self.instantiateLayers(
            outer_layers,
            use.opacity_layers,
            containing_parent_depth,
            containing_instance,
        );
        var instance_transform = geometry.Affine2D.translation(use.offset);
        if (definition.symbol_viewport) |viewport| {
            const width = use.width orelse self.width;
            const height = use.height orelse self.height;
            if (!(width > 0) or !(height > 0)) return;
            instance_transform = geometry.Affine2D.mul(
                instance_transform,
                viewBoxTransform(viewport.view_box, .{ .width = width, .height = height }, viewport.aspect),
            );
        }
        const use_transform = geometry.Affine2D.mul(
            prefix,
            geometry.Affine2D.mul(use.state.transform, instance_transform),
        );
        const definition_prefix = geometry.Affine2D.mul(use_transform, inverse_parent);
        if (!finiteTransform(use_transform) or !finiteTransform(definition_prefix))
            return error.InvalidSvg;
        if (self.next_opacity_instance == std.math.maxInt(u32)) return error.BudgetExceeded;
        const definition_instance = self.next_opacity_instance;
        self.next_opacity_instance += 1;
        for (prototypes[definition.prototype_start..][0..definition.prototype_count]) |item| switch (item) {
            .shape => |shape_value| try self.appendInstantiatedShape(
                output,
                shape_value,
                definition_prefix,
                use_layers,
                definition.parent_layer_depth,
                definition_instance,
                instantiated_commands,
            ),
            .use => |nested| try self.expandUse(
                output,
                prototypes,
                definitions,
                nested,
                definition_prefix,
                use_layers,
                definition.parent_layer_depth,
                definition_instance,
                ancestry,
                instantiated_commands,
            ),
        };
    }

    fn appendInstantiatedShape(
        self: *Parser,
        output: *std.ArrayList(Shape),
        source: Shape,
        prefix: geometry.Affine2D,
        outer_layers: []const OpacityLayer,
        parent_layer_depth: usize,
        instance: u32,
        instantiated_commands: *usize,
    ) Error!void {
        try self.accountInstantiatedShape(output.items.len, source.commands.len, instantiated_commands);
        var instantiated = source;
        instantiated.state.transform = geometry.Affine2D.mul(prefix, source.state.transform);
        if (!finiteTransform(instantiated.state.transform)) return error.InvalidSvg;
        instantiated.state.paintable = true;
        instantiated.opacity_layers = try self.instantiateLayers(outer_layers, source.opacity_layers, parent_layer_depth, instance);
        try output.append(self.allocator, instantiated);
    }

    fn instantiateLayers(
        self: *Parser,
        outer: []const OpacityLayer,
        source: []const OpacityLayer,
        parent_depth: usize,
        instance: u32,
    ) Error![]const OpacityLayer {
        if (parent_depth > source.len) return error.InvalidSvg;
        const relative = source[parent_depth..];
        if (relative.len == 0) return outer;
        const result = try self.allocator.alloc(OpacityLayer, outer.len + relative.len);
        @memcpy(result[0..outer.len], outer);
        for (relative, 0..) |layer, index| {
            result[outer.len + index] = layer;
            result[outer.len + index].instance = instance;
        }
        return result;
    }

    fn accountInstantiatedShape(
        self: *Parser,
        output_count: usize,
        command_count: usize,
        instantiated_commands: *usize,
    ) Error!void {
        if (output_count >= self.limits.maximum_elements) return error.BudgetExceeded;
        instantiated_commands.* = std.math.add(usize, instantiated_commands.*, command_count) catch return error.BudgetExceeded;
        if (instantiated_commands.* > self.limits.maximum_path_commands) return error.BudgetExceeded;
    }

    fn parseRoot(self: *Parser, attributes: []const Attribute) Error!void {
        if (attribute(attributes, "width")) |value| self.width = try parseLength(value, self.width);
        if (attribute(attributes, "height")) |value| self.height = try parseLength(value, self.height);
        if (self.width < 0 or self.height < 0) return error.InvalidSvg;
        if (attribute(attributes, "viewBox")) |value| {
            self.view_box = try parseViewBox(value);
        }
    }

    fn beginGradient(self: *Parser, name: []const u8, attributes: []const Attribute) Error!GradientBuilder {
        var result: GradientBuilder = .{
            .kind = if (std.mem.eql(u8, name, "linearGradient")) .linear else .radial,
            .coordinates = if (std.mem.eql(u8, name, "linearGradient")) .{ 0, 0, 1, 0, 0, 0 } else .{ 0.5, 0.5, 0.5, 0.5, 0.5, 0 },
            .coordinate_percent_mask = if (std.mem.eql(u8, name, "linearGradient")) 0b001111 else 0b111111,
        };
        result.id = try self.allocator.dupe(u8, attribute(attributes, "id") orelse "");
        if (attribute(attributes, "href") orelse attribute(attributes, "xlink:href")) |value| {
            const reference = std.mem.trim(u8, value, " \t\r\n\"'");
            if (reference.len < 2 or reference[0] != '#') return error.InvalidSvg;
            result.href = try self.allocator.dupe(u8, reference[1..]);
        }
        if (attribute(attributes, "gradientUnits")) |value| {
            result.units = if (std.mem.eql(u8, value, "userSpaceOnUse")) .user_space else if (std.mem.eql(u8, value, "objectBoundingBox")) .object_bounding_box else return error.InvalidSvg;
            result.units_specified = true;
        }
        if (attribute(attributes, "gradientTransform")) |value| {
            result.transform = try parseTransform(value);
            result.transform_specified = true;
        }
        if (attribute(attributes, "spreadMethod")) |value| if (!std.mem.eql(u8, value, "pad")) return error.Unsupported;
        const names = if (result.kind == .linear) [_][]const u8{ "x1", "y1", "x2", "y2", "", "" } else [_][]const u8{ "cx", "cy", "r", "fx", "fy", "fr" };
        for (names, 0..) |coordinate_name, index| if (coordinate_name.len != 0) if (attribute(attributes, coordinate_name)) |value| {
            const coordinate = try parseGradientCoordinate(value);
            const bit = @as(u8, 1) << @intCast(index);
            result.coordinates[index] = coordinate.value;
            result.coordinate_mask |= bit;
            if (coordinate.percent) result.coordinate_percent_mask |= bit else result.coordinate_percent_mask &= ~bit;
        };
        return result;
    }

    fn appendStop(self: *Parser, gradient: *GradientBuilder, attributes: []const Attribute, inherited: State) Error!void {
        self.stops_seen += 1;
        if (self.stops_seen > self.limits.maximum_gradient_stops) return error.BudgetExceeded;
        var offset: f32 = 0;
        if (attribute(attributes, "offset")) |value| offset = try parseCoordinate(value);
        var color = inherited.color;
        var opacity: f32 = 1;
        if (attribute(attributes, "stop-color")) |value| color = try parseColor(value, inherited.color);
        if (attribute(attributes, "stop-opacity")) |value| opacity = try parseUnit(value);
        if (attribute(attributes, "style")) |value| {
            var style_parser = StyleParser{ .bytes = value };
            while (try style_parser.next()) |declaration| {
                if (std.mem.eql(u8, declaration.name, "stop-color")) color = try parseColor(declaration.value, inherited.color);
                if (std.mem.eql(u8, declaration.name, "stop-opacity")) opacity = try parseUnit(declaration.value);
            }
        }
        color.a *= std.math.clamp(opacity, 0, 1);
        try gradient.stops.append(self.allocator, .{ .offset = std.math.clamp(offset, 0, 1), .color = color });
    }

    fn finishGradient(self: *Parser, gradients: *std.ArrayList(Gradient), builder: *GradientBuilder) Error!void {
        if (gradients.items.len >= self.limits.maximum_gradients) return error.BudgetExceeded;
        var previous_offset: f32 = 0;
        for (builder.stops.items) |*stop| {
            stop.offset = @max(previous_offset, stop.offset);
            previous_offset = stop.offset;
        }
        for (gradients.items) |gradient| if (builder.id.len != 0 and std.mem.eql(u8, gradient.id, builder.id)) return error.InvalidSvg;
        try gradients.append(self.allocator, .{
            .id = builder.id,
            .href = builder.href,
            .kind = builder.kind,
            .units = builder.units,
            .units_specified = builder.units_specified,
            .transform = builder.transform,
            .transform_specified = builder.transform_specified,
            .coordinates = builder.coordinates,
            .coordinate_mask = builder.coordinate_mask,
            .coordinate_percent_mask = builder.coordinate_percent_mask,
            .stops = try builder.stops.toOwnedSlice(self.allocator),
        });
    }

    fn resolveGradients(self: *Parser, gradients: []Gradient) Error!void {
        const states = try self.allocator.alloc(u8, gradients.len);
        @memset(states, 0);
        for (gradients, 0..) |_, index| try self.resolveGradient(gradients, states, index, 0);
    }

    fn resolveGradient(self: *Parser, gradients: []Gradient, states: []u8, index: usize, depth: usize) Error!void {
        if (states[index] == 2) return;
        if (states[index] == 1 or depth >= self.limits.maximum_nesting) return error.InvalidSvg;
        states[index] = 1;
        var gradient = &gradients[index];
        if (gradient.href.len != 0) {
            var reference_index: ?usize = null;
            for (gradients, 0..) |candidate, candidate_index| if (std.mem.eql(u8, candidate.id, gradient.href)) {
                reference_index = candidate_index;
                break;
            };
            const selected = reference_index orelse return error.InvalidSvg;
            try self.resolveGradient(gradients, states, selected, depth + 1);
            const reference = gradients[selected];
            if (reference.kind != gradient.kind) return error.InvalidSvg;
            if (!gradient.units_specified) gradient.units = reference.units;
            if (!gradient.transform_specified) gradient.transform = reference.transform;
            for (0..gradient.coordinates.len) |coordinate| {
                const bit = @as(u8, 1) << @intCast(coordinate);
                if (gradient.coordinate_mask & bit == 0 and reference.coordinate_mask & bit != 0) {
                    gradient.coordinates[coordinate] = reference.coordinates[coordinate];
                    gradient.coordinate_mask |= bit;
                    if (reference.coordinate_percent_mask & bit != 0)
                        gradient.coordinate_percent_mask |= bit
                    else
                        gradient.coordinate_percent_mask &= ~bit;
                }
            }
            if (gradient.stops.len == 0) gradient.stops = reference.stops;
        }
        if (gradient.kind == .radial) {
            if (gradient.coordinate_mask & (@as(u8, 1) << 3) == 0) gradient.coordinates[3] = gradient.coordinates[0];
            if (gradient.coordinate_mask & (@as(u8, 1) << 4) == 0) gradient.coordinates[4] = gradient.coordinates[1];
            if (gradient.coordinates[2] < 0 or gradient.coordinates[5] < 0) return error.InvalidSvg;
        }
        states[index] = 2;
    }

    fn applyAttributes(self: *Parser, state: *State, attributes: []const Attribute) Error!void {
        for (attributes) |entry| if (!std.mem.eql(u8, entry.name, "style")) try self.applyPresentation(state, entry.name, entry.value);
        if (attribute(attributes, "style")) |value| {
            var parser = StyleParser{ .bytes = value };
            while (try parser.next()) |declaration| try self.applyPresentation(state, declaration.name, declaration.value);
        }
    }

    fn applyPresentation(self: *Parser, state: *State, name: []const u8, value: []const u8) Error!void {
        if ((std.mem.eql(u8, name, "clip-path") or std.mem.eql(u8, name, "mask") or
            std.mem.eql(u8, name, "filter") or std.mem.eql(u8, name, "marker-start") or
            std.mem.eql(u8, name, "marker-mid") or std.mem.eql(u8, name, "marker-end")) and
            !std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "none")) return error.Unsupported;
        if (std.mem.eql(u8, name, "vector-effect") and !std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "none")) return error.Unsupported;
        if (std.mem.eql(u8, name, "fill")) state.fill = try self.parsePaint(value, state.color);
        if (std.mem.eql(u8, name, "stroke")) state.stroke = try self.parsePaint(value, state.color);
        if (std.mem.eql(u8, name, "color")) state.color = try parseColor(value, state.color);
        if (std.mem.eql(u8, name, "fill-opacity")) state.fill_opacity = std.math.clamp(try parseUnit(value), 0, 1);
        if (std.mem.eql(u8, name, "stroke-opacity")) state.stroke_opacity = std.math.clamp(try parseUnit(value), 0, 1);
        if (std.mem.eql(u8, name, "opacity")) state.opacity = std.math.clamp(try parseUnit(value), 0, 1);
        if (std.mem.eql(u8, name, "stroke-width")) state.stroke_width = @max(0, try parseLength(value, 1));
        if (std.mem.eql(u8, name, "stroke-linecap")) state.line_cap = std.meta.stringToEnum(LineCap, std.mem.trim(u8, value, " \t\r\n")) orelse return error.InvalidSvg;
        if (std.mem.eql(u8, name, "stroke-linejoin")) state.line_join = std.meta.stringToEnum(LineJoin, std.mem.trim(u8, value, " \t\r\n")) orelse return error.InvalidSvg;
        if (std.mem.eql(u8, name, "stroke-miterlimit")) state.miter_limit = @max(1, try parseLength(value, 1));
        if (std.mem.eql(u8, name, "stroke-dasharray")) state.dash_array = try self.parseDashArray(value);
        if (std.mem.eql(u8, name, "stroke-dashoffset")) state.dash_offset = try parseLength(value, 1);
        if (std.mem.eql(u8, name, "fill-rule")) {
            const rule = std.mem.trim(u8, value, " \t\r\n");
            state.fill_rule = if (std.mem.eql(u8, rule, "evenodd")) .even_odd else if (std.mem.eql(u8, rule, "nonzero")) .non_zero else return error.InvalidSvg;
        }
        if (std.mem.eql(u8, name, "display") and std.mem.eql(u8, std.mem.trim(u8, value, " \t\r\n"), "none")) state.displayed = false;
        if (std.mem.eql(u8, name, "visibility")) {
            const visibility = std.mem.trim(u8, value, " \t\r\n");
            if (std.mem.eql(u8, visibility, "visible")) state.visibility_visible = true else if (std.mem.eql(u8, visibility, "hidden") or std.mem.eql(u8, visibility, "collapse")) state.visibility_visible = false else return error.InvalidSvg;
        }
        if (std.mem.eql(u8, name, "transform")) {
            state.transform = geometry.Affine2D.mul(state.transform, try parseTransform(value));
            if (!finiteTransform(state.transform)) return error.InvalidSvg;
        }
    }

    fn parseDashArray(self: *Parser, value_raw: []const u8) Error![]const f32 {
        const value = std.mem.trim(u8, value_raw, " \t\r\n");
        if (std.mem.eql(u8, value, "none") or value.len == 0) return &.{};
        var parser = NumberParser{ .bytes = value };
        var values: std.ArrayList(f32) = .empty;
        while (parser.next()) |number| {
            if (number < 0) return error.InvalidSvg;
            self.dash_values_seen += 1;
            if (self.dash_values_seen > self.limits.maximum_dash_values) return error.BudgetExceeded;
            try values.append(self.allocator, number);
        }
        try parser.requireEnd();
        if (values.items.len == 0) return error.InvalidSvg;
        var total: f32 = 0;
        for (values.items) |number| {
            if (!std.math.isFinite(number)) return error.InvalidSvg;
            total += number;
            if (!std.math.isFinite(total)) return error.InvalidSvg;
        }
        if (!(total > 0)) return &.{};
        if (values.items.len % 2 == 0) return values.toOwnedSlice(self.allocator);
        const original = values.items.len;
        if (self.dash_values_seen + original > self.limits.maximum_dash_values) return error.BudgetExceeded;
        try values.ensureUnusedCapacity(self.allocator, original);
        for (values.items[0..original]) |number| values.appendAssumeCapacity(number);
        self.dash_values_seen += original;
        return values.toOwnedSlice(self.allocator);
    }

    fn parsePaint(self: *Parser, value_raw: []const u8, current_color: geometry.Color) Error!Paint {
        const value = std.mem.trim(u8, value_raw, " \t\r\n");
        if (std.mem.eql(u8, value, "none")) return .none;
        if (std.mem.startsWith(u8, value, "url(")) {
            const hash = std.mem.indexOfScalar(u8, value, '#') orelse return error.InvalidSvg;
            const close = std.mem.indexOfScalarPos(u8, value, hash, ')') orelse return error.InvalidSvg;
            if (std.mem.trim(u8, value[close + 1 ..], " \t\r\n").len != 0) return error.Unsupported;
            const id = std.mem.trim(u8, value[hash + 1 .. close], " \t\r\n\"'");
            if (id.len == 0) return error.InvalidSvg;
            return .{ .gradient = try self.allocator.dupe(u8, id) };
        }
        return .{ .color = try parseColor(value, current_color) };
    }

    fn shape(
        self: *Parser,
        name: []const u8,
        attributes: []const Attribute,
        state: State,
        opacity_layers: []const OpacityLayer,
    ) Error!?Shape {
        var commands: std.ArrayList(scene_abi.PathVertex) = .empty;
        if (std.mem.eql(u8, name, "path")) {
            const data = attribute(attributes, "d") orelse return null;
            try parsePath(self.allocator, data, &commands, self.limits.maximum_path_commands -| self.commands_seen);
        } else if (std.mem.eql(u8, name, "rect")) {
            try appendRect(self.allocator, attributes, &commands);
        } else if (std.mem.eql(u8, name, "circle") or std.mem.eql(u8, name, "ellipse")) {
            try appendEllipse(self.allocator, attributes, std.mem.eql(u8, name, "circle"), &commands);
        } else if (std.mem.eql(u8, name, "line")) {
            try appendLine(self.allocator, attributes, &commands);
        } else if (std.mem.eql(u8, name, "polyline") or std.mem.eql(u8, name, "polygon")) {
            try appendPoly(self.allocator, attributes, std.mem.eql(u8, name, "polygon"), &commands);
        }
        if (commands.items.len == 0) return null;
        try validatePathVertices(commands.items);
        self.commands_seen = std.math.add(usize, self.commands_seen, commands.items.len) catch return error.BudgetExceeded;
        if (self.commands_seen > self.limits.maximum_path_commands) return error.BudgetExceeded;
        return .{
            .bounds = pathBounds(commands.items),
            .commands = try commands.toOwnedSlice(self.allocator),
            .state = state,
            .opacity_layers = opacity_layers,
        };
    }

    fn nextTag(self: *Parser) Error!?Tag {
        while (self.cursor < self.source.len) {
            const start = std.mem.indexOfScalarPos(u8, self.source, self.cursor, '<') orelse return null;
            if (std.mem.startsWith(u8, self.source[start..], "<!--")) {
                const end = std.mem.indexOfPos(u8, self.source, start + 4, "-->") orelse return error.InvalidSvg;
                self.cursor = end + 3;
                continue;
            }
            if (start + 1 < self.source.len and (self.source[start + 1] == '?' or self.source[start + 1] == '!')) {
                if (self.source[start + 1] == '!') return error.Unsupported;
                const end = std.mem.indexOfPos(u8, self.source, start + 2, "?>") orelse return error.InvalidSvg;
                self.cursor = end + 2;
                continue;
            }
            const end = findTagEnd(self.source, start + 1) orelse return error.InvalidSvg;
            self.cursor = end + 1;
            return try parseTag(self.allocator, self.source[start + 1 .. end]);
        }
        return null;
    }
};

fn isDefinitionContainer(name: []const u8) bool {
    return std.mem.eql(u8, name, "defs") or std.mem.eql(u8, name, "symbol") or
        std.mem.eql(u8, name, "clipPath") or std.mem.eql(u8, name, "mask") or
        std.mem.eql(u8, name, "pattern") or std.mem.eql(u8, name, "marker") or
        std.mem.eql(u8, name, "linearGradient") or std.mem.eql(u8, name, "radialGradient");
}

fn isUnsupportedVisualElement(name: []const u8) bool {
    return std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "image") or
        std.mem.eql(u8, name, "foreignObject") or std.mem.eql(u8, name, "style");
}

const Attribute = struct { name: []const u8, value: []const u8 };
const Tag = struct { name: []const u8, attributes: []const Attribute, closing: bool, self_closing: bool };

fn parseTag(allocator: std.mem.Allocator, raw: []const u8) Error!Tag {
    var bytes = std.mem.trim(u8, raw, " \t\r\n");
    const closing = bytes.len != 0 and bytes[0] == '/';
    if (closing) bytes = std.mem.trimStart(u8, bytes[1..], " \t\r\n");
    const self_closing = bytes.len != 0 and bytes[bytes.len - 1] == '/';
    if (closing and self_closing) return error.InvalidSvg;
    if (self_closing) bytes = std.mem.trimEnd(u8, bytes[0 .. bytes.len - 1], " \t\r\n");
    var cursor: usize = 0;
    while (cursor < bytes.len and !std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
    if (cursor == 0) return error.InvalidSvg;
    const name = localName(bytes[0..cursor]);
    if (name.len == 0) return error.InvalidSvg;
    var attributes: std.ArrayList(Attribute) = .empty;
    while (cursor < bytes.len) {
        while (cursor < bytes.len and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
        if (cursor >= bytes.len) break;
        const name_start = cursor;
        while (cursor < bytes.len and !std.ascii.isWhitespace(bytes[cursor]) and bytes[cursor] != '=') cursor += 1;
        const attribute_name = localName(bytes[name_start..cursor]);
        if (attribute_name.len == 0 or closing) return error.InvalidSvg;
        for (attributes.items) |existing| if (std.mem.eql(u8, existing.name, attribute_name)) return error.InvalidSvg;
        while (cursor < bytes.len and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
        if (cursor >= bytes.len or bytes[cursor] != '=') return error.InvalidSvg;
        cursor += 1;
        while (cursor < bytes.len and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
        if (cursor >= bytes.len or (bytes[cursor] != '\'' and bytes[cursor] != '"')) return error.InvalidSvg;
        const quote = bytes[cursor];
        cursor += 1;
        const value_start = cursor;
        while (cursor < bytes.len and bytes[cursor] != quote) cursor += 1;
        if (cursor >= bytes.len) return error.InvalidSvg;
        try attributes.append(allocator, .{ .name = attribute_name, .value = bytes[value_start..cursor] });
        cursor += 1;
    }
    return .{ .name = name, .attributes = try attributes.toOwnedSlice(allocator), .closing = closing, .self_closing = self_closing };
}

fn findTagEnd(bytes: []const u8, start: usize) ?usize {
    var quote: ?u8 = null;
    for (bytes[start..], start..) |byte, index| {
        if (quote) |active| {
            if (byte == active) quote = null;
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '>') return index;
    }
    return null;
}

fn localName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |index| return name[index + 1 ..];
    return name;
}

fn attribute(attributes: []const Attribute, name: []const u8) ?[]const u8 {
    for (attributes) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

fn isShape(name: []const u8) bool {
    inline for (&.{ "path", "rect", "circle", "ellipse", "line", "polyline", "polygon" }) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

const StyleParser = struct {
    bytes: []const u8,
    cursor: usize = 0,
    fn next(self: *StyleParser) Error!?Attribute {
        while (self.cursor < self.bytes.len and (std.ascii.isWhitespace(self.bytes[self.cursor]) or self.bytes[self.cursor] == ';')) self.cursor += 1;
        if (self.cursor >= self.bytes.len) return null;
        const colon = std.mem.indexOfScalarPos(u8, self.bytes, self.cursor, ':') orelse return error.InvalidSvg;
        const end = std.mem.indexOfScalarPos(u8, self.bytes, colon + 1, ';') orelse self.bytes.len;
        defer self.cursor = end + @intFromBool(end < self.bytes.len);
        const result: Attribute = .{
            .name = std.mem.trim(u8, self.bytes[self.cursor..colon], " \t\r\n"),
            .value = std.mem.trim(u8, self.bytes[colon + 1 .. end], " \t\r\n"),
        };
        if (result.name.len == 0 or result.value.len == 0) return error.InvalidSvg;
        return result;
    }
};

const NumberParser = struct {
    bytes: []const u8,
    cursor: usize = 0,

    fn next(self: *NumberParser) ?f32 {
        while (self.cursor < self.bytes.len and (std.ascii.isWhitespace(self.bytes[self.cursor]) or self.bytes[self.cursor] == ',')) self.cursor += 1;
        if (self.cursor >= self.bytes.len) return null;
        const start = self.cursor;
        if (self.bytes[self.cursor] == '+' or self.bytes[self.cursor] == '-') self.cursor += 1;
        var digits = false;
        while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) : (self.cursor += 1) digits = true;
        if (self.cursor < self.bytes.len and self.bytes[self.cursor] == '.') {
            self.cursor += 1;
            while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) : (self.cursor += 1) digits = true;
        }
        if (!digits) return null;
        if (self.cursor < self.bytes.len and (self.bytes[self.cursor] == 'e' or self.bytes[self.cursor] == 'E')) {
            const exponent = self.cursor;
            self.cursor += 1;
            if (self.cursor < self.bytes.len and (self.bytes[self.cursor] == '+' or self.bytes[self.cursor] == '-')) self.cursor += 1;
            const exponent_digits = self.cursor;
            while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) self.cursor += 1;
            if (self.cursor == exponent_digits) self.cursor = exponent;
        }
        return std.fmt.parseFloat(f32, self.bytes[start..self.cursor]) catch null;
    }

    fn nextRequired(self: *NumberParser) Error!f32 {
        const value = self.next() orelse return error.InvalidSvg;
        if (!std.math.isFinite(value)) return error.InvalidSvg;
        return value;
    }

    fn requireEnd(self: *NumberParser) Error!void {
        while (self.cursor < self.bytes.len and (std.ascii.isWhitespace(self.bytes[self.cursor]) or self.bytes[self.cursor] == ',')) self.cursor += 1;
        if (self.cursor != self.bytes.len) return error.InvalidSvg;
    }
};

fn parseLength(value_raw: []const u8, percent_base: f32) Error!f32 {
    const value = std.mem.trim(u8, value_raw, " \t\r\n");
    if (value.len == 0 or value[0] == ',') return error.InvalidSvg;
    var parser = NumberParser{ .bytes = value };
    const number = try parser.nextRequired();
    const unit = std.mem.trim(u8, value[parser.cursor..], " \t\r\n");
    if (!std.math.isFinite(percent_base)) return error.InvalidSvg;
    const result = if (std.mem.eql(u8, unit, "%"))
        number * percent_base / 100
    else if (unit.len == 0 or std.mem.eql(u8, unit, "px"))
        number
    else if (std.mem.eql(u8, unit, "pt"))
        number * 96 / 72
    else if (std.mem.eql(u8, unit, "pc"))
        number * 16
    else if (std.mem.eql(u8, unit, "in"))
        number * 96
    else if (std.mem.eql(u8, unit, "cm"))
        number * 96 / 2.54
    else if (std.mem.eql(u8, unit, "mm"))
        number * 96 / 25.4
    else
        return error.Unsupported;
    if (!std.math.isFinite(result)) return error.InvalidSvg;
    return result;
}

fn parseViewBox(value: []const u8) Error!geometry.Rect {
    var numbers = NumberParser{ .bytes = value };
    const x = try numbers.nextRequired();
    const y = try numbers.nextRequired();
    const width = try numbers.nextRequired();
    const height = try numbers.nextRequired();
    try numbers.requireEnd();
    if (!(width > 0) or !(height > 0)) return error.InvalidSvg;
    const result = geometry.Rect.fromXYWH(x, y, width, height);
    if (!finiteRect(result)) return error.InvalidSvg;
    return result;
}

fn parsePreserveAspect(value_raw: []const u8) Error!PreserveAspect {
    var tokens = std.mem.tokenizeAny(u8, value_raw, " \t\r\n");
    const alignment = tokens.next() orelse return error.InvalidSvg;
    if (std.mem.eql(u8, alignment, "defer")) return error.Unsupported;
    if (std.mem.eql(u8, alignment, "none")) {
        if (tokens.next() != null) return error.InvalidSvg;
        return .{ .stretch = true };
    }
    var result: PreserveAspect = .{};
    if (alignment.len != 8 or alignment[0] != 'x' or alignment[4] != 'Y') return error.InvalidSvg;
    result.x = if (std.mem.eql(u8, alignment[1..4], "Min"))
        .min
    else if (std.mem.eql(u8, alignment[1..4], "Mid"))
        .mid
    else if (std.mem.eql(u8, alignment[1..4], "Max"))
        .max
    else
        return error.InvalidSvg;
    result.y = if (std.mem.eql(u8, alignment[5..8], "Min"))
        .min
    else if (std.mem.eql(u8, alignment[5..8], "Mid"))
        .mid
    else if (std.mem.eql(u8, alignment[5..8], "Max"))
        .max
    else
        return error.InvalidSvg;
    if (tokens.next()) |mode| {
        result.mode = if (std.mem.eql(u8, mode, "meet")) .meet else if (std.mem.eql(u8, mode, "slice")) return error.Unsupported else return error.InvalidSvg;
    }
    if (tokens.next() != null) return error.InvalidSvg;
    return result;
}

fn viewBoxTransform(source: geometry.Rect, viewport: geometry.Size, aspect: PreserveAspect) geometry.Affine2D {
    const sx = viewport.width / source.size.width;
    const sy = viewport.height / source.size.height;
    if (aspect.stretch) return .{
        .m11 = sx,
        .m22 = sy,
        .tx = -source.origin.x * sx,
        .ty = -source.origin.y * sy,
    };
    const scale = if (aspect.mode == .meet) @min(sx, sy) else @max(sx, sy);
    const remaining_x = viewport.width - source.size.width * scale;
    const remaining_y = viewport.height - source.size.height * scale;
    const align_x: f32 = switch (aspect.x) {
        .min => 0,
        .mid => 0.5,
        .max => 1,
    };
    const align_y: f32 = switch (aspect.y) {
        .min => 0,
        .mid => 0.5,
        .max => 1,
    };
    return .{
        .m11 = scale,
        .m22 = scale,
        .tx = remaining_x * align_x - source.origin.x * scale,
        .ty = remaining_y * align_y - source.origin.y * scale,
    };
}

fn parseCoordinate(value_raw: []const u8) Error!f32 {
    const value = std.mem.trim(u8, value_raw, " \t\r\n");
    if (value.len == 0) return error.InvalidSvg;
    const result = if (value[value.len - 1] == '%')
        (std.fmt.parseFloat(f32, std.mem.trimEnd(u8, value[0 .. value.len - 1], " \t\r\n")) catch return error.InvalidSvg) / 100
    else
        std.fmt.parseFloat(f32, value) catch return error.InvalidSvg;
    if (!std.math.isFinite(result)) return error.InvalidSvg;
    return result;
}

const GradientCoordinate = struct { value: f32, percent: bool };

fn parseGradientCoordinate(value_raw: []const u8) Error!GradientCoordinate {
    const value = std.mem.trim(u8, value_raw, " \t\r\n");
    if (value.len == 0) return error.InvalidSvg;
    const percent = value[value.len - 1] == '%';
    const number_bytes = if (percent) std.mem.trimEnd(u8, value[0 .. value.len - 1], " \t\r\n") else value;
    const number = std.fmt.parseFloat(f32, number_bytes) catch return error.InvalidSvg;
    if (!std.math.isFinite(number)) return error.InvalidSvg;
    return .{ .value = if (percent) number / 100 else number, .percent = percent };
}

fn parseUnit(value: []const u8) Error!f32 {
    return parseCoordinate(value);
}

fn parseColor(value_raw: []const u8, current: geometry.Color) Error!geometry.Color {
    const value = std.mem.trim(u8, value_raw, " \t\r\n");
    if (std.mem.eql(u8, value, "currentColor")) return current;
    if (value.len > 0 and value[0] == '#') return parseHexColor(value[1..]);
    if (std.mem.startsWith(u8, value, "rgb(")) {
        if (value.len < 5 or value[value.len - 1] != ')') return error.InvalidSvg;
        return parseRgbFunction(value[4 .. value.len - 1], false);
    }
    if (std.mem.startsWith(u8, value, "rgba(")) {
        if (value.len < 6 or value[value.len - 1] != ')') return error.InvalidSvg;
        return parseRgbFunction(value[5 .. value.len - 1], true);
    }
    inline for (named_colors) |entry| if (std.ascii.eqlIgnoreCase(value, entry.name)) return geometry.Color.rgba8(entry.r, entry.g, entry.b, entry.a);
    return error.InvalidSvg;
}

fn parseHexColor(value: []const u8) Error!geometry.Color {
    return switch (value.len) {
        3, 4 => geometry.Color.rgba8(
            try hexNibble(value[0]) * 17,
            try hexNibble(value[1]) * 17,
            try hexNibble(value[2]) * 17,
            if (value.len == 4) try hexNibble(value[3]) * 17 else 255,
        ),
        6, 8 => geometry.Color.rgba8(
            try hexByte(value[0..2]),
            try hexByte(value[2..4]),
            try hexByte(value[4..6]),
            if (value.len == 8) try hexByte(value[6..8]) else 255,
        ),
        else => error.InvalidSvg,
    };
}

fn parseRgbFunction(bytes: []const u8, alpha: bool) Error!geometry.Color {
    var parser = NumberParser{ .bytes = bytes };
    const r = try parser.nextRequired();
    const g = try parser.nextRequired();
    const b = try parser.nextRequired();
    const a = if (alpha) try parser.nextRequired() else 1;
    try parser.requireEnd();
    return geometry.Color.rgba(std.math.clamp(r / 255, 0, 1), std.math.clamp(g / 255, 0, 1), std.math.clamp(b / 255, 0, 1), std.math.clamp(a, 0, 1));
}

fn hexNibble(byte: u8) Error!u8 {
    return std.fmt.charToDigit(byte, 16) catch error.InvalidSvg;
}
fn hexByte(bytes: []const u8) Error!u8 {
    return (try hexNibble(bytes[0])) * 16 + try hexNibble(bytes[1]);
}

const NamedColor = struct { name: []const u8, r: u8, g: u8, b: u8, a: u8 = 255 };
const named_colors = [_]NamedColor{
    .{ .name = "black", .r = 0, .g = 0, .b = 0 },               .{ .name = "white", .r = 255, .g = 255, .b = 255 },
    .{ .name = "red", .r = 255, .g = 0, .b = 0 },               .{ .name = "green", .r = 0, .g = 128, .b = 0 },
    .{ .name = "blue", .r = 0, .g = 0, .b = 255 },              .{ .name = "yellow", .r = 255, .g = 255, .b = 0 },
    .{ .name = "cyan", .r = 0, .g = 255, .b = 255 },            .{ .name = "aqua", .r = 0, .g = 255, .b = 255 },
    .{ .name = "magenta", .r = 255, .g = 0, .b = 255 },         .{ .name = "fuchsia", .r = 255, .g = 0, .b = 255 },
    .{ .name = "gray", .r = 128, .g = 128, .b = 128 },          .{ .name = "grey", .r = 128, .g = 128, .b = 128 },
    .{ .name = "silver", .r = 192, .g = 192, .b = 192 },        .{ .name = "maroon", .r = 128, .g = 0, .b = 0 },
    .{ .name = "olive", .r = 128, .g = 128, .b = 0 },           .{ .name = "lime", .r = 0, .g = 255, .b = 0 },
    .{ .name = "teal", .r = 0, .g = 128, .b = 128 },            .{ .name = "navy", .r = 0, .g = 0, .b = 128 },
    .{ .name = "purple", .r = 128, .g = 0, .b = 128 },          .{ .name = "orange", .r = 255, .g = 165, .b = 0 },
    .{ .name = "transparent", .r = 0, .g = 0, .b = 0, .a = 0 },
};

fn sameOpacityLayer(a: OpacityLayer, b: OpacityLayer) bool {
    return a.scope == b.scope and a.instance == b.instance;
}

fn finiteTransform(value: geometry.Affine2D) bool {
    return std.math.isFinite(value.m11) and std.math.isFinite(value.m12) and
        std.math.isFinite(value.m21) and std.math.isFinite(value.m22) and
        std.math.isFinite(value.tx) and std.math.isFinite(value.ty);
}

fn parseTransform(bytes: []const u8) Error!geometry.Affine2D {
    var cursor: usize = 0;
    var result: geometry.Affine2D = .identity;
    while (cursor < bytes.len) {
        while (cursor < bytes.len and (std.ascii.isWhitespace(bytes[cursor]) or bytes[cursor] == ',')) cursor += 1;
        if (cursor >= bytes.len) break;
        const name_start = cursor;
        while (cursor < bytes.len and std.ascii.isAlphabetic(bytes[cursor])) cursor += 1;
        const name = bytes[name_start..cursor];
        while (cursor < bytes.len and std.ascii.isWhitespace(bytes[cursor])) cursor += 1;
        if (cursor >= bytes.len or bytes[cursor] != '(') return error.InvalidSvg;
        const end = std.mem.indexOfScalarPos(u8, bytes, cursor + 1, ')') orelse return error.InvalidSvg;
        var numbers = NumberParser{ .bytes = bytes[cursor + 1 .. end] };
        var transform: geometry.Affine2D = .identity;
        if (std.mem.eql(u8, name, "matrix")) {
            transform = .{
                .m11 = try numbers.nextRequired(),
                .m12 = try numbers.nextRequired(),
                .m21 = try numbers.nextRequired(),
                .m22 = try numbers.nextRequired(),
                .tx = try numbers.nextRequired(),
                .ty = try numbers.nextRequired(),
            };
            try numbers.requireEnd();
        } else if (std.mem.eql(u8, name, "translate")) {
            const x = try numbers.nextRequired();
            const y = numbers.next() orelse 0;
            if (!std.math.isFinite(y)) return error.InvalidSvg;
            transform = geometry.Affine2D.translation(.{ .x = x, .y = y });
            try numbers.requireEnd();
        } else if (std.mem.eql(u8, name, "scale")) {
            const x = try numbers.nextRequired();
            const y = numbers.next() orelse x;
            if (!std.math.isFinite(y)) return error.InvalidSvg;
            transform = geometry.Affine2D.scale(x, y);
            try numbers.requireEnd();
        } else if (std.mem.eql(u8, name, "rotate")) {
            const angle = try numbers.nextRequired() * std.math.pi / 180;
            const rotation: geometry.Affine2D = .{ .m11 = @cos(angle), .m12 = @sin(angle), .m21 = -@sin(angle), .m22 = @cos(angle) };
            if (numbers.next()) |x| {
                if (!std.math.isFinite(x)) return error.InvalidSvg;
                const y = try numbers.nextRequired();
                transform = rotation.around(.{ .x = x, .y = y });
            } else transform = rotation;
            try numbers.requireEnd();
        } else if (std.mem.eql(u8, name, "skewX")) {
            transform.m21 = @tan(try numbers.nextRequired() * std.math.pi / 180);
            try numbers.requireEnd();
        } else if (std.mem.eql(u8, name, "skewY")) {
            transform.m12 = @tan(try numbers.nextRequired() * std.math.pi / 180);
            try numbers.requireEnd();
        } else return error.InvalidSvg;
        if (!finiteTransform(transform)) return error.InvalidSvg;
        result = geometry.Affine2D.mul(result, transform);
        if (!finiteTransform(result)) return error.InvalidSvg;
        cursor = end + 1;
    }
    return result;
}

fn parsePath(allocator: std.mem.Allocator, bytes: []const u8, output: *std.ArrayList(scene_abi.PathVertex), budget: usize) Error!void {
    var parser = PathParser{ .bytes = bytes, .allocator = allocator, .output = output, .budget = budget };
    try parser.parse();
}

const PathParser = struct {
    bytes: []const u8,
    allocator: std.mem.Allocator,
    output: *std.ArrayList(scene_abi.PathVertex),
    budget: usize,
    cursor: usize = 0,
    command: u8 = 0,
    current: geometry.Point = .{},
    contour_start: geometry.Point = .{},
    previous_cubic: ?geometry.Point = null,
    previous_quadratic: ?geometry.Point = null,

    fn parse(self: *PathParser) Error!void {
        while (true) {
            self.skipSeparators();
            if (self.cursor >= self.bytes.len) break;
            if (std.ascii.isAlphabetic(self.bytes[self.cursor])) {
                self.command = self.bytes[self.cursor];
                self.cursor += 1;
            } else if (self.command == 0) return error.InvalidSvg;
            const relative = std.ascii.isLower(self.command);
            const upper = std.ascii.toUpper(self.command);
            if (upper != 'M' and upper != 'Z' and !self.hasNumber()) return error.InvalidSvg;
            switch (upper) {
                'M' => {
                    var position = try self.point(relative);
                    try self.emit(.move_to, position, .{});
                    self.current = position;
                    self.contour_start = position;
                    self.command = if (relative) 'l' else 'L';
                    while (self.hasNumber()) {
                        position = try self.point(relative);
                        try self.lineTo(position);
                    }
                },
                'L' => while (self.hasNumber()) try self.lineTo(try self.point(relative)),
                'H' => while (self.hasNumber()) {
                    var position = self.current;
                    const value = try self.number();
                    position.x = if (relative) position.x + value else value;
                    try self.lineTo(position);
                },
                'V' => while (self.hasNumber()) {
                    var position = self.current;
                    const value = try self.number();
                    position.y = if (relative) position.y + value else value;
                    try self.lineTo(position);
                },
                'C' => while (self.hasNumber()) {
                    const control1 = try self.point(relative);
                    const control2 = try self.point(relative);
                    const end = try self.point(relative);
                    try flattenCubic(self.allocator, self.output, self.current, control1, control2, end, 0, self.budget);
                    self.current = end;
                    self.previous_cubic = control2;
                    self.previous_quadratic = null;
                },
                'S' => while (self.hasNumber()) {
                    const control1 = if (self.previous_cubic) |previous| reflect(previous, self.current) else self.current;
                    const control2 = try self.point(relative);
                    const end = try self.point(relative);
                    try flattenCubic(self.allocator, self.output, self.current, control1, control2, end, 0, self.budget);
                    self.current = end;
                    self.previous_cubic = control2;
                    self.previous_quadratic = null;
                },
                'Q' => while (self.hasNumber()) {
                    const control = try self.point(relative);
                    const end = try self.point(relative);
                    try self.emit(.quadratic_to, end, control);
                    self.current = end;
                    self.previous_quadratic = control;
                    self.previous_cubic = null;
                },
                'T' => while (self.hasNumber()) {
                    const control = if (self.previous_quadratic) |previous| reflect(previous, self.current) else self.current;
                    const end = try self.point(relative);
                    try self.emit(.quadratic_to, end, control);
                    self.current = end;
                    self.previous_quadratic = control;
                    self.previous_cubic = null;
                },
                'A' => while (self.hasNumber()) {
                    const rx = @abs(try self.number());
                    const ry = @abs(try self.number());
                    const rotation = try self.number();
                    const large_value = try self.number();
                    const sweep_value = try self.number();
                    if ((large_value != 0 and large_value != 1) or (sweep_value != 0 and sweep_value != 1)) return error.InvalidSvg;
                    const large = large_value == 1;
                    const sweep = sweep_value == 1;
                    const end = try self.point(relative);
                    try flattenArc(self.allocator, self.output, self.current, end, rx, ry, rotation, large, sweep, self.budget);
                    self.current = end;
                    self.previous_cubic = null;
                    self.previous_quadratic = null;
                },
                'Z' => {
                    try self.emit(.close, self.contour_start, .{});
                    self.current = self.contour_start;
                    self.command = 0;
                    self.previous_cubic = null;
                    self.previous_quadratic = null;
                },
                else => return error.InvalidSvg,
            }
        }
    }

    fn lineTo(self: *PathParser, position: geometry.Point) Error!void {
        try self.emit(.line_to, position, .{});
        self.current = position;
        self.previous_cubic = null;
        self.previous_quadratic = null;
    }

    fn emit(self: *PathParser, kind: scene_abi.PathCommand, position: geometry.Point, control: geometry.Point) Error!void {
        if (!finitePoint(position) or !finitePoint(control)) return error.InvalidSvg;
        if (self.output.items.len >= self.budget) return error.BudgetExceeded;
        try self.output.append(self.allocator, .{ .position = position, .control = control, .kind = @backingInt(kind) });
    }

    fn point(self: *PathParser, relative: bool) Error!geometry.Point {
        var result: geometry.Point = .{ .x = try self.number(), .y = try self.number() };
        if (relative) result = result.add(self.current);
        if (!finitePoint(result)) return error.InvalidSvg;
        return result;
    }

    fn number(self: *PathParser) Error!f32 {
        self.skipSeparators();
        const start = self.cursor;
        if (self.cursor < self.bytes.len and (self.bytes[self.cursor] == '+' or self.bytes[self.cursor] == '-')) self.cursor += 1;
        var digits = false;
        while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) : (self.cursor += 1) digits = true;
        if (self.cursor < self.bytes.len and self.bytes[self.cursor] == '.') {
            self.cursor += 1;
            while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) : (self.cursor += 1) digits = true;
        }
        if (!digits) return error.InvalidSvg;
        if (self.cursor < self.bytes.len and (self.bytes[self.cursor] == 'e' or self.bytes[self.cursor] == 'E')) {
            self.cursor += 1;
            if (self.cursor < self.bytes.len and (self.bytes[self.cursor] == '+' or self.bytes[self.cursor] == '-')) self.cursor += 1;
            const exponent = self.cursor;
            while (self.cursor < self.bytes.len and std.ascii.isDigit(self.bytes[self.cursor])) self.cursor += 1;
            if (self.cursor == exponent) return error.InvalidSvg;
        }
        const result = std.fmt.parseFloat(f32, self.bytes[start..self.cursor]) catch return error.InvalidSvg;
        if (!std.math.isFinite(result)) return error.InvalidSvg;
        return result;
    }

    fn hasNumber(self: *PathParser) bool {
        self.skipSeparators();
        return self.cursor < self.bytes.len and !std.ascii.isAlphabetic(self.bytes[self.cursor]);
    }

    fn skipSeparators(self: *PathParser) void {
        while (self.cursor < self.bytes.len and (std.ascii.isWhitespace(self.bytes[self.cursor]) or self.bytes[self.cursor] == ',')) self.cursor += 1;
    }
};

fn appendRect(allocator: std.mem.Allocator, attributes: []const Attribute, output: *std.ArrayList(scene_abi.PathVertex)) Error!void {
    const x = try parseLength(attribute(attributes, "x") orelse "0", 1);
    const y = try parseLength(attribute(attributes, "y") orelse "0", 1);
    const width = try parseLength(attribute(attributes, "width") orelse return, 1);
    const height = try parseLength(attribute(attributes, "height") orelse return, 1);
    if (!(width > 0) or !(height > 0)) return;
    var rx = try parseLength(attribute(attributes, "rx") orelse "0", width);
    var ry = try parseLength(attribute(attributes, "ry") orelse "0", height);
    if (rx > 0 and ry == 0) ry = rx;
    if (ry > 0 and rx == 0) rx = ry;
    rx = @min(rx, width / 2);
    ry = @min(ry, height / 2);
    if (rx == 0 or ry == 0) {
        try output.appendSlice(allocator, &.{
            vertex(.move_to, x, y),          vertex(.line_to, x + width, y), vertex(.line_to, x + width, y + height),
            vertex(.line_to, x, y + height), vertex(.close, x, y),
        });
        return;
    }
    try output.append(allocator, vertex(.move_to, x + rx, y));
    try output.append(allocator, vertex(.line_to, x + width - rx, y));
    try appendArcCorner(allocator, output, .{ .x = x + width - rx, .y = y + ry }, rx, ry, -std.math.pi / 2.0, 0);
    try output.append(allocator, vertex(.line_to, x + width, y + height - ry));
    try appendArcCorner(allocator, output, .{ .x = x + width - rx, .y = y + height - ry }, rx, ry, 0, std.math.pi / 2.0);
    try output.append(allocator, vertex(.line_to, x + rx, y + height));
    try appendArcCorner(allocator, output, .{ .x = x + rx, .y = y + height - ry }, rx, ry, std.math.pi / 2.0, std.math.pi);
    try output.append(allocator, vertex(.line_to, x, y + ry));
    try appendArcCorner(allocator, output, .{ .x = x + rx, .y = y + ry }, rx, ry, std.math.pi, std.math.pi * 1.5);
    try output.append(allocator, vertex(.close, x + rx, y));
}

fn appendEllipse(allocator: std.mem.Allocator, attributes: []const Attribute, circle: bool, output: *std.ArrayList(scene_abi.PathVertex)) Error!void {
    const cx = try parseLength(attribute(attributes, "cx") orelse "0", 1);
    const cy = try parseLength(attribute(attributes, "cy") orelse "0", 1);
    const rx = try parseLength(attribute(attributes, if (circle) "r" else "rx") orelse return, 1);
    const ry = if (circle) rx else try parseLength(attribute(attributes, "ry") orelse return, 1);
    if (!(rx > 0) or !(ry > 0)) return;
    try output.append(allocator, vertex(.move_to, cx + rx, cy));
    const segments: usize = 64;
    for (1..segments + 1) |index| {
        const angle = std.math.tau * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
        try output.append(allocator, vertex(.line_to, cx + @cos(angle) * rx, cy + @sin(angle) * ry));
    }
    try output.append(allocator, vertex(.close, cx + rx, cy));
}

fn appendLine(allocator: std.mem.Allocator, attributes: []const Attribute, output: *std.ArrayList(scene_abi.PathVertex)) Error!void {
    const x1 = try parseLength(attribute(attributes, "x1") orelse "0", 1);
    const y1 = try parseLength(attribute(attributes, "y1") orelse "0", 1);
    const x2 = try parseLength(attribute(attributes, "x2") orelse "0", 1);
    const y2 = try parseLength(attribute(attributes, "y2") orelse "0", 1);
    try output.appendSlice(allocator, &.{ vertex(.move_to, x1, y1), vertex(.line_to, x2, y2) });
}

fn appendPoly(allocator: std.mem.Allocator, attributes: []const Attribute, close: bool, output: *std.ArrayList(scene_abi.PathVertex)) Error!void {
    var numbers = NumberParser{ .bytes = attribute(attributes, "points") orelse return };
    var first: ?geometry.Point = null;
    while (numbers.next()) |x| {
        if (!std.math.isFinite(x)) return error.InvalidSvg;
        const y = try numbers.nextRequired();
        const point: geometry.Point = .{ .x = x, .y = y };
        if (first == null) {
            first = point;
            try output.append(allocator, vertex(.move_to, x, y));
        } else try output.append(allocator, vertex(.line_to, x, y));
    }
    try numbers.requireEnd();
    if (close and first != null) try output.append(allocator, vertex(.close, first.?.x, first.?.y));
}

fn vertex(kind: scene_abi.PathCommand, x: f32, y: f32) scene_abi.PathVertex {
    return .{ .position = .{ .x = x, .y = y }, .control = .{}, .kind = @backingInt(kind) };
}

fn appendArcCorner(allocator: std.mem.Allocator, output: *std.ArrayList(scene_abi.PathVertex), center: geometry.Point, rx: f32, ry: f32, start: f32, end: f32) Error!void {
    const segments: usize = 8;
    for (1..segments + 1) |index| {
        const amount = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
        const angle = start + (end - start) * amount;
        try output.append(allocator, vertex(.line_to, center.x + @cos(angle) * rx, center.y + @sin(angle) * ry));
    }
}

fn flattenCubic(allocator: std.mem.Allocator, output: *std.ArrayList(scene_abi.PathVertex), a: geometry.Point, b: geometry.Point, c: geometry.Point, d: geometry.Point, depth: u8, budget: usize) Error!void {
    if (!finitePoint(a) or !finitePoint(b) or !finitePoint(c) or !finitePoint(d))
        return error.InvalidSvg;
    const flatness = @max(pointLineDistance(b, a, d), pointLineDistance(c, a, d));
    if (flatness <= 0.15 or depth >= 14) {
        if (output.items.len >= budget) return error.BudgetExceeded;
        try output.append(allocator, vertex(.line_to, d.x, d.y));
        return;
    }
    const ab = midpoint(a, b);
    const bc = midpoint(b, c);
    const cd = midpoint(c, d);
    const abc = midpoint(ab, bc);
    const bcd = midpoint(bc, cd);
    const center = midpoint(abc, bcd);
    try flattenCubic(allocator, output, a, ab, abc, center, depth + 1, budget);
    try flattenCubic(allocator, output, center, bcd, cd, d, depth + 1, budget);
}

fn flattenArc(allocator: std.mem.Allocator, output: *std.ArrayList(scene_abi.PathVertex), start: geometry.Point, end: geometry.Point, raw_rx: f32, raw_ry: f32, rotation_degrees: f32, large: bool, sweep: bool, budget: usize) Error!void {
    if (!finitePoint(start) or !finitePoint(end) or !std.math.isFinite(raw_rx) or
        !std.math.isFinite(raw_ry) or !std.math.isFinite(rotation_degrees))
        return error.InvalidSvg;
    if (raw_rx <= 0 or raw_ry <= 0 or pointsEqual(start, end)) {
        if (output.items.len >= budget) return error.BudgetExceeded;
        try output.append(allocator, vertex(.line_to, end.x, end.y));
        return;
    }
    const phi = rotation_degrees * std.math.pi / 180;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);
    const dx = (start.x - end.x) / 2;
    const dy = (start.y - end.y) / 2;
    const x_prime = cos_phi * dx + sin_phi * dy;
    const y_prime = -sin_phi * dx + cos_phi * dy;
    var rx = raw_rx;
    var ry = raw_ry;
    const lambda = x_prime * x_prime / (rx * rx) + y_prime * y_prime / (ry * ry);
    if (!std.math.isFinite(lambda)) return error.InvalidSvg;
    if (lambda > 1) {
        const scale = @sqrt(lambda);
        rx *= scale;
        ry *= scale;
    }
    if (!std.math.isFinite(rx) or !std.math.isFinite(ry)) return error.InvalidSvg;
    const numerator = @max(0, rx * rx * ry * ry - rx * rx * y_prime * y_prime - ry * ry * x_prime * x_prime);
    const denominator = @max(0.000001, rx * rx * y_prime * y_prime + ry * ry * x_prime * x_prime);
    if (!std.math.isFinite(numerator) or !std.math.isFinite(denominator)) return error.InvalidSvg;
    const sign: f32 = if (large == sweep) -1 else 1;
    const coefficient = sign * @sqrt(numerator / denominator);
    const center_prime: geometry.Point = .{ .x = coefficient * rx * y_prime / ry, .y = -coefficient * ry * x_prime / rx };
    const center: geometry.Point = .{
        .x = cos_phi * center_prime.x - sin_phi * center_prime.y + (start.x + end.x) / 2,
        .y = sin_phi * center_prime.x + cos_phi * center_prime.y + (start.y + end.y) / 2,
    };
    const first: geometry.Point = .{ .x = (x_prime - center_prime.x) / rx, .y = (y_prime - center_prime.y) / ry };
    const second: geometry.Point = .{ .x = (-x_prime - center_prime.x) / rx, .y = (-y_prime - center_prime.y) / ry };
    if (!finitePoint(center_prime) or !finitePoint(center) or !finitePoint(first) or !finitePoint(second))
        return error.InvalidSvg;
    const start_angle = std.math.atan2(first.y, first.x);
    var delta = signedAngle(first, second);
    if (!std.math.isFinite(start_angle) or !std.math.isFinite(delta)) return error.InvalidSvg;
    if (!sweep and delta > 0) delta -= std.math.tau;
    if (sweep and delta < 0) delta += std.math.tau;
    const segments: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(delta) / (std.math.pi / 16.0)))));
    for (1..segments + 1) |index| {
        if (output.items.len >= budget) return error.BudgetExceeded;
        const angle = start_angle + delta * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segments));
        const x = rx * @cos(angle);
        const y = ry * @sin(angle);
        const point: geometry.Point = .{ .x = center.x + cos_phi * x - sin_phi * y, .y = center.y + sin_phi * x + cos_phi * y };
        if (!finitePoint(point)) return error.InvalidSvg;
        try output.append(allocator, vertex(.line_to, point.x, point.y));
    }
}

fn signedAngle(a: geometry.Point, b: geometry.Point) f32 {
    return std.math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y);
}
fn reflect(point: geometry.Point, around: geometry.Point) geometry.Point {
    return .{ .x = around.x * 2 - point.x, .y = around.y * 2 - point.y };
}
fn midpoint(a: geometry.Point, b: geometry.Point) geometry.Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}
fn pointsEqual(a: geometry.Point, b: geometry.Point) bool {
    return @abs(a.x - b.x) < 0.00001 and @abs(a.y - b.y) < 0.00001;
}
fn pointLineDistance(point: geometry.Point, start: geometry.Point, end: geometry.Point) f32 {
    const delta = end.sub(start);
    const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
    if (length <= 0.00001) return @sqrt((point.x - start.x) * (point.x - start.x) + (point.y - start.y) * (point.y - start.y));
    return @abs(delta.y * point.x - delta.x * point.y + end.x * start.y - end.y * start.x) / length;
}

fn pathBounds(commands: []const scene_abi.PathVertex) geometry.Rect {
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    for (commands) |command| {
        min_x = @min(min_x, command.position.x);
        min_y = @min(min_y, command.position.y);
        max_x = @max(max_x, command.position.x);
        max_y = @max(max_y, command.position.y);
        if (command.kind == @backingInt(scene_abi.PathCommand.quadratic_to)) {
            min_x = @min(min_x, command.control.x);
            min_y = @min(min_y, command.control.y);
            max_x = @max(max_x, command.control.x);
            max_y = @max(max_y, command.control.y);
        }
    }
    if (!std.math.isFinite(min_x)) return .{};
    return geometry.Rect.fromXYWH(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn validatePathVertices(commands: []const scene_abi.PathVertex) Error!void {
    for (commands) |command| {
        _ = std.enums.fromInt(scene_abi.PathCommand, command.kind) orelse return error.InvalidSvg;
        if (!finitePoint(command.position) or !finitePoint(command.control)) return error.InvalidSvg;
    }
}

fn finitePoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y);
}

fn finiteRect(value: geometry.Rect) bool {
    return finitePoint(value.origin) and std.math.isFinite(value.size.width) and
        std.math.isFinite(value.size.height) and value.size.width >= 0 and value.size.height >= 0 and
        std.math.isFinite(value.maxX()) and std.math.isFinite(value.maxY());
}

fn transformPath(allocator: std.mem.Allocator, commands: []const scene_abi.PathVertex, transform: geometry.Affine2D) Error![]scene_abi.PathVertex {
    const result = try allocator.alloc(scene_abi.PathVertex, commands.len);
    errdefer allocator.free(result);
    for (commands, 0..) |command, index| {
        result[index] = command;
        result[index].position = transform.transformPoint(command.position);
        result[index].control = transform.transformPoint(command.control);
        if (!finitePoint(result[index].position) or !finitePoint(result[index].control))
            return error.InvalidSvg;
    }
    return result;
}

fn strokePath(
    builder: *scene.Builder,
    commands: []const scene_abi.PathVertex,
    width: f32,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f32,
    dash_array: []const f32,
    dash_offset: f32,
    scale: f32,
    color: geometry.Color,
    material: ?u32,
) Error!void {
    if (!(width > 0) or !std.math.isFinite(width)) return;
    const allocator = builder.scene.allocator;
    var points: std.ArrayList(geometry.Point) = .empty;
    defer points.deinit(allocator);
    var closed = false;

    for (commands) |command| {
        const kind = std.enums.fromInt(scene_abi.PathCommand, command.kind) orelse return error.InvalidSvg;
        switch (kind) {
            .move_to => {
                try flushStrokeContour(builder, points.items, closed, width / 2, cap, join, miter_limit, dash_array, dash_offset, scale, color, material);
                points.clearRetainingCapacity();
                closed = false;
                try appendDistinctPoint(&points, allocator, command.position);
            },
            .line_to => try appendDistinctPoint(&points, allocator, command.position),
            .quadratic_to => {
                const start = if (points.items.len != 0) points.items[points.items.len - 1] else command.position;
                try flattenQuadraticStroke(allocator, &points, start, command.control, command.position, 0, @max(0.05, width / 16));
            },
            .close => {
                closed = true;
                try flushStrokeContour(builder, points.items, true, width / 2, cap, join, miter_limit, dash_array, dash_offset, scale, color, material);
                points.clearRetainingCapacity();
                closed = false;
            },
        }
    }
    try flushStrokeContour(builder, points.items, closed, width / 2, cap, join, miter_limit, dash_array, dash_offset, scale, color, material);
}

fn flushStrokeContour(
    builder: *scene.Builder,
    points: []const geometry.Point,
    closed: bool,
    half: f32,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f32,
    dash_array: []const f32,
    dash_offset: f32,
    scale: f32,
    color: geometry.Color,
    material: ?u32,
) Error!void {
    if (points.len < 2) return;
    if (dash_array.len == 0) {
        try strokeContour(builder, points, closed, half, cap, join, miter_limit, color, material);
    } else {
        try strokeDashedContour(builder, points, closed, half, cap, join, miter_limit, dash_array, dash_offset, scale, color, material);
    }
}

fn strokeContour(
    builder: *scene.Builder,
    raw_points: []const geometry.Point,
    closed: bool,
    half: f32,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f32,
    color: geometry.Color,
    material: ?u32,
) Error!void {
    var count = raw_points.len;
    if (count > 1 and pointsEqual(raw_points[0], raw_points[count - 1])) count -= 1;
    if (count < 2) return;
    const points = raw_points[0..count];
    const segment_count = if (closed) count else count - 1;
    for (0..segment_count) |index| {
        const next = if (index + 1 == count) 0 else index + 1;
        try strokeSegment(builder, points[index], points[next], half, color, material);
    }

    if (closed) {
        for (0..count) |index| {
            const previous = if (index == 0) count - 1 else index - 1;
            const next = if (index + 1 == count) 0 else index + 1;
            try strokeJoin(builder, points[previous], points[index], points[next], half, join, miter_limit, color, material);
        }
    } else {
        if (count > 2) for (1..count - 1) |index|
            try strokeJoin(builder, points[index - 1], points[index], points[index + 1], half, join, miter_limit, color, material);
        try strokeCap(builder, points[0], points[1], half, cap, true, color, material);
        try strokeCap(builder, points[count - 1], points[count - 2], half, cap, false, color, material);
    }
}

fn strokeSegment(builder: *scene.Builder, a: geometry.Point, b: geometry.Point, half: f32, color: geometry.Color, material: ?u32) Error!void {
    const tangent = normalized(b.sub(a)) orelse return;
    const normal: geometry.Point = .{ .x = -tangent.y * half, .y = tangent.x * half };
    const polygon = [_]geometry.Point{
        a.add(normal), b.add(normal), b.sub(normal), a.sub(normal),
    };
    try emitStrokePolygon(builder, &polygon, color, material);
}

fn strokeJoin(
    builder: *scene.Builder,
    previous: geometry.Point,
    point: geometry.Point,
    next: geometry.Point,
    half: f32,
    join: LineJoin,
    miter_limit: f32,
    color: geometry.Color,
    material: ?u32,
) Error!void {
    const incoming = normalized(point.sub(previous)) orelse return;
    const outgoing = normalized(next.sub(point)) orelse return;
    const cross = incoming.x * outgoing.y - incoming.y * outgoing.x;
    if (@abs(cross) <= 0.00001) return;
    const side: f32 = if (cross > 0) -1 else 1;
    const previous_outer_unit: geometry.Point = .{ .x = -incoming.y * side, .y = incoming.x * side };
    const next_outer_unit: geometry.Point = .{ .x = -outgoing.y * side, .y = outgoing.x * side };
    const previous_outer = point.add(scalePoint(previous_outer_unit, half));
    const next_outer = point.add(scalePoint(next_outer_unit, half));

    switch (join) {
        .bevel => try emitStrokePolygon(builder, &.{ point, previous_outer, next_outer }, color, material),
        .miter => {
            const direction = normalized(previous_outer_unit.add(next_outer_unit));
            if (direction) |miter_direction| {
                const denominator = dot(miter_direction, next_outer_unit);
                if (@abs(denominator) > 0.00001) {
                    const length = half / denominator;
                    if (length > 0 and length <= half * @max(1, miter_limit)) {
                        const miter = point.add(scalePoint(miter_direction, length));
                        try emitStrokePolygon(builder, &.{ previous_outer, miter, next_outer }, color, material);
                        return;
                    }
                }
            }
            try emitStrokePolygon(builder, &.{ point, previous_outer, next_outer }, color, material);
        },
        .round => try strokeRoundJoin(builder, point, previous_outer_unit, next_outer_unit, cross, half, color, material),
    }
}

fn strokeRoundJoin(
    builder: *scene.Builder,
    center: geometry.Point,
    from_unit: geometry.Point,
    to_unit: geometry.Point,
    cross: f32,
    radius: f32,
    color: geometry.Color,
    material: ?u32,
) Error!void {
    const start = std.math.atan2(from_unit.y, from_unit.x);
    const finish = std.math.atan2(to_unit.y, to_unit.x);
    var sweep = finish - start;
    if (cross > 0) {
        while (sweep < 0) sweep += std.math.tau;
    } else {
        while (sweep > 0) sweep -= std.math.tau;
    }
    const segment_count: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(sweep) / (std.math.pi / 16.0)))));
    const vertices = try builder.scene.allocator.alloc(geometry.Point, segment_count + 2);
    defer builder.scene.allocator.free(vertices);
    vertices[0] = center;
    for (0..segment_count + 1) |index| {
        const amount = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(segment_count));
        const angle = start + sweep * amount;
        vertices[index + 1] = .{ .x = center.x + @cos(angle) * radius, .y = center.y + @sin(angle) * radius };
    }
    try emitStrokePolygon(builder, vertices, color, material);
}

fn strokeCap(
    builder: *scene.Builder,
    endpoint: geometry.Point,
    interior: geometry.Point,
    half: f32,
    cap: LineCap,
    is_start: bool,
    color: geometry.Color,
    material: ?u32,
) Error!void {
    switch (cap) {
        .butt => {},
        .round => try strokeCircle(builder, endpoint, half, color, material),
        .square => {
            const toward_interior = normalized(interior.sub(endpoint)) orelse return;
            const outward = scalePoint(toward_interior, if (is_start) -half else -half);
            const normal: geometry.Point = .{ .x = -toward_interior.y * half, .y = toward_interior.x * half };
            try emitStrokePolygon(builder, &.{
                endpoint.add(normal),
                endpoint.add(normal).add(outward),
                endpoint.sub(normal).add(outward),
                endpoint.sub(normal),
            }, color, material);
        },
    }
}

fn strokeDashedContour(
    builder: *scene.Builder,
    raw_points: []const geometry.Point,
    closed: bool,
    half: f32,
    cap: LineCap,
    join: LineJoin,
    miter_limit: f32,
    dash_array: []const f32,
    dash_offset: f32,
    scale: f32,
    color: geometry.Color,
    material: ?u32,
) Error!void {
    const allocator = builder.scene.allocator;
    const pattern = try allocator.alloc(f32, dash_array.len);
    defer allocator.free(pattern);
    var total: f32 = 0;
    for (dash_array, 0..) |value, index| {
        pattern[index] = value * scale;
        total += pattern[index];
    }
    if (!(total > 0)) return strokeContour(builder, raw_points, closed, half, cap, join, miter_limit, color, material);

    var count = raw_points.len;
    if (count > 1 and pointsEqual(raw_points[0], raw_points[count - 1])) count -= 1;
    if (count < 2) return;
    const points = raw_points[0..count];
    var phase = dash_offset * scale;
    phase -= @floor(phase / total) * total;
    if (phase < 0) phase += total;
    var pattern_index: usize = 0;
    while (pattern_index < pattern.len - 1 and phase >= pattern[pattern_index]) {
        phase -= pattern[pattern_index];
        pattern_index += 1;
    }
    var remaining = pattern[pattern_index] - phase;
    var drawing = pattern_index % 2 == 0;
    var dash: std.ArrayList(geometry.Point) = .empty;
    defer dash.deinit(allocator);
    const segment_count = if (closed) count else count - 1;

    for (0..segment_count) |segment_index| {
        var cursor = points[segment_index];
        const end = points[if (segment_index + 1 == count) 0 else segment_index + 1];
        const delta = end.sub(cursor);
        const segment_length = lengthOf(delta);
        if (segment_length <= 0.00001) continue;
        const tangent = scalePoint(delta, 1 / segment_length);
        var distance_left = segment_length;
        while (distance_left > 0.00001) {
            while (remaining <= 0.00001) {
                if (drawing and dash.items.len > 1) try strokeContour(builder, dash.items, false, half, cap, join, miter_limit, color, material);
                dash.clearRetainingCapacity();
                pattern_index = (pattern_index + 1) % pattern.len;
                drawing = pattern_index % 2 == 0;
                remaining = pattern[pattern_index];
            }
            const step = @min(distance_left, remaining);
            const next = cursor.add(scalePoint(tangent, step));
            if (drawing) {
                try appendDistinctPoint(&dash, allocator, cursor);
                try appendDistinctPoint(&dash, allocator, next);
            }
            cursor = next;
            distance_left -= step;
            remaining -= step;
        }
    }
    if (drawing and dash.items.len > 1) try strokeContour(builder, dash.items, false, half, cap, join, miter_limit, color, material);
}

fn emitStrokePolygon(builder: *scene.Builder, points: []const geometry.Point, color: geometry.Color, material: ?u32) Error!void {
    if (points.len < 3) return;
    const vertices = try builder.scene.allocator.alloc(scene_abi.PathVertex, points.len + 1);
    defer builder.scene.allocator.free(vertices);
    vertices[0] = vertex(.move_to, points[0].x, points[0].y);
    for (points[1..], 1..) |point, index| vertices[index] = vertex(.line_to, point.x, point.y);
    vertices[points.len] = vertex(.close, points[0].x, points[0].y);
    try builder.path(.{
        .vertex_start = 0,
        .vertex_count = 0,
        .fill_rule = @backingInt(scene_abi.FillRule.non_zero),
        .color = color,
        .bounds = pathBounds(vertices),
    }, vertices, material);
}

fn flattenQuadraticStroke(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(geometry.Point),
    start: geometry.Point,
    control: geometry.Point,
    end: geometry.Point,
    depth: u8,
    tolerance: f32,
) Error!void {
    if (depth >= 12 or pointLineDistance(control, start, end) <= tolerance) {
        try appendDistinctPoint(output, allocator, end);
        return;
    }
    const left = midpoint(start, control);
    const right = midpoint(control, end);
    const middle = midpoint(left, right);
    try flattenQuadraticStroke(allocator, output, start, left, middle, depth + 1, tolerance);
    try flattenQuadraticStroke(allocator, output, middle, right, end, depth + 1, tolerance);
}

fn appendDistinctPoint(output: *std.ArrayList(geometry.Point), allocator: std.mem.Allocator, point: geometry.Point) Error!void {
    if (output.items.len != 0 and pointsEqual(output.items[output.items.len - 1], point)) return;
    try output.append(allocator, point);
}

fn normalized(point: geometry.Point) ?geometry.Point {
    const length = lengthOf(point);
    if (length <= 0.00001) return null;
    return scalePoint(point, 1 / length);
}

fn lengthOf(point: geometry.Point) f32 {
    return @sqrt(point.x * point.x + point.y * point.y);
}

fn scalePoint(point: geometry.Point, scale: f32) geometry.Point {
    return .{ .x = point.x * scale, .y = point.y * scale };
}

fn dot(a: geometry.Point, b: geometry.Point) f32 {
    return a.x * b.x + a.y * b.y;
}

fn strokeCircle(builder: *scene.Builder, center: geometry.Point, radius: f32, color: geometry.Color, material: ?u32) Error!void {
    var vertices: [34]scene_abi.PathVertex = undefined;
    vertices[0] = vertex(.move_to, center.x + radius, center.y);
    for (1..33) |index| {
        const angle = std.math.tau * @as(f32, @floatFromInt(index)) / 32;
        vertices[index] = vertex(.line_to, center.x + @cos(angle) * radius, center.y + @sin(angle) * radius);
    }
    vertices[33] = vertex(.close, center.x + radius, center.y);
    try builder.path(.{ .vertex_start = 0, .vertex_count = 0, .fill_rule = @backingInt(scene_abi.FillRule.non_zero), .color = color, .bounds = geometry.Rect.fromXYWH(center.x - radius, center.y - radius, radius * 2, radius * 2) }, &vertices, material);
}

fn paintColor(paint: Paint, opacity: f32) geometry.Color {
    return switch (paint) {
        .color => |color| blk: {
            var result = color;
            result.a *= opacity;
            break :blk result;
        },
        else => .transparent,
    };
}

fn fitTransform(source: geometry.Rect, destination: geometry.Rect, fit: Fit) geometry.Affine2D {
    const sx = destination.size.width / source.size.width;
    const sy = destination.size.height / source.size.height;
    const scale_x = switch (fit) {
        .contain => @min(sx, sy),
        .cover => @max(sx, sy),
        .fill => sx,
        .none => 1,
    };
    const scale_y = if (fit == .fill) sy else scale_x;
    const width = source.size.width * scale_x;
    const height = source.size.height * scale_y;
    return .{ .m11 = scale_x, .m22 = scale_y, .tx = destination.origin.x + (destination.size.width - width) / 2 - source.origin.x * scale_x, .ty = destination.origin.y + (destination.size.height - height) / 2 - source.origin.y * scale_y };
}

fn transformScale(transform: geometry.Affine2D) f32 {
    const x = @sqrt(transform.m11 * transform.m11 + transform.m12 * transform.m12);
    const y = @sqrt(transform.m21 * transform.m21 + transform.m22 * transform.m22);
    return @sqrt(@max(x * y, 0.000001));
}

fn normalizedDiagonal(size: geometry.Size) f32 {
    const maximum = @max(@abs(size.width), @abs(size.height));
    if (maximum == 0) return 0;
    const x = size.width / maximum;
    const y = size.height / maximum;
    return maximum * @sqrt(x * x + y * y) / std.math.sqrt2;
}
