import assert from "node:assert/strict";
import process from "node:process";
import test from "node:test";
import { measure, processCounters } from "./memory-growth-vertical.mjs";

// No process holds this id: Windows process ids are small multiples of four.
const absentPid = 2 ** 31 - 1;

test(
  "memory growth counters leave out a process that exited after the tree query",
  { skip: process.platform !== "win32" },
  async () => {
    const counters = await processCounters([process.pid, absentPid]);
    assert.deepEqual(
      counters.map((entry) => entry.Id),
      [process.pid],
    );
    assert.ok(counters[0].WorkingSet64 > 0);
    assert.ok(counters[0].ThreadCount > 0);
  },
);

test(
  "memory growth sampling still fails when the Host itself is gone",
  { skip: process.platform !== "win32" },
  async () => {
    assert.deepEqual(await processCounters([absentPid]), []);
    await assert.rejects(
      measure(absentPid),
      new RegExp(`host process ${absentPid} disappeared while sampling`),
    );
  },
);
