const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const handles = @import("../core/handle.zig");
const custom = @import("../compose/custom.zig");
const compose_store = @import("../compose/store.zig");
const compose_style = @import("../compose/style.zig");
const visual = @import("../compose/visual.zig");
const style = @import("style.zig");

pub const TextMeasure = struct {
    size: geometry.Size,
    baseline: ?f32 = null,
};

pub const MeasureProvider = struct {
    context: *anyopaque,
    text_fn: *const fn (
        *anyopaque,
        []const u8,
        compose_style.TextStyle,
        style.Constraints,
    ) Error!TextMeasure,
    custom_measure_fn: *const fn (
        *anyopaque,
        []const u8,
        compose_style.TextStyle,
        style.Constraints,
    ) Error!geometry.Size,

    pub fn text(
        self: MeasureProvider,
        value: []const u8,
        text_style: compose_style.TextStyle,
        constraints: style.Constraints,
    ) Error!TextMeasure {
        return self.text_fn(self.context, value, text_style, constraints);
    }

    pub fn customServices(self: MeasureProvider) custom.TextServices {
        return .{ .context = self.context, .measure_fn = self.custom_measure_fn };
    }
};

pub const Engine = struct {
    scratch: std.mem.Allocator,
    scale_factor: geometry.ScaleFactor,
    measures: MeasureProvider,
    maximum_grid_cells: usize = 1_048_576,
    svg: ?custom.SvgServices = null,
    feedback_context: ?*anyopaque = null,
    request_recompose_fn: ?*const fn (*anyopaque, handles.ComponentId) void = null,

    pub fn layout(
        self: *Engine,
        nodes: *compose_store.Store,
        root: handles.NodeId,
        viewport: geometry.Size,
    ) Error!void {
        if (!validLayoutSize(viewport)) return error.InvalidLayout;
        const constraints: style.Constraints = .{ .minimum = viewport, .maximum = viewport };
        _ = try self.measureNode(nodes, root, constraints);
        try self.arrangeNode(nodes, root, .{ .origin = .{}, .size = viewport });
        try self.arrangePortals(nodes, root, .{ .origin = .{}, .size = viewport });
    }

    pub fn measureNode(
        self: *Engine,
        nodes: *compose_store.Store,
        id: handles.NodeId,
        constraints: style.Constraints,
    ) Error!geometry.Size {
        if (!validConstraints(constraints)) return error.InvalidLayout;
        const record = nodes.get(id) orelse return error.InvalidHandle;
        const node_style = record.borrowedStyle();
        if (node_style.layout.display == .none) {
            record.layout.baseline = null;
            return .zero;
        }

        const padding = resolveEdges(node_style.layout.padding, constraints.maximum);
        const inner_constraints = insetConstraints(constraints, padding);
        var intrinsic_baseline: ?f32 = null;
        var intrinsic: geometry.Size = switch (record.kind) {
            .text => |value| blk: {
                const measured = try self.measures.text(value, node_style.text, inner_constraints);
                intrinsic_baseline = measured.baseline;
                break :blk measured.size;
            },
            .image => |image| imageSize(image.source_width, image.source_height, inner_constraints.maximum),
            .custom => |custom_node| blk: {
                if (custom_node.vtable.measure) |measure| {
                    var context: custom.MeasureContext = .{
                        .allocator = self.scratch,
                        .scale_factor = self.scale_factor,
                        .text = self.measures.customServices(),
                        .svg = self.svg,
                    };
                    break :blk try measure(custom_node.context, &context, inner_constraints);
                }
                break :blk .zero;
            },
            .spacer => .zero,
            .container, .component, .scroll => blk: {
                const measured = try self.measureContainer(nodes, record, inner_constraints);
                intrinsic_baseline = firstFlowBaseline(nodes, record, inner_constraints.maximum);
                break :blk measured;
            },
        };

        if (!validLayoutSize(intrinsic)) return error.InvalidLayout;
        if (intrinsic_baseline) |baseline| {
            if (!std.math.isFinite(baseline) or baseline < 0 or baseline > intrinsic.height)
                return error.InvalidLayout;
        }

        intrinsic.width += padding.horizontal();
        intrinsic.height += padding.vertical();
        intrinsic = applyDeclaredSize(intrinsic, node_style.layout, constraints.maximum);
        const result = constraints.constrain(intrinsic);
        if (!validLayoutSize(result)) return error.InvalidLayout;
        record.layout.baseline = if (intrinsic_baseline) |baseline|
            std.math.clamp(padding.top + baseline, 0, result.height)
        else
            null;
        return result;
    }

    fn measureContainer(
        self: *Engine,
        nodes: *compose_store.Store,
        record: *const compose_store.Record,
        constraints: style.Constraints,
    ) Error!geometry.Size {
        if (record.children.items.len == 0) return .zero;
        return switch (record.borrowedStyle().layout.display) {
            .none => .zero,
            .flex => self.measureFlex(nodes, record, constraints),
            .grid => self.measureGrid(nodes, record, constraints),
        };
    }

    fn measureFlex(
        self: *Engine,
        nodes: *compose_store.Store,
        record: *const compose_store.Record,
        constraints: style.Constraints,
    ) Error!geometry.Size {
        const node_style = record.borrowedStyle().layout;
        const horizontal = isHorizontal(node_style.direction);
        const main_gap = mainSize(node_style.gap, horizontal);
        const cross_gap = crossSize(node_style.gap, horizontal);
        const available_main = mainSize(constraints.maximum, horizontal);
        const scrolls_main_axis = if (horizontal) node_style.overflow_x == .scroll else node_style.overflow_y == .scroll;
        const wrapping = node_style.wrap != .no_wrap and std.math.isFinite(available_main);
        const exact_main = std.math.isFinite(available_main) and
            mainSize(constraints.minimum, horizontal) == available_main;
        var measured: std.ArrayList(MeasuredChild) = .empty;
        defer measured.deinit(self.scratch);
        for (record.children.items) |child| {
            const child_record = nodes.getConst(child) orelse continue;
            const child_style = child_record.borrowedStyle().layout;
            if (isOutOfFlow(child_style) or child_style.display == .none) continue;
            const margins = resolveEdges(child_style.margin, constraints.maximum);
            var child_size = try self.measureNode(nodes, child, .{ .maximum = constraints.maximum });
            const minimum_main = if (horizontal)
                child_style.min_width.resolve(constraints.maximum.width) orelse 0
            else
                child_style.min_height.resolve(constraints.maximum.height) orelse 0;
            const declared_maximum_main = if (horizontal)
                child_style.max_width.resolve(constraints.maximum.width) orelse std.math.inf(f32)
            else
                child_style.max_height.resolve(constraints.maximum.height) orelse std.math.inf(f32);
            const maximum_main = @max(minimum_main, declared_maximum_main);
            if (child_style.flex_basis.resolve(available_main)) |basis| setMainSize(&child_size, horizontal, basis);
            setMainSize(&child_size, horizontal, std.math.clamp(mainSize(child_size, horizontal), minimum_main, maximum_main));
            try measured.append(self.scratch, .{
                .id = child,
                .size = child_size,
                .margin = margins,
                .grow = child_style.flex_grow,
                .shrink = child_style.flex_shrink,
                .alignment = child_style.align_self,
                .cross_auto = if (horizontal) std.meta.activeTag(child_style.height) == .auto else std.meta.activeTag(child_style.width) == .auto,
                .baseline = child_record.layout.baseline,
                .minimum_main = minimum_main,
                .maximum_main = maximum_main,
            });
        }
        if (measured.items.len == 0) return .zero;

        var lines: std.ArrayList(FlexLine) = .empty;
        defer lines.deinit(self.scratch);
        var line_start: usize = 0;
        var line_main: f32 = 0;
        var line_cross: f32 = 0;
        for (measured.items, 0..) |child, index| {
            const required = mainSize(child.size, horizontal) + mainInsets(child.margin, horizontal);
            const next_main = line_main + (if (index == line_start) 0 else main_gap) + required;
            if (wrapping and index != line_start and next_main > available_main) {
                try lines.append(self.scratch, makeLine(measured.items[line_start..index], line_start, line_main, line_cross, horizontal, node_style.align_items));
                line_start = index;
                line_main = required;
                line_cross = crossSize(child.size, horizontal) + crossInsets(child.margin, horizontal);
            } else {
                line_main = next_main;
                line_cross = @max(line_cross, crossSize(child.size, horizontal) + crossInsets(child.margin, horizontal));
            }
        }
        try lines.append(self.scratch, makeLine(measured.items[line_start..], line_start, line_main, line_cross, horizontal, node_style.align_items));

        var maximum_main: f32 = 0;
        var total_cross = cross_gap * @as(f32, @floatFromInt(lines.items.len -| 1));
        for (lines.items) |*line| {
            const line_children = measured.items[line.start..line.end];
            const free = available_main - line.main;
            const flexible_free = if (scrolls_main_axis and free < 0) 0 else free;
            if (std.math.isFinite(flexible_free) and (flexible_free < 0 or exact_main))
                distributeFlexibleMain(line_children, horizontal, flexible_free);
            for (line_children) |*child| {
                const allocated_main = mainSize(child.size, horizontal);
                var exact: style.Constraints = .{ .maximum = constraints.maximum };
                setMainSize(&exact.minimum, horizontal, allocated_main);
                setMainSize(&exact.maximum, horizontal, allocated_main);
                var remeasured = try self.measureNode(nodes, child.id, exact);
                setMainSize(&remeasured, horizontal, allocated_main);
                child.size = remeasured;
                child.baseline = (nodes.getConst(child.id) orelse return error.InvalidHandle).layout.baseline;
            }
            line.* = makeLine(
                line_children,
                line.start,
                flexLineMain(line_children, horizontal, main_gap),
                flexLineCross(line_children, horizontal),
                horizontal,
                node_style.align_items,
            );
            maximum_main = @max(maximum_main, line.main);
            total_cross += line.cross;
        }
        if (exact_main) maximum_main = available_main;
        return fromMainCross(maximum_main, total_cross, horizontal);
    }

    fn measureGrid(
        self: *Engine,
        nodes: *compose_store.Store,
        record: *const compose_store.Record,
        constraints: style.Constraints,
    ) Error!geometry.Size {
        const node_style = record.borrowedStyle().layout;
        const column_count = @max(node_style.grid_columns.len, 1);
        const plan = try self.gridPlan(nodes, record, column_count);
        const row_count = plan.row_count;
        const columns = try self.scratch.alloc(f32, column_count);
        const rows = try self.scratch.alloc(f32, row_count);
        @memset(columns, 0);
        @memset(rows, 0);
        try self.populateGridTracks(nodes, record, constraints.maximum, columns, rows, plan.items);
        return .{
            .width = sum(columns) + node_style.gap.width * @as(f32, @floatFromInt(column_count - 1)),
            .height = sum(rows) + node_style.gap.height * @as(f32, @floatFromInt(row_count - 1)),
        };
    }

    fn populateGridTracks(
        self: *Engine,
        nodes: *compose_store.Store,
        record: *const compose_store.Record,
        available: geometry.Size,
        columns: []f32,
        rows: []f32,
        items: []const GridItem,
    ) Error!void {
        const node_style = record.borrowedStyle().layout;
        resolveBaseTracks(node_style.grid_columns, columns, available.width);
        for (items) |item| {
            const child_record = nodes.getConst(item.child) orelse return error.InvalidHandle;
            const child_style = child_record.borrowedStyle().layout;
            const child_size = try self.measureNode(nodes, item.child, .{ .maximum = available });
            const column = item.position.column;
            const column_span = item.column_span;
            if (column >= columns.len or column_span > columns.len - column)
                return error.InvalidLayout;
            const margins = resolveEdges(child_style.margin, available);
            growIntrinsicTracks(node_style.grid_columns, columns, column, column_span, child_size.width + margins.horizontal(), node_style.gap.width);
        }
        clampMinMaxTracks(node_style.grid_columns, columns, available.width);
        resolveFractionTracks(node_style.grid_columns, columns, available.width, node_style.gap.width);
        clampMinMaxTracks(node_style.grid_columns, columns, available.width);

        // Row intrinsic sizing must use each item's resolved column span.
        // Measuring rows against the full grid width underestimates wrapped
        // text and custom content placed in a narrower column.
        resolveBaseTracks(node_style.grid_rows, rows, available.height);
        const row_baselines = try self.scratch.alloc(f32, rows.len);
        const row_below_baselines = try self.scratch.alloc(f32, rows.len);
        @memset(row_baselines, -1);
        @memset(row_below_baselines, 0);
        for (items) |item| {
            const child_record = nodes.getConst(item.child) orelse return error.InvalidHandle;
            const child_style = child_record.borrowedStyle().layout;
            const row = item.position.row;
            const row_span = item.row_span;
            if (row >= rows.len or row_span > rows.len - row) return error.InvalidLayout;
            const span_width = sum(columns[item.position.column .. item.position.column + item.column_span]) +
                node_style.gap.width * @as(f32, @floatFromInt(item.column_span - 1));
            const margin_basis: geometry.Size = .{ .width = span_width, .height = available.height };
            const margins = resolveEdges(child_style.margin, margin_basis);
            const child_size = try self.measureNode(nodes, item.child, .{ .maximum = .{
                .width = @max(0, span_width - margins.horizontal()),
                .height = available.height,
            } });
            growIntrinsicTracks(node_style.grid_rows, rows, row, row_span, child_size.height + margins.vertical(), node_style.gap.height);
            const alignment = if (child_style.align_self == .auto) node_style.align_items else child_style.align_self;
            if (alignment == .baseline and row_span == 1) {
                const baseline = child_record.layout.baseline orelse child_size.height;
                row_baselines[row] = @max(row_baselines[row], margins.top + baseline);
                row_below_baselines[row] = @max(row_below_baselines[row], margins.bottom + child_size.height - baseline);
            }
        }
        for (rows, 0..) |*row_size, row| {
            if (row_baselines[row] < 0) continue;
            const required = row_baselines[row] + row_below_baselines[row];
            switch (trackDefinition(node_style.grid_rows, row)) {
                .auto, .fraction, .minmax => row_size.* = @max(row_size.*, required),
                else => {},
            }
        }
        clampMinMaxTracks(node_style.grid_rows, rows, available.height);
        resolveFractionTracks(node_style.grid_rows, rows, available.height, node_style.gap.height);
        clampMinMaxTracks(node_style.grid_rows, rows, available.height);
    }

    fn gridPlan(
        self: *Engine,
        nodes: *const compose_store.Store,
        record: *const compose_store.Record,
        column_count: usize,
    ) Error!GridPlan {
        if (column_count == 0 or self.maximum_grid_cells == 0) return error.InvalidConfiguration;
        var items: std.ArrayList(GridItem) = .empty;
        defer items.deinit(self.scratch);
        try items.ensureTotalCapacity(self.scratch, record.children.items.len);

        var row_count = @max(record.borrowedStyle().layout.grid_rows.len, 1);
        for (record.children.items) |child| {
            const child_record = nodes.getConst(child) orelse return error.InvalidHandle;
            const child_style = child_record.borrowedStyle().layout;
            if (isOutOfFlow(child_style) or child_style.display == .none) continue;
            const column_span: usize = @intCast(child_style.grid_column_span);
            const row_span: usize = @intCast(child_style.grid_row_span);
            if (column_span == 0 or column_span > column_count or row_span == 0) return error.InvalidLayout;
            var item: GridItem = .{
                .child = child,
                .column_span = column_span,
                .row_span = row_span,
                .column_explicit = child_style.grid_column != 0,
                .row_explicit = child_style.grid_row != 0,
            };
            if (item.column_explicit) {
                item.position.column = @as(usize, child_style.grid_column - 1);
                if (item.position.column >= column_count or column_span > column_count - item.position.column)
                    return error.InvalidLayout;
            }
            if (item.row_explicit) {
                item.position.row = @as(usize, child_style.grid_row - 1);
                const row_end = std.math.add(usize, item.position.row, row_span) catch return error.BudgetExceeded;
                row_count = @max(row_count, row_end);
            }
            items.appendAssumeCapacity(item);
        }

        var occupied: std.ArrayList(bool) = .empty;
        defer occupied.deinit(self.scratch);
        try ensureGridRows(&occupied, self.scratch, column_count, &row_count, row_count, self.maximum_grid_cells);

        // Fully explicit items may intentionally overlap, matching desktop
        // scene/layout use cases such as badges and layered panels. They still
        // reserve their cells so auto-placed siblings never overlap them.
        for (items.items) |*item| if (item.row_explicit and item.column_explicit)
            occupyGridArea(occupied.items, column_count, item.*);

        // A definite row with an automatic column is placed before the normal
        // row-major cursor, so source-order auto items also avoid declarations
        // that appear later in the retained child list.
        for (items.items) |*item| {
            if (!item.row_explicit or item.column_explicit) continue;
            var column: usize = 0;
            while (column + item.column_span <= column_count) : (column += 1) {
                item.position.column = column;
                if (gridAreaFree(occupied.items, column_count, item.*)) break;
            }
            if (column + item.column_span > column_count) return error.InvalidLayout;
            occupyGridArea(occupied.items, column_count, item.*);
        }

        var cursor: usize = 0;
        for (items.items) |*item| {
            if (item.row_explicit) continue;
            if (item.column_explicit) {
                var row = cursor / column_count;
                const cursor_column = cursor % column_count;
                if (item.position.column < cursor_column) row = std.math.add(usize, row, 1) catch return error.BudgetExceeded;
                while (true) : (row = std.math.add(usize, row, 1) catch return error.BudgetExceeded) {
                    const required_rows = std.math.add(usize, row, item.row_span) catch return error.BudgetExceeded;
                    try ensureGridRows(&occupied, self.scratch, column_count, &row_count, required_rows, self.maximum_grid_cells);
                    item.position.row = row;
                    if (gridAreaFree(occupied.items, column_count, item.*)) break;
                }
            } else {
                var candidate = cursor;
                while (true) {
                    const column = candidate % column_count;
                    const row = candidate / column_count;
                    if (column + item.column_span > column_count) {
                        const next_row = std.math.add(usize, row, 1) catch return error.BudgetExceeded;
                        candidate = std.math.mul(usize, next_row, column_count) catch return error.BudgetExceeded;
                        continue;
                    }
                    const required_rows = std.math.add(usize, row, item.row_span) catch return error.BudgetExceeded;
                    try ensureGridRows(&occupied, self.scratch, column_count, &row_count, required_rows, self.maximum_grid_cells);
                    item.position = .{ .column = column, .row = row };
                    if (gridAreaFree(occupied.items, column_count, item.*)) break;
                    candidate = std.math.add(usize, candidate, 1) catch return error.BudgetExceeded;
                }
            }
            occupyGridArea(occupied.items, column_count, item.*);
            const row_start = std.math.mul(usize, item.position.row, column_count) catch return error.BudgetExceeded;
            const cell = std.math.add(usize, row_start, item.position.column) catch return error.BudgetExceeded;
            cursor = std.math.add(usize, cell, item.column_span) catch return error.BudgetExceeded;
        }

        return .{ .items = try items.toOwnedSlice(self.scratch), .row_count = row_count };
    }

    pub fn arrangeNode(
        self: *Engine,
        nodes: *compose_store.Store,
        id: handles.NodeId,
        unsnapped_bounds: geometry.Rect,
    ) Error!void {
        try self.arrangeNodeIn(nodes, id, unsnapped_bounds, null);
    }

    fn arrangeNodeIn(
        self: *Engine,
        nodes: *compose_store.Store,
        id: handles.NodeId,
        unsnapped_bounds: geometry.Rect,
        containing: ?style.LayoutResult,
    ) Error!void {
        if (!validLayoutRect(unsnapped_bounds)) return error.InvalidLayout;
        const record = nodes.get(id) orelse return error.InvalidHandle;
        const node_style = record.borrowedStyle();
        const bounds = geometry.snapRect(unsnapped_bounds, self.scale_factor, .nearest);
        const padding = resolveEdges(node_style.layout.padding, bounds.size);
        const content = bounds.inset(padding);
        const measured_baseline = record.layout.baseline;
        record.layout = .{ .bounds = bounds, .content_bounds = content, .scroll_extent = content.size, .baseline = measured_baseline };

        switch (record.kind) {
            .custom => |custom_node| if (custom_node.vtable.arrange) |arrange| {
                var context: custom.ArrangeContext = .{
                    .allocator = self.scratch,
                    .scale_factor = self.scale_factor,
                    .component = record.component,
                    .containing_bounds = if (containing) |value| value.bounds else .{},
                    .containing_content_bounds = if (containing) |value| value.content_bounds else .{},
                    .containing_scroll_extent = if (containing) |value| value.scroll_extent else .{},
                    .feedback_context = self.feedback_context,
                    .request_recompose_fn = self.request_recompose_fn,
                };
                try arrange(custom_node.context, &context, bounds);
            },
            else => {},
        }

        if (record.children.items.len == 0 or node_style.layout.display == .none) return;
        switch (node_style.layout.display) {
            .none => {},
            .flex => try self.arrangeFlex(nodes, record, content),
            .grid => try self.arrangeGrid(nodes, record, content),
        }
        try self.arrangeAbsoluteChildren(nodes, record, content);
    }

    fn arrangeFlex(
        self: *Engine,
        nodes: *compose_store.Store,
        record: *compose_store.Record,
        content: geometry.Rect,
    ) Error!void {
        const node_style = record.borrowedStyle().layout;
        const horizontal = isHorizontal(node_style.direction);
        const reverse = node_style.direction == .row_reverse or node_style.direction == .column_reverse;
        var measured: std.ArrayList(MeasuredChild) = .empty;
        defer measured.deinit(self.scratch);
        for (record.children.items) |child| {
            const child_record = nodes.getConst(child) orelse continue;
            const child_style = child_record.borrowedStyle().layout;
            if (isOutOfFlow(child_style) or child_style.display == .none) continue;
            const margins = resolveEdges(child_style.margin, content.size);
            var measured_size = try self.measureNode(nodes, child, .{ .maximum = content.size });
            const minimum_main = if (horizontal)
                child_style.min_width.resolve(content.size.width) orelse 0
            else
                child_style.min_height.resolve(content.size.height) orelse 0;
            const declared_maximum_main = if (horizontal)
                child_style.max_width.resolve(content.size.width) orelse std.math.inf(f32)
            else
                child_style.max_height.resolve(content.size.height) orelse std.math.inf(f32);
            const maximum_main = @max(minimum_main, declared_maximum_main);
            if (child_style.flex_basis.resolve(mainSize(content.size, horizontal))) |basis| setMainSize(&measured_size, horizontal, basis);
            setMainSize(&measured_size, horizontal, std.math.clamp(mainSize(measured_size, horizontal), minimum_main, maximum_main));
            try measured.append(self.scratch, .{
                .id = child,
                .size = measured_size,
                .margin = margins,
                .grow = child_style.flex_grow,
                .shrink = child_style.flex_shrink,
                .alignment = child_style.align_self,
                .cross_auto = if (horizontal) std.meta.activeTag(child_style.height) == .auto else std.meta.activeTag(child_style.width) == .auto,
                .baseline = child_record.layout.baseline,
                .minimum_main = minimum_main,
                .maximum_main = maximum_main,
            });
        }
        if (measured.items.len == 0) return;

        var lines: std.ArrayList(FlexLine) = .empty;
        defer lines.deinit(self.scratch);
        const available_main = mainSize(content.size, horizontal);
        const scrolls_main_axis = if (horizontal) node_style.overflow_x == .scroll else node_style.overflow_y == .scroll;
        const main_gap = mainSize(node_style.gap, horizontal);
        const cross_gap = crossSize(node_style.gap, horizontal);
        const wrapping = node_style.wrap != .no_wrap;
        var line_start: usize = 0;
        var line_main: f32 = 0;
        var line_cross: f32 = 0;
        for (measured.items, 0..) |child, index| {
            const required = mainSize(child.size, horizontal) + mainInsets(child.margin, horizontal);
            const next_main = line_main + (if (index == line_start) 0 else main_gap) + required;
            if (wrapping and index != line_start and next_main > available_main) {
                try lines.append(self.scratch, makeLine(measured.items[line_start..index], line_start, line_main, line_cross, horizontal, node_style.align_items));
                line_start = index;
                line_main = required;
                line_cross = crossSize(child.size, horizontal) + crossInsets(child.margin, horizontal);
            } else {
                line_main = next_main;
                line_cross = @max(line_cross, crossSize(child.size, horizontal) + crossInsets(child.margin, horizontal));
            }
        }
        try lines.append(self.scratch, makeLine(measured.items[line_start..], line_start, line_main, line_cross, horizontal, node_style.align_items));

        // Main-axis flexing can change a child's wrapping and therefore its
        // cross size and baseline. Resolve constraints first, then remeasure
        // at the exact allocated main size before line cross-axis placement.
        for (lines.items) |*line| {
            const current_start = line.start;
            const line_children = measured.items[line.start..line.end];
            const initial_free = available_main - line.main;
            distributeFlexibleMain(line_children, horizontal, if (scrolls_main_axis and initial_free < 0) 0 else initial_free);
            for (line_children) |*child| {
                const allocated_main = mainSize(child.size, horizontal);
                var exact: style.Constraints = .{ .maximum = content.size };
                setMainSize(&exact.minimum, horizontal, allocated_main);
                setMainSize(&exact.maximum, horizontal, allocated_main);
                var remeasured = try self.measureNode(nodes, child.id, exact);
                setMainSize(&remeasured, horizontal, allocated_main);
                child.size = remeasured;
                child.baseline = (nodes.getConst(child.id) orelse return error.InvalidHandle).layout.baseline;
            }
            line.* = makeLine(
                line_children,
                current_start,
                flexLineMain(line_children, horizontal, main_gap),
                flexLineCross(line_children, horizontal),
                horizontal,
                node_style.align_items,
            );
        }

        var total_cross: f32 = cross_gap * @as(f32, @floatFromInt(lines.items.len - 1));
        for (lines.items) |line| total_cross += line.cross;
        const available_cross = crossSize(content.size, horizontal);
        const free_cross = @max(0, available_cross - total_cross);
        if (node_style.align_content == .stretch and free_cross > 0) {
            const addition = free_cross / @as(f32, @floatFromInt(lines.items.len));
            for (lines.items) |*line| line.cross += addition;
        }
        const cross_leading = switch (node_style.align_content) {
            .center => free_cross / 2,
            .end => free_cross,
            else => 0,
        };
        var cross_cursor = cross_leading;
        var line_iteration: usize = 0;
        while (line_iteration < lines.items.len) : (line_iteration += 1) {
            const line_index = if (node_style.wrap == .wrap_reverse) lines.items.len - 1 - line_iteration else line_iteration;
            const line = &lines.items[line_index];
            const free = if (scrolls_main_axis) @max(0, available_main - line.main) else available_main - line.main;
            const distribution = justify(node_style.justify_content, free, line.end - line.start);
            var cursor = if (reverse) available_main - distribution.leading else distribution.leading;
            var child_iteration: usize = 0;
            while (child_iteration < line.end - line.start) : (child_iteration += 1) {
                const logical = if (reverse) line.end - 1 - child_iteration else line.start + child_iteration;
                const child = &measured.items[logical];
                const leading_margin = if (horizontal) child.margin.left else child.margin.top;
                const trailing_margin = if (horizontal) child.margin.right else child.margin.bottom;
                var alignment = if (child.alignment == .auto) node_style.align_items else child.alignment;
                if (alignment == .stretch and child.cross_auto) setCrossSize(&child.size, horizontal, @max(0, line.cross - crossInsets(child.margin, horizontal)));
                if (alignment == .baseline and !horizontal) alignment = .start;
                const child_main = mainSize(child.size, horizontal);
                if (reverse) cursor -= trailing_margin + child_main else cursor += leading_margin;
                const child_cross = if (horizontal and alignment == .baseline and line.baseline != null)
                    line.baseline.? - (child.baseline orelse child.size.height)
                else
                    alignCross(alignment, line.cross, crossSize(child.size, horizontal), child.margin, horizontal);
                var origin = content.origin;
                if (horizontal) {
                    origin.x += cursor;
                    origin.y += cross_cursor + child_cross;
                } else {
                    origin.y += cursor;
                    origin.x += cross_cursor + child_cross;
                }
                try self.arrangeNodeIn(nodes, child.id, .{ .origin = origin, .size = child.size }, record.layout);
                if (reverse) cursor -= leading_margin + main_gap + distribution.between else cursor += child_main + trailing_margin + main_gap + distribution.between;
            }
            cross_cursor += line.cross + cross_gap;
        }
        if (horizontal and lines.items.len != 0 and lines.items[0].baseline != null)
            record.layout.baseline = content.origin.y - record.layout.bounds.origin.y + cross_leading + lines.items[0].baseline.?;
        updateScrollExtent(nodes, record);
    }

    fn arrangeGrid(
        self: *Engine,
        nodes: *compose_store.Store,
        record: *compose_store.Record,
        content: geometry.Rect,
    ) Error!void {
        const node_style = record.borrowedStyle().layout;
        const column_count = @max(node_style.grid_columns.len, 1);
        const plan = try self.gridPlan(nodes, record, column_count);
        const row_count = plan.row_count;
        const columns = try self.scratch.alloc(f32, column_count);
        const rows = try self.scratch.alloc(f32, row_count);
        @memset(columns, 0);
        @memset(rows, 0);
        try self.populateGridTracks(nodes, record, content.size, columns, rows, plan.items);

        const measured = try self.scratch.alloc(GridMeasured, plan.items.len);
        const row_baselines = try self.scratch.alloc(f32, row_count);
        const row_below_baselines = try self.scratch.alloc(f32, row_count);
        @memset(row_baselines, -1);
        @memset(row_below_baselines, 0);
        for (plan.items, 0..) |item, item_index| {
            const child = item.child;
            const child_record = nodes.getConst(child) orelse return error.InvalidHandle;
            const child_style = child_record.borrowedStyle().layout;
            const column = item.position.column;
            const row = item.position.row;
            const column_span = item.column_span;
            const row_span = item.row_span;
            if (column >= column_count or column_span > column_count - column or row >= row_count or row_span > row_count - row)
                return error.InvalidLayout;
            const cell = gridCell(content, columns, rows, node_style.gap, item);
            const margins = resolveEdges(child_style.margin, cell.size);
            const available = geometry.Size{
                .width = @max(0, cell.size.width - margins.horizontal()),
                .height = @max(0, cell.size.height - margins.vertical()),
            };
            var size = try self.measureNode(nodes, child, .{ .maximum = available });
            const alignment = if (child_style.align_self == .auto) node_style.align_items else child_style.align_self;
            if (std.meta.activeTag(child_style.width) == .auto) size.width = available.width else size.width = @min(size.width, available.width);
            if (alignment == .stretch and std.meta.activeTag(child_style.height) == .auto)
                size.height = available.height
            else
                size.height = @min(size.height, available.height);
            const baseline = child_record.layout.baseline orelse size.height;
            measured[item_index] = .{
                .size = size,
                .alignment = alignment,
                .baseline = baseline,
                .cross_auto = std.meta.activeTag(child_style.height) == .auto,
            };
            if (alignment == .baseline and row_span == 1) {
                row_baselines[row] = @max(row_baselines[row], margins.top + baseline);
                row_below_baselines[row] = @max(row_below_baselines[row], margins.bottom + size.height - baseline);
            }
        }
        for (rows, 0..) |*row_size, row| {
            if (row_baselines[row] < 0) continue;
            const required = row_baselines[row] + row_below_baselines[row];
            switch (trackDefinition(node_style.grid_rows, row)) {
                .auto, .fraction, .minmax => row_size.* = @max(row_size.*, required),
                else => {},
            }
        }
        clampMinMaxTracks(node_style.grid_rows, rows, content.size.height);

        for (plan.items, 0..) |item, item_index| {
            const child_style = (nodes.getConst(item.child) orelse return error.InvalidHandle).borrowedStyle().layout;
            const cell = gridCell(content, columns, rows, node_style.gap, item);
            const item_measure = measured[item_index];
            const margins = resolveEdges(child_style.margin, cell.size);
            const available = geometry.Size{
                .width = @max(0, cell.size.width - margins.horizontal()),
                .height = @max(0, cell.size.height - margins.vertical()),
            };
            var size = item_measure.size;
            size.width = @min(size.width, available.width);
            if (item_measure.alignment == .stretch and item_measure.cross_auto)
                size.height = available.height
            else
                size.height = @min(size.height, available.height);
            const y_offset = switch (item_measure.alignment) {
                .center => (available.height - size.height) / 2,
                .end => available.height - size.height,
                .baseline => if (item.row_span == 1 and row_baselines[item.position.row] >= 0)
                    row_baselines[item.position.row] - item_measure.baseline - margins.top
                else
                    0,
                else => 0,
            };
            try self.arrangeNodeIn(nodes, item.child, .{
                .origin = .{ .x = cell.origin.x + margins.left, .y = cell.origin.y + margins.top + y_offset },
                .size = size,
            }, record.layout);
        }
        updateScrollExtent(nodes, record);
    }

    fn arrangeAbsoluteChildren(
        self: *Engine,
        nodes: *compose_store.Store,
        record: *compose_store.Record,
        content: geometry.Rect,
    ) Error!void {
        for (record.children.items) |child| {
            const child_record = nodes.getConst(child) orelse continue;
            const child_style = child_record.borrowedStyle().layout;
            if (child_style.position != .absolute or child_style.portal.target != .none or child_style.display == .none) continue;
            const margin = resolveEdges(child_style.margin, content.size);
            const available: geometry.Size = .{
                .width = @max(0, content.size.width - margin.horizontal()),
                .height = @max(0, content.size.height - margin.vertical()),
            };
            const measured = try self.measureNode(nodes, child, .{ .maximum = available });
            const inset = child_style.inset;
            const left = inset.left.resolve(content.size.width);
            const right = inset.right.resolve(content.size.width);
            const top = inset.top.resolve(content.size.height);
            const bottom = inset.bottom.resolve(content.size.height);
            var size = measured;
            const stretched_x = left != null and right != null;
            const stretched_y = top != null and bottom != null;
            if (stretched_x) size.width = constrainedAxis(
                @max(0, available.width - left.? - right.?),
                child_style.min_width,
                child_style.max_width,
                content.size.width,
            );
            if (stretched_y) size.height = constrainedAxis(
                @max(0, available.height - top.? - bottom.?),
                child_style.min_height,
                child_style.max_height,
                content.size.height,
            );
            if (child_style.aspect_ratio) |ratio| {
                if (stretched_x and !stretched_y and std.meta.activeTag(child_style.height) == .auto)
                    size.height = constrainedAxis(size.width / ratio, child_style.min_height, child_style.max_height, content.size.height);
                if (stretched_y and !stretched_x and std.meta.activeTag(child_style.width) == .auto)
                    size.width = constrainedAxis(size.height * ratio, child_style.min_width, child_style.max_width, content.size.width);
            }
            const x = content.origin.x + margin.left + if (left) |value|
                value
            else if (right) |value|
                available.width - value - size.width
            else
                0;
            const y = content.origin.y + margin.top + if (top) |value|
                value
            else if (bottom) |value|
                available.height - value - size.height
            else
                0;
            try self.arrangeNodeIn(nodes, child, .{ .origin = .{ .x = x, .y = y }, .size = size }, record.layout);
        }
        updateScrollExtent(nodes, record);
    }

    /// Arranges visual top-layer subtrees after ordinary flow is complete.
    /// Portal records retain their logical parent but use either that parent's
    /// visual bounds or the window viewport as their containing block.
    pub fn arrangePortals(
        self: *Engine,
        nodes: *compose_store.Store,
        root: handles.NodeId,
        viewport: geometry.Rect,
    ) Error!void {
        if (!validLayoutRect(viewport)) return error.InvalidLayout;
        try self.arrangePortalDescendants(nodes, root, viewport);
    }

    fn arrangePortalDescendants(
        self: *Engine,
        nodes: *compose_store.Store,
        parent_id: handles.NodeId,
        viewport: geometry.Rect,
    ) Error!void {
        const parent = nodes.getConst(parent_id) orelse return error.InvalidHandle;
        if (parent.borrowedStyle().layout.display == .none) return;
        for (parent.children.items) |child_id| {
            const child = nodes.getConst(child_id) orelse continue;
            const child_layout = child.borrowedStyle().layout;
            if (child_layout.display == .none) continue;
            if (child_layout.portal.target != .none) {
                const target = switch (child_layout.portal.target) {
                    .none => unreachable,
                    .anchor => try visual.visualBounds(nodes, parent_id, self.scratch),
                    .viewport => viewport,
                };
                try self.arrangePortalNode(nodes, child_id, target, viewport);
            }
            try self.arrangePortalDescendants(nodes, child_id, viewport);
        }
    }

    fn arrangePortalNode(
        self: *Engine,
        nodes: *compose_store.Store,
        id: handles.NodeId,
        target: geometry.Rect,
        viewport: geometry.Rect,
    ) Error!void {
        const record = nodes.getConst(id) orelse return error.InvalidHandle;
        const declaration = record.borrowedStyle().layout;
        const portal = declaration.portal;
        const margin = @max(0, portal.viewport_margin);
        const usable_viewport = viewport.inset(geometry.Insets.all(margin));
        var size = try self.measureNode(nodes, id, .{ .maximum = usable_viewport.size });
        size.width = anchorSized(size.width, target.size.width, portal.anchor_width);
        size.height = anchorSized(size.height, target.size.height, portal.anchor_height);
        size = size.clamp(.zero, usable_viewport.size);

        var bounds = placePortal(target, size, declaration.inset, portal);
        if (portal.flip) {
            const opposite = oppositePlacement(portal.placement);
            if (opposite != portal.placement) {
                var alternate_policy = portal;
                alternate_policy.placement = opposite;
                const alternate = placePortal(target, size, declaration.inset, alternate_policy);
                if (overflowScore(alternate, usable_viewport) < overflowScore(bounds, usable_viewport)) bounds = alternate;
            }
        }
        if (portal.clamp_to_viewport) bounds = clampRect(bounds, usable_viewport);
        try self.arrangeNode(nodes, id, bounds);
    }
};

