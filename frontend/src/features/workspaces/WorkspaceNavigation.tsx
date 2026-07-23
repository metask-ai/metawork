import { useEffect, useRef, useState } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import { SelectionMenu } from "../../components/ui/SelectionMenu.tsx";
import type { TaskView } from "../../bridge/contracts.ts";
import { taskCountMessageId } from "../../i18n/formatters.ts";
import { useI18n } from "../../i18n/context.ts";
import {
  taskGroups,
  taskDisplayState,
  taskSignals,
  type WorkspaceSummary,
} from "../../workbench/selectors.ts";

export function WorkspaceNavigation({
  summaries,
  currentWorkspaceId,
  tasks,
  activeTaskId,
  showArchived,
  disabled,
  onChooseWorkspace,
  onRemoveWorkspace,
  onRetryRemoval,
  onSelectWorkspace,
  onSelectTask,
  onToggleArchived,
}: {
  summaries: WorkspaceSummary[];
  currentWorkspaceId: string | null;
  tasks: TaskView[];
  activeTaskId: string | null;
  showArchived: boolean;
  disabled: boolean;
  onChooseWorkspace: () => void;
  onRemoveWorkspace: (workspaceId: string) => void;
  onRetryRemoval: (workspaceId: string) => void;
  onSelectWorkspace: (workspaceId: string) => void;
  onSelectTask: (id: string) => void;
  onToggleArchived: () => void;
}) {
  const { locale, t } = useI18n();
  const [removalConfirmId, setRemovalConfirmId] = useState<string | null>(null);
  const workspaceSectionHeading = useRef<HTMLDivElement>(null);
  const removalTrigger = useRef<HTMLButtonElement>(null);
  const removalCancel = useRef<HTMLButtonElement>(null);
  const groupedTasks = taskGroups(tasks, showArchived);
  const visibleTaskCount = groupedTasks.reduce(
    (count, group) => count + group.tasks.length,
    0,
  );
  const archivedCount = tasks.filter((task) => task.archived).length;
  const current = summaries.find((item) => item.id === currentWorkspaceId);

  useEffect(() => {
    if (
      removalConfirmId !== null &&
      (removalConfirmId !== currentWorkspaceId ||
        current?.authorization !== "available")
    )
      setRemovalConfirmId(null);
  }, [current?.authorization, currentWorkspaceId, removalConfirmId]);

  useEffect(() => {
    if (removalConfirmId === null) return;
    window.requestAnimationFrame(() => removalCancel.current?.focus());
  }, [removalConfirmId]);

  function closeRemovalConfirmation(returnToTrigger: boolean) {
    setRemovalConfirmId(null);
    window.requestAnimationFrame(() =>
      (returnToTrigger
        ? removalTrigger
        : workspaceSectionHeading
      ).current?.focus(),
    );
  }

  return (
    <>
      <section className="workspace-card">
        <div
          ref={workspaceSectionHeading}
          className="workspace-section-heading focus-ring"
          tabIndex={-1}
          aria-label={t("workspace.label")}
        >
          <p className="section-label">{t("workspace.label")}</p>
          <span className="workspace-heading-actions">
            {current && (
              <button
                ref={removalTrigger}
                className="text-button focus-ring"
                disabled={disabled || current.authorization !== "available"}
                onClick={() => setRemovalConfirmId(current.id)}
              >
                {t("workspace.remove")}
              </button>
            )}
            <button
              className="text-button focus-ring"
              disabled={disabled}
              onClick={onChooseWorkspace}
            >
              {t("workspace.add")}
            </button>
          </span>
        </div>
        <div className="workspace-switcher">
          <SelectionMenu
            value={currentWorkspaceId ?? ""}
            options={summaries.map((workspace) => ({
              value: workspace.id,
              label: workspace.label,
              description: workspace.canonicalRoot,
              disabled: workspace.authorization === "removing",
              trailing: <WorkspaceSignals workspace={workspace} />,
            }))}
            placeholder={t("workspace.none")}
            ariaLabel={t("workspace.switch")}
            disabled={disabled || summaries.length === 0}
            leading={<Icon name="workspace" />}
            triggerClassName="workspace-picker"
            contentClassName="workspace-menu"
            onValueChange={onSelectWorkspace}
          />
        </div>
        {current?.authorization === "removing" && (
          <p className="workspace-removing" role="status">
            {t("workspace.removing_notice")}
          </p>
        )}
        {current?.lastRemovalFailure === "task_close_failed" && (
          <div className="workspace-removal-warning" role="alert">
            <p>{t("mutation.reason.removal_failed")}</p>
            <button
              className="text-button focus-ring"
              disabled={disabled}
              onClick={() => onRetryRemoval(current.id)}
            >
              {t("workspace.retry_removal")}
            </button>
          </div>
        )}
        {current && removalConfirmId === current.id && (
          <div
            className="workspace-removal-confirmation"
            role="group"
            aria-labelledby="workspace-remove-confirm-title"
            aria-describedby="workspace-remove-confirm-body"
            onKeyDown={(event) => {
              if (event.key !== "Escape") return;
              event.preventDefault();
              closeRemovalConfirmation(true);
            }}
          >
            <strong id="workspace-remove-confirm-title">
              {t("workspace.remove_confirm_title")}
            </strong>
            <p id="workspace-remove-confirm-body">
              {t("workspace.remove_confirm_body")}
            </p>
            <span>
              <button
                ref={removalCancel}
                className="text-button focus-ring"
                onClick={() => closeRemovalConfirmation(true)}
              >
                {t("common.cancel")}
              </button>
              <button
                className="text-button is-danger focus-ring"
                disabled={disabled}
                onClick={() => {
                  closeRemovalConfirmation(false);
                  onRemoveWorkspace(current.id);
                }}
              >
                {t("workspace.remove_confirm_action")}
              </button>
            </span>
          </div>
        )}
      </section>

      <nav className="task-list" aria-label={t("task.list")}>
        <div className="task-list-heading">
          <p className="section-label">{t("task.list")}</p>
          <span>
            {t(taskCountMessageId(locale, visibleTaskCount), {
              count: visibleTaskCount,
            })}
          </span>
        </div>
        {groupedTasks.map((group) => (
          <section className="task-group" key={group.kind}>
            <h3>{t(`task.group.${group.kind}`)}</h3>
            {group.tasks.map((task) => (
              <button
                key={task.id}
                className="task-list-item focus-ring"
                aria-current={activeTaskId === task.id ? "page" : undefined}
                onClick={() => onSelectTask(task.id)}
              >
                <span className="task-list-row">
                  <span>{task.title || t("task.item", { id: task.id })}</span>
                  <TaskSignals task={task} />
                </span>
                <span className="task-list-meta">
                  {task.archived ? t("task.archived") : taskStateLabel(task, t)}
                </span>
              </button>
            ))}
          </section>
        ))}
        {visibleTaskCount === 0 && (
          <p className="task-list-empty">
            {tasks.length > 0 ? t("task.archived_hidden") : t("task.no_tasks")}
          </p>
        )}
        {archivedCount > 0 && (
          <button
            className="archived-toggle focus-ring"
            onClick={onToggleArchived}
          >
            {showArchived
              ? t("task.hide_archived")
              : t("task.show_archived", { count: archivedCount })}
          </button>
        )}
      </nav>
    </>
  );
}

