import assert from "node:assert/strict";
import test from "node:test";

const { projectConversation } =
  await import("../frontend/src/features/agent-surface/conversation-projection.ts");

function task(overrides = {}) {
  return {
    id: "task-1",
    runs: [],
    compacts: [],
    pendingUi: null,
    uiHistory: [],
    ...overrides,
  };
}

function run(overrides = {}) {
  return {
    id: "run-1",
    phase: "running",
    input: { kind: "text", text: "inspect", redacted: false },
    assistant: "",
    assistantRedacted: false,
    status: "Running",
    outcome: null,
    cause: null,
    usage: { input: "0", output: "0", cacheRead: "0", cacheCreation: "0" },
    tools: [],
    ...overrides,
  };
}

test("projects typed input and preserves a mixed activity order", () => {
  const projected = projectConversation(
    task({
      runs: [
        run({
          input: {
            kind: "skill",
            skillId: "skill-1",
            catalogRevision: "7",
            invocationName: "review",
            displayName: "Review",
            argumentValues: ["src"],
            redacted: false,
          },
          tools: [
            {
              id: "tool-2",
              order: "20",
              name: "Edit",
              input: "{}",
              progress: "",
              content: "",
              state: "completed",
              isError: false,
              elapsedMs: "1",
              inputTruncated: false,
              progressTruncated: false,
              contentTruncated: false,
              redacted: false,
            },
            {
              id: "tool-1",
              order: "10",
              name: "Read",
              input: "{}",
              progress: "",
              content: "",
              state: "completed",
              isError: false,
              elapsedMs: "1",
              inputTruncated: false,
              progressTruncated: false,
              contentTruncated: false,
              redacted: false,
            },
          ],
        }),
      ],
      uiHistory: [
        {
          requestId: "request-1",
          runId: "run-1",
          order: "15",
          kind: "permission",
          state: "allowed_once",
          agentRequestId: "agent-1",
          permission: null,
          detail: "allowed",
          itemCount: 1,
          detailTruncated: false,
          redacted: false,
        },
      ],
      pendingUi: {
        requestId: "request-2",
        runId: "run-1",
        order: "25",
        redacted: false,
        kind: "permission",
        tool: "Bash",
        args: "{}",
        availableChoices: [
          "deny_once",
          "deny_session",
          "allow_once",
          "allow_session",
        ],
      },
    }),
  );

  assert.equal(projected.length, 1);
  assert.equal(projected[0].kind, "run");
  assert.equal(projected[0].input.kind, "skill");
  assert.deepEqual(
    projected[0].activities.map((activity) => [activity.kind, activity.id]),
    [
      ["tool", "tool-1"],
      ["resolved_ui", "request-1"],
      ["tool", "tool-2"],
      ["pending_ui", "request-2"],
    ],
  );
});

test("projects compact entries after their owning run", () => {
  const projected = projectConversation(
    task({
      runs: [run({ phase: "completed", outcome: "completed" })],
      compacts: [
        {
          operationId: "compact-1",
          afterRunId: "run-1",
          phase: "compacted",
          cause: null,
          beforeContextTokens: "100",
          afterContextTokens: "40",
          usage: {
            input: "10",
            output: "5",
            cacheRead: "0",
            cacheCreation: "0",
          },
        },
      ],
    }),
  );

  assert.deepEqual(
    projected.map((entry) => entry.kind),
    ["run", "compact"],
  );
  assert.equal(projected[1].id, "compact-1");
});
