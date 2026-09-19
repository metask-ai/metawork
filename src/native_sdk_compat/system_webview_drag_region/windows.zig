//! Native SDK 0.10.1 System WebView titlebar compatibility for Windows.
//!
//! The SDK's public drag-region mirror only applies to GPU surfaces. The
//! startup System WebView remains windowed, so this seam reauthorizes each
//! browser pointer press against live OS state, delegates the first press to
//! the system caption loop, and classifies a second press with OS thresholds.

const std = @import("std");
const native_sdk = @import("native_sdk");
const startup_window = @import("../system_webview_startup_window.zig");
const types = @import("types.zig");

pub const live_pointer_drag = true;
pub const chrome_top_override: ?f64 = 40;

const HWND = ?*anyopaque;
const BOOL = i32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;

const ga_root: u32 = 2;
const sm_swapbutton: i32 = 23;
const sm_cxdoubleclk: i32 = 36;
const sm_cydoubleclk: i32 = 37;
const vk_lbutton: i32 = 0x01;
const vk_rbutton: i32 = 0x02;
const wm_nchittest: UINT = 0x0084;
const wm_nclbuttondown: UINT = 0x00a1;
const htclient: isize = 1;
const htcaption: WPARAM = 2;

const Point = extern struct { x: i32, y: i32 };
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

extern "user32" fn IsWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetrics(index: i32) callconv(.winapi) i32;
extern "user32" fn GetAsyncKeyState(key: i32) callconv(.winapi) i16;
extern "user32" fn GetCursorPos(point: *Point) callconv(.winapi) BOOL;
extern "user32" fn WindowFromPoint(point: Point) callconv(.winapi) HWND;
extern "user32" fn GetAncestor(window: HWND, flags: u32) callconv(.winapi) HWND;
extern "user32" fn ScreenToClient(window: HWND, point: *Point) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) u32;
extern "user32" fn GetWindowRect(window: HWND, rect: *Rect) callconv(.winapi) BOOL;
extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;
extern "user32" fn SendMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

const Press = struct {
    tick_ms: u64,
    screen_point: Point,
    window_rect: Rect,
};

const DoubleClickLimits = struct {
    time_ms: u64,
    width: i32,
    height: i32,
};

pub const State = struct {
    root: HWND = null,
    first_press: ?Press = null,
};

pub fn captureStartupWindow(
    state: *State,
    binding: startup_window.Binding,
) !void {
    state.root = binding.root orelse return error.WindowUnavailable;
}

pub fn requirePlatform(_: native_sdk.platform.PlatformServices) !void {}

pub fn bindRoot(state: *State) !void {
    _ = state.root orelse return error.WindowUnavailable;
}

pub fn handlePointerDown(
    state: *State,
    _: native_sdk.platform.PlatformServices,
    _: native_sdk.platform.WindowId,
    _: f64,
    _: f64,
) !types.PointerOutcome {
    const root = state.root orelse return error.WindowUnavailable;
    if (IsWindow(root) == 0) {
        resetPointerSequence(state);
        return error.WindowUnavailable;
    }

    const press = authorizePress(root) orelse {
        resetPointerSequence(state);
        return .ignored;
    };
    if (state.first_press) |first| {
        if (isDoubleClick(first, press, systemDoubleClickLimits())) {
            resetPointerSequence(state);
            return .toggle_maximize;
        }
    }

    state.first_press = press;
    _ = ReleaseCapture();
    if (PostMessageW(
        root,
        wm_nclbuttondown,
        htcaption,
        packScreenPoint(press.screen_point),
    ) == 0) {
        resetPointerSequence(state);
        return error.SystemWebViewDragStartFailed;
    }
    return .drag_started;
}

pub fn resetPointerSequence(state: *State) void {
    state.first_press = null;
}

pub fn deinit(state: *State) void {
    state.* = .{};
}

