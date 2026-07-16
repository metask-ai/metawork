import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";

import { AppShell } from "./app/AppShell.tsx";
import { Icon } from "./components/ui/Icon.tsx";
import { HostClient } from "./host/client.ts";
import {
  WorkbenchConnection,
  type WorkbenchConnectionStatus,
} from "./host/connection.ts";
import type {
  PendingUi,
  RunView,
  SessionView,
  ToolView,
  UiResponsePayload,
} from "./host/contracts.ts";
import {
  formatInteger,
  formatMilliseconds,
  taskCountMessageId,
} from "./i18n/formatters.ts";
import { useI18n, type MessageId } from "./i18n/context.ts";
import { selectActiveSession } from "./workbench/selectors.ts";
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
      return t(`task.status.${phase}`);
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
  const [prompt, setPrompt] = useState("");
  const [status, setStatus] = useState<StatusState>({
    id: "connection.connecting",
  });
  const [busy, setBusy] = useState<string | null>(null);
  const [bridgeReady, setBridgeReady] = useState(false);
  const [viewSyncFailed, setViewSyncFailed] = useState(false);
  const [answers, setAnswers] = useState<Record<string, string[]>>({});
  const client = useMemo(() => new HostClient(), []);
  const connection = useRef<WorkbenchConnection | null>(null);
  const snapshot = workbench.snapshot;
  const activeSession = useMemo(
    () => selectActiveSession(workbench),
    [workbench],
  );

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
          if (!cancelled)
            dispatchWorkbench({ type: "snapshot.accepted", snapshot: next });
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
    if (viewSyncFailed || !bridgeReady || !activeSession || !prompt.trim())
      return;
    const submitted = prompt;
    setPrompt("");
    setBusy("run");
    try {
      try {
        await client.run(activeSession.id, submitted);
      } catch (error) {
        setPrompt(submitted);
        setStatus({
          id: "run.start_failed",
          values: { error: errorText(error) },
        });
        return;
      }
      await refreshAfterCommit("run.started", "operation.run_submit");
    } finally {
      setBusy(null);
    }
  }

  async function cancelRun() {
    if (
      viewSyncFailed ||
      !bridgeReady ||
      !activeSession ||
      activeSession.activeRunId === "0"
    )
      return;
    setBusy("cancel");
    try {
      try {
        await client.cancel(activeSession.id, activeSession.activeRunId);
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
      (activeSession.state === "closing" && !activeSession.closeFailed) ||
      activeSession.state === "closed"
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
    ? t(`task.status.${activeSession.state}`)
    : t("task.new");

  return (
    <AppShell
      taskTitle={
        activeSession ? t("task.item", { id: activeSession.id }) : t("task.new")
      }
      workspaceLabel={
        activeSession?.workspaceRoot || workspacePath || t("workspace.none")
      }
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

          <section className="workspace-card">
            <p className="section-label">{t("workspace.label")}</p>
            <button
              className="workspace-picker focus-ring"
              disabled={busy !== null || viewSyncFailed || !bridgeReady}
              onClick={() => void chooseWorkspace()}
            >
              <Icon name="workspace" />
              <span className="truncate">
                {workspacePath || t("workspace.choose")}
              </span>
              <Icon name="chevron" />
            </button>
            {workspaceGrant && (
              <p className="workspace-grant">{t("workspace.grant_ready")}</p>
            )}
            <button
              className="primary-button focus-ring"
              disabled={
                !workspacePath ||
                !workspaceGrant ||
                busy !== null ||
                viewSyncFailed ||
                !bridgeReady
              }
              onClick={() => void createSession()}
            >
              {busy === "create"
                ? t("workspace.starting_task")
                : t("workspace.start_task")}
            </button>
          </section>

          <nav className="task-list" aria-label={t("task.list")}>
            <div className="task-list-heading">
              <p className="section-label">{t("task.list")}</p>
              <span>
                {t(taskCountMessageId(locale, snapshot.sessions.length), {
                  count: formatInteger(locale, snapshot.sessions.length),
                })}
              </span>
            </div>
            {snapshot.sessions.map((session) => (
              <button
                key={session.id}
                className="task-list-item focus-ring"
                aria-current={
                  activeSession?.id === session.id ? "page" : undefined
                }
                onClick={() =>
                  dispatchWorkbench({
                    type: "session.selected",
                    sessionId: session.id,
                  })
                }
              >
                <span className="task-list-row">
                  <span>{t("task.item", { id: session.id })}</span>
                  <StatePill state={session.state} />
                </span>
                <span className="task-list-path">{session.workspaceRoot}</span>
              </button>
            ))}
            {snapshot.sessions.length === 0 && (
              <p className="task-list-empty">{t("task.no_tasks")}</p>
            )}
          </nav>
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
                className={`activity-dot ${activeSession?.state === "running" ? "is-live" : ""}`}
              />
              <div>
                <p>{currentTaskStatus}</p>
                <span>
                  {!activeSession
                    ? t("activity.current_empty")
                    : activeSession.state === "waiting_ui"
                      ? t("activity.current_waiting")
                      : activeSession.state === "running" ||
                          activeSession.state === "queued"
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
          <h1>
            {activeSession
              ? t("task.item", { id: activeSession.id })
              : t("task.open")}
          </h1>
        </div>
        <div className="task-actions">
          {activeSession &&
            activeSession.activeRunId !== "0" &&
            (activeSession.state === "queued" ||
              activeSession.state === "running" ||
              activeSession.state === "waiting_ui") && (
              <button
                className="danger-button focus-ring"
                disabled={busy !== null || viewSyncFailed || !bridgeReady}
                onClick={() => void cancelRun()}
              >
                <Icon name="stop" />
                {t("task.stop")}
              </button>
            )}
          {activeSession && (
            <button
              className="secondary-button focus-ring"
              disabled={
                (activeSession.state === "closing" &&
                  !activeSession.closeFailed) ||
                activeSession.state === "closed" ||
                busy !== null ||
                viewSyncFailed ||
                !bridgeReady
              }
              onClick={() => void closeSession()}
            >
              {activeSession.closeFailed
                ? t("task.close_retry")
                : activeSession.state === "closing"
                  ? t("task.closing")
                  : t("task.close")}
            </button>
          )}
        </div>
      </header>

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
                  run.phase === "waiting_ui"
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
            disabled={
              !activeSession ||
              activeSession.state !== "idle" ||
              busy !== null ||
              viewSyncFailed ||
              !bridgeReady
            }
            placeholder={
              activeSession
                ? t("run.placeholder")
                : t("run.placeholder_no_task")
            }
            onChange={(event) => setPrompt(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                void submitRun();
              }
            }}
          />
          <button
            className="composer-send focus-ring"
            aria-label={t("run.submit")}
            title={t("run.submit")}
            disabled={
              !activeSession ||
              activeSession.state !== "idle" ||
              !prompt.trim() ||
              busy !== null ||
              viewSyncFailed ||
              !bridgeReady
            }
            onClick={() => void submitRun()}
          >
            <Icon name="send" />
          </button>
        </div>
      </footer>
    </AppShell>
  );
}

function StatePill({ state }: { state: SessionView["state"] }) {
  const { t } = useI18n();
  const active =
    state === "running" || state === "queued" || state === "waiting_ui";
  return (
    <span
      className={`rounded-full px-2 py-1 font-mono text-[9px] uppercase ${active ? "bg-cobalt/10 text-cobalt" : "bg-rule/60 text-muted"}`}
    >
      {t(`task.status.${state}`)}
    </span>
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
