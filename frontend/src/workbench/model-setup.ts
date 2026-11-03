import type {
  AccountView,
  ModelsView,
  NewTaskAdmissionView,
  ModelRef,
} from "../bridge/contracts.ts";

export function supportsCustomProviders(capabilities: {
  management: boolean;
  secretCapture: boolean;
  modelTest: boolean;
}) {
  return (
    capabilities.management &&
    capabilities.secretCapture &&
    capabilities.modelTest
  );
}

export type ModelSetupAction =
  | "start"
  | "login"
  | "cancel"
  | "models"
  | "choose_model"
  | "refresh"
  | "schedules";
export type ModelSetupReason =
  | "persistence"
  | "preparing"
  | "execution_unavailable"
  | "checking"
  | "authorizing"
  | "loading"
  | "sign_in"
  | "no_models"
  | "catalog_failed"
  | "model_unavailable"
  | "choose"
  | "provider_unavailable"
  | "schedule_unavailable"
  | "schedule_failed"
  | "schedule_unknown"
  | "resources_unavailable"
  | "required";
export type ModelSetupNotice = {
  reason: ModelSetupReason;
  action: ModelSetupAction | null;
};

// Presentation only. Task admission and source-qualified selection stay with
// their existing owners; discovering another source never selects it.
export function modelSetupNotice({
  account,
  models,
  admission,
  selected,
  valid,
  hasReadyModels,
  customProvidersAvailable,
  schedulesAvailable,
}: {
  account: AccountView;
  models: ModelsView;
  admission: NewTaskAdmissionView;
  selected: ModelRef | null;
  valid: boolean;
  hasReadyModels: boolean;
  customProvidersAvailable: boolean;
  schedulesAvailable: boolean;
}): ModelSetupNotice | null {
  if (valid) return null;
  if (models.persistenceHealth !== "ready")
    return { reason: "persistence", action: "models" };
  if (admission.reason === "shutting_down")
    return { reason: "preparing", action: null };

  const metask = models.providers.find((provider) => provider.id === "metask");
  const needsMetask =
    selected?.sourceId === "metask" ||
    (!selected && !hasReadyModels && models.customProviders.length === 0);
  if (needsMetask && account.state === "checking")
    return { reason: "checking", action: null };
  if (needsMetask && account.state === "authorizing")
    return {
      reason: "authorizing",
      action: account.canCancel ? "cancel" : null,
    };
  if (
    models.availability === "loading" ||
    models.operation === "refreshing_catalog" ||
    (needsMetask && metask?.catalogState === "loading")
  )
    return { reason: "loading", action: null };
  if (needsMetask && account.state === "signed_out") {
    if (account.errorCode !== "none" && account.errorCode !== "user_cancelled")
      return {
        reason: "sign_in",
        action: "login",
      };
    if (selected) return { reason: "sign_in", action: "login" };
  }
  if (needsMetask && account.state === "authenticated") {
    if (metask?.errorCode === "no_models")
      return { reason: "no_models", action: "refresh" };
    if (
      metask?.catalogState === "failed" ||
      metask?.catalogState === "unavailable"
    )
      return { reason: "catalog_failed", action: "refresh" };
    if (metask?.catalogState === "needs_authentication")
      return { reason: "execution_unavailable", action: "models" };
  }
  if (selected) {
    const customProvider = models.customProviders.find(
      (provider) => provider.id === selected.sourceId,
    );
    if (
      customProvider &&
      (!customProvider.enabled || customProvider.credentialStatus !== "ready")
    )
      return {
        reason: "provider_unavailable",
        action: customProvidersAvailable ? "models" : null,
      };
    return {
      reason: "model_unavailable",
      action: hasReadyModels ? "choose_model" : "models",
    };
  }
  if (hasReadyModels || models.availability === "choosing")
    return {
      reason: "choose",
      action: hasReadyModels ? "choose_model" : "models",
    };
  if (models.customProviders.length > 0)
    return {
      reason: "provider_unavailable",
      action: customProvidersAvailable ? "models" : null,
    };
  if (account.state === "authenticated")
    return { reason: "no_models", action: "refresh" };
  return { reason: "required", action: "start" };
}
