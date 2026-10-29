import { isDemoProjectHidden, setDemoProjectHidden } from "../../demo/state.ts";
import { ArchiveRestore, Ellipsis } from "lucide-react";
import {
  useId,
  useRef,
  useState,
  type ButtonHTMLAttributes,
  type MouseEvent,
  type ReactNode,
} from "react";

import type { TaskSummary, WorkspaceView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { taskCountMessageId } from "../../i18n/formatters.ts";
import { useI18n } from "../../i18n/context.ts";
import { orderedTasks, taskSignals } from "../../workbench/selectors.ts";

export type TaskMenuAction = "rename" | "archive" | "delete";

export function TaskList({
  tasks,
  workspaces,
  activeTaskId,
  suppressedCompletionTaskId = null,
  showArchived,
  onSelectTask,
  onToggleArchived,
  onTaskAction,
  taskMutationDisabled,
  synchronized = true,
  retainedTaskCount = 0,
}: {
  tasks: TaskSummary[];
  workspaces: WorkspaceView[];
  activeTaskId: string | null;
  suppressedCompletionTaskId?: string | null;
  showArchived: boolean;
  onSelectTask: (id: string) => void;
  onToggleArchived: () => void;
  onTaskAction: (task: TaskSummary, action: TaskMenuAction) => void;
  taskMutationDisabled: boolean;
  synchronized?: boolean;
  retainedTaskCount?: number;
}) {
  const { locale, t } = useI18n();
  const [removedProject, setRemovedProject] = useState<WorkspaceView | null>(
    null,
  );
  const [menuTaskId, setMenuTaskId] = useState<string | null>(null);
  const menuAnchor = useRef<HTMLElement | null>(null);
  const visibleTasks = orderedTasks(tasks, showArchived);
  const visibleTaskCount = visibleTasks.length;
  const archivedCount = tasks.filter((task) => task.archived).length;
  const projects = workspaces
    .filter(
      (workspace) =>
        workspace.kind === "manual" &&
        !isDemoProjectHidden(workspace.canonicalRoot),
    )
    .sort((left, right) => {
      const leftOrder = BigInt(left.recentOrder);
      const rightOrder = BigInt(right.recentOrder);
      return rightOrder > leftOrder ? 1 : rightOrder < leftOrder ? -1 : 0;
    });

  const menuTask =
    menuTaskId === null
      ? null
      : (tasks.find((task) => task.id === menuTaskId) ?? null);
  const menuTaskReadOnly = menuTask?.historyReadOnly === true;

  function openTaskMenu(event: MouseEvent<HTMLButtonElement>, taskId: string) {
    event.preventDefault();
    menuAnchor.current = event.currentTarget;
    setMenuTaskId(taskId);
  }

  function renderTask(task: TaskSummary) {
    return (
      <div key={task.id} data-task-id={task.id} className="task-row-shell">
        <button
          className="task-list-item focus-ring"
          aria-current={activeTaskId === task.id ? "page" : undefined}
          onClick={() => onSelectTask(task.id)}
          onContextMenu={(event) => openTaskMenu(event, task.id)}
        >
          <span className="task-list-row">
            <span>{task.title || t("task.item", { id: task.id })}</span>
            <TaskSignals
              task={task}
              synchronized={synchronized}
              completionSuppressed={suppressedCompletionTaskId === task.id}
            />
          </span>
        </button>
        <div className="task-row-quick-actions">
          <TaskActionButton
            label={task.archived ? t("task.restore") : t("task.archive")}
            context={task.title}
            hint={t(
              task.archived
                ? "demo.task_restore_hint"
                : "demo.task_archive_hint",
            )}
            disabled={
              taskMutationDisabled ||
              task.historyReadOnly ||
              task.activeOperation !== null ||
              task.lifecycle === "closing"
            }
            disabledHint={t(
              task.historyReadOnly
                ? "demo.task_action_readonly"
                : task.activeOperation !== null
                  ? "demo.task_action_running"
                  : "demo.task_action_unavailable",
            )}
            onClick={() => onTaskAction(task, "archive")}
          >
            {task.archived ? (
              <ArchiveRestore size={16} aria-hidden="true" />
            ) : (
              <Icon name="archive" />
            )}
          </TaskActionButton>
          <TaskActionButton
            label={t("task.actions")}
            context={task.title}
            hint={t(
              task.archived
                ? "demo.task_actions_archived_hint"
                : "demo.task_actions_hint",
            )}
            menuExpanded={menuTaskId === task.id}
            onClick={(event) => openTaskMenu(event, task.id)}
          >
            <Ellipsis size={16} aria-hidden="true" />
          </TaskActionButton>
        </div>
      </div>
    );
  }

  return (
    <nav className="task-list" aria-label={t("task.list")}>
      {projects.length > 0 && (
        <section className="task-projects" aria-label={t("task.projects")}>
          <p className="section-label">{t("task.projects")}</p>
          {projects.map((workspace) => {
            const projectTasks = visibleTasks.filter(
              (task) => task.workspaceId === workspace.id,
            );
            return (
              <section
                key={workspace.id}
                className="task-project"
                data-workspace-id={workspace.id}
                aria-label={workspace.displayName}
              >
                <h3
                  className="task-project-heading"
                  title={
                    workspace.redacted
                      ? workspace.displayName
                      : workspace.canonicalRoot
                  }
                >
                  <Icon name="workspace" />
                  <span>{workspace.displayName}</span>
                  <button
                    type="button"
                    className="workspace-remove focus-ring"
                    aria-label={`${t("operation.workspace_remove")} · ${workspace.displayName}`}
                    title={t("demo.remove_project_body")}
                    disabled={taskMutationDisabled}
                    onClick={() => {
                      setDemoProjectHidden(workspace.canonicalRoot, true);
                      setRemovedProject(workspace);
                    }}
                  >
                    <Icon name="close" />
                  </button>
                </h3>
                <div className="task-project-items">
                  {projectTasks.map(renderTask)}
                  {projectTasks.length === 0 && (
                    <p className="task-list-empty">
                      {tasks.some((task) => task.workspaceId === workspace.id)
                        ? t("task.archived_hidden")
                        : t("task.project_empty")}
                    </p>
                  )}
                </div>
              </section>
            );
          })}
        </section>
      )}
      {removedProject && (
        <div className="workspace-removed-notice" role="status">
          <p>{t("demo.remove_project_body")}</p>
          <button
            type="button"
            className="text-button focus-ring"
            onClick={() => {
              setDemoProjectHidden(removedProject.canonicalRoot, false);
              setRemovedProject(null);
            }}
          >
            {t("demo.undo")}
          </button>
        </div>
      )}
      <div className="task-list-heading">
        <p className="section-label">{t("task.recent")}</p>
        <span>
          {t(taskCountMessageId(locale, visibleTaskCount), {
            count: visibleTaskCount,
          })}
        </span>
      </div>
      {visibleTasks.map(renderTask)}
      {visibleTaskCount === 0 && (
        <p className="task-list-empty">
          {tasks.length > 0 ? t("task.archived_hidden") : t("task.no_tasks")}
        </p>
      )}
      {retainedTaskCount > 0 && (
        <p className="task-list-empty">
          {t("task.history_retained", { count: retainedTaskCount })}
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
      <Menu.Root
        open={menuTask !== null}
        onOpenChange={(open) => {
          if (open) return;
          setMenuTaskId(null);
          menuAnchor.current = null;
        }}
      >
        <Menu.Portal>
          <Menu.Positioner
            anchor={menuAnchor.current}
            side="right"
            align="start"
            sideOffset={5}
            collisionPadding={8}
          >
            <Menu.Popup
              className="task-menu-popover"
              aria-label={t("task.actions")}
            >
              {menuTask && (
                <>
                  <Menu.Item
                    className="task-menu-item"
                    disabled={
                      taskMutationDisabled ||
                      menuTaskReadOnly ||
                      menuTask.deletionStatus === "deleting"
                    }
                    onClick={() => onTaskAction(menuTask, "rename")}
                  >
                    {t("task.rename")}
                  </Menu.Item>
                  <Menu.Item
                    className="task-menu-item"
                    disabled={
                      taskMutationDisabled ||
                      menuTaskReadOnly ||
                      menuTask.activeOperation !== null ||
                      menuTask.lifecycle === "closing"
                    }
                    onClick={() => onTaskAction(menuTask, "archive")}
                  >
                    {menuTask.archived ? t("task.restore") : t("task.archive")}
                  </Menu.Item>
                  <Menu.Item
                    className="task-menu-item is-danger"
                    disabled={
                      taskMutationDisabled ||
                      menuTaskReadOnly ||
                      menuTask.activeOperation !== null ||
                      menuTask.deletionStatus === "deleting" ||
                      (menuTask.lifecycle === "closing" &&
                        menuTask.deletionStatus !== "failed")
                    }
                    onClick={() => onTaskAction(menuTask, "delete")}
                  >
                    {t(
                      menuTask.deletionStatus === "failed"
                        ? "task.delete_retry"
                        : "task.delete",
                    )}
                  </Menu.Item>
                </>
              )}
            </Menu.Popup>
          </Menu.Positioner>
        </Menu.Portal>
      </Menu.Root>
    </nav>
  );
}

function TaskActionButton({
  label,
  context,
  hint,
  disabled = false,
  disabledHint,
  menuExpanded,
  onClick,
  children,
}: {
  label: string;
  context: string;
  hint: string;
  disabled?: boolean;
  disabledHint?: string;
  menuExpanded?: boolean;
  onClick: (event: MouseEvent<HTMLButtonElement>) => void;
  children: ReactNode;
}) {
  const id = useId();
  const [open, setOpen] = useState(false);
  const name = `${label} · ${context}`;
  function dismissForEscape(event: React.KeyboardEvent<HTMLElement>) {
    if (event.key !== "Escape" || !open) return;
    event.preventDefault();
    event.stopPropagation();
    setOpen(false);
  }
  const buttonProps: ButtonHTMLAttributes<HTMLButtonElement> = {
    type: "button",
    className: "icon-button focus-ring",
    "aria-label": name,
    "aria-describedby": open ? id : undefined,
    "aria-haspopup": menuExpanded === undefined ? undefined : "menu",
    "aria-expanded": menuExpanded,
    disabled,
    onKeyDown: dismissForEscape,
    onClick: (event) => {
      setOpen(false);
      onClick(event);
    },
  };
  return (
    <Tooltip.Root open={open} onOpenChange={setOpen}>
      {disabled ? (
        <Tooltip.Trigger
          delay={220}
          render={
            <span
              className="task-action-disabled"
              tabIndex={0}
              role="button"
              aria-label={name}
              aria-disabled="true"
              aria-describedby={open ? id : undefined}
              onKeyDown={dismissForEscape}
            />
          }
        >
          <button {...buttonProps} aria-hidden="true" tabIndex={-1}>
            {children}
          </button>
        </Tooltip.Trigger>
      ) : (
        <Tooltip.Trigger delay={220} render={<button {...buttonProps} />}>
          {children}
        </Tooltip.Trigger>
      )}
      <Tooltip.Portal>
        <Tooltip.Positioner side="top" align="center" collisionPadding={10}>
          <Tooltip.Popup id={id} role="tooltip" className="task-action-tooltip">
            <strong>{label}</strong>
            <span>{disabled ? disabledHint : hint}</span>
          </Tooltip.Popup>
        </Tooltip.Positioner>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

export function TaskSignals({
  task,
  completionSuppressed = false,
  showCompleted = true,
  synchronized = true,
}: {
  task: TaskSummary;
  completionSuppressed?: boolean;
  showCompleted?: boolean;
  synchronized?: boolean;
}) {
  const { t } = useI18n();
  const signals = taskSignals(task);
  if (!synchronized && (signals.running || signals.attention)) return null;
  const signal = signals.attention
    ? "attention"
    : signals.running
      ? "running"
      : signals.failed
        ? "failed"
        : task.unreadCompletionRunId !== null &&
            showCompleted &&
            !completionSuppressed
          ? "completed"
          : task.archived
            ? "archived"
            : null;
  if (signal === null) return null;

  const label = t(`task.signal.${signal}`);
  if (signal === "archived")
    return <span className="task-archived-label">{label}</span>;

  return (
    <span
      className="task-signal"
      data-signal={signal}
      role="img"
      aria-label={label}
      title={label}
    >
      {signal === "completed" ? (
        <span className="task-notification-dot" aria-hidden="true" />
      ) : (
        <Icon name={signal === "running" ? "loading" : "warning"} />
      )}
    </span>
  );
}
