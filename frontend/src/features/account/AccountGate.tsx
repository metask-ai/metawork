import type { AccountView } from "../../bridge/contracts.ts";
import { useI18n, type Locale } from "../../i18n/context.ts";
import { accountErrorText } from "./account-copy.ts";

type Props = {
  account: AccountView;
  disabled: boolean;
  cancelDisabled: boolean;
  connectionFailed: boolean;
  connectionDiagnostic?: string;
  reconnecting: boolean;
  notice: string;
  onReconnect: () => void;
  onBeginLogin: () => void;
  onReopenLogin: () => void;
  onReauthenticate: () => void;
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
  connectionDiagnostic,
  reconnecting,
  notice,
  onReconnect,
  onBeginLogin,
  onReopenLogin,
  onReauthenticate,
  onCancel,
  onRetry,
  onSelectApiKey,
  onSelectModel,
}: Props) {
  const { locale, setLocale, t } = useI18n();
  if (account.readiness === "ready") return null;

  const operation =
    account.operation === "none"
      ? null
      : t(`account.operation.${account.operation}`);
  const hasError =
    account.readiness !== "restart_required" &&
    account.errorCode !== "none" &&
    account.errorCode !== "user_cancelled";
  const body = hasError
    ? accountErrorText(account.errorCode, t)
    : operation ||
      (account.errorCode === "user_cancelled"
        ? t("account.cancelled")
        : t(`account.readiness.${account.readiness}.body`));

  return (
    <main className="account-gate" data-readiness={account.readiness}>
      <header className="account-gate-titlebar">
        <div className="account-gate-brand" aria-label={t("app.name")}>
          <span className="brand-mark" aria-hidden="true">
            M
          </span>
          <span>{t("app.name")}</span>
        </div>
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
      </header>

      <section
        className="account-gate-stage"
        aria-labelledby="account-gate-title"
      >
        <div className="account-gate-index" aria-hidden="true">
          <span className="account-gate-index-dot" />
          <span>{t("account.gate.path")}</span>
        </div>

        <div className="account-gate-content">
          <p className="account-gate-eyebrow">{t("account.gate.eyebrow")}</p>
          <h1 id="account-gate-title">
            {connectionFailed
              ? t("connection.failed")
              : t(`account.readiness.${account.readiness}.title`)}
          </h1>
          <p
            className="account-gate-body"
            aria-live={hasError || connectionFailed ? "assertive" : "polite"}
            role={hasError || connectionFailed ? "alert" : "status"}
          >
            {connectionFailed ? t("connection.failed_help") : body}
          </p>

          {!connectionFailed && account.displayName && (
            <p className="account-gate-identity">
              <span>{t("account.signed_in")}</span>
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
                  <option key={key.id} value={key.id}>
                    {key.name || key.id}
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
                  <option key={model.id} value={model.id}>
                    {model.displayName || model.id}
                  </option>
                ))}
              </select>
            </label>
          )}

          <div className="account-gate-actions">
            {connectionFailed ? (
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
            ) : (
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

          {(connectionDiagnostic || account.safeDiagnostic) && (
            <details className="account-gate-details">
              <summary>{t("connection.details")}</summary>
              <p>{connectionDiagnostic || account.safeDiagnostic}</p>
            </details>
          )}
        </div>
      </section>

      <footer className="account-gate-footer">
        <span>{t("account.gate.privacy")}</span>
        <span aria-live="polite">{notice}</span>
      </footer>
    </main>
  );
}
