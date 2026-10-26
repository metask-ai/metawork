import { useRef, useState, type MouseEvent } from "react";

import type { TaskSummary, WorkspaceView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { taskCountMessageId } from "../../i18n/formatters.ts";
import { useI18n } from "../../i18n/context.ts";
import { orderedTasks, taskSignals } from "../../workbench/selectors.ts";

export type TaskMenuAction = "rename" | "archive" | "delete";

export function TaskList({
  tasks,
  workspaces,
  activeTaskId,
  suppressedCompletionTaskId = null,
  onSelectTask,
  onTaskAction,
  taskMutationDisabled,
  synchronized = true,
  retainedTaskCount = 0,
}: {
  tasks: TaskSummary[];
  workspaces: WorkspaceView[];
  activeTaskId: string | null;
  suppressedCompletionTaskId?: string | null;
  onSelectTask: (id: string) => void;
  onTaskAction: (task: TaskSummary, action: TaskMenuAction) => void;
  taskMutationDisabled: boolean;
  synchronized?: boolean;
  retainedTaskCount?: number;
}) {
  const { locale, t } = useI18n();
  const [menuTaskId, setMenuTaskId] = useState<string | null>(null);
  const menuAnchor = useRef<HTMLElement | null>(null);
  const openingDialog = useRef(false);
  const visibleTasks = orderedTasks(tasks);
  const visibleTaskCount = visibleTasks.length;
  const projects = workspaces
    .filter((workspace) => workspace.kind === "manual")
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
    openingDialog.current = false;
    menuAnchor.current = event.currentTarget;
    setMenuTaskId(taskId);
  }

  function renderTask(task: TaskSummary) {
    return (
      <button
        key={task.id}
        data-task-id={task.id}
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
              finalFocus={() => !openingDialog.current}
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
                    onClick={() => {
                      openingDialog.current = true;
                      onTaskAction(menuTask, "rename");
                    }}
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
                      menuTask.deletionStatus === "deleting" ||
                      (menuTask.lifecycle === "closing" &&
                        menuTask.deletionStatus !== "failed")
                    }
                    onClick={() => {
                      // The confirmation owns focus after the menu closes.
                      openingDialog.current = true;
                      onTaskAction(menuTask, "delete");
                    }}
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
        <Icon
          name={
            signal === "running"
              ? "loading"
              : signal === "archived"
                ? "archive"
                : "warning"
          }
        />
      )}
    </span>
  );
}
