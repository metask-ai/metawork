import assert from "node:assert/strict";
import { access } from "node:fs/promises";
import { join } from "node:path";

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
  workspaceRoot,
  catalog,
  sendInRenderer,
  observeReadingBeforeAdoption,
  verifyRendererDraft,
  observeTransferred,
}) {
  const read = async (id) =>
    (await snapshot()).tasks.find((task) => task.id === id);
  async function create(title, approvalMode = "manual", rename = true) {
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
      approvalMode,
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    if (rename)
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
      input,
    });
    assert.equal(result.outcome, "accepted", JSON.stringify(result));
    const current = await poll(
      async () => {
        const state = await read(task.id);
        return (
          state.runs.find(
            (run) => run.submission?.operationId === `start-${task.id}`,
          ) ?? null
        );
      },
      10_000,
      "accepted root enters its Run",
    );
    return current.id;
  }
  async function submit(task, runId, text, operationId) {
    return invoke("metawork.tasks.sendInput", {
      operationId,
      taskId: task.id,
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
        return task?.activeOperation === null &&
          task.runs.at(-1)?.terminal &&
          !task.runs.some((run) =>
            run.additionalInputs.some((input) => input.state === "continuing"),
          )
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
  const permissionMarker = join(
    workspaceRoot,
    "active-input-permission-needed.txt",
  );
  const command =
    process.platform === "win32"
      ? `powershell -NoProfile -Command "Set-Content -LiteralPath '${permissionMarker.replaceAll("'", "''")}' -Value active-input"`
      : `touch '${permissionMarker.replaceAll("'", "'\\''")}'`;
  const adopted = await create("Current Run input audit");
  const parent = gate(
    toolSse(
      "active-tool",
      "active-command",
      "Bash",
      {
        command,
        description: "Require an explicit permission answer",
      },
      "Explanation before the second interjection.\n\n" +
        "A visible commentary paragraph keeps the earlier reading surface available.\n\n".repeat(
          18,
        ),
    ),
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
        "accepted",
      );
    let current = await read(adopted.id);
    assert.equal(current.runs.length, 1);
    assert.equal(current.runs[0].additionalInputs[0].state, "pending");
    assert.equal(current.runs[0].additionalInputs[0].afterOutputCount, 0);
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
      "accepted",
    );
    current = await read(adopted.id);
    assert.equal(current.pendingUi.requestId, pending.requestId);
    assert.equal(current.runs[0].additionalInputs[1].afterOutputCount, 1);
    assert.ok(
      current.runs[0].additionalInputs.every(
        (message) => message.state === "pending",
      ),
    );
    if (observeReadingBeforeAdoption)
      await observeReadingBeforeAdoption(adopted.id);
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
  await assert.rejects(access(permissionMarker), { code: "ENOENT" });
  if (retainedDraft && verifyRendererDraft)
    await verifyRendererDraft(adopted.id, retainedDraft);

  const reviewTask = await create(
    "Pending input blocks automatic allow",
    "auto_review",
  );
  const marker = join(workspaceRoot, "active-input-must-not-execute.txt");
  const reviewCommand =
    process.platform === "win32"
      ? `powershell -NoProfile -Command "Set-Content -LiteralPath '${marker.replaceAll("'", "''")}' -Value unexpected"`
      : `touch '${marker.replaceAll("'", "'\\''")}'`;
  const reviewRun = await start(
    reviewTask,
    { kind: "text", text: "input-review-constraint" },
    [
      {
        body: toolSse("input-review-tool", "input-review-command", "Bash", {
          command: reviewCommand,
        }),
        initialDelayMs: 0,
        frameDelayMs: 0,
      },
      (payload) => {
        assert.ok(
          JSON.stringify(payload).includes(
            "Do not execute the pending command",
          ),
        );
        return {
          body: textSse(
            "input-review-final",
            "The user constraint was adopted after manual refusal",
          ),
          initialDelayMs: 0,
          frameDelayMs: 0,
        };
      },
    ],
  );
  await poll(
    async () => provider.inputReviewRequests === 1,
    20_000,
    "real automatic review is waiting",
  );
  const reviewRequest = (await read(reviewTask.id)).pendingUi;
  try {
    assert.equal(
      (
        await submit(
          reviewTask,
          reviewRun,
          "Do not execute the pending command",
          "review-veto",
        )
      ).outcome,
      "accepted",
    );
  } finally {
    provider.releaseReview();
  }
  const manual = await poll(
    async () => {
      const task = await read(reviewTask.id);
      return task.permissionReviewState === "needs_user" &&
        task.pendingUi?.requestId === reviewRequest.requestId
        ? task
        : null;
    },
    20_000,
    "unadopted constraint turns automatic allow into manual attention",
  );
  assert.equal(manual.runs[0].additionalInputs[0].state, "pending");
  await assert.rejects(access(marker), { code: "ENOENT" });
  await invoke("metawork.tasks.respondUi", {
    taskId: reviewTask.id,
    runId: reviewRun,
    requestId: reviewRequest.requestId,
    kind: "permission",
    permission: "deny_once",
  });
  const reviewed = await settled(reviewTask.id);
  assert.equal(reviewed.runs[0].additionalInputs[0].state, "adopted");
  assert.equal(provider.inputReviewRequests, 1);
  await assert.rejects(access(marker), { code: "ENOENT" });
  await assertNoSuccessor(reviewTask);

  const transferredHistory = [];
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
        : {
            body: textSse(
              `input-${mode}`,
              "This original answer was already streaming before the follow-up question.\n\n".repeat(
                8,
              ),
            ),
            initialDelayMs: 0,
            frameDelayMs: mode === "final" ? 500 : 0,
          },
    );
    const next = gate(
      textSse(
        "continued-final",
        "The next Run processed both follow-up messages.",
      ),
    );
    const first = "How many are still active?";
    const second = "Summarize them in Chinese.";
    const merged = `${first}\n\n${second}`;
    const id = await start(task, { kind: "text", text: "Review" }, [
      response.fixture,
      ...(mode === "final"
        ? [
            (payload) => {
              assert.ok(
                JSON.stringify(payload).includes(
                  JSON.stringify(merged).slice(1, -1),
                ),
              );
              return next.fixture();
            },
          ]
        : []),
    ]);
    try {
      await waitGate(response);
      if (mode === "final") {
        response.release();
        await poll(
          async () => {
            const run = (await read(task.id)).runs[0];
            return run.output.provisional.length > 0 && run.phase === "running";
          },
          10_000,
          "source final response visibly streaming",
        );
      }
      const receipt = await submit(
        task,
        id,
        mode === "final" ? first : "Do not continue after Stop or failure",
        `input-${mode}`,
      );
      assert.equal(receipt.outcome, "accepted", JSON.stringify(receipt));
      if (mode === "final") {
        assert.equal(
          (await submit(task, id, second, "input-final-second")).outcome,
          "accepted",
        );
        assert.deepEqual(
          (await read(task.id)).runs[0].additionalInputs.map(
            (input) => input.afterOutputCount,
          ),
          [1, 1],
        );
      }
      if (mode === "stop")
        await invoke("metawork.tasks.cancel", { taskId: task.id, runId: id });
    } finally {
      response.release();
    }
    if (mode === "final") {
      try {
        await waitGate(next);
        const transferred = await read(task.id);
        assert.equal(transferred.runs.length, 2);
        const target = transferred.runs[1];
        assert.equal(target.input.text, merged);
        assert.equal(transferred.runs[0].terminal.outcome, "completed");
        assert.deepEqual(
          transferred.runs[0].additionalInputs.map((input) => [
            input.state,
            input.transferredToRunId,
          ]),
          [
            ["transferred", target.id],
            ["transferred", target.id],
          ],
        );
        await invoke("metawork.tasks.cancel", { taskId: task.id, runId: id });
        assert.equal((await read(task.id)).currentRunId, target.id);
        assert.equal((await read(task.id)).currentRunPhase, "running");
        if (observeTransferred) await observeTransferred(task.id, target.id);
        transferredHistory.push({
          taskId: task.id,
          targetId: target.id,
          text: merged,
        });
      } finally {
        next.release();
      }
      const result = await settled(task.id);
      assert.equal(result.runs.length, 2);
      assert.equal(result.runs[1].terminal.outcome, "completed");
      for (let i = 0; i < 3; i++)
        assert.equal((await read(task.id)).runs.length, 2);
    } else {
      const result = await settled(task.id);
      assert.equal(result.runs[0].additionalInputs[0].state, "unadopted");
      await assertNoSuccessor(task);
    }
    provider.enqueue({
      body: textSse(
        `new-${mode}`,
        "A new explicit message is accepted after the previous Run.",
      ),
      initialDelayMs: 0,
      frameDelayMs: 0,
    });
    const late = await submit(
      task,
      id,
      "A new explicit intent",
      `late-${mode}`,
    );
    assert.equal(late.outcome, "accepted");
    const withNew = await settled(task.id);
    assert.equal(withNew.runs.length, mode === "final" ? 3 : 2);
  }

  const skill = await create("Skill Run retains the next message");
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
    provider.enqueue({
      body: textSse("after-skill", "The waiting message ran after the Skill."),
      initialDelayMs: 0,
      frameDelayMs: 0,
    });
    const waiting = await submit(
      skill,
      skillId,
      "wait behind the Skill",
      "after-skill",
    );
    assert.equal(waiting.outcome, "accepted");
    assert.equal((await read(skill.id)).inputSubmissions[0].state, "waiting");
    assert.equal((await read(skill.id)).runs[0].additionalInputs.length, 0);
  } finally {
    skillReply.release();
  }
  const afterSkill = await settled(skill.id);
  assert.equal(afterSkill.runs.length, 2);

  // Reproduces the original failure window with the real canonical Core:
  // the root is completed while its independent title worker still owns a lease.
  const titleTask = await create(
    "Title cleanup accepts input",
    "manual",
    false,
  );
  const titleGate = provider.holdNextTitle();
  const titleRoot = await start(titleTask, { kind: "text", text: "Review" }, [
    {
      body: textSse("title-root", "Root finished"),
      initialDelayMs: 0,
      frameDelayMs: 0,
    },
  ]);
  try {
    await poll(
      async () => titleGate.entered,
      10_000,
      "title completion held after root terminal",
    );
    provider.enqueue({
      body: textSse("after-title", "After title"),
      initialDelayMs: 0,
      frameDelayMs: 0,
    });
    for (const id of ["A", "B", "C"]) {
      const result = await submit(
        titleTask,
        titleRoot,
        `waiting ${id}`,
        `title-${id}`,
      );
      assert.equal(result.outcome, "accepted");
    }
    const waiting = await read(titleTask.id);
    assert.equal(waiting.runs.length, 1);
    assert.deepEqual(
      waiting.inputSubmissions.map((record) => record.submission.operationId),
      ["title-A", "title-B", "title-C"],
    );
    await invoke("metawork.tasks.stop", { taskId: titleTask.id });
    assert.ok(
      (await read(titleTask.id)).inputSubmissions.every(
        (record) => record.state === "cancelled",
      ),
    );
    assert.equal(
      (
        await submit(
          titleTask,
          titleRoot,
          "after stop new intent",
          "title-after-stop",
        )
      ).outcome,
      "accepted",
    );
  } finally {
    titleGate.release();
  }
  const titleDone = await settled(titleTask.id);
  assert.equal(titleDone.runs.length, 2);
  assert.equal(titleDone.runs[1].submission.operationId, "title-after-stop");

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
    "accepted",
  );
  return async () => {
    const current = await read(restart.id);
    assert.equal(current.sendInputResult, undefined);
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
    for (const saved of transferredHistory) {
      const task = await read(saved.taskId);
      assert.equal(task.runs.length, 3);
      assert.equal(task.runs[1].id, saved.targetId);
      assert.equal(task.runs[1].input.text, saved.text);
      assert.deepEqual(
        task.runs[0].additionalInputs.map((input) => [
          input.state,
          input.transferredToRunId,
          input.afterOutputCount,
        ]),
        [
          ["transferred", saved.targetId, 1],
          ["transferred", saved.targetId, 1],
        ],
      );
      if (observeTransferred)
        await observeTransferred(saved.taskId, saved.targetId);
    }
    const restored = await read(adopted.id);
    assert.deepEqual(
      restored.runs[0].additionalInputs.map(
        (message) => message.afterOutputCount,
      ),
      [0, 1],
    );
    assert.deepEqual(
      restored.runs[0].additionalInputs.map((message) => message.state),
      ["adopted", "adopted"],
    );
    console.log(
      "AgentCore active input: real receipt, boundary adoption, one merged continuation after streaming final output, old-source Stop isolation, stop/failure without continuation, Skill waiting and restart without replay passed.",
    );
  };
}
