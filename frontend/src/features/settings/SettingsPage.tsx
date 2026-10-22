import { useEffect, useMemo, useRef, useState } from "react";

import type {
  AccountView,
  BuiltinProviderId,
  ModelsView,
  Protocol,
  WorkbenchSnapshot,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { ConfirmationNotice } from "../../components/ConfirmationNotice.tsx";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { useI18n, type Locale, type MessageId } from "../../i18n/context.ts";
import { accountErrorText } from "../../i18n/account-error.ts";
import {
  accountIdentityInitial,
  accountIdentityLabel,
} from "../../workbench/account-identity.ts";
import { AccountBalance, AccountUsageSummary } from "./AccountUsageSummary.tsx";
import { supportsCustomProviders } from "../../workbench/model-setup.ts";

export type SettingsFocusTarget = "title" | "account" | "models" | "providers";
type SettingsSection = "general" | "account" | "models" | "providers";
type ProvidersPage = "list" | "builtin" | "custom";
type RequestedSelection = {
  selectionId: string;
  label: string;
};
type CustomProviderDraft = {
  displayName: string;
  protocol: Protocol;
  baseUrl: string;
  apiKey: string;
};
type BuiltinProviderDraft = {
  providerId: BuiltinProviderId | "";
  baseUrl: string;
  apiKey: string;
  editingBaseUrl: boolean;
};
type CustomProviderSubmission = {
  displayName: string;
  protocol: Protocol;
  normalizedBaseUrl: string;
  apiKey: string;
};
type CustomProviderEditDraft = Omit<CustomProviderDraft, "apiKey"> & {
  providerId: string;
  expectedProviderRevision: string;
};
type CustomProviderEditSubmission = Omit<CustomProviderSubmission, "apiKey"> & {
  providerId: string;
  expectedProviderRevision: string;
};
type CustomProviderRemoval = {
  providerId: string;
  expectedProviderRevision: string;
};
type CustomModelRemoval = CustomProviderRemoval & {
  expectedCatalogGeneration: string;
  modelId: string;
};
type CustomProviderCredentialEdit = CustomProviderRemoval & {
  apiKey: string;
};
type AutomaticWorkspaceRootAction = "choose" | "reset" | "retry";
type AutomaticWorkspaceRootMutationOutcome = "applied" | "cancelled" | false;

const customProviderBaseUrlExamples: Record<Protocol, string> = {
  openai_responses: "https://api.openai.com/v1",
  anthropic_messages: "https://api.anthropic.com",
  openai_chat_completions: "https://api.openai.com/v1",
  gemini_native: "https://generativelanguage.googleapis.com",
};

const customProviderRequestPaths: Record<Protocol, string> = {
  openai_responses: "/responses",
  openai_chat_completions: "/chat/completions",
  anthropic_messages: "/v1/messages",
  gemini_native: "",
};

function trimTrailingSlashes(value: string) {
  return value.replace(/\/+$/u, "");
}

export function customProviderEndpointFromBaseUrl(
  protocol: Protocol,
  baseUrl: string,
) {
  const normalizedBase = trimTrailingSlashes(baseUrl.trim());
  const requestPath = customProviderRequestPaths[protocol];
  if (!requestPath || normalizedBase.endsWith(requestPath)) {
    return normalizedBase;
  }
  return `${normalizedBase}${requestPath}`;
}

function customProviderBaseUrlFromEndpoint(
  protocol: Protocol,
  endpoint: string,
) {
  const normalizedEndpoint = trimTrailingSlashes(endpoint);
  const requestPath = customProviderRequestPaths[protocol];
  return requestPath && normalizedEndpoint.endsWith(requestPath)
    ? normalizedEndpoint.slice(0, -requestPath.length)
    : normalizedEndpoint;
}

function newCustomProviderDraft(): CustomProviderDraft {
  return {
    displayName: "",
    protocol: "openai_chat_completions",
    baseUrl: "",
    apiKey: "",
  };
}

function newBuiltinProviderDraft(): BuiltinProviderDraft {
  return {
    providerId: "",
    baseUrl: "",
    apiKey: "",
    editingBaseUrl: false,
  };
}

function providerAddressHost(value: string) {
  try {
    return new URL(value).host;
  } catch {
    return value.trim();
  }
}

function modelLabel(
  model: ModelsView["providers"][number]["models"][number],
  t: ReturnType<typeof useI18n>["t"],
) {
  return model.displayName.trim() || model.id;
}

function customProviderProtocolLabel(
  protocol: Protocol,
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`settings.custom_provider_protocol.${protocol}`);
}

function customProviderCredentialLabel(
  status: ModelsView["customProviders"][number]["credentialStatus"],
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`settings.custom_provider_credential.${status}`);
}

function customProviderStateLabel(
  state: ModelsView["customProviders"][number]["state"],
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`settings.custom_provider_state.${state}`);
}

function customModelTestStatusLabel(
  status: ModelsView["customProviders"][number]["models"][number]["testStatus"],
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`settings.custom_model_test_status.${status}`);
}

