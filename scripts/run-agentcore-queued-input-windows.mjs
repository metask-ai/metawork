// Focused desktop acceptance: reuse the canonical launcher and queue scenarios only.
process.env.METAWORK_QUEUED_INPUT_ONLY = "1";
await import("./run-agentcore-vertical-windows.mjs");
