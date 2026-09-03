//! Product-owned anti-corruption adapter for the Agent execution boundary.
//!
//! Product Protocol is an admitted product capability; Agent Protocol is an
//! executable codec capability. Keep both enums independently owned and map
//! the admitted subset here exactly once.

const std = @import("std");
const agent = @import("metawork_agent");
const models_contract = @import("metawork_product_models_contract");

pub fn toAgent(protocol: models_contract.Protocol) agent.Protocol {
    return switch (protocol) {
        .openai_responses => .openai_responses,
        .openai_chat_completions => .openai_chat_completions,
        .anthropic_messages => .anthropic_messages,
        .gemini_native => .gemini_native,
    };
}

test "every admitted Product protocol maps to an explicit Agent codec" {
    try std.testing.expectEqual(
        agent.Protocol.openai_responses,
        toAgent(.openai_responses),
    );
    try std.testing.expectEqual(
        agent.Protocol.openai_chat_completions,
        toAgent(.openai_chat_completions),
    );
    try std.testing.expectEqual(
        agent.Protocol.anthropic_messages,
        toAgent(.anthropic_messages),
    );
    try std.testing.expectEqual(
        agent.Protocol.gemini_native,
        toAgent(.gemini_native),
    );
}
