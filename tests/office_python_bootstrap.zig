//! Exact Application first-stage ZIP + PE + WinTrust path, no Python toolchain.
const std = @import("std");
const component = @import("office_component_store");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.UsageFixedZipSha256SizeAndExistingStage;
    var expected: component.BootstrapExpected = .{ .bytes = try std.fmt.parseInt(u64, args[3], 10), .sha256 = undefined };
    if (args[2].len != 64) return error.InvalidPinnedDigest;
    _ = try std.fmt.hexToBytes(&expected.sha256, args[2]);
    const input = try std.Io.Dir.cwd().openFile(init.io, args[1], .{});
    defer input.close(init.io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = input.reader(init.io, &buffer);
    const stage = try std.Io.Dir.cwd().openDir(init.io, args[4], .{ .iterate = true, .follow_symlinks = false });
    defer stage.close(init.io);
    const cancellation: @import("office_process").Cancellation = .{};
    const outcome = component.prepareBootstrapPython(init.gpa, init.io, &reader.interface, stage, args[4], expected, &cancellation);
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    if (outcome) |result| {
        try std.json.Stringify.value(.{ .status = "authenticated", .files = result.files, .unpackedBytes = result.unpacked_bytes }, .{}, &output.interface);
    } else |failure| {
        try std.json.Stringify.value(.{ .status = "rejected", .reason = @errorName(failure) }, .{}, &output.interface);
    }
    try output.interface.writeByte('\n');
    try output.interface.flush();
}
