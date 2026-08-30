const std = @import("std");
const win = @import("abi.zig");

pub const Object = extern struct { vtable: *const anyopaque };
pub const SafeArray = opaque {};
pub const BStr = ?[*:0]u16;

pub const VariantData = extern union {
    long_long: i64,
    long: i32,
    boolean: i16,
    double: f64,
    string: BStr,
    unknown: ?*Object,
    array: ?*SafeArray,
    raw: [16]u8,
};

pub const Variant = extern struct {
    variant_type: u16 = variant_empty,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    data: VariantData = .{ .raw = @splat(0) },
};

pub const Rect = extern struct { left: f64, top: f64, width: f64, height: f64 };
pub const Point = extern struct { x: f64, y: f64 };

pub const variant_empty: u16 = 0;
pub const variant_i4: u16 = 3;
pub const variant_r8: u16 = 5;
pub const variant_bstr: u16 = 8;
pub const variant_bool: u16 = 11;
pub const variant_unknown: u16 = 13;
pub const variant_true: i16 = -1;
pub const variant_false: i16 = 0;

pub const root_object_id: win.LPARAM = -25;
pub const append_runtime_id: i32 = 3;
pub const provider_server_side: i32 = 0x2;
/// Request COM apartment threading so UI Automation invokes the server-side
/// provider on the STA thread that owns ZigUI's mutable accessibility tree.
pub const provider_use_com_threading: i32 = 0x20;
pub const provider_owns_set_focus: i32 = 0x10;

pub const navigate_parent: i32 = 0;
pub const navigate_next_sibling: i32 = 1;
pub const navigate_previous_sibling: i32 = 2;
pub const navigate_first_child: i32 = 3;
pub const navigate_last_child: i32 = 4;

pub const structure_children_invalidated: i32 = 2;
pub const toggle_off: i32 = 0;
pub const toggle_on: i32 = 1;
pub const toggle_indeterminate: i32 = 2;
pub const expand_collapsed: i32 = 0;
pub const expand_expanded: i32 = 1;
pub const expand_partially: i32 = 2;
pub const expand_leaf: i32 = 3;

pub const automation_focus_changed_event: i32 = 20005;
pub const invoke_invoked_event: i32 = 20009;
pub const selection_item_selected_event: i32 = 20012;
pub const text_selection_changed_event: i32 = 20014;
pub const text_changed_event: i32 = 20015;

pub const invoke_pattern: i32 = 10000;
pub const value_pattern: i32 = 10002;
pub const range_value_pattern: i32 = 10003;
pub const expand_collapse_pattern: i32 = 10005;
pub const selection_item_pattern: i32 = 10010;
pub const toggle_pattern: i32 = 10015;
pub const text_pattern: i32 = 10014;

pub const text_unit_character: i32 = 0;
pub const text_unit_format: i32 = 1;
pub const text_unit_word: i32 = 2;
pub const text_unit_line: i32 = 3;
pub const text_unit_paragraph: i32 = 4;
pub const text_unit_page: i32 = 5;
pub const text_unit_document: i32 = 6;
pub const text_endpoint_start: i32 = 0;
pub const text_endpoint_end: i32 = 1;
pub const text_selection_none: i32 = 0;
pub const text_selection_single: i32 = 1;
pub const text_selection_multiple: i32 = 2;

pub const text_attribute_background_color: i32 = 40001;
pub const text_attribute_culture: i32 = 40004;
pub const text_attribute_font_name: i32 = 40005;
pub const text_attribute_font_size: i32 = 40006;
pub const text_attribute_foreground_color: i32 = 40008;
pub const text_attribute_is_hidden: i32 = 40013;
pub const text_attribute_is_read_only: i32 = 40015;
pub const text_attribute_flow_directions: i32 = 40028;

pub const property_control_type: i32 = 30003;
pub const property_name: i32 = 30005;
pub const property_has_keyboard_focus: i32 = 30008;
pub const property_is_keyboard_focusable: i32 = 30009;
pub const property_is_enabled: i32 = 30010;
pub const property_automation_id: i32 = 30011;
pub const property_class_name: i32 = 30012;
pub const property_help_text: i32 = 30013;
pub const property_is_control_element: i32 = 30016;
pub const property_is_content_element: i32 = 30017;
pub const property_is_password: i32 = 30019;
pub const property_native_window_handle: i32 = 30020;
pub const property_is_offscreen: i32 = 30022;
pub const property_framework_id: i32 = 30024;
pub const property_value_value: i32 = 30045;
pub const property_value_is_read_only: i32 = 30046;
pub const property_range_value: i32 = 30047;
pub const property_range_is_read_only: i32 = 30048;
pub const property_range_minimum: i32 = 30049;
pub const property_range_maximum: i32 = 30050;
pub const property_range_large_change: i32 = 30051;
pub const property_range_small_change: i32 = 30052;
pub const property_expand_state: i32 = 30070;
pub const property_selection_item_selected: i32 = 30079;
pub const property_toggle_state: i32 = 30086;

