import {
  useId,
  useRef,
  useState,
  type MouseEvent,
  type DragEvent,
  type KeyboardEvent,
  type ReactNode,
} from "react";

import type { TaskSummary, WorkspaceView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { ProjectSelector } from "./ProjectSelector.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import {
  createContextMenuAnchor,
  type ContextMenuAnchor,
} from "../../components/ui/context-menu-anchor.ts";
import {
  taskActionBlockerMessageId,
  taskCountMessageId,
} from "../../i18n/formatters.ts";
import { useI18n } from "../../i18n/context.ts";
import {
  readLocalPreference,
  writeLocalPreference,
} from "../../platform/local-preferences.ts";
import { orderedProjects, orderedTasks } from "../../workbench/selectors.ts";

export type TaskMenuAction = "rename" | "archive" | "delete";

const collapsedProjectsPreference =
  "metawork.panel.workspaces.collapsedProjects";

function readCollapsedProjects(): Set<string> {
  const stored = readLocalPreference(collapsedProjectsPreference);
  if (stored !== null) {
    try {
      const ids: unknown = JSON.parse(stored);
      if (Array.isArray(ids)) {
        return new Set(ids.filter((id) => typeof id === "string"));
      }
    } catch {
      // A malformed preference restores the default expanded state.
    }
  }
  return new Set();
}

