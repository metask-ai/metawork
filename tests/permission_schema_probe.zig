//! Account-only protocol diagnostic, never a permission authority or quality pass.
//! Reference: https://platform.claude.com/docs/en/build-with-claude/structured-outputs
const std = @import("std");
const agent = @import("metawork_agent");
const review = @import("permission_review");

const marker = "metawork_schema_probe_20261025";
const valid_config = "{\"format\":{\"type\":\"json_schema\",\"schema\":{\"type\":\"object\",\"properties\":{\"probe\":{\"type\":\"string\",\"const\":\"" ++ marker ++ "\"}},\"required\":[\"probe\"],\"additionalProperties\":false}}}";
const invalid_config = "{\"format\":{\"type\":\"json_schema\",\"schema\":\"not a schema object\"}}";

const FormatTransport = struct {
    allocator: std.mem.Allocator,
    inner: agent.CompletionTransport,
    invalid: bool = false,
    status: ?u16 = null,
    matches_schema: bool = false,

    fn transport(self: *FormatTransport) agent.CompletionTransport {
        return .{ .context = self, .perform_fn = perform, .signal_cancellation_fn = cancel };
    }

    fn cancel(context: ?*anyopaque, cancellation: *agent.CompletionCancellation) void {
        const self: *FormatTransport = @ptrCast(@alignCast(context.?));
        if (self.inner.signal_cancellation_fn) |signal| signal(self.inner.context, cancellation);
    }

    fn perform(context: ?*anyopaque, request: agent.CompletionHttpRequest, cancellation: *const agent.CompletionCancellation, output: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
        const self: *FormatTransport = @ptrCast(@alignCast(context.?));
        self.status = null;
        self.matches_schema = false;
        var body = std.json.parseFromSlice(std.json.Value, self.allocator, request.body, .{}) catch return error.InvalidHttp;
        defer body.deinit();
        if (body.value != .object or body.value.object.contains("output_config")) return error.InvalidHttp;
        var config = std.json.parseFromSlice(std.json.Value, self.allocator, if (self.invalid) invalid_config else valid_config, .{}) catch return error.InvalidHttp;
        defer config.deinit();
        body.value.object.put(body.arena.allocator(), "output_config", config.value) catch return error.OutOfMemory;
        const encoded = std.json.Stringify.valueAlloc(self.allocator, body.value, .{}) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, encoded);
            self.allocator.free(encoded);
        }
        // The diagnostic changes only this documented format field. Preserve
        // the frozen URL, headers, model and messages from production Completion.
        var formatted = request;
        formatted.body = encoded;
        const response = try self.inner.perform(formatted, cancellation, output);
        self.status = response.status;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{}) catch return response;
        defer parsed.deinit();
        if (parsed.value != .object) return response;
        const content = parsed.value.object.get("content") orelse return response;
        if (content != .array) return response;
        var text: ?[]const u8 = null;
        for (content.array.items) |block| {
            if (block != .object) continue;
            const block_type = block.object.get("type") orelse continue;
            if (block_type != .string or !std.mem.eql(u8, block_type.string, "text")) continue;
            const value = block.object.get("text") orelse continue;
            if (value != .string) continue;
            if (text != null) return response; // Multiple blocks are inconclusive.
            text = value.string;
        }
        var value = std.json.parseFromSlice(std.json.Value, self.allocator, text orelse return response, .{ .duplicate_field_behavior = .@"error" }) catch return response;
        defer value.deinit();
        if (value.value != .object or value.value.object.count() != 1) return response;
        const probe = value.value.object.get("probe") orelse return response;
        self.matches_schema = probe == .string and std.mem.eql(u8, probe.string, marker);
        return response;
    }
};

fn line(init: std.process.Init, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try std.json.Stringify.value(value, .{}, &output.interface);
    try output.interface.writeByte('\n');
    try output.interface.flush();
}

fn summarize(valid_status: ?u16, valid_matches: bool, returned_review_decision: bool, invalid_status: ?u16) struct {
    kind: []const u8 = "schema_protocol_probe_summary",
    constraint_observed: bool,
    not_enforced_observed: bool,
    invalid_schema_rejected: bool,
    quality_eligible: bool = false,
} {
    return .{
        .constraint_observed = valid_status == 200 and valid_matches and invalid_status == 400,
        // A completed decision+reason object is incompatible with the requested
        // probe-only schema. A later timeout must not hide that observed fact.
        .not_enforced_observed = valid_status == 200 and !valid_matches and returned_review_decision,
        .invalid_schema_rejected = invalid_status == 400,
    };
}