const MeasuredChild = struct {
    id: handles.NodeId,
    size: geometry.Size,
    margin: geometry.Insets,
    grow: f32,
    shrink: f32,
    alignment: style.Align,
    cross_auto: bool,
    baseline: ?f32,
    minimum_main: f32,
    maximum_main: f32,
};

const FlexLine = struct {
    start: usize,
    end: usize,
    main: f32,
    cross: f32,
    baseline: ?f32 = null,
};

fn makeLine(children: []const MeasuredChild, start: usize, main: f32, initial_cross: f32, horizontal: bool, parent_alignment: style.Align) FlexLine {
    var cross = initial_cross;
    var baseline: ?f32 = null;
    var below_baseline: f32 = 0;
    for (children) |child| {
        const alignment = if (child.alignment == .auto) parent_alignment else child.alignment;
        if (horizontal and alignment == .baseline) {
            const child_baseline = child.baseline orelse child.size.height;
            baseline = @max(baseline orelse 0, child.margin.top + child_baseline);
            below_baseline = @max(below_baseline, child.margin.bottom + child.size.height - child_baseline);
        }
    }
    if (baseline) |line_baseline| cross = @max(cross, line_baseline + below_baseline);
    return .{ .start = start, .end = start + children.len, .main = main, .cross = cross, .baseline = baseline };
}

