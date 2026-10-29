import { Button } from "../../components/ui/button.tsx";
import { BrandLogo } from "../../components/ui/BrandLogo.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { WindowControls } from "../../components/ui/WindowControls.tsx";
import { WindowTitlebar } from "../../components/ui/WindowTitlebar.tsx";
import { bindWindowTitlebar } from "../../bridge/window-chrome.ts";
import { useI18n, type Locale, type MessageId } from "../../i18n/context.ts";

export function ConnectionFailureScreen({
  titleId,
  helpId,
  sourceId,
  diagnostic,
  retryable,
  retrying,
  onRetry,
}: {
  titleId: MessageId;
  helpId: MessageId;
  sourceId?: MessageId;
  diagnostic?: string;
  retryable: boolean;
  retrying: boolean;
  onRetry: () => void;
}) {
  const { locale, setLocale, t } = useI18n();

  return (
    <main className="connection-failure-screen">
      <WindowTitlebar
        ref={bindWindowTitlebar}
        className="connection-failure-toolbar"
      >
        <div className="connection-failure-brand" aria-label={t("app.name")}>
          <BrandLogo label={t("app.name")} />
        </div>
        <div
          className="connection-failure-toolbar-actions"
          data-native-window-drag-exclude=""
        >
          <label className="locale-control">
            <span className="sr-only">{t("app.language")}</span>
            <SelectionMenu
              ariaLabel={t("app.language")}
              value={locale}
              placeholder={t("app.language")}
              disabled={false}
              triggerClassName="connection-failure-locale-trigger"
              contentClassName="connection-failure-locale-menu"
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
        className="connection-failure-stage"
        aria-labelledby="connection-failure-title"
      >
        <div className="connection-failure-content">
          <span className="connection-failure-symbol" aria-hidden="true">
            <Icon name="warning" />
          </span>
          <h1 id="connection-failure-title">{t(titleId)}</h1>
          <p className="connection-failure-body" role="alert">
            {t(helpId)}
          </p>
          {retryable && (
            <Button
              autoFocus
              type="button"
              variant="primary"
              size="lg"
              disabled={retrying}
              onClick={onRetry}
            >
              {t(retrying ? "connection.retrying" : "connection.retry")}
            </Button>
          )}
          {(sourceId || diagnostic) && (
            <details className="connection-failure-details">
              <summary>{t("connection.details")}</summary>
              <p>
                {sourceId ? `${t(sourceId)}: ` : ""}
                {diagnostic}
              </p>
            </details>
          )}
        </div>
      </section>
    </main>
  );
}
