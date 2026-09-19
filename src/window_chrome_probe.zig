const std = @import("std");
const app = @import("metawork_app");
pub const panic = app.panic;

pub fn main(init: std.process.Init) !void {
    return app.runWindowChromeProbe(init);
}
