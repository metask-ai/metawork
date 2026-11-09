//! Compile the pinned IANA TZif release into effect-free Schedule inputs.
const std = @import("std");
const tempora = @import("tempora");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    const root = args.next() orelse return error.MissingTimeZoneData;
    if (args.next() != null) return error.UnexpectedArgument;
    var dir = try std.Io.Dir.openDirAbsolute(init.io, root, .{});
    defer dir.close(init.io);
    const names = try dir.readFileAlloc(init.io, "src/tzdata/zones", init.gpa, .limited(128 * 1024));
    defer init.gpa.free(names);
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("// Generated from the checksum-pinned tzdata release.\npub const Zone = enum {\n");
    var lines = std.mem.tokenizeAny(u8, names, "\r\n");
    while (lines.next()) |name| try writer.print("@\"{f}\",\n", .{std.zig.fmtString(name)});
    try writer.writeAll("};\npub const Transition = struct { at: i64, offset: i32 };\npub const Data = struct { initial_offset: i32, offsets: []const i32, transitions: []const Transition, footer: ?[]const u8 };\npub const entries = [_]Data{\n");
    lines.reset();
    while (lines.next()) |name| {
        const path = try std.fmt.allocPrint(init.gpa, "src/tzdata/zoneinfo/{s}", .{name});
        defer init.gpa.free(path);
        const bytes = try dir.readFileAlloc(init.io, path, init.gpa, .limited(1024 * 1024));
        defer init.gpa.free(bytes);
        var reader = std.Io.Reader.fixed(bytes);
        var tz = try std.tz.Tz.parse(init.gpa, &reader);
        defer tz.deinit();
        try writer.print(".{{ .initial_offset = {d}, .offsets = &.{{", .{tz.timetypes[0].offset});
        for (tz.timetypes, 0..) |time_type, index| {
            const duplicate = for (tz.timetypes[0..index]) |prior| {
                if (prior.offset == time_type.offset) break true;
            } else false;
            if (!duplicate) try writer.print("{d},", .{time_type.offset});
        }
        if (tz.footer) |footer| {
            const future = try tempora.Timezone.Posix.parse(footer);
            try writer.print("{d},", .{future.standard.utc_offset_seconds});
            if (future.dst) |dst| try writer.print("{d},", .{dst.info.utc_offset_seconds});
        }
        try writer.writeAll("}, .transitions = &.{");
        for (tz.transitions) |transition|
            try writer.print(".{{ .at = {d}, .offset = {d} }},", .{ transition.ts, transition.timetype.offset });
        try writer.writeAll("}, .footer = ");
        if (tz.footer) |footer| {
            try writer.print("\"{f}\"", .{std.zig.fmtString(footer)});
        } else try writer.writeAll("null");
        try writer.writeAll("},\n");
    }
    try writer.writeAll("};\n");
    try writer.flush();
}
