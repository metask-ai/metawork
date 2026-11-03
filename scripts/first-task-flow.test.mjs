import assert from "node:assert/strict";
import test from "node:test";

import { TaskSubmissionSession } from "../frontend/src/features/composer/submitTaskInstruction.ts";
import { chooseWorkspaceAndMigrateDraft } from "../frontend/src/features/workspaces/chooseWorkspace.ts";

test("a failed authoritative refresh cannot move or lose the source draft", async () => {
  const calls = [];
  const failure = new Error("snapshot unavailable");
  const result = await chooseWorkspaceAndMigrateDraft({
    choose: async () => {
      calls.push("choose");
      return { selected: true, workspaceId: "7" };
    },
    refresh: async () => {
      calls.push("refresh");
      throw failure;
    },
    migratableDraftId: "unscoped",
    current: () => true,
    moveDraft() {
      calls.push("move");
      return "moved";
    },
  });
  assert.deepEqual(result, { kind: "sync_failed" });
  assert.deepEqual(calls, ["choose", "refresh"]);
});

test("choosing a Workspace without a migratable draft only changes draft context", async () => {
  const calls = [];
  const result = await chooseWorkspaceAndMigrateDraft({
    choose: async () => {
      calls.push("choose");
      return { selected: true, workspaceId: "7" };
    },
    refresh: async () => calls.push("refresh"),
    migratableDraftId: null,
    current: () => true,
    moveDraft() {
      calls.push("move");
    },
  });
  assert.deepEqual(result, {
    kind: "selected",
    result: { selected: true, workspaceId: "7" },
  });
  assert.deepEqual(calls, ["choose", "refresh"]);
});

test("a late Workspace picker or read never migrates a different draft", async () => {
  for (const stage of ["picker", "read"]) {
    let current = true,
      moves = 0,
      reads = 0;
    const result = await chooseWorkspaceAndMigrateDraft({
      choose: async () => {
        if (stage === "picker") current = false;
        return { selected: true, workspaceId: "7" };
      },
      refresh: async () => {
        reads++;
        current = false;
      },
      current: () => current,
      migratableDraftId: "unscoped",
      moveDraft: () => moves++,
    });
    assert.deepEqual(result, { kind: "superseded" });
    assert.equal(moves, 0);
    assert.equal(reads, stage === "read" ? 1 : 0);
  }
});

const deferred = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => {
    resolve = a;
    reject = b;
  });
  return { promise, resolve, reject };
};
const text = (value) => ({ kind: "text", text: value });
function sessionFixture(taskId = null) {
  const creation = deferred(),
    receipts = new Map(),
    calls = [];
  let current = true,
    creates = 0;
  const session = new TaskSubmissionSession({
    taskId,
    create: () => {
      creates++;
      return creation.promise;
    },
    send: (operationId, taskId, input) => {
      calls.push([operationId, taskId, input]);
      const reply = deferred();
      receipts.set(operationId, reply);
      return reply.promise;
    },
    stop: async (id) => {
      calls.push(["stop", id]);
    },
    current: () => current,
    onCreated: (id) => calls.push(["created", id]),
  });
  return {
    session,
    creation,
    receipts,
    calls,
    creates: () => creates,
    replace: () => {
      current = false;
    },
  };
}
const created = {
  accepted: true,
  taskId: "9",
  bindingEpoch: "2",
  reason: null,
};
const accept = (id) => ({
  taskId: "9",
  operationId: id,
  outcome: "accepted",
  reason: null,
});
test("creation is shared and A B C are delivered before any receipt", async () => {
  const f = sessionFixture();
  const results = ["A", "B", "C"].map((id) =>
    f.session.submit(id, text(id), () => {}),
  );
  assert.equal(f.creates(), 1);
  assert.equal(f.session.canReleaseAfterCreationRejection, false);
  assert.deepEqual(f.calls, []);
  f.creation.resolve(created);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(
    f.calls.map((call) => call[0]),
    ["created", "A", "B", "C"],
  );
  for (const id of ["C", "A", "B"]) f.receipts.get(id).resolve(accept(id));
  assert.deepEqual(
    (await Promise.all(results)).map((result) => result.kind),
    ["accepted", "accepted", "accepted"],
  );
});
test("existing Task sends synchronously without waiting for any previous reply", async () => {
  const f = sessionFixture("9");
  const a = f.session.submit("A", text("A"), () => {});
  const b = f.session.submit("B", text("B"), () => {});
  assert.deepEqual(
    f.calls.map((call) => call[0]),
    ["A", "B"],
  );
  assert.equal(f.creates(), 0);
  f.receipts.get("B").resolve(accept("B"));
  f.receipts.get("A").resolve(accept("A"));
  await Promise.all([a, b]);
});
test("stop during creation cancels only earlier messages and precedes later sends", async () => {
  const f = sessionFixture();
  const a = f.session.submit("A", text("A"), () => {});
  const stopping = f.session.stop();
  const b = f.session.submit("B", text("B"), () => {});
  f.creation.resolve(created);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(
    f.calls.map((call) => call[0]),
    ["created", "stop", "B"],
  );
  assert.equal((await a).kind, "cancelled");
  f.receipts.get("B").resolve(accept("B"));
  const [stopped] = await Promise.all([stopping, b]);
  assert.equal(stopped.localOnly, true);
});
test("definite rejection allows a new explicit creation while unknown creation never replays", async () => {
  for (const refused of [true, false]) {
    const f = sessionFixture();
    const a = f.session.submit("A", text("A"), () => {});
    if (refused)
      f.creation.resolve({ accepted: false, reason: "catalog_unavailable" });
    else f.creation.reject(new Error("lost"));
    assert.equal((await a).kind, refused ? "create_rejected" : "unknown");
    assert.equal(f.session.canReleaseAfterCreationRejection, refused);
    const b = await f.session.submit("B", text("B"), () => {});
    assert.equal(b.kind, refused ? "create_rejected" : "unknown");
    assert.equal(f.creates(), refused ? 2 : 1);
    assert.deepEqual(f.calls, []);
  }
});
test("connection replacement prevents delivery after late creation", async () => {
  const f = sessionFixture();
  const a = f.session.submit("A", text("A"), () => {});
  f.replace();
  f.creation.resolve(created);
  assert.equal((await a).kind, "unknown");
  assert.deepEqual(f.calls, []);
});
test("lost A receipt does not block B and is never automatically resent", async () => {
  const f = sessionFixture("9");
  const a = f.session.submit("A", text("A"), () => {});
  const b = f.session.submit("B", text("B"), () => {});
  f.receipts.get("A").reject(new Error("lost"));
  f.receipts.get("B").resolve(accept("B"));
  assert.equal((await a).kind, "unknown");
  assert.equal((await b).kind, "accepted");
  assert.equal(f.calls.length, 2);
});
test("creation buffer is bounded and reserves no additional create request", async () => {
  const f = sessionFixture();
  const results = Array.from({ length: 64 }, (_, i) =>
    f.session.submit(String(i), text(String(i)), () => {}),
  );
  assert.deepEqual(
    await f.session.submit("overflow", text("overflow"), () => {}),
    { kind: "create_rejected", reason: "capacity_reached" },
  );
  assert.equal(f.session.canReleaseAfterCreationRejection, false);
  const stop = f.session.stop();
  f.creation.resolve(created);
  await stop;
  assert.ok(
    (await Promise.all(results)).every((result) => result.kind === "cancelled"),
  );
  assert.equal(f.creates(), 1);
});

