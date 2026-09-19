const std = @import("std");

pub fn validCoordinate(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= 65_536;
}

pub fn pointInTopBand(x: f64, y: f64, top: f64) bool {
    return validCoordinate(x) and validCoordinate(y) and validCoordinate(top) and y < top;
}

test "top band rejects unavailable, nonfinite and out-of-range coordinates" {
    try std.testing.expect(pointInTopBand(20, 0, 40));
    try std.testing.expect(pointInTopBand(20, 39.9, 40));
    for ([_]f64{ -1, 40, 100, std.math.nan(f64), std.math.inf(f64) }) |y|
        try std.testing.expect(!pointInTopBand(20, y, 40));
    try std.testing.expect(!pointInTopBand(-1, 20, 40));
    try std.testing.expect(!pointInTopBand(20, 0, 0));
    try std.testing.expect(!pointInTopBand(20, 20, std.math.nan(f64)));
}

pub const GestureMode = enum { browser_mouse, native_press, disabled };
pub const GestureAction = enum { start_drag, toggle_maximize };
pub const GestureOutcome = enum {
    ignored,
    drag_started,
    toggle_maximize,
};
