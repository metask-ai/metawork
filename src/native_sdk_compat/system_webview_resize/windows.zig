//! Owns only a narrow input child; Windows still owns the resize loop. The top
//! band's OS metrics take precedence over DWM's invisible caption-button hits.
//! Never subclasses or inspects WebView2's descendant windows.
const std = @import("std");
const startup_window = @import("../system_webview_startup_window.zig");

const HWND = ?*anyopaque;
const Handle = ?*anyopaque;
const BOOL = i32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WindowProc = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const SubclassProc = *const fn (HWND, UINT, WPARAM, LPARAM, usize, usize) callconv(.winapi) LRESULT;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const Point = extern struct { x: i32, y: i32 };
const WindowClass = extern struct {
    size: UINT = @sizeOf(WindowClass),
    style: UINT = 0,
    proc: WindowProc = childProc,
    class_extra: i32 = 0,
    window_extra: i32 = 0,
    instance: Handle,
    icon: Handle = null,
    cursor: Handle = null,
    background: Handle = null,
    menu_name: ?[*:0]const u16 = null,
    class_name: [*:0]const u16 = class_name,
    small_icon: Handle = null,
};
const CreateStruct = extern struct {
    params: *State,
    instance: Handle,
    menu: Handle,
    parent: HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: i32,
    name: ?[*:0]const u16,
    class: ?[*:0]const u16,
    ex_style: u32,
};

