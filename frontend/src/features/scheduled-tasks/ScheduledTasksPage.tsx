import { useEffect, useRef, useState } from "react";

import type {
  PermissionProfile,
  ScheduledTaskCalendarFrequency,
  ScheduledTaskMutation,
  ScheduledTaskView,
  WorkbenchSnapshot,
} from "../../bridge/contracts.ts";
import {
  modelOptionId,
  readyModelOptions,
} from "../../app/new-task-model-selection.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { BrandIcon } from "../../components/ui/BrandIcon.tsx";
import { ConfirmationNotice } from "../../components/ConfirmationNotice.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Popover } from "../../components/ui/popover.tsx";
import { Input } from "../../components/ui/input.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { Textarea } from "../../components/ui/textarea.tsx";
import { TimePicker } from "../../components/ui/time-picker.tsx";
import { Switch } from "../../components/ui/switch.tsx";
import { cn, controlFocus } from "../../components/ui/utils.ts";
import { useI18n } from "../../i18n/context.ts";
import { persistenceRecoveryErrorMessageId } from "../../i18n/persistence-recovery.ts";
import { BridgeCommandTimeoutError } from "../../bridge/client.ts";

import {
  ScheduleRecurrencePicker,
  formatRecurrence,
} from "./ScheduleRecurrencePicker.tsx";

import { calendarInstant, nextOnceTime } from "./calendar-time.ts";

type Draft = {
  modelId: string;
  modelChanged: boolean;
  title: string;
  text: string;
  permissionProfile: PermissionProfile;
  recurrenceKind: "once" | "interval" | ScheduledTaskCalendarFrequency;
  weekdays: number[];
  monthDays: number[];
  timezone: string;
  originalStart: number | null;
  start: string;
  every: string;
  unit: "minutes" | "hours" | "days";
};

