//! MetaWork-owned closed Provider adapter shared by Agent execution and
//! independent Completion. AgentCore wire projection belongs to Session.

pub const ProviderKind = enum {
    anthropic,
    openai,
    gemini,
};

/// MetaWork's wire protocols. Callers select one explicitly; endpoint and
/// model names never determine the protocol. AgentCore codes stay in Session.
pub const Protocol = enum {
    openai_responses,
    openai_chat_completions,
    anthropic_messages,
    gemini_native,

    pub fn validFor(self: Protocol, kind: ProviderKind) bool {
        return switch (self) {
            .openai_responses, .openai_chat_completions => kind == .openai,
            .anthropic_messages => kind == .anthropic,
            .gemini_native => kind == .gemini,
        };
    }
};

test "provider identity is a closed three-value union" {
    try @import("std").testing.expectEqual(@as(usize, 3), @typeInfo(ProviderKind).@"enum".fields.len);
}
