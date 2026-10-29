import type { BridgeClient } from "../bridge/client.ts";
import type { CustomProviderView, ModelsView } from "../bridge/contracts.ts";
import type {
  CustomModelEditInput,
  CustomModelEditResult,
  ModelEditPart,
} from "../features/settings/CustomModelsSettings.tsx";

type Client = Pick<
  BridgeClient,
  | "updateCustomProvider"
  | "replaceCustomProviderCredential"
  | "replaceCustomModel"
>;

export async function editCustomModel(
  client: Client,
  models: ModelsView,
  refreshModels: () => Promise<ModelsView>,
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
  const steps: ModelEditPart[] = [
    ...(addressChanged ? ["address" as const] : []),
    ...(input.apiKey ? ["api_key" as const] : []),
    ...(input.nextModelId !== modelId ? ["model_id" as const] : []),
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
                replacement: { id: input.nextModelId },
              });
      if (response.accepted) {
        applied.push(step);
        if (step === "model_id") modelId = input.nextModelId;
      }
      const next = await refreshModels();
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
        (step !== "model_id" &&
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
