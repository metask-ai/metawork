//! Opens one Application-validated HTML file URL in the system web browser.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .windows or builtin.os.tag == .macos;

pub fn openHtml(url: []const u8) !void {
    const extension = std.fs.path.extension(url);
    if (!std.mem.startsWith(u8, url, "file://") or
        !(std.ascii.eqlIgnoreCase(extension, ".html") or std.ascii.eqlIgnoreCase(extension, ".htm")))
        return error.RestrictedOutput;
    return switch (builtin.os.tag) {
        .windows => windows.open(url),
        .macos => macos.open(url),
        else => error.UnsupportedService,
    };
}

const windows = struct {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;

    extern "shlwapi" fn AssocQueryStringW(u32, u32, [*:0]const u16, ?[*:0]const u16, [*]u16, *u32) callconv(.winapi) i32;
    extern "shell32" fn ShellExecuteW(?*anyopaque, [*:0]const u16, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) usize;

    fn open(url: []const u8) !void {
        const assocf_is_protocol = 0x1000;
        const assocstr_executable = 2;
        var executable: [32768:0]u16 = undefined;
        var executable_len: u32 = executable.len;
        if (AssocQueryStringW(assocf_is_protocol, assocstr_executable, wide("https"), wide("open"), &executable, &executable_len) != 0 or
            executable_len < 2 or executable_len > executable.len or executable[executable_len - 1] != 0 or
            !std.fs.path.isAbsoluteWindowsWtf16(executable[0 .. executable_len - 1]))
            return error.UnsupportedService;
        const allocator = std.heap.c_allocator;
        const argument = try std.fmt.allocPrint(allocator, "\"{s}\"", .{url});
        defer allocator.free(argument);
        const parameters = try std.unicode.utf8ToUtf16LeAllocZ(allocator, argument);
        defer allocator.free(parameters);
        const result = ShellExecuteW(null, wide("open"), @ptrCast(&executable), parameters, null, 1);
        if (result <= 32) return error.BrowserHandoffFailed;
    }
};

const macos = struct {
    const Ref = *const anyopaque;
    const LaunchSpec = extern struct {
        application: Ref,
        items: Ref,
        pass_through: ?Ref = null,
        flags: u32 = 1, // kLSLaunchDefaults
        async_context: ?*anyopaque = null,
    };
    extern "CoreFoundation" fn CFURLCreateWithBytes(?Ref, [*]const u8, isize, u32, ?Ref) ?Ref;
    extern "CoreFoundation" fn CFArrayCreate(?Ref, [*]const Ref, isize, ?Ref) ?Ref;
    extern "CoreFoundation" fn CFRelease(Ref) void;
    extern "CoreServices" fn LSCopyDefaultApplicationURLForURL(Ref, u32, ?*?Ref) ?Ref;
    extern "CoreServices" fn LSOpenFromURLSpec(*const LaunchSpec, ?*?Ref) i32;

    fn urlRef(url: []const u8) !Ref {
        const utf8_encoding = 0x08000100; // kCFStringEncodingUTF8
        return CFURLCreateWithBytes(null, url.ptr, @intCast(url.len), utf8_encoding, null) orelse error.InvalidOutputPath;
    }

    fn open(url: []const u8) !void {
        const https = try urlRef("https://example.invalid");
        defer CFRelease(https);
        const application = LSCopyDefaultApplicationURLForURL(https, 0xffffffff, null) orelse return error.UnsupportedService;
        defer CFRelease(application);
        const file = try urlRef(url);
        defer CFRelease(file);
        const items = CFArrayCreate(null, &.{file}, 1, null) orelse return error.BrowserHandoffFailed;
        defer CFRelease(items);
        if (LSOpenFromURLSpec(&.{ .application = application, .items = items }, null) != 0)
            return error.BrowserHandoffFailed;
    }
};
