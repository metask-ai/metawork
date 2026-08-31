const std = @import("std");
const provider = @import("agent_provider");

pub const max_config_bytes: usize = 16 * 1024;
pub const max_messages: usize = 4096;
pub const max_request_bytes: usize = 16 * 1024 * 1024;
pub const max_response_bytes: usize = 4 * 1024 * 1024;
pub const max_result_bytes: usize = 1024 * 1024;

pub const Role = enum {
    user,
    assistant,
};

pub const Config = struct {
    provider: provider.ProviderKind,
    protocol: provider.Protocol,
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
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

pub const StopReason = enum {
    end_turn,
    max_tokens,
    stop_sequence,
    refusal,
    content_filter,
};

pub const TransportFailure = enum {
    dns,
    connect,
    tls,
    write,
    read,
    invalid_http,
    other,
};

pub const RejectionCategory = enum {
    invalid_request,
    unauthorized,
    forbidden,
    not_found,
    rate_limited,
    provider_failure,
    other,
};

pub const ProviderRejection = struct {
    status: u16,
    category: RejectionCategory,
};

pub const Failure = union(enum) {
    invalid_config,
    invalid_request,
    cancelled,
    transport_failed: TransportFailure,
    provider_rejected: ProviderRejection,
    malformed_response,
    unsupported_response,
    resource_limit,
    out_of_memory,
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

pub const CompleteOutcome = union(enum) {
    result: Result,
    failure: Failure,
};

pub fn rejectionForStatus(status: u16) ProviderRejection {
    return .{
        .status = status,
        .category = switch (status) {
            400, 409, 422 => .invalid_request,
            401 => .unauthorized,
            403 => .forbidden,
            404 => .not_found,
            429 => .rate_limited,
            500...599 => .provider_failure,
            else => .other,
        },
    };
}

test "Completion result and error types are MetaWork-owned" {
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), max_response_bytes);
    try std.testing.expectEqual(
        RejectionCategory.rate_limited,
        rejectionForStatus(429).category,
    );
}
