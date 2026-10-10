import { execFile, spawn } from "node:child_process";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rename,
  rm,
  symlink,
  unlink,
  writeFile,
} from "node:fs/promises";
import { release, tmpdir } from "node:os";
import path from "node:path";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { crc32 as pngCrc32, deflateSync } from "node:zlib";
import { buildAutomationDebugArtifact } from "./build.mjs";
import { verifyStagedAgentCoreBundle } from "./verify-staged-agentcore-bundle.mjs";
import { verifyAgentCoreRuntimeAssets } from "./agentcore-runtime-assets.mjs";
import {
  allocateWebViewTestPort,
  connectTestWebView,
} from "./window-top-resize-paint.mjs";
import { probeWindowChromeUi } from "./window-chrome-ui.mjs";
import { invokeWebViewBridge } from "./webview-bridge-probe.mjs";

const execFileAsync = promisify(execFile);
const root = fileURLToPath(new URL("../", import.meta.url));
const [targetId] = process.argv.slice(2);
if (
  process.argv.length > 3 ||
  (targetId !== undefined &&
    targetId !== "aarch64-macos" &&
    targetId !== "x86_64-macos")
)
  throw new Error(
    "usage: node scripts/test-agentcore-vertical-macos.mjs [aarch64-macos|x86_64-macos]",
  );
const bundleOptions = targetId ? { targetId } : undefined;
const native = path.join(
  root,
  "node_modules",
  "@native-sdk",
  "cli",
  "bin",
  "native.js",
);
const binary = path.join(
  root,
  "zig-out",
  "bin",
  process.platform === "win32" ? "metawork.exe" : "metawork",
);
const appCwd = process.env.METAWORK_TEST_APP_CWD
  ? path.resolve(root, process.env.METAWORK_TEST_APP_CWD)
  : root;
const automationDir = path.join(appCwd, ".zig-cache", "native-sdk-automation");
const visualCaptureDir = process.env.METAWORK_VISUAL_CAPTURE_DIR
  ? path.resolve(process.env.METAWORK_VISUAL_CAPTURE_DIR)
  : null;
const visualCaptureScript = path.join(
  root,
  "scripts",
  "capture-windows-window.ps1",
);
const macosWindowLookupScript = path.join(
  root,
  "scripts",
  "capture-macos-window.swift",
);
const windowsWebViewFocusProbeScript = path.join(
  root,
  "scripts",
  "probe-windows-webview-focus.ps1",
);
const windowsClipboardProbeScript = path.join(
  root,
  "scripts",
  "probe-windows-clipboard.ps1",
);

// This harness owns the artifact it drives. run-agentcore-vertical-windows.mjs
// builds the same artifact before importing this module and sets the flag so
// the automation Debug build does not run twice.
if (!process.env.METAWORK_VERTICAL_PREBUILT)
  await buildAutomationDebugArtifact(root, bundleOptions);
const bundle = await verifyStagedAgentCoreBundle(root, bundleOptions);
await verifyAgentCoreRuntimeAssets(bundle, path.dirname(binary));
// Exercise the shipped rg beside the Host, not an ambient development install.
const appEnvironment = { ...process.env };
for (const key of Object.keys(appEnvironment)) {
  if (key.toUpperCase() === "PATH" || key.toUpperCase() === "RG_BIN")
    delete appEnvironment[key];
}
appEnvironment.PATH =
  process.platform === "win32"
    ? [
        path.join(process.env.SystemRoot ?? "C:\\Windows", "System32"),
        path.join(
          process.env.SystemRoot ?? "C:\\Windows",
          "System32",
          "WindowsPowerShell",
          "v1.0",
        ),
      ].join(path.delimiter)
    : "/usr/bin:/bin";

const commandTimeoutMs = 20_000;
const runTimeoutMs = 60_000;
const workspace = await mkdtemp(join(tmpdir(), "metawork-agentcore-vertical-"));
const fixtureRoot = await realpath(workspace);
await mkdir(join(fixtureRoot, "work"));
const canonicalWorkspace = await realpath(join(fixtureRoot, "work"));
// Match production: owned originals live outside the Task's Workspace.
const platformHome = join(fixtureRoot, "platform-home");
await mkdir(platformHome, { recursive: true });
const automationDataDirectoryName = "MetaWork Automation";
const dataRoot =
  process.platform === "win32"
    ? join(platformHome, automationDataDirectoryName, "Data")
    : join(
        platformHome,
        "Library",
        "Application Support",
        automationDataDirectoryName,
      );
const isolatedPlatformEnv =
  process.platform === "win32"
    ? { APPDATA: platformHome, LOCALAPPDATA: platformHome }
    : { HOME: platformHome };
const relativeDataRoot = path.relative(fixtureRoot, dataRoot);
if (
  relativeDataRoot === "" ||
  relativeDataRoot === ".." ||
  relativeDataRoot.startsWith(`..${path.sep}`) ||
  path.isAbsolute(relativeDataRoot)
)
  throw new Error(`vertical data root escaped its fixture: ${dataRoot}`);
const fixturePath = join(canonicalWorkspace, "fixture.txt");
await writeFile(fixturePath, "agentcore-vertical-before\n", { mode: 0o600 });
// A valid 100 MB PNG exercises the same admission ceiling as the log. Its
// high-entropy pixels require a bounded preview and a >1 MiB checkpoint string.
const attachmentPngBytes = largePngFixture(1200, 900, 100_000_000);
const attachmentJpegBytes = Buffer.from(
  "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAaADAAQAAAABAAAAAQAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAAQABAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A+L6KKK/lM/38P//Z",
  "base64",
);
const attachmentPngPath = join(canonicalWorkspace, "reference.png");
const attachmentJpegPath = join(canonicalWorkspace, "brief.jpg");
await writeFile(attachmentPngPath, attachmentPngBytes, { mode: 0o600 });
await writeFile(attachmentJpegPath, attachmentJpegBytes, { mode: 0o600 });
const attachmentLogPath = join(canonicalWorkspace, "build.log");
const attachmentLogText =
  "LOG_START\n" + "x".repeat(100_000_000 - 18) + "\nLOG_END";
assert.equal(Buffer.byteLength(attachmentLogText), 100_000_000);
await writeFile(attachmentLogPath, attachmentLogText, { mode: 0o600 });
// Stay within the Native automation command budget.
const multimodalInstruction = "Compare the reference images and log.\n".padEnd(
  12 * 1024,
  "x",
);
const attachmentMetadata = [
  {
    kind: "image",
    format: "png",
    displayName: path.basename(attachmentPngPath),
    sizeBytes: String(attachmentPngBytes.length),
  },
  {
    kind: "image",
    format: "jpeg",
    displayName: path.basename(attachmentJpegPath),
    sizeBytes: String(attachmentJpegBytes.length),
  },
  {
    kind: "file",
    displayName: path.basename(attachmentLogPath),
    sizeBytes: String(Buffer.byteLength(attachmentLogText)),
  },
];
let retainedAttachmentPaths = [];

const windowsClipboard70 = clipboardMarkdownFixture(
  70 * 1024,
  "70K",
  "multimodal",
);
const streamingMarkdown256 = clipboardMarkdownFixture(
  256 * 1024,
  "256K",
  "text",
);
const windowsClipboard256 = streamingMarkdown256;
const windowsClipboard70Path = join(canonicalWorkspace, "clipboard-70k.md");
const windowsClipboard256Path = join(canonicalWorkspace, "clipboard-256k.md");
if (process.platform === "win32") {
  await writeFile(windowsClipboard70Path, windowsClipboard70, { mode: 0o600 });
  await writeFile(windowsClipboard256Path, windowsClipboard256, {
    mode: 0o600,
  });
}
// The real desktop must discover and run this Skill through a persisted fixed
// compatibility switch, not through a default source or a mock catalog.
const skillSourceDirectory = ".claude";
const skillDirectory = join(
  canonicalWorkspace,
  skillSourceDirectory,
  "skills",
  "review",
);
await mkdir(skillDirectory, { recursive: true });
await writeFile(
  join(skillDirectory, "SKILL.md"),
  [
    "---",
    "name: Review",
    "description: Exercise the real AgentCore typed Skill vertical",
    "arguments: [target]",
    "disable-model-invocation: true",
    "---",
    "METAWORK_TYPED_SKILL_VERTICAL",
    process.platform === "win32"
      ? "Review $target. Exercise Read, Write, Glob, Grep, Bash, Edit, BashOutput, and KillShell, then finish."
      : "Review $target. Exercise Read, Bash, and Edit, then finish.",
    "",
  ].join("\n"),
  { mode: 0o600 },
);
await rm(automationDir, { recursive: true, force: true });

const writtenPath = join(canonicalWorkspace, "agentcore-vertical-write.txt");
const responses = [
  streamedSse(
    toolSse(
      "m1",
      "read-1",
      "Read",
      { file_path: fixturePath },
      "I’m checking the workspace before making changes.",
    ),
    350,
  ),
  toolSse(
    "m2",
    "bash-1",
    "Bash",
    {
      command:
        process.platform === "win32"
          ? 'powershell -NoProfile -Command "Start-Sleep -Milliseconds 400; Write-Output agentcore-vertical-bash-ok"'
          : "sleep 0.4; echo agentcore-vertical-bash-ok",
      description: "Check the command output",
    },
    "I’ve checked the input; now I’m running a focused verification.",
  ),
  toolSse(
    "m3",
    "edit-1",
    "Edit",
    {
      file_path: fixturePath,
      old_string: "agentcore-vertical-before",
      new_string: "agentcore-vertical-after",
    },
    "The verification passed; now I’m applying the change.",
  ),
  ...(process.platform === "win32"
    ? [
        toolSse("m4", "write-1", "Write", {
          file_path: writtenPath,
          content: "agentcore-vertical-write\n",
        }),
        toolSse("m5", "glob-1", "Glob", {
          pattern: "*.txt",
          path: canonicalWorkspace,
        }),
        toolSse("m6", "grep-1", "Grep", {
          pattern: "agentcore-vertical-after",
          path: canonicalWorkspace,
        }),
        toolSse("m7", "bash-background-1", "Bash", {
          command: 'powershell -NoProfile -Command "Start-Sleep -Seconds 30"',
          description: "background lifecycle fixture",
        }),
        toolSseFromBackgroundJob("m8", "bash-output-1", "BashOutput", {
          max_bytes: 1024,
        }),
        toolSseFromBackgroundJob("m9", "kill-shell-1", "KillShell"),
      ]
    : []),
  streamedSse(
    textSse(
      process.platform === "win32" ? "m10" : "m4",
      "metawork agentcore vertical complete",
    ),
    350,
  ),
  async (payload) => {
    const logPath = await assertMultimodalProviderRequest(
      payload,
      multimodalInstruction,
    );
    return toolSse("attachment-read", "attachment-read-1", "Read", {
      file_path: logPath,
      offset: 1,
      limit: 1,
    });
  },
  (payload) => {
    const result = payload.messages
      ?.at(-1)
      ?.content?.find(
        (part) =>
          part.type === "tool_result" &&
          part.tool_use_id === "attachment-read-1",
      );
    assert.ok(result, "missing real attachment Read result");
    assert.equal(result.is_error ?? false, false, JSON.stringify(result));
    assert.ok(
      JSON.stringify(result.content).includes("LOG_START"),
      "Read did not return the original file's first line",
    );
    return textSse(
      process.platform === "win32" ? "m11" : "m5",
      process.platform === "win32"
        ? windowsClipboard70
        : "metawork multimodal checkpoint complete",
    );
  },
  streamedSse(
    textSseChunks(
      process.platform === "win32" ? "m12" : "m6",
      streamingMarkdown256,
      8 * 1024,
    ),
    80,
    1_500,
  ),
  textSse(
    process.platform === "win32" ? "m14" : "m8",
    "metawork compact checkpoint complete",
  ),
];
const provider = createProvider(responses, {
  initialDelayMs: visualCaptureDir ? 1_500 : 120,
  frameDelayMs: 80,
});
const baseUrl = await provider.listen();
const chromeProbePort =
  process.platform === "win32" ? await allocateWebViewTestPort() : null;
