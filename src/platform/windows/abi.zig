const std = @import("std");

pub const BOOL = i32;
pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const UINT = u32;
pub const ULONG = u32;
pub const LONG = i32;
pub const WCHAR = u16;
pub const HRESULT = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const ATOM = u16;

pub const HANDLE = ?*anyopaque;
pub const HINSTANCE = HANDLE;
pub const HMODULE = HANDLE;
pub const HWND = HANDLE;
pub const HICON = HANDLE;
pub const HCURSOR = HANDLE;
pub const HBRUSH = HANDLE;
pub const HMENU = HANDLE;
pub const HDC = HANDLE;
pub const HMONITOR = HANDLE;
pub const HGLOBAL = HANDLE;
pub const HDROP = HANDLE;
pub const HIMC = HANDLE;

pub const POINT = extern struct { x: LONG = 0, y: LONG = 0 };
pub const SIZE = extern struct { cx: LONG = 0, cy: LONG = 0 };
pub const RECT = extern struct { left: LONG = 0, top: LONG = 0, right: LONG = 0, bottom: LONG = 0 };
pub const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD = 0,
};
pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    erase: BOOL,
    paint: RECT,
    restore: BOOL,
    inc_update: BOOL,
    reserved: [32]BYTE,
};
pub const CREATESTRUCTW = extern struct {
    create_params: ?*anyopaque,
    instance: HINSTANCE,
    menu: HMENU,
    parent: HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: LONG,
    name: ?[*:0]const WCHAR,
    class_name: ?[*:0]const WCHAR,
    ex_style: DWORD,
};
pub const WNDCLASSEXW = extern struct {
    size: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT,
    window_proc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT,
    class_extra: i32 = 0,
    window_extra: i32 = 0,
    instance: HINSTANCE,
    icon: HICON = null,
    cursor: HCURSOR = null,
    background: HBRUSH = null,
    menu_name: ?[*:0]const WCHAR = null,
    class_name: [*:0]const WCHAR,
    icon_small: HICON = null,
};
pub const TRACKMOUSEEVENT = extern struct {
    size: DWORD = @sizeOf(TRACKMOUSEEVENT),
    flags: DWORD,
    hwnd_track: HWND,
    hover_time: DWORD = 0,
};
pub const MINMAXINFO = extern struct {
    reserved: POINT,
    max_size: POINT,
    max_position: POINT,
    min_track_size: POINT,
    max_track_size: POINT,
};
pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    show_command: UINT = 0,
    minimum_position: POINT = .{},
    maximum_position: POINT = .{},
    normal_position: RECT = .{},
};
pub const MONITORINFOEXW = extern struct {
    size: DWORD = @sizeOf(MONITORINFOEXW),
    monitor: RECT = .{},
    work: RECT = .{},
    flags: DWORD = 0,
    device: [32]WCHAR = @splat(0),
};
pub const MonitorEnumProc = *const fn (HMONITOR, HDC, *RECT, LPARAM) callconv(.winapi) BOOL;
pub const DROPFILES = extern struct {
    files_offset: DWORD,
    point: POINT,
    non_client: BOOL,
    wide: BOOL,
};
pub const COMPOSITIONFORM = extern struct { style: DWORD, current_pos: POINT, area: RECT };
pub const CANDIDATEFORM = extern struct { index: DWORD, style: DWORD, current_pos: POINT, area: RECT };

pub const OPENFILENAMEW = extern struct {
    struct_size: DWORD = @sizeOf(OPENFILENAMEW),
    owner: HWND = null,
    instance: HINSTANCE = null,
    filter: ?[*:0]const WCHAR = null,
    custom_filter: ?[*]WCHAR = null,
    max_custom_filter: DWORD = 0,
    filter_index: DWORD = 0,
    file: [*]WCHAR,
    max_file: DWORD,
    file_title: ?[*]WCHAR = null,
    max_file_title: DWORD = 0,
    initial_directory: ?[*:0]const WCHAR = null,
    title: ?[*:0]const WCHAR = null,
    flags: DWORD,
    file_offset: WORD = 0,
    file_extension: WORD = 0,
    default_extension: ?[*:0]const WCHAR = null,
    custom_data: LPARAM = 0,
    hook: ?*const anyopaque = null,
    template_name: ?[*:0]const WCHAR = null,
    reserved: ?*anyopaque = null,
    reserved_dword: DWORD = 0,
    flags_ex: DWORD = 0,
};