fn authorizePress(root: HWND) ?Press {
    const primary_button = if (GetSystemMetrics(sm_swapbutton) != 0)
        vk_rbutton
    else
        vk_lbutton;
    if ((@as(u16, @bitCast(GetAsyncKeyState(primary_button))) & 0x8000) == 0)
        return null;

    var screen_point: Point = undefined;
    if (GetCursorPos(&screen_point) == 0) return null;
    const pointer_window = WindowFromPoint(screen_point) orelse return null;
    if (GetAncestor(pointer_window, ga_root) != root) return null;
    if (SendMessageW(root, wm_nchittest, 0, packScreenPoint(screen_point)) != htclient)
        return null;

    var client_point = screen_point;
    if (ScreenToClient(root, &client_point) == 0) return null;
    const dpi = @max(GetDpiForWindow(root), 96);
    const scale = @as(f64, @floatFromInt(dpi)) / 96.0;
    if (!types.pointInTopBand(
        @as(f64, @floatFromInt(client_point.x)) / scale,
        @as(f64, @floatFromInt(client_point.y)) / scale,
        chrome_top_override.?,
    )) return null;

    var window_rect: Rect = undefined;
    if (GetWindowRect(root, &window_rect) == 0) return null;
    return .{
        .tick_ms = GetTickCount64(),
        .screen_point = screen_point,
        .window_rect = window_rect,
    };
}

fn systemDoubleClickLimits() DoubleClickLimits {
    return .{
        .time_ms = GetDoubleClickTime(),
        .width = @max(GetSystemMetrics(sm_cxdoubleclk), 1),
        .height = @max(GetSystemMetrics(sm_cydoubleclk), 1),
    };
}

fn isDoubleClick(first: Press, second: Press, limits: DoubleClickLimits) bool {
    if (second.tick_ms < first.tick_ms or
        second.tick_ms - first.tick_ms > limits.time_ms or
        !equalRect(first.window_rect, second.window_rect)) return false;
    const dx = @abs(@as(i64, second.screen_point.x) - first.screen_point.x);
    const dy = @abs(@as(i64, second.screen_point.y) - first.screen_point.y);
    return dx * 2 <= @as(i64, limits.width) and
        dy * 2 <= @as(i64, limits.height);
}

fn equalRect(left: Rect, right: Rect) bool {
    return left.left == right.left and left.top == right.top and
        left.right == right.right and left.bottom == right.bottom;
}

fn packScreenPoint(point: Point) LPARAM {
    const x: u16 = @bitCast(@as(i16, @truncate(point.x)));
    const y: u16 = @bitCast(@as(i16, @truncate(point.y)));
    return @bitCast(@as(usize, x) | (@as(usize, y) << 16));
}

