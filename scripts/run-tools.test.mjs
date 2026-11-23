import assert from "node:assert/strict";
import test from "node:test";

import { JSDOM } from "jsdom";

import { decodeRunToolsPage } from "../frontend/src/bridge/decode-contracts.ts";
import {
  RunToolsCache,
  runToolsKey,
  runToolsRefreshCursor,
  useRunTools,
} from "../frontend/src/features/tasks/run-tools.ts";

const dom = new JSDOM("<!doctype html><html><body></body></html>", {
  url: "http://localhost/",
});
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  HTMLElement: dom.window.HTMLElement,
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator,
});
const { act, cleanup, renderHook, waitFor } =
  await import("./renderer-testing-library.mjs");
test.afterEach(() => cleanup());

function tool(order, state = "completed", overrides = {}) {
  return {
    bash: null,
    presentation: null,
    errorDetail: null,
    id: `tool-${order}`,
    order: String(order),
    name: "Read",
    input: "",
    progress: "",
    content: "",
    state,
    isError: false,
    elapsedMs: "1",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
    fileRefs: [],
    ...overrides,
  };
}

function page(tools, overrides = {}) {
  return {
    generation: "1",
    requestId: "1",
    state: "ready",
    securityEpoch: "1",
    revision: "4",
    total: "3",
    tools,
    nextAfterOrder: null,
    ...overrides,
  };
}

test("Tool pages decode strictly in activity order after their cursor", () => {
  const decoded = decodeRunToolsPage(
    page([tool(2), tool(3, "completed", { transportTruncated: true })], {
      nextAfterOrder: "3",
    }),
    "1",
  );
  assert.equal(decoded.tools[1].transportTruncated, true);
  assert.equal(decoded.nextAfterOrder, "3");
  for (const invalid of [
    page([tool(1)]),
    page([tool(3), tool(2)]),
    page([tool(2), { ...tool(3), id: "tool-2" }]),
    page([tool(2)], { nextAfterOrder: "5" }),
    page([tool(2)], { state: "missing" }),
    page([tool(2, "completed", { transportTruncated: false })]),
    page([tool(2)], { extra: true }),
  ])
    assert.throws(() => decodeRunToolsPage(invalid, "1"));
  assert.deepEqual(
    decodeRunToolsPage(page([], { state: "missing", total: "0" }), "0").tools,
    [],
  );
});

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((settle, fail) => {
    resolve = settle;
    reject = fail;
  });
  return { promise, resolve, reject };
}

async function settled(cache, key) {
  for (let turn = 0; turn < 100 && cache.get(key).status === "loading"; turn++)
    await new Promise((resolve) => setImmediate(resolve));
}

function readRequest(loader, overrides = {}) {
  return {
    loader,
    taskId: "1",
    runId: "1",
    securityEpoch: "1",
    cursor: "0",
    through: null,
    revision: "4",
    active: true,
    ...overrides,
  };
}

test("a read extends what was read and refreshes only what can still change", async () => {
  const cache = new RunToolsCache();
  const key = runToolsKey("1", "1", "1");
  const answers = [
    page([tool(1), tool(2, "running")], { nextAfterOrder: "2" }),
    page([tool(2), tool(3)], { revision: "5" }),
    page([], { state: "missing", total: "0" }),
  ];
  const calls = [];
  const loader = async (...args) => {
    calls.push(args);
    return answers.shift();
  };
  cache.read(key, readRequest(loader));
  assert.equal(cache.get(key).status, "loading");
  await settled(cache, key);
  let state = cache.get(key);
  assert.deepEqual(
    state.tools.map((entry) => entry.order),
    ["1", "2"],
  );
  // The pages answer the task page revision they were read for.
  assert.equal(state.revision, "4");
  assert.equal(state.readWhileActive, true);
  // A running record is read again from just before it.
  assert.equal(runToolsRefreshCursor(state), "1");
  cache.read(
    key,
    readRequest(loader, { cursor: "1", through: "2", revision: "6" }),
  );
  await settled(cache, key);
  state = cache.get(key);
  assert.deepEqual(
    state.tools.map((entry) => [entry.order, entry.state]),
    [
      ["1", "completed"],
      ["2", "completed"],
      ["3", "completed"],
    ],
  );
  assert.equal(state.nextAfterOrder, null);
  assert.equal(state.revision, "6");
  // Read to the end: only records after the last can appear.
  assert.equal(runToolsRefreshCursor(state), "3");
  // Not read to the end and nothing running: later pages bring the rest.
  assert.equal(runToolsRefreshCursor({ ...state, nextAfterOrder: "3" }), null);
  cache.read(key, readRequest(loader));
  await settled(cache, key);
  assert.deepEqual(cache.get(key).tools, []);
  assert.deepEqual(
    calls.map((args) => args[2]),
    ["0", "1", "0"],
  );
});

test("a read follows pages through the extent it replaces", async () => {
  const cache = new RunToolsCache();
  const key = runToolsKey("1", "1", "1");
  const cursors = [];
  const loader = async (_task, _run, after) => {
    cursors.push(after);
    const order = Number(after) + 1;
    return page([tool(order)], {
      nextAfterOrder: order < 5 ? String(order) : null,
    });
  };
  cache.read(key, readRequest(loader, { through: "3", active: false }));
  await settled(cache, key);
  assert.deepEqual(cursors, ["0", "1", "2"]);
  assert.deepEqual(
    cache.get(key).tools.map((entry) => entry.order),
    ["1", "2", "3"],
  );
  assert.equal(cache.get(key).nextAfterOrder, "3");
  assert.equal(cache.get(key).readWhileActive, false);
});

