pub const PointIsDraggableFn = *const fn (*const anyopaque, f64, f64) bool;

pub const PointerOutcome = enum {
    ignored,
    drag_started,
    toggle_maximize,
};
