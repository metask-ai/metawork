//! Desktop Host compatibility seam for System WebView window chrome.
//!
//! Native SDK 0.8.0 owns the real window, chrome geometry, native controls,
//! close policy, and the platform drag loop. Its drag-region mirror is wired
//! to Canvas views but not to the startup System WebView, so MetaWork keeps a
//! deliberately narrow single-window seam here. Bridge ingress may describe
//! one top-band drag candidate plus bounded exclusions; it may not request a
//! window action or provide a native window identity.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const windows_host = @import("windows_host.zig");

pub const max_regions: usize = 33;
const max_coordinate: f64 = 65_536;
const geometry_epsilon: f64 = 0.5;

pub const Region = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    exclusion: bool,
};

pub const Environment = struct {
    generation: u64,
    top: f64,
    left: f64,
    bottom: f64,
    right: f64,
    buttons_x: f64,
    buttons_y: f64,
    buttons_width: f64,
    buttons_height: f64,
    live_pointer_drag: bool,
};

pub const Capability = struct {
    window_id: native_sdk.platform.WindowId,
    generation: u64 = 0,
    connected: bool = false,
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,
    windows: Windows.State = .{},

    pub fn init(window_id: native_sdk.platform.WindowId) Capability {
        std.debug.assert(window_id != 0);
        return .{ .window_id = window_id };
    }

    pub fn requirePlatform(self: *Capability, services: native_sdk.platform.PlatformServices) !void {
        if (services.window_chrome_fn == null) return error.SystemWebViewChromeUnavailable;
        switch (builtin.os.tag) {
            .windows => try Windows.requirePlatform(self, services),
            .macos => if (services.start_window_drag_fn == null)
                return error.SystemWebViewChromeUnavailable,
            else => return error.SystemWebViewChromeUnavailable,
        }
    }

    pub fn connect(self: *Capability, services: native_sdk.platform.PlatformServices) !Environment {
        try self.requirePlatform(services);
        try self.installPlatformOrDisconnect(services);
        self.clearRegions();
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.connected = true;
        return self.environment(services);
    }

    pub fn sync(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
        generation: u64,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const Region,
    ) !Environment {
        try self.requireCurrent(generation);
        if (!validExtent(viewport_width) or !validExtent(viewport_height))
            return error.InvalidWindowChromeGeometry;
        const chrome = services.windowChrome(self.window_id);
        if (regions.len == 0) {
            self.clearRegions();
            try self.installPlatformOrDisconnect(services);
            return environmentFromChrome(self.generation, chrome);
        }
        try self.replaceRegions(chrome.insets.top, viewport_width, viewport_height, regions);
        try self.installPlatformOrDisconnect(services);
        return environmentFromChrome(self.generation, chrome);
    }

    pub fn beginLivePointerDrag(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
        generation: u64,
        x: f64,
        y: f64,
    ) !Environment {
        try self.requireCurrent(generation);
        if (builtin.os.tag != .macos) return error.UnsupportedWindowChromeGesture;
        if (!validCoordinate(x) or !validCoordinate(y) or !self.pointIsDraggable(x, y))
            return error.InvalidWindowChromeGesture;
        try services.startWindowDrag(self.window_id);
        return self.environment(services);
    }

    pub fn disconnect(self: *Capability, generation: u64) !void {
        try self.requireCurrent(generation);
        self.connected = false;
        self.clearRegions();
    }

    pub fn deinit(self: *Capability) void {
        self.connected = false;
        self.clearRegions();
        if (builtin.os.tag == .windows) Windows.uninstall(self);
    }

    fn environment(self: *const Capability, services: native_sdk.platform.PlatformServices) Environment {
        return environmentFromChrome(self.generation, services.windowChrome(self.window_id));
    }

    fn requireCurrent(self: *const Capability, generation: u64) !void {
        if (!self.connected or generation == 0 or generation != self.generation)
            return error.StaleWindowChromeDocument;
    }

    fn clearRegions(self: *Capability) void {
        self.region_count = 0;
    }

    fn installPlatformOrDisconnect(
        self: *Capability,
        services: native_sdk.platform.PlatformServices,
    ) !void {
        if (builtin.os.tag != .windows) return;
        Windows.install(self, services) catch |err| {
            self.connected = false;
            self.clearRegions();
            Windows.uninstall(self);
            return err;
        };
    }

    fn replaceRegions(
        self: *Capability,
        chrome_top: f64,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const Region,
    ) !void {
        try self.validateRegions(chrome_top, viewport_width, viewport_height, regions);
        self.region_count = regions.len;
        @memcpy(self.regions[0..regions.len], regions);
    }

    fn validateRegions(
        self: *const Capability,
        chrome_top: f64,
        viewport_width: f64,
        viewport_height: f64,
        regions: []const Region,
    ) !void {
        _ = self;
        if (regions.len > max_regions)
            return error.InvalidWindowChromeRegions;
        const candidate = regions[0];
        if (candidate.exclusion or !validRegion(candidate, viewport_width, viewport_height))
            return error.InvalidWindowChromeRegions;
        if (!validExtent(chrome_top) or candidate.y + candidate.height > chrome_top + geometry_epsilon)
            return error.WindowChromeRegionOutsideNativeBand;
        for (regions[1..]) |region| {
            if (!region.exclusion or !validRegion(region, viewport_width, viewport_height) or
                !contains(candidate, region))
                return error.InvalidWindowChromeRegions;
        }
    }

    fn pointIsDraggable(self: *const Capability, x: f64, y: f64) bool {
        if (self.region_count == 0 or !containsPoint(self.regions[0], x, y)) return false;
        for (self.regions[1..self.region_count]) |region|
            if (containsPoint(region, x, y)) return false;
        return true;
    }
};

