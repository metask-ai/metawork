import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { fetchWorkbenchSnapshot } from "../frontend/src/bridge/snapshot/snapshot-client.ts";
import { RendererBridgeContractError } from "../frontend/src/bridge/contract-error.ts";

const snapshotCommand = "metawork.workbench.snapshot";
const chunkCommand = "metawork.workbench.snapshot.chunk";

function encoded(value) {
  return Buffer.from(value).toString("base64");
}

test("Workbench snapshots are assembled from identity-checked chunks", async () => {
  const expected = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
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
  const source = Buffer.from('{"revision":"1"}');
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

test("a malformed snapshot is a typed terminal contract failure", async () => {
  const source = Buffer.from('{"revision":"1"}');
  const invoke = async (command, payload) =>
    command === snapshotCommand
      ? { snapshotId: "3", bytes: source.length, chunkBytes: source.length }
      : {
          snapshotId: payload.snapshotId,
          offset: 0,
          bytes: source.length,
          data: encoded(source),
        };

  await assert.rejects(
    fetchWorkbenchSnapshot(invoke),
    (error) =>
      error instanceof RendererBridgeContractError &&
      error.code === "invalid_response",
  );
});

test("a valid snapshot larger than 8 MiB is assembled within the Host budget", async () => {
  const fixture = readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  );
  // JSON whitespace exercises transport size without violating product bounds.
  const fixtureBytes = Buffer.from(fixture);
  const source = Buffer.concat([
    fixtureBytes,
    Buffer.alloc(9 * 1024 * 1024 - fixtureBytes.length, " "),
  ]);
  const chunkBytes = 256 * 1024;
  let chunks = 0;
  const actual = await fetchWorkbenchSnapshot(async (command, payload) => {
    if (command === snapshotCommand)
      return { snapshotId: "19", bytes: source.length, chunkBytes };
    assert.equal(command, chunkCommand);
    assert.equal(payload.snapshotId, "19");
    const offset = chunks++ * chunkBytes;
    assert.equal(Number(payload.offset), offset);
    const part = source.subarray(offset, offset + chunkBytes);
    return {
      snapshotId: "19",
      offset,
      bytes: part.length,
      data: encoded(part),
    };
  });
  assert.deepEqual(actual, JSON.parse(fixture));
  assert.equal(chunks, 36);
});

test("snapshot descriptor accepts the Host limit and rejects larger budgets before reading", async () => {
  const host = readFileSync(
    new URL("../src/bridge/snapshot_delivery.zig", import.meta.url),
    "utf8",
  );
  assert.match(host, /pub const max_bytes: usize = 64 \* 1024 \* 1024;/);
  const limit = 64 * 1024 * 1024;
  const firstChunk = new Error("descriptor accepted");
  let reads = 0;
  await assert.rejects(
    fetchWorkbenchSnapshot(async (command) => {
      if (command === snapshotCommand)
        return { snapshotId: "20", bytes: limit, chunkBytes: 256 * 1024 };
      reads++;
      throw firstChunk;
    }),
    (error) => error === firstChunk,
  );
  assert.equal(reads, 1);
  for (const [bytes, chunkBytes] of [
    [limit + 1, 256 * 1024],
    [limit, 256 * 1024 + 1],
  ]) {
    await assert.rejects(
      fetchWorkbenchSnapshot(async (command) => {
        assert.equal(command, snapshotCommand);
        return { snapshotId: "21", bytes, chunkBytes };
      }),
      /exceeds the negotiated bounds/,
    );
  }
});
