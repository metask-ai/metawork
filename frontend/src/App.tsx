import { useCallback, useEffect, useMemo, useRef, useState } from "react";

type HostSignal = {
  sequence: number;
  transport: string;
  origin: string;
  onMainThread: boolean;
  requestBytes?: number;
};

type TraceEntry = HostSignal & {
  id: number;
  direction: "React → Zig" | "Zig → React";
  receivedAt: string;
};

const bridgeCommand = "metawork.smoke.ping";
const hostEvent = "metawork:host-signal";
const eventAckCommand = "metawork.smoke.eventAck";

function errorText(error: unknown) {
  if (error instanceof Error) return error.message;
  return String(error);
}

export default function App() {
  const [bridgeReady, setBridgeReady] = useState(Boolean(window.zero));
  const [trace, setTrace] = useState<TraceEntry[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [result, setResult] = useState("Waiting for the native shell.");
  const [childWindowId, setChildWindowId] = useState<number | null>(null);
  const traceId = useRef(0);
  const didAutoPing = useRef(false);

  const appendTrace = useCallback(
    (direction: TraceEntry["direction"], signal: HostSignal) => {
      traceId.current += 1;
      const id = traceId.current;
      setTrace((current) =>
        [
          {
            ...signal,
            id,
            direction,
            receivedAt: new Date().toLocaleTimeString([], {
              hour12: false,
              hour: "2-digit",
              minute: "2-digit",
              second: "2-digit",
              fractionalSecondDigits: 3,
            }),
          },
          ...current,
        ].slice(0, 20),
      );
    },
    [],
  );

  const runPing = useCallback(async () => {
    const zero = window.zero;
    if (!zero) {
      setBridgeReady(false);
      setResult(
        "Open this page through the Native SDK shell to run the bridge smoke.",
      );
      return;
    }

    setBusy("ping");
    try {
      const response = await zero.invoke<HostSignal>(bridgeCommand, {
        source: "phase-0-react-shell",
      });
      appendTrace("React → Zig", response);
      sessionStorage.setItem(
        "metawork:last-host-sequence",
        String(response.sequence),
      );
      setResult(`Host answered on sequence ${response.sequence}.`);
      setBridgeReady(true);
    } catch (error) {
      setResult(`Bridge failed: ${errorText(error)}`);
    } finally {
      setBusy(null);
    }
  }, [appendTrace]);

  useEffect(() => {
    const zero = window.zero;
    if (!zero) return;

    const unsubscribe = zero.on<HostSignal>(hostEvent, (signal) => {
      appendTrace("Zig → React", signal);
      void zero
        .invoke<HostSignal>(eventAckCommand, { sequence: signal.sequence })
        .then((acknowledgement) => {
          appendTrace("React → Zig", acknowledgement);
        })
        .catch((error) => {
          setResult(`Event acknowledgement failed: ${errorText(error)}`);
        });
    });
    if (!didAutoPing.current) {
      didAutoPing.current = true;
      void runPing();
    }
    return unsubscribe;
  }, [appendTrace, runPing]);

  const previousSequence = useMemo(
    () => sessionStorage.getItem("metawork:last-host-sequence") ?? "none",
    [],
  );

  async function choose(kind: "file" | "directory") {
    const zero = window.zero;
    if (!zero) return;
    setBusy(kind);
    try {
      const paths = await zero.dialogs.openFile({
        title:
          kind === "file"
            ? "Choose a smoke-test file"
            : "Choose a smoke-test workspace",
        allowDirectories: kind === "directory",
        allowMultiple: false,
      });
      setResult(
        paths?.[0] ??
          `${kind === "file" ? "File" : "Directory"} selection cancelled.`,
      );
    } catch (error) {
      setResult(`Dialog failed: ${errorText(error)}`);
    } finally {
      setBusy(null);
    }
  }

  async function createWindow() {
    const zero = window.zero;
    if (!zero) return;
    setBusy("window");
    try {
      const created = await zero.windows.create({
        label: `smoke-${Date.now()}`,
        title: "MetaWork · Secondary smoke",
        width: 640,
        height: 440,
        url: window.location.href,
      });
      setChildWindowId(created.id);
      setResult(`Created native window ${created.id}.`);
    } catch (error) {
      setResult(`Window creation failed: ${errorText(error)}`);
    } finally {
      setBusy(null);
    }
  }

  async function closeChildWindow() {
    const zero = window.zero;
    if (!zero || childWindowId === null) return;
    setBusy("close-child");
    try {
      await zero.windows.close(childWindowId);
      setResult(`Closed native window ${childWindowId}.`);
      setChildWindowId(null);
    } catch (error) {
      setResult(`Window close failed: ${errorText(error)}`);
    } finally {
      setBusy(null);
    }
  }

  async function closeMainWindow() {
    const zero = window.zero;
    if (!zero) return;
    setBusy("close-main");
    try {
      await zero.windows.close("main");
    } catch (error) {
      setResult(`App close failed: ${errorText(error)}`);
      setBusy(null);
    }
  }

  return (
    <main className="min-h-screen bg-ink text-cloud selection:bg-signal/30">
      <div className="mx-auto grid min-h-screen max-w-[1480px] grid-cols-1 lg:grid-cols-[minmax(0,1fr)_420px]">
        <section className="flex min-h-[58vh] flex-col border-b border-line px-6 py-8 sm:px-10 lg:border-r lg:border-b-0 lg:px-14 lg:py-12">
          <header className="flex items-center justify-between gap-6">
            <div className="flex items-center gap-3">
              <span
                className={`h-2.5 w-2.5 rounded-full ${bridgeReady ? "bg-ok shadow-[0_0_16px_#5ee6a8]" : "bg-warn"}`}
              />
              <span className="font-mono text-[11px] tracking-[0.24em] text-mist uppercase whitespace-nowrap">
                Phase 0 / Gate 0
              </span>
            </div>
            <span className="hidden font-mono text-[11px] text-steel sm:inline">
              Native SDK {__NATIVE_SDK_VERSION__} · macOS
            </span>
          </header>

          <div className="my-auto py-16">
            <p className="mb-5 max-w-xl font-mono text-xs leading-6 text-signal">
              A live transport bench for the desktop boundary.
            </p>
            <h1 className="max-w-4xl font-display text-[3rem] leading-[0.82] font-semibold tracking-[-0.075em] text-bone sm:text-[clamp(3.5rem,8vw,8.5rem)] sm:leading-[0.78]">
              Host,
              <br />
              answer.
            </h1>
            <p className="mt-10 max-w-2xl text-base leading-7 text-mist sm:text-lg">
              This shell proves that trusted React chrome can call Zig, receive
              an explicit response, and accept a native event without inventing
              an AgentCore protocol.
            </p>
          </div>

          <div className="grid gap-px overflow-hidden rounded-2xl border border-line bg-line sm:grid-cols-3">
            <Metric label="Release origin" value="zero://app" />
            <Metric label="Bridge ceiling" value="1 MiB" />
            <Metric label="Host event budget" value="8 KiB" />
          </div>
        </section>

        <aside className="flex min-h-screen flex-col bg-panel px-6 py-8 sm:px-8 lg:py-10">
          <div className="flex items-start justify-between gap-4 border-b border-line pb-6">
            <div>
              <p className="font-mono text-[10px] tracking-[0.22em] text-steel uppercase">
                Transport rail
              </p>
              <h2 className="mt-2 text-xl font-semibold tracking-tight text-bone">
                Live boundary trace
              </h2>
            </div>
            <button
              className="focus-ring rounded-full border border-line px-3 py-1.5 font-mono text-[10px] text-mist transition hover:border-signal hover:text-bone disabled:opacity-40"
              disabled={!bridgeReady || busy !== null}
              onClick={() => void runPing()}
            >
              {busy === "ping" ? "Pinging…" : "Ping host"}
            </button>
          </div>

          <div className="grid grid-cols-2 gap-3 border-b border-line py-5 font-mono text-[11px]">
            <Status
              label="Bridge"
              value={bridgeReady ? "ready" : "offline"}
              active={bridgeReady}
            />
            <Status label="Before reload" value={previousSequence} />
          </div>

          <div className="relative min-h-[280px] flex-1 overflow-y-auto py-6 pl-7">
            <div className="absolute top-7 bottom-7 left-[7px] w-px bg-line" />
            {trace.length === 0 ? (
              <p className="pt-1 text-sm leading-6 text-steel">
                No transport frames yet. Ping the host to begin.
              </p>
            ) : (
              <ol className="space-y-5">
                {trace.map((entry) => (
                  <li className="relative" key={entry.id}>
                    <span
                      className={`absolute top-1.5 -left-[25px] h-2.5 w-2.5 rounded-full border-2 border-panel ${entry.direction === "Zig → React" ? "bg-signal" : "bg-ok"}`}
                    />
                    <div className="flex items-baseline justify-between gap-4">
                      <strong className="font-mono text-[11px] font-medium text-bone">
                        {entry.direction}
                      </strong>
                      <time className="font-mono text-[10px] text-steel">
                        {entry.receivedAt}
                      </time>
                    </div>
                    <p className="mt-1 font-mono text-[10px] leading-5 text-mist">
                      #{entry.sequence} · {entry.transport} · main thread{" "}
                      {String(entry.onMainThread)}
                    </p>
                  </li>
                ))}
              </ol>
            )}
          </div>

          <div className="space-y-3 border-t border-line pt-6">
            <p className="min-h-12 rounded-xl bg-ink/60 px-4 py-3 font-mono text-[11px] leading-5 text-mist">
              {result}
            </p>
            <div className="grid grid-cols-2 gap-2">
              <Action
                disabled={!bridgeReady || busy !== null}
                onClick={() => void choose("file")}
              >
                Choose file
              </Action>
              <Action
                disabled={!bridgeReady || busy !== null}
                onClick={() => void choose("directory")}
              >
                Choose directory
              </Action>
              <Action
                disabled={!bridgeReady || busy !== null}
                onClick={() => void createWindow()}
              >
                Create window
              </Action>
              <Action
                disabled={
                  !bridgeReady || busy !== null || childWindowId === null
                }
                onClick={() => void closeChildWindow()}
              >
                Close child
              </Action>
              <Action
                disabled={!bridgeReady || busy !== null}
                onClick={() => window.location.reload()}
              >
                Reload renderer
              </Action>
              <Action
                danger
                disabled={!bridgeReady || busy !== null}
                onClick={() => void closeMainWindow()}
              >
                Close app
              </Action>
            </div>
          </div>
        </aside>
      </div>
    </main>
  );
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="bg-ink px-5 py-5">
      <p className="font-mono text-[10px] tracking-[0.16em] text-steel uppercase">
        {label}
      </p>
      <p className="mt-2 text-sm font-medium text-bone">{value}</p>
    </div>
  );
}

function Status({
  label,
  value,
  active = false,
}: {
  label: string;
  value: string;
  active?: boolean;
}) {
  return (
    <div>
      <p className="text-steel">{label}</p>
      <p className={`mt-1 ${active ? "text-ok" : "text-mist"}`}>{value}</p>
    </div>
  );
}

function Action({
  children,
  danger = false,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { danger?: boolean }) {
  return (
    <button
      className={`focus-ring rounded-xl border px-3 py-3 text-left text-xs font-medium transition disabled:cursor-not-allowed disabled:opacity-35 ${
        danger
          ? "border-danger/35 text-danger hover:border-danger hover:bg-danger/8"
          : "border-line text-mist hover:border-signal/70 hover:bg-signal/8 hover:text-bone"
      }`}
      {...props}
    >
      {children}
    </button>
  );
}
