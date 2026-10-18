import assert from "node:assert/strict";

// Real Desktop → Bridge → Product → staged AgentCore. Only Provider replies are scripted.
export async function runActiveInputVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  workspaceId,
  workspaceEpoch,
  catalog,
  sendInRenderer,
  verifyRendererDraft,
}) {
  const read = async (id) =>
    (await snapshot()).tasks.find((task) => task.id === id);
  async function create(title) {
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
      expectedSkillCatalogRevision: catalog.catalog.revision,
      expectedSkillSelectionRevision: catalog.catalog.selectionRevision,
      approvalMode: "manual",
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    await invoke("metawork.tasks.rename", { taskId: result.taskId, title });
    return read(result.taskId);
  }
  function gate(body) {
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
        return typeof body === "string"
          ? { body, initialDelayMs: 0, frameDelayMs: 0 }
          : body;
      },
    };
    return state;
  }
  async function start(task, input, entries) {
    provider.enqueue(...entries);
    const result = await invoke("metawork.tasks.sendInput", {
      operationId: `start-${task.id}`,
      taskId: task.id,
      expectedBindingEpoch: task.binding.epoch,
      expectedExecution: { kind: "idle", lastRunId: null },
      input,
    });
    assert.equal(result.outcome, "started", JSON.stringify(result));
    return result.runId;
  }
  async function submit(task, runId, text, operationId) {
    return invoke("metawork.tasks.sendInput", {
      operationId,
      taskId: task.id,
      expectedBindingEpoch: task.binding.epoch,
      expectedExecution: { kind: "run", runId },
      input: { kind: "text", text },
    });
  }
  const waitGate = (g) =>
    poll(async () => g.entered, 10_000, "current Run Provider request");
  const settled = (id) =>
    poll(
      async () => {
        if (provider.error) throw provider.error;
        const task = await read(id);
        return task?.activeOperation === null && task.runs.at(-1)?.terminal
          ? task
          : null;
      },
      30_000,
      "current Run settled",
    );
  async function assertNoSuccessor(task) {
    for (let i = 0; i < 3; i++) {
      const current = await read(task.id);
      assert.equal(current.runs.length, 1);
      assert.equal(current.activeOperation, null);
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  const command =
    process.platform === "win32"
      ? 'powershell -NoProfile -Command "Write-Output active-input"'
      : "printf active-input";
  const adopted = await create("Current Run input audit");
  const parent = gate(
    toolSse("active-tool", "active-command", "Bash", {
      command,
      description: "Require an explicit permission answer",
    }),
  );
  const text =
    "Preserve this explicit constraint\nhttps://example.test/" +
    "long-segment-".repeat(25) +
    "\n后续消息保持在当前运行中。";
  const runId = await start(adopted, { kind: "text", text: "Review" }, [
    parent.fixture,
    (payload) => {
      const encoded = JSON.stringify(payload);
      assert.ok(encoded.includes("Preserve this explicit constraint"));
      assert.ok(
        encoded.includes("Additional constraint during permission wait"),
      );
      return {
        body: textSse("active-final", "current Run received both constraints"),
        initialDelayMs: 0,
        frameDelayMs: 0,
      };
    },
  ]);
  let retainedDraft = null;
  try {
    await waitGate(parent);
    if (sendInRenderer) retainedDraft = await sendInRenderer(adopted.id, text);
    else
      assert.equal(
        (await submit(adopted, runId, text, "active-first")).outcome,
        "submitted",
      );
    let current = await read(adopted.id);
    assert.equal(current.runs.length, 1);
    assert.equal(current.runs[0].additionalInputs[0].state, "pending");
    parent.release();
    current = await poll(
      async () => {
        const task = await read(adopted.id);
        return task.pendingUi?.runId === runId ? task : null;
      },
      20_000,
      "permission wait remains independent of interjection",
    );
    const pending = current.pendingUi;
    assert.equal(
      (
        await submit(
          adopted,
          runId,
          "Additional constraint during permission wait",
          "active-ui-wait",
        )
      ).outcome,
      "submitted",
    );
    current = await read(adopted.id);
    assert.equal(current.pendingUi.requestId, pending.requestId);
    assert.ok(
      current.runs[0].additionalInputs.every(
        (message) => message.state === "pending",
      ),
    );
    await invoke("metawork.tasks.respondUi", {
      taskId: adopted.id,
      runId,
      requestId: pending.requestId,
      kind: "permission",
      permission: "deny_once",
    });
  } finally {
    parent.release();
  }
  const complete = await settled(adopted.id);
  assert.equal(complete.runs[0].terminal.outcome, "completed");
  assert.deepEqual(
    complete.runs[0].additionalInputs.map((message) => message.state),
    ["adopted", "adopted"],
  );
  assert.deepEqual(
    complete.runs[0].additionalInputs.map((message) => message.sequence),
    [1, 2],
  );
  assert.ok(
    complete.runs[0].additionalInputs.every(
      (message) => message.order !== null && message.adoptedTurn !== null,
    ),
  );
  await assertNoSuccessor(adopted);
  if (retainedDraft && verifyRendererDraft)
    await verifyRendererDraft(adopted.id, retainedDraft);

  for (const mode of ["final", "stop", "failure"]) {
    const task = await create(`Input ${mode} audit`);
    const response = gate(
      mode === "failure"
        ? {
            status: 400,
            body: JSON.stringify({
              type: "error",
              error: {
                type: "invalid_request_error",
                message: "active input fixture failure",
              },
            }),
          }
        : textSse(`input-${mode}`, "final answer closes this Run"),
    );
    const id = await start(task, { kind: "text", text: "Review" }, [
      response.fixture,
    ]);
    try {
      await waitGate(response);
      const receipt = await submit(
        task,
        id,
        "Never launch a successor for this input",
        `input-${mode}`,
      );
      assert.equal(receipt.outcome, "submitted", JSON.stringify(receipt));
      if (mode === "stop")
        await invoke("metawork.tasks.cancel", { taskId: task.id, runId: id });
    } finally {
      response.release();
    }
    const result = await settled(task.id);
    assert.equal(result.runs[0].additionalInputs[0].state, "unadopted");
    await assertNoSuccessor(task);
    const late = await submit(
      task,
      id,
      "Late text cannot become a new Run",
      `late-${mode}`,
    );
    assert.equal(late.outcome, "rejected");
    assert.equal((await read(task.id)).runs.length, 1);
  }

  const skill = await create("Skill Run rejects interjection");
  const skillReply = gate(textSse("skill-final", "typed Skill complete"));
  const skillId = await start(
    skill,
    {
      kind: "skill",
      skillId: catalog.skill.skillId,
      catalogRevision: catalog.catalog.revision,
      selectionRevision: catalog.catalog.selectionRevision,
      argumentValues: ["active-skill-target"],
    },
    [skillReply.fixture],
  );
  try {
    await waitGate(skillReply);
    assert.equal(
      (await submit(skill, skillId, "must stay a draft", "skill-refusal"))
        .reason,
      "unsupported_input",
    );
    assert.equal((await read(skill.id)).runs[0].additionalInputs.length, 0);
  } finally {
    skillReply.release();
  }
  await settled(skill.id);

  const restart = await create("Input restart audit");
  const restartId = await start(restart, { kind: "text", text: "Review" }, [
    {
      body: toolSse("restart-tool", "restart-command", "Bash", {
        command,
        description: "Wait for permission across shutdown",
      }),
      initialDelayMs: 0,
      frameDelayMs: 0,
    },
  ]);
  await poll(
    async () => (await read(restart.id)).pendingUi,
    20_000,
    "restart permission wait",
  );
  assert.equal(
    (
      await submit(
        restart,
        restartId,
        "History only after restart",
        "restart-input",
      )
    ).outcome,
    "submitted",
  );
  return async () => {
    const current = await read(restart.id);
    assert.equal(current.sendInputResult, null);
    assert.equal(current.runs.length, 1);
    assert.ok(
      ["unadopted", "unknown"].includes(
        current.runs[0].additionalInputs[0].state,
      ),
    );
    assert.equal(
      current.runs[0].additionalInputs[0].text,
      "History only after restart",
    );
    await assertNoSuccessor(current);
    const restored = await read(adopted.id);
    assert.deepEqual(
      restored.runs[0].additionalInputs.map((message) => message.state),
      ["adopted", "adopted"],
    );
    console.log(
      "AgentCore active input: real receipt, tool-boundary adoption, independent permission, final/stop/failure, Skill refusal and restart without replay passed.",
    );
  };
}
