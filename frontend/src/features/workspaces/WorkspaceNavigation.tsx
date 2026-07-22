import { useEffect, useRef, useState } from "react";

import { Icon } from "../../components/ui/Icon.tsx";
import type { TaskView } from "../../bridge/contracts.ts";
import { taskCountMessageId } from "../../i18n/formatters.ts";
import { useI18n } from "../../i18n/context.ts";
import {
  taskDisplayState,
  taskSignals,
  workspaceLabel,
  type WorkspaceSummary,
} from "../../workbench/selectors.ts";

export function WorkspaceNavigation({
  summaries,
  currentWorkspace,
  tasks,
  activeTaskId,
  selectedPath,
  grantReady,
  showArchived,
  disabled,
  onSearch,
  onChooseWorkspace,
  onSelectWorkspace,
  onCreateTask,
  onSelectTask,
  onToggleArchived,
}: {
  summaries: WorkspaceSummary[];
  currentWorkspace: string | null;
  tasks: TaskView[];
  activeTaskId: string | null;
  selectedPath: string;
  grantReady: boolean;
  showArchived: boolean;
  disabled: boolean;
  onSearch: () => void;
  onChooseWorkspace: () => void;
  onSelectWorkspace: (root: string) => void;
  onCreateTask: () => void;
  onSelectTask: (id: string) => void;
  onToggleArchived: () => void;
}) {
  const { locale, t } = useI18n();
  const [switcherOpen, setSwitcherOpen] = useState(false);
  const switcher = useRef<HTMLDivElement>(null);
  const visibleTasks = tasks.filter((task) => showArchived || !task.archived);
  const archivedCount = tasks.filter((task) => task.archived).length;
  const current = summaries.find((item) => item.root === currentWorkspace);

  useEffect(() => {
    if (!switcherOpen) return;
    const dismiss = (event: MouseEvent) => {
      if (!switcher.current?.contains(event.target as Node))
        setSwitcherOpen(false);
    };
    document.addEventListener("mousedown", dismiss);
    return () => document.removeEventListener("mousedown", dismiss);
  }, [switcherOpen]);

  return (
    <>
      <button className="global-search focus-ring" onClick={onSearch}>
        <span>{t("search.open")}</span>
        <kbd>⌘K</kbd>
      </button>

      <section className="workspace-card">
        <div className="workspace-section-heading">
          <p className="section-label">{t("workspace.label")}</p>
          <button
            className="text-button focus-ring"
            disabled={disabled}
            onClick={onChooseWorkspace}
          >
            {t("workspace.add")}
          </button>
        </div>
        <div className="workspace-switcher" ref={switcher}>
          <button
            className="workspace-picker focus-ring"
            aria-expanded={switcherOpen}
            aria-haspopup="listbox"
            disabled={summaries.length === 0 && !selectedPath}
            onClick={() => setSwitcherOpen((open) => !open)}
          >
            <Icon name="workspace" />
            <span className="truncate">
              {current?.label ||
                (selectedPath ? workspaceLabel(selectedPath) : "") ||
                t("workspace.none")}
            </span>
            <Icon name="chevron" />
          </button>
          {switcherOpen && summaries.length > 0 && (
            <div
              className="workspace-menu"
              role="listbox"
              aria-label={t("workspace.switch")}
            >
              {summaries.map((workspace) => (
                <button
                  key={workspace.root}
                  className="workspace-option focus-ring"
                  role="option"
                  aria-selected={workspace.root === currentWorkspace}
                  onClick={() => {
                    onSelectWorkspace(workspace.root);
                    setSwitcherOpen(false);
                  }}
                >
                  <span className="workspace-option-copy">
                    <strong>{workspace.label}</strong>
                    <small>{workspace.root}</small>
                  </span>
                  <WorkspaceSignals workspace={workspace} />
                </button>
              ))}
            </div>
          )}
        </div>
        {grantReady && (
          <p className="workspace-grant">{t("workspace.grant_ready")}</p>
        )}
        <button
          className="primary-button focus-ring"
          disabled={disabled}
          onClick={onCreateTask}
        >
          {t("task.new")}
        </button>
      </section>

      <nav className="task-list" aria-label={t("task.list")}>
        <div className="task-list-heading">
          <p className="section-label">{t("task.list")}</p>
          <span>
            {t(taskCountMessageId(locale, visibleTasks.length), {
              count: visibleTasks.length,
            })}
          </span>
        </div>
        {visibleTasks.map((task) => (
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
        {visibleTasks.length === 0 && (
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
    <span className="workspace-signals" aria-label={t("workspace.activity")}>
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
