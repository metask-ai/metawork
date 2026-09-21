import type {
  ModelMetadata,
  ModelRef,
  ModelsView,
  NewTaskAdmissionView,
  NewTaskModelSelectionIntent,
} from "../bridge/contracts.ts";

export type NewTaskModelOption = {
  selectionId: string;
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
  const authority = active ? resolveAuthority(models, active.sourceId) : null;
  const options = authority?.options ?? [];
  const requestedOption = requested
    ? options.find(
        (option) =>
          authority?.sourceId === requested.sourceId &&
          option.selectionId === requested.modelId,
      )
    : null;
  const valid = requested === null || requestedOption != null;
  const selected = requested ?? active;
  const selectedOption =
    requestedOption ??
    options.find((option) => option.selectionId === selected?.modelId);
  const intent =
    requestedOption &&
    active &&
    requested &&
    requested.modelId !== active.modelId &&
    authority
      ? {
          targetModelRef: requested,
          expectedSourceGeneration: authority.sourceGeneration,
          expectedCatalogGeneration: authority.catalogGeneration,
        }
      : null;
  return {
    editable: admission.available && authority !== null && options.length !== 0,
    valid,
    options,
    selectedModelId: selected?.modelId ?? "",
    selectedModelLabel: selectedOption?.displayName || selected?.modelId || "",
    selectedMetadata: selectedOption?.metadata ?? null,
    intent,
  };
}

function resolveAuthority(models: ModelsView, sourceId: string) {
  if (sourceId === "metask") {
    const provider = models.providers.find(
      (candidate) => candidate.id === "metask",
    );
    if (
      !provider ||
      models.metaskSelection?.sourceId !== sourceId ||
      provider.catalogState !== "ready" ||
      provider.sourceGeneration === "0" ||
      provider.catalogGeneration === "0"
    )
      return null;
    return {
      sourceId,
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
