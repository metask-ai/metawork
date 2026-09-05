//! Communication protocols for a configured model service.
//! Product execution sources own service instances; Session owns AgentCore adapter selection.

/// MetaWork's wire protocols. Callers select one explicitly; endpoint and
/// model names never determine the protocol. AgentCore codes stay in Session.
pub const Protocol = enum {
    openai_responses,
    openai_chat_completions,
    anthropic_messages,
    gemini_native,
};
