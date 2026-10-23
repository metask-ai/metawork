//! Application-only Office installer validation. The current Native SDK does
//! not expose available-volume bytes or Authenticode verification.
const std = @import("std");
const builtin = @import("builtin");

const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const FileInfo = extern struct {
    size: u32 = @sizeOf(FileInfo),
    path: [*:0]const u16,
    file: ?*anyopaque = null,
    subject: ?*Guid = null,
};
const TrustData = extern struct {
    size: u32 = @sizeOf(TrustData),
    policy: ?*anyopaque = null,
    sip: ?*anyopaque = null,
    ui: u32 = 2, // WTD_UI_NONE
    revocation: u32 = 0,
    choice: u32 = 1, // WTD_CHOICE_FILE
    info: *FileInfo,
    action: u32 = 1, // WTD_STATEACTION_VERIFY
    state: ?*anyopaque = null,
    url: ?[*:0]const u16 = null,
    // No network or additional revocation retrieval. Main's exact archive
    // digest is the release authority; Windows still verifies Authenticode.
    flags: u32 = 0x1000 | 0x10,
    context: u32 = 0,
    signatures: ?*anyopaque = null,
};

extern "wintrust" fn WinVerifyTrust(?*anyopaque, *Guid, *TrustData) callconv(.winapi) i32;
extern "kernel32" fn GetDiskFreeSpaceExW([*:0]const u16, *u64, ?*u64, ?*u64) callconv(.winapi) i32;

pub fn availableBytes(allocator: std.mem.Allocator, directory: []const u8) !u64 {
    if (builtin.os.tag != .windows) return error.UnsupportedComponentTarget;
    const wide = try widePath(allocator, directory);
    defer allocator.free(wide);
    var available: u64 = 0;
    if (GetDiskFreeSpaceExW(wide, &available, null, null) == 0) return error.DiskSpaceUnavailable;
    return available;
}

pub fn verifySignature(allocator: std.mem.Allocator, path: []const u8) !void {
    if (try signatureStatus(allocator, path) != 0) return error.InvalidAuthenticode;
}

pub fn signatureStatus(allocator: std.mem.Allocator, path: []const u8) !i32 {
    if (builtin.os.tag != .windows) return error.UnsupportedComponentTarget;
    const wide = try widePath(allocator, path);
    defer allocator.free(wide);
    var file: FileInfo = .{ .path = wide };
    var data: TrustData = .{ .info = &file };
    var action: Guid = .{ .a = 0x00aac56b, .b = 0xcd44, .c = 0x11d0, .d = .{ 0x8c, 0xc2, 0, 0xc0, 0x4f, 0xc2, 0x95, 0xee } };
    const no_ui: *anyopaque = @ptrFromInt(std.math.maxInt(usize));
    const result = WinVerifyTrust(no_ui, &action, &data);
    defer {
        data.action = 2; // WTD_STATEACTION_CLOSE, including failed verifications
        _ = WinVerifyTrust(no_ui, &action, &data);
    }
    return result;
}

fn widePath(allocator: std.mem.Allocator, path: []const u8) ![:0]u16 {
    if (path.len == 0 or path.len > 4096 or !std.fs.path.isAbsolute(path)) return error.InvalidComponentPath;
    for (path) |character| if (std.ascii.isControl(character)) return error.InvalidComponentPath;
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
}

test "Office Windows validation rejects unsupported targets before platform effects" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectError(error.UnsupportedComponentTarget, availableBytes(std.testing.allocator, "."));
    try std.testing.expectError(error.UnsupportedComponentTarget, signatureStatus(std.testing.allocator, "."));
    try std.testing.expectError(error.UnsupportedComponentTarget, verifySignature(std.testing.allocator, "."));
}

test "Office disk observations are scoped to existing absolute directories" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expect(try availableBytes(std.testing.allocator, root) > 0);
    try std.testing.expectError(error.InvalidComponentPath, availableBytes(std.testing.allocator, "."));
    try std.testing.expectError(error.InvalidAuthenticode, verifySignature(std.testing.allocator, root));
}
