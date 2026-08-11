import type { AccountView } from "../../bridge/contracts.ts";
import { WindowControls } from "../../components/ui/WindowControls.tsx";
import { WindowTitlebar } from "../../components/ui/WindowTitlebar.tsx";
import { useI18n, type Locale, type MessageId } from "../../i18n/context.ts";

type Props = {
  account: AccountView;
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
  onCancel: () => void;
};

export function AccountGate({
  account,
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
  onCancel,
}: Props) {
  const { locale, setLocale, t } = useI18n();
  const authorizing = account.state === "authorizing";
  const title = authorizing
    ? t("account.authorizing.title")
    : t("account.checking.title");
  const body = authorizing
    ? t("account.authorizing.body")
    : t("account.checking.body");

  return (
    <main className="account-gate" data-readiness={account.state}>
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
            {connectionFailed ? t(connectionTitleId) : title}
          </h1>
          <p
            className="account-gate-body"
            aria-live={connectionFailed ? "assertive" : "polite"}
            role={connectionFailed ? "alert" : "status"}
          >
            {connectionFailed ? t(connectionHelpId) : body}
          </p>

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
            ) : (
              authorizing &&
              account.canCancel && (
                <button
                  className="text-button focus-ring"
                  disabled={cancelDisabled}
                  onClick={onCancel}
                >
                  {t("account.cancel")}
                </button>
              )
            )}
          </div>

          {(connectionDiagnostic || account.safeDiagnostic) && (
            <p className="account-gate-diagnostic">
              {connectionDiagnostic || account.safeDiagnostic}
            </p>
          )}
          {notice && <p className="account-gate-notice">{notice}</p>}
          {connectionSourceId && connectionFailed && (
            <p className="account-gate-source">{t(connectionSourceId)}</p>
          )}
          <p className="account-gate-security">{t("account.gate.privacy")}</p>
        </div>
      </section>
    </main>
  );
}