pub const control_button: i32 = 50000;
pub const control_checkbox: i32 = 50002;
pub const control_edit: i32 = 50004;
pub const control_hyperlink: i32 = 50005;
pub const control_image: i32 = 50006;
pub const control_list_item: i32 = 50007;
pub const control_list: i32 = 50008;
pub const control_menu: i32 = 50009;
pub const control_menu_item: i32 = 50011;
pub const control_progress: i32 = 50012;
pub const control_radio: i32 = 50013;
pub const control_slider: i32 = 50015;
pub const control_tab: i32 = 50018;
pub const control_tab_item: i32 = 50019;
pub const control_text: i32 = 50020;
pub const control_toolbar: i32 = 50021;
pub const control_tooltip: i32 = 50022;
pub const control_tree: i32 = 50023;
pub const control_tree_item: i32 = 50024;
pub const control_custom: i32 = 50025;
pub const control_group: i32 = 50026;
pub const control_data_grid: i32 = 50028;
pub const control_data_item: i32 = 50029;
pub const control_window: i32 = 50032;
pub const control_pane: i32 = 50033;
pub const control_separator: i32 = 50038;

pub const element_not_enabled: win.HRESULT = @bitCast(@as(u32, 0x80040200));
pub const element_not_available: win.HRESULT = @bitCast(@as(u32, 0x80040201));
pub const not_supported: win.HRESULT = @bitCast(@as(u32, 0x80040204));
pub const invalid_operation: win.HRESULT = @bitCast(@as(u32, 0x80131509));
pub const out_of_memory: win.HRESULT = @bitCast(@as(u32, 0x8007000e));

pub const iid_iunknown: win.GUID = guid(0x00000000, 0x0000, 0x0000, .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
pub const iid_simple: win.GUID = guid(0xd6dd68d1, 0x86fd, 0x4332, .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c });
pub const iid_fragment: win.GUID = guid(0xf7063da8, 0x8359, 0x439c, .{ 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87 });
pub const iid_fragment_root: win.GUID = guid(0x620ce2a5, 0xab8f, 0x40a9, .{ 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58 });
pub const iid_invoke: win.GUID = guid(0x54fcb24b, 0xe18e, 0x47a2, .{ 0xb4, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2 });
pub const iid_toggle: win.GUID = guid(0x56d00bd0, 0xc4f4, 0x433c, .{ 0xa8, 0x36, 0x1a, 0x52, 0xa5, 0x7e, 0x08, 0x92 });
pub const iid_range_value: win.GUID = guid(0x36dc7aef, 0x33e6, 0x4691, .{ 0xaf, 0xe1, 0x2b, 0xe7, 0x27, 0x4b, 0x3d, 0x33 });
pub const iid_value: win.GUID = guid(0xc7935180, 0x6fb3, 0x4201, .{ 0xb1, 0x74, 0x7d, 0xf7, 0x3a, 0xdb, 0xf6, 0x4a });
pub const iid_selection_item: win.GUID = guid(0x2acad808, 0xb2d4, 0x452d, .{ 0xa4, 0x07, 0x91, 0xff, 0x1a, 0xd1, 0x67, 0xb2 });
pub const iid_expand_collapse: win.GUID = guid(0xd847d3a5, 0xcab0, 0x4a98, .{ 0x8c, 0x32, 0xec, 0xb4, 0x5c, 0x59, 0xad, 0x24 });
pub const iid_text_provider: win.GUID = guid(0x3589c92c, 0x63f3, 0x4367, .{ 0x99, 0xbb, 0xad, 0xa6, 0x53, 0xb7, 0x7c, 0xf2 });
pub const iid_text_range_provider: win.GUID = guid(0x5347ad7b, 0xc355, 0x46f8, .{ 0xaf, 0xf5, 0x90, 0x90, 0x33, 0x58, 0x2f, 0x63 });

fn guid(data1: u32, data2: u16, data3: u16, data4: [8]u8) win.GUID {
    return .{ .data1 = data1, .data2 = data2, .data3 = data3, .data4 = data4 };
}

pub const SimpleVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    provider_options: *const fn (*Object, *i32) callconv(.winapi) win.HRESULT,
    get_pattern_provider: *const fn (*Object, i32, *?*Object) callconv(.winapi) win.HRESULT,
    get_property_value: *const fn (*Object, i32, *Variant) callconv(.winapi) win.HRESULT,
    host_raw_element_provider: *const fn (*Object, *?*Object) callconv(.winapi) win.HRESULT,
};

