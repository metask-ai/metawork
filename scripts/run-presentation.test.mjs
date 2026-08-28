import assert from "node:assert/strict";
import test from "node:test";

import {
  deriveRunPresentation,
  observeRunProcessDisclosure,
  shouldAutoCollapseRunProcess,
  toggleRunProcessDisclosure,
} from "../frontend/src/features/tasks/run-presentation.ts";
import { RevisionNotificationQueue } from "../frontend/src/bridge/revision-notification.ts";

function run(overrides = {}) {
  return {
    id: "7",
    phase: "running",
    input: { kind: "text", text: "Build it", redacted: false },
    output: {
      commentary: "",
      response: "",
      responseKind: null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    activity: { kind: "waiting_model" },
    outcome: null,
    cause: null,
    usage: { input: "0", output: "0", cacheRead: "0", cacheCreation: "0" },
    tools: [],
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

test("active Runs always derive one safe current activity and remain expanded", () => {
  const presentation = deriveRunPresentation(
    run({ phase: "waiting_ui", activity: null }),
  );
  assert.equal(presentation.active, true);
  assert.deepEqual(presentation.activity, { kind: "waiting_user" });
  assert.equal(presentation.processVisible, true);
  assert.equal(presentation.processDefaultExpanded, true);
  assert.equal(presentation.processCanCollapse, false);
});

test("active process evidence remains user-collapsible without losing activity", () => {
  const presentation = deriveRunPresentation(
    run({
      output: {
        commentary: "Inspecting the workspace",
        response: "",
        responseKind: null,
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: { kind: "thinking" },
    }),
  );
  assert.equal(presentation.processCanCollapse, true);
  assert.equal(presentation.processDefaultExpanded, true);
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
        commentary: "Checked the workspace",
        response: "Done",
        responseKind: "final",
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: null,
      outcome: "completed",
      tools: [tool("read", "1")],
    }),
  );
  assert.equal(presentation.processVisible, true);
  assert.equal(presentation.processDefaultExpanded, false);
  assert.equal(presentation.processCanCollapse, true);
  assert.equal(presentation.showTerminalNotice, false);
});

test("failure, missing response, and partial response keep truthful terminal treatment", () => {
  const failed = deriveRunPresentation(
    run({
      phase: "failed",
      activity: null,
      outcome: "failed",
      cause: "agent_failure",
    }),
  );
  assert.equal(failed.processDefaultExpanded, true);
  assert.equal(failed.showTerminalNotice, true);

  const partial = deriveRunPresentation(
    run({
      phase: "interrupted",
      output: {
        commentary: "",
        response: "Incomplete",
        responseKind: "partial",
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: null,
      outcome: "interrupted",
    }),
  );
  assert.equal(partial.responseVisible, true);
  assert.equal(partial.showTerminalNotice, true);
  assert.equal(partial.processDefaultExpanded, true);
});

test("automatic terminal collapse never overrides reading position or user choice", () => {
  const presentation = deriveRunPresentation(
    run({
      phase: "completed",
      output: {
        commentary: "Worked",
        response: "Done",
        responseKind: "final",
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: null,
      outcome: "completed",
    }),
  );
  assert.equal(
    shouldAutoCollapseRunProcess({
      presentation,
      wasActive: true,
      followingLatest: true,
      userToggled: false,
    }),
    true,
  );
  for (const state of [
    { wasActive: false, followingLatest: true, userToggled: false },
    { wasActive: true, followingLatest: false, userToggled: false },
    { wasActive: true, followingLatest: true, userToggled: true },
  ]) {
    assert.equal(
      shouldAutoCollapseRunProcess({ presentation, ...state }),
      false,
    );
  }
});

test("Run disclosure preserves manual choice and only collapses on an eligible terminal transition", () => {
  const activePresentation = deriveRunPresentation(
    run({
      output: {
        commentary: "Working",
        response: "",
        responseKind: null,
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
    }),
  );
  const terminalPresentation = deriveRunPresentation(
    run({
      phase: "completed",
      output: {
        commentary: "Working",
        response: "Done",
        responseKind: "final",
        provisional: "",
        redacted: false,
        provisionalRedacted: false,
      },
      activity: null,
      outcome: "completed",
    }),
  );

  const active = observeRunProcessDisclosure(
    undefined,
    activePresentation,
    true,
  );
  assert.deepEqual(active, {
    expanded: true,
    userToggled: false,
    wasActive: true,
  });
  assert.equal(
    observeRunProcessDisclosure(active, terminalPresentation, true).expanded,
    false,
  );
  assert.equal(
    observeRunProcessDisclosure(active, terminalPresentation, false).expanded,
    true,
  );

  const manual = toggleRunProcessDisclosure(active, false);
  assert.deepEqual(
    observeRunProcessDisclosure(manual, activePresentation, true),
    { expanded: false, userToggled: true, wasActive: true },
  );
  assert.equal(
    observeRunProcessDisclosure(manual, terminalPresentation, true).expanded,
    false,
  );
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
