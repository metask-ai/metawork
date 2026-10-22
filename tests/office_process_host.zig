//! Drives the exact Application Office process owner. The qualification script
//! supplies test component roots; no production command accepts these paths.
const std = @import("std");
const office = @import("office_process");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 and args.len != 5 and args.len != 6) return error.UsageComponentRootTimeoutCancelAfterOptionalOperationOrPreviewPaths;
    var random: [16]u8 = undefined;
    if (args.len == 5) {
        if (args[4].len != 32) return error.InvalidOperationIdentity;
        _ = try std.fmt.hexToBytes(&random, args[4]);
    } else try std.Io.randomSecure(init.io, &random);
    const name = try std.fmt.allocPrint(init.arena.allocator(), ".host-{s}", .{std.fmt.bytesToHex(random, .lower)});
    const scratch = try std.fs.path.join(init.arena.allocator(), &.{ std.fs.path.dirname(args[1]) orelse return error.InvalidRoot, name });
    try std.Io.Dir.cwd().createDir(init.io, scratch, .default_dir);
    var quiescent = true;
    defer if (quiescent) std.Io.Dir.cwd().deleteTree(init.io, scratch) catch {};
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
    const command: office.Command = if (args.len == 6) .{ .preview = .{ .input = args[4], .output = args[5] } } else .selftest;
    var result = switch (office.run(init.gpa, init.io, args[1], command, .{ .parent_environment = init.environ_map, .scratch_root = scratch, .operation_identity = random }, timeout, &cancellation)) {
        .completed => |output| output,
        .failed => |failure| {
            quiescent = failure.quiescent;
            try std.json.Stringify.value(.{ .failure = @errorName(failure.cause), .quiescent = failure.quiescent }, .{}, &writer.interface);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
            return;
        },
    };
    defer result.deinit(init.gpa);
    try std.json.Stringify.value(.{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr, .quiescent = true }, .{}, &writer.interface);
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
