import assert from "node:assert/strict";
import test from "node:test";

import {
  deriveRunPresentation,
  runElapsedSeconds,
  observeRunProcessDisclosure,
  toggleRunProcessDisclosure,
} from "../frontend/src/features/tasks/run-presentation.ts";
import { RevisionNotificationQueue } from "../frontend/src/bridge/revision-notification.ts";

function terminal(outcome, cause = null) {
  return { outcome, cause, diagnosticDisposition: "absent" };
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

function run(overrides = {}) {
  return {
    id: "7",
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
    terminal: null,
    usage: { input: "0", output: "0", cacheRead: "0", cacheCreation: "0" },
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

test("presentation orders Tool evidence and only names one typed running Tool", () => {
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
  assert.equal(presentation.runningToolName, "Tool current");

  const ambiguous = deriveRunPresentation(
    run({
      activity: { kind: "executing_tools", inFlight: "2" },
      tools: [tool("one", "1", "running"), tool("two", "2", "running")],
    }),
  );
  assert.equal(ambiguous.runningToolName, null);
});

test("successful final response compresses process evidence without a duplicate notice", () => {
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

test("technical process stays collapsed by default while activity remains visible", () => {
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

test("revision delivery coalesces bursts but releases spaced preterminal updates", async () => {
  const previousWindow = globalThis.window;
  globalThis.window = { setTimeout, clearTimeout };
  try {
    const revisions = [];
    const queue = new RevisionNotificationQueue(
      (revision) => revisions.push(revision),
      5,
    );
    queue.push("2");
    queue.push("3");
    await new Promise((resolve) => setTimeout(resolve, 12));
    queue.push("4");
    await new Promise((resolve) => setTimeout(resolve, 12));
    queue.stop();
    assert.deepEqual(revisions, ["3", "4"]);
  } finally {
    if (previousWindow === undefined) delete globalThis.window;
    else globalThis.window = previousWindow;
  }
});