const chromeUiProbeEnabled =
  chromeProbePort !== null &&
  process.env.METAWORK_WINDOW_CHROME_WORKBENCH === "1";

let output = "";
let exitState = null;
let lastCheckpointObservation = null;
let app;
let exited;
startApplication();

try {
  await waitForBridge();
  await captureVisual("new-task", 1320, 812);
  await probeWindowsWebViewFocusWithColdProfileRetry();
  await captureVisual("search-keyboard", 1320, 812, false, true);
  const chosenWorkspace = await invokeBridge("metawork.workspaces.choose", {});
  let workspaceId;
  if (chosenWorkspace === null) {
    // Native SDK exposes one latest-response artifact for automation and the
    // live WebView. A product notification can replace that artifact before
    // the harness reads it, so never replay a mutation: reconcile from the
    // authoritative snapshot instead.
    const reconciled = await snapshot();
    const selected = reconciled.workspaces.find(
      (item) =>
        item.kind === "manual" && item.canonicalRoot === canonicalWorkspace,
    );
    if (!selected)
      throw new Error("Workspace choice had no response or committed state");
    workspaceId = selected.id;
  } else if (
    chosenWorkspace?.selected !== true ||
    !isWireId(chosenWorkspace.workspaceId)
  ) {
    throw new Error(
      `automation Workspace choice returned an invalid identity: ${JSON.stringify(chosenWorkspace)}`,
    );
  } else {
    workspaceId = chosenWorkspace.workspaceId;
  }
  const afterChoose = await snapshot();
  const selectedWorkspace = afterChoose.workspaces.find(
    (item) => item.id === workspaceId,
  );
  if (
    selectedWorkspace?.kind !== "manual" ||
    selectedWorkspace.authorization !== "available" ||
    selectedWorkspace.canonicalRoot !== canonicalWorkspace ||
    !isWireId(selectedWorkspace.epoch) ||
    selectedWorkspace.lastRemovalFailure !== null
  )
    throw new Error(
      `Workspace choice was not committed to the product snapshot: ${JSON.stringify(afterChoose.workspaces)}`,
    );
  const expectedWorkspaceEpoch = selectedWorkspace.epoch;
  const initialSources = afterChoose.skillManagement.sourceSettings;
  assert.equal(initialSources.health, "ready");
  assert.equal(initialSources.entries.length, 4);
  assert.ok(initialSources.entries.every((entry) => entry.enabled === false));
  let sourceRevision = initialSources.revision;
  // Exercise real reparse points on Windows (no symlink privilege required)
  // and directory symlinks on POSIX at both fixed-root components. A linked
  // enabled root must fail the entire scope, not silently omit that source.
  for (const component of [".codex", ".claude/skills"]) {
    const linkPath = path.join(canonicalWorkspace, component);
    const isOuter = component === ".codex";
    const sourceId = isOuter
      ? "compat.codex.workspace"
      : "compat.claude.workspace";
    const target = path.join(
      canonicalWorkspace,
      isOuter ? ".claude" : "linked-skill-target",
    );
    if (!isOuter) {
      // Keep the existing Skill fixture intact; only rename the test-owned
      // directory while checking its aliased root, then restore it exactly.
      await rename(path.join(canonicalWorkspace, ".claude/skills"), target);
    }
    await symlink(
      target,
      linkPath,
      process.platform === "win32" ? "junction" : "dir",
    );
    try {
      const enabled = await invokeBridge("metawork.skills.setSourceEnabled", {
        sourceId: isOuter ? "codex" : "claude",
        enabled: true,
        expectedRevision: sourceRevision,
      });
      assert.equal(enabled.applied, true);
      sourceRevision = enabled.revision;
      await poll(
        async () => {
          const current = await snapshot();
          const selected = current.workspaces.find(
            (item) => item.id === workspaceId,
          );
          const check = selected?.skillSourceDiscovery?.find(
            (entry) => entry.sourceId === sourceId,
          );
          if (check?.state !== "error") return null;
          assert.equal(check.reason, "unsupported_entry");
          assert.equal(selected.skillCatalog.availability, "unavailable");
          return true;
        },
        commandTimeoutMs,
        `linked fixed Skill root ${component}`,
      );
      const disabled = await invokeBridge("metawork.skills.setSourceEnabled", {
        sourceId: isOuter ? "codex" : "claude",
        enabled: false,
        expectedRevision: sourceRevision,
      });
      assert.equal(disabled.applied, true);
      sourceRevision = disabled.revision;
    } finally {
      await unlink(linkPath);
      if (!isOuter)
        await rename(target, path.join(canonicalWorkspace, ".claude/skills"));
    }
  }
  const sourceCommit = await invokeBridge("metawork.skills.setSourceEnabled", {
    sourceId: "claude",
    enabled: true,
    expectedRevision: sourceRevision,
  });
  assert.equal(sourceCommit.applied, true);
  const expectedExecutionGeneration =
    afterChoose.newTaskAdmission.activeGeneration;
  const expectedSelectionRevision =
    afterChoose.newTaskAdmission.activeSelectionRevision;
  if (!isWireId(expectedExecutionGeneration))
    throw new Error("snapshot omitted the current execution generation");
  if (!isWireId(expectedSelectionRevision))
    throw new Error("snapshot omitted the current selection revision");
  const catalogSnapshot = await poll(
    async () => {
      const current = await snapshot();
      const selected = current.workspaces.find(
        (item) => item.id === workspaceId,
      );
      const catalog = selected?.skillCatalog;
      if (
        (catalog?.availability !== "ready" &&
          catalog?.availability !== "degraded") ||
        !isOpaqueRevision(catalog.revision) ||
        !isWireId(catalog.selectionRevision)
      )
        throw new Error(
          `Workspace Skill catalog is not ready: ${JSON.stringify(catalog)}`,
        );
      const skill = catalog.skills.find(
        (item) => item.invocationName === "review",
      );
      if (!skill)
        throw new Error(
          `Workspace Skill catalog omitted review: ${JSON.stringify(catalog)}`,
        );
      return { catalog, skill };
    },
    commandTimeoutMs,
    "Workspace Skill catalog",
  );
  if (
    !/^[0-9a-f]{64}$/.test(catalogSnapshot.skill.skillId) ||
    catalogSnapshot.skill.displayName !== "Review" ||
    !catalogSnapshot.skill.argumentNames.includes("target")
  )
    throw new Error(
      `Workspace catalog omitted the review Skill projection: ${JSON.stringify(catalogSnapshot)}`,
    );
  const createResult = await invokeBridge("metawork.tasks.create", {
    workspace: {
      kind: "manual",
      workspaceId,
      expectedWorkspaceEpoch,
    },
    expectedExecutionGeneration,
    expectedSelectionRevision,
    modelSelection: null,
    expectedSkillCatalogRevision: catalogSnapshot.catalog.revision,
    expectedSkillSelectionRevision: catalogSnapshot.catalog.selectionRevision,
    approvalMode: "manual",
  });
  if (
    createResult !== null &&
    (createResult.accepted !== true ||
      createResult.reason !== null ||
      !isWireId(createResult.taskId) ||
      !isWireId(createResult.bindingEpoch))
  ) {
    throw new Error(
      `Task creation was not accepted truthfully: ${JSON.stringify(createResult)}`,
    );
  }
  const acceptedTaskId = createResult?.taskId ?? null;
  const createdTask = await poll(
    async () => {
      const current = await snapshot();
      return (
        current.tasks.find((item) =>
          acceptedTaskId
            ? item.id === acceptedTaskId
            : item.workspaceId === workspaceId,
        ) ?? null
      );
    },
    commandTimeoutMs,
    "Task creation",
  );
  const taskId = createdTask.id;
  const expectedBindingEpoch =
    createResult?.bindingEpoch ?? createdTask.binding?.epoch;
  if (!isWireId(taskId) || !isWireId(expectedBindingEpoch))
    throw new Error("Task creation omitted its authoritative identity");
  if (createdTask.binding?.epoch !== expectedBindingEpoch)
    throw new Error(
      `Task snapshot disagrees with the accepted binding epoch: ${JSON.stringify(createdTask.binding)}`,
    );
  const deliveryCountBeforeRun = productDeliveryEmitCount();
  if (chromeUiProbeEnabled) {
    const evidenceDir = process.env.METAWORK_WINDOW_CHROME_EVIDENCE_DIR;
    if (!evidenceDir)
      throw new Error("Workbench chrome probe requires an evidence directory");
    await mkdir(evidenceDir, { recursive: true });
    const git = async (...args) =>
      (
        await execFileAsync("git", args, {
          cwd: root,
          maxBuffer: 8 * 1024 * 1024,
        })
      ).stdout;
    const patch = await git("diff", "--binary", "HEAD");
    const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
    const untracked = (
      await git("ls-files", "--others", "--exclude-standard", "-z")
    )
      .split("\0")
      .filter(Boolean);
    await writeFile(path.join(evidenceDir, "source.patch"), patch);
    await writeFile(
      path.join(evidenceDir, "window-chrome-artifact.json"),
      JSON.stringify(
        {
          timestamp: new Date().toISOString(),
          revision: (await git("rev-parse", "HEAD")).trim(),
          status: await git("status", "--short"),
          diffSha256: sha256(patch),
          untracked: await Promise.all(
            untracked.map(async (file) => ({
              file,
              sha256: sha256(await readFile(path.join(root, file))),
            })),
          ),
          artifact: binary,
          artifactSha256: sha256(await readFile(binary)),
          os: {
            platform: process.platform,
            release: release(),
            arch: process.arch,
          },
          sdk: JSON.parse(
            await readFile(
              path.join(root, "node_modules/@native-sdk/cli/package.json"),
              "utf8",
            ),
          ).version,
          command: process.argv,
        },
        null,
        2,
      ),
    );
    await probeWindowsChromeUi();
  }
  // Disabling the source invalidates the Workspace current authority, but the
  // already-created Task must still execute its pinned Skill below.
  const sourceOff = await invokeBridge("metawork.skills.setSourceEnabled", {
    sourceId: "claude",
    enabled: false,
    expectedRevision: sourceCommit.revision,
  });
  assert.equal(sourceOff.applied, true);
  await poll(
    async () => {
      const current = await snapshot();
      const workspaceCatalog = current.workspaces.find(
        (item) => item.id === workspaceId,
      )?.skillCatalog;
      if (workspaceCatalog?.availability !== "ready") return null;
      assert.equal(
        workspaceCatalog.skills.some(
          (item) => item.invocationName === "review",
        ),
        false,
      );
      assert.equal(
        current.tasks.find((item) => item.id === taskId)?.skillCatalog.revision,
        catalogSnapshot.catalog.revision,
      );
      return true;
    },
    commandTimeoutMs,
    "disabled compatibility source with pinned Task",
  );
  const runSubmittedAfterUnixMs = Date.now() - 1_000;
  const runResult = await invokeBridge("metawork.tasks.run", {
    taskId,
    expectedBindingEpoch,
    input: {
      kind: "skill",
      skillId: catalogSnapshot.skill.skillId,
      catalogRevision: catalogSnapshot.catalog.revision,
      selectionRevision: catalogSnapshot.catalog.selectionRevision,
      argumentValues: ["fixture.txt"],
    },
  });
  if (
    runResult !== null &&
    (runResult.accepted !== true ||
      runResult.reason !== null ||
      runResult.taskId !== taskId ||
      !isWireId(runResult.runId))
  ) {
    throw new Error(
      `Run submission was not accepted truthfully: ${JSON.stringify(runResult)}`,
    );
  }
  const acceptedRunId = runResult?.runId ?? null;
  const submittedRun = await poll(
    async () => {
      const current = await snapshot();
      return (
        current.tasks
          .find((item) => item.id === taskId)
          ?.runs.find((item) =>
            acceptedRunId ? item.id === acceptedRunId : true,
          ) ?? null
      );
    },
    commandTimeoutMs,
    "Run submission",
  );
  const runId = submittedRun.id;
  if (!isWireId(runId)) throw new Error("Run submission omitted its identity");
  if (acceptedRunId !== null && submittedRun.id !== acceptedRunId)
    throw new Error("Run snapshot disagrees with the accepted Run identity");
  if (
    submittedRun.input?.kind !== "skill" ||
    submittedRun.input.skillId !== catalogSnapshot.skill.skillId ||
    submittedRun.input.catalogRevision !== catalogSnapshot.catalog.revision ||
    submittedRun.input.invocationName !== "review" ||
    submittedRun.input.displayName !== "Review" ||
    submittedRun.input.redacted !== false ||
    JSON.stringify(submittedRun.input.argumentValues) !==
      JSON.stringify(["fixture.txt"])
  )
    throw new Error(
      `Run history lost its typed Skill input: ${JSON.stringify(submittedRun.input)}`,
    );
  await captureVisual("running", 1320, 812, false, false, true);
  await captureVisual("running-narrow", 390, 812);
  let visualAttentionCaptured = false;
  const answered = new Set();
  const observedRunRevisions = new Map();
  const terminal = new Set([
    "completed",
    "stopped",
    "cancelled",
    "interrupted",
    "failed",
  ]);
  let finalSnapshot = await poll(
    async () => {
      if (provider.error) throw provider.error;
      const current = await snapshot();
      const task = current.tasks.find((item) => item.id === taskId);
      const run = task?.runs.find((item) => item.id === runId);
      if (!task || !run) return null;
      observeRunRevision(observedRunRevisions, current.revision, run);
      const pending = task.pendingUi;
      if (pending && !answered.has(pending.requestId)) {
        if (!visualAttentionCaptured) {
          await captureVisual("attention", 1320, 812);
          if (process.platform === "win32")
            await captureVisual("attention-inspector", 960, 680);
          visualAttentionCaptured = true;
        }
        if (typeof pending.redacted !== "boolean")
          throw new Error("pending UI omitted its projection privacy state");
        if (pending.runId !== runId)
          throw new Error(
            `pending UI routed to another run: ${JSON.stringify(pending)}`,
          );
        let responsePayload;
        if (pending.kind === "permission") {
          responsePayload = {
            taskId,
            runId,
            requestId: pending.requestId,
            kind: "permission",
            permission: "allow_once",
          };
        } else {
          throw new Error(
            `unexpected AgentCore vertical UI request: ${JSON.stringify(pending)}`,
          );
        }
        await invokeBridge("metawork.tasks.respondUi", responsePayload);
        await expectBridgeFailure(
          "metawork.tasks.respondUi",
          responsePayload,
          `duplicate UI response ${pending.requestId}`,
        );
        answered.add(pending.requestId);
      }
      if (terminal.has(run.phase)) return current;
      return null;
    },
    runTimeoutMs,
    "AgentCore run",
  );

  const fileChangesEvidence = await poll(
    async () => {
      const current = await snapshot();
      const currentTask = current.tasks.find((item) => item.id === taskId);
      const currentRun = currentTask?.runs.find((item) => item.id === runId);
      const modified = currentRun?.fileChanges?.changes.find(
        (item) =>
          item.kind === "modified" &&
          normalizedDisplayPath(item.displayPath).endsWith("/fixture.txt"),
      );
      if (
        current.capabilities?.typedFileChanges !== true ||
        currentRun?.fileChanges?.observation === "collecting" ||
        !modified?.diffAvailable
      )
        return null;
      return {
        snapshot: current,
        task: currentTask,
        run: currentRun,
        modified,
      };
    },
    commandTimeoutMs,
    "typed File Changes artifact",
  );
  finalSnapshot = fileChangesEvidence.snapshot;

  const task = finalSnapshot.tasks.find((item) => item.id === taskId);
  const run = task.runs.find((item) => item.id === runId);
  if (finalSnapshot.capabilities?.conversationRecovery !== true)
    throw new Error("checkpoint export did not expose conversation recovery");
  if (task.continuationAvailable !== true)
    throw new Error("completed Task did not remain available for continuation");
  if (run.phase !== "completed" || run.terminal?.outcome !== "completed")
    throw new Error(`run did not complete truthfully: ${JSON.stringify(run)}`);
  const submittedAtUnixMs = Number(run.submittedAtUnixMs);
  const finishedAtUnixMs = Number(run.finishedAtUnixMs);
  if (
    typeof run.submittedAtUnixMs !== "string" ||
    !Number.isSafeInteger(submittedAtUnixMs) ||
    submittedAtUnixMs <= 0 ||
    submittedAtUnixMs < runSubmittedAfterUnixMs ||
    submittedAtUnixMs > finishedAtUnixMs ||
    submittedAtUnixMs > Date.now() + 1_000
  )
    throw new Error(
      `run did not publish a credible submitted time: ${JSON.stringify(run.submittedAtUnixMs)}`,
    );
  if (
    typeof run.finishedAtUnixMs !== "string" ||
    !Number.isSafeInteger(finishedAtUnixMs) ||
    finishedAtUnixMs <= 0 ||
    Math.abs(Date.now() - finishedAtUnixMs) > 60_000
  )
    throw new Error(
      `run did not publish a credible terminal time: ${JSON.stringify(run.finishedAtUnixMs)}`,
    );
  assertFileChanges(run.fileChanges, process.platform === "win32");
  const fileChangeDiff = await invokeBridge("metawork.files.diff", {
    taskId,
    runId,
    fileChangeId: fileChangesEvidence.modified.id,
  });
  if (
    fileChangeDiff?.status !== "ready" ||
    fileChangeDiff.complete !== true ||
    typeof fileChangeDiff.redacted !== "boolean" ||
    !fileChangeDiff.content.includes("agentcore-vertical-before") ||
    !fileChangeDiff.content.includes("agentcore-vertical-after")
  )
    throw new Error(
      `typed File Changes diff was not served truthfully: ${JSON.stringify(fileChangeDiff)}`,
    );
  const runDeliveryEvents = productDeliveryEmitCount() - deliveryCountBeforeRun;
  if (chromeUiProbeEnabled) await probeWindowsChromeUi({ conversation: true });
  assertLiveRunRevisions(observedRunRevisions, run, runDeliveryEvents);
  await captureVisual("terminal", 1320, 812);
  await captureVisual("terminal-narrow", 390, 812);
  await captureVisual("bash-detail", 1320, 812, false, false, false, true);
  await captureVisual("bash-detail-narrow", 390, 812);
  await captureVisual("settings", 1320, 812, true);
  if (run.terminal?.cause !== null)
    throw new Error(
      `completed run retained a Host cause: ${JSON.stringify(task)}`,
    );
  if (
    !(run.output.commentary.join("") + run.output.response).includes(
      "metawork agentcore vertical complete",
    )
  )
    throw new Error("final assistant text was not projected");
  const checkpointTerminalObservedAt = Date.now();
  const checkpointEvidence = await poll(
    async () =>
      readCheckpointEvidence(taskId, "run", runId, expectedBindingEpoch),
    commandTimeoutMs,
    "durable checkpoint descriptor",
  ).catch((error) => {
    throw new Error(
      `${error.message}: ${JSON.stringify(lastCheckpointObservation)}`,
    );
  });
  checkpointEvidence.descriptorLatencyMs =
    Date.now() - checkpointTerminalObservedAt;
  process.stdout.write(
    `AgentCore checkpoint evidence: ${JSON.stringify({
      kind: "skill",
      byteSize: checkpointEvidence.byteSize,
      generation: checkpointEvidence.generation,
      descriptorLatencyMs: checkpointEvidence.descriptorLatencyMs,
      historyByteSize: checkpointEvidence.historyByteSize,
    })}\n`,
  );
  const activityOrders = [];
  const executedToolChecks =
    process.platform === "win32"
      ? [
          ["Read", "agentcore-vertical-before"],
          ["Bash", "agentcore-vertical-bash-ok"],
          ["Edit", ""],
          ["Write", ""],
          ["Glob", ""],
          ["Grep", ""],
          ["BashOutput", ""],
          ["KillShell", ""],
        ]
      : [
          ["Read", "agentcore-vertical-before"],
          ["Bash", "agentcore-vertical-bash-ok"],
          ["Edit", ""],
        ];
  for (const [name, evidence] of executedToolChecks) {
    const tool = run.tools.find((item) => item.name === name);
    if (!tool || tool.state !== "completed" || tool.isError)
      throw new Error(`${name} did not complete: ${JSON.stringify(tool)}`);
    if (!/^[1-9][0-9]*$/.test(tool.order))
      throw new Error(`${name} omitted its stable activity order`);
    activityOrders.push(tool.order);
    for (const field of [
      "inputTruncated",
      "progressTruncated",
      "contentTruncated",
      "redacted",
    ])
      if (typeof tool[field] !== "boolean")
        throw new Error(`${name} omitted projection safety flag ${field}`);
    if (evidence && !tool.content.includes(evidence))
      throw new Error(`${name} result omitted ${evidence}`);
    if (name === "Bash") {
      const raw = JSON.parse(tool.content);
      if (
        raw.schema_version !== "metacodes.bash-result.v2" ||
        tool.bash?.result?.exitCode !== 0 ||
        !tool.bash.result.stdout.includes("agentcore-vertical-bash-ok") ||
        tool.bash.description !== "Check the command output" ||
        tool.bash.result.stdoutIncomplete ||
        tool.bash.result.stderrIncomplete
      )
        throw new Error(
          "foreground Bash did not expose exact readable evidence",
        );
    }
  }
  if (
    process.platform === "win32" &&
    (await readFile(writtenPath, "utf8")) !== "agentcore-vertical-write\n"
  )
    throw new Error("Write did not materialize the expected file");
  if (/metawork\.product_delivery\.emit.*main_thread=false/.test(output))
    throw new Error(
      "ProductDelivery emitted a Renderer revision off the main thread",
    );
  if (!/metawork\.smoke\.event_ack.*main_thread=true/.test(output))
    throw new Error(
      "synchronous Renderer Bridge commands were not observed on the main thread",
    );
  if (/metawork\.smoke\.event_ack.*main_thread=false/.test(output))
    throw new Error(
      "a synchronous Renderer Bridge command ran off the main thread",
    );
  if (task.pendingUi !== null)
    throw new Error("completed run retained an actionable UI request");
  if (!Array.isArray(task.uiHistory) || task.uiHistory.length === 0)
    throw new Error("resolved UI requests were not retained in Task history");
  for (const record of task.uiHistory) {
    if (!/^[1-9][0-9]*$/.test(record.order))
      throw new Error("resolved UI request omitted its stable activity order");
    activityOrders.push(record.order);
  }
  if (new Set(activityOrders).size !== activityOrders.length)
    throw new Error("Run activity order was not unique");
  for (const requestId of answered)
    if (!task.uiHistory.some((item) => item.requestId === requestId))
      throw new Error(`resolved UI request ${requestId} was lost from history`);
  if (
    !task.uiHistory.some(
      (item) => item.kind === "permission" && item.state === "allowed_once",
    )
  )
    throw new Error("permission decision was not retained in Task history");
  const edited = await readFile(fixturePath, "utf8");
  if (edited !== "agentcore-vertical-after\n")
    throw new Error(
      `Edit did not update the workspace: ${JSON.stringify(edited)}`,
    );

  const refreshOff = await invokeBridge("metawork.tasks.refreshSkillCatalog", {
    taskId,
    expectedBindingEpoch,
  });
  assert.equal(refreshOff.accepted, true);
  await poll(
    async () => {
      const current = await snapshot();
      const pinned = current.tasks.find(
        (item) => item.id === taskId,
      )?.skillCatalog;
      return pinned?.availability === "ready" && pinned.skills.length === 0
        ? true
        : null;
    },
    commandTimeoutMs,
    "idle Task explicit refresh adopts disabled source",
  );
  const sourceOn = await invokeBridge("metawork.skills.setSourceEnabled", {
    sourceId: "claude",
    enabled: true,
    expectedRevision: sourceOff.revision,
  });
  assert.equal(sourceOn.applied, true);
  await poll(
    async () => {
      const current = await snapshot();
      const effective = current.workspaces.find(
        (item) => item.id === workspaceId,
      )?.skillCatalog;
      if (!effective?.skills.some((item) => item.invocationName === "review"))
        return null;
      assert.equal(
        current.tasks.find((item) => item.id === taskId)?.skillCatalog.skills
          .length,
        0,
      );
      return true;
    },
    commandTimeoutMs,
    "source reenabled without implicit Task rebinding",
  );
  const refreshOn = await invokeBridge("metawork.tasks.refreshSkillCatalog", {
    taskId,
    expectedBindingEpoch,
  });
  assert.equal(refreshOn.accepted, true);
  await poll(
    async () => {
      const current = await snapshot();
      return current.tasks
        .find((item) => item.id === taskId)
        ?.skillCatalog.skills.some((item) => item.invocationName === "review")
        ? true
        : null;
    },
    commandTimeoutMs,
    "idle Task adopts reenabled compatible Skill",
  );

  // The automation fixture intentionally shares home and Workspace. Cover
  // all four persisted switches here, including physical-root deduplication;
  // the canonical Agent suite separately covers distinct home/project roots.
  const codexSkill = join(
    canonicalWorkspace,
    ".codex",
    "skills",
    "codex-proof",
  );
  await mkdir(codexSkill, { recursive: true });
  await writeFile(
    join(codexSkill, "SKILL.md"),
    "---\nname: Codex proof\ndescription: Fixed-source discovery fixture\ndisable-model-invocation: true\n---\nA supported Skill from the Codex compatibility directory.\n",
    { mode: 0o600 },
  );
  const codexOn = await invokeBridge("metawork.skills.setSourceEnabled", {
    sourceId: "codex",
    enabled: true,
    expectedRevision: sourceOn.revision,
  });
  assert.equal(codexOn.applied, true);
  sourceRevision = codexOn.revision;
  await poll(
    async () => {
      const current = await snapshot();
      const project = current.workspaces.find(
        (item) => item.id === workspaceId,
      );
      if (
        current.skillCatalog.availability !== "ready" ||
        project?.skillCatalog.availability !== "ready"
      )
        return null;
      const expected = ["codex-proof", "review"];
      assert.deepEqual(
        current.skillCatalog.skills.map((skill) => skill.invocationName).sort(),
        expected,
      );
      assert.deepEqual(
        project.skillCatalog.skills.map((skill) => skill.invocationName).sort(),
        expected,
      );
      assert.ok(
        current.skillManagement.sourceSettings.entries.every(
          (entry) => entry.enabled === true,
        ),
      );
      for (const asset of current.skillManagement.assets) {
        assert.equal(
          asset.origin.scope,
          asset.scope.kind === "personal" ? "personal" : "project",
        );
        assert.equal(
          asset.canExport || asset.canReimport || asset.canUninstall,
          false,
        );
      }
      return true;
    },
    commandTimeoutMs,
    "all four fixed switches and source scopes",
  );

  const attachmentChoice = await invokeBridge(
    "metawork.attachments.choose",
    {},
  );
  assertAttachmentChoice(attachmentChoice, attachmentMetadata);
  const attachmentTokens = attachmentChoice.attachments.map(
    (attachment) => attachment.token,
  );
  const beforeMultimodalRunIds = new Set(task.runs.map((item) => item.id));
  const multimodalRunResult = await invokeBridge("metawork.tasks.run", {
    taskId,
    expectedBindingEpoch,
    input: {
      kind: "multimodal",
      text: multimodalInstruction,
      attachmentTokens,
    },
  });
  if (
    multimodalRunResult !== null &&
    (multimodalRunResult.accepted !== true ||
      multimodalRunResult.taskId !== taskId ||
      !isWireId(multimodalRunResult.runId))
  )
    throw new Error(
      `Multimodal Run was not accepted: ${JSON.stringify(multimodalRunResult)}`,
    );
  const acceptedMultimodalRunId = multimodalRunResult?.runId ?? null;
  const multimodalTerminal = await poll(
    async () => {
      if (provider.error) throw provider.error;
      const current = await snapshot();
      const currentRun = current.tasks
        .find((item) => item.id === taskId)
        ?.runs.find((item) =>
          acceptedMultimodalRunId
            ? item.id === acceptedMultimodalRunId
            : !beforeMultimodalRunIds.has(item.id),
        );
      return currentRun && terminal.has(currentRun.phase)
        ? { current, run: currentRun }
        : null;
    },
    runTimeoutMs,
    "Multimodal Run",
  );
  const multimodalRunId = multimodalTerminal.run.id;
  if (provider.error) throw provider.error;
  if (
    multimodalTerminal.run.phase !== "completed" ||
    !(
      multimodalTerminal.run.output.commentary.join("") +
      multimodalTerminal.run.output.response
    ).includes("metawork multimodal checkpoint complete")
  )
    throw new Error(
      `Multimodal Run did not complete: ${JSON.stringify(multimodalTerminal.run)}`,
    );
  assertMultimodalHistory(
    multimodalTerminal,
    attachmentTokens,
    attachmentMetadata,
  );
  await probeWindowsClipboard({
    taskId,
    expectedPath: windowsClipboard70Path,
    expectedBytes: 70 * 1024,
    marker: "CLIPBOARD_70K_END",
    expectedCode: 'const clipboardProbe = "70K";',
  });
  for (const token of attachmentTokens) {
    const released = await invokeBridge("metawork.attachments.release", {
      token,
    });
    if (released?.released !== false)
      throw new Error(
        `consumed attachment grant remained releasable: ${JSON.stringify(released)}`,
      );
  }
  const multimodalCheckpointObservedAt = Date.now();
  const multimodalCheckpoint = await poll(
    async () =>
      readCheckpointEvidence(
        taskId,
        "run",
        multimodalRunId,
        expectedBindingEpoch,
      ),
    commandTimeoutMs,
    "Multimodal durable checkpoint descriptor",
  );
  multimodalCheckpoint.descriptorLatencyMs =
    Date.now() - multimodalCheckpointObservedAt;
  await expectMissing(checkpointEvidence.blobPath);
  process.stdout.write(
    `AgentCore checkpoint evidence: ${JSON.stringify({
      kind: "multimodal",
      byteSize: multimodalCheckpoint.byteSize,
      generation: multimodalCheckpoint.generation,
      descriptorLatencyMs: multimodalCheckpoint.descriptorLatencyMs,
      historyByteSize: multimodalCheckpoint.historyByteSize,
    })}\n`,
  );

  const currentTask = multimodalTerminal.current.tasks.find(
    (item) => item.id === taskId,
  );
  const priorRunIds = new Set(currentTask.runs.map((item) => item.id));
  const deliveryCountBeforeTextRun = productDeliveryEmitCount();
  const textRunResult = await invokeBridge("metawork.tasks.run", {
    taskId,
    expectedBindingEpoch,
    input: {
      kind: "text",
      text: "Produce the streaming Markdown validation response.",
    },
  });
  if (
    textRunResult !== null &&
    (textRunResult.accepted !== true ||
      textRunResult.taskId !== taskId ||
      !isWireId(textRunResult.runId))
  )
    throw new Error(
      `Text checkpoint Run was not accepted: ${JSON.stringify(textRunResult)}`,
    );
  const acceptedTextRunId = textRunResult?.runId ?? null;
  const submittedTextRun = await poll(
    async () => {
      const current = await snapshot();
      return (
        current.tasks
          .find((item) => item.id === taskId)
          ?.runs.find((item) => !priorRunIds.has(item.id)) ?? null
      );
    },
    commandTimeoutMs,
    "Text checkpoint Run submission",
  );
  const textRunId = submittedTextRun.id;
  if (!isWireId(textRunId))
    throw new Error("Text checkpoint Run omitted its identity");
  if (acceptedTextRunId !== null && textRunId !== acceptedTextRunId)
    throw new Error(
      "Text checkpoint Run snapshot disagrees with its accepted identity",
    );
  const textDeliveryEvents = await poll(
    async () => {
      const count = productDeliveryEmitCount() - deliveryCountBeforeTextRun;
      return count >= 8 ? count : null;
    },
    runTimeoutMs,
    "Streaming Markdown ProductDelivery revisions",
  );
  const textTerminal = await poll(
    async () => {
      const current = await snapshot();
      const currentRun = current.tasks
        .find((item) => item.id === taskId)
        ?.runs.find((item) => item.id === textRunId);
      return currentRun && terminal.has(currentRun.phase)
        ? { current, run: currentRun }
        : null;
    },
    runTimeoutMs,
    "Text checkpoint Run",
  );
  if (
    textTerminal.run.phase !== "completed" ||
    Buffer.byteLength(textTerminal.run.output.response) !== 256 * 1024 ||
    !textTerminal.run.output.response.includes("CLIPBOARD_256K_END")
  )
    throw new Error(
      `Text checkpoint Run did not complete: ${JSON.stringify(textTerminal.run)}`,
    );
  process.stdout.write(
    `Streaming Markdown WebView evidence: ${JSON.stringify({ responseBytes: Buffer.byteLength(textTerminal.run.output.response), textDeliveryEvents })}\n`,
  );
  await probeWindowsClipboard({
    taskId,
    expectedPath: windowsClipboard256Path,
    expectedBytes: 256 * 1024,
    marker: "CLIPBOARD_256K_END",
  });
  const textCheckpointObservedAt = Date.now();
  const textCheckpoint = await poll(
    async () =>
      readCheckpointEvidence(taskId, "run", textRunId, expectedBindingEpoch),
    commandTimeoutMs,
    "Text durable checkpoint descriptor",
  );
  textCheckpoint.descriptorLatencyMs = Date.now() - textCheckpointObservedAt;
  await expectMissing(multimodalCheckpoint.blobPath);
  process.stdout.write(
    `AgentCore checkpoint evidence: ${JSON.stringify({
      kind: "text",
      byteSize: textCheckpoint.byteSize,
      generation: textCheckpoint.generation,
      descriptorLatencyMs: textCheckpoint.descriptorLatencyMs,
      historyByteSize: textCheckpoint.historyByteSize,
    })}\n`,
  );

  const compactResult = await invokeBridge("metawork.tasks.compact", {
    taskId,
    expectedBindingEpoch,
  });
  if (
    compactResult !== null &&
    (compactResult.accepted !== true ||
      compactResult.taskId !== taskId ||
      !isWireId(compactResult.operationId))
  )
    throw new Error(
      `checkpoint compact was not accepted: ${JSON.stringify(compactResult)}`,
    );
  const acceptedCompactId = compactResult?.operationId ?? null;
  const compactTerminalResult = await poll(
    async () => {
      const current = await snapshot();
      const compact = current.tasks
        .find((item) => item.id === taskId)
        ?.compacts.find((item) =>
          acceptedCompactId
            ? item.operationId === acceptedCompactId
            : item.afterRunId === textRunId,
        );
      return compact &&
        !["queued", "compacting", "stopping"].includes(compact.phase)
        ? { current, compact }
        : null;
    },
    runTimeoutMs,
    "checkpoint compact",
  );
  const compactTerminal = compactTerminalResult.compact;
  const compactId = compactTerminal.operationId;
  if (!["compacted", "no_change", "degraded"].includes(compactTerminal.phase))
    throw new Error(
      `checkpoint compact failed: ${JSON.stringify(compactTerminal)}`,
    );
  const compactCheckpointObservedAt = Date.now();
  const compactCheckpoint = await poll(
    async () =>
      readCheckpointEvidence(
        taskId,
        "compact",
        compactId,
        expectedBindingEpoch,
      ),
    commandTimeoutMs,
    "Compact durable checkpoint descriptor",
  );
  compactCheckpoint.descriptorLatencyMs =
    Date.now() - compactCheckpointObservedAt;
  await expectMissing(textCheckpoint.blobPath);
  process.stdout.write(
    `AgentCore checkpoint evidence: ${JSON.stringify({
      kind: "compact",
      byteSize: compactCheckpoint.byteSize,
      generation: compactCheckpoint.generation,
      descriptorLatencyMs: compactCheckpoint.descriptorLatencyMs,
      historyByteSize: compactCheckpoint.historyByteSize,
    })}\n`,
  );
  const expectedProviderResponses =
    compactTerminal.phase === "no_change"
      ? responses.length - 1
      : responses.length;
  if (provider.served !== expectedProviderResponses)
    throw new Error(
      `provider served ${provider.served}/${expectedProviderResponses} expected responses`,
    );
  if (provider.titleCompletions !== 1)
    throw new Error(
      `automatic title Completion served ${provider.titleCompletions}/1 responses`,
    );
  if (provider.error) throw provider.error;
  const providerInput = JSON.stringify(provider.requests);
  if (
    !providerInput.includes("METAWORK_TYPED_SKILL_VERTICAL") ||
    !providerInput.includes("fixture.txt")
  )
    throw new Error("provider did not receive the materialized Skill input");
  if (providerInput.includes("/review"))
    throw new Error("raw slash syntax reached the AgentCore provider");
  if (
    !providerInput.includes('"name":"WebSearch"') ||
    !providerInput.includes('"name":"WebFetch"')
  )
    throw new Error(
      "Desktop full profile did not expose WebSearch/WebFetch to AgentCore",
    );

  await invokeBridge("metawork.tasks.rename", {
    taskId,
    title: "AgentCore vertical release audit",
  });
  let metadataSnapshot = await snapshot();
  let metadataTask = metadataSnapshot.tasks.find((item) => item.id === taskId);
  if (metadataTask?.title !== "AgentCore vertical release audit")
    throw new Error("Task rename was not projected");
  await invokeBridge("metawork.tasks.archive", {
    taskId,
    archived: true,
  });
  metadataSnapshot = await snapshot();
  metadataTask = metadataSnapshot.tasks.find((item) => item.id === taskId);
  if (metadataTask?.archived !== true)
    throw new Error("Task archive was not projected");
  await invokeBridge("metawork.tasks.archive", {
    taskId,
    archived: false,
  });

  const transport = await automate("snapshot");
  assertTransport(transport.stdout);
  await stopApplication("checkpoint restart stop");
  await rm(compactCheckpoint.blobPath, { force: true });
  await rm(automationDir, { recursive: true, force: true });
  startApplication();
  await waitForBridge();
  const restoredSnapshot = await snapshot();
  const restoredTask = restoredSnapshot.tasks.find(
    (item) => item.id === taskId,
  );
  assert.equal(
    restoredSnapshot.skillManagement.sourceSettings.entries.every(
      (entry) => entry.enabled === true,
    ),
    true,
  );
  if (
    restoredSnapshot.capabilities?.conversationRecovery !== true ||
    restoredTask?.lifecycle !== "open" ||
    restoredTask.runs.length !== 3 ||
    restoredTask.compacts.length !== 1
  )
    throw new Error(
      `checkpoint restart changed product history or recovery gate: ${JSON.stringify({ restoredTask, tasks: restoredSnapshot.tasks, capabilities: restoredSnapshot.capabilities })}`,
    );
  const restoredMultimodalRun = restoredTask.runs.find(
    (item) => item.id === multimodalRunId,
  );
  if (!restoredMultimodalRun)
    throw new Error("checkpoint restart lost the multimodal Run");
  assertMultimodalHistory(
    { current: restoredSnapshot, run: restoredMultimodalRun },
    attachmentTokens,
    attachmentMetadata,
  );
  await assertRetainedOriginals(retainedAttachmentPaths);
  await poll(
    async () => {
      const health = await readCheckpointHealth(taskId);
      return health?.checkpoint === null &&
        health.checkpointAnchor === "blob_missing"
        ? health
        : null;
    },
    commandTimeoutMs,
    "missing checkpoint startup reconciliation",
  );
  await invokeBridge("metawork.tasks.archive", {
    taskId,
    archived: true,
  });
  await invokeBridge("metawork.tasks.delete", { taskId });
  const afterDelete = await snapshot();
  if (afterDelete.tasks.some((item) => item.id === taskId))
    throw new Error("Deleted Task record remained in the projection");
  for (const originalPath of retainedAttachmentPaths)
    await expectMissing(originalPath);
  await expectMissing(compactCheckpoint.blobPath);
  await stopApplication("app stop");

  process.stdout.write(
    process.platform === "win32"
      ? "AgentCore Windows desktop vertical passed: real Skill/multimodal/Text/compact checkpoints, 70 KiB and 256 KiB dual-format response clipboard plus plain-only code copy, ordered image provider input, metadata-only attachment history, typed File Changes/diff, hash/descriptor verification, missing-blob restart reconciliation, main-thread ProductDelivery, Runtime-owned tray routing, and clean shutdown; Windows Shell chrome/tray remain separate non-blocking gates.\n"
      : "AgentCore macOS desktop vertical passed: real Skill/multimodal/Text/compact checkpoints, ordered image provider input, metadata-only attachment history, typed File Changes/diff, hash/descriptor verification, missing-blob restart reconciliation, materialized arguments without raw slash, main-thread ProductDelivery, Read/Bash/Edit, permission UI, duplicate UI-response rejection, Task metadata lifecycle, Runtime-owned tray routing, and clean shutdown.\n",
  );
} catch (error) {
  process.stderr.write(`${output}\n`);
  throw error;
} finally {
  if (exitState === null) {
    app.kill("SIGTERM");
    await withTimeout(exited, 5_000, "forced app stop").catch(async () => {
      app.kill("SIGKILL");
      await withTimeout(exited, 5_000, "killed app stop");
    });
  }
  await provider.close();
  await removeWorkspaceWithRetry();
}

