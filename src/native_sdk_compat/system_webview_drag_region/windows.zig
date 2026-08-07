//! Native SDK 0.8.0 System WebView drag-region support for Windows.
//!
//! The SDK creates its startup HWND before `app.start`. The Desktop Host arms
//! a current-thread CBT hook immediately before entering the SDK runner and
//! closes that interval at the start callback. Exactly one top-level window
//! must be observed; no SDK private context or window-discovery heuristic is
//! used. This file owns the narrow Win32 root binding associated with the
//! startup System WebView. It does not traverse Chromium's cross-process
//! child HWND tree or synthesize window movement.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub const live_pointer_drag = false;
pub const chrome_top_override: ?f64 = 40;
pub const PointIsDraggableFn = *const fn (*const anyopaque, f64, f64) bool;

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
const DWORD_PTR = usize;
const UINT_PTR = usize;

const wh_cbt: i32 = 5;
const hcbt_createwnd: i32 = 3;
const ga_root: u32 = 2;
const gw_owner: u32 = 4;
const wm_nchittest: UINT = 0x0084;
const wm_ncdestroy: UINT = 0x0082;
const htclient: LRESULT = 1;
const htcaption: LRESULT = 2;
const subclass_id: UINT_PTR = 0x4d57_4348;
const ws_child: u32 = 0x4000_0000;

const HookProc = *const fn (i32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const SubclassProc = *const fn (HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR) callconv(.winapi) LRESULT;

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

const Point = extern struct { x: i32, y: i32 };

extern "user32" fn SetWindowsHookExW(id: i32, callback: HookProc, module: HINSTANCE, thread_id: DWORD) callconv(.winapi) HHOOK;
extern "user32" fn UnhookWindowsHookEx(hook: HHOOK) callconv(.winapi) BOOL;
extern "user32" fn CallNextHookEx(hook: HHOOK, code: i32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn IsWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetAncestor(window: HWND, flags: u32) callconv(.winapi) HWND;
extern "user32" fn GetWindow(window: HWND, command: u32) callconv(.winapi) HWND;
extern "user32" fn GetWindowThreadProcessId(window: HWND, process_id: *DWORD) callconv(.winapi) DWORD;
extern "user32" fn ScreenToClient(window: HWND, point: *Point) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) u32;
extern "user32" fn CreateWindowExW(ex_style: DWORD, class_name: [*:0]const u16, title: [*:0]const u16, style: DWORD, x: i32, y: i32, width: i32, height: i32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "comctl32" fn SetWindowSubclass(window: HWND, callback: SubclassProc, id: UINT_PTR, data: DWORD_PTR) callconv(.winapi) BOOL;
extern "comctl32" fn RemoveWindowSubclass(window: HWND, callback: SubclassProc, id: UINT_PTR) callconv(.winapi) BOOL;
extern "comctl32" fn DefSubclassProc(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;

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

    fn deinit(self: *StartupCapture) void {
        self.stop() catch {};
        self.candidate = null;
        self.candidate_count = 0;
    }

    fn stop(self: *StartupCapture) !void {
        const hook = self.hook orelse return;
        if (armed_capture == self) armed_capture = null;
        if (UnhookWindowsHookEx(hook) == 0)
            return error.StartupWindowCaptureTeardownFailed;
        self.hook = null;
    }
};

pub const State = struct {
    capture: StartupCapture = .{},
    root: HWND = null,
    root_bound: bool = false,
    drag_context: ?*const anyopaque = null,
    point_is_draggable: ?PointIsDraggableFn = null,
};

pub fn prepareStartup(
    state: *State,
    context: *const anyopaque,
    point_is_draggable: PointIsDraggableFn,
) !void {
    state.drag_context = context;
    state.point_is_draggable = point_is_draggable;
    errdefer {
        state.drag_context = null;
        state.point_is_draggable = null;
    }
    try state.capture.arm();
}

pub fn captureStartupWindow(
    state: *State,
    window_id: native_sdk.platform.WindowId,
) !void {
    state.root = try state.capture.take(window_id);
}

pub fn requirePlatform(_: native_sdk.platform.PlatformServices) !void {}

pub fn bindRoot(state: *State) !void {
    const root = state.root orelse return error.WindowUnavailable;
    if (state.root_bound) return;
    if (SetWindowSubclass(root, subclassProc, subclass_id, @intFromPtr(state)) == 0)
        return error.SystemWebViewChromeInstallFailed;
    state.root_bound = true;
}

pub fn beginLivePointerDrag(
    _: *State,
    _: native_sdk.platform.PlatformServices,
    _: native_sdk.platform.WindowId,
) !void {
    return error.UnsupportedWindowChromeGesture;
}

pub fn deinit(state: *State) void {
    if (state.root) |root| {
        if (state.root_bound)
            _ = RemoveWindowSubclass(root, subclassProc, subclass_id);
    }
    state.root_bound = false;
    state.root = null;
    state.capture.deinit();
    state.drag_context = null;
    state.point_is_draggable = null;
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

fn subclassProc(
    window: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
    _: UINT_PTR,
    data: DWORD_PTR,
) callconv(.winapi) LRESULT {
    const state: *State = @ptrFromInt(data);
    if (message == wm_ncdestroy) {
        _ = RemoveWindowSubclass(window, subclassProc, subclass_id);
        if (window == state.root) {
            state.root = null;
            state.root_bound = false;
        }
        return DefSubclassProc(window, message, wparam, lparam);
    }
    if (message != wm_nchittest)
        return DefSubclassProc(window, message, wparam, lparam);

    const root = state.root orelse
        return DefSubclassProc(window, message, wparam, lparam);
    const native_hit = DefSubclassProc(window, message, wparam, lparam);
    if (native_hit != htclient) return native_hit;
    var point = screenPoint(lparam);
    if (ScreenToClient(root, &point) == 0)
        return DefSubclassProc(window, message, wparam, lparam);
    const dpi = @max(GetDpiForWindow(root), 96);
    const scale = @as(f64, @floatFromInt(dpi)) / 96.0;
    const context = state.drag_context orelse
        return DefSubclassProc(window, message, wparam, lparam);
    const point_is_draggable = state.point_is_draggable orelse
        return DefSubclassProc(window, message, wparam, lparam);
    if (!point_is_draggable(
        context,
        @as(f64, @floatFromInt(point.x)) / scale,
        @as(f64, @floatFromInt(point.y)) / scale,
    )) return htclient;
    return htcaption;
}

fn screenPoint(lparam: LPARAM) Point {
    const bits: u32 = @truncate(@as(usize, @bitCast(lparam)));
    return .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
    };
}

test "startup capture accepts one current-thread top-level creation" {
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

test "startup capture rejects zero or multiple top-level creations" {
    var empty: StartupCapture = .{};
    try empty.arm();
    try std.testing.expectError(error.WindowUnavailable, empty.take(1));
    empty.deinit();

    var capture: StartupCapture = .{};
    try capture.arm();
    defer capture.deinit();
    const first = CreateWindowExW(
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
    defer _ = DestroyWindow(first);
    const second = CreateWindowExW(
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
    defer _ = DestroyWindow(second);
    try std.testing.expectError(
        error.WindowIdentityAmbiguous,
        capture.take(1),
    );
}
