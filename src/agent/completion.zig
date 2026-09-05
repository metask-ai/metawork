//! MetaWork-owned one-shot text Completion.
//!
//! Provider JSON belongs here. DNS, HTTP, TLS and request cancellation are
//! supplied through the injected Transport.

const std = @import("std");
const types = @import("completion/types.zig");
const transport = @import("completion/transport.zig");
const codec = @import("completion/codec.zig");
const openai = @import("completion/openai_codec.zig");
const responses = @import("completion/openai_responses_codec.zig");
const gemini = @import("completion/gemini_codec.zig");
const anthropic = @import("completion/anthropic_codec.zig");
const model_binding = @import("agent_model_binding");

pub const Protocol = @import("agent_protocol").Protocol;
pub const max_provider_id_bytes = @import("agent_protocol").max_provider_id_bytes;
pub const Transport = transport.Transport;
pub const HttpRequest = transport.HttpRequest;
pub const HttpHeader = transport.Header;
pub const Cancellation = transport.Cancellation;
pub const TransportError = transport.Error;
pub const TransportResponse = transport.Response;
pub const ModelBinding = model_binding.ModelBinding;
pub const Message = types.Message;
pub const Request = types.Request;
pub const Role = types.Role;
pub const Usage = types.Usage;
pub const StopReason = types.StopReason;
pub const Failure = types.Failure;
pub const Result = types.Result;
pub const CompleteOutcome = types.CompleteOutcome;
pub const max_config_bytes = types.max_config_bytes;
pub const max_messages = types.max_messages;
pub const max_request_bytes = types.max_request_bytes;
pub const max_response_bytes = types.max_response_bytes;
pub const max_result_bytes = types.max_result_bytes;

pub const InitError = error{
    InvalidConfig,
    OutOfMemory,
};

pub const Completion = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    provider_id: []u8,
    protocol: Protocol,
    credential: []u8,
    base_url: []u8,
    model: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        network: Transport,
        binding: ModelBinding,
    ) InitError!*Completion {
        try validateConfig(binding);
        const self = try allocator.create(Completion);
        errdefer allocator.destroy(self);
        const provider_id = try allocator.dupe(u8, binding.target.provider_id);
        errdefer allocator.free(provider_id);
        const credential = try allocator.dupe(u8, binding.credential);
        errdefer {
            std.crypto.secureZero(u8, credential);
            allocator.free(credential);
        }
        const base_url = try allocator.dupe(u8, binding.target.base_url);
        errdefer allocator.free(base_url);
        const model = try allocator.dupe(u8, binding.target.model);
        self.* = .{
            .allocator = allocator,
            .transport = network,
            .provider_id = provider_id,
            .protocol = binding.target.protocol,
            .credential = credential,
            .base_url = base_url,
            .model = model,
        };
        return self;
    }

    pub fn newCancellation(self: *const Completion) Cancellation {
        return Cancellation.init(self.transport);
    }

    pub fn complete(
        self: *Completion,
        request: Request,
        cancellation: *const Cancellation,
    ) CompleteOutcome {
        validateRequest(request) catch |failure| return .{ .failure = switch (failure) {
            error.InvalidRequest => .invalid_request,
            error.ResourceLimit => .resource_limit,
        } };
        if (cancellation.isRequested()) return .{ .failure = .cancelled };

        var encoded = switch (self.protocol) {
            .openai_responses => responses.encode(self.allocator, self.codecConfigView(), request),
            .openai_chat_completions => openai.encode(self.allocator, self.codecConfigView(), request),
            .anthropic_messages => anthropic.encode(self.allocator, self.codecConfigView(), request),
            .gemini_native => gemini.encode(self.allocator, self.codecConfigView(), request),
        } catch |failure| return .{ .failure = codecFailure(failure) };
        defer encoded.deinit();
        if (cancellation.isRequested()) return .{ .failure = .cancelled };

        const response_buffer = self.allocator.alloc(u8, types.max_response_bytes) catch
            return .{ .failure = .out_of_memory };
        defer {
            std.crypto.secureZero(u8, response_buffer);
            self.allocator.free(response_buffer);
        }
        const response = self.transport.perform(
            encoded.view(),
            cancellation,
            response_buffer,
        ) catch |failure| return .{ .failure = if (failure == error.Cancelled)
            .cancelled
        else
            .{ .transport_failed = transportFailure(failure) } };
        if (cancellation.isRequested()) return .{ .failure = .cancelled };
        if (response.status < 200 or response.status > 299) return .{ .failure = .{
            .provider_rejected = types.rejectionForStatus(response.status),
        } };

        const result = switch (self.protocol) {
            .openai_responses => responses.decode(self.allocator, response.body),
            .openai_chat_completions => openai.decode(self.allocator, response.body),
            .anthropic_messages => anthropic.decode(self.allocator, response.body),
            .gemini_native => gemini.decode(self.allocator, response.body),
        } catch |failure| return .{ .failure = codecFailure(failure) };
        return .{ .result = result };
    }

    pub fn deinit(self: *Completion) void {
        const allocator = self.allocator;
        allocator.free(self.provider_id);
        std.crypto.secureZero(u8, self.credential);
        allocator.free(self.credential);
        allocator.free(self.base_url);
        allocator.free(self.model);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn codecConfigView(self: *const Completion) types.CodecConfig {
        return .{
            .credential = self.credential,
            .base_url = self.base_url,
            .model = self.model,
        };
    }
};