test("stop immediately settles the local cancellation before delayed creation replies", async () => {
  const f = sessionFixture();
  let cancelled = 0;
  const a = f.session.submit(
    "A",
    text("A"),
    () => {},
    () => cancelled++,
  );
  const targets = [];
  const stopping = f.session.stop((id) => targets.push(id));
  assert.equal(cancelled, 1);
  assert.equal(f.session.canReleaseAfterCreationRejection, false);
  assert.deepEqual(f.calls, []);
  assert.deepEqual(targets, []);
  f.creation.resolve(created);
  await stopping;
  assert.equal((await a).kind, "cancelled");
  assert.equal(cancelled, 1);
  assert.deepEqual(targets, ["9"]);
  assert.equal(f.session.canReleaseAfterCreationRejection, false);
});

test("a shared creation rejection releases only after waiting messages settle", async () => {
  const f = sessionFixture();
  const pending = ["A", "B", "C"].map((id) =>
    f.session.submit(id, text(id), () => {}),
  );
  assert.equal(f.session.canReleaseAfterCreationRejection, false);
  // The creation continuation clears its Promise before these submits resume.
  const beforeMessagesSettle = f.creation.promise.then(() => {
    assert.equal(f.session.canReleaseAfterCreationRejection, false);
  });
  f.creation.resolve({ accepted: false, reason: "execution_unavailable" });
  await beforeMessagesSettle;
  assert.ok(
    (await Promise.all(pending)).every(
      (result) => result.kind === "create_rejected",
    ),
  );
  assert.equal(f.session.canReleaseAfterCreationRejection, true);
  assert.equal(f.creates(), 1);
  assert.deepEqual(f.calls, []);
});

test("stopping a creation does not release identity until its definite rejection", async () => {
  const f = sessionFixture();
  const pending = f.session.submit("A", text("A"), () => {});
  const stopping = f.session.stop();
  assert.equal(f.session.canReleaseAfterCreationRejection, false);
  f.creation.resolve({ accepted: false, reason: "execution_unavailable" });
  await stopping;
  assert.equal((await pending).kind, "create_rejected");
  assert.equal(f.session.canReleaseAfterCreationRejection, true);
});

test("a rejected send retains its successfully created Task identity", async () => {
  const f = sessionFixture();
  const pending = f.session.submit("A", text("A"), () => {});
  f.creation.resolve(created);
  await new Promise((resolve) => setImmediate(resolve));
  f.receipts
    .get("A")
    .resolve({ outcome: "rejected", reason: "capacity_reached" });
  assert.equal((await pending).kind, "rejected");
  assert.equal(f.session.canReleaseAfterCreationRejection, false);
  assert.equal(f.creates(), 1);
});
