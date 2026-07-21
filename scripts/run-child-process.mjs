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

export async function runChild(
  command,
  arguments_,
  { cwd, label, timeoutMs = configuredChildTimeout() },
) {
  const detached = process.platform !== "win32";
  const child = spawn(command, arguments_, {
    cwd,
    stdio: "inherit",
    detached,
  });
  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    try {
      if (detached && child.pid) process.kill(-child.pid, "SIGKILL");
      else child.kill("SIGKILL");
    } catch {
      child.kill("SIGKILL");
    }
  }, timeoutMs);
  let outcome;
  try {
    outcome = await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("exit", (code, signal) => resolve({ code, signal }));
    });
  } finally {
    clearTimeout(timeout);
  }
  if (timedOut) throw new Error(`${label} exceeded ${timeoutMs} milliseconds`);
  if (outcome.code !== 0)
    throw new Error(
      `${label} failed${
        outcome.signal
          ? ` with signal ${outcome.signal}`
          : ` with exit code ${outcome.code}`
      }`,
    );
}