function WorkspaceSignals({ workspace }: { workspace: WorkspaceSummary }) {
  const { t } = useI18n();
  return (
    <span className="workspace-signals">
      {workspace.attention > 0 && (
        <span data-signal="attention">
          {t("workspace.attention_count", { count: workspace.attention })}
        </span>
      )}
      {workspace.running > 0 && (
        <span data-signal="running">
          {t("workspace.running_count", { count: workspace.running })}
        </span>
      )}
      {workspace.failed > 0 && (
        <span data-signal="failed">
          {t("workspace.failed_count", { count: workspace.failed })}
        </span>
      )}
      {workspace.lastRemovalFailure !== null && (
        <span data-signal="failed">{t("workspace.removal_failed_short")}</span>
      )}
      {workspace.authorization === "removing" && (
        <span data-signal="attention">{t("workspace.removing_short")}</span>
      )}
    </span>
  );
}

export function TaskSignals({ task }: { task: TaskView }) {
  const { t } = useI18n();
  const signals = taskSignals(task);
  const signal = signals.attention
    ? "attention"
    : signals.running
      ? "running"
      : signals.failed
        ? "failed"
        : null;
  if (!signal) return null;
  return (
    <span className="task-signal" data-signal={signal}>
      {t(`task.signal.${signal}`)}
    </span>
  );
}

function taskStateLabel(task: TaskView, t: ReturnType<typeof useI18n>["t"]) {
  const state = taskDisplayState(task);
  if (state.kind === "phase") return t(`task.phase.${state.value}`);
  if (state.kind === "lifecycle") return t(`task.lifecycle.${state.value}`);
  if (state.kind === "archived") return t("task.archived");
  if (state.kind === "outcome")
    return t("task.last_result", {
      result: t(`outcome.${state.value}`),
    });
  return t("task.ready");
}
