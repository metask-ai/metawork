import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { EventDelivery } from "./event-delivery";
import { fetchWorkbenchSnapshot } from "./snapshot-client";
import { SnapshotDemand } from "./snapshot-demand";

type ToolView = {
  id: string;
  name: string;
  input: string;
  progress: string;
  content: string;
  state: "running" | "completed" | "failed";
  isError: boolean;
  elapsedMs: string;
};

type RunView = {
  id: string;
  phase:
    | "queued"
    | "running"
    | "waiting_ui"
    | "completed"
    | "stopped"
    | "cancelled"
    | "interrupted"
    | "failed";
  user: string;
  assistant: string;
  status: string;
  outcome: string | null;
  cause: string | null;
  usage: {
    input: string;
    output: string;
    cacheRead: string;
    cacheCreation: string;
  };
  tools: ToolView[];
};

type AskOption = { label: string; description: string; preview?: string };
type AskQuestion = {
  question: string;
  header: string;
  multi: boolean;
  options: AskOption[];
};

type PendingUi = {
  requestId: string;
  runId: string;
  kind: "ask_question" | "permission" | "plan_approval" | "custom";
  questions?: AskQuestion[];
  tool?: string;
  args?: string;
  plan?: string;
  customKind?: string;
  payload?: string;
};

type SessionView = {
  id: string;
  workspaceRoot: string;
  state: "idle" | "queued" | "running" | "waiting_ui" | "closing" | "closed";
  closeFailed: boolean;
  activeRunId: string;
  outcome: string | null;
  cause: string | null;
  runs: RunView[];
  pendingUi: PendingUi | null;
};

type WorkbenchSnapshot = { revision: string; sessions: SessionView[] };
type AgentBatchItem = {
  sessionId: string;
  runId: string;
  sequence: string;
  event?: unknown;
  object?: { id: string; bytes: number };
};
type AgentBatch = { generation: string; items: AgentBatchItem[] };
type AgentObject = {
  generation: string;
  sessionId: string;
  runId: string;
  sequence: string;
  event: unknown;
};
type HostSignal = {
  sequence: number;
  automation?: boolean;
  gate5Fixture?: boolean;
};

const commands = {
  ping: "metawork.smoke.ping",
  pingAck: "metawork.smoke.eventAck",
  connect: "metawork.events.connect",
  disconnect: "metawork.events.disconnect",
  ack: "metawork.events.ack",
  fetch: "metawork.events.fetch",
  chooseWorkspace: "metawork.workspace.choose",
  snapshot: "metawork.workbench.snapshot",
  snapshotChunk: "metawork.workbench.snapshot.chunk",
  createSession: "metawork.sessions.create",
  run: "metawork.sessions.run",
  cancel: "metawork.sessions.cancel",
  respondUi: "metawork.sessions.respondUi",
  closeSession: "metawork.sessions.close",
  gate5Fixture: "metawork.gate5.emitFixture",
} as const;

const events = {
  hostSignal: "metawork:host-signal",
  agent: "metawork:agent-events",
  workbench: "metawork:workbench-changed",
} as const;

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function revisionValue(value: string) {
  try {
    return BigInt(value);
  } catch {
    return -1n;
  }
}

function tokenTotal(run: RunView) {
  try {
    return (BigInt(run.usage.input) + BigInt(run.usage.output)).toString();
  } catch {
    return "invalid";
  }
}