test("a Task or epoch the view no longer shows drops its pages and reads", async () => {
  const cache = new RunToolsCache();
  const first = runToolsKey("1", "1", "1");
  const other = runToolsKey("12", "1", "1");
  const answer = deferred();
  cache.read(
    first,
    readRequest(async () => answer.promise),
  );
  cache.read(
    other,
    readRequest(async () => page([tool(1)]), { taskId: "12" }),
  );
  await settled(cache, other);
  cache.retain("12", "1");
  assert.equal(cache.get(first).status, "idle");
  answer.resolve(page([tool(1)]));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(cache.get(first).status, "idle");
  assert.equal(cache.get(other).tools.length, 1);
  cache.retain("12", "2");
  assert.equal(cache.get(other).status, "idle");
});

function hookProps(overrides = {}) {
  return {
    loader: async () => page([tool(1), tool(2)]),
    taskId: "1",
    runId: "1",
    securityEpoch: "1",
    toolLog: { count: "2", revision: "4", runningName: null },
    expanded: true,
    active: true,
    cache: undefined,
    ...overrides,
  };
}

function renderRunTools(props) {
  return renderHook(
    (current) =>
      useRunTools(
        current.loader,
        current.taskId,
        current.runId,
        current.securityEpoch,
        current.toolLog,
        current.expanded,
        current.active,
        current.cache,
      ),
    { initialProps: props },
  );
}

async function turns(count = 5) {
  for (let turn = 0; turn < count; turn++)
    await act(() => new Promise((resolve) => setImmediate(resolve)));
}

test("a page newer than the snapshot asks again only when the snapshot moves", async () => {
  let calls = 0;
  const loader = async () => {
    calls += 1;
    return page([tool(1), tool(2)], { revision: "9" });
  };
  const props = hookProps({ loader });
  const { result, rerender } = renderRunTools(props);
  await waitFor(() => assert.equal(result.current.status, "ready"));
  await turns();
  assert.equal(calls, 1);
  rerender({ ...props, toolLog: { ...props.toolLog } });
  await turns();
  assert.equal(calls, 1);
  rerender({ ...props, toolLog: { ...props.toolLog, revision: "5" } });
  await waitFor(() => assert.equal(calls, 2));
  await turns();
  assert.equal(calls, 2);
});

test("a read in flight when the Run ends reaches the details that mount next", async () => {
  const cache = new RunToolsCache();
  const answers = [deferred(), deferred()];
  let calls = 0;
  const loader = () => answers[calls++].promise;
  const running = renderRunTools(hookProps({ loader, cache }));
  await waitFor(() => assert.equal(calls, 1));
  assert.equal(running.result.current.status, "loading");
  running.unmount();
  const ended = renderRunTools(hookProps({ loader, cache, active: false }));
  answers[0].resolve(page([tool(1), tool(2, "running")]));
  // What was read while the Run ran is read once more after it ends.
  await waitFor(() => assert.equal(calls, 2));
  answers[1].resolve(page([tool(1), tool(2)]));
  await waitFor(() => assert.equal(ended.result.current.status, "ready"));
  assert.deepEqual(
    ended.result.current.tools.map((entry) => entry.state),
    ["completed", "completed"],
  );
  await turns();
  assert.equal(calls, 2);
});

test("Runs with the same id in two Tasks keep their own records", async () => {
  const cache = new RunToolsCache();
  const asked = [];
  const loader = async (taskId, runId, after) => {
    asked.push([taskId, runId, after]);
    return page([tool(1, "completed", { name: `Task ${taskId}` })]);
  };
  const props = hookProps({ loader, cache });
  const { result, rerender } = renderRunTools(props);
  await waitFor(() => assert.equal(result.current.status, "ready"));
  assert.equal(result.current.tools[0].name, "Task 1");
  rerender({ ...props, taskId: "2" });
  assert.deepEqual(result.current.tools, []);
  await waitFor(() => assert.equal(result.current.status, "ready"));
  assert.equal(result.current.tools[0].name, "Task 2");
  assert.deepEqual(asked, [
    ["1", "1", "0"],
    ["2", "1", "0"],
  ]);
});

test("details show more records on request and retry a failed read", async () => {
  let failures = 1;
  const cursors = [];
  const loader = async (_task, _run, after) => {
    cursors.push(after);
    if (after === "1" && failures-- > 0) throw new Error("offline");
    return after === "0"
      ? page([tool(1)], { nextAfterOrder: "1" })
      : page([tool(2), tool(3)]);
  };
  const { result } = renderRunTools(
    hookProps({
      loader,
      toolLog: { count: "3", revision: "4", runningName: null },
    }),
  );
  await waitFor(() => assert.equal(result.current.status, "ready"));
  assert.equal(result.current.hasMore, true);
  assert.equal(result.current.remaining, 2n);
  await act(async () => result.current.loadMore());
  await waitFor(() => assert.equal(result.current.status, "error"));
  // The records read so far stay while the failed page can be retried.
  assert.equal(result.current.tools.length, 1);
  await act(async () => result.current.retry());
  await waitFor(() => assert.equal(result.current.status, "ready"));
  assert.deepEqual(
    result.current.tools.map((entry) => entry.order),
    ["1", "2", "3"],
  );
  assert.equal(result.current.hasMore, false);
  assert.deepEqual(cursors, ["0", "1", "1"]);
});

test("a page from another security epoch is not shown", async () => {
  const loader = async () => page([tool(1)], { securityEpoch: "2" });
  const { result } = renderRunTools(hookProps({ loader }));
  await waitFor(() => assert.equal(result.current.status, "error"));
  assert.deepEqual(result.current.tools, []);
});
