const std = @import("std");
const win = @import("abi.zig");
const uia = @import("uia_abi.zig");

pub const Selection = struct {
    start: usize,
    end: usize,

    fn normalized(self: Selection) Selection {
        return if (self.start <= self.end) self else .{ .start = self.end, .end = self.start };
    }
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    context: *anyopaque,
    query_fn: *const fn (*anyopaque, *const win.GUID, *?*anyopaque) win.HRESULT,
    retain_fn: *const fn (*anyopaque) u32,
    release_fn: *const fn (*anyopaque) u32,
    available_fn: *const fn (*anyopaque) bool,
    value_fn: *const fn (*anyopaque) []const u16,
    selection_fn: *const fn (*anyopaque) ?Selection,
    bounds_fn: *const fn (*anyopaque) uia.Rect,
    enclosing_fn: *const fn (*anyopaque) *uia.Object,
    select_fn: *const fn (*anyopaque, Selection) win.HRESULT,
    read_only_fn: *const fn (*anyopaque) bool,
    hidden_fn: *const fn (*anyopaque) bool,
    multiline_fn: *const fn (*anyopaque) bool,
    selectable_fn: *const fn (*anyopaque) bool,

    fn query(self: Owner, id: *const win.GUID, output: *?*anyopaque) win.HRESULT {
        return self.query_fn(self.context, id, output);
    }

    fn retain(self: Owner) u32 {
        return self.retain_fn(self.context);
    }

    fn release(self: Owner) u32 {
        return self.release_fn(self.context);
    }

    fn available(self: Owner) bool {
        return self.available_fn(self.context);
    }

    fn value(self: Owner) []const u16 {
        return self.value_fn(self.context);
    }

    fn selection(self: Owner) ?Selection {
        return self.selection_fn(self.context);
    }

    fn bounds(self: Owner) uia.Rect {
        return self.bounds_fn(self.context);
    }

    fn enclosing(self: Owner) *uia.Object {
        return self.enclosing_fn(self.context);
    }

    fn select(self: Owner, selection_value: Selection) win.HRESULT {
        return self.select_fn(self.context, selection_value);
    }

    fn readOnly(self: Owner) bool {
        return self.read_only_fn(self.context);
    }

    fn hidden(self: Owner) bool {
        return self.hidden_fn(self.context);
    }

    fn multiline(self: Owner) bool {
        return self.multiline_fn(self.context);
    }

    fn selectable(self: Owner) bool {
        return self.selectable_fn(self.context);
    }
};

pub const Provider = struct {
    object: uia.Object = .{ .vtable = &provider_vtable },
    owner: Owner,

    pub fn init(owner: Owner) Provider {
        return .{ .owner = owner };
    }
};

const Range = struct {
    object: uia.Object = .{ .vtable = &range_vtable },
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    owner: Owner,
    start: usize,
    end: usize,

    fn create(owner: Owner, start: usize, end: usize) ?*Range {
        const self = owner.allocator.create(Range) catch return null;
        _ = owner.retain();
        const length = owner.value().len;
        self.* = .{
            .owner = owner,
            .start = @min(start, length),
            .end = @min(end, length),
        };
        if (self.start > self.end) std.mem.swap(usize, &self.start, &self.end);
        return self;
    }

    fn retain(self: *Range) u32 {
        return self.references.fetchAdd(1, .monotonic) + 1;
    }

    fn release(self: *Range) u32 {
        const previous = self.references.fetchSub(1, .acq_rel);
        if (previous == 1) {
            const owner = self.owner;
            owner.allocator.destroy(self);
            _ = owner.release();
            return 0;
        }
        return previous - 1;
    }

    fn clamp(self: *Range) void {
        const length = self.owner.value().len;
        self.start = @min(self.start, length);
        self.end = @min(self.end, length);
        if (self.start > self.end) std.mem.swap(usize, &self.start, &self.end);
    }
};

