import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import assert from "node:assert/strict";
import { mkdir, readFile, writeFile, unlink } from "node:fs/promises";
import { join } from "node:path";

export async function runAutomaticFirstSkillVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  canonicalHome,
}) {
  const name = "first-message-review";
  const marker = "METAWORK_FIRST_MESSAGE_PERSONAL_SKILL";
  const skillDir = join(canonicalHome, ".agents", "skills", name);
  await mkdir(skillDir, { recursive: true });
  await writeFile(
    join(skillDir, "SKILL.md"),
    `---\nname: ${name}\ndescription: Review the first message\n---\n${marker}\n`,
  );
  await invoke("metawork.skills.refreshCatalog", {});
  const before = await poll(
    async () => {
      const state = await snapshot();
      return state.skillCatalog.skills.some(
        (skill) => skill.invocationName === name,
      )
        ? state
        : null;
    },
    20_000,
    "personal Skill before creating a Task",
  );
  assert.equal(before.tasks.length, 0);
  assert.equal(before.workspaces.length, 0);
  assert.ok(
    before.skillCatalog.skills.some(
      (skill) => skill.invocationName === "docx" && skill.enabled,
    ),
  );
  const catalog = before.skillCatalog;
  const skill = catalog.skills.find(
    (candidate) => candidate.invocationName === name,
  );
  assert.equal(skill.enabled, true);
  const request = {
    workspace: { kind: "automatic" },
    modelSelection: fixtureModelSelection(before),
    expectedSkillCatalogRevision: catalog.revision,
    expectedSkillSelectionRevision: catalog.selectionRevision,
    approvalMode: "manual",
  };
  const stale = await invoke("metawork.tasks.create", {
    ...request,
    expectedSkillCatalogRevision: "stale-catalog",
  });
  assert.equal(stale.reason, "stale_catalog");
  assert.equal((await snapshot()).workspaces.length, 0);
  const docx = catalog.skills.find(
    (candidate) => candidate.invocationName === "docx",
  );
  for (const [selected, expectedInstructions, message] of [
    [
      docx,
      "DOCX creation, editing, and analysis",
      "帮我把这些要点整理成 Word 周报。\n- 梳理本周交付",
    ],
    [skill, marker, "Review the complete first message.\nCheck the evidence."],
  ]) {
    assert.ok(selected.maxValues >= 1);
    const created = await invoke("metawork.tasks.create", request);
    assert.equal(created.accepted, true, JSON.stringify(created));
    const requestsBefore = provider.requests.length;
    provider.enqueue((payload) => {
      const messages = JSON.stringify(payload.messages);
      assert.ok(messages.includes(expectedInstructions));
      assert.ok(messages.includes(JSON.stringify(message).slice(1, -1)));
      return textSse("first-skill", "First Skill complete.");
    });
    const result = await invoke("metawork.tasks.sendInput", {
      operationId: `first-skill-${selected.invocationName}`,
      taskId: created.taskId,
      input: {
        kind: "skill",
        skillId: selected.skillId,
        catalogRevision: catalog.revision,
        selectionRevision: catalog.selectionRevision,
        argumentValues: [message],
      },
    });
    assert.equal(result.outcome, "accepted", JSON.stringify(result));
    const task = await poll(
      async () => {
        if (provider.error) throw provider.error;
        const state = await snapshot();
        const task = state.tasks.find(
          (candidate) => candidate.id === created.taskId,
        );
        const failed = task?.inputSubmissions.find(
          (input) => input.state === "failed",
        );
        assert.equal(failed, undefined, JSON.stringify(failed));
        if (!task?.runs[0]?.terminal) return null;
        assert.equal(
          state.workspaces.find(
            (workspace) => workspace.id === task.workspaceId,
          )?.kind,
          "automatic",
        );
        return task;
      },
      30_000,
      `Skill ${selected.invocationName} completes as the first Run`,
    );
    assert.equal(task.runs.length, 1);
    assert.equal(task.runs[0].input.kind, "skill");
    assert.equal(task.runs[0].input.invocationName, selected.invocationName);
    assert.deepEqual(task.runs[0].input.argumentValues, [message]);
    assert.equal(task.runs[0].terminal.outcome, "completed");
    assert.equal(provider.requests.length, requestsBefore + 1);
  }
}