function startApplication() {
  exitState = null;
  app = spawn(binary, [], {
    cwd: appCwd,
    env: {
      ...appEnvironment,
      ...isolatedPlatformEnv,
      METAWORK_AUTOMATION: "1",
      METAWORK_AUTOMATION_WORKSPACE: canonicalWorkspace,
      METAWORK_AUTOMATION_ATTACHMENTS: [
        attachmentPngPath,
        attachmentJpegPath,
        attachmentLogPath,
      ].join("\n"),
      METAWORK_AGENTCORE_VERTICAL_PROVIDER_BASE_URL: baseUrl,
      ...(chromeProbePort === null
        ? {}
        : {
            WEBVIEW2_USER_DATA_FOLDER: join(platformHome, "chrome-webview"),
            WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${chromeProbePort} --remote-debugging-address=127.0.0.1`,
          }),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  app.stdout.setEncoding("utf8");
  app.stderr.setEncoding("utf8");
  app.stdout.on("data", (chunk) => {
    output += chunk;
  });
  app.stderr.on("data", (chunk) => {
    output += chunk;
  });
  exited = new Promise((resolve, reject) => {
    app.once("error", reject);
    app.once("exit", (code, signal) => {
      exitState = { code, signal };
      resolve(exitState);
    });
  });
}

async function stopApplication(label) {
  const stopEventsBefore = (output.match(/runtime\.event.*event="stop"/g) ?? [])
    .length;
  // Exercise the product's explicit Quit route on both platforms. The
  // built-in window Bridge is intentionally disabled, and closing a main
  // window whose policy is `hide` is not an application shutdown request.
  await automate("tray-action", "2");
  const final = await withTimeout(exited, commandTimeoutMs, label);
  if (final.code !== 0 || final.signal !== null)
    throw new Error(`app exited abnormally: ${JSON.stringify(final)}`);
  const stopEventsAfter = (output.match(/runtime\.event.*event="stop"/g) ?? [])
    .length;
  if (stopEventsAfter !== stopEventsBefore + 1)
    throw new Error("normal runtime stop was not observed");
}

function decodeTaskStore(bytes) {
  const magic = Buffer.from("MWTF");
  const headerBytes = 36;
  const records = { workspaces: [], tasks: [] };
  let offset = 0;
  while (offset < bytes.length) {
    if (
      offset + headerBytes > bytes.length ||
      !bytes.subarray(offset, offset + 4).equals(magic)
    )
      throw new Error("invalid hard-cut Task store frame");
    if (bytes[offset + 4] !== 0)
      throw new Error("invalid Task store frame flags");
    const kind = bytes[offset + 5];
    const payloadLength = bytes.readUInt32LE(offset + 24);
    const payloadStart = offset + headerBytes;
    const payloadEnd = payloadStart + payloadLength;
    if (payloadEnd > bytes.length)
      throw new Error("truncated Task store frame");
    const headerChecksum = bytes.readUInt32LE(offset + 28);
    const payloadChecksum = bytes.readUInt32LE(offset + 32);
    if (crc32(bytes.subarray(offset, offset + 28)) !== headerChecksum)
      throw new Error("invalid Task store header checksum");
    if (crc32(bytes.subarray(payloadStart, payloadEnd)) !== payloadChecksum)
      throw new Error("invalid Task store payload checksum");
    const value = JSON.parse(
      bytes.subarray(payloadStart, payloadEnd).toString("utf8"),
    );
    if (kind === 2) records.workspaces.push(value);
    if (kind === 3) records.tasks.push(value);
    offset = payloadEnd;
  }
  return records;
}

function crc32(bytes) {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++)
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function assertAttachmentChoice(actual, expected) {
  if (actual?.status !== "ready" || !Array.isArray(actual.attachments))
    throw new Error(
      `attachment choice did not return a ready batch: ${JSON.stringify(actual)}`,
    );
  assert.equal(actual.attachments.length, expected.length);
  assert.equal(
    new Set(actual.attachments.map((item) => item.token)).size,
    expected.length,
  );
  for (const [index, attachment] of actual.attachments.entries()) {
    assert.match(attachment.token, /^[0-9a-f]{48}$/);
    assert.deepEqual(
      {
        kind: attachment.kind,
        ...(attachment.kind === "image" ? { format: attachment.format } : {}),
        displayName: attachment.displayName,
        sizeBytes: attachment.sizeBytes,
      },
      expected[index],
    );
  }
}

async function assertMultimodalProviderRequest(payload, text) {
  const lastUser = payload.messages
    ?.filter((message) => message.role === "user")
    .at(-1);
  assert.equal(lastUser?.content?.length, 7);
  const [
    context,
    instruction,
    png,
    pngReference,
    jpeg,
    jpegReference,
    logReference,
  ] = lastUser.content;
  assert.equal(context.type, "text");
  assert.match(
    context.text,
    /^<system-reminder>[\s\S]*# metawork-time-context\n[\s\S]*<\/system-reminder>$/,
  );
  assert.match(
    context.text,
    /Run start time \(system local\): \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}|Run start time \(UTC\): \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z|Current time for this Run: unavailable\./,
  );
  assert.ok(
    context.text.includes(
      "Your knowledge cutoff does not indicate the current date.",
    ),
  );
  assert.deepEqual(instruction, { type: "text", text });
  for (const [index, image] of [png, jpeg].entries()) {
    assert.equal(image.type, "image");
    assert.equal(image.source.media_type, "image/png");
    const bytes = Buffer.from(image.source.data, "base64");
    assert.ok(
      bytes.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex")),
    );
    assert.ok(bytes.length <= 1_400_000);
    if (index === 0) {
      assert.ok(bytes.readUInt32BE(16) > 0 && bytes.readUInt32BE(16) < 1200);
      assert.ok(bytes.readUInt32BE(20) > 0 && bytes.readUInt32BE(20) < 900);
      assert.ok(
        image.source.data.length > 1024 * 1024,
        "fixture did not exercise the larger checkpoint string budget",
      );
    } else {
      assert.equal(bytes.readUInt32BE(16), 1);
      assert.equal(bytes.readUInt32BE(20), 1);
    }
  }
  const references = [pngReference, jpegReference, logReference];
  const originalPaths = references.map((reference, index) => {
    assert.equal(reference.type, "text");
    assert.match(reference.text, /Trust: untrusted reference data/);
    assert.ok(
      reference.text.includes(
        `size=${attachmentMetadata[index].sizeBytes} bytes`,
      ),
    );
    const encodedPath = reference.text.match(
      /file_path=("(?:[^"\\]|\\.)*")\. The original/,
    );
    assert.ok(encodedPath, "missing encoded original-file reference");
    const originalPath = JSON.parse(encodedPath[1]);
    const relative = path.relative(
      join(dataRoot, "workbench", "attachments"),
      originalPath,
    );
    assert.ok(
      relative !== "" &&
        !relative.startsWith("..") &&
        !path.isAbsolute(relative),
      "original escaped Task attachment store",
    );
    assert.ok(
      path.relative(canonicalWorkspace, originalPath).startsWith(".."),
      "fixture did not exercise reading an original outside the Workspace",
    );
    return originalPath;
  });
  await assertRetainedOriginals(originalPaths);
  retainedAttachmentPaths = originalPaths;
  assert.ok(
    [instruction, pngReference, jpegReference, logReference].reduce(
      (sum, part) => sum + part.text.length,
      0,
    ) <
      multimodalInstruction.length + 20 * 1024,
    "large log body was embedded in the prompt",
  );
  assert.ok(
    JSON.stringify(lastUser).length < 16 * 1024 * 1024,
    "prepared image input exceeded the SDK prompt budget",
  );
  return originalPaths[2];
}

async function assertRetainedOriginals(originalPaths) {
  assert.equal(originalPaths.length, 3);
  const originals = [
    attachmentPngBytes,
    attachmentJpegBytes,
    Buffer.from(attachmentLogText),
  ];
  for (let index = 0; index < originalPaths.length; index++) {
    const stored = await readFile(originalPaths[index]);
    assert.equal(
      createHash("sha256").update(stored).digest("hex"),
      createHash("sha256").update(originals[index]).digest("hex"),
      "retained original differs from the selected file",
    );
  }
}

function assertMultimodalHistory(result, attachmentTokens, expected) {
  assert.deepEqual(result.run.input, {
    kind: "multimodal",
    text: multimodalInstruction,
    attachments: expected.map((attachment) => ({
      ...attachment,
      redacted: false,
    })),
    redacted: false,
  });
  const encoded = JSON.stringify(result.run);
  assert.equal(
    encoded.includes(attachmentLogPath),
    false,
    "snapshot retained text file path",
  );
  assert.equal(
    encoded.includes("x".repeat(64 * 1024)),
    false,
    "snapshot automatically retained the full text file body",
  );

  for (const token of attachmentTokens)
    assert.equal(
      encoded.includes(token),
      false,
      "snapshot retained grant token",
    );
  assert.equal(
    encoded.includes(attachmentPngPath),
    false,
    "snapshot retained attachment path",
  );
  assert.equal(
    encoded.includes(attachmentJpegPath),
    false,
    "snapshot retained attachment path",
  );
  assert.equal(
    encoded.includes(attachmentPngBytes.subarray(0, 4096).toString("base64")),
    false,
    "snapshot retained attachment bytes",
  );
  assert.equal(
    encoded.includes(attachmentJpegBytes.toString("base64")),
    false,
    "snapshot retained attachment bytes",
  );
}

function largePngFixture(width, height, size) {
  function chunk(type, data) {
    const bytes = Buffer.alloc(data.length + 12);
    bytes.writeUInt32BE(data.length);
    bytes.write(type, 4, "ascii");
    data.copy(bytes, 8);
    bytes.writeUInt32BE(pngCrc32(bytes.subarray(4, -4)), bytes.length - 4);
    return bytes;
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  const pixels = Buffer.alloc((width * 4 + 1) * height);
  let state = 12345;
  for (let row = 0; row < height; row++) {
    for (let column = 0; column < width; column++) {
      const offset = row * (width * 4 + 1) + 1 + column * 4;
      for (let channel = 0; channel < 3; channel++) {
        state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
        pixels[offset + channel] = state >>> 24;
      }
      pixels[offset + 3] = 255;
    }
  }
  const image = [
    Buffer.from("89504e470d0a1a0a", "hex"),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(pixels)),
  ];
  const end = chunk("IEND", Buffer.alloc(0));
  const paddingSize =
    size - image.reduce((sum, item) => sum + item.length, 0) - end.length - 12;
  image.push(chunk("mwTa", Buffer.alloc(paddingSize, 120)), end);
  const result = Buffer.concat(image);
  assert.equal(result.length, size);
  return result;
}

async function readCheckpointHealth(taskId) {
  const historyPath = join(dataRoot, "workbench", "workbench-history.store");
  let bytes;
  try {
    bytes = await readFile(historyPath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  const history = decodeTaskStore(bytes);
  const task = history.tasks?.find((item) => String(item.id) === taskId);
  return task
    ? {
        checkpoint: task.checkpoint,
        checkpointAnchor: task.checkpoint_anchor,
      }
    : null;
}

async function readCheckpointEvidence(
  taskId,
  terminalKind,
  terminalId,
  bindingEpoch,
) {
  const historyPath = join(dataRoot, "workbench", "workbench-history.store");
  let historyBytes;
  try {
    historyBytes = await readFile(historyPath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  const history = decodeTaskStore(historyBytes);
  const task = history.tasks?.find((item) => String(item.id) === taskId);
  lastCheckpointObservation = task
    ? {
        anchor: task.checkpoint_anchor,
        hasDescriptor: task.checkpoint !== null,
      }
    : { task: "missing" };
  if (!task || task.checkpoint_anchor !== "available" || !task.checkpoint)
    return null;
  const descriptor = task.checkpoint;
  const blobDescriptor = descriptor.blob;
  const terminal = descriptor.anchor?.terminal;
  if (
    !blobDescriptor ||
    !descriptor.session ||
    !descriptor.anchor ||
    terminal?.kind !== terminalKind ||
    String(terminal.id) !== terminalId ||
    String(descriptor.anchor.binding_epoch) !== bindingEpoch ||
    !Number.isSafeInteger(blobDescriptor.generation) ||
    blobDescriptor.generation < 0 ||
    !Number.isSafeInteger(blobDescriptor.byte_size) ||
    blobDescriptor.byte_size <= 0 ||
    !/^[0-9a-f]{64}$/.test(blobDescriptor.digest)
  )
    throw new Error(
      `checkpoint descriptor is malformed: ${JSON.stringify(descriptor)}`,
    );
  const blobPath = join(
    dataRoot,
    "workbench",
    "checkpoints",
    String(task.id),
    `${blobDescriptor.generation}-${blobDescriptor.digest}.ckpt`,
  );
  let blob;
  try {
    blob = await readFile(blobPath);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
  const digest = createHash("sha256").update(blob).digest("hex");
  if (
    blob.length !== blobDescriptor.byte_size ||
    digest !== blobDescriptor.digest
  )
    throw new Error("checkpoint blob did not match its durable descriptor");
  return {
    blobPath,
    byteSize: blobDescriptor.byte_size,
    generation: blobDescriptor.generation,
    historyByteSize: historyBytes.length,
  };
}

async function expectMissing(filePath) {
  try {
    await readFile(filePath);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  throw new Error(`checkpoint blob survived Task deletion: ${filePath}`);
}

async function invokeBridge(command, payload) {
  if (chromeProbePort !== null) {
    const webview = await connectTestWebView(chromeProbePort, {
      requestTimeoutMs: commandTimeoutMs,
    });
    try {
      return await invokeWebViewBridge(webview, command, payload);
    } finally {
      webview.close();
    }
  }
  // macOS keeps the SDK automation path. Windows uses the real Renderer
  // request Promise because unrelated page responses share one SDK artifact.
  const id = `agentcore-vertical-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  let stopResponseWatch = false;
  const responseWatch = (async () => {
    const deadline = Date.now() + commandTimeoutMs;
    while (!stopResponseWatch && Date.now() < deadline) {
      try {
        const latest = JSON.parse(
          await readFile(join(automationDir, "bridge-response.txt"), "utf8"),
        );
        if (latest.id === id) return latest;
      } catch {
        // The artifact is atomically replaced and may not exist between runs.
      }
      await new Promise((resolve) => setTimeout(resolve, 1));
    }
    return null;
  })();
  let result;
  try {
    result = await automate("bridge", JSON.stringify({ id, command, payload }));
  } catch (error) {
    stopResponseWatch = true;
    await responseWatch;
    throw error;
  }
  const responses = result.stdout
    .trim()
    .split("\n")
    .reverse()
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
  let response = responses.find((value) => value.id === id) ?? null;
  if (response === null) response = await responseWatch;
  stopResponseWatch = true;
  await responseWatch;
  if (response && !response.ok) {
    const error = new Error(
      `${command} failed: ${JSON.stringify(response.error)}`,
    );
    error.bridgeCommand = command;
    error.bridgeResponseError = response.error;
    throw error;
  }
  return response?.result ?? null;
}

function productDeliveryEmitCount() {
  return (
    output.match(
      /metawork\.product_delivery\.emit event=metawork:workbench-changed main_thread=true/g,
    ) ?? []
  ).length;
}

function observeRunRevision(observations, revision, run) {
  if (!isWireId(revision))
    throw new Error(`Run observation omitted snapshot revision: ${revision}`);
  if (observations.has(revision)) return;
  observations.set(revision, {
    revision,
    phase: run.phase,
    activity: run.activity?.kind ?? null,
    commentaryBytes: Buffer.byteLength(run.output.commentary.join("")),
    provisionalBytes: Buffer.byteLength(run.output.provisional),
    responseBytes: Buffer.byteLength(run.output.response),
    tools: run.tools.map((tool) => ({ name: tool.name, state: tool.state })),
  });
}

function assertLiveRunRevisions(observations, terminalRun, deliveryEvents) {
  const observed = [...observations.values()];
  const preterminal = observed.filter((item) =>
    ["queued", "running", "waiting_ui", "stopping"].includes(item.phase),
  );
  const commentaryTransitions = preterminal.filter(
    (item, index) =>
      index === 0 ||
      item.commentaryBytes !== preterminal[index - 1].commentaryBytes,
  );
  const provisionalTransitions = preterminal.filter(
    (item, index) =>
      index === 0 ||
      item.provisionalBytes !== preterminal[index - 1].provisionalBytes,
  );
  const commentaryUpdates = commentaryTransitions.filter(
    (item) => item.commentaryBytes > 0,
  );
  for (let index = 1; index < observed.length; index += 1) {
    if (
      BigInt(observed[index - 1].revision) >= BigInt(observed[index].revision)
    )
      throw new Error(
        `Run snapshots did not advance monotonically: ${JSON.stringify(observed)}`,
      );
  }
  const hasActivity = (kind) =>
    preterminal.some((item) => item.activity === kind);
  const hasToolState = (state) =>
    preterminal.some((item) => item.tools.some((tool) => tool.state === state));
  if (
    deliveryEvents < 4 ||
    preterminal.length < 4 ||
    commentaryUpdates.length < 3 ||
    !hasActivity("executing_tools") ||
    !hasActivity("waiting_user") ||
    !hasToolState("running") ||
    !hasToolState("completed")
  )
    throw new Error(
      `Run did not expose sufficient preterminal presentation facts: ${JSON.stringify(observed)}`,
    );
  if (
    terminalRun.output.provisional !== "" ||
    terminalRun.output.responseKind !== "final" ||
    terminalRun.output.response.length === 0
  )
    throw new Error(
      `terminal Run did not settle live output into a final response: ${JSON.stringify(terminalRun.output)}`,
    );
  process.stdout.write(
    `AgentCore live revision evidence: ${JSON.stringify({
      observedRevisions: observed.length,
      preterminalRevisions: preterminal.length,
      deliveryEvents,
      activities: [...new Set(preterminal.map((item) => item.activity))],
      toolStates: [
        ...new Set(
          preterminal.flatMap((item) => item.tools.map((tool) => tool.state)),
        ),
      ],
      provisionalObserved: preterminal.some(
        (item) => item.provisionalBytes > 0,
      ),
      commentaryObserved: preterminal.some((item) => item.commentaryBytes > 0),
      commentaryUpdates: commentaryUpdates.length,
      commentaryTransitions: commentaryTransitions.map((item) => ({
        revision: item.revision,
        bytes: item.commentaryBytes,
      })),
      provisionalTransitions: provisionalTransitions.map((item) => ({
        revision: item.revision,
        bytes: item.provisionalBytes,
      })),
      preterminalSequence: preterminal.map((item) => ({
        revision: item.revision,
        activity: item.activity,
        commentaryBytes: item.commentaryBytes,
        provisionalBytes: item.provisionalBytes,
        tools: item.tools.map((tool) => `${tool.name}:${tool.state}`),
      })),
      textDeliveryGranularity: preterminal.some(
        (item) => item.provisionalBytes > 0,
      )
        ? "chunk"
        : "provider_message_boundary",
    })}\n`,
  );
}

async function expectBridgeFailure(command, payload, context) {
  try {
    await invokeBridge(command, payload);
  } catch {
    return;
  }
  throw new Error(`${context} was accepted`);
}

async function snapshot() {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await readSnapshot();
    } catch (error) {
      const stale =
        error?.bridgeCommand === "metawork.workbench.snapshot.chunk" &&
        error?.bridgeResponseError?.code === "handler_failed" &&
        error?.bridgeResponseError?.message === "StaleSnapshot";
      if ((!stale && error?.retryableSnapshotRead !== true) || attempt >= 2)
        throw error;
    }
  }
}

async function readSnapshot() {
  const descriptor = await invokeBridge("metawork.workbench.snapshot", {});
  if (descriptor === null) {
    const error = new Error("snapshot descriptor response was unavailable");
    error.retryableSnapshotRead = true;
    throw error;
  }
  if (
    !/^[1-9][0-9]*$/.test(descriptor.snapshotId) ||
    !Number.isSafeInteger(descriptor.bytes) ||
    descriptor.bytes <= 0 ||
    descriptor.bytes > 64 * 1024 * 1024 ||
    !Number.isSafeInteger(descriptor.chunkBytes) ||
    descriptor.chunkBytes <= 0 ||
    descriptor.chunkBytes > 256 * 1024
  )
    throw new Error(
      `invalid snapshot descriptor: ${JSON.stringify(descriptor)}`,
    );

  const assembled = Buffer.alloc(descriptor.bytes);
  for (
    let offset = 0;
    offset < descriptor.bytes;
    offset += descriptor.chunkBytes
  ) {
    const chunk = await invokeBridge("metawork.workbench.snapshot.chunk", {
      snapshotId: descriptor.snapshotId,
      offset: String(offset),
    });
    if (chunk === null) {
      const error = new Error("snapshot chunk response was unavailable");
      error.retryableSnapshotRead = true;
      throw error;
    }
    const expectedBytes = Math.min(
      descriptor.chunkBytes,
      descriptor.bytes - offset,
    );
    const decoded = Buffer.from(chunk?.data ?? "", "base64");
    if (
      chunk?.snapshotId !== descriptor.snapshotId ||
      chunk?.offset !== offset ||
      chunk?.bytes !== expectedBytes ||
      decoded.length !== expectedBytes
    )
      throw new Error(`invalid snapshot chunk: ${JSON.stringify(chunk)}`);
    decoded.copy(assembled, offset);
  }
  const encoded = assembled.toString("utf8");
  if (encoded.includes("metawork-agentcore-vertical-fixture-key"))
    throw new Error("Host provider credential reached the Renderer snapshot");
  const parsed = JSON.parse(encoded);
  if (
    typeof parsed.account !== "object" ||
    parsed.account === null ||
    Array.isArray(parsed.account) ||
    !Array.isArray(parsed.workspaces) ||
    !Array.isArray(parsed.tasks)
  )
    throw new Error("invalid Workbench snapshot");
  return parsed;
}

function isWireId(value) {
  return typeof value === "string" && /^[1-9][0-9]*$/.test(value);
}

function normalizedDisplayPath(value) {
  return `/${String(value).replaceAll("\\", "/").replace(/^\/+/, "")}`;
}

function assertFileChanges(fileChanges, requireCreated) {
  if (fileChanges?.observation !== "complete")
    throw new Error(
      `typed File Changes observation did not close completely: ${JSON.stringify(fileChanges)}`,
    );
  if (!Array.isArray(fileChanges.changes) || fileChanges.changes.length === 0)
    throw new Error("typed File Changes omitted its records");
  const ids = new Set();
  let previousOrder = 0n;
  for (const change of fileChanges.changes) {
    if (
      typeof change.id !== "string" ||
      change.id.length === 0 ||
      ids.has(change.id) ||
      !/^[1-9][0-9]*$/.test(change.order) ||
      BigInt(change.order) <= previousOrder ||
      !["created", "modified", "deleted", "moved"].includes(change.kind) ||
      !["applied", "partial"].includes(change.status) ||
      typeof change.displayPath !== "string" ||
      !/^(0|[1-9][0-9]*)$/.test(change.beforeBytes) ||
      !/^(0|[1-9][0-9]*)$/.test(change.afterBytes) ||
      typeof change.diffAvailable !== "boolean" ||
      typeof change.diffComplete !== "boolean" ||
      typeof change.redacted !== "boolean" ||
      (change.kind === "moved") !== (change.fromDisplayPath !== null)
    )
      throw new Error(
        `typed File Changes record violated its wire contract: ${JSON.stringify(change)}`,
      );
    ids.add(change.id);
    previousOrder = BigInt(change.order);
  }
  if (
    !fileChanges.changes.some(
      (change) =>
        change.kind === "modified" &&
        normalizedDisplayPath(change.displayPath).endsWith("/fixture.txt"),
    )
  )
    throw new Error("typed File Changes omitted the real Edit record");
  if (
    requireCreated &&
    !fileChanges.changes.some(
      (change) =>
        change.kind === "created" &&
        normalizedDisplayPath(change.displayPath).endsWith(
          "/agentcore-vertical-write.txt",
        ),
    )
  )
    throw new Error("typed File Changes omitted the real Write record");
}

function isOpaqueRevision(value) {
  return typeof value === "string" && value.length > 0;
}

async function automate(...args) {
  return execFileAsync(process.execPath, [native, "automate", ...args], {
    cwd: appCwd,
    timeout: commandTimeoutMs,
    maxBuffer: 1024 * 1024,
  });
}

async function probeWindowsChromeUi({ conversation = false } = {}) {
  await probeWindowChromeUi({
    port: chromeProbePort,
    hasTask: true,
    conversation,
    evidenceDir: process.env.METAWORK_WINDOW_CHROME_EVIDENCE_DIR,
    runProbe: async (mode, args = []) => {
      const result = await execFileAsync(
        "powershell.exe",
        [
          "-NoProfile",
          "-File",
          path.join(root, "scripts/probe-windows-window-chrome.ps1"),
          "-ProcessId",
          String(app.pid),
          "-Mode",
          mode,
          ...args,
        ],
        { timeout: commandTimeoutMs, maxBuffer: 1024 * 1024 },
      );
      process.stdout.write(result.stdout);
      return result.stdout;
    },
  });
}

async function probeWindowsClipboard({
  taskId,
  expectedPath,
  expectedBytes,
  marker,
  expectedCode = null,
}) {
  if (process.platform !== "win32") return;
  const webview = await connectTestWebView(chromeProbePort);
  try {
    await poll(
      async () => {
        const selection = await webview.evaluate(`(() => {
          const task = [...document.querySelectorAll('.task-list-item')]
            .find(candidate => candidate.dataset.taskId === ${JSON.stringify(taskId)});
          if (!task) return {ready:false, reason:'task_not_rendered'};
          if (task.getAttribute('aria-current') === 'page') return {ready:true};
          task.click();
          return {ready:false, reason:'selection_pending'};
        })()`);
        if (selection?.ready) return true;
        throw new Error(JSON.stringify(selection));
      },
      commandTimeoutMs,
      `Renderer Task ${taskId} selection`,
    );
    // Bind both controls to the same latest exchange. Measuring the code
    // control after response copying avoids stale points and older Run buttons.
    for (const kind of expectedCode === null
      ? ["response"]
      : ["response", "code"]) {
      const point = await poll(
        async () => {
          const observation = await webview.evaluate(`(() => {
            const buttons = document.querySelectorAll('.response-copy-action[data-latest="true"]');
            if (buttons.length !== 1) return {point:null, buttonCount:buttons.length};
            const response = buttons[0];
            const exchange = response.closest('.ai-exchange');
            const markerPresent = exchange?.textContent.includes(${JSON.stringify(marker)}) === true;
            if (!markerPresent) return {point:null, markerPresent};
            let button = response;
            if (${JSON.stringify(kind)} === 'code') {
              const codeButtons = [...exchange.querySelectorAll('.code-block-copy-action')]
                .filter(candidate => candidate.closest('.code-block-copyable')?.querySelector('pre')?.textContent.trimEnd() === ${JSON.stringify(expectedCode)});
              if (codeButtons.length !== 1) return {point:null, codeButtonCount:codeButtons.length};
              button = codeButtons[0];
            }
            button.scrollIntoView({block:'center', behavior:'instant'});
            const r = button.getBoundingClientRect();
            const x = r.x + r.width / 2, y = r.y + r.height / 2;
            const hit = document.elementFromPoint(x,y);
            // Code controls activate on native hover/focus. The wrapper must
            // be exposed here; UIA still requires an exact button hit after hover.
            const hitOwner = ${JSON.stringify(kind)} === 'code' ? button.closest('.code-block-copyable') : button;
            if (!r.width || !r.height || button.disabled || !hitOwner?.contains(hit))
              return {point:null, bounds:{x:r.x,y:r.y,width:r.width,height:r.height}, disabled:button.disabled, hit:hit?.tagName ?? null};
            return {point:{x, y, width:innerWidth, height:innerHeight}};
          })()`);
          if (observation?.point) return observation.point;
          throw new Error(JSON.stringify(observation));
        },
        commandTimeoutMs,
        `Latest ${kind} copy action`,
      );
      const args = [
        "-NoProfile",
        "-Sta",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        windowsClipboardProbeScript,
        "-ProcessId",
        String(app.pid),
        "-ExpectedPlainPath",
        expectedPath,
        "-ExpectedBytes",
        String(expectedBytes),
        "-Marker",
        marker,
        "-TargetClientX",
        String(point.x),
        "-TargetClientY",
        String(point.y),
        "-ViewportWidth",
        String(point.width),
        "-ViewportHeight",
        String(point.height),
      ];
      if (kind === "code")
        args.push("-CodeOnly", "-ExpectedCode", expectedCode);
      const { stdout } = await execFileAsync(
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        args,
        { timeout: commandTimeoutMs, maxBuffer: 1024 * 1024 },
      );
      process.stdout.write(`Windows clipboard evidence: ${stdout.trim()}\n`);
    }
  } finally {
    webview.close();
  }
}

async function captureVisual(
  name,
  width,
  height,
  openSettings = false,
  openSearch = false,
  selectFirstTask = false,
  openBashDetail = false,
) {
  if (visualCaptureDir === null) return;
  if (process.platform === "darwin" && (openSettings || openSearch)) return;
  if (process.platform !== "darwin" && process.platform !== "win32") return;
  await mkdir(visualCaptureDir, { recursive: true });
  if (process.platform === "darwin") {
    await automate("reload");
    await waitForBridge();
  } else {
    await automate("resize", String(width), String(height));
  }
  await new Promise((resolve) => setTimeout(resolve, 750));
  if (process.platform === "darwin") {
    const { stdout } = await execFileAsync("/usr/bin/xcrun", [
      "swift",
      macosWindowLookupScript,
      String(app.pid),
    ]);
    const windowId = stdout.trim();
    if (!/^[1-9][0-9]*$/.test(windowId))
      throw new Error(`could not resolve MetaWork window id: ${windowId}`);
    await execFileAsync("/usr/sbin/screencapture", [
      "-x",
      "-l",
      windowId,
      path.join(visualCaptureDir, `${name}.png`),
    ]);
    return;
  }
  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    visualCaptureScript,
    "-ProcessId",
    String(app.pid),
    "-OutputPath",
    path.join(visualCaptureDir, `${name}.png`),
    "-Width",
    String(width),
    "-Height",
    String(height),
  ];
  if (openSettings) args.push("-OpenSettings");
  if (selectFirstTask) {
    const webview = await connectTestWebView(chromeProbePort);
    let taskPoint;
    try {
      taskPoint = await webview.evaluate(`(() => {
        const row = document.querySelector('.task-list-item');
        if (!row) throw new Error('Task row missing during capture');
        const rect = row.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0 || rect.left < 0 || rect.right > innerWidth)
          throw new Error('Task row is not visible during capture');
        return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2, width: innerWidth, height: innerHeight };
      })()`);
    } finally {
      webview.close();
    }
    args.push(
      "-SelectFirstTask",
      "-TaskClientX",
      String(taskPoint.x),
      "-TaskClientY",
      String(taskPoint.y),
      "-ViewportWidth",
      String(taskPoint.width),
      "-ViewportHeight",
      String(taskPoint.height),
    );
  }
  if (openSearch) args.push("-OpenSearch");
  if (openBashDetail) args.push("-OpenBashDetail");
  await execFileAsync(
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    args,
    { timeout: commandTimeoutMs, maxBuffer: 1024 * 1024 },
  );
}

async function probeWindowsWebViewFocus() {
  if (process.platform !== "win32") return;
  const webview = await connectTestWebView(chromeProbePort);
  let composerName;
  try {
    composerName = await webview.evaluate(`(() => {
      const inputs = [...document.querySelectorAll('textarea[role="combobox"]')]
        .filter((input) => !input.disabled && input.getClientRects().length !== 0);
      if (inputs.length !== 1) throw new Error('Expected one editable Composer');
      return inputs[0].getAttribute('aria-label') || inputs[0].placeholder;
    })()`);
  } finally {
    webview.close();
  }
  if (!composerName) throw new Error("Composer has no accessible name");
  await new Promise((resolve, reject) => {
    const args = [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      windowsWebViewFocusProbeScript,
      "-ProcessId",
      String(app.pid),
      "-ComposerName",
      composerName,
    ];
    const child = spawn(
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
      args,
      { stdio: ["ignore", "pipe", "pipe"], windowsHide: true },
    );
    let diagnostic = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      diagnostic += chunk;
    });
    child.stderr.on("data", (chunk) => {
      diagnostic += chunk;
    });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error("Windows WebView focus probe timed out"));
    }, commandTimeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      if (code === 0 && signal === null) resolve();
      else
        reject(
          new Error(
            `Windows WebView focus probe failed: code=${code} signal=${signal}\n${diagnostic}`,
          ),
        );
    });
  });
}