const provider_vtable: uia.TextProviderVTable = .{
    .query_interface = providerQuery,
    .add_ref = providerAddRef,
    .release = providerRelease,
    .get_selection = providerGetSelection,
    .get_visible_ranges = providerGetVisibleRanges,
    .range_from_child = providerRangeFromChild,
    .range_from_point = providerRangeFromPoint,
    .get_document_range = providerDocumentRange,
    .get_supported_selection = providerSupportedSelection,
};

fn providerParent(object: *uia.Object) *Provider {
    return @alignCast(@fieldParentPtr("object", object));
}

fn providerQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    return providerParent(object).owner.query(id, output);
}

fn providerAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return providerParent(object).owner.retain();
}

fn providerRelease(object: *uia.Object) callconv(.winapi) u32 {
    return providerParent(object).owner.release();
}

fn providerGetSelection(object: *uia.Object, output: *?*uia.SafeArray) callconv(.winapi) win.HRESULT {
    const owner = providerParent(object).owner;
    output.* = null;
    if (!owner.available()) return uia.element_not_available;
    if (!owner.selectable()) return emptyUnknownArray(output);
    const selected = (owner.selection() orelse Selection{ .start = 0, .end = 0 }).normalized();
    return oneRangeArray(owner, selected.start, selected.end, output);
}

fn providerGetVisibleRanges(object: *uia.Object, output: *?*uia.SafeArray) callconv(.winapi) win.HRESULT {
    const owner = providerParent(object).owner;
    output.* = null;
    if (!owner.available()) return uia.element_not_available;
    return oneRangeArray(owner, 0, owner.value().len, output);
}

fn providerRangeFromChild(object: *uia.Object, _: *uia.Object, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const owner = providerParent(object).owner;
    output.* = null;
    if (!owner.available()) return uia.element_not_available;
    return win.E_INVALIDARG;
}

fn providerRangeFromPoint(object: *uia.Object, point: uia.Point, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const owner = providerParent(object).owner;
    output.* = null;
    if (!owner.available()) return uia.element_not_available;
    const bounds = owner.bounds();
    const value = owner.value();
    var position: usize = 0;
    if (value.len != 0 and bounds.width > 0) {
        const ratio = std.math.clamp((point.x - bounds.left) / bounds.width, 0, 1);
        position = nearestScalarBoundary(value, @intFromFloat(@round(ratio * @as(f64, @floatFromInt(value.len)))));
    }
    const range = Range.create(owner, position, position) orelse return uia.out_of_memory;
    output.* = &range.object;
    return win.S_OK;
}

fn providerDocumentRange(object: *uia.Object, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const owner = providerParent(object).owner;
    output.* = null;
    if (!owner.available()) return uia.element_not_available;
    const range = Range.create(owner, 0, owner.value().len) orelse return uia.out_of_memory;
    output.* = &range.object;
    return win.S_OK;
}

fn providerSupportedSelection(object: *uia.Object, output: *i32) callconv(.winapi) win.HRESULT {
    const owner = providerParent(object).owner;
    if (!owner.available()) return uia.element_not_available;
    output.* = if (owner.selectable()) uia.text_selection_single else uia.text_selection_none;
    return win.S_OK;
}

fn emptyUnknownArray(output: *?*uia.SafeArray) win.HRESULT {
    output.* = uia.SafeArrayCreateVector(uia.variant_unknown, 0, 0) orelse return uia.out_of_memory;
    return win.S_OK;
}

fn oneRangeArray(owner: Owner, start: usize, end: usize, output: *?*uia.SafeArray) win.HRESULT {
    const range = Range.create(owner, start, end) orelse return uia.out_of_memory;
    var range_owned = true;
    defer {
        if (range_owned) _ = range.release();
    }
    const array = uia.SafeArrayCreateVector(uia.variant_unknown, 0, 1) orelse return uia.out_of_memory;
    var array_owned = true;
    defer {
        if (array_owned) _ = uia.SafeArrayDestroy(array);
    }
    var raw: ?*anyopaque = null;
    if (!win.succeeded(uia.SafeArrayAccessData(array, &raw)) or raw == null) return win.E_FAIL;
    const values: [*]?*uia.Object = @ptrCast(@alignCast(raw.?));
    values[0] = &range.object;
    range_owned = false;
    if (!win.succeeded(uia.SafeArrayUnaccessData(array))) return win.E_FAIL;
    output.* = array;
    array_owned = false;
    return win.S_OK;
}

