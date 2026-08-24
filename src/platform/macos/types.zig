pub const CGFloat = f64;

pub const Point = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const Size = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const Rect = extern struct { origin: Point = .{}, size: Size = .{} };
pub const Range = extern struct { location: usize, length: usize };

pub const not_found = ~@as(usize, 0);
pub const any_event_mask = ~@as(u64, 0);
pub const backing_store_buffered: usize = 2;

pub const EventType = struct {
    pub const left_mouse_down: usize = 1;
    pub const left_mouse_up: usize = 2;
    pub const right_mouse_down: usize = 3;
    pub const right_mouse_up: usize = 4;
    pub const mouse_moved: usize = 5;
    pub const left_mouse_dragged: usize = 6;
    pub const right_mouse_dragged: usize = 7;
    pub const mouse_entered: usize = 8;
    pub const mouse_exited: usize = 9;
    pub const key_down: usize = 10;
    pub const key_up: usize = 11;
    pub const flags_changed: usize = 12;
    pub const scroll_wheel: usize = 22;
    pub const tablet_point: usize = 23;
    pub const other_mouse_down: usize = 25;
    pub const other_mouse_up: usize = 26;
    pub const other_mouse_dragged: usize = 27;
};

pub const WindowStyle = struct {
    pub const titled: usize = 1 << 0;
    pub const closable: usize = 1 << 1;
    pub const miniaturizable: usize = 1 << 2;
    pub const resizable: usize = 1 << 3;
    pub const fullscreen: usize = 1 << 14;
    pub const full_size_content_view: usize = 1 << 15;
};

pub const Modifier = struct {
    pub const caps_lock: u64 = 1 << 16;
    pub const shift: u64 = 1 << 17;
    pub const control: u64 = 1 << 18;
    pub const option: u64 = 1 << 19;
    pub const command: u64 = 1 << 20;
    pub const numeric_pad: u64 = 1 << 21;
    pub const function: u64 = 1 << 23;
};
