import assert from "node:assert/strict";
import test from "node:test";

import {
  deriveAssistantOutputParts,
  deriveRunReadingFlow,
  deriveTaskReadingPlan,
  localReadingAnchor,
} from "../frontend/src/features/tasks/assistant-output.ts";

function input(id, afterOutputCount) {
  return {
    id,
    afterOutputCount,
    text: `input ${id}`,
    redacted: false,
    operationId: `send-${id}`,
    sequence: Number(id),
    adoptedTurn: null,
    order: null,
    state: "pending",
  };
}

function readingOrder(out, inputs) {
  return deriveRunReadingFlow("7", out, inputs).map((entry) =>
    entry.kind === "input"
      ? `user:${entry.input.id}`
      : entry.parts.map((part) => part.ordinal),
  );
}

test("submission anchors interleave ordinary input without fragmenting adjacent output", () => {
  const out = output({ commentary: ["Earlier", "More"], provisional: "Tail" });
  assert.deepEqual(readingOrder(out, []), [[0, 1, 2]]);
  assert.deepEqual(readingOrder(out, [input("1", 1), input("2", 1)]), [
    [0],
    "user:1",
    "user:2",
    [1, 2],
  ]);
  assert.deepEqual(readingOrder(out, [input("1", 0)]), ["user:1", [0, 1, 2]]);
});

test("discarded tails and decreasing anchors cannot reverse user submissions", () => {
  const inputs = [input("1", 1), input("2", 0), input("3", 257)];
  assert.deepEqual(readingOrder(output(), inputs), [
    "user:1",
    "user:2",
    "user:3",
  ]);
  assert.deepEqual(readingOrder(output({ provisional: "Retry" }), inputs), [
    [0],
    "user:1",
    "user:2",
    "user:3",
  ]);
});

test("empty sanitized slots and redacted tails retain their reading positions", () => {
  const out = output({
    commentary: ["Earlier", ""],
    provisionalRedacted: true,
  });
  const flow = deriveRunReadingFlow("7", out, [input("1", 2)]);
  assert.deepEqual(readingOrder(out, [input("1", 2)]), [[0, 1], "user:1", [2]]);
  assert.equal(flow[2].redacted, true);
  assert.equal(flow[0].redacted, false);
  assert.equal(flow[2].parts[0].disposition, "provisional");
});

test("adoption and tail classification do not change reading block identities", () => {
  const before = deriveRunReadingFlow(
    "7",
    output({ commentary: ["Earlier"], provisional: "Answer" }),
    [input("1", 1)],
  );
  const after = deriveRunReadingFlow(
    "7",
    output({
      commentary: ["Earlier"],
      response: "Answer",
      responseKind: "final",
    }),
    [{ ...input("1", 1), state: "adopted", adoptedTurn: 2, order: "4" }],
  );
  assert.deepEqual(
    before.map((entry) => entry.identity),
    after.map((entry) => entry.identity),
  );
  assert.equal(before[2].parts[0].identity, after[2].parts[0].identity);
});

function output(overrides = {}) {
  return {
    commentary: [],
    response: "",
    responseKind: null,
    provisional: "",
    redacted: false,
    provisionalRedacted: false,
    ...overrides,
  };
}

test("a provisional tail keeps its identity when classified as commentary", () => {
  const provisional = deriveAssistantOutputParts(
    "7",
    output({ provisional: "Checking" }),
  );
  const commentary = deriveAssistantOutputParts(
    "7",
    output({ commentary: ["Checking"] }),
  );

  assert.deepEqual(provisional, [
    {
      identity: "7:output:0",
      ordinal: 0,
      content: "Checking",
      disposition: "provisional",
    },
  ]);
  assert.equal(commentary[0].identity, provisional[0].identity);
  assert.equal(commentary[0].disposition, "commentary");
});

test("a provisional tail keeps its identity when classified as a response", () => {
  const provisional = deriveAssistantOutputParts(
    "9",
    output({
      commentary: ["Worked"],
      provisional: "Ready",
    }),
  );
  const response = deriveAssistantOutputParts(
    "9",
    output({
      commentary: ["Worked"],
      response: "Ready",
      responseKind: "final",
    }),
  );

  assert.equal(provisional[1].identity, "9:output:1");
  assert.equal(response[1].identity, provisional[1].identity);
  assert.equal(response[1].disposition, "final");
});

