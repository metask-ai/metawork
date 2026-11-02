import assert from "node:assert/strict";
import test from "node:test";

import {
  deriveRunPresentation,
  formatRunFinishedTime,
  runElapsedSeconds,
  observeRunProcessDisclosure,
  toggleRunProcessDisclosure,
} from "../frontend/src/features/tasks/run-presentation.ts";

function terminal(outcome, cause = null) {
  return { outcome, cause, diagnosticDisposition: "absent", modelError: null };
}

test("elapsed time uses the snapshot receipt rather than component mount or event count", () => {
  assert.equal(runElapsedSeconds("120000", 1000, 1500), 120n);
  assert.equal(runElapsedSeconds("120000", 1000, 15000), 134n);
  assert.equal(runElapsedSeconds("120000", 1000, 500), 120n);
  assert.equal(
    runElapsedSeconds("18446744073709551615", 0, 1000),
    18446744073709552n,
  );
});

test("finished time uses a locale-aware relative label with an absolute value", () => {
  const finishedAt = new Date(2026, 8, 11, 10, 25).getTime();
  const now = finishedAt + 4 * 24 * 60 * 60 * 1000;
  const english = formatRunFinishedTime("en-US", String(finishedAt), now);
  assert.equal(english.relative, "4 days ago");
  assert.equal(english.dateTime, new Date(finishedAt).toISOString());
  assert.ok(english.absolute.includes("2026"));
  assert.equal(
    formatRunFinishedTime("zh-CN", String(finishedAt), now).relative,
    "4天前",
  );
  assert.equal(
    formatRunFinishedTime("en-US", String(finishedAt), finishedAt + 30000)
      .relative,
    "Just now",
  );
  assert.equal(
    formatRunFinishedTime("zh-CN", String(finishedAt), finishedAt + 30000)
      .relative,
    "刚刚",
  );
  assert.equal(formatRunFinishedTime("en-US", null, now), null);
});