fn flexLineMain(children: []const MeasuredChild, horizontal: bool, gap: f32) f32 {
    var total = gap * @as(f32, @floatFromInt(children.len -| 1));
    for (children) |child| total += mainSize(child.size, horizontal) + mainInsets(child.margin, horizontal);
    return total;
}

fn flexLineCross(children: []const MeasuredChild, horizontal: bool) f32 {
    var maximum: f32 = 0;
    for (children) |child|
        maximum = @max(maximum, crossSize(child.size, horizontal) + crossInsets(child.margin, horizontal));
    return maximum;
}

/// Distributes remaining main-axis space iteratively. Children that hit a
/// min/max constraint are frozen and their unconsumed share is redistributed
/// to the remaining children instead of silently leaving overflow or a gap.
fn distributeFlexibleMain(
    children: []MeasuredChild,
    horizontal: bool,
    initial_free: f32,
) void {
    const epsilon: f32 = 0.0001;
    if (@abs(initial_free) <= epsilon or children.len == 0) return;
    const growing = initial_free > 0;
    var remaining = @abs(initial_free);
    var iteration: usize = 0;
    while (remaining > epsilon and iteration <= children.len) : (iteration += 1) {
        var total_factor: f32 = 0;
        for (children) |child| {
            const current = mainSize(child.size, horizontal);
            if (growing) {
                if (current + epsilon < child.maximum_main) total_factor += child.grow;
            } else if (current > child.minimum_main + epsilon) {
                total_factor += child.shrink * @max(current, 1);
            }
        }
        if (total_factor <= 0) break;

        const offered = remaining;
        var consumed: f32 = 0;
        for (children) |*child| {
            const current = mainSize(child.size, horizontal);
            const factor = if (growing)
                if (current + epsilon < child.maximum_main) child.grow else 0
            else if (current > child.minimum_main + epsilon)
                child.shrink * @max(current, 1)
            else
                0;
            if (factor <= 0) continue;
            const share = offered * factor / total_factor;
            const next = if (growing)
                @min(child.maximum_main, current + share)
            else
                @max(child.minimum_main, current - share);
            consumed += @abs(next - current);
            setMainSize(&child.size, horizontal, next);
        }
        if (consumed <= epsilon) break;
        remaining = @max(0, remaining - consumed);
    }
}

