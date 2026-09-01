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

function account(overrides = {}) {
  return {
    state: "authenticated",
    canCreateTask: true,
    catalogState: "ready",
    executionSource: "metask",
    apiKeys: [
      {
        selectionId: "key-1",
        name: "Primary",
        suffix: "1234",
        protocol: "openai_chat_completions",
      },
    ],
    models: [{ selectionId: "gpt-5", displayName: "GPT-5" }],
    selectedApiKeySelectionId: "key-1",
    catalogGeneration: "9",
    metaskExecutionGeneration: "7",
    executionGeneration: "7",
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
  assert.deepEqual(taskModelSelectionPolicy(account(), task()), {
    authorityExact: true,
    catalogUsable: true,
  });
});

test("catalog loading preserves authority but disables selection", () => {
  assert.deepEqual(
    taskModelSelectionPolicy(account({ catalogState: "loading" }), task()),
    { authorityExact: true, catalogUsable: false },
  );
});

test("credential generation, protocol, and execution source are exact", () => {
  assert.equal(
    taskModelSelectionPolicy(account(), task({ executionGeneration: "6" }))
      .authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(account(), task({ protocol: "gemini_native" }))
      .authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(
      account({ executionSource: "model_connection" }),
      task(),
    ).authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(account({ canCreateTask: false }), task())
      .authorityExact,
    false,
  );
});