const range_vtable: uia.TextRangeVTable = .{
    .query_interface = rangeQuery,
    .add_ref = rangeAddRef,
    .release = rangeRelease,
    .clone = rangeClone,
    .compare = rangeCompare,
    .compare_endpoints = rangeCompareEndpoints,
    .expand_to_enclosing_unit = rangeExpand,
    .find_attribute = rangeFindAttribute,
    .find_text = rangeFindText,
    .get_attribute_value = rangeGetAttribute,
    .get_bounding_rectangles = rangeGetBounds,
    .get_enclosing_element = rangeGetEnclosing,
    .get_text = rangeGetText,
    .move = rangeMove,
    .move_endpoint_by_unit = rangeMoveEndpointByUnit,
    .move_endpoint_by_range = rangeMoveEndpointByRange,
    .select = rangeSelect,
    .add_to_selection = rangeAddToSelection,
    .remove_from_selection = rangeRemoveFromSelection,
    .scroll_into_view = rangeScrollIntoView,
    .get_children = rangeGetChildren,
};

fn rangeParent(object: *uia.Object) *Range {
    return @alignCast(@fieldParentPtr("object", object));
}

fn checkedRange(object: *uia.Object) ?*Range {
    if (object.vtable != @as(*const anyopaque, @ptrCast(&range_vtable))) return null;
    return rangeParent(object);
}

fn rangeQuery(object: *uia.Object, id: *const win.GUID, output: *?*anyopaque) callconv(.winapi) win.HRESULT {
    output.* = null;
    if (!id.eql(uia.iid_iunknown) and !id.eql(uia.iid_text_range_provider)) return win.E_NOINTERFACE;
    const self = rangeParent(object);
    output.* = &self.object;
    _ = self.retain();
    return win.S_OK;
}

fn rangeAddRef(object: *uia.Object) callconv(.winapi) u32 {
    return rangeParent(object).retain();
}

fn rangeRelease(object: *uia.Object) callconv(.winapi) u32 {
    return rangeParent(object).release();
}

fn rangeClone(object: *uia.Object, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = null;
    if (!self.owner.available()) return uia.element_not_available;
    self.clamp();
    const copy = Range.create(self.owner, self.start, self.end) orelse return uia.out_of_memory;
    output.* = &copy.object;
    return win.S_OK;
}

fn rangeCompare(object: *uia.Object, other_object: *uia.Object, output: *win.BOOL) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    const other = checkedRange(other_object) orelse return win.E_INVALIDARG;
    if (!self.owner.available() or !other.owner.available()) return uia.element_not_available;
    self.clamp();
    other.clamp();
    output.* = @intFromBool(self.owner.context == other.owner.context and self.start == other.start and self.end == other.end);
    return win.S_OK;
}

fn rangeCompareEndpoints(object: *uia.Object, endpoint: i32, other_object: *uia.Object, other_endpoint: i32, output: *i32) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    const other = checkedRange(other_object) orelse return win.E_INVALIDARG;
    if (!self.owner.available() or !other.owner.available()) return uia.element_not_available;
    if (self.owner.context != other.owner.context) return win.E_INVALIDARG;
    self.clamp();
    other.clamp();
    const left = endpointValue(self, endpoint) orelse return win.E_INVALIDARG;
    const right = endpointValue(other, other_endpoint) orelse return win.E_INVALIDARG;
    output.* = if (left < right) -1 else if (left > right) 1 else 0;
    return win.S_OK;
}

fn rangeExpand(object: *uia.Object, unit: i32) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (!self.owner.available()) return uia.element_not_available;
    self.clamp();
    const enclosing = unitRange(self.owner.value(), self.start, unit) orelse return win.E_INVALIDARG;
    self.start = enclosing.start;
    self.end = enclosing.end;
    return win.S_OK;
}

