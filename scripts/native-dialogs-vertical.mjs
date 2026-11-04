import assert from "node:assert/strict";
import { access, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";

// Real native windows are operated externally (CUA or a human). An observer
// acknowledges visibility before the fixture releases the Agent response.
// No path injection, synthetic dialog completion or native input automation.
export async function runNativeDialogsVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  workspaceRoot,
  fixturePath,
  evidenceDir,
  automate,
  stop,
}) {
  assert.equal(
    process.platform,
    "darwin",
    "This native dialog harness currently requires macOS",
  );
  const scope = process.env.METAWORK_NATIVE_DIALOGS_SCOPE ?? "all";
  assert.ok(
    ["all", "mcp", "assets"].includes(scope),
    "Unknown native dialog scope",
  );
  await rm(evidenceDir, { recursive: true, force: true });
  await mkdir(evidenceDir, { recursive: true });
  const observations = [];
  const stage = async (label, details = {}) => {
    await writeFile(
      join(evidenceDir, "stage.json"),
      JSON.stringify({ label, at: Date.now(), ...details }, null, 2),
    );
    console.log(`Native dialog acceptance: ${label}`);
  };
  const ack = async (label) =>
    poll(
      async () => {
        try {
          await access(join(evidenceDir, `${label}.ack`));
          return true;
        } catch {
          await snapshot();
          return false;
        }
      },
      180_000,
      `external observer: ${label}`,
    );
  const schedule = async (
    title,
    seconds = Math.floor(Date.now() / 1000) + 3600,
    permissionProfile = "approval_required",
  ) => {
    const result = await invoke("metawork.scheduledTasks.create", {
      title,
      modelSelection: fixtureModelSelection(await snapshot()),
      permissionProfile,
      input: { kind: "text", text: title },
      recurrence: { kind: "once", atUnixSeconds: String(seconds) },
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    return result.scheduledTaskId;
  };
  const background = async (label) => {
    let release;
    let entered = false;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    provider.enqueue(async () => {
      entered = true;
      await gate;
      return {
        body: textSse(label, `Background ${label} completed`),
        initialDelayMs: 0,
        frameDelayMs: 0,
      };
    });
    const id = await schedule(label);
    const current = (await snapshot()).scheduledTasks.find(
      (item) => item.id === id,
    );
    const result = await invoke("metawork.scheduledTasks.runNow", {
      scheduledTaskId: id,
      expectedEpoch: current.epoch,
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    await poll(
      async () => entered,
      20_000,
      "Agent entered Provider before dialog",
    );
    return { taskId: result.taskId, release };
  };
  const completed = async (id) =>
    poll(
      async () => {
        const task = (await snapshot()).tasks.find((item) => item.id === id);
        return task?.runs.at(-1)?.terminal?.outcome === "completed"
          ? task
          : null;
      },
      30_000,
      "Agent completion while native dialog remains open",
    );
  const openWithProgress = async (
    label,
    command,
    payload,
    close,
    timer = false,
  ) => {
    const agent = await background(label);
    let timerId;
    if (timer) {
      timerId = await schedule(
        "Native picker timer",
        Math.floor(Date.now() / 1000) + 30,
      );
      provider.enqueue(
        textSse("native-picker-timer", "Timer completed while picker open"),
      );
    }
    let settled = false;
    const pending = invoke(command, payload).finally(() => {
      settled = true;
    });
    void pending.catch(() => {});
    await stage(`${label}-visible`, {
      command,
      close,
      fixturePath,
      workspaceRoot,
    });
    await Promise.race([
      ack(`${label}-visible`),
      pending.then(() => {
        throw new Error("dialog settled before visibility acknowledgment");
      }),
    ]);
    assert.equal(settled, false, "real picker must still be waiting");
    agent.release();
    await completed(agent.taskId);
    let occurrence;
    if (timer) {
      occurrence = await poll(
        async () => {
          const current = (await snapshot()).scheduledTasks.find(
            (item) => item.id === timerId,
          );
          return (
            current.occurrences.find(
              (item) => item.source === "timer" && item.result === "submitted",
            ) ?? null
          );
        },
        40_000,
        "OS timer creates Task before picker closes",
      );
      await completed(occurrence.taskId);
      assert.equal(
        (await snapshot()).scheduledTasks.find((item) => item.id === timerId)
          .occurrences.length,
        1,
      );
    }
    assert.equal(
      settled,
      false,
      "Agent/timer completion must precede dialog settlement",
    );
    observations.push({
      label,
      progressedAt: Date.now(),
      taskId: agent.taskId,
      occurrence,
    });
    await stage(`${label}-close`, { close, fixturePath, workspaceRoot });
    const result = await pending;
    observations.at(-1).closedAt = Date.now();
    observations.at(-1).result = result;
    await writeFile(
      join(evidenceDir, "observations.json"),
      JSON.stringify(observations, null, 2),
    );
    return result;
  };
  if (scope === "assets") {
    const choose = async (label, command, payload, path) => {
      await stage(label, { command, path });
      const pending = invoke(command, payload);
      void pending.catch(() => {});
      await snapshot({ includeManagement: false });
      const result = await pending;
      observations.push({ label, result, at: Date.now() });
      await writeFile(
        join(evidenceDir, "observations.json"),
        JSON.stringify(observations, null, 2),
      );
      return result;
    };
    const root = join(workspaceRoot, "root-candidate");
    const skill = join(workspaceRoot, "dialog-skill");
    const exported = join(workspaceRoot, "exported");
    await mkdir(root);
    await mkdir(skill);
    await mkdir(exported);
    await writeFile(
      join(skill, "SKILL.md"),
      "---\nname: dialog-smoke\ndescription: Native dialog smoke fixture\n---\nTest fixture.\n",
    );
    const config = async () => (await snapshot()).automaticWorkspaceRoot;
    assert.equal(
      (
        await choose(
          "root-confirm",
          "metawork.workspaces.chooseAutomaticRoot",
          { expectedGeneration: (await config()).generation },
          root,
        )
      ).outcome,
      "applied",
    );
    assert.equal(
      (
        await choose(
          "root-cancel",
          "metawork.workspaces.chooseAutomaticRoot",
          { expectedGeneration: (await config()).generation },
          null,
        )
      ).outcome,
      "cancelled",
    );
    const target = {
      kind: "personal",
      workspaceId: null,
      expectedWorkspaceEpoch: null,
      installId: null,
    };
    assert.equal(
      (
        await choose(
          "skill-import-cancel",
          "metawork.skills.chooseImport",
          { kind: "directory", target },
          null,
        )
      ).status,
      "cancelled",
    );
    const preview = await choose(
      "skill-import-confirm",
      "metawork.skills.chooseImport",
      { kind: "directory", target },
      skill,
    );
    assert.equal(preview.status, "prepared", JSON.stringify(preview));
    const installed = await invoke("metawork.skills.install", {
      previewId: preview.previewId,
      preparationRevision: preview.preparationRevision,
      confirmation: preview.effect,
    });
    assert.equal(installed.accepted, true, JSON.stringify(installed));
    const output = await choose(
      "skill-export-confirm",
      "metawork.skills.export",
      { installId: installed.installId },
      exported,
    );
    assert.equal(output.exported, true, JSON.stringify(output));
    await access(join(exported, output.fileName));
    assert.equal(
      (
        await choose(
          "skill-export-cancel",
          "metawork.skills.export",
          { installId: installed.installId },
          null,
        )
      ).reason,
      "cancelled",
    );
    await stop();
    await stage("completed");
    return;
  }
  if (scope !== "mcp") {
    // This isolated process has one initial Renderer connection, no reconnect.
    const connection = "1";
    const key = { generation: connection, batchId: "1" };
    const attachment = await openWithProgress(
      "attachment-confirm",
      "metawork.attachments.beginAdd",
      { ...key, source: { kind: "picker" } },
      "select fixturePath",
      true,
    );
    assert.equal(attachment.status, "ready", JSON.stringify(attachment));
    await invoke("metawork.attachments.cancelAdd", key);
    const cancelled = await openWithProgress(
      "attachment-cancel",
      "metawork.attachments.beginAdd",
      { generation: connection, batchId: "2", source: { kind: "picker" } },
      "Cancel",
    );
    assert.equal(cancelled.status, "cancelled", JSON.stringify(cancelled));
    const workspace = await openWithProgress(
      "workspace-confirm",
      "metawork.workspaces.choose",
      {},
      "select workspaceRoot",
    );
    assert.equal(workspace.selected, true, JSON.stringify(workspace));
    const workspaceCancel = await openWithProgress(
      "workspace-cancel",
      "metawork.workspaces.choose",
      {},
      "Cancel",
    );
    assert.equal(workspaceCancel.selected, false);
    // Create a real delivered Output through the same staged Core used above.
    provider.enqueue(
      toolSse("dialog-write", "dialog-write", "Write", {
        file_path: "dialog-output.txt",
        content: "Native Save As test\n",
      }),
      toolSse("dialog-deliver", "dialog-deliver", "DeliverFile", {
        path: "dialog-output.txt",
      }),
      textSse("dialog-output-done", "Delivered"),
    );
    const outputSchedule = await schedule(
      "Produce Save As output",
      undefined,
      "full_access",
    );
    const outputDef = (await snapshot()).scheduledTasks.find(
      (item) => item.id === outputSchedule,
    );
    const outputStart = await invoke("metawork.scheduledTasks.runNow", {
      scheduledTaskId: outputSchedule,
      expectedEpoch: outputDef.epoch,
    });
    const outputTask = await completed(outputStart.taskId);
    const run = outputTask.runs.at(-1);
    assert.equal(run.outputs.length, 1);
    const save = {
      generation: connection,
      taskId: outputTask.id,
      runId: run.id,
      outputId: run.outputs[0].id,
      action: "save",
    };
    const saved = await openWithProgress(
      "save-confirm",
      "metawork.outputs.action",
      { ...save, operationId: "1" },
      `save to ${join(workspaceRoot, "saved-output.txt")}`,
    );
    assert.equal(saved.state, "saved", JSON.stringify(saved));
    assert.equal(
      await readFile(join(workspaceRoot, "saved-output.txt"), "utf8"),
      "Native Save As test\n",
    );
    const saveCancelled = await openWithProgress(
      "save-cancel",
      "metawork.outputs.action",
      { ...save, operationId: "2" },
      "Cancel",
    );
    assert.equal(
      saveCancelled.state,
      "cancelled",
      JSON.stringify(saveCancelled),
    );
  }
  const mcp = (await snapshot()).mcp;
  const server = await invoke("metawork.mcp.createStdioServer", {
    expectedDesiredGeneration: mcp.desiredGeneration,
    displayName: "Native confirmation paging",
    negotiation: "automatic",
    timeoutMs: 1000,
    command: "/usr/bin/true",
    arguments: Array(3).fill("x".repeat(3000)),
    cwd: null,
    environmentNames: [],
  });
  assert.equal(server.outcome, "saved", JSON.stringify(server));
  // Product creation already approves this exact fingerprint. Confirming it
  // again returns unchanged, mapped by the Host to the existing rejected wire outcome.
  const mcpCurrent = (await snapshot()).mcp;
  const serverId = mcpCurrent.servers.at(-1).id;
  await stage("mcp-hide-main");
  await ack("mcp-hide-main");
  for (const action of ["Cancel on page two", "approve only the final page"]) {
    await stage("mcp-pages", { action, serverId });
    const result = await invoke("metawork.mcp.approveConnection", {
      expectedDesiredGeneration: (await snapshot()).mcp.desiredGeneration,
      serverId,
    });
    observations.push({ label: action, result });
    assert.equal(
      result.outcome,
      action.startsWith("Cancel") ? "cancelled" : "rejected",
      JSON.stringify(result),
    );
  }
  // Stop while a real open panel remains pending: SDK abandon cannot be the
  // mechanism that releases the app-owned responder/preparing state.
  const quitPicker = invoke("metawork.workspaces.choose", {}).catch(() => null);
  await stage("quit-picker-visible");
  await ack("quit-picker-visible");
  await stop();
  await quitPicker;
  await writeFile(
    join(evidenceDir, "results.json"),
    JSON.stringify(
      {
        observations,
        gaps: [
          "Windows Esc/close matrix",
          "hidden-window parentless OAuth consent",
          "Root/Skill real picker smoke is collected by the assets scope",
        ],
      },
      null,
      2,
    ),
  );
  await stage("completed");
}