export function TaskList({
  tasks,
  workspaces,
  activeTaskId,
  suppressedCompletionTaskId = null,
  onSelectTask,
  onTaskAction,
  onSetProject,
  renderProjectFeedback,
  onAddProject,
  addProjectNotice,
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
  onSetProject?: (task: TaskSummary, projectId: string | null) => void;
  renderProjectFeedback?: (task: TaskSummary) => ReactNode;
  onAddProject?: () => void;
  addProjectNotice?: ReactNode;
  renderWorkspaceHeading?: (
    workspace: WorkspaceView,
    heading: ReactNode,
  ) => ReactNode;
  taskMutationDisabled: boolean;
  synchronized?: boolean;
  retainedTaskCount?: number;
}) {
  const { locale, t } = useI18n();
  const projectListId = useId();
  const draggedTask = useRef<string | null>(null);
  const menuSourceTask = useRef<string | null>(null);
  const [dropTarget, setDropTarget] = useState<string | null | undefined>(
    undefined,
  );
  const [collapsedProjects, setCollapsedProjects] = useState(
    readCollapsedProjects,
  );
  const [projectTarget, setProjectTarget] = useState<{
    taskId: string;
    open: boolean;
  } | null>(null);
  const projectDialog = useRef<HTMLDivElement>(null);
  const [menuTaskId, setMenuTaskId] = useState<string | null>(null);
  const [menuAnchor, setMenuAnchor] = useState<ContextMenuAnchor | null>(null);
  const menuTrigger = useRef<HTMLButtonElement>(null);
  const menuPopup = useRef<HTMLDivElement>(null);
  const keyboardOpen = useRef(false);
  const openingDialog = useRef(false);
  const visibleTasks = orderedTasks(tasks);
  const visibleTaskCount = visibleTasks.length;
  const projects = orderedProjects(workspaces);

  const menuTask =
    menuTaskId === null
      ? null
      : (tasks.find((task) => task.id === menuTaskId) ?? null);
  const projectTask = tasks.find((task) => task.id === projectTarget?.taskId);
  const menuTaskReadOnly = menuTask?.historyReadOnly === true;

  function toggleProject(workspaceId: string) {
    const next = new Set(collapsedProjects);
    if (next.has(workspaceId)) next.delete(workspaceId);
    else next.add(workspaceId);
    writeLocalPreference(
      collapsedProjectsPreference,
      JSON.stringify([...next]),
    );
    setCollapsedProjects(next);
  }

  function archiveDisabled(task: TaskSummary) {
    return taskMutationDisabled || task.archiveBlocker !== null;
  }

  function openTaskMenu(
    event: MouseEvent<HTMLButtonElement> | KeyboardEvent<HTMLButtonElement>,
    taskId: string,
    anchorToElement = false,
  ) {
    event.preventDefault();
    openingDialog.current = false;
    menuTrigger.current = event.currentTarget;
    keyboardOpen.current =
      !("clientX" in event) || (anchorToElement && event.detail === 0);
    setMenuAnchor(
      "clientX" in event && !anchorToElement
        ? createContextMenuAnchor(
            event.currentTarget,
            event.clientX,
            event.clientY,
          )
        : event.currentTarget,
    );
    menuSourceTask.current = taskId;
    setMenuTaskId(taskId);
  }

  function dragAllowed(task: TaskSummary) {
    return (
      synchronized &&
      !taskMutationDisabled &&
      !task.historyReadOnly &&
      task.lifecycle === "open" &&
      task.deletionStatus !== "deleting"
    );
  }
  function dropProject(event: DragEvent, projectId: string | null) {
    if (
      !event.dataTransfer.types.includes("application/x-metawork-task") ||
      event.dataTransfer.files.length > 0
    )
      return;
    const task = tasks.find((task) => task.id === draggedTask.current);
    if (!task || !dragAllowed(task) || !onSetProject) return;
    event.preventDefault();
    draggedTask.current = null;
    setDropTarget(undefined);
    onSetProject(task, projectId);
  }
  function dragOver(event: DragEvent, projectId: string | null) {
    if (
      !event.dataTransfer.types.includes("application/x-metawork-task") ||
      event.dataTransfer.files.length > 0
    )
      return;
    const task = tasks.find((task) => task.id === draggedTask.current);
    if (!task || !dragAllowed(task) || !onSetProject) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    setDropTarget(projectId);
  }
  function renderTask(task: TaskSummary, recent = false) {
    return (
      <div key={task.id} className="task-list-entry">
        <button
          data-task-id={task.id}
          data-task-recent={recent ? "true" : undefined}
          draggable={dragAllowed(task) && Boolean(onSetProject)}
          onDragStart={(event) => {
            if (!dragAllowed(task)) {
              event.preventDefault();
              return;
            }
            draggedTask.current = task.id;
            event.dataTransfer.effectAllowed = "move";
            event.dataTransfer.setData("application/x-metawork-task", task.id);
          }}
          onDragEnd={() => {
            draggedTask.current = null;
            setDropTarget(undefined);
          }}
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
          <span className="task-list-title">
            <span className="task-list-title-text">
              {task.title || t("task.item", { id: task.id })}
            </span>
          </span>
          <TaskSignals
            task={task}
            synchronized={synchronized}
            completionSuppressed={suppressedCompletionTaskId === task.id}
          />
        </button>
        <button
          type="button"
          className="icon-button task-list-action task-list-archive-trigger focus-ring"
          aria-label={t("task.archive_for", {
            title: task.title || t("task.item", { id: task.id }),
          })}
          title={t(
            task.archiveBlocker
              ? taskActionBlockerMessageId(task.archiveBlocker)
              : "task.archive",
          )}
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
        {recent && renderProjectFeedback?.(task)}
      </div>
    );
  }

  return (
    <nav className="task-list" aria-label={t("task.list")}>
      {(projects.length > 0 || onAddProject) && (
        <section className="task-projects" aria-label={t("task.projects")}>
          <div className="task-list-heading">
            <p className="section-label">{t("task.projects")}</p>
            {onAddProject && (
              <button
                type="button"
                className="icon-button focus-ring"
                aria-label={t("task.add_project")}
                title={t("task.add_project")}
                disabled={taskMutationDisabled}
                onClick={onAddProject}
              >
                <Icon name="plus" />
              </button>
            )}
          </div>
          {addProjectNotice}
          {projects.map((workspace) => {
            const expanded = !collapsedProjects.has(workspace.id);
            const itemsId = `${projectListId}-project-${workspace.id}`;
            const projectTasks = visibleTasks.filter(
              (task) => task.projectId === workspace.id,
            );
            const heading = (
              <h3>
                <button
                  type="button"
                  className="task-project-heading focus-ring"
                  aria-expanded={expanded}
                  aria-controls={itemsId}
                  title={
                    workspace.redacted
                      ? workspace.displayName
                      : workspace.canonicalRoot
                  }
                  onClick={() => toggleProject(workspace.id)}
                >
                  <Icon name="workspace" />
                  <span>{workspace.displayName}</span>
                </button>
              </h3>
            );
            return (
              <section
                key={workspace.id}
                className="task-project"
                data-workspace-id={workspace.id}
                data-drop-target={dropTarget === workspace.id}
                onDragOver={(event) => dragOver(event, workspace.id)}
                onDragLeave={(event) => {
                  if (
                    !(event.relatedTarget instanceof Node) ||
                    !event.currentTarget.contains(event.relatedTarget)
                  )
                    setDropTarget(undefined);
                }}
                onDrop={(event) => dropProject(event, workspace.id)}
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
                <div
                  id={itemsId}
                  className="task-project-items"
                  aria-hidden={!expanded}
                  inert={!expanded}
                >
                  <div className="task-project-items-content">
                    {projectTasks.map((task) => renderTask(task))}
                    {projectTasks.length === 0 && (
                      <p className="task-list-empty">
                        {tasks.some((task) => task.projectId === workspace.id)
                          ? t("task.archived_hidden")
                          : t("task.project_empty")}
                      </p>
                    )}
                  </div>
                </div>
              </section>
            );
          })}
        </section>
      )}
      <div
        className="task-list-heading"
        data-drop-target={dropTarget === null}
        onDragOver={(event) => dragOver(event, null)}
        onDrop={(event) => dropProject(event, null)}
      >
        <p className="section-label">{t("task.recent")}</p>
        <span>
          {t(taskCountMessageId(locale, visibleTaskCount), {
            count: visibleTaskCount,
          })}
        </span>
      </div>
      {visibleTasks.map((task) => renderTask(task, true))}
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
      {onSetProject && (
        <Dialog.Root
          open={Boolean(projectTask && projectTarget?.open)}
          onOpenChangeComplete={(open) => {
            if (open) return;
            const taskId = projectTarget?.taskId;
            setProjectTarget(null);
            // The nested selector must release its focus trap before the
            // dialog returns focus to the chat's stable Recent row.
            window.requestAnimationFrame(() => {
              const target = document.querySelector<HTMLButtonElement>(
                `[data-task-recent="true"][data-task-id="${CSS.escape(taskId ?? "")}"]`,
              );
              (
                target ??
                document.querySelector<HTMLButtonElement>(
                  ".task-list-item, .sidebar-capability",
                )
              )?.focus();
            });
          }}
          onOpenChange={(open) => {
            if (!open)
              setProjectTarget((current) =>
                current ? { ...current, open: false } : null,
              );
          }}
        >
          <Dialog.Portal>
            <Dialog.Backdrop />
            <Dialog.Popup
              ref={projectDialog}
              initialFocus={() =>
                projectDialog.current?.querySelector<HTMLElement>(
                  '[role="combobox"]',
                ) ?? false
              }
              finalFocus={false}
            >
              <Dialog.Title>
                {t(
                  projectTask?.projectId === null
                    ? "task.move_to_project"
                    : "task.change_project",
                )}
              </Dialog.Title>
              <Dialog.Description>
                {t("task.project_change_body")}
              </Dialog.Description>
              {projectTask && (
                <ProjectSelector
                  projectId={projectTask.projectId}
                  workspaces={workspaces}
                  disabled={
                    taskMutationDisabled ||
                    Boolean(projectTask.historyReadOnly) ||
                    projectTask.lifecycle !== "open" ||
                    projectTask.deletionStatus === "deleting"
                  }
                  onSelect={(projectId) => {
                    onSetProject(projectTask, projectId);
                    setProjectTarget((current) =>
                      current ? { ...current, open: false } : null,
                    );
                  }}
                />
              )}
              <div className="delete-confirmation-actions">
                <Button
                  variant="secondary"
                  onClick={() =>
                    setProjectTarget((current) =>
                      current ? { ...current, open: false } : null,
                    )
                  }
                >
                  {t("common.cancel")}
                </Button>
              </div>
            </Dialog.Popup>
          </Dialog.Portal>
        </Dialog.Root>
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
            sideOffset={menuAnchor && !("contextElement" in menuAnchor) ? 2 : 0}
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
                    : menuSourceTask.current
                      ? document.querySelector<HTMLButtonElement>(
                          `[data-task-id="${CSS.escape(menuSourceTask.current)}"]`,
                        )
                      : document.querySelector<HTMLButtonElement>(
                          ".task-list-item",
                        )
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
                    title={
                      menuTask.archiveBlocker
                        ? t(taskActionBlockerMessageId(menuTask.archiveBlocker))
                        : undefined
                    }
                    onClick={() => onTaskAction(menuTask, "archive")}
                  >
                    <Icon name="archive" />
                    {menuTask.archived ? t("task.restore") : t("task.archive")}
                  </Menu.Item>
                  {onSetProject && (
                    <Menu.Item
                      disabled={
                        taskMutationDisabled ||
                        menuTaskReadOnly ||
                        menuTask.lifecycle !== "open" ||
                        menuTask.deletionStatus === "deleting"
                      }
                      onClick={() => {
                        openingDialog.current = true;
                        setProjectTarget({
                          taskId: menuTask.id,
                          open: true,
                        });
                      }}
                    >
                      <Icon name="workspace" />
                      {t(
                        menuTask.projectId === null
                          ? "task.move_to_project"
                          : "task.change_project",
                      )}
                    </Menu.Item>
                  )}
                  <Menu.Item
                    variant="danger"
                    disabled={
                      taskMutationDisabled || menuTask.deleteBlocker !== null
                    }
                    title={
                      menuTask.deleteBlocker
                        ? t(taskActionBlockerMessageId(menuTask.deleteBlocker))
                        : undefined
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
  if (
    !synchronized &&
    (task.signal === "running" || task.signal === "attention")
  )
    return null;
  const signal =
    task.signal ??
    (task.unreadCompletionRunId !== null &&
    showCompleted &&
    !completionSuppressed
      ? "completed"
      : task.archived
        ? "archived"
        : null);
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
