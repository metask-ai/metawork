import { fileURLToPath } from "node:url";
import path from "node:path";
import { runChild } from "./run-child-process.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const bundle = await verifyStagedAgentCoreBundle(repositoryRoot);
await runChild(
  "zig",
  [
    "build",
    "test-agentcore-sdk",
    `-Dtarget=${bundle.target}`,
    "-Doptimize=Debug",
  ],
  { cwd: repositoryRoot, label: "AgentCore SDK contract tests" },
);
