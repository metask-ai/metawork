import test from "node:test";
import assert from "node:assert/strict";
import { configuredChildTimeout } from "./run-child-process.mjs";

test("uses a configurable bounded child-process timeout", () => {
  assert.equal(configuredChildTimeout({}), 120_000);
  assert.equal(
    configuredChildTimeout({ METAWORK_CHILD_TIMEOUT_MS: "45000" }),
    45_000,
  );
  assert.throws(
    () => configuredChildTimeout({ METAWORK_CHILD_TIMEOUT_MS: "0" }),
    /positive integer/,
  );
  assert.throws(
    () => configuredChildTimeout({ METAWORK_CHILD_TIMEOUT_MS: "invalid" }),
    /positive integer/,
  );
});