fn rangeFindAttribute(object: *uia.Object, attribute: i32, value: uia.Variant, _: win.BOOL, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = null;
    if (!self.owner.available()) return uia.element_not_available;
    const matches = switch (attribute) {
        uia.text_attribute_is_read_only => value.variant_type == uia.variant_bool and (value.data.boolean != 0) == self.owner.readOnly(),
        uia.text_attribute_is_hidden => value.variant_type == uia.variant_bool and (value.data.boolean != 0) == self.owner.hidden(),
        else => false,
    };
    if (!matches) return win.S_OK;
    return rangeClone(object, output);
}

fn rangeFindText(object: *uia.Object, needle_bstr: uia.BStr, backward: win.BOOL, ignore_case: win.BOOL, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = null;
    if (!self.owner.available()) return uia.element_not_available;
    self.clamp();
    const needle_length = uia.SysStringLen(needle_bstr);
    if (needle_length == 0) return win.S_OK;
    const needle_pointer = needle_bstr orelse return win.S_OK;
    const needle = needle_pointer[0..needle_length];
    const value = self.owner.value();
    if (needle.len > self.end - self.start) return win.S_OK;
    const found = findUnits(value[self.start..self.end], needle, backward != 0, ignore_case != 0) orelse return win.S_OK;
    const result = Range.create(self.owner, self.start + found, self.start + found + needle.len) orelse return uia.out_of_memory;
    output.* = &result.object;
    return win.S_OK;
}

fn rangeGetAttribute(object: *uia.Object, attribute: i32, output: *uia.Variant) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = uia.emptyVariant();
    if (!self.owner.available()) return uia.element_not_available;
    output.* = switch (attribute) {
        uia.text_attribute_is_read_only => uia.boolVariant(self.owner.readOnly()),
        uia.text_attribute_is_hidden => uia.boolVariant(self.owner.hidden()),
        else => return reservedNotSupported(output),
    };
    return win.S_OK;
}

fn reservedNotSupported(output: *uia.Variant) win.HRESULT {
    var reserved: ?*uia.Object = null;
    const result = uia.UiaGetReservedNotSupportedValue(&reserved);
    if (!win.succeeded(result)) return result;
    output.* = uia.unknownVariant(reserved);
    return win.S_OK;
}

fn rangeGetBounds(object: *uia.Object, output: *?*uia.SafeArray) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = null;
    if (!self.owner.available()) return uia.element_not_available;
    self.clamp();
    const array = uia.SafeArrayCreateVector(uia.variant_r8, 0, 4) orelse return uia.out_of_memory;
    var array_owned = true;
    defer {
        if (array_owned) _ = uia.SafeArrayDestroy(array);
    }
    var raw: ?*anyopaque = null;
    if (!win.succeeded(uia.SafeArrayAccessData(array, &raw)) or raw == null) return win.E_FAIL;
    const values: [*]f64 = @ptrCast(@alignCast(raw.?));
    const bounds = self.owner.bounds();
    const length = self.owner.value().len;
    if (self.owner.multiline() or length == 0) {
        values[0] = bounds.left;
        values[1] = bounds.top;
        values[2] = if (length == 0) 1 else bounds.width;
        values[3] = bounds.height;
    } else {
        const start_ratio = @as(f64, @floatFromInt(self.start)) / @as(f64, @floatFromInt(length));
        const end_ratio = @as(f64, @floatFromInt(self.end)) / @as(f64, @floatFromInt(length));
        values[0] = bounds.left + bounds.width * start_ratio;
        values[1] = bounds.top;
        values[2] = if (self.start == self.end) 1 else bounds.width * (end_ratio - start_ratio);
        values[3] = bounds.height;
    }
    if (!win.succeeded(uia.SafeArrayUnaccessData(array))) return win.E_FAIL;
    output.* = array;
    array_owned = false;
    return win.S_OK;
}

fn rangeGetEnclosing(object: *uia.Object, output: *?*uia.Object) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = null;
    if (!self.owner.available()) return uia.element_not_available;
    output.* = self.owner.enclosing();
    _ = self.owner.retain();
    return win.S_OK;
}

