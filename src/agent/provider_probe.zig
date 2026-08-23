//! One-shot AgentCore provider validation used by Account Model Connections.
//!
//! This is intentionally an Agent-owned ABI consumer. It performs one
//! tool-free streaming Run and returns only a bounded typed outcome; provider
//! HTTP serialization and SSE decoding remain entirely inside AgentCore.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const provider = @import("agent_provider");

pub const ProviderKind = provider.ProviderKind;

pub const Input = struct {
    provider: ProviderKind,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const Failure = enum {
    invalid_input,
    unsupported_abi,
    runtime_create_failed,
    session_create_failed,
    watchdog_failed,
    run_failed,
    provider_rejected,
    timed_out,
    invalid_result,
    cleanup_failed,
};

const probe_timeout_ms: u32 = 30_000;
const watchdog_poll_ms: u32 = 10;

const Watchdog = struct {
    io: std.Io,
    api: sdk.Api,
    session: *wire.SessionHandle,
    finished: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watchdog) void {
        var elapsed_ms: u32 = 0;
        while (elapsed_ms < probe_timeout_ms) : (elapsed_ms += watchdog_poll_ms) {
            if (self.finished.load(.acquire)) return;
            std.Io.Timeout.sleep(.{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(watchdog_poll_ms),
                .clock = .awake,
            } }, self.io) catch break;
        }
        if (self.finished.load(.acquire)) return;
        self.timed_out.store(true, .release);
        _ = self.api.sessionAbort()(
            self.session,
            1,
            wire.ABORT_TIMEOUT,
            null,
        );
    }
};

pub const Outcome = union(enum) {
    connected,
    failed: Failure,
};

const Observer = struct {
    event_count: usize = 0,
    malformed: bool = false,

    fn onEvent(
        context: ?*anyopaque,
        run_context: ?*const wire.RunContextV1,
        event_json: wire.BytesViewV1,
    ) callconv(.c) u32 {
        const self: *Observer = @ptrCast(@alignCast(context orelse
            return wire.EVENT_FATAL));
        _ = sdk.validateRunContext(run_context) catch {
            self.malformed = true;
            return wire.EVENT_FATAL;
        };
        const bytes = sdk.borrowedBytes(event_json) catch {
            self.malformed = true;
            return wire.EVENT_FATAL;
        };
        if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) {
            self.malformed = true;
            return wire.EVENT_FATAL;
        }
        self.event_count += 1;
        return wire.EVENT_CONTINUE;
    }

    fn onUiRequest(
        _: ?*anyopaque,
        _: ?*const wire.RunContextV1,
        _: wire.BytesViewV1,
        out_response: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (out_response) |output| output.* = .{ .ptr = null, .len = 0 };
        return wire.UI_UNAVAILABLE;
    }

    fn releaseResponse(
        _: ?*anyopaque,
        response: ?*wire.OwnedBytesV1,
    ) callconv(.c) void {
        if (response) |output| output.* = .{ .ptr = null, .len = 0 };
    }
};