async function probeWindowsWebViewFocusWithColdProfileRetry() {
  if (process.platform !== "win32") return;
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    try {
      await probeWindowsWebViewFocus();
      return;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError;
}

async function waitForBridge() {
  return poll(
    async () => {
      try {
        return await snapshot();
      } catch {
        return null;
      }
    },
    commandTimeoutMs,
    "Renderer bridge connection",
  );
}

async function poll(operation, milliseconds, label) {
  const deadline = Date.now() + milliseconds;
  let lastError = null;
  while (Date.now() < deadline) {
    if (exitState !== null)
      throw new Error(
        `app exited while waiting for ${label}: ${JSON.stringify(exitState)}`,
      );
    try {
      const value = await operation();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    if (provider.error) throw provider.error;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(
    `${label} timed out${lastError ? `: ${lastError.message}` : ""}`,
  );
}

async function removeWorkspaceWithRetry() {
  let lastError = null;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      await rm(workspace, { recursive: true, force: true });
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
  throw lastError;
}

function createProvider(queue, { initialDelayMs = 0, frameDelayMs = 0 } = {}) {
  let served = 0;
  let titleCompletions = 0;
  let providerError = null;
  const requests = [];
  const server = createServer((request, response) => {
    const chunks = [];
    let bytes = 0;
    request.on("data", (chunk) => {
      bytes += chunk.length;
      if (bytes <= 2 * 1024 * 1024) chunks.push(chunk);
    });
    request.on("end", async () => {
      try {
        if (bytes > 2 * 1024 * 1024)
          throw new Error(
            "provider request exceeded the AgentCore vertical fixture bound",
          );
        if (request.method !== "POST" || request.url !== "/v1/messages")
          throw new Error("AgentCore used an unexpected provider endpoint");
        const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (request.headers["x-api-key"] !== undefined) {
          if (
            request.headers["x-api-key"] !==
              "metawork-agentcore-vertical-fixture-key" ||
            request.headers.authorization !== undefined ||
            request.headers["anthropic-version"] !== "2023-06-01" ||
            payload.model !== "claude-sonnet-4-20250514" ||
            typeof payload.system !== "string" ||
            !payload.system.startsWith("Generate a concise title") ||
            !Array.isArray(payload.messages) ||
            payload.messages.length !== 1 ||
            payload.messages[0]?.role !== "user" ||
            payload.messages[0]?.content !== "Review"
          )
            throw new Error(
              "automatic title Completion did not preserve its frozen Anthropic request",
            );
          titleCompletions += 1;
          response.writeHead(200, {
            "content-type": "application/json",
            connection: "close",
          });
          response.end(
            JSON.stringify({
              type: "message",
              content: [{ type: "text", text: "Review fixture" }],
              stop_reason: "end_turn",
              usage: { input_tokens: 1, output_tokens: 1 },
            }),
          );
          return;
        }
        if (
          request.headers.authorization !==
          "Bearer metawork-agentcore-vertical-fixture-key"
        )
          throw new Error(
            `Host credential did not reach AgentCore correctly (${describeAuthorizationHeader(request.headers.authorization)}, x-api-key=${request.headers["x-api-key"] === undefined ? "absent" : "present"})`,
          );
        requests.push(payload);
        if (payload.model !== "claude-sonnet-4-20250514")
          throw new Error("Host model did not reach AgentCore correctly");
        const queued = queue[served];
        const fixture =
          typeof queued === "function"
            ? await queued(payload, requests)
            : queued;
        const body =
          typeof fixture === "string" ? fixture : (fixture?.body ?? null);
        if (!body) throw new Error("unexpected extra provider request");
        served += 1;
        response.writeHead(200, {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "close",
        });
        response.flushHeaders();
        response.socket?.setNoDelay(true);
        await streamProviderResponse(
          response,
          body,
          fixture?.initialDelayMs ?? initialDelayMs,
          fixture?.frameDelayMs ?? frameDelayMs,
        );
      } catch (error) {
        providerError ??= error;
        if (!response.headersSent) {
          response.writeHead(400, { "content-type": "application/json" });
          response.end(JSON.stringify({ error: "invalid fixture request" }));
        } else response.destroy(error);
      }
    });
  });
  return {
    get served() {
      return served;
    },
    get error() {
      return providerError;
    },
    get titleCompletions() {
      return titleCompletions;
    },
    get requests() {
      return requests;
    },
    listen() {
      return new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", () => {
          const address = server.address();
          resolve(`http://127.0.0.1:${address.port}/v1/messages`);
        });
      });
    },
    close() {
      return new Promise((resolve) => server.close(resolve));
    },
  };
}

