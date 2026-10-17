import assert from "node:assert/strict";
import { join } from "node:path";
import test from "node:test";

import { createServer } from "vite";

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});

const { taskModelSelectionPolicy } = await vite.ssrLoadModule(
  "/src/app/task-model-selection.ts",
);

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
  assert.deepEqual(taskModelSelectionPolicy(task("execution_replacing")), {
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

test("detached, unsupported, and changed authority remain read-only", () => {
  for (const availability of [
    "runtime_detached",
    "unsupported_source",
    "authority_changed",
  ]) {
    assert.deepEqual(taskModelSelectionPolicy(task(availability)), {
      showsSelector: false,
      selectable: false,
      pending: false,
    });
  }
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