fn environmentFromChrome(generation: u64, chrome: native_sdk.platform.WindowChrome) Environment {
    return .{
        .generation = generation,
        .top = chrome.insets.top,
        .left = chrome.insets.left,
        .bottom = chrome.insets.bottom,
        .right = chrome.insets.right,
        .buttons_x = chrome.buttons.x,
        .buttons_y = chrome.buttons.y,
        .buttons_width = chrome.buttons.width,
        .buttons_height = chrome.buttons.height,
        .live_pointer_drag = builtin.os.tag == .macos,
    };
}

fn validCoordinate(value: f64) bool {
    return std.math.isFinite(value) and value >= 0 and value <= max_coordinate;
}

fn validExtent(value: f64) bool {
    return validCoordinate(value) and value > 0;
}

fn validRegion(region: Region, viewport_width: f64, viewport_height: f64) bool {
    return validCoordinate(region.x) and validCoordinate(region.y) and
        validExtent(region.width) and validExtent(region.height) and
        region.x + region.width <= viewport_width + geometry_epsilon and
        region.y + region.height <= viewport_height + geometry_epsilon;
}

fn contains(outer: Region, inner: Region) bool {
    return inner.x + geometry_epsilon >= outer.x and
        inner.y + geometry_epsilon >= outer.y and
        inner.x + inner.width <= outer.x + outer.width + geometry_epsilon and
        inner.y + inner.height <= outer.y + outer.height + geometry_epsilon;
}

fn containsPoint(region: Region, x: f64, y: f64) bool {
    return x >= region.x and y >= region.y and
        x < region.x + region.width and y < region.y + region.height;
}

