import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";

import { HostClient } from "./host/client.ts";
import { WorkbenchConnection } from "./host/connection.ts";
import type {
  PendingUi,
  RunView,
  SessionView,
  ToolView,
  UiResponsePayload,
} from "./host/contracts.ts";
import { selectActiveSession } from "./workbench/selectors.ts";
import { initialWorkbenchState, workbenchReducer } from "./workbench/store.ts";

const gate5FixtureLoader =
  import.meta.env.VITE_METAWORK_GATE5_FIXTURE === "1"
    ? () => import("./host/fixtures/gate5-fixture.ts")
    : undefined;

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function tokenTotal(run: RunView) {
  try {
    return (BigInt(run.usage.input) + BigInt(run.usage.output)).toString();
  } catch {
    return "invalid";
  }
}

export default function App() {
  const [workbench, dispatchWorkbench] = useReducer(
    workbenchReducer,
    initialWorkbenchState,
  );
  const [workspacePath, setWorkspacePath] = useState("");
  const [workspaceGrant, setWorkspaceGrant] = useState("");
  const [prompt, setPrompt] = useState("");
  const [status, setStatus] = useState("Connect the native shell to begin.");
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
          if (!cancelled) setStatus(next);
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
        setStatus(`Host connection failed: ${errorText(error)}`);
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
      setStatus("Workbench view synchronized.");
    } catch (error) {
      setViewSyncFailed(true);
      setBridgeReady(false);
      setStatus(`Workbench recovery failed: ${errorText(error)}`);
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
        setStatus("The Host confirmed a one-time trust grant for this path.");
      } else {
        setWorkspacePath("");
        setStatus("Workspace selection was cancelled.");
      }
    } catch (error) {
      setStatus(`Workspace selection failed: ${errorText(error)}`);
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
        setStatus(`Session creation failed: ${errorText(error)}`);
        return;
      }
      await refreshAfterCommit(
        "Session created. AgentCore credentials remain in the Host.",
        "Session creation",
      );
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
        setStatus(`Run failed to start: ${errorText(error)}`);
        return;
      }
      await refreshAfterCommit("Run accepted by AgentCore.", "Run submission");
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
        setStatus(`Cancellation failed: ${errorText(error)}`);
        return;
      }
      await refreshAfterCommit(
        "Cancellation requested; waiting for AgentCore to stop.",
        "Cancellation request",
      );
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
        setStatus(`Session close failed: ${errorText(error)}`);
        return;
      }
      await refreshAfterCommit(
        "Session close requested; AgentCore cleanup continues off the UI thread.",
        "Session close request",
      );
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
        setStatus(`Response rejected: ${errorText(error)}`);
        return;
      }
      await refreshAfterCommit(
        "Response delivered to AgentCore.",
        "UI response",
      );
    } finally {
      setBusy(null);
    }
  }

  async function refreshAfterCommit(success: string, operation: string) {
    try {
      await refreshSnapshot();
      setStatus(success);
    } catch (error) {
      setStatus(
        `${operation} was committed, but the view refresh failed: ${errorText(error)}`,
      );
    }
  }

  return (
    <main className="min-h-screen bg-canvas text-graphite">
      <div className="grid min-h-screen grid-cols-1 xl:grid-cols-[260px_minmax(0,1fr)_340px]">
        <aside className="border-b border-rule bg-rail p-5 xl:border-r xl:border-b-0">
          <div className="flex items-center justify-between gap-3">
            <div>
              <p className="font-mono text-[10px] tracking-[0.2em] text-muted uppercase">
                MetaWork / Phase 0
              </p>
              <h1 className="mt-1 font-display text-2xl font-semibold tracking-[-0.04em]">
                Run desk
              </h1>
            </div>
            <span
              className={`h-2.5 w-2.5 rounded-full ${bridgeReady ? "bg-live" : "bg-danger"}`}
              title={
                viewSyncFailed
                  ? "Workbench view synchronization failed"
                  : bridgeReady
                    ? "Host connected"
                    : "Host offline"
              }
            />
          </div>

          <div className="mt-8 rounded-xl border border-rule bg-canvas/70 p-3">
            <p className="font-mono text-[10px] text-muted uppercase">
              Workspace
            </p>
            <button
              className="focus-ring mt-2 w-full rounded-lg border border-rule bg-paper px-3 py-2 text-left text-sm hover:border-cobalt"
              disabled={busy !== null || viewSyncFailed || !bridgeReady}
              onClick={() => void chooseWorkspace()}
            >
              {workspacePath || "Choose a folder…"}
            </button>
            {workspaceGrant && (
              <p className="mt-3 text-xs leading-5 text-muted">
                Host-confirmed one-time trust grant. Strict workspace security
                is not yet claimed.
              </p>
            )}
            <button
              className="focus-ring mt-3 w-full rounded-lg bg-cobalt px-3 py-2 text-sm font-semibold text-white disabled:opacity-40"
              disabled={
                !workspacePath ||
                !workspaceGrant ||
                busy !== null ||
                viewSyncFailed ||
                !bridgeReady
              }
              onClick={() => void createSession()}
            >
              Create session
            </button>
          </div>

          <nav className="mt-6 space-y-2" aria-label="Sessions">
            <p className="mb-3 font-mono text-[10px] tracking-[0.16em] text-muted uppercase">
              Sessions · {snapshot.sessions.length}
            </p>
            {snapshot.sessions.map((session) => (
              <button
                key={session.id}
                className={`focus-ring w-full rounded-xl border px-3 py-3 text-left transition ${activeSession?.id === session.id ? "border-cobalt bg-cobalt/8" : "border-transparent hover:border-rule hover:bg-paper"}`}
                onClick={() =>
                  dispatchWorkbench({
                    type: "session.selected",
                    sessionId: session.id,
                  })
                }
              >
                <span className="flex items-center justify-between gap-2">
                  <span className="font-mono text-xs">S-{session.id}</span>
                  <StatePill state={session.state} />
                </span>
                <span className="mt-2 block truncate text-xs text-muted">
                  {session.workspaceRoot}
                </span>
              </button>
            ))}
            {snapshot.sessions.length === 0 && (
              <p className="rounded-xl border border-dashed border-rule p-4 text-sm leading-6 text-muted">
                Choose a trusted workspace to create the first Session.
              </p>
            )}
          </nav>
        </aside>

        <section className="flex min-h-[70vh] min-w-0 flex-col">
          <header className="flex min-h-20 items-center justify-between gap-5 border-b border-rule bg-paper/70 px-6 backdrop-blur">
            <div className="min-w-0">
              <p className="truncate font-mono text-[10px] tracking-[0.14em] text-muted uppercase">
                {activeSession?.workspaceRoot ?? "No active workspace"}
              </p>
              <h2 className="mt-1 text-lg font-semibold">
                {activeSession
                  ? `Session ${activeSession.id}`
                  : "Open a Session"}
              </h2>
            </div>
            <div className="flex items-center gap-2">
              {activeSession &&
                activeSession.activeRunId !== "0" &&
                (activeSession.state === "queued" ||
                  activeSession.state === "running" ||
                  activeSession.state === "waiting_ui") && (
                  <button
                    className="focus-ring rounded-lg border border-danger/50 px-3 py-2 text-sm font-medium text-danger hover:bg-danger/8 disabled:opacity-40"
                    disabled={busy !== null || viewSyncFailed || !bridgeReady}
                    onClick={() => void cancelRun()}
                  >
                    Stop run
                  </button>
                )}
              <button
                className="focus-ring rounded-lg border border-rule px-3 py-2 text-sm text-muted hover:border-graphite hover:text-graphite disabled:opacity-30"
                disabled={
                  !activeSession ||
                  (activeSession.state === "closing" &&
                    !activeSession.closeFailed) ||
                  activeSession.state === "closed" ||
                  busy !== null ||
                  viewSyncFailed ||
                  !bridgeReady
                }
                onClick={() => void closeSession()}
              >
                {activeSession?.closeFailed
                  ? "Retry close"
                  : activeSession?.state === "closing"
                    ? "Closing…"
                    : "Close"}
              </button>
            </div>
          </header>

          <div className="flex-1 overflow-y-auto px-5 py-8 sm:px-8">
            <div className="mx-auto max-w-4xl">
              {activeSession?.runs.map((run, index) => (
                <article
                  key={run.id}
                  className="run-spine relative pb-12 pl-10"
                >
                  <span className="absolute top-0 left-0 grid h-7 w-7 place-items-center rounded-full border border-cobalt bg-canvas font-mono text-[10px] text-cobalt">
                    {index + 1}
                  </span>
                  <div className="rounded-2xl border border-rule bg-paper p-5 shadow-[0_16px_50px_rgba(52,68,92,0.06)]">
                    <div className="flex items-center justify-between gap-4 border-b border-rule pb-4">
                      <p className="font-mono text-[10px] tracking-[0.14em] text-muted uppercase">
                        Run {run.id} · {run.status}
                      </p>
                      <span className="font-mono text-[10px] text-muted">
                        {tokenTotal(run)} tokens
                      </span>
                    </div>
                    <div className="mt-5 grid gap-5">
                      <Message role="You" text={run.user} />
                      {run.assistant && (
                        <Message role="Agent" text={run.assistant} agent />
                      )}
                      {run.tools.map((tool) => (
                        <ToolCard key={tool.id} tool={tool} />
                      ))}
                      {!run.assistant && run.tools.length === 0 && (
                        <p className="text-sm text-muted">
                          AgentCore is preparing this Run…
                        </p>
                      )}
                      {run.outcome && (
                        <div
                          className={`rounded-xl border px-4 py-3 text-xs ${run.phase === "completed" ? "border-live/40 bg-live/5 text-live" : "border-danger/30 bg-danger/5 text-danger"}`}
                        >
                          Run {run.outcome.replaceAll("_", " ")}
                          {run.cause
                            ? ` · ${run.cause.replaceAll("_", " ")}`
                            : ""}
                        </div>
                      )}
                    </div>
                  </div>
                </article>
              ))}
              {activeSession && activeSession.runs.length === 0 && (
                <div className="grid min-h-[45vh] place-items-center text-center">
                  <div>
                    <p className="font-display text-4xl font-semibold tracking-[-0.05em] text-graphite/25">
                      Ready when you are.
                    </p>
                    <p className="mx-auto mt-4 max-w-md text-sm leading-6 text-muted">
                      Ask the Agent to inspect this workspace. Read, Bash and
                      Edit run through AgentCore built-in tools.
                    </p>
                  </div>
                </div>
              )}
              {!activeSession && (
                <div className="grid min-h-[60vh] place-items-center text-center text-muted">
                  <p>Create a Session from the workspace rail.</p>
                </div>
              )}
            </div>
          </div>

          <footer className="border-t border-rule bg-paper p-4 sm:px-8">
            <div className="mx-auto flex max-w-4xl items-end gap-3 rounded-2xl border border-rule bg-canvas p-2 focus-within:border-cobalt">
              <textarea
                className="min-h-16 flex-1 resize-none bg-transparent px-3 py-2 text-sm leading-6 outline-none placeholder:text-muted/70"
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
                    ? "Describe the work to do…"
                    : "Create a Session first"
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
                className="focus-ring rounded-xl bg-graphite px-4 py-3 text-sm font-semibold text-white disabled:opacity-30"
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
                Run
              </button>
            </div>
          </footer>
        </section>

        <aside className="border-t border-rule bg-inspector p-5 xl:border-t-0 xl:border-l">
          <p className="font-mono text-[10px] tracking-[0.18em] text-muted uppercase">
            Decision desk
          </p>
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
            <div className="mt-5 rounded-2xl border border-dashed border-rule p-5">
              <p className="text-sm font-medium">No decision waiting</p>
              <p className="mt-2 text-xs leading-5 text-muted">
                Permission prompts and questions remain bound to their original
                Session and Run, including after a Renderer reload.
              </p>
            </div>
          )}
          <div className="mt-6 border-t border-rule pt-5">
            <p className="font-mono text-[10px] text-muted uppercase">
              Host status
            </p>
            <p className="mt-2 text-sm leading-6">{status}</p>
            {viewSyncFailed && (
              <button
                className="focus-ring mt-3 rounded-lg border border-danger/40 px-3 py-2 text-xs font-medium text-danger hover:bg-danger/8 disabled:opacity-40"
                disabled={busy !== null}
                onClick={() => void retryViewSynchronization()}
              >
                Retry Workbench connection
              </button>
            )}
            <dl className="mt-5 grid grid-cols-2 gap-3 text-xs">
              <Metric label="Revision" value={snapshot.revision} />
              <Metric label="Contract" value="ABI v1" />
              <Metric label="Platform" value="macOS 13+" />
              <Metric label="Mode" value="In process" />
            </dl>
          </div>
        </aside>
      </div>
    </main>
  );
}