const Distribution = struct { leading: f32 = 0, between: f32 = 0 };

fn isOutOfFlow(value: style.LayoutStyle) bool {
    return value.position == .absolute or value.portal.target != .none;
}

fn firstFlowBaseline(
    nodes: *const compose_store.Store,
    record: *const compose_store.Record,
    available: geometry.Size,
) ?f32 {
    for (record.children.items) |child| {
        const child_record = nodes.getConst(child) orelse continue;
        const child_style = child_record.borrowedStyle().layout;
        if (child_style.display == .none or isOutOfFlow(child_style)) continue;
        const baseline = child_record.layout.baseline orelse continue;
        return resolveEdges(child_style.margin, available).top + baseline;
    }
    return null;
}

fn anchorSized(value: f32, anchor: f32, policy: style.PortalAnchorSize) f32 {
    return switch (policy) {
        .none => value,
        .minimum => @max(value, anchor),
        .exact => anchor,
    };
}

fn placePortal(
    target: geometry.Rect,
    measured: geometry.Size,
    inset: style.LengthEdges,
    portal: style.PortalStyle,
) geometry.Rect {
    var size = measured;
    return switch (portal.placement) {
        .fill => target,
        .center => .{
            .origin = .{
                .x = target.origin.x + (target.size.width - size.width) / 2,
                .y = target.origin.y + (target.size.height - size.height) / 2,
            },
            .size = size,
        },
        .above => .{
            .origin = .{
                .x = alignedOrigin(target.minX(), target.size.width, size.width, portal.alignment),
                .y = target.minY() - portal.gap - size.height,
            },
            .size = size,
        },
        .below => .{
            .origin = .{
                .x = alignedOrigin(target.minX(), target.size.width, size.width, portal.alignment),
                .y = target.maxY() + portal.gap,
            },
            .size = size,
        },
        .left => .{
            .origin = .{
                .x = target.minX() - portal.gap - size.width,
                .y = alignedOrigin(target.minY(), target.size.height, size.height, portal.alignment),
            },
            .size = size,
        },
        .right => .{
            .origin = .{
                .x = target.maxX() + portal.gap,
                .y = alignedOrigin(target.minY(), target.size.height, size.height, portal.alignment),
            },
            .size = size,
        },
        .inset => blk: {
            const left = inset.left.resolve(target.size.width);
            const right = inset.right.resolve(target.size.width);
            const top = inset.top.resolve(target.size.height);
            const bottom = inset.bottom.resolve(target.size.height);
            if (left != null and right != null) size.width = @max(0, target.size.width - left.? - right.?);
            if (top != null and bottom != null) size.height = @max(0, target.size.height - top.? - bottom.?);
            break :blk .{
                .origin = .{
                    .x = target.origin.x + if (left) |value| value else if (right) |value| target.size.width - value - size.width else 0,
                    .y = target.origin.y + if (top) |value| value else if (bottom) |value| target.size.height - value - size.height else 0,
                },
                .size = size,
            };
        },
    };
}