extern "user32" fn RegisterClassExW(*const WindowClass) callconv(.winapi) u16;
extern "user32" fn RegisterWindowMessageW([*:0]const u16) callconv(.winapi) UINT;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, HWND, Handle, Handle, ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowThreadProcessId(HWND, ?*u32) callconv(.winapi) u32;
extern "user32" fn IsWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
extern "user32" fn IsWindowEnabled(HWND) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(HWND, *Rect) callconv(.winapi) BOOL;
extern "user32" fn ScreenToClient(HWND, *Point) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
extern "user32" fn GetSystemMetricsForDpi(i32, UINT) callconv(.winapi) i32;
extern "user32" fn GetWindow(HWND, UINT) callconv(.winapi) HWND;
extern "user32" fn SetWindowPos(HWND, HWND, i32, i32, i32, i32, UINT) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
// MAKEINTRESOURCE is a tagged integer, not an aligned UTF-16 string pointer.
extern "user32" fn LoadCursorW(Handle, ?*const anyopaque) callconv(.winapi) Handle;
extern "user32" fn SetCursor(Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) Handle;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "comctl32" fn SetWindowSubclass(HWND, SubclassProc, usize, usize) callconv(.winapi) BOOL;
extern "comctl32" fn RemoveWindowSubclass(HWND, SubclassProc, usize) callconv(.winapi) BOOL;
extern "comctl32" fn DefSubclassProc(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MetaWorkSystemWebViewTopResize");
const refresh_name = std.unicode.utf8ToUtf16LeStringLiteral("MetaWork.SystemWebViewTopResize.Refresh");
const wm_nccreate = 0x0081;
const wm_ncdestroy = 0x0082;
const wm_nchittest = 0x0084;
const wm_ncbuttondown = 0x00a1;
const wm_ncbuttondoubleclick = 0x00a3;
const wm_setcursor = 0x0020;
const gwlp_userdata = -21;
const ht_top = 12;
const ht_top_left = 13;
const ht_top_right = 14;
var registered_class: u16 = 0;
var refresh_message: UINT = 0;

pub const State = struct {
    root: HWND = null,
    child: HWND = null,
    thread_id: u32 = 0,
    subclass_installed: bool = false,
    refresh_pending: bool = false,
    updating: bool = false,
    stopping: bool = false,
    width: i32 = -1,
    height: i32 = -1,
    press_data: ?*anyopaque = null,
    on_press: ?*const fn (*anyopaque) void = null,

    pub fn attach(self: *State, binding: startup_window.Binding, data: *anyopaque, on_press: *const fn (*anyopaque) void) !void {
        if (self.root != null) return error.TopResizeAlreadyAttached;
        const root = binding.root orelse return error.WindowUnavailable;
        const thread_id = GetCurrentThreadId();
        if (IsWindow(root) == 0 or GetWindowThreadProcessId(root, null) != thread_id)
            return error.WindowIdentityMismatch;
        const instance = GetModuleHandleW(null) orelse return error.TopResizeModuleUnavailable;
        if (registered_class == 0) {
            registered_class = RegisterClassExW(&.{ .instance = instance });
            if (registered_class == 0) return error.TopResizeClassRegistrationFailed;
        }
        if (refresh_message == 0) {
            refresh_message = RegisterWindowMessageW(refresh_name);
            if (refresh_message == 0) return error.TopResizeMessageRegistrationFailed;
        }
        self.* = .{ .root = root, .thread_id = thread_id, .press_data = data, .on_press = on_press };
        errdefer self.deinit();
        if (SetWindowSubclass(root, parentProc, @intFromPtr(self), @intFromPtr(self)) == 0)
            return error.TopResizeSubclassFailed;
        self.subclass_installed = true;
        self.child = CreateWindowExW(
            0x0000_0020, // WS_EX_TRANSPARENT: let the WebView paint beneath this input-only child.
            class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            0x4000_0000 | 0x0400_0000, // WS_CHILD | WS_CLIPSIBLINGS; initially hidden.
            0,
            0,
            0,
            0,
            root,
            null,
            instance,
            self,
        ) orelse return error.TopResizeChildCreationFailed;
        try self.sync();
        try self.queueRefresh();
    }

    pub fn deinit(self: *State) void {
        if (self.root == null and self.child == null) return;
        std.debug.assert(self.thread_id == GetCurrentThreadId());
        self.stopping = true;
        if (self.subclass_installed) {
            if (RemoveWindowSubclass(self.root, parentProc, @intFromPtr(self)) == 0) {
                std.log.err("system_webview_resize: failed to remove host callback", .{});
                return;
            }
            self.subclass_installed = false;
        }
        if (self.child) |child| {
            if (DestroyWindow(child) == 0) {
                std.log.err("system_webview_resize: failed to destroy input child", .{});
                return;
            }
        }
        self.* = .{};
    }

    fn queueRefresh(self: *State) !void {
        if (self.stopping or self.refresh_pending or self.root == null) return;
        if (PostMessageW(self.root, refresh_message, 0, 0) == 0)
            return error.TopResizeRefreshPostFailed;
        self.refresh_pending = true;
    }

    fn sync(self: *State) !void {
        if (self.stopping or self.updating) return;
        const root = self.root orelse return;
        const child = self.child orelse return;
        self.updating = true;
        defer self.updating = false;
        var client: Rect = undefined;
        if (GetClientRect(root, &client) == 0) return error.TopResizeGeometryUnavailable;
        const dpi = GetDpiForWindow(root);
        if (dpi == 0) return error.TopResizeDpiUnavailable;
        const enabled = IsZoomed(root) == 0 and IsIconic(root) == 0 and IsWindowEnabled(root) != 0 and
            (GetWindowLongPtrW(root, -16) & 0x0004_0000) != 0;
        const band = GetSystemMetricsForDpi(33, dpi) + GetSystemMetricsForDpi(92, dpi);
        if (band <= 0) return error.TopResizeGeometryUnavailable;
        const width = @max(0, client.right);
        const height = if (enabled) @min(@max(0, client.bottom), band) else 0;
        const same_size = self.width == width and self.height == height;
        const at_top = GetWindow(child, 3) == null; // GW_HWNDPREV.
        if (same_size and at_top) return;
        var flags: UINT = 0x0010 | (if (height > 0) @as(UINT, 0x0040) else 0x0080); // NOACTIVATE; SHOW/HIDE.
        if (same_size) flags |= 0x0001 | 0x0002; // NOSIZE | NOMOVE.
        if (at_top) flags |= 0x0004; // NOZORDER.
        if (SetWindowPos(child, null, 0, 0, width, height, flags) == 0)
            return error.TopResizePositionFailed;
        self.width = width;
        self.height = height;
    }

    fn fail(self: *State, err: anyerror) void {
        std.log.err("system_webview_resize: {s}; removing input layer", .{@errorName(err)});
        self.deinit();
    }

    fn hitTest(self: *const State, screen_coordinates: LPARAM) isize {
        const root = self.root orelse return -1;
        if (self.stopping or IsZoomed(root) != 0 or IsIconic(root) != 0 or IsWindowEnabled(root) == 0 or
            (GetWindowLongPtrW(root, -16) & 0x0004_0000) == 0) return -1;
        const bits: usize = @bitCast(screen_coordinates);
        var point = Point{
            .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))),
            .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
        };
        var client: Rect = undefined;
        if (ScreenToClient(root, &point) == 0 or GetClientRect(root, &client) == 0) return -1;
        const dpi = GetDpiForWindow(root);
        if (dpi == 0) return -1;
        const padding = GetSystemMetricsForDpi(92, dpi);
        const top = GetSystemMetricsForDpi(33, dpi) + padding;
        const corner = GetSystemMetricsForDpi(32, dpi) + padding;
        if (point.x < 0 or point.x >= client.right or point.y < 0 or point.y >= @min(client.bottom, top)) return -1;
        if (point.x < corner) return ht_top_left;
        if (point.x >= client.right - corner) return ht_top_right;
        return ht_top;
    }
};

