import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { BridgeClient } from "../frontend/src/bridge/client.ts";
import {
  decodeOfficeComponentView,
  decodeOfficeComponentResult,
} from "../frontend/src/bridge/generated-wire.ts";

const initial = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
).office;

test("Office management wire is closed and preserves zero progress and full u64 precision", () => {
  assert.deepEqual(decodeOfficeComponentView(initial, "$"), initial);
  const running = {
    ...initial,
    supported: true,
    health: "ready",
    generation: "18446744073709551615",
    operation: {
      id: "9",
      kind: "install",
      phase: "downloading",
      bytes: "0",
      total: "18446744073709551615",
      cancelling: false,
    },
  };
  assert.deepEqual(decodeOfficeComponentView(running, "$"), running);
  for (const value of [
    { ...initial, generation: "0" },
    { ...initial, generation: "01" },
    { ...initial, generation: 1 },
    { ...initial, supported: 1 },
    { ...initial, downloadUrl: "https://example.invalid/" },
    {
      ...running,
      operation: { ...running.operation, bytes: "18446744073709551616" },
    },
    { ...running, operation: { ...running.operation, phase: "unknown" } },
    { ...initial, actions: { ...initial.actions, other: true } },
    Object.fromEntries(
      Object.entries(initial).filter(([key]) => key !== "terminal"),
    ),
  ])
    assert.throws(() => decodeOfficeComponentView(value, "$"));
  const result = {
    accepted: true,
    generation: "7",
    operationId: "9",
    reason: null,
  };
  assert.deepEqual(decodeOfficeComponentResult(result, "$"), result);
  assert.throws(() =>
    decodeOfficeComponentResult({ ...result, operationId: "0" }, "$"),
  );
  assert.throws(() =>
    decodeOfficeComponentResult({ ...result, reason: "unrecognized" }, "$"),
  );
});

test("Office commands carry only fixed intent; cancellation is stable across progress generations", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: {
      async invoke(command, payload) {
        calls.push({ command, payload });
        return {
          accepted: true,
          generation: "11",
          operationId: "9",
          reason: null,
        };
      },
      on() {
        return () => {};
      },
    },
  });
  for (const action of ["install", "repair", "remove", "retry", "cleanup"])
    await client.manageOffice(action, "7");
  await client.cancelOffice("9");
  assert.deepEqual(calls, [
    ...["install", "repair", "remove", "retry", "cleanup"].map((action) => ({
      command: `metawork.office.${action}`,
      payload: { expectedGeneration: "7" },
    })),
    { command: "metawork.office.cancel", payload: { operationId: "9" } },
  ]);
});

test("Office transport failure does not replay the admitted effect", async () => {
  let calls = 0;
  const client = new BridgeClient({
    bridge: {
      async invoke() {
        calls++;
        throw new Error("lost response");
      },
      on() {
        return () => {};
      },
    },
  });
  await assert.rejects(client.manageOffice("install", "7"));
  assert.equal(calls, 1);
});