fn alignedOrigin(origin: f32, available: f32, child: f32, alignment: style.PortalAlignment) f32 {
    return origin + switch (alignment) {
        .start => 0,
        .center => (available - child) / 2,
        .end => available - child,
    };
}

fn oppositePlacement(value: style.PortalPlacement) style.PortalPlacement {
    return switch (value) {
        .above => .below,
        .below => .above,
        .left => .right,
        .right => .left,
        else => value,
    };
}

fn overflowScore(value: geometry.Rect, container: geometry.Rect) f32 {
    return @max(0, container.minX() - value.minX()) +
        @max(0, value.maxX() - container.maxX()) +
        @max(0, container.minY() - value.minY()) +
        @max(0, value.maxY() - container.maxY());
}

fn clampRect(value: geometry.Rect, container: geometry.Rect) geometry.Rect {
    const size: geometry.Size = .{
        .width = @min(value.size.width, container.size.width),
        .height = @min(value.size.height, container.size.height),
    };
    return .{
        .origin = .{
            .x = std.math.clamp(value.origin.x, container.minX(), @max(container.minX(), container.maxX() - size.width)),
            .y = std.math.clamp(value.origin.y, container.minY(), @max(container.minY(), container.maxY() - size.height)),
        },
        .size = size,
    };
}