function StatePill({ state }: { state: SessionView["state"] }) {
  const active =
    state === "running" || state === "queued" || state === "waiting_ui";
  return (
    <span
      className={`rounded-full px-2 py-1 font-mono text-[9px] uppercase ${active ? "bg-cobalt/10 text-cobalt" : "bg-rule/60 text-muted"}`}
    >
      {state.replace("_", " ")}
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
    <section
      className={
        agent ? "border-l-2 border-cobalt pl-4" : "border-l-2 border-rule pl-4"
      }
    >
      <p className="font-mono text-[10px] tracking-[0.14em] text-muted uppercase">
        {role}
      </p>
      <p className="mt-2 whitespace-pre-wrap text-sm leading-7">{text}</p>
    </section>
  );
}

function ToolCard({ tool }: { tool: ToolView }) {
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
          {tool.elapsedMs === "0" ? tool.state : `${tool.elapsedMs} ms`}
        </span>
      </summary>
      <div className="grid gap-3 border-t border-rule px-4 py-4 text-xs">
        <CodeBlock label="Input" value={tool.input} />
        {tool.progress && <CodeBlock label="Progress" value={tool.progress} />}
        {tool.content && (
          <CodeBlock
            label={tool.isError ? "Error" : "Result"}
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
  return (
    <div className="mt-5 rounded-2xl border border-amber bg-amber/8 p-4">
      <p className="font-mono text-[10px] tracking-[0.14em] text-amber-ink uppercase">
        Run {pending.runId} · response required
      </p>
      {pending.kind === "permission" && (
        <div className="mt-4">
          <h3 className="font-semibold">Allow {pending.tool}?</h3>
          <CodeBlock label="Arguments" value={pending.args ?? ""} />
          <div className="mt-4 grid grid-cols-2 gap-2">
            <DecisionButton
              disabled={busy}
              onClick={() =>
                respond({ kind: "permission", permission: "deny_once" })
              }
            >
              Deny
            </DecisionButton>
            <DecisionButton
              primary
              disabled={busy}
              onClick={() =>
                respond({ kind: "permission", permission: "allow_once" })
              }
            >
              Allow once
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
                  <option value="">Choose…</option>
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
            Send answers
          </DecisionButton>
        </div>
      )}
      {pending.kind === "plan_approval" && (
        <div className="mt-4">
          <h3 className="font-semibold">Review the proposed plan</h3>
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
              Reject
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
              Approve
            </DecisionButton>
          </div>
        </div>
      )}
      {pending.kind === "custom" && (
        <div className="mt-4">
          <h3 className="font-semibold">{pending.customKind}</h3>
          <CodeBlock label="Request" value={pending.payload ?? ""} />
          <p className="mt-3 text-xs text-muted">
            This custom request has no product response control in the current
            baseline.
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

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-lg border border-rule bg-paper p-3">
      <dt className="font-mono text-[9px] tracking-[0.12em] text-muted uppercase">
        {label}
      </dt>
      <dd className="mt-1 font-mono text-xs">{value}</dd>
    </div>
  );
}
