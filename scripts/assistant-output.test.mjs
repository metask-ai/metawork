import assert from "node:assert/strict";
import test from "node:test";

import { deriveAssistantOutputParts } from "../frontend/src/features/tasks/assistant-output.ts";

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
