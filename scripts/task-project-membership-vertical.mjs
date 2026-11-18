import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";

// Real Application, Bridge, SQL history and canonical Core. Only the Provider
// and credential vault are controlled fixtures, shared with the desktop harness.
export async function runTaskProjectMembershipVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  toolSse,
  workspaceId,
  workspaceRoot,
}) {
  const directory = (await snapshot()).workspaces.find(
    (workspace) => workspace.id === workspaceId,
  );
  assert.equal(directory.projectEntry, false);
  const added = await invoke("metawork.workspaces.addProject", {});
  assert.equal(added.workspaceId, workspaceId);
  assert.equal(
    (await snapshot()).workspaces.find((w) => w.id === workspaceId)
      .projectEntry,
    true,
  );
  const personal = await poll(
    async () => {
      const current = await snapshot();
      return ["ready", "degraded"].includes(current.skillCatalog.availability)
        ? current
        : null;
    },
    20_000,
    "personal catalog for Automatic Task",
  );
  async function create(projectId) {
    const created = await invoke("metawork.tasks.create", {
      projectId,
      workspace: { kind: "automatic" },
      modelSelection: fixtureModelSelection(personal),
      expectedSkillCatalogRevision: personal.skillCatalog.revision,
      expectedSkillSelectionRevision: personal.skillCatalog.selectionRevision,
      approvalMode: "full_access",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    assert.equal(created.projectId, projectId);
    return created.taskId;
  }
  const taskId = await create(null);
  const bornInProject = await create(workspaceId);
  const readTask = async (id) =>
    (await snapshot()).tasks.find((task) => task.id === id);
  const original = await readTask(taskId);
  assert.notEqual(original.workspaceId, workspaceId);
  const actual = (await snapshot()).workspaces.find(
    (workspace) => workspace.id === original.workspaceId,
  );
  assert.equal(actual.kind, "automatic");
  for (const projectId of [workspaceId, null]) {
    const moved = await invoke("metawork.tasks.setProject", {
      taskId,
      projectId,
    });
    assert.equal(moved.applied, true, JSON.stringify(moved));
    const after = await readTask(taskId);
    assert.equal(after.projectId, projectId);
    assert.equal(after.workspaceId, original.workspaceId);
    assert.equal(after.bindingEpoch, original.bindingEpoch);
    const marker = projectId === null ? "after-removal.txt" : "after-move.txt";
    provider.enqueue(
      toolSse("membership-tool", `write-${marker}`, "Bash", {
        command:
          process.platform === "win32"
            ? `[IO.File]::WriteAllText('${marker}', 'membership-cwd'); [Console]::Write([IO.File]::ReadAllText('${marker}'))`
            : `printf 'membership-cwd' > '${marker}'; cat '${marker}'`,
        description: "Write and read in the Task working directory",
      }),
      textSse("membership-complete", "Working directory preserved."),
    );
    const sent = await invoke("metawork.tasks.sendInput", {
      taskId,
      operationId: `membership-${marker}`,
      input: { kind: "text", text: "Review" },
    });
    assert.equal(sent.outcome, "accepted", JSON.stringify(sent));
    await poll(
      async () => {
        if (provider.error) throw provider.error;
        const task = await readTask(taskId);
        return (
          task?.activeOperation === null &&
          task.runs.at(-1)?.terminal?.outcome === "completed"
        );
      },
      30_000,
      "membership Run completed by real Core",
    );
    assert.equal(
      await readFile(join(actual.canonicalRoot, marker), "utf8"),
      "membership-cwd",
    );
    await assert.rejects(access(join(workspaceRoot, marker)), {
      code: "ENOENT",
    });
  }
  return async function verifyRestart() {
    const restored = await readTask(taskId);
    assert.equal(restored.projectId, null);
    assert.equal(restored.workspaceId, original.workspaceId);
    assert.equal(restored.runs.length, 2);
    const created = await readTask(bornInProject);
    assert.equal(created.projectId, workspaceId);
    assert.notEqual(created.workspaceId, workspaceId);
    assert.equal(
      await readFile(join(actual.canonicalRoot, "after-move.txt"), "utf8"),
      "membership-cwd",
    );
  };
}
