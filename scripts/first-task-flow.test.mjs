import assert from "node:assert/strict";
import test from "node:test";

import { submitTaskInstruction } from "../frontend/src/features/composer/submitTaskInstruction.ts";
import {
  resolveFirstSendWorkspace,
  workspaceGrantForRoot,
} from "../frontend/src/features/composer/firstSendWorkspace.ts";

test("a Workspace grant is never reused for a different draft root", () => {
  assert.equal(
    workspaceGrantForRoot({
      draftActive: true,
      workspaceRoot: "/repo/beta",
      grantRoot: "/repo/alpha",
      grant: "alpha-grant",
    }),
    "",
  );
  assert.equal(
    workspaceGrantForRoot({
      draftActive: true,
      workspaceRoot: "/repo/alpha",
      grantRoot: "/repo/alpha",
      grant: "alpha-grant",
    }),
    "alpha-grant",
  );
});

test("cancelling first-send Workspace selection preserves the draft boundary", async () => {
  let draft = "Keep this instruction";
  let chooseCalls = 0;
  let createCalls = 0;
  const workspace = await resolveFirstSendWorkspace({
    taskId: null,
    workspaceGrant: "",
    chooseWorkspace: async () => {
      chooseCalls += 1;
      return null;
    },
  });
  if (workspace.kind === "ready") {
    const submitted = draft;
    draft = "";
    await submitTaskInstruction({
      client: {
        async createTask() {
          createCalls += 1;
          return "unexpected";
        },
        async run() {},
      },
      taskId: null,
      workspaceGrant: workspace.grant,
      instruction: submitted,
      onTaskCreated() {},
    });
  }
  assert.deepEqual(workspace, { kind: "cancelled" });
  assert.equal(chooseCalls, 1);
  assert.equal(createCalls, 0);
  assert.equal(draft, "Keep this instruction");
});

test("an existing Task never asks for a new Workspace grant", async () => {
  let chooseCalled = false;
  const result = await resolveFirstSendWorkspace({
    taskId: "9",
    workspaceGrant: "",
    chooseWorkspace: async () => {
      chooseCalled = true;
      return "unexpected";
    },
  });
  assert.deepEqual(result, { kind: "ready", grant: "" });
  assert.equal(chooseCalled, false);
});

test("the first send creates one Task before starting its Run", async () => {
  const calls = [];
  const created = [];
  const result = await submitTaskInstruction({
    client: {
      async createTask(grant) {
        calls.push(["create", grant]);
        return "41";
      },
      async run(taskId, instruction) {
        calls.push(["run", taskId, instruction]);
      },
    },
    taskId: null,
    workspaceGrant: "trusted-grant",
    instruction: "Ship a working product",
    onTaskCreated: (taskId) => created.push(taskId),
  });
  assert.deepEqual(calls, [
    ["create", "trusted-grant"],
    ["run", "41", "Ship a working product"],
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
    workspaceGrant: "one-time-grant",
    instruction: "Keep this text",
    onTaskCreated: () => {
      createdCalled = true;
    },
  });
  assert.deepEqual(result, { kind: "create_failed", error: failure });
  assert.equal(runCalled, false);
  assert.equal(createdCalled, false);
});

test("the first send cannot bypass the Host-issued workspace grant", async () => {
  let createCalled = false;
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        createCalled = true;
        return "unexpected";
      },
      async run() {
        assert.fail("a Run cannot start without a trusted workspace");
      },
    },
    taskId: null,
    workspaceGrant: "",
    instruction: "Do not bypass trust",
    onTaskCreated() {
      assert.fail("a Task cannot exist without a trusted workspace");
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
        return "42";
      },
      async run() {
        throw failure;
      },
    },
    taskId: null,
    workspaceGrant: "one-time-grant",
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

test("sending on an existing Task never creates another Task", async () => {
  let createCalled = false;
  const result = await submitTaskInstruction({
    client: {
      async createTask() {
        createCalled = true;
        return "unexpected";
      },
      async run(taskId, instruction) {
        assert.equal(taskId, "9");
        assert.equal(instruction, "Continue");
      },
    },
    taskId: "9",
    workspaceGrant: "",
    instruction: "Continue",
    onTaskCreated() {
      assert.fail("existing Task must not create a Task");
    },
  });
  assert.equal(createCalled, false);
  assert.deepEqual(result, { kind: "started", taskId: "9", created: false });
});
