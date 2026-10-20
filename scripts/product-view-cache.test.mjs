import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { ViewCache } from "../frontend/src/bridge/snapshot/view-cache.ts";
import { fetchWorkbenchSnapshot } from "../frontend/src/bridge/snapshot/snapshot-client.ts";
import { viewBlockNames } from "../frontend/src/bridge/contracts.ts";
import { decodeWorkbenchSnapshot } from "../frontend/src/bridge/decode-contracts.ts";
const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/product-view.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);
function seed(cache) {
  const captured = cache.capture(fixture.scope);
  const candidate = cache.materialize(
    structuredClone(fixture),
    fixture.scope,
    captured,
  );
  const snapshot = decodeWorkbenchSnapshot(candidate.wire);
  candidate.install(snapshot);
  return snapshot;
}
function reused(names = viewBlockNames) {
  const wire = structuredClone(fixture);
  wire.revision = "91";
  wire.reusedBlocks = [...names];
  for (const name of names) wire[name] = null;
  return wire;
}
test("Product block reuse transports only confirmed bodies and preserves stable Renderer references", async () => {
  const cache = new ViewCache();
  const previous = seed(cache);
  const wire = reused();
  let source;
  const snapshot = await fetchWorkbenchSnapshot(
    async (command, payload) => {
      if (command === "metawork.workbench.snapshot") {
        assert.deepEqual(payload.known, {
          securityEpoch: fixture.securityEpoch,
          versions: fixture.blockVersions,
        });
        source = Buffer.from(JSON.stringify(wire));
        return {
          snapshotId: "12",
          bytes: source.length,
          chunkBytes: source.length,
        };
      }
      return {
        snapshotId: "12",
        offset: 0,
        bytes: source.length,
        data: source.toString("base64"),
      };
    },
    fixture.scope,
    cache,
  );
  assert.equal(snapshot.revision, "91");
  assert.equal(snapshot.tasks, previous.tasks);
  assert.equal(snapshot.account, previous.account);
  assert.equal(snapshot.taskIndex, previous.taskIndex);
  assert.equal(
    source.length < Buffer.byteLength(JSON.stringify(fixture)) / 2,
    true,
  );
});
test("Product reuse rejects missing, duplicate, stale, wrong-scope and unversioned blocks", () => {
  for (const mutate of [
    (wire) => {
      wire.securityEpoch = "99";
    },
    (wire) => {
      wire.blockVersions.context = "99";
    },
    (wire) => {
      wire.reusedBlocks.push("context");
    },
    (wire) => {
      wire.reusedBlocks.push("unexpected");
    },
    (wire) => {
      wire.context = fixture.context;
    },
    (wire) => {
      wire.blockVersions.context = "0";
    },
    (wire) => {
      wire.blockVersions.context = "18446744073709551616";
    },
  ]) {
    const cache = new ViewCache();
    seed(cache);
    const wire = reused();
    mutate(wire);
    assert.throws(() =>
      cache.materialize(wire, fixture.scope, cache.capture(fixture.scope)),
    );
  }
  const empty = new ViewCache();
  assert.throws(() =>
    empty.materialize(reused(), fixture.scope, empty.capture(fixture.scope)),
  );
  const cache = new ViewCache();
  seed(cache);
  const other = { ...fixture.scope, taskId: "999" };
  assert.equal(cache.capture(other).known.versions.taskPage, "0");
  assert.throws(() => cache.materialize(reused(), other, cache.capture(other)));
});
test("Product cache clears across security epochs, reconnect and a clear during an in-flight read", () => {
  const cache = new ViewCache();
  seed(cache);
  const old = cache.capture(fixture.scope);
  cache.clear();
  assert.throws(
    () => cache.materialize(reused(), fixture.scope, old),
    /connection changed/,
  );
  assert.equal(cache.capture(fixture.scope).known.securityEpoch, "0");
  seed(cache);
  const fresh = structuredClone(fixture);
  fresh.securityEpoch = "42";
  const next = cache.materialize(
    fresh,
    fixture.scope,
    cache.capture(fixture.scope),
  );
  next.install(decodeWorkbenchSnapshot(next.wire));
  assert.equal(cache.capture(fixture.scope).known.securityEpoch, "42");
  assert.throws(
    () =>
      cache.materialize(reused(), fixture.scope, cache.capture(fixture.scope)),
    /Unconfirmed/,
  );
});
test("Product cache never installs a malformed decoded candidate", async () => {
  const cache = new ViewCache();
  seed(cache);
  const wire = structuredClone(fixture);
  wire.context.models = {};
  wire.blockVersions.context = "101";
  const source = Buffer.from(JSON.stringify(wire));
  await assert.rejects(
    fetchWorkbenchSnapshot(
      async (command) =>
        command === "metawork.workbench.snapshot"
          ? {
              snapshotId: "13",
              bytes: source.length,
              chunkBytes: source.length,
            }
          : {
              snapshotId: "13",
              offset: 0,
              bytes: source.length,
              data: source.toString("base64"),
            },
      fixture.scope,
      cache,
    ),
  );
  assert.equal(
    cache.capture(fixture.scope).known.versions.context,
    fixture.blockVersions.context,
  );
});
