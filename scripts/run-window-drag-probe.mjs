// A-stage manual harness. Builds the isolated public-SDK entry, records exact
// inputs/artifact identity, and launches it without injecting desktop input.
// Completion of this process is NOT a gesture/paint acceptance verdict.
import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { release } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { runChild } from "./run-child-process.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";
import { allocateWebViewTestPort } from "./window-top-resize-paint.mjs";

if (process.platform !== "win32")
  throw new Error("Windows-only native input probe");
const buildOnly = process.argv[2] === "--build-only";
if (process.argv.length !== (buildOnly ? 3 : 2))
  throw new Error(
    "usage: node scripts/run-window-drag-probe.mjs [--build-only]",
  );

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const execFileAsync = promisify(execFile);
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const git = async (...args) =>
  (
    await execFileAsync("git", args, {
      cwd: root,
      encoding: "buffer",
      maxBuffer: 16 * 1024 * 1024,
    })
  ).stdout;

async function sourceIdentity() {
  const untracked = (
    await git("ls-files", "--others", "--exclude-standard", "-z")
  )
    .toString()
    .split("\0")
    .filter(Boolean)
    .sort();
  return {
    revision: (await git("rev-parse", "HEAD")).toString().trim(),
    diff: (await git("diff", "--binary", "HEAD")).toString(),
    untracked: await Promise.all(
      untracked.map(async (file) => ({
        file,
        sha256: sha256(await readFile(path.join(root, file))),
      })),
    ),
  };
}

const before = await sourceIdentity();
const bundle = await verifyStagedAgentCoreBundle(root);
const runs = path.join(root, "zig-out", "drag-probe", "evidence");
await mkdir(runs, { recursive: true });
const evidence = await mkdtemp(path.join(runs, "manual-"));
// Each run retains its own artifact; never rebuild over an in-use executable.
const prefix = path.join(evidence, "artifact");
const args = [
  "build",
  `-Dtarget=${bundle.target}`,
  "-Doptimize=Debug",
  "-Dartifact=automation",
  "-Dautomation=true",
  "-Dwindow-chrome-probe=true",
  "--prefix",
  prefix,
  "--summary",
  "all",
];
await runChild("zig", args, {
  cwd: root,
  label: "Fixed native drag probe build",
  timeoutMs: null,
});
const after = await sourceIdentity();
if (JSON.stringify(before) !== JSON.stringify(after))
  throw new Error(
    "Source changed during build; do not attribute this artifact to an ambiguous input",
  );

const binary = path.join(prefix, "bin", "metawork-drag-probe.exe");
const port = await allocateWebViewTestPort();
await writeFile(path.join(evidence, "source.patch"), before.diff);
await writeFile(
  path.join(evidence, "identity.json"),
  JSON.stringify(
    {
      timestamp: new Date().toISOString(),
      revision: before.revision,
      diffSha256: sha256(before.diff),
      untracked: before.untracked,
      artifact: {
        binary,
        sha256: sha256(await readFile(binary)),
        buildArguments: args,
      },
      os: { release: release(), arch: process.arch },
      sdk: JSON.parse(
        await readFile(
          path.join(root, "node_modules/@native-sdk/cli/package.json"),
          "utf8",
        ),
      ).version,
      debugPort: port,
      launched: !buildOnly,
      acceptance:
        "unverified; manual inputs and their native/paint results must be recorded separately",
    },
    null,
    2,
  ),
);

if (buildOnly) {
  console.log(`Build-only evidence: ${evidence}; no desktop process launched.`);
} else {
  const child = spawn(binary, [], {
    cwd: path.dirname(binary),
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: {
      ...process.env,
      APPDATA: evidence,
      LOCALAPPDATA: evidence,
      WEBVIEW2_USER_DATA_FOLDER: path.join(evidence, "webview"),
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port} --remote-debugging-address=127.0.0.1`,
    },
  });
  // Register before any await; close also guarantees both log pipes were drained.
  const completion = new Promise((resolve) => {
    child.once("error", (error) => resolve({ error: error.message }));
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
    process.stdout.write(chunk);
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk;
    process.stderr.write(chunk);
  });
  console.log(
    `Evidence: ${evidence}\nProcess: ${child.pid}\nManual input only. Ctrl+Shift+Q exits; the probe has a 15-minute watchdog.`,
  );
  let outcome;
  try {
    // Reading the isolated endpoint records the actual runtime, not an installed
    // browser version guessed from a different process. No DOM/input injection.
    for (let attempt = 0; attempt < 30; attempt++) {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`, {
        signal: AbortSignal.timeout(500),
      }).catch(() => null);
      if (response?.ok) {
        await writeFile(
          path.join(evidence, "webview-version.json"),
          JSON.stringify(await response.json(), null, 2),
        );
        break;
      }
      if (!child.pid || child.exitCode !== null) break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    outcome = await completion;
  } finally {
    await writeFile(path.join(evidence, "stdout.log"), stdout);
    await writeFile(path.join(evidence, "stderr.log"), stderr);
    await writeFile(
      path.join(evidence, "process-result.json"),
      JSON.stringify({ ...outcome, acceptance: "unverified" }, null, 2),
    );
  }
  if (outcome.code !== 0)
    throw new Error(`Probe exited abnormally: ${JSON.stringify(outcome)}`);
}
