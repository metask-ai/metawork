import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";

import { AppShell } from "./app/AppShell.tsx";
import { GlobalSearch } from "./app/GlobalSearch.tsx";
import {
  TaskSignals,
  WorkspaceNavigation,
} from "./app/WorkspaceNavigation.tsx";
import { Icon } from "./components/ui/Icon.tsx";
import { HostClient } from "./host/client.ts";
import {
  WorkbenchConnection,
  type WorkbenchConnectionStatus,
} from "./host/connection.ts";
import type {
  PendingUi,
  RunView,
  ToolView,
  UiResponsePayload,
} from "./host/contracts.ts";
import { formatInteger, formatMilliseconds } from "./i18n/formatters.ts";
import { useI18n, type MessageId } from "./i18n/context.ts";
import {
  searchWorkbench,
  selectActiveSession,
  selectCurrentWorkspace,
  workspaceLabel,
  workspaceSummaries,
  type SearchResult,
} from "./workbench/selectors.ts";
import {
  clearTaskDraft,
  pruneTaskDrafts,
  readTaskDraft,
  writeTaskDraft,
} from "./workbench/drafts.ts";
import { initialWorkbenchState, workbenchReducer } from "./workbench/store.ts";

const gate5FixtureLoader =
  import.meta.env.VITE_METAWORK_GATE5_FIXTURE === "1"
    ? () => import("./host/fixtures/gate5-fixture.ts")
    : undefined;

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function tokenTotal(run: RunView): bigint | null {
  try {
    return BigInt(run.usage.input) + BigInt(run.usage.output);
  } catch {
    return null;
  }
}

type StatusState = {
  id: MessageId;
  values?: Record<string, string>;
  diagnostic?: string;
  sourceId?: MessageId;
};

