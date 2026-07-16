import assert from "node:assert/strict";
import test from "node:test";

import { fetchWorkbenchSnapshot } from "../frontend/src/snapshot-client.ts";

function encoded(value) {
  return Buffer.from(value).toString("base64");
}

test("Workbench snapshots are assembled from identity-checked chunks", async () => {
  const expected = { revision: "9", sessions: [{ id: "3", user: "你好" }] };
  const source = Buffer.from(JSON.stringify(expected));
  const chunkBytes = 11;
  const invoke = async (command, payload) => {
    if (command === "begin")
      return { snapshotId: "17", bytes: source.length, chunkBytes };
    assert.equal(command, "chunk");
    const offset = Number(payload.offset);
    const chunk = source.subarray(offset, offset + chunkBytes);
    return {
      snapshotId: payload.snapshotId,
      offset,
      bytes: chunk.length,
      data: encoded(chunk),
    };
  };

  assert.deepEqual(
    await fetchWorkbenchSnapshot(invoke, "begin", "chunk"),
    expected,
  );
});

test("Workbench snapshot assembly rejects a stale chunk", async () => {
  const source = Buffer.from('{"revision":"1","sessions":[]}');
  const invoke = async (command) =>
    command === "begin"
      ? { snapshotId: "2", bytes: source.length, chunkBytes: source.length }
      : {
          snapshotId: "1",
          offset: 0,
          bytes: source.length,
          data: encoded(source),
        };

  await assert.rejects(
    fetchWorkbenchSnapshot(invoke, "begin", "chunk"),
    /identity mismatch/,
  );
});
