import { useEffect, useId, useMemo, useState } from "react";

import type { SkillCatalogView } from "../../bridge/contracts.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import {
  resolveSlashCandidates,
  type SlashCandidate,
  type SlashCommandDisabledReason,
  type SlashCommandState,
  type SlashInput,
} from "./slash.ts";

const commandMessageIds: Record<
  SlashCommandState["name"],
  { label: MessageId; description: MessageId }
> = {
  new: { label: "slash.command.new", description: "slash.command.new_help" },
  compact: {
    label: "slash.command.compact",
    description: "slash.command.compact_help",
  },
};

const disabledReasonMessageIds: Record<SlashCommandDisabledReason, MessageId> =
  {
    already_new_task: "slash.disabled_already_new_task",
    task_busy: "slash.disabled_task_busy",
    no_history: "slash.disabled_no_history",
    unavailable: "slash.disabled_unavailable",
  };

export function SlashMenu({
  input,
  commands,
  catalog,
  skillsOnly,
  activeKey,
  onActiveKey,
  onChoose,
  onRefresh,
}: {
  input: SlashInput;
  commands: readonly SlashCommandState[];
  catalog: SkillCatalogView;
  skillsOnly: boolean;
  activeKey: string | null;
  onActiveKey: (key: string | null) => void;
  onChoose: (candidate: SlashCandidate) => void;
  onRefresh: () => void;
}) {
  const { t } = useI18n();
  const headingId = useId();
  const candidates = useMemo(
    () =>
      resolveSlashCandidates({
        input,
        commands,
        catalog,
        skillsOnly,
      }),
    [catalog, commands, input, skillsOnly],
  );
  const [pointerInside, setPointerInside] = useState(false);

  useEffect(() => {
    if (activeKey && candidates.some((item) => item.key === activeKey)) return;
    onActiveKey(candidates.find((item) => item.enabled)?.key ?? null);
  }, [activeKey, candidates, onActiveKey]);

  const commandCandidates = candidates.filter(
    (candidate) => candidate.kind === "command",
  );
  const skillCandidates = candidates.filter(
    (candidate) => candidate.kind === "skill",
  );
  const catalogUsable =
    catalog.availability === "ready" || catalog.availability === "degraded";

  function renderCandidate(candidate: SlashCandidate) {
    const label =
      candidate.kind === "command"
        ? t(commandMessageIds[candidate.name].label)
        : candidate.displayName || candidate.invocationName;
    const description =
      candidate.kind === "command"
        ? t(commandMessageIds[candidate.name].description)
        : candidate.description;
    return (
      <button
        id={`slash-option-${candidate.key.replaceAll(":", "-")}`}
        key={candidate.key}
        className="slash-option focus-ring"
        type="button"
        role="option"
        tabIndex={-1}
        aria-selected={activeKey === candidate.key}
        aria-disabled={!candidate.enabled}
        data-active={activeKey === candidate.key}
        data-disabled={!candidate.enabled || undefined}
        onPointerEnter={() => {
          setPointerInside(true);
          if (candidate.enabled) onActiveKey(candidate.key);
        }}
        onPointerLeave={() => setPointerInside(false)}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => {
          if (candidate.enabled) onChoose(candidate);
        }}
      >
        <span className="slash-option-invocation">{candidate.invocation}</span>
        <span className="slash-option-copy">
          <strong>{label}</strong>
          <span>
            {candidate.kind === "command" && candidate.disabledReason
              ? t(disabledReasonMessageIds[candidate.disabledReason])
              : candidate.disabledReason ||
                description ||
                t("slash.no_description")}
          </span>
        </span>
      </button>
    );
  }

  return (
    <div
      className="slash-menu"
      role="listbox"
      id="composer-slash-menu"
      aria-labelledby={headingId}
      data-pointer-inside={pointerInside || undefined}
    >
      <div className="slash-menu-heading">
        <span id={headingId}>{t("slash.title")}</span>
        <kbd>↑↓</kbd>
        <kbd>Enter</kbd>
        <kbd>Esc</kbd>
      </div>
      {!skillsOnly && commandCandidates.length > 0 && (
        <section
          className="slash-group"
          role="group"
          aria-label={t("slash.group.commands")}
        >
          <p>{t("slash.group.commands")}</p>
          {commandCandidates.map(renderCandidate)}
        </section>
      )}
      <section
        className="slash-group"
        role="group"
        aria-label={t("slash.group.skills")}
      >
        <p>{t("slash.group.skills")}</p>
        {!catalogUsable ? (
          <div className="slash-catalog-state">
            <span>
              {t(
                catalog.availability === "loading"
                  ? "slash.skills_loading"
                  : "slash.skills_unavailable",
              )}
            </span>
            <button
              type="button"
              className="slash-refresh focus-ring"
              onMouseDown={(event) => event.preventDefault()}
              onClick={onRefresh}
            >
              {t("slash.refresh")}
            </button>
          </div>
        ) : skillCandidates.length > 0 ? (
          skillCandidates.map(renderCandidate)
        ) : (
          <p className="slash-empty">
            {t(skillsOnly ? "slash.no_skills" : "slash.no_matches")}
          </p>
        )}
      </section>
    </div>
  );
}
