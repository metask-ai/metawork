import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import { readProbeProductState } from "./probe-product-state.mjs";
import { readFixtureCheckpoint } from "./test-support/checkpoint-history.mjs";
import { execFile, spawn } from "node:child_process";
import assert from "node:assert/strict";
import { createReadStream, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import {
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  readdir,
  rename,
  rm,
  symlink,
  stat,
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
import { runApprovalModeVertical } from "./agentcore-approval-vertical.mjs";
import { runApprovalReadabilityVertical } from "./agentcore-approval-readability-vertical.mjs";
import { runActiveInputVertical } from "./agentcore-active-input-vertical.mjs";
import {
  runAutomaticFirstSkillVertical,
  runSkillAutoRefreshVertical,
} from "./skill-auto-refresh-vertical.mjs";
import { runTaskArchiveVertical } from "./task-archive-vertical.mjs";
import { runModelSwitchVertical } from "./agentcore-model-switch-vertical.mjs";
import { runModelErrorVertical } from "./agentcore-model-error-vertical.mjs";
import { runMcpLifecycleVertical } from "./mcp-lifecycle-vertical.mjs";
import { runNativeDialogsVertical } from "./native-dialogs-vertical.mjs";
import { runScheduledTasksVertical } from "./scheduled-tasks-vertical.mjs";
import {
  runOutputDeliveryVertical,
  runOfficeDeliveryHostProbe,
} from "./output-delivery-vertical.mjs";

import {
  runAttachmentCapacityVertical,
  verifyAttachmentBaselineArtifact,
} from "./attachment-capacity-vertical.mjs";

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
// An explicit prebuilt artifact lets isolated probes avoid replacing a user's
// development executable. Ordinary runs retain the standard build output.
const binary = process.env.METAWORK_TEST_APP_BINARY
  ? path.resolve(root, process.env.METAWORK_TEST_APP_BINARY)
  : path.join(
      root,
      "zig-out",
      "bin",
      process.platform === "win32" ? "metawork.exe" : "metawork",
    );
const appCwd = process.env.METAWORK_TEST_APP_CWD
  ? path.resolve(root, process.env.METAWORK_TEST_APP_CWD)
  : root;
const automationDir = path.join(appCwd, ".zig-cache", "native-sdk-automation");
const relativeAutomation = path.relative(root, path.resolve(automationDir));
if (
  !relativeAutomation ||
  relativeAutomation === ".." ||
  relativeAutomation.startsWith(`..${path.sep}`) ||
  path.isAbsolute(relativeAutomation)
)
  throw new Error("Automation cleanup target must stay inside this repository");
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
const attachmentBaseline =
  process.env.METAWORK_ATTACHMENT_BASELINE_ONLY === "1"
    ? await verifyAttachmentBaselineArtifact({
        prebuilt: process.env.METAWORK_VERTICAL_PREBUILT,
        binary: process.env.METAWORK_TEST_APP_BINARY ? binary : null,
        cwd: process.env.METAWORK_TEST_APP_CWD,
        expectedSha256: process.env.METAWORK_ATTACHMENT_BASELINE_SHA256,
      })
    : null;
if (!process.env.METAWORK_VERTICAL_PREBUILT)
  await buildAutomationDebugArtifact(root, bundleOptions);
const bundle = await verifyStagedAgentCoreBundle(root, bundleOptions);
const runtimeAssetOptions =
  process.platform === "darwin" &&
  path.basename(path.dirname(binary)) === "MacOS"
    ? {
        licenseDirectory: path.join(
          path.dirname(path.dirname(binary)),
          "Resources",
          "licenses",
        ),
      }
    : {};
await verifyAgentCoreRuntimeAssets(
  bundle,
  path.dirname(binary),
  runtimeAssetOptions,
);
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

assert.ok(
  ["win32", "darwin"].includes(process.platform),
  "Office desktop qualification requires a supported native platform",
);
const builtinSkillNames = ["docx", "pptx", "xlsx"];
const officeNamespace = JSON.parse(
  await readFile(join(root, "build_support/office-environment.json"), "utf8"),
).namespace.split("/");
const builtinOfficeOnly = process.env.METAWORK_BUILTIN_OFFICE_ONLY === "1";
const skillAutoRefreshOnly =
  process.env.METAWORK_SKILL_AUTO_REFRESH_ONLY === "1";

const nativeDialogsOnly = process.env.METAWORK_NATIVE_DIALOGS_ONLY === "1";
const commandTimeoutMs = 20_000;
const runTimeoutMs = 60_000;
const workspace = await mkdtemp(join(tmpdir(), "metawork-agentcore-vertical-"));
const fixtureRoot = await realpath(workspace);
if (
  path.dirname(fixtureRoot) !== (await realpath(tmpdir())) ||
  !path.basename(fixtureRoot).startsWith("metawork-agentcore-vertical-")
)
  throw new Error(
    "Temporary workspace cleanup target is outside the task fixture directory",
  );
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
// Stay within the Native automation command budget; the exact 256 KiB
// boundary is covered by Renderer/Bridge and Product lifecycle tests.
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
const readCommentaryObserved = observationGate();
const editCommentaryObserved = observationGate();
// Outside the Workspace so the verification handshake cannot become an
// apparent Agent-owned File Change.
const bashObservedPath = join(fixtureRoot, "bash-observed");
const bashObservationCommand =
  process.platform === "win32"
    ? `powershell -NoProfile -Command "while (-not (Test-Path -LiteralPath '${bashObservedPath.replaceAll("'", "''")}')) { Start-Sleep -Milliseconds 20 }; Write-Output agentcore-vertical-bash-ok"`
    : `while [ ! -f '${bashObservedPath.replaceAll("'", "'\\''")}' ]; do sleep 0.02; done; echo agentcore-vertical-bash-ok`;
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
  streamedSse(
    toolSse(
      "m2",
      "bash-1",
      "Bash",
      {
        command: bashObservationCommand,
        description: "Check the command output",
      },
      "I’ve checked the input; now I’m running a focused verification.",
    ),
    80,
    undefined,
    readCommentaryObserved.beforeFrame,
  ),
  streamedSse(
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
    80,
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
    undefined,
    editCommentaryObserved.beforeFrame,
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
  // CLI snapshot polling needs an observation window during this larger probe.
  initialDelayMs: visualCaptureDir ? 1_500 : 120,
  frameDelayMs: 80,
  titleInputs: skillAutoRefreshOnly
    ? ["docx", "first-message-review"]
    : ["Review"],
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
const attachmentCapacityOnly =
  process.env.METAWORK_ATTACHMENT_CAPACITY_ONLY === "1" ||
  process.env.METAWORK_ATTACHMENT_BASELINE_ONLY === "1";
const taskArchiveOnly = process.env.METAWORK_TASK_ARCHIVE_ONLY === "1";
const activeInputOnly = process.env.METAWORK_ACTIVE_INPUT_ONLY === "1";
const outputOnly = process.env.METAWORK_OUTPUT_VERTICAL_ONLY === "1";
const approvalReadabilityOnly =
  process.env.METAWORK_APPROVAL_READABILITY_ONLY === "1";
const approvalOnly =
  process.env.METAWORK_APPROVAL_ONLY === "1" || approvalReadabilityOnly;
if (
  skillAutoRefreshOnly &&
  (activeInputOnly ||
    outputOnly ||
    builtinOfficeOnly ||
    approvalOnly ||
    taskArchiveOnly)
)
  throw new Error(
    "Skill automatic refresh verification requires its own scope",
  );
if (approvalOnly && process.platform !== "win32")
  throw new Error("The approval-mode desktop audit currently requires Windows");
if (
  approvalOnly &&
  (activeInputOnly || outputOnly || builtinOfficeOnly || taskArchiveOnly)
)
  throw new Error("Approval-only verification cannot combine other scopes");
if (
  attachmentCapacityOnly &&
  (process.platform !== "darwin" ||
    [
      taskArchiveOnly,
      skillAutoRefreshOnly,
      activeInputOnly,
      outputOnly,
      builtinOfficeOnly,
      approvalOnly,
      process.env.METAWORK_SCHEDULE_ONLY === "1",
      process.env.METAWORK_MCP_ONLY === "1",
      process.env.METAWORK_MODEL_SWITCH_ONLY === "1",
    ].some(Boolean))
)
  throw new Error(
    "Attachment capacity verification requires its own macOS scope",
  );
startApplication();

desktopVertical: try {
  await waitForBridge();
  if (nativeDialogsOnly) {
    await runNativeDialogsVertical({
      invoke: invokeBridge,
      snapshot,
      poll,
      provider,
      textSse,
      toolSse,
      workspaceRoot: canonicalWorkspace,
      fixturePath,
      evidenceDir: path.join(root, ".zig-cache", "native-dialog-desktop"),
      automate,
      stop: () => stopApplication("native dialog shutdown"),
    });
    break desktopVertical;
  }
  if (process.env.METAWORK_MODEL_ERROR_ONLY === "1") {
    if (chromeProbePort === null)
      throw new Error(
        "Model-error WebView acceptance currently requires Windows",
      );
    await runModelErrorVertical({
      invoke: invokeBridge,
      runPrepared: invokePreparedRun,
      snapshot,
      poll,
      provider,
      connect: () => connectTestWebView(chromeProbePort),
      resize: resizeActiveInputVisualWindow,
      stop: () => stopApplication("model-error cold history stop"),
      restart: async () => {
        await rm(automationDir, { recursive: true, force: true });
        startApplication();
        await waitForBridge();
      },
      dataRoot,
      evidenceDir: path.join(root, ".zig-cache", "model-error-desktop"),
    });
    await stopApplication("model-error acceptance complete");
    break desktopVertical;
  }
  if (process.env.METAWORK_SCHEDULE_ONLY === "1") {
    await runScheduledTasksVertical({
      invoke: invokeBridge,
      snapshot,
      poll,
      provider,
      textSse,
      toolSse,
      dataRoot,
      evidenceDir: path.join(root, ".zig-cache", "schedule-desktop"),
      restart: async () => {
        await stopApplication("schedule restart");
        await rm(automationDir, { recursive: true, force: true });
        startApplication();
        await waitForBridge();
      },
    });
    await stopApplication("schedule verification complete");
    break desktopVertical;
  }
  if (process.env.METAWORK_MCP_ONLY === "1") {
    await runMcpLifecycleVertical({
      invoke: invokeBridge,
      snapshot,
      poll,
      provider,
      toolSse,
      textSse,
      repositoryRoot: root,
      fixtureRoot,
      evidenceDir: path.join(root, ".zig-cache", "mcp-lifecycle-desktop"),
      protocolVersion: process.env.METAWORK_MCP_PROTOCOL,
      transport: process.env.METAWORK_MCP_TRANSPORT,
    });
    await stopApplication("MCP lifecycle verification complete");
    break desktopVertical;
  }
  if (process.env.METAWORK_MODEL_SWITCH_ONLY === "1") {
    await verifyModelSwitch();
    await stopApplication("model switch verification complete");
    break desktopVertical;
  }
  if (skillAutoRefreshOnly) {
    await runAutomaticFirstSkillVertical({
      invoke: invokeBridge,
      snapshot,
      poll,
      provider,
      textSse,
      canonicalHome: canonicalWorkspace,
    });
  }
  if (
    !skillAutoRefreshOnly &&
    !activeInputOnly &&
    !outputOnly &&
    !builtinOfficeOnly &&
    !approvalOnly &&
    !taskArchiveOnly &&
    !attachmentCapacityOnly
  ) {
    await captureVisual("new-task", 1320, 812);
    await probeWindowsWebViewFocusWithColdProfileRetry();
    await captureVisual("search-keyboard", 1320, 812, false, true);
  }
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
  if (attachmentCapacityOnly) {
    const catalog = await poll(
      async () => {
        const current = (await snapshot()).workspaces.find(
          (item) => item.id === workspaceId,
        )?.skillCatalog;
        return current?.availability === "ready" ||
          current?.availability === "degraded"
          ? current
          : null;
      },
      commandTimeoutMs,
      "attachment capacity Workspace catalog",
    );
    await runAttachmentCapacityVertical({
      invoke: invokeBridge,
      snapshot,
      poll,
      provider,
      textSse,
      pid: app.pid,
      workspaceId,
      workspaceEpoch: expectedWorkspaceEpoch,
      workspaceRoot: canonicalWorkspace,
      catalog,
      evidenceDir: join(root, ".zig-cache", "attachment-issue76", "desktop"),
      pngFixture: largePngFixture,
      maxOriginalPath: attachmentPngPath,
      baselineOnly: process.env.METAWORK_ATTACHMENT_BASELINE_ONLY === "1",
      artifact: attachmentBaseline ?? {
        path: await realpath(binary),
        sha256: createHash("sha256")
          .update(await readFile(binary))
          .digest("hex"),
      },
    });
    await stopApplication("attachment capacity verification complete");
    break desktopVertical;
  }

  if (taskArchiveOnly) {
    const catalog = await poll(
      async () => {
        const scope = (await snapshot()).workspaces.find(
          (item) => item.id === workspaceId,
        )?.skillCatalog;
        return scope?.availability === "ready" ||
          scope?.availability === "degraded"
          ? scope
          : null;
      },
      commandTimeoutMs,
      "Task archive Workspace catalog",
    );
    const audit = await runTaskArchiveVertical({
      invoke: invokeBridge,
      snapshot,
      poll,
      provider,
      textSse,
      toolSse,
      workspaceId,
      workspaceEpoch: expectedWorkspaceEpoch,
      workspaceRoot: canonicalWorkspace,
      catalog,
    });
    await stopApplication("Task archive cold restart");
    await rm(automationDir, { recursive: true, force: true });
    startApplication();
    await waitForBridge();
    await audit.verifyRestart();
    await writeFile(
      join(root, ".zig-cache/task-archive-vertical-evidence.json"),
      JSON.stringify(
        { ...audit.evidence, binary, core: bundle.manifest?.version ?? null },
        null,
        2,
      ),
    );
    if (process.env.METAWORK_TASK_ARCHIVE_UI_HOLD === "1") {
      const releaseFile = join(root, ".zig-cache/task-archive-ui-release");
      await rm(releaseFile, { force: true });
      await writeFile(
        join(root, ".zig-cache/task-archive-vertical-session.json"),
        JSON.stringify(
          {
            pid: app.pid,
            binary,
            appCwd,
            automationDir,
            workspaceRoot: canonicalWorkspace,
            archivedTaskId: audit.evidence.archivedTaskId,
            uiTaskId: audit.evidence.uiTaskId,
          },
          null,
          2,
        ),
      );
      process.stdout.write(
        "Task archive host vertical passed; isolated App awaits UI verification.\n",
      );
      await poll(
        async () => {
          try {
            await readFile(releaseFile);
            return true;
          } catch {
            return false;
          }
        },
        600_000,
        "Task archive UI verification release",
      );
    }
    await stopApplication("Task archive verification complete");
    process.stdout.write(
      "Task archive desktop Host vertical passed: direct idle/running/permission-wait deletion, archive/restore, source preservation and cold restart. UI gestures require separate evidence.\n",
    );
    break desktopVertical;
  }
  if (outputOnly) {
    assert.equal(process.platform, "win32");
    const catalog = await poll(
      async () => {
        const selected = (await snapshot()).workspaces.find(
          (item) => item.id === workspaceId,
        );
        return selected?.skillCatalog.availability === "ready"
          ? selected.skillCatalog
          : null;
      },
      commandTimeoutMs,
      "Output Workspace catalog",
    );
    await runOutputDeliveryVertical({
      workspaceRoot: canonicalWorkspace,
      workspaceId,
      workspaceEpoch: expectedWorkspaceEpoch,
      catalog,
      invoke: invokeBridge,
      snapshot,
      poll,
      provider,
      toolSse,
      textSse,
      nativeOutputProbe:
        process.env.METAWORK_OUTPUT_NATIVE === "1"
          ? async ({ mode, source, destination, trigger }) => {
              const args = [
                "-NoProfile",
                "-NonInteractive",
                "-File",
                join(root, "scripts/probe-windows-output-native.ps1"),
                "-ProcessId",
                String(app.pid),
                "-ExpectedExecutable",
                binary,
                "-WorkspaceRoot",
                canonicalWorkspace,
                "-SourcePath",
                source,
                "-Mode",
                mode,
              ];
              if (destination) args.push("-Destination", destination);
              const child = spawn("powershell.exe", args, {
                cwd: root,
                windowsHide: true,
                stdio: ["ignore", "pipe", "pipe"],
              });
              let output = "",
                errors = "",
                readyResolve,
                readyReject;
              const ready = new Promise((resolve, reject) => {
                readyResolve = resolve;
                readyReject = reject;
              });
              child.stdout.on("data", (chunk) => {
                output += chunk.toString("utf8");
                if (output.length > 65536) {
                  child.kill();
                  readyReject(
                    new Error(
                      "Native output probe exceeded its capture budget",
                    ),
                  );
                }
                for (const line of output.split(/\r?\n/)) {
                  try {
                    if (JSON.parse(line).phase === "ready") readyResolve();
                  } catch {}
                }
              });
              child.stderr.on("data", (chunk) => {
                errors += chunk.toString("utf8");
                if (errors.length > 65536) child.kill();
              });
              const finished = new Promise((resolve, reject) => {
                child.once("error", reject);
                child.once("close", (code, signal) => {
                  if (code !== 0 || signal !== null)
                    reject(
                      new Error(
                        `Native output probe failed: ${code}/${signal}: ${errors}\n${output}`,
                      ),
                    );
                  else resolve();
                });
              });
              void finished.catch(readyReject);
              const timer = setTimeout(() => child.kill(), 40_000);
              try {
                await ready;
                await Promise.all([trigger(), finished]);
                return JSON.parse(output.trim().split(/\r?\n/).at(-1));
              } finally {
                clearTimeout(timer);
                if (child.exitCode === null && child.signalCode === null) {
                  child.kill();
                  await finished.catch(() => undefined);
                }
              }
            }
          : undefined,
      connectWebView: () =>
        connectTestWebView(chromeProbePort, {
          requestTimeoutMs: commandTimeoutMs,
        }),
      restart: async () => {
        await stopApplication("Output cold restart");
        await rm(automationDir, { recursive: true, force: true });
        startApplication();
        await waitForBridge();
      },
      evidenceDirectory: join(
        root,
        process.env.METAWORK_OUTPUT_NATIVE === "1"
          ? ".zig-cache/output-native-desktop"
          : ".zig-cache/output-delivery-desktop",
      ),
    });
    await stopApplication("Output desktop verification complete");
    process.stdout.write(
      `Output Windows desktop vertical passed: real Core delivery, Renderer checks/edit draft, cold history and source preservation${process.env.METAWORK_OUTPUT_NATIVE === "1" ? ", native Save As/cancel/overwrite protection and exact Explorer selection" : ""}.\n`,
    );
    break desktopVertical;
  }
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
  const readCatalog = () =>
    poll(
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
  let catalogSnapshot = await readCatalog();
  if (builtinSkillNames.length > 0) {
    for (const name of builtinSkillNames) {
      const office = catalogSnapshot.catalog.skills.find(
        (item) => item.invocationName === name,
      );
      assert.ok(office, `Local Office catalog omitted ${name}`);
      assert.equal(office.displayName, name);
      assert.equal(office.enabled, true);
    }
    process.stdout.write(
      "Office Skills reached the desktop Workspace catalog through canonical AgentCore.\n",
    );
  }
  if (builtinOfficeOnly) {
    const verifyNewTask = async (catalog) => {
      const modelSnapshot = await snapshot();
      const created = await invokeBridge("metawork.tasks.create", {
        workspace: { kind: "manual", workspaceId, expectedWorkspaceEpoch },

        modelSelection: fixtureModelSelection(modelSnapshot),
        expectedSkillCatalogRevision: catalog.revision,
        expectedSkillSelectionRevision: catalog.selectionRevision,
        approvalMode: "full_access",
      });
      assert.equal(created.accepted, true);
      const task = (await snapshot()).tasks.find(
        (item) => item.id === created.taskId,
      );
      for (const name of builtinSkillNames)
        assert.ok(
          task.skillCatalog.skills.some((item) => item.invocationName === name),
        );
      return created;
    };
    const officeTask = await verifyNewTask(catalogSnapshot.catalog);
    const deliveredOffice = await runOfficeDeliveryHostProbe({
      created: officeTask,
      workspaceRoot: canonicalWorkspace,
      fixture: join(root, "tests/fixtures/office/sample.docx"),
      invoke: (command, payload) =>
        command === "metawork.tasks.run"
          ? invokePreparedRun(payload)
          : invokeBridge(command, payload),
      snapshot,
      poll,
      provider,
      toolSse,
      textSse,
    });
    const refresh = await invokeBridge(
      "metawork.workspaces.refreshSkillCatalog",
      {
        workspaceId,
        expectedWorkspaceEpoch,
      },
    );
    assert.equal(refresh.accepted, true);
    await readCatalog();
    await stopApplication("built-in Office cold restart");
    await rm(automationDir, { recursive: true, force: true });
    startApplication();
    await waitForBridge();
    assert.equal(
      (
        await invokeBridge("metawork.workspaces.refreshSkillCatalog", {
          workspaceId,
          expectedWorkspaceEpoch,
        })
      ).accepted,
      true,
    );
    const cold = await readCatalog();
    for (const name of builtinSkillNames)
      assert.ok(
        cold.catalog.skills.some((item) => item.invocationName === name),
      );
    await verifyNewTask(cold.catalog);
    const restoredOffice = (await snapshot()).tasks
      .find((t) => t.id === deliveredOffice.taskId)
      ?.runs.find((r) => r.id === deliveredOffice.runId);
    assert.deepEqual(restoredOffice?.outputs, [deliveredOffice.output]);
    process.stdout.write(
      "Actual Office DeliverFile receipt and cold-history projection passed; Renderer output gestures are separately scoped.\n",
    );
    await assert.rejects(
      readdir(
        process.platform === "win32"
          ? join(platformHome, ...officeNamespace)
          : join(
              platformHome,
              "Library",
              "Application Support",
              ...officeNamespace,
            ),
      ),
      { code: "ENOENT" },
    );
    await stopApplication("built-in Office publication failure fixture");
    const published = await readdir(join(dataRoot, "builtin-office"));
    assert.equal(published.length, 1);
    await writeFile(
      join(dataRoot, "builtin-office", published[0], "docx", "SKILL.md"),
      "changed fixture",
    );
    await rm(automationDir, { recursive: true, force: true });
    startApplication();
    await waitForBridge();
    assert.equal(
      (
        await invokeBridge("metawork.workspaces.refreshSkillCatalog", {
          workspaceId,
          expectedWorkspaceEpoch,
        })
      ).accepted,
      true,
    );
    const unavailable = await readCatalog();
    for (const name of builtinSkillNames)
      assert.ok(
        !unavailable.catalog.skills.some(
          (item) => item.invocationName === name,
        ),
      );
    await stopApplication("built-in Office catalog verification complete");
    process.stdout.write(
      "Full Office catalog, explicit refresh, cold restart and nonfatal publication failure passed without preparing private environments.\n",
    );
    break desktopVertical;
  }
  if (
    !/^[0-9a-f]{64}$/.test(catalogSnapshot.skill.skillId) ||
    catalogSnapshot.skill.displayName !== "Review" ||
    !catalogSnapshot.skill.argumentNames.includes("target")
  )
    throw new Error(
      `Workspace catalog omitted the review Skill projection: ${JSON.stringify(catalogSnapshot)}`,
    );
  if (skillAutoRefreshOnly) {
    await runSkillAutoRefreshVertical({
      invoke: invokeBridge,
      snapshot,
      poll,
      provider,
      textSse,
      workspaceId,
      workspaceEpoch: expectedWorkspaceEpoch,
      catalog: catalogSnapshot,
      skillPath: join(skillDirectory, "SKILL.md"),
    });
    await stopApplication("Skill automatic refresh verification complete");
    break desktopVertical;
  }
  if (approvalReadabilityOnly) {
    await verifyApprovalReadability(workspaceId, expectedWorkspaceEpoch);
    await stopApplication("approval readability verification complete");
    break desktopVertical;
  }
  const finishApprovalRestart =
    process.platform === "win32" && !activeInputOnly
      ? await runApprovalModeVertical({
          invoke: invokeBridge,
          snapshot,
          poll,
          provider,
          toolSse,
          textSse,
          backgroundTool: toolSseFromBackgroundJob,
          checkpoint: readCheckpointEvidence,
          checkpointHealth: readCheckpointHealth,
          workspaceId,
          workspaceEpoch: expectedWorkspaceEpoch,
          markerPath: join(
            canonicalWorkspace,
            "mode-cancel-must-not-execute.txt",
          ),
          expectMissing,
          selectRenderedMode,
        })
      : null;
  if (finishApprovalRestart) {
    await stopApplication("approval checkpoint restart stop");
    await rm(automationDir, { recursive: true, force: true });
    startApplication();
    await waitForBridge();
    const restoredWorkspace = (await snapshot()).workspaces.find(
      (workspace) => workspace.id === workspaceId,
    );
    assert.equal(restoredWorkspace.authorization, "available");
    assert.equal(restoredWorkspace.epoch, expectedWorkspaceEpoch);
    assert.equal(restoredWorkspace.canonicalRoot, canonicalWorkspace);
    await finishApprovalRestart();
    if (approvalOnly) {
      await verifyApprovalReadability(workspaceId, expectedWorkspaceEpoch);
      await stopApplication("approval-mode verification complete");
      process.stdout.write(
        "AgentCore approval-only desktop vertical passed: real Product/Bridge/Core grants, review, mode changes, cancellation, stale responses, checkpoint and restart. Fixture model replies do not measure real-model quality; other desktop gestures were not run.\n",
      );
      break desktopVertical;
    }
    await probeWindowsWebViewFocus();
    const refreshedCatalog = await invokeBridge(
      "metawork.workspaces.refreshSkillCatalog",
      { workspaceId, expectedWorkspaceEpoch },
    );
    assert.equal(refreshedCatalog.accepted, true);
    catalogSnapshot = await readCatalog();
  }
  const verifyActiveRestart = await runActiveInputVertical({
    invoke: invokeBridge,
    snapshot,
    poll,
    provider,
    textSse,
    toolSse,
    workspaceId,
    workspaceEpoch: expectedWorkspaceEpoch,
    workspaceRoot: canonicalWorkspace,
    catalog: catalogSnapshot,
    sendInRenderer: chromeProbePort === null ? null : sendInRenderer,
    observeReadingBeforeAdoption:
      chromeProbePort === null ? null : observeActiveReadingBeforeAdoption,
    verifyRendererDraft:
      chromeProbePort === null ? null : verifyActiveRendererDraft,
    observeTransferred:
      chromeProbePort === null ? null : observeTransferredInput,
  });
  if (activeInputOnly) {
    await stopApplication("active input restart");
    await rm(automationDir, { recursive: true, force: true });
    startApplication();
    await waitForBridge();
    await verifyActiveRestart();
    await stopApplication("active input verification complete");
    process.stdout.write(
      "AgentCore active input desktop vertical passed: receipt/adoption, permission wait, merged final-output continuation, stop/failure, ordinary user messages, Skill waiting, timeout reconciliation, draft focus and restart.\n",
    );
    break desktopVertical;
  }
  const modelSnapshot = await snapshot();
  const createResult = await invokeBridge("metawork.tasks.create", {
    workspace: {
      kind: "manual",
      workspaceId,
      expectedWorkspaceEpoch,
    },

    modelSelection: fixtureModelSelection(modelSnapshot),
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
  await probeUnifiedAttachmentInputs();
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
  const runSubmittedAfterUnixMs = Date.now() - 1_000;
  const runResult = await invokePreparedRun({
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
  const observedRunRevisions = new Map();
  let bashReleased = false;
  const readObservedRun = async () => {
    const current = await snapshot({
      taskId,
      includeManagement: false,
      observeTaskView({ revision, task }) {
        if (task?.id !== taskId) return;
        const run = task.runs.find((item) =>
          acceptedRunId ? item.id === acceptedRunId : true,
        );
        if (run) observeRunRevision(observedRunRevisions, revision, run);
        if (run?.output.commentary.length >= 1)
          readCommentaryObserved.release();
        if (run?.output.commentary.length >= 3)
          editCommentaryObserved.release();
      },
    });
    const run = current.tasks
      .find((task) => task.id === taskId)
      ?.runs.find((run) => (acceptedRunId ? run.id === acceptedRunId : true));
    if (
      !bashReleased &&
      run?.activity?.kind === "executing_tools" &&
      run.tools.some((tool) => tool.name === "Bash" && tool.state === "running")
    ) {
      await writeFile(bashObservedPath, "observed");
      bashReleased = true;
    }
    return current;
  };
  const submittedRun = await poll(
    async () => {
      const current = await readObservedRun();
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
  // A source change leaves the already-admitted Run on its captured authority.
  const sourceOff = await invokeBridge("metawork.skills.setSourceEnabled", {
    sourceId: "claude",
    enabled: false,
    expectedRevision: sourceCommit.revision,
  });
  assert.equal(sourceOff.applied, true);
  await poll(
    async () => {
      const current = await readObservedRun();
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
      const current = await readObservedRun();
      const task = current.tasks.find((item) => item.id === taskId);
      const run = task?.runs.find((item) => item.id === runId);
      if (!task || !run) return null;
      const pending = task.pendingUi;
      if (pending && !answered.has(pending.requestId)) {
        // Request delivery can precede the Agent's waiting activity fact.
        // Observe that state before responding so the driver cannot erase
        // the very preterminal transition this vertical is asserting.
        if (run.activity?.kind !== "waiting_user") return null;
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
      historyMainByteSize: checkpointEvidence.historyMainByteSize,
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
      if (pinned?.availability !== "ready") return null;
      const names = pinned.skills.map((item) => item.invocationName).sort();
      return JSON.stringify(names) === JSON.stringify(builtinSkillNames)
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
      assert.deepEqual(
        current.tasks
          .find((item) => item.id === taskId)
          ?.skillCatalog.skills.map((item) => item.invocationName)
          .sort(),
        builtinSkillNames,
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
      const expected = [...builtinSkillNames, "codex-proof", "review"].sort();
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
        if (builtinSkillNames.includes(asset.invocationName)) {
          assert.equal(asset.origin, null);
          assert.equal(asset.managementState, "externally_managed");
        } else {
          assert.equal(
            asset.origin.scope,
            asset.scope.kind === "personal" ? "personal" : "project",
          );
        }
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
  const multimodalRunResult = await invokePreparedRun({
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
      historyMainByteSize: multimodalCheckpoint.historyMainByteSize,
    })}\n`,
  );

  const currentTask = multimodalTerminal.current.tasks.find(
    (item) => item.id === taskId,
  );
  const priorRunIds = new Set(currentTask.runs.map((item) => item.id));
  const deliveryCountBeforeTextRun = productDeliveryEmitCount();
  const textRunResult = await invokePreparedRun({
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
      historyMainByteSize: textCheckpoint.historyMainByteSize,
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
      historyMainByteSize: compactCheckpoint.historyMainByteSize,
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
  if (provider.titleCompletions !== 2)
    throw new Error(
      `automatic title Completion served ${provider.titleCompletions}/2 responses`,
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
  await verifyActiveRestart();
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
  if (process.platform === "win32") await verifyModelSwitch();
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
  readCommentaryObserved.release();
  editCommentaryObserved.release();
  await writeFile(bashObservedPath, "cleanup");
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
      ...(nativeDialogsOnly ? { METAWORK_AUTOMATION_NATIVE_DIALOGS: "1" } : {}),
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

async function probeUnifiedAttachmentInputs() {
  const key = { generation: "1", batchId: "1" };
  const started = performance.now();
  const picker = await invokeBridge("metawork.attachments.beginAdd", {
    ...key,
    source: { kind: "picker" },
  });
  assertAttachmentChoice(picker, attachmentMetadata);
  const timings = [
    { source: "picker", elapsedMs: performance.now() - started },
  ];
  await assertUnifiedStagedOriginals();
  assert.deepEqual(await invokeBridge("metawork.attachments.cancelAdd", key), {
    status: "cleaned",
    released: true,
  });
  for (const attachment of picker.attachments) {
    assert.deepEqual(
      await invokeBridge("metawork.attachments.release", {
        token: attachment.token,
      }),
      { released: false },
    );
  }
  const dropStarted = performance.now();
  const dropKey = { generation: "1", batchId: "2" };
  const choice =
    process.platform === "win32"
      ? await probeDomAttachmentBytes(dropKey)
      : await invokeBridge("metawork.attachments.beginAdd", {
          ...dropKey,
          source: {
            kind: "native_paths",
            paths: [attachmentPngPath, attachmentJpegPath, attachmentLogPath],
          },
        });
  assertAttachmentChoice(choice, attachmentMetadata);
  const dropElapsedMs = performance.now() - dropStarted;
  await assertUnifiedStagedOriginals();
  timings.push({
    source: process.platform === "win32" ? "file_bytes" : "native_paths",
    elapsedMs: dropElapsedMs,
  });
  assert.deepEqual(
    await invokeBridge("metawork.attachments.cancelAdd", dropKey),
    { status: "cleaned", released: true },
  );
  for (const attachment of choice.attachments) {
    assert.deepEqual(
      await invokeBridge("metawork.attachments.release", {
        token: attachment.token,
      }),
      { released: false },
    );
  }
  console.log(
    JSON.stringify({
      attachmentInputProbe: {
        timings,
        bytes: attachmentMetadata.reduce(
          (total, item) => total + Number(item.sizeBytes),
          0,
        ),
        count: attachmentMetadata.length,
        pickerSelection: "automation-path-injection",
        domFiles: process.platform === "win32" ? "cdp-file-input" : null,
        osDrag: false,
      },
    }),
  );
}

async function assertUnifiedStagedOriginals() {
  const staging = join(dataRoot, "workbench", "attachments", "0");
  const originals = await readdir(staging);
  assert.equal(originals.length, 3);
  const expected = new Map([
    [".png", createHash("sha256").update(attachmentPngBytes).digest("hex")],
    [".jpg", createHash("sha256").update(attachmentJpegBytes).digest("hex")],
    [
      path.extname(attachmentLogPath),
      createHash("sha256").update(attachmentLogText).digest("hex"),
    ],
  ]);
  for (const name of originals) {
    const extension = path.extname(name);
    assert.ok(expected.has(extension));
    const hash = createHash("sha256");
    for await (const chunk of createReadStream(join(staging, name)))
      hash.update(chunk);
    assert.equal(hash.digest("hex"), expected.get(extension));
    expected.delete(extension);
  }
  assert.equal(expected.size, 0);
}

async function probeDomAttachmentBytes(key) {
  const webview = await connectTestWebView(chromeProbePort, {
    requestTimeoutMs: commandTimeoutMs,
  });
  const selector = "[data-attachment-input-probe]";
  try {
    await webview.evaluate(
      `(() => { const input = document.createElement('input'); input.type = 'file'; input.multiple = true; input.hidden = true; input.dataset.attachmentInputProbe = ''; document.body.append(input); })()`,
    );
    const document = await webview.send("DOM.getDocument");
    const input = await webview.send("DOM.querySelector", {
      nodeId: document.root.nodeId,
      selector,
    });
    await webview.send("DOM.setFileInputFiles", {
      nodeId: input.nodeId,
      files: [attachmentPngPath, attachmentJpegPath, attachmentLogPath],
    });
    const files = await webview.evaluate(
      `Array.from(document.querySelector(${JSON.stringify(selector)}).files, file => ({ name: file.name, sizeBytes: String(file.size) }))`,
    );
    assert.deepEqual(
      await invokeWebViewBridge(webview, "metawork.attachments.beginAdd", {
        ...key,
        source: { kind: "file_bytes", files },
      }),
      { status: "accepted" },
    );
    for (const [fileIndex, file] of files.entries()) {
      for (
        let offset = 0;
        offset < Number(file.sizeBytes);
        offset += 128 * 1024
      ) {
        const accepted = await webview.evaluate(`(async () => {
          const file = document.querySelector(${JSON.stringify(selector)}).files[${fileIndex}];
          const bytes = new Uint8Array(await file.slice(${offset}, ${offset + 128 * 1024}).arrayBuffer());
          let binary = '';
          for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
          return await window.zero.invoke('metawork.attachments.appendAdd', { ...${JSON.stringify(key)}, fileIndex: ${fileIndex}, offset: ${JSON.stringify(String(offset))}, dataBase64: btoa(binary) });
        })()`);
        assert.deepEqual(accepted, { status: "accepted" });
      }
    }
    return await invokeWebViewBridge(
      webview,
      "metawork.attachments.finishAdd",
      key,
    );
  } finally {
    await webview
      .evaluate(`document.querySelector(${JSON.stringify(selector)})?.remove()`)
      .catch(() => {});
    webview.close();
  }
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
    /^<system-reminder>[\s\S]*# currentDate\n[\s\S]*<\/system-reminder>$/,
  );
  assert.match(
    context.text,
    /Today's date is \d{4}-\d{2}-\d{2} \([A-Za-z]+\)\. (?:Time zone:|The date is in UTC;)/,
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
  return readFixtureCheckpoint(
    join(dataRoot, "workbench", "workbench-history.sqlite"),
    taskId,
  );
}

async function readCheckpointEvidence(
  taskId,
  terminalKind,
  terminalId,
  bindingEpoch,
) {
  const historyPath = join(dataRoot, "workbench", "workbench-history.sqlite");
  const task = await readFixtureCheckpoint(historyPath, taskId);
  lastCheckpointObservation = task
    ? { anchor: task.checkpointAnchor, hasDescriptor: task.checkpoint !== null }
    : { task: "missing" };
  if (!task || task.checkpointAnchor !== "available" || !task.checkpoint)
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
    BigInt(blobDescriptor.byte_size) <= 0n ||
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
    BigInt(blob.length) !== BigInt(blobDescriptor.byte_size) ||
    digest !== blobDescriptor.digest
  )
    throw new Error("checkpoint blob did not match its durable descriptor");
  return {
    blobPath,
    byteSize: blobDescriptor.byte_size,
    generation: blobDescriptor.generation,
    historyMainByteSize: (await stat(historyPath)).size,
    sessionId: descriptor.session.logical_session_id,
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

// Direct tasks.run remains synchronous and never fabricates a Run receipt
// while its fresh query is pending. Normal Composer messages use sendInput.
async function invokePreparedRun(payload) {
  return poll(
    async () => {
      const result = await invokeBridge("metawork.tasks.run", payload);
      if (result?.reason === "catalog_loading") return null;
      return result;
    },
    commandTimeoutMs,
    "fresh catalog before direct Run",
  );
}

async function invokeBridge(command, payload) {
  const responseTimeoutMs = nativeDialogsOnly
    ? command.startsWith("metawork.workbench.snapshot")
      ? 1500
      : 180_000
    : commandTimeoutMs;
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
  // The native-dialog scope observes the SDK single response file before a
  // focus/chrome response can replace it. This bounded busy observation is
  // test-only and does not measure application CPU or input performance.
  let stopResponseWatch = false;
  const responseWatch = (async () => {
    const deadline = Date.now() + responseTimeoutMs;
    while (!stopResponseWatch && Date.now() < deadline) {
      try {
        const latest = JSON.parse(
          nativeDialogsOnly
            ? readFileSync(join(automationDir, "bridge-response.txt"), "utf8")
            : await readFile(
                join(automationDir, "bridge-response.txt"),
                "utf8",
              ),
        );
        if (latest.id === id) return latest;
      } catch {
        // The artifact is atomically replaced and may not exist between runs.
      }
      await new Promise((resolve) =>
        nativeDialogsOnly ? setImmediate(resolve) : setTimeout(resolve, 1),
      );
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

async function snapshot(options) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await readSnapshot(options);
    } catch (error) {
      const stale =
        (error?.bridgeCommand === "metawork.workbench.snapshot" ||
          error?.bridgeCommand === "metawork.workbench.snapshot.chunk") &&
        error?.bridgeResponseError?.code === "handler_failed" &&
        error?.bridgeResponseError?.message === "StaleSnapshot";
      const lastAttempt = stale && approvalOnly ? 9 : 2;
      if (
        (!stale && error?.retryableSnapshotRead !== true) ||
        attempt >= lastAttempt
      )
        throw error;
      // A rejected read handle must be replaced, never reused. Give the real
      // Renderer a turn between this probe's fresh reads of the shared slot.
      if (stale)
        await new Promise((resolve) =>
          setTimeout(resolve, Math.min(50 * (attempt + 1), 250)),
        );
    }
  }
}

async function readSnapshot(options) {
  return readProbeProductState(invokeBridge, {
    ...options,
    forbidden: ["metawork-agentcore-vertical-fixture-key"],
  });
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
    timeout: nativeDialogsOnly ? 180_000 : commandTimeoutMs,
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
            const buttons = document.querySelectorAll('.message-info-bar[data-role=assistant][data-latest="true"] .message-info-copy');
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
            const viewport = button.closest('.ai-conversation-viewport');
            if (!viewport) return {point:null, reason:'conversation_viewport_missing'};
            const target = button.getBoundingClientRect();
            const view = viewport.getBoundingClientRect();
            viewport.scrollTop += target.y + target.height / 2 - view.y - view.height / 2;
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
        {
          timeout: commandTimeoutMs,
          maxBuffer: 1024 * 1024,
          windowsHide: true,
        },
      );
      process.stdout.write(`Windows clipboard evidence: ${stdout.trim()}\n`);
    }
  } finally {
    webview.close();
  }
}

async function verifyApprovalReadability(workspaceId, workspaceEpoch) {
  const webview = await connectTestWebView(chromeProbePort);
  try {
    await runApprovalReadabilityVertical({
      invoke: invokeBridge,
      invokeRun: invokePreparedRun,
      snapshot,
      poll,
      provider,
      toolSse,
      textSse,
      workspaceId,
      workspaceEpoch,
      workspaceRoot: canonicalWorkspace,
      webview,
      expectMissing,
      evidenceDir: join(root, ".zig-cache", "approval-readability"),
    });
  } finally {
    webview.close();
  }
}

async function selectRenderedMode(taskId, targetMode) {
  const webview = await connectTestWebView(chromeProbePort);
  try {
    // The verification-only Host collector and Renderer share one frozen-read
    // slot. Start a fresh Renderer read after polling stops; retain every UI
    // assertion and exercise reload while the real permission request waits.
    if (approvalOnly) await webview.send("Page.reload");
    await poll(
      async () =>
        webview.evaluate(`(() => {
      const row = document.querySelector('.task-list-item[data-task-id="${taskId}"]');
      if (!row) return false;
      row.click(); return true;
    })()`),
      commandTimeoutMs,
      "approval Task Renderer row",
    );
    const triggerPoint = await poll(
      async () =>
        webview.evaluate(`(() => {
      const trigger = document.getElementById('task-approval-mode-${taskId}');
      if (!trigger || trigger.disabled) return null;
      const rect = trigger.getBoundingClientRect();
      return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
    })()`),
      commandTimeoutMs,
      "approval Renderer menu",
    );
    await webview.send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      button: "left",
      clickCount: 1,
      ...triggerPoint,
    });
    await webview.send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      button: "left",
      clickCount: 1,
      ...triggerPoint,
    });
    const labels = {
      manual: ["人工审批", "Manual approval"],
      auto_review: ["自动评审", "Automatic review"],
      full_access: ["完全访问", "Full access"],
    }[targetMode];
    const choice = await poll(
      async () =>
        webview.evaluate(`(() => {
      const labels = ${JSON.stringify(labels)};
      const choice = [...document.querySelectorAll('.task-approval-menu [role="option"]')].find(option => labels.includes(option.querySelector('.selection-menu-item-copy')?.firstElementChild?.textContent));
      if (!choice || choice.getAttribute('aria-disabled') === 'true') return null;
      choice.scrollIntoView({ block: 'nearest' });
      const rect = choice.getBoundingClientRect();
      if (rect.y < 0 || rect.bottom > innerHeight) return null;
      return { label: choice.textContent, viewport: [innerWidth, innerHeight], overflow: document.documentElement.scrollWidth > innerWidth, point: { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 } };
    })()`),
      commandTimeoutMs,
      "approval Renderer choice",
    );
    assert.equal(choice.overflow, false);
    assert.match(choice.label, /先停止当前运行|Stops the current run/);
    const evidence = join(root, ".zig-cache", "agentcore-r19");
    await mkdir(evidence, { recursive: true });
    const image = await webview.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      join(evidence, "approval-menu-live.png"),
      Buffer.from(image.data, "base64"),
    );
    console.log(
      `AgentCore approval Renderer evidence: ${JSON.stringify(choice)}`,
    );
    await webview.send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      button: "left",
      clickCount: 1,
      ...choice.point,
    });
    await webview.send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      button: "left",
      clickCount: 1,
      ...choice.point,
    });
    await poll(
      () =>
        webview.evaluate(`(() => {
      const menu = document.querySelector('.task-approval-menu');
      return !menu || menu.getBoundingClientRect().width === 0;
    })()`),
      commandTimeoutMs,
      "approval menu dismissed after selection",
    );
  } finally {
    webview.close();
  }
}

async function resizeActiveInputVisualWindow(width, height) {
  await execFileAsync(
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      visualCaptureScript,
      "-ProcessId",
      String(app.pid),
      "-OutputPath",
      path.join(root, ".zig-cache", "active-input-resize.png"),
      "-Width",
      String(width),
      "-Height",
      String(height),
    ],
    { timeout: commandTimeoutMs, maxBuffer: 1024 * 1024 },
  );
}

async function sendInRenderer(taskId, text) {
  await resizeActiveInputVisualWindow(1320, 812);
  const webview = await connectTestWebView(chromeProbePort, {
    requestTimeoutMs: commandTimeoutMs,
  });
  const newerDraft =
    "Unsent draft remains editable while the current Run works";
  try {
    await webview.evaluate(`(() => {
      window.__activeInputUiErrors=0;
      const original=console.error;
      console.error=function(...args){window.__activeInputUiErrors++;original.apply(this,args);};
      window.addEventListener('error',()=>window.__activeInputUiErrors++);
      window.addEventListener('unhandledrejection',()=>window.__activeInputUiErrors++);
    })()`);
    await poll(
      () =>
        webview.evaluate(`(() => {
      const row=[...document.querySelectorAll('.task-list-item')].find(node=>node.dataset.taskId===${JSON.stringify(taskId)});
      if(!row) return false;
      if(row.getAttribute('aria-current')!=='page') {row.click();return false;}
      return Boolean(document.querySelector('.composer-shell textarea:not(:disabled)'));
    })()`),
      commandTimeoutMs,
      "active input rendered Task",
    );
    await webview.evaluate(
      `document.querySelector('.composer-shell textarea').focus()`,
    );
    await webview.send("Input.insertText", { text });
    await poll(
      () =>
        webview.evaluate(
          `document.querySelector('.composer-send')?.disabled===false && document.querySelector('.composer-stop')===null`,
        ),
      commandTimeoutMs,
      "content shows Send without Task Stop",
    );
    assert.deepEqual(
      await webview.evaluate(
        `(() => {const r=document.querySelector('.composer-send').getBoundingClientRect();return [r.width,r.height];})()`,
      ),
      [44, 44],
    );
    await webview.evaluate(`(() => {
      const transport=window.chrome.webview, post=transport.postMessage;
      window.__activeInputOriginalPost=post;window.__activeInputCalls=0;
      transport.postMessage=function(message) {
        const envelope=typeof message==='string'?JSON.parse(message):message;
        if(envelope.command==='metawork.tasks.sendInput') {
          window.__activeInputCalls++;
          setTimeout(()=>post.call(transport,message),11000);
          return;
        }
        return post.call(transport,message);
      };
      document.querySelector('.composer-send').click();
    })()`);
    await poll(
      () =>
        webview.evaluate(`
        document.querySelector('.composer-shell textarea')?.value === '' &&
        document.querySelector('.composer-stop')?.disabled === false &&
        document.querySelector('.composer-send') === null
      `),
      commandTimeoutMs,
      "submitted draft clears while Task Stop remains available",
    );
    await webview.evaluate(
      `document.querySelector('.composer-shell textarea').focus();document.querySelector('.composer-shell textarea').select()`,
    );
    await webview.send("Input.dispatchKeyEvent", {
      type: "keyDown",
      key: "Backspace",
      windowsVirtualKeyCode: 8,
    });
    await webview.send("Input.dispatchKeyEvent", {
      type: "keyUp",
      key: "Backspace",
      windowsVirtualKeyCode: 8,
    });
    await poll(
      () =>
        webview.evaluate(
          `document.querySelector('.composer-shell textarea')?.value==='' && document.querySelector('.composer-stop')?.disabled===false && document.querySelector('.composer-send')===null`,
        ),
      commandTimeoutMs,
      "empty busy draft shows Stop only",
    );
    assert.deepEqual(
      await webview.evaluate(
        `(() => {const r=document.querySelector('.composer-stop').getBoundingClientRect();return [r.width,r.height];})()`,
      ),
      [44, 44],
    );
    await webview.send("Input.insertText", { text: newerDraft });
    await poll(
      async () => {
        const task = (await snapshot()).tasks.find(
          (item) => item.id === taskId,
        );
        return task.runs[0].additionalInputs.some(
          (message) => message.text === text,
        );
      },
      20_000,
      "single delayed input reaches this Run after Renderer timeout",
    );
    await poll(
      () =>
        webview.evaluate(`document.querySelector('.additional-input')!==null`),
      commandTimeoutMs,
      "additional input history visible",
    );
    assert.deepEqual(
      await webview.evaluate(
        `({calls:window.__activeInputCalls,text:document.querySelector('.composer-shell textarea')?.value})`,
      ),
      { calls: 1, text: newerDraft },
    );
    if (visualCaptureDir) {
      await mkdir(visualCaptureDir, { recursive: true });
      for (const [name, width, theme] of [
        ["active-desktop-light", 1320, "light"],
        ["active-desktop-dark", 1320, "dark"],
        ["active-narrow-light", 390, "light"],
        ["active-narrow-dark", 390, "dark"],
      ]) {
        await resizeActiveInputVisualWindow(width, 812);
        await webview.evaluate(
          `document.documentElement.dataset.theme=${JSON.stringify(theme)}`,
        );
        await webview.send("Emulation.setEmulatedMedia", {
          features: [{ name: "prefers-reduced-motion", value: "reduce" }],
        });
        await poll(
          () =>
            webview.evaluate(`(() => {
          if(innerWidth>${width} || innerWidth<${width}-32) return false;
          const message=document.querySelector('.additional-input'), actions=[...document.querySelectorAll('.composer-send,.composer-stop')];
          if(!message || actions.length!==1 || !actions[0].classList.contains('composer-send') || actions[0].disabled) return false;
          const bubble=message.querySelector('.ai-message[data-role="user"]');
          if(!bubble) throw new Error('interjection must use the shared user message');
          const shared=document.querySelector('.ai-exchange > .ai-message[data-role="user"]');
          if(getComputedStyle(message).borderTopWidth!=='0px' || getComputedStyle(bubble).backgroundColor!==getComputedStyle(shared).backgroundColor) throw new Error('interjection still renders a separate card');
          const r=message.getBoundingClientRect();
          if(r.width===0 || r.left < -1 || r.right>innerWidth+1) return false;
          for(const action of actions) {const b=action.getBoundingClientRect();if(b.height<43 || b.left < -1 || b.right>innerWidth+1) throw new Error('active input control outside viewport or too small');}
          if(document.documentElement.scrollWidth>innerWidth) throw new Error('active input horizontal overflow');
          return true;
        })()`),
          commandTimeoutMs,
          `active input ${name} geometry`,
        );
        const png = await webview.send("Page.captureScreenshot", {
          format: "png",
          captureBeyondViewport: false,
        });
        await writeFile(
          path.join(visualCaptureDir, `${name}.png`),
          Buffer.from(png.data, "base64"),
        );
      }
    }
    await resizeActiveInputVisualWindow(1320, 812);
    await webview.evaluate(
      `delete document.documentElement.dataset.theme;document.querySelector('.composer-shell textarea').focus()`,
    );
    await webview.send("Emulation.setEmulatedMedia", { features: [] });
    return newerDraft;
  } finally {
    await webview
      .evaluate(
        `if(window.__activeInputOriginalPost){window.chrome.webview.postMessage=window.__activeInputOriginalPost;delete window.__activeInputOriginalPost;}`,
      )
      .catch(() => {});
    webview.close();
  }
}

async function observeActiveReadingBeforeAdoption(taskId) {
  const webview = await connectTestWebView(chromeProbePort, {
    requestTimeoutMs: commandTimeoutMs,
  });
  try {
    await poll(
      () =>
        webview.evaluate(
          `document.querySelectorAll('.run-reading-flow .additional-input').length===2`,
        ),
      commandTimeoutMs,
      "both interjections in the actual reading surface",
    );
    const order = await webview.evaluate(`(() => {
      const flow=document.querySelector('.run-reading-flow');
      const messages=[...flow.querySelectorAll('.ai-message')];
      const viewport=document.querySelector('.ai-conversation-viewport');
      viewport.scrollTop=0;viewport.dispatchEvent(new Event('scroll',{bubbles:true}));
      const first=flow.querySelector('.additional-input .ai-message');
      window.__activeReadingObservation={first,top:first.getBoundingClientRect().top};
      return messages.map(node=>node.dataset.role);
    })()`);
    assert.deepEqual(order, ["user", "assistant", "user"]);
  } finally {
    webview.close();
  }
}

async function verifyActiveRendererDraft(taskId, text) {
  const webview = await connectTestWebView(chromeProbePort, {
    requestTimeoutMs: commandTimeoutMs,
  });
  try {
    const observed = await webview.evaluate(`(() => {
      const textarea=document.querySelector('.composer-shell textarea');
      return {text:textarea?.value,focused:document.activeElement===textarea,calls:window.__activeInputCalls,task:document.querySelector('.task-list-item[aria-current="page"]')?.dataset.taskId};
    })()`);
    assert.deepEqual(observed, { text, focused: true, calls: 1, task: taskId });
    const reading = await poll(
      async () => {
        const current = await webview.evaluate(`(() => {
      const flow=document.querySelector('.run-reading-flow');
      const first=flow.querySelector('.additional-input .ai-message');
      const before=window.__activeReadingObservation;
      return {roles:[...flow.querySelectorAll('.ai-message')].map(node=>node.dataset.role),same:first===before.first,shift:Math.abs(first.getBoundingClientRect().top-before.top),following:document.querySelector('.ai-conversation-viewport').scrollTop,copies:flow.querySelectorAll('.additional-input .message-info-bar[data-role=user]').length};
    })()`);
        if (current.roles.join(",") === "user,assistant,user,assistant")
          return current;
        throw new Error(JSON.stringify(current));
      },
      commandTimeoutMs,
      "adopted input and final response in the Renderer",
    );
    assert.deepEqual(reading.roles, ["user", "assistant", "user", "assistant"]);
    assert.equal(reading.copies, 2);
    assert.equal(reading.same, true);
    assert.ok(reading.shift <= 1, JSON.stringify(reading));
    assert.equal(reading.following, 0);
    assert.equal(await webview.evaluate(`window.__activeInputUiErrors`), 0);
    await webview.evaluate(
      `(() => {const viewport=document.querySelector('.ai-conversation-viewport');viewport.scrollTop=viewport.scrollHeight;viewport.dispatchEvent(new Event('scroll',{bubbles:true}));})()`,
    );
    if (visualCaptureDir) {
      const png = await webview.send("Page.captureScreenshot", {
        format: "png",
        captureBeyondViewport: false,
      });
      await writeFile(
        path.join(visualCaptureDir, "active-adopted-desktop-light.png"),
        Buffer.from(png.data, "base64"),
      );
    }
  } finally {
    webview.close();
  }
}

async function observeTransferredInput(taskId, targetRunId) {
  const webview = await connectTestWebView(chromeProbePort, {
    requestTimeoutMs: commandTimeoutMs,
  });
  const observations = [];
  try {
    await poll(
      () =>
        webview.evaluate(`(() => {
      const row=[...document.querySelectorAll('.task-list-item')].find(node=>node.dataset.taskId===${JSON.stringify(taskId)});
      if(row && row.getAttribute('aria-current')!=='page') row.click();
      return row?.getAttribute('aria-current')==='page' && document.querySelectorAll('.additional-input[data-input-id]').length===2;
    })()`),
      commandTimeoutMs,
      "transferred inputs in the real reading surface",
    );
    const inputCopies = await webview.evaluate(`(() => {
      const source=[...document.querySelectorAll('.additional-input[data-input-id] .task-input-copy')];
      const copies=[...document.querySelectorAll('.ai-message[data-role="user"] .task-input-copy')];
      const target=document.querySelector('[data-run-id="${targetRunId}"]');
      return {counts:source.map(message=>copies.filter(copy=>copy.textContent.includes(message.textContent)).length),targetInput:!!target.querySelector(':scope > .ai-message[data-role="user"]'),targetMetadata:!!target.querySelector(':scope > .message-info-bar[data-role=user]')};
    })()`);
    assert.deepEqual(inputCopies, {
      counts: [1, 1],
      targetInput: false,
      targetMetadata: false,
    });
    for (const [name, width, theme] of [
      ["continuation-desktop-light", 1320, "light"],
      ["continuation-desktop-dark", 1320, "dark"],
      ["continuation-narrow-light", 390, "light"],
      ["continuation-narrow-dark", 390, "dark"],
    ]) {
      await resizeActiveInputVisualWindow(width, 812);
      await webview.send("Emulation.setEmulatedMedia", {
        features: [{ name: "prefers-reduced-motion", value: "reduce" }],
      });
      await webview.evaluate(
        `document.documentElement.dataset.theme=${JSON.stringify(theme)}`,
      );
      const geometry = await poll(
        () =>
          webview.evaluate(`(() => {
        if(innerWidth>${width} || innerWidth<${width}-32) return false;
        const messages=[...document.querySelectorAll('.additional-input[data-input-id]')];
        if(messages.length!==2) return false;
        if(document.querySelector('.additional-input-target, .additional-input-state, .additional-input-restore, .run-process-input')) throw new Error('Interjection-specific status or action is visible');
        for(const message of messages) {
          if(message.querySelectorAll('button').length!==1 || !message.querySelector('.message-info-bar[data-role=user] .message-info-copy')) throw new Error('User message must only offer ordinary copy');
        }
        if(document.documentElement.scrollWidth>innerWidth) throw new Error('Continuation horizontal overflow');
        if(!document.querySelector('[data-run-id="${targetRunId}"]')) throw new Error('Transfer target is not a real exchange');
        messages[0].scrollIntoView({block:'start'});
        return {width:innerWidth,theme:document.documentElement.dataset.theme,messages:messages.length,copyActions:messages.filter(node=>node.querySelector('.message-info-copy')).length,errors:window.__activeInputUiErrors??0};
      })()`),
        commandTimeoutMs,
        `${name} transfer geometry`,
      );
      assert.equal(geometry.errors, 0);
      observations.push({ name, ...geometry });
      if (visualCaptureDir) {
        await mkdir(visualCaptureDir, { recursive: true });
        const png = await webview.send("Page.captureScreenshot", {
          format: "png",
          captureBeyondViewport: false,
        });
        await writeFile(
          path.join(visualCaptureDir, `${name}.png`),
          Buffer.from(png.data, "base64"),
        );
      }
    }
    if (visualCaptureDir)
      await writeFile(
        path.join(visualCaptureDir, "continuation-dom.json"),
        JSON.stringify({ taskId, targetRunId, observations }, null, 2),
      );
  } finally {
    await resizeActiveInputVisualWindow(1320, 812);
    await webview
      .evaluate("delete document.documentElement.dataset.theme")
      .catch(() => {});
    await webview
      .send("Emulation.setEmulatedMedia", { features: [] })
      .catch(() => {});
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

async function verifyModelSwitch() {
  if (chromeProbePort === null)
    throw new Error("Model switch WebView verification requires Windows");
  const webview = await connectTestWebView(chromeProbePort);
  try {
    await runModelSwitchVertical({
      invoke: invokeBridge,
      snapshot: ({ taskId = null } = {}) => snapshot({ taskId }),
      poll,
      provider,
      textSse,
      webview,
      evidenceDir:
        visualCaptureDir ?? path.join(root, ".zig-cache", "model-switch-ui"),
    });
  } finally {
    webview.close();
  }
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
  if (approvalOnly) {
    const webview = await connectTestWebView(chromeProbePort);
    try {
      // Bootstrap must finish before the verification collector starts its
      // competing frozen reads. These controls are disabled until the real
      // Renderer connection has accepted and confirmed its initial snapshot.
      await poll(
        () =>
          webview.evaluate(
            `(() => [...document.querySelectorAll('.task-approval-trigger')].some(control => !control.disabled))()`,
          ),
        commandTimeoutMs,
        "approval Renderer bootstrap ready",
      );
    } finally {
      webview.close();
    }
  }
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

function createProvider(
  queue,
  { initialDelayMs = 0, frameDelayMs = 0, titleInputs = ["Review"] } = {},
) {
  let modelProbeCredential = "metawork-agentcore-vertical-fixture-key";
  let served = 0;
  let titleCompletions = 0;
  let nextTitleGate = null;
  let reviewRequests = 0;
  let mcpReviewRequests = 0;
  let inputReviewRequests = 0;
  let readabilityReviewRequests = 0;
  let technicalReviewRequests = 0;

  let releaseReview = null;
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
        if (
          typeof payload.system === "string" &&
          payload.system.startsWith("你是独立的权限评审器")
        ) {
          assert.equal(
            request.headers["x-api-key"],
            "metawork-agentcore-vertical-fixture-key",
          );
          assert.equal(request.headers.authorization, undefined);
          assert.equal(payload.model, "claude-sonnet-4-20250514");
          assert.equal(payload.stream, undefined);
          assert.equal(payload.tools, undefined);
          const review = JSON.parse(payload.messages[0].content);
          if (review.evidence.request.tool_namespace === "mcp") {
            assert.equal(process.env.METAWORK_MCP_ONLY, "1");
            assert.ok(
              ["mcp-automatic-first", "mcp-automatic-second"].includes(
                review.evidence.user_intent,
              ),
            );
            assert.equal(review.host.delegation, "current_request_only");
            assert.equal(
              review.evidence.request.arguments.text,
              "desktop-echo",
            );
            mcpReviewRequests++;
            response.writeHead(200, {
              "content-type": "application/json",
              connection: "close",
            });
            response.end(
              JSON.stringify({
                type: "message",
                content: [
                  {
                    type: "text",
                    text: JSON.stringify({
                      decision: "allow_once",
                      reason: "当前任务内的本地合成 MCP 回显。",
                    }),
                  },
                ],
                stop_reason: "end_turn",
                usage: { input_tokens: 1, output_tokens: 1 },
              }),
            );
            return;
          }
          const readability =
            review.evidence.user_intent ===
            "请检查审批请求，确认这条命令的用途。";
          assert.equal(review.host.delegation, "current_request_only");
          assert.equal(review.evidence.request.tool_name, "Bash");
          if (
            review.evidence.user_intent === "请检查这条命令的审批服务故障提示。"
          ) {
            technicalReviewRequests++;
            assert.equal(technicalReviewRequests, 1);
            response.writeHead(503, {
              "content-type": "text/plain",
              connection: "close",
            });
            response.end("synthetic service unavailable");
            return;
          }
          if (review.evidence.user_intent === "input-review-constraint") {
            inputReviewRequests++;
            assert.equal(
              inputReviewRequests,
              1,
              "interjection must not schedule another review",
            );
          } else if (readability) {
            readabilityReviewRequests++;
            assert.equal(readabilityReviewRequests, 1);
            assert.equal(
              review.evidence.recent_tool_calls,
              undefined,
              "Write from a previous turn must not become evidence while same-turn Edit and Bash await tool_start",
            );
            assert.equal(review.evidence.omitted_tool_calls, undefined);
            assert.ok(
              !payload.messages[0].content.includes("BEFORE"),
              "benign old script content must not reach the reviewer",
            );
          } else {
            assert.equal(
              review.evidence.user_intent,
              "mode-review-current-request",
            );
            assert.equal(review.evidence.earlier_user_instructions.length, 1);
            assert.deepEqual(
              review.evidence.earlier_user_instructions[0].messages,
              ["mode-grant-seed"],
            );
            assert.match(
              review.evidence.earlier_user_instructions[0].run_id,
              /^[1-9][0-9]*$/,
            );
            assert.equal(review.evidence.omitted_earlier_user_messages, 0);
            assert.equal(
              JSON.stringify(review.evidence).includes("MODE_GRANT"),
              false,
              "prior tool output cannot become user authorization evidence",
            );
            reviewRequests++;
            assert.equal(
              reviewRequests,
              1,
              "current request was automatically reviewed twice",
            );
          }
          if (!readability) {
            await new Promise((resolve) => {
              releaseReview = resolve;
            });
          }
          response.writeHead(200, {
            "content-type": "application/json",
            connection: "close",
          });
          response.end(
            JSON.stringify({
              type: "message",
              content: [
                {
                  type: "text",
                  text: JSON.stringify({
                    decision: readability ? "needs_user" : "allow_once",
                    reason: readability
                      ? "用途说明与实际命令不一致，需要你确认是否执行。"
                      : "bounded fixture command",
                  }),
                },
              ],
              stop_reason: "end_turn",
              usage: { input_tokens: 1, output_tokens: 1 },
            }),
          );
          return;
        }
        if (payload.messages?.[0]?.content === "Reply with OK.") {
          assert.equal(request.headers["x-api-key"], modelProbeCredential);
          assert.equal(request.headers.authorization, undefined);
          assert.equal(request.headers["anthropic-version"], "2023-06-01");
          assert.equal(payload.model, "claude-sonnet-4-20250514");
          assert.equal(payload.messages.length, 1);
          assert.equal(payload.messages[0].role, "user");
          assert.equal(payload.stream, undefined);
          assert.equal(payload.tools, undefined);
          response.writeHead(200, {
            "content-type": "application/json",
            connection: "close",
          });
          response.end(
            JSON.stringify({
              type: "message",
              role: "assistant",
              content: [{ type: "text", text: "OK" }],
              stop_reason: "end_turn",
              usage: { input_tokens: 1, output_tokens: 1 },
            }),
          );
          return;
        }
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
            !titleInputs.includes(payload.messages[0]?.content)
          )
            throw new Error(
              "automatic title Completion did not preserve its frozen Anthropic request",
            );
          titleCompletions += 1;
          if (nextTitleGate) {
            const held = nextTitleGate;
            nextTitleGate = null;
            held.entered = true;
            await held.promise;
          }
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
        if (response.destroyed) return;
        if (fixture?.status !== undefined) {
          assert.ok([400, 401, 402].includes(fixture.status));
          response.writeHead(fixture.status, {
            "content-type": "application/json",
            connection: "close",
          });
          response.end(body);
          return;
        }
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
          fixture?.beforeFrame,
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
    expectModelProbeCredential(credential) {
      assert.ok(credential.length > 0 && credential.length <= 4096);
      modelProbeCredential = credential;
    },
    enqueue(...fixtures) {
      queue.splice(served, 0, ...fixtures);
    },
    holdNextTitle() {
      assert.equal(nextTitleGate, null);
      let release;
      const promise = new Promise((resolve) => {
        release = resolve;
      });
      const held = { entered: false, promise, release };
      nextTitleGate = held;
      return held;
    },
    get inputReviewRequests() {
      return inputReviewRequests;
    },
    get readabilityReviewRequests() {
      return readabilityReviewRequests;
    },
    get technicalReviewRequests() {
      return technicalReviewRequests;
    },
    get reviewRequests() {
      return reviewRequests;
    },
    get mcpReviewRequests() {
      return mcpReviewRequests;
    },

    releaseReview() {
      assert.ok(releaseReview, "review fixture was not admitted");
      releaseReview();
      releaseReview = null;
    },
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
      releaseReview?.();
      return new Promise((resolve) => server.close(resolve));
    },
  };
}

async function streamProviderResponse(
  response,
  body,
  initialDelayMs,
  frameDelayMs,
  beforeFrame,
) {
  if (initialDelayMs > 0)
    await new Promise((resolve) => setTimeout(resolve, initialDelayMs));
  const frames = body.match(/[\s\S]*?\n\n/g) ?? [];
  if (frames.join("") !== body)
    throw new Error("provider fixture produced an invalid SSE body");
  for (const frame of frames) {
    await beforeFrame?.(frame);
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

function toolSse(
  messageId,
  toolId,
  name,
  input,
  commentary = null,
  precedingTools = [],
) {
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
  for (const tool of [...precedingTools, { id: toolId, name, input }]) {
    events.push(
      {
        type: "content_block_start",
        index: toolIndex,
        content_block: {
          type: "tool_use",
          id: tool.id,
          name: tool.name,
          input: {},
        },
      },
      {
        type: "content_block_delta",
        index: toolIndex,
        delta: {
          type: "input_json_delta",
          partial_json: JSON.stringify(tool.input),
        },
      },
      { type: "content_block_stop", index: toolIndex },
    );
    toolIndex++;
  }
  events.push(
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
    const jobId = findJsonField(payload.messages.at(-1), "job_id");
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
  // Keep reply padding distinct from attachment padding so the history leak
  // assertion observes attachment content rather than the expected reply.
  const markdown = `${prefix}${"r".repeat(remaining)}${suffix}`;
  if (Buffer.byteLength(markdown) !== targetBytes)
    throw new Error("clipboard fixture byte count is not exact");
  return markdown;
}

function sse(events) {
  return events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
}

function streamedSse(body, frameDelayMs, initialDelayMs, beforeFrame) {
  return { body, frameDelayMs, initialDelayMs, beforeFrame };
}

function observationGate() {
  let release;
  const observed = new Promise((resolve) => {
    release = resolve;
  });
  return {
    release,
    async beforeFrame(frame) {
      const event = JSON.parse(frame.slice("data: ".length));
      if (event.type === "message_start") await observed;
    },
  };
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
