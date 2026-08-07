//! Native SDK 0.8.0 System WebView window-control compatibility for Windows.
//!
//! The SDK does not expose maximize/restore, user-close, or maximized state.
//! These capabilities share the startup HWND lifecycle but retain explicit
//! entry points and independent removal conditions.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub const renderer_controls = true;

const HWND = ?*anyopaque;
const HHOOK = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMENU = ?*anyopaque;
const BOOL = i32;
const UINT = u32;
const DWORD = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;

const wh_cbt: i32 = 5;
const hcbt_createwnd: i32 = 3;
const ga_root: u32 = 2;
const gw_owner: u32 = 4;
const wm_close: UINT = 0x0010;
const ws_child: u32 = 0x4000_0000;
const sw_maximize: i32 = 3;
const sw_restore: i32 = 9;

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
extern "user32" fn PostMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn IsZoomed(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(window: HWND, command: i32) callconv(.winapi) BOOL;
extern "user32" fn CreateWindowExW(ex_style: DWORD, class_name: [*:0]const u16, title: [*:0]const u16, style: DWORD, x: i32, y: i32, width: i32, height: i32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

threadlocal var armed_capture: ?*StartupCapture = null;

const StartupCapture = struct {
    hook: HHOOK = null,
    thread_id: DWORD = 0,
    process_id: DWORD = 0,
    candidate: HWND = null,
    candidate_count: u8 = 0,

    fn arm(self: *StartupCapture) !void {
        if (self.hook != null or armed_capture != null)
            return error.StartupWindowCaptureAlreadyArmed;
        self.thread_id = GetCurrentThreadId();
        self.process_id = GetCurrentProcessId();
        self.candidate = null;
        self.candidate_count = 0;
        armed_capture = self;
        errdefer armed_capture = null;
        self.hook = SetWindowsHookExW(
            wh_cbt,
            captureHook,
            null,
            self.thread_id,
        ) orelse return error.StartupWindowCaptureUnavailable;
    }

    fn take(
        self: *StartupCapture,
        expected_window_id: native_sdk.platform.WindowId,
    ) !HWND {
        if (expected_window_id == 0) return error.WindowIdentityMismatch;
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
        return window;
    }

    fn stop(self: *StartupCapture) !void {
        const hook = self.hook orelse return;
        if (armed_capture == self) armed_capture = null;
        if (UnhookWindowsHookEx(hook) == 0)
            return error.StartupWindowCaptureTeardownFailed;
        self.hook = null;
    }

    fn deinit(self: *StartupCapture) void {
        self.stop() catch {};
        self.candidate = null;
        self.candidate_count = 0;
    }
};

pub const State = struct {
    capture: StartupCapture = .{},
    root: HWND = null,
};

pub fn prepareStartup(state: *State) !void {
    try state.capture.arm();
}

pub fn captureStartupWindow(
    state: *State,
    window_id: native_sdk.platform.WindowId,
) !void {
    state.root = try state.capture.take(window_id);
}

pub fn toggleMaximize(state: *State) !void {
    const root = state.root orelse return error.WindowUnavailable;
    _ = ShowWindow(
        root,
        if (IsZoomed(root) != 0) sw_restore else sw_maximize,
    );
}

pub fn userClose(state: *State) !void {
    const root = state.root orelse return error.WindowUnavailable;
    if (PostMessageW(root, wm_close, 0, 0) == 0)
        return error.SystemWebViewUserCloseFailed;
}

pub fn maximized(state: *const State) bool {
    return if (state.root) |root| IsZoomed(root) != 0 else false;
}

pub fn deinit(state: *State) void {
    state.capture.deinit();
    state.root = null;
}

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

test "button seam captures one current-thread startup window" {
    var capture: StartupCapture = .{};
    try capture.arm();
    defer capture.deinit();
    const window = CreateWindowExW(
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
    ) orelse return error.TestWindowCreationFailed;
    defer _ = DestroyWindow(window);
    try std.testing.expectEqual(window, try capture.take(1));
}
