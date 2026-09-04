import { useEffect, useMemo, useRef, useState } from "react";

import type {
  AccountView,
  ModelsView,
  Protocol,
  PermissionProfile,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { ConfirmationNotice } from "../../components/ConfirmationNotice.tsx";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { useI18n, type Locale } from "../../i18n/context.ts";
import { accountErrorText } from "../../i18n/account-error.ts";

export type SettingsFocusTarget = "title" | "account" | "models" | "providers";
type SettingsSection =
  "general" | "permissions" | "account" | "models" | "providers";
type ProvidersPage = "list" | "add";
type RequestedSelection = {
  selectionId: string;
  label: string;
};
type ModelConnectionDraft = {
  displayName: string;
  protocol: Protocol;
  baseUrl: string;
};
type ModelConnectionSubmission = {
  displayName: string;
  protocol: Protocol;
  normalizedBaseUrl: string;
};
type ModelConnectionEditDraft = ModelConnectionDraft & {
  connectionId: string;
  expectedConnectionRevision: string;
};
type ModelConnectionEditSubmission = ModelConnectionSubmission & {
  connectionId: string;
  expectedConnectionRevision: string;
};
type ModelConnectionRemoval = {
  connectionId: string;
  expectedConnectionRevision: string;
};

const modelConnectionBaseUrlExamples: Record<Protocol, string> = {
  openai_responses: "https://api.openai.com/v1",
  anthropic_messages: "https://api.anthropic.com",
  openai_chat_completions: "https://api.openai.com/v1",
  gemini_native: "https://generativelanguage.googleapis.com",
};

const modelConnectionRequestPaths: Record<Protocol, string> = {
  openai_responses: "/responses",
  openai_chat_completions: "/chat/completions",
  anthropic_messages: "/v1/messages",
  gemini_native: "",
};

function trimTrailingSlashes(value: string) {
  return value.replace(/\/+$/u, "");
}

export function modelConnectionEndpointFromBaseUrl(
  protocol: Protocol,
  baseUrl: string,
) {
  const normalizedBase = trimTrailingSlashes(baseUrl.trim());
  const requestPath = modelConnectionRequestPaths[protocol];
  if (!requestPath || normalizedBase.endsWith(requestPath)) {
    return normalizedBase;
  }
  return `${normalizedBase}${requestPath}`;
}

function modelConnectionBaseUrlFromEndpoint(
  protocol: Protocol,
  endpoint: string,
) {
  const normalizedEndpoint = trimTrailingSlashes(endpoint);
  const requestPath = modelConnectionRequestPaths[protocol];
  return requestPath && normalizedEndpoint.endsWith(requestPath)
    ? normalizedEndpoint.slice(0, -requestPath.length)
    : normalizedEndpoint;
}

function newModelConnectionDraft(): ModelConnectionDraft {
  return {
    displayName: "",
    protocol: "openai_chat_completions",
    baseUrl: "",
  };
}

function apiLabel(
  api: ModelsView["providers"][number]["apiKeys"][number],
  t: ReturnType<typeof useI18n>["t"],
) {
  return api.name.trim() || `${t("account.api_fallback")} ${api.id}`;
}

function modelLabel(
  model: ModelsView["providers"][number]["models"][number],
  t: ReturnType<typeof useI18n>["t"],
) {
  return model.displayName.trim() || model.id;
}

function modelConnectionProtocolLabel(
  protocol: Protocol,
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`settings.model_connection_protocol.${protocol}`);
}

function modelConnectionCredentialLabel(
  status: ModelsView["connections"][number]["credentialStatus"],
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`settings.model_connection_credential.${status}`);
}

function modelConnectionStateLabel(
  state: ModelsView["connections"][number]["state"],
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`settings.model_connection_state.${state}`);
}

function modelConnectionTestStatusLabel(
  status: ModelsView["connections"][number]["testStatus"],
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`settings.model_connection_test_status.${status}`);
}

