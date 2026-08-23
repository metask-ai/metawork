//! Agent Provider identity；上游 SDK 补 typed enum 后，本模块改为别名或删除。

const sdk = @import("metask_agentcore");
const wire = sdk.types;

pub const ProviderKind = enum {
    anthropic,
    openai,
    gemini,
};

pub fn wireCode(value: ProviderKind) u32 {
    return switch (value) {
        .anthropic => wire.PROVIDER_ANTHROPIC,
        .openai => wire.PROVIDER_OPENAI,
        .gemini => wire.PROVIDER_GEMINI,
    };
}

pub fn fromWireCode(value: u32) error{UnknownProvider}!ProviderKind {
    return switch (value) {
        wire.PROVIDER_ANTHROPIC => .anthropic,
        wire.PROVIDER_OPENAI => .openai,
        wire.PROVIDER_GEMINI => .gemini,
        else => error.UnknownProvider,
    };
}

test "provider wire mapping is exhaustive" {
    inline for (.{
        ProviderKind.anthropic,
        ProviderKind.openai,
        ProviderKind.gemini,
    }) |value| {
        try @import("std").testing.expectEqual(value, try fromWireCode(wireCode(value)));
    }
}
