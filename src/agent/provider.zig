//! MetaWork-owned closed Provider adapter shared by Agent execution and
//! independent Completion. AgentCore wire projection belongs to Session.

pub const ProviderKind = enum {
    anthropic,
    openai,
    gemini,
};

/// Explicit protocol selection, independent of endpoint or model names.
pub const Protocol = enum {
    /// Anthropic Messages, OpenAI Chat Completions or Gemini Native, selected
    /// by ProviderKind. This never infers a protocol from the configured URL.
    provider_default,
    openai_responses,

    pub fn validFor(self: Protocol, kind: ProviderKind) bool {
        return switch (self) {
            .provider_default => true,
            .openai_responses => kind == .openai,
        };
    }
};

test "provider identity is a closed three-value union" {
    try @import("std").testing.expectEqual(@as(usize, 3), @typeInfo(ProviderKind).@"enum".fields.len);
}