fn justify(value: style.Justify, free: f32, count: usize) Distribution {
    const positive = @max(0, free);
    return switch (value) {
        .start => .{},
        .center => .{ .leading = positive / 2 },
        .end => .{ .leading = positive },
        .space_between => .{ .between = if (count > 1) positive / @as(f32, @floatFromInt(count - 1)) else 0 },
        .space_around => .{
            .leading = if (count > 0) positive / @as(f32, @floatFromInt(count)) / 2 else 0,
            .between = if (count > 0) positive / @as(f32, @floatFromInt(count)) else 0,
        },
        .space_evenly => .{
            .leading = positive / @as(f32, @floatFromInt(count + 1)),
            .between = positive / @as(f32, @floatFromInt(count + 1)),
        },
    };
}

fn alignCross(
    alignment: style.Align,
    available: f32,
    child: f32,
    margin: geometry.Insets,
    horizontal: bool,
) f32 {
    const leading = if (horizontal) margin.top else margin.left;
    const trailing = if (horizontal) margin.bottom else margin.right;
    const free = @max(0, available - child - leading - trailing);
    return switch (alignment) {
        .center => leading + free / 2,
        .end => leading + free,
        else => leading,
    };
}

fn applyDeclaredSize(intrinsic: geometry.Size, declaration: style.LayoutStyle, available: geometry.Size) geometry.Size {
    var result = intrinsic;
    if (declaration.width.resolve(available.width)) |width| result.width = width;
    if (declaration.height.resolve(available.height)) |height| result.height = height;
    const min_width = declaration.min_width.resolve(available.width) orelse 0;
    const min_height = declaration.min_height.resolve(available.height) orelse 0;
    const max_width = declaration.max_width.resolve(available.width) orelse std.math.inf(f32);
    const max_height = declaration.max_height.resolve(available.height) orelse std.math.inf(f32);
    const effective_max_width = @max(min_width, max_width);
    const effective_max_height = @max(min_height, max_height);
    result.width = @min(@max(result.width, min_width), effective_max_width);
    result.height = @min(@max(result.height, min_height), effective_max_height);
    if (declaration.aspect_ratio) |ratio| {
        if (std.meta.activeTag(declaration.width) != .auto and std.meta.activeTag(declaration.height) == .auto) result.height = result.width / ratio;
        if (std.meta.activeTag(declaration.height) != .auto and std.meta.activeTag(declaration.width) == .auto) result.width = result.height * ratio;
    }
    result.width = @min(@max(result.width, min_width), effective_max_width);
    result.height = @min(@max(result.height, min_height), effective_max_height);
    return result;
}

