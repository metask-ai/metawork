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

function models(providerOverrides = {}) {
  return {
    metaskSelection: { sourceId: "metask:key-1", modelId: "gpt-5" },
    selectionRevision: "11",
    providers: [
      {
        id: "metask",
        catalogState: "ready",
        apiKeys: [
          {
            id: "key-1",
            name: "Primary",
            suffix: "1234",
            protocol: "openai_chat_completions",
          },
        ],
        models: [{ id: "gpt-5", displayName: "GPT-5" }],
        selectedApiKeyId: "key-1",
        catalogGeneration: "9",
        ...providerOverrides,
      },
    ],
  };
}

function admission(overrides = {}) {
  return {
    available: true,
    reason: "none",
    activeModelRef: { sourceId: "metask:key-1", modelId: "gpt-5" },
    activeGeneration: "7",
    activeSelectionRevision: "11",
    state: "ready",
    ...overrides,
  };
}

function task(overrides = {}) {
  return {
    binding: {
      protocol: "openai_chat_completions",
      model: "removed-model",
      executionGeneration: "7",
      ...overrides,
    },
  };
}

test("exact Metask authority can replace a model removed from the current catalog", () => {
  assert.deepEqual(taskModelSelectionPolicy(models(), admission(), task()), {
    authorityExact: true,
    catalogUsable: true,
  });
});

test("catalog loading preserves authority but disables selection", () => {
  assert.deepEqual(
    taskModelSelectionPolicy(
      models({ catalogState: "loading" }),
      admission(),
      task(),
    ),
    { authorityExact: true, catalogUsable: false },
  );
});

test("generation, protocol, and installed source are exact", () => {
  assert.equal(
    taskModelSelectionPolicy(
      models(),
      admission(),
      task({ executionGeneration: "6" }),
    ).authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(
      models(),
      admission(),
      task({ protocol: "gemini_native" }),
    ).authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(
      models(),
      admission({
        activeModelRef: { sourceId: "provider-1", modelId: "gpt-5" },
      }),
      task(),
    ).authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(models(), admission({ available: false }), task())
      .authorityExact,
    false,
  );
});

test("Metask provider authorization loss disables selection without consulting Account", () => {
  assert.deepEqual(
    taskModelSelectionPolicy(
      models({
        catalogState: "needs_authentication",
        apiKeys: [],
        models: [],
        selectedApiKeyId: "",
        catalogGeneration: "0",
      }),
      admission(),
      task(),
    ),
    { authorityExact: false, catalogUsable: false },
  );
});
