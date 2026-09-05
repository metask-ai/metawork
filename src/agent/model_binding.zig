//! Borrowed model execution input shared by Agent entry points.
//!
//! Product authority, generations, catalog metadata, and ownership do not
//! cross this boundary. Each consumer applies its own lifetime policy.

const Protocol = @import("agent_protocol").Protocol;

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
    try @import("std").testing.expectEqualStrings(
        "fixture-provider",
        binding.target.provider_id,
    );
    try @import("std").testing.expectEqualStrings(
        "fixture-secret",
        binding.credential,
    );
}
