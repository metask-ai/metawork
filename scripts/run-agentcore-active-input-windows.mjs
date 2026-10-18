// Focused acceptance through the canonical Windows desktop launcher.
process.env.METAWORK_ACTIVE_INPUT_ONLY = "1";
await import("./run-agentcore-vertical-windows.mjs");
