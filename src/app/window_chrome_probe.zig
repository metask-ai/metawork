//! Isolated A-stage startup System WebView, no product/Bridge/input listener.
const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const runner = @import("runner");
const identity = @import("metawork_product_identity");
const window = @import("window.zig");

// Callback storage must survive a failed native detach; never put it on a
// short-lived start/stop stack. Only this separate entry activates it.
var prototype: window.InputPrototype = .{};

pub fn run(init: std.process.Init) !void {
    if (builtin.os.tag != .windows) @compileError("window-chrome-probe is Windows only");
    try prototype.prepare();
    defer prototype.deinit() catch |err| std.log.err("drag-probe shutdown: {s}", .{@errorName(err)});
    try runner.runWithOptions(.{
        .context = &prototype,
        .name = "metawork-drag-probe",
        .source = native_sdk.WebViewSource.html(@embedFile("window_chrome_probe.html")),
        .start_fn = start,
        .event_fn = event,
        .stop_fn = stop,
    }, .{
        .app_name = "MetaWork Drag Probe",
        .window_title = "MetaWork Drag Probe - fixed native input",
        .bundle_id = identity.runnerBundleId(),
        .icon_path = "assets/icons/app-icon.png",
        .restore_state = false,
        .js_window_api = false,
        .commands = &.{},
        .menus = &.{},
        .shortcuts = &.{.{ .id = "probe.quit", .key = "q", .modifiers = .{ .control = true, .shift = true } }},
    }, init);
}

fn start(_: *anyopaque, runtime: *native_sdk.Runtime) !void {
    try prototype.start(runtime);
    try runtime.showWindow(window.main_window_id);
    // A bounded process watchdog, never used for gesture classification.
    try runtime.startTimer(1, 15 * 60 * std.time.ns_per_s, false);
    std.debug.print("DRAG_PROBE ready; Ctrl+Shift+Q exits\n", .{});
}

fn event(_: *anyopaque, runtime: *native_sdk.Runtime, value: native_sdk.Event) !void {
    switch (value) {
        .shortcut => |shortcut| if (std.mem.eql(u8, shortcut.id, "probe.quit")) {
            try prototype.deinit();
            try runtime.closeWindow(window.main_window_id);
        },
        .timer => {
            try prototype.deinit();
            try runtime.closeWindow(window.main_window_id);
        },
        else => {},
    }
}

fn stop(_: *anyopaque, _: *native_sdk.Runtime) !void {
    try prototype.deinit();
}
