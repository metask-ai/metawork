import assert from "node:assert/strict";
import test from "node:test";

import { submitTaskInstruction } from "../frontend/src/features/composer/submitTaskInstruction.ts";
import { resolveFirstSendWorkspace } from "../frontend/src/features/composer/firstSendWorkspace.ts";
import { chooseWorkspaceWithDraft } from "../frontend/src/features/workspaces/chooseWorkspace.ts";

test("a failed authoritative refresh cannot move or lose the source draft", async () => {
  const calls = [];
  const failure = new Error("snapshot unavailable");
  await assert.rejects(
    chooseWorkspaceWithDraft({
      choose: async () => {
        calls.push("choose");
        return { selected: true, workspaceId: "7" };
      },
      refresh: async () => {
        calls.push("refresh");
        throw failure;
      },
      openDraft: true,
      sourceDraftId: "unscoped",
      moveDraft() {
        calls.push("move");
        return "moved";
      },
    }),
    failure,
  );
  assert.deepEqual(calls, ["choose", "refresh"]);
});

test("cancelling first-send Workspace selection preserves the draft boundary", async () => {
  let draft = "Keep this instruction";
  let chooseCalls = 0;
  const workspace = await resolveFirstSendWorkspace({
    taskId: null,
    workspace: null,
    chooseWorkspace: async () => {
      chooseCalls += 1;
      return null;
    },
  });
  if (workspace.kind === "ready") draft = "";
  assert.deepEqual(workspace, { kind: "cancelled" });
  assert.equal(chooseCalls, 1);
  assert.equal(draft, "Keep this instruction");
});

test("an existing Task never asks for another Workspace", async () => {
  let chooseCalled = false;
  const result = await resolveFirstSendWorkspace({
    taskId: "9",
    workspace: { workspaceId: "2", workspaceEpoch: "5" },
    chooseWorkspace: async () => {
      chooseCalled = true;
      return "unexpected";
    },
  });
  assert.deepEqual(result, {
    kind: "ready",
    workspaceId: "2",
    workspaceEpoch: "5",
  });
  assert.equal(chooseCalled, false);
});

test("an existing Task with missing Workspace identity fails closed", async () => {
  let chooseCalled = false;
  const result = await resolveFirstSendWorkspace({
    taskId: "9",
    workspace: null,
    chooseWorkspace: async () => {
      chooseCalled = true;
      return { workspaceId: "unrelated-workspace", workspaceEpoch: "1" };
    },
  });
  assert.deepEqual(result, { kind: "cancelled" });
  assert.equal(chooseCalled, false);
});

test("the first send uses Host generations and creates one Task before its Run", async () => {
  const calls = [];
  const created = [];
  const result = await submitTaskInstruction({
    client: {
      async createTask(
        workspaceId,
        expectedWorkspaceEpoch,
        expectedExecutionGeneration,
      ) {
        calls.push([
          "create",
          workspaceId,
          expectedWorkspaceEpoch,
          expectedExecutionGeneration,
        ]);
        return {
          accepted: true,
          taskId: "41",
          bindingEpoch: "8",
          reason: null,
        };
      },
      async run(taskId, expectedBindingEpoch, instruction) {
        calls.push(["run", taskId, expectedBindingEpoch, instruction]);
        return { accepted: true, taskId, runId: "9", reason: null };
      },
    },
    taskId: null,
    workspaceId: "7",
    expectedWorkspaceEpoch: "5",
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    instruction: "Ship a working product",
    onTaskCreated: (taskId) => created.push(taskId),
  });
  assert.deepEqual(calls, [
    ["create", "7", "5", "19"],
    ["run", "41", "8", "Ship a working product"],
  ]);
  assert.deepEqual(created, ["41"]);
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
    workspaceId: "7",
    expectedWorkspaceEpoch: "5",
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    instruction: "Keep this text",
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
    workspaceId: "7",
    expectedWorkspaceEpoch: "5",
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    instruction: "Keep this text",
    onTaskCreated: () => assert.fail("a rejected creation has no Task"),
  });
  assert.deepEqual(result, {
    kind: "create_rejected",
    reason: "execution_changed",
  });
});

test("the first send cannot bypass the Host-projected Workspace identity", async () => {
  let createCalled = false;
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        createCalled = true;
        return { accepted: true, taskId: "1", bindingEpoch: "1", reason: null };
      },
      async run() {
        assert.fail("a Run cannot start without a Workspace");
      },
    },
    taskId: null,
    workspaceId: "",
    expectedWorkspaceEpoch: "",
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    instruction: "Do not bypass trust",
    onTaskCreated() {
      assert.fail("a Task cannot exist without a Workspace");
    },
  });
  assert.equal(result.kind, "create_failed");
  assert.equal(createCalled, false);
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
    workspaceId: "7",
    expectedWorkspaceEpoch: "5",
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    instruction: "Recover me",
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
      async run(taskId, expectedBindingEpoch, instruction) {
        assert.equal(taskId, "9");
        assert.equal(expectedBindingEpoch, "12");
        assert.equal(instruction, "Continue");
        return { accepted: true, taskId, runId: "10", reason: null };
      },
    },
    taskId: "9",
    workspaceId: "7",
    expectedWorkspaceEpoch: "5",
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: "12",
    instruction: "Continue",
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
    workspaceId: "7",
    expectedWorkspaceEpoch: "5",
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: "12",
    instruction: "Continue",
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
    workspaceId: "7",
    expectedWorkspaceEpoch: "5",
    expectedExecutionGeneration: "19",
    expectedBindingEpoch: null,
    instruction: "Continue",
    onTaskCreated() {},
  });
  assert.equal(result.kind, "run_failed");
  assert.equal(runCalled, false);
});
