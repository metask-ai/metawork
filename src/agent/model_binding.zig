//! Borrowed model execution input shared by Agent entry points.
//!
//! Product authority, generations, catalog metadata, and ownership do not
//! cross this boundary. Each consumer applies its own lifetime policy.

const std = @import("std");
const Protocol = @import("agent_protocol").Protocol;

pub const max_provider_id_bytes: usize = 256;
pub const max_model_bytes: usize = 256;
pub const max_base_url_bytes: usize = 2048;
pub const max_credential_bytes: usize = 4096;

pub const EndpointPolicy = enum {
    required_explicit,
    optional_sdk_default,
};

pub const ValidationError = error{InvalidModelBinding};

pub const ModelTarget = struct {
    /// Opaque configured service instance reference; never sent to a provider.
    provider_id: []const u8,
    protocol: Protocol,
    base_url: []const u8,
    model: []const u8,
};

pub const ModelBinding = struct {
    target: ModelTarget,
    credential: []const u8,
};

pub fn validate(
    binding: ModelBinding,
    endpoint_policy: EndpointPolicy,
) ValidationError!void {
    try validateProviderId(binding.target.provider_id);
    try validateModel(binding.target.model);
    if (binding.credential.len == 0 or
        binding.credential.len > max_credential_bytes)
        return error.InvalidModelBinding;
    try validateEndpoint(binding.target.base_url, endpoint_policy);
}

pub fn validateModel(model: []const u8) ValidationError!void {
    if (model.len == 0 or model.len > max_model_bytes or
        !std.unicode.utf8ValidateSlice(model))
        return error.InvalidModelBinding;
}

fn validateProviderId(provider_id: []const u8) ValidationError!void {
    if (provider_id.len == 0 or provider_id.len > max_provider_id_bytes or
        !std.unicode.utf8ValidateSlice(provider_id))
        return error.InvalidModelBinding;
}

fn validateEndpoint(
    base_url: []const u8,
    endpoint_policy: EndpointPolicy,
) ValidationError!void {
    if (base_url.len == 0) return switch (endpoint_policy) {
        .required_explicit => error.InvalidModelBinding,
        .optional_sdk_default => {},
    };
    if (base_url.len > max_base_url_bytes or
        !std.unicode.utf8ValidateSlice(base_url))
        return error.InvalidModelBinding;
    const uri = std.Uri.parse(base_url) catch return error.InvalidModelBinding;
    if (uri.host == null or uri.user != null or uri.password != null or
        uri.query != null or uri.fragment != null)
        return error.InvalidModelBinding;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") and
        !loopbackHttp(uri)) return error.InvalidModelBinding;
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

test "model binding separates the non-secret target from its credential" {
    const binding: ModelBinding = .{
        .target = .{
            .provider_id = "fixture-provider",
            .protocol = .openai_responses,
            .base_url = "https://example.test/v1/responses",
            .model = "fixture-model",
        },
        .credential = "fixture-secret",
    };
    try std.testing.expectEqualStrings(
        "fixture-provider",
        binding.target.provider_id,
    );
    try std.testing.expectEqualStrings(
        "fixture-secret",
        binding.credential,
    );
}

test "model binding owns exact field limits and treats credential as opaque bytes" {
    var binding: ModelBinding = .{
        .target = .{
            .provider_id = "fixture-provider",
            .protocol = .openai_responses,
            .base_url = "https://example.test/v1/responses",
            .model = "fixture-model",
        },
        .credential = "fixture-secret",
    };

    var provider_id = [_]u8{'p'} ** max_provider_id_bytes;
    binding.target.provider_id = &provider_id;
    try validate(binding, .required_explicit);
    var oversized_provider_id = [_]u8{'p'} ** (max_provider_id_bytes + 1);
    binding.target.provider_id = &oversized_provider_id;
    try std.testing.expectError(
        error.InvalidModelBinding,
        validate(binding, .required_explicit),
    );
    binding.target.provider_id = "fixture-provider";

    var model = [_]u8{'m'} ** max_model_bytes;
    binding.target.model = &model;
    try validate(binding, .required_explicit);
    var oversized_model = [_]u8{'m'} ** (max_model_bytes + 1);
    binding.target.model = &oversized_model;
    try std.testing.expectError(
        error.InvalidModelBinding,
        validate(binding, .required_explicit),
    );
    binding.target.model = "fixture-model";

    var credential = [_]u8{0xff} ** max_credential_bytes;
    binding.credential = &credential;
    try validate(binding, .required_explicit);
    var oversized_credential = [_]u8{0xff} ** (max_credential_bytes + 1);
    binding.credential = &oversized_credential;
    try std.testing.expectError(
        error.InvalidModelBinding,
        validate(binding, .required_explicit),
    );
}

test "endpoint policy distinguishes explicit endpoints from SDK defaults" {
    var binding: ModelBinding = .{
        .target = .{
            .provider_id = "fixture-provider",
            .protocol = .anthropic_messages,
            .base_url = "",
            .model = "fixture-model",
        },
        .credential = "fixture-secret",
    };
    try validate(binding, .optional_sdk_default);
    try std.testing.expectError(
        error.InvalidModelBinding,
        validate(binding, .required_explicit),
    );

    var endpoint = [_]u8{'a'} ** max_base_url_bytes;
    @memcpy(endpoint[0.."https://a/".len], "https://a/");
    binding.target.base_url = &endpoint;
    try validate(binding, .required_explicit);
    var oversized_endpoint = [_]u8{'a'} ** (max_base_url_bytes + 1);
    @memcpy(oversized_endpoint[0.."https://a/".len], "https://a/");
    binding.target.base_url = &oversized_endpoint;
    try std.testing.expectError(
        error.InvalidModelBinding,
        validate(binding, .required_explicit),
    );
}
