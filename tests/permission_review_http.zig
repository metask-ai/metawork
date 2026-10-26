//! Exercise the real buffered HTTP/cancellation path without a model service.
const std = @import("std");
const agent = @import("metawork_agent");
const review = @import("permission_review");
const http = @import("completion_http_backend");
const options = @import("review_http_fixture_options");
const evaluation = @import("permission_review_evaluation");

const Fixture = struct {
    child: std.process.Child,
    base: []u8,

    fn start() !Fixture {
        var budget_buffer: [32]u8 = undefined;
        const budget = try std.fmt.bufPrint(&budget_buffer, "{d}", .{review.max_output_tokens});
        var child = try std.process.spawn(std.testing.io, .{
            .argv = &.{ options.node_path, options.fixture_path, budget },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        });
        errdefer child.kill(std.testing.io);
        var storage: [1024]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(std.testing.io, &storage);
        const line = try reader.interface.takeDelimiterExclusive('\n');
        if (try reader.interface.takeByte() != '\n') return error.InvalidHandshake;
        const ready = try std.json.parseFromSlice(struct { base: []const u8 }, std.testing.allocator, line, .{});
        defer ready.deinit();
        return .{ .child = child, .base = try std.testing.allocator.dupe(u8, ready.value.base) };
    }

    fn deinit(self: *Fixture) void {
        self.child.kill(std.testing.io);
        std.testing.allocator.free(self.base);
    }
};

fn invoke(owner: *agent.Completion, trace: *@import("permission_review_network_trace").Trace, mode: []const u8, milliseconds: i64) review.Outcome {
    trace.prepare();
    var cancellation = owner.newCancellation();
    return review.review(std.testing.allocator, std.testing.io, owner, .{
        .host = .{ .delegated = true, .constraints = "local fixture only", .authorization = "synthetic review" },
        .user_intent = mode,
        .request = .{ .tool_name = "Bash", .arguments_json = "{\"command\":\"printf fixture\"}", .working_directory = "/workspace" },
    }, &cancellation, std.Io.Clock.Timestamp.now(std.testing.io, .awake).addDuration(.{ .raw = .fromMilliseconds(milliseconds), .clock = .awake }));
}

test "review HTTP deadline joins the old request and isolates later 503 invalid JSON and success" {
    var fixture = try Fixture.start();
    defer fixture.deinit();
    const endpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/v1/messages", .{fixture.base});
    defer std.testing.allocator.free(endpoint);
    var trace: @import("permission_review_network_trace").Trace = undefined;
    try trace.init(std.testing.io);
    defer trace.deinit();
    try std.testing.expect(trace.io().userdata == std.testing.io.userdata);
    try std.testing.expect(trace.io().vtable != std.testing.io.vtable);
    inline for (@typeInfo(std.Io.VTable).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "netLookup") and !std.mem.eql(u8, field.name, "netConnectIp") and !std.mem.eql(u8, field.name, "netRead") and !std.mem.eql(u8, field.name, "netWrite")) {
            try std.testing.expect(@field(trace.table, field.name) == @field(std.testing.io.vtable.*, field.name));
        }
    }
    var duplicate_trace: @import("permission_review_network_trace").Trace = undefined;
    try std.testing.expectError(error.DiagnosticTraceAlreadyActive, duplicate_trace.init(std.testing.io));
    var backend = http.Backend{ .allocator = std.testing.allocator, .io = trace.io() };
    var observed = evaluation.ObservedTransport{ .inner = trace.wrap(backend.transport()), .trace = &trace };
    const owner = try agent.Completion.init(std.testing.allocator, observed.transport(), .{
        .target = .{ .provider_id = "fixture", .protocol = .anthropic_messages, .base_url = endpoint, .model = "fixture-review" },
        .credential = "synthetic-review-key",
    });
    defer owner.deinit();
    trace.prepare();
    var early_cancellation = owner.newCancellation();
    early_cancellation.request();
    try std.testing.expect(owner.complete(.{ .messages = &.{.{ .role = .user, .text = "synthetic" }}, .max_output_tokens = 1 }, &early_cancellation).failure == .cancelled);
    try std.testing.expect(trace.report().cancelled_before_transport);
    try std.testing.expect(trace.report().finished == null);
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const held = invoke(owner, &trace, "hold", 500);
    try std.testing.expect(held == .failure);
    try std.testing.expect(held.failure == .timeout);
    try std.testing.expect(!trace.report().cancelled_before_transport);
    try std.testing.expectEqual(@as(?usize, null), observed.observation.response_bytes);
    try std.testing.expectEqual(@as(?bool, false), observed.observation.response_buffer_modified_on_failure);
    const held_trace = trace.report();
    try std.testing.expect(held_trace.at_cancel.?.read.pending > 0);
    try std.testing.expectEqual(@as(u64, 0), held_trace.finished.?.read.bytes);
    try std.testing.expect(held_trace.finished.?.write.bytes > 0);
    try std.testing.expect(held_trace.finished.?.connect.calls > 0);
    try std.testing.expectEqual(@as(u64, 0), held_trace.finished.?.read.pending);
    try std.testing.expect(started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() < 5_000);
    const partial = invoke(owner, &trace, "partial-hold", 500);
    try std.testing.expect(partial == .failure);
    try std.testing.expect(partial.failure == .timeout);
    try std.testing.expectEqual(@as(?usize, null), observed.observation.response_bytes);
    try std.testing.expectEqual(@as(?bool, true), observed.observation.response_buffer_modified_on_failure);
    const partial_trace = trace.report();
    try std.testing.expect(partial_trace.at_cancel.?.read.pending > 0);
    try std.testing.expect(partial_trace.finished.?.read.bytes > 0);
    const trace_json = try std.json.Stringify.valueAlloc(std.testing.allocator, partial_trace, .{});
    defer std.testing.allocator.free(trace_json);
    try std.testing.expect(std.mem.indexOf(u8, trace_json, "synthetic-review-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, trace_json, "127.0.0.1") == null);
    const rejected = invoke(owner, &trace, "reject-503", 5_000);
    try std.testing.expect(rejected == .failure);
    try std.testing.expect(rejected.failure == .completion);
    try std.testing.expect(rejected.failure.completion == .provider_rejected);
    try std.testing.expectEqual(@as(u16, 503), rejected.failure.completion.provider_rejected.status);
    const invalid = invoke(owner, &trace, "invalid-json", 5_000);
    try std.testing.expect(invalid == .failure);
    try std.testing.expect(invalid.failure == .invalid_output);
    for ([_][]const u8{ "success", "split-json" }) |mode| {
        var outcome = invoke(owner, &trace, mode, 5_000);
        try std.testing.expect(outcome == .suggestion);
        defer std.crypto.secureZero(u8, &outcome.suggestion.reason.bytes);
        try std.testing.expectEqual(review.Decision.allow_once, outcome.suggestion.decision);
    }
    // The server observes the cancelled socket closing, not just a local flag.
    const state_url = try std.fmt.allocPrint(std.testing.allocator, "{s}/state", .{fixture.base});
    defer std.testing.allocator.free(state_url);
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var bytes: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const result = try client.fetch(.{ .location = .{ .url = state_url }, .response_writer = &writer });
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    const state = try std.json.parseFromSlice(struct { calls: usize, active: usize, cancelled: usize }, std.testing.allocator, writer.buffered(), .{});
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 6), state.value.calls);
    try std.testing.expectEqual(@as(usize, 0), state.value.active);
    try std.testing.expectEqual(@as(usize, 2), state.value.cancelled);
}