fn validateConfig(binding: ModelBinding) InitError!void {
    if (binding.target.provider_id.len == 0 or binding.target.provider_id.len > max_provider_id_bytes or
        !std.unicode.utf8ValidateSlice(binding.target.provider_id)) return error.InvalidConfig;
    if (binding.credential.len == 0 or binding.target.base_url.len == 0 or
        binding.target.model.len == 0 or !std.unicode.utf8ValidateSlice(binding.target.base_url) or
        !std.unicode.utf8ValidateSlice(binding.target.model))
        return error.InvalidConfig;
    var total: usize = 0;
    inline for (.{ binding.target.provider_id, binding.credential, binding.target.base_url, binding.target.model }) |value|
        total = std.math.add(usize, total, value.len) catch return error.InvalidConfig;
    if (total > types.max_config_bytes) return error.InvalidConfig;
    const uri = std.Uri.parse(binding.target.base_url) catch return error.InvalidConfig;
    if (uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null)
        return error.InvalidConfig;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and
        !loopbackHttp(uri)) return error.InvalidConfig;
}

fn loopbackHttp(uri: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const host = switch (uri.host.?) {
        .raw, .percent_encoded => |value| value,
    };
    return std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "[::1]");
}

fn validateRequest(request: Request) error{ InvalidRequest, ResourceLimit }!void {
    if (request.messages.len == 0 or request.messages.len > types.max_messages or
        !std.unicode.utf8ValidateSlice(request.system))
        return error.InvalidRequest;
    var total = request.system.len;
    for (request.messages) |message| {
        if (message.text.len == 0 or !std.unicode.utf8ValidateSlice(message.text))
            return error.InvalidRequest;
        total = std.math.add(usize, total, message.text.len) catch
            return error.ResourceLimit;
        if (total > types.max_request_bytes) return error.ResourceLimit;
    }
}

fn codecFailure(failure: codec.Error) Failure {
    return switch (failure) {
        error.OutOfMemory => .out_of_memory,
        error.ResourceLimit => .resource_limit,
        error.MalformedResponse => .malformed_response,
        error.UnsupportedResponse => .unsupported_response,
    };
}

fn transportFailure(failure: transport.Error) types.TransportFailure {
    return switch (failure) {
        error.DnsFailed => .dns,
        error.ConnectFailed => .connect,
        error.TlsFailed => .tls,
        error.WriteFailed => .write,
        error.ReadFailed => .read,
        error.InvalidHttp => .invalid_http,
        error.Cancelled, error.ResponseTooLarge, error.OutOfMemory, error.Unexpected => .other,
    };
}