function run(overrides = {}) {
  return {
    id: "7",
    conversationCoverage: "included",
    phase: "running",
    permissionProfile: "approval_required",
    permissionInteraction: "interactive",
    execution: {
      generation: "1",
      protocol: "anthropic_messages",
      model: "fixture-model",
    },
    input: { kind: "text", text: "Build it", redacted: false },
    output: {
      commentary: [],
      response: "",
      responseKind: null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    activity: { kind: "waiting_model" },
    submittedAtUnixMs: null,
    finishedAtUnixMs: null,
    terminal: null,
    usage: { input: "0", output: "0", cacheRead: "0", cacheCreation: "0" },
    additionalInputs: [],
    tools: [],
    fileChanges: null,
    ...overrides,
  };
}

function tool(id, order, state = "completed") {
  return {
    id,
    order,
    name: `Tool ${id}`,
    input: "",
    progress: "",
    content: "",
    state,
    isError: state === "failed",
    elapsedMs: state === "running" ? "0" : "12",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
    fileRefs: [],
  };
}

test("active Runs always derive one safe current activity without opening technical details", () => {
  const presentation = deriveRunPresentation(
    run({ phase: "waiting_ui", activity: null }),
  );
  assert.equal(presentation.active, true);
  assert.deepEqual(presentation.activity, { kind: "waiting_user" });
  assert.equal(presentation.processVisible, true);
  assert.equal(presentation.processCanCollapse, false);
});

test("commentary remains narrative content instead of technical process evidence", () => {
  const presentation = deriveRunPresentation(
    run({
      output: {
        commentary: ["Inspecting the workspace"],
        response: "",
        responseKind: null,
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: { kind: "thinking" },
    }),
  );
  assert.equal(presentation.processVisible, true);
  assert.equal(presentation.processCanCollapse, false);
  assert.deepEqual(presentation.activity, { kind: "thinking" });
});

test("presentation orders Tool evidence without deriving activity from records", () => {
  const presentation = deriveRunPresentation(
    run({
      activity: { kind: "executing_tools", inFlight: "1" },
      tools: [tool("later", "2"), tool("current", "1", "running")],
    }),
  );
  assert.deepEqual(
    presentation.tools.map((item) => item.id),
    ["current", "later"],
  );
  assert.deepEqual(presentation.activity, {
    kind: "executing_tools",
    inFlight: "1",
  });
  assert.equal(presentation.runningToolName, "Tool current");

  const ambiguous = deriveRunPresentation(
    run({
      activity: { kind: "executing_tools", inFlight: "2" },
      tools: [tool("one", "1", "running"), tool("two", "2", "running")],
    }),
  );
  assert.deepEqual(ambiguous.activity, {
    kind: "executing_tools",
    inFlight: "2",
  });
  assert.equal(ambiguous.runningToolName, null);

  for (const inFlight of ["2", null]) {
    const inconsistent = deriveRunPresentation(
      run({
        activity: { kind: "executing_tools", inFlight },
        tools: [tool("current", "1", "running")],
      }),
    );
    assert.deepEqual(inconsistent.activity, {
      kind: "executing_tools",
      inFlight,
    });
    assert.equal(inconsistent.runningToolName, null);
  }
  const degraded = deriveRunPresentation(
    run({
      activity: { kind: "waiting_model" },
      tools: [tool("old", "1", "running")],
    }),
  );
  assert.equal(degraded.runningToolName, null);
});

test("successful final response retains Tool evidence without a duplicate notice", () => {
  const presentation = deriveRunPresentation(
    run({
      phase: "completed",
      output: {
        commentary: ["Checked the workspace"],
        response: "Done",
        responseKind: "final",
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: null,
      terminal: terminal("completed"),
      tools: [tool("read", "1")],
    }),
  );
  assert.equal(presentation.processVisible, true);
  assert.equal(presentation.processCanCollapse, true);
  assert.equal(presentation.showTerminalNotice, false);
});

test("failure, missing response, and partial response keep truthful terminal treatment", () => {
  const failed = deriveRunPresentation(
    run({
      phase: "failed",
      activity: null,
      terminal: terminal("failed", "agent_failure"),
    }),
  );
  assert.equal(failed.processVisible, false);
  assert.equal(failed.showTerminalNotice, true);

  const partial = deriveRunPresentation(
    run({
      phase: "interrupted",
      output: {
        commentary: [],
        response: "Incomplete",
        responseKind: "partial",
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: null,
      terminal: terminal("interrupted"),
    }),
  );
  assert.equal(partial.responseVisible, true);
  assert.equal(partial.showTerminalNotice, true);
});

test("technical process remains available after a Tool-bearing Run completes", () => {
  const active = deriveRunPresentation(
    run({
      activity: { kind: "executing_tools", inFlight: "1" },
      tools: [tool("read", "1", "running")],
    }),
  );
  const terminalPresentation = deriveRunPresentation(
    run({
      phase: "completed",
      output: {
        commentary: ["Worked"],
        response: "Done",
        responseKind: "final",
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: null,
      terminal: terminal("completed"),
      tools: [tool("read", "1")],
    }),
  );
  assert.equal(active.processVisible, true);
  assert.equal(active.processCanCollapse, true);
  assert.equal(terminalPresentation.processVisible, true);
  assert.equal(terminalPresentation.processCanCollapse, true);
});

test("Run disclosure remains collapsed unless the user explicitly opens it", () => {
  const active = observeRunProcessDisclosure(undefined);
  assert.deepEqual(active, { expanded: false });
  assert.equal(observeRunProcessDisclosure(active).expanded, false);

  const manual = toggleRunProcessDisclosure(true);
  assert.deepEqual(observeRunProcessDisclosure(manual), {
    expanded: true,
  });
  assert.equal(observeRunProcessDisclosure(manual).expanded, true);
});

test("adoption facts do not create user message entries in the technical process", () => {
  const message = {
    id: "1",
    operationId: "input-1",
    text: "constraint",
    afterOutputCount: 0,
    redacted: false,
    state: "adopted",
    sequence: 1,
    adoptedTurn: 2,
    order: "2",
  };
  const presentation = deriveRunPresentation(
    run({
      additionalInputs: [
        message,
        {
          ...message,
          id: "2",
          operationId: "input-2",
          sequence: 2,
          adoptedTurn: null,
          order: null,
        },
        {
          ...message,
          id: "3",
          operationId: "input-3",
          sequence: 3,
          state: "unadopted",
          adoptedTurn: null,
          order: null,
        },
      ],
      tools: [tool("before", "1"), tool("after", "3")],
    }),
  );
  assert.equal("inputs" in presentation, false);
  const withoutTools = deriveRunPresentation(
    run({
      phase: "completed",
      terminal: terminal("completed"),
      additionalInputs: [message],
      tools: [],
    }),
  );
  assert.equal(withoutTools.processCanCollapse, false);
  assert.equal(withoutTools.processVisible, false);
  assert.equal(presentation.processCanCollapse, true);
  assert.deepEqual(
    presentation.tools.map((tool) => tool.order),
    ["1", "3"],
  );
});