function localDateTime(unixSeconds: number) {
  const date = new Date(unixSeconds * 1000);
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function defaultDraft(permissionProfile: PermissionProfile): Draft {
  return {
    modelId: "",
    modelChanged: true,
    title: "",
    text: "",
    permissionProfile,
    recurrenceKind: "once",
    weekdays: [new Date(Date.now()).getDay() || 7],
    monthDays: [new Date(Date.now()).getDate()],
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    originalStart: null,
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
  const timezone =
    task.recurrence.kind === "calendar"
      ? task.recurrence.timezone
      : Intl.DateTimeFormat().resolvedOptions().timeZone;
  const startText =
    task.recurrence.kind === "calendar"
      ? task.recurrence.localTime
      : localDateTime(Number(start));
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
    modelId: modelOptionId(task.binding.modelRef),
    // Confirming an invalidated connection must renew its model proof, even
    // when the user keeps the same model. Ordinary edits retain the binding.
    modelChanged:
      task.health === "needs_attention" &&
      task.failureReason === "execution_changed",
    title: task.title,
    text: task.input.text,
    permissionProfile: task.permissionProfile,
    recurrenceKind:
      task.recurrence.kind === "calendar"
        ? task.recurrence.frequency
        : task.recurrence.kind,
    weekdays:
      task.recurrence.kind === "calendar" &&
      task.recurrence.frequency === "weekly"
        ? (task.recurrence.days ?? [])
        : [new Date(Date.now()).getDay() || 7],
    monthDays:
      task.recurrence.kind === "calendar" &&
      task.recurrence.frequency === "monthly"
        ? (task.recurrence.days ?? [])
        : [new Date(Date.now()).getDate()],
    timezone,
    originalStart: Number(start),
    start: startText,
    every: String(everySeconds / divisor),
    unit,
  };
}

function modelOptions(snapshot: WorkbenchSnapshot) {
  return [
    ...snapshot.models.providers,
    ...snapshot.models.customProviders,
  ].flatMap((provider) => readyModelOptions(snapshot.models, provider.id));
}

function draftUnixSeconds(draft: Draft): number | null {
  if (draft.originalStart !== null) return draft.originalStart;
  if (draft.recurrenceKind === "interval")
    return calendarInstant(draft.start, draft.timezone);
  if (draft.recurrenceKind === "once")
    return nextOnceTime(draft.start.slice(-5), draft.timezone);
  return null;
}

function toMutation(
  snapshot: WorkbenchSnapshot,
  draft: Draft,
  start: number | null,
  availableModels: ReturnType<typeof modelOptions>,
): ScheduledTaskMutation | null {
  const absolute =
    draft.recurrenceKind === "once" || draft.recurrenceKind === "interval";
  const localTime = draft.start.slice(-5);
  if (!draft.title.trim() || (absolute && start === null)) return null;
  if (
    draft.recurrenceKind === "once" &&
    Number(start) <= Math.floor(Date.now() / 1000)
  )
    return null;
  if (!draft.text.trim()) return null;
  if (!snapshot.capabilities.automaticWorkspaces) return null;
  if (
    !snapshot.capabilities.permissionProfiles ||
    !snapshot.permissions.availableProfiles.includes(draft.permissionProfile)
  )
    return null;
  const every = Number(draft.every);
  const unitSeconds =
    draft.unit === "days" ? 86_400 : draft.unit === "hours" ? 3600 : 60;
  if (
    draft.recurrenceKind === "interval" &&
    (!Number.isSafeInteger(every) ||
      every <= 0 ||
      !Number.isSafeInteger(every * unitSeconds))
  )
    return null;
  const option = availableModels.find(
    (candidate) => candidate.selectionId === draft.modelId,
  );
  if (draft.modelChanged && !option) return null;
  return {
    title: draft.title.trim(),
    modelSelection:
      draft.modelChanged && option
        ? {
            targetModelRef: option.modelRef,
            expectedSourceGeneration: option.sourceGeneration,
            expectedCatalogGeneration: option.catalogGeneration,
          }
        : null,
    permissionProfile: draft.permissionProfile,
    input: { kind: "text", text: draft.text.trim() },
    recurrence:
      draft.recurrenceKind === "once"
        ? { kind: "once", atUnixSeconds: String(start) }
        : draft.recurrenceKind === "interval"
          ? {
              kind: "interval",
              startAtUnixSeconds: String(start),
              everySeconds: String(every * unitSeconds),
            }
          : {
              kind: "calendar",
              ...(start === null
                ? { localTime }
                : { startAtUnixSeconds: String(start) }),
              timezone: draft.timezone,
              frequency: draft.recurrenceKind,
              ...(draft.recurrenceKind === "weekly"
                ? { days: draft.weekdays }
                : draft.recurrenceKind === "monthly"
                  ? { days: draft.monthDays }
                  : {}),
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
  recoveryDisabled,
  onCreate,
  onUpdate,
  onSetEnabled,
  onRunNow,
  onDelete,
  onRecover,
  onOpenTask,
}: {
  snapshot: WorkbenchSnapshot & { scheduledTasks: ScheduledTaskView[] };
  disabled: boolean;
  recoveryDisabled: boolean;
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
  ) => Promise<{ epoch: string }>;
  onRunNow: (id: string, epoch: string) => Promise<{ taskId: string }>;
  onDelete: (id: string, epoch: string) => Promise<void>;
  onRecover: () => Promise<{
    outcome: import("../../bridge/contracts.ts").PersistenceRecoveryOutcome;
  }>;
  onOpenTask: (taskId: string) => void;
}) {
  const { locale, t } = useI18n();
  const [now, setNow] = useState(Date.now);
  const [query, setQuery] = useState("");
  const searchInput = useRef<HTMLInputElement>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [editingEpoch, setEditingEpoch] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [editorView, setEditorView] = useState<"form" | "history">("form");
  const [draft, setDraft] = useState(() =>
    defaultDraft(snapshot.permissions.defaultProfile),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const editorTrigger = useRef<HTMLElement | null>(null);
  const editorHeading = useRef<HTMLHeadingElement | null>(null);
  const editorName = useRef<HTMLInputElement | null>(null);
  const selected =
    snapshot.scheduledTasks.find((task) => task.id === selectedId) ?? null;
  const editorOpen = creating || selected !== null;
  const historyView = editorView === "history";
  const editorStale =
    !historyView &&
    selected !== null &&
    selected.epoch !== editingEpoch &&
    !busy;
  const hasScheduledTasks = snapshot.scheduledTasks.length > 0;
  const hasNextRun = snapshot.scheduledTasks.some(
    (task) => task.nextRunAtUnixSeconds !== null,
  );
  useEffect(() => {
    if (!hasNextRun) return;
    setNow(Date.now());
    const interval = window.setInterval(() => setNow(Date.now()), 60_000);
    return () => window.clearInterval(interval);
  }, [hasNextRun]);
  const timeLabel = t("scheduled.time");
  const availableModels = modelOptions(snapshot);
  const draftStart = draftUnixSeconds(draft);
  const mutation = toMutation(snapshot, draft, draftStart, availableModels);
  const absolute =
    draft.recurrenceKind === "once" || draft.recurrenceKind === "interval";
  const invalidStart = absolute && draftStart === null;
  const expiredOnce =
    draft.recurrenceKind === "once" &&
    draftStart !== null &&
    draftStart <= Math.floor(Date.now() / 1000);
  const normalizedQuery = query.trim().toLocaleLowerCase(locale);
  const filteredTasks = snapshot.scheduledTasks.filter((task) => {
    if (!normalizedQuery) return true;
    return `${task.title} ${task.input.text}`
      .toLocaleLowerCase(locale)
      .includes(normalizedQuery);
  });
  const groups = [
    {
      key: "enabled",
      label: t("scheduled.section.enabled"),
      tasks: filteredTasks.filter((task) => task.enabled),
    },
    {
      key: "disabled",
      label: t("scheduled.section.disabled"),
      tasks: filteredTasks.filter((task) => !task.enabled),
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
    setEditingEpoch(null);
    setError(null);
    if (restoreFocus)
      window.requestAnimationFrame(() => {
        if (trigger?.isConnected) trigger.focus();
      });
  }

  function beginCreate() {
    rememberEditorTrigger();
    setEditorView("form");
    setCreating(true);
    setSelectedId(null);
    setEditingEpoch(null);
    setDraft({
      ...defaultDraft(snapshot.permissions.defaultProfile),
      modelId: snapshot.models.defaultSelection
        ? modelOptionId(snapshot.models.defaultSelection)
        : "",
    });
    setError(null);
  }

  function openSchedule(task: ScheduledTaskView, view: "form" | "history") {
    if (!editorOpen) rememberEditorTrigger();
    setEditorView(view);
    setSelectedId(task.id);
    setEditingEpoch(task.epoch);
    setCreating(false);
    setDraft(draftFromTask(task));
    setError(null);
  }

  async function submit() {
    if (busy) return;
    if (editorStale) {
      setError(t("scheduled.changed"));
      return;
    }
    const mutation = toMutation(
      snapshot,
      draft,
      draftUnixSeconds(draft),
      availableModels,
    );
    if (!mutation) {
      setError(t(expiredOnce ? "scheduled.expired_once" : "scheduled.error"));
      return;
    }
    setBusy(true);
    setError(null);
    try {
      if (selected) await onUpdate(selected.id, editingEpoch!, mutation);
      else await onCreate(mutation);
      closeEditor();
      setQuery("");
    } catch (caught) {
      setError(
        t(
          caught instanceof BridgeCommandTimeoutError
            ? "scheduled.timeout"
            : "scheduled.error",
        ),
      );
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
      setError(
        t(
          caught instanceof BridgeCommandTimeoutError
            ? "scheduled.timeout"
            : "scheduled.error",
        ),
      );
    } finally {
      setBusy(false);
    }
  }

  function recurrenceLabel(task: ScheduledTaskView) {
    if (task.recurrence.kind === "once")
      return `${t("scheduled.recurrence.once")} ${formatTime(task.recurrence.atUnixSeconds, locale, "")}`;
    if (task.recurrence.kind === "calendar")
      return `${formatRecurrence(
        task.recurrence.frequency,
        task.recurrence.days ?? [],
        t,
      )} ${task.recurrence.localTime}`;
    const seconds = Number(task.recurrence.everySeconds);
    const clock = localDateTime(
      Number(task.recurrence.startAtUnixSeconds),
    ).slice(11);
    if (seconds === 3600) return t("scheduled.repeat.hourly");
    if (seconds === 86_400) return `${t("scheduled.repeat.daily")} ${clock}`;
    if (seconds === 604_800) return `${t("scheduled.repeat.weekly")} ${clock}`;
    return `${t("scheduled.every")} ${seconds / 60} ${t("scheduled.minutes")}`;
  }

  function nextRunLabel(unixSeconds: string) {
    const remainingMs = Number(unixSeconds) * 1000 - now;
    if (remainingMs <= 0) return t("scheduled.awaiting_run");
    const minutes = Math.ceil(remainingMs / 60_000);
    const [value, unit]: [number, Intl.RelativeTimeFormatUnit] =
      minutes < 60
        ? [minutes, "minute"]
        : minutes < 1440
          ? [Math.floor(minutes / 60), "hour"]
          : [Math.floor(minutes / 1440), "day"];
    return t("scheduled.runs_in", {
      time: new Intl.RelativeTimeFormat(locale, { numeric: "always" }).format(
        value,
        unit,
      ),
    });
  }

  function occurrenceLabel(
    occurrence: ScheduledTaskView["occurrences"][number],
  ) {
    if (occurrence.reason === "permission_required")
      return t("cause.permission_required");
    if (occurrence.taskOutcome === "completed")
      return t("scheduled.occurrence.completed");
    if (occurrence.taskOutcome === "unavailable")
      return t("scheduled.occurrence.unavailable");
    if (
      occurrence.taskOutcome === "stopped" ||
      occurrence.taskOutcome === "cancelled"
    )
      return t("scheduled.occurrence.stopped");
    if (occurrence.taskOutcome === "interrupted")
      return t("scheduled.occurrence.interrupted");
    if (occurrence.taskOutcome) return t("scheduled.occurrence.failed");
    if (occurrence.result === "submitted")
      return t("scheduled.occurrence.running");
    if (occurrence.result === "skipped")
      return t("scheduled.occurrence.skipped");
    if (occurrence.result === "rejected")
      return t("scheduled.occurrence.rejected");
    return t("scheduled.occurrence.starting");
  }

  function occurrenceLinkLabel(
    occurrence: ScheduledTaskView["occurrences"][number],
  ) {
    if (!occurrence.taskOutcome && occurrence.result === "submitted")
      return t("scheduled.open_run");
    return t(
      occurrence.result === "skipped" &&
        occurrence.reason === "previous_task_running"
        ? "scheduled.open_previous_task"
        : "scheduled.open_task",
    );
  }

  return (
    <section className="scheduled-page" aria-labelledby="scheduled-title">
      <div className="scheduled-page-inner">
        <header className="scheduled-header">
          <div className="scheduled-header-copy">
            <h1 id="scheduled-title">{t("scheduled.title")}</h1>
            <p>
              {t(
                snapshot.capabilities.backgroundScheduleWake
                  ? "scheduled.subtitle_background"
                  : "scheduled.subtitle",
              )}
            </p>
          </div>
          <div className="scheduled-header-actions">
            {hasScheduledTasks && (
              <Popover.Root>
                <Popover.Trigger
                  className="icon-button scheduled-search-trigger"
                  aria-label={t("scheduled.search_placeholder")}
                  title={t("scheduled.search_placeholder")}
                  data-active={query.trim() ? "true" : undefined}
                >
                  <Icon name="search" />
                </Popover.Trigger>
                <Popover.Portal>
                  <Popover.Positioner
                    side="left"
                    align="center"
                    sideOffset={-32}
                  >
                    <Popover.Popup
                      aria-label={t("scheduled.search_placeholder")}
                      initialFocus={() => searchInput.current}
                      className={cn(
                        "w-[min(180px,calc(100vw-32px))] p-0 shadow-none",
                        controlFocus,
                      )}
                    >
                      <label className="scheduled-search">
                        <Icon name="search" />
                        <span className="sr-only">
                          {t("scheduled.search_placeholder")}
                        </span>
                        <Input
                          ref={searchInput}
                          type="search"
                          value={query}
                          placeholder={t("scheduled.search_placeholder")}
                          onChange={(event) => setQuery(event.target.value)}
                        />
                        {query && (
                          <button
                            type="button"
                            className="focus-ring"
                            aria-label={t("scheduled.clear_search")}
                            onClick={() => {
                              setQuery("");
                              searchInput.current?.focus();
                            }}
                          >
                            <Icon name="close" />
                          </button>
                        )}
                      </label>
                    </Popover.Popup>
                  </Popover.Positioner>
                </Popover.Portal>
              </Popover.Root>
            )}
            <Button
              className="scheduled-create-button"
              type="button"
              variant="primary"
              size="sm"
              disabled={disabled}
              onClick={() => beginCreate()}
            >
              <Icon name="plus" />
              {t("scheduled.new")}
            </Button>
          </div>
        </header>

        {!editorOpen && error && (
          <p className="scheduled-error" role="alert">
            {error}
          </p>
        )}

        {snapshot.capabilities.scheduledTaskPersistenceHealth !== "ready" && (
          <ConfirmationNotice
            className="scheduled-capability-error"
            message={t(
              `scheduled.persistence.${snapshot.capabilities.scheduledTaskPersistenceHealth}`,
            )}
            detail={t("persistence.recovery.scheduled.hard_cut")}
            actionLabel={t("persistence.recovery.action")}
            dialogTitle={t("persistence.recovery.scheduled.title")}
            dialogDescription={t("persistence.recovery.scheduled.body")}
            cancelLabel={t("persistence.recovery.cancel")}
            confirmLabel={t("persistence.recovery.scheduled.confirm")}
            pendingLabel={t("persistence.recovery.running")}
            failureMessage={t("persistence.recovery.failed")}
            actionAvailable={
              snapshot.capabilities.scheduledTaskRecoveryAvailable
            }
            disabled={recoveryDisabled}
            onConfirm={async () => {
              const result = await onRecover();
              return result.outcome === "recovered"
                ? null
                : t(persistenceRecoveryErrorMessageId(result.outcome));
            }}
          />
        )}

        {!hasScheduledTasks ? (
          <p className="scheduled-empty-state">{t("scheduled.empty")}</p>
        ) : (
          <>
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
                      <span>({group.tasks.length})</span>
                    </div>
                    <ul className="scheduled-list" aria-label={group.label}>
                      {group.tasks.map((task) => {
                        const latestOccurrence = task.occurrences.at(-1);
                        return (
                          <li key={task.id} data-health={task.health}>
                            <div className="scheduled-row-main">
                              <span
                                className="scheduled-row-status"
                                aria-hidden="true"
                              />
                              <span className="scheduled-row-copy">
                                <strong>{task.title}</strong>
                                <span className="scheduled-row-schedule">
                                  <span className="scheduled-row-frequency">
                                    {recurrenceLabel(task)}
                                  </span>
                                  {task.nextRunAtUnixSeconds && (
                                    <time
                                      className="scheduled-row-next"
                                      dateTime={new Date(
                                        Number(task.nextRunAtUnixSeconds) *
                                          1000,
                                      ).toISOString()}
                                      title={formatTime(
                                        task.nextRunAtUnixSeconds,
                                        locale,
                                        "",
                                      )}
                                    >
                                      <span className="sr-only">
                                        {t("scheduled.next_run")}{" "}
                                      </span>
                                      {nextRunLabel(task.nextRunAtUnixSeconds)}
                                    </time>
                                  )}
                                </span>
                                <small>{task.input.text}</small>
                                {latestOccurrence && (
                                  <span className="scheduled-row-result">
                                    <span>{t("scheduled.latest_run")}</span>
                                    {latestOccurrence.taskId &&
                                    latestOccurrence.taskOutcome !==
                                      "unavailable" ? (
                                      <button
                                        type="button"
                                        className="scheduled-row-result-link focus-ring"
                                        aria-label={occurrenceLinkLabel(
                                          latestOccurrence,
                                        )}
                                        title={occurrenceLinkLabel(
                                          latestOccurrence,
                                        )}
                                        onClick={() =>
                                          onOpenTask(latestOccurrence.taskId!)
                                        }
                                      >
                                        {occurrenceLabel(latestOccurrence)}
                                        <Icon name="external-link" />
                                      </button>
                                    ) : (
                                      <span>
                                        {occurrenceLabel(latestOccurrence)}
                                      </span>
                                    )}
                                  </span>
                                )}
                                {task.failureReason && (
                                  <span className="scheduled-row-reason">
                                    {t(
                                      `scheduled.reason.${task.failureReason}`,
                                    )}
                                  </span>
                                )}
                              </span>
                            </div>
                            <div
                              className="scheduled-row-actions"
                              role="group"
                              aria-label={t("scheduled.actions", {
                                title: task.title,
                              })}
                            >
                              <Button
                                type="button"
                                variant="ghost"
                                size="icon"
                                className="size-8 text-base text-(--ui-content-muted)"
                                aria-label={t("scheduled.run_now")}
                                title={t("scheduled.run_now")}
                                disabled={
                                  disabled ||
                                  busy ||
                                  task.health === "needs_attention"
                                }
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
                                <Icon name="play" />
                              </Button>
                              <Button
                                type="button"
                                variant="ghost"
                                size="icon"
                                className="size-8 text-base text-(--ui-content-muted)"
                                aria-label={t("common.edit")}
                                title={t("common.edit")}
                                onClick={() => openSchedule(task, "form")}
                              >
                                <Icon name="edit" />
                              </Button>
                              <Button
                                type="button"
                                variant="ghost"
                                size="icon"
                                className="size-8 text-base text-(--ui-content-muted)"
                                aria-label={t("scheduled.view_history", {
                                  title: task.title,
                                })}
                                title={t("scheduled.view_history", {
                                  title: task.title,
                                })}
                                onClick={() => openSchedule(task, "history")}
                              >
                                <Icon name="history" />
                              </Button>
                              <Switch.Root
                                checked={task.enabled}
                                className="mx-1 h-4 w-7 data-checked:bg-(--metask-state-complete)"
                                aria-label={t("scheduled.enablement", {
                                  title: task.title,
                                })}
                                title={t(
                                  task.enabled
                                    ? "scheduled.pause"
                                    : "scheduled.resume",
                                )}
                                disabled={
                                  disabled ||
                                  busy ||
                                  task.health === "completed" ||
                                  task.health === "needs_attention"
                                }
                                onCheckedChange={(enabled) =>
                                  void action(() =>
                                    onSetEnabled(task.id, task.epoch, enabled),
                                  )
                                }
                              >
                                <Switch.Thumb className="size-3 data-checked:translate-x-3" />
                              </Switch.Root>
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

      <Dialog.Root
        open={editorOpen}
        onOpenChange={(open) => {
          if (!open && !busy) closeEditor();
        }}
      >
        <Dialog.Portal>
          <Dialog.Backdrop />
          <Dialog.Popup
            className={cn(
              "scheduled-editor scheduled-editor-neutral gap-0 overflow-hidden bg-(--ui-surface-panel) p-0",
              historyView
                ? "scheduled-history-dialog w-[min(480px,calc(100vw-32px))]"
                : "w-[min(640px,calc(100vw-32px))]",
            )}
            initialFocus={() =>
              historyView ? editorHeading.current : editorName.current
            }
          >
            <header>
              <div>
                <Dialog.Title
                  id="scheduled-editor-title"
                  ref={editorHeading}
                  tabIndex={-1}
                  aria-label={
                    historyView
                      ? t("scheduled.view_history", {
                          title: selected?.title ?? "",
                        })
                      : undefined
                  }
                >
                  {historyView
                    ? t("scheduled.history_title")
                    : t(creating ? "scheduled.creating" : "scheduled.editing")}
                </Dialog.Title>
                {historyView && (
                  <p className="scheduled-history-title">{selected?.title}</p>
                )}
              </div>
              <button
                type="button"
                className="icon-button focus-ring"
                aria-label={t("common.close")}
                onClick={() => closeEditor()}
              >
                <Icon name="close" />
              </button>
            </header>

            <div className="scheduled-editor-scroll">
              {!historyView && selected?.failureReason && (
                <p className="scheduled-attention" role="status">
                  {t(`scheduled.reason.${selected.failureReason}`)}
                </p>
              )}
              {historyView ? (
                selected && (
                  <>
                    <section className="scheduled-history">
                      {selected.occurrences.length === 0 ? (
                        <p>{t("scheduled.history_empty")}</p>
                      ) : (
                        <ol>
                          {[...selected.occurrences]
                            .reverse()
                            .map((occurrence) => (
                              <li
                                key={`${occurrence.source}:${occurrence.plannedAtUnixSeconds}:${occurrence.triggeredAtUnixSeconds}:${occurrence.taskId ?? "pending"}`}
                                data-result={
                                  occurrence.taskOutcome ?? occurrence.result
                                }
                              >
                                <div className="scheduled-history-entry">
                                  <div className="scheduled-history-line">
                                    <time
                                      dateTime={new Date(
                                        Number(
                                          occurrence.triggeredAtUnixSeconds,
                                        ) * 1000,
                                      ).toISOString()}
                                    >
                                      {formatTime(
                                        occurrence.triggeredAtUnixSeconds,
                                        locale,
                                        t("scheduled.no_next_run"),
                                      )}
                                    </time>
                                    <span className="scheduled-history-state">
                                      <span
                                        className="scheduled-history-dot"
                                        aria-hidden="true"
                                      />
                                      {occurrenceLabel(occurrence)}
                                    </span>
                                  </div>
                                  {occurrence.reason && (
                                    <small className="scheduled-history-reason">
                                      {t(
                                        `scheduled.reason.${occurrence.reason}`,
                                      )}
                                    </small>
                                  )}
                                  {occurrence.source === "timer" &&
                                    BigInt(occurrence.triggeredAtUnixSeconds) >
                                      BigInt(
                                        occurrence.plannedAtUnixSeconds,
                                      ) && (
                                      <small>
                                        {t("scheduled.occurrence.delayed", {
                                          time: formatTime(
                                            occurrence.plannedAtUnixSeconds,
                                            locale,
                                            "",
                                          ),
                                        })}
                                      </small>
                                    )}
                                </div>
                                {occurrence.taskId &&
                                  occurrence.taskOutcome !== "unavailable" && (
                                    <Button
                                      type="button"
                                      variant="ghost"
                                      size="icon"
                                      className="size-8 text-base text-(--ui-content-muted)"
                                      aria-label={occurrenceLinkLabel(
                                        occurrence,
                                      )}
                                      title={occurrenceLinkLabel(occurrence)}
                                      onClick={() =>
                                        onOpenTask(occurrence.taskId!)
                                      }
                                    >
                                      <Icon name="external-link" />
                                    </Button>
                                  )}
                              </li>
                            ))}
                        </ol>
                      )}
                    </section>
                  </>
                )
              ) : (
                <>
                  {editorStale && (
                    <div className="scheduled-stale" role="alert">
                      <p>{t("scheduled.changed")}</p>
                      <Button
                        type="button"
                        size="sm"
                        onClick={() => {
                          setDraft(draftFromTask(selected!));
                          setEditingEpoch(selected!.epoch);
                          setError(null);
                        }}
                      >
                        {t("scheduled.reload")}
                      </Button>
                    </div>
                  )}
                  <label className="scheduled-editor-name">
                    <span className="sr-only">{t("scheduled.name")}</span>
                    <Input
                      ref={editorName}
                      placeholder={t("scheduled.name")}

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

                  <section
                    className={cn("scheduled-composer", controlFocus)}
                    aria-label={t("scheduled.what")}
                  >
                    <Textarea
                      aria-label={t("scheduled.instruction")}
                      rows={3}
                      value={draft.text}
                      placeholder={t("scheduled.instruction_placeholder")}
                      onChange={(event) =>
                        setDraft((value) => ({
                          ...value,
                          text: event.target.value,
                        }))
                      }
                    />
                    <div className="ai-composer-toolbar">
                      <div className="composer-context-actions">
                        <SelectionMenu
                          ariaLabel={t("scheduled.permission")}
                          placeholder={t("scheduled.permission")}
                          value={draft.permissionProfile}
                          disabled={false}
                          leading={
                            <Icon
                              name={
                                draft.permissionProfile === "full_access"
                                  ? "shield-alert"
                                  : "account"
                              }
                            />
                          }
                          triggerClassName="task-approval-trigger w-auto"
                          contentClassName="scheduled-editor-neutral permission-profile-menu task-approval-menu"
                          options={snapshot.permissions.availableProfiles.map(
                            (permissionProfile) => ({
                              value: permissionProfile,
                              label: t(
                                `permission.profile.${permissionProfile}`,
                              ),
                              leading: (
                                <Icon
                                  name={
                                    permissionProfile === "full_access"
                                      ? "shield-alert"
                                      : "account"
                                  }
                                />
                              ),
                              description: t(
                                `scheduled.permission.${permissionProfile}.help`,
                              ),
                              descriptionKind: "text",
                            }),
                          )}
                          onValueChange={(permissionProfile) =>
                            setDraft((value) => ({
                              ...value,
                              permissionProfile:
                                permissionProfile as PermissionProfile,
                            }))
                          }
                        />
                      </div>
                      <div className="composer-model-actions">
                        <SelectionMenu
                          value={draft.modelId}
                          ariaLabel={t("account.model")}
                          placeholder={t("account.choose_model")}
                          disabled={false}
                          leading={
                            <BrandIcon
                              brand={
                                availableModels.find(
                                  (option) =>
                                    option.selectionId === draft.modelId,
                                )?.vendor
                              }
                            />
                          }
                          triggerClassName="composer-model-trigger w-auto"
                          compact
                          contentClassName="scheduled-editor-neutral composer-model-menu"
                          options={[
                            ...(!draft.modelChanged &&
                            selected &&
                            !availableModels.some(
                              (option) => option.selectionId === draft.modelId,
                            )
                              ? [
                                  {
                                    value: draft.modelId,
                                    label: selected.binding.modelRef.modelId,
                                  },
                                ]
                              : []),
                            ...availableModels.map((option) => ({
                              value: option.selectionId,
                              label: option.displayName,
                              leading: <BrandIcon brand={option.vendor} />,
                            })),
                          ]}
                          onValueChange={(modelId) =>
                            setDraft((value) => ({
                              ...value,
                              modelId,
                              modelChanged: true,
                            }))
                          }
                        />
                      </div>
                    </div>
                  </section>
                  <section
                    className="scheduled-editor-section"
                    aria-labelledby="scheduled-editor-time-title"
                  >
                    <h3 id="scheduled-editor-time-title" className="sr-only">
                      {t("scheduled.when")}
                    </h3>
                    <div className="scheduled-time-fields">
                      <ScheduleRecurrencePicker
                        value={draft.recurrenceKind}
                        weekdays={draft.weekdays}
                        monthDays={draft.monthDays}
                        legacyKind={
                          selected?.recurrence.kind === "interval"
                            ? "interval"
                            : selected?.recurrence.kind === "calendar" &&
                                selected.recurrence.frequency === "hourly"
                              ? "hourly"
                              : undefined
                        }
                        onKindChange={(kind) =>
                          setDraft((value) =>
                            value.recurrenceKind === kind
                              ? value
                              : {
                                  ...value,
                                  recurrenceKind: kind,
                                  originalStart: null,
                                  ...(kind === "weekly"
                                    ? {
                                        weekdays: [
                                          new Date(Date.now()).getDay() || 7,
                                        ],
                                      }
                                    : kind === "monthly"
                                      ? {
                                          monthDays: [
                                            new Date(Date.now()).getDate(),
                                          ],
                                        }
                                      : {}),
                                },
                          )
                        }
                        onDaysChange={(kind, days) =>
                          setDraft((value) => ({
                            ...value,
                            recurrenceKind: kind,
                            originalStart: null,
                            ...(kind === "weekly"
                              ? { weekdays: days }
                              : { monthDays: days }),
                          }))
                        }
                      />
                      <div
                        className={cn(
                          "scheduled-inline-input scheduled-start",
                          controlFocus,
                        )}
                      >
                        <span>{timeLabel}:</span>
                        <TimePicker
                          aria-label={timeLabel}
                          aria-invalid={expiredOnce || invalidStart}
                          aria-describedby={
                            expiredOnce || invalidStart
                              ? "scheduled-time-error"
                              : undefined
                          }
                          value={draft.start.slice(-5)}
                          hourLabel={t("scheduled.hours")}
                          minuteLabel={t("scheduled.minutes")}
                          className="flex-1 border-0 bg-transparent px-0"
                          onValueChange={(time) =>
                            setDraft((value) => ({
                              ...value,
                              start: `${value.start.slice(0, -5)}${time}`,
                              originalStart: null,
                            }))
                          }
                        />
                      </div>
                      {draft.recurrenceKind === "interval" && (
                        <div
                          className={cn(
                            "scheduled-inline-input scheduled-interval",
                            controlFocus,
                          )}
                          role="group"
                          aria-label={t("scheduled.recurrence.interval")}
                        >
                          <span>{t("scheduled.every")}:</span>
                          <Input
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
                          <SelectionMenu
                            ariaLabel={t("scheduled.interval_unit")}
                            placeholder={t("scheduled.interval_unit")}
                            disabled={false}
                            triggerClassName="scheduled-unit-select h-9 w-auto flex-1 px-0 text-sm"
                            contentClassName="scheduled-editor-neutral"
                            value={draft.unit}
                            onValueChange={(unit) =>
                              setDraft((value) => ({
                                ...value,
                                unit: unit as Draft["unit"],
                              }))
                            }
                            options={[
                              {
                                value: "minutes",
                                label: t("scheduled.minutes"),
                              },
                              { value: "hours", label: t("scheduled.hours") },
                              { value: "days", label: t("scheduled.days") },
                            ]}
                          />
                        </div>
                      )}
                    </div>
                    {(expiredOnce || invalidStart) && (
                      <small id="scheduled-time-error" role="alert">
                        {t(
                          invalidStart
                            ? "scheduled.invalid_time"
                            : "scheduled.expired_once",
                        )}
                      </small>
                    )}
                  </section>
                </>
              )}

              {error && (
                <p className="scheduled-error" role="alert">
                  {error}
                </p>
              )}
            </div>

            {!historyView && (
              <footer>
                {selected && (
                  <Button
                    type="button"
                    variant="ghost"
                    size="icon"
                    className="scheduled-editor-delete"
                    aria-label={t("scheduled.delete")}
                    title={t("scheduled.delete")}
                    disabled={disabled || busy || editorStale}
                    onClick={() =>
                      void action(async () => {
                        await onDelete(selected.id, selected.epoch);
                        closeEditor();
                      })
                    }
                  >
                    <Icon name="trash" />
                  </Button>
                )}
                <Button
                  type="button"
                  variant="secondary"
                  size="sm"
                  className="min-w-24"
                  disabled={busy}
                  onClick={() => closeEditor()}
                >
                  {t("common.cancel")}
                </Button>
                <Button
                  type="button"
                  variant="primary"
                  size="sm"
                  className="min-w-24"
                  disabled={
                    disabled || busy || editorStale || mutation === null
                  }
                  onClick={() => void submit()}
                >
                  {t(busy ? "scheduled.saving" : "scheduled.confirm")}
                </Button>
              </footer>
            )}
          </Dialog.Popup>
        </Dialog.Portal>
      </Dialog.Root>
    </section>
  );
}
