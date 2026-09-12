import {
  skillSourceBrands,
  type SkillSourceBrand,
  type SkillSourceDiscovery,
  type SkillSourceSettings,
} from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { Checkbox } from "../../components/ui/checkbox.tsx";
import { useI18n } from "../../i18n/context.ts";

export function SkillSourceControls({
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
  onSetEnabled: (
    brand: SkillSourceBrand,
    enabled: boolean,
    revision: string,
  ) => void;
  onRecover: (action: "reread" | "reset", token: string) => void;
}) {
  const { t } = useI18n();
  const rootErrors =
    discovery?.filter((entry) => entry.state === "error") ?? [];
  return (
    <section
      className="skill-source-controls"
      aria-label={t("skills.sources.title")}
      aria-busy={busy}
    >
      <div
        className="skill-source-options"
        role="group"
        aria-label={t("skills.sources.title")}
      >
        <span>{t("skills.sources.title")}</span>
        {skillSourceBrands.map((brand) => {
          const personal = settings.entries.find(
            (entry) => entry.sourceId === `compat.${brand}.user`,
          )!;
          const project = settings.entries.find(
            (entry) => entry.sourceId === `compat.${brand}.workspace`,
          )!;
          const unknown = personal.enabled === null || project.enabled === null;
          const partial = !unknown && personal.enabled !== project.enabled;
          const canSet =
            !unknown &&
            personal.canSetEnabled &&
            project.canSetEnabled &&
            settings.revision !== null &&
            !busy &&
            !disabled;
          return (
            <label key={brand} className="skill-source-option">
              <Checkbox.Root
                checked={personal.enabled === true && project.enabled === true}
                indeterminate={unknown || partial}
                disabled={!canSet}
                onCheckedChange={(enabled) => {
                  if (canSet && settings.revision !== null)
                    onSetEnabled(brand, enabled, settings.revision);
                }}
              >
                <Checkbox.Indicator aria-hidden="true">
                  {unknown || partial ? "−" : "✓"}
                </Checkbox.Indicator>
              </Checkbox.Root>
              <span>{brand === "claude" ? "Claude" : "Codex"}</span>
              {(unknown || partial) && (
                <small>
                  {t(
                    unknown
                      ? "skills.sources.unknown"
                      : "skills.sources.partial",
                  )}
                </small>
              )}
            </label>
          );
        })}
        {busy && <span role="status">{t("skills.sources.saving")}</span>}
      </div>
      <p className="skill-source-hint">{t("skills.sources.hint")}</p>
      {error && (
        <p className="skill-enablement-error" role="alert">
          {error}
        </p>
      )}
      {settings.health !== "ready" && (
        <div className="skill-source-recovery" role="status">
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
      {rootErrors.length > 0 && (
        <div className="skill-source-errors" role="status">
          <p>
            {contextLabel} · {t("skills.sources.state.error")}
          </p>
          <ul>
            {rootErrors.map((entry) => (
              <li key={entry.sourceId}>
                {t(`skills.sources.root.${entry.sourceId}`)}
                {entry.reason !== null &&
                  ` · ${t(`skills.sources.reason.${entry.reason}`)}`}
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
