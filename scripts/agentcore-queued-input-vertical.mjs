import assert from "node:assert/strict";

// Uses the real desktop Bridge, Product owners and staged AgentCore. Only model responses are scripted.
export async function runQueuedInputVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  workspaceId,
  workspaceEpoch,
  catalog,
  queueInRenderer,
  verifyRendererDraft,
}) {
  const readTask = async (id) =>
    (await snapshot()).tasks.find((task) => task.id === id);
  const create = async (title, pinned = true) => {
    const admission = (await snapshot()).newTaskAdmission;
    const result = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },
      expectedExecutionGeneration: admission.activeGeneration,
      expectedSelectionRevision: admission.activeSelectionRevision,
      modelSelection: null,
      expectedSkillCatalogRevision: pinned ? catalog.catalog.revision : null,
      expectedSkillSelectionRevision: pinned
        ? catalog.catalog.selectionRevision
        : null,
      approvalMode: "manual",
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    if (title)
      await invoke("metawork.tasks.rename", { taskId: result.taskId, title });
    return readTask(result.taskId);
  };
  function gate(value) {
    let release;
    const promise = new Promise((resolve) => {
      release = resolve;
    });
    const state = {
      entered: false,
      release,
      fixture: async () => {
        state.entered = true;
        await promise;
        return value;
      },
    };
    return state;
  }
  async function start(taskId, text, entries) {
    provider.enqueue(...entries);
    const task = await readTask(taskId);
    const result = await invoke("metawork.tasks.run", {
      taskId,
      expectedBindingEpoch: task.binding.epoch,
      input: { kind: "text", text },
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    return result.runId;
  }
  async function queue(taskId, runId, input, operationId) {
    const task = await readTask(taskId);
    const result = await invoke("metawork.tasks.queueInput", {
      operationId,
      taskId,
      expectedBindingEpoch: task.binding.epoch,
      runId,
      input,
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    return result.revision;
  }
  async function withdraw(taskId, queued, operationId) {
    const result = await invoke("metawork.tasks.withdrawQueuedInput", {
      operationId,
      taskId,
      runId: queued.runId,
      revision: queued.revision,
    });
    assert.equal(result.withdrawn, true, JSON.stringify(result));
    return result;
  }
  const settled = async (id, count) =>
    poll(
      async () => {
        const task = await readTask(id);
        const last = task.runs.at(-1);
        return task.runs.length === count &&
          task.activeOperation === null &&
          last?.terminal
          ? task
          : null;
      },
      30_000,
      `queued input Task ${id} ${count} settled Runs`,
    );

  const audit = await create("Queued input audit");
  const id = audit.id;
  const normalText =
    "Queue follow up marker\nhttps://example.test/" +
    "long-segment-".repeat(25) +
    "\n后续消息保持独立。";
  const first = gate(textSse("queue-parent-result", "queue parent finished"));
  const parentId = await start(id, "queue-parent", [
    first.fixture,
    {
      body: textSse("queue-successor-result", "queue successor finished"),
      initialDelayMs: 0,
      frameDelayMs: 0,
    },
  ]);
  try {
    await poll(
      async () => first.entered,
      10_000,
      "queued input real Core request",
    );
    if (queueInRenderer) await queueInRenderer(id, normalText);
    else
      await queue(
        id,
        parentId,
        { kind: "text", text: normalText },
        "queue-normal",
      );
    const waiting = await readTask(id);
    assert.equal(waiting.runs.length, 1);
    assert.equal(waiting.queuedInput.state, "waiting");
    const refusal = await invoke("metawork.tasks.run", {
      taskId: id,
      expectedBindingEpoch: waiting.binding.epoch,
      input: { kind: "text", text: "must not bypass queued input" },
    });
    assert.equal(refusal.reason, "queued_input_present");
  } finally {
    first.release();
  }
  const releasedAt = Date.now();
  let current = await settled(id, 2);
  assert.equal(current.queuedInput, null);
  assert.equal(current.runs[1].input.text, normalText);
  assert.equal(current.runs[1].terminal.outcome, "completed");
  assert.ok(Number(current.runs[1].submittedAtUnixMs) >= releasedAt - 100);
  for (let i = 0; i < 3; i++) assert.equal((await readTask(id)).runs.length, 2);
  if (verifyRendererDraft)
    await verifyRendererDraft(id, "Draft kept while queued Run starts");
  console.log(
    "AgentCore queued input: normal completion starts exactly one successor; Renderer draft survives.",
  );

  const stopped = gate(
    textSse("queue-stopped-parent", "not normally completed"),
  );
  const stoppedId = await start(id, "queue-stop-parent", [stopped.fixture]);
  try {
    await poll(
      async () => stopped.entered,
      10_000,
      "queued stop real Core request",
    );
    await queue(
      id,
      stoppedId,
      { kind: "text", text: "held after ordinary stop" },
      "queue-stop",
    );
    await invoke("metawork.tasks.cancel", { taskId: id, runId: stoppedId });
  } finally {
    stopped.release();
  }
  current = await settled(id, 3);
  assert.equal(current.queuedInput.state, "held");
  assert.equal(current.queuedInput.heldReason, "stopped_by_user");
  await withdraw(id, current.queuedInput, "withdraw-stopped");
  await new Promise((resolve) => setTimeout(resolve, 50));
  console.log(
    "AgentCore queued input: ordinary stop retains input without starting a Run.",
  );

  const skillParent = gate(
    textSse("queue-skill-parent-result", "skill parent finished"),
  );
  const skillInput = {
    kind: "skill",
    skillId: catalog.skill.skillId,
    catalogRevision: catalog.catalog.revision,
    selectionRevision: catalog.catalog.selectionRevision,
    argumentValues: ["queued-skill-target"],
  };
  const skillParentId = await start(id, "queue-skill-parent", [
    skillParent.fixture,
    (payload) => {
      const encoded = JSON.stringify(payload);
      assert.ok(encoded.includes("METAWORK_TYPED_SKILL_VERTICAL"));
      assert.ok(encoded.includes("queued-skill-target"));
      return {
        body: textSse("queue-skill-result", "typed queued Skill finished"),
        initialDelayMs: 0,
        frameDelayMs: 0,
      };
    },
  ]);
  try {
    await poll(
      async () => skillParent.entered,
      10_000,
      "queued Skill parent request",
    );
    await queue(id, skillParentId, skillInput, "queue-skill");
  } finally {
    skillParent.release();
  }
  current = await settled(id, 5);
  assert.equal(current.queuedInput, null);
  assert.equal(current.runs[4].input.kind, "skill");
  assert.deepEqual(current.runs[4].input.argumentValues, [
    "queued-skill-target",
  ]);
  await new Promise((resolve) => setTimeout(resolve, 50));
  console.log(
    "AgentCore queued input: pinned Skill is materialized only in the successor Run.",
  );

  const failure = gate({
    status: 400,
    body: JSON.stringify({
      type: "error",
      error: {
        type: "invalid_request_error",
        message: "queued input failure fixture",
      },
    }),
  });
  const failureId = await start(id, "queue-failure-parent", [failure.fixture]);
  try {
    await poll(
      async () => failure.entered,
      10_000,
      "queued failure parent request",
    );
    await queue(
      id,
      failureId,
      { kind: "text", text: "held after failed Run" },
      "queue-failure",
    );
  } finally {
    failure.release();
  }
  current = await settled(id, 6);
  assert.equal(current.runs.at(-1).terminal.outcome, "failed");
  assert.equal(current.queuedInput.state, "held");
  assert.equal(current.queuedInput.heldReason, "run_not_completed");
  await withdraw(id, current.queuedInput, "withdraw-failed");
  console.log(
    "AgentCore queued input: actual provider failure retains input without replay.",
  );

  provider.holdQueuedTitle("queue-title-probe");
  const titleTask = await create(null, false);
  const titleParent = gate(
    textSse("queue-title-parent-result", "title parent finished"),
  );
  const titleRun = await start(titleTask.id, "queue-title-probe", [
    titleParent.fixture,
    {
      body: textSse("queue-title-successor", "after title settled"),
      initialDelayMs: 0,
      frameDelayMs: 0,
    },
  ]);
  try {
    await poll(
      async () => titleParent.entered,
      10_000,
      "queued title parent request",
    );
    await queue(
      titleTask.id,
      titleRun,
      { kind: "text", text: "after title" },
      "queue-title",
    );
    titleParent.release();
    await poll(
      async () => provider.queuedTitleEntered,
      10_000,
      "real first title Completion",
    );
    const heldByTitle = await readTask(titleTask.id);
    assert.equal(heldByTitle.runs.length, 1);
    assert.equal(heldByTitle.queuedInput.state, "waiting");
  } finally {
    titleParent.release();
    provider.releaseQueuedTitle();
  }
  const titled = await settled(titleTask.id, 2);
  assert.equal(titled.queuedInput, null);
  assert.equal(titled.runs[1].input.text, "after title");
  console.log(
    "AgentCore queued input: first title Completion holds admission until its final lease releases.",
  );

  const restart = await create("Queued restart audit");
  const restartRun = await start(restart.id, "queue-restart-parent", [
    {
      body: toolSse("queue-restart-tool", "queue-restart-command", "Bash", {
        command:
          process.platform === "win32"
            ? 'powershell -NoProfile -Command "Write-Output queued-restart"'
            : "printf queued-restart",
        description: "Wait for explicit approval before restart",
      }),
      initialDelayMs: 0,
      frameDelayMs: 0,
    },
  ]);
  await poll(
    async () => {
      const task = await readTask(restart.id);
      return task.pendingUi?.runId === restartRun ? task : null;
    },
    20_000,
    "queued restart approval wait",
  );
  await queue(
    restart.id,
    restartRun,
    { kind: "text", text: "must not replay after restart" },
    "queue-restart",
  );
  return async () => {
    for (let i = 0; i < 3; i++) {
      const restored = await readTask(restart.id);
      assert.equal(restored.queuedInput, null);
      assert.equal(restored.queuedInputResult, null);
      assert.equal(restored.runs.length, 1);
      assert.equal(restored.activeOperation, null);
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    console.log(
      "AgentCore queued input: restart discards slot and receipt, with no automatic replay.",
    );
  };
}
