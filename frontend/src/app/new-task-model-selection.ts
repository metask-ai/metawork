import type {
  ModelMetadata,
  ModelRef,
  ModelsView,
  NewTaskAdmissionView,
  NewTaskModelSelectionIntent,
} from "../bridge/contracts.ts";
import type { Brand } from "../components/ui/BrandIcon.tsx";

export type NewTaskModelOption = {
  selectionId: string;
  modelRef: ModelRef;
  sourceGeneration: string;
  catalogGeneration: string;
  displayName: string;
  vendor: Brand;
  group?: "custom";
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

/** Presentation only, for the official catalog; never infer a custom source's vendor. */
function catalogModelVendor(modelId: string): Brand {
  const family = modelId.toLowerCase().split("-", 1)[0];
  switch (family) {
    case "deepseek":
    case "glm":
    case "kimi":
    case "minimax":
      return family;
    default:
      return "custom";
  }
}

export function newTaskModelSelectionState(
  models: ModelsView,
  admission: NewTaskAdmissionView,
  requested: ModelRef | null,
): NewTaskModelSelectionState {
  const selected =
    requested ?? admission.activeModelRef ?? models.defaultSelection;
  const options = [...models.providers, ...models.customProviders].flatMap(
    (provider) =>
      readyModelOptions(models, provider.id).map((option) => ({
        ...option,
        group: provider.id === "metask" ? undefined : ("custom" as const),
      })),
  );
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
    selectedModelLabel: selected ? modelDisplayLabel(models, selected) : "",
    selectedMetadata: selectedOption?.metadata ?? null,
    intent,
  };
}

export function modelOptionId(model: ModelRef): string {
  return JSON.stringify([model.sourceId, model.modelId]);
}

export function modelDisplayLabel(models: ModelsView, model: ModelRef): string {
  const provider =
    models.providers.find((candidate) => candidate.id === model.sourceId) ??
    models.customProviders.find((candidate) => candidate.id === model.sourceId);
  return (
    provider?.models.find((candidate) => candidate.id === model.modelId)
      ?.displayName || model.modelId
  );
}

export function readyModelOptions(
  models: ModelsView,
  sourceId: string | null,
): NewTaskModelOption[] {
  if (models.availability !== "ready" || sourceId === null) return [];
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
    };
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
      sourceGeneration: provider.sourceGeneration,
      catalogGeneration: provider.catalogGeneration,
      options: provider.models.map((model) => ({
        selectionId: model.id,
        displayName: model.displayName || model.id,
        metadata: model.metadata,
        vendor: catalogModelVendor(model.id),
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
        vendor: provider.builtinProviderId ?? ("custom" as const),
      })),
  };
}