fn constrainedAxis(value: f32, minimum: style.Length, maximum: style.Length, available: f32) f32 {
    const lower = minimum.resolve(available) orelse 0;
    const upper = @max(lower, maximum.resolve(available) orelse std.math.inf(f32));
    return std.math.clamp(value, lower, upper);
}

fn validLayoutSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and
        value.width >= 0 and value.height >= 0;
}

fn validConstraints(value: style.Constraints) bool {
    return validLayoutSize(value.minimum) and
        !std.math.isNan(value.maximum.width) and !std.math.isNan(value.maximum.height) and
        value.maximum.width >= 0 and value.maximum.height >= 0 and
        value.minimum.width <= value.maximum.width and value.minimum.height <= value.maximum.height;
}

fn validLayoutRect(value: geometry.Rect) bool {
    return std.math.isFinite(value.origin.x) and std.math.isFinite(value.origin.y) and validLayoutSize(value.size);
}

fn resolveEdges(edges: style.LengthEdges, available: geometry.Size) geometry.Insets {
    return .{
        .top = edges.top.resolve(available.height) orelse 0,
        .right = edges.right.resolve(available.width) orelse 0,
        .bottom = edges.bottom.resolve(available.height) orelse 0,
        .left = edges.left.resolve(available.width) orelse 0,
    };
}

fn insetConstraints(constraints: style.Constraints, insets: geometry.Insets) style.Constraints {
    return .{
        .minimum = .{
            .width = @max(0, constraints.minimum.width - insets.horizontal()),
            .height = @max(0, constraints.minimum.height - insets.vertical()),
        },
        .maximum = .{
            .width = @max(0, constraints.maximum.width - insets.horizontal()),
            .height = @max(0, constraints.maximum.height - insets.vertical()),
        },
    };
}