// Real Desktop → Bridge → Product → canonical AgentCore; only model replies
// are scripted. Every message is sent once, including while a Run is active.
export async function runSkillAutoRefreshVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  workspaceId,
  workspaceEpoch,
  catalog,
  skillPath,
}) {
  const original = await readFile(skillPath, "utf8");
  let releaseFirst;
  let firstEntered = false;
  let firstProviderAt;
  let secondProviderAt;
  let textProviderAt;
  let queuedReleasedAt;
  let textSentAt;
  const firstGate = new Promise((resolve) => {
    releaseFirst = resolve;
  });
  const readTask = async (id) =>
    (await snapshot()).tasks.find((task) => task.id === id);
  const scope = async () =>
    (await snapshot()).workspaces.find((w) => w.id === workspaceId)
      .skillCatalog;
  const skillInput = (view, values = ["fixture.txt"]) => ({
    kind: "skill",
    skillId: view.skills.find(
      (s) => s.skillPolicyKey === catalog.skill.skillPolicyKey,
    ).skillId,
    catalogRevision: view.revision,
    selectionRevision: view.selectionRevision,
    argumentValues: values,
  });
  let taskId;
  const send = async (operationId, input) => {
    const result = await invoke("metawork.tasks.sendInput", {
      operationId,
      taskId,
      input,
    });
    assert.equal(result.outcome, "accepted", JSON.stringify(result));
  };
  const settled = (operationId) =>
    poll(
      async () => {
        if (provider.error) throw provider.error;
        const task = await readTask(taskId);
        const run = task?.runs.find(
          (r) => r.submission?.operationId === operationId,
        );
        return task?.activeOperation === null && run?.terminal
          ? { task, run }
          : null;
      },
      30_000,
      `${operationId} terminal`,
    );
  const failed = (operationId) =>
    poll(
      async () => {
        const task = await readTask(taskId);
        return (
          task?.inputSubmissions.find(
            (s) =>
              s.submission.operationId === operationId && s.state === "failed",
          ) ?? null
        );
      },
      20_000,
      `${operationId} rejected before Run`,
    );
  try {
    const modelSnapshot = await snapshot();
    const created = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },

      modelSelection: fixtureModelSelection(modelSnapshot),
      expectedSkillCatalogRevision: catalog.catalog.revision,
      expectedSkillSelectionRevision: catalog.catalog.selectionRevision,
      approvalMode: "manual",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    taskId = created.taskId;
    await invoke("metawork.tasks.rename", {
      taskId,
      title: "Automatic Skill adoption",
    });
    const requestsBefore = provider.requests.length;
    provider.enqueue(
      async () => {
        firstEntered = true;
        firstProviderAt = Date.now();
        await firstGate;
        return {
          body: textSse("auto-skill-v1", "First version complete."),
          frameDelayMs: 0,
        };
      },
      () => {
        secondProviderAt = Date.now();
        return textSse("auto-skill-v2", "Second version complete.");
      },
      () => {
        textProviderAt = Date.now();
        return textSse("auto-skill-text", "Text run complete.");
      },
    );
    const before = Date.now();
    await send("skill-auto-v1", skillInput(catalog.catalog));
    const acceptanceMs = Date.now() - before;
    await poll(async () => firstEntered, 20_000, "first Skill enters Provider");
    const first = await readTask(taskId);
    const firstRun = first.runs.find(
      (r) => r.submission?.operationId === "skill-auto-v1",
    );
    assert.equal(firstRun.input.skillId, catalog.skill.skillId);
    await writeFile(skillPath, `${original}\nMETAWORK_AUTO_SKILL_V2\n`);
    await send("skill-auto-v2", skillInput(catalog.catalog));
    const waiting = await readTask(taskId);
    assert.equal(waiting.skillCatalog.revision, first.skillCatalog.revision);
    assert.ok(
      waiting.inputSubmissions.some(
        (s) =>
          s.submission.operationId === "skill-auto-v2" && s.state === "waiting",
      ),
    );
    queuedReleasedAt = Date.now();
    releaseFirst();
    const second = await settled("skill-auto-v2");
    assert.equal(second.run.terminal.outcome, "completed");
    assert.notEqual(second.run.input.skillId, firstRun.input.skillId);
    assert.notEqual(
      second.run.input.catalogRevision,
      firstRun.input.catalogRevision,
    );
    assert.deepEqual(second.run.input.argumentValues, ["fixture.txt"]);
    const requests = provider.requests.slice(requestsBefore);
    assert.equal(requests.length, 2);
    assert.equal(
      JSON.stringify(requests[0]).includes("METAWORK_AUTO_SKILL_V2"),
      false,
    );
    assert.equal(
      JSON.stringify(requests[1]).includes("METAWORK_AUTO_SKILL_V2"),
      true,
    );

    await writeFile(skillPath, `${original}\nMETAWORK_AUTO_SKILL_V3\n`);
    textSentAt = Date.now();
    await send("skill-auto-text", { kind: "text", text: "Continue normally." });
    const text = await settled("skill-auto-text");
    assert.equal(text.run.terminal.outcome, "completed");
    assert.notEqual(
      text.task.skillCatalog.skills.find(
        (s) => s.skillPolicyKey === catalog.skill.skillPolicyKey,
      ).skillId,
      second.run.input.skillId,
    );
    const requestCount = provider.requests.length;
    const beforeShape = await scope();
    await writeFile(
      skillPath,
      original.replace("arguments: [target]", "arguments: [changed]"),
    );
    await send(
      "skill-auto-shape",
      skillInput(beforeShape, ["preserve my argument"]),
    );
    const shape = await failed("skill-auto-shape");
    assert.equal(shape.reason, "invalid_skill_arguments");
    assert.deepEqual(shape.input.argumentValues, ["preserve my argument"]);
    const beforeRemoval = await scope();
    await unlink(skillPath);
    await send("skill-auto-removed", skillInput(beforeRemoval));
    const removed = await failed("skill-auto-removed");
    assert.equal(removed.reason, "skill_not_found");
    assert.equal(provider.requests.length, requestCount);
    process.stdout.write(
      `Skill auto-refresh passed: active Run kept v1, queued input adopted v2 once, text adopted v3, changed parameters/removal preserved input without execution; ${Date.now() - before} ms; observed end-to-end timing ${JSON.stringify({ acceptanceMs, firstProviderMs: firstProviderAt - before, queuedProviderAfterReleaseMs: secondProviderAt - queuedReleasedAt, textProviderMs: textProviderAt - textSentAt })} (includes Host scheduling and Provider entry, not an isolated scan benchmark).\n`,
    );
  } finally {
    releaseFirst?.();
    await writeFile(skillPath, original);
  }
}