fn rangeGetText(object: *uia.Object, maximum: i32, output: *uia.BStr) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = null;
    if (!self.owner.available()) return uia.element_not_available;
    if (maximum < -1) return win.E_INVALIDARG;
    self.clamp();
    var end = self.end;
    if (maximum >= 0) end = @min(end, self.start + @as(usize, @intCast(maximum)));
    if (end < self.end and end > self.start and isHighSurrogate(self.owner.value()[end - 1])) end -= 1;
    const units = self.owner.value()[self.start..end];
    output.* = uia.SysAllocStringLen(if (units.len == 0) null else units.ptr, @intCast(units.len));
    if (output.* == null and units.len != 0) return uia.out_of_memory;
    return win.S_OK;
}

fn rangeMove(object: *uia.Object, unit: i32, count: i32, output: *i32) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = 0;
    if (!self.owner.available()) return uia.element_not_available;
    self.clamp();
    var current = unitRange(self.owner.value(), self.start, unit) orelse return win.E_INVALIDARG;
    if (count > 0) {
        while (output.* < count) {
            const next = nextUnit(self.owner.value(), current, unit) orelse break;
            current = next;
            output.* += 1;
        }
    } else if (count < 0) {
        while (output.* > count) {
            const previous = previousUnit(self.owner.value(), current, unit) orelse break;
            current = previous;
            output.* -= 1;
        }
    }
    self.start = current.start;
    self.end = current.end;
    return win.S_OK;
}

fn rangeMoveEndpointByUnit(object: *uia.Object, endpoint: i32, unit: i32, count: i32, output: *i32) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = 0;
    if (!self.owner.available()) return uia.element_not_available;
    self.clamp();
    var position = endpointValue(self, endpoint) orelse return win.E_INVALIDARG;
    if (unit < uia.text_unit_character or unit > uia.text_unit_document) return win.E_INVALIDARG;
    if (count > 0) {
        while (output.* < count) {
            const next = nextBoundary(self.owner.value(), position, unit);
            if (next == position) break;
            position = next;
            output.* += 1;
        }
    } else if (count < 0) {
        while (output.* > count) {
            const previous = previousBoundary(self.owner.value(), position, unit);
            if (previous == position) break;
            position = previous;
            output.* -= 1;
        }
    }
    if (endpoint == uia.text_endpoint_start) {
        self.start = position;
        if (self.start > self.end) self.end = self.start;
    } else {
        self.end = position;
        if (self.end < self.start) self.start = self.end;
    }
    return win.S_OK;
}

fn rangeMoveEndpointByRange(object: *uia.Object, endpoint: i32, other_object: *uia.Object, other_endpoint: i32) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    const other = checkedRange(other_object) orelse return win.E_INVALIDARG;
    if (!self.owner.available() or !other.owner.available()) return uia.element_not_available;
    if (self.owner.context != other.owner.context) return win.E_INVALIDARG;
    self.clamp();
    other.clamp();
    const value = endpointValue(other, other_endpoint) orelse return win.E_INVALIDARG;
    if (endpoint == uia.text_endpoint_start) {
        self.start = value;
        if (self.start > self.end) self.end = self.start;
    } else if (endpoint == uia.text_endpoint_end) {
        self.end = value;
        if (self.end < self.start) self.start = self.end;
    } else return win.E_INVALIDARG;
    return win.S_OK;
}

fn rangeSelect(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (!self.owner.available()) return uia.element_not_available;
    if (!self.owner.selectable()) return uia.not_supported;
    self.clamp();
    return self.owner.select(.{ .start = self.start, .end = self.end });
}

fn rangeAddToSelection(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (!self.owner.available()) return uia.element_not_available;
    if (!self.owner.selectable()) return uia.not_supported;
    return uia.invalid_operation;
}

fn rangeRemoveFromSelection(object: *uia.Object) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    if (!self.owner.available()) return uia.element_not_available;
    if (!self.owner.selectable()) return uia.not_supported;
    self.clamp();
    return self.owner.select(.{ .start = self.end, .end = self.end });
}

