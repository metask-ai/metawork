//! Communication protocols for a configured model service.
//! Account owns service instances; Session owns AgentCore adapter selection.

/// MetaWork's wire protocols. Callers select one explicitly; endpoint and
/// model names never determine the protocol. AgentCore codes stay in Session.
pub const Protocol = enum {
    openai_responses,
    openai_chat_completions,
    anthropic_messages,
    gemini_native,
};

/// Maximum UTF-8 byte length of the caller's opaque service instance reference.
/// Shared by Session, Completion and Probe; Account may impose a tighter bound.
pub const max_provider_id_bytes: usize = 256;