test("empty commentary retains its ordinal without producing a false tail", () => {
  const parts = deriveAssistantOutputParts(
    "11",
    output({ commentary: ["Visible", ""], provisional: "Next" }),
  );

  assert.deepEqual(
    parts.map(({ identity, ordinal, disposition }) => ({
      identity,
      ordinal,
      disposition,
    })),
    [
      { identity: "11:output:0", ordinal: 0, disposition: "commentary" },
      { identity: "11:output:1", ordinal: 1, disposition: "commentary" },
      { identity: "11:output:2", ordinal: 2, disposition: "provisional" },
    ],
  );
});

test("redacted provisional output retains a tail identity and discard removes it", () => {
  const redacted = deriveAssistantOutputParts(
    "13",
    output({ provisionalRedacted: true }),
  );
  const discarded = deriveAssistantOutputParts("13", output());

  assert.deepEqual(redacted, [
    {
      identity: "13:output:0",
      ordinal: 0,
      content: "",
      disposition: "provisional",
    },
  ]);
  assert.deepEqual(discarded, []);
});

test("an empty classified response retains the canonical output ordinal", () => {
  const parts = deriveAssistantOutputParts(
    "15",
    output({ commentary: ["Done"], responseKind: "partial" }),
  );

  assert.deepEqual(parts[1], {
    identity: "15:output:1",
    ordinal: 1,
    content: "",
    disposition: "partial",
  });
});

function positionedInput(id, anchor, order) {
  const value = input(id, anchor);
  value.submission = {
    operationId: value.operationId,
    receivedAtUnixMs: null,
    anchorRunId: "7",
    afterOutputCount: anchor,
    presentationOrder: order,
  };
  return value;
}
function image(id, anchor, order) {
  return {
    id,
    title: "",
    displayPath: `${id}.png`,
    generatedImage: true,
    presentationAnchor: { afterOutputCount: anchor, presentationOrder: order },
  };
}
function flowLabels(flow) {
  return flow.map((entry) =>
    entry.kind === "assistant"
      ? entry.parts.map((part) => part.ordinal)
      : entry.kind === "image"
        ? `image:${entry.reference.id}`
        : entry.kind === "input"
          ? `user:${entry.input.id}`
          : entry.kind,
  );
}
function projectedRun(id, overrides = {}) {
  return {
    id,
    submission: null,
    phase: "completed",
    terminal: { outcome: "completed" },
    activity: null,
    tools: [],
    additionalInputs: [],
    input: { kind: "text", text: `root ${id}`, redacted: false },
    output: output({ response: "done", responseKind: "final" }),
    ...overrides,
  };
}

test("an accepted image stays before the interjection when later output arrives, without adoption order", () => {
  const user = positionedInput("1", 1, "2");
  const oldImage = image("old", 1, "1");
  const initial = output({ commentary: ["original"] });
  assert.deepEqual(
    flowLabels(deriveRunReadingFlow("7", initial, [user], [], [oldImage])),
    [[0], "image:old", "user:1"],
  );
  const later = { ...initial, provisional: "adjusting" };
  assert.deepEqual(
    flowLabels(deriveRunReadingFlow("7", later, [user], [], [oldImage])),
    [[0], "image:old", "user:1", [1]],
  );
  assert.deepEqual(
    flowLabels(
      deriveRunReadingFlow(
        "7",
        later,
        [{ ...user, state: "adopted", order: "100" }],
        [],
        [oldImage],
      ),
    ),
    [[0], "image:old", "user:1", [1]],
  );
  const newImage = image("new", 2, "3");
  assert.deepEqual(
    flowLabels(
      deriveRunReadingFlow("7", later, [user], [], [newImage, oldImage]),
    ),
    [[0], "image:old", "user:1", [1], "image:new"],
  );
});

