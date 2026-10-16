import { spawn } from "node:child_process";
import process from "node:process";

const defaultTimeoutMs = 120_000;

export function configuredChildTimeout(environment = process.env) {
  const raw = environment.METAWORK_CHILD_TIMEOUT_MS;
  if (raw === undefined) return defaultTimeoutMs;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value <= 0)
    throw new Error("METAWORK_CHILD_TIMEOUT_MS must be a positive integer");
  return value;
}

// Compilation and packaging have no meaningful upper bound on developer
// machines, so they pass timeoutMs: null and stay unbounded like the signing
// script's spawnSync calls. Everything else keeps the bounded default.
export async function runChild(
  command,
  arguments_,
  { cwd, label, env, signal, timeoutMs = configuredChildTimeout() },
) {
  if (signal?.aborted) throw new Error(`${label} cancelled`);
  const detached = process.platform !== "win32";
  const child = spawn(command, arguments_, {
    cwd,
    stdio: "inherit",
    detached,
    env,
  });
  const terminate = (terminationSignal) => {
    try {
      if (detached && child.pid) process.kill(-child.pid, terminationSignal);
      else child.kill(terminationSignal);
    } catch {
      child.kill(terminationSignal);
    }
  };
  let cancellationTimeout;
  const cancel = () => {
    terminate("SIGTERM");
    // Builds may run without a deadline, but cancellation must still finish.
    // Only escalate while the owned child is alive, before its PID is reaped.
    cancellationTimeout = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null)
        terminate("SIGKILL");
    }, 2000);
  };
  signal?.addEventListener("abort", cancel, { once: true });
  if (signal?.aborted) cancel();
  let timedOut = false;
  const timeout =
    timeoutMs === null
      ? null
      : setTimeout(() => {
          timedOut = true;
          terminate("SIGKILL");
        }, timeoutMs);
  let outcome;
  try {
    outcome = await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code, signal) => resolve({ code, signal }));
    });
  } finally {
    if (timeout !== null) clearTimeout(timeout);
    clearTimeout(cancellationTimeout);
    signal?.removeEventListener("abort", cancel);
  }
  if (signal?.aborted || timedOut || outcome.code !== 0) {
    const error = new Error(
      signal?.aborted
        ? `${label} cancelled`
        : timedOut
          ? `${label} exceeded ${timeoutMs} milliseconds`
          : `${label} failed${
              outcome.signal
                ? ` with signal ${outcome.signal}`
                : ` with exit code ${outcome.code}`
            }`,
    );
    // An abnormal parent exit cannot establish descendant quiescence: a child
    // may have started a separate process group. Keep its resources rather
    // than treating the original group's absence as proof of safe removal.
    error.childProcessesMayBeRunning = true;
    throw error;
  }
}
