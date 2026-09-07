import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { newTaskModelSelectionState } from "../frontend/src/app/new-task-model-selection.ts";

const appSource = readFileSync(
  new URL("../frontend/src/app/App.tsx", import.meta.url),
  "utf8",
);

const metadata = {
  maxInputTokens: null,
  maxOutputTokens: null,
  capabilities: {
    imageInput: null,
    pdfInput: null,
    batch: null,
    citations: null,
    codeExecution: null,
    structuredOutputs: null,
    thinking: { supported: null, adaptive: null, enabled: null },
    effort: {
      supported: null,
      low: null,
      medium: null,
      high: null,
      max: null,
    },
    contextManagement: {
      supported: null,
      clearThinking20251015: null,
      clearToolUses20250919: null,
      compact20260112: null,
    },
  },
};

function metaskModels() {
  return {
    providers: [
      {
        id: "metask",
        catalogState: "ready",
        sourceGeneration: "7",
        catalogGeneration: "11",
        models: [
          { id: "model-1", displayName: "Model one", metadata },
          { id: "model-2", displayName: "Model two", metadata },
        ],
      },
    ],
    metaskSelection: { sourceId: "metask:key-1", modelId: "model-1" },
    defaultSelection: { sourceId: "metask:key-1", modelId: "model-1" },
    customProviders: [],
  };
}

function admission(activeModelRef) {
  return {
    available: true,
    activeModelRef,
    activeGeneration: "13",
    activeSelectionRevision: "17",
  };
}

test("a new Task starts from the active default without emitting an override", () => {
  const state = newTaskModelSelectionState(
    metaskModels(),
    admission({ sourceId: "metask:key-1", modelId: "model-1" }),
    null,
  );

  assert.equal(state.editable, true);
  assert.equal(state.valid, true);
  assert.equal(state.selectedModelId, "model-1");
  assert.equal(state.selectedModelLabel, "Model one");
  assert.equal(state.intent, null);
  assert.deepEqual(
    state.options.map((option) => option.selectionId),
    ["model-1", "model-2"],
  );
});

test("the New task Composer consumes editable draft model state", () => {
  assert.match(
    appSource,
    /modelEditable=\{\s*newTaskDraftActive\s*\?\s*newTaskModelState\.editable/,
  );
  assert.match(
    appSource,
    /if \(newTaskDraftActive\) \{[\s\S]*id === activeModel\.modelId\s*\? null/,
  );
  assert.doesNotMatch(
    appSource,
    /modelEditable=\{!newTaskDraftActive && taskModelPolicy\.showsSelector\}/,
  );
});

test("a new Task model override is source-qualified and does not mutate the default", () => {
  const models = metaskModels();
  const originalDefault = structuredClone(models.defaultSelection);
  const requested = { sourceId: "metask:key-1", modelId: "model-2" };
  const state = newTaskModelSelectionState(
    models,
    admission(models.defaultSelection),
    requested,
  );

  assert.equal(state.selectedModelId, "model-2");
  assert.deepEqual(state.intent, {
    targetModelRef: requested,
    expectedSourceGeneration: "7",
    expectedCatalogGeneration: "11",
  });
  assert.deepEqual(models.defaultSelection, originalDefault);
});

test("a catalog change invalidates a draft model instead of silently falling back", () => {
  const state = newTaskModelSelectionState(
    metaskModels(),
    admission({ sourceId: "metask:key-1", modelId: "model-1" }),
    { sourceId: "metask:key-1", modelId: "removed-model" },
  );

  assert.equal(state.editable, true);
  assert.equal(state.valid, false);
  assert.equal(state.intent, null);
  assert.equal(state.selectedModelId, "removed-model");
});

test("a ready custom source can select another model for only the new Task", () => {
  const models = {
    providers: [],
    metaskSelection: null,
    defaultSelection: { sourceId: "provider-1", modelId: "custom-1" },
    customProviders: [
      {
        id: "provider-1",
        state: "ready",
        credentialStatus: "ready",
        enabled: true,
        sourceGeneration: "23",
        catalogGeneration: "29",
        models: [
          {
            id: "custom-1",
            displayName: "Custom one",
            metadata,
            ready: true,
          },
          {
            id: "custom-2",
            displayName: "Custom two",
            metadata,
            ready: true,
          },
        ],
      },
    ],
  };
  const requested = { sourceId: "provider-1", modelId: "custom-2" };
  const state = newTaskModelSelectionState(
    models,
    admission(models.defaultSelection),
    requested,
  );

  assert.equal(state.editable, true);
  assert.equal(state.selectedModelLabel, "Custom two");
  assert.deepEqual(state.intent, {
    targetModelRef: requested,
    expectedSourceGeneration: "23",
    expectedCatalogGeneration: "29",
  });
});