test("image and message prefix anchors survive discard followed by slot reuse", () => {
  const user = positionedInput("1", 1, "2");
  const old = image("old", 3, "1");
  assert.deepEqual(
    flowLabels(deriveRunReadingFlow("7", output(), [user], [], [old])),
    ["image:old", "user:1"],
  );
  assert.deepEqual(
    flowLabels(
      deriveRunReadingFlow(
        "7",
        output({ commentary: ["a", "b"], provisional: "retry" }),
        [user],
        [],
        [old],
      ),
    ),
    [[0, 1, 2], "image:old", "user:1"],
  );
});

test("local confirmation keeps its logical position and operation identity beside images", () => {
  const ref = image("old", 1, "10");
  const run = projectedRun("7", {
    phase: "running",
    terminal: null,
    output: output({ commentary: ["original"] }),
    tools: [{ fileRefs: [ref] }],
  });
  const task = { runs: [run], inputSubmissions: [] };
  const local = { operationId: "send-1", anchor: localReadingAnchor(task, 0) };
  const before = deriveRunReadingFlow("7", run.output, [], [], [ref], [local]);
  const after = deriveRunReadingFlow(
    "7",
    run.output,
    [positionedInput("1", 1, "11")],
    [],
    [ref],
  );
  assert.deepEqual(
    before.map((entry) => entry.identity),
    after.map((entry) => entry.identity),
  );
});

test("terminal supplements precede trailing messages and missing anchor pages cannot hide roots", () => {
  const next = projectedRun("8", {
    submission: {
      operationId: "continue",
      anchorRunId: "7",
      afterOutputCount: 1,
      presentationOrder: "1",
      receivedAtUnixMs: null,
    },
  });
  const paged = deriveTaskReadingPlan({ runs: [next], inputSubmissions: [] });
  assert.equal(paged.runs[0].showRoot, true);
  const full = deriveTaskReadingPlan({
    runs: [projectedRun("7"), next],
    inputSubmissions: [],
  });
  assert.equal(full.runs[1].showRoot, false);
  assert.deepEqual(
    full.runs[0].entries.map((entry) => entry.kind),
    ["assistant", "supplement", "submission"],
  );
  assert.equal(full.runs[0].entries.at(-1).identity, "submission:continue");
});

test("legacy images follow Run text and precede details and old or new continuation messages", () => {
  const pictures = ["old-a", "old-b"].map((id) => ({
    ...image(id, 0, "1"),
    presentationAnchor: null,
  }));
  for (const presentationOrder of [null, "1"]) {
    const previous = projectedRun("7", {
      output: output({
        commentary: ["Earlier"],
        response: "ANSWER1",
        responseKind: "final",
      }),
      additionalInputs: [input("1", 1)],
      tools: [{ fileRefs: pictures }],
    });
    const next = projectedRun("8", {
      submission: {
        operationId: "continue",
        anchorRunId: "7",
        afterOutputCount: 2,
        presentationOrder,
        receivedAtUnixMs: null,
      },
    });
    const plan = deriveTaskReadingPlan({
      runs: [previous, next],
      inputSubmissions: [],
    });
    assert.deepEqual(flowLabels(plan.runs[0].entries), [
      [0],
      "user:1",
      [1],
      "image:old-a",
      "image:old-b",
      "supplement",
      "submission",
    ]);
    assert.deepEqual(
      plan.runs[0].entries
        .filter((entry) => entry.kind === "image")
        .map((entry) => entry.identity),
      ["7:image:old-a", "7:image:old-b"],
    );
    assert.equal(plan.runs[1].showRoot, false);
  }
});

test("legacy image-only Runs place the image and details before trailing input", () => {
  const plan = deriveTaskReadingPlan({
    inputSubmissions: [],
    runs: [
      projectedRun("7", {
        output: output(),
        additionalInputs: [input("1", 0)],
        tools: [
          { fileRefs: [{ ...image("old", 0, "1"), presentationAnchor: null }] },
        ],
      }),
    ],
  });
  assert.deepEqual(flowLabels(plan.runs[0].entries), [
    "image:old",
    "supplement",
    "user:1",
  ]);
});
