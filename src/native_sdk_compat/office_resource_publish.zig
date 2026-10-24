//! Application-only macOS exclusive publication of an owned Office resource stage.
//! Native SDK 0.11.0-fork.4 has no exclusive directory rename primitive.
const std = @import("std");
const builtin = @import("builtin");
extern "c" fn renameatx_np(c_int, [*:0]const u8, c_int, [*:0]const u8, c_uint) c_int;

pub fn publish(parent: std.Io.Dir, stage: []const u8, final: []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    // The capability accepts only sibling resource names in the caller's owned dir.
    if (stage.len != 37 or stage[0] != '.' or !std.mem.endsWith(u8, stage, ".tmp") or final.len != 64)
        return error.InvalidResourceName;
    for (stage[1..33]) |byte| if (!std.ascii.isHex(byte)) return error.InvalidResourceName;
    for (final) |byte| if (!std.ascii.isHex(byte)) return error.InvalidResourceName;
    var stage_z: [38]u8 = undefined;
    var final_z: [65]u8 = undefined;
    @memcpy(stage_z[0..stage.len], stage);
    stage_z[stage.len] = 0;
    @memcpy(final_z[0..final.len], final);
    final_z[final.len] = 0;
    const result = renameatx_np(parent.handle, @ptrCast(&stage_z), parent.handle, @ptrCast(&final_z), 4); // RENAME_EXCL
    switch (std.c.errno(result)) {
        .SUCCESS => {},
        .EXIST => return error.PathAlreadyExists,
        else => return error.ResourcePublishFailed,
    }
}

test "Office resource publication preserves an existing empty directory and file" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const stage = ".0123456789abcdef0123456789abcdef.tmp";
    const final = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const io = std.testing.io;
    try temporary.dir.createDir(io, stage, .default_dir);
    try temporary.dir.createDir(io, final, .default_dir);
    try std.testing.expectError(error.PathAlreadyExists, publish(temporary.dir, stage, final));
    try temporary.dir.deleteDir(io, final);
    try temporary.dir.writeFile(io, .{ .sub_path = final, .data = "preserved" });
    try std.testing.expectError(error.PathAlreadyExists, publish(temporary.dir, stage, final));
    try temporary.dir.deleteFile(io, final);
    try temporary.dir.symLink(io, stage, final, .{ .is_directory = true });
    try std.testing.expectError(error.PathAlreadyExists, publish(temporary.dir, stage, final));
    var target: [64]u8 = undefined;
    try std.testing.expectEqualStrings(stage, target[0..try temporary.dir.readLink(io, final, &target)]);
    try temporary.dir.deleteFile(io, final);
    try publish(temporary.dir, stage, final);
    try temporary.dir.createDir(io, stage, .default_dir);
    try std.testing.expectError(error.PathAlreadyExists, publish(temporary.dir, stage, final));
}

test "Office resource publication has exactly one concurrent winner" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{ .iterate = true });
    defer temporary.cleanup();
    const Context = struct {
        parent: std.Io.Dir,
        stage: []const u8,
        start: *std.atomic.Value(bool),
        result: enum { pending, published, occupied, failed } = .pending,
        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            publish(self.parent, self.stage, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") catch |failure| {
                self.result = if (failure == error.PathAlreadyExists) .occupied else .failed;
                return;
            };
            self.result = .published;
        }
    };
    var start = std.atomic.Value(bool).init(false);
    var first: Context = .{ .parent = temporary.dir, .stage = ".11111111111111111111111111111111.tmp", .start = &start };
    var second: Context = .{ .parent = temporary.dir, .stage = ".22222222222222222222222222222222.tmp", .start = &start };
    try temporary.dir.createDir(std.testing.io, first.stage, .default_dir);
    try temporary.dir.createDir(std.testing.io, second.stage, .default_dir);
    const one = try std.Thread.spawn(.{}, Context.run, .{&first});
    errdefer {
        start.store(true, .release);
        one.join();
    }
    const two = try std.Thread.spawn(.{}, Context.run, .{&second});
    start.store(true, .release);
    one.join();
    two.join();
    try std.testing.expect((first.result == .published and second.result == .occupied) or (second.result == .published and first.result == .occupied));
}
