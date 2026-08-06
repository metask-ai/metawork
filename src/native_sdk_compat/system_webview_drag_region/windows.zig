//! Native SDK 0.8.0 System WebView drag-region support for Windows.
//!
//! The SDK creates its startup HWND before `app.start`. The Desktop Host arms
//! a current-thread CBT hook immediately before entering the SDK runner and
//! closes that interval at the start callback. Exactly one top-level window
//! must be observed; no SDK private context or window-discovery heuristic is
//! used. This file also owns the Win32 subclass and overlay resources needed
//! to project the validated drag region over the startup System WebView.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub const live_pointer_drag = false;
pub const PointIsDraggableFn = *const fn (*const anyopaque, f64, f64) bool;

const HWND = ?*anyopaque;
const HHOOK = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMENU = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
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
const wm_nclbuttondown: UINT = 0x00a1;
const wm_nclbuttondblclk: UINT = 0x00a3;
const wm_ncrbuttondown: UINT = 0x00a4;
const wm_ncrbuttonup: UINT = 0x00a5;
const wm_syscommand: UINT = 0x0112;
const wm_null: UINT = 0x0000;
const wm_paint: UINT = 0x000f;
const wm_size: UINT = 0x0005;
const wm_activate: UINT = 0x0006;
const wm_showwindow: UINT = 0x0018;
const wm_windowposchanged: UINT = 0x0047;
const wm_dpichanged: UINT = 0x02e0;
const htclient: LRESULT = 1;
const httransparent: LRESULT = -1;
const htcaption: LRESULT = 2;
const tpm_rightbutton: UINT = 0x0002;
const tpm_nonotify: UINT = 0x0080;
const tpm_returncmd: UINT = 0x0100;
const subclass_id: UINT_PTR = 0x4d57_4348;
const cs_dblclks: u32 = 0x0008;
const ws_child: u32 = 0x4000_0000;
const ws_visible: u32 = 0x1000_0000;
const ws_ex_transparent: u32 = 0x0000_0020;
const ws_ex_noactivate: u32 = 0x0800_0000;
const swp_noactivate: u32 = 0x0010;
const swp_showwindow: u32 = 0x0040;

const HookProc = *const fn (i32, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const SubclassProc = *const fn (HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR) callconv(.winapi) LRESULT;
const WndProc = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const EnumProc = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;

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

const WndClassExW = extern struct {
    size: u32,
    style: u32,
    window_proc: WndProc,
    class_extra: i32,
    window_extra: i32,
    instance: HINSTANCE,
    icon: HICON,
    cursor: HCURSOR,
    background: HBRUSH,
    menu_name: ?[*:0]const u16,
    class_name: [*:0]const u16,
    small_icon: HICON,
};

const Point = extern struct { x: i32, y: i32 };
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

const overlay_class_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "MetaWorkSystemWebViewChrome",
);
var overlay_class_registered = false;

