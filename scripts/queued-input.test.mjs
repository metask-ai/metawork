import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createServer } from "vite";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
});
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  Node: dom.window.Node,
});
const { act, renderHook, cleanup } = await import("@testing-library/react");
const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { useQueuedInput } = await vite.ssrLoadModule(
  "/src/features/composer/useQueuedInput.ts",
);
const drafts = await vite.ssrLoadModule("/src/features/composer/drafts.ts");
const journal = await vite.ssrLoadModule(
  "/src/features/composer/queued-input.ts",
);
const fixture = JSON.parse(
  readFileSync(
    new URL(
      "../frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
      import.meta.url,
    ),
    "utf8",
  ),
);
const taskId = "3";
const input = { kind: "text", text: "follow up", redacted: false };
const queued = {
  revision: "1",
  runId: "7",
  input,
  state: "waiting",
  heldReason: null,
  queuedAtUnixMs: null,
};
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => {
    resolve = ok;
    reject = fail;
  });
  return { promise, resolve, reject };
}
function receipt(id, kind = "queue", outcome = "queued") {
  return {
    operationId: id,
    kind,
    outcome,
    revision: "1",
    reason: null,
    input: outcome === "withdrawn" ? input : null,
  };
}
function snapshot(change = {}) {
  const next = structuredClone(fixture);
  Object.assign(next.tasks[0], change);
  return next;
}
function harness({
  initial = snapshot(),
  queue = deferred(),
  withdraw = deferred(),
} = {}) {
  const calls = [];
  let refreshes = 0;
  const generationRef = { current: "1" };
  const client = {
    queueInput(...args) {
      calls.push({ kind: "queue", args });
      return queue.promise;
    },
    withdrawQueuedInput(...args) {
      calls.push({ kind: "withdraw", args });
      return withdraw.promise;
    },
  };
  const draftApi = {
    getDraft: drafts.readTaskDraft,
    setDraft: drafts.writeTaskDraft,
    clearDraft: drafts.clearTaskDraft,
  };
  const view = renderHook(
    (props) =>
      useQueuedInput({
        client,
        generationRef,
        drafts: draftApi,
        refresh: async () => {
          refreshes++;
        },
        ...props,
      }),
    { initialProps: { snapshot: initial, ready: true, generation: "1" } },
  );
  return {
    ...view,
    calls,
    queue,
    withdraw,
    generationRef,
    refreshes: () => refreshes,
    observe(next, generation = "1") {
      generationRef.current = generation;
      view.rerender({ snapshot: next, ready: true, generation });
    },
  };
}
function startQueue(h) {
  let completion;
  act(() => {
    completion = h.result.current.submit(hookTask(h));
  });
  return completion;
}
function hookTask() {
  return snapshot().tasks[0];
}
test.beforeEach(() => {
  cleanup();
  dom.window.sessionStorage.clear();
  drafts.pruneTaskDrafts(new Set());
  drafts.writeTaskDraft(taskId, { kind: "text", text: "follow up" });
});
test.afterEach(() => cleanup());
test.after(async () => {
  await vite.close();
  dom.window.close();
});

test("timeout refreshes but empty slot is not failure; matching consumed receipt clears exactly the original draft", async () => {
  const h = harness();
  const completion = startQueue(h);
  const operationId = h.calls[0].args[0];
  assert.equal(h.result.current.isBusy(taskId), true);
  await act(async () => {
    h.queue.reject(new Error("response lost"));
    await completion;
  });
  assert.equal(h.refreshes(), 1);
  assert.equal(h.calls.length, 1);
  assert.equal(h.result.current.isBusy(taskId), false);
  assert.equal(h.result.current.blocked(taskId), true);
  h.observe(snapshot());
  h.observe(
    snapshot({ queuedInputResult: receipt("another-window-operation") }),
  );
  assert.equal(drafts.readTaskDraft(taskId).text, "follow up");
  assert.equal(h.result.current.blocked(taskId), true);
  h.observe(
    snapshot({ queuedInput: null, queuedInputResult: receipt(operationId) }),
  );
  assert.equal(drafts.readTaskDraft(taskId).text, "");
  assert.equal(h.result.current.quietDraft(taskId), true);
  drafts.writeTaskDraft(taskId, { kind: "text", text: "new draft" });
  h.observe(snapshot({ queuedInputResult: receipt(operationId) }));
  assert.equal(drafts.readTaskDraft(taskId).text, "new draft");
  assert.equal(h.calls.length, 1);
});

test("newer draft and a replacement connection survive a late response", async () => {
  const h = harness();
  const completion = startQueue(h);
  const operationId = h.calls[0].args[0];
  drafts.writeTaskDraft(taskId, { kind: "text", text: "newer draft" });
  h.observe(snapshot(), "2");
  assert.equal(h.result.current.isBusy(taskId), false);
  await act(async () => {
    h.queue.resolve({
      operationId,
      taskId,
      accepted: true,
      revision: "1",
      reason: null,
    });
    await completion;
  });
  assert.equal(drafts.readTaskDraft(taskId).text, "newer draft");
  assert.equal(h.result.current.blocked(taskId), true);
  h.observe(
    snapshot({ queuedInput: queued, queuedInputResult: receipt(operationId) }),
    "2",
  );
  assert.equal(h.result.current.blocked(taskId), false);
  assert.equal(drafts.readTaskDraft(taskId).text, "newer draft");
});