fn imageSize(width: u32, height: u32, maximum: geometry.Size) geometry.Size {
    if (width == 0 or height == 0) return .zero;
    const source = geometry.Size{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
    const scale = @min(1, @min(maximum.width / source.width, maximum.height / source.height));
    return .{ .width = source.width * scale, .height = source.height * scale };
}

fn isHorizontal(direction: style.FlexDirection) bool {
    return direction == .row or direction == .row_reverse;
}

fn mainSize(size: geometry.Size, horizontal: bool) f32 {
    return if (horizontal) size.width else size.height;
}

fn crossSize(size: geometry.Size, horizontal: bool) f32 {
    return if (horizontal) size.height else size.width;
}

fn setMainSize(size: *geometry.Size, horizontal: bool, value: f32) void {
    if (horizontal) size.width = value else size.height = value;
}

fn setCrossSize(size: *geometry.Size, horizontal: bool, value: f32) void {
    if (horizontal) size.height = value else size.width = value;
}

fn fromMainCross(main: f32, cross: f32, horizontal: bool) geometry.Size {
    return if (horizontal) .{ .width = main, .height = cross } else .{ .width = cross, .height = main };
}

fn mainInsets(insets: geometry.Insets, horizontal: bool) f32 {
    return if (horizontal) insets.horizontal() else insets.vertical();
}

fn crossInsets(insets: geometry.Insets, horizontal: bool) f32 {
    return if (horizontal) insets.vertical() else insets.horizontal();
}

fn resolveBaseTracks(template: []const style.GridTrack, output: []f32, available: f32) void {
    for (output, 0..) |*track, index| {
        const definition: style.GridTrack = if (index < template.len) template[index] else .auto;
        switch (definition) {
            .auto => {},
            .points => |value| track.* = @max(0, value),
            .percent => |value| track.* = if (std.math.isFinite(available)) @max(0, available * value) else 0,
            .fraction => {},
            .minmax => |range| track.* = @max(0, range.min.resolve(available) orelse 0),
        }
    }
}

fn growIntrinsicTracks(
    template: []const style.GridTrack,
    tracks: []f32,
    start: usize,
    span: usize,
    required: f32,
    gap: f32,
) void {
    const current = sum(tracks[start .. start + span]) + gap * @as(f32, @floatFromInt(span -| 1));
    const deficit = required - current;
    if (deficit <= 0) return;
    var flexible: usize = 0;
    for (start..start + span) |index| switch (trackDefinition(template, index)) {
        .auto, .fraction, .minmax => flexible += 1,
        else => {},
    };
    if (flexible == 0) return;
    const addition = deficit / @as(f32, @floatFromInt(flexible));
    for (start..start + span) |index| switch (trackDefinition(template, index)) {
        .auto, .fraction, .minmax => tracks[index] += addition,
        else => {},
    };
}

fn resolveFractionTracks(template: []const style.GridTrack, output: []f32, available: f32, gap: f32) void {
    if (!std.math.isFinite(available)) return;
    const usable = @max(0, available - gap * @as(f32, @floatFromInt(output.len -| 1)));
    var total_fractions: f32 = 0;
    var fixed_space: f32 = 0;
    for (output, 0..) |track, index| {
        const fraction = trackFraction(trackDefinition(template, index));
        if (fraction > 0) total_fractions += fraction else fixed_space += track;
    }
    if (total_fractions <= 0) return;

    // Solve sum(max(intrinsic_min, fraction * unit)) == remaining space.
    // Tracks whose intrinsic/minmax floor is larger than their fractional
    // share freeze at that floor; the rest divide what remains. This avoids
    // overflowing a grid merely because one fractional track has a minimum.
    var unit = @max(0, usable - fixed_space) / total_fractions;
    var iteration: usize = 0;
    while (iteration <= output.len) : (iteration += 1) {
        var frozen_space = fixed_space;
        var active_fractions: f32 = 0;
        for (output, 0..) |track, index| {
            const fraction = trackFraction(trackDefinition(template, index));
            if (fraction <= 0) continue;
            if (track > fraction * unit) frozen_space += track else active_fractions += fraction;
        }
        if (active_fractions <= 0) break;
        const next = @max(0, usable - frozen_space) / active_fractions;
        if (@abs(next - unit) <= 0.0001) {
            unit = next;
            break;
        }
        unit = next;
    }
    for (output, 0..) |*track, index| {
        const fraction = trackFraction(trackDefinition(template, index));
        if (fraction > 0) track.* = @max(track.*, fraction * unit);
    }
}

fn clampMinMaxTracks(template: []const style.GridTrack, output: []f32, available: f32) void {
    for (output, 0..) |*track, index| switch (trackDefinition(template, index)) {
        .minmax => |range| {
            const minimum = range.min.resolve(available) orelse 0;
            const maximum = range.max.resolve(available) orelse std.math.inf(f32);
            track.* = std.math.clamp(track.*, minimum, @max(minimum, maximum));
        },
        else => {},
    };
}

fn trackDefinition(template: []const style.GridTrack, index: usize) style.GridTrack {
    return if (index < template.len) template[index] else .auto;
}

fn trackFraction(definition: style.GridTrack) f32 {
    return switch (definition) {
        .fraction => |value| @max(0, value),
        .minmax => |range| switch (range.max) {
            .fraction => |value| @max(0, value),
            else => 0,
        },
        else => 0,
    };
}

fn updateScrollExtent(nodes: *const compose_store.Store, record: *compose_store.Record) void {
    var maximum_x = record.layout.content_bounds.maxX();
    var maximum_y = record.layout.content_bounds.maxY();
    for (record.children.items) |child| {
        const child_record = nodes.getConst(child) orelse continue;
        const child_style = child_record.borrowedStyle().layout;
        if (child_style.display == .none or child_style.portal.target != .none) continue;
        maximum_x = @max(maximum_x, child_record.layout.bounds.maxX());
        maximum_y = @max(maximum_y, child_record.layout.bounds.maxY());
    }
    record.layout.scroll_extent = .{
        .width = @max(record.layout.content_bounds.size.width, maximum_x - record.layout.content_bounds.origin.x),
        .height = @max(record.layout.content_bounds.size.height, maximum_y - record.layout.content_bounds.origin.y),
    };
    switch (record.kind) {
        .scroll => |*scroll| {
            scroll.offset_x = if (scroll.horizontal) std.math.clamp(scroll.offset_x, 0, @max(0, record.layout.scroll_extent.width - record.layout.content_bounds.size.width)) else 0;
            scroll.offset_y = if (scroll.vertical) std.math.clamp(scroll.offset_y, 0, @max(0, record.layout.scroll_extent.height - record.layout.content_bounds.size.height)) else 0;
        },
        else => {},
    }
}

const GridPosition = struct { column: usize, row: usize };

const GridItem = struct {
    child: handles.NodeId,
    position: GridPosition = .{ .column = 0, .row = 0 },
    column_span: usize,
    row_span: usize,
    column_explicit: bool,
    row_explicit: bool,
};

const GridMeasured = struct {
    size: geometry.Size,
    alignment: style.Align,
    baseline: f32,
    cross_auto: bool,
};

fn gridCell(
    content: geometry.Rect,
    columns: []const f32,
    rows: []const f32,
    gap: geometry.Size,
    item: GridItem,
) geometry.Rect {
    return geometry.Rect.fromXYWH(
        content.origin.x + sum(columns[0..item.position.column]) + gap.width * @as(f32, @floatFromInt(item.position.column)),
        content.origin.y + sum(rows[0..item.position.row]) + gap.height * @as(f32, @floatFromInt(item.position.row)),
        sum(columns[item.position.column .. item.position.column + item.column_span]) + gap.width * @as(f32, @floatFromInt(item.column_span - 1)),
        sum(rows[item.position.row .. item.position.row + item.row_span]) + gap.height * @as(f32, @floatFromInt(item.row_span - 1)),
    );
}

const GridPlan = struct {
    items: []GridItem,
    row_count: usize,
};

fn ensureGridRows(
    occupied: *std.ArrayList(bool),
    allocator: std.mem.Allocator,
    column_count: usize,
    row_count: *usize,
    required_rows: usize,
    maximum_cells: usize,
) Error!void {
    if (required_rows > row_count.*) row_count.* = required_rows;
    const cells = std.math.mul(usize, row_count.*, column_count) catch return error.BudgetExceeded;
    if (cells > maximum_cells) return error.BudgetExceeded;
    if (cells <= occupied.items.len) return;
    const previous = occupied.items.len;
    try occupied.resize(allocator, cells);
    @memset(occupied.items[previous..], false);
}

fn gridAreaFree(occupied: []const bool, column_count: usize, item: GridItem) bool {
    var row_offset: usize = 0;
    while (row_offset < item.row_span) : (row_offset += 1) {
        const row = item.position.row + row_offset;
        const base = row * column_count + item.position.column;
        for (occupied[base .. base + item.column_span]) |cell| if (cell) return false;
    }
    return true;
}

fn occupyGridArea(occupied: []bool, column_count: usize, item: GridItem) void {
    var row_offset: usize = 0;
    while (row_offset < item.row_span) : (row_offset += 1) {
        const row = item.position.row + row_offset;
        const base = row * column_count + item.position.column;
        @memset(occupied[base .. base + item.column_span], true);
    }
}

fn sum(values: []const f32) f32 {
    var result: f32 = 0;
    for (values) |value| result += value;
    return result;
}
