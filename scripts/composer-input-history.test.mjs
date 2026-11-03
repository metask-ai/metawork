import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { createServer } from "vite";
import { productStateFixture } from "./test-support/product-view-fixture.mjs";

const vite = await createServer({
  root: join(process.cwd(), "frontend"),
  appType: "custom",
  logLevel: "silent",
  server: { middlewareMode: true },
});
const { loadTaskInputHistory } = await vite.ssrLoadModule(
  "/src/features/composer/input-history.ts",
);
test.after(() => vite.close());
const base = JSON.parse(
  readFileSync(
    "frontend/src/bridge/__fixtures__/workbench-snapshot.fixture",
    "utf8",
  ),
);
const scope = {
  taskId: "3",
  beforeRunId: null,
  runLimit: 4,
  management: "none",
  search: false,
  searchQuery: "",
  searchCursor: null,
  receipts: [],
};
const submission = (id, order = id) => ({
  operationId: `operation-${id}`,
  presentationOrder: String(order),
  receivedAtUnixMs: "1",
  anchorRunId: null,
  afterOutputCount: 0,
});
function run(id, value = `input-${id}`) {
  return {
    ...structuredClone(base.tasks[0].runs[0]),
    id: String(id),
    contentVersion: "1",
    input: { kind: "text", text: value, redacted: false },
    submission: submission(id),
    additionalInputs: [],
  };
}
function fixture(count = 9) {
  const state = structuredClone(base);
  state.tasks[0].runs = Array.from({ length: count }, (_, index) =>
    run(index + 1),
  );
  state.tasks[0].inputSubmissions = [];
  return state;
}

test("input history pages older Runs without changing the reader or including new submissions", async () => {
  const state = fixture();
  const initial = productStateFixture(state, scope);
  const requests = [];
  const history = await loadTaskInputHistory(
    initial,
    "3",
    async (requested) => {
      requests.push(requested);
      state.tasks[0].runs.push(run(10 + requests.length, "too new"));
      state.tasks[0].inputSubmissions.push({
        submission: submission(30),
        input: { kind: "text", text: "new queued", redacted: false },
        state: "waiting",
        reason: null,
      });
      return productStateFixture(state, requested);
    },
    () => true,
  );
  assert.deepEqual(
    history,
    Array.from({ length: 9 }, (_, i) => `input-${i + 1}`),
  );
  assert.deepEqual(
    requests.map((request) => request.beforeRunId),
    ["6", "2"],
  );
  assert.ok(
    requests.every(
      (request) =>
        request.taskId === "3" &&
        request.runLimit === 4 &&
        request.management === "none" &&
        !request.search,
    ),
  );
  assert.equal(initial.scope.beforeRunId, null);
  assert.deepEqual(
    initial.tasks[0].runs.map((item) => item.id),
    ["6", "7", "8", "9"],
  );
});

test("input history excludes real continuation roots and collapses consecutive exact duplicates", async () => {
  const state = fixture(4);
  const task = state.tasks[0];
  task.runs[0] = run(1, "A");
  task.runs[0].additionalInputs = [
    {
      id: "2",
      operationId: "operation-2",
      text: "X",
      redacted: false,
      submission: submission(2),
      state: "transferred",
      transferredToRunId: "2",
    },
    {
      id: "3",
      operationId: "operation-3",
      text: "Y",
      redacted: false,
      submission: submission(3),
      state: "transferred",
      transferredToRunId: "2",
    },
  ];
  task.runs[1] = run(2, "X\n\nY");
  task.runs[1].submission = null;
  task.runs[2] = { ...run(3, "Y"), submission: submission(4) };
  task.runs[3] = { ...run(4, " Y "), submission: submission(5) };
  task.inputSubmissions = [
    {
      submission: submission(6),
      input: { kind: "text", text: "queued", redacted: false },
      state: "waiting",
      reason: null,
    },
  ];
  const history = await loadTaskInputHistory(
    productStateFixture(state, scope),
    "3",
    () => assert.fail("already loaded"),
    () => true,
  );
  assert.deepEqual(history, ["A", "X", "Y", " Y ", "queued"]);
});

