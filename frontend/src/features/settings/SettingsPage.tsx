import { useEffect, useMemo, useRef, useState } from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type Locale } from "../../i18n/context.ts";
import { accountErrorText } from "../../i18n/account-error.ts";

export type SettingsFocusTarget = "title" | "signout";

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
  const title = useRef<HTMLHeadingElement>(null);
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
  const modelCatalogLoading = account.operation === "loading_models";
  const authenticated = account.sessionState === "authenticated";
  const canChooseApi =
    authenticated && ["none", "selecting_key"].includes(account.operation);
  const canChooseModel =
    authenticated && ["none", "selecting_model"].includes(account.operation);
  const operationStatus =
    account.operation === "none"
      ? null
      : t(`account.operation.${account.operation}`);

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

  function closeSignOutConfirmation() {
    setConfirmSignOut(false);
    window.requestAnimationFrame(() => signOut.current?.focus());
  }

  function apiLabel(key: AccountView["apiKeys"][number]) {
    const name = key.name || t("account.api_fallback");
    const suffix = key.suffix ? ` •••• ${key.suffix}` : "";
    return `${name} · ${providerLabel(key.provider, t)}${suffix}`;
  }

  return (
    <div className="settings-page">
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
          <a className="focus-ring" href="#settings-general">
            {t("settings.general")}
          </a>
          <a className="focus-ring" href="#settings-account">
            {t("settings.account_models")}
          </a>
        </nav>

        <div className="settings-content">
          <section id="settings-general" className="settings-section">
            <div className="settings-section-heading">
              <p>{t("settings.section_label")}</p>
              <h2>{t("settings.general")}</h2>
            </div>
            <div className="settings-row">
              <div>
                <label htmlFor="settings-language">{t("app.language")}</label>
                <p>{t("settings.language_help")}</p>
              </div>
              <select
                id="settings-language"
                className="settings-select focus-ring"
                value={locale}
                onChange={(event) => setLocale(event.target.value as Locale)}
              >
                <option value="en-US">{t("app.language.en-US")}</option>
                <option value="zh-CN">{t("app.language.zh-CN")}</option>
                {import.meta.env.DEV && (
                  <option value="pseudo">{t("app.language.pseudo")}</option>
                )}
              </select>
            </div>
          </section>

          <section id="settings-account" className="settings-section">
            <div className="settings-section-heading">
              <p>{t("settings.section_label")}</p>
              <h2>{t("settings.account_models")}</h2>
            </div>

            <div className="settings-identity-row">
              <span className="settings-avatar" aria-hidden="true">
                {[...(account.displayName || "M")][0]?.toLocaleUpperCase()}
              </span>
              <div>
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

            <div className="settings-row settings-row-stack">
              <div>
                <label htmlFor="settings-api">
                  {t("settings.default_api")}
                </label>
                <p>{t("settings.default_api_help")}</p>
              </div>
              <select
                id="settings-api"
                className="settings-select settings-select-wide focus-ring"
                value={
                  modelCatalogApi?.selectionId || selectedApi?.selectionId || ""
                }
                disabled={
                  disabled || !canChooseApi || account.apiKeys.length === 0
                }
                onChange={(event) => onSelectApiKey(event.target.value)}
              >
                {account.apiKeys.map((key) => (
                  <option key={key.selectionId} value={key.selectionId}>
                    {apiLabel(key)}
                  </option>
                ))}
              </select>
            </div>

            <div className="settings-row settings-row-stack">
              <div>
                <label htmlFor="settings-model">
                  {t("settings.default_model")}
                </label>
                <p>
                  {modelCatalogLoading && modelCatalogApi
                    ? t("settings.loading_models_for", {
                        api: modelCatalogApi.name || t("account.api_fallback"),
                      })
                    : t("settings.default_model_help")}
                </p>
              </div>
              <select
                id="settings-model"
                className="settings-select settings-select-wide focus-ring"
                value={
                  account.models.some(
                    (model) =>
                      model.selectionId === account.selectedModelSelectionId,
                  )
                    ? account.selectedModelSelectionId
                    : ""
                }
                disabled={
                  disabled || !canChooseModel || account.models.length === 0
                }
                onChange={(event) => {
                  if (event.target.value) onSelectModel(event.target.value);
                }}
              >
                {!account.models.some(
                  (model) =>
                    model.selectionId === account.selectedModelSelectionId,
                ) && <option value="">{t("account.choose_model")}</option>}
                {account.models.map((model) => (
                  <option key={model.selectionId} value={model.selectionId}>
                    {model.displayName || t("account.model_fallback")}
                  </option>
                ))}
              </select>
            </div>

            <p className="settings-binding-note">
              {t("settings.existing_tasks_unchanged")}
            </p>

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

            {account.errorCode !== "none" &&
              account.errorCode !== "user_cancelled" && (
                <div className="settings-error" role="alert">
                  <strong>{t("account.action_failed")}</strong>
                  <span>{accountErrorText(account.errorCode, t)}</span>
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