pub const MENUITEMINFOW = extern struct {
    size: UINT = @sizeOf(MENUITEMINFOW),
    mask: UINT,
    item_type: UINT = 0,
    state: UINT = 0,
    id: UINT = 0,
    submenu: HMENU = null,
    checked_bitmap: HANDLE = null,
    unchecked_bitmap: HANDLE = null,
    item_data: usize = 0,
    type_data: ?[*]WCHAR = null,
    text_length: UINT = 0,
    item_bitmap: HANDLE = null,
};

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    pub fn eql(a: GUID, b: GUID) bool {
        return a.data1 == b.data1 and a.data2 == b.data2 and a.data3 == b.data3 and std.mem.eql(u8, &a.data4, &b.data4);
    }
};

pub const IUnknown = extern struct {
    vtable: *const VTable,
    pub const VTable = extern struct {
        query_interface: *const fn (*IUnknown, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        add_ref: *const fn (*IUnknown) callconv(.winapi) ULONG,
        release: *const fn (*IUnknown) callconv(.winapi) ULONG,
    };
};

pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
pub fn succeeded(value: HRESULT) bool {
    return value >= 0;
}

pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
pub const WS_OVERLAPPED: DWORD = 0;
pub const WS_CAPTION: DWORD = 0x00c00000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_OVERLAPPEDWINDOW: DWORD = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const WS_EX_LAYERED: DWORD = 0x00080000;
pub const WS_EX_TOPMOST: DWORD = 0x00000008;

pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;
pub const SW_SHOWNORMAL: i32 = 1;
pub const SW_SHOWMAXIMIZED: i32 = 3;
pub const SW_SHOWMINIMIZED: i32 = 2;
pub const SW_MINIMIZE: i32 = 6;
pub const SW_RESTORE: i32 = 9;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const GWL_STYLE: i32 = -16;
pub const GWL_EXSTYLE: i32 = -20;
pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;
pub const MONITORINFOF_PRIMARY: DWORD = 1;

pub const WM_NULL: UINT = 0x0000;
pub const WM_CREATE: UINT = 0x0001;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_MOVE: UINT = 0x0003;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_GETMINMAXINFO: UINT = 0x0024;
pub const WM_GETOBJECT: UINT = 0x003d;
pub const WM_INPUTLANGCHANGE: UINT = 0x0051;
pub const WM_CONTEXTMENU: UINT = 0x007b;
pub const WM_NCCREATE: UINT = 0x0081;
pub const WM_NCDESTROY: UINT = 0x0082;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_IME_STARTCOMPOSITION: UINT = 0x010d;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010e;
pub const WM_IME_COMPOSITION: UINT = 0x010f;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020a;
pub const WM_XBUTTONDOWN: UINT = 0x020b;
pub const WM_XBUTTONUP: UINT = 0x020c;
pub const WM_MOUSEHWHEEL: UINT = 0x020e;
pub const WM_MOUSELEAVE: UINT = 0x02a3;
pub const WM_DPICHANGED: UINT = 0x02e0;
pub const WM_DROPFILES: UINT = 0x0233;
pub const WM_PAINT: UINT = 0x000f;
pub const WM_APP: UINT = 0x8000;
pub const WM_ZIGUI_WAKE: UINT = WM_APP + 0x3f0;

pub const GWLP_USERDATA: i32 = -21;
pub const PM_REMOVE: UINT = 0x0001;
pub const PM_NOREMOVE: UINT = 0x0000;
pub const TME_LEAVE: DWORD = 0x00000002;
pub const WHEEL_DELTA: i16 = 120;
pub const MK_LBUTTON: WPARAM = 0x0001;
pub const MK_RBUTTON: WPARAM = 0x0002;
pub const MK_SHIFT: WPARAM = 0x0004;
pub const MK_CONTROL: WPARAM = 0x0008;
pub const MK_MBUTTON: WPARAM = 0x0010;
pub const MK_XBUTTON1: WPARAM = 0x0020;
pub const MK_XBUTTON2: WPARAM = 0x0040;

pub const VK_BACK: u32 = 0x08;
pub const VK_TAB: u32 = 0x09;
pub const VK_RETURN: u32 = 0x0d;
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = 0x11;
pub const VK_MENU: u32 = 0x12;
pub const VK_ESCAPE: u32 = 0x1b;
pub const VK_SPACE: u32 = 0x20;
pub const VK_PRIOR: u32 = 0x21;
pub const VK_NEXT: u32 = 0x22;
pub const VK_END: u32 = 0x23;
pub const VK_HOME: u32 = 0x24;
pub const VK_LEFT: u32 = 0x25;
pub const VK_UP: u32 = 0x26;
pub const VK_RIGHT: u32 = 0x27;
pub const VK_DOWN: u32 = 0x28;
pub const VK_INSERT: u32 = 0x2d;
pub const VK_DELETE: u32 = 0x2e;
pub const VK_F1: u32 = 0x70;
pub const VK_F24: u32 = 0x87;
pub const VK_LSHIFT: u32 = 0xa0;
pub const VK_RSHIFT: u32 = 0xa1;
pub const VK_LCONTROL: u32 = 0xa2;
pub const VK_RCONTROL: u32 = 0xa3;
pub const VK_LMENU: u32 = 0xa4;
pub const VK_RMENU: u32 = 0xa5;
pub const VK_LWIN: u32 = 0x5b;
pub const VK_RWIN: u32 = 0x5c;
pub const VK_CAPITAL: u32 = 0x14;
pub const VK_NUMLOCK: u32 = 0x90;

pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;
pub const GMEM_ZEROINIT: UINT = 0x0040;
pub const OFN_EXPLORER: DWORD = 0x00080000;
pub const OFN_FILEMUSTEXIST: DWORD = 0x00001000;
pub const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
pub const OFN_ALLOWMULTISELECT: DWORD = 0x00000200;
pub const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
pub const MF_STRING: UINT = 0x00000000;
pub const MF_POPUP: UINT = 0x00000010;
pub const MF_SEPARATOR: UINT = 0x00000800;
pub const MF_GRAYED: UINT = 0x00000001;
pub const MF_CHECKED: UINT = 0x00000008;
pub const TPM_RETURNCMD: UINT = 0x0100;
pub const TPM_RIGHTBUTTON: UINT = 0x0002;

pub const GCS_COMPSTR: DWORD = 0x0008;
pub const GCS_COMPATTR: DWORD = 0x0010;
pub const GCS_CURSORPOS: DWORD = 0x0080;
pub const GCS_RESULTSTR: DWORD = 0x0800;
pub const CFS_POINT: DWORD = 0x0002;
pub const CFS_EXCLUDE: DWORD = 0x0080;
pub const IACE_CHILDREN: DWORD = 0x0001;
pub const IACE_DEFAULT: DWORD = 0x0010;
pub const IACE_IGNORENOCONTEXT: DWORD = 0x0020;

pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const WCHAR) callconv(.winapi) HMODULE;
pub extern "kernel32" fn GetWindowsDirectoryW(buffer: [*]WCHAR, size: UINT) callconv(.winapi) UINT;
pub extern "kernel32" fn LoadLibraryW(name: [*:0]const WCHAR) callconv(.winapi) HMODULE;
pub extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
pub extern "kernel32" fn QueryPerformanceCounter(value: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(value: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) HGLOBAL;
pub extern "kernel32" fn GlobalLock(memory: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(memory: HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(memory: HGLOBAL) callconv(.winapi) HGLOBAL;
pub extern "kernel32" fn GlobalSize(memory: HGLOBAL) callconv(.winapi) usize;

pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(class_name: [*:0]const WCHAR, instance: HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(ex_style: DWORD, class_name: [*:0]const WCHAR, title: [*:0]const WCHAR, style: DWORD, x: i32, y: i32, width: i32, height: i32, parent: HWND, menu: HMENU, instance: HINSTANCE, parameter: ?*anyopaque) callconv(.winapi) HWND;
pub extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetWindowLongPtrW(window: HWND, index: i32) callconv(.winapi) isize;
pub extern "user32" fn SetWindowLongPtrW(window: HWND, index: i32, value: isize) callconv(.winapi) isize;
pub extern "user32" fn ShowWindow(window: HWND, command: i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(window: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(window: HWND, title: [*:0]const WCHAR) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectEx(rect: *RECT, style: DWORD, menu: BOOL, ex_style: DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(window: HWND, after: HWND, x: i32, y: i32, width: i32, height: i32, flags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowPlacement(window: HWND, placement: *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(window: HWND, placement: *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn MonitorFromWindow(window: HWND, flags: DWORD) callconv(.winapi) HMONITOR;
pub extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: *MONITORINFOEXW) callconv(.winapi) BOOL;
pub extern "user32" fn EnumDisplayMonitors(hdc: HDC, clip: ?*const RECT, callback: MonitorEnumProc, data: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(window: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn ClientToScreen(window: HWND, point: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn ScreenToClient(window: HWND, point: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) UINT;
pub extern "shcore" fn GetDpiForMonitor(monitor: HMONITOR, dpi_type: i32, x: *UINT, y: *UINT) callconv(.winapi) HRESULT;
pub extern "user32" fn SetProcessDpiAwarenessContext(context: isize) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(message: *MSG, window: HWND, minimum: UINT, maximum: UINT, remove: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(message: *MSG, window: HWND, minimum: UINT, maximum: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(message: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(message: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostThreadMessageW(thread: DWORD, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(exit_code: i32) callconv(.winapi) void;
pub extern "user32" fn InvalidateRect(window: HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn ValidateRect(window: HWND, rect: ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn BeginPaint(window: HWND, paint: *PAINTSTRUCT) callconv(.winapi) HDC;
pub extern "user32" fn EndPaint(window: HWND, paint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn TrackMouseEvent(event: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(window: HWND) callconv(.winapi) HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(key: i32) callconv(.winapi) i16;
pub extern "user32" fn GetKeyboardState(state: *[256]BYTE) callconv(.winapi) BOOL;
pub extern "user32" fn MapVirtualKeyW(code: UINT, map_type: UINT) callconv(.winapi) UINT;
pub extern "user32" fn ToUnicodeEx(virtual_key: UINT, scan_code: UINT, state: *const [256]BYTE, buffer: [*]WCHAR, length: i32, flags: UINT, layout: HANDLE) callconv(.winapi) i32;
pub extern "user32" fn GetKeyboardLayout(thread: DWORD) callconv(.winapi) HANDLE;
pub extern "user32" fn LoadCursorW(instance: HINSTANCE, name: usize) callconv(.winapi) HCURSOR;
pub extern "user32" fn SetCursor(cursor: HCURSOR) callconv(.winapi) HCURSOR;
pub extern "user32" fn OpenClipboard(owner: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) HANDLE;
pub extern "user32" fn SetClipboardData(format: UINT, memory: HANDLE) callconv(.winapi) HANDLE;
pub extern "user32" fn CreateMenu() callconv(.winapi) HMENU;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) HMENU;
pub extern "user32" fn DestroyMenu(menu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn AppendMenuW(menu: HMENU, flags: UINT, identifier: usize, label: ?[*:0]const WCHAR) callconv(.winapi) BOOL;
pub extern "user32" fn SetMenu(window: HWND, menu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn DrawMenuBar(window: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenu(menu: HMENU, flags: UINT, x: i32, y: i32, reserved: i32, owner: HWND, rect: ?*const RECT) callconv(.winapi) UINT;

pub extern "shell32" fn DragAcceptFiles(window: HWND, accept: BOOL) callconv(.winapi) void;
pub extern "shell32" fn DragQueryFileW(drop: HDROP, index: UINT, output: ?[*]WCHAR, count: UINT) callconv(.winapi) UINT;
pub extern "shell32" fn DragQueryPoint(drop: HDROP, point: *POINT) callconv(.winapi) BOOL;
pub extern "shell32" fn DragFinish(drop: HDROP) callconv(.winapi) void;
pub extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: DWORD, token: HANDLE, path: *?[*:0]WCHAR) callconv(.winapi) HRESULT;

pub extern "imm32" fn ImmGetContext(window: HWND) callconv(.winapi) HIMC;
pub extern "imm32" fn ImmReleaseContext(window: HWND, context: HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmGetCompositionStringW(context: HIMC, index: DWORD, buffer: ?*anyopaque, bytes: DWORD) callconv(.winapi) LONG;
pub extern "imm32" fn ImmSetCompositionWindow(context: HIMC, form: *const COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(context: HIMC, form: *const CANDIDATEFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmAssociateContextEx(window: HWND, context: HIMC, flags: DWORD) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmNotifyIME(context: HIMC, action: DWORD, index: DWORD, value: DWORD) callconv(.winapi) BOOL;

pub extern "comdlg32" fn GetOpenFileNameW(options: *OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(options: *OPENFILENAMEW) callconv(.winapi) BOOL;

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, concurrency: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;

pub fn lowWord(value: usize) u16 {
    return @truncate(value);
}
pub fn highWord(value: usize) u16 {
    return @truncate(value >> 16);
}
pub fn signedLowWord(value: usize) i16 {
    return @bitCast(lowWord(value));
}
pub fn signedHighWord(value: usize) i16 {
    return @bitCast(highWord(value));
}