fn rangeScrollIntoView(object: *uia.Object, _: win.BOOL) callconv(.winapi) win.HRESULT {
    if (!rangeParent(object).owner.available()) return uia.element_not_available;
    return win.S_OK;
}

fn rangeGetChildren(object: *uia.Object, output: *?*uia.SafeArray) callconv(.winapi) win.HRESULT {
    const self = rangeParent(object);
    output.* = null;
    if (!self.owner.available()) return uia.element_not_available;
    output.* = uia.SafeArrayCreateVector(uia.variant_unknown, 0, 0) orelse return uia.out_of_memory;
    return win.S_OK;
}

fn endpointValue(range: *const Range, endpoint: i32) ?usize {
    return switch (endpoint) {
        uia.text_endpoint_start => range.start,
        uia.text_endpoint_end => range.end,
        else => null,
    };
}

fn findUnits(haystack: []const u16, needle: []const u16, backward: bool, ignore_case: bool) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    if (backward) {
        var index = haystack.len - needle.len + 1;
        while (index != 0) {
            index -= 1;
            if (unitsEqual(haystack[index..][0..needle.len], needle, ignore_case)) return index;
        }
        return null;
    }
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (unitsEqual(haystack[index..][0..needle.len], needle, ignore_case)) return index;
    }
    return null;
}

fn unitsEqual(left: []const u16, right: []const u16, ignore_case: bool) bool {
    for (left, right) |a, b| if (a != b and (!ignore_case or foldAscii(a) != foldAscii(b))) return false;
    return true;
}

fn foldAscii(value: u16) u16 {
    return if (value >= 'A' and value <= 'Z') value + ('a' - 'A') else value;
}

fn unitRange(value: []const u16, position_value: usize, unit: i32) ?Selection {
    const position = nearestScalarBoundary(value, @min(position_value, value.len));
    return switch (unit) {
        uia.text_unit_character => characterRange(value, position),
        uia.text_unit_word => tokenRange(value, position),
        uia.text_unit_line => lineRange(value, position),
        uia.text_unit_paragraph => paragraphRange(value, position),
        uia.text_unit_format, uia.text_unit_page, uia.text_unit_document => .{ .start = 0, .end = value.len },
        else => null,
    };
}

fn nextUnit(value: []const u16, current: Selection, unit: i32) ?Selection {
    if (current.end >= value.len or unit == uia.text_unit_document or unit == uia.text_unit_page or unit == uia.text_unit_format) return null;
    return unitRange(value, current.end, unit);
}

fn previousUnit(value: []const u16, current: Selection, unit: i32) ?Selection {
    if (current.start == 0 or unit == uia.text_unit_document or unit == uia.text_unit_page or unit == uia.text_unit_format) return null;
    return unitRange(value, previousScalar(value, current.start), unit);
}

fn nextBoundary(value: []const u16, position: usize, unit: i32) usize {
    if (position >= value.len) return value.len;
    if (unit == uia.text_unit_character) return nextScalar(value, position);
    const current = unitRange(value, position, unit) orelse return position;
    return current.end;
}

fn previousBoundary(value: []const u16, position: usize, unit: i32) usize {
    if (position == 0) return 0;
    if (unit == uia.text_unit_character) return previousScalar(value, position);
    const previous = previousScalar(value, position);
    const current = unitRange(value, previous, unit) orelse return position;
    return current.start;
}

fn characterRange(value: []const u16, position: usize) Selection {
    if (value.len == 0) return .{ .start = 0, .end = 0 };
    const start = if (position == value.len) previousScalar(value, position) else position;
    return .{ .start = start, .end = nextScalar(value, start) };
}

const TokenClass = enum { word, space, punctuation };

