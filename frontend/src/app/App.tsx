import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";

import { AppShell } from "./AppShell.tsx";
import { Icon } from "../components/ui/Icon.tsx";
import { ComposerFooter } from "../features/composer/ComposerFooter.tsx";
import { ApprovalPanel } from "../features/approvals/ApprovalPanel.tsx";
import { UiRecordCard } from "../features/approvals/UiRecordCard.tsx";
import {
  uiRequestIdentity,
  uiResponsePhase,
} from "../features/approvals/response-state.ts";
import { useUiResponseStates } from "../features/approvals/useUiResponseStates.ts";
import { GlobalSearch } from "../features/search/GlobalSearch.tsx";
import { TaskActivity } from "../features/task-activity/TaskActivity.tsx";
import { TaskTimeline } from "../features/timeline/TaskTimeline.tsx";
import {
  TaskSignals,
  WorkspaceNavigation,
} from "../features/workspaces/WorkspaceNavigation.tsx";
import {
  useNewTaskDrafts,
  useTaskDrafts,
} from "../features/composer/useTaskDrafts.ts";
import { prepareRetryDraft } from "../features/composer/drafts.ts";
import { submitTaskInstruction } from "../features/composer/submitTaskInstruction.ts";
import { HostClient } from "../host/client.ts";
import {
  WorkbenchConnection,
  type WorkbenchConnectionStatus,
} from "../host/connection.ts";
import type { UiResponsePayload } from "../host/contracts.ts";
import { useI18n, type MessageId } from "../i18n/context.ts";
import {
  searchWorkbench,
  isRunInFlight,
  selectActiveTask,
  selectCurrentWorkspace,
  taskDisplayState,
  workspaceLabel,
  workspaceSummaries,
  type SearchResult,
} from "../workbench/selectors.ts";
import { initialWorkbenchState, workbenchReducer } from "../workbench/store.ts";

const gate5FixtureLoader =
  import.meta.env.VITE_METAWORK_GATE5_FIXTURE === "1"
    ? () => import("../host/fixtures/gate5-fixture.ts")
    : undefined;

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

type StatusState = {
  id: MessageId;
  values?: Record<string, string>;
  diagnostic?: string;
  sourceId?: MessageId;
};

function connectionStatus(status: WorkbenchConnectionStatus): StatusState {
  if (status.kind === "connected")
    return {
      id: status.recovered ? "connection.recovered" : "connection.connected",
    };
  if (status.kind === "refresh_failed")
    return {
      id: "connection.refresh_failed",
      diagnostic: status.diagnostic,
    };
  return {
    id: "connection.failed",
    diagnostic: status.diagnostic,
    sourceId: `connection.source.${status.source}`,
  };
}

