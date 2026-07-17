import assert from "node:assert/strict";
import test from "node:test";

import { submitTaskInstruction } from "../frontend/src/features/composer/submitTaskInstruction.ts";

test("the first send creates one Session before starting its Run", async () => {
  const calls = [];
  const created = [];
  const result = await submitTaskInstruction({
    client: {
      async createSession(grant) {
        calls.push(["create", grant]);
        return "41";
      },
      async run(sessionId, instruction) {
        calls.push(["run", sessionId, instruction]);
      },
    },
    sessionId: null,
    workspaceGrant: "trusted-grant",
    instruction: "Ship a working product",
    onSessionCreated: (sessionId) => created.push(sessionId),
  });
  assert.deepEqual(calls, [
    ["create", "trusted-grant"],
    ["run", "41", "Ship a working product"],
  ]);
  assert.deepEqual(created, ["41"]);
  assert.deepEqual(result, { kind: "started", sessionId: "41", created: true });
});

test("a creation failure never starts a Run or invents a Task", async () => {
  let runCalled = false;
  let createdCalled = false;
  const failure = new Error("credential missing");
  const result = await submitTaskInstruction({
    client: {
      async createSession() {
        throw failure;
      },
      async run() {
        runCalled = true;
      },
    },
    sessionId: null,
    workspaceGrant: "one-time-grant",
    instruction: "Keep this text",
    onSessionCreated: () => {
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
      async createSession() {
        createCalled = true;
        return "unexpected";
      },
      async run() {
        assert.fail("a Run cannot start without a trusted workspace");
      },
    },
    sessionId: null,
    workspaceGrant: "",
    instruction: "Do not bypass trust",
    onSessionCreated() {
      assert.fail("a Session cannot exist without a trusted workspace");
    },
  });
  assert.equal(result.kind, "create_failed");
  assert.equal(createCalled, false);
});

test("a Run failure reports the real created Session for draft recovery", async () => {
  const failure = new Error("executor full");
  const result = await submitTaskInstruction({
    client: {
      async createSession() {
        return "42";
      },
      async run() {
        throw failure;
      },
    },
    sessionId: null,
    workspaceGrant: "one-time-grant",
    instruction: "Recover me",
    onSessionCreated() {},
  });
  assert.deepEqual(result, {
    kind: "run_failed",
    sessionId: "42",
    created: true,
    error: failure,
  });
});

test("sending on an existing Task never creates another Session", async () => {
  let createCalled = false;
  const result = await submitTaskInstruction({
    client: {
      async createSession() {
        createCalled = true;
        return "unexpected";
      },
      async run(sessionId, instruction) {
        assert.equal(sessionId, "9");
        assert.equal(instruction, "Continue");
      },
    },
    sessionId: "9",
    workspaceGrant: "",
    instruction: "Continue",
    onSessionCreated() {
      assert.fail("existing Task must not create a Session");
    },
  });
  assert.equal(createCalled, false);
  assert.deepEqual(result, { kind: "started", sessionId: "9", created: false });
});