fn tokenRange(value: []const u16, position: usize) Selection {
    if (value.len == 0) return .{ .start = 0, .end = 0 };
    var anchor = if (position == value.len) previousScalar(value, position) else position;
    anchor = nearestScalarBoundary(value, anchor);
    const class = tokenClass(scalarAt(value, anchor).value);
    var start = anchor;
    while (start != 0) {
        const previous = previousScalar(value, start);
        if (tokenClass(scalarAt(value, previous).value) != class) break;
        start = previous;
    }
    var end = nextScalar(value, anchor);
    while (end < value.len and tokenClass(scalarAt(value, end).value) == class) end = nextScalar(value, end);
    return .{ .start = start, .end = end };
}

fn lineRange(value: []const u16, position: usize) Selection {
    var start = @min(position, value.len);
    while (start != 0) {
        const previous = previousScalar(value, start);
        if (isLineBreak(scalarAt(value, previous).value)) break;
        start = previous;
    }
    var end = @min(position, value.len);
    while (end < value.len) {
        const scalar = scalarAt(value, end);
        end = scalar.end;
        if (isLineBreak(scalar.value)) break;
    }
    return .{ .start = start, .end = end };
}

fn paragraphRange(value: []const u16, position: usize) Selection {
    var start = @min(position, value.len);
    while (start != 0) {
        const previous = previousScalar(value, start);
        const scalar = scalarAt(value, previous).value;
        if (scalar == 0x2029 or (scalar == '\n' and previous != 0 and scalarAt(value, previousScalar(value, previous)).value == '\n')) break;
        start = previous;
    }
    var end = @min(position, value.len);
    var previous_was_newline = false;
    while (end < value.len) {
        const scalar = scalarAt(value, end);
        end = scalar.end;
        if (scalar.value == 0x2029 or (scalar.value == '\n' and previous_was_newline)) break;
        previous_was_newline = scalar.value == '\n';
    }
    return .{ .start = start, .end = end };
}

fn tokenClass(value: u21) TokenClass {
    if (isSpace(value)) return .space;
    if ((value >= '0' and value <= '9') or (value >= 'A' and value <= 'Z') or (value >= 'a' and value <= 'z') or value == '_' or value >= 0x80 and !isPunctuation(value)) return .word;
    return .punctuation;
}

fn isSpace(value: u21) bool {
    return switch (value) {
        0x0009...0x000d, 0x0020, 0x0085, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn isPunctuation(value: u21) bool {
    return switch (value) {
        0x0021...0x002f, 0x003a...0x0040, 0x005b...0x0060, 0x007b...0x007e, 0x2000...0x206f, 0x2e00...0x2e7f, 0x3001...0x303f => true,
        else => false,
    };
}

fn isLineBreak(value: u21) bool {
    return value == '\n' or value == '\r' or value == 0x2028 or value == 0x2029;
}

const Decoded = struct { value: u21, end: usize };

fn scalarAt(value: []const u16, index: usize) Decoded {
    const first = value[index];
    if (isHighSurrogate(first) and index + 1 < value.len and isLowSurrogate(value[index + 1])) {
        const high: u21 = first - 0xd800;
        const low: u21 = value[index + 1] - 0xdc00;
        return .{ .value = 0x10000 + (high << 10) + low, .end = index + 2 };
    }
    return .{ .value = first, .end = index + 1 };
}

fn nextScalar(value: []const u16, position: usize) usize {
    if (position >= value.len) return value.len;
    return scalarAt(value, position).end;
}

fn previousScalar(value: []const u16, position: usize) usize {
    if (position == 0) return 0;
    var previous = position - 1;
    if (isLowSurrogate(value[previous]) and previous != 0 and isHighSurrogate(value[previous - 1])) previous -= 1;
    return previous;
}

fn nearestScalarBoundary(value: []const u16, position_value: usize) usize {
    var position = @min(position_value, value.len);
    if (position != 0 and position < value.len and isLowSurrogate(value[position]) and isHighSurrogate(value[position - 1])) position -= 1;
    return position;
}

fn isHighSurrogate(value: u16) bool {
    return value >= 0xd800 and value <= 0xdbff;
}

fn isLowSurrogate(value: u16) bool {
    return value >= 0xdc00 and value <= 0xdfff;
}
