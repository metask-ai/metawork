import { decodeWorkbenchSnapshot } from "../frontend/src/bridge/decode-contracts.ts";
import { maxSnapshotPreparationSteps } from "../frontend/src/bridge/generated-wire.ts";
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
        "../frontend/src/bridge/__fixtures__/product-view.fixture",
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

  assert.deepEqual(
    await fetchWorkbenchSnapshot(invoke, expected.scope),
    decodeWorkbenchSnapshot(expected),
  );
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
      "../frontend/src/bridge/__fixtures__/product-view.fixture",
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
  }, JSON.parse(fixture).scope);
  assert.deepEqual(actual, decodeWorkbenchSnapshot(JSON.parse(fixture)));
  assert.equal(chunks, 36);
});

test("snapshot descriptor accepts the Host limit and rejects larger budgets before reading", async () => {
  const host = readFileSync(
    new URL("../src/bridge/snapshot_contract.zig", import.meta.url),
    "utf8",
  );
  assert.match(host, /pub const max_snapshot_bytes = 64 \* 1024 \* 1024;/);
  const delivery = readFileSync(
    new URL("../src/bridge/snapshot_delivery.zig", import.meta.url),
    "utf8",
  );
  assert.match(
    delivery,
    /max_bytes: usize = @import\("snapshot_contract.zig"\).max_snapshot_bytes/,
  );
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

test("scoped snapshot transport assembles split UTF-8 and rejects malformed UTF-8", async () => {
  const wire = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/product-view.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  wire.taskPage.task.title = wire.taskIndex[0].title = "跨块内容 café 🏔";
  const source = Buffer.from(JSON.stringify(wire));
  const invoke = async (command, payload) => {
    if (command === snapshotCommand)
      return { snapshotId: "91", bytes: source.length, chunkBytes: 5 };
    const offset = Number(payload.offset),
      part = source.subarray(offset, offset + 5);
    return {
      snapshotId: "91",
      offset,
      bytes: part.length,
      data: part.toString("base64"),
    };
  };
  const actual = await fetchWorkbenchSnapshot(invoke, wire.scope);
  assert.equal(actual.tasks[0].title, wire.taskPage.task.title);
  const invalid = Buffer.from([0xc3, 0x28]);
  await assert.rejects(
    fetchWorkbenchSnapshot(async (command) =>
      command === snapshotCommand
        ? { snapshotId: "92", bytes: 2, chunkBytes: 2 }
        : {
            snapshotId: "92",
            offset: 0,
            bytes: 2,
            data: invalid.toString("base64"),
          },
    ),
    /not valid UTF-8/,
  );
});

test("snapshot preparation uses the same command and a fixed identity before chunks", async () => {
  const expected = JSON.parse(
    readFileSync(
      new URL(
        "../frontend/src/bridge/__fixtures__/product-view.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const source = Buffer.from(JSON.stringify(expected));
  let steps = 0;
  const invoke = async (command, payload) => {
    if (command === snapshotCommand) {
      if (steps > 0) assert.deepEqual(payload, { preparingSnapshotId: "31" });
      if (++steps < 4) return { snapshotId: "31", phase: "preparing" };
      return {
        snapshotId: "31",
        bytes: source.length,
        chunkBytes: source.length,
      };
    }
    assert.equal(steps, 4);
    return {
      snapshotId: "31",
      offset: 0,
      bytes: source.length,
      data: encoded(source),
    };
  };
  assert.deepEqual(
    await fetchWorkbenchSnapshot(invoke, expected.scope),
    decodeWorkbenchSnapshot(expected),
  );
});

test("snapshot preparation fails closed on identity changes, extra fields and endless preparation", async () => {
  for (const kind of ["changed", "readyChanged", "extra", "endless"]) {
    let calls = 0;
    await assert.rejects(
      fetchWorkbenchSnapshot(async (command) => {
        assert.equal(command, snapshotCommand);
        calls += 1;
        if (kind === "extra")
          return { snapshotId: "1", phase: "preparing", bytes: 1 };
        if (calls > 1 && kind === "readyChanged")
          return { snapshotId: "2", bytes: 1, chunkBytes: 1 };
        return {
          snapshotId: calls > 1 && kind === "changed" ? "2" : "1",
          phase: "preparing",
        };
      }),
      RendererBridgeContractError,
    );
    assert(calls <= maxSnapshotPreparationSteps + 1);
  }
});
