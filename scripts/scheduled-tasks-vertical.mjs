import assert from "node:assert/strict";
import { createServer } from "node:http";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { protocolTextSse } from "../tests/fixtures/provider_protocol.mjs";

// The desktop, Product, persistence, OS timer and staged Core are real. Only
// Provider replies are scripted; this does not measure model output quality.
export async function runScheduledTasksVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  restart,
  dataRoot,
  evidenceDir,
}) {
  const observations = [];
  const wait = (fn, label, timeout = 30_000) => poll(fn, timeout, label);
  const now = () => Math.floor(Date.now() / 1000);
  const read = async (id) =>
    (await snapshot()).scheduledTasks.find((item) => item.id === id);
  const binding = async () => {
    const current = await snapshot();
    const admission = current.newTaskAdmission;
    assert.equal(admission.available, true);
    assert.deepEqual(current.models.defaultSelection, admission.activeModelRef);
    const source = [
      ...current.models.providers,
      ...current.models.customProviders,
    ].find((item) => item.id === admission.activeModelRef.sourceId);
    return {
      modelRef: admission.activeModelRef,
      sourceGeneration: source.sourceGeneration,
      selectionRevision: admission.activeSelectionRevision,
      protocol: admission.activeProtocol,
    };
  };
  const definition = async (title, recurrence) => ({
    title,
    binding: await binding(),
    permissionProfile: "approval_required",
    input: { kind: "text", text: title },
    recurrence,
  });
  const create = async (
    title,
    recurrence = { kind: "once", atUnixSeconds: String(now() + 3600) },
  ) => {
    const result = await invoke(
      "metawork.scheduledTasks.create",
      await definition(title, recurrence),
    );
    assert.equal(result.accepted, true);
    return read(result.scheduledTaskId);
  };
  const completed = async (id, taskId) =>
    wait(async () => {
      const state = await snapshot();
      const schedule = state.scheduledTasks.find((item) => item.id === id);
      const occurrence = schedule.occurrences.find(
        (item) => item.taskId === taskId && item.result === "submitted",
      );
      const task = state.tasks.find((item) => item.id === taskId);
      if (!occurrence?.taskOutcome || !task?.runs.at(-1)?.terminal) return null;
      assert.equal(occurrence.taskOutcome, "completed");
      assert.equal(task.runs.at(-1).terminal.outcome, "completed");
      assert.equal(task.runs.at(-1).permissionInteraction, "noninteractive");
      assert.equal(
        state.workspaces.find((item) => item.id === task.workspaceId).kind,
        "automatic",
      );
      return { schedule, task };
    }, "real scheduled Task completion");
  const initial = await snapshot();
  assert.equal(initial.capabilities.scheduledTaskPersistenceHealth, "ready");
  assert.equal(initial.capabilities.backgroundScheduleWake, true);
  const schedule = await create("Scheduled desktop review");
  provider.enqueue(textSse("schedule-manual", "Manual scheduled result"));
  const manual = await invoke("metawork.scheduledTasks.runNow", {
    scheduledTaskId: schedule.id,
    expectedEpoch: schedule.epoch,
  });
  const first = await completed(schedule.id, manual.taskId);
  observations.push({
    label: "manual",
    binding: schedule.binding,
    taskId: first.task.id,
    workspaceId: first.task.workspaceId,
  });

  console.log(
    "Scheduled vertical: manual Task completed through canonical Core.",
  );
  let release;
  let entered = false;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  provider.enqueue(async () => {
    entered = true;
    await gate;
    return {
      body: textSse("schedule-timer", "Timed scheduled result"),
      initialDelayMs: 0,
      frameDelayMs: 0,
    };
  });
  const start = now() + 4;
  await invoke("metawork.scheduledTasks.update", {
    scheduledTaskId: schedule.id,
    expectedEpoch: schedule.epoch,
    ...(await definition("Scheduled desktop review", {
      kind: "interval",
      startAtUnixSeconds: String(start),
      everySeconds: "60",
    })),
  });
  const updated = await read(schedule.id);
  try {
    await wait(async () => entered, "OS timer to real Core Provider");
    const running = await read(schedule.id);
    const timed = running.occurrences.at(-1);
    assert.equal(timed.source, "timer");
    assert.equal(timed.plannedAtUnixSeconds, String(start));
    assert.notEqual(timed.taskId, manual.taskId);
    await assert.rejects(
      invoke("metawork.scheduledTasks.runNow", {
        scheduledTaskId: schedule.id,
        expectedEpoch: updated.epoch,
      }),
      (error) => error.bridgeResponseError?.message === "TaskBusy",
    );
    const skipped = await wait(
      async () =>
        (await read(schedule.id)).occurrences.find(
          (item) => item.result === "skipped",
        ),
      "OS timer overlap skip",
      80_000,
    );
    assert.equal(skipped.taskId, timed.taskId);
    assert.equal(skipped.reason, "previous_task_running");
    assert.equal(skipped.plannedAtUnixSeconds, String(start + 60));
    console.log(
      "Scheduled vertical: OS timer preserved the blocker and skipped overlap.",
    );
    release();
    const second = await completed(schedule.id, timed.taskId);
    assert.notEqual(first.task.workspaceId, second.task.workspaceId);
    observations.push({
      label: "timer-and-skip",
      taskId: timed.taskId,
      blockerTaskId: skipped.taskId,
      plannedAt: timed.plannedAtUnixSeconds,
      skippedAt: skipped.plannedAtUnixSeconds,
    });
  } finally {
    release();
  }
  const paused = await invoke("metawork.scheduledTasks.setEnabled", {
    scheduledTaskId: schedule.id,
    expectedEpoch: updated.epoch,
    enabled: false,
  });
  assert.equal(paused.enabled, false);

  const denied = await create("Scheduled permission boundary");
  provider.enqueue(
    toolSse("schedule-permission", "schedule-write", "Bash", {
      command: "printf forbidden > schedule-permission-must-not-exist.txt",
      purpose: "Write a fixture marker",
    }),
  );
  const deniedRun = await invoke("metawork.scheduledTasks.runNow", {
    scheduledTaskId: denied.id,
    expectedEpoch: denied.epoch,
  });
  const stopped = await wait(async () => {
    const state = await snapshot();
    const item = state.scheduledTasks.find((item) => item.id === denied.id);
    const task = state.tasks.find((item) => item.id === deniedRun.taskId);
    return item.health === "needs_attention" && task?.runs.at(-1)?.terminal
      ? { item, task, state }
      : null;
  }, "canonical noninteractive permission stop");
  assert.equal(stopped.item.failureReason, "permission_required");
  assert.equal(stopped.task.runs.at(-1).terminal.cause, "permission_required");
  assert.equal(stopped.task.pendingUi, null);
  const stoppedRoot = stopped.state.workspaces.find(
    (item) => item.id === stopped.task.workspaceId,
  ).canonicalRoot;
  await assert.rejects(
    access(join(stoppedRoot, "schedule-permission-must-not-exist.txt")),
    { code: "ENOENT" },
  );
  for (const [command, extra] of [
    ["runNow", {}],
    ["setEnabled", { enabled: false }],
    ["setEnabled", { enabled: true }],
  ])
    await assert.rejects(
      invoke(`metawork.scheduledTasks.${command}`, {
        scheduledTaskId: denied.id,
        expectedEpoch: stopped.item.epoch,
        ...extra,
      }),
      (error) =>
        error.bridgeResponseError?.message === "ScheduledTaskNeedsAttention",
    );
  observations.push({
    label: "permission-stop",
    taskId: deniedRun.taskId,
    reason: stopped.item.failureReason,
  });

  console.log(
    "Scheduled vertical: noninteractive permission stopped without executing the marker.",
  );
  await restart();
  assert.equal((await read(schedule.id)).health, "paused");
  assert.equal((await read(denied.id)).failureReason, "permission_required");
  assert.equal(
    (await read(schedule.id)).occurrences.filter(
      (item) => item.result === "submitted",
    ).length,
    2,
  );
  observations.push({
    label: "restart",
    pausedScheduleId: schedule.id,
    attentionScheduleId: denied.id,
  });
  console.log(
    "Scheduled vertical: restart retained paused and attention state without replay.",
  );
  await verifyCustomSource();
  const bytes = await readFile(
    join(dataRoot, "workbench", "scheduled-tasks.json"),
    "utf8",
  );
  assert.equal(JSON.parse(bytes).schema_version, 1);
  assert.equal(bytes.includes("schedule-owned-fixture-key"), false);
  await mkdir(evidenceDir, { recursive: true });
  await writeFile(
    join(evidenceDir, "schedule-desktop.json"),
    JSON.stringify(
      {
        observations,
        notificationOsClick:
          "not exercised; SDK action, Bridge and Renderer navigation covered separately",
      },
      null,
      2,
    ),
  );
  console.log(
    `Scheduled desktop vertical passed: ${JSON.stringify(observations)}`,
  );

  async function verifyCustomSource() {
    let failure;
    let streams = 0;
    const server = createServer(async (request, response) => {
      try {
        assert.equal(
          request.headers.authorization,
          "Bearer schedule-owned-fixture-key",
        );
        let size = 0;
        const chunks = [];
        for await (const chunk of request) {
          size += chunk.length;
          assert.ok(size <= 2 * 1024 * 1024);
          chunks.push(chunk);
        }
        const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (body.stream) {
          streams++;
          response.writeHead(200, {
            "content-type": "text/event-stream",
            connection: "close",
          });
          response.end(protocolTextSse("responses", "Custom scheduled result"));
        } else {
          response.writeHead(200, {
            "content-type": "application/json",
            connection: "close",
          });
          response.end(
            JSON.stringify({
              id: "probe",
              status: "completed",
              output: [
                {
                  type: "message",
                  role: "assistant",
                  status: "completed",
                  content: [
                    { type: "output_text", text: "OK", annotations: [] },
                  ],
                },
              ],
              usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
            }),
          );
        }
      } catch (error) {
        failure = error;
        response.destroy(error);
      }
    });
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    try {
      // The canonical desktop harness owns one process-local vault slot and
      // one Custom Provider. Reconfigure that fixture through its public
      // commands; do not allocate another credential slot.
      let source = (await snapshot()).models.customProviders[0];
      assert.ok(source);
      assert.equal(
        (
          await invoke("metawork.models.customProviders.update", {
            providerId: source.id,
            expectedProviderRevision: source.providerRevision,
            displayName: "Schedule fixture",
            protocol: "openai_responses",
            normalizedBaseUrl: `http://127.0.0.1:${server.address().port}/v1/responses`,
          })
        ).accepted,
        true,
      );
      source = (await snapshot()).models.customProviders[0];
      assert.equal(
        (
          await invoke("metawork.models.customProviders.replaceCredential", {
            providerId: source.id,
            expectedProviderRevision: source.providerRevision,
            apiKey: "schedule-owned-fixture-key",
          })
        ).accepted,
        true,
      );
      source = (await snapshot()).models.customProviders[0];
      assert.equal(
        (
          await invoke("metawork.models.customModels.add", {
            providerId: source.id,
            expectedProviderRevision: source.providerRevision,
            expectedCatalogGeneration: source.catalogGeneration,
            model: { id: "schedule-model", displayName: "Schedule model" },
          })
        ).accepted,
        true,
      );
      source = (await snapshot()).models.customProviders.at(-1);
      assert.equal(
        (
          await invoke("metawork.models.customModels.test", {
            model: { sourceId: source.id, modelId: "schedule-model" },
            expectedProviderRevision: source.providerRevision,
            expectedSourceGeneration: source.sourceGeneration,
            expectedCatalogGeneration: source.catalogGeneration,
          })
        ).accepted,
        true,
      );
      source = await wait(async () => {
        const current = (await snapshot()).models.customProviders.find(
          (item) => item.id === source.id,
        );
        return current.models.some(
          (model) => model.id === "schedule-model" && model.ready,
        )
          ? current
          : null;
      }, "custom source probe");
      const state = await snapshot();
      assert.equal(
        (
          await invoke("metawork.models.selectDefault", {
            sourceId: source.id,
            modelId: "schedule-model",
            expectedSelectionRevision: state.models.selectionRevision,
            expectedSourceGeneration: source.sourceGeneration,
            expectedCatalogGeneration: source.catalogGeneration,
          })
        ).accepted,
        true,
      );
      const custom = await create("Custom source scheduled review");
      assert.equal(custom.binding.protocol, "openai_responses");
      const manual = await invoke("metawork.scheduledTasks.runNow", {
        scheduledTaskId: custom.id,
        expectedEpoch: custom.epoch,
      });
      await completed(custom.id, manual.taskId);
      await invoke("metawork.scheduledTasks.update", {
        scheduledTaskId: custom.id,
        expectedEpoch: custom.epoch,
        ...(await definition("Custom source scheduled review", {
          kind: "once",
          atUnixSeconds: String(now() + 4),
        })),
      });
      const timed = await wait(
        async () =>
          (await read(custom.id)).occurrences.find(
            (item) => item.source === "timer",
          ),
        "custom source OS timer",
      );
      await completed(custom.id, timed.taskId);
      if (failure) throw failure;
      assert.equal(streams, 2);
      console.log(
        "Scheduled vertical: Custom Provider Responses manual and OS-timer Tasks completed.",
      );
      observations.push({
        label: "custom-source",
        sourceId: source.id,
        protocol: custom.binding.protocol,
        manualTaskId: manual.taskId,
        timedTaskId: timed.taskId,
      });
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  }
}
