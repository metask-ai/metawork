//! One-shot Windows startup HWND identity acquisition for compatibility seams.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub const HWND = ?*anyopaque;
const HHOOK = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMENU = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;

const wh_cbt: i32 = 5;
const hcbt_createwnd: i32 = 3;
const ga_root: u32 = 2;
const gw_owner: u32 = 4;
const ws_child: u32 = 0x4000_0000;

const HookProc = *const fn (i32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const CreateStructW = extern struct {
    create_params: ?*anyopaque,
    instance: HINSTANCE,
    menu: HMENU,
    parent: HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    name: ?[*:0]const u16,
    class_name: ?[*:0]const u16,
    ex_style: DWORD,
};

const CbtCreateWindowW = extern struct {
    create: *const CreateStructW,
    insert_after: HWND,
};

extern "user32" fn SetWindowsHookExW(id: i32, callback: HookProc, module: HINSTANCE, thread_id: DWORD) callconv(.winapi) HHOOK;
extern "user32" fn UnhookWindowsHookEx(hook: HHOOK) callconv(.winapi) BOOL;
extern "user32" fn CallNextHookEx(hook: HHOOK, code: i32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn IsWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetAncestor(window: HWND, flags: u32) callconv(.winapi) HWND;
extern "user32" fn GetWindow(window: HWND, command: u32) callconv(.winapi) HWND;
extern "user32" fn GetWindowThreadProcessId(window: HWND, process_id: *DWORD) callconv(.winapi) DWORD;
extern "user32" fn CreateWindowExW(ex_style: DWORD, class_name: [*:0]const u16, title: [*:0]const u16, style: DWORD, x: i32, y: i32, width: i32, height: i32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

threadlocal var armed_capture: ?*Capture = null;

pub const Binding = struct {
    root: HWND,
};

pub const Capture = struct {
    hook: HHOOK = null,
    thread_id: DWORD = 0,
    process_id: DWORD = 0,
    candidate: HWND = null,
    candidate_count: u8 = 0,
    taken: bool = false,

    pub fn prepare(self: *Capture) !void {
        if (self.hook != null or armed_capture != null)
            return error.StartupWindowCaptureAlreadyArmed;
        self.thread_id = GetCurrentThreadId();
        self.process_id = GetCurrentProcessId();
        self.candidate = null;
        self.candidate_count = 0;
        self.taken = false;
        armed_capture = self;
        errdefer armed_capture = null;
        self.hook = SetWindowsHookExW(
            wh_cbt,
            captureHook,
            null,
            self.thread_id,
        ) orelse return error.StartupWindowCaptureUnavailable;
    }

    pub fn take(
        self: *Capture,
        expected_window_id: native_sdk.platform.WindowId,
    ) !Binding {
        if (expected_window_id == 0) return error.WindowIdentityMismatch;
        if (self.taken) return error.StartupWindowBindingAlreadyTaken;
        try self.stop();
        if (self.candidate_count == 0) return error.WindowUnavailable;
        if (self.candidate_count != 1) return error.WindowIdentityAmbiguous;
        const window = self.candidate orelse return error.WindowUnavailable;
        if (IsWindow(window) == 0 or
            GetAncestor(window, ga_root) != window or
            GetWindow(window, gw_owner) != null)
            return error.WindowIdentityMismatch;
        var process_id: DWORD = 0;
        const thread_id = GetWindowThreadProcessId(window, &process_id);
        if (thread_id != self.thread_id or process_id != self.process_id)
            return error.WindowIdentityMismatch;
        self.taken = true;
        return .{ .root = window };
    }

    pub fn deinit(self: *Capture) void {
        self.stop() catch {};
        self.candidate = null;
        self.candidate_count = 0;
        self.taken = false;
    }

    fn stop(self: *Capture) !void {
        const hook = self.hook orelse return;
        if (armed_capture == self) armed_capture = null;
        if (UnhookWindowsHookEx(hook) == 0)
            return error.StartupWindowCaptureTeardownFailed;
        self.hook = null;
    }
};

fn captureHook(code: i32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    if (code == hcbt_createwnd and lparam != 0) if (armed_capture) |capture| {
        const event: *const CbtCreateWindowW = @ptrFromInt(
            @as(usize, @bitCast(lparam)),
        );
        if (isStartupCandidate(event.create.style, event.create.parent)) {
            capture.candidate_count +|= 1;
            if (capture.candidate_count == 1)
                capture.candidate = @ptrFromInt(wparam);
        }
    };
    return CallNextHookEx(null, code, wparam, lparam);
}

fn isStartupCandidate(style: i32, parent: HWND) bool {
    return (@as(u32, @bitCast(style)) & ws_child) == 0 and parent == null;
}

test "startup capture accepts one current-thread top-level creation" {
    var capture: Capture = .{};
    try capture.prepare();
    defer capture.deinit();
    const window = try createTestWindow();
    defer _ = DestroyWindow(window);
    try std.testing.expectEqual(window, (try capture.take(1)).root);
    try std.testing.expectError(
        error.StartupWindowBindingAlreadyTaken,
        capture.take(1),
    );
}

test "startup capture rejects zero or multiple top-level creations" {
    var empty: Capture = .{};
    try empty.prepare();
    try std.testing.expectError(error.WindowUnavailable, empty.take(1));
    empty.deinit();

    var capture: Capture = .{};
    try capture.prepare();
    defer capture.deinit();
    const first = try createTestWindow();
    defer _ = DestroyWindow(first);
    const second = try createTestWindow();
    defer _ = DestroyWindow(second);
    try std.testing.expectError(error.WindowIdentityAmbiguous, capture.take(1));
}

fn createTestWindow() !HWND {
    return CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        0,
        0,
        0,
        1,
        1,
        null,
        null,
        null,
        null,
    ) orelse error.TestWindowCreationFailed;
}

pub const TestSupport = if (@import("builtin").is_test) struct {
    pub const Window = struct {
        handle: HWND,
        pub fn init() !Window {
            return .{ .handle = try createTestWindow() };
        }
        pub fn deinit(self: Window) void {
            std.debug.assert(DestroyWindow(self.handle) != 0);
        }
    };
} else struct {};