function runPhaseLabel(
  t: (
    id: MessageId,
    values?: Record<string, string | number | bigint>,
  ) => string,
  phase: RunView["phase"],
) {
  switch (phase) {
    case "queued":
    case "running":
    case "waiting_ui":
    case "stopping":
      return t(`task.phase.${phase}`);
    case "completed":
    case "stopped":
    case "cancelled":
    case "interrupted":
    case "failed":
      return t(`outcome.${phase}`);
  }
}

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
  const { locale, t } = useI18n();
  const [workbench, dispatchWorkbench] = useReducer(
    workbenchReducer,
    initialWorkbenchState,
  );
  const [workspacePath, setWorkspacePath] = useState("");
  const [workspaceGrant, setWorkspaceGrant] = useState("");
  const [drafts, setDrafts] = useState<Record<string, string>>({});
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
  const [answers, setAnswers] = useState<Record<string, string[]>>({});
  const client = useMemo(() => new HostClient(), []);
  const connection = useRef<WorkbenchConnection | null>(null);
  const taskMenu = useRef<HTMLDivElement>(null);
  const snapshot = workbench.snapshot;
  const activeSession = useMemo(
    () => selectActiveSession(workbench),
    [workbench],
  );
  const currentWorkspace = selectCurrentWorkspace(workbench);
  const summaries = useMemo(() => workspaceSummaries(snapshot), [snapshot]);
  const currentTasks = useMemo(
    () =>
      snapshot.sessions.filter(
        (session) => session.workspaceRoot === currentWorkspace,
      ),
    [currentWorkspace, snapshot],
  );
  const searchResults = useMemo(
    () => searchWorkbench(snapshot, searchQuery),
    [searchQuery, snapshot],
  );
  const prompt = activeSession
    ? (drafts[activeSession.id] ?? readTaskDraft(activeSession.id))
    : "";
  const mutationDisabled = viewSyncFailed || !bridgeReady || busy !== null;
  const taskCanCompose =
    activeSession?.lifecycle === "open" && !activeSession.archived;
  const runInFlight = activeSession?.currentRunPhase !== null;
  const canSubmit =
    taskCanCompose &&
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
            const validSessionIds = new Set(
              next.sessions.map((session) => session.id),
            );
            pruneTaskDrafts(validSessionIds);
            setDrafts((current) =>
              Object.fromEntries(
                Object.entries(current).filter(([sessionId]) =>
                  validSessionIds.has(sessionId),
                ),
              ),
            );
            dispatchWorkbench({ type: "snapshot.accepted", snapshot: next });
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
  }, [client]);

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
  }, [activeSession?.id]);

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

  function updatePrompt(value: string) {
    if (!activeSession) return;
    setDrafts((current) => ({ ...current, [activeSession.id]: value }));
    writeTaskDraft(activeSession.id, value);
  }

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

  async function chooseWorkspace() {
    if (viewSyncFailed || !bridgeReady) return;
    setBusy("workspace");
    setWorkspaceGrant("");
    try {
      const result = await client.chooseWorkspace();
      if (result.selected) {
        setWorkspacePath(result.workspaceRoot);
        setWorkspaceGrant(result.grant);
        dispatchWorkbench({
          type: "workspace.selected",
          workspaceRoot: result.workspaceRoot,
        });
        setStatus({ id: "workspace.grant_confirmed" });
      } else {
        setWorkspacePath("");
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

  async function createSession() {
    if (viewSyncFailed || !bridgeReady || !workspacePath || !workspaceGrant)
      return;
    setBusy("create");
    try {
      let sessionId: string;
      try {
        sessionId = await client.createSession(workspaceGrant);
      } catch (error) {
        setStatus({
          id: "task.create_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      await refreshAfterCommit("task.created", "operation.task_create");
      dispatchWorkbench({ type: "session.selected", sessionId });
    } finally {
      setWorkspaceGrant("");
      setBusy(null);
    }
  }

  async function submitRun() {
    if (!canSubmit || !activeSession) return;
    const submitted = prompt;
    updatePrompt("");
    setBusy("run");
    try {
      try {
        await client.run(activeSession.id, submitted);
      } catch (error) {
        updatePrompt(submitted);
        setStatus({
          id: "run.start_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      await refreshAfterCommit("run.started", "operation.run_submit");
      clearTaskDraft(activeSession.id);
    } finally {
      setBusy(null);
    }
  }

  async function cancelRun() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      !activeSession ||
      activeSession.currentRunId === "0" ||
      activeSession.currentRunPhase === null
    )
      return;
    setBusy("cancel");
    try {
      try {
        await client.cancel(activeSession.id, activeSession.currentRunId);
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

  async function closeSession() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      !activeSession ||
      (activeSession.lifecycle === "closing" && !activeSession.closeFailed) ||
      activeSession.lifecycle === "closed"
    )
      return;
    setBusy("close");
    try {
      try {
        await client.closeSession(activeSession.id);
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
    if (!activeSession || mutationDisabled || !titleDraft.trim()) return;
    setBusy("rename");
    try {
      try {
        await client.renameTask(activeSession.id, titleDraft.trim());
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
    if (
      !activeSession ||
      mutationDisabled ||
      activeSession.currentRunPhase !== null
    )
      return;
    setBusy("archive");
    try {
      try {
        await client.setTaskArchived(activeSession.id, archived);
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
    if (
      !activeSession ||
      mutationDisabled ||
      activeSession.lifecycle !== "closed"
    )
      return;
    setBusy("delete");
    try {
      try {
        await client.deleteTask(activeSession.id);
      } catch (error) {
        setStatus({
          id: "task.delete_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      clearTaskDraft(activeSession.id);
      setConfirmDelete(false);
      await refreshAfterCommit("task.deleted", "operation.task_delete");
    } finally {
      setBusy(null);
    }
  }

  function selectSearchResult(result: SearchResult) {
    dispatchWorkbench({
      type: "workspace.selected",
      workspaceRoot: result.workspaceRoot,
    });
    if (result.sessionId)
      dispatchWorkbench({
        type: "session.selected",
        sessionId: result.sessionId,
      });
    setWorkspacePath(result.workspaceRoot);
    setWorkspaceGrant("");
    setSearchOpen(false);
    setSearchQuery("");
  }

  async function respondUi(payload: UiResponsePayload) {
    const pending = activeSession?.pendingUi;
    if (viewSyncFailed || !bridgeReady || !activeSession || !pending) return;
    setBusy("respond");
    try {
      try {
        await client.respondUi(
          activeSession.id,
          pending.runId,
          pending.requestId,
          payload,
        );
      } catch (error) {
        setStatus({
          id: "approval.response_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      await refreshAfterCommit(
        "approval.response_sent",
        "operation.ui_response",
      );
    } finally {
      setBusy(null);
    }
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

  const currentTaskStatus = activeSession
    ? activeSession.currentRunPhase
      ? t(`task.phase.${activeSession.currentRunPhase}`)
      : t(`task.lifecycle.${activeSession.lifecycle}`)
    : t("task.new");
  const activeTaskTitle = activeSession
    ? activeSession.title || t("task.item", { id: activeSession.id })
    : t("task.new");

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
            activeSessionId={activeSession?.id ?? null}
            selectedPath={workspacePath || currentWorkspace || ""}
            grantReady={Boolean(workspacePath && workspaceGrant)}
            showArchived={showArchived}
            disabled={mutationDisabled}
            creating={busy === "create"}
            onSearch={() => setSearchOpen(true)}
            onChooseWorkspace={() => void chooseWorkspace()}
            onSelectWorkspace={(root) => {
              setWorkspacePath(root);
              setWorkspaceGrant("");
              dispatchWorkbench({
                type: "workspace.selected",
                workspaceRoot: root,
              });
            }}
            onCreateTask={() => void createSession()}
            onSelectTask={(sessionId) =>
              dispatchWorkbench({ type: "session.selected", sessionId })
            }
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

          <section className="activity-section">
            <p className="section-label">{t("activity.needs_attention")}</p>
            {activeSession?.pendingUi ? (
              <ApprovalPanel
                pending={activeSession.pendingUi}
                answers={answers[activeSession.pendingUi.requestId] ?? []}
                busy={busy !== null || viewSyncFailed || !bridgeReady}
                setAnswers={(next) =>
                  setAnswers((current) => ({
                    ...current,
                    [activeSession.pendingUi!.requestId]: next,
                  }))
                }
                respond={(payload) => void respondUi(payload)}
              />
            ) : (
              <div className="activity-empty">
                <p>{t("activity.no_decision")}</p>
                <span>{t("activity.no_decision_help")}</span>
              </div>
            )}
          </section>

          <section className="activity-section">
            <p className="section-label">{t("activity.current")}</p>
            <div className="current-activity">
              <span
                className={`activity-dot ${activeSession?.currentRunPhase ? "is-live" : ""}`}
              />
              <div>
                <p>{currentTaskStatus}</p>
                <span>
                  {!activeSession
                    ? t("activity.current_empty")
                    : activeSession.currentRunPhase === "waiting_ui"
                      ? t("activity.current_waiting")
                      : activeSession.currentRunPhase !== null
                        ? t("activity.current_working")
                        : t("activity.current_ready")}
                </span>
              </div>
            </div>
          </section>
        </>
      }
    >
      <header className="task-header">
        <div className="min-w-0">
          <p className="task-header-workspace">
            {activeSession?.workspaceRoot ||
              workspacePath ||
              t("workspace.none")}
          </p>
          {activeSession && editingTitle ? (
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
                placeholder={t("task.item", { id: activeSession.id })}
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
              <h1>{activeSession ? activeTaskTitle : t("task.open")}</h1>
              {activeSession && <TaskSignals session={activeSession} />}
            </div>
          )}
        </div>
        <div className="task-actions">
          {activeSession &&
            activeSession.currentRunId !== "0" &&
            activeSession.currentRunPhase !== null &&
            activeSession.currentRunPhase !== "stopping" && (
              <button
                className="danger-button focus-ring"
                disabled={mutationDisabled}
                onClick={() => void cancelRun()}
              >
                <Icon name="stop" />
                {t("task.stop")}
              </button>
            )}
          {activeSession && (
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
                      setTitleDraft(activeSession.title);
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
                      activeSession.lifecycle === "closing"
                    }
                    onClick={() => {
                      closeTaskMenuAndRestoreFocus();
                      void setArchived(!activeSession.archived);
                    }}
                  >
                    {activeSession.archived
                      ? t("task.restore")
                      : t("task.archive")}
                  </button>
                  <button
                    role="menuitem"
                    disabled={
                      (activeSession.lifecycle === "closing" &&
                        !activeSession.closeFailed) ||
                      activeSession.lifecycle === "closed" ||
                      mutationDisabled
                    }
                    onClick={() => {
                      closeTaskMenuAndRestoreFocus();
                      void closeSession();
                    }}
                  >
                    {activeSession.closeFailed
                      ? t("task.end_retry")
                      : activeSession.lifecycle === "closing"
                        ? t("task.ending")
                        : t("task.end")}
                  </button>
                  <button
                    role="menuitem"
                    className="is-danger"
                    disabled={
                      activeSession.lifecycle !== "closed" || mutationDisabled
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

      {activeSession && confirmDelete && (
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

      <div className="timeline-scroll">
        <div className="timeline">
          {activeSession?.runs.map((run) => {
            const total = tokenTotal(run);
            return (
              <article
                key={run.id}
                className="timeline-run"
                data-active={
                  run.phase === "queued" ||
                  run.phase === "running" ||
                  run.phase === "waiting_ui" ||
                  run.phase === "stopping"
                }
              >
                <div className="workline-node" aria-hidden="true" />
                <header className="run-heading">
                  <p>
                    {t("run.label", { id: run.id })} ·{" "}
                    {runPhaseLabel(t, run.phase)}
                  </p>
                  {total !== null && (
                    <span>
                      {t("run.tokens", {
                        count: formatInteger(locale, total),
                      })}
                    </span>
                  )}
                </header>
                <div className="run-content">
                  <Message role={t("message.you")} text={run.user} />
                  {run.assistant && (
                    <Message
                      role={t("message.agent")}
                      text={run.assistant}
                      agent
                    />
                  )}
                  {run.tools.map((tool) => (
                    <ToolCard key={tool.id} tool={tool} />
                  ))}
                  {!run.assistant && run.tools.length === 0 && (
                    <p className="preparing-copy">{t("run.preparing")}</p>
                  )}
                  {run.outcome && (
                    <div className="run-outcome" data-phase={run.phase}>
                      <p>
                        {t("run.outcome", {
                          outcome: t(`outcome.${run.outcome}`),
                        })}
                      </p>
                      {run.cause && (
                        <span>
                          {t("run.cause", {
                            cause: t(`cause.${run.cause}`),
                          })}
                        </span>
                      )}
                    </div>
                  )}
                </div>
              </article>
            );
          })}
          {activeSession && activeSession.runs.length === 0 && (
            <div className="task-empty-state">
              <h2>{t("task.empty_title")}</h2>
              <p>{t("task.empty_body")}</p>
            </div>
          )}
          {!activeSession && (
            <div className="task-empty-state">
              <h2>{t("task.new")}</h2>
              <p>{t("task.no_tasks")}</p>
            </div>
          )}
        </div>
      </div>

      <footer className="composer-bar">
        <div className="composer">
          <textarea
            value={prompt}
            maxLength={16 * 1024}
            disabled={!taskCanCompose || viewSyncFailed || !bridgeReady}
            placeholder={
              !activeSession
                ? t("run.placeholder_no_task")
                : activeSession.archived
                  ? t("run.placeholder_archived")
                  : activeSession.lifecycle !== "open"
                    ? t("run.placeholder_closed")
                    : t("run.placeholder")
            }
            onChange={(event) => updatePrompt(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey && canSubmit) {
                event.preventDefault();
                void submitRun();
              }
            }}
          />
          <button
            className="composer-send focus-ring"
            aria-label={t("run.submit")}
            title={t("run.submit")}
            disabled={!canSubmit}
            onClick={() => void submitRun()}
          >
            <Icon name="send" />
          </button>
        </div>
        {taskCanCompose && runInFlight && (
          <p className="composer-draft-note">{t("run.draft_only")}</p>
        )}
      </footer>
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

function Message({
  role,
  text,
  agent = false,
}: {
  role: string;
  text: string;
  agent?: boolean;
}) {
  return (
    <section className={`timeline-message ${agent ? "is-agent" : "is-user"}`}>
      <p className="message-role">{role}</p>
      <p className="message-body">{text}</p>
    </section>
  );
}

function ToolCard({ tool }: { tool: ToolView }) {
  const { locale, t } = useI18n();
  let duration: bigint | null = null;
  try {
    duration = BigInt(tool.elapsedMs);
  } catch {
    duration = null;
  }
  return (
    <details
      className="group rounded-xl border border-rule bg-canvas"
      open={tool.state === "running"}
    >
      <summary className="flex cursor-pointer list-none items-center justify-between gap-4 px-4 py-3">
        <span className="flex items-center gap-3">
          <span
            className={`h-2 w-2 rounded-full ${tool.state === "failed" ? "bg-danger" : tool.state === "running" ? "bg-cobalt" : "bg-live"}`}
          />
          <span className="font-mono text-xs font-semibold">{tool.name}</span>
        </span>
        <span className="font-mono text-[10px] text-muted">
          {duration === null || duration === 0n
            ? runPhaseLabel(
                t,
                tool.state === "completed" ? "completed" : tool.state,
              )
            : t("tool.duration_ms", {
                count: formatMilliseconds(locale, duration),
              })}
        </span>
      </summary>
      <div className="grid gap-3 border-t border-rule px-4 py-4 text-xs">
        <CodeBlock label={t("tool.input")} value={tool.input} />
        {tool.progress && (
          <CodeBlock label={t("tool.progress")} value={tool.progress} />
        )}
        {tool.content && (
          <CodeBlock
            label={tool.isError ? t("tool.error") : t("tool.result")}
            value={tool.content}
          />
        )}
      </div>
    </details>
  );
}

function CodeBlock({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="mb-1 font-mono text-[9px] tracking-[0.14em] text-muted uppercase">
        {label}
      </p>
      <pre className="max-h-64 overflow-auto whitespace-pre-wrap rounded-lg bg-graphite p-3 font-mono text-[11px] leading-5 text-white/85">
        {value}
      </pre>
    </div>
  );
}

function ApprovalPanel({
  pending,
  answers,
  busy,
  setAnswers,
  respond,
}: {
  pending: PendingUi;
  answers: string[];
  busy: boolean;
  setAnswers: (answers: string[]) => void;
  respond: (payload: UiResponsePayload) => void;
}) {
  const { t } = useI18n();
  return (
    <div className="mt-5 rounded-2xl border border-amber bg-amber/8 p-4">
      <p className="font-mono text-[10px] tracking-[0.14em] text-amber-ink uppercase">
        {t("approval.response_required", { id: pending.runId })}
      </p>
      {pending.kind === "permission" && (
        <div className="mt-4">
          <h3 className="font-semibold">
            {t("approval.allow_tool", { tool: pending.tool })}
          </h3>
          <CodeBlock
            label={t("approval.arguments")}
            value={pending.args ?? ""}
          />
          <div className="mt-4 grid grid-cols-2 gap-2">
            <DecisionButton
              disabled={busy}
              onClick={() =>
                respond({ kind: "permission", permission: "deny_once" })
              }
            >
              {t("approval.deny")}
            </DecisionButton>
            <DecisionButton
              primary
              disabled={busy}
              onClick={() =>
                respond({ kind: "permission", permission: "allow_once" })
              }
            >
              {t("approval.allow_once")}
            </DecisionButton>
          </div>
        </div>
      )}
      {pending.kind === "ask_question" && (
        <div className="mt-4 space-y-5">
          {(pending.questions ?? []).map((question, index) => (
            <div key={`${question.header}-${index}`}>
              <p className="text-sm font-semibold">{question.question}</p>
              {question.multi && question.options.length > 0 ? (
                <div className="mt-3 space-y-2">
                  {question.options.map((option) => {
                    const selected = (answers[index] ?? "")
                      .split(", ")
                      .filter(Boolean);
                    return (
                      <label
                        key={option.label}
                        className="flex items-start gap-3 rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                      >
                        <input
                          className="mt-1 accent-cobalt"
                          type="checkbox"
                          checked={selected.includes(option.label)}
                          onChange={(event) => {
                            const choices = event.target.checked
                              ? [...selected, option.label]
                              : selected.filter(
                                  (label) => label !== option.label,
                                );
                            const next = [...answers];
                            next[index] = choices.join(", ");
                            setAnswers(next);
                          }}
                        />
                        <span>
                          <span className="font-medium">{option.label}</span>
                          {option.description && (
                            <span className="mt-0.5 block text-xs leading-5 text-muted">
                              {option.description}
                            </span>
                          )}
                        </span>
                      </label>
                    );
                  })}
                </div>
              ) : question.options.length > 0 ? (
                <select
                  className="focus-ring mt-2 w-full rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                  value={answers[index] ?? ""}
                  onChange={(event) => {
                    const next = [...answers];
                    next[index] = event.target.value;
                    setAnswers(next);
                  }}
                >
                  <option value="">{t("approval.choose")}</option>
                  {question.options.map((option) => (
                    <option key={option.label} value={option.label}>
                      {option.label}
                    </option>
                  ))}
                </select>
              ) : (
                <input
                  className="focus-ring mt-2 w-full rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                  value={answers[index] ?? ""}
                  onChange={(event) => {
                    const next = [...answers];
                    next[index] = event.target.value;
                    setAnswers(next);
                  }}
                />
              )}
            </div>
          ))}
          <DecisionButton
            primary
            disabled={
              busy ||
              answers.length !== (pending.questions?.length ?? 0) ||
              answers.some((answer) => !answer)
            }
            onClick={() => respond({ kind: "answers", answers })}
          >
            {t("approval.send_answers")}
          </DecisionButton>
        </div>
      )}
      {pending.kind === "plan_approval" && (
        <div className="mt-4">
          <h3 className="font-semibold">{t("approval.review_plan")}</h3>
          <p className="mt-3 whitespace-pre-wrap text-xs leading-6 text-muted">
            {pending.plan}
          </p>
          <div className="mt-4 grid grid-cols-2 gap-2">
            <DecisionButton
              disabled={busy}
              onClick={() =>
                respond({ kind: "plan_approval", planApproval: "reject" })
              }
            >
              {t("approval.reject_plan")}
            </DecisionButton>
            <DecisionButton
              primary
              disabled={busy}
              onClick={() =>
                respond({
                  kind: "plan_approval",
                  planApproval: "approve_default",
                })
              }
            >
              {t("approval.approve_plan")}
            </DecisionButton>
          </div>
        </div>
      )}
      {pending.kind === "custom" && (
        <div className="mt-4">
          <h3 className="font-semibold">{pending.customKind}</h3>
          <CodeBlock
            label={t("approval.request")}
            value={pending.payload ?? ""}
          />
          <p className="mt-3 text-xs text-muted">
            {t("approval.custom_request")}
          </p>
        </div>
      )}
    </div>
  );
}

function DecisionButton({
  primary = false,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { primary?: boolean }) {
  return (
    <button
      {...props}
      className={`focus-ring rounded-lg px-3 py-2 text-sm font-semibold disabled:opacity-40 ${primary ? "bg-amber-ink text-white" : "border border-amber/60 text-amber-ink"}`}
    />
  );
}
