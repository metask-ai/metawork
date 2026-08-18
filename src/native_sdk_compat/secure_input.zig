//! Application-owned compatibility seam for secure native text input.
//!
//! Native SDK 0.9.2 does not expose a Runtime API for collecting masked text.
//! This seam owns one bounded prompt, keeps plaintext out of Renderer transport,
//! and is deleted when an official Runtime capability passes platform validation.

const builtin = @import("builtin");
const std = @import("std");
const startup_window = @import("system_webview_startup_window.zig");

const Platform = switch (builtin.os.tag) {
    .windows => @import("secure_input/windows.zig"),
    .macos => @import("secure_input/macos.zig"),
    else => struct {
        pub const State = struct {};
        pub const Result = union(enum) { submitted: usize, cancelled };

        pub fn bind(_: *State, _: startup_window.Binding) !void {
            return error.Unavailable;
        }

        pub fn capture(_: *State, _: Options, _: []u8) !@This().Result {
            return error.Unavailable;
        }

        pub fn deinit(_: *State) void {}
    },
};

pub const max_title_bytes: usize = 512;
pub const max_message_bytes: usize = 4096;
pub const max_button_label_bytes: usize = 128;

pub const Options = struct {
    title: []const u8,
    message: []const u8,
    accept_label: []const u8,
    cancel_label: []const u8,
};

pub const Result = union(enum) {
    submitted: usize,
    cancelled,
};

pub const Error = error{
    Unavailable,
    Busy,
    WrongThread,
    InvalidOptions,
    WindowUnavailable,
    PlatformFailure,
};

pub const Capability = struct {
    owner_thread_id: ?std.Thread.Id = null,
    ready: bool = false,
    active: bool = false,
    platform: Platform.State = .{},

    pub fn captureStartupWindow(
        self: *Capability,
        binding: startup_window.Binding,
    ) Error!void {
        if (self.ready) return error.PlatformFailure;
        Platform.bind(&self.platform, binding) catch |err| return mapError(err);
        self.owner_thread_id = std.Thread.getCurrentId();
        self.ready = true;
    }

    pub fn available(self: *const Capability) bool {
        return self.ready;
    }

    pub fn capture(
        self: *Capability,
        options: Options,
        output: []u8,
    ) Error!Result {
        std.crypto.secureZero(u8, output);
        errdefer std.crypto.secureZero(u8, output);

        if (!self.ready) return error.Unavailable;
        if (self.owner_thread_id != std.Thread.getCurrentId())
            return error.WrongThread;
        if (self.active) return error.Busy;
        if (!validOptions(options) or output.len == 0)
            return error.InvalidOptions;

        self.active = true;
        defer self.active = false;
        const platform_result = Platform.capture(
            &self.platform,
            options,
            output,
        ) catch |err| return mapError(err);
        return switch (platform_result) {
            .submitted => |length| .{ .submitted = length },
            .cancelled => cancelled: {
                std.crypto.secureZero(u8, output);
                break :cancelled .cancelled;
            },
        };
    }

    pub fn deinit(self: *Capability) void {
        Platform.deinit(&self.platform);
        self.owner_thread_id = null;
        self.ready = false;
        self.active = false;
    }
};

fn mapError(err: anyerror) Error {
    return switch (err) {
        error.Unavailable => error.Unavailable,
        error.WindowUnavailable => error.WindowUnavailable,
        else => error.PlatformFailure,
    };
}

fn validOptions(options: Options) bool {
    return validRequiredText(options.title, max_title_bytes) and
        validOptionalText(options.message, max_message_bytes) and
        validRequiredText(options.accept_label, max_button_label_bytes) and
        validRequiredText(options.cancel_label, max_button_label_bytes);
}

fn validRequiredText(value: []const u8, max_bytes: usize) bool {
    return value.len > 0 and validOptionalText(value, max_bytes);
}

fn validOptionalText(value: []const u8, max_bytes: usize) bool {
    return value.len <= max_bytes and
        std.mem.indexOfScalar(u8, value, 0) == null and
        std.unicode.utf8ValidateSlice(value);
}

test "secure input validates bounded UTF-8 options" {
    const valid: Options = .{
        .title = "Credential",
        .message = "Enter the value.",
        .accept_label = "Save",
        .cancel_label = "Cancel",
    };
    try std.testing.expect(validOptions(valid));

    var invalid = valid;
    invalid.title = "";
    try std.testing.expect(!validOptions(invalid));
    invalid = valid;
    invalid.message = "bad\x00message";
    try std.testing.expect(!validOptions(invalid));
    invalid = valid;
    invalid.accept_label = "\xff";
    try std.testing.expect(!validOptions(invalid));
}

test "unavailable and busy capture paths clear caller output" {
    const options: Options = .{
        .title = "Credential",
        .message = "",
        .accept_label = "Save",
        .cancel_label = "Cancel",
    };
    var output: [16]u8 = undefined;
    @memset(&output, 0xa5);

    var unavailable: Capability = .{};
    try std.testing.expectError(
        error.Unavailable,
        unavailable.capture(options, &output),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** output.len), &output);

    var busy: Capability = .{
        .owner_thread_id = std.Thread.getCurrentId(),
        .ready = true,
        .active = true,
    };
    @memset(&output, 0xa5);
    try std.testing.expectError(error.Busy, busy.capture(options, &output));
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** output.len), &output);
}

test "secure input rejects a different thread and clears caller output" {
    const options: Options = .{
        .title = "Credential",
        .message = "",
        .accept_label = "Save",
        .cancel_label = "Cancel",
    };
    var capability: Capability = .{
        .owner_thread_id = std.Thread.getCurrentId(),
        .ready = true,
    };
    var output: [16]u8 = undefined;
    @memset(&output, 0xa5);
    var observed: ?Error = null;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(
            target: *Capability,
            capture_options: Options,
            capture_output: []u8,
            capture_error: *?Error,
        ) void {
            _ = target.capture(capture_options, capture_output) catch |err| {
                capture_error.* = err;
                return;
            };
        }
    }.run, .{ &capability, options, &output, &observed });
    thread.join();
    try std.testing.expectEqual(error.WrongThread, observed.?);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** output.len), &output);
}