const FakeTransport = struct {
    response: []const u8,
    private_provider_id: ?[]const u8 = null,
    status: u16 = 200,
    perform_count: usize = 0,
    saw_sensitive_header: bool = false,
    request_streaming: bool = false,
    request_has_responses_input: bool = false,

    fn port(self: *FakeTransport) Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: ?*anyopaque,
        request: HttpRequest,
        cancellation: *const Cancellation,
        response_buffer: []u8,
    ) transport.Error!transport.Response {
        const self: *FakeTransport = @ptrCast(@alignCast(context.?));
        self.perform_count += 1;
        if (self.private_provider_id) |id| {
            if (std.mem.indexOf(u8, request.url, id) != null or
                std.mem.indexOf(u8, request.body, id) != null) return error.Unexpected;
            for (request.headers) |header| {
                if (std.mem.indexOf(u8, header.name, id) != null or
                    std.mem.indexOf(u8, header.value, id) != null) return error.Unexpected;
            }
        }
        if (cancellation.isRequested()) return error.Cancelled;
        for (request.headers) |header|
            self.saw_sensitive_header = self.saw_sensitive_header or header.sensitive;
        var parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, request.body, .{}) catch
            return error.Unexpected;
        defer parsed.deinit();
        const fields = parsed.value.object;
        if (fields.get("stream")) |stream| self.request_streaming = stream.bool;
        self.request_has_responses_input = fields.contains("input") and !fields.contains("messages");
        if (self.response.len > response_buffer.len) return error.ResponseTooLarge;
        @memcpy(response_buffer[0..self.response.len], self.response);
        return .{ .status = self.status, .body = response_buffer[0..self.response.len] };
    }
};

test "invalid config and request fail before Transport" {
    var fake = FakeTransport{ .response = "{}" };
    try std.testing.expectError(error.InvalidConfig, Completion.init(
        std.testing.allocator,
        fake.port(),
        .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = .openai_responses,
                .base_url = "https://example.test",
                .model = "m",
            },
            .credential = "",
        },
    ));
    const owner = try Completion.init(std.testing.allocator, fake.port(), .{
        .target = .{
            .provider_id = "fixture-provider",
            .protocol = .openai_chat_completions,
            .base_url = "https://example.test/v1/chat/completions",
            .model = "m",
        },
        .credential = "secret",
    });
    defer owner.deinit();
    var cancellation = owner.newCancellation();
    try std.testing.expectEqual(
        Failure.invalid_request,
        owner.complete(.{ .messages = &.{} }, &cancellation).failure,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.perform_count);
}

test "explicit protocols complete through one non-streaming path" {
    const Fixture = struct {
        protocol: Protocol,
        base_url: []const u8,
        response: []const u8,
        expected: []const u8,
    };
    const fixtures = [_]Fixture{
        .{
            .protocol = .anthropic_messages,
            .base_url = "https://api.anthropic.com/v1/messages",
            .response = "{\"type\":\"message\",\"content\":[{\"type\":\"text\",\"text\":\"anthropic\"}],\"stop_reason\":\"end_turn\",\"usage\":{}}",
            .expected = "anthropic",
        },
        .{
            .protocol = .openai_chat_completions,
            .base_url = "https://api.openai.com/v1/chat/completions",
            .response = "{\"choices\":[{\"message\":{\"content\":\"openai\"},\"finish_reason\":\"stop\"}],\"usage\":{}}",
            .expected = "openai",
        },
        .{
            .protocol = .openai_responses,
            // A custom endpoint must not select or rewrite the protocol.
            .base_url = "https://example.test/custom-endpoint",
            .response = "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"responses\"}]}]}",
            .expected = "responses",
        },
        .{
            .protocol = .gemini_native,
            .base_url = "https://generativelanguage.googleapis.com",
            .response = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"gemini\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{}}",
            .expected = "gemini",
        },
    };
    for (fixtures) |fixture| {
        var fake = FakeTransport{ .response = fixture.response };
        const owner = try Completion.init(std.testing.allocator, fake.port(), .{
            .target = .{
                .provider_id = "fixture-provider",
                .protocol = fixture.protocol,
                .base_url = fixture.base_url,
                .model = "model",
            },
            .credential = "secret",
        });
        defer owner.deinit();
        var cancellation = owner.newCancellation();
        var result = switch (owner.complete(.{ .messages = &.{.{
            .role = .user,
            .text = "hello",
        }} }, &cancellation)) {
            .result => |value| value,
            .failure => return error.TestUnexpectedResult,
        };
        defer result.deinit();
        try std.testing.expectEqualStrings(fixture.expected, result.text);
        try std.testing.expectEqual(StopReason.end_turn, result.stop_reason);
        try std.testing.expect(fake.saw_sensitive_header);
        try std.testing.expect(!fake.request_streaming);
        try std.testing.expectEqual(fixture.protocol == .openai_responses, fake.request_has_responses_input);
        try std.testing.expectEqual(@as(usize, 1), fake.perform_count);
    }
}