async function streamProviderResponse(
  response,
  body,
  initialDelayMs,
  frameDelayMs,
) {
  if (initialDelayMs > 0)
    await new Promise((resolve) => setTimeout(resolve, initialDelayMs));
  const frames = body.match(/[\s\S]*?\n\n/g) ?? [];
  if (frames.join("") !== body)
    throw new Error("provider fixture produced an invalid SSE body");
  for (const frame of frames) {
    response.write(frame);
    if (frameDelayMs > 0)
      await new Promise((resolve) => setTimeout(resolve, frameDelayMs));
  }
  response.end();
}

function describeAuthorizationHeader(value) {
  if (value === undefined) return "authorization=absent";
  return `authorization=present,length=${value.length},bearer=${value.startsWith("Bearer ")}`;
}

function toolSse(messageId, toolId, name, input, commentary = null) {
  const events = [
    {
      type: "message_start",
      message: {
        id: messageId,
        role: "assistant",
        model: "fixture",
        usage: { input_tokens: 1, output_tokens: 1 },
      },
    },
  ];
  let toolIndex = 0;
  if (commentary !== null) {
    events.push(
      {
        type: "content_block_start",
        index: 0,
        content_block: { type: "text", text: "" },
      },
      {
        type: "content_block_delta",
        index: 0,
        delta: { type: "text_delta", text: commentary },
      },
      { type: "content_block_stop", index: 0 },
    );
    toolIndex = 1;
  }
  events.push(
    {
      type: "content_block_start",
      index: toolIndex,
      content_block: { type: "tool_use", id: toolId, name, input: {} },
    },
    {
      type: "content_block_delta",
      index: toolIndex,
      delta: { type: "input_json_delta", partial_json: JSON.stringify(input) },
    },
    { type: "content_block_stop", index: toolIndex },
    {
      type: "message_delta",
      delta: { stop_reason: "tool_use" },
      usage: { output_tokens: 1 },
    },
    { type: "message_stop" },
  );
  return sse(events);
}