pub fn run(io: std.Io, input: Input) Outcome {
    if (input.credential.len == 0 or input.credential.len > 4096 or
        input.model.len == 0 or input.model.len > 256 or
        input.base_url.len == 0 or input.base_url.len > 2048 or
        !std.unicode.utf8ValidateSlice(input.model) or
        !std.unicode.utf8ValidateSlice(input.base_url))
        return .{ .failed = .invalid_input };

    const api = sdk.Api.discover() catch
        return .{ .failed = .unsupported_abi };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var runtime: ?*wire.RuntimeHandle = null;
    if (!statusOk(api.runtimeCreate()(&runtime_config, &runtime, null)) or
        runtime == null)
        return .{ .failed = .runtime_create_failed };
    const raw_runtime = runtime.?;
    var runtime_owned = true;
    defer if (runtime_owned) {
        _ = api.runtimeDestroy()(raw_runtime, null);
    };

    var observer = Observer{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &observer;
    callbacks.on_event = Observer.onEvent;
    callbacks.on_ui_request = Observer.onUiRequest;
    callbacks.release_response = Observer.releaseResponse;

    var secret_storage: [4096]u8 = undefined;
    @memcpy(secret_storage[0..input.credential.len], input.credential);
    defer std.crypto.secureZero(u8, &secret_storage);
    const workspace = if (builtin.os.tag == .windows) "C:\\" else "/";
    var host = std.mem.zeroes(wire.SessionHostConfigV1);
    host.struct_size = @sizeOf(wire.SessionHostConfigV1);
    host.provider_kind_code = provider.wireCode(input.provider);
    host.permission_mode_code = wire.PERMISSION_DEFAULT;
    host.shell_policy_code = wire.SHELL_DISABLED;
    host.api_key = sdk.bytesView(secret_storage[0..input.credential.len]);
    host.base_url = sdk.bytesView(input.base_url);
    host.workspace_root = sdk.bytesView(workspace);
    host.workspace_home = sdk.bytesView(workspace);

    var session_config = std.mem.zeroes(wire.SessionCreateConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionCreateConfigV1);
    session_config.host = &host;
    session_config.model = sdk.bytesView(input.model);
    var session: ?*wire.SessionHandle = null;
    if (!statusOk(api.sessionCreate()(
        raw_runtime,
        &session_config,
        &callbacks,
        &session,
        null,
    )) or session == null)
        return .{ .failed = .session_create_failed };
    const raw_session = session.?;
    var session_owned = true;
    defer if (session_owned) {
        _ = api.sessionDestroy()(raw_session, null);
    };

    var options = std.mem.zeroes(wire.RunOptionsV1);
    options.struct_size = @sizeOf(wire.RunOptionsV1);
    options.max_turns = 1;
    var result = std.mem.zeroes(wire.RunResultV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer releaseOwned(api, &diagnostic);
    var watchdog: Watchdog = .{
        .io = io,
        .api = api,
        .session = raw_session,
    };
    const watchdog_thread = std.Thread.spawn(.{}, Watchdog.run, .{&watchdog}) catch
        return .{ .failed = .watchdog_failed };
    const run_status = api.sessionRunText(
        raw_session,
        1,
        sdk.bytesView("Reply with OK."),
        &options,
        &result,
        &diagnostic,
    );
    watchdog.finished.store(true, .release);
    watchdog_thread.join();
    if (!statusOk(run_status)) return .{ .failed = .run_failed };
    const stop_reason = sdk.StopReason.fromCode(result.stop_reason_code) catch
        return .{ .failed = .invalid_result };
    if (result.struct_size != @sizeOf(wire.RunResultV1) or
        observer.malformed or observer.event_count == 0)
        return .{ .failed = .invalid_result };
    if (watchdog.timed_out.load(.acquire))
        return .{ .failed = .timed_out };
    if (stop_reason != .end_turn or result.turns != 1 or result.tool_calls != 0)
        return .{ .failed = .provider_rejected };

    const session_status = api.sessionDestroy()(raw_session, null);
    session_owned = false;
    const runtime_status = api.runtimeDestroy()(raw_runtime, null);
    runtime_owned = false;
    if (!statusOk(session_status) or !statusOk(runtime_status))
        return .{ .failed = .cleanup_failed };
    return .connected;
}

fn statusOk(raw: u32) bool {
    const status = sdk.Status.fromCode(raw) catch return false;
    return status == .ok;
}

fn releaseOwned(api: sdk.Api, bytes: *wire.OwnedBytesV1) void {
    if (bytes.ptr != null or bytes.len != 0) api.bufferRelease()(bytes);
    bytes.* = .{ .ptr = null, .len = 0 };
}

test "provider probe rejects invalid input before AgentCore discovery" {
    try std.testing.expectEqual(
        Outcome{ .failed = .invalid_input },
        run(std.testing.io, .{
            .provider = .openai,
            .credential = "",
            .model = "gpt-5",
            .base_url = "https://api.openai.com/v1/chat/completions",
        }),
    );
}
