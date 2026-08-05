import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type ComponentProps,
} from "react";

import type {
  ScheduledTaskMutation,
  ScheduledTaskView,
  WorkbenchSnapshot,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";

type Draft = {
  title: string;
  text: string;
  recurrenceKind: "once" | "interval";
  start: string;
  every: string;
  unit: "minutes" | "hours" | "days";
};

type SuggestionKind = "daily" | "weekly" | "followup";

function ScheduledSelect({ children, ...props }: ComponentProps<"select">) {
  return (
    <span className="scheduled-select">
      <select {...props}>{children}</select>
      <Icon name="chevron" />
    </span>
  );
}

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

function defaultDraft(): Draft {
  return {
    title: "",
    text: "",
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
    text: task.input.text,
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
  const start = Math.floor(new Date(draft.start).getTime() / 1000);
  if (!draft.title.trim() || !Number.isSafeInteger(start) || start <= 0)
    return null;
  if (!draft.text.trim()) return null;
  if (!snapshot.capabilities.automaticWorkspaces) return null;
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
    expectedExecutionGeneration: snapshot.account.executionGeneration,
    input: { kind: "text", text: draft.text.trim() },
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

function formatDraftTime(value: string, locale: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat(locale, {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
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
  const [draft, setDraft] = useState(defaultDraft);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const editorTrigger = useRef<HTMLElement | null>(null);
  const editorHeading = useRef<HTMLHeadingElement | null>(null);
  const selected =
    snapshot.scheduledTasks.find((task) => task.id === selectedId) ?? null;
  const editorOpen = creating || selected !== null;
  const hasScheduledTasks = snapshot.scheduledTasks.length > 0;
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const mutation = useMemo(
    () => toMutation(snapshot, draft),
    [snapshot, draft],
  );
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const filteredTasks = snapshot.scheduledTasks.filter((task) => {
    if (!normalizedQuery) return true;
    return `${task.title} ${task.input.text}`
      .toLocaleLowerCase(locale)
      .includes(normalizedQuery);
  });
  const groups = [
    {
      key: "attention",
      label: t("scheduled.section.needs_attention"),
      tasks: filteredTasks.filter((task) => task.health === "needs_attention"),
    },
    {
      key: "ongoing",
      label: t("scheduled.section.ongoing"),
      tasks: filteredTasks.filter((task) => task.health === "ready"),
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

  useEffect(() => {
    if (!editorOpen || creating) return;
    const frame = window.requestAnimationFrame(() =>
      editorHeading.current?.focus(),
    );
    return () => window.cancelAnimationFrame(frame);
  }, [creating, editorOpen, selectedId]);

  function rememberEditorTrigger() {
    editorTrigger.current =
      document.activeElement instanceof HTMLElement
        ? document.activeElement
        : null;
  }

  function closeEditor(restoreFocus = true) {
    const trigger = editorTrigger.current;
    setCreating(false);
    setSelectedId(null);
    setError(null);
    if (restoreFocus)
      window.requestAnimationFrame(() => {
        if (trigger?.isConnected) trigger.focus();
      });
  }

  function beginCreate(seed?: Partial<Draft>) {
    rememberEditorTrigger();
    setCreating(true);
    setSelectedId(null);
    setDraft({ ...defaultDraft(), ...seed });
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
    rememberEditorTrigger();
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
      closeEditor();
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

  const suggestions = [
    {
      kind: "daily" as const,
      icon: "sunrise" as const,
      title: t("scheduled.suggestion.daily.title"),
      schedule: t("scheduled.suggestion.daily.schedule"),
      body: t("scheduled.suggestion.daily.body"),
    },
    {
      kind: "weekly" as const,
      icon: "calendar-days" as const,
      title: t("scheduled.suggestion.weekly.title"),
      schedule: t("scheduled.suggestion.weekly.schedule"),
      body: t("scheduled.suggestion.weekly.body"),
    },
    {
      kind: "followup" as const,
      icon: "radar" as const,
      title: t("scheduled.suggestion.followup.title"),
      schedule: t("scheduled.suggestion.followup.schedule"),
      body: t("scheduled.suggestion.followup.body"),
    },
  ];
  const confirmationTitle =
    draft.title.trim() || t("scheduled.confirmation.untitled");
  const confirmation =
    draft.recurrenceKind === "once"
      ? t("scheduled.confirmation.once", {
          title: confirmationTitle,
          time: formatDraftTime(draft.start, locale),
        })
      : t("scheduled.confirmation.interval", {
          title: confirmationTitle,
          time: formatDraftTime(draft.start, locale),
          every: draft.every || "—",
          unit: t(`scheduled.unit.${draft.unit}`),
        });

  return (
    <section className="scheduled-page" aria-labelledby="scheduled-title">
      <div className="scheduled-page-inner">
        <header className="scheduled-header">
          <div className="scheduled-header-copy">
            <h1 id="scheduled-title">{t("scheduled.title")}</h1>
            <p>{t("scheduled.subtitle")}</p>
            {snapshot.capabilities.backgroundScheduleWake && (
              <span className="scheduled-background-state">
                <Icon name="clock" />
                {t("scheduled.background_ready")}
              </span>
            )}
          </div>
          <button
            type="button"
            className="primary-button focus-ring"
            disabled={disabled}
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

        {!hasScheduledTasks ? (
          <div className="scheduled-empty-state">
            <div className="scheduled-starter">
              <div className="scheduled-section-heading">
                <div>
                  <h2>{t("scheduled.suggestions")}</h2>
                  <p>{t("scheduled.suggestions_help")}</p>
                </div>
              </div>
              <div className="scheduled-suggestion-list">
                {suggestions.map((suggestion) => (
                  <button
                    key={suggestion.kind}
                    type="button"
                    className="scheduled-suggestion focus-ring"
                    disabled={disabled}
                    onClick={() => beginSuggestion(suggestion.kind)}
                  >
                    <span
                      className="scheduled-suggestion-mark"
                      aria-hidden="true"
                    >
                      <Icon name={suggestion.icon} />
                    </span>
                    <span>
                      <strong>{suggestion.title}</strong>
                      <span>{suggestion.body}</span>
                    </span>
                    <span className="scheduled-suggestion-time">
                      <small>{suggestion.schedule}</small>
                      <Icon name="chevron" />
                    </span>
                  </button>
                ))}
              </div>
            </div>
          </div>
        ) : (
          <>
            <div className="scheduled-toolbar">
              <label className="scheduled-search">
                <Icon name="search" />
                <span className="sr-only">
                  {t("scheduled.search_placeholder")}
                </span>
                <input
                  type="search"
                  value={query}
                  placeholder={t("scheduled.search_placeholder")}
                  onChange={(event) => setQuery(event.target.value)}
                />
                {query && (
                  <button
                    type="button"
                    className="focus-ring"
                    aria-label={t("common.cancel")}
                    onClick={() => setQuery("")}
                  >
                    <Icon name="close" />
                  </button>
                )}
              </label>
              <span className="scheduled-count">
                {t(
                  filteredTasks.length === 1
                    ? "scheduled.count.one"
                    : "scheduled.count.other",
                  { count: filteredTasks.length },
                )}
              </span>
            </div>

            {groups.length === 0 ? (
              <div className="scheduled-no-results">
                <Icon name="search" />
                <h2>{t("scheduled.no_matches")}</h2>
                <p>{t("scheduled.no_matches_body")}</p>
              </div>
            ) : (
              <div className="scheduled-groups">
                {groups.map((group) => (
                  <section
                    key={group.key}
                    className="scheduled-group"
                    aria-labelledby={`scheduled-group-${group.key}`}
                  >
                    <div className="scheduled-section-heading">
                      <h2 id={`scheduled-group-${group.key}`}>{group.label}</h2>
                      <span>{group.tasks.length}</span>
                    </div>
                    <ul className="scheduled-list" aria-label={group.label}>
                      {group.tasks.map((task) => {
                        const latestOccurrence = task.occurrences.at(-1);
                        return (
                          <li key={task.id} data-health={task.health}>
                            <button
                              type="button"
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
                                  {task.input.text}
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
                                type="button"
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
                                type="button"
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
          </>
        )}
      </div>

      {editorOpen && (
        <div
          className="scheduled-editor-backdrop"
          onMouseDown={() => {
            if (busy) return;
            closeEditor();
          }}
          onKeyDown={(event) => {
            if (event.key !== "Escape" || busy) return;
            event.preventDefault();
            closeEditor();
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
                <h2
                  id="scheduled-editor-title"
                  ref={editorHeading}
                  tabIndex={-1}
                >
                  {selected?.title || t("scheduled.new")}
                </h2>
              </div>
              <button
                type="button"
                className="icon-button focus-ring"
                aria-label={t("common.cancel")}
                onClick={() => closeEditor()}
              >
                <Icon name="close" />
              </button>
            </header>

            <div className="scheduled-editor-scroll">
              <label className="scheduled-editor-name">
                <span>{t("scheduled.name")}</span>
                <input
                  autoFocus={creating}
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

              <section
                className="scheduled-editor-section"
                aria-labelledby="scheduled-editor-content-title"
              >
                <h3 id="scheduled-editor-content-title">
                  {t("scheduled.what")}
                </h3>
                <textarea
                  aria-label={t("scheduled.instruction")}
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
                <small>{t("scheduled.instruction_help")}</small>
              </section>

              <section
                className="scheduled-editor-section"
                aria-labelledby="scheduled-editor-time-title"
              >
                <h3 id="scheduled-editor-time-title">{t("scheduled.when")}</h3>
                <div className="scheduled-segments">
                  {(["once", "interval"] as const).map((kind) => (
                    <button
                      key={kind}
                      type="button"
                      data-active={draft.recurrenceKind === kind}
                      aria-pressed={draft.recurrenceKind === kind}
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
                        aria-label={t("scheduled.every")}
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
                      <ScheduledSelect
                        aria-label={t("scheduled.interval_unit")}
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
                      </ScheduledSelect>
                    </div>
                  </label>
                )}
              </section>

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
                              type="button"
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

              <section className="scheduled-confirmation" aria-live="polite">
                <Icon name="clock" />
                <div>
                  <strong>{t("scheduled.confirmation.title")}</strong>
                  <p>{confirmation}</p>
                  <small>{t("scheduled.timezone", { timezone })}</small>
                </div>
              </section>

              {error && <p className="scheduled-error">{error}</p>}
            </div>

            <footer>
              {selected && (
                <>
                  <button
                    type="button"
                    className="danger-text-button focus-ring"
                    disabled={disabled || busy}
                    onClick={() =>
                      void action(async () => {
                        await onDelete(selected.id, selected.epoch);
                        closeEditor();
                      })
                    }
                  >
                    {t("scheduled.delete")}
                  </button>
                  <button
                    type="button"
                    className="text-button focus-ring"
                    disabled={
                      disabled ||
                      busy ||
                      selected.health === "completed" ||
                      selected.health === "needs_attention"
                    }
                    onClick={() =>
                      void action(() =>
                        onSetEnabled(
                          selected.id,
                          selected.epoch,
                          !selected.enabled,
                        ),
                      )
                    }
                  >
                    {t(
                      selected.enabled ? "scheduled.pause" : "scheduled.resume",
                    )}
                  </button>
                  <button
                    type="button"
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
                type="button"
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