fn parentProc(root: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM, id: usize, data: usize) callconv(.winapi) LRESULT {
    const self: *State = @ptrFromInt(data);
    if (message == wm_ncdestroy) {
        _ = RemoveWindowSubclass(root, parentProc, id);
        self.subclass_installed = false;
        self.root = null;
        self.refresh_pending = false;
        self.stopping = true;
        return DefSubclassProc(root, message, wparam, lparam);
    }
    if (message == refresh_message) {
        self.refresh_pending = false;
        self.sync() catch |err| self.fail(err);
        return 0;
    }
    const result = DefSubclassProc(root, message, wparam, lparam);
    if (self.stopping) return result;
    switch (message) {
        0x0005, 0x000a, 0x0018, 0x007d, 0x02e0 => self.sync() catch |err| self.fail(err), // SIZE, ENABLE, SHOWWINDOW, STYLECHANGED, DPICHANGED.
        0x0210 => { // PARENTNOTIFY. Reorder after the new WebView's creation stack completes.
            if ((wparam & 0xffff) == 1 and @as(usize, @bitCast(lparam)) != @intFromPtr(self.child))
                self.queueRefresh() catch |err| self.fail(err);
        },
        else => {},
    }
    return result;
}

fn childProc(child: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    if (message == wm_nccreate) {
        const create: *const CreateStruct = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = SetWindowLongPtrW(child, gwlp_userdata, @bitCast(@intFromPtr(create.params)));
        create.params.child = child;
    }
    const address = GetWindowLongPtrW(child, gwlp_userdata);
    if (address == 0) return DefWindowProcW(child, message, wparam, lparam);
    const self: *State = @ptrFromInt(@as(usize, @bitCast(address)));
    if (message == wm_ncdestroy) {
        _ = SetWindowLongPtrW(child, gwlp_userdata, 0);
        self.child = null;
        return DefWindowProcW(child, message, wparam, lparam);
    }
    if (self.stopping or self.root == null) return DefWindowProcW(child, message, wparam, lparam);
    switch (message) {
        wm_nchittest => {
            return self.hitTest(lparam);
        },
        wm_setcursor => {
            const hit: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)))));
            const cursor_id: usize = switch (hit) {
                ht_top => 32645, // IDC_SIZENS.
                ht_top_left => 32642, // IDC_SIZENWSE.
                ht_top_right => 32643, // IDC_SIZENESW.
                else => return DefWindowProcW(child, message, wparam, lparam),
            };
            if (LoadCursorW(null, @ptrFromInt(cursor_id))) |cursor| {
                _ = SetCursor(cursor);
                return 1;
            }
        },
        wm_ncbuttondown, wm_ncbuttondoubleclick => {
            const root = self.root;
            const hit = self.hitTest(lparam);
            if (isTopResize(hit)) {
                if (self.on_press) |on_press| on_press(self.press_data.?);
                _ = ReleaseCapture();
                if (PostMessageW(root, message, @intCast(hit), lparam) == 0)
                    self.fail(error.TopResizeInputPostFailed);
            }
            return 0;
        },
        else => {},
    }
    return DefWindowProcW(child, message, wparam, lparam);
}

fn isTopResize(hit: isize) bool {
    return hit == ht_top or hit == ht_top_left or hit == ht_top_right;
}

var test_destroy_during_install = false;

fn testHostProc(root: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    if (test_destroy_during_install and message == 0x0210 and (wparam & 0xffff) == 1) {
        test_destroy_during_install = false;
        _ = DestroyWindow(root);
        return 0;
    }
    return DefWindowProcW(root, message, wparam, lparam);
}

fn testWindow() !HWND {
    const Fixture = struct {
        var atom: u16 = 0;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("MetaWorkTopResizeTestHost");
    };
    const instance = GetModuleHandleW(null);
    if (Fixture.atom == 0) {
        Fixture.atom = RegisterClassExW(&.{ .instance = instance, .proc = testHostProc, .class_name = Fixture.name });
        if (Fixture.atom == 0) return error.TestHostRegistrationFailed;
    }
    // Hidden window at negative screen coordinates: no interactive desktop needed.
    return CreateWindowExW(0, Fixture.name, Fixture.name, 0x00cf_0000, -1000, -200, 900, 620, null, null, instance, null) orelse
        error.TestHostCreationFailed;
}

fn testReset(data: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(data));
    count.* += 1;
}

fn testScreenPoint(root: HWND, x: i32, y: i32) LPARAM {
    var offset = Point{ .x = 0, .y = 0 };
    std.debug.assert(ScreenToClient(root, &offset) != 0);
    const screen_x: u16 = @bitCast(@as(i16, @intCast(x - offset.x)));
    const screen_y: u16 = @bitCast(@as(i16, @intCast(y - offset.y)));
    return @bitCast(@as(usize, screen_x) | (@as(usize, screen_y) << 16));
}

