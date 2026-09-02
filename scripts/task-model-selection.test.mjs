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

function execution(overrides = {}) {
  return {
    state: "ready",
    defaultSource: "metask",
    activeSource: "metask",
    activeGeneration: "7",
    taskCreationAvailable: true,
    selectedModelConnectionId: "",
    modelConnections: [],
    errorCode: "none",
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
  assert.deepEqual(taskModelSelectionPolicy(models(), execution(), task()), {
    authorityExact: true,
    catalogUsable: true,
  });
});

test("catalog loading preserves authority but disables selection", () => {
  assert.deepEqual(
    taskModelSelectionPolicy(
      models({ catalogState: "loading" }),
      execution(),
      task(),
    ),
    { authorityExact: true, catalogUsable: false },
  );
});

test("credential generation, protocol, and execution source are exact", () => {
  assert.equal(
    taskModelSelectionPolicy(
      models(),
      execution(),
      task({ executionGeneration: "6" }),
    ).authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(
      models(),
      execution(),
      task({ protocol: "gemini_native" }),
    ).authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(
      models(),
      execution({ activeSource: "model_connection" }),
      task(),
    ).authorityExact,
    false,
  );
  assert.equal(
    taskModelSelectionPolicy(
      models(),
      execution({ taskCreationAvailable: false }),
      task(),
    ).authorityExact,
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
      execution(),
      task(),
    ),
    { authorityExact: false, catalogUsable: false },
  );
});