pub fn run(init: std.process.Init, binding: agent.ModelBinding, network: agent.CompletionTransport, revision: []const u8) !void {
    if (binding.target.protocol != .anthropic_messages) return error.UnsupportedProbeProtocol;
    var format = FormatTransport{ .allocator = init.gpa, .inner = network };
    const completion = try agent.Completion.init(init.gpa, format.transport(), binding);
    defer completion.deinit();
    var valid_matches = false;
    var valid_status: ?u16 = null;
    var returned_review_decision = false;
    var invalid_status: ?u16 = null;
    for (0..2) |index| {
        format.invalid = index == 1;
        format.status = null;
        format.matches_schema = false;
        var cancellation = completion.newCancellation();
        const start = std.Io.Clock.Timestamp.now(init.io, .awake);
        var outcome = review.review(init.gpa, init.io, completion, .{
            .host = .{ .delegated = true, .constraints = "只诊断协议格式，不执行任何工具。", .authorization = "只允许本次格式诊断。" },
            .user_intent = "这是格式能力诊断，不执行操作。",
            .request = .{ .tool_name = "Bash", .arguments_json = "{\"command\":\"printf probe\"}", .working_directory = "/workspace" },
        }, &cancellation, start.addDuration(.{ .raw = .fromSeconds(30), .clock = .awake }));
        const failure: ?review.Failure = switch (outcome) {
            .failure => |value| value,
            .suggestion => |*value| cleaned: {
                std.crypto.secureZero(u8, &value.reason.bytes);
                break :cleaned null;
            },
        };
        try line(init, .{ .kind = "schema_protocol_probe", .revision = revision, .model = binding.target.model, .protocol = binding.target.protocol, .invalid_schema = format.invalid, .http_status = format.status, .matches_probe_schema = format.matches_schema, .classifier_failure = failure, .elapsed_ms = start.durationTo(std.Io.Clock.Timestamp.now(init.io, .awake)).raw.toMilliseconds(), .interpretation = "Protocol diagnostic only; the probe schema intentionally differs from the review decision schema. No response text is retained." });
        if (index == 0) {
            // A probe-only object intentionally fails the strict decision
            // decoder, after the production codec proved a complete end_turn.
            valid_matches = format.matches_schema and switch (outcome) {
                .failure => |value| value == .invalid_output,
                .suggestion => false,
            };
            valid_status = format.status;
            returned_review_decision = outcome == .suggestion;
        } else invalid_status = format.status;
    }
    try line(init, summarize(valid_status, valid_matches, returned_review_decision, invalid_status));
    return error.DiagnosticSamplesOnly;
}

test "a later timeout cannot hide an observed schema violation" {
    const violation = summarize(200, false, true, null);
    try std.testing.expect(violation.not_enforced_observed);
    try std.testing.expect(!violation.constraint_observed);
    try std.testing.expect(!violation.invalid_schema_rejected);
    try std.testing.expect(!violation.quality_eligible);
    try std.testing.expect(!summarize(null, false, false, null).not_enforced_observed);
    try std.testing.expect(summarize(200, true, false, 400).constraint_observed);
}

test "format probe preserves frozen headers and body fields without copying credentials into JSON" {
    const Fixture = struct {
        fn perform(_: ?*anyopaque, request: agent.CompletionHttpRequest, _: *const agent.CompletionCancellation, _: []u8) agent.CompletionTransportError!agent.CompletionTransportResponse {
            std.testing.expectEqualStrings("https://example.com/v1/messages", request.url) catch return error.Unexpected;
            std.testing.expectEqualStrings("fixture-secret", request.headers[0].value) catch return error.Unexpected;
            std.testing.expect(request.headers[0].sensitive) catch return error.Unexpected;
            std.testing.expect(std.mem.indexOf(u8, request.body, "fixture-secret") == null) catch return error.Unexpected;
            var value = std.json.parseFromSlice(std.json.Value, std.testing.allocator, request.body, .{}) catch return error.Unexpected;
            defer value.deinit();
            std.testing.expectEqualStrings("frozen-model", value.value.object.get("model").?.string) catch return error.Unexpected;
            std.testing.expect(value.value.object.contains("messages")) catch return error.Unexpected;
            const format = value.value.object.get("output_config").?.object.get("format").?.object;
            std.testing.expectEqualStrings("json_schema", format.get("type").?.string) catch return error.Unexpected;
            return .{ .status = 200, .body = "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"probe\\\":\\\"" ++ marker ++ "\\\"}\"}]}" };
        }
    };
    var format = FormatTransport{ .allocator = std.testing.allocator, .inner = .{ .perform_fn = Fixture.perform } };
    var cancellation = agent.CompletionCancellation.init(format.transport());
    var output: [1]u8 = undefined;
    _ = try format.transport().perform(.{ .url = "https://example.com/v1/messages", .headers = &.{.{ .name = "x-api-key", .value = "fixture-secret", .sensitive = true }}, .body = "{\"model\":\"frozen-model\",\"messages\":[]}" }, &cancellation, &output);
    try std.testing.expect(format.matches_schema);
}