function toolSseFromBackgroundJob(messageId, toolId, name, input = {}) {
  return (payload) => {
    const jobId = findJsonField(payload, "job_id");
    if (typeof jobId !== "string" || jobId.length === 0)
      throw new Error(
        `provider fixture did not receive a background job id for ${name}`,
      );
    return toolSse(messageId, toolId, name, { job_id: jobId, ...input });
  };
}

function findJsonField(value, field) {
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = findJsonField(item, field);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  if (value && typeof value === "object") {
    if (field in value) return value[field];
    for (const item of Object.values(value)) {
      const found = findJsonField(item, field);
      if (found !== undefined) return found;
    }
    return undefined;
  }
  if (typeof value === "string") {
    try {
      return findJsonField(JSON.parse(value), field);
    } catch {
      return undefined;
    }
  }
  return undefined;
}

function textSse(messageId, text) {
  return sse([
    {
      type: "message_start",
      message: {
        id: messageId,
        role: "assistant",
        model: "fixture",
        usage: { input_tokens: 1, output_tokens: 1 },
      },
    },
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text },
    },
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "end_turn" },
      usage: { output_tokens: 1 },
    },
    { type: "message_stop" },
  ]);
}

function textSseChunks(messageId, text, targetChunkBytes) {
  const chunks = [];
  let chunk = "";
  let chunkBytes = 0;
  for (const character of text) {
    const characterBytes = Buffer.byteLength(character);
    if (chunk && chunkBytes + characterBytes > targetChunkBytes) {
      chunks.push(chunk);
      chunk = "";
      chunkBytes = 0;
    }
    chunk += character;
    chunkBytes += characterBytes;
  }
  if (chunk) chunks.push(chunk);
  return sse([
    {
      type: "message_start",
      message: {
        id: messageId,
        role: "assistant",
        model: "fixture",
        usage: { input_tokens: 1, output_tokens: 1 },
      },
    },
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    ...chunks.map((value) => ({
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text: value },
    })),
    { type: "content_block_stop", index: 0 },
    {
      type: "message_delta",
      delta: { stop_reason: "end_turn" },
      usage: { output_tokens: 1 },
    },
    { type: "message_stop" },
  ]);
}