/// Fixed-region experiment, deliberately separate from the production State.
/// No first-press cache: the experiment succeeds only if Windows supplies the
/// correct NC double-click after handing the first press to the root move loop.
pub const InputPrototype = struct {
    const Self = @This();
    const Proc = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize;
    const SubclassProc = *const fn (HWND, UINT, WPARAM, LPARAM, usize, usize) callconv(.winapi) isize;
    const WindowClass = extern struct {
        size: UINT = @sizeOf(WindowClass),
        style: UINT = 0,
        proc: Proc = childProc,
        class_extra: i32 = 0,
        window_extra: i32 = 0,
        instance: HWND,
        icon: HWND = null,
        cursor: HWND = null,
        background: HWND = null,
        menu_name: ?[*:0]const u16 = null,
        class_name: [*:0]const u16 = class_name,
        small_icon: HWND = null,
    };
    const CreateStruct = extern struct {
        params: *Self,
        instance: HWND,
        menu: HWND,
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
    extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, HWND, HWND, HWND, ?*anyopaque) callconv(.winapi) HWND;
    extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
    extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize;
    extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
    extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
    extern "user32" fn GetWindowThreadProcessId(HWND, ?*u32) callconv(.winapi) u32;
    extern "user32" fn GetClientRect(HWND, *Rect) callconv(.winapi) BOOL;
    extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
    extern "user32" fn IsWindowEnabled(HWND) callconv(.winapi) BOOL;
    extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
    extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
    extern "user32" fn GetCapture() callconv(.winapi) HWND;
    extern "user32" fn GetWindow(HWND, UINT) callconv(.winapi) HWND;
    extern "user32" fn SetWindowPos(HWND, HWND, i32, i32, i32, i32, UINT) callconv(.winapi) BOOL;
    extern "user32" fn SetWindowRgn(HWND, HWND, BOOL) callconv(.winapi) i32;
    extern "gdi32" fn CreateRectRgn(i32, i32, i32, i32) callconv(.winapi) HWND;
    extern "gdi32" fn DeleteObject(HWND) callconv(.winapi) BOOL;
    extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HWND;
    extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
    extern "comctl32" fn SetWindowSubclass(HWND, SubclassProc, usize, usize) callconv(.winapi) BOOL;
    extern "comctl32" fn RemoveWindowSubclass(HWND, SubclassProc, usize) callconv(.winapi) BOOL;
    extern "comctl32" fn DefSubclassProc(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize;

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MetaWorkFixedDragInputProbe");
    var registered_class: u16 = 0;
    var refresh_message: UINT = 0;
    root: HWND = null,
    child: HWND = null,
    thread_id: u32 = 0,
    subclass_installed: bool = false,
    stopping: bool = false,
    updating: bool = false,
    active: bool = false,
    refresh_pending: bool = false,
    data: ?*anyopaque = null,
    on_refresh: ?*const fn (*anyopaque) anyerror!void = null,
    on_toggle: ?*const fn (*anyopaque) anyerror!void = null,
    trace_count: usize = 0,

    pub fn attach(self: *Self, binding: startup_window.Binding, data: *anyopaque, on_refresh: *const fn (*anyopaque) anyerror!void, on_toggle: *const fn (*anyopaque) anyerror!void) !void {
        if (self.root != null or self.child != null) return error.DragInputAlreadyAttached;
        const root = binding.root orelse return error.WindowUnavailable;
        const thread_id = GetCurrentThreadId();
        if (IsWindow(root) == 0 or GetWindowThreadProcessId(root, null) != thread_id)
            return error.WindowIdentityMismatch;
        const instance = GetModuleHandleW(null) orelse return error.DragInputModuleUnavailable;
        if (registered_class == 0) {
            registered_class = RegisterClassExW(&.{ .instance = instance });
            if (registered_class == 0) return error.DragInputClassRegistrationFailed;
        }
        if (refresh_message == 0) {
            refresh_message = RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("MetaWork.FixedDragInputProbe.Refresh"));
            if (refresh_message == 0) return error.DragInputMessageRegistrationFailed;
        }
        self.* = .{ .root = root, .thread_id = thread_id, .data = data, .on_refresh = on_refresh, .on_toggle = on_toggle };
        errdefer self.deinit() catch |err| std.log.err("drag-probe rollback: {s}", .{@errorName(err)});
        if (SetWindowSubclass(root, parentProc, @intFromPtr(self), @intFromPtr(self)) == 0)
            return error.DragInputSubclassFailed;
        self.subclass_installed = true;
        try self.createChild();
        try self.queueRefresh();
        self.trace("attach", 0, 0);
    }

    fn createChild(self: *Self) !void {
        const root = self.root orelse return error.WindowUnavailable;
        const instance = GetModuleHandleW(null) orelse return error.DragInputModuleUnavailable;
        const child = CreateWindowExW(0x20, class_name, std.unicode.utf8ToUtf16LeStringLiteral(""), 0x4000_0000 | 0x0400_0000, 0, 0, 0, 0, root, null, instance, self) orelse return error.DragInputCreationFailed;
        // Creation delivers parent/child callbacks synchronously. Do not restore
        // a handle that WM_NCDESTROY has already cleared during reentry.
        if (self.root != root or self.child != child or IsWindow(child) == 0)
            return error.DragInputCreationFailed;
    }

    fn replaceInactiveInput(self: *Self) !void {
        if (self.stopping) return;
        if (self.updating) return error.DragInputActivationDuringUpdate;
        self.updating = true;
        defer self.updating = false;
        try self.withdraw();
        const old = self.child orelse return error.DragInputUnavailable;
        if (DestroyWindow(old) == 0) return error.DragInputDestroyFailed;
        try self.createChild();
        self.trace("activation-replacement", 0, 0);
        // Rebuild while inactive, not during the click that activates the root.
        // This is an experimental HWND-lifetime boundary, not a click cache.
    }

    /// Fixed HTML is part of this experiment, not a production DOM mirror.
    /// Application supplies the resize owner's live band and sibling anchor.
    pub fn syncFixed(self: *Self, resize_anchor: HWND, resize_width: i32, resize_height: i32) !void {
        if (self.stopping) return error.DragInputStopped;
        if (self.updating) return;
        self.updating = true;
        defer self.updating = false;
        const root = self.root orelse return error.WindowUnavailable;
        const child = self.child orelse return error.DragInputUnavailable;
        try self.withdraw();
        var client: Rect = undefined;
        if (GetClientRect(root, &client) == 0) return error.DragInputGeometryUnavailable;
        const dpi = GetDpiForWindow(root);
        if (dpi == 0 or resize_anchor == null or resize_width != client.right or resize_height < 0)
            return error.DragInputGeometryUnavailable;
        const area = fixedRect(client, dpi, resize_height);
        if (area.right <= area.left or area.bottom <= area.top or IsIconic(root) != 0 or IsWindowEnabled(root) == 0 or IsWindowVisible(root) == 0) return;
        const width = area.right - area.left;
        const height = area.bottom - area.top;
        try self.setShape(width, height);
        // The resize child is the insert-after anchor, never HWND_TOP.
        if (SetWindowPos(child, resize_anchor, area.left, area.top, width, height, 0x0010 | 0x0040) == 0)
            return error.DragInputPositionFailed;
        if (GetWindow(child, 3) != resize_anchor) return error.DragInputOrderMismatch;
        self.active = true;
        self.trace("active", 0, 0);
    }

    fn fixedRect(client: Rect, dpi: u32, resize_height: i32) Rect {
        const scale = @as(f64, @floatFromInt(dpi)) / 96.0;
        return .{
            .left = @min(client.right, @as(i32, @intFromFloat(200 * scale))),
            .right = @min(client.right, @as(i32, @intFromFloat(360 * scale))),
            .top = @min(client.bottom, resize_height),
            .bottom = @min(client.bottom, @as(i32, @intFromFloat(40 * scale))),
        };
    }

    fn setShape(self: *Self, width: i32, height: i32) !void {
        const region = CreateRectRgn(0, 0, width, height) orelse return error.DragInputRegionCreationFailed;
        if (SetWindowRgn(self.child, region, 1) == 0) {
            if (DeleteObject(region) == 0) std.log.err("drag-probe: failed to release rejected HRGN", .{});
            return error.DragInputRegionInstallFailed;
        }
        // Windows owns region after success, including the empty shape.
    }

    fn withdraw(self: *Self) !void {
        self.active = false;
        const child = self.child orelse return;
        try self.setShape(0, 0); // NULL would REMOVE the restriction, not clear it.
        if (SetWindowPos(child, null, 0, 0, 0, 0, 0x0010 | 0x0080 | 0x0001 | 0x0002 | 0x0004) == 0)
            return error.DragInputHideFailed;
    }

    pub fn deinit(self: *Self) !void {
        if (self.root == null and self.child == null) return;
        std.debug.assert(self.thread_id == GetCurrentThreadId());
        self.stopping = true;
        self.active = false;
        // On failure retain state/data: never claim a live HWND was removed.
        if (self.child) |child| {
            if (DestroyWindow(child) == 0) return error.DragInputDestroyFailed;
        }
        if (self.subclass_installed) {
            if (RemoveWindowSubclass(self.root, parentProc, @intFromPtr(self)) == 0)
                return error.DragInputUnsubclassFailed;
            self.subclass_installed = false;
        }
        self.trace("detached", 0, 0);
        self.* = .{};
    }

    fn fail(self: *Self, err: anyerror) void {
        std.log.err("drag-probe: {s}; destroying input resource", .{@errorName(err)});
        self.deinit() catch |cleanup_err| std.log.err("drag-probe CLEANUP FAILED: {s}", .{@errorName(cleanup_err)});
    }

    fn queueRefresh(self: *Self) !void {
        if (self.stopping or self.refresh_pending) return;
        if (PostMessageW(self.root, refresh_message, 0, 0) == 0) return error.DragInputRefreshPostFailed;
        self.refresh_pending = true;
    }

    fn refresh(self: *Self) void {
        if (self.stopping or self.child == null or self.updating) return;
        if (self.on_refresh) |callback| callback(self.data.?) catch |err| self.fail(err);
    }

    fn trace(self: *Self, label: []const u8, message: UINT, lparam: LPARAM) void {
        if (@import("builtin").is_test) return;
        if (self.trace_count >= 4096) {
            if (self.trace_count == 4096) {
                self.trace_count += 1;
                std.debug.print("DRAG_PROBE trace-overflow; subsequent absence is not evidence\n", .{});
            }
            return;
        }
        self.trace_count += 1;
        var rect: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const rect_ok = GetWindowRect(self.root, &rect) != 0;
        std.debug.print("DRAG_PROBE {s} tick={d} msg=0x{x} root=0x{x} child=0x{x} thread={d} capture=0x{x} xy=0x{x} rect_ok={} rect={d},{d},{d},{d} zoom={}\n", .{ label, GetTickCount64(), message, @intFromPtr(self.root), @intFromPtr(self.child), GetCurrentThreadId(), @intFromPtr(GetCapture()), @as(usize, @bitCast(lparam)), rect_ok, rect.left, rect.top, rect.right, rect.bottom, IsZoomed(self.root) != 0 });
    }

    fn parentProc(root: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM, id: usize, data: usize) callconv(.winapi) isize {
        const self: *Self = @ptrFromInt(data);
        if (message == 0x0082) { // WM_NCDESTROY.
            self.trace("root-destroy", message, lparam);
            _ = RemoveWindowSubclass(root, parentProc, id);
            self.subclass_installed = false;
            self.root = null;
            self.stopping = true;
            self.active = false;
            return DefSubclassProc(root, message, wparam, lparam);
        }
        if (message == refresh_message) {
            self.refresh_pending = false;
            self.refresh();
            return 0;
        }
        const deactivating = message == 0x0006 and (wparam & 0xffff) == 0;
        if (deactivating and !self.stopping)
            self.replaceInactiveInput() catch |err| self.fail(err);
        const geometry_change = switch (message) {
            0x0005, 0x000a, 0x0018, 0x007d, 0x02e0 => true,
            0x0210 => (wparam & 0xffff) == 1 and @as(usize, @bitCast(lparam)) != @intFromPtr(self.child),
            else => false,
        };
        if (geometry_change and !self.stopping and !self.updating) self.withdraw() catch |err| self.fail(err);
        switch (message) {
            0x0231, 0x0232, 0x0215, 0x0006 => self.trace("root-event", message, lparam), // move loop, capture, activation.
            else => {},
        }
        const result = DefSubclassProc(root, message, wparam, lparam);
        if (deactivating and !self.stopping) self.refresh();
        if (geometry_change and !self.stopping) {
            if (message == 0x0210) self.queueRefresh() catch |err| self.fail(err) else self.refresh();
        }
        // SHOWWINDOW can precede the root's WS_VISIBLE transition, including
        // when DefSubclassProc has returned. Retry the withdrawn input at the
        // completed native transition, not via a timer or another user press.
        if (message == 0x0047 and lparam != 0 and !self.stopping) { // WM_WINDOWPOSCHANGED.
            const WindowPos = extern struct { window: HWND, insert_after: HWND, x: i32, y: i32, width: i32, height: i32, flags: UINT };
            const position: *const WindowPos = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (position.flags & 0x00c0 != 0) self.refresh(); // SHOWWINDOW / HIDEWINDOW.
        }
        return result;
    }

    fn childProc(child: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize {
        if (message == 0x0081) { // WM_NCCREATE, userdata belongs only to our child.
            const create: *const CreateStruct = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = SetWindowLongPtrW(child, -21, @bitCast(@intFromPtr(create.params)));
            create.params.child = child;
        }
        const raw = GetWindowLongPtrW(child, -21);
        if (raw == 0) return DefWindowProcW(child, message, wparam, lparam);
        const self: *Self = @ptrFromInt(@as(usize, @bitCast(raw)));
        if (message == 0x0082) {
            self.trace("child-destroy", message, lparam);
            _ = SetWindowLongPtrW(child, -21, 0);
            self.child = null;
            self.active = false;
        }
        if (message == wm_nchittest) return if (self.active and !self.stopping) htcaption else -1;
        if (message == wm_nclbuttondown or message == 0x00a3 or message == 0x00a2)
            self.trace("child-input", message, lparam);
        if (!self.stopping and self.active and wparam == htcaption) {
            if (message == wm_nclbuttondown) {
                _ = ReleaseCapture();
                if (PostMessageW(self.root, wm_nclbuttondown, htcaption, lparam) == 0)
                    self.fail(error.DragInputMovePostFailed);
                return 0;
            }
            if (message == 0x00a3) { // The OS, not a local classifier, pairs presses.
                if (self.on_toggle) |toggle| toggle(self.data.?) catch |err| self.fail(err);
                return 0;
            }
        }
        return DefWindowProcW(child, message, wparam, lparam);
    }
};

test "window drag input fixed rectangle clips resize and client bounds" {
    const client = Rect{ .left = 0, .top = 0, .right = 1200, .bottom = 900 };
    try std.testing.expectEqualDeep(Rect{ .left = 300, .top = 12, .right = 540, .bottom = 60 }, InputPrototype.fixedRect(client, 144, 12));
    try std.testing.expectEqualDeep(Rect{ .left = 200, .top = 0, .right = 360, .bottom = 40 }, InputPrototype.fixedRect(client, 96, 0));
    const tiny = Rect{ .left = 0, .top = 0, .right = 150, .bottom = 6 };
    const area = InputPrototype.fixedRect(tiny, 96, 8);
    try std.testing.expect(area.left == area.right and area.top == area.bottom);
}

fn testInputCallback(_: *anyopaque) !void {}

var test_destroy_input_root = false;

fn testInputRootProc(root: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize {
    if (test_destroy_input_root and message == 0x0210 and (wparam & 0xffff) == 1) {
        test_destroy_input_root = false;
        _ = InputPrototype.DestroyWindow(root);
        return 0;
    }
    return InputPrototype.DefWindowProcW(root, message, wparam, lparam);
}

fn testInputRoot() !HWND {
    const Fixture = struct {
        var atom: u16 = 0;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("MetaWorkDragInputTestHost");
    };
    const instance = InputPrototype.GetModuleHandleW(null);
    if (Fixture.atom == 0) {
        Fixture.atom = InputPrototype.RegisterClassExW(&.{ .instance = instance, .proc = testInputRootProc, .class_name = Fixture.name });
        if (Fixture.atom == 0) return error.TestHostRegistrationFailed;
    }
    return InputPrototype.CreateWindowExW(0, Fixture.name, Fixture.name, 0x00cf_0000, -1200, -300, 900, 620, null, null, instance, null) orelse error.TestWindowCreationFailed;
}

test "window drag input rolls back a root destroyed during child creation" {
    const root = try testInputRoot();
    defer if (IsWindow(root) != 0) {
        _ = InputPrototype.DestroyWindow(root);
    };
    var input: InputPrototype = .{};
    defer input.deinit() catch {};
    var data: u8 = 0;
    test_destroy_input_root = true;
    defer test_destroy_input_root = false;
    if (input.attach(.{ .root = root }, &data, testInputCallback, testInputCallback)) |_| {
        return error.DestroyedRootWasAccepted;
    } else |err| {
        try std.testing.expect(err == error.DragInputCreationFailed or err == error.WindowUnavailable);
    }
    try std.testing.expect(IsWindow(root) == 0);
    try std.testing.expect(input.root == null and input.child == null and !input.subclass_installed);
}

test "window drag input rejects missing bindings without resources" {
    var input: InputPrototype = .{};
    var data: u8 = 0;
    try std.testing.expectError(error.WindowUnavailable, input.attach(.{ .root = null }, &data, testInputCallback, testInputCallback));
    try std.testing.expectError(error.WindowIdentityMismatch, input.attach(.{ .root = @ptrFromInt(1) }, &data, testInputCallback, testInputCallback));
    try std.testing.expect(input.child == null and input.root == null and !input.subclass_installed);
    try input.deinit();
}

test "window drag input activation boundary replaces only its own child" {
    const root = try testInputRoot();
    defer if (IsWindow(root) != 0) {
        _ = InputPrototype.DestroyWindow(root);
    };
    var input: InputPrototype = .{};
    defer input.deinit() catch {};
    var data: u8 = 0;
    try input.attach(.{ .root = root }, &data, testInputCallback, testInputCallback);
    for (0..20) |_| {
        const old = input.child;
        // Lifecycle unit test only; real mouse/activation pairing is a probe.
        _ = InputPrototype.parentProc(root, 0x0006, 0, 0, @intFromPtr(&input), @intFromPtr(&input));
        try std.testing.expect(input.root == root and input.subclass_installed);
        try std.testing.expect(input.child != null and input.child != old);
        try std.testing.expect(IsWindow(old) == 0 and IsWindow(input.child) != 0);
        try std.testing.expect(!input.active and !input.updating);
        const current = input.child;
        _ = InputPrototype.parentProc(root, 0x0006, 2, 0, @intFromPtr(&input), @intFromPtr(&input));
        try std.testing.expect(input.child == current);
    }
}

test "window drag input replacement rolls back if root is destroyed" {
    const root = try testInputRoot();
    defer if (IsWindow(root) != 0) {
        _ = InputPrototype.DestroyWindow(root);
    };
    var input: InputPrototype = .{};
    defer input.deinit() catch {};
    var data: u8 = 0;
    try input.attach(.{ .root = root }, &data, testInputCallback, testInputCallback);
    test_destroy_input_root = true;
    defer test_destroy_input_root = false;
    try std.testing.expectError(error.DragInputCreationFailed, input.replaceInactiveInput());
    try input.deinit();
    try std.testing.expect(IsWindow(root) == 0);
    try std.testing.expect(input.root == null and input.child == null and !input.subclass_installed);
}

test "window drag input repeated attach detach and both destruction orders" {
    const root = try testInputRoot();
    defer if (IsWindow(root) != 0) {
        _ = InputPrototype.DestroyWindow(root);
    };
    var input: InputPrototype = .{};
    defer input.deinit() catch {};
    var data: u8 = 0;
    for (0..20) |_| {
        try input.attach(.{ .root = root }, &data, testInputCallback, testInputCallback);
        input.trace_count = 4096;
        const child = input.child;
        try std.testing.expect(IsWindow(child) != 0 and InputPrototype.IsWindowVisible(child) == 0);
        try std.testing.expectError(error.DragInputAlreadyAttached, input.attach(.{ .root = root }, &data, testInputCallback, testInputCallback));
        try input.setShape(20, 10);
        try input.withdraw();
        try std.testing.expect(!input.active);
        try input.deinit();
        try std.testing.expect(IsWindow(child) == 0 and input.root == null and !input.subclass_installed);
        try input.deinit();
    }
    try input.attach(.{ .root = root }, &data, testInputCallback, testInputCallback);
    input.trace_count = 4096;
    try std.testing.expect(InputPrototype.DestroyWindow(input.child) != 0);
    try std.testing.expect(input.child == null and !input.active);
    try input.deinit();
    try input.attach(.{ .root = root }, &data, testInputCallback, testInputCallback);
    input.trace_count = 4096;
    const child = input.child;
    try std.testing.expect(InputPrototype.DestroyWindow(root) != 0);
    try std.testing.expect(IsWindow(child) == 0 and input.child == null and input.root == null and !input.subclass_installed);
    try input.deinit();
}

test "window drag input restores after native visibility change without resize" {
    const Fixture = struct {
        input: InputPrototype = .{},
        anchor: HWND,

        fn refresh(data: *anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(data));
            var client: Rect = undefined;
            if (InputPrototype.GetClientRect(self.input.root, &client) == 0) return error.TestGeometryUnavailable;
            try self.input.syncFixed(self.anchor, client.right, 8);
        }
    };
    const root = try testInputRoot();
    defer _ = InputPrototype.DestroyWindow(root);
    const anchor = InputPrototype.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("MetaWorkDragInputTestHost"), std.unicode.utf8ToUtf16LeStringLiteral(""), 0x4000_0000, 0, 0, 900, 8, root, null, InputPrototype.GetModuleHandleW(null), null) orelse return error.TestWindowCreationFailed;
    var fixture = Fixture{ .anchor = anchor };
    defer fixture.input.deinit() catch {};
    try fixture.input.attach(.{ .root = root }, &fixture, Fixture.refresh, testInputCallback);
    for (0..3) |_| {
        // Actual native visibility transitions on an offscreen, nonactivated
        // owned root; no fabricated lifecycle messages or manual refresh.
        try std.testing.expect(InputPrototype.SetWindowPos(root, null, 0, 0, 0, 0, 0x0057) != 0);
        try std.testing.expect(InputPrototype.IsWindowVisible(root) != 0);
        try std.testing.expect(fixture.input.active and InputPrototype.IsWindowVisible(fixture.input.child) != 0);
        try std.testing.expect(InputPrototype.SetWindowPos(root, null, 0, 0, 0, 0, 0x0097) != 0);
        try std.testing.expect(InputPrototype.IsWindowVisible(root) == 0);
        try std.testing.expect(!fixture.input.active and InputPrototype.IsWindowVisible(fixture.input.child) == 0);
    }
}

test "double-click classification uses OS time distance and stable window rect" {
    const first = Press{
        .tick_ms = 100,
        .screen_point = .{ .x = 400, .y = 20 },
        .window_rect = .{ .left = 100, .top = 100, .right = 900, .bottom = 700 },
    };
    const limits = DoubleClickLimits{ .time_ms = 500, .width = 4, .height = 4 };
    try std.testing.expect(isDoubleClick(first, .{
        .tick_ms = 600,
        .screen_point = .{ .x = 402, .y = 18 },
        .window_rect = first.window_rect,
    }, limits));
    try std.testing.expect(!isDoubleClick(first, .{
        .tick_ms = 601,
        .screen_point = first.screen_point,
        .window_rect = first.window_rect,
    }, limits));
    try std.testing.expect(!isDoubleClick(first, .{
        .tick_ms = 200,
        .screen_point = .{ .x = 403, .y = 20 },
        .window_rect = first.window_rect,
    }, limits));
    try std.testing.expect(!isDoubleClick(first, .{
        .tick_ms = 200,
        .screen_point = first.screen_point,
        .window_rect = .{ .left = 101, .top = 100, .right = 901, .bottom = 700 },
    }, limits));
}
