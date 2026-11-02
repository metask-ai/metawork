import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import assert from "node:assert/strict";
import { readFile, writeFile, access } from "node:fs/promises";
import { join } from "node:path";

// Real Application/Bridge/Product/canonical Core; only model replies are fixtures.
export async function runTaskArchiveVertical({
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
}) {
  const evidence = {
    scope:
      "Real Application/Bridge/Product/canonical Core with scripted model replies; UI gestures recorded separately",
    cases: [],
  };
  const source = join(workspaceRoot, "archive-preserved.txt");
  const bytes = "Task deletion preserves workspace files.\n";
  await writeFile(source, bytes);
  const read = async (id) =>
    (await snapshot()).tasks.find((task) => task.id === id);
  async function create(title) {
    const modelSnapshot = await snapshot();
    const created = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },

      modelSelection: fixtureModelSelection(modelSnapshot),
      expectedSkillCatalogRevision: catalog.revision,
      expectedSkillSelectionRevision: catalog.selectionRevision,
      approvalMode: "manual",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    await invoke("metawork.tasks.rename", { taskId: created.taskId, title });
    return created.taskId;
  }
  const send = (taskId, operationId, text) =>
    invoke("metawork.tasks.sendInput", {
      taskId,
      operationId,
      input: { kind: "text", text },
    });
  const deleted = (id) =>
    poll(
      async () => !(await snapshot()).taskIndex.some((task) => task.id === id),
      20_000,
      "Task record physically deleted",
    );
  const idle = await create("Archive audit idle direct delete");
  assert.equal((await read(idle)).archived, false);
  await invoke("metawork.tasks.delete", { taskId: idle });
  await deleted(idle);
  evidence.cases.push("idle unarchived deletion");

  const running = await create("Archive audit stop and delete");
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  let entered = false;
  provider.enqueue(async () => {
    entered = true;
    await gate;
    return {
      body: textSse(
        "archive-running",
        "Late response must not revive the deleted Task.",
      ),
      initialDelayMs: 0,
      frameDelayMs: 0,
    };
  });
  try {
    assert.equal(
      (await send(running, "archive-running", "Wait while I delete this task"))
        .outcome,
      "accepted",
    );
    await poll(async () => entered, 10_000, "live Core Provider request");
    await invoke("metawork.tasks.delete", { taskId: running });
    const current = await read(running);
    if (current) {
      assert.equal(current.archived, false);
      assert.equal(current.deletionStatus, "deleting");
    }
  } finally {
    release();
  }
  await deleted(running);
  evidence.cases.push(
    "running unarchived stop and delete with late Provider result",
  );

  const waiting = await create("Archive audit permission wait delete");
  const marker = join(workspaceRoot, "archive-permission-must-not-run.txt");
  provider.enqueue(
    toolSse("archive-tool", "archive-tool-call", "Bash", {
      command: `touch '${marker.replaceAll("'", "'\\''")}'`,
      description: "Wait for manual permission before writing",
    }),
  );
  assert.equal(
    (
      await send(
        waiting,
        "archive-waiting",
        "Request approval before writing the marker",
      )
    ).outcome,
    "accepted",
  );
  await poll(
    async () => (await read(waiting))?.pendingUi,
    20_000,
    "real permission request",
  );
  await invoke("metawork.tasks.delete", { taskId: waiting });
  await deleted(waiting);
  await assert.rejects(access(marker), { code: "ENOENT" });
  evidence.cases.push("permission-wait deletion without tool effect");

  const archived = await create("Archive history audit");
  provider.enqueue(
    textSse(
      "archive-history",
      "Retain this conversation through archive and restore.",
    ),
  );
  assert.equal(
    (await send(archived, "archive-history", "Keep this history")).outcome,
    "accepted",
  );
  await poll(
    async () => {
      const task = await read(archived);
      return (
        task?.activeOperation === null &&
        task.runs.at(-1)?.terminal?.outcome === "completed"
      );
    },
    20_000,
    "archive history completed",
  );
  const runIds = (await read(archived)).runs.map((run) => run.id);
  await invoke("metawork.tasks.archive", { taskId: archived, archived: true });
  assert.equal((await read(archived)).archived, true);
  assert.equal(
    (
      await send(
        archived,
        "archive-rejected",
        "Must not execute while archived",
      )
    ).outcome,
    "rejected",
  );
  await invoke("metawork.tasks.archive", { taskId: archived, archived: false });
  assert.equal((await read(archived)).archived, false);
  assert.deepEqual(
    (await read(archived)).runs.map((run) => run.id),
    runIds,
  );
  await invoke("metawork.tasks.archive", { taskId: archived, archived: true });
  assert.equal((await read(archived)).unreadCompletionRunId, null);
  evidence.cases.push(
    "archive/restore preserves Task and Run identities and denies archived input",
  );
  const uiTask = await create("Archive UI audit");
  assert.equal(await readFile(source, "utf8"), bytes);
  evidence.cases.push("workspace source file preserved");
  evidence.archivedTaskId = archived;
  evidence.uiTaskId = uiTask;
  return {
    evidence,
    async verifyRestart() {
      const current = await read(archived);
      assert.equal(current.archived, true);
      assert.deepEqual(
        current.runs.map((run) => run.id),
        runIds,
      );
      assert.equal(current.unreadCompletionRunId, null);
      for (const id of [idle, running, waiting])
        assert.equal(await read(id), undefined);
      assert.equal(await readFile(source, "utf8"), bytes);
      evidence.cases.push(
        "clean cold restart retains archive and confirmed deletions without replay",
      );
    },
  };
}
