//! One-shot AgentCore provider validation used by Account Model Connections.
//!
//! This is intentionally an Agent-owned ABI consumer. It performs one
//! independent streaming Completion and returns only a bounded typed outcome; provider
//! HTTP serialization and SSE decoding remain entirely inside AgentCore.

const std = @import("std");
const completion = @import("agent_completion");

pub const ProviderKind = completion.ProviderKind;

pub const Input = struct {
    provider: ProviderKind,
    credential: []const u8,
    model: []const u8,
    base_url: []const u8,
};

pub const Failure = enum {
    invalid_input,
    unsupported_abi,
    run_failed,
    provider_rejected,
    timed_out,
    invalid_result,
};

const probe_timeout_ms: u32 = 30_000;
const watchdog_poll_ms: u32 = 10;

const Watchdog = struct {
    io: std.Io,
    stream: *completion.Stream,
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
        _ = self.stream.abort(.timeout) catch return;
    }
};

pub const Outcome = union(enum) {
    connected,
    failed: Failure,
};

pub fn run(io: std.Io, input: Input) Outcome {
    if (input.credential.len == 0 or input.credential.len > 4096 or
        input.model.len == 0 or input.model.len > 256 or
        input.base_url.len == 0 or input.base_url.len > 2048 or
        !std.unicode.utf8ValidateSlice(input.model) or
        !std.unicode.utf8ValidateSlice(input.base_url))
        return .{ .failed = .invalid_input };

    var secret_storage: [4096]u8 = undefined;
    @memcpy(secret_storage[0..input.credential.len], input.credential);
    defer std.crypto.secureZero(u8, &secret_storage);
    const owner = completion.Completion.init(std.heap.c_allocator, .{
        .provider = input.provider,
        .credential = secret_storage[0..input.credential.len],
        .base_url = input.base_url,
        .model = input.model,
    }) catch |err| return .{ .failed = initFailure(err) };
    const messages = [_]completion.Message{.{
        .role = .user,
        .text = "Reply with OK.",
    }};
    const stream = owner.startStream(.{ .messages = &messages }) catch |err| {
        if (!destroyCompletion(owner)) return .{ .failed = .run_failed };
        return .{ .failed = operationFailure(err) };
    };

    var watchdog: Watchdog = .{
        .io = io,
        .stream = stream,
    };
    const watchdog_thread = std.Thread.spawn(.{}, Watchdog.run, .{&watchdog}) catch {
        if (!destroyStreamAndCompletion(stream, owner))
            return .{ .failed = .run_failed };
        return .{ .failed = .run_failed };
    };

    var terminal_reason: ?completion.StopReason = null;
    var stream_failure: ?Failure = null;
    while (terminal_reason == null and stream_failure == null) {
        var event = stream.next() catch |err| {
            stream_failure = operationFailure(err);
            break;
        };
        const kind = event.kind;
        const stop_reason = event.stop_reason;
        event.deinit();
        if (kind == .done) terminal_reason = stop_reason;
    }
    watchdog.finished.store(true, .release);
    watchdog_thread.join();

    const outcome = classifyOutcome(
        watchdog.timed_out.load(.acquire),
        stream_failure,
        terminal_reason,
    );

    if (!destroyStreamAndCompletion(stream, owner))
        return .{ .failed = .run_failed };
    return outcome;
}

fn initFailure(err: completion.Error) Failure {
    return switch (err) {
        error.InvalidConfig, error.InvalidRequest, error.InvalidArgument => .invalid_input,
        error.UnsupportedAbi => .unsupported_abi,
        error.DependencyContractFailure => .invalid_result,
        else => .run_failed,
    };
}

fn operationFailure(err: completion.Error) Failure {
    return switch (err) {
        error.DependencyContractFailure => .invalid_result,
        else => .run_failed,
    };
}

fn classifyOutcome(
    timed_out: bool,
    stream_failure: ?Failure,
    terminal_reason: ?completion.StopReason,
) Outcome {
    if (timed_out) return .{ .failed = .timed_out };
    if (stream_failure) |failure| return .{ .failed = failure };
    const reason = terminal_reason orelse return .{ .failed = .invalid_result };
    if (reason != .end_turn) return .{ .failed = .provider_rejected };
    return .connected;
}

fn destroyCompletion(owner: *completion.Completion) bool {
    owner.deinit() catch return false;
    return true;
}

fn destroyStreamAndCompletion(
    stream: *completion.Stream,
    owner: *completion.Completion,
) bool {
    stream.deinit() catch return false;
    return destroyCompletion(owner);
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

test "provider probe classifies terminal Completion outcome" {
    try std.testing.expectEqual(Outcome.connected, classifyOutcome(false, null, .end_turn));
    try std.testing.expectEqual(
        Outcome{ .failed = .provider_rejected },
        classifyOutcome(false, null, .refusal),
    );
    try std.testing.expectEqual(
        Outcome{ .failed = .invalid_result },
        classifyOutcome(false, null, null),
    );
    try std.testing.expectEqual(
        Outcome{ .failed = .timed_out },
        classifyOutcome(true, .run_failed, .end_turn),
    );
}
