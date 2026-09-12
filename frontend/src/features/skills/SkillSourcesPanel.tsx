import type {
  SkillSourceDiscovery,
  SkillSourceId,
  SkillSourceSettings,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Checkbox } from "../../components/ui/checkbox.tsx";
import { useI18n } from "../../i18n/context.ts";

export function SkillSourcesPanel({
  settings,
  discovery,
  contextLabel,
  busy,
  error,
  disabled,
  onSetEnabled,
  onRecover,
}: {
  settings: SkillSourceSettings;
  discovery: SkillSourceDiscovery;
  contextLabel: string;
  busy: boolean;
  error: string | null;
  disabled: boolean;
  onSetEnabled: (id: SkillSourceId, enabled: boolean, revision: string) => void;
  onRecover: (action: "reread" | "reset", token: string) => void;
}) {
  const { t } = useI18n();
  return (
    <div className="skill-sources-panel" aria-busy={busy}>
      <p>{t("skills.sources.explanation")}</p>
      <p>{t("skills.sources.tasks")}</p>
      <p>{t("skills.sources.compatibility")}</p>
      <p className="skill-sources-default">
        <code>.agents/skills</code> · {t("skills.sources.default")}
      </p>
      {(["claude", "codex"] as const).map((ecosystem) => (
        <fieldset key={ecosystem}>
          <legend>{ecosystem === "claude" ? "Claude" : "Codex"}</legend>
          {(["user", "workspace"] as const).map((scope) => {
            const id: SkillSourceId = `compat.${ecosystem}.${scope}`;
            const entry = settings.entries.find(
              (candidate) => candidate.sourceId === id,
            )!;
            return (
              <label key={id} className="skill-source-option">
                <Checkbox.Root
                  checked={entry.enabled === true}
                  indeterminate={entry.enabled === null}
                  disabled={disabled || busy || !entry.canSetEnabled}
                  onCheckedChange={(enabled) => {
                    if (
                      settings.revision !== null &&
                      entry.canSetEnabled &&
                      !busy &&
                      !disabled
                    )
                      onSetEnabled(id, enabled, settings.revision);
                  }}
                >
                  <Checkbox.Indicator>
                    {entry.enabled === null ? "−" : "✓"}
                  </Checkbox.Indicator>
                </Checkbox.Root>
                <span>
                  {t(`skills.sources.scope.${scope}`)}
                  <small>
                    <code>.{ecosystem}/skills</code>
                    {entry.enabled === null &&
                      ` · ${t("skills.sources.unknown")}`}
                  </small>
                </span>
              </label>
            );
          })}
        </fieldset>
      ))}
      {busy && <p role="status">{t("skills.sources.saving")}</p>}
      {error && (
        <p className="skill-drawer-error" role="alert">
          {error}
        </p>
      )}
      {settings.health !== "ready" && (
        <div className="skill-drawer-notice" role="status">
          <p>{t(`skills.sources.health.${settings.health}`)}</p>
          {settings.recovery.canReread && (
            <Button
              variant="secondary"
              disabled={busy || disabled}
              onClick={() => onRecover("reread", settings.recovery.token!)}
            >
              {t("skills.sources.reread")}
            </Button>
          )}
          {settings.recovery.canReset && (
            <>
              <p>{t("skills.sources.reset_body")}</p>
              <Button
                variant="secondary"
                disabled={busy || disabled}
                onClick={() => onRecover("reset", settings.recovery.token!)}
              >
                {t("skills.sources.reset")}
              </Button>
            </>
          )}
        </div>
      )}
      <section
        className="skill-source-discovery"
        aria-label={t("skills.sources.discovery")}
      >
        <h3>{t("skills.sources.discovery")}</h3>
        <p>{contextLabel}</p>
        <p>{t("skills.sources.check_note")}</p>
        {discovery === null ? (
          <p>{t("skills.sources.not_checked")}</p>
        ) : (
          <ul>
            {discovery.map((entry) => (
              <li key={entry.sourceId}>
                <span>{t(`skills.sources.root.${entry.sourceId}`)}</span>
                <span>
                  {t(`skills.sources.state.${entry.state}`)}
                  {entry.reason !== null &&
                    ` · ${t(`skills.sources.reason.${entry.reason}`)}`}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