test "service instances share a protocol without sharing identity or sending it on the wire" {
    var identities = [_][18]u8{ "service-instance-a".*, "service-instance-b".* };
    for (&identities, [_][]const u8{ "service-instance-a", "service-instance-b" }) |*id, expected| {
        var fake = FakeTransport{
            .private_provider_id = expected,
            .response = "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}],\"usage\":{}}",
        };
        const owner = try Completion.init(std.testing.allocator, fake.port(), .{
            .target = .{
                .provider_id = id,
                .protocol = .openai_responses,
                .base_url = "https://example.test/v1/responses",
                .model = "model",
            },
            .credential = "secret",
        });
        defer owner.deinit();
        @memset(id, 'x');
        try std.testing.expectEqualStrings(expected, owner.provider_id);
        var cancellation = owner.newCancellation();
        var result = switch (owner.complete(.{ .messages = &.{.{ .role = .user, .text = "hello" }} }, &cancellation)) {
            .result => |value| value,
            .failure => return error.TestUnexpectedResult,
        };
        defer result.deinit();
        try std.testing.expectEqualStrings("ok", result.text);
        try std.testing.expectEqual(@as(usize, 1), fake.perform_count);
    }
}

test "cancellation and provider rejection are explicit outcomes" {
    var fake = FakeTransport{ .response = "{}", .status = 429 };
    const owner = try Completion.init(std.testing.allocator, fake.port(), .{
        .target = .{
            .provider_id = "fixture-provider",
            .protocol = .openai_responses,
            .base_url = "https://example.test/v1/responses",
            .model = "m",
        },
        .credential = "secret",
    });
    defer owner.deinit();
    var cancellation = owner.newCancellation();
    cancellation.request();
    try std.testing.expectEqual(
        Failure.cancelled,
        owner.complete(.{ .messages = &.{.{ .role = .user, .text = "hi" }} }, &cancellation).failure,
    );
    try std.testing.expectEqual(@as(usize, 0), fake.perform_count);

    var active = owner.newCancellation();
    const rejected = owner.complete(.{ .messages = &.{.{ .role = .user, .text = "hi" }} }, &active);
    try std.testing.expectEqual(@as(u16, 429), rejected.failure.provider_rejected.status);
}

test "Completion clears its owned credential copy" {
    var storage: [8 * 1024]u8 = [_]u8{0xaa} ** (8 * 1024);
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var fake = FakeTransport{ .response = "{}" };
    const owner = try Completion.init(fixed.allocator(), fake.port(), .{
        .target = .{
            .provider_id = "fixture-provider",
            .protocol = .openai_responses,
            .base_url = "https://example.test/v1/responses",
            .model = "m",
        },
        .credential = "FIXTURE_SECRET",
    });
    try std.testing.expect(std.mem.indexOf(u8, &storage, "FIXTURE_SECRET") != null);
    owner.deinit();
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, &storage, "FIXTURE_SECRET"),
    );
}

test "Completion public surface is fully analyzed" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Completion);
}
