import test from "node:test";
import assert from "node:assert/strict";
import process from "node:process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { configuredChildTimeout, runChild } from "./run-child-process.mjs";

test("uses a configurable bounded child-process timeout", () => {
  assert.equal(configuredChildTimeout({}), 120_000);
  assert.equal(
    configuredChildTimeout({ METAWORK_CHILD_TIMEOUT_MS: "45000" }),
    45_000,
  );
  assert.throws(
    () => configuredChildTimeout({ METAWORK_CHILD_TIMEOUT_MS: "0" }),
    /positive integer/,
  );
  assert.throws(
    () => configuredChildTimeout({ METAWORK_CHILD_TIMEOUT_MS: "invalid" }),
    /positive integer/,
  );
});

test("a bounded child that overruns its timeout is killed and reported", async () => {
  await assert.rejects(
    runChild(process.execPath, ["-e", "setTimeout(() => {}, 60_000)"], {
      label: "overrunning probe",
      timeoutMs: 50,
    }),
    /overrunning probe exceeded 50 milliseconds/,
  );
});

test("an unbounded child runs to completion without arming a timer", async () => {
  await runChild(process.execPath, ["-e", ""], {
    label: "unbounded probe",
    timeoutMs: null,
  });
});

test("owned child receives an explicit environment and cancellation waits for close", async () => {
  await runChild(
    process.execPath,
    ["-e", "process.exit(process.env.PROBE === 'isolated' ? 0 : 1)"],
    {
      label: "explicit environment",
      env: { ...process.env, PROBE: "isolated" },
      timeoutMs: null,
    },
  );
  const cancellation = new AbortController();
  const timer = setTimeout(() => cancellation.abort(), 100);
  try {
    await assert.rejects(
      runChild(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
        label: "cancelled owned child",
        timeoutMs: null,
        signal: cancellation.signal,
      }),
      /cancelled owned child cancelled/,
    );
  } finally {
    clearTimeout(timer);
  }
});

test(
  "cancellation finishes even when an owned child ignores SIGTERM",
  { skip: process.platform === "win32" },
  async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "metawork-cancel-"));
    const ready = path.join(directory, "ready");
    const cancellation = new AbortController();
    let pid;
    let deadline;
    const pending = runChild(
      process.execPath,
      [
        "-e",
        `
    process.on('SIGTERM', () => {});
    require('node:fs').writeFileSync(process.argv[1], String(process.pid));
    setInterval(() => {}, 1000);
  `,
        ready,
      ],
      {
        label: "unresponsive owned child",
        timeoutMs: null,
        signal: cancellation.signal,
      },
    ).catch((error) => error);
    try {
      const startDeadline = Date.now() + 5000;
      while (pid === undefined) {
        pid =
          Number(
            await readFile(ready, "utf8").catch((error) => {
              if (error.code === "ENOENT") return "";
              throw error;
            }),
          ) || undefined;
        if (pid === undefined) {
          if (Date.now() >= startDeadline)
            throw new Error("child did not become ready");
          await new Promise((resolve) => setTimeout(resolve, 10));
        }
      }
      cancellation.abort();
      const error = await Promise.race([
        pending,
        new Promise((_, reject) => {
          deadline = setTimeout(
            () => reject(new Error("cancellation did not finish")),
            5000,
          );
        }),
      ]);
      assert.match(error.message, /unresponsive owned child cancelled/);
      assert.equal(error.childProcessesMayBeRunning, true);
      assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
    } finally {
      clearTimeout(deadline);
      if (pid !== undefined) {
        try {
          process.kill(-pid, "SIGKILL");
        } catch (error) {
          if (error.code !== "ESRCH") throw error;
        }
      }
      await pending;
      await rm(directory, { recursive: true, force: true });
    }
  },
);
