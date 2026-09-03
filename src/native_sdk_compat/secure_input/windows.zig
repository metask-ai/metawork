//! Native SDK 0.9.2 secure-input compatibility for Windows.

const std = @import("std");
const secure_input = @import("../secure_input.zig");
const startup_window = @import("../system_webview_startup_window.zig");
const windows_uia = @import("windows_uia.zig");

pub const Result = union(enum) { submitted: usize, cancelled };

const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HMENU = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;
const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const ATOM = u16;

const WndProc = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WndClassExW = extern struct {
    size: UINT,
    style: UINT,
    window_proc: WndProc,
    class_extra: i32,
    window_extra: i32,
    instance: HINSTANCE,
    icon: HICON,
    cursor: HCURSOR,
    background: HBRUSH,
    menu_name: ?[*:0]const u16,
    class_name: [*:0]const u16,
    icon_small: HICON,
};

const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const Point = extern struct { x: i32, y: i32 };
const Msg = extern struct {
    window: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
    time: DWORD,
    point: Point,
    private: DWORD,
};

const ws_popup: DWORD = 0x8000_0000;
const ws_child: DWORD = 0x4000_0000;
const ws_visible: DWORD = 0x1000_0000;
const ws_caption: DWORD = 0x00c0_0000;
const ws_sysmenu: DWORD = 0x0008_0000;
const ws_border: DWORD = 0x0080_0000;
const ws_tabstop: DWORD = 0x0001_0000;
const ws_ex_dlgmodalframe: DWORD = 0x0000_0001;
const ws_ex_controlparent: DWORD = 0x0001_0000;
const es_password: DWORD = 0x0020;
const es_autohscroll: DWORD = 0x0080;
const bs_defpushbutton: DWORD = 0x0001;
const wm_command: UINT = 0x0111;
const wm_close: UINT = 0x0010;
const wm_ncdestroy: UINT = 0x0082;
const wm_setfont: UINT = 0x0030;
const em_setlimittext: UINT = 0x00c5;
const id_ok: u16 = 1;
const id_cancel: u16 = 2;
const sw_show: i32 = 5;
const default_gui_font: i32 = 17;
const color_window: usize = 5;
const cp_utf8: UINT = 65001;
const wc_err_invalid_chars: DWORD = 0x0080;
const error_class_already_exists: DWORD = 1410;
const max_secret_utf16_units: usize = 16 * 1024;
const option_storage_units: usize = secure_input.max_message_bytes + 1;

