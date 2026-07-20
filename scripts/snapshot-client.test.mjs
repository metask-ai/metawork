import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { fetchWorkbenchSnapshot } from "../frontend/src/bridge/snapshot/snapshot-client.ts";

const snapshotCommand = "metawork.workbench.snapshot";
const chunkCommand = "metawork.workbench.snapshot.chunk";

function encoded(value) {
  return Buffer.from(value).toString("base64");
}

test("Workbench snapshots are assembled from identity-checked chunks", async () => {
  const expected = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/workbench-snapshot-v6.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const source = Buffer.from(JSON.stringify(expected));
  const chunkBytes = 11;
  const invoke = async (command, payload) => {
    if (command === snapshotCommand)
      return { snapshotId: "17", bytes: source.length, chunkBytes };
    assert.equal(command, chunkCommand);
    const offset = Number(payload.offset);
    const chunk = source.subarray(offset, offset + chunkBytes);
    return {
      snapshotId: payload.snapshotId,
      offset,
      bytes: chunk.length,
      data: encoded(chunk),
    };
  };

  assert.deepEqual(await fetchWorkbenchSnapshot(invoke), expected);
});

test("Workbench snapshot assembly rejects a stale chunk", async () => {
  const source = Buffer.from(
    '{"schemaVersion":6,"revision":"1","account":{"sessionState":"signed_out","executionState":"none","operation":"none","accountId":"","displayName":"","apiKeys":[],"models":[],"selectedApiKeyId":"","selectedModel":"","canCreateTask":false,"errorCode":"none","safeDiagnostic":"","catalogGeneration":"0","executionGeneration":"0"},"tasks":[]}',
  );
  const invoke = async (command) =>
    command === snapshotCommand
      ? { snapshotId: "2", bytes: source.length, chunkBytes: source.length }
      : {
          snapshotId: "1",
          offset: 0,
          bytes: source.length,
          data: encoded(source),
        };

  await assert.rejects(fetchWorkbenchSnapshot(invoke), /identity mismatch/);
});
