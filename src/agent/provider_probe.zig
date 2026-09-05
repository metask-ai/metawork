//! One-shot Provider validation over MetaWork-owned Completion.

const std = @import("std");
const completion = @import("agent_completion");
const model_binding = @import("agent_model_binding");
const ModelBinding = model_binding.ModelBinding;
const Protocol = completion.Protocol;

pub const Failure = enum {
    invalid_input,
    run_failed,
    provider_rejected,
    timed_out,
    invalid_result,
};

const probe_timeout_ms: u32 = 30_000;
const watchdog_poll_ms: u32 = 10;

pub const Cancellation = struct {
    requested: std.atomic.Value(bool) = .init(false),

    pub fn request(self: *Cancellation) void {
        self.requested.store(true, .release);
    }

    pub fn isRequested(self: *const Cancellation) bool {
        return self.requested.load(.acquire);
    }
};

const Watchdog = struct {
    io: std.Io,
    request_cancellation: *completion.Cancellation,
    external_cancellation: *const Cancellation,
    finished: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn run(self: *Watchdog) void {
        var elapsed_ms: u32 = 0;
        while (elapsed_ms < probe_timeout_ms) : (elapsed_ms += watchdog_poll_ms) {
            if (self.finished.load(.acquire)) return;
            if (self.external_cancellation.isRequested()) {
                self.request_cancellation.request();
                return;
            }
            std.Io.Timeout.sleep(.{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(watchdog_poll_ms),
                .clock = .awake,
            } }, self.io) catch break;
        }
        if (self.finished.load(.acquire)) return;
        if (self.external_cancellation.isRequested()) {
            self.request_cancellation.request();
            return;
        }
        self.timed_out.store(true, .release);
        self.request_cancellation.request();
    }
};

pub const Outcome = union(enum) {
    connected,
    failed: Failure,
};

pub fn run(
    io: std.Io,
    network: completion.Transport,
    binding: ModelBinding,
    cancellation: *const Cancellation,
) Outcome {
    if (!validInput(binding)) return .{ .failed = .invalid_input };
    if (cancellation.isRequested()) return .{ .failed = .run_failed };

    const owner = completion.Completion.init(
        std.heap.c_allocator,
        network,
        binding,
    ) catch |failure| return .{ .failed = switch (failure) {
        error.InvalidConfig => .invalid_input,
        error.OutOfMemory => .run_failed,
    } };
    defer owner.deinit();

    var request_cancellation = owner.newCancellation();
    var watchdog: Watchdog = .{
        .io = io,
        .request_cancellation = &request_cancellation,
        .external_cancellation = cancellation,
    };
    const watchdog_thread = std.Thread.spawn(.{}, Watchdog.run, .{&watchdog}) catch
        return .{ .failed = .run_failed };
    const messages = [_]completion.Message{.{
        .role = .user,
        .text = "Reply with OK.",
    }};
    var complete_outcome = owner.complete(
        .{ .messages = &messages },
        &request_cancellation,
    );
    watchdog.finished.store(true, .release);
    watchdog_thread.join();
    return classifyOutcome(
        cancellation.isRequested(),
        watchdog.timed_out.load(.acquire),
        &complete_outcome,
    );
}

fn validInput(binding: ModelBinding) bool {
    model_binding.validate(binding, .required_explicit) catch return false;
    return true;
}

fn classifyOutcome(
    externally_cancelled: bool,
    timed_out: bool,
    outcome: *completion.CompleteOutcome,
) Outcome {
    if (externally_cancelled) {
        deinitResult(outcome);
        return .{ .failed = .run_failed };
    }
    if (timed_out) {
        deinitResult(outcome);
        return .{ .failed = .timed_out };
    }
    return switch (outcome.*) {
        .result => |*result| result_outcome: {
            defer result.deinit();
            if (result.stop_reason != .end_turn)
                break :result_outcome .{ .failed = .provider_rejected };
            if (result.text.len == 0)
                break :result_outcome .{ .failed = .invalid_result };
            break :result_outcome .connected;
        },
        .failure => |failure| .{ .failed = switch (failure) {
            .provider_rejected => .provider_rejected,
            .malformed_response, .unsupported_response => .invalid_result,
            .invalid_config, .invalid_request => .invalid_input,
            .cancelled, .transport_failed, .resource_limit, .out_of_memory => .run_failed,
        } },
    };
}

fn deinitResult(outcome: *completion.CompleteOutcome) void {
    switch (outcome.*) {
        .result => |*result| result.deinit(),
        .failure => {},
    }
}

