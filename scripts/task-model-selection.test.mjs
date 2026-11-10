import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

import { createServer } from "vite";

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});

const { taskModelCandidates, taskModelSelectionPolicy } =
  await vite.ssrLoadModule("/src/app/task-model-selection.ts");

test.after(async () => {
  await vite.close();
});

function task(modelSelectionAvailability) {
  return { modelSelectionAvailability };
}

test("Host availability is the only Renderer model-selection authority", () => {
  assert.deepEqual(taskModelSelectionPolicy(task("available")), {
    showsSelector: true,
    selectable: true,
    pending: false,
  });
  assert.deepEqual(taskModelSelectionPolicy(task("catalog_loading")), {
    showsSelector: true,
    selectable: false,
    pending: true,
  });
  assert.deepEqual(taskModelSelectionPolicy(task("catalog_unavailable")), {
    showsSelector: true,
    selectable: false,
    pending: false,
  });
});

test("Host lifecycle restrictions keep unavailable Tasks read-only", () => {
  assert.deepEqual(taskModelSelectionPolicy(task("task_unavailable")), {
    showsSelector: false,
    selectable: false,
    pending: false,
  });
  assert.deepEqual(taskModelSelectionPolicy(null), {
    showsSelector: false,
    selectable: false,
    pending: false,
  });
});

test("busy Tasks can select the next model but an unknown save waits for Host recovery", () => {
  const value = {
    modelSelectionAvailability: "available",
    activeOperation: { kind: "run", id: "7" },
    modelIntent: {
      modelRef: { sourceId: "provider-b", modelId: "model" },
      selectionRevision: "2",
      state: "committed",
    },
  };
  assert.equal(taskModelSelectionPolicy(value).selectable, true);
  value.modelIntent.state = "outcome_unknown";
  assert.deepEqual(taskModelSelectionPolicy(value), {
    showsSelector: true,
    selectable: false,
    pending: true,
  });
});

function modelsWithCustomSource() {
  const { models } = JSON.parse(
    readFileSync(
      "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      "utf8",
    ),
  );
  const model = models.providers[0].models[0];
  models.customProviders = [
    {
      id: "other",
      enabled: true,
      state: "ready",
      credentialStatus: "ready",
      sourceGeneration: "7",
      catalogGeneration: "8",
      protocol: "openai_responses",
      models: [{ ...model, ready: true }],
    },
  ];
  return models;
}

test("a Task with no model intent lists every ready source without inferring its old provider", () => {
  const models = modelsWithCustomSource();
  const options = taskModelCandidates(models, null);
  assert.deepEqual(
    options.map((option) => option.modelRef.sourceId),
    ["metask", "other"],
  );
  assert.notEqual(options[0].selectionId, options[1].selectionId);
  assert.deepEqual(
    taskModelCandidates(models, {
      sourceId: "deleted-provider",
      modelId: "old-model",
    }).map((option) => option.modelRef.sourceId),
    ["metask", "other"],
  );
  assert.deepEqual(
    taskModelCandidates(models, {
      sourceId: "metask",
      modelId: "disabled",
    }).map((option) => option.modelRef.sourceId),
    ["metask"],
  );
});

test("Task model candidates agree with the Host availability fixture", () => {
  const cases = JSON.parse(
    readFileSync(
      "frontend/src/bridge/__fixtures__/task-model-menu.fixture",
      "utf8",
    ),
  );
  for (const entry of cases) {
    const models = modelsWithCustomSource();
    models.persistenceHealth = entry.persistenceHealth;
    models.providers[0].catalogState = entry.metaskCatalog;
    const [custom] = models.customProviders;
    custom.enabled = entry.customEnabled;
    custom.state = entry.customState;
    custom.models[0].ready = custom.state === "ready";
    const candidates = taskModelCandidates(
      models,
      entry.intentSource === null
        ? null
        : { sourceId: entry.intentSource, modelId: custom.models[0].id },
    );
    const policy = taskModelSelectionPolicy(task(entry.availability));
    assert.deepEqual(
      candidates.map((option) => option.modelRef.sourceId),
      entry.menuSources,
      JSON.stringify(entry),
    );
    assert.equal(
      policy.selectable,
      candidates.length !== 0,
      JSON.stringify(entry),
    );
    assert.equal(
      policy.pending,
      entry.availability === "catalog_loading",
      JSON.stringify(entry),
    );
  }
});
