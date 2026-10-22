//! Drives the exact Application Office process owner. The qualification script
//! supplies test component roots; no production command accepts these paths.
const std = @import("std");
const office = @import("office_process");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.UsageComponentRootTimeoutCancelAfter;
    const timeout = try std.fmt.parseInt(u32, args[2], 10);
    const cancel_after = try std.fmt.parseInt(u32, args[3], 10);
    var cancellation: office.Cancellation = .{};
    var timer: Timer = .{ .io = init.io, .cancellation = &cancellation, .after = cancel_after };
    const thread = try std.Thread.spawn(.{}, Timer.run, .{&timer});
    defer {
        timer.done.store(true, .release);
        thread.join();
    }
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    var result = office.run(init.gpa, init.io, args[1], .selftest, timeout, &cancellation) catch |failure| {
        try std.json.Stringify.value(.{ .failure = @errorName(failure) }, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        return;
    };
    defer result.deinit(init.gpa);
    try std.json.Stringify.value(.{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr }, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

const Timer = struct {
    io: std.Io,
    cancellation: *office.Cancellation,
    after: u32,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Timer) void {
        const start: std.Io.Timestamp = .now(self.io, .awake);
        while (!self.done.load(.acquire)) {
            if (self.after != 0 and start.durationTo(.now(self.io, .awake)).toMilliseconds() >= self.after) {
                self.cancellation.requested.store(true, .release);
                return;
            }
            std.Io.Timeout.sleep(.{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }, self.io) catch return;
        }
    }
};