test "top resize rejects an unavailable binding without installing resources" {
    var state: State = .{};
    var presses: usize = 0;
    try std.testing.expectError(error.WindowUnavailable, state.attach(.{ .root = null }, &presses, testReset));
    try std.testing.expectError(error.WindowIdentityMismatch, state.attach(.{ .root = @ptrFromInt(1) }, &presses, testReset));
    try std.testing.expect(state.root == null and state.child == null and !state.subclass_installed);
    state.deinit();
}

test "top resize rolls back if the host is destroyed during child installation" {
    const root = try testWindow();
    defer {
        if (IsWindow(root) != 0) _ = DestroyWindow(root);
    }
    var state: State = .{};
    defer state.deinit();
    var presses: usize = 0;
    test_destroy_during_install = true;
    defer test_destroy_during_install = false;
    if (state.attach(.{ .root = root }, &presses, testReset)) |_| {
        return error.DestroyedHostWasAccepted;
    } else |err| {
        try std.testing.expect(err == error.TopResizeChildCreationFailed or err == error.WindowUnavailable);
    }
    try std.testing.expect(IsWindow(root) == 0);
    try std.testing.expect(state.root == null and state.child == null and !state.subclass_installed);
}

test "top resize uses live geometry, signed screen coordinates and resizable style" {
    const root = try testWindow();
    defer _ = DestroyWindow(root);
    var state: State = .{};
    var presses: usize = 0;
    try state.attach(.{ .root = root }, &presses, testReset);
    defer state.deinit();
    try std.testing.expect(state.height > 0);
    try std.testing.expectEqual(@as(isize, ht_top_left), state.hitTest(testScreenPoint(root, 0, 1)));
    try std.testing.expectEqual(@as(isize, ht_top), state.hitTest(testScreenPoint(root, @divTrunc(state.width, 2), 1)));
    try std.testing.expectEqual(@as(isize, ht_top_right), state.hitTest(testScreenPoint(root, state.width - 1, 1)));
    for ([_]Point{ .{ .x = -1, .y = 1 }, .{ .x = state.width, .y = 1 }, .{ .x = 10, .y = -1 }, .{ .x = 10, .y = state.height } }) |point| {
        try std.testing.expectEqual(@as(isize, -1), state.hitTest(testScreenPoint(root, point.x, point.y)));
    }
    const style = GetWindowLongPtrW(root, -16);
    _ = SetWindowLongPtrW(root, -16, style & ~@as(isize, 0x0004_0000));
    try std.testing.expectEqual(@as(i32, 0), state.height);
    try std.testing.expectEqual(@as(isize, -1), state.hitTest(testScreenPoint(root, 10, 1)));
    _ = SetWindowLongPtrW(root, -16, style);
    try std.testing.expect(state.height > 0);
    const child = state.child;
    try std.testing.expectError(error.TopResizeAlreadyAttached, state.attach(.{ .root = root }, &presses, testReset));
    try std.testing.expectEqual(child, state.child);
    // Coalescing changes neither geometry nor resources.
    for (0..100) |_| {
        try state.queueRefresh();
        try state.sync();
    }
    try std.testing.expectEqual(child, state.child);
    try std.testing.expect(state.refresh_pending);
}

test "top resize cleanup removes callbacks and children on repeated attach and detach" {
    const root = try testWindow();
    defer _ = DestroyWindow(root);
    var state: State = .{};
    var presses: usize = 0;
    for (0..100) |_| {
        try state.attach(.{ .root = root }, &presses, testReset);
        const child = state.child;
        state.deinit();
        state.deinit();
        try std.testing.expect(IsWindow(child) == 0);
        try std.testing.expect(GetWindow(root, 5) == null); // GW_CHILD: no orphan input window.
        try std.testing.expect(state.root == null and state.child == null and !state.subclass_installed);
    }
}

test "top resize tolerates root-first and child-first destruction" {
    var presses: usize = 0;
    var state: State = .{};
    const root = try testWindow();
    try state.attach(.{ .root = root }, &presses, testReset);
    try std.testing.expect(DestroyWindow(root) != 0);
    try std.testing.expect(state.root == null and state.child == null and !state.subclass_installed);
    state.deinit();
    // Reuse the owner after the old HWND and its pending refresh are gone.
    const next = try testWindow();
    defer _ = DestroyWindow(next);
    try state.attach(.{ .root = next }, &presses, testReset);
    try std.testing.expect(DestroyWindow(state.child) != 0);
    try std.testing.expect(state.child == null);
    state.deinit();
    state.deinit();
    try std.testing.expect(state.root == null and !state.subclass_installed);
}