test("input history suppresses a continuation root even when its source arrives on an older page", async () => {
  const state = fixture(6);
  const task = state.tasks[0];
  task.runs[0] = run(1, "A");
  task.runs[0].additionalInputs = [
    {
      id: "101",
      operationId: "operation-101",
      text: "X",
      redacted: false,
      submission: submission(101, 2),
      state: "transferred",
      transferredToRunId: "5",
    },
    {
      id: "102",
      operationId: "operation-102",
      text: "Y",
      redacted: false,
      submission: submission(102, 3),
      state: "transferred",
      transferredToRunId: "5",
    },
  ];
  for (const [index, value] of [
    [1, "B"],
    [2, "C"],
    [3, "D"],
    [5, "Z"],
  ])
    task.runs[index] = {
      ...run(index + 1, value),
      submission: submission(index + 1, index + 3),
    };
  task.runs[4] = { ...run(5, "X\n\nY"), submission: null };
  const history = await loadTaskInputHistory(
    productStateFixture(state, scope),
    "3",
    async (requested) => productStateFixture(state, requested),
    () => true,
  );
  assert.deepEqual(history, ["A", "X", "Y", "B", "C", "D", "Z"]);
});

test("input history excludes attachments, Skills, whitespace, redacted text and other Tasks", async () => {
  const state = fixture(7);
  const task = state.tasks[0];
  task.runs[0].input = {
    kind: "multimodal",
    text: "attachment text",
    redacted: false,
    attachments: [],
  };
  task.runs[1].input = {
    kind: "skill",
    displayName: "Skill",
    argumentValues: ["argument"],
    redacted: false,
  };
  task.runs[2].input = { kind: "text", text: "masked", redacted: true };
  task.runs[3].input.text = " \n";
  task.runs[4].input.text = "";
  // Even a second unredacted representation may not revive a withheld submission.
  task.runs[5].submission = submission(3);
  task.runs[5].input.text = "unsafe duplicate";
  task.runs[6].input.text = "safe";
  state.tasks.push({
    ...structuredClone(task),
    id: "99",
    runs: [run(99, "another task")],
  });
  const history = await loadTaskInputHistory(
    productStateFixture(state, scope),
    "3",
    async (requested) => productStateFixture(state, requested),
    () => true,
  );
  assert.deepEqual(history, ["safe"]);
});

test("input history includes accepted running interjections and waiting messages in submission order", async () => {
  const state = fixture(1);
  state.tasks[0].runs[0].additionalInputs = [
    {
      operationId: "operation-3",
      text: "third",
      redacted: false,
      submission: submission(3),
      state: "unknown",
    },
    {
      operationId: "operation-2",
      text: "second",
      redacted: false,
      submission: submission(2),
      state: "pending",
    },
  ];
  state.tasks[0].inputSubmissions = [
    {
      submission: submission(4),
      input: { kind: "text", text: "waiting", redacted: false },
      state: "waiting",
      reason: null,
    },
  ];
  assert.deepEqual(
    await loadTaskInputHistory(
      productStateFixture(state, scope),
      "3",
      () => assert.fail("already loaded"),
      () => true,
    ),
    ["input-1", "second", "third", "waiting"],
  );
});

test("an empty Task has no input history and needs no paging", async () => {
  const state = fixture(0);
  assert.deepEqual(
    await loadTaskInputHistory(
      productStateFixture(state, scope),
      "3",
      () => assert.fail("no runs to load"),
      () => true,
    ),
    [],
  );
});

test("input history rejects stale authority, changing older Runs, failed or nonprogressing pages", async () => {
  for (const failure of [
    "security",
    "history",
    "version",
    "missing",
    "scope",
    "read",
  ]) {
    const state = fixture(5);
    await assert.rejects(
      loadTaskInputHistory(
        productStateFixture(state, scope),
        "3",
        async (requested) => {
          if (failure === "read") throw new Error("I/O failed");
          const next = productStateFixture(state, requested);
          if (failure === "security") next.securityEpoch = "999";
          if (failure === "history") next.historyEpoch = "999";
          if (failure === "version")
            next.taskPage.runManifest[0].contentVersion = "99";
          if (failure === "missing") next.historyPage.runs = [];
          if (failure === "scope") next.scope.taskId = "99";
          return next;
        },
        () => true,
      ),
    );
  }
  const state = fixture(5);
  let current = true;
  await assert.rejects(
    loadTaskInputHistory(
      productStateFixture(state, scope),
      "3",
      async (requested) => {
        current = false;
        return productStateFixture(state, requested);
      },
      () => current,
    ),
    /authority changed/,
  );
  await assert.rejects(
    loadTaskInputHistory(
      productStateFixture(state, scope),
      "99",
      () => assert.fail("wrong task"),
      () => true,
    ),
    /scope unavailable/,
  );
});
