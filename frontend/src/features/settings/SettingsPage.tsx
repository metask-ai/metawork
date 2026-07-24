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
  const [pendingModel, setPendingModel] = useState<{
    selectionId: string;
    displayName: string;
  } | null>(null);
  const page = useRef<HTMLDivElement>(null);
  const title = useRef<HTMLHeadingElement>(null);
  const generalSection = useRef<HTMLElement>(null);
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
  const selectedApi = account.apiKeys.find(
    (key) => key.selectionId === account.selectedApiKeySelectionId,
  );
  const modelCatalogLoading = ["loading_keys", "loading_models"].includes(
    account.operation,
  );
  const apiBusy = ["loading_keys", "loading_models"].includes(
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
  const operationStatus =
    account.operation === "none"
      ? null
      : t(`account.operation.${account.operation}`);
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
      pendingModel &&
      !options.some((option) => option.value === pendingModel.selectionId)
    ) {
      options.unshift({
        value: pendingModel.selectionId,
        label: pendingModel.displayName,
      });
    }
    return options;
  }, [account.models, pendingModel, t]);
  const selectedApiId =
    modelCatalogApi?.selectionId || selectedApi?.selectionId || "";
  const selectedModelId = pendingModel
    ? pendingModel.selectionId
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
      setPendingModel(null);
    }
  }, [
    account.errorCode,
    account.operation,
    account.selectedModelSelectionId,
    account.sessionState,
    disabled,
  ]);

  useEffect(() => {
    if (!page.current || typeof IntersectionObserver === "undefined") return;
    const sections = [generalSection.current, accountSection.current].filter(
      (section): section is HTMLElement => section !== null,
    );
    const observer = new IntersectionObserver(
      (entries) => {
        const visible = entries
          .filter((entry) => entry.isIntersecting)
          .sort(
            (left, right) =>
              Math.abs(left.boundingClientRect.top) -
              Math.abs(right.boundingClientRect.top),
          )[0];
        if (visible?.target.id === "settings-general") {
          setActiveSection("general");
        } else if (visible?.target.id === "settings-account") {
          setActiveSection("account");
        }
      },
      {
        root: page.current,
        rootMargin: "-18% 0px -62% 0px",
        threshold: [0, 0.1, 0.5],
      },
    );
    sections.forEach((section) => observer.observe(section));
    return () => observer.disconnect();
  }, []);

  function closeSignOutConfirmation() {
    setConfirmSignOut(false);
    window.requestAnimationFrame(() => signOut.current?.focus());
  }

  return (
    <div ref={page} className="settings-page">
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
          <section
            ref={generalSection}
            id="settings-general"
            className="settings-section"
          >
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
                  onValueChange={onSelectApiKey}
                />
              </div>

              <div className="settings-field">
                <div className="settings-field-copy">
                  <label htmlFor="settings-model">
                    {t("settings.default_model")}
                  </label>
                  <p>
                    {modelCatalogLoading && modelCatalogApi
                      ? t("settings.loading_models_for", {
                          api:
                            modelCatalogApi.name || t("account.api_fallback"),
                        })
                      : t("settings.default_model_help")}
                  </p>
                </div>
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
                    setPendingModel({
                      selectionId: value,
                      displayName:
                        model.displayName || t("account.model_fallback"),
                    });
                    onSelectModel(value);
                  }}
                />
              </div>

              {operationStatus && (
                <div className="settings-operation" role="status">
                  <span className="settings-operation-dot" aria-hidden="true" />
                  <span>{operationStatus}</span>
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
