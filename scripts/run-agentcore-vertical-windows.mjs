import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { buildAutomationDebugArtifact } from "./build.mjs";

if (process.platform !== "win32") {
  throw new Error("run-agentcore-vertical-windows.mjs requires Windows");
}

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

await buildAutomationDebugArtifact(root);

process.env.METAWORK_VERTICAL_PREBUILT = "1";
process.env.METAWORK_TEST_APP_CWD = path.join("zig-out", "bin");
await import("./test-agentcore-vertical-macos.mjs");
