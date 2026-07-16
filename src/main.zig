const app = @import("app.zig");

pub const panic = app.panic;

pub fn main(init: @import("std").process.Init) !void {
    return app.run(init);
}

test {
    _ = app;
}
