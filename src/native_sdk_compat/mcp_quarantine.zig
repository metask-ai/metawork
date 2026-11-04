//! Application-only macOS atomic, non-replacing MCP quarantine moves.
//! The caller derives the bounded leaf names from Product's typed request.
const std = @import("std");
const builtin = @import("builtin");

extern "c" fn renameatx_np(c_int, [*:0]const u8, c_int, [*:0]const u8, c_uint) c_int;

pub fn move(io: std.Io, source: std.Io.Dir, source_name: []const u8, target: std.Io.Dir, target_name: []const u8) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    for ([_][]const u8{ source_name, target_name }) |name| {
        if (name.len == 0 or name.len > 25 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
        for (name) |byte| if (byte == '/' or byte == '\\' or byte == 0) return error.InvalidName;
    }
    const from = try std.posix.toPosixPath(source_name);
    const to = try std.posix.toPosixPath(target_name);
    try io.checkCancel();
    while (true) switch (std.c.errno(renameatx_np(source.handle, &from, target.handle, &to, 4))) { // RENAME_EXCL
        .SUCCESS => return,
        .INTR => try io.checkCancel(),
        .EXIST, .NOTEMPTY => return error.PathAlreadyExists,
        else => return error.MoveFailed,
    };
}
