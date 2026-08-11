import test from "node:test";
import assert from "node:assert/strict";
import process from "node:process";
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