const Windows = if (builtin.os.tag == .windows) struct {
    const HWND = ?*anyopaque;
    const HMENU = ?*anyopaque;
    const HINSTANCE = ?*anyopaque;
    const HICON = ?*anyopaque;
    const HCURSOR = ?*anyopaque;
    const HBRUSH = ?*anyopaque;
    const BOOL = i32;
    const UINT = u32;
    const WPARAM = usize;
    const LPARAM = isize;
    const LRESULT = isize;
    const DWORD_PTR = usize;
    const UINT_PTR = usize;
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

    const SubclassProc = *const fn (HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR) callconv(.winapi) LRESULT;
    const WndProc = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
    const EnumProc = *const fn (HWND, LPARAM) callconv(.winapi) BOOL;

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

    const overlay_class_name = std.unicode.utf8ToUtf16LeStringLiteral("MetaWorkSystemWebViewChrome");
    var overlay_class_registered = false;

    extern "user32" fn EnumChildWindows(parent: HWND, callback: EnumProc, data: LPARAM) callconv(.winapi) BOOL;
    extern "user32" fn RegisterClassExW(class: *const WndClassExW) callconv(.winapi) u16;
    extern "user32" fn DefWindowProcW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
    extern "user32" fn ScreenToClient(window: HWND, point: *Point) callconv(.winapi) BOOL;
    extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) u32;
    extern "user32" fn GetClientRect(window: HWND, rect: *Rect) callconv(.winapi) BOOL;
    extern "user32" fn GetCursorPos(point: *Point) callconv(.winapi) BOOL;
    extern "user32" fn GetSystemMenu(window: HWND, revert: BOOL) callconv(.winapi) HMENU;
    extern "user32" fn TrackPopupMenu(menu: HMENU, flags: UINT, x: i32, y: i32, reserved: i32, window: HWND, rect: ?*const Rect) callconv(.winapi) UINT;
    extern "user32" fn CreateWindowExW(ex_style: u32, class_name: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: ?*anyopaque) callconv(.winapi) HWND;
    extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
    extern "user32" fn SetWindowPos(window: HWND, insert_after: HWND, x: i32, y: i32, width: i32, height: i32, flags: u32) callconv(.winapi) BOOL;
    extern "user32" fn PostMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
    extern "user32" fn SendMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
    extern "user32" fn ValidateRect(window: HWND, rect: ?*const Rect) callconv(.winapi) BOOL;
    extern "kernel32" fn GetModuleHandleW(module_name: ?[*:0]const u16) callconv(.winapi) HINSTANCE;
    extern "comctl32" fn SetWindowSubclass(window: HWND, callback: SubclassProc, id: UINT_PTR, data: DWORD_PTR) callconv(.winapi) BOOL;
    extern "comctl32" fn RemoveWindowSubclass(window: HWND, callback: SubclassProc, id: UINT_PTR) callconv(.winapi) BOOL;
    extern "comctl32" fn DefSubclassProc(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;

    const Point = extern struct { x: i32, y: i32 };
    const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

    pub const State = struct {
        root: HWND = null,
        overlay: HWND = null,
        band_height: f64 = 1,
    };

    fn requirePlatform(capability: *Capability, services: native_sdk.platform.PlatformServices) !void {
        _ = try windows_host.exactStartupWindow(services, capability.window_id);
    }

    fn install(capability: *Capability, services: native_sdk.platform.PlatformServices) !void {
        const root = try windows_host.exactStartupWindow(services, capability.window_id);
        capability.windows.root = root;
        if (SetWindowSubclass(root, subclassProc, subclass_id, @intFromPtr(capability)) == 0)
            return error.SystemWebViewChromeInstallFailed;
        const overlay = capability.windows.overlay orelse create: {
            const instance = GetModuleHandleW(null) orelse return error.SystemWebViewChromeInstallFailed;
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
                if (RegisterClassExW(&class) == 0) return error.SystemWebViewChromeInstallFailed;
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
            capability.windows.overlay = created;
            if (SetWindowSubclass(created, subclassProc, subclass_id, @intFromPtr(capability)) == 0) {
                _ = DestroyWindow(created);
                capability.windows.overlay = null;
                return error.SystemWebViewChromeInstallFailed;
            }
            break :create created;
        };
        _ = overlay;
        const chrome = services.windowChrome(capability.window_id);
        capability.windows.band_height = @max(chrome.insets.top, 1);
        try layoutOverlay(capability);
        _ = EnumChildWindows(root, installChild, @intCast(@intFromPtr(capability)));
    }

    fn uninstall(capability: *Capability) void {
        const root = capability.windows.root orelse return;
        _ = EnumChildWindows(root, removeChild, 0);
        if (capability.windows.overlay) |overlay| {
            _ = RemoveWindowSubclass(overlay, subclassProc, subclass_id);
            _ = DestroyWindow(overlay);
            capability.windows.overlay = null;
        }
        _ = RemoveWindowSubclass(root, subclassProc, subclass_id);
        capability.windows.root = null;
    }

    fn installChild(window: HWND, data: LPARAM) callconv(.winapi) BOOL {
        const capability: *Capability = @ptrFromInt(@as(usize, @bitCast(data)));
        if (window != capability.windows.overlay)
            _ = SetWindowSubclass(window, subclassProc, subclass_id, @intFromPtr(capability));
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
        const capability: *Capability = @ptrFromInt(data);
        if (message == wm_ncdestroy) {
            _ = RemoveWindowSubclass(window, subclassProc, subclass_id);
            return DefSubclassProc(window, message, wparam, lparam);
        }
        if (window == capability.windows.overlay) {
            if (message == wm_paint) {
                _ = ValidateRect(window, null);
                return 0;
            }
            if (message == wm_nchittest) {
                if (!capability.connected or capability.region_count == 0) return httransparent;
                const root = capability.windows.root orelse return httransparent;
                const root_hit = SendMessageW(root, message, wparam, lparam);
                return if (root_hit == htclient) httransparent else root_hit;
            }
            if (message == wm_ncrbuttonup) {
                const root = capability.windows.root orelse return 0;
                showSystemMenu(root);
                return 0;
            }
            if (message == wm_nclbuttondown or message == wm_nclbuttondblclk or message == wm_ncrbuttondown) {
                const root = capability.windows.root orelse return 0;
                return SendMessageW(root, message, wparam, lparam);
            }
            return DefSubclassProc(window, message, wparam, lparam);
        }
        if (window != capability.windows.root and message == wm_windowposchanged) {
            const result = DefSubclassProc(window, message, wparam, lparam);
            layoutOverlay(capability) catch {};
            return result;
        }
        if (window != capability.windows.root) {
            if (message == wm_nchittest and capability.connected and capability.region_count != 0) {
                const root = capability.windows.root orelse
                    return DefSubclassProc(window, message, wparam, lparam);
                if (SendMessageW(root, message, wparam, lparam) != htclient) return httransparent;
            }
            return DefSubclassProc(window, message, wparam, lparam);
        }
        if (message == wm_size or message == wm_activate or message == wm_showwindow or message == wm_dpichanged) {
            const result = DefSubclassProc(window, message, wparam, lparam);
            layoutOverlay(capability) catch {};
            return result;
        }
        if (message != wm_nchittest or !capability.connected or capability.region_count == 0)
            return DefSubclassProc(window, message, wparam, lparam);

        const root = capability.windows.root orelse
            return DefSubclassProc(window, message, wparam, lparam);
        var point = screenPoint(lparam);
        if (ScreenToClient(root, &point) == 0)
            return DefSubclassProc(window, message, wparam, lparam);
        const dpi = @max(GetDpiForWindow(root), 96);
        const scale = @as(f64, @floatFromInt(dpi)) / 96.0;
        if (!capability.pointIsDraggable(
            @as(f64, @floatFromInt(point.x)) / scale,
            @as(f64, @floatFromInt(point.y)) / scale,
        )) return DefSubclassProc(window, message, wparam, lparam);

        const native_hit = DefSubclassProc(window, message, wparam, lparam);
        return if (native_hit == htclient) htcaption else native_hit;
    }

    fn overlayWindowProc(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
        return DefWindowProcW(window, message, wparam, lparam);
    }

    fn layoutOverlay(capability: *Capability) !void {
        const root = capability.windows.root orelse return error.SystemWebViewChromeInstallFailed;
        const overlay = capability.windows.overlay orelse return error.SystemWebViewChromeInstallFailed;
        var client: Rect = undefined;
        if (GetClientRect(root, &client) == 0) return error.SystemWebViewChromeInstallFailed;
        const scale = @as(f64, @floatFromInt(@max(GetDpiForWindow(root), 96))) / 96.0;
        const height = @max(
            @as(i32, 1),
            @as(i32, @intFromFloat(@ceil(capability.windows.band_height * scale))),
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
} else struct {
    pub const State = struct {};

    fn requirePlatform(_: *Capability, _: native_sdk.platform.PlatformServices) !void {
        return error.SystemWebViewChromeUnavailable;
    }

    fn install(_: *Capability, _: native_sdk.platform.PlatformServices) !void {}
    fn uninstall(_: *Capability) void {}
};

test "chrome regions stay inside one native top band" {
    var capability = Capability.init(1);
    const valid = [_]Region{
        .{ .x = 0, .y = 0, .width = 500, .height = 52, .exclusion = false },
        .{ .x = 12, .y = 8, .width = 40, .height = 36, .exclusion = true },
    };
    try capability.validateRegions(52, 800, 600, &valid);
    try std.testing.expect(capability.region_count == 0);

    var outside = valid;
    outside[0].height = 60;
    try std.testing.expectError(
        error.WindowChromeRegionOutsideNativeBand,
        capability.validateRegions(52, 800, 600, &outside),
    );
    var escaped = valid;
    escaped[1].x = 700;
    try std.testing.expectError(
        error.InvalidWindowChromeRegions,
        capability.validateRegions(52, 800, 600, &escaped),
    );
}

test "chrome hit testing only accepts candidate minus exclusions" {
    var capability = Capability.init(1);
    capability.connected = true;
    capability.region_count = 2;
    capability.regions[0] = .{ .x = 0, .y = 0, .width = 500, .height = 52, .exclusion = false };
    capability.regions[1] = .{ .x = 12, .y = 8, .width = 40, .height = 36, .exclusion = true };
    try std.testing.expect(capability.pointIsDraggable(200, 20));
    try std.testing.expect(!capability.pointIsDraggable(20, 20));
    try std.testing.expect(!capability.pointIsDraggable(700, 20));
}

test "invalid chrome geometry cannot partially replace live regions" {
    var capability = Capability.init(1);
    const valid = [_]Region{
        .{ .x = 0, .y = 0, .width = 500, .height = 52, .exclusion = false },
        .{ .x = 12, .y = 8, .width = 40, .height = 36, .exclusion = true },
    };
    try capability.replaceRegions(52, 800, 600, &valid);

    var invalid = valid;
    invalid[1].x = 700;
    try std.testing.expectError(
        error.InvalidWindowChromeRegions,
        capability.replaceRegions(52, 800, 600, &invalid),
    );
    try std.testing.expectEqual(@as(usize, valid.len), capability.region_count);
    try std.testing.expect(capability.pointIsDraggable(200, 20));
    try std.testing.expect(!capability.pointIsDraggable(20, 20));
}

test "chrome document generations fail closed" {
    var capability = Capability.init(1);
    capability.connected = true;
    capability.generation = 7;
    try capability.requireCurrent(7);
    try std.testing.expectError(error.StaleWindowChromeDocument, capability.requireCurrent(6));
    try capability.disconnect(7);
    try std.testing.expectError(error.StaleWindowChromeDocument, capability.requireCurrent(7));
}
