//! Independent AgentCore text-completion capability.
//!
//! Completion does not borrow an Agent Runtime or Session. This module owns
//! the ABI mapping, output validation, and AgentCore buffer lifecycle; callers
//! receive only MetaWork-owned typed values.

const std = @import("std");
const sdk = @import("metask_agentcore");
const wire = sdk.types;
const provider = @import("agent_provider");

pub const ProviderKind = provider.ProviderKind;
pub const Status = sdk.Status;
pub const StopReason = wire.CompletionStopReason;
pub const EventKind = wire.CompletionEventKind;

pub const Role = enum {
    user,
    assistant,
};

pub const AbortReason = enum {
    user_request,
    timeout,
};

pub const AbortOutcome = enum {
    requested,
    too_late,
};

pub const Config = struct {
    provider: ProviderKind,
    credential: []const u8,
    base_url: []const u8,
    model: []const u8,
};

pub const Message = struct {
    role: Role,
    text: []const u8,
};

pub const Request = struct {
    system: []const u8 = "",
    messages: []const Message,
};

pub const Usage = struct {
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
};

pub const Info = struct {
    allocator: std.mem.Allocator,
    provider: ProviderKind,
    model: []u8,

    pub fn deinit(self: *Info) void {
        self.allocator.free(self.model);
        self.* = undefined;
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    usage: Usage,
    stop_reason: StopReason,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Event = struct {
    allocator: std.mem.Allocator,
    kind: EventKind,
    payload: []u8,
    usage: Usage,
    stop_reason: StopReason,

    pub fn deinit(self: *Event) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidConfig,
    InvalidRequest,
    InvalidArgument,
    UnsupportedAbi,
    Busy,
    ResourceLimit,
    UnsupportedResponse,
    CoreCallFailed,
    DependencyContractFailure,
    StreamsOutstanding,
    OutOfMemory,
};

/// Provider-bound independent Completion owner. The returned pointer is stable
/// until `deinit`; every child Stream must be destroyed first.
pub const Completion = struct {
    allocator: std.mem.Allocator,
    api: sdk.Api,
    raw: *wire.CompletionHandle,
    active_streams: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
    ) Error!*Completion {
        return initWithValidatedApi(allocator, try sdk.Api.discover(), config);
    }

    /// Test-only injection boundary. `raw_api` must outlive the Completion.
    pub fn initWithApi(
        allocator: std.mem.Allocator,
        raw_api: *const wire.ApiV1,
        config: Config,
    ) Error!*Completion {
        return initWithValidatedApi(allocator, try sdk.Api.validate(raw_api), config);
    }

    fn initWithValidatedApi(
        allocator: std.mem.Allocator,
        api: sdk.Api,
        config: Config,
    ) Error!*Completion {
        try validateConfig(config);
        var raw_config = std.mem.zeroes(wire.CompletionConfigV1);
        raw_config.struct_size = @sizeOf(wire.CompletionConfigV1);
        raw_config.provider_kind_code = provider.wireCode(config.provider);
        raw_config.api_key = sdk.bytesView(config.credential);
        raw_config.base_url = sdk.bytesView(config.base_url);
        raw_config.model = sdk.bytesView(config.model);

        var raw: ?*wire.CompletionHandle = null;
        var diagnostic = emptyOwnedBytes();
        const status_code = api.completionCreate()(&raw_config, &raw, &diagnostic);
        defer releaseOwned(api, &diagnostic);
        operationStatus(.create, status_code) catch |err| {
            if (raw) |handle| discardCompletion(api, handle);
            return err;
        };
        const handle = raw orelse return error.DependencyContractFailure;
        const self = allocator.create(Completion) catch |err| {
            discardCompletion(api, handle);
            return err;
        };
        self.* = .{
            .allocator = allocator,
            .api = api,
            .raw = handle,
        };
        return self;
    }

    pub fn describe(self: *Completion) Error!Info {
        var raw_info = std.mem.zeroes(wire.CompletionInfoV1);
        var diagnostic = emptyOwnedBytes();
        const status_code = self.api.completionDescribe()(
            self.raw,
            &raw_info,
            &diagnostic,
        );
        defer releaseOwned(self.api, &raw_info.model);
        defer releaseOwned(self.api, &diagnostic);
        try operationStatus(.describe, status_code);
        if (raw_info.struct_size != @sizeOf(wire.CompletionInfoV1) or
            !allZero(&raw_info.reserved))
            return error.DependencyContractFailure;
        const model = try copyOwnedUtf8(
            self.allocator,
            raw_info.model,
            wire.MAX_COMPLETION_CONFIG_BYTES_V1,
        );
        if (model.len == 0) {
            self.allocator.free(model);
            return error.DependencyContractFailure;
        }
        return .{
            .allocator = self.allocator,
            .provider = provider.fromWireCode(raw_info.provider_kind_code) catch {
                self.allocator.free(model);
                return error.DependencyContractFailure;
            },
            .model = model,
        };
    }

    pub fn complete(self: *Completion, request: Request) Error!Result {
        var prepared = try PreparedRequest.init(self.allocator, request);
        defer prepared.deinit();
        var raw_result = std.mem.zeroes(wire.CompletionResultV1);
        var diagnostic = emptyOwnedBytes();
        const status_code = self.api.completionComplete()(
            self.raw,
            &prepared.raw,
            &raw_result,
            &diagnostic,
        );
        defer releaseOwned(self.api, &raw_result.text);
        defer releaseOwned(self.api, &diagnostic);
        try operationStatus(.complete, status_code);
        if (raw_result.struct_size != @sizeOf(wire.CompletionResultV1) or
            !allZero(&raw_result.reserved))
            return error.DependencyContractFailure;
        const stop_reason = StopReason.fromCode(raw_result.stop_reason_code) catch
            return error.DependencyContractFailure;
        return .{
            .allocator = self.allocator,
            .text = try copyOwnedUtf8(
                self.allocator,
                raw_result.text,
                wire.MAX_COMPLETION_RESULT_BYTES_V1,
            ),
            .usage = usageFromResult(raw_result),
            .stop_reason = stop_reason,
        };
    }

    pub fn startStream(self: *Completion, request: Request) Error!*Stream {
        var prepared = try PreparedRequest.init(self.allocator, request);
        defer prepared.deinit();
        var raw: ?*wire.CompletionStreamHandle = null;
        var diagnostic = emptyOwnedBytes();
        const status_code = self.api.completionStreamStart()(
            self.raw,
            &prepared.raw,
            &raw,
            &diagnostic,
        );
        defer releaseOwned(self.api, &diagnostic);
        operationStatus(.stream_start, status_code) catch |err| {
            if (raw) |handle| discardStream(self.api, handle);
            return err;
        };
        const handle = raw orelse return error.DependencyContractFailure;
        const stream = self.allocator.create(Stream) catch |err| {
            discardStream(self.api, handle);
            return err;
        };
        self.active_streams += 1;
        stream.* = .{
            .parent = self,
            .raw = handle,
        };
        return stream;
    }

    pub fn deinit(self: *Completion) Error!void {
        if (self.active_streams != 0) return error.StreamsOutstanding;
        var diagnostic = emptyOwnedBytes();
        const status_code = self.api.completionDestroy()(self.raw, &diagnostic);
        releaseOwned(self.api, &diagnostic);
        try operationStatus(.destroy, status_code);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

/// Linear stream owner. `next` may be blocked while another thread calls
/// `abort`, but both calls must return before `deinit`.
pub const Stream = struct {
    parent: *Completion,
    raw: *wire.CompletionStreamHandle,

    pub fn next(self: *Stream) Error!Event {
        var raw_event = std.mem.zeroes(wire.CompletionEventV1);
        var diagnostic = emptyOwnedBytes();
        const status_code = self.parent.api.completionStreamNext()(
            self.raw,
            &raw_event,
            &diagnostic,
        );
        defer releaseOwned(self.parent.api, &raw_event.payload);
        defer releaseOwned(self.parent.api, &diagnostic);
        try operationStatus(.stream_next, status_code);
        if (raw_event.struct_size != @sizeOf(wire.CompletionEventV1) or
            raw_event.reserved0 != 0 or !allZero(&raw_event.reserved))
            return error.DependencyContractFailure;
        const kind = eventKindFromCode(raw_event.kind_code) catch
            return error.DependencyContractFailure;
        const stop_reason = StopReason.fromCode(raw_event.stop_reason_code) catch
            return error.DependencyContractFailure;
        return .{
            .allocator = self.parent.allocator,
            .kind = kind,
            .payload = try copyOwnedUtf8(
                self.parent.allocator,
                raw_event.payload,
                wire.MAX_COMPLETION_RESULT_BYTES_V1,
            ),
            .usage = usageFromEvent(raw_event),
            .stop_reason = stop_reason,
        };
    }

    pub fn abort(self: *Stream, reason: AbortReason) Error!AbortOutcome {
        var diagnostic = emptyOwnedBytes();
        const status_code = self.parent.api.completionStreamAbort()(
            self.raw,
            switch (reason) {
                .user_request => wire.ABORT_USER_REQUEST,
                .timeout => wire.ABORT_TIMEOUT,
            },
            &diagnostic,
        );
        defer releaseOwned(self.parent.api, &diagnostic);
        const status = Status.fromCode(status_code) catch
            return error.DependencyContractFailure;
        if (status == .too_late) return .too_late;
        try operationStatus(.stream_abort, status_code);
        return .requested;
    }

    pub fn deinit(self: *Stream) Error!void {
        var diagnostic = emptyOwnedBytes();
        const status_code = self.parent.api.completionStreamDestroy()(
            self.raw,
            &diagnostic,
        );
        releaseOwned(self.parent.api, &diagnostic);
        try operationStatus(.stream_destroy, status_code);
        const parent = self.parent;
        const allocator = parent.allocator;
        std.debug.assert(parent.active_streams != 0);
        parent.active_streams -= 1;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const Operation = enum {
    create,
    destroy,
    describe,
    complete,
    stream_start,
    stream_next,
    stream_abort,
    stream_destroy,
};

const PreparedRequest = struct {
    allocator: std.mem.Allocator,
    messages: []wire.CompletionMessageV1,
    raw: wire.CompletionRequestV1,

    fn init(allocator: std.mem.Allocator, request: Request) Error!PreparedRequest {
        try validateRequest(request);
        const messages = try allocator.alloc(wire.CompletionMessageV1, request.messages.len);
        for (messages, request.messages) |*target, source| {
            target.* = std.mem.zeroes(wire.CompletionMessageV1);
            target.struct_size = @sizeOf(wire.CompletionMessageV1);
            target.role_code = switch (source.role) {
                .user => wire.COMPLETION_ROLE_USER,
                .assistant => wire.COMPLETION_ROLE_ASSISTANT,
            };
            target.text = sdk.bytesView(source.text);
        }
        var raw = std.mem.zeroes(wire.CompletionRequestV1);
        raw.struct_size = @sizeOf(wire.CompletionRequestV1);
        raw.messages = messages.ptr;
        raw.message_count = messages.len;
        raw.system = sdk.bytesView(request.system);
        return .{ .allocator = allocator, .messages = messages, .raw = raw };
    }

    fn deinit(self: *PreparedRequest) void {
        self.allocator.free(self.messages);
        self.* = undefined;
    }
};

fn validateConfig(config: Config) Error!void {
    if (config.credential.len == 0 or config.base_url.len == 0 or
        config.model.len == 0 or !std.unicode.utf8ValidateSlice(config.base_url) or
        !std.unicode.utf8ValidateSlice(config.model))
        return error.InvalidConfig;
    var total: usize = 0;
    total = std.math.add(usize, total, config.credential.len) catch
        return error.InvalidConfig;
    total = std.math.add(usize, total, config.base_url.len) catch
        return error.InvalidConfig;
    total = std.math.add(usize, total, config.model.len) catch
        return error.InvalidConfig;
    if (total > wire.MAX_COMPLETION_CONFIG_BYTES_V1) return error.InvalidConfig;
}

fn validateRequest(request: Request) Error!void {
    if (request.messages.len == 0 or
        request.messages.len > wire.MAX_COMPLETION_MESSAGES_V1 or
        !std.unicode.utf8ValidateSlice(request.system))
        return error.InvalidRequest;
    var total = request.system.len;
    for (request.messages) |message| {
        if (message.text.len == 0 or !std.unicode.utf8ValidateSlice(message.text))
            return error.InvalidRequest;
        total = std.math.add(usize, total, message.text.len) catch
            return error.InvalidRequest;
        if (total > wire.MAX_COMPLETION_REQUEST_BYTES_V1)
            return error.InvalidRequest;
    }
}

fn operationStatus(operation: Operation, status_code: u32) Error!void {
    const status = Status.fromCode(status_code) catch
        return error.DependencyContractFailure;
    if (status == .ok) return;
    if (!statusAllowed(operation, status)) return error.DependencyContractFailure;
    return switch (status) {
        .invalid_argument => error.InvalidArgument,
        .busy => error.Busy,
        .resource_limit => error.ResourceLimit,
        .completion_unsupported_response => error.UnsupportedResponse,
        else => error.CoreCallFailed,
    };
}

fn statusAllowed(operation: Operation, status: Status) bool {
    return switch (operation) {
        .create => switch (status) {
            .ok, .invalid_argument, .out_of_memory, .core_error, .internal_error, .resource_limit => true,
            else => false,
        },
        .destroy, .describe, .stream_destroy => switch (status) {
            .ok, .invalid_argument, .busy, .invalid_state, .core_error, .internal_error, .resource_limit => true,
            else => false,
        },
        .complete, .stream_start, .stream_next => switch (status) {
            .ok, .invalid_argument, .out_of_memory, .busy, .invalid_state, .core_error, .internal_error, .resource_limit, .completion_unsupported_response => true,
            else => false,
        },
        .stream_abort => switch (status) {
            .ok, .invalid_argument, .too_late, .invalid_state, .core_error, .internal_error => true,
            else => false,
        },
    };
}

fn eventKindFromCode(code: u32) error{UnknownEventKind}!EventKind {
    return switch (code) {
        wire.COMPLETION_EVENT_TEXT => .text,
        wire.COMPLETION_EVENT_THINKING => .thinking,
        wire.COMPLETION_EVENT_USAGE => .usage,
        wire.COMPLETION_EVENT_DONE => .done,
        else => error.UnknownEventKind,
    };
}

fn usageFromResult(value: wire.CompletionResultV1) Usage {
    return .{
        .input_tokens = value.input_tokens,
        .output_tokens = value.output_tokens,
        .cache_read_input_tokens = value.cache_read_input_tokens,
        .cache_creation_input_tokens = value.cache_creation_input_tokens,
    };
}

fn usageFromEvent(value: wire.CompletionEventV1) Usage {
    return .{
        .input_tokens = value.input_tokens,
        .output_tokens = value.output_tokens,
        .cache_read_input_tokens = value.cache_read_input_tokens,
        .cache_creation_input_tokens = value.cache_creation_input_tokens,
    };
}

fn copyOwnedUtf8(
    allocator: std.mem.Allocator,
    value: wire.OwnedBytesV1,
    maximum: u64,
) Error![]u8 {
    if (value.len > maximum or value.len > std.math.maxInt(usize) or
        (value.len == 0 and value.ptr != null))
        return error.DependencyContractFailure;
    const bytes = sdk.borrowedBytes(.{ .ptr = value.ptr, .len = value.len }) catch
        return error.DependencyContractFailure;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.DependencyContractFailure;
    return allocator.dupe(u8, bytes);
}

fn discardCompletion(api: sdk.Api, raw: *wire.CompletionHandle) void {
    var diagnostic = emptyOwnedBytes();
    _ = api.completionDestroy()(raw, &diagnostic);
    releaseOwned(api, &diagnostic);
}

fn discardStream(api: sdk.Api, raw: *wire.CompletionStreamHandle) void {
    var diagnostic = emptyOwnedBytes();
    _ = api.completionStreamDestroy()(raw, &diagnostic);
    releaseOwned(api, &diagnostic);
}

fn emptyOwnedBytes() wire.OwnedBytesV1 {
    return .{ .ptr = null, .len = 0 };
}

fn releaseOwned(api: sdk.Api, value: *wire.OwnedBytesV1) void {
    if (value.ptr != null or value.len != 0) api.bufferRelease()(value);
    value.* = emptyOwnedBytes();
}

fn allZero(values: []const u64) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

test "completion validates config and request before ABI calls" {
    try std.testing.expectError(error.InvalidConfig, validateConfig(.{
        .provider = .openai,
        .credential = "",
        .base_url = "https://example.test/v1/chat/completions",
        .model = "model",
    }));
    try std.testing.expectError(error.InvalidRequest, validateRequest(.{
        .messages = &.{},
    }));
    try validateConfig(.{
        .provider = .gemini,
        .credential = "secret",
        .base_url = "https://example.test",
        .model = "model",
    });
    try validateRequest(.{
        .system = "Be concise.",
        .messages = &.{.{ .role = .user, .text = "Hello" }},
    });
}

test "prepared completion request uses canonical role codes and zeroed reserved fields" {
    var prepared = try PreparedRequest.init(std.testing.allocator, .{
        .system = "system",
        .messages = &.{
            .{ .role = .user, .text = "question" },
            .{ .role = .assistant, .text = "answer" },
        },
    });
    defer prepared.deinit();
    try std.testing.expectEqual(@as(u64, 2), prepared.raw.message_count);
    try std.testing.expectEqual(wire.COMPLETION_ROLE_USER, prepared.messages[0].role_code);
    try std.testing.expectEqual(wire.COMPLETION_ROLE_ASSISTANT, prepared.messages[1].role_code);
    try std.testing.expect(allZero(&prepared.raw.reserved));
    try std.testing.expect(allZero(&prepared.messages[0].reserved));
    try std.testing.expect(allZero(&prepared.messages[1].reserved));
}

test "completion operation status sets reject unrelated ABI statuses" {
    try std.testing.expectError(
        error.DependencyContractFailure,
        operationStatus(.stream_next, wire.STATUS_STALE_RUN),
    );
    try std.testing.expectError(
        error.UnsupportedResponse,
        operationStatus(.stream_next, wire.STATUS_COMPLETION_UNSUPPORTED_RESPONSE),
    );
    try operationStatus(.stream_next, wire.STATUS_OK);
}

const TestCore = struct {
    var completion_storage: u8 = 0;
    var stream_storage: u8 = 0;
    var next_index: usize = 0;
    var stream_destroyed: bool = false;
    var completion_destroyed: bool = false;
    var release_count: usize = 0;

    fn reset() void {
        next_index = 0;
        stream_destroyed = false;
        completion_destroyed = false;
        release_count = 0;
    }

    fn completionHandle() *wire.CompletionHandle {
        return @ptrCast(&completion_storage);
    }

    fn streamHandle() *wire.CompletionStreamHandle {
        return @ptrCast(&stream_storage);
    }

    fn setOwned(target: *wire.OwnedBytesV1, bytes: []const u8) void {
        target.* = .{
            .ptr = if (bytes.len == 0) null else @constCast(bytes.ptr),
            .len = bytes.len,
        };
    }

    fn create(
        config: ?*const wire.CompletionConfigV1,
        out_completion: ?*?*wire.CompletionHandle,
        out_diagnostic: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        const value = config orelse return wire.STATUS_INVALID_ARGUMENT;
        if (value.struct_size != @sizeOf(wire.CompletionConfigV1) or
            value.provider_kind_code != wire.PROVIDER_OPENAI or
            !allZero(&value.reserved))
            return wire.STATUS_INVALID_ARGUMENT;
        if (out_completion) |output| output.* = completionHandle();
        if (out_diagnostic) |output| output.* = emptyOwnedBytes();
        return wire.STATUS_OK;
    }

    fn destroy(
        completion: ?*wire.CompletionHandle,
        out_diagnostic: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (completion != completionHandle() or !stream_destroyed)
            return wire.STATUS_INVALID_STATE;
        completion_destroyed = true;
        if (out_diagnostic) |output| output.* = emptyOwnedBytes();
        return wire.STATUS_OK;
    }

    fn describe(
        completion: ?*wire.CompletionHandle,
        out_info: ?*wire.CompletionInfoV1,
        out_diagnostic: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (completion != completionHandle()) return wire.STATUS_INVALID_ARGUMENT;
        const output = out_info orelse return wire.STATUS_INVALID_ARGUMENT;
        output.* = std.mem.zeroes(wire.CompletionInfoV1);
        output.struct_size = @sizeOf(wire.CompletionInfoV1);
        output.provider_kind_code = wire.PROVIDER_OPENAI;
        setOwned(&output.model, "test-model");
        if (out_diagnostic) |diagnostic| diagnostic.* = emptyOwnedBytes();
        return wire.STATUS_OK;
    }

    fn complete(
        completion: ?*wire.CompletionHandle,
        request: ?*const wire.CompletionRequestV1,
        out_result: ?*wire.CompletionResultV1,
        out_diagnostic: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (completion != completionHandle() or request == null)
            return wire.STATUS_INVALID_ARGUMENT;
        const output = out_result orelse return wire.STATUS_INVALID_ARGUMENT;
        output.* = std.mem.zeroes(wire.CompletionResultV1);
        output.struct_size = @sizeOf(wire.CompletionResultV1);
        output.stop_reason_code = wire.COMPLETION_STOP_END_TURN;
        setOwned(&output.text, "complete answer");
        output.input_tokens = 3;
        output.output_tokens = 2;
        if (out_diagnostic) |diagnostic| diagnostic.* = emptyOwnedBytes();
        return wire.STATUS_OK;
    }

    fn streamStart(
        completion: ?*wire.CompletionHandle,
        request: ?*const wire.CompletionRequestV1,
        out_stream: ?*?*wire.CompletionStreamHandle,
        out_diagnostic: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (completion != completionHandle() or request == null)
            return wire.STATUS_INVALID_ARGUMENT;
        if (out_stream) |output| output.* = streamHandle();
        if (out_diagnostic) |diagnostic| diagnostic.* = emptyOwnedBytes();
        return wire.STATUS_OK;
    }

    fn streamNext(
        stream: ?*wire.CompletionStreamHandle,
        out_event: ?*wire.CompletionEventV1,
        out_diagnostic: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (stream != streamHandle()) return wire.STATUS_INVALID_ARGUMENT;
        const output = out_event orelse return wire.STATUS_INVALID_ARGUMENT;
        output.* = std.mem.zeroes(wire.CompletionEventV1);
        output.struct_size = @sizeOf(wire.CompletionEventV1);
        if (next_index == 0) {
            output.kind_code = wire.COMPLETION_EVENT_TEXT;
            output.stop_reason_code = wire.COMPLETION_STOP_UNKNOWN;
            setOwned(&output.payload, "stream answer");
        } else {
            output.kind_code = wire.COMPLETION_EVENT_DONE;
            output.stop_reason_code = wire.COMPLETION_STOP_END_TURN;
            output.input_tokens = 4;
            output.output_tokens = 2;
        }
        next_index += 1;
        if (out_diagnostic) |diagnostic| diagnostic.* = emptyOwnedBytes();
        return wire.STATUS_OK;
    }

    fn streamAbort(
        stream: ?*wire.CompletionStreamHandle,
        reason_code: u32,
        out_diagnostic: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (stream != streamHandle() or reason_code != wire.ABORT_TIMEOUT)
            return wire.STATUS_INVALID_ARGUMENT;
        if (out_diagnostic) |diagnostic| diagnostic.* = emptyOwnedBytes();
        return wire.STATUS_TOO_LATE;
    }

    fn streamDestroy(
        stream: ?*wire.CompletionStreamHandle,
        out_diagnostic: ?*wire.OwnedBytesV1,
    ) callconv(.c) u32 {
        if (stream != streamHandle()) return wire.STATUS_INVALID_ARGUMENT;
        stream_destroyed = true;
        if (out_diagnostic) |diagnostic| diagnostic.* = emptyOwnedBytes();
        return wire.STATUS_OK;
    }

    fn bufferRelease(value: ?*wire.OwnedBytesV1) callconv(.c) void {
        const output = value orelse return;
        if (output.ptr != null or output.len != 0) release_count += 1;
        output.* = emptyOwnedBytes();
    }

    fn api() sdk.Api {
        var raw = std.mem.zeroes(wire.ApiV1);
        raw.completion_create = create;
        raw.completion_destroy = destroy;
        raw.completion_describe = describe;
        raw.completion_complete = complete;
        raw.completion_stream_start = streamStart;
        raw.completion_stream_next = streamNext;
        raw.completion_stream_abort = streamAbort;
        raw.completion_stream_destroy = streamDestroy;
        raw.buffer_release = bufferRelease;
        test_api = raw;
        return .{ .raw = &test_api };
    }

    var test_api: wire.ApiV1 = std.mem.zeroes(wire.ApiV1);
};

test "completion owns typed results and enforces stream-before-parent teardown" {
    TestCore.reset();
    const completion = try Completion.initWithValidatedApi(
        std.testing.allocator,
        TestCore.api(),
        .{
            .provider = .openai,
            .credential = "secret",
            .base_url = "https://example.test/v1/chat/completions",
            .model = "test-model",
        },
    );

    var info = try completion.describe();
    try std.testing.expectEqual(ProviderKind.openai, info.provider);
    try std.testing.expectEqualStrings("test-model", info.model);
    info.deinit();

    var result = try completion.complete(.{
        .messages = &.{.{ .role = .user, .text = "question" }},
    });
    try std.testing.expectEqualStrings("complete answer", result.text);
    try std.testing.expectEqual(StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u64, 3), result.usage.input_tokens);
    result.deinit();

    const stream = try completion.startStream(.{
        .messages = &.{.{ .role = .user, .text = "question" }},
    });
    try std.testing.expectError(error.StreamsOutstanding, completion.deinit());
    var text_event = try stream.next();
    try std.testing.expectEqual(EventKind.text, text_event.kind);
    try std.testing.expectEqualStrings("stream answer", text_event.payload);
    text_event.deinit();
    var done_event = try stream.next();
    try std.testing.expectEqual(EventKind.done, done_event.kind);
    try std.testing.expectEqual(StopReason.end_turn, done_event.stop_reason);
    try std.testing.expectEqual(@as(u64, 4), done_event.usage.input_tokens);
    done_event.deinit();
    try std.testing.expectEqual(AbortOutcome.too_late, try stream.abort(.timeout));
    try stream.deinit();
    try completion.deinit();

    try std.testing.expect(TestCore.stream_destroyed);
    try std.testing.expect(TestCore.completion_destroyed);
    try std.testing.expectEqual(@as(usize, 3), TestCore.release_count);
}

test "completion public surface is fully analyzed" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Completion);
    std.testing.refAllDecls(Stream);
}
