import { useEffect, useRef, useState, type MouseEvent } from "react";

import type { TaskView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { taskCountMessageId } from "../../i18n/formatters.ts";
import { useI18n } from "../../i18n/context.ts";
import {
  taskGroups,
  taskCompletionNotificationKey,
  taskDisplayState,
  taskSignals,
} from "../../workbench/selectors.ts";

export type TaskMenuAction = "rename" | "archive" | "delete";

export function TaskList({
  tasks,
  activeTaskId,
  showArchived,
  onSelectTask,
  onToggleArchived,
  onTaskAction,
  taskMutationDisabled,
  synchronized = true,
}: {
  tasks: TaskView[];
  activeTaskId: string | null;
  showArchived: boolean;
  onSelectTask: (id: string) => void;
  onToggleArchived: () => void;
  onTaskAction: (task: TaskView, action: TaskMenuAction) => void;
  taskMutationDisabled: boolean;
  synchronized?: boolean;
}) {
  const { locale, t } = useI18n();
  const [seenCompletionKeys, setSeenCompletionKeys] = useState<Set<string>>(
    () => new Set(),
  );
  const [menuTaskId, setMenuTaskId] = useState<string | null>(null);
  const menuAnchor = useRef<HTMLElement | null>(null);
  const groupedTasks = taskGroups(tasks, showArchived);
  const visibleTaskCount = groupedTasks.reduce(
    (count, group) => count + group.tasks.length,
    0,
  );
  const archivedCount = tasks.filter((task) => task.archived).length;

  const menuTask =
    menuTaskId === null
      ? null
      : (tasks.find((task) => task.id === menuTaskId) ?? null);

  function openTaskMenu(event: MouseEvent<HTMLButtonElement>, taskId: string) {
    event.preventDefault();
    menuAnchor.current = event.currentTarget;
    setMenuTaskId(taskId);
  }

  useEffect(() => {
    const currentCompletionKeys = new Set(
      tasks
        .map(taskCompletionNotificationKey)
        .filter((key): key is string => key !== null),
    );
    const activeTask =
      activeTaskId === null
        ? null
        : (tasks.find((task) => task.id === activeTaskId) ?? null);
    const activeCompletionKey =
      activeTask === null ? null : taskCompletionNotificationKey(activeTask);

    setSeenCompletionKeys((previous) => {
      const next = new Set(
        [...previous].filter((key) => currentCompletionKeys.has(key)),
      );
      if (activeCompletionKey !== null) next.add(activeCompletionKey);
      if (
        next.size === previous.size &&
        [...next].every((key) => previous.has(key))
      )
        return previous;
      return next;
    });
  }, [activeTaskId, tasks]);

  return (
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
                  completionSeen={seenCompletionKeys.has(
                    taskCompletionNotificationKey(task) ?? "",
                  )}
                />
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
                      !menuTask.archived ||
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

export function TaskSignals({
  task,
  completionSeen = false,
  showCompleted = true,
  synchronized = true,
}: {
  task: TaskView;
  completionSeen?: boolean;
  showCompleted?: boolean;
  synchronized?: boolean;
}) {
  const { t } = useI18n();
  const signals = taskSignals(task);
  const state = taskDisplayState(task);
  if (!synchronized && (signals.running || signals.attention)) return null;
  const signal = signals.attention
    ? "attention"
    : signals.running
      ? "running"
      : signals.failed
        ? "failed"
        : state.kind === "outcome" &&
            state.value === "completed" &&
            showCompleted &&
            !completionSeen
          ? "completed"
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
        <Icon name={signal === "running" ? "loading" : "warning"} />
      )}
    </span>
  );
}