export function SettingsPage({
  account,
  models,
  modelConnectionCapabilities,
  permissionProfiles,
  focusTarget,
  initialSection = "general",
  disabled,
  accountDisabled,
  executionDisabled,
  cancelDisabled,
  onBack,
  onRefresh,
  onResetModels,
  onCancel,
  onSelectApiKey,
  onSelectModel,
  onCreateModelConnection,
  onUpdateModelConnection,
  onReplaceModelConnectionCredential,
  onAddCustomModel,
  onRemoveModelConnection,
  onTestModelConnection,
  onSelectModelConnection,
  onBeginLogin,
  onRetryRefresh,
  onLogout,
  onSetDefaultPermissionProfile,
}: {
  account: AccountView;
  models: ModelsView;
  modelConnectionCapabilities: {
    management: boolean;
    secretCapture: boolean;
    connectionTest: boolean;
  };
  permissionProfiles: {
    enabled: boolean;
    available: PermissionProfile[];
    defaultProfile: PermissionProfile;
    busy: boolean;
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
  onCancel: () => void;
  onSelectApiKey: (id: string) => void;
  onSelectModel: (id: string) => void;
  onCreateModelConnection: (
    input: ModelConnectionSubmission,
  ) => Promise<boolean>;
  onUpdateModelConnection: (
    input: ModelConnectionEditSubmission,
  ) => Promise<boolean>;
  onReplaceModelConnectionCredential: (
    connectionId: string,
    expectedConnectionRevision: string,
  ) => Promise<boolean>;
  onAddCustomModel: (
    connectionId: string,
    expectedConnectionRevision: string,
    expectedCatalogGeneration: string,
    modelId: string,
  ) => Promise<boolean>;
  onRemoveModelConnection: (
    connectionId: string,
    expectedConnectionRevision: string,
  ) => Promise<boolean>;
  onTestModelConnection: (
    connectionId: string,
    connectionRevision: string,
    modelId: string,
    sourceGeneration: string,
    catalogGeneration: string,
  ) => void;
  onSelectModelConnection: (
    connectionId: string,
    connectionRevision: string,
    modelId: string,
  ) => void;
  onBeginLogin: () => void;
  onRetryRefresh: () => void;
  onLogout: () => void;
  onSetDefaultPermissionProfile: (profile: PermissionProfile) => void;
}) {
  const { locale, setLocale, t } = useI18n();
  const modelConnectionSettingsAvailable =
    modelConnectionCapabilities.management &&
    modelConnectionCapabilities.secretCapture &&
    modelConnectionCapabilities.connectionTest;
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const [activeSection, setActiveSection] =
    useState<SettingsSection>(initialSection);
  const [providersPage, setProvidersPage] = useState<ProvidersPage>("list");
  const [requestedApi, setRequestedApi] = useState<RequestedSelection | null>(
    null,
  );
  const [requestedModel, setRequestedModel] =
    useState<RequestedSelection | null>(null);
  const [requestedProviderId, setRequestedProviderId] = useState<string | null>(
    null,
  );
  const [modelConnectionDraft, setModelConnectionDraft] =
    useState<ModelConnectionDraft | null>(null);
  const [creatingModelConnection, setCreatingModelConnection] = useState(false);
  const [customModelId, setCustomModelId] = useState("");
  const [addingCustomModel, setAddingCustomModel] = useState(false);
  const [modelConnectionEdit, setModelConnectionEdit] =
    useState<ModelConnectionEditDraft | null>(null);
  const [modelConnectionRemoval, setModelConnectionRemoval] =
    useState<ModelConnectionRemoval | null>(null);
  const [mutatingModelConnection, setMutatingModelConnection] = useState(false);
  const content = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const generalHeading = useRef<HTMLHeadingElement>(null);
  const permissionsHeading = useRef<HTMLHeadingElement>(null);
  const accountHeading = useRef<HTMLHeadingElement>(null);
  const modelsHeading = useRef<HTMLHeadingElement>(null);
  const providersHeading = useRef<HTMLHeadingElement>(null);
  const signOut = useRef<HTMLButtonElement>(null);
  const signOutCancel = useRef<HTMLButtonElement>(null);
  const metaskProvider = models.providers.find(
    (provider) => provider.id === "metask",
  );
  const metaskApiKeys = metaskProvider?.apiKeys ?? [];
  const metaskModels = metaskProvider?.models ?? [];
  const metaskCatalogState =
    metaskProvider?.catalogState ?? "needs_authentication";
  const selectedApiId = metaskProvider?.selectedApiKeyId ?? "";
  const selectedModelId = models.metaskSelection?.modelId ?? "";
  const committedProviderId = models.defaultSelection
    ? models.defaultSelection.sourceId.startsWith("metask:")
      ? "metask"
      : models.defaultSelection.sourceId
    : "";
  const selectedProviderId = requestedProviderId ?? committedProviderId;
  const selectedConnection = models.connections.find(
    (connection) => connection.id === selectedProviderId,
  );
  const committedConnection = models.connections.find(
    (connection) => connection.id === committedProviderId,
  );
  const committedDefaultModel = models.defaultSelection
    ? committedProviderId === "metask"
      ? metaskModels.find(
          (model) => model.id === models.defaultSelection?.modelId,
        )
      : committedConnection?.models.find(
          (model) => model.id === models.defaultSelection?.modelId,
        )
    : null;
  const currentDefaultLabel = models.defaultSelection
    ? `${
        committedProviderId === "metask"
          ? "Metask"
          : (committedConnection?.displayName ?? committedProviderId)
      } · ${
        committedDefaultModel?.displayName || models.defaultSelection.modelId
      }`
    : t("settings.default_selection_missing");
  const committedApi = metaskApiKeys.find((key) => key.id === selectedApiId);
  const committedModel = metaskModels.find(
    (model) => model.id === selectedModelId,
  );
  const candidateApiId = requestedApi?.selectionId ?? "";
  const candidateModelId = requestedModel?.selectionId ?? "";
  const candidateApi =
    metaskApiKeys.find((key) => key.id === candidateApiId) ?? null;
  const candidateModel =
    metaskModels.find((model) => model.id === candidateModelId) ?? null;
  const modelCatalogLoading = models.operation === "refreshing_catalog";
  const apiBusy = modelCatalogLoading;
  const modelBusy = modelCatalogLoading;
  const authenticated = account.state === "authenticated";
  const accountIdentityTitle = authenticated
    ? account.displayName || t("account.signed_in")
    : account.state === "checking"
      ? t("account.checking.title")
      : account.state === "authorizing"
        ? t("account.authorizing.title")
        : t("account.sign_in_required.title");
  const accountIdentityBody = authenticated
    ? t("account.connected")
    : account.state === "checking"
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
      models.connections.some(
        (connection) =>
          connection.enabled &&
          connection.credentialStatus === "ready" &&
          connection.state !== "disabled",
      ));
  const canChooseApi =
    modelsPersistenceReady &&
    selectedProviderId.length > 0 &&
    (providerIsMetask
      ? authenticated && !modelCatalogLoading
      : selectedConnection?.credentialStatus === "ready");
  const canChooseModel =
    modelsPersistenceReady &&
    (providerIsMetask
      ? authenticated &&
        (metaskCatalogState === "ready" || metaskCatalogState === "choosing")
      : selectedConnection?.state === "ready" &&
        selectedConnection.credentialStatus === "ready");
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
  const permissionOptions = useMemo<SelectionMenuOption[]>(
    () =>
      permissionProfiles.available.map((profile) => ({
        value: profile,
        label: t(`permission.profile.${profile}`),
        description: t(`permission.profile.${profile}.help`),
        descriptionKind: "text",
      })),
    [permissionProfiles.available, t],
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
      ...models.connections.map((connection) => ({
        value: connection.id,
        label: connection.displayName || connection.id,
        description: modelConnectionProtocolLabel(connection.protocol, t),
        descriptionKind: "text" as const,
        disabled:
          !connection.enabled ||
          connection.credentialStatus !== "ready" ||
          connection.state === "disabled",
      })),
    ],
    [account.state, metaskCatalogState, models.connections, t],
  );
  const apiOptions = useMemo<SelectionMenuOption[]>(() => {
    if (selectedProviderId === "metask") {
      return metaskApiKeys.map((key) => ({
        value: key.id,
        label: apiLabel(key, t),
        description: modelConnectionProtocolLabel(key.protocol, t),
        descriptionKind: "text",
        trailing: key.suffix ? `•••• ${key.suffix}` : undefined,
      }));
    }
    if (!selectedConnection) return [];
    return [
      {
        value: selectedConnection.id,
        label: t("settings.saved_api_key"),
        description: modelConnectionCredentialLabel(
          selectedConnection.credentialStatus,
          t,
        ),
        descriptionKind: "text",
      },
    ];
  }, [metaskApiKeys, selectedConnection, selectedProviderId, t]);
  const modelOptions = useMemo<SelectionMenuOption[]>(() => {
    const options =
      selectedProviderId === "metask"
        ? metaskModels.map((model) => ({
            value: model.id,
            label: modelLabel(model, t),
          }))
        : (selectedConnection?.models ?? []).map((model) => ({
            value: model.id,
            label: model.displayName || model.id,
            disabled: !model.ready,
          }));
    if (
      selectedProviderId === "metask" &&
      requestedModel &&
      !options.some((option) => option.value === requestedModel.selectionId)
    ) {
      options.unshift({
        value: requestedModel.selectionId,
        label: requestedModel.label,
      });
    }
    return options;
  }, [metaskModels, requestedModel, selectedConnection, selectedProviderId, t]);
  const modelConnectionProtocolOptions = useMemo<SelectionMenuOption[]>(
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
        label: modelConnectionProtocolLabel(protocol, t),
      })),
    [t],
  );
  const displayedApiId = providerIsMetask
    ? selectedApiId
    : (selectedConnection?.id ?? "");
  const displayedModelId = providerIsMetask
    ? committedProviderId === "metask"
      ? selectedModelId
      : ""
    : selectedConnection &&
        models.defaultSelection?.sourceId === selectedConnection.id
      ? models.defaultSelection.modelId
      : "";
  const apiHasAlternative = apiOptions.some(
    (option) => option.value !== displayedApiId,
  );
  const modelHasAlternative = modelOptions.some(
    (option) => option.value !== displayedModelId,
  );
  const apiIsOnlyOption =
    displayedApiId.length > 0 && apiOptions.length === 1 && !apiHasAlternative;
  const modelIsOnlyOption =
    displayedModelId.length > 0 &&
    modelOptions.length === 1 &&
    !modelHasAlternative;
  const customModelNeedingTest =
    !providerIsMetask &&
    selectedConnection &&
    !selectedConnection.models.some((model) => model.ready)
      ? selectedConnection.models[0]
      : undefined;
  const modelPlaceholder =
    providerIsMetask && modelCatalogLoading
      ? t("settings.model_loading")
      : providerIsMetask &&
          metaskCatalogState === "choosing" &&
          candidateApiId.length === 0
        ? t("settings.model_waiting_api")
        : t("account.choose_model");
  const committedApiName = committedApi
    ? apiLabel(committedApi, t)
    : t("account.api_fallback");
  const committedModelName =
    (committedModel ? modelLabel(committedModel, t) : "") ||
    selectedModelId ||
    t("account.model_fallback");
  const candidateApiName =
    (candidateApi ? apiLabel(candidateApi, t) : "") ||
    (requestedApi?.selectionId === candidateApiId
      ? requestedApi.label
      : candidateApiId) ||
    t("account.api_fallback");
  const candidateModelName =
    (candidateModel ? modelLabel(candidateModel, t) : "") ||
    (requestedModel?.selectionId === candidateModelId
      ? requestedModel.label
      : candidateModelId) ||
    t("account.model_fallback");
  const apiHasPendingChange =
    candidateApiId.length > 0 && candidateApiId !== selectedApiId;
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
            detail: t("settings.switch.current_preserved", {
              api: committedApiName,
              model: committedModelName,
            }),
          };
        }
        if (apiHasPendingChange) {
          return {
            title: t("settings.switch.preparing_api", {
              api: candidateApiName,
            }),
            detail: t("settings.switch.current_preserved", {
              api: committedApiName,
              model: committedModelName,
            }),
          };
        }
        return {
          title: t("account.operation.loading_keys"),
          detail: t("settings.switch.refreshing"),
        };
      case "choosing":
        return candidateApiId
          ? {
              title: t("settings.switch.choose_model", {
                api: candidateApiName,
              }),
              detail: t("settings.switch.choose_model_help"),
            }
          : {
              title: t("account.operation.selecting_key"),
              detail: t("settings.switch.choose_api_help"),
            };
      case "unavailable":
      case "ready":
      case "failed":
        return null;
    }
  })();

  useEffect(() => {
    if (focusTarget === "providers" && modelConnectionSettingsAvailable) {
      setActiveSection("providers");
    } else if (focusTarget === "models") {
      setActiveSection("models");
    } else if (focusTarget === "account") {
      setActiveSection("account");
    }
  }, [focusTarget, modelConnectionSettingsAvailable]);

  useEffect(() => {
    if (
      (activeSection === "permissions" && !permissionProfiles.enabled) ||
      (activeSection === "providers" && !modelConnectionSettingsAvailable)
    ) {
      setActiveSection("general");
      return;
    }
    const frame = window.requestAnimationFrame(() => {
      if (activeSection === "general" && focusTarget === "title") {
        generalHeading.current?.focus();
      } else if (activeSection === "permissions") {
        permissionsHeading.current?.focus();
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
    modelConnectionSettingsAvailable,
    permissionProfiles.enabled,
    providersPage,
  ]);

  useEffect(() => {
    content.current?.scrollTo?.({ top: 0, behavior: "auto" });
  }, [activeSection, providersPage]);

  useEffect(() => {
    if (activeSection === "providers") return;
    setProvidersPage("list");
    setModelConnectionDraft(null);
  }, [activeSection]);

  useEffect(() => {
    if (!confirmSignOut) return;
    const frame = window.requestAnimationFrame(() =>
      signOutCancel.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [confirmSignOut]);

  useEffect(() => {
    if (modelConnectionCapabilities.secretCapture) return;
    setModelConnectionDraft(null);
    setCreatingModelConnection(false);
  }, [modelConnectionCapabilities.secretCapture]);

  useEffect(() => {
    setModelConnectionEdit((current) => {
      if (!current) return null;
      const connection = models.connections.find(
        (candidate) => candidate.id === current.connectionId,
      );
      return connection?.connectionRevision ===
        current.expectedConnectionRevision
        ? current
        : null;
    });
    setModelConnectionRemoval((current) => {
      if (!current) return null;
      const connection = models.connections.find(
        (candidate) => candidate.id === current.connectionId,
      );
      return connection?.connectionRevision ===
        current.expectedConnectionRevision
        ? current
        : null;
    });
  }, [models.connections]);

  useEffect(() => {
    if (
      models.errorCode !== "none" ||
      account.state !== "authenticated" ||
      (metaskCatalogState === "ready" && !disabled)
    ) {
      setRequestedApi(null);
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

  async function submitModelConnection() {
    if (!modelConnectionDraft || creatingModelConnection) return;
    const baseUrl = modelConnectionDraft.baseUrl.trim();
    const displayName = modelConnectionDraft.displayName.trim();
    if (!displayName || !baseUrl) return;
    const input = {
      displayName,
      protocol: modelConnectionDraft.protocol,
      normalizedBaseUrl: modelConnectionEndpointFromBaseUrl(
        modelConnectionDraft.protocol,
        baseUrl,
      ),
    };
    setCreatingModelConnection(true);
    try {
      if (await onCreateModelConnection(input)) {
        setModelConnectionDraft(null);
        setProvidersPage("list");
      }
    } finally {
      setCreatingModelConnection(false);
    }
  }

  async function addCustomModel() {
    const modelId = customModelId.trim();
    if (!selectedConnection || !modelId || addingCustomModel) return;
    setAddingCustomModel(true);
    try {
      if (
        await onAddCustomModel(
          selectedConnection.id,
          selectedConnection.connectionRevision,
          selectedConnection.catalogGeneration,
          modelId,
        )
      ) {
        setCustomModelId("");
      }
    } finally {
      setAddingCustomModel(false);
    }
  }

  async function submitModelConnectionEdit() {
    if (!modelConnectionEdit || mutatingModelConnection) return;
    const baseUrl = modelConnectionEdit.baseUrl.trim();
    const displayName = modelConnectionEdit.displayName.trim();
    if (!displayName || !baseUrl) return;
    const input = {
      connectionId: modelConnectionEdit.connectionId,
      expectedConnectionRevision:
        modelConnectionEdit.expectedConnectionRevision,
      displayName,
      protocol: modelConnectionEdit.protocol,
      normalizedBaseUrl: modelConnectionEndpointFromBaseUrl(
        modelConnectionEdit.protocol,
        baseUrl,
      ),
    };
    setMutatingModelConnection(true);
    try {
      if (await onUpdateModelConnection(input)) setModelConnectionEdit(null);
    } finally {
      setMutatingModelConnection(false);
    }
  }

  async function removeModelConnection() {
    if (!modelConnectionRemoval || mutatingModelConnection) return;
    setMutatingModelConnection(true);
    try {
      if (
        await onRemoveModelConnection(
          modelConnectionRemoval.connectionId,
          modelConnectionRemoval.expectedConnectionRevision,
        )
      )
        setModelConnectionRemoval(null);
    } finally {
      setMutatingModelConnection(false);
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
        if (activeSection === "providers" && providersPage === "add") {
          setModelConnectionDraft(null);
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
          {permissionProfiles.enabled && (
            <a
              className="focus-ring"
              href="#settings-permissions"
              aria-current={
                activeSection === "permissions" ? "location" : undefined
              }
              onClick={(event) => {
                event.preventDefault();
                setActiveSection("permissions");
              }}
            >
              <span className="settings-nav-icon" aria-hidden="true">
                <Icon name="shield" />
              </span>
              <span>{t("settings.permissions")}</span>
            </a>
          )}
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
            hidden={!modelConnectionSettingsAvailable}
            onClick={(event) => {
              event.preventDefault();
              setModelConnectionDraft(null);
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
                </div>
              </div>
            </section>
          )}

          {activeSection === "permissions" && permissionProfiles.enabled && (
            <section id="settings-permissions" className="settings-section">
              <div className="settings-section-heading">
                <h2 ref={permissionsHeading} tabIndex={-1}>
                  {t("settings.permissions")}
                </h2>
              </div>
              <div className="settings-group">
                <h3 className="settings-group-label">
                  {t("settings.permission_defaults")}
                </h3>
                <div className="permission-policy-card">
                  <div className="permission-policy-copy">
                    <strong>
                      {t(
                        `permission.profile.${permissionProfiles.defaultProfile}`,
                      )}
                    </strong>
                    <p>{t("permission.default.help")}</p>
                  </div>
                  <SelectionMenu
                    triggerId="settings-permission-profile"
                    value={permissionProfiles.defaultProfile}
                    options={permissionOptions}
                    placeholder={t("permission.default.label")}
                    ariaLabel={t("permission.default.label")}
                    helper={t("permission.menu_help")}
                    disabled={disabled || permissionProfiles.busy}
                    busy={permissionProfiles.busy}
                    valueLayout="detailed"
                    triggerClassName="permission-profile-trigger"
                    contentClassName="permission-profile-menu"
                    onValueChange={(value) =>
                      onSetDefaultPermissionProfile(value as PermissionProfile)
                    }
                  />
                  <p className="permission-policy-boundary">
                    <Icon name="info" />
                    {t("permission.full_access.boundary")}
                  </p>
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
                    {[...(account.displayName || "M")][0]?.toLocaleUpperCase()}
                  </span>
                  <div className="settings-identity-copy">
                    <strong title={account.displayName}>
                      {accountIdentityTitle}
                    </strong>
                    <span>{accountIdentityBody}</span>
                  </div>
                  {account.canCancel ? (
                    <Button
                      variant="secondary"
                      size="sm"
                      disabled={cancelDisabled}
                      onClick={onCancel}
                    >
                      {t("common.cancel")}
                    </Button>
                  ) : !authenticated ? (
                    <Button
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
                              apis: metaskApiKeys.length,
                              models: metaskModels.length,
                            })}
                          </span>
                          <button
                            className="settings-refresh-button focus-ring"
                            disabled={
                              disabled ||
                              accountDisabled ||
                              !authenticated ||
                              apiBusy
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
                          setRequestedApi(null);
                          setRequestedModel(null);
                          setCustomModelId("");
                        }}
                      />
                    </div>
                  </div>

                  <div className="settings-field settings-field-api">
                    <span className="settings-field-step" aria-hidden="true">
                      02
                    </span>
                    <div className="settings-field-copy">
                      <label htmlFor="settings-api">
                        {t("settings.api_key")}
                      </label>
                      <p>
                        {t(
                          providerIsMetask
                            ? apiIsOnlyOption
                              ? "settings.only_api_help"
                              : "settings.api_key_help"
                            : "settings.provider_api_key_help",
                        )}
                      </p>
                    </div>
                    <div className="settings-control-stack">
                      <SelectionMenu
                        triggerId="settings-api"
                        value={
                          providerIsMetask
                            ? candidateApiId || displayedApiId
                            : displayedApiId
                        }
                        options={apiOptions}
                        placeholder={t("account.choose_key")}
                        ariaLabel={t("settings.api_key")}
                        helper={t(
                          providerIsMetask
                            ? "settings.api_menu_help"
                            : "settings.provider_api_menu_help",
                        )}
                        actionLabel={t(
                          apiIsOnlyOption
                            ? "settings.view_selection"
                            : displayedApiId
                              ? "settings.change_selection"
                              : "settings.choose_selection",
                        )}
                        disabled={
                          disabled ||
                          (providerIsMetask && accountDisabled) ||
                          !canChooseApi ||
                          apiOptions.length === 0
                        }
                        busy={providerIsMetask && apiBusy}
                        valueLayout="detailed"
                        leading={<Icon name="account" />}
                        triggerClassName="settings-control settings-control-detailed"
                        contentClassName="settings-selection-menu"
                        onValueChange={(value) => {
                          if (!providerIsMetask) return;
                          const api = metaskApiKeys.find(
                            (candidate) => candidate.id === value,
                          );
                          if (!api) return;
                          setRequestedApi({
                            selectionId: value,
                            label: apiLabel(api, t),
                          });
                          setRequestedModel(null);
                          onSelectApiKey(value);
                        }}
                      />
                      {providerIsMetask && apiHasPendingChange && (
                        <span className="settings-pending-label">
                          <span aria-hidden="true" />
                          {t("settings.switch.pending_label")}
                        </span>
                      )}
                    </div>
                  </div>

                  <div className="settings-field">
                    <span className="settings-field-step" aria-hidden="true">
                      03
                    </span>
                    <div className="settings-field-copy">
                      <label htmlFor="settings-model">
                        {t("settings.default_model")}
                      </label>
                      <p>
                        {!providerIsMetask &&
                        selectedConnection?.models.length === 0
                          ? t("settings.custom_model_add_help")
                          : providerIsMetask &&
                              modelCatalogLoading &&
                              (candidateApi || committedApi)
                            ? t("settings.loading_models_for", {
                                api:
                                  candidateApi?.name ||
                                  committedApi?.name ||
                                  t("account.api_fallback"),
                              })
                            : t(
                                modelIsOnlyOption
                                  ? "settings.only_model_help"
                                  : "settings.default_model_help",
                              )}
                      </p>
                    </div>
                    <div className="settings-control-stack">
                      {!providerIsMetask &&
                      selectedConnection?.models.length === 0 ? (
                        <form
                          className="settings-custom-model-add"
                          onSubmit={(event) => {
                            event.preventDefault();
                            void addCustomModel();
                          }}
                        >
                          <input
                            id="settings-model"
                            className="settings-model-connection-input settings-model-connection-input-mono focus-ring"
                            autoComplete="off"
                            maxLength={256}
                            value={customModelId}
                            placeholder={t(
                              "settings.model_connection_model_id_placeholder",
                            )}
                            disabled={
                              disabled || executionDisabled || addingCustomModel
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
                      ) : (
                        <>
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
                              if (!providerIsMetask && selectedConnection) {
                                onSelectModelConnection(
                                  selectedConnection.id,
                                  selectedConnection.connectionRevision,
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
                          {customModelNeedingTest && selectedConnection && (
                            <div className="settings-custom-model-test">
                              <span>
                                <code>{customModelNeedingTest.id}</code>
                                <small>
                                  {modelConnectionTestStatusLabel(
                                    customModelNeedingTest.testStatus,
                                    t,
                                  )}
                                </small>
                              </span>
                              <Button
                                variant="secondary"
                                size="sm"
                                disabled={
                                  disabled ||
                                  executionDisabled ||
                                  customModelNeedingTest.testStatus ===
                                    "testing"
                                }
                                onClick={() =>
                                  onTestModelConnection(
                                    selectedConnection.id,
                                    selectedConnection.connectionRevision,
                                    customModelNeedingTest.id,
                                    selectedConnection.sourceGeneration,
                                    selectedConnection.catalogGeneration,
                                  )
                                }
                              >
                                {customModelNeedingTest.testStatus === "testing"
                                  ? t("settings.model_connection_testing")
                                  : t("settings.custom_model_test")}
                              </Button>
                            </div>
                          )}
                        </>
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

                {models.errorCode !== "none" &&
                  models.errorCode !== "authorization_unavailable" && (
                    <div className="settings-error" role="alert">
                      <Icon name="warning" />
                      <span className="settings-error-copy">
                        <strong>{t("settings.models_error")}</strong>
                        <span>{t("settings.models_error_help")}</span>
                      </span>
                    </div>
                  )}
              </div>
            </section>
          )}

          {activeSection === "providers" &&
            modelConnectionSettingsAvailable && (
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
                    {providersPage === "add"
                      ? t("settings.provider_add_title")
                      : t("settings.providers")}
                  </h2>
                </div>
                <div className="settings-group">
                  <h3 className="settings-group-label">
                    {providersPage === "add"
                      ? t("settings.provider_details")
                      : t("settings.providers_saved")}
                  </h3>
                  <div className="settings-model-connections">
                    <div className="settings-execution-header">
                      {providersPage === "list" ? (
                        <p>{t("settings.providers_help")}</p>
                      ) : (
                        <button
                          type="button"
                          className="settings-subpage-back text-button focus-ring"
                          onClick={() => {
                            setModelConnectionDraft(null);
                            setProvidersPage("list");
                          }}
                        >
                          <Icon name="arrow-left" />
                          {t("settings.back_to_providers")}
                        </button>
                      )}
                      {providersPage === "list" &&
                        modelConnectionCapabilities.secretCapture && (
                          <Button
                            variant="secondary"
                            size="sm"
                            disabled={
                              disabled ||
                              executionDisabled ||
                              creatingModelConnection
                            }
                            onClick={() => {
                              setModelConnectionDraft(
                                newModelConnectionDraft(),
                              );
                              setProvidersPage("add");
                            }}
                          >
                            {t("settings.provider_add")}
                          </Button>
                        )}
                    </div>
                    {modelConnectionDraft && (
                      <form
                        id="settings-model-connection-create"
                        className="settings-model-connection-create"
                        onSubmit={(event) => {
                          event.preventDefault();
                          void submitModelConnection();
                        }}
                      >
                        <div
                          className="settings-model-connection-route"
                          aria-hidden="true"
                        >
                          <span>
                            {t("settings.model_connection_route.protocol")}
                          </span>
                          <span>
                            {t("settings.model_connection_route.endpoint")}
                          </span>
                          <span>
                            {t("settings.model_connection_route.api_key")}
                          </span>
                        </div>
                        <label className="settings-model-connection-create-field">
                          <span>{t("settings.model_connection_name")}</span>
                          <input
                            className="settings-model-connection-input focus-ring"
                            autoComplete="off"
                            maxLength={256}
                            value={modelConnectionDraft.displayName}
                            placeholder={t(
                              "settings.model_connection_name_placeholder",
                            )}
                            disabled={
                              disabled ||
                              executionDisabled ||
                              creatingModelConnection
                            }
                            onChange={(event) =>
                              setModelConnectionDraft((current) =>
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
                        <div className="settings-model-connection-create-field">
                          <span>{t("settings.model_connection_protocol")}</span>
                          <SelectionMenu
                            value={modelConnectionDraft.protocol}
                            options={modelConnectionProtocolOptions}
                            placeholder={t(
                              "settings.model_connection_protocol",
                            )}
                            ariaLabel={t("settings.model_connection_protocol")}
                            disabled={
                              disabled ||
                              executionDisabled ||
                              creatingModelConnection
                            }
                            triggerClassName="settings-control"
                            onValueChange={(value) => {
                              const protocol = value as Protocol;
                              setModelConnectionDraft((current) =>
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
                        <label className="settings-model-connection-create-field settings-model-connection-create-field-wide">
                          <span>{t("settings.model_connection_endpoint")}</span>
                          <input
                            className="settings-model-connection-input focus-ring"
                            autoComplete="url"
                            inputMode="url"
                            maxLength={2048}
                            value={modelConnectionDraft.baseUrl}
                            placeholder={
                              modelConnectionBaseUrlExamples[
                                modelConnectionDraft.protocol
                              ]
                            }
                            disabled={
                              disabled ||
                              executionDisabled ||
                              creatingModelConnection
                            }
                            onChange={(event) =>
                              setModelConnectionDraft((current) =>
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
                        <div className="settings-model-connection-create-field settings-model-connection-create-field-wide">
                          <span>{t("settings.api_key")}</span>
                          <div className="settings-secure-credential-handoff">
                            <Icon name="shield" />
                            <span>
                              <strong>
                                {t("settings.provider_secure_api_key_title")}
                              </strong>
                              <small>
                                {t("settings.provider_secure_api_key_help")}
                              </small>
                            </span>
                          </div>
                        </div>
                        <div className="settings-model-connection-create-footer">
                          <p>
                            {t("settings.provider_models_configured_elsewhere")}
                          </p>
                          <Button
                            type="submit"
                            size="sm"
                            disabled={
                              disabled ||
                              executionDisabled ||
                              creatingModelConnection ||
                              !modelConnectionDraft.displayName.trim() ||
                              !modelConnectionDraft.baseUrl.trim()
                            }
                          >
                            {creatingModelConnection
                              ? t("settings.model_connection_adding")
                              : t("settings.provider_set_key_and_save")}
                          </Button>
                        </div>
                      </form>
                    )}
                    {providersPage === "list" &&
                      (!modelConnectionCapabilities.management ? (
                        <p className="settings-model-connections-empty">
                          {t("settings.providers_unavailable")}
                        </p>
                      ) : models.connections.length === 0 ? (
                        <p className="settings-model-connections-empty">
                          {t("settings.providers_empty")}
                        </p>
                      ) : (
                        <div className="settings-model-connection-list">
                          {models.connections.map((connection) => (
                            <div
                              className="settings-model-connection"
                              key={connection.id}
                            >
                              <div className="settings-model-connection-copy">
                                <strong>
                                  {connection.displayName || connection.id}
                                </strong>
                                <span>
                                  {modelConnectionProtocolLabel(
                                    connection.protocol,
                                    t,
                                  )}
                                  <span aria-hidden="true"> · </span>
                                  {modelConnectionBaseUrlFromEndpoint(
                                    connection.protocol,
                                    connection.normalizedBaseUrl,
                                  )}
                                </span>
                                <span>
                                  {modelConnectionCredentialLabel(
                                    connection.credentialStatus,
                                    t,
                                  )}
                                  <span aria-hidden="true"> · </span>
                                  {modelConnectionStateLabel(
                                    connection.state,
                                    t,
                                  )}
                                  <span aria-hidden="true"> · </span>
                                  {modelConnectionTestStatusLabel(
                                    connection.testStatus,
                                    t,
                                  )}
                                </span>
                              </div>
                              <div className="settings-model-connection-actions">
                                <button
                                  className="text-button focus-ring"
                                  disabled={
                                    disabled ||
                                    executionDisabled ||
                                    mutatingModelConnection ||
                                    !modelConnectionCapabilities.secretCapture
                                  }
                                  onClick={() =>
                                    void onReplaceModelConnectionCredential(
                                      connection.id,
                                      connection.connectionRevision,
                                    )
                                  }
                                >
                                  {t(
                                    "settings.model_connection_replace_credential",
                                  )}
                                </button>
                                <button
                                  className="text-button focus-ring"
                                  disabled={
                                    disabled ||
                                    executionDisabled ||
                                    !modelConnectionCapabilities.connectionTest ||
                                    connection.testStatus === "testing" ||
                                    connection.credentialStatus !== "ready" ||
                                    connection.selectedModel.length === 0
                                  }
                                  onClick={() =>
                                    onTestModelConnection(
                                      connection.id,
                                      connection.connectionRevision,
                                      connection.selectedModel,
                                      connection.sourceGeneration,
                                      connection.catalogGeneration,
                                    )
                                  }
                                >
                                  {connection.testStatus === "testing"
                                    ? t("settings.model_connection_testing")
                                    : t("settings.model_connection_test")}
                                </button>
                                <button
                                  className="text-button focus-ring"
                                  disabled={
                                    disabled ||
                                    executionDisabled ||
                                    mutatingModelConnection
                                  }
                                  onClick={() => {
                                    setModelConnectionRemoval(null);
                                    setModelConnectionEdit({
                                      connectionId: connection.id,
                                      expectedConnectionRevision:
                                        connection.connectionRevision,
                                      displayName: connection.displayName,
                                      protocol: connection.protocol,
                                      baseUrl:
                                        modelConnectionBaseUrlFromEndpoint(
                                          connection.protocol,
                                          connection.normalizedBaseUrl,
                                        ),
                                    });
                                  }}
                                >
                                  {t("common.edit")}
                                </button>
                                <button
                                  className="text-button settings-model-connection-remove focus-ring"
                                  disabled={
                                    disabled ||
                                    executionDisabled ||
                                    mutatingModelConnection
                                  }
                                  onClick={() => {
                                    setModelConnectionEdit(null);
                                    setModelConnectionRemoval({
                                      connectionId: connection.id,
                                      expectedConnectionRevision:
                                        connection.connectionRevision,
                                    });
                                  }}
                                >
                                  {t("common.remove")}
                                </button>
                              </div>
                              {modelConnectionEdit?.connectionId ===
                                connection.id && (
                                <form
                                  className="settings-model-connection-edit"
                                  onSubmit={(event) => {
                                    event.preventDefault();
                                    void submitModelConnectionEdit();
                                  }}
                                >
                                  <label className="settings-model-connection-create-field">
                                    <span>
                                      {t("settings.model_connection_name")}
                                    </span>
                                    <input
                                      className="settings-model-connection-input focus-ring"
                                      autoComplete="off"
                                      maxLength={256}
                                      value={modelConnectionEdit.displayName}
                                      disabled={
                                        disabled ||
                                        executionDisabled ||
                                        mutatingModelConnection
                                      }
                                      onChange={(event) =>
                                        setModelConnectionEdit((current) =>
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
                                  <div className="settings-model-connection-create-field">
                                    <span>
                                      {t("settings.model_connection_protocol")}
                                    </span>
                                    <SelectionMenu
                                      value={modelConnectionEdit.protocol}
                                      options={modelConnectionProtocolOptions}
                                      placeholder={t(
                                        "settings.model_connection_protocol",
                                      )}
                                      ariaLabel={t(
                                        "settings.model_connection_protocol",
                                      )}
                                      disabled={
                                        disabled ||
                                        executionDisabled ||
                                        mutatingModelConnection
                                      }
                                      triggerClassName="settings-control"
                                      onValueChange={(value) => {
                                        const protocol = value as Protocol;
                                        setModelConnectionEdit((current) =>
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
                                  <label className="settings-model-connection-create-field settings-model-connection-edit-endpoint">
                                    <span>
                                      {t("settings.model_connection_endpoint")}
                                    </span>
                                    <input
                                      className="settings-model-connection-input focus-ring"
                                      autoComplete="url"
                                      inputMode="url"
                                      maxLength={2048}
                                      value={modelConnectionEdit.baseUrl}
                                      disabled={
                                        disabled ||
                                        executionDisabled ||
                                        mutatingModelConnection
                                      }
                                      onChange={(event) =>
                                        setModelConnectionEdit((current) =>
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
                                  <div className="settings-model-connection-edit-actions">
                                    <p>
                                      {t("settings.model_connection_edit_help")}
                                    </p>
                                    <Button
                                      type="button"
                                      variant="ghost"
                                      size="sm"
                                      disabled={mutatingModelConnection}
                                      onClick={() =>
                                        setModelConnectionEdit(null)
                                      }
                                    >
                                      {t("common.cancel")}
                                    </Button>
                                    <Button
                                      type="submit"
                                      size="sm"
                                      disabled={
                                        disabled ||
                                        executionDisabled ||
                                        mutatingModelConnection ||
                                        !modelConnectionEdit.displayName.trim() ||
                                        !modelConnectionEdit.baseUrl.trim()
                                      }
                                    >
                                      {mutatingModelConnection
                                        ? t("common.saving")
                                        : t("common.save")}
                                    </Button>
                                  </div>
                                </form>
                              )}
                              {modelConnectionRemoval?.connectionId ===
                                connection.id && (
                                <div
                                  className="settings-model-connection-confirm-remove"
                                  role="group"
                                  aria-label={t(
                                    "settings.model_connection_remove_confirm",
                                  )}
                                >
                                  <p>
                                    {t(
                                      "settings.model_connection_remove_confirm",
                                    )}
                                  </p>
                                  <Button
                                    variant="ghost"
                                    size="sm"
                                    disabled={mutatingModelConnection}
                                    onClick={() =>
                                      setModelConnectionRemoval(null)
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
                                      mutatingModelConnection
                                    }
                                    onClick={() => void removeModelConnection()}
                                  >
                                    {mutatingModelConnection
                                      ? t("settings.model_connection_removing")
                                      : t("common.remove")}
                                  </Button>
                                </div>
                              )}
                            </div>
                          ))}
                        </div>
                      ))}
                    {providersPage === "list" &&
                      modelConnectionCapabilities.management &&
                      !modelConnectionCapabilities.secretCapture && (
                        <p className="settings-model-connections-empty">
                          {t("settings.model_connection_capture_unavailable")}
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
