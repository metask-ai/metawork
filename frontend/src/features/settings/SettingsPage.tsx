import { useEffect, useMemo, useRef, useState } from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import {
  SelectionMenu,
  type SelectionMenuOption,
} from "../../components/ui/SelectionMenu.tsx";
import { useI18n, type Locale } from "../../i18n/context.ts";
import { accountErrorText } from "../../i18n/account-error.ts";

export type SettingsFocusTarget = "title" | "signout";
type SettingsSection = "general" | "account";
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

export function SettingsPage({
  account,
  focusTarget,
  disabled,
  cancelDisabled,
  onBack,
  onRefresh,
  onCancel,
  onSelectApiKey,
  onSelectModel,
  onReauthenticate,
  onLogout,
}: {
  account: AccountView;
  focusTarget: SettingsFocusTarget;
  disabled: boolean;
  cancelDisabled: boolean;
  onBack: () => void;
  onRefresh: () => void;
  onCancel: () => void;
  onSelectApiKey: (id: string) => void;
  onSelectModel: (id: string) => void;
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
  const page = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const accountSection = useRef<HTMLElement>(null);
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
        label: key.name || t("account.api_fallback"),
        description: providerLabel(key.provider, t),
        descriptionKind: "text",
        trailing: key.suffix ? `•••• ${key.suffix}` : undefined,
      })),
    [account.apiKeys, t],
  );
  const modelOptions = useMemo<SelectionMenuOption[]>(() => {
    const options = account.models.map((model) => ({
      value: model.selectionId,
      label: model.displayName || t("account.model_fallback"),
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
  const modelPlaceholder = modelCatalogLoading
    ? t("settings.model_loading")
    : account.operation === "selecting_key"
      ? t("settings.model_waiting_api")
      : t("account.choose_model");
  const committedApiName = committedApi?.name || t("account.api_fallback");
  const committedModelName =
    committedModel?.displayName ||
    account.selectedModelSelectionId ||
    t("account.model_fallback");
  const candidateApiName =
    candidateApi?.name ||
    (requestedApi?.selectionId === candidateApiId
      ? requestedApi.label
      : candidateApiId) ||
    t("account.api_fallback");
  const candidateModelName =
    candidateModel?.displayName ||
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

  function updateActiveSection() {
    if (!page.current || !accountSection.current) return;
    const readingLine =
      page.current.scrollTop + Math.min(160, page.current.clientHeight * 0.3);
    setActiveSection(
      accountSection.current.offsetTop <= readingLine ? "account" : "general",
    );
  }

  return (
    <div ref={page} className="settings-page" onScroll={updateActiveSection}>
      <header className="settings-hero">
        <button className="settings-back focus-ring" onClick={onBack}>
          <Icon name="arrow-left" />
          {t("settings.back")}
        </button>
        <p className="settings-eyebrow">{t("app.name")}</p>
        <h1 ref={title} tabIndex={-1}>
          {t("settings.title")}
        </h1>
        <p>{t("settings.intro")}</p>
      </header>

      <div className="settings-layout">
        <nav className="settings-nav" aria-label={t("settings.sections")}>
          <a
            className="focus-ring"
            href="#settings-general"
            aria-current={activeSection === "general" ? "location" : undefined}
            onClick={() => setActiveSection("general")}
          >
            {t("settings.general")}
          </a>
          <a
            className="focus-ring"
            href="#settings-account"
            aria-current={activeSection === "account" ? "location" : undefined}
            onClick={() => setActiveSection("account")}
          >
            {t("settings.account_models")}
          </a>
        </nav>

        <div className="settings-content">
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
            ref={accountSection}
            id="settings-account"
            className="settings-section"
          >
            <div className="settings-section-heading">
              <p>{t("settings.section_label")}</p>
              <h2>{t("settings.account_models")}</h2>
            </div>

            <div className="settings-identity-row">
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
              aria-label={t("settings.execution_defaults")}
            >
              <div className="settings-field">
                <div className="settings-field-copy">
                  <label htmlFor="settings-api">
                    {t("settings.default_api")}
                  </label>
                  <p>{t("settings.default_api_help")}</p>
                </div>
                <div className="settings-control-stack">
                  <SelectionMenu
                    triggerId="settings-api"
                    value={selectedApiId}
                    options={apiOptions}
                    placeholder={t("account.choose_key")}
                    ariaLabel={t("settings.default_api")}
                    helper={t("settings.api_menu_help")}
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
                        label: api.name || t("account.api_fallback"),
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
                      : t("settings.default_model_help")}
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
                        label: model.displayName || t("account.model_fallback"),
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

            <div className="settings-actions">
              <button
                className="secondary-button focus-ring"
                disabled={
                  disabled || !authenticated || account.operation !== "none"
                }
                onClick={onRefresh}
              >
                {t("account.refresh_catalog")}
              </button>
            </div>

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
                    {t("settings.signout_confirm")}
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