test "provider probe rejects invalid input before Transport" {
    const Fixture = struct {
        fn perform(
            _: ?*anyopaque,
            _: completion.HttpRequest,
            _: *const completion.Cancellation,
            _: []u8,
        ) completion.TransportError!completion.TransportResponse {
            return error.Unexpected;
        }
    };
    var cancellation: Cancellation = .{};
    try std.testing.expectEqual(
        Outcome{ .failed = .invalid_input },
        run(std.testing.io, .{ .perform_fn = Fixture.perform }, .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .openai_responses,
                .base_url = "https://api.openai.com/v1/chat/completions",
                .model = "gpt-5",
            },
            .credential = "",
        }, &cancellation),
    );
    var oversized_credential = [_]u8{0xff} ** (model_binding.max_credential_bytes + 1);
    try std.testing.expectEqual(
        Outcome{ .failed = .invalid_input },
        run(std.testing.io, .{ .perform_fn = Fixture.perform }, .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .openai_responses,
                .base_url = "https://api.openai.com/v1/chat/completions",
                .model = "gpt-5",
            },
            .credential = &oversized_credential,
        }, &cancellation),
    );
}

test "provider probe selects the OpenAI protocol and requires a completed result" {
    const Fixture = struct {
        response: []const u8,

        fn perform(
            context: ?*anyopaque,
            _: completion.HttpRequest,
            _: *const completion.Cancellation,
            buffer: []u8,
        ) completion.TransportError!completion.TransportResponse {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            @memcpy(buffer[0..self.response.len], self.response);
            return .{ .status = 200, .body = buffer[0..self.response.len] };
        }
    };
    const text_item = "{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"OK\"}]}";
    const cases = [_]struct { protocol: Protocol, response: []const u8, expected: Outcome }{
        .{
            .protocol = .openai_chat_completions,
            .response = "{\"choices\":[{\"message\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}",
            .expected = .connected,
        },
        .{
            .protocol = .openai_responses,
            .response = "{\"status\":\"completed\",\"output\":[" ++ text_item ++ "]}",
            .expected = .connected,
        },
        .{
            .protocol = .openai_responses,
            .response = "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[" ++ text_item ++ "]}",
            .expected = .{ .failed = .provider_rejected },
        },
    };
    for (cases) |case| {
        var fixture = Fixture{ .response = case.response };
        var cancellation: Cancellation = .{};
        try std.testing.expectEqual(
            case.expected,
            run(std.testing.io, .{ .context = &fixture, .perform_fn = Fixture.perform }, .{
                .target = .{
                    .provider_id = "fixture-provider",
                    .protocol = case.protocol,
                    .base_url = "https://example.test/endpoint",
                    .model = "fixture-model",
                },
                .credential = "secret",
            }, &cancellation),
        );
    }
}

test "external cancellation wakes a blocked Provider probe" {
    const BlockingTransport = struct {
        entered: std.Io.Semaphore = .{},
        release: std.Io.Semaphore = .{},
        signals: std.atomic.Value(usize) = .init(0),

        fn perform(
            context: ?*anyopaque,
            _: completion.HttpRequest,
            cancellation: *const completion.Cancellation,
            _: []u8,
        ) completion.TransportError!completion.TransportResponse {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.entered.post(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
            if (cancellation.isRequested()) return error.Cancelled;
            return error.Unexpected;
        }

        fn signal(
            context: ?*anyopaque,
            _: *completion.Cancellation,
        ) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.signals.fetchAdd(1, .acq_rel);
            self.release.post(std.testing.io);
        }
    };
    const ProbeThread = struct {
        network: completion.Transport,
        cancellation: *Cancellation,
        outcome: Outcome = undefined,

        fn runProbe(self: *@This()) void {
            self.outcome = run(std.testing.io, self.network, .{
                .target = .{
                    .provider_id = "fixture-provider",
                    .protocol = .openai_chat_completions,
                    .base_url = "https://api.openai.com/v1/chat/completions",
                    .model = "gpt-5",
                },
                .credential = "secret",
            }, self.cancellation);
        }
    };

    var blocked: BlockingTransport = .{};
    var cancellation: Cancellation = .{};
    var probe = ProbeThread{
        .network = .{
            .context = &blocked,
            .perform_fn = BlockingTransport.perform,
            .signal_cancellation_fn = BlockingTransport.signal,
        },
        .cancellation = &cancellation,
    };
    const thread = try std.Thread.spawn(.{}, ProbeThread.runProbe, .{&probe});
    blocked.entered.waitUncancelable(std.testing.io);
    cancellation.request();
    thread.join();
    try std.testing.expectEqual(Outcome{ .failed = .run_failed }, probe.outcome);
    try std.testing.expectEqual(@as(usize, 1), blocked.signals.load(.acquire));
}
