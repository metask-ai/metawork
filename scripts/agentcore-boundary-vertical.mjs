import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";

// Real Product/Agent/canonical Core. Only the loopback Provider is scripted.
export async function runAgentBoundaryVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  workspaceId,
  workspaceRoot,
  workspaceEpoch,
  catalog,
  evidenceDirectory,
}) {
  const read = async (id) =>
    (await snapshot({ taskId: id, includeManagement: false })).tasks.find(
      (task) => task.id === id,
    );
  const evidence = [];
  async function create(title) {
    const result = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },
      modelSelection: fixtureModelSelection(await snapshot()),
      expectedSkillCatalogRevision: catalog.revision,
      expectedSkillSelectionRevision: catalog.selectionRevision,
      approvalMode: "full_access",
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    await invoke("metawork.tasks.rename", { taskId: result.taskId, title });
    return result.taskId;
  }
  async function send(id, text, operationId) {
    const result = await invoke("metawork.tasks.sendInput", {
      taskId: id,
      operationId,
      input: { kind: "text", text },
    });
    assert.equal(result.outcome, "accepted", JSON.stringify(result));
  }
  const settled = (id) =>
    poll(
      async () => {
        if (provider.error) throw provider.error;
        const task = await read(id);
        return task?.activeOperation === null && task.runs.at(-1)?.terminal
          ? task
          : null;
      },
      180_000,
      "boundary Run terminal and checkpoint settled",
    );
  const immediate = (body) => ({ body, initialDelayMs: 0, frameDelayMs: 0 });
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
        return immediate(body);
      },
    };
    return state;
  }

  const forkId = await create("Agent boundary fork");
  let releaseFork;
  const forkGate = new Promise((resolve) => {
    releaseFork = resolve;
  });
  let forkTextDelivered = false;
  provider.enqueue(
    immediate(
      toolSse(
        "boundary-parent",
        "boundary-skill",
        "Skill",
        { name: "boundary-fork" },
        "Parent commentary.",
      ),
    ),
    {
      ...immediate(textSse("boundary-child", "Fork public text.")),
      beforeFrame: async (frame) => {
        if (JSON.parse(frame.slice(6)).type === "content_block_stop") {
          forkTextDelivered = true;
          await forkGate;
        }
      },
    },
    immediate(textSse("boundary-final", "Parent final answer.")),
  );
  try {
    await send(forkId, "Run the fork Skill.", "boundary-fork-root");
    await poll(
      async () =>
        forkTextDelivered &&
        (await read(forkId)).runs[0]?.output.provisional.includes(
          "Fork public text.",
        ),
      20_000,
      "fork public text is provisionally visible",
    );
    await send(forkId, "Keep this constraint.", "boundary-fork-input");
    const pending = (await read(forkId)).runs[0];
    assert.equal(pending.additionalInputs[0].afterOutputCount, 2);
  } finally {
    releaseFork();
  }
  const fork = await settled(forkId);
  const forkRun = fork.runs[0];
  assert.equal(forkRun.terminal.outcome, "completed", JSON.stringify(forkRun));
  assert.ok(forkRun.output.commentary.includes("Fork public text."));
  assert.equal(forkRun.output.response, "Parent final answer.");
  assert.equal(forkRun.additionalInputs[0].afterOutputCount, 2);
  assert.equal(forkRun.additionalInputs[0].state, "adopted");
  evidence.push({ scenario: "fork", taskId: forkId, run: forkRun });

  for (const mode of ["abort", "provider_failure", "max_turns"]) {
    const id = await create(`Agent boundary continued ${mode}`);
    const continued = textSse(`boundary-${mode}`, "retained.").replace(
      '"stop_reason":"end_turn"',
      '"stop_reason":"max_tokens"',
    );
    const next = gate(textSse("boundary-unused", "unused"));
    const countBefore = provider.served;
    if (mode === "max_turns") {
      // The canonical ABI v1 run cap used by Agent is 1000, not a probe override.
      provider.enqueue(
        ...Array.from({ length: 999 }, (_, index) =>
          immediate(
            toolSse(
              `boundary-turn-${index}`,
              `boundary-write-${index}`,
              "Write",
              {
                file_path: path.join(
                  workspaceRoot,
                  `boundary-turn-${index}.txt`,
                ),
                content: "x",
              },
            ),
          ),
        ),
        immediate(continued),
      );
    } else {
      provider.enqueue(
        immediate(continued),
        mode === "abort"
          ? next.fixture
          : {
              status: 400,
              body: JSON.stringify({
                error: {
                  type: "invalid_request_error",
                  message: "next stream rejected",
                },
              }),
            },
      );
    }
    try {
      await send(id, `Exercise continued ${mode}.`, `boundary-${mode}`);
      if (mode === "abort") {
        await poll(
          async () => next.entered,
          20_000,
          "next stream entered after continued",
        );
        await invoke("metawork.tasks.stop", { taskId: id });
      }
    } finally {
      next.release();
    }
    const task = await settled(id);
    const run = task.runs[0];
    assert.equal(run.output.responseKind, "partial", JSON.stringify(run));
    assert.ok(run.output.response.startsWith("retained."));
    assert.equal(run.output.provisional, "");
    assert.equal(
      run.terminal.outcome,
      mode === "abort"
        ? "cancelled"
        : mode === "max_turns"
          ? "stopped"
          : "failed",
      JSON.stringify(run.terminal),
    );
    if (mode === "max_turns") assert.equal(provider.served - countBefore, 1000);
    evidence.push({ scenario: `continued_${mode}`, taskId: id, run });
    // A retained partial response must not poison the live Session.
    provider.enqueue(
      immediate(textSse("boundary-reuse", "Session remains usable.")),
    );
    await send(id, "Continue using this Session.", `boundary-reuse-${mode}`);
    const reused = await settled(id);
    assert.equal(reused.runs.at(-1).terminal.outcome, "completed");
  }
  await mkdir(evidenceDirectory, { recursive: true });
  await writeFile(
    path.join(evidenceDirectory, "agent-boundary.json"),
    JSON.stringify(evidence, null, 2),
  );
  return async () => {
    for (const item of evidence) {
      const task = await read(item.taskId);
      assert.deepEqual(
        task.runs[0].output,
        item.run.output,
        `cold output: ${item.scenario}`,
      );
      assert.equal(task.runs[0].terminal.outcome, item.run.terminal.outcome);
    }
  };
}
