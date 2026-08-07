import { useEffect, useRef, useState } from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { WindowTitlebar } from "../../components/ui/WindowTitlebar.tsx";
import { WindowControls } from "../../components/ui/WindowControls.tsx";
import { useI18n, type Locale, type MessageId } from "../../i18n/context.ts";
import { accountErrorText } from "../../i18n/account-error.ts";

type Props = {
  account: AccountView;
  disabled: boolean;
  cancelDisabled: boolean;
  connectionFailed: boolean;
  connectionRetryable: boolean;
  connectionTitleId: MessageId;
  connectionHelpId: MessageId;
  connectionSourceId?: MessageId;
  connectionDiagnostic?: string;
  reconnecting: boolean;
  notice: string;
  onReconnect: () => void;
  onBeginLogin: () => void;
  onReopenLogin: () => void;
  onReauthenticate: () => void;
  onLogout: () => void;
  onCancel: () => void;
  onRetry: () => void;
  onSelectApiKey: (id: string) => void;
  onSelectModel: (id: string) => void;
};

export function AccountGate({
  account,
  disabled,
  cancelDisabled,
  connectionFailed,
  connectionRetryable,
  connectionTitleId,
  connectionHelpId,
  connectionSourceId,
  connectionDiagnostic,
  reconnecting,
  notice,
  onReconnect,
  onBeginLogin,
  onReopenLogin,
  onReauthenticate,
  onLogout,
  onCancel,
  onRetry,
  onSelectApiKey,
  onSelectModel,
}: Props) {
  const { locale, setLocale, t } = useI18n();
  const signOut = useRef<HTMLButtonElement>(null);
  const signOutCancel = useRef<HTMLButtonElement>(null);
  const [confirmSignOut, setConfirmSignOut] = useState(false);

  useEffect(() => {
    if (confirmSignOut)
      window.requestAnimationFrame(() => signOutCancel.current?.focus());
  }, [confirmSignOut]);

  if (account.readiness === "ready") return null;

  const operation =
    account.operation === "none"
      ? null
      : t(`account.operation.${account.operation}`);
  const reauthenticationRequired =
    account.sessionState === "reauth_required" &&
    account.primaryAction === "reauthenticate";
  const identityMismatch =
    reauthenticationRequired && account.errorCode === "account_mismatch";
  const signInExpired =
    reauthenticationRequired &&
    (account.errorCode === "token_refresh_failed" ||
      account.errorCode === "metask_unauthorized");
  const hasError =
    account.readiness !== "restart_required" &&
    account.errorCode !== "none" &&
    account.errorCode !== "user_cancelled";
  const body = identityMismatch
    ? t("account.reauthentication_stale.body")
    : signInExpired
      ? t("account.reauthentication.body")
      : hasError
        ? accountErrorText(account.errorCode, t)
        : operation ||
          (account.errorCode === "user_cancelled"
            ? t("account.cancelled")
            : t(`account.readiness.${account.readiness}.body`));
  const reauthenticationTitle = identityMismatch
    ? t("account.reauthentication_stale.title")
    : signInExpired
      ? t("account.reauthentication.title")
      : t("account.action_failed");

  function closeSignOutConfirmation() {
    setConfirmSignOut(false);
    window.requestAnimationFrame(() => signOut.current?.focus());
  }

  return (
    <main className="account-gate" data-readiness={account.readiness}>
      <WindowTitlebar className="account-gate-toolbar">
        <div className="account-gate-brand" aria-label={t("app.name")}>
          <span className="brand-mark" aria-hidden="true">
            M
          </span>
          <span>{t("app.name")}</span>
        </div>
        <div className="account-gate-toolbar-actions">
          <label className="locale-control">
            <span className="sr-only">{t("app.language")}</span>
            <select
              className="focus-ring"
              aria-label={t("app.language")}
              value={locale}
              onChange={(event) => setLocale(event.target.value as Locale)}
            >
              <option value="en-US">{t("app.language.en-US")}</option>
              <option value="zh-CN">{t("app.language.zh-CN")}</option>
              {import.meta.env.DEV && (
                <option value="pseudo">{t("app.language.pseudo")}</option>
              )}
            </select>
          </label>
          <WindowControls
            labels={{
              controls: t("window.controls"),
              minimize: t("window.minimize"),
              maximize: t("window.maximize"),
              restore: t("window.restore"),
              close: t("window.close"),
            }}
          />
        </div>
      </WindowTitlebar>

      <section
        className="account-gate-stage"
        aria-labelledby="account-gate-title"
      >
        <div className="account-gate-content">
          <div className="account-gate-symbol" aria-hidden="true">
            M
          </div>
          <p className="account-gate-eyebrow">{t("account.gate.eyebrow")}</p>
          <h1 id="account-gate-title">
            {connectionFailed
              ? t(connectionTitleId)
              : reauthenticationRequired
                ? reauthenticationTitle
                : t(`account.readiness.${account.readiness}.title`)}
          </h1>
          <p
            className="account-gate-body"
            aria-live={hasError || connectionFailed ? "assertive" : "polite"}
            role={hasError || connectionFailed ? "alert" : "status"}
          >
            {connectionFailed ? t(connectionHelpId) : body}
          </p>

          {!connectionFailed && account.displayName && (
            <p className="account-gate-identity">
              <span>
                {t(
                  reauthenticationRequired
                    ? "account.saved_account"
                    : "account.signed_in",
                )}
              </span>
              <strong>{account.displayName}</strong>
            </p>
          )}

          {!connectionFailed && account.primaryAction === "choose_api_key" && (
            <label className="account-gate-choice">
              <span>{t("account.api_key")}</span>
              <select
                autoFocus
                className="focus-ring"
                value=""
                disabled={disabled || account.apiKeys.length === 0}
                onChange={(event) => {
                  if (event.target.value) onSelectApiKey(event.target.value);
                }}
              >
                <option value="">{t("account.choose_key")}</option>
                {account.apiKeys.map((key) => (
                  <option key={key.selectionId} value={key.selectionId}>
                    {key.name || key.selectionId}
                    {key.suffix ? ` · ${key.suffix}` : ""}
                  </option>
                ))}
              </select>
            </label>
          )}

          {!connectionFailed && account.primaryAction === "choose_model" && (
            <label className="account-gate-choice">
              <span>{t("account.model")}</span>
              <select
                autoFocus
                className="focus-ring"
                value=""
                disabled={disabled || account.models.length === 0}
                onChange={(event) => {
                  if (event.target.value) onSelectModel(event.target.value);
                }}
              >
                <option value="">{t("account.choose_model")}</option>
                {account.models.map((model) => (
                  <option key={model.selectionId} value={model.selectionId}>
                    {model.displayName || model.selectionId}
                  </option>
                ))}
              </select>
            </label>
          )}

          <div className="account-gate-actions">
            {connectionFailed && connectionRetryable ? (
              <button
                autoFocus
                className="primary-button focus-ring"
                disabled={reconnecting}
                onClick={onReconnect}
              >
                {reconnecting
                  ? t("connection.retrying")
                  : t("connection.retry")}
              </button>
            ) : connectionFailed ? null : (
              <>
                {account.primaryAction === "sign_in" && (
                  <button
                    autoFocus
                    className="primary-button focus-ring"
                    disabled={disabled}
                    onClick={onBeginLogin}
                  >
                    {t("account.login")}
                  </button>
                )}
                {account.primaryAction === "reopen_login" && (
                  <button
                    className="primary-button focus-ring"
                    disabled={disabled}
                    onClick={onReopenLogin}
                  >
                    {t("account.reopen_login")}
                  </button>
                )}
                {account.primaryAction === "retry_catalog" && (
                  <button
                    className="primary-button focus-ring"
                    disabled={disabled}
                    onClick={onRetry}
                  >
                    {t("account.retry_preparation")}
                  </button>
                )}
                {account.primaryAction === "reauthenticate" && (
                  <button
                    className="primary-button focus-ring"
                    disabled={disabled}
                    onClick={onReauthenticate}
                  >
                    {t("account.reauthenticate")}
                  </button>
                )}
                {reauthenticationRequired && (
                  <button
                    ref={signOut}
                    className="text-button focus-ring"
                    disabled={disabled}
                    onClick={() => setConfirmSignOut(true)}
                  >
                    {t("account.logout_short")}
                  </button>
                )}
                {account.canCancel && (
                  <button
                    className="text-button focus-ring"
                    disabled={cancelDisabled}
                    onClick={onCancel}
                  >
                    {t("account.cancel")}
                  </button>
                )}
              </>
            )}
          </div>
          {reauthenticationRequired && confirmSignOut && (
            <div
              className="account-gate-signout-confirmation"
              role="group"
              aria-labelledby="account-gate-title"
              aria-describedby="account-gate-signout-confirmation-copy"
              onKeyDown={(event) => {
                if (event.key !== "Escape") return;
                event.preventDefault();
                closeSignOutConfirmation();
              }}
            >
              <p id="account-gate-signout-confirmation-copy">
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
                  disabled={disabled}
                  onClick={onLogout}
                >
                  {t("account.logout")}
                </button>
              </span>
            </div>
          )}

          {(connectionDiagnostic || account.safeDiagnostic) && (
            <details className="account-gate-details">
              <summary>{t("connection.details")}</summary>
              <p>
                {connectionDiagnostic && connectionSourceId
                  ? `${t(connectionSourceId)}: `
                  : ""}
                {connectionDiagnostic || account.safeDiagnostic}
              </p>
            </details>
          )}
          <div className="account-gate-meta">
            <span>{t("account.gate.privacy")}</span>
            <span aria-live="polite">{notice}</span>
          </div>
        </div>
      </section>
    </main>
  );
}
