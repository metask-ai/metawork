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

function localDateTime(unixSeconds: number) {
  const date = new Date(unixSeconds * 1000);
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function defaultDraft(snapshot: WorkbenchSnapshot): Draft {
  return {
    title: "",
    workspaceId:
      snapshot.selectedWorkspaceId ?? snapshot.workspaces[0]?.id ?? "",
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
    workspaceId: task.workspaceId,
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
  const workspace = snapshot.workspaces.find(
    (candidate) => candidate.id === draft.workspaceId,
  );
  const start = Math.floor(new Date(draft.start).getTime() / 1000);
  if (
    !workspace ||
    !draft.title.trim() ||
    !Number.isSafeInteger(start) ||
    start <= 0
  )
    return null;
  let input: TaskRunInput;
  if (draft.inputKind === "text") {
    if (!draft.text.trim()) return null;
    input = { kind: "text", text: draft.text.trim() };
  } else {
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
    workspaceId: workspace.id,
    expectedWorkspaceEpoch: workspace.epoch,
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
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [draft, setDraft] = useState(() => defaultDraft(snapshot));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const selected =
    snapshot.scheduledTasks.find((task) => task.id === selectedId) ?? null;
  const workspace = snapshot.workspaces.find(
    (candidate) => candidate.id === draft.workspaceId,
  );
  const selectedSkill = workspace?.skillCatalog.skills.find(
    (skill) => skill.skillId === draft.skillId,
  );
  const mutation = useMemo(
    () => toMutation(snapshot, draft),
    [snapshot, draft],
  );

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

  const editorOpen = creating || selected !== null;

  return (
    <section className="scheduled-page" aria-labelledby="scheduled-title">
      <div className="scheduled-page-inner">
        <header className="scheduled-header">
          <div>
            <h1 id="scheduled-title">{t("scheduled.title")}</h1>
            <p>{t("scheduled.subtitle")}</p>
          </div>
          <button
            className="primary-button focus-ring"
            disabled={disabled || snapshot.workspaces.length === 0}
            onClick={() => {
              setCreating(true);
              setSelectedId(null);
              setDraft(defaultDraft(snapshot));
              setError(null);
            }}
          >
            <Icon name="plus" />
            {t("scheduled.new")}
          </button>
        </header>

        <div className="scheduled-runtime-note" role="note">
          <Icon name="clock" />
          <span>{t("scheduled.runtime_only")}</span>
        </div>

        {snapshot.scheduledTasks.length === 0 ? (
          <div className="scheduled-empty">
            <span aria-hidden="true">◷</span>
            <h2>{t("scheduled.empty_title")}</h2>
            <p>{t("scheduled.empty_body")}</p>
          </div>
        ) : (
          <ul className="scheduled-list">
            {snapshot.scheduledTasks.map((task) => {
              const boundWorkspace = snapshot.workspaces.find(
                (candidate) => candidate.id === task.workspaceId,
              );
              const latestOccurrence = task.occurrences.at(-1);
              return (
                <li key={task.id} data-health={task.health}>
                  <button
                    className="scheduled-row-main focus-ring"
                    onClick={() => edit(task)}
                  >
                    <span className="scheduled-row-status" aria-hidden="true" />
                    <span className="scheduled-row-copy">
                      <strong>{task.title || t("scheduled.untitled")}</strong>
                      <small>
                        {boundWorkspace?.displayName ??
                          boundWorkspace?.canonicalRoot ??
                          t("workspace.none")}
                        <span aria-hidden="true"> · </span>
                        {task.input.kind === "skill"
                          ? `/${task.input.skillId}`
                          : t("scheduled.text_input")}
                      </small>
                    </span>
                    <span className="scheduled-row-next">
                      <small>{t(`scheduled.health.${task.health}`)}</small>
                      <time>
                        {formatTime(
                          task.nextRunAtUnixSeconds,
                          locale,
                          t("scheduled.no_next_run"),
                        )}
                      </time>
                    </span>
                  </button>
                  <div className="scheduled-row-actions">
                    {latestOccurrence?.taskId && (
                      <button
                        className="text-button focus-ring"
                        onClick={() => onOpenTask(latestOccurrence.taskId!)}
                      >
                        {t("scheduled.open_last_task")}
                      </button>
                    )}
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
                          onSetEnabled(task.id, task.epoch, !task.enabled),
                        )
                      }
                    >
                      {t(task.enabled ? "scheduled.pause" : "scheduled.resume")}
                    </button>
                    <button
                      className="text-button focus-ring"
                      disabled={disabled || busy}
                      onClick={() =>
                        void action(async () => {
                          const result = await onRunNow(task.id, task.epoch);
                          onOpenTask(result.taskId);
                        })
                      }
                    >
                      {t("scheduled.run_now")}
                    </button>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </div>

      {editorOpen && (
        <aside className="scheduled-editor" aria-label={t("scheduled.editor")}>
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
            <label>
              <span>{t("scheduled.name")}</span>
              <input
                value={draft.title}
                maxLength={120}
                onChange={(event) =>
                  setDraft((value) => ({ ...value, title: event.target.value }))
                }
              />
            </label>

            <label>
              <span>{t("scheduled.workspace")}</span>
              <select
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
                {snapshot.workspaces.map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.displayName || item.canonicalRoot}
                  </option>
                ))}
              </select>
            </label>

            <fieldset>
              <legend>{t("scheduled.what")}</legend>
              <div className="scheduled-segments">
                {(["text", "skill"] as const).map((kind) => (
                  <button
                    key={kind}
                    type="button"
                    data-active={draft.inputKind === kind}
                    onClick={() =>
                      setDraft((value) => ({ ...value, inputKind: kind }))
                    }
                  >
                    {t(`scheduled.input.${kind}`)}
                  </button>
                ))}
              </div>
              {draft.inputKind === "text" ? (
                <textarea
                  rows={7}
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
                      <option value="minutes">{t("scheduled.minutes")}</option>
                      <option value="hours">{t("scheduled.hours")}</option>
                      <option value="days">{t("scheduled.days")}</option>
                    </select>
                  </div>
                </label>
              )}
            </fieldset>

            {error && <p className="scheduled-error">{error}</p>}
          </div>

          <footer>
            {selected && (
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
      )}
    </section>
  );
}
