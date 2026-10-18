import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  modelDisplayLabel,
  modelOptionId,
  readyModelOptions,
  newTaskModelSelectionState,
} from "../frontend/src/app/new-task-model-selection.ts";

const appSource = readFileSync(
  new URL("../frontend/src/app/App.tsx", import.meta.url),
  "utf8",
);

const metadata = {
  maxInputTokens: null,
  maxOutputTokens: null,
  capabilities: {
    textInput: null,
    audioInput: null,
    videoInput: null,
    output: {
      text: null,
      image: null,
      audio: null,
      video: null,
      embedding: null,
    },
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
    availability: "ready",
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
    metaskSelection: { sourceId: "metask", modelId: "model-1" },
    defaultSelection: { sourceId: "metask", modelId: "model-1" },
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
    admission({ sourceId: "metask", modelId: "model-1" }),
    null,
  );

  assert.equal(state.editable, true);
  assert.equal(state.valid, true);
  assert.equal(
    state.selectedModelId,
    modelOptionId({ sourceId: "metask", modelId: "model-1" }),
  );
  assert.equal(state.selectedModelLabel, "Model one");
  assert.equal(state.intent, null);
  assert.deepEqual(
    state.options.map((option) => option.selectionId),
    ["model-1", "model-2"].map((modelId) =>
      modelOptionId({ sourceId: "metask", modelId }),
    ),
  );
});

test("the New task Composer consumes editable draft model state", () => {
  assert.match(
    appSource,
    /modelEditable=\{\s*newTaskDraftActive\s*\?\s*newTaskModelState\.editable/,
  );
  assert.match(
    appSource,
    /if \(newTaskDraftActive\) \{[\s\S]*setNewTaskRequestedModel\(option\.modelRef\)/,
  );
  assert.doesNotMatch(
    appSource,
    /modelEditable=\{!newTaskDraftActive && taskModelPolicy\.showsSelector\}/,
  );
});

test("a new Task model override is source-qualified and does not mutate the default", () => {
  const models = metaskModels();
  const originalDefault = structuredClone(models.defaultSelection);
  const requested = { sourceId: "metask", modelId: "model-2" };
  const state = newTaskModelSelectionState(
    models,
    admission(models.defaultSelection),
    requested,
  );

  assert.equal(state.selectedModelId, modelOptionId(requested));
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
    admission({ sourceId: "metask", modelId: "model-1" }),
    { sourceId: "metask", modelId: "removed-model" },
  );

  assert.equal(state.editable, true);
  assert.equal(state.valid, false);
  assert.equal(state.intent, null);
  assert.equal(state.selectedModelLabel, "removed-model");
  assert.equal(
    state.selectedModelId,
    modelOptionId({ sourceId: "metask", modelId: "removed-model" }),
  );
});

test("model labels show only the model name even when a catalog or source is unavailable", () => {
  const models = metaskModels();
  models.availability = "unavailable";
  models.providers[0].catalogState = "failed";
  assert.equal(
    modelDisplayLabel(models, { sourceId: "metask", modelId: "model-2" }),
    "Model two",
  );
  assert.equal(
    modelDisplayLabel(models, {
      sourceId: "removed-provider",
      modelId: "same-model",
    }),
    "same-model",
  );
});

test("a ready custom source can select another model for only the new Task", () => {
  const models = {
    availability: "ready",
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

test("explicit choices remain available without default admission and survive default changes", () => {
  const models = metaskModels();
  const requested = { sourceId: "metask", modelId: "model-2" };
  const state = newTaskModelSelectionState(
    models,
    {
      ...admission(null),
      available: false,
      activeGeneration: "0",
      activeSelectionRevision: "0",
    },
    requested,
  );
  assert.equal(state.editable, true);
  assert.equal(state.valid, true);
  assert.deepEqual(state.intent.targetModelRef, requested);
  const changedDefault = newTaskModelSelectionState(
    models,
    admission(requested),
    requested,
  );
  assert.deepEqual(changedDefault.intent.targetModelRef, requested);
});

test("identical model ids from different connections remain distinct and invalid choices do not fall back", () => {
  const models = metaskModels();
  models.customProviders = [
    {
      id: "another-source",
      displayName: "Other",
      state: "ready",
      credentialStatus: "ready",
      enabled: true,
      sourceGeneration: "23",
      catalogGeneration: "29",
      models: [
        { id: "model-1", displayName: "Model one", metadata, ready: true },
      ],
    },
  ];
  const requested = { sourceId: "another-source", modelId: "model-1" };
  const state = newTaskModelSelectionState(
    models,
    admission(models.defaultSelection),
    requested,
  );
  assert.equal(state.options.length, 1);
  assert.deepEqual(
    state.options.map((option) => option.modelRef),
    [requested],
  );
  assert.equal(state.selectedModelLabel, "Model one");
  assert.deepEqual(state.intent, {
    targetModelRef: requested,
    expectedSourceGeneration: "23",
    expectedCatalogGeneration: "29",
  });
  models.customProviders[0].enabled = false;
  const unavailable = newTaskModelSelectionState(
    models,
    admission(models.defaultSelection),
    requested,
  );
  assert.equal(unavailable.valid, false);
  assert.equal(unavailable.selectedModelId, modelOptionId(requested));
  assert.equal(unavailable.intent, null);
  assert.deepEqual(unavailable.options, []);
  assert.equal(unavailable.selectedModelLabel, "Model one");
  assert.deepEqual(
    readyModelOptions(models, "metask").map(
      (option) => option.modelRef.sourceId,
    ),
    ["metask", "metask"],
  );
});

test("a Composer only lists the chosen Provider even when other Providers have ready models", () => {
  const models = metaskModels();
  models.customProviders = [
    {
      id: "cc",
      displayName: "cc",
      state: "ready",
      credentialStatus: "ready",
      enabled: true,
      sourceGeneration: "23",
      catalogGeneration: "29",
      models: [{ id: "gpt-5.6-sol", displayName: "", metadata, ready: true }],
    },
  ];
  const metask = newTaskModelSelectionState(
    models,
    admission(models.defaultSelection),
    null,
  );
  assert.deepEqual(
    metask.options.map((option) => option.modelRef.sourceId),
    ["metask", "metask"],
  );
  assert.deepEqual(
    metask.options.map((option) => option.displayName),
    ["Model one", "Model two"],
  );
  const custom = newTaskModelSelectionState(
    models,
    admission({ sourceId: "cc", modelId: "gpt-5.6-sol" }),
    null,
  );
  assert.deepEqual(
    custom.options.map((option) => option.modelRef.sourceId),
    ["cc"],
  );
  assert.equal(custom.selectedModelLabel, "gpt-5.6-sol");
  assert.deepEqual(
    custom.options.map((option) => option.displayName),
    ["gpt-5.6-sol"],
  );
  const retainedDraft = newTaskModelSelectionState(
    models,
    admission({ sourceId: "cc", modelId: "gpt-5.6-sol" }),
    { sourceId: "metask", modelId: "model-2" },
  );
  assert.deepEqual(
    retainedDraft.options.map((option) => option.modelRef.sourceId),
    ["metask", "metask"],
  );
  models.providers[0].catalogState = "unavailable";
  assert.deepEqual(
    newTaskModelSelectionState(models, admission(models.defaultSelection), null)
      .options,
    [],
  );
  models.defaultSelection = null;
  const unselected = newTaskModelSelectionState(
    models,
    { ...admission(null), available: false },
    null,
  );
  assert.deepEqual(unselected.options, []);
  assert.equal(unselected.editable, false);
  assert.deepEqual(readyModelOptions(models, null), []);
});
