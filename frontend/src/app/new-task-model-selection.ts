import type {
  ModelMetadata,
  ModelRef,
  ModelsView,
  NewTaskAdmissionView,
  NewTaskModelSelectionIntent,
} from "../bridge/contracts.ts";

export type NewTaskModelOption = {
  selectionId: string;
  modelRef: ModelRef;
  sourceGeneration: string;
  catalogGeneration: string;
  displayName: string;
  metadata: ModelMetadata | null;
};

export type NewTaskModelSelectionState = {
  editable: boolean;
  valid: boolean;
  options: NewTaskModelOption[];
  selectedModelId: string;
  selectedModelLabel: string;
  selectedMetadata: ModelMetadata | null;
  intent: NewTaskModelSelectionIntent | null;
};

export function newTaskModelSelectionState(
  models: ModelsView,
  admission: NewTaskAdmissionView,
  requested: ModelRef | null,
): NewTaskModelSelectionState {
  const active = admission.activeModelRef;
  const options = readyModelOptions(models);
  const selected = requested ?? active;
  const requestedOption = requested
    ? options.find(
        (option) =>
          option.modelRef.sourceId === requested.sourceId &&
          option.modelRef.modelId === requested.modelId,
      )
    : null;
  const selectedOption =
    requestedOption ??
    (requested === null
      ? options.find(
          (option) =>
            option.modelRef.sourceId === selected?.sourceId &&
            option.modelRef.modelId === selected?.modelId,
        )
      : undefined);
  const valid = requested
    ? requestedOption != null
    : admission.available && selectedOption != null;
  const intent =
    requestedOption && requested
      ? {
          targetModelRef: requested,
          expectedSourceGeneration: requestedOption.sourceGeneration,
          expectedCatalogGeneration: requestedOption.catalogGeneration,
        }
      : null;
  return {
    editable: options.length !== 0,
    valid,
    options,
    selectedModelId: selected ? modelOptionId(selected) : "",
    selectedModelLabel: selectedOption?.displayName || selected?.modelId || "",
    selectedMetadata: selectedOption?.metadata ?? null,
    intent,
  };
}

export function modelOptionId(model: ModelRef): string {
  return JSON.stringify([model.sourceId, model.modelId]);
}

export function readyModelOptions(models: ModelsView): NewTaskModelOption[] {
  if (models.availability !== "ready") return [];
  return [
    "metask",
    ...models.customProviders.map((provider) => provider.id),
  ].flatMap((sourceId) => {
    const authority = resolveAuthority(models, sourceId);
    if (!authority) return [];
    return authority.options.map((option) => {
      const modelRef = { sourceId, modelId: option.selectionId };
      return {
        ...option,
        modelRef,
        selectionId: modelOptionId(modelRef),
        sourceGeneration: authority.sourceGeneration,
        catalogGeneration: authority.catalogGeneration,
        displayName: `${authority.displayName} · ${option.displayName}`,
      };
    });
  });
}

function resolveAuthority(models: ModelsView, sourceId: string) {
  if (sourceId === "metask") {
    const provider = models.providers.find(
      (candidate) => candidate.id === "metask",
    );
    if (
      !provider ||
      provider.catalogState !== "ready" ||
      provider.sourceGeneration === "0" ||
      provider.catalogGeneration === "0"
    )
      return null;
    return {
      sourceId,
      displayName: provider.displayName || "Metask",
      sourceGeneration: provider.sourceGeneration,
      catalogGeneration: provider.catalogGeneration,
      options: provider.models.map((model) => ({
        selectionId: model.id,
        displayName: model.displayName || model.id,
        metadata: model.metadata,
      })),
    };
  }

  const provider = models.customProviders.find(
    (candidate) => candidate.id === sourceId,
  );
  if (
    !provider ||
    provider.state !== "ready" ||
    provider.credentialStatus !== "ready" ||
    !provider.enabled ||
    provider.sourceGeneration === "0" ||
    provider.catalogGeneration === "0"
  )
    return null;
  return {
    sourceId,
    displayName: provider.displayName || provider.id,
    sourceGeneration: provider.sourceGeneration,
    catalogGeneration: provider.catalogGeneration,
    options: provider.models
      .filter((model) => model.ready)
      .map((model) => ({
        selectionId: model.id,
        displayName: model.displayName || model.id,
        metadata: model.metadata,
      })),
  };
}
