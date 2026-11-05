const std = @import("std");
const Error = @import("../core/error.zig").Error;
const geometry = @import("../core/geometry.zig");
const component = @import("../compose/component.zig");
const node = @import("../compose/node.zig");
const compose_style = @import("../compose/style.zig");
const custom = @import("../compose/custom.zig");
const input = @import("../input/event.zig");
const layout = @import("../layout/style.zig");
const a11y = @import("../a11y/api.zig");
const text_api = @import("../text/api.zig");
const unicode = @import("../text/unicode.zig");
const Callback = @import("callback.zig").Callback;
const Theme = @import("theme.zig").Theme;

pub const TextField = struct {
    /// Project-neutral visual overrides for the editable surface. A null
    /// value keeps the corresponding Theme/default behavior, which means
    /// existing TextFields remain byte-for-byte compatible until a consumer
    /// opts into a value.
    pub const VisualConfig = struct {
        /// Insets between the field bounds and text, selection, and caret.
        content_insets: ?geometry.Insets = null,
        /// Surface and unfocused border colors. Focus still uses the theme's
        /// accent/focus-ring treatment unless the widget itself changes it.
        surface_color: ?geometry.Color = null,
        border_color: ?geometry.Color = null,
        radius: ?f32 = null,
        text_color: ?geometry.Color = null,
        placeholder_color: ?geometry.Color = null,
        /// A positive logical line height. Null delegates to the text
        /// backend's normal line height, preserving the previous behavior.
        line_height: ?f32 = null,
        vertical_alignment: enum { top, center } = .top,
        selection_color: ?geometry.Color = null,
        focus_border_color: ?geometry.Color = null,
    };

    const DisplayText = struct {
        /// Logical UTF-8 after applying the active IME replacement.
        logical: []const u8,
        /// What is painted. This differs from `logical` only for passwords.
        shown: []const u8,
    };

    const Edit = struct {
        start: usize,
        removed: []u8,
        inserted: []u8,
        selection_before: input.TextRange,
        selection_after: input.TextRange,

        fn byteCost(self: Edit) usize {
            return self.removed.len + self.inserted.len;
        }

        fn deinit(self: *Edit, allocator: std.mem.Allocator) void {
            allocator.free(self.removed);
            allocator.free(self.inserted);
            self.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    marked_text: std.ArrayList(u8) = .empty,
    undo_edits: std.ArrayList(Edit) = .empty,
    redo_edits: std.ArrayList(Edit) = .empty,
    history_bytes: usize = 0,
    composition_active: bool = false,
    selection: input.TextRange = .{ .start = 0, .end = 0 },
    marked_selection: input.TextRange = .{ .start = 0, .end = 0 },
    placeholder: []const u8 = "",
    label: []const u8 = "",
    semantic_role: a11y.Role = .text_field,
    theme: *const Theme = &Theme.dark,
    font_size: f32 = 14,
    font_weight: text_api.FontWeight = .regular,
    multiline: bool = false,
    password: bool = false,
    /// Ordered family fallback list used for both measurement and painting.
    /// The default preserves the widget's existing system-ui behavior.
    font_families: []const []const u8 = &.{"system-ui"},
    visual: VisualConfig = .{},
    disabled: bool = false,
    read_only: bool = false,
    maximum_bytes: usize = 1024 * 1024,
    maximum_history_entries: usize = 256,
    maximum_history_bytes: usize = 4 * 1024 * 1024,
    focused: bool = false,
    selecting_pointer: ?u64 = null,
    preferred_x: ?f32 = null,
    text_services: ?custom.TextServices = null,
    last_content_bounds: geometry.Rect = .{},
    last_text_extent: geometry.Size = .{},
    scroll_offset: geometry.Point = .{},
    reveal_caret: bool = true,
    on_change: ?Callback = null,
    on_submit: ?Callback = null,

    pub fn init(allocator: std.mem.Allocator, initial: []const u8) Error!TextField {
        return initWithLimit(allocator, initial, 1024 * 1024);
    }

    pub fn initWithLimit(allocator: std.mem.Allocator, initial: []const u8, maximum_bytes: usize) Error!TextField {
        try validateUtf8(initial);
        if (initial.len > maximum_bytes) return error.BudgetExceeded;
        var self: TextField = .{ .allocator = allocator, .maximum_bytes = maximum_bytes };
        errdefer self.deinit();
        try self.text.appendSlice(allocator, initial);
        self.selection = .{ .start = initial.len, .end = initial.len };
        return self;
    }

    pub fn deinit(self: *TextField) void {
        self.clearHistoryList(&self.undo_edits);
        self.clearHistoryList(&self.redo_edits);
        self.undo_edits.deinit(self.allocator);
        self.redo_edits.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.marked_text.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn value(self: *const TextField) []const u8 {
        return self.text.items;
    }

    pub fn setValue(self: *TextField, value_text: []const u8) Error!void {
        try validateUtf8(value_text);
        if (value_text.len > self.maximum_bytes) return error.BudgetExceeded;
        const replacement = try self.allocator.dupe(u8, value_text);
        var previous = self.text;
        self.text = .{ .items = replacement, .capacity = replacement.len };
        previous.deinit(self.allocator);
        self.clearHistory();
        self.selection = .{ .start = value_text.len, .end = value_text.len };
        self.marked_text.clearRetainingCapacity();
        self.marked_selection = .{};
        self.composition_active = false;
        self.preferred_x = null;
        self.reveal_caret = true;
    }

    /// Replaces the current selection as one undoable edit and selects a
    /// UTF-8 range inside the inserted text. This is the project-neutral path
    /// for formatting toolbars, autocomplete, and other external editing
    /// controls that must preserve the field's normal history and callbacks.
    pub fn replaceSelection(
        self: *TextField,
        replacement: []const u8,
        selected_inserted: input.TextRange,
        ctx: *input.Context,
    ) Error!void {
        if (self.disabled or self.read_only) return error.InvalidConfiguration;
        try validateUtf8(replacement);
        const selected = selected_inserted.normalized();
        if (selected.end > replacement.len or
            !utf8Boundary(replacement, selected.start) or
            !utf8Boundary(replacement, selected.end))
            return error.InvalidConfiguration;

        const range = self.selection.normalized();
        const previous_undo_count = self.undo_edits.items.len;
        try self.replace(range.start, range.end, replacement);
        self.selection = .{
            .start = range.start + selected.start,
            .end = range.start + selected.end,
        };
        if (self.undo_edits.items.len > previous_undo_count) {
            self.undo_edits.items[self.undo_edits.items.len - 1].selection_after = self.selection;
        }
        self.marked_text.clearRetainingCapacity();
        self.marked_selection = .{};
        self.composition_active = false;
        self.preferred_x = null;
        self.reveal_caret = true;
        try self.changed(ctx);
    }

    pub fn clearHistory(self: *TextField) void {
        self.clearHistoryList(&self.undo_edits);
        self.clearHistoryList(&self.redo_edits);
        self.history_bytes = 0;
    }

    pub fn build(self: *TextField, ctx: *component.BuildContext) Error!node.Spec {
        if (self.disabled) self.selecting_pointer = null;
        try self.validateState();
        var action_buffer: [4]a11y.Action = undefined;
        var action_count: usize = 0;
        if (!self.disabled) {
            action_buffer[action_count] = .focus;
            action_count += 1;
            action_buffer[action_count] = .activate;
            action_count += 1;
            action_buffer[action_count] = .set_selection;
            action_count += 1;
            if (!self.read_only) {
                action_buffer[action_count] = .set_value;
                action_count += 1;
            }
        }
        const actions = try ctx.allocator.dupe(a11y.Action, action_buffer[0..action_count]);
        return .{
            .kind = .{ .custom = custom.Node.from(TextField, self) },
            .style = .{
                .layout = .{
                    .min_height = .{ .points = self.theme.control_height },
                    .padding = self.contentPadding(),
                    .overflow_x = .hidden,
                    .overflow_y = if (self.multiline) .scroll else .hidden,
                },
                .paint = .{
                    .background = .{ .solid = self.surfaceColor() },
                    .border = .{
                        .widths = geometry.Insets.all(if (self.focused) self.theme.focus_ring_width else 1),
                        .color = if (self.focused) self.visual.focus_border_color orelse self.theme.focus_ring else self.borderColor(),
                    },
                    .radii = geometry.CornerRadii.all(self.radius()),
                    .opacity = if (self.disabled) self.theme.disabled_opacity else 1,
                },
                .text = self.textStyle(false),
                .interaction = .{
                    .focusable = true,
                    .cursor = if (self.disabled) .not_allowed else .text,
                    .disabled = self.disabled,
                },
            },
            .semantics = .{
                .role = self.semantic_role,
                .label = self.label,
                .value = if (self.password) "" else self.text.items,
                .selection = if (self.password) null else .{ .anchor = self.selection.start, .focus = self.selection.end },
                .actions = actions,
                .disabled = self.disabled,
                .multiline = self.multiline,
                .password = self.password,
            },
        };
    }

    pub fn measure(self: *TextField, ctx: *custom.MeasureContext, constraints: layout.Constraints) Error!geometry.Size {
        try self.validateState();
        const services = ctx.text orelse return error.TextUnavailable;
        self.text_services = services;
        const display = try self.displayText(ctx.allocator);
        const empty = display.logical.len == 0;
        const shown = if (empty) self.placeholder else display.shown;
        const style = self.textStyle(empty);
        const measured = try services.measure(shown, style, constraints);
        self.last_text_extent = try self.measureExtent(services, shown, style, constraints.maximum.width);
        return .{
            .width = measured.width,
            .height = @max(measured.height, self.minimumLineHeight()),
        };
    }

    pub fn paint(self: *TextField, ctx: *custom.PaintContext, bounds: geometry.Rect) Error!void {
        try self.validateState();
        const services = ctx.text orelse return error.TextUnavailable;
        self.text_services = services;
        var content = bounds.inset(self.contentInsets());
        const display = try self.displayText(ctx.scratch);
        const empty = display.logical.len == 0;
        const shown = if (empty) self.placeholder else display.shown;
        const style = self.textStyle(empty);
        self.last_text_extent = try self.measureExtent(services, shown, style, content.size.width);
        if (!self.multiline and self.visual.vertical_alignment == .center) {
            const extra = @max(0, content.size.height - self.last_text_extent.height);
            content.origin.y += extra * 0.5;
            content.size.height -= extra;
        }
        self.last_content_bounds = content;
        try self.ensureCaretVisible(services, shown, style, display, content.size);
        const text_origin = content.origin.sub(self.scroll_offset);
        const text_bounds: geometry.Rect = .{ .origin = text_origin, .size = content.size };
        const normalized = self.selection.normalized();
        const selection_start = if (self.composition_active)
            self.displayOffsetForSource(normalized.start, display) + self.displayOffsetWithinMarked(self.marked_selection.start)
        else
            self.displayOffsetForSource(normalized.start, display);
        const selection_end = if (self.composition_active)
            self.displayOffsetForSource(normalized.start, display) + self.displayOffsetWithinMarked(self.marked_selection.end)
        else
            self.displayOffsetForSource(normalized.end, display);
        if (selection_start != selection_end) {
            var rectangles: std.ArrayList(geometry.Rect) = .empty;
            defer rectangles.deinit(ctx.scratch);
            try services.selectionRects(shown, style, content.size.width, selection_start, selection_end, &rectangles, ctx.scratch);
            for (rectangles.items) |local| try ctx.quad(.{
                .bounds = local.translated(text_origin),
                .background = self.visual.selection_color orelse geometry.Color.rgba(self.theme.accent.r, self.theme.accent.g, self.theme.accent.b, 0.38),
                .border_color = .transparent,
                .border_widths = .{},
                .radii = .{},
            });
        }
        if (self.composition_active and self.marked_text.items.len != 0) {
            const marked_start = self.displayOffsetForSource(normalized.start, display);
            const marked_end = marked_start + self.displayOffsetWithinMarked(self.marked_text.items.len);
            var rectangles: std.ArrayList(geometry.Rect) = .empty;
            defer rectangles.deinit(ctx.scratch);
            try services.selectionRects(shown, style, content.size.width, marked_start, marked_end, &rectangles, ctx.scratch);
            const thickness = @max(1 / @max(1, ctx.scale_factor.value), 0.75);
            for (rectangles.items) |local| try ctx.emit(.{ .underline = .{
                .bounds = geometry.Rect.fromXYWH(
                    text_origin.x + local.origin.x,
                    text_origin.y + local.maxY() - thickness,
                    local.size.width,
                    thickness,
                ),
                .color = self.textColor(),
                .thickness = thickness,
                .wave_amplitude = 0,
                .wave_period = 0,
            } });
        }
        try ctx.paintText(shown, style, text_bounds);
        if (self.focused and !self.read_only) {
            const source_caret = if (self.composition_active) normalized.start else self.selection.end;
            const display_caret = self.displayOffsetForSource(source_caret, display) + if (self.composition_active)
                self.displayOffsetWithinMarked(self.marked_selection.end)
            else
                0;
            var caret = try services.caretRect(shown, style, content.size.width, display_caret, .downstream);
            caret.origin = caret.origin.add(text_origin);
            caret.size.width = @max(1 / @max(1, ctx.scale_factor.value), 0.5);
            try ctx.quad(.{
                .bounds = caret,
                .background = self.textColor(),
                .border_color = .transparent,
                .border_widths = .{},
                .radii = .{},
            });
        }
    }

    pub fn event(self: *TextField, dispatch: *input.Dispatch, event_value: *const input.Event, ctx: *input.Context) Error!void {
        try handle(self, dispatch, event_value, ctx);
    }

    fn displayText(self: *TextField, allocator: std.mem.Allocator) Error!DisplayText {
        const logical = if (self.composition_active)
            try self.displayCombined(allocator)
        else
            self.text.items;
        if (!self.password) return .{ .logical = logical, .shown = logical };
        const count = graphemeCount(logical);
        const obscured_length = std.math.mul(usize, count, 3) catch return error.BudgetExceeded;
        const obscured = try allocator.alloc(u8, obscured_length);
        var index: usize = 0;
        while (index < count) : (index += 1) @memcpy(obscured[index * 3 ..][0..3], "•");
        return .{ .logical = logical, .shown = obscured };
    }

    fn handle(context: *anyopaque, dispatch: *input.Dispatch, event_value: *const input.Event, ctx: *input.Context) Error!void {
        const self: *TextField = @ptrCast(@alignCast(context));
        switch (event_value.*) {
            .focus_in => {
                self.focused = true;
                self.reveal_caret = true;
                try self.syncNative(ctx);
                try ctx.setTextInputActive(true);
                try self.syncNative(ctx);
                try ctx.invalidate(.{});
            },
            .focus_out => {
                self.focused = false;
                self.marked_text.clearRetainingCapacity();
                self.marked_selection = .{};
                self.composition_active = false;
                try ctx.setTextInputActive(false);
                try ctx.invalidate(.{});
            },
            .pointer_down => |pointer| if (!self.disabled and pointer.button == .primary) {
                dispatch.requestFocus(dispatch.current);
                const byte_offset = try self.offsetAtPoint(ctx.localPoint(pointer.position));
                if (pointer.click_count >= 3) {
                    self.selection = lineRange(self.text.items, byte_offset);
                } else if (pointer.click_count == 2) {
                    self.selection = try wordRange(self.text.items, byte_offset);
                } else if (pointer.modifiers.shift) {
                    self.selection.end = byte_offset;
                } else {
                    self.selection = .{ .start = byte_offset, .end = byte_offset };
                }
                self.preferred_x = null;
                self.reveal_caret = true;
                self.selecting_pointer = pointer.pointer_id;
                dispatch.capturePointer(dispatch.current);
                dispatch.handled = true;
                try self.syncNative(ctx);
                try ctx.invalidate(.{});
            },
            .pointer_move => |pointer| if (!self.disabled and self.selecting_pointer == pointer.pointer_id) {
                self.selection.end = try self.offsetAtPoint(ctx.localPoint(pointer.position));
                self.preferred_x = null;
                self.reveal_caret = true;
                dispatch.handled = true;
                try self.syncNative(ctx);
                try ctx.invalidate(.{});
            },
            .pointer_up, .pointer_cancel => |pointer| if (self.selecting_pointer == pointer.pointer_id) {
                self.selecting_pointer = null;
                dispatch.releasePointer();
                dispatch.handled = true;
            },
            .scroll => |scroll| {
                const previous = self.scroll_offset;
                self.clampScroll(self.last_content_bounds.size);
                if (self.multiline) {
                    self.scroll_offset.y = clampOffset(
                        self.scroll_offset.y + scroll.delta.y,
                        self.last_text_extent.height,
                        self.last_content_bounds.size.height,
                    );
                } else if (scroll.delta.x != 0) {
                    self.scroll_offset.x = clampOffset(
                        self.scroll_offset.x + scroll.delta.x,
                        self.last_text_extent.width,
                        self.last_content_bounds.size.width,
                    );
                }
                if (std.meta.eql(previous, self.scroll_offset)) return;
                self.reveal_caret = false;
                dispatch.handled = true;
                dispatch.preventDefault();
                try ctx.invalidate(.{ .layout = false, .resources = false, .semantics = false });
            },
            .key_down => |key| if (!self.disabled) try self.handleKey(key, dispatch, ctx),
            .ime => |ime| if (!self.disabled and !self.read_only) try self.handleIme(ime, dispatch, ctx),
            .accessibility => |request| if (!self.disabled) try self.handleAccessibility(request, dispatch, ctx),
            else => {},
        }
    }

    fn handleKey(self: *TextField, key: input.KeyEvent, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        if (key.composing) return;
        const normalized = self.selection.normalized();
        const primary_shortcut = key.modifiers.command or key.modifiers.control;
        const word_navigation = key.modifiers.alt or key.modifiers.control;
        var value_changed = false;
        switch (key.key) {
            .arrow_left => self.moveCursor(if (!key.modifiers.shift and normalized.start != normalized.end)
                normalized.start
            else if (key.modifiers.command)
                lineStart(self.text.items, self.selection.end)
            else if (word_navigation)
                try previousWordBoundary(self.text.items, self.selection.end)
            else
                previousBoundary(self.text.items, self.selection.end), key.modifiers.shift),
            .arrow_right => self.moveCursor(if (!key.modifiers.shift and normalized.start != normalized.end)
                normalized.end
            else if (key.modifiers.command)
                lineEnd(self.text.items, self.selection.end)
            else if (word_navigation)
                try nextWordBoundary(self.text.items, self.selection.end)
            else
                nextBoundary(self.text.items, self.selection.end), key.modifiers.shift),
            .arrow_up => if (key.modifiers.command)
                self.moveCursor(0, key.modifiers.shift)
            else
                try self.moveVertical(-1, false, key.modifiers.shift),
            .arrow_down => if (key.modifiers.command)
                self.moveCursor(self.text.items.len, key.modifiers.shift)
            else
                try self.moveVertical(1, false, key.modifiers.shift),
            .page_up => try self.moveVertical(-1, true, key.modifiers.shift),
            .page_down => try self.moveVertical(1, true, key.modifiers.shift),
            .home => self.moveCursor(if (key.modifiers.command or key.modifiers.control)
                0
            else
                lineStart(self.text.items, self.selection.end), key.modifiers.shift),
            .end => self.moveCursor(if (key.modifiers.command or key.modifiers.control)
                self.text.items.len
            else
                lineEnd(self.text.items, self.selection.end), key.modifiers.shift),
            .backspace => if (!self.read_only) {
                const start = if (normalized.start != normalized.end) normalized.start else previousBoundary(self.text.items, normalized.start);
                if (start != normalized.end) {
                    try self.replace(start, normalized.end, "");
                    value_changed = true;
                }
            },
            .delete => if (!self.read_only) {
                const end = if (normalized.start != normalized.end) normalized.end else nextBoundary(self.text.items, normalized.end);
                if (normalized.start != end) {
                    try self.replace(normalized.start, end, "");
                    value_changed = true;
                }
            },
            .enter => if (self.multiline and !self.read_only) {
                try self.replace(normalized.start, normalized.end, "\n");
                value_changed = true;
            } else if (self.on_submit) |callback| try callback.call(ctx),
            .character => |scalar| {
                if (!primary_shortcut or scalar > 0x7f) return;
                switch (std.ascii.toLower(@as(u8, @intCast(scalar)))) {
                    'a' => self.selection = .{ .start = 0, .end = self.text.items.len },
                    'c' => try self.copySelection(ctx),
                    'x' => {
                        if (!self.read_only) {
                            value_changed = try self.cutSelection(ctx);
                        } else {
                            try self.copySelection(ctx);
                        }
                    },
                    'v' => if (!self.read_only) {
                        value_changed = try self.paste(ctx);
                    },
                    'z' => if (!self.read_only) {
                        value_changed = if (key.modifiers.shift) try self.redo() else try self.undo();
                    },
                    'y' => if (!self.read_only) {
                        value_changed = try self.redo();
                    },
                    else => return,
                }
            },
            else => return,
        }
        self.reveal_caret = true;
        dispatch.handled = true;
        dispatch.preventDefault();
        if (value_changed) {
            try self.changed(ctx);
        } else {
            try self.syncNative(ctx);
            try ctx.invalidate(.{});
        }
    }

    fn handleIme(self: *TextField, ime: input.ImeEvent, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        var value_changed = false;
        switch (ime) {
            .set_marked_text => |marked| {
                const selection = if (marked.replacement_utf8) |replacement|
                    clampRange(self.text.items, replacement)
                else
                    self.selection.normalized();
                const removed = selection.end - selection.start;
                const retained = self.text.items.len - removed;
                const next_length = std.math.add(usize, retained, marked.text.len) catch return error.BudgetExceeded;
                if (next_length > self.maximum_bytes) return error.BudgetExceeded;
                const replacement = try self.allocator.dupe(u8, marked.text);
                var previous = self.marked_text;
                self.marked_text = .{ .items = replacement, .capacity = replacement.len };
                previous.deinit(self.allocator);
                self.marked_selection = marked.selected_utf8;
                self.selection = selection;
                self.composition_active = true;
            },
            .commit_text => |commit| {
                const range = if (commit.replacement_utf8) |replacement| clampRange(self.text.items, replacement) else self.selection.normalized();
                try self.replace(range.start, range.end, commit.text);
                self.marked_text.clearRetainingCapacity();
                self.marked_selection = .{};
                self.composition_active = false;
                value_changed = true;
            },
            .unmark_text => {
                if (self.composition_active and self.marked_text.items.len != 0) {
                    const range = self.selection.normalized();
                    try self.replace(range.start, range.end, self.marked_text.items);
                    value_changed = true;
                }
                self.marked_text.clearRetainingCapacity();
                self.marked_selection = .{};
                self.composition_active = false;
            },
            .cancel_composition => {
                self.marked_text.clearRetainingCapacity();
                self.marked_selection = .{};
                self.composition_active = false;
            },
            .request_surrounding_text => {},
        }
        self.reveal_caret = true;
        dispatch.handled = true;
        if (value_changed) {
            try self.changed(ctx);
        } else {
            try self.syncNative(ctx);
            try ctx.invalidate(.{});
        }
    }

    fn handleAccessibility(self: *TextField, request: input.AccessibilityEvent, dispatch: *input.Dispatch, ctx: *input.Context) Error!void {
        var value_changed = false;
        switch (request.action) {
            .focus, .activate => {
                dispatch.requestFocus(dispatch.current);
                try self.syncNative(ctx);
                try ctx.setTextInputActive(true);
            },
            .set_value => {
                if (self.read_only) return;
                const requested_value = request.value orelse return;
                try self.setValue(requested_value);
                value_changed = true;
            },
            .set_selection => {
                const selection = request.selection orelse return;
                self.selection = .{
                    .start = clampBoundary(self.text.items, selection.anchor),
                    .end = clampBoundary(self.text.items, selection.focus),
                };
            },
            else => return,
        }
        self.reveal_caret = true;
        dispatch.handled = true;
        if (value_changed) {
            try self.changed(ctx);
        } else {
            try self.syncNative(ctx);
            try ctx.invalidate(.{});
        }
    }

    fn moveCursor(self: *TextField, offset: usize, extend: bool) void {
        if (extend) self.selection.end = offset else self.selection = .{ .start = offset, .end = offset };
        self.marked_text.clearRetainingCapacity();
        self.marked_selection = .{};
        self.composition_active = false;
        self.preferred_x = null;
        self.reveal_caret = true;
    }

    fn replace(self: *TextField, start: usize, end: usize, replacement: []const u8) Error!void {
        if (start > end or end > self.text.items.len) return error.InvalidConfiguration;
        if (!utf8Boundary(self.text.items, start) or !utf8Boundary(self.text.items, end)) return error.InvalidConfiguration;
        try validateUtf8(replacement);
        const removed = end - start;
        const next_length = std.math.add(usize, self.text.items.len - removed, replacement.len) catch return error.BudgetExceeded;
        if (next_length > self.maximum_bytes) return error.BudgetExceeded;
        const inserted_copy = try self.allocator.dupe(u8, replacement);
        errdefer self.allocator.free(inserted_copy);

        const edit_bytes = std.math.add(usize, removed, replacement.len) catch return error.BudgetExceeded;
        const record = self.maximum_history_entries != 0 and self.maximum_history_bytes != 0 and
            edit_bytes <= self.maximum_history_bytes;
        var removed_copy: []u8 = &.{};
        if (record) {
            removed_copy = try self.allocator.dupe(u8, self.text.items[start..end]);
        }
        errdefer if (record) self.allocator.free(removed_copy);

        try self.text.ensureTotalCapacity(self.allocator, next_length);
        if (record) try self.undo_edits.ensureUnusedCapacity(self.allocator, 1);
        const before = self.selection;
        self.replaceAssumeCapacity(start, end, inserted_copy);
        self.preferred_x = null;
        self.reveal_caret = true;

        self.clearHistoryList(&self.redo_edits);
        if (record) {
            while (self.undo_edits.items.len >= self.maximum_history_entries or
                edit_bytes > self.maximum_history_bytes -| self.history_bytes)
            {
                if (self.undo_edits.items.len == 0) break;
                var evicted = self.undo_edits.orderedRemove(0);
                self.history_bytes -= evicted.byteCost();
                evicted.deinit(self.allocator);
            }
            self.undo_edits.appendAssumeCapacity(.{
                .start = start,
                .removed = removed_copy,
                .inserted = inserted_copy,
                .selection_before = before,
                .selection_after = self.selection,
            });
            self.history_bytes += edit_bytes;
        } else {
            self.allocator.free(inserted_copy);
            self.clearHistoryList(&self.undo_edits);
        }
    }

    fn replaceAssumeCapacity(self: *TextField, start: usize, end: usize, replacement: []const u8) void {
        const removed = end - start;
        const next_length = self.text.items.len - removed + replacement.len;
        const old_length = self.text.items.len;
        if (replacement.len > removed) {
            self.text.items.len = next_length;
            std.mem.copyBackwards(u8, self.text.items[start + replacement.len .. next_length], self.text.items[end..old_length]);
        } else {
            std.mem.copyForwards(u8, self.text.items[start + replacement.len .. next_length], self.text.items[end..old_length]);
            self.text.items.len = next_length;
        }
        @memcpy(self.text.items[start..][0..replacement.len], replacement);
        const cursor = start + replacement.len;
        self.selection = .{ .start = cursor, .end = cursor };
    }

    fn undo(self: *TextField) Error!bool {
        if (self.undo_edits.items.len == 0) return false;
        const edit = self.undo_edits.items[self.undo_edits.items.len - 1];
        const end = std.math.add(usize, edit.start, edit.inserted.len) catch return error.InvalidConfiguration;
        if (end > self.text.items.len or !std.mem.eql(u8, self.text.items[edit.start..end], edit.inserted))
            return error.InvalidConfiguration;
        const next_length = std.math.add(usize, self.text.items.len - edit.inserted.len, edit.removed.len) catch
            return error.BudgetExceeded;
        if (next_length > self.maximum_bytes) return error.BudgetExceeded;
        try self.text.ensureTotalCapacity(self.allocator, next_length);
        try self.redo_edits.ensureUnusedCapacity(self.allocator, 1);
        const moved = self.undo_edits.pop().?;
        self.replaceAssumeCapacity(moved.start, end, moved.removed);
        self.selection = moved.selection_before;
        self.marked_text.clearRetainingCapacity();
        self.marked_selection = .{};
        self.composition_active = false;
        self.preferred_x = null;
        self.reveal_caret = true;
        self.redo_edits.appendAssumeCapacity(moved);
        return true;
    }

    fn redo(self: *TextField) Error!bool {
        if (self.redo_edits.items.len == 0) return false;
        const edit = self.redo_edits.items[self.redo_edits.items.len - 1];
        const end = std.math.add(usize, edit.start, edit.removed.len) catch return error.InvalidConfiguration;
        if (end > self.text.items.len or !std.mem.eql(u8, self.text.items[edit.start..end], edit.removed))
            return error.InvalidConfiguration;
        const next_length = std.math.add(usize, self.text.items.len - edit.removed.len, edit.inserted.len) catch
            return error.BudgetExceeded;
        if (next_length > self.maximum_bytes) return error.BudgetExceeded;
        try self.text.ensureTotalCapacity(self.allocator, next_length);
        try self.undo_edits.ensureUnusedCapacity(self.allocator, 1);
        const moved = self.redo_edits.pop().?;
        self.replaceAssumeCapacity(moved.start, end, moved.inserted);
        self.selection = moved.selection_after;
        self.marked_text.clearRetainingCapacity();
        self.marked_selection = .{};
        self.composition_active = false;
        self.preferred_x = null;
        self.reveal_caret = true;
        self.undo_edits.appendAssumeCapacity(moved);
        return true;
    }

    fn clearHistoryList(self: *TextField, list: *std.ArrayList(Edit)) void {
        for (list.items) |*edit| {
            self.history_bytes -|= edit.byteCost();
            edit.deinit(self.allocator);
        }
        list.clearRetainingCapacity();
    }

    fn copySelection(self: *TextField, ctx: *input.Context) Error!void {
        if (self.password or !ctx.hasClipboard()) return;
        const normalized = self.selection.normalized();
        if (normalized.start == normalized.end) return;
        try ctx.writeClipboardText(self.text.items[normalized.start..normalized.end]);
    }

    fn cutSelection(self: *TextField, ctx: *input.Context) Error!bool {
        if (self.password or !ctx.hasClipboard()) return false;
        const normalized = self.selection.normalized();
        if (normalized.start == normalized.end) return false;
        try ctx.writeClipboardText(self.text.items[normalized.start..normalized.end]);
        try self.replace(normalized.start, normalized.end, "");
        return true;
    }

    fn paste(self: *TextField, ctx: *input.Context) Error!bool {
        if (!ctx.hasClipboard()) return false;
        const clipboard = (try ctx.readClipboardText(self.allocator)) orelse return false;
        defer self.allocator.free(clipboard);
        if (clipboard.len == 0 and self.selection.start == self.selection.end) return false;
        const normalized = self.selection.normalized();
        try self.replace(normalized.start, normalized.end, clipboard);
        return true;
    }

    fn moveVertical(self: *TextField, direction: i2, page: bool, extend: bool) Error!void {
        if (!self.multiline) return;
        const services = self.text_services orelse return error.TextUnavailable;
        self.marked_text.clearRetainingCapacity();
        self.marked_selection = .{};
        self.composition_active = false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const display = try self.displayText(arena.allocator());
        const current_offset = self.displayOffsetForSource(self.selection.end, display);
        const caret = try services.caretRect(
            display.shown,
            self.textStyle(false),
            self.last_content_bounds.size.width,
            current_offset,
            .downstream,
        );
        const preferred = self.preferred_x orelse caret.origin.x;
        self.preferred_x = preferred;
        const step = if (page)
            @max(self.last_content_bounds.size.height, self.minimumLineHeight())
        else
            self.minimumLineHeight();
        const target_y = caret.origin.y + @as(f32, @floatFromInt(direction)) * step;
        const hit = try services.hitTest(
            display.shown,
            self.textStyle(false),
            self.last_content_bounds.size.width,
            .{ .x = preferred, .y = @max(0, target_y) },
        );
        const offset = self.sourceOffsetForDisplay(hit.utf8_offset, display);
        if (extend) self.selection.end = offset else self.selection = .{ .start = offset, .end = offset };
        self.reveal_caret = true;
    }

    fn changed(self: *TextField, ctx: *input.Context) Error!void {
        try self.syncNative(ctx);
        try ctx.invalidate(.{});
        if (self.on_change) |callback| try callback.call(ctx);
    }

    fn syncNative(self: *TextField, ctx: *input.Context) Error!void {
        const local_candidate = self.currentCaretRect() catch |err| switch (err) {
            error.TextUnavailable => geometry.Rect.fromXYWH(
                ctx.current_layout_bounds.origin.x + self.contentInsets().left,
                ctx.current_layout_bounds.origin.y + self.contentInsets().top,
                1,
                self.minimumLineHeight(),
            ),
            else => return err,
        };
        try ctx.updateTextInput(self.text.items, self.selection.normalized(), ctx.worldRect(local_candidate));
    }

    fn textStyle(self: *const TextField, placeholder_text: bool) compose_style.TextStyle {
        return .{
            .font_families = self.font_families,
            .font_size = self.font_size,
            .font_weight = self.font_weight,
            .line_height = self.visual.line_height,
            .color = if (placeholder_text) self.placeholderColor() else self.textColor(),
            .wrap = if (self.multiline) .word else .none,
        };
    }

    fn contentInsets(self: *const TextField) geometry.Insets {
        return self.visual.content_insets orelse .{ .left = 9, .right = 9, .top = 6, .bottom = 6 };
    }

    fn contentPadding(self: *const TextField) layout.LengthEdges {
        const insets = self.contentInsets();
        return .{
            .top = .{ .points = insets.top },
            .right = .{ .points = insets.right },
            .bottom = .{ .points = insets.bottom },
            .left = .{ .points = insets.left },
        };
    }

    fn surfaceColor(self: *const TextField) geometry.Color {
        return self.visual.surface_color orelse self.theme.surface;
    }

    fn borderColor(self: *const TextField) geometry.Color {
        return self.visual.border_color orelse self.theme.border;
    }

    fn radius(self: *const TextField) f32 {
        return self.visual.radius orelse self.theme.radius;
    }

    fn textColor(self: *const TextField) geometry.Color {
        return self.visual.text_color orelse self.theme.text;
    }

    fn placeholderColor(self: *const TextField) geometry.Color {
        return self.visual.placeholder_color orelse self.theme.muted_text;
    }

    fn minimumLineHeight(self: *const TextField) f32 {
        return self.visual.line_height orelse self.font_size * 1.35;
    }

    fn offsetAtPoint(self: *TextField, screen_point: geometry.Point) Error!usize {
        const services = self.text_services orelse return error.TextUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const display = try self.displayText(arena.allocator());
        const empty = display.logical.len == 0;
        const shown = if (empty) self.placeholder else display.shown;
        if (empty) return 0;
        const local = screen_point.sub(self.last_content_bounds.origin).add(self.scroll_offset);
        const hit = try services.hitTest(shown, self.textStyle(false), self.last_content_bounds.size.width, local);
        return self.sourceOffsetForDisplay(hit.utf8_offset, display);
    }

    fn currentCaretRect(self: *TextField) Error!geometry.Rect {
        const services = self.text_services orelse return error.TextUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const display = try self.displayText(arena.allocator());
        const normalized = self.selection.normalized();
        const empty = display.logical.len == 0;
        const shown = if (empty) self.placeholder else display.shown;
        var display_offset = self.displayOffsetForSource(self.selection.end, display);
        if (self.composition_active) display_offset = self.displayOffsetForSource(normalized.start, display) + self.displayOffsetWithinMarked(self.marked_selection.end);
        var rect = try services.caretRect(shown, self.textStyle(empty), self.last_content_bounds.size.width, display_offset, .downstream);
        rect.origin = rect.origin.add(self.last_content_bounds.origin.sub(self.scroll_offset));
        return rect;
    }

    fn displayOffsetForSource(self: *const TextField, source_offset: usize, display: DisplayText) usize {
        const combined_offset = if (self.composition_active) blk: {
            const normalized = self.selection.normalized();
            break :blk if (source_offset <= normalized.start)
                source_offset
            else if (source_offset >= normalized.end)
                normalized.start + self.marked_text.items.len + source_offset - normalized.end
            else
                normalized.start;
        } else source_offset;
        if (!self.password) return @min(combined_offset, display.shown.len);
        const grapheme_index = graphemeCount(display.logical[0..@min(combined_offset, display.logical.len)]);
        return @min(grapheme_index * 3, display.shown.len);
    }

    fn sourceOffsetForDisplay(self: *const TextField, display_offset: usize, display: DisplayText) usize {
        const combined_offset = if (!self.password)
            @min(display_offset, display.logical.len)
        else
            byteOffsetForGrapheme(display.logical, @min(display_offset / 3, graphemeCount(display.logical)));
        if (!self.composition_active) return @min(combined_offset, self.text.items.len);
        const normalized = self.selection.normalized();
        if (combined_offset <= normalized.start) return combined_offset;
        if (combined_offset >= normalized.start + self.marked_text.items.len)
            return @min(normalized.end + combined_offset - normalized.start - self.marked_text.items.len, self.text.items.len);
        return normalized.start;
    }

    fn displayOffsetWithinMarked(self: *const TextField, marked_offset: usize) usize {
        const clamped = @min(marked_offset, self.marked_text.items.len);
        if (!self.password) return clamped;
        return graphemeCount(self.marked_text.items[0..clamped]) * 3;
    }

    fn extentConstraints(self: *const TextField, viewport_width: f32) layout.Constraints {
        return .{ .maximum = .{
            .width = if (self.multiline and std.math.isFinite(viewport_width)) @max(0, viewport_width) else std.math.inf(f32),
            .height = std.math.inf(f32),
        } };
    }

    fn measureExtent(
        self: *const TextField,
        services: custom.TextServices,
        shown: []const u8,
        style: compose_style.TextStyle,
        viewport_width: f32,
    ) Error!geometry.Size {
        var extent = try services.measure(shown, style, self.extentConstraints(viewport_width));
        if (!finiteNonNegativeSize(extent) or extent.width > std.math.floatMax(f32) - 4)
            return error.InvalidLayout;
        // A trailing caret has physical width even when it sits at the line's
        // final advance. Reserve a small logical gutter so clipping never
        // hides it at the maximum horizontal offset.
        extent.width += 4;
        return extent;
    }

    fn ensureCaretVisible(
        self: *TextField,
        services: custom.TextServices,
        shown: []const u8,
        style: compose_style.TextStyle,
        display: DisplayText,
        viewport: geometry.Size,
    ) Error!void {
        if (!finiteNonNegativeSize(viewport) or !finiteNonNegativeSize(self.last_text_extent))
            return error.InvalidLayout;
        self.clampScroll(viewport);
        if (!self.reveal_caret) return;

        const normalized = self.selection.normalized();
        const display_offset = if (self.composition_active)
            self.displayOffsetForSource(normalized.start, display) + self.displayOffsetWithinMarked(self.marked_selection.end)
        else
            self.displayOffsetForSource(self.selection.end, display);
        const caret = try services.caretRect(shown, style, viewport.width, display_offset, .downstream);
        const horizontal_margin = @min(4, viewport.width * 0.25);
        const vertical_margin = @min(2, viewport.height * 0.25);

        if (caret.minX() < self.scroll_offset.x + horizontal_margin) {
            self.scroll_offset.x = @max(0, caret.minX() - horizontal_margin);
        } else if (caret.maxX() > self.scroll_offset.x + viewport.width - horizontal_margin) {
            self.scroll_offset.x = caret.maxX() - viewport.width + horizontal_margin;
        }
        if (caret.minY() < self.scroll_offset.y + vertical_margin) {
            self.scroll_offset.y = @max(0, caret.minY() - vertical_margin);
        } else if (caret.maxY() > self.scroll_offset.y + viewport.height - vertical_margin) {
            self.scroll_offset.y = caret.maxY() - viewport.height + vertical_margin;
        }
        self.clampScroll(viewport);
        self.reveal_caret = false;
    }

    fn clampScroll(self: *TextField, viewport: geometry.Size) void {
        self.scroll_offset.x = clampOffset(self.scroll_offset.x, self.last_text_extent.width, viewport.width);
        self.scroll_offset.y = if (self.multiline)
            clampOffset(self.scroll_offset.y, self.last_text_extent.height, viewport.height)
        else
            0;
    }

    fn displayCombined(self: *const TextField, allocator: std.mem.Allocator) Error![]u8 {
        if (!self.composition_active) return allocator.dupe(u8, self.text.items);
        const normalized = self.selection.normalized();
        const length = try self.combinedLength();
        const combined = try allocator.alloc(u8, length);
        @memcpy(combined[0..normalized.start], self.text.items[0..normalized.start]);
        @memcpy(combined[normalized.start..][0..self.marked_text.items.len], self.marked_text.items);
        @memcpy(combined[normalized.start + self.marked_text.items.len ..], self.text.items[normalized.end..]);
        return combined;
    }

    fn combinedLength(self: *const TextField) Error!usize {
        if (!self.composition_active) return self.text.items.len;
        const normalized = self.selection.normalized();
        if (normalized.end > self.text.items.len) return error.InvalidConfiguration;
        return std.math.add(usize, self.text.items.len - (normalized.end - normalized.start), self.marked_text.items.len) catch
            return error.BudgetExceeded;
    }

    fn validateState(self: *const TextField) Error!void {
        if (!std.math.isFinite(self.font_size) or self.font_size <= 0 or self.font_size > 1_000_000)
            return error.InvalidConfiguration;
        try self.validateVisualConfig();
        if (!finiteNonNegativePoint(self.scroll_offset) or !finiteNonNegativeSize(self.last_text_extent))
            return error.InvalidConfiguration;
        if (self.semantic_role != .text_field and self.semantic_role != .search_field)
            return error.InvalidConfiguration;
        try validateUtf8(self.text.items);
        try validateUtf8(self.marked_text.items);
        try validateUtf8(self.placeholder);
        try validateUtf8(self.label);
        if (self.text.items.len > self.maximum_bytes) return error.BudgetExceeded;
        if (self.selection.start > self.text.items.len or self.selection.end > self.text.items.len or
            !utf8Boundary(self.text.items, self.selection.start) or !utf8Boundary(self.text.items, self.selection.end))
            return error.InvalidConfiguration;
        if (self.marked_selection.start > self.marked_selection.end or self.marked_selection.end > self.marked_text.items.len or
            !utf8Boundary(self.marked_text.items, self.marked_selection.start) or !utf8Boundary(self.marked_text.items, self.marked_selection.end))
            return error.InvalidConfiguration;
        if (!self.composition_active and (self.marked_text.items.len != 0 or self.marked_selection.start != 0 or self.marked_selection.end != 0))
            return error.InvalidConfiguration;
        if (try self.combinedLength() > self.maximum_bytes) return error.BudgetExceeded;
        const history_count = std.math.add(usize, self.undo_edits.items.len, self.redo_edits.items.len) catch
            return error.BudgetExceeded;
        if (history_count > self.maximum_history_entries)
            return error.BudgetExceeded;
        var history_bytes: usize = 0;
        for (self.undo_edits.items) |edit| history_bytes = std.math.add(usize, history_bytes, edit.byteCost()) catch
            return error.BudgetExceeded;
        for (self.redo_edits.items) |edit| history_bytes = std.math.add(usize, history_bytes, edit.byteCost()) catch
            return error.BudgetExceeded;
        if (history_bytes != self.history_bytes) return error.InvalidConfiguration;
        if (history_bytes > self.maximum_history_bytes) return error.BudgetExceeded;
    }

    fn validateVisualConfig(self: *const TextField) Error!void {
        if (self.visual.content_insets) |insets| {
            inline for (.{ insets.top, insets.right, insets.bottom, insets.left }) |amount| {
                if (!std.math.isFinite(amount) or amount < 0) return error.InvalidConfiguration;
            }
        }
        if (self.visual.surface_color) |color| if (!validColor(color)) return error.InvalidConfiguration;
        if (self.visual.border_color) |color| if (!validColor(color)) return error.InvalidConfiguration;
        if (self.visual.text_color) |color| if (!validColor(color)) return error.InvalidConfiguration;
        if (self.visual.placeholder_color) |color| if (!validColor(color)) return error.InvalidConfiguration;
        if (self.visual.radius) |configured_radius| if (!std.math.isFinite(configured_radius) or configured_radius < 0) return error.InvalidConfiguration;
        if (self.visual.line_height) |line_height| if (!std.math.isFinite(line_height) or
            line_height <= 0 or line_height > 1_000_000)
            return error.InvalidConfiguration;
    }
};

fn clampOffset(value: f32, extent: f32, viewport: f32) f32 {
    if (!std.math.isFinite(value) or !std.math.isFinite(extent) or !std.math.isFinite(viewport) or
        value <= 0 or extent <= viewport or viewport <= 0)
        return 0;
    return std.math.clamp(value, 0, extent - viewport);
}

fn finiteNonNegativePoint(value: geometry.Point) bool {
    return std.math.isFinite(value.x) and std.math.isFinite(value.y) and value.x >= 0 and value.y >= 0;
}

fn finiteNonNegativeSize(value: geometry.Size) bool {
    return std.math.isFinite(value.width) and std.math.isFinite(value.height) and value.width >= 0 and value.height >= 0;
}

fn validColor(value: geometry.Color) bool {
    return std.math.isFinite(value.r) and std.math.isFinite(value.g) and std.math.isFinite(value.b) and
        std.math.isFinite(value.a) and value.a >= 0 and value.a <= 1;
}

fn validateUtf8(bytes: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidUtf8;
    var iterator: unicode.Iterator = .{ .bytes = bytes };
    while (try iterator.next()) |_| {}
}

fn graphemeCount(bytes: []const u8) usize {
    var iterator: unicode.GraphemeIterator = .{ .bytes = bytes };
    var count: usize = 0;
    while (iterator.next() catch null) |_| count += 1;
    return count;
}

fn byteOffsetForGrapheme(bytes: []const u8, target: usize) usize {
    var iterator: unicode.GraphemeIterator = .{ .bytes = bytes };
    var count: usize = 0;
    while (iterator.next() catch null) |cluster| {
        if (count == target) return @intFromPtr(cluster.ptr) - @intFromPtr(bytes.ptr);
        count += 1;
    }
    return bytes.len;
}

fn previousBoundary(bytes: []const u8, cursor: usize) usize {
    var iterator: unicode.GraphemeIterator = .{ .bytes = bytes };
    var previous: usize = 0;
    while (iterator.next() catch null) |cluster| {
        const start = @intFromPtr(cluster.ptr) - @intFromPtr(bytes.ptr);
        if (start >= cursor) break;
        previous = start;
    }
    return previous;
}

fn nextBoundary(bytes: []const u8, cursor: usize) usize {
    var iterator: unicode.GraphemeIterator = .{ .bytes = bytes };
    while (iterator.next() catch null) |cluster| {
        const end = @intFromPtr(cluster.ptr) - @intFromPtr(bytes.ptr) + cluster.len;
        if (end > cursor) return end;
    }
    return bytes.len;
}

fn previousWordBoundary(bytes: []const u8, cursor: usize) Error!usize {
    var iterator: unicode.WordIterator = .{ .bytes = bytes };
    var previous: usize = 0;
    while (try iterator.next()) |segment| {
        if (segment.end >= cursor) return segment.start;
        previous = segment.end;
    }
    return previous;
}

fn nextWordBoundary(bytes: []const u8, cursor: usize) Error!usize {
    var iterator: unicode.WordIterator = .{ .bytes = bytes };
    while (try iterator.next()) |segment| if (segment.end > cursor) return segment.end;
    return bytes.len;
}

fn wordRange(bytes: []const u8, cursor: usize) Error!input.TextRange {
    if (bytes.len == 0) return .{};
    const offset = @min(cursor, bytes.len);
    var iterator: unicode.WordIterator = .{ .bytes = bytes };
    var previous: input.TextRange = .{};
    while (try iterator.next()) |segment| {
        const range: input.TextRange = .{ .start = segment.start, .end = segment.end };
        if (offset < segment.end or (offset == bytes.len and segment.end == bytes.len)) return range;
        previous = range;
    }
    return previous;
}

fn lineStart(bytes: []const u8, cursor: usize) usize {
    const offset = @min(cursor, bytes.len);
    return if (std.mem.lastIndexOfScalar(u8, bytes[0..offset], '\n')) |newline| newline + 1 else 0;
}

fn lineEnd(bytes: []const u8, cursor: usize) usize {
    const offset = @min(cursor, bytes.len);
    return if (std.mem.indexOfScalarPos(u8, bytes, offset, '\n')) |newline| newline else bytes.len;
}

fn lineRange(bytes: []const u8, cursor: usize) input.TextRange {
    const start = lineStart(bytes, cursor);
    var end = lineEnd(bytes, cursor);
    if (end < bytes.len) end += 1;
    return .{ .start = start, .end = end };
}

fn clampRange(bytes: []const u8, range: input.TextRange) input.TextRange {
    const normalized = range.normalized();
    return .{ .start = clampBoundary(bytes, normalized.start), .end = clampBoundary(bytes, normalized.end) };
}

fn utf8Boundary(bytes: []const u8, index: usize) bool {
    return index == bytes.len or (index < bytes.len and bytes[index] & 0xc0 != 0x80);
}

fn clampBoundary(bytes: []const u8, requested: usize) usize {
    const target = @min(requested, bytes.len);
    if (target == bytes.len) return target;
    var iterator: unicode.GraphemeIterator = .{ .bytes = bytes };
    var previous: usize = 0;
    while (iterator.next() catch null) |cluster| {
        const start = @intFromPtr(cluster.ptr) - @intFromPtr(bytes.ptr);
        if (start > target) return previous;
        if (start == target) return start;
        previous = start;
    }
    return previous;
}