test("document reload loads an operation only for reconciliation and ignores the old document response", async () => {
  const old = harness();
  const completion = startQueue(old);
  const operationId = old.calls[0].args[0];
  old.unmount();
  const next = harness();
  assert.equal(next.calls.length, 0);
  assert.equal(next.result.current.blocked(taskId), true);
  await act(async () => {
    old.queue.resolve({
      operationId,
      taskId,
      accepted: true,
      revision: "1",
      reason: null,
    });
    await completion;
  });
  assert.equal(drafts.readTaskDraft(taskId).text, "follow up");
  assert.ok(journal.readQueuedOperation(taskId));
  next.observe(snapshot({ queuedInputResult: receipt(operationId) }));
  assert.equal(drafts.readTaskDraft(taskId).text, "");
  assert.equal(next.calls.length, 0);
});

test("edit withdrawal retains returned input when typing wins the race, then restores only on explicit choice", async () => {
  drafts.clearTaskDraft(taskId);
  const h = harness({ initial: snapshot({ queuedInput: queued }) });
  let completion;
  act(() => {
    completion = h.result.current.withdraw(
      snapshot({ queuedInput: queued }).tasks[0],
      "edit",
    );
  });
  const operationId = h.calls[0].args[0];
  drafts.writeTaskDraft(taskId, {
    kind: "text",
    text: "typed while withdrawing",
  });
  await act(async () => {
    h.withdraw.resolve({
      operationId,
      taskId,
      withdrawn: true,
      revision: "1",
      reason: null,
      input,
    });
    await completion;
  });
  assert.equal(drafts.readTaskDraft(taskId).text, "typed while withdrawing");
  assert.equal(h.result.current.operation(taskId).phase, "draft_conflict");
  assert.equal(h.result.current.operation(taskId).draft.text, "follow up");
  assert.equal(h.result.current.isBusy(taskId), false);
  drafts.clearTaskDraft(taskId);
  act(() => h.result.current.recover(taskId, true));
  assert.equal(drafts.readTaskDraft(taskId).text, "follow up");
  assert.equal(h.result.current.blocked(taskId), false);
  assert.equal(h.calls.length, 1);
});

test("discard withdrawal and rejection never repopulate a draft", async () => {
  const h = harness({ initial: snapshot({ queuedInput: queued }) });
  let completion;
  act(() => {
    completion = h.result.current.withdraw(
      snapshot({ queuedInput: queued }).tasks[0],
      "discard",
    );
  });
  const operationId = h.calls[0].args[0];
  drafts.writeTaskDraft(taskId, { kind: "text", text: "keep this" });
  await act(async () => {
    h.withdraw.resolve({
      operationId,
      taskId,
      withdrawn: true,
      revision: "1",
      reason: null,
      input,
    });
    await completion;
  });
  assert.equal(drafts.readTaskDraft(taskId).text, "keep this");
  const q = harness();
  const sent = startQueue(q);
  const id = q.calls[0].args[0];
  await act(async () => {
    q.queue.resolve({
      operationId: id,
      taskId,
      accepted: false,
      revision: null,
      reason: "task_idle",
    });
    await sent;
  });
  assert.equal(q.result.current.error(taskId), "task_idle");
  assert.equal(drafts.readTaskDraft(taskId).text, "keep this");
});

test("queue refuses to invoke Host if its local correlation record cannot be saved", async () => {
  const h = harness();
  const original = Object.getOwnPropertyDescriptor(
    dom.window,
    "sessionStorage",
  );
  Object.defineProperty(dom.window, "sessionStorage", {
    configurable: true,
    get: () => ({
      getItem: () => null,
      setItem: () => {
        throw new Error("quota");
      },
    }),
  });
  try {
    await act(async () => {
      await h.result.current.submit(hookTask());
    });
  } finally {
    Object.defineProperty(dom.window, "sessionStorage", original);
  }
  assert.equal(h.calls.length, 0);
  assert.equal(h.result.current.isBusy(taskId), false);
});

test("Skill edit preserves captured revisions and arguments without silently reselecting a new catalog", () => {
  const skill = {
    kind: "skill",
    skillId: "review",
    catalogRevision: "old",
    selectionRevision: "1",
    invocationName: "review",
    displayName: "Review",
    argumentValues: ["src/main.zig"],
    redacted: false,
  };
  const draft = journal.queuedInputDraft(skill, {
    availability: "ready",
    revision: "new",
    selectionRevision: "2",
    skills: [],
    issues: [],
    redacted: false,
  });
  assert.equal(draft.catalogRevision, "old");
  assert.equal(draft.selectionRevision, "1");
  assert.deepEqual(draft.argumentValues, ["src/main.zig"]);
});

test("same Task cannot admit concurrent queue commands even before React rerenders", async () => {
  const h = harness();
  let first, second;
  act(() => {
    first = h.result.current.submit(hookTask());
    second = h.result.current.submit(hookTask());
  });
  assert.equal(h.calls.length, 1);
  await act(async () => {
    h.queue.reject(new Error("lost"));
    await Promise.all([first, second]);
  });
  assert.equal(h.calls.length, 1);
});
