import { useEffect, useMemo, useRef, useState } from "react";

import type {
  AccountView,
  ModelsView,
  Protocol,
  PermissionProfile,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { useI18n, type Locale } from "../../i18n/context.ts";
import { accountErrorText } from "../../i18n/account-error.ts";

export type SettingsFocusTarget = "title" | "account" | "model_connections";
type SettingsSection =
  "general" | "permissions" | "account" | "models" | "model_connections";
type RequestedSelection = {
  selectionId: string;
  label: string;
};
type ModelConnectionDraft = {
  displayName: string;
  protocol: Protocol;
  normalizedBaseUrl: string;
  modelId: string;
};
type ModelConnectionEditDraft = Omit<ModelConnectionDraft, "modelId"> & {
  connectionId: string;
  expectedConnectionRevision: string;
};
type ModelConnectionRemoval = {
  connectionId: string;
  expectedConnectionRevision: string;
};

const modelConnectionEndpointDefaults: Record<Protocol, string> = {
  openai_responses: "https://api.openai.com/v1/responses",
  anthropic_messages: "https://api.anthropic.com/v1/messages",
  openai_chat_completions: "https://api.openai.com/v1/chat/completions",
  gemini_native: "https://generativelanguage.googleapis.com",
};

function newModelConnectionDraft(): ModelConnectionDraft {
  return {
    displayName: "",
    protocol: "openai_chat_completions",
    normalizedBaseUrl: modelConnectionEndpointDefaults.openai_chat_completions,
    modelId: "",
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
  disabled,
  accountDisabled,
  executionDisabled,
  cancelDisabled,
  onBack,
  onRefresh,
  onCancel,
  onSelectApiKey,
  onSelectModel,
  onActivateMetask,
  onCreateModelConnection,
  onUpdateModelConnection,
  onRemoveModelConnection,
  onTestModelConnection,
  onSelectModelConnection,
  onBeginLogin,
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
  disabled: boolean;
  accountDisabled: boolean;
  executionDisabled: boolean;
  cancelDisabled: boolean;
  onBack: () => void;
  onRefresh: () => void;
  onCancel: () => void;
  onSelectApiKey: (id: string) => void;
  onSelectModel: (id: string) => void;
  onActivateMetask: () => void;
  onCreateModelConnection: (input: ModelConnectionDraft) => Promise<boolean>;
  onUpdateModelConnection: (
    input: ModelConnectionEditDraft,
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
    useState<SettingsSection>("general");
  const [requestedApi, setRequestedApi] = useState<RequestedSelection | null>(
    null,
  );
  const [requestedModel, setRequestedModel] =
    useState<RequestedSelection | null>(null);
  const [modelConnectionDraft, setModelConnectionDraft] =
    useState<ModelConnectionDraft | null>(null);
  const [creatingModelConnection, setCreatingModelConnection] = useState(false);
  const [modelConnectionEdit, setModelConnectionEdit] =
    useState<ModelConnectionEditDraft | null>(null);
  const [modelConnectionRemoval, setModelConnectionRemoval] =
    useState<ModelConnectionRemoval | null>(null);
  const [mutatingModelConnection, setMutatingModelConnection] = useState(false);
  const content = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const accountSection = useRef<HTMLElement>(null);
  const modelsSection = useRef<HTMLElement>(null);
  const permissionsSection = useRef<HTMLElement>(null);
  const accountHeading = useRef<HTMLHeadingElement>(null);
  const modelsHeading = useRef<HTMLHeadingElement>(null);
  const modelConnectionsSection = useRef<HTMLDivElement>(null);
  const modelConnectionsHeading = useRef<HTMLHeadingElement>(null);
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
  const customDefaultSelected = models.connections.some(
    (connection) => connection.id === models.defaultSelection?.sourceId,
  );
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
  const preferenceRecovery = models.persistenceHealth === "recovery_required";
  const canChooseApi =
    authenticated && !preferenceRecovery && !modelCatalogLoading;
  const canChooseModel =
    authenticated &&
    !preferenceRecovery &&
    (metaskCatalogState === "ready" || metaskCatalogState === "choosing");
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
  const apiOptions = useMemo<SelectionMenuOption[]>(
    () =>
      metaskApiKeys.map((key) => ({
        value: key.id,
        label: apiLabel(key, t),
        description: modelConnectionProtocolLabel(key.protocol, t),
        descriptionKind: "text",
        trailing: key.suffix ? `•••• ${key.suffix}` : undefined,
      })),
    [metaskApiKeys, t],
  );
  const modelOptions = useMemo<SelectionMenuOption[]>(() => {
    const options = metaskModels.map((model) => ({
      value: model.id,
      label: modelLabel(model, t),
    }));
    if (
      requestedModel &&
      !options.some((option) => option.value === requestedModel.selectionId)
    ) {
      options.unshift({
        value: requestedModel.selectionId,
        label: requestedModel.label,
      });
    }
    return options;
  }, [metaskModels, requestedModel, t]);
  const modelConnectionProtocolOptions = useMemo<SelectionMenuOption[]>(
    () =>
      (["openai_chat_completions", "gemini_native"] as const).map(
        (protocol) => ({
          value: protocol,
          label: modelConnectionProtocolLabel(protocol, t),
        }),
      ),
    [t],
  );
  const apiHasAlternative = apiOptions.some(
    (option) => option.value !== selectedApiId,
  );
  const modelHasAlternative = modelOptions.some(
    (option) => option.value !== selectedModelId,
  );
  const apiIsOnlyOption =
    selectedApiId.length > 0 && apiOptions.length === 1 && !apiHasAlternative;
  const modelIsOnlyOption =
    selectedModelId.length > 0 &&
    modelOptions.length === 1 &&
    !modelHasAlternative;
  const modelPlaceholder = modelCatalogLoading
    ? t("settings.model_loading")
    : metaskCatalogState === "choosing" && candidateApiId.length === 0
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
    const frame = window.requestAnimationFrame(() => {
      if (focusTarget === "account") {
        setActiveSection("account");
        if (content.current && accountSection.current) {
          content.current.scrollTo({
            top: contentTop(accountSection.current) - 18,
            behavior: "auto",
          });
        }
        accountHeading.current?.focus();
        return;
      }
      if (
        focusTarget === "model_connections" &&
        modelConnectionSettingsAvailable
      ) {
        setActiveSection("model_connections");
        if (content.current && modelConnectionsSection.current) {
          content.current.scrollTo({
            top: contentTop(modelConnectionsSection.current) - 18,
            behavior: "auto",
          });
        }
        modelConnectionsHeading.current?.focus();
        return;
      }
      title.current?.focus();
    });
    return () => window.cancelAnimationFrame(frame);
  }, [focusTarget, modelConnectionSettingsAvailable]);

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

  function closeSignOutConfirmation() {
    setConfirmSignOut(false);
    window.requestAnimationFrame(() => signOut.current?.focus());
  }

  async function submitModelConnection() {
    if (!modelConnectionDraft || creatingModelConnection) return;
    const input = {
      ...modelConnectionDraft,
      displayName: modelConnectionDraft.displayName.trim(),
      normalizedBaseUrl: modelConnectionDraft.normalizedBaseUrl.trim(),
      modelId: modelConnectionDraft.modelId.trim(),
    };
    if (!input.displayName || !input.normalizedBaseUrl || !input.modelId)
      return;
    setCreatingModelConnection(true);
    try {
      if (await onCreateModelConnection(input)) setModelConnectionDraft(null);
    } finally {
      setCreatingModelConnection(false);
    }
  }

  async function submitModelConnectionEdit() {
    if (!modelConnectionEdit || mutatingModelConnection) return;
    const input = {
      ...modelConnectionEdit,
      displayName: modelConnectionEdit.displayName.trim(),
      normalizedBaseUrl: modelConnectionEdit.normalizedBaseUrl.trim(),
    };
    if (!input.displayName || !input.normalizedBaseUrl) return;
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

  function contentTop(element: HTMLElement | null) {
    if (!content.current || !element) return 0;
    return (
      element.getBoundingClientRect().top -
      content.current.getBoundingClientRect().top +
      content.current.scrollTop
    );
  }

  function updateActiveSection() {
    if (
      !content.current ||
      !accountSection.current ||
      !modelsSection.current ||
      !modelConnectionsSection.current ||
      (permissionProfiles.enabled && !permissionsSection.current)
    )
      return;
    const readingLine =
      content.current.scrollTop +
      Math.min(160, content.current.clientHeight * 0.3);
    if (
      modelConnectionSettingsAvailable &&
      contentTop(modelConnectionsSection.current) <= readingLine
    )
      setActiveSection("model_connections");
    else if (contentTop(modelsSection.current) <= readingLine)
      setActiveSection("models");
    else if (contentTop(accountSection.current) <= readingLine)
      setActiveSection("account");
    else if (
      permissionProfiles.enabled &&
      contentTop(permissionsSection.current) <= readingLine
    )
      setActiveSection("permissions");
    else setActiveSection("general");
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
        <div className="settings-header-copy">
          <h1 id="settings-page-title" ref={title} tabIndex={-1}>
            {t("settings.title")}
          </h1>
          <p>{t("settings.intro")}</p>
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
              content.current?.scrollTo({ top: 0, behavior: "smooth" });
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
                if (!content.current || !permissionsSection.current) return;
                content.current.scrollTo({
                  top: contentTop(permissionsSection.current) - 18,
                  behavior: "smooth",
                });
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
              if (!content.current || !accountHeading.current) return;
              content.current.scrollTo({
                top: contentTop(accountHeading.current) - 18,
                behavior: "smooth",
              });
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
              if (!content.current || !modelsHeading.current) return;
              content.current.scrollTo({
                top: contentTop(modelsHeading.current) - 18,
                behavior: "smooth",
              });
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="model" />
            </span>
            <span>{t("settings.models")}</span>
          </a>
          <a
            className="focus-ring"
            href="#settings-model-connections"
            aria-current={
              activeSection === "model_connections" ? "location" : undefined
            }
            hidden={!modelConnectionSettingsAvailable}
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("model_connections");
              if (!content.current || !modelConnectionsHeading.current) return;
              content.current.scrollTo({
                top: contentTop(modelConnectionsHeading.current) - 18,
                behavior: "smooth",
              });
            }}
          >
            <span className="settings-nav-icon" aria-hidden="true">
              <Icon name="model" />
            </span>
            <span>{t("settings.model_connections")}</span>
          </a>
        </nav>

        <div
          ref={content}
          className="settings-content"
          onScroll={updateActiveSection}
        >
          <section id="settings-general" className="settings-section">
            <div className="settings-section-heading">
              <p>{t("settings.section_label")}</p>
              <h2>{t("settings.general")}</h2>
            </div>
            <div className="settings-preference-list">
              <div className="settings-row">
                <div>
                  <label htmlFor="settings-language">{t("app.language")}</label>
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
          </section>

          {permissionProfiles.enabled && (
            <section
              ref={permissionsSection}
              id="settings-permissions"
              className="settings-section"
            >
              <div className="settings-section-heading">
                <p>{t("settings.section_label")}</p>
                <h2>{t("settings.permissions")}</h2>
              </div>
              <div className="permission-policy-card">
                <div className="permission-policy-copy">
                  <span className="permission-policy-kicker">
                    {t("permission.default.label")}
                  </span>
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
            </section>
          )}

          <section
            ref={accountSection}
            id="settings-account"
            className="settings-section"
          >
            <div className="settings-section-heading">
              <p>{t("settings.section_label")}</p>
              <h2 ref={accountHeading} tabIndex={-1}>
                {t("settings.account")}
              </h2>
            </div>

            <div
              className="settings-identity-row"
              data-session-state={account.state}
            >
              <span className="settings-avatar" aria-hidden="true">
                {[...(account.displayName || "M")][0]?.toLocaleUpperCase()}
              </span>
              <div className="settings-identity-copy">
                <strong title={account.displayName}>
                  {authenticated
                    ? account.displayName || t("account.signed_in")
                    : t("account.sign_in_required.title")}
                </strong>
                <span>
                  {authenticated
                    ? t("account.connected")
                    : t("account.sign_in_required.body")}
                </span>
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
                </div>
              )}

            {authenticated && (
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
            )}
          </section>

          <section
            ref={modelsSection}
            id="settings-models"
            className="settings-section"
          >
            <div className="settings-section-heading">
              <p>{t("settings.section_label")}</p>
              <h2 ref={modelsHeading} tabIndex={-1}>
                {t("settings.models")}
              </h2>
            </div>

            <div
              className="settings-execution-group"
              role="group"
              aria-labelledby="settings-execution-title"
            >
              <div className="settings-execution-header">
                <h3 id="settings-execution-title">
                  {t("settings.execution_defaults")}
                </h3>
                <div className="settings-execution-actions">
                  {customDefaultSelected &&
                    authenticated &&
                    metaskCatalogState === "ready" && (
                      <Button
                        variant="secondary"
                        size="sm"
                        disabled={disabled || executionDisabled}
                        onClick={onActivateMetask}
                      >
                        {t("settings.use_metask_default")}
                      </Button>
                    )}
                  <span className="settings-catalog-count">
                    {t("settings.catalog_count", {
                      apis: metaskApiKeys.length,
                      models: metaskModels.length,
                    })}
                  </span>
                  <button
                    className="settings-refresh-button focus-ring"
                    disabled={
                      disabled || accountDisabled || !authenticated || apiBusy
                    }
                    onClick={onRefresh}
                  >
                    <Icon name="refresh" />
                    {t("account.refresh_catalog")}
                  </button>
                </div>
              </div>

              <div className="settings-field settings-field-api">
                <span className="settings-field-step" aria-hidden="true">
                  01
                </span>
                <div className="settings-field-copy">
                  <label htmlFor="settings-api">
                    {t("settings.default_api")}
                  </label>
                  <p>
                    {t(
                      apiIsOnlyOption
                        ? "settings.only_api_help"
                        : "settings.default_api_help",
                    )}
                  </p>
                </div>
                <div className="settings-control-stack">
                  <SelectionMenu
                    triggerId="settings-api"
                    value={candidateApiId || selectedApiId}
                    options={apiOptions}
                    placeholder={t("account.choose_key")}
                    ariaLabel={t("settings.default_api")}
                    helper={t("settings.api_menu_help")}
                    actionLabel={t(
                      apiIsOnlyOption
                        ? "settings.view_selection"
                        : selectedApiId
                          ? "settings.change_selection"
                          : "settings.choose_selection",
                    )}
                    disabled={
                      disabled ||
                      accountDisabled ||
                      !canChooseApi ||
                      metaskApiKeys.length === 0
                    }
                    busy={apiBusy}
                    valueLayout="detailed"
                    leading={<Icon name="account" />}
                    triggerClassName="settings-control settings-control-detailed"
                    contentClassName="settings-selection-menu"
                    onValueChange={(value) => {
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
                  {apiHasPendingChange && (
                    <span className="settings-pending-label">
                      <span aria-hidden="true" />
                      {t("settings.switch.pending_label")}
                    </span>
                  )}
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
                    {modelCatalogLoading && (candidateApi || committedApi)
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
                  <SelectionMenu
                    triggerId="settings-model"
                    value={candidateModelId || selectedModelId}
                    options={modelOptions}
                    placeholder={modelPlaceholder}
                    ariaLabel={t("settings.default_model")}
                    helper={t("settings.model_menu_help")}
                    actionLabel={t(
                      modelIsOnlyOption
                        ? "settings.view_selection"
                        : selectedModelId
                          ? "settings.change_selection"
                          : "settings.choose_selection",
                    )}
                    disabled={
                      disabled ||
                      accountDisabled ||
                      !canChooseModel ||
                      metaskModels.length === 0
                    }
                    busy={modelBusy}
                    leading={<Icon name="model" />}
                    triggerClassName="settings-control"
                    contentClassName="settings-selection-menu"
                    onValueChange={(value) => {
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
                  {modelHasPendingChange && (
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
                  <span className="settings-operation-dot" aria-hidden="true" />
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
          </section>

          <section
            ref={modelConnectionsSection}
            id="settings-model-connections"
            className="settings-section settings-model-connections"
            aria-labelledby="settings-model-connections-title"
            hidden={!modelConnectionSettingsAvailable}
          >
            <div className="settings-execution-header">
              <div>
                <h3
                  id="settings-model-connections-title"
                  ref={modelConnectionsHeading}
                  tabIndex={-1}
                >
                  {t("settings.model_connections")}
                </h3>
                <p>{t("settings.model_connections_help")}</p>
              </div>
              {modelConnectionCapabilities.secretCapture && (
                <Button
                  variant="secondary"
                  size="sm"
                  disabled={
                    disabled || executionDisabled || creatingModelConnection
                  }
                  onClick={() =>
                    setModelConnectionDraft((current) =>
                      current ? null : newModelConnectionDraft(),
                    )
                  }
                  aria-expanded={modelConnectionDraft !== null}
                  aria-controls="settings-model-connection-create"
                >
                  {modelConnectionDraft
                    ? t("common.cancel")
                    : t("settings.model_connection_add")}
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
                  <span>{t("settings.model_connection_route.protocol")}</span>
                  <span>{t("settings.model_connection_route.endpoint")}</span>
                  <span>{t("settings.model_connection_route.model")}</span>
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
                      disabled || executionDisabled || creatingModelConnection
                    }
                    onChange={(event) =>
                      setModelConnectionDraft((current) =>
                        current
                          ? { ...current, displayName: event.target.value }
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
                    placeholder={t("settings.model_connection_protocol")}
                    ariaLabel={t("settings.model_connection_protocol")}
                    disabled={
                      disabled || executionDisabled || creatingModelConnection
                    }
                    triggerClassName="settings-control"
                    onValueChange={(value) => {
                      const protocol = value as Protocol;
                      setModelConnectionDraft((current) =>
                        current
                          ? {
                              ...current,
                              protocol,
                              normalizedBaseUrl:
                                modelConnectionEndpointDefaults[protocol],
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
                    value={modelConnectionDraft.normalizedBaseUrl}
                    disabled={
                      disabled || executionDisabled || creatingModelConnection
                    }
                    onChange={(event) =>
                      setModelConnectionDraft((current) =>
                        current
                          ? {
                              ...current,
                              normalizedBaseUrl: event.target.value,
                            }
                          : current,
                      )
                    }
                  />
                </label>
                <label className="settings-model-connection-create-field settings-model-connection-create-field-wide">
                  <span>{t("settings.model_connection_model_id")}</span>
                  <input
                    className="settings-model-connection-input settings-model-connection-input-mono focus-ring"
                    autoComplete="off"
                    maxLength={256}
                    value={modelConnectionDraft.modelId}
                    placeholder={t(
                      "settings.model_connection_model_id_placeholder",
                    )}
                    disabled={
                      disabled || executionDisabled || creatingModelConnection
                    }
                    onChange={(event) =>
                      setModelConnectionDraft((current) =>
                        current
                          ? { ...current, modelId: event.target.value }
                          : current,
                      )
                    }
                  />
                </label>
                <div className="settings-model-connection-create-footer">
                  <p>{t("settings.model_connection_secure_capture_help")}</p>
                  <Button
                    type="submit"
                    size="sm"
                    disabled={
                      disabled ||
                      executionDisabled ||
                      creatingModelConnection ||
                      !modelConnectionDraft.displayName.trim() ||
                      !modelConnectionDraft.normalizedBaseUrl.trim() ||
                      !modelConnectionDraft.modelId.trim()
                    }
                  >
                    {creatingModelConnection
                      ? t("settings.model_connection_adding")
                      : t("settings.model_connection_add")}
                  </Button>
                </div>
              </form>
            )}
            {!modelConnectionCapabilities.management ? (
              <p className="settings-model-connections-empty">
                {t("settings.model_connections_unavailable")}
              </p>
            ) : models.connections.length === 0 ? (
              <p className="settings-model-connections-empty">
                {t("settings.model_connections_empty")}
              </p>
            ) : (
              <div className="settings-model-connection-list">
                {models.connections.map((connection) => (
                  <div
                    className="settings-model-connection"
                    key={connection.id}
                  >
                    <div className="settings-model-connection-copy">
                      <strong>{connection.displayName || connection.id}</strong>
                      <span>
                        {modelConnectionProtocolLabel(connection.protocol, t)}
                        <span aria-hidden="true"> · </span>
                        {connection.normalizedBaseUrl}
                      </span>
                      <span>
                        {modelConnectionCredentialLabel(
                          connection.credentialStatus,
                          t,
                        )}
                        <span aria-hidden="true"> · </span>
                        {modelConnectionStateLabel(connection.state, t)}
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
                      <SelectionMenu
                        value={
                          models.defaultSelection?.sourceId === connection.id
                            ? models.defaultSelection.modelId
                            : ""
                        }
                        options={connection.models.map((model) => ({
                          value: model.id,
                          label: model.displayName || model.id,
                          disabled: !model.ready,
                        }))}
                        placeholder={t("settings.model_connection_set_default")}
                        ariaLabel={t(
                          "settings.model_connection_default_model",
                          {
                            connection: connection.displayName || connection.id,
                          },
                        )}
                        disabled={
                          disabled ||
                          executionDisabled ||
                          connection.state !== "ready" ||
                          connection.credentialStatus !== "ready" ||
                          connection.models.length === 0
                        }
                        triggerClassName="settings-control settings-model-connection-select"
                        onValueChange={(modelId) =>
                          onSelectModelConnection(
                            connection.id,
                            connection.connectionRevision,
                            modelId,
                          )
                        }
                      />
                      <button
                        className="text-button focus-ring"
                        disabled={
                          disabled ||
                          executionDisabled ||
                          mutatingModelConnection ||
                          models.defaultSelection?.sourceId === connection.id
                        }
                        onClick={() => {
                          setModelConnectionRemoval(null);
                          setModelConnectionEdit({
                            connectionId: connection.id,
                            expectedConnectionRevision:
                              connection.connectionRevision,
                            displayName: connection.displayName,
                            protocol: connection.protocol,
                            normalizedBaseUrl: connection.normalizedBaseUrl,
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
                          mutatingModelConnection ||
                          models.defaultSelection?.sourceId === connection.id
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
                    {models.defaultSelection?.sourceId === connection.id && (
                      <p className="settings-model-connection-active-note">
                        {t("settings.model_connection_active_mutation_help")}
                      </p>
                    )}
                    {modelConnectionEdit?.connectionId === connection.id && (
                      <form
                        className="settings-model-connection-edit"
                        onSubmit={(event) => {
                          event.preventDefault();
                          void submitModelConnectionEdit();
                        }}
                      >
                        <label className="settings-model-connection-create-field">
                          <span>{t("settings.model_connection_name")}</span>
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
                          <span>{t("settings.model_connection_protocol")}</span>
                          <SelectionMenu
                            value={modelConnectionEdit.protocol}
                            options={modelConnectionProtocolOptions}
                            placeholder={t(
                              "settings.model_connection_protocol",
                            )}
                            ariaLabel={t("settings.model_connection_protocol")}
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
                                      normalizedBaseUrl:
                                        modelConnectionEndpointDefaults[
                                          protocol
                                        ],
                                    }
                                  : current,
                              );
                            }}
                          />
                        </div>
                        <label className="settings-model-connection-create-field settings-model-connection-edit-endpoint">
                          <span>{t("settings.model_connection_endpoint")}</span>
                          <input
                            className="settings-model-connection-input focus-ring"
                            autoComplete="url"
                            inputMode="url"
                            maxLength={2048}
                            value={modelConnectionEdit.normalizedBaseUrl}
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
                                      normalizedBaseUrl: event.target.value,
                                    }
                                  : current,
                              )
                            }
                          />
                        </label>
                        <div className="settings-model-connection-edit-actions">
                          <p>{t("settings.model_connection_edit_help")}</p>
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            disabled={mutatingModelConnection}
                            onClick={() => setModelConnectionEdit(null)}
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
                              !modelConnectionEdit.normalizedBaseUrl.trim()
                            }
                          >
                            {mutatingModelConnection
                              ? t("common.saving")
                              : t("common.save")}
                          </Button>
                        </div>
                      </form>
                    )}
                    {modelConnectionRemoval?.connectionId === connection.id && (
                      <div
                        className="settings-model-connection-confirm-remove"
                        role="group"
                        aria-label={t(
                          "settings.model_connection_remove_confirm",
                        )}
                      >
                        <p>{t("settings.model_connection_remove_confirm")}</p>
                        <Button
                          variant="ghost"
                          size="sm"
                          disabled={mutatingModelConnection}
                          onClick={() => setModelConnectionRemoval(null)}
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
            )}
            {modelConnectionCapabilities.management &&
              !modelConnectionCapabilities.secretCapture && (
                <p className="settings-model-connections-empty">
                  {t("settings.model_connection_capture_unavailable")}
                </p>
              )}
          </section>
        </div>
      </div>
    </div>
  );
}