pub const FragmentVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    navigate: *const fn (*Object, i32, *?*Object) callconv(.winapi) win.HRESULT,
    get_runtime_id: *const fn (*Object, *?*SafeArray) callconv(.winapi) win.HRESULT,
    bounding_rectangle: *const fn (*Object, *Rect) callconv(.winapi) win.HRESULT,
    embedded_fragment_roots: *const fn (*Object, *?*SafeArray) callconv(.winapi) win.HRESULT,
    set_focus: *const fn (*Object) callconv(.winapi) win.HRESULT,
    fragment_root: *const fn (*Object, *?*Object) callconv(.winapi) win.HRESULT,
};

pub const FragmentRootVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    element_from_point: *const fn (*Object, f64, f64, *?*Object) callconv(.winapi) win.HRESULT,
    get_focus: *const fn (*Object, *?*Object) callconv(.winapi) win.HRESULT,
};

pub const InvokeVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    invoke: *const fn (*Object) callconv(.winapi) win.HRESULT,
};

pub const ToggleVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    toggle: *const fn (*Object) callconv(.winapi) win.HRESULT,
    get_state: *const fn (*Object, *i32) callconv(.winapi) win.HRESULT,
};

pub const RangeValueVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    set_value: *const fn (*Object, f64) callconv(.winapi) win.HRESULT,
    get_value: *const fn (*Object, *f64) callconv(.winapi) win.HRESULT,
    get_is_read_only: *const fn (*Object, *win.BOOL) callconv(.winapi) win.HRESULT,
    get_maximum: *const fn (*Object, *f64) callconv(.winapi) win.HRESULT,
    get_minimum: *const fn (*Object, *f64) callconv(.winapi) win.HRESULT,
    get_large_change: *const fn (*Object, *f64) callconv(.winapi) win.HRESULT,
    get_small_change: *const fn (*Object, *f64) callconv(.winapi) win.HRESULT,
};

pub const ValueVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    set_value: *const fn (*Object, ?[*:0]const u16) callconv(.winapi) win.HRESULT,
    get_value: *const fn (*Object, *BStr) callconv(.winapi) win.HRESULT,
    get_is_read_only: *const fn (*Object, *win.BOOL) callconv(.winapi) win.HRESULT,
};

pub const SelectionItemVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    select: *const fn (*Object) callconv(.winapi) win.HRESULT,
    add_to_selection: *const fn (*Object) callconv(.winapi) win.HRESULT,
    remove_from_selection: *const fn (*Object) callconv(.winapi) win.HRESULT,
    get_is_selected: *const fn (*Object, *win.BOOL) callconv(.winapi) win.HRESULT,
    get_selection_container: *const fn (*Object, *?*Object) callconv(.winapi) win.HRESULT,
};

pub const ExpandCollapseVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    expand: *const fn (*Object) callconv(.winapi) win.HRESULT,
    collapse: *const fn (*Object) callconv(.winapi) win.HRESULT,
    get_state: *const fn (*Object, *i32) callconv(.winapi) win.HRESULT,
};

pub const TextProviderVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    get_selection: *const fn (*Object, *?*SafeArray) callconv(.winapi) win.HRESULT,
    get_visible_ranges: *const fn (*Object, *?*SafeArray) callconv(.winapi) win.HRESULT,
    range_from_child: *const fn (*Object, *Object, *?*Object) callconv(.winapi) win.HRESULT,
    range_from_point: *const fn (*Object, Point, *?*Object) callconv(.winapi) win.HRESULT,
    get_document_range: *const fn (*Object, *?*Object) callconv(.winapi) win.HRESULT,
    get_supported_selection: *const fn (*Object, *i32) callconv(.winapi) win.HRESULT,
};

