import assert from "node:assert/strict";
import test from "node:test";

import { submitTaskInstruction } from "../frontend/src/features/composer/submitTaskInstruction.ts";
import { chooseWorkspaceAndMigrateDraft } from "../frontend/src/features/workspaces/chooseWorkspace.ts";

test("a failed authoritative refresh cannot move or lose the source draft", async () => {
  const calls = [];
  const failure = new Error("snapshot unavailable");
  await assert.rejects(
    chooseWorkspaceAndMigrateDraft({
      choose: async () => {
        calls.push("choose");
        return { selected: true, workspaceId: "7" };
      },
      refresh: async () => {
        calls.push("refresh");
        throw failure;
      },
      migratableDraftId: "unscoped",
      moveDraft() {
        calls.push("move");
        return "moved";
      },
    }),
    failure,
  );
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

test("the first send uses Host generations and creates one Task before its Run", async () => {
  const calls = [];
  const created = [];
  const result = await submitTaskInstruction({
    client: {
      async createTask(
        workspace,
        expectedExecutionGeneration,
        expectedSkillCatalogRevision,
      ) {
        calls.push([
          "create",
          workspace,
          expectedExecutionGeneration,
          expectedSkillCatalogRevision,
        ]);
        return {
          accepted: true,
          taskId: "41",
          bindingEpoch: "8",
          reason: null,
        };
      },
      async run(taskId, expectedBindingEpoch, input) {
        calls.push(["run", taskId, expectedBindingEpoch, input]);
        return { accepted: true, taskId, runId: "9", reason: null };
      },
    },
    taskId: null,
    workspace: {
      kind: "manual",
      workspaceId: "7",
      expectedWorkspaceEpoch: "5",
    },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    input: { kind: "text", text: "Ship a working product" },
    onTaskCreated: (taskId) => created.push(taskId),
  });
  assert.deepEqual(calls, [
    [
      "create",
      { kind: "manual", workspaceId: "7", expectedWorkspaceEpoch: "5" },
      "19",
      null,
    ],
    ["run", "41", "8", { kind: "text", text: "Ship a working product" }],
  ]);
  assert.deepEqual(created, ["41"]);
  assert.deepEqual(result, { kind: "started", taskId: "41", created: true });
});

test("the first Skill send pins its selected catalog before typed execution", async () => {
  const calls = [];
  const input = {
    kind: "skill",
    skillId: "builtin.review",
    catalogRevision: "17",
    argumentValues: ["src/main.zig"],
  };
  const result = await submitTaskInstruction({
    client: {
      async createTask(...args) {
        calls.push(["create", ...args]);
        return {
          accepted: true,
          taskId: "41",
          bindingEpoch: "8",
          reason: null,
        };
      },
      async run(...args) {
        calls.push(["run", ...args]);
        return { accepted: true, taskId: "41", runId: "9", reason: null };
      },
    },
    taskId: null,
    workspace: {
      kind: "manual",
      workspaceId: "7",
      expectedWorkspaceEpoch: "5",
    },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    input,
    onTaskCreated() {},
  });
  assert.deepEqual(calls, [
    [
      "create",
      { kind: "manual", workspaceId: "7", expectedWorkspaceEpoch: "5" },
      "19",
      "17",
    ],
    ["run", "41", "8", input],
  ]);
  assert.deepEqual(result, { kind: "started", taskId: "41", created: true });
});

test("a creation failure never starts a Run or invents a Task", async () => {
  let runCalled = false;
  let createdCalled = false;
  const failure = new Error("credential missing");
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        throw failure;
      },
      async run() {
        runCalled = true;
      },
    },
    taskId: null,
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    input: { kind: "text", text: "Keep this text" },
    onTaskCreated: () => {
      createdCalled = true;
    },
  });
  assert.deepEqual(result, { kind: "create_failed", error: failure });
  assert.equal(runCalled, false);
  assert.equal(createdCalled, false);
});

test("a Host-rejected creation preserves the structured product reason", async () => {
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        return {
          accepted: false,
          taskId: null,
          bindingEpoch: null,
          reason: "execution_changed",
        };
      },
      async run() {
        assert.fail("a rejected creation cannot start a Run");
      },
    },
    taskId: null,
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    input: { kind: "text", text: "Keep this text" },
    onTaskCreated: () => assert.fail("a rejected creation has no Task"),
  });
  assert.deepEqual(result, {
    kind: "create_rejected",
    reason: "execution_changed",
  });
});

test("the first send can request an Automatic Workspace without a prior identity", async () => {
  const calls = [];
  const result = await submitTaskInstruction({
    client: {
      async createTask(...args) {
        calls.push(["create", ...args]);
        return { accepted: true, taskId: "1", bindingEpoch: "1", reason: null };
      },
      async run(...args) {
        calls.push(["run", ...args]);
        return { accepted: true, taskId: "1", runId: "1", reason: null };
      },
    },
    taskId: null,
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    input: { kind: "text", text: "Do not bypass trust" },
    onTaskCreated: (taskId) => calls.push(["created", taskId]),
  });
  assert.deepEqual(calls, [
    ["create", { kind: "automatic" }, "19", null],
    ["created", "1"],
    ["run", "1", "1", { kind: "text", text: "Do not bypass trust" }],
  ]);
  assert.deepEqual(result, { kind: "started", taskId: "1", created: true });
});

test("a Run failure reports the real created Task for draft recovery", async () => {
  const failure = new Error("executor full");
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        return {
          accepted: true,
          taskId: "42",
          bindingEpoch: "3",
          reason: null,
        };
      },
      async run() {
        throw failure;
      },
    },
    taskId: null,
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    input: { kind: "text", text: "Recover me" },
    onTaskCreated() {},
  });
  assert.deepEqual(result, {
    kind: "run_failed",
    taskId: "42",
    created: true,
    error: failure,
  });
});

test("sending on an existing Task uses its binding epoch and never creates", async () => {
  let createCalled = false;
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        createCalled = true;
        return {
          accepted: true,
          taskId: "unexpected",
          bindingEpoch: "99",
          reason: null,
        };
      },
      async run(taskId, expectedBindingEpoch, input) {
        assert.equal(taskId, "9");
        assert.equal(expectedBindingEpoch, "12");
        assert.deepEqual(input, { kind: "text", text: "Continue" });
        return { accepted: true, taskId, runId: "10", reason: null };
      },
    },
    taskId: "9",
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: "12",
    input: { kind: "text", text: "Continue" },
    onTaskCreated() {
      assert.fail("existing Task must not create a Task");
    },
  });
  assert.equal(createCalled, false);
  assert.deepEqual(result, { kind: "started", taskId: "9", created: false });
});

test("a Host-rejected Run preserves the structured product reason", async () => {
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        assert.fail("existing Task must not create a Task");
      },
      async run(taskId) {
        return {
          accepted: false,
          taskId,
          runId: null,
          reason: "binding_changed",
        };
      },
    },
    taskId: "9",
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: "12",
    input: { kind: "text", text: "Continue" },
    onTaskCreated() {},
  });
  assert.deepEqual(result, {
    kind: "run_rejected",
    taskId: "9",
    created: false,
    reason: "binding_changed",
  });
});

test("an existing Task without a binding epoch fails closed", async () => {
  let runCalled = false;
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        assert.fail("existing Task must not create a Task");
      },
      async run() {
        runCalled = true;
      },
    },
    taskId: "9",
    workspace: { kind: "automatic" },
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    input: { kind: "text", text: "Continue" },
    onTaskCreated() {},
  });
  assert.equal(result.kind, "run_failed");
  assert.equal(runCalled, false);
});
