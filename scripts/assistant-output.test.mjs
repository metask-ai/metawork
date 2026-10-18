import assert from "node:assert/strict";
import test from "node:test";

import {
  deriveAssistantOutputParts,
  deriveRunReadingFlow,
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
