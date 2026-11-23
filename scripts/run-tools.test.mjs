import assert from "node:assert/strict";
import test from "node:test";

import { decodeRunToolsPage } from "../frontend/src/bridge/decode-contracts.ts";
import {
  idleRunTools,
  mergeRunToolsPage,
  runToolsRefreshCursor,
} from "../frontend/src/features/tasks/run-tools.ts";

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

test("Tool pages extend what was read and refresh only what can still change", () => {
  let state = mergeRunToolsPage(
    idleRunTools,
    "0",
    page([tool(1), tool(2, "running")], { nextAfterOrder: "2" }),
  );
  assert.deepEqual(
    state.tools.map((entry) => entry.order),
    ["1", "2"],
  );
  // A running record is read again from just before it.
  assert.equal(runToolsRefreshCursor(state), "1");
  state = mergeRunToolsPage(
    state,
    "1",
    page([tool(2), tool(3)], { revision: "5" }),
  );
  assert.deepEqual(
    state.tools.map((entry) => [entry.order, entry.state]),
    [
      ["1", "completed"],
      ["2", "completed"],
      ["3", "completed"],
    ],
  );
  assert.equal(state.nextAfterOrder, null);
  assert.equal(state.revision, "5");
  // Read to the end: only records after the last can appear.
  assert.equal(runToolsRefreshCursor(state), "3");
  // Not read to the end and nothing running: later pages bring the rest.
  assert.equal(runToolsRefreshCursor({ ...state, nextAfterOrder: "3" }), null);
  assert.deepEqual(
    mergeRunToolsPage(state, "0", page([], { state: "missing", total: "0" }))
      .tools,
    [],
  );
});
