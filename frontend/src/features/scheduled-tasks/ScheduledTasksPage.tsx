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
import { Drawer } from "../../components/ui/drawer.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { Input } from "../../components/ui/input.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import { Textarea } from "../../components/ui/textarea.tsx";
import { TimePicker } from "../../components/ui/time-picker.tsx";
import { cn, controlFocus } from "../../components/ui/utils.ts";
import { useI18n } from "../../i18n/context.ts";
import { persistenceRecoveryErrorMessageId } from "../../i18n/persistence-recovery.ts";
import { BridgeCommandTimeoutError } from "../../bridge/client.ts";

type Draft = {
  modelId: string;
  modelChanged: boolean;
  title: string;
  text: string;
  permissionProfile: PermissionProfile;
  recurrenceKind: "once" | "interval" | ScheduledTaskCalendarFrequency;
  timezone: string;
  originalStart: { text: string; unixSeconds: number } | null;
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
  const startText = localDateTime(Number(start));
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
    modelChanged: false,
    title: task.title,
    text: task.input.text,
    permissionProfile: task.permissionProfile,
    recurrenceKind:
      task.recurrence.kind === "calendar"
        ? task.recurrence.frequency
        : task.recurrence.kind,
    timezone,
    originalStart: { text: startText, unixSeconds: Number(start) },
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

function draftUnixSeconds(draft: Draft, timeOnly = false): number | null {
  if (timeOnly) {
    const time = draft.start.slice(11);
    if (!/^\d{2}:\d{2}$/.test(time)) return null;
    const [hour, minute] = time.split(":").map(Number);
    if (hour > 23 || minute > 59) return null;
    const now = Date.now();
    const next = new Date(now);
    next.setHours(hour, minute, 0, 0);
    if (next.getTime() <= now) {
      next.setDate(next.getDate() + 1);
      next.setHours(hour, minute, 0, 0);
    }
    return Math.floor(next.getTime() / 1000);
  }
  if (draft.originalStart && draft.start === draft.originalStart.text)
    return draft.originalStart.unixSeconds;
  const start = Math.floor(new Date(draft.start).getTime() / 1000);
  return Number.isSafeInteger(start) && start > 0 && start <= 253402300799
    ? start
    : null;
}

function toMutation(
  snapshot: WorkbenchSnapshot,
  draft: Draft,
  timeOnly = false,
): ScheduledTaskMutation | null {
  const start = draftUnixSeconds(draft, timeOnly);
  if (!draft.title.trim() || start === null) return null;
  if (draft.recurrenceKind === "once" && start <= Math.floor(Date.now() / 1000))
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
  const option = modelOptions(snapshot).find(
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
              startAtUnixSeconds: String(start),
              timezone: draft.timezone,
              frequency: draft.recurrenceKind,
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
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [editingEpoch, setEditingEpoch] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
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
  const Editor = creating ? Dialog : Drawer;
  const editorStale =
    selected !== null && selected.epoch !== editingEpoch && !busy;
  const hasScheduledTasks = snapshot.scheduledTasks.length > 0;
  const timeOnly =
    creating &&
    (draft.recurrenceKind === "once" || draft.recurrenceKind === "daily");
  const timeLabel = t(timeOnly ? "scheduled.time" : "scheduled.starts");
  const mutation = toMutation(snapshot, draft, timeOnly);
  const draftStart = draftUnixSeconds(draft, timeOnly);
  const invalidStart = draftStart === null;
  const expiredOnce =
    draft.recurrenceKind === "once" &&
    draftStart !== null &&
    draftStart <= Math.floor(Date.now() / 1000);
  const availableModels = modelOptions(snapshot);
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
    setEditingEpoch(null);
    setError(null);
    if (restoreFocus)
      window.requestAnimationFrame(() => {
        if (trigger?.isConnected) trigger.focus();
      });
  }

  function beginCreate() {
    rememberEditorTrigger();
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

  function edit(task: ScheduledTaskView) {
    rememberEditorTrigger();
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
    const mutation = toMutation(snapshot, draft, timeOnly);
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
      return formatTime(
        task.recurrence.atUnixSeconds,
        locale,
        t("scheduled.no_next_run"),
      );
    if (task.recurrence.kind === "calendar")
      return t(`scheduled.recurrence.${task.recurrence.frequency}`);
    const seconds = Number(task.recurrence.everySeconds);
    if (seconds === 3600) return t("scheduled.repeat.hourly");
    if (seconds === 86_400) return t("scheduled.repeat.daily");
    if (seconds === 604_800) return t("scheduled.repeat.weekly");
    return `${t("scheduled.every")} ${seconds / 60} ${t("scheduled.minutes")}`;
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
            <p>{t("scheduled.subtitle")}</p>
            {snapshot.capabilities.backgroundScheduleWake && (
              <span className="scheduled-background-state">
                <Icon name="clock" />
                {t("scheduled.background_ready")}
              </span>
            )}
          </div>
          <Button
            type="button"
            variant="primary"
            size="sm"
            disabled={disabled}
            onClick={() => beginCreate()}
          >
            <Icon name="plus" />
            {t("scheduled.new")}
          </Button>
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
            <div className="scheduled-toolbar">
              <label className={cn("scheduled-search", controlFocus)}>
                <Icon name="search" />
                <span className="sr-only">
                  {t("scheduled.search_placeholder")}
                </span>
                <Input
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
                        const showLatestResult =
                          latestOccurrence &&
                          !(
                            task.health === "completed" &&
                            latestOccurrence.taskOutcome === "completed"
                          );
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
                                {showLatestResult && (
                                  <span className="scheduled-row-result">
                                    <span>{t("scheduled.latest_run")}</span>
                                    <span>
                                      {occurrenceLabel(latestOccurrence)}
                                    </span>
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
                              <span className="scheduled-row-next">
                                <span
                                  className="scheduled-state"
                                  data-health={task.health}
                                >
                                  {t(`scheduled.health.${task.health}`)}
                                </span>
                                {task.nextRunAtUnixSeconds && (
                                  <time>
                                    <span className="sr-only">
                                      {t("scheduled.next_run")}{" "}
                                    </span>
                                    {formatTime(
                                      task.nextRunAtUnixSeconds,
                                      locale,
                                      "",
                                    )}
                                  </time>
                                )}
                              </span>
                              <Icon name="chevron" />
                            </button>
                            <Menu.Root>
                              <Menu.Trigger
                                className="scheduled-row-actions icon-button"
                                aria-label={t("scheduled.actions", {
                                  title: task.title,
                                })}
                              >
                                <Icon name="more" />
                              </Menu.Trigger>
                              <Menu.Portal>
                                <Menu.Positioner align="end">
                                  <Menu.Popup>
                                    {latestOccurrence?.taskId &&
                                      latestOccurrence.taskOutcome !==
                                        "unavailable" && (
                                        <Menu.Item
                                          onClick={() =>
                                            onOpenTask(latestOccurrence.taskId!)
                                          }
                                        >
                                          {occurrenceLinkLabel(
                                            latestOccurrence,
                                          )}
                                        </Menu.Item>
                                      )}
                                    <Menu.Item
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
                                      {t("scheduled.run_now")}
                                    </Menu.Item>
                                    <Menu.Item
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
                                    </Menu.Item>
                                  </Menu.Popup>
                                </Menu.Positioner>
                              </Menu.Portal>
                            </Menu.Root>
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

      <Editor.Root
        key={creating ? "create" : "detail"}
        open={editorOpen}
        onOpenChange={(open) => {
          if (!open && !busy) closeEditor();
        }}
      >
        <Editor.Portal>
          <Editor.Backdrop />
          <Editor.Popup
            className={
              creating
                ? "scheduled-editor scheduled-editor-neutral w-[min(640px,calc(100vw-32px))] gap-0 overflow-hidden bg-(--ui-surface-panel) p-0"
                : "scheduled-editor scheduled-editor-neutral w-[min(472px,calc(100vw-28px))] max-[920px]:w-full bg-(--ui-surface-canvas) shadow-[-18px_0_54px_rgba(37,34,45,0.13)]"
            }
            initialFocus={creating ? () => editorName.current : undefined}
          >
            <header>
              <div>
                {selected && <small>{t("scheduled.editing")}</small>}
                <Editor.Title
                  id="scheduled-editor-title"
                  ref={editorHeading}
                  tabIndex={-1}
                >
                  {selected?.title || t("scheduled.creating")}
                </Editor.Title>
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
                  {selected.occurrences.at(-1) && (
                    <div className="scheduled-detail-latest">
                      <span>{t("scheduled.latest_run")}</span>
                      <strong>
                        {occurrenceLabel(selected.occurrences.at(-1)!)}
                      </strong>
                      <time>
                        {formatTime(
                          selected.occurrences.at(-1)!.triggeredAtUnixSeconds,
                          locale,
                          "",
                        )}
                      </time>
                    </div>
                  )}
                </section>
              )}

              {selected?.failureReason && (
                <p className="scheduled-attention" role="status">
                  {t(`scheduled.reason.${selected.failureReason}`)}
                </p>
              )}
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
                          label: t(`permission.profile.${permissionProfile}`),
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
                              (option) => option.selectionId === draft.modelId,
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
              {selected && draft.modelChanged && (
                <p className="scheduled-reconfirm" role="status">
                  {t("scheduled.reconfirm", {
                    model:
                      availableModels.find(
                        (option) => option.selectionId === draft.modelId,
                      )?.displayName || t("account.choose_model"),
                  })}
                </p>
              )}

              <section
                className="scheduled-editor-section"
                aria-labelledby="scheduled-editor-time-title"
              >
                <h3 id="scheduled-editor-time-title" className="sr-only">
                  {t("scheduled.when")}
                </h3>
                <div className="scheduled-time-fields">
                  <SelectionMenu
                    value={draft.recurrenceKind}
                    ariaLabel={t("scheduled.repeat")}
                    placeholder={t("scheduled.repeat")}
                    leading={<span>{t("scheduled.repeat")}:</span>}
                    triggerClassName="scheduled-time-select h-10 px-3 text-sm"
                    contentClassName="scheduled-editor-neutral"
                    disabled={false}
                    options={[
                      ...([
                        "once",
                        "daily",
                        "weekly",
                        "monthly",
                        "yearly",
                      ] as const),
                      ...(selected?.recurrence.kind === "interval"
                        ? ["interval" as const]
                        : []),
                      ...(selected?.recurrence.kind === "calendar" &&
                      selected.recurrence.frequency === "hourly"
                        ? ["hourly" as const]
                        : []),
                    ].map((kind) => ({
                      value: kind,
                      label: t(`scheduled.recurrence.${kind}`),
                    }))}
                    onValueChange={(recurrenceKind) =>
                      setDraft((value) => ({
                        ...value,
                        recurrenceKind:
                          recurrenceKind as Draft["recurrenceKind"],
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
                    {timeOnly ? (
                      <TimePicker
                        aria-label={timeLabel}
                        value={draft.start.slice(11)}
                        hourLabel={t("scheduled.hours")}
                        minuteLabel={t("scheduled.minutes")}
                        className="flex-1 border-0 bg-transparent px-0"
                        onValueChange={(time) =>
                          setDraft((value) => ({
                            ...value,
                            start: `${value.start.slice(0, 11)}${time}`,
                          }))
                        }
                      />
                    ) : (
                      <Input
                        type="datetime-local"
                        aria-label={timeLabel}
                        aria-invalid={expiredOnce || invalidStart}
                        aria-describedby={
                          expiredOnce || invalidStart
                            ? "scheduled-time-error"
                            : undefined
                        }
                        value={draft.start}
                        onChange={(event) =>
                          setDraft((value) => ({
                            ...value,
                            start: event.target.value,
                          }))
                        }
                      />
                    )}
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
                          { value: "minutes", label: t("scheduled.minutes") },
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

              {selected && (
                <section className="scheduled-history">
                  <h3>{t("scheduled.history")}</h3>
                  {selected.occurrences.length === 0 ? (
                    <p>{t("scheduled.history_empty")}</p>
                  ) : (
                    <ol>
                      {[...selected.occurrences].reverse().map((occurrence) => (
                        <li
                          key={`${occurrence.source}:${occurrence.plannedAtUnixSeconds}:${occurrence.triggeredAtUnixSeconds}:${occurrence.taskId ?? "pending"}`}
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
                            {occurrence.reason && (
                              <small className="scheduled-history-reason">
                                {t(`scheduled.reason.${occurrence.reason}`)}
                              </small>
                            )}
                            {occurrence.source === "timer" &&
                              BigInt(occurrence.triggeredAtUnixSeconds) >
                                BigInt(occurrence.plannedAtUnixSeconds) && (
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
                          </span>
                          {occurrence.taskId &&
                            occurrence.taskOutcome !== "unavailable" && (
                              <button
                                type="button"
                                className="text-button focus-ring"
                                onClick={() => onOpenTask(occurrence.taskId!)}
                              >
                                {occurrenceLinkLabel(occurrence)}
                              </button>
                            )}
                        </li>
                      ))}
                    </ol>
                  )}
                </section>
              )}

              {error && (
                <p className="scheduled-error" role="alert">
                  {error}
                </p>
              )}
            </div>

            <footer>
              {selected && (
                <>
                  <button
                    type="button"
                    className="danger-text-button focus-ring"
                    disabled={disabled || busy || editorStale}
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
                      editorStale ||
                      selected.health === "completed" ||
                      selected.health === "needs_attention"
                    }
                    onClick={() =>
                      void action(async () => {
                        const result = await onSetEnabled(
                          selected.id,
                          selected.epoch,
                          !selected.enabled,
                        );
                        if (result?.epoch) setEditingEpoch(result.epoch);
                      })
                    }
                  >
                    {t(
                      selected.enabled ? "scheduled.pause" : "scheduled.resume",
                    )}
                  </button>
                  <button
                    type="button"
                    className="text-button focus-ring"
                    disabled={
                      disabled ||
                      busy ||
                      editorStale ||
                      selected.health === "needs_attention"
                    }
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
                disabled={disabled || busy || editorStale || mutation === null}
                onClick={() => void submit()}
              >
                {t(busy ? "scheduled.saving" : "scheduled.confirm")}
              </Button>
            </footer>
          </Editor.Popup>
        </Editor.Portal>
      </Editor.Root>
    </section>
  );
}
