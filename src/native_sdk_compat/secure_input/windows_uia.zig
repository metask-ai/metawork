//! UI Automation password semantics for the Windows secure-input edit.
//!
//! The standard Win32 host provider supplies the ordinary Edit patterns. This
//! narrow server-side provider overrides only `IsPassword`, so assistive
//! technology cannot read the credential through ValuePattern.

const std = @import("std");

pub const Window = ?*anyopaque;

const UINT = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const HRESULT = i32;
const ULONG = u32;
const PROPERTYID = i32;
const PATTERNID = i32;

const WindowProc = *const fn (Window, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const Variant = extern struct {
    kind: u16,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    value: extern union {
        boolean: i16,
        storage: [16]u8,
    },
};

const RawElementProvider = extern struct {
    vtable: *const RawElementProviderVTable,
};

const RawElementProviderVTable = extern struct {
    query_interface: *const fn (*RawElementProvider, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT,
    add_ref: *const fn (*RawElementProvider) callconv(.winapi) ULONG,
    release: *const fn (*RawElementProvider) callconv(.winapi) ULONG,
    get_provider_options: *const fn (*RawElementProvider, *i32) callconv(.winapi) HRESULT,
    get_pattern_provider: *const fn (*RawElementProvider, PATTERNID, *?*anyopaque) callconv(.winapi) HRESULT,
    get_property_value: *const fn (*RawElementProvider, PROPERTYID, *Variant) callconv(.winapi) HRESULT,
    get_host_raw_element_provider: *const fn (*RawElementProvider, *?*RawElementProvider) callconv(.winapi) HRESULT,
};

const PasswordProvider = struct {
    interface: RawElementProvider = .{ .vtable = &password_provider_vtable },
    window: Window,
    references: i32 = 1,
};

const wm_getobject: UINT = 0x003d;
const wm_ncdestroy: UINT = 0x0082;
const gwlp_wndproc: i32 = -4;
const uia_root_object_id: LPARAM = -25;
const uia_is_password_property_id: PROPERTYID = 30019;
const provider_options_server_side: i32 = 1;
const variant_true: i16 = -1;
const variant_bool: u16 = 11;
const s_ok: HRESULT = 0;
const e_no_interface: HRESULT = @bitCast(@as(u32, 0x8000_4002));
const iid_iunknown: Guid = .{
    .data1 = 0x00000000,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
const iid_raw_element_provider_simple: Guid = .{
    .data1 = 0xd6dd68d1,
    .data2 = 0x86fd,
    .data3 = 0x4332,
    .data4 = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c },
};

extern "user32" fn SetWindowLongPtrW(window: Window, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn CallWindowProcW(previous: WindowProc, window: Window, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DefWindowProcW(window: Window, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn SetLastError(code: u32) callconv(.winapi) void;
extern "uiautomationcore" fn UiaHostProviderFromHwnd(window: Window, provider: *?*RawElementProvider) callconv(.winapi) HRESULT;
extern "uiautomationcore" fn UiaReturnRawElementProvider(window: Window, wparam: WPARAM, lparam: LPARAM, provider: *RawElementProvider) callconv(.winapi) LRESULT;

threadlocal var active_provider: ?*PasswordProvider = null;
threadlocal var original_window_proc: ?WindowProc = null;

const password_provider_vtable: RawElementProviderVTable = .{
    .query_interface = passwordProviderQueryInterface,
    .add_ref = passwordProviderAddRef,
    .release = passwordProviderRelease,
    .get_provider_options = passwordProviderOptions,
    .get_pattern_provider = passwordProviderPattern,
    .get_property_value = passwordProviderProperty,
    .get_host_raw_element_provider = passwordProviderHost,
};

pub fn install(edit: Window) !void {
    if (active_provider != null or original_window_proc != null)
        return error.PlatformFailure;
    const provider = std.heap.page_allocator.create(PasswordProvider) catch
        return error.PlatformFailure;
    provider.* = .{ .window = edit };
    SetLastError(0);
    const previous = SetWindowLongPtrW(
        edit,
        gwlp_wndproc,
        @bitCast(@intFromPtr(&passwordEditWindowProc)),
    );
    if (previous == 0 and GetLastError() != 0) {
        std.heap.page_allocator.destroy(provider);
        return error.PlatformFailure;
    }
    active_provider = provider;
    original_window_proc = @ptrFromInt(@as(usize, @bitCast(previous)));
}

pub fn uninstall(edit: Window) void {
    const provider = active_provider orelse return;
    const original = original_window_proc orelse return;
    if (provider.window != edit) return;
    _ = SetWindowLongPtrW(edit, gwlp_wndproc, @bitCast(@intFromPtr(original)));
    active_provider = null;
    original_window_proc = null;
    _ = passwordProviderRelease(&provider.interface);
}

fn passwordEditWindowProc(
    window: Window,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT {
    if (message == wm_getobject and lparam == uia_root_object_id) {
        if (active_provider) |provider|
            return UiaReturnRawElementProvider(window, wparam, lparam, &provider.interface);
    }
    const original = original_window_proc orelse
        return DefWindowProcW(window, message, wparam, lparam);
    const result = CallWindowProcW(original, window, message, wparam, lparam);
    if (message == wm_ncdestroy) {
        if (active_provider) |provider| {
            active_provider = null;
            original_window_proc = null;
            _ = passwordProviderRelease(&provider.interface);
        }
    }
    return result;
}

fn passwordProviderQueryInterface(
    interface: *RawElementProvider,
    interface_id: *const Guid,
    output: *?*anyopaque,
) callconv(.winapi) HRESULT {
    output.* = null;
    if (!guidEqual(interface_id, &iid_iunknown) and
        !guidEqual(interface_id, &iid_raw_element_provider_simple))
        return e_no_interface;
    output.* = interface;
    _ = passwordProviderAddRef(interface);
    return s_ok;
}

fn passwordProviderAddRef(interface: *RawElementProvider) callconv(.winapi) ULONG {
    const provider: *PasswordProvider = @fieldParentPtr("interface", interface);
    const previous = @atomicRmw(i32, &provider.references, .Add, 1, .seq_cst);
    return @intCast(previous + 1);
}

fn passwordProviderRelease(interface: *RawElementProvider) callconv(.winapi) ULONG {
    const provider: *PasswordProvider = @fieldParentPtr("interface", interface);
    const previous = @atomicRmw(i32, &provider.references, .Sub, 1, .seq_cst);
    if (previous == 1) {
        std.heap.page_allocator.destroy(provider);
        return 0;
    }
    return @intCast(previous - 1);
}

fn passwordProviderOptions(
    _: *RawElementProvider,
    options: *i32,
) callconv(.winapi) HRESULT {
    options.* = provider_options_server_side;
    return s_ok;
}

fn passwordProviderPattern(
    _: *RawElementProvider,
    _: PATTERNID,
    output: *?*anyopaque,
) callconv(.winapi) HRESULT {
    output.* = null;
    return s_ok;
}

fn passwordProviderProperty(
    _: *RawElementProvider,
    property_id: PROPERTYID,
    output: *Variant,
) callconv(.winapi) HRESULT {
    @memset(std.mem.asBytes(output), 0);
    if (property_id == uia_is_password_property_id) {
        output.kind = variant_bool;
        output.value.boolean = variant_true;
    }
    return s_ok;
}

fn passwordProviderHost(
    interface: *RawElementProvider,
    output: *?*RawElementProvider,
) callconv(.winapi) HRESULT {
    const provider: *PasswordProvider = @fieldParentPtr("interface", interface);
    return UiaHostProviderFromHwnd(provider.window, output);
}

fn guidEqual(left: *const Guid, right: *const Guid) bool {
    return left.data1 == right.data1 and
        left.data2 == right.data2 and
        left.data3 == right.data3 and
        std.mem.eql(u8, &left.data4, &right.data4);
}

test "password provider has the exact UI Automation ABI and property" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Guid));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Variant, "value"));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Variant));
    try std.testing.expectEqual(
        @as(usize, 7 * @sizeOf(usize)),
        @sizeOf(RawElementProviderVTable),
    );

    var provider: PasswordProvider = .{ .window = null };
    var value: Variant = undefined;
    try std.testing.expectEqual(
        s_ok,
        passwordProviderProperty(
            &provider.interface,
            uia_is_password_property_id,
            &value,
        ),
    );
    try std.testing.expectEqual(variant_bool, value.kind);
    try std.testing.expectEqual(variant_true, value.value.boolean);

    try std.testing.expectEqual(
        s_ok,
        passwordProviderProperty(&provider.interface, 30005, &value),
    );
    try std.testing.expectEqual(@as(u16, 0), value.kind);

    var queried: ?*anyopaque = null;
    try std.testing.expectEqual(
        s_ok,
        passwordProviderQueryInterface(
            &provider.interface,
            &iid_raw_element_provider_simple,
            &queried,
        ),
    );
    try std.testing.expectEqual(@as(?*anyopaque, &provider.interface), queried);
    try std.testing.expectEqual(@as(ULONG, 1), passwordProviderRelease(&provider.interface));

    const unknown: Guid = .{
        .data1 = 1,
        .data2 = 2,
        .data3 = 3,
        .data4 = @splat(4),
    };
    queried = @ptrFromInt(1);
    try std.testing.expectEqual(
        e_no_interface,
        passwordProviderQueryInterface(&provider.interface, &unknown, &queried),
    );
    try std.testing.expectEqual(@as(?*anyopaque, null), queried);
}
