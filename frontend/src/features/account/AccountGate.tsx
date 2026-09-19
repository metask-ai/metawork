import { useRef, useState } from "react";

import type { AccountView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { WindowControls } from "../../components/ui/WindowControls.tsx";
import { WindowTitlebar } from "../../components/ui/WindowTitlebar.tsx";
import { bindWindowTitlebar } from "../../bridge/window-chrome.ts";
import { useI18n, type Locale, type MessageId } from "../../i18n/context.ts";
import { AboutMetaWorkDialog } from "./AboutMetaWorkDialog.tsx";

type Props = {
  account: AccountView;
  beginLoginDisabled: boolean;
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
  onCancel: () => void;
};

export function AccountGate({
  account,
  beginLoginDisabled,
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
  onCancel,
}: Props) {
  const { locale, setLocale, t } = useI18n();
  const aboutTrigger = useRef<HTMLButtonElement>(null);
  const [aboutOpen, setAboutOpen] = useState(false);
  const authorizing = account.state === "authorizing";
  const signedOut = account.state === "signed_out";
  const title = signedOut
    ? t("account.sign_in_required.title")
    : authorizing
      ? t("account.authorizing.title")
      : t("account.checking.title");
  const body = signedOut
    ? t("account.sign_in_required.body")
    : authorizing
      ? t("account.authorizing.body")
      : t("account.checking.body");

  return (
    <main className="account-gate" data-readiness={account.state}>
      <WindowTitlebar ref={bindWindowTitlebar} className="account-gate-toolbar">
        <div className="account-gate-brand" aria-label={t("app.name")}>
          <span className="brand-mark" aria-hidden="true">
            M
          </span>
          <span>{t("app.name")}</span>
        </div>
        <div className="account-gate-toolbar-actions">
          <label className="locale-control">
            <span className="sr-only">{t("app.language")}</span>
            <SelectionMenu
              ariaLabel={t("app.language")}
              value={locale}
              placeholder={t("app.language")}
              disabled={false}
              triggerClassName="account-gate-locale-trigger"
              contentClassName="account-gate-locale-menu"
              options={[
                { value: "en-US", label: t("app.language.en-US") },
                { value: "zh-CN", label: t("app.language.zh-CN") },
                ...(import.meta.env.DEV
                  ? [{ value: "pseudo", label: t("app.language.pseudo") }]
                  : []),
              ]}
              onValueChange={(nextLocale) => setLocale(nextLocale as Locale)}
            />
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
              <Button
                autoFocus
                type="button"
                variant="primary"
                size="lg"
                disabled={reconnecting}
                onClick={onReconnect}
              >
                {reconnecting
                  ? t("connection.retrying")
                  : t("connection.retry")}
              </Button>
            ) : signedOut ? (
              <Button
                autoFocus
                type="button"
                variant="primary"
                size="lg"
                disabled={beginLoginDisabled}
                onClick={onBeginLogin}
              >
                {t("account.login")}
              </Button>
            ) : (
              authorizing &&
              account.canCancel && (
                <Button
                  type="button"
                  variant="ghost"
                  size="md"
                  className="text-button"
                  disabled={cancelDisabled}
                  onClick={onCancel}
                >
                  {t("account.cancel")}
                </Button>
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
          <button
            ref={aboutTrigger}
            type="button"
            className="account-gate-about focus-ring"
            onClick={() => setAboutOpen(true)}
          >
            <Icon name="info" />
            {t("about.menu_item")}
          </button>
        </div>
      </section>
      <AboutMetaWorkDialog
        open={aboutOpen}
        onOpenChange={(nextOpen) => {
          setAboutOpen(nextOpen);
          if (!nextOpen)
            window.requestAnimationFrame(() => aboutTrigger.current?.focus());
        }}
      />
    </main>
  );
}