function clipboardMarkdownFixture(targetBytes, label, checkpointKind) {
  const prefix = [
    `# Clipboard ${label}`,
    "",
    `metawork ${checkpointKind} checkpoint complete`,
    "",
    "| target | result |",
    "| --- | --- |",
    "| editor | Markdown |",
    "| rich text | semantic HTML |",
    "",
    "```ts",
    `const clipboardProbe = \"${label}\";`,
    "```",
    "",
    `CLIPBOARD_${label}_BEGIN`,
    "",
  ].join("\n");
  const suffix = `\nCLIPBOARD_${label}_END`;
  const remaining =
    targetBytes - Buffer.byteLength(prefix) - Buffer.byteLength(suffix);
  if (remaining < 0) throw new Error("clipboard fixture target is too small");
  const markdown = `${prefix}${"x".repeat(remaining)}${suffix}`;
  if (Buffer.byteLength(markdown) !== targetBytes)
    throw new Error("clipboard fixture byte count is not exact");
  return markdown;
}

function sse(events) {
  return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
}

function streamedSse(body, frameDelayMs, initialDelayMs) {
  return { body, frameDelayMs, initialDelayMs };
}

function assertTransport(snapshot) {
  if (
    !/dispatch_errors=0/.test(snapshot) ||
    !/dropped_trace_records=0/.test(snapshot)
  )
    throw new Error(
      `automation snapshot reports transport errors:\n${snapshot}`,
    );
}

function withTimeout(promise, milliseconds, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${label} timed out`)),
      milliseconds,
    );
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
