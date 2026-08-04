import type { TaskView, WorkspaceView } from "../../bridge/contracts.ts";
import { taskCountMessageId } from "../../i18n/formatters.ts";
import { useI18n } from "../../i18n/context.ts";
import {
  taskGroups,
  taskDisplayState,
  taskSignals,
  workspaceDirectoryLabel,
} from "../../workbench/selectors.ts";

export function TaskList({
  tasks,
  workspaces,
  activeTaskId,
  showArchived,
  onSelectTask,
  onToggleArchived,
}: {
  tasks: TaskView[];
  workspaces: WorkspaceView[];
  activeTaskId: string | null;
  showArchived: boolean;
  onSelectTask: (id: string) => void;
  onToggleArchived: () => void;
}) {
  const { locale, t } = useI18n();
  const groupedTasks = taskGroups(tasks, showArchived);
  const visibleTaskCount = groupedTasks.reduce(
    (count, group) => count + group.tasks.length,
    0,
  );
  const archivedCount = tasks.filter((task) => task.archived).length;
  const visibleTasks = groupedTasks.flatMap((group) => group.tasks);
  const titleCounts = new Map<string, number>();
  for (const task of visibleTasks) {
    const title = task.title.trim();
    if (title) titleCounts.set(title, (titleCounts.get(title) ?? 0) + 1);
  }
  const workspacesById = new Map(
    workspaces.map((workspace) => [workspace.id, workspace]),
  );
  const workspaceContextByTaskId = new Map<string, string>();
  for (const task of visibleTasks) {
    if ((titleCounts.get(task.title.trim()) ?? 0) < 2) continue;
    const workspace = workspacesById.get(task.workspaceId);
    if (!workspace) continue;
    workspaceContextByTaskId.set(
      task.id,
      workspaceDirectoryLabel(workspace, t("workspace.default_directory")),
    );
  }

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
                {workspaceContextByTaskId.has(task.id) && (
                  <span title={workspaceContextByTaskId.get(task.id)}>
                    {` · ${workspaceContextByTaskId.get(task.id)}`}
                  </span>
                )}
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
