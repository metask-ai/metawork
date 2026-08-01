import { useEffect, useMemo, useState } from "react";

import type {
  ScheduledTaskMutation,
  ScheduledTaskView,
  TaskRunInput,
  WorkbenchSnapshot,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

type Draft = {
  title: string;
  targetKind: "default" | "explicit";
  workspaceId: string;
  inputKind: "text" | "skill";
  text: string;
  skillId: string;
  argumentValues: string[];
  recurrenceKind: "once" | "interval";
  start: string;
  every: string;
  unit: "minutes" | "hours" | "days";
};

type SuggestionKind = "daily" | "weekly" | "followup";

function localDateTime(unixSeconds: number) {
  const date = new Date(unixSeconds * 1000);
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function nextLocalOccurrence(hour: number, minute: number, weekday?: number) {
  const now = new Date();
  const next = new Date(now);
  next.setSeconds(0, 0);
  next.setHours(hour, minute, 0, 0);
  if (weekday === undefined) {
    if (next <= now) next.setDate(next.getDate() + 1);
  } else {
    const days = (weekday - next.getDay() + 7) % 7;
    next.setDate(next.getDate() + days);
    if (next <= now) next.setDate(next.getDate() + 7);
  }
  return localDateTime(Math.floor(next.getTime() / 1000));
}

function defaultDraft(snapshot: WorkbenchSnapshot): Draft {
  const userWorkspaces = snapshot.workspaces.filter(
    (workspace) => workspace.origin === "user",
  );
  return {
    title: "",
    targetKind: snapshot.capabilities.managedWorkspaces
      ? "default"
      : "explicit",
    workspaceId: snapshot.selectedWorkspaceId ?? userWorkspaces[0]?.id ?? "",
    inputKind: "text",
    text: "",
    skillId: "",
    argumentValues: [],
    recurrenceKind: "once",
    start: localDateTime(Math.floor(Date.now() / 1000) + 3600),
    every: "1",
    unit: "hours",
  };
}

function draftFromTask(task: ScheduledTaskView): Draft {
  const start =
    task.recurrence.kind === "once"
      ? task.recurrence.atUnixSeconds
      : task.recurrence.startAtUnixSeconds;
  const everySeconds =
    task.recurrence.kind === "interval"
      ? Number(task.recurrence.everySeconds)
      : 3600;
  const unit =
    everySeconds % 86_400 === 0
      ? "days"
      : everySeconds % 3600 === 0
        ? "hours"
        : "minutes";
  const divisor = unit === "days" ? 86_400 : unit === "hours" ? 3600 : 60;
  return {
    title: task.title,
    targetKind: task.target.kind,
    workspaceId: task.target.kind === "explicit" ? task.target.workspaceId : "",
    inputKind: task.input.kind,
    text: task.input.kind === "text" ? task.input.text : "",
    skillId: task.input.kind === "skill" ? task.input.skillId : "",
    argumentValues:
      task.input.kind === "skill" ? task.input.argumentValues : [],
    recurrenceKind: task.recurrence.kind,
    start: localDateTime(Number(start)),
    every: String(everySeconds / divisor),
    unit,
  };
}

function toMutation(
  snapshot: WorkbenchSnapshot,
  draft: Draft,
): ScheduledTaskMutation | null {
  const workspace =
    draft.targetKind === "explicit"
      ? snapshot.workspaces.find(
          (candidate) =>
            candidate.id === draft.workspaceId && candidate.origin === "user",
        )
      : null;
  const start = Math.floor(new Date(draft.start).getTime() / 1000);
  if (!draft.title.trim() || !Number.isSafeInteger(start) || start <= 0)
    return null;
  let input: TaskRunInput;
  if (draft.inputKind === "text") {
    if (!draft.text.trim()) return null;
    if (
      draft.targetKind === "default" &&
      !snapshot.capabilities.managedWorkspaces
    )
      return null;
    if (draft.targetKind === "explicit" && !workspace) return null;
    input = { kind: "text", text: draft.text.trim() };
  } else {
    if (draft.targetKind !== "explicit" || !workspace) return null;
    const skill = workspace.skillCatalog.skills.find(
      (candidate) => candidate.skillId === draft.skillId,
    );
    const revision = workspace.skillCatalog.revision;
    if (!skill || !revision) return null;
    input = {
      kind: "skill",
      skillId: skill.skillId,
      catalogRevision: revision,
      argumentValues: draft.argumentValues,
    };
  }
  const every = Number(draft.every);
  const unitSeconds =
    draft.unit === "days" ? 86_400 : draft.unit === "hours" ? 3600 : 60;
  if (
    draft.recurrenceKind === "interval" &&
    (!Number.isSafeInteger(every) || every <= 0)
  )
    return null;
  return {
    title: draft.title.trim(),
    target:
      draft.targetKind === "default"
        ? { kind: "default" }
        : {
            kind: "explicit",
            workspaceId: workspace!.id,
            expectedWorkspaceEpoch: workspace!.epoch,
          },
    expectedExecutionGeneration: snapshot.account.executionGeneration,
    input,
    recurrence:
      draft.recurrenceKind === "once"
        ? { kind: "once", atUnixSeconds: String(start) }
        : {
            kind: "interval",
            startAtUnixSeconds: String(start),
            everySeconds: String(every * unitSeconds),
          },
  };
}

function formatTime(
  unixSeconds: string | null,
  locale: string,
  fallback: string,
) {
  if (unixSeconds === null) return fallback;
  return new Intl.DateTimeFormat(locale, {
    month: "short",
    day: "numeric",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(Number(unixSeconds) * 1000));
}

export function ScheduledTasksPage({
  snapshot,
  disabled,
  onCreate,
  onUpdate,
  onSetEnabled,
  onRunNow,
  onDelete,
  onOpenTask,
}: {
  snapshot: WorkbenchSnapshot;
  disabled: boolean;
  onCreate: (input: ScheduledTaskMutation) => Promise<unknown>;
  onUpdate: (
    id: string,
    epoch: string,
    input: ScheduledTaskMutation,
  ) => Promise<unknown>;
  onSetEnabled: (
    id: string,
    epoch: string,
    enabled: boolean,
  ) => Promise<unknown>;
  onRunNow: (id: string, epoch: string) => Promise<{ taskId: string }>;
  onDelete: (id: string, epoch: string) => Promise<void>;
  onOpenTask: (taskId: string) => void;
}) {
  const { locale, t } = useI18n();
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [draft, setDraft] = useState(() => defaultDraft(snapshot));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const selected =
    snapshot.scheduledTasks.find((task) => task.id === selectedId) ?? null;
  const userWorkspaces = snapshot.workspaces.filter(
    (candidate) => candidate.origin === "user",
  );
  const workspace =
    draft.targetKind === "explicit"
      ? userWorkspaces.find((candidate) => candidate.id === draft.workspaceId)
      : undefined;
  const canCreateDefinition =
    snapshot.capabilities.managedWorkspaces || userWorkspaces.length > 0;
  const selectedSkill = workspace?.skillCatalog.skills.find(
    (skill) => skill.skillId === draft.skillId,
  );
  const mutation = useMemo(
    () => toMutation(snapshot, draft),
    [snapshot, draft],
  );
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const filteredTasks = snapshot.scheduledTasks.filter((task) => {
    if (!normalizedQuery) return true;
    const instruction =
      task.input.kind === "text"
        ? task.input.text
        : `/${task.input.skillId} ${task.input.argumentValues.join(" ")}`;
    return `${task.title} ${instruction}`
      .toLocaleLowerCase(locale)
      .includes(normalizedQuery);
  });
  const groups = [
    {
      key: "ongoing",
      label: t("scheduled.section.ongoing"),
      tasks: filteredTasks.filter((task) => task.health === "ready"),
    },
    {
      key: "attention",
      label: t("scheduled.section.needs_attention"),
      tasks: filteredTasks.filter((task) => task.health === "needs_attention"),
    },
    {
      key: "paused",
      label: t("scheduled.section.paused"),
      tasks: filteredTasks.filter((task) => task.health === "paused"),
    },
    {
      key: "completed",
      label: t("scheduled.section.completed"),
      tasks: filteredTasks.filter((task) => task.health === "completed"),
    },
  ].filter((group) => group.tasks.length > 0);

  useEffect(() => {
    if (!selectedId) return;
    const current = snapshot.scheduledTasks.find(
      (task) => task.id === selectedId,
    );
    if (!current) {
      setSelectedId(null);
      setCreating(false);
    }
  }, [selectedId, snapshot.scheduledTasks]);

  function beginCreate(seed?: Partial<Draft>) {
    setCreating(true);
    setSelectedId(null);
    setDraft({ ...defaultDraft(snapshot), ...seed });
    setError(null);
  }

  function beginSuggestion(kind: SuggestionKind) {
    const presets: Record<SuggestionKind, Partial<Draft>> = {
      daily: {
        title: t("scheduled.suggestion.daily.title"),
        text: t("scheduled.suggestion.daily.prompt"),
        recurrenceKind: "interval",
        start: nextLocalOccurrence(8, 0),
        every: "1",
        unit: "days",
      },
      weekly: {
        title: t("scheduled.suggestion.weekly.title"),
        text: t("scheduled.suggestion.weekly.prompt"),
        recurrenceKind: "interval",
        start: nextLocalOccurrence(16, 0, 5),
        every: "7",
        unit: "days",
      },
      followup: {
        title: t("scheduled.suggestion.followup.title"),
        text: t("scheduled.suggestion.followup.prompt"),
        recurrenceKind: "interval",
        start: nextLocalOccurrence(9, 0),
        every: "1",
        unit: "days",
      },
    };
    beginCreate(presets[kind]);
  }

  function edit(task: ScheduledTaskView) {
    setSelectedId(task.id);
    setCreating(false);
    setDraft(draftFromTask(task));
    setError(null);
  }

  async function submit() {
    if (!mutation || busy) return;
    setBusy(true);
    setError(null);
    try {
      if (selected) await onUpdate(selected.id, selected.epoch, mutation);
      else await onCreate(mutation);
      setCreating(false);
      setSelectedId(null);
      setQuery("");
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : t("scheduled.error"));
    } finally {
      setBusy(false);
    }
  }

  async function action(run: () => Promise<unknown>) {
    setBusy(true);
    setError(null);
    try {
      await run();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : t("scheduled.error"));
    } finally {
      setBusy(false);
    }
  }

  function recurrenceLabel(task: ScheduledTaskView) {
    if (task.recurrence.kind === "once")
      return formatTime(
        task.recurrence.atUnixSeconds,
        locale,
        t("scheduled.no_next_run"),
      );
    const seconds = Number(task.recurrence.everySeconds);
    if (seconds === 3600) return t("scheduled.repeat.hourly");
    if (seconds === 86_400) return t("scheduled.repeat.daily");
    if (seconds === 604_800) return t("scheduled.repeat.weekly");
    return `${t("scheduled.every")} ${seconds / 60} ${t("scheduled.minutes")}`;
  }

  function occurrenceLabel(
    occurrence: ScheduledTaskView["occurrences"][number],
  ) {
    if (occurrence.taskOutcome === "completed")
      return t("scheduled.occurrence.completed");
    if (occurrence.taskOutcome) return t("scheduled.occurrence.failed");
    if (occurrence.result === "submitted")
      return t("scheduled.occurrence.running");
    if (occurrence.result === "skipped")
      return t("scheduled.occurrence.skipped");
    if (occurrence.result === "rejected")
      return t("scheduled.occurrence.rejected");
    return t("scheduled.occurrence.starting");
  }

  const editorOpen = creating || selected !== null;
  const suggestions = [
    {
      kind: "daily" as const,
      mark: "◔",
      title: t("scheduled.suggestion.daily.title"),
      schedule: t("scheduled.suggestion.daily.schedule"),
      body: t("scheduled.suggestion.daily.body"),
    },
    {
      kind: "weekly" as const,
      mark: "▣",
      title: t("scheduled.suggestion.weekly.title"),
      schedule: t("scheduled.suggestion.weekly.schedule"),
      body: t("scheduled.suggestion.weekly.body"),
    },
    {
      kind: "followup" as const,
      mark: "⌁",
      title: t("scheduled.suggestion.followup.title"),
      schedule: t("scheduled.suggestion.followup.schedule"),
      body: t("scheduled.suggestion.followup.body"),
    },
  ];

  return (
    <section className="scheduled-page" aria-labelledby="scheduled-title">
      <div className="scheduled-page-inner">
        <header className="scheduled-header">
          <div>
            <div className="scheduled-title-line">
              <h1 id="scheduled-title">{t("scheduled.title")}</h1>
              {snapshot.capabilities.backgroundScheduleWake && (
                <span className="scheduled-background-state">
                  <span aria-hidden="true" />
                  {t("scheduled.background_ready")}
                </span>
              )}
            </div>
            <p>{t("scheduled.subtitle")}</p>
          </div>
          <button
            className="primary-button focus-ring"
            disabled={disabled || !canCreateDefinition}
            onClick={() => beginCreate()}
          >
            <Icon name="plus" />
            {t("scheduled.new")}
          </button>
        </header>

        {snapshot.capabilities.scheduledTaskPersistenceHealth !== "ready" && (
          <div className="scheduled-capability-error" role="alert">
            <Icon name="warning" />
            <span>
              {t(
                `scheduled.persistence.${snapshot.capabilities.scheduledTaskPersistenceHealth}`,
              )}
            </span>
          </div>
        )}

        <label className="scheduled-search">
          <Icon name="search" />
          <span className="sr-only">{t("scheduled.search_placeholder")}</span>
          <input
            value={query}
            placeholder={t("scheduled.search_placeholder")}
            onChange={(event) => setQuery(event.target.value)}
          />
          {query && (
            <button
              className="focus-ring"
              aria-label={t("common.cancel")}
              onClick={() => setQuery("")}
            >
              <Icon name="close" />
            </button>
          )}
        </label>

        {snapshot.scheduledTasks.length === 0 ? (
          <div className="scheduled-starter">
            <h2>{t("scheduled.suggestions")}</h2>
            <div className="scheduled-suggestion-list">
              {suggestions.map((suggestion) => (
                <button
                  key={suggestion.kind}
                  className="scheduled-suggestion focus-ring"
                  disabled={
                    disabled || !snapshot.capabilities.managedWorkspaces
                  }
                  onClick={() => beginSuggestion(suggestion.kind)}
                >
                  <span
                    className="scheduled-suggestion-mark"
                    aria-hidden="true"
                  >
                    {suggestion.mark}
                  </span>
                  <span>
                    <strong>
                      {suggestion.title}
                      <small>{suggestion.schedule}</small>
                    </strong>
                    <span>{suggestion.body}</span>
                  </span>
                  <Icon name="plus" />
                </button>
              ))}
              <button
                className="scheduled-suggestion scheduled-suggestion-custom focus-ring"
                disabled={disabled || !snapshot.capabilities.managedWorkspaces}
                onClick={() =>
                  beginCreate({
                    title: query.trim().slice(0, 80),
                    text: query.trim(),
                  })
                }
              >
                <span className="scheduled-suggestion-mark" aria-hidden="true">
                  <Icon name="plus" />
                </span>
                <span>
                  <strong>{t("scheduled.suggestion.custom.title")}</strong>
                  <span>{t("scheduled.suggestion.custom.body")}</span>
                </span>
                <Icon name="chevron" />
              </button>
            </div>
          </div>
        ) : groups.length === 0 ? (
          <div className="scheduled-no-results">
            <Icon name="search" />
            <h2>{t("scheduled.no_matches")}</h2>
            <p>{t("scheduled.no_matches_body")}</p>
          </div>
        ) : (
          <div className="scheduled-groups">
            {groups.map((group) => (
              <section key={group.key} className="scheduled-group">
                <h2>{group.label}</h2>
                <ul className="scheduled-list">
                  {group.tasks.map((task) => {
                    const latestOccurrence = task.occurrences.at(-1);
                    return (
                      <li key={task.id} data-health={task.health}>
                        <button
                          className="scheduled-row-main focus-ring"
                          onClick={() => edit(task)}
                        >
                          <span
                            className="scheduled-row-status"
                            aria-hidden="true"
                          />
                          <span className="scheduled-row-copy">
                            <strong>{task.title}</strong>
                            <small>
                              {recurrenceLabel(task)}
                              <span aria-hidden="true"> · </span>
                              {task.input.kind === "skill"
                                ? `/${task.input.skillId}`
                                : task.input.text}
                            </small>
                          </span>
                          <span className="scheduled-row-next">
                            <small>
                              {t(`scheduled.health.${task.health}`)}
                            </small>
                            <time>
                              {formatTime(
                                task.nextRunAtUnixSeconds,
                                locale,
                                latestOccurrence
                                  ? occurrenceLabel(latestOccurrence)
                                  : t("scheduled.no_next_run"),
                              )}
                            </time>
                          </span>
                          <Icon name="chevron" />
                        </button>
                        <div className="scheduled-row-actions">
                          <button
                            className="text-button focus-ring"
                            disabled={disabled || busy}
                            onClick={() =>
                              void action(async () => {
                                const result = await onRunNow(
                                  task.id,
                                  task.epoch,
                                );
                                onOpenTask(result.taskId);
                              })
                            }
                          >
                            {t("scheduled.run_now")}
                          </button>
                          <button
                            className="text-button focus-ring"
                            disabled={
                              disabled ||
                              busy ||
                              task.health === "completed" ||
                              task.health === "needs_attention"
                            }
                            onClick={() =>
                              void action(() =>
                                onSetEnabled(
                                  task.id,
                                  task.epoch,
                                  !task.enabled,
                                ),
                              )
                            }
                          >
                            {t(
                              task.enabled
                                ? "scheduled.pause"
                                : "scheduled.resume",
                            )}
                          </button>
                        </div>
                      </li>
                    );
                  })}
                </ul>
              </section>
            ))}
          </div>
        )}
      </div>

      {editorOpen && (
        <div
          className="scheduled-editor-backdrop"
          onMouseDown={() => {
            if (busy) return;
            setCreating(false);
            setSelectedId(null);
            setError(null);
          }}
        >
          <aside
            className="scheduled-editor"
            role="dialog"
            aria-modal="true"
            aria-label={t("scheduled.editor")}
            onMouseDown={(event) => event.stopPropagation()}
          >
            <header>
              <div>
                <small>
                  {selected ? t("scheduled.editing") : t("scheduled.creating")}
                </small>
                <h2>{selected?.title || t("scheduled.new")}</h2>
              </div>
              <button
                className="icon-button focus-ring"
                aria-label={t("common.cancel")}
                onClick={() => {
                  setCreating(false);
                  setSelectedId(null);
                  setError(null);
                }}
              >
                <Icon name="close" />
              </button>
            </header>

            <div className="scheduled-editor-scroll">
              {selected && (
                <section className="scheduled-detail-summary">
                  <div>
                    <span>{t("scheduled.next_run")}</span>
                    <strong>
                      {formatTime(
                        selected.nextRunAtUnixSeconds,
                        locale,
                        t("scheduled.no_next_run"),
                      )}
                    </strong>
                  </div>
                  <div>
                    <span>{t("scheduled.status")}</span>
                    <strong>{t(`scheduled.health.${selected.health}`)}</strong>
                  </div>
                </section>
              )}

              <fieldset className="scheduled-editor-primary">
                <legend>{t("scheduled.what")}</legend>
                <div className="scheduled-segments">
                  {(["text", "skill"] as const).map((kind) => (
                    <button
                      key={kind}
                      type="button"
                      data-active={draft.inputKind === kind}
                      disabled={kind === "skill" && userWorkspaces.length === 0}
                      onClick={() =>
                        setDraft((value) => ({
                          ...value,
                          inputKind: kind,
                          targetKind:
                            kind === "skill" ? "explicit" : value.targetKind,
                          workspaceId:
                            kind === "skill" && !value.workspaceId
                              ? (snapshot.selectedWorkspaceId ??
                                userWorkspaces[0]?.id ??
                                "")
                              : value.workspaceId,
                          skillId: kind === "text" ? "" : value.skillId,
                          argumentValues:
                            kind === "text" ? [] : value.argumentValues,
                        }))
                      }
                    >
                      {t(`scheduled.input.${kind}`)}
                    </button>
                  ))}
                </div>
                {draft.inputKind === "text" ? (
                  <textarea
                    autoFocus={creating}
                    rows={6}
                    value={draft.text}
                    placeholder={t("scheduled.instruction_placeholder")}
                    onChange={(event) =>
                      setDraft((value) => ({
                        ...value,
                        text: event.target.value,
                      }))
                    }
                  />
                ) : (
                  <>
                    <select
                      value={draft.skillId}
                      onChange={(event) => {
                        const skill = workspace?.skillCatalog.skills.find(
                          (item) => item.skillId === event.target.value,
                        );
                        setDraft((value) => ({
                          ...value,
                          skillId: event.target.value,
                          argumentValues: skill
                            ? skill.argumentNames.map(() => "")
                            : [],
                        }));
                      }}
                    >
                      <option value="">{t("scheduled.choose_skill")}</option>
                      {workspace?.skillCatalog.skills.map((skill) => (
                        <option key={skill.skillId} value={skill.skillId}>
                          /{skill.invocationName}
                        </option>
                      ))}
                    </select>
                    {selectedSkill?.argumentNames.map((name, index) => (
                      <label
                        key={`${name}:${index}`}
                        className="scheduled-argument"
                      >
                        <span>{name}</span>
                        <input
                          value={draft.argumentValues[index] ?? ""}
                          onChange={(event) =>
                            setDraft((value) => {
                              const values = [...value.argumentValues];
                              values[index] = event.target.value;
                              return { ...value, argumentValues: values };
                            })
                          }
                        />
                      </label>
                    ))}
                  </>
                )}
              </fieldset>

              <fieldset>
                <legend>{t("scheduled.when")}</legend>
                <div className="scheduled-segments">
                  {(["once", "interval"] as const).map((kind) => (
                    <button
                      key={kind}
                      type="button"
                      data-active={draft.recurrenceKind === kind}
                      onClick={() =>
                        setDraft((value) => ({
                          ...value,
                          recurrenceKind: kind,
                        }))
                      }
                    >
                      {t(`scheduled.recurrence.${kind}`)}
                    </button>
                  ))}
                </div>
                <label>
                  <span>{t("scheduled.starts")}</span>
                  <input
                    type="datetime-local"
                    value={draft.start}
                    onChange={(event) =>
                      setDraft((value) => ({
                        ...value,
                        start: event.target.value,
                      }))
                    }
                  />
                </label>
                {draft.recurrenceKind === "interval" && (
                  <label>
                    <span>{t("scheduled.every")}</span>
                    <div className="scheduled-interval">
                      <input
                        type="number"
                        min="1"
                        step="1"
                        value={draft.every}
                        onChange={(event) =>
                          setDraft((value) => ({
                            ...value,
                            every: event.target.value,
                          }))
                        }
                      />
                      <select
                        value={draft.unit}
                        onChange={(event) =>
                          setDraft((value) => ({
                            ...value,
                            unit: event.target.value as Draft["unit"],
                          }))
                        }
                      >
                        <option value="minutes">
                          {t("scheduled.minutes")}
                        </option>
                        <option value="hours">{t("scheduled.hours")}</option>
                        <option value="days">{t("scheduled.days")}</option>
                      </select>
                    </div>
                  </label>
                )}
              </fieldset>

              <details className="scheduled-advanced" open={creating}>
                <summary className="focus-ring">
                  <span>{t("scheduled.details")}</span>
                  <Icon name="chevron" />
                </summary>
                <div>
                  <label>
                    <span>{t("scheduled.name")}</span>
                    <input
                      value={draft.title}
                      maxLength={120}
                      onChange={(event) =>
                        setDraft((value) => ({
                          ...value,
                          title: event.target.value,
                        }))
                      }
                    />
                  </label>
                  <label>
                    <span>{t("scheduled.target")}</span>
                    <select
                      aria-label={t("scheduled.target")}
                      value={draft.targetKind}
                      disabled={draft.inputKind === "skill"}
                      onChange={(event) =>
                        setDraft((value) => ({
                          ...value,
                          targetKind: event.target.value as Draft["targetKind"],
                          workspaceId:
                            event.target.value === "explicit" &&
                            !value.workspaceId
                              ? (snapshot.selectedWorkspaceId ??
                                userWorkspaces[0]?.id ??
                                "")
                              : value.workspaceId,
                          skillId: "",
                          argumentValues: [],
                        }))
                      }
                    >
                      {draft.inputKind === "text" &&
                        (snapshot.capabilities.managedWorkspaces ||
                          draft.targetKind === "default") && (
                          <option value="default">
                            {t("scheduled.target.default")}
                          </option>
                        )}
                      {(userWorkspaces.length > 0 ||
                        draft.targetKind === "explicit") && (
                        <option value="explicit">
                          {t("scheduled.target.explicit")}
                        </option>
                      )}
                    </select>
                    <small>
                      {t(
                        draft.targetKind === "default"
                          ? "scheduled.target.default_help"
                          : "scheduled.target.explicit_help",
                      )}
                    </small>
                  </label>
                  {draft.targetKind === "explicit" && (
                    <label>
                      <span>{t("scheduled.workspace")}</span>
                      <select
                        aria-label={t("scheduled.workspace")}
                        value={draft.workspaceId}
                        onChange={(event) =>
                          setDraft((value) => ({
                            ...value,
                            workspaceId: event.target.value,
                            skillId: "",
                            argumentValues: [],
                          }))
                        }
                      >
                        {!workspace && draft.workspaceId && (
                          <option value={draft.workspaceId} disabled>
                            {t("scheduled.workspace_unavailable")}
                          </option>
                        )}
                        {userWorkspaces.map((item) => (
                          <option key={item.id} value={item.id}>
                            {item.displayName || item.canonicalRoot}
                          </option>
                        ))}
                      </select>
                    </label>
                  )}
                </div>
              </details>

              {selected && (
                <section className="scheduled-history">
                  <h3>{t("scheduled.history")}</h3>
                  {selected.occurrences.length === 0 ? (
                    <p>{t("scheduled.history_empty")}</p>
                  ) : (
                    <ol>
                      {[...selected.occurrences].reverse().map((occurrence) => (
                        <li
                          key={`${occurrence.source}:${occurrence.plannedAtUnixSeconds}:${occurrence.triggeredAtUnixSeconds}`}
                          data-result={
                            occurrence.taskOutcome ?? occurrence.result
                          }
                        >
                          <span className="scheduled-history-dot" />
                          <span>
                            <strong>{occurrenceLabel(occurrence)}</strong>
                            <time>
                              {formatTime(
                                occurrence.triggeredAtUnixSeconds,
                                locale,
                                t("scheduled.no_next_run"),
                              )}
                            </time>
                          </span>
                          {occurrence.taskId && (
                            <button
                              className="text-button focus-ring"
                              onClick={() => onOpenTask(occurrence.taskId!)}
                            >
                              {t("scheduled.open_task")}
                            </button>
                          )}
                        </li>
                      ))}
                    </ol>
                  )}
                </section>
              )}

              {error && <p className="scheduled-error">{error}</p>}
            </div>

            <footer>
              {selected && (
                <>
                  <button
                    className="danger-text-button focus-ring"
                    disabled={disabled || busy}
                    onClick={() =>
                      void action(async () => {
                        await onDelete(selected.id, selected.epoch);
                        setSelectedId(null);
                      })
                    }
                  >
                    {t("scheduled.delete")}
                  </button>
                  <button
                    className="text-button focus-ring"
                    disabled={disabled || busy}
                    onClick={() =>
                      void action(async () => {
                        const result = await onRunNow(
                          selected.id,
                          selected.epoch,
                        );
                        onOpenTask(result.taskId);
                      })
                    }
                  >
                    {t("scheduled.run_now")}
                  </button>
                </>
              )}
              <button
                className="primary-button focus-ring"
                disabled={disabled || busy || mutation === null}
                onClick={() => void submit()}
              >
                {t(busy ? "scheduled.saving" : "common.save")}
              </button>
            </footer>
          </aside>
        </div>
      )}
    </section>
  );
}
