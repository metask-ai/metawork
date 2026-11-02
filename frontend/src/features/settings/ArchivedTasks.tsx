import { useEffect, useRef } from "react";
import type { TaskSummary, WorkspaceView } from "../../bridge/contracts.ts";
import { Button } from "../../components/ui/button.tsx";
import { DiagnosticDisclosure } from "../../components/ui/DiagnosticDisclosure.tsx";
import { useI18n } from "../../i18n/context.ts";

export type ArchivedTasksProps = {
  tasks: TaskSummary[];
  workspaces: WorkspaceView[];
  query: string;
  pending: Record<string, string>;
  errors?: Record<string, string>;
  diagnostics?: Record<string, string>;
  synchronized: boolean;
  scrollTop?: number;
  focusTaskId?: string | null;
  onScroll?: (scrollTop: number) => void;
  onQuery: (query: string) => void;
  onOpen: (task: TaskSummary) => void;
  onRestore: (task: TaskSummary) => void;
  onDelete: (task: TaskSummary) => void;
};

export function ArchivedTasks({
  tasks,
  workspaces,
  query,
  pending,
  errors = {},
  diagnostics = {},
  synchronized,
  focusTaskId = null,
  onQuery,
  onOpen,
  onRestore,
  onDelete,
}: ArchivedTasksProps) {
  const { t } = useI18n();
  const heading = useRef<HTMLHeadingElement>(null);
  const list = useRef<HTMLUListElement>(null);
  const lastFocusedTask = useRef<string | null>(null);
  useEffect(() => {
    const row = focusTaskId
      ? document.querySelector<HTMLElement>(
          `[data-archived-task-id="${CSS.escape(focusTaskId)}"] button`,
        )
      : null;
    (row ?? heading.current)?.focus();
  }, []);
  const archived = tasks
    .filter((task) => task.archived)
    .sort((a, b) => {
      const left = BigInt(a.recentOrder),
        right = BigInt(b.recentOrder);
      return left > right ? -1 : left < right ? 1 : 0;
    });
  const needle = query.trim().toLocaleLowerCase();
  const visible = archived.filter((task) =>
    task.title.toLocaleLowerCase().includes(needle),
  );
  const visibleIds = visible.map((task) => task.id).join(",");
  useEffect(() => {
    if (
      lastFocusedTask.current &&
      !visible.some((task) => task.id === lastFocusedTask.current) &&
      document.activeElement === document.body
    ) {
      (
        list.current?.querySelector<HTMLElement>(".archived-task-title") ??
        heading.current
      )?.focus();
      lastFocusedTask.current = null;
    }
  }, [visibleIds]);
  return (
    <section id="settings-archived" className="settings-section">
      <div className="settings-section-heading">
        <h2 ref={heading} tabIndex={-1}>
          {t("settings.archived_tasks")}
        </h2>
      </div>
      <div className="settings-group archived-tasks">
        <label className="sr-only" htmlFor="archived-task-search">
          {t("archive.search")}
        </label>
        <input
          id="archived-task-search"
          className="archived-task-search focus-ring"
          type="search"
          value={query}
          onChange={(event) => onQuery(event.target.value)}
          placeholder={t("archive.search")}
        />
        {!synchronized && <p role="status">{t("archive.sync_unavailable")}</p>}
        {(synchronized || archived.length > 0) && (
          <p className="archived-task-count">
            {t("archive.count", { count: archived.length })}
          </p>
        )}
        <ul
          ref={list}
          className="settings-preference-list archived-task-list"
          aria-label={t("settings.archived_tasks")}
        >
          {visible.map((task) => {
            const workspace = workspaces.find(
              (entry) => entry.id === task.workspaceId,
            );
            const busy =
              !synchronized ||
              `task:${task.id}` in pending ||
              task.deletionStatus === "deleting";
            return (
              <li
                className="settings-row archived-task-row"
                key={task.id}
                onFocusCapture={() => {
                  lastFocusedTask.current = task.id;
                }}
                data-archived-task-id={task.id}
              >
                <div className="archived-task-copy">
                  <button
                    type="button"
                    className="archived-task-title focus-ring"
                    onClick={() => onOpen(task)}
                    disabled={!synchronized}
                  >
                    {task.title || t("task.item", { id: task.id })}
                  </button>
                  {workspace && <p>{workspace.displayName}</p>}
                  {errors[task.id] && <p role="alert">{errors[task.id]}</p>}
                  {diagnostics[task.id] && (
                    <DiagnosticDisclosure
                      label={t("task.operation_diagnostics")}
                    >
                      <pre className="feedback-notice-details">
                        {diagnostics[task.id]}
                      </pre>
                    </DiagnosticDisclosure>
                  )}
                  {task.historyReadOnly && (
                    <p>{t("archive.history_read_only")}</p>
                  )}
                  {task.deletionStatus !== "idle" && (
                    <p role="status">
                      {t(
                        task.deletionStatus === "deleting"
                          ? "archive.deleting"
                          : "task.delete_failed",
                      )}
                    </p>
                  )}
                </div>
                <div className="archived-task-actions">
                  <Button
                    variant="secondary"
                    size="sm"
                    disabled={
                      busy ||
                      task.historyReadOnly ||
                      task.lifecycle === "closing" ||
                      task.activeOperation !== null
                    }
                    onClick={() => onRestore(task)}
                  >
                    {t("task.restore")}
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    disabled={
                      busy ||
                      task.historyReadOnly ||
                      (task.lifecycle === "closing" &&
                        task.deletionStatus !== "failed")
                    }
                    onClick={() => onDelete(task)}
                  >
                    {t(
                      task.deletionStatus === "failed"
                        ? "task.delete_retry"
                        : "task.delete",
                    )}
                  </Button>
                </div>
              </li>
            );
          })}
        </ul>
        {synchronized && visible.length === 0 && (
          <p role="status">
            {t(archived.length === 0 ? "archive.empty" : "archive.no_results")}
          </p>
        )}
      </div>
    </section>
  );
}
