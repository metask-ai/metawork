import { useEffect, useMemo, useRef, useState } from "react";

import type {
  AccountView,
  TaskView,
  WorkspaceView,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { useI18n, type Locale } from "../../i18n/context.ts";
import { accountErrorText } from "../../i18n/account-error.ts";
import {
  WorkspaceSettings,
  type WorkspaceChoiceIntent,
  type WorkspaceChoiceResult,
  type WorkspaceRemovalResult,
} from "./WorkspaceSettings.tsx";

export type {
  WorkspaceChoiceResult,
  WorkspaceChoiceIntent,
  WorkspaceRemovalResult,
} from "./WorkspaceSettings.tsx";

export type SettingsFocusTarget = "title" | "signout";
type SettingsSection = "general" | "workspaces" | "account";
type RequestedSelection = {
  selectionId: string;
  label: string;
};

function providerLabel(
  provider: AccountView["apiKeys"][number]["provider"],
  t: ReturnType<typeof useI18n>["t"],
) {
  return t(`provider.${provider}`);
}

function apiLabel(
  api: AccountView["apiKeys"][number],
  t: ReturnType<typeof useI18n>["t"],
) {
  return api.name.trim() || `${t("account.api_fallback")} ${api.selectionId}`;
}

function modelLabel(
  model: AccountView["models"][number],
  t: ReturnType<typeof useI18n>["t"],
) {
  return model.displayName.trim() || model.selectionId;
}

export function SettingsPage({
  account,
  userWorkspaces,
  tasks,
  focusTarget,
  disabled,
  workspaceDisabled,
  workspaceBusy,
  cancelDisabled,
  onBack,
  onRefresh,
  onCancel,
  onSelectApiKey,
  onSelectModel,
  onChooseWorkspace,
  onRemoveWorkspace,
  onReauthenticate,
  onLogout,
}: {
  account: AccountView;
  userWorkspaces: WorkspaceView[];
  tasks: TaskView[];
  focusTarget: SettingsFocusTarget;
  disabled: boolean;
  workspaceDisabled: boolean;
  workspaceBusy: boolean;
  cancelDisabled: boolean;
  onBack: () => void;
  onRefresh: () => void;
  onCancel: () => void;
  onSelectApiKey: (id: string) => void;
  onSelectModel: (id: string) => void;
  onChooseWorkspace: (
    intent: WorkspaceChoiceIntent,
  ) => Promise<WorkspaceChoiceResult>;
  onRemoveWorkspace: (workspaceId: string) => Promise<WorkspaceRemovalResult>;
  onReauthenticate: () => void;
  onLogout: () => void;
}) {
  const { locale, setLocale, t } = useI18n();
  const [confirmSignOut, setConfirmSignOut] = useState(false);
  const [activeSection, setActiveSection] =
    useState<SettingsSection>("general");
  const [requestedApi, setRequestedApi] = useState<RequestedSelection | null>(
    null,
  );
  const [requestedModel, setRequestedModel] =
    useState<RequestedSelection | null>(null);
  const content = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const workspaceSection = useRef<HTMLElement>(null);
  const accountSection = useRef<HTMLElement>(null);
  const accountHeading = useRef<HTMLDivElement>(null);
  const signOut = useRef<HTMLButtonElement>(null);
  const signOutCancel = useRef<HTMLButtonElement>(null);
  const modelCatalogApi = useMemo(
    () =>
      account.apiKeys.find(
        (key) => key.selectionId === account.modelCatalogApiKeySelectionId,
      ) ?? null,
    [account.apiKeys, account.modelCatalogApiKeySelectionId],
  );
  const committedApi = account.apiKeys.find(
    (key) => key.selectionId === account.selectedApiKeySelectionId,
  );
  const committedModel = account.models.find(
    (model) => model.selectionId === account.selectedModelSelectionId,
  );
  const hostCandidateApi = account.apiKeys.find(
    (key) => key.selectionId === account.candidateApiKeySelectionId,
  );
  const hostCandidateModel = account.models.find(
    (model) => model.selectionId === account.candidateModelSelectionId,
  );
  const candidateApiId =
    account.candidateApiKeySelectionId || requestedApi?.selectionId || "";
  const candidateModelId =
    account.candidateModelSelectionId || requestedModel?.selectionId || "";
  const candidateApi =
    hostCandidateApi ??
    account.apiKeys.find((key) => key.selectionId === candidateApiId) ??
    null;
  const candidateModel =
    hostCandidateModel ??
    account.models.find((model) => model.selectionId === candidateModelId) ??
    null;
  const modelCatalogLoading = account.operation === "loading_models";
  const apiBusy = ["loading_keys", "loading_models", "persisting"].includes(
    account.operation,
  );
  const modelBusy = ["loading_models", "persisting"].includes(
    account.operation,
  );
  const authenticated = account.sessionState === "authenticated";
  const canChooseApi =
    authenticated && ["none", "selecting_key"].includes(account.operation);
  const canChooseModel =
    authenticated && ["none", "selecting_model"].includes(account.operation);
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
  const apiOptions = useMemo<SelectionMenuOption[]>(
    () =>
      account.apiKeys.map((key) => ({
        value: key.selectionId,
        label: apiLabel(key, t),
        description: providerLabel(key.provider, t),
        descriptionKind: "text",
        trailing: key.suffix ? `•••• ${key.suffix}` : undefined,
      })),
    [account.apiKeys, t],
  );
  const modelOptions = useMemo<SelectionMenuOption[]>(() => {
    const options = account.models.map((model) => ({
      value: model.selectionId,
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
  }, [account.models, requestedModel, t]);
  const selectedApiId =
    candidateApi?.selectionId ||
    modelCatalogApi?.selectionId ||
    committedApi?.selectionId ||
    "";
  const selectedModelId = candidateModel
    ? candidateModel.selectionId
    : account.models.some(
          (model) => model.selectionId === account.selectedModelSelectionId,
        )
      ? account.selectedModelSelectionId
      : "";
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
    : account.operation === "selecting_key"
      ? t("settings.model_waiting_api")
      : t("account.choose_model");
  const committedApiName = committedApi
    ? apiLabel(committedApi, t)
    : t("account.api_fallback");
  const committedModelName =
    (committedModel ? modelLabel(committedModel, t) : "") ||
    account.selectedModelSelectionId ||
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
    candidateApiId.length > 0 &&
    candidateApiId !== account.selectedApiKeySelectionId;
  const modelHasPendingChange =
    candidateModelId.length > 0 &&
    candidateModelId !== account.selectedModelSelectionId;
  const transactionStatus = (() => {
    switch (account.operation) {
      case "loading_keys":
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
      case "loading_models":
        return {
          title: t("settings.switch.loading_models", {
            api: candidateApiName,
          }),
          detail: t("settings.switch.current_preserved", {
            api: committedApiName,
            model: committedModelName,
          }),
        };
      case "selecting_model":
        return {
          title: t("settings.switch.choose_model", {
            api: candidateApiName,
          }),
          detail: t("settings.switch.choose_model_help"),
        };
      case "persisting":
        return {
          title: t("settings.switch.saving"),
          detail: t("settings.switch.saving_detail", {
            api: candidateApiName,
            model: candidateModelName,
          }),
        };
      case "selecting_key":
        return {
          title: t("account.operation.selecting_key"),
          detail: t("settings.switch.choose_api_help"),
        };
      case "none":
        return null;
      default:
        return {
          title: t(`account.operation.${account.operation}`),
          detail: t("settings.switch.working"),
        };
    }
  })();

  useEffect(() => {
    window.requestAnimationFrame(() => {
      (focusTarget === "signout" ? signOut.current : title.current)?.focus();
    });
  }, [focusTarget]);

  useEffect(() => {
    if (!confirmSignOut) return;
    const frame = window.requestAnimationFrame(() =>
      signOutCancel.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [confirmSignOut]);

  useEffect(() => {
    if (
      account.errorCode !== "none" ||
      account.sessionState === "reauth_required" ||
      (account.operation === "none" && !disabled)
    ) {
      setRequestedApi(null);
      setRequestedModel(null);
    }
  }, [
    account.errorCode,
    account.operation,
    account.selectedModelSelectionId,
    account.sessionState,
    disabled,
  ]);

  function closeSignOutConfirmation() {
    setConfirmSignOut(false);
    window.requestAnimationFrame(() => signOut.current?.focus());
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
      !workspaceSection.current ||
      !accountSection.current
    )
      return;
    const readingLine =
      content.current.scrollTop +
      Math.min(160, content.current.clientHeight * 0.3);
    if (contentTop(accountSection.current) <= readingLine)
      setActiveSection("account");
    else if (contentTop(workspaceSection.current) <= readingLine)
      setActiveSection("workspaces");
    else setActiveSection("general");
  }

  return (
    <div className="settings-page">
      <header className="settings-header">
        <button className="settings-back focus-ring" onClick={onBack}>
          <Icon name="arrow-left" />
          {t("settings.back")}
        </button>
        <div className="settings-header-copy">
          <h1 ref={title} tabIndex={-1}>
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
            {t("settings.general")}
          </a>
          <a
            className="focus-ring"
            href="#settings-workspaces"
            aria-current={
              activeSection === "workspaces" ? "location" : undefined
            }
            onClick={(event) => {
              event.preventDefault();
              setActiveSection("workspaces");
              if (!content.current || !workspaceSection.current) return;
              content.current.scrollTo({
                top: contentTop(workspaceSection.current) - 18,
                behavior: "smooth",
              });
            }}
          >
            {t("settings.workspaces")}
          </a>
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
            {t("settings.account_models")}
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

          <section
            ref={workspaceSection}
            id="settings-workspaces"
            className="settings-section"
          >
            <WorkspaceSettings
              userWorkspaces={userWorkspaces}
              tasks={tasks}
              disabled={workspaceDisabled}
              busy={workspaceBusy}
              onChooseWorkspace={onChooseWorkspace}
              onRemoveWorkspace={onRemoveWorkspace}
            />
          </section>

          <section
            ref={accountSection}
            id="settings-account"
            className="settings-section"
          >
            <div ref={accountHeading} className="settings-section-heading">
              <p>{t("settings.section_label")}</p>
              <h2>{t("settings.account_models")}</h2>
            </div>

            <div
              className="settings-identity-row"
              data-session-state={account.sessionState}
            >
              <span className="settings-avatar" aria-hidden="true">
                {[...(account.displayName || "M")][0]?.toLocaleUpperCase()}
              </span>
              <div className="settings-identity-copy">
                <strong title={account.displayName}>
                  {account.displayName || t("account.signed_in")}
                </strong>
                <span>
                  {account.sessionState === "reauth_required"
                    ? t("account.connection_attention")
                    : t("account.connected")}
                </span>
              </div>
              {account.sessionState === "reauth_required" && (
                <button
                  className="secondary-button focus-ring"
                  disabled={disabled}
                  onClick={onReauthenticate}
                >
                  {t("account.reauthenticate")}
                </button>
              )}
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
                  <span className="settings-catalog-count">
                    {t("settings.catalog_count", {
                      apis: account.apiKeys.length,
                      models: account.models.length,
                    })}
                  </span>
                  <button
                    className="settings-refresh-button focus-ring"
                    disabled={
                      disabled || !authenticated || account.operation !== "none"
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
                    value={selectedApiId}
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
                      disabled || !canChooseApi || account.apiKeys.length === 0
                    }
                    busy={apiBusy}
                    valueLayout="detailed"
                    leading={<Icon name="account" />}
                    triggerClassName="settings-control settings-control-detailed"
                    contentClassName="settings-selection-menu"
                    onValueChange={(value) => {
                      const api = account.apiKeys.find(
                        (candidate) => candidate.selectionId === value,
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
                      {t(
                        account.operation === "persisting"
                          ? "settings.switch.saving_label"
                          : "settings.switch.pending_label",
                      )}
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
                    {modelCatalogLoading && (candidateApi || modelCatalogApi)
                      ? t("settings.loading_models_for", {
                          api:
                            candidateApi?.name ||
                            modelCatalogApi?.name ||
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
                    value={selectedModelId}
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
                      disabled || !canChooseModel || account.models.length === 0
                    }
                    busy={modelBusy}
                    leading={<Icon name="model" />}
                    triggerClassName="settings-control"
                    contentClassName="settings-selection-menu"
                    onValueChange={(value) => {
                      const model = account.models.find(
                        (candidate) => candidate.selectionId === value,
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
                      {t(
                        account.operation === "persisting"
                          ? "settings.switch.saving_label"
                          : "settings.switch.pending_label",
                      )}
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
                  {account.canCancel && (
                    <button
                      className="text-button focus-ring"
                      disabled={cancelDisabled}
                      onClick={onCancel}
                    >
                      {t("common.cancel")}
                    </button>
                  )}
                </div>
              )}
            </div>

            {account.errorCode === "user_cancelled" &&
              account.executionState === "ready" && (
                <p className="settings-outcome" role="status">
                  <Icon name="check" />
                  {t("settings.switch.cancelled", {
                    api: committedApiName,
                    model: committedModelName,
                  })}
                </p>
              )}

            <p className="settings-binding-note">
              <Icon name="check" />
              {t("settings.existing_tasks_unchanged")}
            </p>

            {account.errorCode !== "none" &&
              account.errorCode !== "user_cancelled" && (
                <div className="settings-error" role="alert">
                  <Icon name="warning" />
                  <span className="settings-error-copy">
                    <strong>{t("account.action_failed")}</strong>
                    <span>{accountErrorText(account.errorCode, t)}</span>
                    {account.executionState === "ready" && (
                      <span>
                        {t("settings.switch.failure_preserved", {
                          api: committedApiName,
                          model: committedModelName,
                        })}
                      </span>
                    )}
                  </span>
                </div>
              )}

            <div className="settings-danger-zone">
              <div>
                <h3 id="settings-signout-title">
                  {t("settings.signout_title")}
                </h3>
                <p>{t("settings.signout_help")}</p>
              </div>
              {!confirmSignOut ? (
                <button
                  ref={signOut}
                  className="danger-button focus-ring"
                  disabled={disabled || account.operation !== "none"}
                  onClick={() => setConfirmSignOut(true)}
                >
                  {t("account.logout_short")}
                </button>
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
                    <button
                      ref={signOutCancel}
                      className="secondary-button focus-ring"
                      onClick={closeSignOutConfirmation}
                    >
                      {t("common.cancel")}
                    </button>
                    <button
                      className="danger-button focus-ring"
                      disabled={disabled || account.operation !== "none"}
                      onClick={onLogout}
                    >
                      {t("account.logout")}
                    </button>
                  </span>
                </div>
              )}
            </div>
          </section>
        </div>
      </div>
    </div>
  );
}
