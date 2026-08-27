//! MetaWork-owned closed Provider identity shared by Agent execution and
//! independent Completion. AgentCore wire projection belongs to Session.

pub const ProviderKind = enum {
    anthropic,
    openai,
    gemini,
};

test "provider identity is a closed three-value union" {
    try @import("std").testing.expectEqual(@as(usize, 3), @typeInfo(ProviderKind).@"enum".fields.len);
}
