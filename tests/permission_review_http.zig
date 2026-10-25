//! Exercise the real buffered HTTP/cancellation path without a model service.
const std = @import("std");
const agent = @import("metawork_agent");
const review = @import("permission_review");
const http = @import("completion_http_backend");
const options = @import("review_http_fixture_options");

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

fn invoke(owner: *agent.Completion, mode: []const u8, milliseconds: i64) review.Outcome {
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
    var backend = http.Backend{ .allocator = std.testing.allocator, .io = std.testing.io };
    const owner = try agent.Completion.init(std.testing.allocator, backend.transport(), .{
        .target = .{ .provider_id = "fixture", .protocol = .anthropic_messages, .base_url = endpoint, .model = "fixture-review" },
        .credential = "synthetic-review-key",
    });
    defer owner.deinit();
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    const held = invoke(owner, "hold", 500);
    try std.testing.expect(held == .failure);
    try std.testing.expect(held.failure == .timeout);
    try std.testing.expect(started.durationTo(std.Io.Clock.Timestamp.now(std.testing.io, .awake)).raw.toMilliseconds() < 5_000);
    const rejected = invoke(owner, "reject-503", 5_000);
    try std.testing.expect(rejected == .failure);
    try std.testing.expect(rejected.failure == .completion);
    try std.testing.expect(rejected.failure.completion == .provider_rejected);
    try std.testing.expectEqual(@as(u16, 503), rejected.failure.completion.provider_rejected.status);
    const invalid = invoke(owner, "invalid-json", 5_000);
    try std.testing.expect(invalid == .failure);
    try std.testing.expect(invalid.failure == .invalid_output);
    for ([_][]const u8{ "success", "split-json" }) |mode| {
        var outcome = invoke(owner, mode, 5_000);
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
    try std.testing.expectEqual(@as(usize, 5), state.value.calls);
    try std.testing.expectEqual(@as(usize, 0), state.value.active);
    try std.testing.expectEqual(@as(usize, 1), state.value.cancelled);
}
