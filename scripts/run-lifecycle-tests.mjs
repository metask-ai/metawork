import { fileURLToPath } from "node:url";
import path from "node:path";
import process from "node:process";
import { runChild } from "./run-child-process.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const bundle = await verifyStagedAgentCoreBundle(repositoryRoot);
const testFilter = process.env.LIFECYCLE_TEST_FILTER;
const zigArguments = [
  "build",
  "test-lifecycle",
  `-Dtarget=${bundle.target}`,
  "-Doptimize=Debug",
];
if (testFilter) zigArguments.push(`-Dtfilter=${testFilter}`);

await runChild("zig", zigArguments, {
  cwd: repositoryRoot,
  label: "Lifecycle tests",
});
