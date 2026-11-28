import type { BridgeClient } from "../bridge/client.ts";
import type { CustomProviderView, ModelsView } from "../bridge/contracts.ts";
import type {
  CustomModelEditInput,
  CustomModelEditResult,
  ModelEditPart,
} from "../features/settings/CustomModelsSettings.tsx";
import { declareImageInput } from "../features/settings/model-declaration.ts";

type Client = Pick<
  BridgeClient,
  | "updateCustomProvider"
  | "replaceCustomProviderCredential"
  | "replaceCustomModel"
>;

export async function editCustomModel(
  client: Client,
  models: ModelsView,
  /// Null while there is no current view to read, as after a newer security
  /// epoch emptied it; asked once more before the edit counts as uncertain.
  refreshModels: () => Promise<ModelsView | null>,
  input: CustomModelEditInput,
): Promise<CustomModelEditResult> {
  let source: CustomProviderView | null =
    models.customProviders.find((item) => item.id === input.providerId) ?? null;
  let modelId = input.modelId;
  const applied: ModelEditPart[] = [];
  const result = (
    accepted: boolean,
    reviewRequired = false,
  ): CustomModelEditResult => ({
    accepted,
    applied,
    source,
    modelId,
    reviewRequired,
  });
  if (
    !source ||
    source.providerRevision !== input.expectedProviderRevision ||
    source.catalogGeneration !== input.expectedCatalogGeneration ||
    !source.models.some((model) => model.id === modelId)
  )
    return result(false, true);
  const addressChanged =
    source.protocol !== input.protocol ||
    new URL(source.normalizedBaseUrl).href !== new URL(input.endpoint).href;
  if (addressChanged && source.builtinProviderId !== null)
    return result(false, true);
  // One replacement carries both the model id and its declaration.
  const modelParts: ModelEditPart[] = [
    ...(input.nextModelId !== modelId ? ["model_id" as const] : []),
    ...(declaredImageInput(source, modelId) !== input.imageInput
      ? ["image_input" as const]
      : []),
  ];
  const steps = [
    ...(addressChanged ? ["address" as const] : []),
    ...(input.apiKey ? ["api_key" as const] : []),
    ...(modelParts.length > 0 ? ["model" as const] : []),
  ];
  try {
    for (const step of steps) {
      const before = source;
      const response =
        step === "address"
          ? await client.updateCustomProvider({
              providerId: before.id,
              expectedProviderRevision: before.providerRevision,
              displayName: before.displayName,
              protocol: input.protocol,
              normalizedBaseUrl: input.endpoint,
            })
          : step === "api_key"
            ? await client.replaceCustomProviderCredential(
                before.id,
                before.providerRevision,
                input.apiKey,
              )
            : await client.replaceCustomModel({
                selection: { sourceId: before.id, modelId },
                expectedProviderRevision: before.providerRevision,
                expectedCatalogGeneration: before.catalogGeneration,
                // A replace is whole: build it on what Host holds now.
                replacement: replacementFor(before, modelId, input),
              });
      if (response.accepted) {
        if (step === "model") {
          applied.push(...modelParts);
          modelId = input.nextModelId;
        } else applied.push(step);
      }
      const next = (await refreshModels()) ?? (await refreshModels());
      if (!next) throw Error("No current Models view");
      source =
        next.customProviders.find((item) => item.id === input.providerId) ??
        null;
      if (!response.accepted)
        return result(
          false,
          response.errorCode === "generation_mismatch" || !source,
        );
      if (
        !source ||
        source.providerRevision === before.providerRevision ||
        !source.models.some((model) => model.id === modelId) ||
        (step === "model" &&
          declaredImageInput(source, modelId) !== input.imageInput) ||
        (step !== "model" &&
          source.catalogGeneration !== before.catalogGeneration)
      )
        return result(false, true);
      if (
        source.protocol !== input.protocol ||
        new URL(source.normalizedBaseUrl).href !== new URL(input.endpoint).href
      )
        return result(false, true);
    }
    return result(true);
  } catch {
    // An uncertain command or failed observation must never trigger a replay.
    source = null;
    return result(false, true);
  }
}

function declaredImageInput(source: CustomProviderView, modelId: string) {
  return (
    source.models.find((model) => model.id === modelId)?.metadata.capabilities
      .imageInput ?? null
  );
}

function replacementFor(
  source: CustomProviderView,
  modelId: string,
  input: CustomModelEditInput,
) {
  const current = source.models.find((model) => model.id === modelId);
  return {
    id: input.nextModelId,
    ...(current?.displayName ? { displayName: current.displayName } : {}),
    metadata: declareImageInput(current?.metadata, input.imageInput),
  };
}
