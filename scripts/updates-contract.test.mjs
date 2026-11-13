import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { BridgeClient } from "../frontend/src/bridge/client.ts";
import {
  decodeUpdateView,
  decodeUpdateCommandResult,
  decodeUpdateWebsiteResult,
} from "../frontend/src/bridge/decode-contracts.ts";

const fixture = JSON.parse(
  readFileSync(
    new URL("../src/product/update.fixture", import.meta.url),
    "utf8",
  ),
);

const failedFixture = JSON.parse(
  readFileSync(
    new URL("../src/product/update_failed.fixture", import.meta.url),
    "utf8",
  ),
);

test("updates decode the independent actual Host encoding without transporting download URLs", () => {
  assert.deepEqual(decodeUpdateView(fixture), fixture);
  assert.equal(Object.hasOwn(decodeUpdateView(fixture), "downloadUrl"), false);
  const lastKnown = { ...fixture, checkState: "failed", checkError: "timeout" };
  assert.equal(decodeUpdateView(lastKnown).updateAvailable, true);
  assert.equal(
    decodeUpdateView({ ...fixture, downloadAvailable: false }).updateAvailable,
    true,
  );
});

test("updates decode the failed check diagnostic without any endpoint or address", () => {
  assert.deepEqual(decodeUpdateView(failedFixture), failedFixture);
  assert.equal(
    decodeUpdateView(failedFixture).checkDiagnostic.phase,
    "connect",
  );
  assert.doesNotMatch(
    JSON.stringify(decodeUpdateView(failedFixture).checkDiagnostic),
    /https?:|\/\/|\d+\.\d+\.\d+\.\d+|authorization|metask/i,
  );
  // A diagnostic belongs to a failed check and to nothing else.
  assert.throws(() =>
    decodeUpdateView({
      ...fixture,
      checkDiagnostic: failedFixture.checkDiagnostic,
    }),
  );
  for (const patch of [
    { checkDiagnostic: {} },
    { checkDiagnostic: { ...failedFixture.checkDiagnostic, phase: "idle" } },
    { checkDiagnostic: { ...failedFixture.checkDiagnostic, cause: "refused" } },
    { checkDiagnostic: { ...failedFixture.checkDiagnostic, elapsed: 1200 } },
    {
      checkDiagnostic: {
        ...failedFixture.checkDiagnostic,
        host: "example.com",
      },
    },
  ])
    assert.throws(() => decodeUpdateView({ ...failedFixture, ...patch }));
});

test("updates reject missing extra malformed and inconsistent wire facts", () => {
  for (const field of Object.keys(fixture)) {
    const missing = { ...fixture };
    delete missing[field];
    assert.throws(() => decodeUpdateView(missing));
  }
  for (const patch of [
    { downloadUrl: "https://example.com" },
    { checkState: "ready" },
    { checkError: "credentials" },
    { latestVersion: "0.2.8-beta" },
    { latestVersion: "00.2.8" },
    { latestVersion: "0.2.4294967296" },
    { latestVersion: null },
    { latestVersion: 8 },
    { downloadAvailable: true, updateAvailable: false },
    { checkState: "failed" },
    { checkError: "network" },
    { downloadState: "failed" },
    { downloadError: "invalid_link" },
  ])
    assert.throws(() => decodeUpdateView({ ...fixture, ...patch }));
  for (const value of [
    {},
    { outcome: "downloaded" },
    { outcome: "accepted", url: "https://example.com" },
  ])
    assert.throws(() => decodeUpdateCommandResult(value));
  assert.throws(() => decodeUpdateWebsiteResult({ outcome: "accepted" }));
});

test("updates client submits only explicit fixed intent and expected release version", async () => {
  const calls = [];
  const client = new BridgeClient({
    bridge: {
      async invoke(command, payload) {
        calls.push({ command, payload });
        return {
          outcome: command.endsWith("openWebsite") ? "opened" : "accepted",
        };
      },
      on() {
        return () => {};
      },
    },
  });
  assert.equal((await client.checkUpdates()).outcome, "accepted");
  assert.equal((await client.openUpdateDownload("0.2.10")).outcome, "accepted");
  assert.equal((await client.openUpdateWebsite()).outcome, "opened");
  assert.deepEqual(calls, [
    { command: "metawork.updates.check", payload: {} },
    {
      command: "metawork.updates.openDownload",
      payload: { expectedVersion: "0.2.10" },
    },
    { command: "metawork.updates.openWebsite", payload: {} },
  ]);
});
