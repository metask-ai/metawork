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
  droppedStreamSse,
  droppedToolStreamSse,
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

  // An accepted stream that drops after visible output is re-issued inside the
  // same Run once the Host grants a stream retry budget. The re-issue every
  // request has of its own does not reach this failure, so without the budget
  // the Run ends as a provider failure and the whole turn's work is lost.
  // Printed as each Run settles so the observation survives a failing
  // assertion below.
  function observe(scenario, taskId, run, requests, retryActivity) {
    const observation = {
      scenario,
      requests,
      retryActivity,
      outcome: run.terminal.outcome,
      cause: run.terminal.cause,
      responseKind: run.output.responseKind,
      response: run.output.response,
      commentary: run.output.commentary,
      modelError: run.terminal.modelError,
      feedback: run.terminal.feedback,
    };
    process.stdout.write(
      `agent boundary observation ${JSON.stringify(observation)}\n`,
    );
    evidence.push({ scenario, taskId, run, observation });
    return observation;
  }

  // text_drop is covered by the free per-request re-issue even with no budget;
  // tool_drop gets no free re-issue at all, and double_text_drop has already
  // spent it. The last two are the #83 loss, and the budget closes both.
  // The announced ceiling is the Host budget end to end: one attempt plus the
  // budget, plus the free re-issue only where the request started no tool call.
  const announcedMax = {
    text_drop: "4",
    tool_drop: "3",
    double_text_drop: "4",
  };
  for (const shape of ["text_drop", "tool_drop", "double_text_drop"]) {
    const id = await create(`Agent boundary stream ${shape}`);
    const before = provider.served;
    const drops = {
      text_drop: [
        droppedStreamSse("boundary-drop-text", "Dropped after visible text."),
      ],
      tool_drop: [
        droppedToolStreamSse(
          "boundary-drop-tool",
          "Dropped after a complete tool call.",
          path.join(workspaceRoot, `boundary-drop-${shape}.txt`),
        ),
      ],
      double_text_drop: [
        droppedStreamSse("boundary-drop-first", "First drop."),
        droppedStreamSse("boundary-drop-second", "Second drop."),
      ],
    }[shape];
    provider.enqueue(
      ...drops.map((body) => immediate(body)),
      immediate(textSse(`boundary-after-${shape}`, "Answer after the drops.")),
    );
    await send(id, `Exercise ${shape}.`, `boundary-stream-${shape}`);
    // Sampled tighter than the shared poll interval: the retry activity only
    // lives for the Core backoff between a drop and its re-issue.
    let retryActivity = null;
    const deadline = Date.now() + 180_000;
    while (Date.now() < deadline) {
      if (provider.error) throw provider.error;
      const observed = (await read(id))?.runs?.[0];
      if (observed?.activity?.kind === "retrying_provider")
        retryActivity = observed.activity;
      if (retryActivity !== null || observed?.terminal) break;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const task = await settled(id);
    const run = task.runs[0];
    const requests = provider.served - before;
    observe(shape, id, run, requests, retryActivity);
    // Every drop is re-issued, so the Run consumes the whole scripted
    // sequence exactly once and leaves nothing in the shared queue.
    assert.equal(
      requests,
      drops.length + 1,
      `${shape} did not re-issue every dropped stream exactly once`,
    );
    assert.equal(
      run.terminal.outcome,
      "completed",
      `${shape}: ${JSON.stringify(run.terminal)}`,
    );
    assert.equal(run.output.response, "Answer after the drops.");
    assert.equal(run.output.responseKind, "final");
    assert.equal(run.output.provisional, "");
    assert.equal(run.terminal.modelError, null);
    for (const discarded of ["First drop.", "Second drop.", "Dropped after"])
      assert.ok(
        !JSON.stringify(run.output).includes(discarded),
        `${shape} kept discarded output: ${JSON.stringify(run.output)}`,
      );
    assert.equal(retryActivity?.kind, "retrying_provider", `${shape} retry`);
    assert.equal(retryActivity.max, announcedMax[shape], `${shape} max`);
    assert.ok(Number(retryActivity.attempt) >= 1);
    assert.ok(Number(retryActivity.attempt) <= Number(retryActivity.max));
  }

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
    // The stream retry budget covers an accepted stream that dropped, never a
    // server-declared error, so the rejected second stream is not re-issued.
    if (mode === "provider_failure")
      assert.equal(
        provider.served - countBefore,
        2,
        "a server-declared error must not spend the stream retry budget",
      );
    evidence.push({ scenario: `continued_${mode}`, taskId: id, run });
    // A retained partial response must not poison the live Session.
    provider.enqueue(
      immediate(textSse("boundary-reuse", "Session remains usable.")),
    );
    await send(id, "Continue using this Session.", `boundary-reuse-${mode}`);
    const reused = await settled(id);
    assert.equal(reused.runs.at(-1).terminal.outcome, "completed");
  }
  // Exhausting the budget pins its value end to end, measured for both
  // shapes: a tool-call drop takes no free re-issue, so its total is one
  // attempt plus the budget, while a text-only drop also spends the free one.
  // Kept last: a Run that stops before the scripted drops run out would leave
  // them in the shared queue.
  for (const [shape, attempts] of [
    ["tool", 3],
    ["text", 4],
  ]) {
    const id = await create(`Agent boundary stream retry exhausted ${shape}`);
    const before = provider.served;
    provider.enqueue(
      ...Array.from({ length: attempts }, (_, index) =>
        immediate(
          shape === "tool"
            ? droppedToolStreamSse(
                `boundary-exhaust-${shape}-${index}`,
                "Dropped again.",
                path.join(workspaceRoot, `boundary-exhaust-${index}.txt`),
              )
            : droppedStreamSse(
                `boundary-exhaust-${shape}-${index}`,
                "Dropped again.",
              ),
        ),
      ),
    );
    await send(
      id,
      "Exhaust the stream retry budget.",
      `boundary-stream-exhausted-${shape}`,
    );
    const task = await settled(id);
    const run = task.runs[0];
    const requests = provider.served - before;
    observe(`budget_exhausted_${shape}`, id, run, requests, null);
    // No more than this: a further request would find an empty queue and fail
    // the fixture rather than pass unnoticed.
    assert.equal(requests, attempts, `${shape} exhaustion request count`);
    assert.equal(
      run.terminal.outcome,
      "failed",
      `${shape}: ${JSON.stringify(run.terminal)}`,
    );
    assert.equal(run.terminal.cause, "provider_failure");
    assert.equal(run.terminal.modelError.category, "stream_interrupted");
    // Core counts the attempts the Host counted requests.
    assert.equal(run.terminal.modelError.attempts, String(attempts));
    assert.equal(run.output.response, "");
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