extern "user32" fn RegisterClassExW(class: *const WndClassExW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(ex_style: DWORD, class_name: [*:0]const u16, title: [*:0]const u16, style: DWORD, x: i32, y: i32, width: i32, height: i32, parent: HWND, menu: HMENU, instance: HINSTANCE, param: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DefWindowProcW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn IsWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn IsWindowEnabled(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn EnableWindow(window: HWND, enabled: BOOL) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(window: HWND, command: i32) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn SetActiveWindow(window: HWND) callconv(.winapi) HWND;
extern "user32" fn SetFocus(window: HWND) callconv(.winapi) HWND;
extern "user32" fn SetWindowTextW(window: HWND, text: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextLengthW(window: HWND) callconv(.winapi) i32;
extern "user32" fn GetWindowTextW(window: HWND, text: [*]u16, max_count: i32) callconv(.winapi) i32;
extern "user32" fn GetWindowRect(window: HWND, rect: *Rect) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(window: HWND) callconv(.winapi) UINT;
extern "user32" fn AdjustWindowRectEx(rect: *Rect, style: DWORD, has_menu: BOOL, ex_style: DWORD) callconv(.winapi) BOOL;
extern "user32" fn SendMessageW(window: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(message: *Msg, window: HWND, min: UINT, max: UINT) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(message: *const Msg) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(message: *const Msg) callconv(.winapi) LRESULT;
extern "user32" fn IsDialogMessageW(dialog: HWND, message: *Msg) callconv(.winapi) BOOL;
extern "user32" fn PostQuitMessage(exit_code: i32) callconv(.winapi) void;
extern "user32" fn LoadCursorW(instance: HINSTANCE, name: [*:0]const u16) callconv(.winapi) HCURSOR;
extern "gdi32" fn GetStockObject(index: i32) callconv(.winapi) HGDIOBJ;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) HINSTANCE;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn SetLastError(code: DWORD) callconv(.winapi) void;
extern "kernel32" fn WideCharToMultiByte(code_page: UINT, flags: DWORD, wide: [*]const u16, wide_len: i32, utf8: [*]u8, utf8_len: i32, default_char: ?[*]const u8, used_default: ?*BOOL) callconv(.winapi) i32;

pub const State = struct { root: HWND = null };

const Dialog = struct {
    window: HWND = null,
    edit: HWND = null,
    error_label: HWND = null,
    output: []u8,
    done: bool = false,
    result: Result = .cancelled,
};

const WideText = struct {
    buffer: [option_storage_units]u16 = undefined,
    len: usize = 0,

    fn ptr(self: *const WideText) [*:0]const u16 {
        return self.buffer[0..self.len :0].ptr;
    }
};

threadlocal var active_dialog: ?*Dialog = null;
var class_registered = false;

pub fn bind(state: *State, binding: startup_window.Binding) !void {
    state.root = binding.root orelse return error.WindowUnavailable;
}

pub fn capture(state: *State, options: secure_input.Options, output: []u8) !Result {
    const root = state.root orelse return error.WindowUnavailable;
    if (IsWindow(root) == 0 or active_dialog != null)
        return error.WindowUnavailable;
    try ensureClass();

    var title = try wideText(options.title);
    var message = try wideText(options.message);
    var accept_label = try wideText(options.accept_label);
    var cancel_label = try wideText(options.cancel_label);
    defer {
        std.crypto.secureZero(u16, &title.buffer);
        std.crypto.secureZero(u16, &message.buffer);
        std.crypto.secureZero(u16, &accept_label.buffer);
        std.crypto.secureZero(u16, &cancel_label.buffer);
    }

    var dialog: Dialog = .{ .output = output };
    active_dialog = &dialog;
    defer active_dialog = null;

    const owner_was_enabled = IsWindowEnabled(root) != 0;
    if (owner_was_enabled) _ = EnableWindow(root, 0);
    defer cleanupModal(root, owner_was_enabled, &dialog);

    try createDialog(
        &dialog,
        root,
        title.ptr(),
        message.ptr(),
        accept_label.ptr(),
        cancel_label.ptr(),
    );
    _ = ShowWindow(dialog.window, sw_show);
    _ = UpdateWindow(dialog.window);
    _ = SetFocus(dialog.edit);

    while (!dialog.done) {
        var msg: Msg = undefined;
        const status = GetMessageW(&msg, null, 0, 0);
        if (status == -1) return error.PlatformFailure;
        if (status == 0) {
            PostQuitMessage(@intCast(msg.wparam));
            return error.PlatformFailure;
        }
        if (IsDialogMessageW(dialog.window, &msg) == 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
    }
    return dialog.result;
}

pub fn deinit(state: *State) void {
    state.root = null;
}

fn ensureClass() !void {
    if (class_registered) return;
    const instance = GetModuleHandleW(null) orelse return error.PlatformFailure;
    const class: WndClassExW = .{
        .size = @sizeOf(WndClassExW),
        .style = 0,
        .window_proc = windowProc,
        .class_extra = 0,
        .window_extra = 0,
        .instance = instance,
        .icon = null,
        .cursor = LoadCursorW(null, @ptrFromInt(32512)),
        .background = @ptrFromInt(color_window + 1),
        .menu_name = null,
        .class_name = className(),
        .icon_small = null,
    };
    if (RegisterClassExW(&class) == 0 and
        GetLastError() != error_class_already_exists)
        return error.PlatformFailure;
    class_registered = true;
}

fn createDialog(
    dialog: *Dialog,
    root: HWND,
    title: [*:0]const u16,
    message: [*:0]const u16,
    accept_label: [*:0]const u16,
    cancel_label: [*:0]const u16,
) !void {
    const dpi = @max(GetDpiForWindow(root), 96);
    const window_style = ws_popup | ws_caption | ws_sysmenu;
    const window_ex_style = ws_ex_dlgmodalframe | ws_ex_controlparent;
    var window_rect: Rect = .{
        .left = 0,
        .top = 0,
        .right = scale(480, dpi),
        .bottom = scale(220, dpi),
    };
    if (AdjustWindowRectEx(&window_rect, window_style, 0, window_ex_style) == 0)
        return error.PlatformFailure;
    var owner_rect: Rect = undefined;
    if (GetWindowRect(root, &owner_rect) == 0) return error.PlatformFailure;
    const width = window_rect.right - window_rect.left;
    const height = window_rect.bottom - window_rect.top;
    const x = owner_rect.left + @divTrunc(owner_rect.right - owner_rect.left - width, 2);
    const y = owner_rect.top + @divTrunc(owner_rect.bottom - owner_rect.top - height, 2);
    const instance = GetModuleHandleW(null) orelse return error.PlatformFailure;

    dialog.window = CreateWindowExW(
        window_ex_style,
        className(),
        title,
        window_style,
        x,
        y,
        width,
        height,
        root,
        null,
        instance,
        null,
    ) orelse return error.PlatformFailure;

    const font: WPARAM = @intFromPtr(GetStockObject(default_gui_font) orelse
        return error.PlatformFailure);
    const label = try child(
        dialog.window,
        staticClass(),
        message,
        ws_child | ws_visible,
        24,
        20,
        432,
        48,
        0,
        dpi,
        instance,
    );
    dialog.edit = try child(
        dialog.window,
        editClass(),
        emptyWide(),
        ws_child | ws_visible | ws_tabstop | ws_border | es_password | es_autohscroll,
        24,
        76,
        432,
        28,
        100,
        dpi,
        instance,
    );
    try windows_uia.install(dialog.edit);
    dialog.error_label = try child(
        dialog.window,
        staticClass(),
        emptyWide(),
        ws_child | ws_visible,
        24,
        110,
        432,
        36,
        101,
        dpi,
        instance,
    );
    const accept = try child(
        dialog.window,
        buttonClass(),
        accept_label,
        ws_child | ws_visible | ws_tabstop | bs_defpushbutton,
        264,
        158,
        92,
        30,
        id_ok,
        dpi,
        instance,
    );
    const cancel = try child(
        dialog.window,
        buttonClass(),
        cancel_label,
        ws_child | ws_visible | ws_tabstop,
        364,
        158,
        92,
        30,
        id_cancel,
        dpi,
        instance,
    );
    for ([_]HWND{ label, dialog.edit, dialog.error_label, accept, cancel }) |control|
        _ = SendMessageW(control, wm_setfont, font, 1);
    _ = SendMessageW(dialog.edit, em_setlimittext, max_secret_utf16_units, 0);
}

fn child(
    parent: HWND,
    class_name: [*:0]const u16,
    text: [*:0]const u16,
    style: DWORD,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    id: u16,
    dpi: UINT,
    instance: HINSTANCE,
) !HWND {
    return CreateWindowExW(
        0,
        class_name,
        text,
        style,
        scale(x, dpi),
        scale(y, dpi),
        scale(width, dpi),
        scale(height, dpi),
        parent,
        if (id == 0) null else @ptrFromInt(id),
        instance,
        null,
    ) orelse error.PlatformFailure;
}

fn windowProc(
    window: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT {
    if (active_dialog) |dialog| switch (message) {
        wm_command => switch (@as(u16, @truncate(wparam))) {
            id_ok => {
                submit(dialog);
                return 0;
            },
            id_cancel => {
                finishCancelled(dialog);
                return 0;
            },
            else => {},
        },
        wm_close => {
            finishCancelled(dialog);
            return 0;
        },
        wm_ncdestroy => {
            noteDestroyed(dialog);
        },
        else => {},
    };
    return DefWindowProcW(window, message, wparam, lparam);
}

fn submit(dialog: *Dialog) void {
    const edit = dialog.edit orelse return;
    SetLastError(0);
    const length = GetWindowTextLengthW(edit);
    if (length < 0 or (length == 0 and GetLastError() != 0) or
        @as(usize, @intCast(length)) > max_secret_utf16_units)
    {
        showError(dialog, invalidUnicodeMessage());
        return;
    }
    var scratch: [max_secret_utf16_units + 1]u16 = undefined;
    defer std.crypto.secureZero(u16, &scratch);
    const read = GetWindowTextW(edit, &scratch, @intCast(scratch.len));
    if (read != length) {
        showError(dialog, invalidUnicodeMessage());
        return;
    }
    std.crypto.secureZero(u8, dialog.output);
    if (read == 0) {
        finishSubmitted(dialog, 0);
        return;
    }
    const converted = WideCharToMultiByte(
        cp_utf8,
        wc_err_invalid_chars,
        &scratch,
        read,
        dialog.output.ptr,
        @intCast(@min(dialog.output.len, std.math.maxInt(i32))),
        null,
        null,
    );
    if (converted == 0) {
        std.crypto.secureZero(u8, dialog.output);
        showError(dialog, if (requiredUtf8Bytes(scratch[0..@intCast(read)])) |required|
            if (required > dialog.output.len) inputTooLargeMessage() else invalidUnicodeMessage()
        else
            invalidUnicodeMessage());
        return;
    }
    finishSubmitted(dialog, @intCast(converted));
}

fn requiredUtf8Bytes(wide: []const u16) ?usize {
    const required = WideCharToMultiByte(
        cp_utf8,
        wc_err_invalid_chars,
        wide.ptr,
        @intCast(wide.len),
        @constCast(emptyUtf8()),
        0,
        null,
        null,
    );
    return if (required > 0) @intCast(required) else null;
}

fn showError(dialog: *Dialog, message: [*:0]const u16) void {
    _ = SetWindowTextW(dialog.error_label, message);
    _ = SetFocus(dialog.edit);
}

fn finishSubmitted(dialog: *Dialog, length: usize) void {
    if (dialog.edit) |edit| _ = SetWindowTextW(edit, emptyWide());
    dialog.result = .{ .submitted = length };
    dialog.done = true;
}

fn finishCancelled(dialog: *Dialog) void {
    std.crypto.secureZero(u8, dialog.output);
    if (dialog.edit) |edit| _ = SetWindowTextW(edit, emptyWide());
    dialog.result = .cancelled;
    dialog.done = true;
}

fn cleanupModal(root: HWND, owner_was_enabled: bool, dialog: *Dialog) void {
    if (dialog.edit) |edit| _ = SetWindowTextW(edit, emptyWide());
    if (dialog.edit) |edit| windows_uia.uninstall(edit);
    if (owner_was_enabled) _ = EnableWindow(root, 1);
    if (dialog.window) |window| {
        if (IsWindow(window) != 0) _ = DestroyWindow(window);
    }
    dialog.window = null;
    dialog.edit = null;
    dialog.error_label = null;
    if (owner_was_enabled) _ = SetActiveWindow(root);
}

fn noteDestroyed(dialog: *Dialog) void {
    dialog.window = null;
    dialog.edit = null;
    dialog.error_label = null;
    if (!dialog.done) {
        std.crypto.secureZero(u8, dialog.output);
        dialog.result = .cancelled;
        dialog.done = true;
    }
}

fn wideText(value: []const u8) !WideText {
    var result: WideText = .{};
    result.len = std.unicode.utf8ToUtf16Le(&result.buffer, value) catch
        return error.PlatformFailure;
    if (result.len >= result.buffer.len) return error.PlatformFailure;
    result.buffer[result.len] = 0;
    return result;
}

fn scale(value: i32, dpi: UINT) i32 {
    return @intCast(@divTrunc(@as(i64, value) * dpi, 96));
}

fn className() [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral("MetaWorkSecureInput");
}

fn staticClass() [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
}

fn editClass() [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
}

fn buttonClass() [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
}

fn emptyWide() [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral("");
}

fn inputTooLargeMessage() [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral("The value is too long. Shorten it and try again.");
}

fn invalidUnicodeMessage() [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral("The value contains invalid text. Re-enter it and try again.");
}

fn emptyUtf8() [*]const u8 {
    return "".ptr;
}
