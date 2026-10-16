import assert from "node:assert/strict";
import test from "node:test";
import { generateRendererWire } from "./generate-renderer-wire.mjs";
import {
  decodeSnapshotDescriptor,
  decodeTaskApprovalResultWire,
  maxSnapshotBytes,
} from "../frontend/src/bridge/generated-wire.ts";

test("committed Renderer wire is generated from current Host types", async () => {
  await generateRendererWire({ check: true });
});

test("generated wire preserves string integers and rejects missing fields and coercion", () => {
  const descriptor = {
    snapshotId: "18446744073709551615",
    bytes: maxSnapshotBytes,
    chunkBytes: 262144,
  };
  assert.deepEqual(decodeSnapshotDescriptor(descriptor, "$"), descriptor);
  for (const bad of [
    { ...descriptor, snapshotId: 42 },
    { ...descriptor, snapshotId: "01" },
    { ...descriptor, snapshotId: "0" },
    { ...descriptor, bytes: 1.5 },
    { ...descriptor, bytes: 0 },
    { ...descriptor, bytes: "1" },
    { ...descriptor, extra: true },
    { snapshotId: "1", bytes: 1 },
  ])
    assert.throws(() => decodeSnapshotDescriptor(bad, "$"));
  const result = {
    revision: descriptor.snapshotId,
    outcome: "completed",
    reason: null,
  };
  assert.deepEqual(decodeTaskApprovalResultWire(result, "$"), result);
  assert.throws(() =>
    decodeTaskApprovalResultWire({ ...result, reason: "unknown" }, "$"),
  );
  assert.throws(() =>
    decodeTaskApprovalResultWire({ revision: "1", outcome: "completed" }, "$"),
  );
});