export function SettingsPage({
  account,
  models,
  automaticWorkspaceRoot,
  customProviderCapabilities,
  focusTarget,
  initialSection = "general",
  disabled,
  accountDisabled,
  executionDisabled,
  cancelDisabled,
  onBack,
  onRefresh,
  onResetModels,
  onChooseAutomaticWorkspaceRoot,
  onResetAutomaticWorkspaceRoot,
  onRetryAutomaticWorkspaceRoot,
  onCancel,
  onSelectModel,
  onCreateCustomProvider,
  onCreateBuiltinProvider,
  onUpdateBuiltinProviderBaseUrl,
  onUpdateCustomProvider,
  onReplaceCustomProviderCredential,
  onAddCustomModel,
  onRemoveCustomModel,
  onRemoveCustomProvider,
  onTestCustomModel,
  onSelectCustomModel,
  onBeginLogin,
  onRetryRefresh,
  onRefreshAccountSummary,
  onOpenRecharge,
  onLogout,
}: {
  account: AccountView;
  models: ModelsView;
  automaticWorkspaceRoot: WorkbenchSnapshot["automaticWorkspaceRoot"];
  customProviderCapabilities: {
    management: boolean;
    secretCapture: boolean;
    modelTest: boolean;
  };
  focusTarget: SettingsFocusTarget;
  initialSection?: SettingsSection;
  disabled: boolean;
  accountDisabled: boolean;
  executionDisabled: boolean;
  cancelDisabled: boolean;
  onBack: () => void;
  onRefresh: () => void;
  onResetModels: () => Promise<boolean>;
  onChooseAutomaticWorkspaceRoot: (
    expectedGeneration: string,
  ) => Promise<AutomaticWorkspaceRootMutationOutcome>;
  onResetAutomaticWorkspaceRoot: (
    expectedGeneration: string,
  ) => Promise<AutomaticWorkspaceRootMutationOutcome>;
  onRetryAutomaticWorkspaceRoot: (
    expectedGeneration: string,
  ) => Promise<AutomaticWorkspaceRootMutationOutcome>;
  onCancel: () => void;
  onSelectModel: (id: string) => void;
  onCreateCustomProvider: (input: CustomProviderSubmission) => Promise<boolean>;
  onCreateBuiltinProvider: (input: {
    providerId: BuiltinProviderId;
    baseUrl: string;
    apiKey: string;
  }) => Promise<boolean>;
  onUpdateBuiltinProviderBaseUrl: (input: {
    providerId: string;
    expectedProviderRevision: string;
    baseUrl: string;
  }) => Promise<boolean>;
  onUpdateCustomProvider: (
    input: CustomProviderEditSubmission,
  ) => Promise<boolean>;
  onReplaceCustomProviderCredential: (
    providerId: string,
    expectedProviderRevision: string,
    apiKey: string,
  ) => Promise<boolean>;
  onAddCustomModel: (
    providerId: string,
    expectedProviderRevision: string,
    expectedCatalogGeneration: string,
    modelId: string,
  ) => Promise<boolean>;
  onRemoveCustomModel: (
    providerId: string,
    expectedProviderRevision: string,
    expectedCatalogGeneration: string,
    modelId: string,
  ) => Promise<boolean>;
  onRemoveCustomProvider: (
    providerId: string,
    expectedProviderRevision: string,
  ) => Promise<boolean>;
  onTestCustomModel: (
    providerId: string,
    providerRevision: string,
    modelId: string,
    sourceGeneration: string,
    catalogGeneration: string,
  ) => void;
  onSelectCustomModel: (
    providerId: string,
    providerRevision: string,
    modelId: string,
  ) => void;
  onBeginLogin: () => void;
  onRetryRefresh: () => void;
  onRefreshAccountSummary: () => void;
  onOpenRecharge: () => void;
  onLogout: () => void;
}) {
  const { locale, setLocale, t } = useI18n();
  const customProviderSettingsAvailable = supportsCustomProviders(
    customProviderCapabilities,
  );
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const [activeSection, setActiveSection] =
    useState<SettingsSection>(initialSection);
  const [providersPage, setProvidersPage] = useState<ProvidersPage>("list");
  const [requestedModel, setRequestedModel] =
    useState<RequestedSelection | null>(null);
  const [requestedProviderId, setRequestedProviderId] = useState<string | null>(
    null,
  );
  const [customProviderDraft, setCustomProviderDraft] =
    useState<CustomProviderDraft | null>(null);
  const [builtinProviderDraft, setBuiltinProviderDraft] =
    useState<BuiltinProviderDraft>({
      providerId: "",
      baseUrl: "",
      apiKey: "",
      editingBaseUrl: false,
    });
  const [creatingCustomProvider, setCreatingCustomProvider] = useState(false);
  const [customModelId, setCustomModelId] = useState("");
  const [addingCustomModel, setAddingCustomModel] = useState(false);
  const [customProviderEdit, setCustomProviderEdit] =
    useState<CustomProviderEditDraft | null>(null);
  const [customProviderRemoval, setCustomProviderRemoval] =
    useState<CustomProviderRemoval | null>(null);
  const [customModelRemoval, setCustomModelRemoval] =
    useState<CustomModelRemoval | null>(null);
  const [customProviderCredentialEdit, setCustomProviderCredentialEdit] =
    useState<CustomProviderCredentialEdit | null>(null);
  const [mutatingCustomProvider, setMutatingCustomProvider] = useState(false);
  const [automaticRootPending, setAutomaticRootPending] = useState<{
    action: AutomaticWorkspaceRootAction;
    generation: string;
  } | null>(null);
  const [automaticRootMutationFailed, setAutomaticRootMutationFailed] =
    useState(false);
  const content = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const generalHeading = useRef<HTMLHeadingElement>(null);
  const accountHeading = useRef<HTMLHeadingElement>(null);
  const modelsHeading = useRef<HTMLHeadingElement>(null);
  const providersHeading = useRef<HTMLHeadingElement>(null);
  const signOut = useRef<HTMLButtonElement>(null);
  const signOutCancel = useRef<HTMLButtonElement>(null);
  const automaticRootChooseButton = useRef<HTMLButtonElement>(null);
  const automaticRootResetButton = useRef<HTMLButtonElement>(null);
  const automaticRootRetryButton = useRef<HTMLButtonElement>(null);
  const automaticRootGeneration = useRef(automaticWorkspaceRoot.generation);
  automaticRootGeneration.current = automaticWorkspaceRoot.generation;
  const metaskProvider = models.providers.find(
    (provider) => provider.id === "metask",
  );
  const metaskModels = metaskProvider?.models ?? [];
  const metaskCatalogState =
    metaskProvider?.catalogState ?? "needs_authentication";
  const selectedModelId = models.metaskSelection?.modelId ?? "";
  const committedProviderId = models.defaultSelection
    ? models.defaultSelection.sourceId === "metask"
      ? "metask"
      : models.defaultSelection.sourceId
    : "";
  const selectedProviderId = requestedProviderId ?? committedProviderId;
  const selectedCustomProvider = models.customProviders.find(
    (provider) => provider.id === selectedProviderId,
  );
  const committedCustomProvider = models.customProviders.find(
    (provider) => provider.id === committedProviderId,
  );
  const committedDefaultModel = models.defaultSelection
    ? committedProviderId === "metask"
      ? metaskModels.find(
          (model) => model.id === models.defaultSelection?.modelId,
        )
      : committedCustomProvider?.models.find(
          (model) => model.id === models.defaultSelection?.modelId,
        )
    : null;
  const metaskDefaultUnavailable =
    models.defaultSelection?.sourceId === "metask" &&
    metaskCatalogState === "ready" &&
    !committedDefaultModel;
  const currentDefaultLabel = models.defaultSelection
    ? `${
        committedProviderId === "metask"
          ? "Metask"
          : (committedCustomProvider?.displayName ?? committedProviderId)
      } · ${
        committedDefaultModel?.displayName || models.defaultSelection.modelId
      }`
    : t("settings.default_selection_missing");
  const committedModel = metaskModels.find(
    (model) => model.id === selectedModelId,
  );
  const candidateModelId = requestedModel?.selectionId ?? "";
  const candidateModel =
    metaskModels.find((model) => model.id === candidateModelId) ?? null;
  const modelCatalogLoading = models.operation === "refreshing_catalog";
  const modelBusy = modelCatalogLoading;
  const authenticated = account.state === "authenticated";
  const accountIdentityTitle = authenticated
    ? accountIdentityLabel(account, t("account.signed_in"))
    : account.state === "checking"
      ? t("account.checking.title")
      : account.state === "authorizing"
        ? t("account.authorizing.title")
        : t("account.sign_in_required.title");
  const accountIdentityBody =
    account.state === "checking"
      ? t("account.checking.body")
      : account.state === "authorizing"
        ? t("account.authorizing.body")
        : t("account.sign_in_required.body");
  const modelsPersistenceReady = models.persistenceHealth === "ready";
  const providerIsMetask = selectedProviderId === "metask";
  const canChooseProvider =
    modelsPersistenceReady &&
    ((authenticated &&
      (metaskCatalogState === "ready" || metaskCatalogState === "choosing")) ||
      models.customProviders.some(
        (provider) =>
          provider.enabled &&
          provider.credentialStatus === "ready" &&
          provider.state !== "disabled",
      ));
  const canChooseModel =
    modelsPersistenceReady &&
    (providerIsMetask
      ? authenticated &&
        (metaskCatalogState === "ready" || metaskCatalogState === "choosing")
      : selectedCustomProvider?.state === "ready" &&
        selectedCustomProvider.credentialStatus === "ready");
  const languageOptions = useMemo<SelectionMenuOption[]>(
    () => [
      { value: "en-US", label: t("app.language.en-US") },
      { value: "zh-CN", label: t("app.language.zh-CN") },
      ...(import.meta.env.DEV
        ? [{ value: "pseudo", label: t("app.language.pseudo") }]
        : []),
    ],
    [t],
  );
  const providerOptions = useMemo<SelectionMenuOption[]>(
    () => [
      {
        value: "metask",
        label: "Metask",
        description: t("settings.provider_managed_description"),
        descriptionKind: "text",
        disabled:
          account.state !== "authenticated" ||
          (metaskCatalogState !== "ready" && metaskCatalogState !== "choosing"),
      },
      ...models.customProviders.map((provider) => ({
        value: provider.id,
        label: provider.displayName || provider.id,
        description: customProviderProtocolLabel(provider.protocol, t),
        descriptionKind: "text" as const,
        disabled:
          !provider.enabled ||
          provider.credentialStatus !== "ready" ||
          provider.state === "disabled",
      })),
    ],
    [account.state, metaskCatalogState, models.customProviders, t],
  );
  const modelOptions = useMemo<SelectionMenuOption[]>(() => {
    const options =
      selectedProviderId === "metask"
        ? metaskModels.map((model) => ({
            value: model.id,
            label: modelLabel(model, t),
          }))
        : (selectedCustomProvider?.models ?? []).map((model) => ({
            value: model.id,
            label: model.displayName || model.id,
            disabled: !model.ready,
          }));
    return options;
  }, [metaskModels, selectedCustomProvider, selectedProviderId, t]);
  const customProviderProtocolOptions = useMemo<SelectionMenuOption[]>(
    () =>
      (
        [
          "openai_responses",
          "openai_chat_completions",
          "anthropic_messages",
          "gemini_native",
        ] as const
      ).map((protocol) => ({
        value: protocol,
        label: customProviderProtocolLabel(protocol, t),
      })),
    [t],
  );
  const selectedBuiltinPreset = models.builtinProviderPresets.find(
    (preset) => preset.id === builtinProviderDraft.providerId,
  );
  const selectedBuiltinProvider = models.customProviders.find(
    (provider) =>
      provider.builtinProviderId === builtinProviderDraft.providerId,
  );
  const customProviders = models.customProviders.filter(
    (provider) => provider.builtinProviderId === null,
  );
  const displayedModelId = providerIsMetask
    ? committedProviderId === "metask"
      ? selectedModelId
      : ""
    : selectedCustomProvider &&
        models.defaultSelection?.sourceId === selectedCustomProvider.id
      ? models.defaultSelection.modelId
      : "";
  const modelHasAlternative = modelOptions.some(
    (option) => option.value !== displayedModelId,
  );
  const modelIsOnlyOption =
    displayedModelId.length > 0 &&
    modelOptions.length === 1 &&
    !modelHasAlternative;
  const modelPlaceholder =
    providerIsMetask && modelCatalogLoading
      ? t("settings.model_loading")
      : t("account.choose_model");
  const committedModelName =
    (committedModel ? modelLabel(committedModel, t) : "") ||
    selectedModelId ||
    t("account.model_fallback");
  const candidateModelName =
    (candidateModel ? modelLabel(candidateModel, t) : "") ||
    (requestedModel?.selectionId === candidateModelId
      ? requestedModel.label
      : candidateModelId) ||
    t("account.model_fallback");
  const modelHasPendingChange =
    candidateModelId.length > 0 && candidateModelId !== selectedModelId;
  const transactionStatus = (() => {
    if (!providerIsMetask) return null;
    switch (metaskCatalogState) {
      case "needs_authentication":
        return null;
      case "loading":
        if (modelHasPendingChange) {
          return {
            title: t("settings.switch.preparing_model", {
              model: candidateModelName,
            }),
            detail: t("settings.switch.current_model_preserved", {
              model: committedModelName,
            }),
          };
        }
        return {
          title: t("settings.loading_models"),
          detail: t("settings.switch.refreshing"),
        };
      case "choosing":
        return {
          title: t("account.choose_model"),
          detail: t("settings.default_model_help"),
        };
      case "unavailable":
      case "ready":
      case "failed":
        return null;
    }
  })();

  useEffect(() => {
    if (focusTarget === "providers" && customProviderSettingsAvailable) {
      setActiveSection("providers");
    } else if (focusTarget === "models") {
      setActiveSection("models");
    } else if (focusTarget === "account") {
      setActiveSection("account");
    }
  }, [focusTarget, customProviderSettingsAvailable]);

  useEffect(() => {
    if (activeSection === "providers" && !customProviderSettingsAvailable) {
      setActiveSection("general");
      return;
    }
    const frame = window.requestAnimationFrame(() => {
      if (activeSection === "general" && focusTarget === "title") {
        generalHeading.current?.focus();
      } else if (activeSection === "account") {
        accountHeading.current?.focus();
      } else if (activeSection === "models") {
        modelsHeading.current?.focus();
      } else if (activeSection === "providers") {
        providersHeading.current?.focus();
      }
    });
    return () => window.cancelAnimationFrame(frame);
  }, [
    activeSection,
    focusTarget,
    customProviderSettingsAvailable,
    providersPage,
  ]);

  useEffect(() => {
    content.current?.scrollTo?.({ top: 0, behavior: "auto" });
  }, [activeSection, providersPage]);

  useEffect(() => {
    if (activeSection === "providers") return;
    setProvidersPage("list");
    setCustomProviderDraft(null);
    setBuiltinProviderDraft(newBuiltinProviderDraft());
    setCustomProviderCredentialEdit(null);
  }, [activeSection]);

  useEffect(() => {
    if (!confirmSignOut) return;
    const frame = window.requestAnimationFrame(() =>
      signOutCancel.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [confirmSignOut]);

  useEffect(() => {
    if (
      !automaticRootPending ||
      automaticRootPending.generation === automaticWorkspaceRoot.generation
    )
      return;
    const action = automaticRootPending.action;
    setAutomaticRootPending(null);
    setAutomaticRootMutationFailed(false);
    restoreAutomaticRootFocus(action);
  }, [automaticWorkspaceRoot.generation, automaticRootPending]);

  function restoreAutomaticRootFocus(action: AutomaticWorkspaceRootAction) {
    const origin =
      action === "choose"
        ? automaticRootChooseButton
        : action === "reset"
          ? automaticRootResetButton
          : automaticRootRetryButton;
    window.requestAnimationFrame(() =>
      (
        origin.current ??
        automaticRootChooseButton.current ??
        automaticRootResetButton.current ??
        automaticRootRetryButton.current
      )?.focus(),
    );
  }

  async function mutateAutomaticWorkspaceRoot(
    action: AutomaticWorkspaceRootAction,
  ) {
    if (automaticRootPending) return;
    const generation = automaticWorkspaceRoot.generation;
    setAutomaticRootMutationFailed(false);
    setAutomaticRootPending({ action, generation });
    const invoke =
      action === "choose"
        ? onChooseAutomaticWorkspaceRoot
        : action === "reset"
          ? onResetAutomaticWorkspaceRoot
          : onRetryAutomaticWorkspaceRoot;
    let outcome: AutomaticWorkspaceRootMutationOutcome;
    try {
      outcome = await invoke(generation);
    } catch {
      outcome = false;
    }
    // A canonical refresh can win the race with a lost/late command result.
    // Once generation advances, that Snapshot is authoritative for both the
    // value and the action state; never paint a stale local failure over it.
    if (automaticRootGeneration.current !== generation) return;
    if (outcome === "applied") return;
    setAutomaticRootPending(null);
    setAutomaticRootMutationFailed(outcome === false);
    restoreAutomaticRootFocus(action);
  }

  const automaticRootDisplay =
    automaticWorkspaceRoot.canonicalRoot ??
    t("settings.automatic_workspace.location_unavailable");
  const automaticRootHasAttention = automaticWorkspaceRoot.health !== "ready";
  const automaticRootHealthMessage: MessageId =
    automaticWorkspaceRoot.health === "write_failed" &&
    automaticWorkspaceRoot.canonicalRoot === null
      ? "settings.automatic_workspace.health.write_failed_no_active"
      : `settings.automatic_workspace.health.${automaticWorkspaceRoot.health}`;

  useEffect(() => {
    if (customProviderCapabilities.secretCapture) return;
    setCustomProviderDraft(null);
    setBuiltinProviderDraft(newBuiltinProviderDraft());
    setCustomProviderCredentialEdit(null);
    setCreatingCustomProvider(false);
  }, [customProviderCapabilities.secretCapture]);

  useEffect(() => {
    setCustomProviderEdit((current) => {
      if (!current) return null;
      const provider = models.customProviders.find(
        (candidate) => candidate.id === current.providerId,
      );
      return provider?.providerRevision === current.expectedProviderRevision
        ? current
        : null;
    });
    setCustomProviderRemoval((current) => {
      if (!current) return null;
      const provider = models.customProviders.find(
        (candidate) => candidate.id === current.providerId,
      );
      return provider?.providerRevision === current.expectedProviderRevision
        ? current
        : null;
    });
    setCustomProviderCredentialEdit((current) => {
      if (!current) return null;
      const provider = models.customProviders.find(
        (candidate) => candidate.id === current.providerId,
      );
      return provider?.providerRevision === current.expectedProviderRevision
        ? current
        : null;
    });
  }, [models.customProviders]);

  useEffect(() => {
    if (
      models.errorCode !== "none" ||
      account.state !== "authenticated" ||
      (metaskCatalogState === "ready" && !disabled)
    ) {
      setRequestedModel(null);
    }
  }, [
    models.errorCode,
    metaskCatalogState,
    models.metaskSelection,
    account.state,
    disabled,
  ]);

  useEffect(() => {
    if (
      requestedProviderId !== null &&
      committedProviderId === requestedProviderId
    ) {
      setRequestedProviderId(null);
    }
  }, [committedProviderId, requestedProviderId]);

  function closeSignOutConfirmation() {
    setConfirmSignOut(false);
    window.requestAnimationFrame(() => signOut.current?.focus());
  }

  async function submitCustomProvider() {
    if (!customProviderDraft || creatingCustomProvider) return;
    const baseUrl = customProviderDraft.baseUrl.trim();
    const displayName = customProviderDraft.displayName.trim();
    if (!displayName || !baseUrl || !customProviderDraft.apiKey) return;
    const input = {
      displayName,
      protocol: customProviderDraft.protocol,
      normalizedBaseUrl: customProviderEndpointFromBaseUrl(
        customProviderDraft.protocol,
        baseUrl,
      ),
      apiKey: customProviderDraft.apiKey,
    };
    setCreatingCustomProvider(true);
    try {
      if (await onCreateCustomProvider(input)) {
        setCustomProviderDraft(null);
        setBuiltinProviderDraft(newBuiltinProviderDraft());
        setProvidersPage("list");
      }
    } finally {
      setCreatingCustomProvider(false);
    }
  }

  async function submitBuiltinProvider() {
    if (
      creatingCustomProvider ||
      !builtinProviderDraft.providerId ||
      !builtinProviderDraft.baseUrl.trim() ||
      !builtinProviderDraft.apiKey ||
      !selectedBuiltinPreset
    )
      return;
    setCreatingCustomProvider(true);
    try {
      if (
        await onCreateBuiltinProvider({
          providerId: builtinProviderDraft.providerId,
          baseUrl: builtinProviderDraft.baseUrl.trim(),
          apiKey: builtinProviderDraft.apiKey,
        })
      ) {
        setBuiltinProviderDraft(newBuiltinProviderDraft());
        setCustomProviderDraft(null);
        setProvidersPage("list");
      }
    } finally {
      setCreatingCustomProvider(false);
    }
  }

  function openBuiltinProvider(providerId: BuiltinProviderId) {
    const preset = models.builtinProviderPresets.find(
      (candidate) => candidate.id === providerId,
    );
    if (!preset) return;
    const provider = models.customProviders.find(
      (candidate) => candidate.builtinProviderId === providerId,
    );
    setCustomProviderDraft(null);
    setCustomProviderEdit(null);
    setCustomProviderCredentialEdit(null);
    setCustomProviderRemoval(null);
    setBuiltinProviderDraft({
      providerId,
      baseUrl: provider
        ? customProviderBaseUrlFromEndpoint(
            provider.protocol,
            provider.normalizedBaseUrl,
          )
        : preset.defaultBaseUrl,
      apiKey: "",
      editingBaseUrl: false,
    });
    setProvidersPage("builtin");
  }

  async function updateBuiltinProviderBaseUrl() {
    if (
      !selectedBuiltinProvider ||
      !builtinProviderDraft.baseUrl.trim() ||
      mutatingCustomProvider
    )
      return;
    setMutatingCustomProvider(true);
    try {
      if (
        await onUpdateBuiltinProviderBaseUrl({
          providerId: selectedBuiltinProvider.id,
          expectedProviderRevision: selectedBuiltinProvider.providerRevision,
          baseUrl: builtinProviderDraft.baseUrl.trim(),
        })
      ) {
        setBuiltinProviderDraft(newBuiltinProviderDraft());
        setProvidersPage("list");
      }
    } finally {
      setMutatingCustomProvider(false);
    }
  }

  async function replaceCustomProviderCredential() {
    if (!customProviderCredentialEdit || mutatingCustomProvider) return;
    if (!customProviderCredentialEdit.apiKey) return;
    setMutatingCustomProvider(true);
    try {
      if (
        await onReplaceCustomProviderCredential(
          customProviderCredentialEdit.providerId,
          customProviderCredentialEdit.expectedProviderRevision,
          customProviderCredentialEdit.apiKey,
        )
      ) {
        setCustomProviderCredentialEdit(null);
      }
    } finally {
      setMutatingCustomProvider(false);
    }
  }

  async function addCustomModel() {
    const modelId = customModelId.trim();
    if (!selectedCustomProvider || !modelId || addingCustomModel) return;
    setAddingCustomModel(true);
    try {
      if (
        await onAddCustomModel(
          selectedCustomProvider.id,
          selectedCustomProvider.providerRevision,
          selectedCustomProvider.catalogGeneration,
          modelId,
        )
      ) {
        setCustomModelId("");
      }
    } finally {
      setAddingCustomModel(false);
    }
  }

  async function removeCustomModel() {
    if (!customModelRemoval || mutatingCustomProvider) return;
    setMutatingCustomProvider(true);
    try {
      if (
        await onRemoveCustomModel(
          customModelRemoval.providerId,
          customModelRemoval.expectedProviderRevision,
          customModelRemoval.expectedCatalogGeneration,
          customModelRemoval.modelId,
        )
      ) {
        setCustomModelRemoval(null);
      }
    } finally {
      setMutatingCustomProvider(false);
    }
  }

  async function submitCustomProviderEdit() {
    if (!customProviderEdit || mutatingCustomProvider) return;
    const baseUrl = customProviderEdit.baseUrl.trim();
    const displayName = customProviderEdit.displayName.trim();
    if (!displayName || !baseUrl) return;
    const input = {
      providerId: customProviderEdit.providerId,
      expectedProviderRevision: customProviderEdit.expectedProviderRevision,
      displayName,
      protocol: customProviderEdit.protocol,
      normalizedBaseUrl: customProviderEndpointFromBaseUrl(
        customProviderEdit.protocol,
        baseUrl,
      ),
    };
    setMutatingCustomProvider(true);
    try {
      if (await onUpdateCustomProvider(input)) {
        setCustomProviderCredentialEdit(null);
        setCustomProviderEdit(null);
      }
    } finally {
      setMutatingCustomProvider(false);
    }
  }

  async function removeCustomProvider() {
    if (!customProviderRemoval || mutatingCustomProvider) return;
    setMutatingCustomProvider(true);
    try {
      if (
        await onRemoveCustomProvider(
          customProviderRemoval.providerId,
          customProviderRemoval.expectedProviderRevision,
        )
      ) {
        setCustomProviderRemoval(null);
        if (providersPage === "builtin") {
          setCustomProviderCredentialEdit(null);
          setBuiltinProviderDraft(newBuiltinProviderDraft());
          setProvidersPage("list");
        }
      }
    } finally {
      setMutatingCustomProvider(false);
    }
  }

  return (
    <div
      className="settings-page"
      role="dialog"
      aria-modal="true"
      aria-labelledby="settings-page-title"
      tabIndex={-1}
      onKeyDown={(event) => {
        if (event.key !== "Escape" || event.defaultPrevented) return;
        const nestedOverlay = (event.target as HTMLElement).closest(
          '[role="menu"], [role="listbox"], [role="dialog"], [role="alertdialog"]',
        );
        if (nestedOverlay && nestedOverlay !== event.currentTarget) return;
        event.preventDefault();
        if (activeSection === "providers" && providersPage !== "list") {
          setCustomProviderDraft(null);
          setBuiltinProviderDraft(newBuiltinProviderDraft());
          setCustomProviderCredentialEdit(null);
          setCustomProviderRemoval(null);
          setProvidersPage("list");
          return;
        }
        onBack();
      }}
    >
      <header className="settings-header">
        <div className="settings-back-slot">
          <button className="settings-back focus-ring" onClick={onBack}>
            <Icon name="arrow-left" />
            {t("settings.back")}
          </button>
        </div>
      </header>

      <div className="settings-layout">
        <nav className="settings-nav" aria-label={t("settings.sections")}>
          <a
            className="focus-ring"
            href="#settings-general"
            aria-current={activeSection === "general" ? "location" : undefined}
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("general");
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="settings" />
            </span>
            <span>{t("settings.general")}</span>
          </a>
          <a
            className="focus-ring"
            href="#settings-account"
            aria-current={activeSection === "account" ? "location" : undefined}
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("account");
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="account" />
            </span>
            <span>{t("settings.account")}</span>
          </a>
          <a
            className="focus-ring"
            href="#settings-models"
            aria-current={activeSection === "models" ? "location" : undefined}
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("models");
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="model" />
            </span>
            <span>{t("settings.models")}</span>
          </a>
          <a
            className="focus-ring"
            href="#settings-providers"
            aria-current={
              activeSection === "providers" ? "location" : undefined
            }
            hidden={!customProviderSettingsAvailable}
            onClick={(event) => {
              event.preventDefault();
              setCustomProviderDraft(null);
              setBuiltinProviderDraft(newBuiltinProviderDraft());
              setCustomProviderCredentialEdit(null);
              setCustomProviderRemoval(null);
              setProvidersPage("list");
              setActiveSection("providers");
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="provider" />
            </span>
            <span>{t("settings.providers")}</span>
          </a>
        </nav>

        <div ref={content} className="settings-content">
          <h1
            id="settings-page-title"
            ref={title}
            className="sr-only"
            tabIndex={-1}
          >
            {t("settings.title")}
          </h1>
          {activeSection === "general" && (
            <section id="settings-general" className="settings-section">
              <div className="settings-section-heading">
                <h2 ref={generalHeading} tabIndex={-1}>
                  {t("settings.general")}
                </h2>
              </div>
              <div className="settings-group">
                <h3 className="settings-group-label">
                  {t("settings.general_basics")}
                </h3>
                <div className="settings-preference-list">
                  <div className="settings-row">
                    <div>
                      <label htmlFor="settings-language">
                        {t("app.language")}
                      </label>
                      <p>{t("settings.language_help")}</p>
                    </div>
                    <SelectionMenu
                      triggerId="settings-language"
                      value={locale}
                      options={languageOptions}
                      placeholder={t("app.language")}
                      ariaLabel={t("app.language")}
                      disabled={false}
                      triggerClassName="settings-control settings-control-compact"
                      onValueChange={(value) => setLocale(value as Locale)}
                    />
                  </div>
                  <div className="settings-row settings-automatic-root-row">
                    <div className="settings-automatic-root-copy">
                      <span className="settings-row-label">
                        {t("settings.automatic_workspace.title")}
                      </span>
                      <p>{t("settings.automatic_workspace.help")}</p>
                      <div className="settings-automatic-root-value">
                        <code
                          className="settings-automatic-root-location"
                          title={automaticRootDisplay}
                        >
                          {automaticRootDisplay}
                        </code>
                        {automaticWorkspaceRoot.mode === "system_default" ? (
                          <span className="settings-automatic-root-default">
                            {t("settings.automatic_workspace.system_default")}
                          </span>
                        ) : null}
                      </div>
                      {automaticRootHasAttention ? (
                        <p
                          className="settings-automatic-root-health"
                          role="status"
                        >
                          {t(automaticRootHealthMessage)}
                        </p>
                      ) : null}
                      {automaticRootMutationFailed &&
                      !automaticRootHasAttention ? (
                        <p
                          className="settings-automatic-root-error"
                          role="alert"
                        >
                          {t("settings.automatic_workspace.command_failed")}
                        </p>
                      ) : null}
                    </div>
                    <div className="settings-automatic-root-actions">
                      {automaticWorkspaceRoot.canChoose ? (
                        <Button
                          ref={automaticRootChooseButton}
                          variant="secondary"
                          size="sm"
                          disabled={disabled || automaticRootPending !== null}
                          onClick={() =>
                            void mutateAutomaticWorkspaceRoot("choose")
                          }
                        >
                          {automaticRootPending?.action === "choose"
                            ? t("settings.automatic_workspace.choosing")
                            : t("settings.automatic_workspace.choose")}
                        </Button>
                      ) : null}
                      {automaticWorkspaceRoot.canReset ? (
                        <Button
                          ref={automaticRootResetButton}
                          variant="secondary"
                          size="sm"
                          disabled={disabled || automaticRootPending !== null}
                          onClick={() =>
                            void mutateAutomaticWorkspaceRoot("reset")
                          }
                        >
                          {automaticRootPending?.action === "reset"
                            ? t("settings.automatic_workspace.resetting")
                            : t("settings.automatic_workspace.reset")}
                        </Button>
                      ) : null}
                      {automaticWorkspaceRoot.canRetry ? (
                        <Button
                          ref={automaticRootRetryButton}
                          variant="secondary"
                          size="sm"
                          disabled={disabled || automaticRootPending !== null}
                          onClick={() =>
                            void mutateAutomaticWorkspaceRoot("retry")
                          }
                        >
                          {automaticRootPending?.action === "retry"
                            ? t("settings.automatic_workspace.retrying")
                            : t("settings.automatic_workspace.retry")}
                        </Button>
                      ) : null}
                    </div>
                  </div>
                </div>
              </div>
            </section>
          )}

          {activeSection === "account" && (
            <section id="settings-account" className="settings-section">
              <div className="settings-section-heading">
                <h2 ref={accountHeading} tabIndex={-1}>
                  {t("settings.account")}
                </h2>
              </div>

              <div className="settings-group">
                <h3 className="settings-group-label">
                  {t("settings.account_profile")}
                </h3>
                <div
                  className="settings-identity-row"
                  data-session-state={account.state}
                >
                  <span className="settings-avatar" aria-hidden="true">
                    {accountIdentityInitial(account)}
                  </span>
                  <div className="settings-identity-copy">
                    <strong title={accountIdentityTitle}>
                      {accountIdentityTitle}
                    </strong>
                    {authenticated ? (
                      <div className="settings-identity-meta">
                        {account.emailHint &&
                        account.emailHint !== accountIdentityTitle ? (
                          <span title={account.emailHint}>
                            {account.emailHint}
                          </span>
                        ) : null}
                        {account.phoneHint &&
                        account.phoneHint !== accountIdentityTitle ? (
                          <span title={account.phoneHint}>
                            {account.phoneHint}
                          </span>
                        ) : null}
                        <span>
                          {t("settings.account_concurrency_limit", {
                            value:
                              account.concurrencyLimit === 0
                                ? t("settings.account_concurrency_unlimited")
                                : (account.concurrencyLimit ?? "—"),
                          })}
                        </span>
                      </div>
                    ) : (
                      <span>{accountIdentityBody}</span>
                    )}
                  </div>
                  {authenticated &&
                  account.summary.usageEligibility !== "disabled" ? (
                    <AccountBalance
                      wallet={account.summary.wallet}
                      disabled={disabled || accountDisabled}
                      onRecharge={onOpenRecharge}
                    />
                  ) : null}
                  {account.canCancel ? (
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={cancelDisabled}
                      onClick={onCancel}
                    >
                      {t("common.cancel")}
                    </Button>
                  ) : !authenticated ||
                    (account.errorCode !== "none" &&
                      account.errorCode !== "refresh_schedule_failed") ? (
                    <Button
                      className="settings-identity-login"
                      variant="secondary"
                      size="sm"
                      disabled={disabled || accountDisabled}
                      onClick={onBeginLogin}
                    >
                      {t("account.login")}
                    </Button>
                  ) : null}
                </div>
              </div>

              {account.errorCode !== "none" &&
                account.errorCode !== "user_cancelled" && (
                  <div className="settings-error" role="alert">
                    <Icon name="warning" />
                    <span className="settings-error-copy">
                      <strong>{t("account.action_failed")}</strong>
                      <span>{accountErrorText(account.errorCode, t)}</span>
                      {account.safeDiagnostic && (
                        <span className="settings-error-diagnostic">
                          {account.safeDiagnostic}
                        </span>
                      )}
                    </span>
                    {account.errorCode === "refresh_schedule_failed" && (
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={disabled || accountDisabled}
                        onClick={onRetryRefresh}
                      >
                        {t("account.retry_refresh")}
                      </Button>
                    )}
                  </div>
                )}

              {authenticated && (
                <AccountUsageSummary
                  summary={account.summary}
                  disabled={disabled || accountDisabled}
                  onRefresh={onRefreshAccountSummary}
                />
              )}

              {authenticated && (
                <div className="settings-group">
                  <h3 className="settings-group-label">
                    {t("settings.account_security")}
                  </h3>
                  <div className="settings-danger-zone">
                    <div>
                      <h3 id="settings-signout-title">
                        {t("settings.signout_title")}
                      </h3>
                      <p>{t("settings.signout_help")}</p>
                    </div>
                    {!confirmSignOut ? (
                      <Button
                        variant="danger"
                        size="sm"
                        ref={signOut}
                        disabled={disabled || accountDisabled}
                        onClick={() => setConfirmSignOut(true)}
                      >
                        {t("account.logout_short")}
                      </Button>
                    ) : (
                      <div
                        className="settings-signout-confirmation"
                        role="group"
                        aria-labelledby="settings-signout-title"
                        aria-describedby="settings-signout-confirmation-copy"
                        onKeyDown={(event) => {
                          if (event.key !== "Escape") return;
                          event.preventDefault();
                          closeSignOutConfirmation();
                        }}
                      >
                        <p id="settings-signout-confirmation-copy">
                          {t("account.logout_confirm")}
                        </p>
                        <span>
                          <Button
                            variant="secondary"
                            size="sm"
                            ref={signOutCancel}
                            onClick={closeSignOutConfirmation}
                          >
                            {t("common.cancel")}
                          </Button>
                          <Button
                            variant="danger"
                            size="sm"
                            disabled={disabled || accountDisabled}
                            onClick={onLogout}
                          >
                            {t("account.logout")}
                          </Button>
                        </span>
                      </div>
                    )}
                  </div>
                </div>
              )}
            </section>
          )}

          {activeSection === "models" && (
            <section id="settings-models" className="settings-section">
              <div className="settings-section-heading">
                <h2 ref={modelsHeading} tabIndex={-1}>
                  {t("settings.models")}
                </h2>
              </div>

              <div className="settings-group">
                <h3
                  id="settings-execution-title"
                  className="settings-group-label"
                >
                  {t("settings.default_model_for_new_tasks")}
                </h3>
                <div
                  className="settings-execution-group"
                  role="group"
                  aria-labelledby="settings-execution-title"
                >
                  <div className="settings-execution-header">
                    <span className="settings-current-default">
                      <span>{t("settings.current_default")}</span>
                      <strong>{currentDefaultLabel}</strong>
                    </span>
                    <div className="settings-execution-actions">
                      {providerIsMetask && (
                        <>
                          <span className="settings-catalog-count">
                            {t("settings.catalog_count", {
                              models: metaskModels.length,
                            })}
                          </span>
                          <button
                            className="settings-refresh-button focus-ring"
                            disabled={
                              disabled ||
                              accountDisabled ||
                              !authenticated ||
                              modelBusy
                            }
                            onClick={onRefresh}
                          >
                            <Icon name="refresh" />
                            {t("account.refresh_catalog")}
                          </button>
                        </>
                      )}
                    </div>
                  </div>

                  <div className="settings-field settings-field-provider">
                    <span className="settings-field-step" aria-hidden="true">
                      01
                    </span>
                    <div className="settings-field-copy">
                      <label>{t("settings.provider")}</label>
                      <p>{t("settings.provider_help")}</p>
                    </div>
                    <div className="settings-control-stack">
                      <SelectionMenu
                        value={selectedProviderId}
                        options={providerOptions}
                        placeholder={t("settings.choose_provider")}
                        ariaLabel={t("settings.provider")}
                        helper={t("settings.provider_menu_help")}
                        actionLabel={t(
                          selectedProviderId
                            ? "settings.change_selection"
                            : "settings.choose_selection",
                        )}
                        disabled={
                          disabled || executionDisabled || !canChooseProvider
                        }
                        valueLayout="detailed"
                        leading={<Icon name="provider" />}
                        triggerClassName="settings-control settings-control-detailed"
                        contentClassName="settings-selection-menu"
                        onValueChange={(value) => {
                          setRequestedProviderId(value);
                          setRequestedModel(null);
                          setCustomModelId("");
                        }}
                      />
                    </div>
                  </div>

                  <div className="settings-field">
                    <span className="settings-field-step" aria-hidden="true">
                      02
                    </span>
                    <div className="settings-field-copy">
                      <label htmlFor="settings-model">
                        {t("settings.default_model")}
                      </label>
                      <p>
                        {!providerIsMetask &&
                        selectedCustomProvider?.models.length === 0
                          ? t("settings.custom_model_add_help")
                          : providerIsMetask && modelCatalogLoading
                            ? t("settings.loading_models")
                            : t(
                                modelIsOnlyOption
                                  ? "settings.only_model_help"
                                  : "settings.default_model_help",
                              )}
                      </p>
                    </div>
                    <div className="settings-control-stack">
                      <SelectionMenu
                        triggerId="settings-model"
                        value={
                          providerIsMetask
                            ? candidateModelId || displayedModelId
                            : displayedModelId
                        }
                        options={modelOptions}
                        placeholder={modelPlaceholder}
                        ariaLabel={t("settings.default_model")}
                        helper={t("settings.model_menu_help")}
                        actionLabel={t(
                          modelIsOnlyOption
                            ? "settings.view_selection"
                            : displayedModelId
                              ? "settings.change_selection"
                              : "settings.choose_selection",
                        )}
                        disabled={
                          disabled ||
                          (providerIsMetask && accountDisabled) ||
                          !canChooseModel ||
                          modelOptions.length === 0
                        }
                        busy={providerIsMetask && modelBusy}
                        leading={<Icon name="model" />}
                        triggerClassName="settings-control"
                        contentClassName="settings-selection-menu"
                        onValueChange={(value) => {
                          if (!providerIsMetask && selectedCustomProvider) {
                            onSelectCustomModel(
                              selectedCustomProvider.id,
                              selectedCustomProvider.providerRevision,
                              value,
                            );
                            return;
                          }
                          const model = metaskModels.find(
                            (candidate) => candidate.id === value,
                          );
                          if (!model) return;
                          setRequestedModel({
                            selectionId: value,
                            label: modelLabel(model, t),
                          });
                          onSelectModel(value);
                        }}
                      />
                      {!providerIsMetask && selectedCustomProvider && (
                        <div className="settings-custom-model-manager">
                          {selectedCustomProvider.models.map((model) => (
                            <div
                              className="settings-custom-model-entry"
                              key={model.id}
                            >
                              <div className="settings-custom-model-test">
                                <span>
                                  <code>{model.displayName || model.id}</code>
                                  <small>
                                    {customModelTestStatusLabel(
                                      model.testStatus,
                                      t,
                                    )}
                                  </small>
                                </span>
                                <div className="settings-custom-model-actions">
                                  <Button
                                    variant="secondary"
                                    size="sm"
                                    disabled={
                                      disabled ||
                                      executionDisabled ||
                                      !customProviderCapabilities.modelTest ||
                                      selectedCustomProvider.credentialStatus !==
                                        "ready" ||
                                      model.testStatus === "testing"
                                    }
                                    onClick={() =>
                                      onTestCustomModel(
                                        selectedCustomProvider.id,
                                        selectedCustomProvider.providerRevision,
                                        model.id,
                                        selectedCustomProvider.sourceGeneration,
                                        selectedCustomProvider.catalogGeneration,
                                      )
                                    }
                                  >
                                    {model.testStatus === "testing"
                                      ? t("settings.custom_model_testing")
                                      : t("settings.custom_model_test")}
                                  </Button>
                                  <Button
                                    variant="ghost"
                                    size="sm"
                                    disabled={
                                      disabled ||
                                      executionDisabled ||
                                      mutatingCustomProvider
                                    }
                                    onClick={() =>
                                      setCustomModelRemoval({
                                        providerId: selectedCustomProvider.id,
                                        expectedProviderRevision:
                                          selectedCustomProvider.providerRevision,
                                        expectedCatalogGeneration:
                                          selectedCustomProvider.catalogGeneration,
                                        modelId: model.id,
                                      })
                                    }
                                  >
                                    {t("common.remove")}
                                  </Button>
                                </div>
                              </div>
                              {customModelRemoval?.providerId ===
                                selectedCustomProvider.id &&
                                customModelRemoval.modelId === model.id && (
                                  <div
                                    className="settings-custom-model-confirm-remove"
                                    role="group"
                                    aria-label={t(
                                      "settings.custom_model_remove_confirm",
                                    )}
                                  >
                                    <p>
                                      {t(
                                        "settings.custom_model_remove_confirm",
                                      )}
                                    </p>
                                    <Button
                                      variant="ghost"
                                      size="sm"
                                      disabled={mutatingCustomProvider}
                                      onClick={() =>
                                        setCustomModelRemoval(null)
                                      }
                                    >
                                      {t("common.cancel")}
                                    </Button>
                                    <Button
                                      variant="danger"
                                      size="sm"
                                      disabled={
                                        disabled ||
                                        executionDisabled ||
                                        mutatingCustomProvider
                                      }
                                      onClick={() => void removeCustomModel()}
                                    >
                                      {mutatingCustomProvider
                                        ? t("settings.custom_model_removing")
                                        : t("common.remove")}
                                    </Button>
                                  </div>
                                )}
                            </div>
                          ))}
                          <form
                            className="settings-custom-model-add"
                            onSubmit={(event) => {
                              event.preventDefault();
                              void addCustomModel();
                            }}
                          >
                            <input
                              className="settings-custom-provider-input settings-custom-provider-input-mono focus-ring"
                              aria-label={t("settings.custom_model_id")}
                              autoComplete="off"
                              maxLength={256}
                              value={customModelId}
                              placeholder={t(
                                "settings.custom_provider_model_id_placeholder",
                              )}
                              disabled={
                                disabled ||
                                executionDisabled ||
                                addingCustomModel
                              }
                              onChange={(event) =>
                                setCustomModelId(event.target.value)
                              }
                            />
                            <Button
                              type="submit"
                              size="sm"
                              disabled={
                                disabled ||
                                executionDisabled ||
                                addingCustomModel ||
                                !customModelId.trim()
                              }
                            >
                              {addingCustomModel
                                ? t("settings.custom_model_adding")
                                : t("settings.custom_model_add")}
                            </Button>
                          </form>
                        </div>
                      )}
                      {providerIsMetask && modelHasPendingChange && (
                        <span className="settings-pending-label">
                          <span aria-hidden="true" />
                          {t("settings.switch.pending_label")}
                        </span>
                      )}
                    </div>
                  </div>

                  {transactionStatus && (
                    <div
                      className="settings-operation"
                      role="status"
                      aria-live="polite"
                    >
                      <span
                        className="settings-operation-dot"
                        aria-hidden="true"
                      />
                      <span className="settings-operation-copy">
                        <strong>{transactionStatus.title}</strong>
                        <span>{transactionStatus.detail}</span>
                      </span>
                    </div>
                  )}
                </div>

                <p className="settings-binding-note">
                  <Icon name="check" />
                  {t("settings.existing_tasks_unchanged")}
                </p>

                {models.persistenceHealth === "recovery_required" && (
                  <ConfirmationNotice
                    className="task-persistence-error settings-model-reset-notice"
                    message={t("settings.models_reset_message")}
                    detail={t("settings.models_reset_detail")}
                    actionLabel={t("settings.models_reset_action")}
                    dialogTitle={t("settings.models_reset_dialog_title")}
                    dialogDescription={t("settings.models_reset_dialog_body")}
                    cancelLabel={t("common.cancel")}
                    confirmLabel={t("settings.models_reset_confirm")}
                    pendingLabel={t("settings.models_reset_pending")}
                    failureMessage={t("settings.models_reset_failed")}
                    actionAvailable
                    disabled={disabled || executionDisabled}
                    onConfirm={async () =>
                      (await onResetModels())
                        ? null
                        : t("settings.models_reset_failed")
                    }
                  />
                )}

                {((models.errorCode !== "none" &&
                  models.errorCode !== "authorization_unavailable") ||
                  metaskDefaultUnavailable) && (
                  <div className="settings-error" role="alert">
                    <Icon name="warning" />
                    <span className="settings-error-copy">
                      <strong>{t("settings.models_error")}</strong>
                      <span>
                        {t(
                          models.errorCode === "no_models"
                            ? "account.error.no_models"
                            : metaskDefaultUnavailable
                              ? "settings.default_model_unavailable"
                              : "settings.models_error_help",
                        )}
                      </span>
                    </span>
                  </div>
                )}
              </div>
            </section>
          )}

          {activeSection === "providers" && customProviderSettingsAvailable && (
            <section
              id="settings-providers"
              className="settings-section"
              aria-labelledby="settings-providers-title"
            >
              <div className="settings-section-heading">
                <h2
                  id="settings-providers-title"
                  ref={providersHeading}
                  tabIndex={-1}
                >
                  {providersPage === "builtin" && selectedBuiltinPreset
                    ? selectedBuiltinPreset.displayName
                    : providersPage === "custom"
                      ? t("settings.custom_provider_title")
                      : t("settings.providers")}
                </h2>
              </div>
              <div className="settings-group">
                <h3 className="settings-group-label">
                  {providersPage === "builtin"
                    ? t("settings.builtin_provider")
                    : providersPage === "custom"
                      ? t("settings.custom_provider")
                      : t("settings.providers_saved")}
                </h3>
                <div className="settings-custom-providers">
                  <div className="settings-execution-header">
                    {providersPage === "list" ? (
                      <div>
                        <p>{t("settings.providers_help")}</p>
                        <p>{t("model_setup.provider_next")}</p>
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          disabled={disabled}
                          onClick={() => setActiveSection("models")}
                        >
                          {t("settings.open_models")}
                        </Button>
                      </div>
                    ) : (
                      <button
                        type="button"
                        className="settings-subpage-back text-button focus-ring"
                        onClick={() => {
                          setCustomProviderDraft(null);
                          setBuiltinProviderDraft(newBuiltinProviderDraft());
                          setCustomProviderCredentialEdit(null);
                          setCustomProviderRemoval(null);
                          setProvidersPage("list");
                        }}
                      >
                        <Icon name="arrow-left" />
                        {t("settings.back_to_providers")}
                      </button>
                    )}
                  </div>
                  {providersPage === "list" && (
                    <div className="settings-provider-directory">
                      <div className="settings-provider-directory-heading">
                        <div>
                          <strong>
                            {t("settings.builtin_provider_group")}
                          </strong>
                          <p>{t("settings.builtin_provider_group_help")}</p>
                        </div>
                      </div>
                      <div className="settings-custom-provider-list settings-builtin-provider-list">
                        {models.builtinProviderPresets.map((preset) => {
                          const provider = models.customProviders.find(
                            (candidate) =>
                              candidate.builtinProviderId === preset.id,
                          );
                          const status = !provider
                            ? t("settings.builtin_provider_unconfigured")
                            : provider.credentialStatus !== "ready"
                              ? customProviderCredentialLabel(
                                  provider.credentialStatus,
                                  t,
                                )
                              : provider.state === "configuring"
                                ? t("settings.builtin_provider_needs_models")
                                : customProviderStateLabel(provider.state, t);
                          return (
                            <div
                              className="settings-custom-provider settings-builtin-provider-row"
                              key={preset.id}
                            >
                              <div className="settings-custom-provider-copy">
                                <strong>{preset.displayName}</strong>
                                <span>{status}</span>
                              </div>
                              <div className="settings-custom-provider-actions">
                                <Button
                                  variant={provider ? "ghost" : "secondary"}
                                  size="sm"
                                  disabled={
                                    disabled ||
                                    executionDisabled ||
                                    mutatingCustomProvider
                                  }
                                  onClick={() => openBuiltinProvider(preset.id)}
                                >
                                  {provider
                                    ? t("settings.builtin_provider_manage")
                                    : t("settings.builtin_provider_configure")}
                                </Button>
                              </div>
                            </div>
                          );
                        })}
                      </div>
                    </div>
                  )}
                  {providersPage === "builtin" && selectedBuiltinPreset && (
                    <form
                      className="settings-custom-provider-create settings-builtin-provider-create"
                      onSubmit={(event) => {
                        event.preventDefault();
                        if (selectedBuiltinProvider) {
                          if (
                            customProviderCredentialEdit?.providerId ===
                            selectedBuiltinProvider.id
                          ) {
                            void replaceCustomProviderCredential();
                          } else if (builtinProviderDraft.editingBaseUrl) {
                            void updateBuiltinProviderBaseUrl();
                          }
                        } else {
                          void submitBuiltinProvider();
                        }
                      }}
                    >
                      <div className="settings-provider-create-intro">
                        <strong>{selectedBuiltinPreset.displayName}</strong>
                        <p>{t("settings.builtin_provider_help")}</p>
                      </div>
                      <div className="settings-builtin-provider-address settings-custom-provider-create-field-wide">
                        <div>
                          <span>{t("settings.builtin_provider_address")}</span>
                          <code>{builtinProviderDraft.baseUrl}</code>
                          <small>
                            {customProviderProtocolLabel(
                              selectedBuiltinPreset.protocol,
                              t,
                            )}
                          </small>
                        </div>
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          disabled={disabled || executionDisabled}
                          onClick={() => {
                            setCustomProviderCredentialEdit(null);
                            setBuiltinProviderDraft((current) => ({
                              ...current,
                              baseUrl: current.editingBaseUrl
                                ? selectedBuiltinProvider
                                  ? customProviderBaseUrlFromEndpoint(
                                      selectedBuiltinProvider.protocol,
                                      selectedBuiltinProvider.normalizedBaseUrl,
                                    )
                                  : selectedBuiltinPreset.defaultBaseUrl
                                : current.baseUrl,
                              editingBaseUrl: !current.editingBaseUrl,
                            }));
                          }}
                        >
                          {builtinProviderDraft.editingBaseUrl
                            ? t("common.cancel")
                            : t("settings.builtin_provider_change_address")}
                        </Button>
                      </div>
                      {builtinProviderDraft.editingBaseUrl && (
                        <label className="settings-custom-provider-create-field settings-custom-provider-create-field-wide">
                          <span>{t("settings.custom_provider_endpoint")}</span>
                          <input
                            className="settings-custom-provider-input focus-ring"
                            aria-label={t("settings.custom_provider_endpoint")}
                            autoComplete="url"
                            inputMode="url"
                            maxLength={2048}
                            value={builtinProviderDraft.baseUrl}
                            disabled={
                              disabled ||
                              executionDisabled ||
                              creatingCustomProvider ||
                              mutatingCustomProvider
                            }
                            onChange={(event) =>
                              setBuiltinProviderDraft((current) => ({
                                ...current,
                                baseUrl: event.target.value,
                              }))
                            }
                          />
                          <small className="settings-custom-provider-field-help">
                            {t("settings.custom_provider_endpoint_preview", {
                              endpoint: customProviderEndpointFromBaseUrl(
                                selectedBuiltinPreset.protocol,
                                builtinProviderDraft.baseUrl,
                              ),
                            })}
                          </small>
                          {trimTrailingSlashes(
                            builtinProviderDraft.baseUrl.trim(),
                          ) !==
                            trimTrailingSlashes(
                              selectedBuiltinPreset.defaultBaseUrl,
                            ) && (
                            <small className="settings-provider-address-warning">
                              {t("settings.builtin_provider_address_warning", {
                                host: providerAddressHost(
                                  builtinProviderDraft.baseUrl,
                                ),
                              })}
                            </small>
                          )}
                          <button
                            type="button"
                            className="text-button focus-ring settings-provider-reset-address"
                            onClick={() =>
                              setBuiltinProviderDraft((current) => ({
                                ...current,
                                baseUrl: selectedBuiltinPreset.defaultBaseUrl,
                              }))
                            }
                          >
                            {t("settings.builtin_provider_reset_address")}
                          </button>
                        </label>
                      )}
                      {!selectedBuiltinProvider && (
                        <label className="settings-custom-provider-create-field settings-custom-provider-create-field-wide">
                          <span>{t("settings.api_key")}</span>
                          <input
                            className="settings-custom-provider-input settings-custom-provider-input-mono focus-ring"
                            type="password"
                            autoComplete="off"
                            spellCheck={false}
                            maxLength={4096}
                            value={builtinProviderDraft.apiKey}
                            placeholder={t(
                              "settings.provider_api_key_placeholder",
                            )}
                            disabled={
                              disabled ||
                              executionDisabled ||
                              creatingCustomProvider
                            }
                            onChange={(event) =>
                              setBuiltinProviderDraft((current) => ({
                                ...current,
                                apiKey: event.target.value,
                              }))
                            }
                          />
                        </label>
                      )}
                      {selectedBuiltinProvider && (
                        <div className="settings-custom-provider-edit-credential settings-custom-provider-create-field-wide">
                          <div className="settings-custom-provider-edit-credential-copy">
                            <strong>{t("settings.api_key")}</strong>
                            <span>
                              {customProviderCredentialLabel(
                                selectedBuiltinProvider.credentialStatus,
                                t,
                              )}
                            </span>
                          </div>
                          <Button
                            type="button"
                            variant="secondary"
                            size="sm"
                            disabled={
                              disabled ||
                              executionDisabled ||
                              mutatingCustomProvider
                            }
                            onClick={() => {
                              setBuiltinProviderDraft((current) => ({
                                ...current,
                                baseUrl: customProviderBaseUrlFromEndpoint(
                                  selectedBuiltinProvider.protocol,
                                  selectedBuiltinProvider.normalizedBaseUrl,
                                ),
                                editingBaseUrl: false,
                              }));
                              setCustomProviderCredentialEdit({
                                providerId: selectedBuiltinProvider.id,
                                expectedProviderRevision:
                                  selectedBuiltinProvider.providerRevision,
                                apiKey: "",
                              });
                            }}
                          >
                            {t("settings.custom_provider_replace_credential")}
                          </Button>
                        </div>
                      )}
                      {selectedBuiltinProvider &&
                        customProviderCredentialEdit?.providerId ===
                          selectedBuiltinProvider.id && (
                          <div className="settings-custom-provider-credential-edit settings-custom-provider-create-field-wide">
                            <label className="settings-custom-provider-create-field">
                              <span>{t("settings.api_key")}</span>
                              <input
                                className="settings-custom-provider-input settings-custom-provider-input-mono focus-ring"
                                type="password"
                                autoComplete="off"
                                spellCheck={false}
                                maxLength={4096}
                                value={customProviderCredentialEdit.apiKey}
                                placeholder={t(
                                  "settings.provider_api_key_placeholder",
                                )}
                                disabled={mutatingCustomProvider}
                                onChange={(event) =>
                                  setCustomProviderCredentialEdit((current) =>
                                    current
                                      ? {
                                          ...current,
                                          apiKey: event.target.value,
                                        }
                                      : current,
                                  )
                                }
                              />
                            </label>
                            <div className="settings-custom-provider-credential-actions">
                              <Button
                                type="button"
                                variant="ghost"
                                size="sm"
                                disabled={mutatingCustomProvider}
                                onClick={() =>
                                  setCustomProviderCredentialEdit(null)
                                }
                              >
                                {t("common.cancel")}
                              </Button>
                              <Button
                                type="button"
                                size="sm"
                                disabled={
                                  mutatingCustomProvider ||
                                  !customProviderCredentialEdit.apiKey
                                }
                                onClick={() =>
                                  void replaceCustomProviderCredential()
                                }
                              >
                                {t("settings.provider_save_api_key")}
                              </Button>
                            </div>
                          </div>
                        )}
                      <div className="settings-custom-provider-create-footer">
                        <p>
                          <a
                            href={selectedBuiltinPreset.apiKeyUrl}
                            target="_blank"
                            rel="noreferrer"
                          >
                            {t("settings.get_api_key")}
                          </a>
                          <span aria-hidden="true"> · </span>
                          <a
                            href={selectedBuiltinPreset.documentationUrl}
                            target="_blank"
                            rel="noreferrer"
                          >
                            {t("settings.open_provider_docs")}
                          </a>
                        </p>
                        <div className="settings-provider-footer-actions">
                          {selectedBuiltinProvider && (
                            <Button
                              type="button"
                              variant="ghost"
                              size="sm"
                              onClick={() => {
                                setCustomProviderCredentialEdit(null);
                                setBuiltinProviderDraft(
                                  newBuiltinProviderDraft(),
                                );
                                setProvidersPage("list");
                                setActiveSection("models");
                              }}
                            >
                              {t("settings.open_models")}
                            </Button>
                          )}
                          {selectedBuiltinProvider && (
                            <button
                              type="button"
                              className="text-button settings-custom-provider-remove focus-ring"
                              onClick={() =>
                                setCustomProviderRemoval({
                                  providerId: selectedBuiltinProvider.id,
                                  expectedProviderRevision:
                                    selectedBuiltinProvider.providerRevision,
                                })
                              }
                            >
                              {t("common.remove")}
                            </button>
                          )}
                          {(!selectedBuiltinProvider ||
                            builtinProviderDraft.editingBaseUrl) && (
                            <Button
                              type="submit"
                              size="sm"
                              disabled={
                                disabled ||
                                executionDisabled ||
                                creatingCustomProvider ||
                                mutatingCustomProvider ||
                                !builtinProviderDraft.baseUrl.trim() ||
                                (!selectedBuiltinProvider &&
                                  !builtinProviderDraft.apiKey)
                              }
                            >
                              {creatingCustomProvider || mutatingCustomProvider
                                ? t("common.saving")
                                : t("settings.provider_save")}
                            </Button>
                          )}
                        </div>
                      </div>
                      {selectedBuiltinProvider &&
                        customProviderRemoval?.providerId ===
                          selectedBuiltinProvider.id && (
                          <div className="settings-custom-provider-confirm-remove settings-custom-provider-create-field-wide">
                            <p>
                              {t("settings.custom_provider_remove_confirm")}
                            </p>
                            <Button
                              type="button"
                              variant="ghost"
                              size="sm"
                              disabled={mutatingCustomProvider}
                              onClick={() => setCustomProviderRemoval(null)}
                            >
                              {t("common.cancel")}
                            </Button>
                            <Button
                              type="button"
                              variant="danger"
                              size="sm"
                              disabled={mutatingCustomProvider}
                              onClick={() => void removeCustomProvider()}
                            >
                              {t("common.remove")}
                            </Button>
                          </div>
                        )}
                    </form>
                  )}
                  {providersPage === "custom" && customProviderDraft && (
                    <form
                      id="settings-custom-provider-create"
                      className="settings-custom-provider-create settings-custom-provider-create-custom"
                      onSubmit={(event) => {
                        event.preventDefault();
                        void submitCustomProvider();
                      }}
                    >
                      <div className="settings-provider-create-intro">
                        <strong>{t("settings.custom_provider_title")}</strong>
                        <p>{t("settings.custom_provider_help")}</p>
                      </div>
                      <label className="settings-custom-provider-create-field settings-custom-provider-create-field-wide">
                        <span>{t("settings.custom_provider_name")}</span>
                        <input
                          className="settings-custom-provider-input focus-ring"
                          aria-label={t("settings.custom_provider_name")}
                          autoComplete="off"
                          maxLength={256}
                          value={customProviderDraft.displayName}
                          placeholder={t(
                            "settings.custom_provider_name_placeholder",
                          )}
                          disabled={
                            disabled ||
                            executionDisabled ||
                            creatingCustomProvider
                          }
                          onChange={(event) =>
                            setCustomProviderDraft((current) =>
                              current
                                ? {
                                    ...current,
                                    displayName: event.target.value,
                                  }
                                : current,
                            )
                          }
                        />
                        <small className="settings-custom-provider-field-help">
                          {t("settings.custom_provider_name_help")}
                        </small>
                      </label>
                      <div className="settings-custom-provider-create-field settings-custom-provider-create-field-wide">
                        <span>{t("settings.custom_provider_protocol")}</span>
                        <SelectionMenu
                          value={customProviderDraft.protocol}
                          options={customProviderProtocolOptions}
                          placeholder={t("settings.custom_provider_protocol")}
                          ariaLabel={t("settings.custom_provider_protocol")}
                          disabled={
                            disabled ||
                            executionDisabled ||
                            creatingCustomProvider
                          }
                          triggerClassName="settings-control"
                          onValueChange={(value) => {
                            const protocol = value as Protocol;
                            setCustomProviderDraft((current) =>
                              current
                                ? {
                                    ...current,
                                    protocol,
                                  }
                                : current,
                            );
                          }}
                        />
                      </div>
                      <label className="settings-custom-provider-create-field settings-custom-provider-create-field-wide">
                        <span>{t("settings.custom_provider_endpoint")}</span>
                        <input
                          className="settings-custom-provider-input focus-ring"
                          aria-label={t("settings.custom_provider_endpoint")}
                          autoComplete="url"
                          inputMode="url"
                          maxLength={2048}
                          value={customProviderDraft.baseUrl}
                          placeholder={
                            customProviderBaseUrlExamples[
                              customProviderDraft.protocol
                            ]
                          }
                          disabled={
                            disabled ||
                            executionDisabled ||
                            creatingCustomProvider
                          }
                          onChange={(event) =>
                            setCustomProviderDraft((current) =>
                              current
                                ? {
                                    ...current,
                                    baseUrl: event.target.value,
                                  }
                                : current,
                            )
                          }
                        />
                        <small
                          className="settings-custom-provider-field-help"
                          aria-live="polite"
                        >
                          {customProviderDraft.baseUrl.trim()
                            ? t("settings.custom_provider_endpoint_preview", {
                                endpoint: customProviderEndpointFromBaseUrl(
                                  customProviderDraft.protocol,
                                  customProviderDraft.baseUrl,
                                ),
                              })
                            : t("settings.custom_provider_endpoint_help")}
                        </small>
                      </label>
                      <label className="settings-custom-provider-create-field settings-custom-provider-create-field-wide">
                        <span>{t("settings.api_key")}</span>
                        <input
                          className="settings-custom-provider-input settings-custom-provider-input-mono focus-ring"
                          type="password"
                          autoComplete="off"
                          spellCheck={false}
                          maxLength={4096}
                          value={customProviderDraft.apiKey}
                          placeholder={t(
                            "settings.provider_api_key_placeholder",
                          )}
                          disabled={
                            disabled ||
                            executionDisabled ||
                            creatingCustomProvider
                          }
                          onChange={(event) =>
                            setCustomProviderDraft((current) =>
                              current
                                ? { ...current, apiKey: event.target.value }
                                : current,
                            )
                          }
                        />
                      </label>
                      <div className="settings-custom-provider-create-footer">
                        <p>
                          {t("settings.provider_models_configured_elsewhere")}
                        </p>
                        <Button
                          type="submit"
                          size="sm"
                          disabled={
                            disabled ||
                            executionDisabled ||
                            creatingCustomProvider ||
                            !customProviderDraft.displayName.trim() ||
                            !customProviderDraft.baseUrl.trim() ||
                            !customProviderDraft.apiKey
                          }
                        >
                          {creatingCustomProvider
                            ? t("settings.custom_provider_adding")
                            : t("settings.provider_save")}
                        </Button>
                      </div>
                    </form>
                  )}
                  {providersPage === "list" && (
                    <div className="settings-provider-directory settings-provider-directory-secondary">
                      <div className="settings-provider-directory-heading">
                        <div>
                          <strong>{t("settings.custom_provider_group")}</strong>
                          <p>{t("settings.custom_provider_group_help")}</p>
                        </div>
                        <Button
                          variant="ghost"
                          size="sm"
                          disabled={
                            disabled ||
                            executionDisabled ||
                            creatingCustomProvider
                          }
                          onClick={() => {
                            setBuiltinProviderDraft(newBuiltinProviderDraft());
                            setCustomProviderDraft(newCustomProviderDraft());
                            setProvidersPage("custom");
                          }}
                        >
                          {t("settings.custom_provider_add_action")}
                        </Button>
                      </div>
                    </div>
                  )}
                  {providersPage === "list" &&
                    (customProviders.length === 0 ? (
                      <p className="settings-custom-providers-empty">
                        {t("settings.providers_empty")}
                      </p>
                    ) : (
                      <div className="settings-custom-provider-list">
                        {customProviders.map((provider) => (
                          <div
                            className="settings-custom-provider"
                            key={provider.id}
                          >
                            <div className="settings-custom-provider-copy">
                              <strong>
                                {provider.displayName || provider.id}
                              </strong>
                              <span>
                                {customProviderProtocolLabel(
                                  provider.protocol,
                                  t,
                                )}
                                <span aria-hidden="true"> · </span>
                                {customProviderBaseUrlFromEndpoint(
                                  provider.protocol,
                                  provider.normalizedBaseUrl,
                                )}
                              </span>
                              <span>
                                {customProviderCredentialLabel(
                                  provider.credentialStatus,
                                  t,
                                )}
                                <span aria-hidden="true"> · </span>
                                {customProviderStateLabel(provider.state, t)}
                              </span>
                            </div>
                            <div className="settings-custom-provider-actions">
                              <button
                                className="text-button focus-ring"
                                disabled={
                                  disabled ||
                                  executionDisabled ||
                                  mutatingCustomProvider
                                }
                                onClick={() => {
                                  setCustomProviderRemoval(null);
                                  setCustomProviderCredentialEdit(null);
                                  setCustomProviderEdit({
                                    providerId: provider.id,
                                    expectedProviderRevision:
                                      provider.providerRevision,
                                    displayName: provider.displayName,
                                    protocol: provider.protocol,
                                    baseUrl: customProviderBaseUrlFromEndpoint(
                                      provider.protocol,
                                      provider.normalizedBaseUrl,
                                    ),
                                  });
                                }}
                              >
                                {t("common.edit")}
                              </button>
                              <button
                                className="text-button settings-custom-provider-remove focus-ring"
                                disabled={
                                  disabled ||
                                  executionDisabled ||
                                  mutatingCustomProvider
                                }
                                onClick={() => {
                                  setCustomProviderCredentialEdit(null);
                                  setCustomProviderEdit(null);
                                  setCustomProviderRemoval({
                                    providerId: provider.id,
                                    expectedProviderRevision:
                                      provider.providerRevision,
                                  });
                                }}
                              >
                                {t("common.remove")}
                              </button>
                            </div>
                            {customProviderEdit?.providerId === provider.id && (
                              <form
                                className="settings-custom-provider-edit"
                                onSubmit={(event) => {
                                  event.preventDefault();
                                  void submitCustomProviderEdit();
                                }}
                              >
                                <label className="settings-custom-provider-create-field">
                                  <span>
                                    {t("settings.custom_provider_name")}
                                  </span>
                                  <input
                                    className="settings-custom-provider-input focus-ring"
                                    autoComplete="off"
                                    maxLength={256}
                                    value={customProviderEdit.displayName}
                                    disabled={
                                      disabled ||
                                      executionDisabled ||
                                      mutatingCustomProvider
                                    }
                                    onChange={(event) =>
                                      setCustomProviderEdit((current) =>
                                        current
                                          ? {
                                              ...current,
                                              displayName: event.target.value,
                                            }
                                          : current,
                                      )
                                    }
                                  />
                                </label>
                                <div className="settings-custom-provider-create-field">
                                  <span>
                                    {t("settings.custom_provider_protocol")}
                                  </span>
                                  <SelectionMenu
                                    value={customProviderEdit.protocol}
                                    options={customProviderProtocolOptions}
                                    placeholder={t(
                                      "settings.custom_provider_protocol",
                                    )}
                                    ariaLabel={t(
                                      "settings.custom_provider_protocol",
                                    )}
                                    disabled={
                                      disabled ||
                                      executionDisabled ||
                                      mutatingCustomProvider
                                    }
                                    triggerClassName="settings-control"
                                    onValueChange={(value) => {
                                      const protocol = value as Protocol;
                                      setCustomProviderEdit((current) =>
                                        current
                                          ? {
                                              ...current,
                                              protocol,
                                            }
                                          : current,
                                      );
                                    }}
                                  />
                                </div>
                                <label className="settings-custom-provider-create-field settings-custom-provider-edit-endpoint">
                                  <span>
                                    {t("settings.custom_provider_endpoint")}
                                  </span>
                                  <input
                                    className="settings-custom-provider-input focus-ring"
                                    autoComplete="url"
                                    inputMode="url"
                                    maxLength={2048}
                                    value={customProviderEdit.baseUrl}
                                    disabled={
                                      disabled ||
                                      executionDisabled ||
                                      mutatingCustomProvider
                                    }
                                    onChange={(event) =>
                                      setCustomProviderEdit((current) =>
                                        current
                                          ? {
                                              ...current,
                                              baseUrl: event.target.value,
                                            }
                                          : current,
                                      )
                                    }
                                  />
                                </label>
                                <div className="settings-custom-provider-edit-credential">
                                  <div className="settings-custom-provider-edit-credential-copy">
                                    <strong>{t("settings.api_key")}</strong>
                                    <span>
                                      {customProviderCredentialLabel(
                                        provider.credentialStatus,
                                        t,
                                      )}
                                    </span>
                                  </div>
                                  <Button
                                    type="button"
                                    variant="secondary"
                                    size="sm"
                                    disabled={
                                      disabled ||
                                      executionDisabled ||
                                      mutatingCustomProvider ||
                                      !customProviderCapabilities.secretCapture ||
                                      customProviderCredentialEdit?.providerId ===
                                        provider.id
                                    }
                                    onClick={() =>
                                      setCustomProviderCredentialEdit({
                                        providerId: provider.id,
                                        expectedProviderRevision:
                                          provider.providerRevision,
                                        apiKey: "",
                                      })
                                    }
                                  >
                                    {t(
                                      "settings.custom_provider_replace_credential",
                                    )}
                                  </Button>
                                </div>
                                <div className="settings-custom-provider-edit-actions">
                                  <p>
                                    {t("settings.custom_provider_edit_help")}
                                  </p>
                                  <Button
                                    type="button"
                                    variant="ghost"
                                    size="sm"
                                    disabled={mutatingCustomProvider}
                                    onClick={() => {
                                      setCustomProviderCredentialEdit(null);
                                      setCustomProviderEdit(null);
                                    }}
                                  >
                                    {t("common.cancel")}
                                  </Button>
                                  <Button
                                    type="submit"
                                    size="sm"
                                    disabled={
                                      disabled ||
                                      executionDisabled ||
                                      mutatingCustomProvider ||
                                      !customProviderEdit.displayName.trim() ||
                                      !customProviderEdit.baseUrl.trim()
                                    }
                                  >
                                    {mutatingCustomProvider
                                      ? t("common.saving")
                                      : t("common.save")}
                                  </Button>
                                </div>
                              </form>
                            )}
                            {customProviderEdit?.providerId === provider.id &&
                              customProviderCredentialEdit?.providerId ===
                                provider.id && (
                                <form
                                  className="settings-custom-provider-credential-edit"
                                  onSubmit={(event) => {
                                    event.preventDefault();
                                    void replaceCustomProviderCredential();
                                  }}
                                >
                                  <label className="settings-custom-provider-create-field">
                                    <span>{t("settings.api_key")}</span>
                                    <input
                                      className="settings-custom-provider-input settings-custom-provider-input-mono focus-ring"
                                      type="password"
                                      autoComplete="off"
                                      spellCheck={false}
                                      maxLength={4096}
                                      value={
                                        customProviderCredentialEdit.apiKey
                                      }
                                      placeholder={t(
                                        "settings.provider_api_key_placeholder",
                                      )}
                                      disabled={
                                        disabled ||
                                        executionDisabled ||
                                        mutatingCustomProvider
                                      }
                                      onChange={(event) =>
                                        setCustomProviderCredentialEdit(
                                          (current) =>
                                            current
                                              ? {
                                                  ...current,
                                                  apiKey: event.target.value,
                                                }
                                              : current,
                                        )
                                      }
                                    />
                                  </label>
                                  <div className="settings-custom-provider-credential-actions">
                                    <Button
                                      type="button"
                                      variant="ghost"
                                      size="sm"
                                      disabled={mutatingCustomProvider}
                                      onClick={() =>
                                        setCustomProviderCredentialEdit(null)
                                      }
                                    >
                                      {t("common.cancel")}
                                    </Button>
                                    <Button
                                      type="submit"
                                      variant="secondary"
                                      size="sm"
                                      disabled={
                                        disabled ||
                                        executionDisabled ||
                                        mutatingCustomProvider ||
                                        !customProviderCredentialEdit.apiKey
                                      }
                                    >
                                      {mutatingCustomProvider
                                        ? t("common.saving")
                                        : t("settings.provider_save_api_key")}
                                    </Button>
                                  </div>
                                </form>
                              )}
                            {customProviderRemoval?.providerId ===
                              provider.id && (
                              <div
                                className="settings-custom-provider-confirm-remove"
                                role="group"
                                aria-label={t(
                                  "settings.custom_provider_remove_confirm",
                                )}
                              >
                                <p>
                                  {t("settings.custom_provider_remove_confirm")}
                                </p>
                                <Button
                                  variant="ghost"
                                  size="sm"
                                  disabled={mutatingCustomProvider}
                                  onClick={() => setCustomProviderRemoval(null)}
                                >
                                  {t("common.cancel")}
                                </Button>
                                <Button
                                  variant="danger"
                                  size="sm"
                                  disabled={
                                    disabled ||
                                    executionDisabled ||
                                    mutatingCustomProvider
                                  }
                                  onClick={() => void removeCustomProvider()}
                                >
                                  {mutatingCustomProvider
                                    ? t("settings.custom_provider_removing")
                                    : t("common.remove")}
                                </Button>
                              </div>
                            )}
                          </div>
                        ))}
                      </div>
                    ))}
                  {providersPage === "list" &&
                    customProviderCapabilities.management &&
                    !customProviderCapabilities.secretCapture && (
                      <p className="settings-custom-providers-empty">
                        {t("settings.custom_provider_capture_unavailable")}
                      </p>
                    )}
                </div>
              </div>
            </section>
          )}
        </div>
      </div>
    </div>
  );
}