export default function App() {
  const { t } = useI18n();
  const [workbench, dispatchWorkbench] = useReducer(
    workbenchReducer,
    initialWorkbenchState,
  );
  const [workspacePath, setWorkspacePath] = useState("");
  const [workspaceGrant, setWorkspaceGrant] = useState("");
  const [showArchived, setShowArchived] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState("");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [taskMenuOpen, setTaskMenuOpen] = useState(false);
  const [status, setStatus] = useState<StatusState>({
    id: "connection.connecting",
  });
  const [busy, setBusy] = useState<string | null>(null);
  const [bridgeReady, setBridgeReady] = useState(false);
  const [viewSyncFailed, setViewSyncFailed] = useState(false);
  const {
    states: uiResponseStates,
    begin: beginUiResponse,
    accepted: acceptUiResponse,
    failed: failUiResponse,
    observeSnapshot: observeUiResponseSnapshot,
  } = useUiResponseStates();
  const client = useMemo(() => new HostClient(), []);
  const connection = useRef<WorkbenchConnection | null>(null);
  const pendingTaskSelection = useRef<string | null>(null);
  const pendingTaskDraftRetention = useRef(new Set<string>());
  const taskMenu = useRef<HTMLDivElement>(null);
  const composer = useRef<HTMLTextAreaElement>(null);
  const snapshot = workbench.snapshot;
  const activeTask = useMemo(() => selectActiveTask(workbench), [workbench]);
  const currentWorkspace = selectCurrentWorkspace(workbench);
  const summaries = useMemo(() => workspaceSummaries(snapshot), [snapshot]);
  const currentTasks = useMemo(
    () =>
      snapshot.tasks.filter((task) => task.workspaceRoot === currentWorkspace),
    [currentWorkspace, snapshot],
  );
  const searchResults = useMemo(
    () => searchWorkbench(snapshot, searchQuery),
    [searchQuery, snapshot],
  );
  const taskDrafts = useTaskDrafts(activeTask?.id ?? null);
  const newTaskDrafts = useNewTaskDrafts(workbench.draftWorkspaceRoot);
  const prompt = workbench.draftWorkspaceRoot
    ? newTaskDrafts.draft
    : taskDrafts.draft;
  const updatePrompt = workbench.draftWorkspaceRoot
    ? newTaskDrafts.updateDraft
    : taskDrafts.updateDraft;
  const mutationDisabled = viewSyncFailed || !bridgeReady || busy !== null;
  const taskCanCompose =
    Boolean(workbench.draftWorkspaceRoot) ||
    (activeTask?.lifecycle === "open" &&
      activeTask.continuationAvailable &&
      !activeTask.archived);
  const runInFlight = isRunInFlight(activeTask);
  const canSubmit =
    taskCanCompose &&
    (!workbench.draftWorkspaceRoot || Boolean(workspaceGrant)) &&
    !runInFlight &&
    prompt.trim().length > 0 &&
    !mutationDisabled;

  const refreshSnapshot = useCallback(() => {
    const current = connection.current;
    return current ? current.refresh() : Promise.resolve();
  }, []);

  useEffect(() => {
    let cancelled = false;
    const current = new WorkbenchConnection(
      client,
      {
        onSnapshot: (next) => {
          if (!cancelled) {
            observeUiResponseSnapshot(next);
            const projectedTaskIds = next.tasks.map((task) => task.id);
            taskDrafts.pruneDrafts([
              ...projectedTaskIds,
              ...pendingTaskDraftRetention.current,
            ]);
            for (const taskId of projectedTaskIds)
              pendingTaskDraftRetention.current.delete(taskId);
            dispatchWorkbench({ type: "snapshot.accepted", snapshot: next });
            const pendingTaskId = pendingTaskSelection.current;
            if (
              pendingTaskId &&
              next.tasks.some((task) => task.id === pendingTaskId)
            ) {
              pendingTaskSelection.current = null;
              dispatchWorkbench({
                type: "task.selected",
                taskId: pendingTaskId,
              });
            }
          }
        },
        onStatus: (next) => {
          if (!cancelled) setStatus(connectionStatus(next));
        },
        onReady: (ready) => {
          if (!cancelled) setBridgeReady(ready);
        },
        onViewSyncFailed: (failed) => {
          if (!cancelled) setViewSyncFailed(failed);
        },
      },
      { gate5FixtureLoader },
    );
    connection.current = current;
    void current.start().catch((error) => {
      if (!cancelled) {
        setViewSyncFailed(true);
        setStatus({
          id: "connection.failed",
          diagnostic: errorText(error),
        });
      }
    });

    const onPageHide = () => {
      void current.stop();
    };
    window.addEventListener("pagehide", onPageHide);
    return () => {
      cancelled = true;
      if (connection.current === current) connection.current = null;
      setBridgeReady(false);
      window.removeEventListener("pagehide", onPageHide);
      void current.stop();
    };
  }, [client, observeUiResponseSnapshot, taskDrafts.pruneDrafts]);

  useEffect(() => {
    const openSearch = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setSearchOpen(true);
      }
    };
    window.addEventListener("keydown", openSearch);
    return () => window.removeEventListener("keydown", openSearch);
  }, []);

  useEffect(() => {
    setEditingTitle(false);
    setConfirmDelete(false);
    setTaskMenuOpen(false);
  }, [activeTask?.id]);

  function focusPendingRequest() {
    const requestId = activeTask?.pendingUi?.requestId;
    if (!requestId) return;
    const target = document.getElementById(`ui-request-${requestId}`);
    target?.scrollIntoView({ block: "center", behavior: "smooth" });
    window.requestAnimationFrame(() => target?.focus());
  }

  useEffect(() => {
    if (!taskMenuOpen) return;
    const dismiss = (event: MouseEvent) => {
      if (!taskMenu.current?.contains(event.target as Node))
        setTaskMenuOpen(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      setTaskMenuOpen(false);
      taskMenu.current?.querySelector<HTMLButtonElement>("button")?.focus();
    };
    document.addEventListener("mousedown", dismiss);
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("mousedown", dismiss);
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, [taskMenuOpen]);

  function closeTaskMenuAndRestoreFocus() {
    setTaskMenuOpen(false);
    window.requestAnimationFrame(() =>
      taskMenu.current?.querySelector<HTMLButtonElement>("button")?.focus(),
    );
  }

  async function retryViewSynchronization() {
    if (busy !== null) return;
    setBusy("reconnect");
    setViewSyncFailed(false);
    try {
      const current = connection.current;
      if (!current) throw new Error("Workbench connection is not available");
      await current.retry();
      setBridgeReady(true);
      setStatus({ id: "connection.recovered" });
    } catch (error) {
      setViewSyncFailed(true);
      setBridgeReady(false);
      setStatus({
        id: "connection.failed",
        diagnostic: errorText(error),
      });
    } finally {
      setBusy(null);
    }
  }

  async function chooseWorkspace(openDraft = false) {
    if (viewSyncFailed || !bridgeReady) return;
    setBusy(openDraft ? "new-task" : "workspace");
    setWorkspaceGrant("");
    try {
      const result = await client.chooseWorkspace();
      if (result.selected) {
        setWorkspacePath(result.workspaceRoot);
        setWorkspaceGrant(result.grant);
        dispatchWorkbench(
          openDraft
            ? {
                type: "task.draft.opened",
                workspaceRoot: result.workspaceRoot,
              }
            : {
                type: "workspace.selected",
                workspaceRoot: result.workspaceRoot,
              },
        );
        setStatus({ id: "workspace.grant_confirmed" });
        if (openDraft)
          window.requestAnimationFrame(() => composer.current?.focus());
      } else {
        setStatus({ id: "workspace.selection_cancelled" });
      }
    } catch (error) {
      setStatus({
        id: "workspace.selection_failed",
        values: { error: errorText(error) },
      });
    } finally {
      setBusy(null);
    }
  }

  async function beginNewTask() {
    if (mutationDisabled) return;
    pendingTaskSelection.current = null;
    if (workspacePath && workspaceGrant) {
      dispatchWorkbench({
        type: "task.draft.opened",
        workspaceRoot: workspacePath,
      });
      window.requestAnimationFrame(() => composer.current?.focus());
      return;
    }
    await chooseWorkspace(true);
  }

  async function submitRun() {
    if (!canSubmit) return;
    const submitted = prompt;
    const draftWorkspaceRoot = workbench.draftWorkspaceRoot;
    const existingTaskId = activeTask?.id ?? null;
    updatePrompt("");
    setBusy("run");
    try {
      const result = await submitTaskInstruction({
        client,
        taskId: existingTaskId,
        workspaceGrant,
        instruction: submitted,
        onTaskCreated: (taskId) => {
          setWorkspaceGrant("");
          pendingTaskSelection.current = taskId;
          pendingTaskDraftRetention.current.add(taskId);
          if (draftWorkspaceRoot) newTaskDrafts.clearDraft(draftWorkspaceRoot);
          taskDrafts.setDraft(taskId, submitted);
          dispatchWorkbench({ type: "task.draft.closed" });
        },
      });
      if (result.kind === "create_failed") {
        setWorkspaceGrant("");
        newTaskDrafts.updateDraft(submitted);
        setStatus({
          id: "task.create_failed",
          values: { error: errorText(result.error) },
        });
        return;
      }
      if (result.kind === "run_failed") {
        taskDrafts.setDraft(result.taskId, submitted);
        setStatus({
          id: "run.start_failed",
          values: { error: errorText(result.error) },
        });
        if (result.created) await refreshSnapshot().catch(() => undefined);
        return;
      }
      taskDrafts.clearDraft(result.taskId);
      await refreshAfterCommit("run.started", "operation.run_submit");
    } finally {
      setBusy(null);
    }
  }

  async function cancelRun() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      !activeTask ||
      activeTask.currentRunId === "0" ||
      activeTask.currentRunPhase === null
    )
      return;
    setBusy("cancel");
    try {
      try {
        await client.cancel(activeTask.id, activeTask.currentRunId);
      } catch (error) {
        setStatus({
          id: "run.stop_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      await refreshAfterCommit("run.stop_requested", "operation.run_stop");
    } finally {
      setBusy(null);
    }
  }

  async function closeTask() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      !activeTask ||
      (activeTask.lifecycle === "closing" && !activeTask.closeFailed) ||
      activeTask.lifecycle === "closed"
    )
      return;
    setBusy("close");
    try {
      try {
        await client.closeTask(activeTask.id);
      } catch (error) {
        setStatus({
          id: "task.close_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      await refreshAfterCommit("task.close_requested", "operation.task_close");
    } finally {
      setBusy(null);
    }
  }

  async function renameTask() {
    if (!activeTask || mutationDisabled || !titleDraft.trim()) return;
    setBusy("rename");
    try {
      try {
        await client.renameTask(activeTask.id, titleDraft.trim());
      } catch (error) {
        setStatus({
          id: "task.rename_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      setEditingTitle(false);
      await refreshAfterCommit("task.renamed", "operation.task_rename");
    } finally {
      setBusy(null);
    }
  }

  async function setArchived(archived: boolean) {
    if (!activeTask || mutationDisabled || activeTask.currentRunPhase !== null)
      return;
    setBusy("archive");
    try {
      try {
        await client.setTaskArchived(activeTask.id, archived);
      } catch (error) {
        setStatus({
          id: archived ? "task.archive_failed" : "task.restore_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      if (archived) setShowArchived(true);
      await refreshAfterCommit(
        archived ? "task.archived_status" : "task.restored",
        archived ? "operation.task_archive" : "operation.task_restore",
      );
    } finally {
      setBusy(null);
    }
  }

  async function deleteTask() {
    if (!activeTask || mutationDisabled || activeTask.lifecycle !== "closed")
      return;
    setBusy("delete");
    try {
      try {
        await client.deleteTask(activeTask.id);
      } catch (error) {
        setStatus({
          id: "task.delete_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      taskDrafts.clearDraft(activeTask.id);
      setConfirmDelete(false);
      await refreshAfterCommit("task.deleted", "operation.task_delete");
    } finally {
      setBusy(null);
    }
  }

  function selectSearchResult(result: SearchResult) {
    pendingTaskSelection.current = null;
    setWorkspacePath(result.workspaceRoot);
    setWorkspaceGrant("");
    dispatchWorkbench({
      type: "workspace.selected",
      workspaceRoot: result.workspaceRoot,
    });
    if (result.taskId)
      dispatchWorkbench({
        type: "task.selected",
        taskId: result.taskId,
      });
    setWorkspacePath(result.workspaceRoot);
    setWorkspaceGrant("");
    setSearchOpen(false);
    setSearchQuery("");
  }

  async function respondUi(payload: UiResponsePayload) {
    const pending = activeTask?.pendingUi;
    if (viewSyncFailed || !bridgeReady || !activeTask || !pending) return;
    const identity = uiRequestIdentity(activeTask.id, pending);
    if (!beginUiResponse(identity)) return;
    setBusy("respond");
    try {
      try {
        await client.respondUi(
          activeTask.id,
          pending.runId,
          pending.requestId,
          payload,
        );
      } catch (error) {
        failUiResponse(identity);
        setStatus({
          id: "approval.response_failed",
          values: { error: errorText(error) },
        });
        await refreshSnapshot().catch(() => undefined);
        return;
      }
      acceptUiResponse(identity);
      await refreshAfterCommit(
        "approval.response_sent",
        "operation.ui_response",
      );
    } finally {
      setBusy(null);
    }
  }

  function prepareRetry(instruction: string) {
    if (!activeTask || !taskCanCompose) return;
    const prepared = prepareRetryDraft(prompt, instruction);
    switch (prepared.kind) {
      case "prepared":
        updatePrompt(prepared.draft);
        setStatus({ id: "run.retry_prepared" });
        break;
      case "preserved":
        setStatus({ id: "run.draft_preserved" });
        break;
      case "too_long":
        setStatus({ id: "run.retry_too_long" });
        break;
    }
    window.requestAnimationFrame(() => composer.current?.focus());
  }

  async function refreshAfterCommit(success: MessageId, operation: MessageId) {
    try {
      await refreshSnapshot();
      setStatus({ id: success });
    } catch (error) {
      setStatus({
        id: "view.refresh_after_commit_failed",
        values: {
          operation: t(operation),
          error: errorText(error),
        },
      });
    }
  }

  const currentTaskState = activeTask ? taskDisplayState(activeTask) : null;
  const currentTaskStatus = !currentTaskState
    ? t(workbench.draftWorkspaceRoot ? "task.new" : "task.open")
    : currentTaskState.kind === "phase"
      ? t(`task.phase.${currentTaskState.value}`)
      : currentTaskState.kind === "lifecycle"
        ? t(`task.lifecycle.${currentTaskState.value}`)
        : currentTaskState.kind === "archived"
          ? t("task.archived")
          : currentTaskState.kind === "outcome"
            ? t(`outcome.${currentTaskState.value}`)
            : t("task.ready");
  const activeTaskTitle = activeTask
    ? activeTask.title || t("task.item", { id: activeTask.id })
    : t(workbench.draftWorkspaceRoot ? "task.new" : "task.open");

  return (
    <AppShell
      taskTitle={activeTaskTitle}
      workspaceLabel={currentWorkspace || workspacePath || t("workspace.none")}
      status={t(status.id, status.values)}
      left={
        <>
          <div className="brand-lockup">
            <span className="brand-mark" aria-hidden="true">
              M
            </span>
            <div>
              <p className="brand-name">{t("app.name")}</p>
              <p className="brand-subtitle">{t("app.window_label")}</p>
            </div>
          </div>

          <WorkspaceNavigation
            summaries={summaries}
            currentWorkspace={currentWorkspace}
            tasks={currentTasks}
            activeTaskId={activeTask?.id ?? null}
            selectedPath={workspacePath || currentWorkspace || ""}
            grantReady={Boolean(workspacePath && workspaceGrant)}
            showArchived={showArchived}
            disabled={mutationDisabled}
            creating={busy === "new-task"}
            onSearch={() => setSearchOpen(true)}
            onChooseWorkspace={() => void chooseWorkspace(false)}
            onSelectWorkspace={(root) => {
              pendingTaskSelection.current = null;
              setWorkspacePath(root);
              setWorkspaceGrant("");
              dispatchWorkbench({
                type: "workspace.selected",
                workspaceRoot: root,
              });
            }}
            onCreateTask={() => void beginNewTask()}
            onSelectTask={(taskId) => {
              pendingTaskSelection.current = null;
              dispatchWorkbench({ type: "task.selected", taskId });
            }}
            onToggleArchived={() => setShowArchived((shown) => !shown)}
          />
        </>
      }
      activity={
        <>
          <h2 className="activity-title">{t("activity.title")}</h2>
          {viewSyncFailed && (
            <section className="sync-failure" role="alert">
              <h3>{t("connection.failed")}</h3>
              <p>{t("connection.failed_help")}</p>
              <button
                className="secondary-button focus-ring"
                disabled={busy !== null}
                onClick={() => void retryViewSynchronization()}
              >
                {busy === "reconnect"
                  ? t("connection.retrying")
                  : t("connection.retry")}
              </button>
              {status.diagnostic && (
                <details>
                  <summary>{t("connection.details")}</summary>
                  <p>
                    {status.sourceId ? `${t(status.sourceId)}: ` : ""}
                    {status.diagnostic}
                  </p>
                </details>
              )}
            </section>
          )}

          <TaskActivity
            task={activeTask}
            draft={Boolean(workbench.draftWorkspaceRoot)}
            currentStatus={currentTaskStatus}
            onFocusPending={focusPendingRequest}
          />
        </>
      }
    >
      <header className="task-header">
        <div className="min-w-0">
          <p className="task-header-workspace">
            {activeTask?.workspaceRoot || workspacePath || t("workspace.none")}
          </p>
          {activeTask && editingTitle ? (
            <form
              className="task-title-editor"
              onSubmit={(event) => {
                event.preventDefault();
                void renameTask();
              }}
            >
              <input
                autoFocus
                maxLength={120}
                value={titleDraft}
                aria-label={t("task.rename")}
                placeholder={t("task.item", { id: activeTask.id })}
                onChange={(event) => setTitleDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Escape") setEditingTitle(false);
                }}
              />
              <button
                className="secondary-button focus-ring"
                disabled={!titleDraft.trim() || mutationDisabled}
              >
                {t("common.save")}
              </button>
              <button
                type="button"
                className="text-button focus-ring"
                onClick={() => setEditingTitle(false)}
              >
                {t("common.cancel")}
              </button>
            </form>
          ) : (
            <div className="task-title-row">
              <h1>
                {activeTask
                  ? activeTaskTitle
                  : workbench.draftWorkspaceRoot
                    ? t("task.new")
                    : t("task.open")}
              </h1>
              {activeTask && <TaskSignals task={activeTask} />}
            </div>
          )}
        </div>
        <div className="task-actions">
          {activeTask &&
            activeTask.currentRunId !== "0" &&
            activeTask.currentRunPhase !== null &&
            activeTask.currentRunPhase !== "stopping" && (
              <button
                className="danger-button focus-ring"
                disabled={mutationDisabled}
                onClick={() => void cancelRun()}
              >
                <Icon name="stop" />
                {t("task.stop")}
              </button>
            )}
          {activeTask && (
            <div className="task-menu" ref={taskMenu}>
              <button
                className="secondary-button focus-ring"
                aria-expanded={taskMenuOpen}
                aria-haspopup="menu"
                onClick={() => setTaskMenuOpen((open) => !open)}
              >
                {t("task.actions")}
              </button>
              {taskMenuOpen && (
                <div
                  className="task-menu-popover"
                  role="menu"
                  onKeyDown={(event) => {
                    if (event.key !== "ArrowDown" && event.key !== "ArrowUp")
                      return;
                    const items = [
                      ...event.currentTarget.querySelectorAll<HTMLButtonElement>(
                        "button:not([disabled])",
                      ),
                    ];
                    if (items.length === 0) return;
                    event.preventDefault();
                    const index = items.indexOf(
                      document.activeElement as HTMLButtonElement,
                    );
                    const offset = event.key === "ArrowDown" ? 1 : -1;
                    const next =
                      index < 0
                        ? event.key === "ArrowDown"
                          ? 0
                          : items.length - 1
                        : (index + offset + items.length) % items.length;
                    items[next].focus();
                  }}
                >
                  <button
                    role="menuitem"
                    disabled={mutationDisabled}
                    onClick={() => {
                      setTitleDraft(activeTask.title);
                      setEditingTitle(true);
                      setTaskMenuOpen(false);
                    }}
                  >
                    {t("task.rename")}
                  </button>
                  <button
                    role="menuitem"
                    disabled={
                      mutationDisabled ||
                      runInFlight ||
                      activeTask.lifecycle === "closing"
                    }
                    onClick={() => {
                      closeTaskMenuAndRestoreFocus();
                      void setArchived(!activeTask.archived);
                    }}
                  >
                    {activeTask.archived
                      ? t("task.restore")
                      : t("task.archive")}
                  </button>
                  <button
                    role="menuitem"
                    disabled={
                      (activeTask.lifecycle === "closing" &&
                        !activeTask.closeFailed) ||
                      activeTask.lifecycle === "closed" ||
                      mutationDisabled
                    }
                    onClick={() => {
                      closeTaskMenuAndRestoreFocus();
                      void closeTask();
                    }}
                  >
                    {activeTask.closeFailed
                      ? t("task.end_retry")
                      : activeTask.lifecycle === "closing"
                        ? t("task.ending")
                        : t("task.end")}
                  </button>
                  <button
                    role="menuitem"
                    className="is-danger"
                    disabled={
                      activeTask.lifecycle !== "closed" || mutationDisabled
                    }
                    onClick={() => {
                      setTaskMenuOpen(false);
                      setConfirmDelete(true);
                    }}
                  >
                    {t("task.delete")}
                  </button>
                </div>
              )}
            </div>
          )}
        </div>
      </header>

      {activeTask && confirmDelete && (
        <section
          className="delete-confirmation"
          role="alertdialog"
          aria-labelledby="task-delete-title"
          aria-describedby="task-delete-description"
        >
          <div>
            <strong id="task-delete-title">
              {t("task.delete_confirm_title")}
            </strong>
            <span id="task-delete-description">
              {t("task.delete_confirm_body")}
            </span>
          </div>
          <button
            autoFocus
            className="secondary-button focus-ring"
            onClick={() => setConfirmDelete(false)}
          >
            {t("common.cancel")}
          </button>
          <button
            className="danger-button focus-ring"
            disabled={mutationDisabled}
            onClick={() => void deleteTask()}
          >
            {t("task.delete")}
          </button>
        </section>
      )}

      <TaskTimeline
        task={activeTask}
        draft={Boolean(workbench.draftWorkspaceRoot)}
        revision={snapshot.revision}
        composerHasDraft={prompt.trim().length > 0}
        retryAvailable={taskCanCompose && !runInFlight}
        responseDisabled={busy !== null || viewSyncFailed || !bridgeReady}
        onPrepareRetry={prepareRetry}
        onRespond={(payload) => void respondUi(payload)}
        renderPendingUi={(props) => {
          const { taskId, ...panelProps } = props;
          const identity = uiRequestIdentity(taskId, props.pending);
          return (
            <ApprovalPanel
              {...panelProps}
              responsePhase={uiResponsePhase(uiResponseStates, identity)}
            />
          );
        }}
        renderUiRecord={(record) => <UiRecordCard record={record} />}
      />

      <ComposerFooter
        textareaRef={composer}
        hasTask={Boolean(activeTask)}
        draft={Boolean(workbench.draftWorkspaceRoot)}
        archived={Boolean(activeTask?.archived)}
        closing={activeTask?.lifecycle === "closing"}
        closed={activeTask?.lifecycle === "closed"}
        unavailable={Boolean(
          activeTask &&
          activeTask.lifecycle === "open" &&
          !activeTask.continuationAvailable,
        )}
        prompt={prompt}
        composeDisabled={!taskCanCompose || mutationDisabled}
        canSubmit={canSubmit}
        runInFlight={Boolean(taskCanCompose && runInFlight)}
        accessRequired={Boolean(
          workbench.draftWorkspaceRoot && !workspaceGrant,
        )}
        actionDisabled={mutationDisabled}
        onStart={() => void beginNewTask()}
        onPromptChange={updatePrompt}
        onSubmit={() => void submitRun()}
        onConfirmAccess={() => void chooseWorkspace(true)}
      />
      <GlobalSearch
        open={searchOpen}
        query={searchQuery}
        results={searchResults}
        onQuery={setSearchQuery}
        onClose={() => {
          setSearchOpen(false);
          setSearchQuery("");
        }}
        onSelect={selectSearchResult}
      />
    </AppShell>
  );
}