export default function App() {
  const [snapshot, setSnapshot] = useState<WorkbenchSnapshot>({
    revision: "0",
    sessions: [],
  });
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null);
  const [workspacePath, setWorkspacePath] = useState("");
  const [workspaceGrant, setWorkspaceGrant] = useState("");
  const [prompt, setPrompt] = useState("");
  const [status, setStatus] = useState("Connect the native shell to begin.");
  const [busy, setBusy] = useState<string | null>(null);
  const [bridgeReady, setBridgeReady] = useState(false);
  const [viewSyncFailed, setViewSyncFailed] = useState(false);
  const [answers, setAnswers] = useState<Record<string, string[]>>({});
  const generation = useRef("0");
  const didGate5Fixture = useRef(false);
  const snapshotDemand = useRef(new SnapshotDemand());
  const snapshotInFlight = useRef<Promise<void> | null>(null);
  const deliveryRestart = useRef<(() => Promise<void>) | null>(null);

  const activeSession = useMemo(
    () =>
      snapshot.sessions.find((session) => session.id === activeSessionId) ??
      snapshot.sessions[0] ??
      null,
    [activeSessionId, snapshot.sessions],
  );

  const refreshSnapshot = useCallback(
    (targetRevision?: string): Promise<void> => {
      if (targetRevision === undefined) {
        snapshotDemand.current.request();
      } else {
        snapshotDemand.current.request(revisionValue(targetRevision));
        if (!snapshotDemand.current.needsRefresh() && !snapshotInFlight.current)
          return Promise.resolve();
      }
      if (snapshotInFlight.current) return snapshotInFlight.current;

      const pending = (async () => {
        try {
          while (snapshotDemand.current.needsRefresh()) {
            const zero = window.zero;
            if (!zero || generation.current === "0") return;
            const attemptGeneration = generation.current;
            snapshotDemand.current.beginAttempt();
            try {
              const next = await fetchWorkbenchSnapshot<WorkbenchSnapshot>(
                (command, payload) => zero.invoke(command, payload),
                commands.snapshot,
                commands.snapshotChunk,
              );
              if (generation.current !== attemptGeneration) return;
              const revision = revisionValue(next.revision);
              if (revision < 0n)
                throw new Error("Host returned an invalid Workbench revision");
              if (!snapshotDemand.current.accept(revision)) continue;
              setViewSyncFailed(false);
              setBridgeReady(true);
              setSnapshot(next);
              setActiveSessionId((current) => {
                if (
                  current &&
                  next.sessions.some((session) => session.id === current)
                )
                  return current;
                return next.sessions[0]?.id ?? null;
              });
            } catch (error) {
              if (generation.current !== attemptGeneration) return;
              const delay = snapshotDemand.current.failAttempt();
              if (delay === null) {
                setViewSyncFailed(true);
                setBridgeReady(false);
                throw error;
              }
              await new Promise((resolve) => window.setTimeout(resolve, delay));
              if (generation.current !== attemptGeneration) return;
            }
          }
        } finally {
          snapshotInFlight.current = null;
        }
      })();
      snapshotInFlight.current = pending;
      return pending;
    },
    [],
  );

  useEffect(() => {
    const zero = window.zero;
    if (!zero) return;
    let cancelled = false;
    let pendingWorkbenchRevision = "0";
    let workbenchRefreshTimer: number | null = null;

    const consumeBatch = async (batch: AgentBatch) => {
      for (const item of batch.items) {
        if (batch.generation !== generation.current) return;
        const inline = Object.prototype.hasOwnProperty.call(item, "event");
        if (inline === Boolean(item.object))
          throw new Error("Invalid Agent event envelope");
        if (item.object) {
          const fetched = await zero.invoke<AgentObject>(commands.fetch, {
            generation: batch.generation,
            sessionId: item.sessionId,
            runId: item.runId,
            objectId: item.object.id,
          });
          if (
            fetched.generation !== batch.generation ||
            fetched.sessionId !== item.sessionId ||
            fetched.runId !== item.runId ||
            fetched.sequence !== item.sequence
          )
            throw new Error("Fetched Agent event identity mismatch");
        }
        await zero.invoke(commands.ack, {
          generation: batch.generation,
          sessionId: item.sessionId,
          runId: item.runId,
          sequence: item.sequence,
        });
      }
    };

    const delivery = new EventDelivery<AgentBatch>({
      connect: async () =>
        (await zero.invoke<{ generation: string }>(commands.connect, {}))
          .generation,
      disconnect: async (activeGeneration) => {
        await zero.invoke(commands.disconnect, {
          generation: activeGeneration,
        });
      },
      consume: consumeBatch,
      onConnected: async (activeGeneration, recovered) => {
        generation.current = activeGeneration;
        snapshotDemand.current.beginGeneration(activeGeneration);
        setViewSyncFailed(false);
        setBridgeReady(true);
        await refreshSnapshot();
        if (generation.current !== activeGeneration)
          throw new Error("Event delivery generation changed during resync");
        // A request from the previous generation can still own the shared
        // in-flight Promise. It returns without publishing, while preserving
        // this generation's demand. Start the real resync before declaring
        // the new connection ready.
        if (snapshotDemand.current.needsRefresh()) await refreshSnapshot();
        if (recovered)
          setStatus("Event delivery recovered with a new Host generation.");
      },
      onDisconnected: () => {
        generation.current = "0";
        snapshotDemand.current.beginGeneration("0");
        setBridgeReady(false);
      },
      onRecoveryFailure: (error) => {
        setViewSyncFailed(true);
        setStatus(`Event delivery recovery failed: ${errorText(error)}`);
      },
    });
    deliveryRestart.current = () =>
      delivery.restart(new Error("User requested event delivery recovery"));

    const removeAgent = zero.on<AgentBatch>(events.agent, (batch) => {
      delivery.enqueue(batch);
    });
    const scheduleWorkbenchRefresh = (revision: string) => {
      if (revisionValue(revision) > revisionValue(pendingWorkbenchRevision))
        pendingWorkbenchRevision = revision;
      if (workbenchRefreshTimer !== null) return;
      workbenchRefreshTimer = window.setTimeout(() => {
        workbenchRefreshTimer = null;
        const target = pendingWorkbenchRevision;
        pendingWorkbenchRevision = "0";
        void refreshSnapshot(target).catch((error) =>
          setStatus(errorText(error)),
        );
      }, 32);
    };
    const removeWorkbench = zero.on<{ revision: string }>(
      events.workbench,
      ({ revision }) => scheduleWorkbenchRefresh(revision),
    );
    const removeHostSignal = zero.on<HostSignal>(
      events.hostSignal,
      (signal) => {
        void zero.invoke(commands.pingAck, { sequence: signal.sequence });
      },
    );

    void delivery
      .start()
      .then(async () => {
        if (cancelled) return;
        const signal = await zero.invoke<HostSignal>(commands.ping, {
          source: "gate-6-workbench",
        });
        setStatus("Workbench connected.");
        if (signal.gate5Fixture === true && !didGate5Fixture.current) {
          didGate5Fixture.current = true;
          await zero.invoke(commands.gate5Fixture, {});
        }
      })
      .catch((error) => {
        if (!cancelled) {
          setViewSyncFailed(true);
          setStatus(`Host connection failed: ${errorText(error)}`);
        }
      });

    const onPageHide = () => {
      void delivery.stop();
    };
    window.addEventListener("pagehide", onPageHide);
    return () => {
      cancelled = true;
      setBridgeReady(false);
      removeAgent();
      removeWorkbench();
      removeHostSignal();
      if (workbenchRefreshTimer !== null)
        window.clearTimeout(workbenchRefreshTimer);
      deliveryRestart.current = null;
      window.removeEventListener("pagehide", onPageHide);
      void delivery.stop();
    };
  }, [refreshSnapshot]);

  async function retryViewSynchronization() {
    if (busy !== null) return;
    setBusy("reconnect");
    snapshotDemand.current.resetRetry();
    setViewSyncFailed(false);
    try {
      if (generation.current !== "0") {
        await refreshSnapshot();
      } else {
        const restart = deliveryRestart.current;
        if (!restart) throw new Error("Event delivery is not available");
        await restart();
      }
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
    const zero = window.zero;
    if (!zero || viewSyncFailed || !bridgeReady) return;
    setBusy("workspace");
    setWorkspaceGrant("");
    try {
      const result = await zero.invoke<{
        selected: boolean;
        workspaceRoot?: string;
        grant?: string;
      }>(commands.chooseWorkspace, {});
      if (result.selected && result.workspaceRoot && result.grant) {
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
    const zero = window.zero;
    if (
      !zero ||
      viewSyncFailed ||
      !bridgeReady ||
      !workspacePath ||
      !workspaceGrant
    )
      return;
    setBusy("create");
    try {
      let result: { sessionId: string };
      try {
        result = await zero.invoke<{ sessionId: string }>(
          commands.createSession,
          { workspaceGrant },
        );
      } catch (error) {
        setStatus(`Session creation failed: ${errorText(error)}`);
        return;
      }
      setActiveSessionId(result.sessionId);
      await refreshAfterCommit(
        "Session created. AgentCore credentials remain in the Host.",
        "Session creation",
      );
    } finally {
      setWorkspaceGrant("");
      setBusy(null);
    }
  }

  async function submitRun() {
    const zero = window.zero;
    if (
      !zero ||
      viewSyncFailed ||
      !bridgeReady ||
      !activeSession ||
      !prompt.trim()
    )
      return;
    const submitted = prompt;
    setPrompt("");
    setBusy("run");
    try {
      try {
        await zero.invoke(commands.run, {
          sessionId: activeSession.id,
          prompt: submitted,
        });
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
    const zero = window.zero;
    if (
      !zero ||
      viewSyncFailed ||
      !bridgeReady ||
      !activeSession ||
      activeSession.activeRunId === "0"
    )
      return;
    setBusy("cancel");
    try {
      try {
        await zero.invoke(commands.cancel, {
          sessionId: activeSession.id,
          runId: activeSession.activeRunId,
        });
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
    const zero = window.zero;
    if (
      !zero ||
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
        await zero.invoke(commands.closeSession, {
          sessionId: activeSession.id,
        });
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

  async function respondUi(payload: Record<string, unknown>) {
    const zero = window.zero;
    const pending = activeSession?.pendingUi;
    if (!zero || viewSyncFailed || !bridgeReady || !activeSession || !pending)
      return;
    setBusy("respond");
    try {
      try {
        await zero.invoke(commands.respondUi, {
          sessionId: activeSession.id,
          runId: pending.runId,
          requestId: pending.requestId,
          ...payload,
        });
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
                onClick={() => setActiveSessionId(session.id)}
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
  respond: (payload: Record<string, unknown>) => void;
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
