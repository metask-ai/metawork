import {
  useRef,
  useState,
  type MouseEvent,
  type KeyboardEvent,
  type ReactNode,
} from "react";

import type { TaskSummary, WorkspaceView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import {
  createContextMenuAnchor,
  type ContextMenuAnchor,
} from "../../components/ui/context-menu-anchor.ts";
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
  renderWorkspaceHeading,
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
  renderWorkspaceHeading?: (
    workspace: WorkspaceView,
    heading: ReactNode,
  ) => ReactNode;
  taskMutationDisabled: boolean;
  synchronized?: boolean;
  retainedTaskCount?: number;
}) {
  const { locale, t } = useI18n();
  const [menuTaskId, setMenuTaskId] = useState<string | null>(null);
  const [menuAnchor, setMenuAnchor] = useState<ContextMenuAnchor | null>(null);
  const menuTrigger = useRef<HTMLButtonElement>(null);
  const menuPopup = useRef<HTMLDivElement>(null);
  const keyboardOpen = useRef(false);
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

  function archiveDisabled(task: TaskSummary) {
    return (
      taskMutationDisabled ||
      task.historyReadOnly === true ||
      task.activeOperation !== null ||
      task.lifecycle === "closing"
    );
  }

  function openTaskMenu(
    event: MouseEvent<HTMLButtonElement> | KeyboardEvent<HTMLButtonElement>,
    taskId: string,
    anchorToElement = false,
  ) {
    event.preventDefault();
    openingDialog.current = false;
    menuTrigger.current = event.currentTarget;
    keyboardOpen.current = anchorToElement || !("clientX" in event);
    setMenuAnchor(
      "clientX" in event && !anchorToElement
        ? createContextMenuAnchor(
            event.currentTarget,
            event.clientX,
            event.clientY,
          )
        : event.currentTarget,
    );
    setMenuTaskId(taskId);
  }

  function renderTask(task: TaskSummary) {
    return (
      <div key={task.id} className="task-list-entry">
        <button
          data-task-id={task.id}
          className="task-list-item focus-ring"
          aria-current={activeTaskId === task.id ? "page" : undefined}
          onClick={() => onSelectTask(task.id)}
          onContextMenu={(event) => openTaskMenu(event, task.id)}
          aria-haspopup="menu"
          aria-expanded={menuTaskId === task.id}
          onKeyDown={(event) => {
            if (
              event.key === "ContextMenu" ||
              (event.shiftKey && event.key === "F10")
            )
              openTaskMenu(event, task.id);
          }}
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
        <button
          type="button"
          className="icon-button task-list-action task-list-archive-trigger focus-ring"
          aria-label={t("task.archive_for", {
            title: task.title || t("task.item", { id: task.id }),
          })}
          title={t("task.archive")}
          disabled={archiveDisabled(task)}
          onClick={() => onTaskAction(task, "archive")}
          onContextMenu={(event) => openTaskMenu(event, task.id)}
        >
          <Icon name="archive" />
        </button>
        <button
          type="button"
          className="icon-button task-list-action task-list-menu-trigger focus-ring"
          aria-label={t("task.actions_for", {
            title: task.title || t("task.item", { id: task.id }),
          })}
          title={t("task.actions")}
          aria-haspopup="menu"
          aria-expanded={menuTaskId === task.id}
          onClick={(event) => openTaskMenu(event, task.id, true)}
          onContextMenu={(event) => openTaskMenu(event, task.id)}
        >
          <Icon name="more" />
        </button>
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
            const heading = (
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
            );
            return (
              <section
                key={workspace.id}
                className="task-project"
                data-workspace-id={workspace.id}
                aria-label={workspace.displayName}
              >
                {renderWorkspaceHeading?.(workspace, heading) ?? heading}
                {workspace.authorization === "removing" && (
                  <p className="task-list-empty" role="status">
                    {t("workspace.removing_short")}
                  </p>
                )}
                {workspace.lastRemovalFailure && (
                  <p className="task-list-empty" role="alert">
                    {t("workspace.remove_close_failed")}
                  </p>
                )}
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
        onOpenChangeComplete={(open) => {
          if (open && keyboardOpen.current)
            window.requestAnimationFrame(() => {
              if (menuTrigger.current?.getAttribute("aria-expanded") !== "true")
                return;
              menuPopup.current
                ?.querySelector<HTMLElement>(
                  '[role="menuitem"]:not([aria-disabled="true"]):not([data-disabled])',
                )
                ?.focus();
            });
        }}
        open={menuTask !== null}
        onOpenChange={(open) => {
          if (open) return;
          setMenuTaskId(null);
        }}
      >
        <Menu.Portal>
          <Menu.Positioner
            anchor={menuAnchor}
            positionMethod="fixed"
            sticky
            side="bottom"
            align="start"
            sideOffset={keyboardOpen.current ? 2 : 0}
            alignOffset={0}
            arrowPadding={0}
            collisionPadding={8}
          >
            <Menu.Popup
              ref={menuPopup}
              finalFocus={() =>
                openingDialog.current
                  ? false
                  : menuTrigger.current?.isConnected
                    ? menuTrigger.current
                    : false
              }
              className="task-menu-popover"
              aria-label={t("task.actions")}
            >
              {menuTask && (
                <>
                  <Menu.Item
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
                    <Icon name="edit" />
                    {t("task.rename")}
                  </Menu.Item>
                  <Menu.Item
                    disabled={archiveDisabled(menuTask)}
                    onClick={() => onTaskAction(menuTask, "archive")}
                  >
                    <Icon name="archive" />
                    {menuTask.archived ? t("task.restore") : t("task.archive")}
                  </Menu.Item>
                  <Menu.Item
                    variant="danger"
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
                    <Icon name="trash" />
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