extern "user32" fn SetWindowsHookExW(id: i32, callback: HookProc, module: HINSTANCE, thread_id: DWORD) callconv(.winapi) HHOOK;
extern "user32" fn UnhookWindowsHookEx(hook: HHOOK) callconv(.winapi) BOOL;
extern "user32" fn CallNextHookEx(hook: HHOOK, code: i32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn IsWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetAncestor(window: HWND, flags: u32) callconv(.winapi) HWND;
extern "user32" fn GetWindow(window: HWND, command: u32) callconv(.winapi) HWND;
extern "user32" fn GetWindowThreadProcessId(window: HWND, process_id: *DWORD) callconv(.winapi) DWORD;
extern "user32" fn EnumChildWindows(parent: HWND, callback: EnumProc, data: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn RegisterClassExW(class: *const WndClassExW) callconv(.winapi) u16;
extern "user32" fn DefWindowProcW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ScreenToClient(window: HWND, point: *Point) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) u32;
extern "user32" fn GetClientRect(window: HWND, rect: *Rect) callconv(.winapi) BOOL;
extern "user32" fn GetCursorPos(point: *Point) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMenu(window: HWND, revert: BOOL) callconv(.winapi) HMENU;
extern "user32" fn TrackPopupMenu(menu: HMENU, flags: UINT, x: i32, y: i32, reserved: i32, window: HWND, rect: ?*const Rect) callconv(.winapi) UINT;
extern "user32" fn CreateWindowExW(ex_style: DWORD, class_name: [*:0]const u16, title: [*:0]const u16, style: DWORD, x: i32, y: i32, width: i32, height: i32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(window: HWND, insert_after: HWND, x: i32, y: i32, width: i32, height: i32, flags: u32) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn SendMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ValidateRect(window: HWND, rect: ?*const Rect) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetModuleHandleW(module_name: ?[*:0]const u16) callconv(.winapi) HINSTANCE;
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
    overlay: HWND = null,
    band_height: f64 = 1,
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

pub fn install(
    state: *State,
    services: native_sdk.platform.PlatformServices,
    window_id: native_sdk.platform.WindowId,
) !void {
    const root = state.root orelse return error.WindowUnavailable;
    if (SetWindowSubclass(root, subclassProc, subclass_id, @intFromPtr(state)) == 0)
        return error.SystemWebViewChromeInstallFailed;
    const overlay = state.overlay orelse create: {
        const instance = GetModuleHandleW(null) orelse
            return error.SystemWebViewChromeInstallFailed;
        if (!overlay_class_registered) {
            const class = WndClassExW{
                .size = @sizeOf(WndClassExW),
                .style = cs_dblclks,
                .window_proc = overlayWindowProc,
                .class_extra = 0,
                .window_extra = 0,
                .instance = instance,
                .icon = null,
                .cursor = null,
                .background = null,
                .menu_name = null,
                .class_name = overlay_class_name,
                .small_icon = null,
            };
            if (RegisterClassExW(&class) == 0)
                return error.SystemWebViewChromeInstallFailed;
            overlay_class_registered = true;
        }
        const created = CreateWindowExW(
            ws_ex_transparent | ws_ex_noactivate,
            overlay_class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            ws_child | ws_visible,
            0,
            0,
            1,
            1,
            root,
            null,
            instance,
            null,
        ) orelse return error.SystemWebViewChromeInstallFailed;
        state.overlay = created;
        if (SetWindowSubclass(
            created,
            subclassProc,
            subclass_id,
            @intFromPtr(state),
        ) == 0) {
            _ = DestroyWindow(created);
            state.overlay = null;
            return error.SystemWebViewChromeInstallFailed;
        }
        break :create created;
    };
    _ = overlay;
    const chrome = services.windowChrome(window_id);
    state.band_height = @max(chrome.insets.top, 1);
    try layoutOverlay(state);
    _ = EnumChildWindows(root, installChild, @bitCast(@intFromPtr(state)));
}

pub fn beginLivePointerDrag(
    _: *State,
    _: native_sdk.platform.PlatformServices,
    _: native_sdk.platform.WindowId,
) !void {
    return error.UnsupportedWindowChromeGesture;
}

pub fn deinit(state: *State) void {
    uninstall(state);
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

fn uninstall(state: *State) void {
    const root = state.root orelse return;
    _ = EnumChildWindows(root, removeChild, 0);
    if (state.overlay) |overlay| {
        _ = RemoveWindowSubclass(overlay, subclassProc, subclass_id);
        _ = DestroyWindow(overlay);
        state.overlay = null;
    }
    _ = RemoveWindowSubclass(root, subclassProc, subclass_id);
    state.root = null;
}

fn installChild(window: HWND, data: LPARAM) callconv(.winapi) BOOL {
    const state: *State = @ptrFromInt(@as(usize, @bitCast(data)));
    if (window != state.overlay)
        _ = SetWindowSubclass(window, subclassProc, subclass_id, @intFromPtr(state));
    return 1;
}

fn removeChild(window: HWND, _: LPARAM) callconv(.winapi) BOOL {
    _ = RemoveWindowSubclass(window, subclassProc, subclass_id);
    return 1;
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
        return DefSubclassProc(window, message, wparam, lparam);
    }
    if (window == state.overlay) {
        if (message == wm_paint) {
            _ = ValidateRect(window, null);
            return 0;
        }
        if (message == wm_nchittest) {
            const root = state.root orelse return httransparent;
            const root_hit = SendMessageW(root, message, wparam, lparam);
            return if (root_hit == htclient) httransparent else root_hit;
        }
        if (message == wm_ncrbuttonup) {
            const root = state.root orelse return 0;
            showSystemMenu(root);
            return 0;
        }
        if (message == wm_nclbuttondown or
            message == wm_nclbuttondblclk or
            message == wm_ncrbuttondown)
        {
            const root = state.root orelse return 0;
            return SendMessageW(root, message, wparam, lparam);
        }
        return DefSubclassProc(window, message, wparam, lparam);
    }
    if (window != state.root and message == wm_windowposchanged) {
        const result = DefSubclassProc(window, message, wparam, lparam);
        layoutOverlay(state) catch {};
        return result;
    }
    if (window != state.root) {
        if (message == wm_nchittest) {
            const root = state.root orelse
                return DefSubclassProc(window, message, wparam, lparam);
            if (SendMessageW(root, message, wparam, lparam) != htclient)
                return httransparent;
        }
        return DefSubclassProc(window, message, wparam, lparam);
    }
    if (message == wm_size or message == wm_activate or
        message == wm_showwindow or message == wm_dpichanged)
    {
        const result = DefSubclassProc(window, message, wparam, lparam);
        layoutOverlay(state) catch {};
        return result;
    }
    if (message != wm_nchittest)
        return DefSubclassProc(window, message, wparam, lparam);

    const root = state.root orelse
        return DefSubclassProc(window, message, wparam, lparam);
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
    )) return DefSubclassProc(window, message, wparam, lparam);

    const native_hit = DefSubclassProc(window, message, wparam, lparam);
    return if (native_hit == htclient) htcaption else native_hit;
}

fn overlayWindowProc(
    window: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT {
    return DefWindowProcW(window, message, wparam, lparam);
}

fn layoutOverlay(state: *State) !void {
    const root = state.root orelse
        return error.SystemWebViewChromeInstallFailed;
    const overlay = state.overlay orelse
        return error.SystemWebViewChromeInstallFailed;
    var client: Rect = undefined;
    if (GetClientRect(root, &client) == 0)
        return error.SystemWebViewChromeInstallFailed;
    const scale = @as(f64, @floatFromInt(@max(GetDpiForWindow(root), 96))) / 96.0;
    const height = @max(
        @as(i32, 1),
        @as(i32, @intFromFloat(@ceil(state.band_height * scale))),
    );
    if (SetWindowPos(
        overlay,
        null,
        0,
        0,
        @max(@as(i32, 1), client.right),
        height,
        swp_noactivate | swp_showwindow,
    ) == 0) return error.SystemWebViewChromeInstallFailed;
}

fn showSystemMenu(root: HWND) void {
    const menu = GetSystemMenu(root, 0) orelse return;
    var point: Point = undefined;
    if (GetCursorPos(&point) == 0) return;
    const command = TrackPopupMenu(
        menu,
        tpm_returncmd | tpm_nonotify | tpm_rightbutton,
        point.x,
        point.y,
        0,
        root,
        null,
    );
    if (command != 0) _ = PostMessageW(root, wm_syscommand, command, 0);
    _ = PostMessageW(root, wm_null, 0, 0);
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
