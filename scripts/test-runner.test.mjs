import assert from "node:assert/strict";
import test from "node:test";

import { runTestPhases } from "./run-tests.mjs";

test("repository test phases run in order and report every failure", async () => {
  const calls = [];
  const first = new Error("node failed");
  const second = new Error("native failed");

  await assert.rejects(
    runTestPhases([
      async () => {
        calls.push("node");
        throw first;
      },
      async () => {
        calls.push("native");
        throw second;
      },
    ]),
    (error) => {
      assert.ok(error instanceof AggregateError);
      assert.deepEqual(error.errors, [first, second]);
      return true;
    },
  );
  assert.deepEqual(calls, ["node", "native"]);
});