pub const TextRangeVTable = extern struct {
    query_interface: *const fn (*Object, *const win.GUID, *?*anyopaque) callconv(.winapi) win.HRESULT,
    add_ref: *const fn (*Object) callconv(.winapi) u32,
    release: *const fn (*Object) callconv(.winapi) u32,
    clone: *const fn (*Object, *?*Object) callconv(.winapi) win.HRESULT,
    compare: *const fn (*Object, *Object, *win.BOOL) callconv(.winapi) win.HRESULT,
    compare_endpoints: *const fn (*Object, i32, *Object, i32, *i32) callconv(.winapi) win.HRESULT,
    expand_to_enclosing_unit: *const fn (*Object, i32) callconv(.winapi) win.HRESULT,
    find_attribute: *const fn (*Object, i32, Variant, win.BOOL, *?*Object) callconv(.winapi) win.HRESULT,
    find_text: *const fn (*Object, BStr, win.BOOL, win.BOOL, *?*Object) callconv(.winapi) win.HRESULT,
    get_attribute_value: *const fn (*Object, i32, *Variant) callconv(.winapi) win.HRESULT,
    get_bounding_rectangles: *const fn (*Object, *?*SafeArray) callconv(.winapi) win.HRESULT,
    get_enclosing_element: *const fn (*Object, *?*Object) callconv(.winapi) win.HRESULT,
    get_text: *const fn (*Object, i32, *BStr) callconv(.winapi) win.HRESULT,
    move: *const fn (*Object, i32, i32, *i32) callconv(.winapi) win.HRESULT,
    move_endpoint_by_unit: *const fn (*Object, i32, i32, i32, *i32) callconv(.winapi) win.HRESULT,
    move_endpoint_by_range: *const fn (*Object, i32, *Object, i32) callconv(.winapi) win.HRESULT,
    select: *const fn (*Object) callconv(.winapi) win.HRESULT,
    add_to_selection: *const fn (*Object) callconv(.winapi) win.HRESULT,
    remove_from_selection: *const fn (*Object) callconv(.winapi) win.HRESULT,
    scroll_into_view: *const fn (*Object, win.BOOL) callconv(.winapi) win.HRESULT,
    get_children: *const fn (*Object, *?*SafeArray) callconv(.winapi) win.HRESULT,
};

pub extern "uiautomationcore" fn UiaReturnRawElementProvider(win.HWND, win.WPARAM, win.LPARAM, ?*Object) callconv(.winapi) win.LRESULT;
pub extern "uiautomationcore" fn UiaHostProviderFromHwnd(win.HWND, *?*Object) callconv(.winapi) win.HRESULT;
pub extern "uiautomationcore" fn UiaRaiseAutomationEvent(*Object, i32) callconv(.winapi) win.HRESULT;
pub extern "uiautomationcore" fn UiaRaiseAutomationPropertyChangedEvent(*Object, i32, Variant, Variant) callconv(.winapi) win.HRESULT;
pub extern "uiautomationcore" fn UiaRaiseStructureChangedEvent(*Object, i32, ?[*]i32, i32) callconv(.winapi) win.HRESULT;
pub extern "uiautomationcore" fn UiaDisconnectProvider(*Object) callconv(.winapi) win.HRESULT;
pub extern "uiautomationcore" fn UiaGetReservedNotSupportedValue(*?*Object) callconv(.winapi) win.HRESULT;
pub extern "uiautomationcore" fn UiaGetReservedMixedAttributeValue(*?*Object) callconv(.winapi) win.HRESULT;

pub extern "oleaut32" fn SysAllocStringLen(?[*]const u16, u32) callconv(.winapi) BStr;
pub extern "oleaut32" fn SysStringLen(BStr) callconv(.winapi) u32;
pub extern "oleaut32" fn VariantClear(*Variant) callconv(.winapi) win.HRESULT;
pub extern "oleaut32" fn SafeArrayCreateVector(u16, i32, u32) callconv(.winapi) ?*SafeArray;
pub extern "oleaut32" fn SafeArrayAccessData(*SafeArray, *?*anyopaque) callconv(.winapi) win.HRESULT;
pub extern "oleaut32" fn SafeArrayUnaccessData(*SafeArray) callconv(.winapi) win.HRESULT;
pub extern "oleaut32" fn SafeArrayDestroy(*SafeArray) callconv(.winapi) win.HRESULT;

pub fn emptyVariant() Variant {
    return .{};
}

pub fn intVariant(value: i32) Variant {
    return .{ .variant_type = variant_i4, .data = .{ .long = value } };
}

pub fn doubleVariant(value: f64) Variant {
    return .{ .variant_type = variant_r8, .data = .{ .double = value } };
}

pub fn boolVariant(value: bool) Variant {
    return .{ .variant_type = variant_bool, .data = .{ .boolean = if (value) variant_true else variant_false } };
}

pub fn unknownVariant(value: ?*Object) Variant {
    return .{ .variant_type = variant_unknown, .data = .{ .unknown = value } };
}

pub fn stringVariant(units: []const u16) ?Variant {
    if (units.len > std.math.maxInt(u32)) return null;
    const value = SysAllocStringLen(if (units.len == 0) null else units.ptr, @intCast(units.len));
    if (value == null and units.len != 0) return null;
    return .{ .variant_type = variant_bstr, .data = .{ .string = value } };
}
