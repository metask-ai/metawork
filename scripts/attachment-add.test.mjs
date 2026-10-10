import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import {
  decodeAttachmentAddResult,
  decodeAttachmentAddBegin,
  decodeAttachmentAddAcceptance,
  decodeAttachmentCancelResult,
} from "../frontend/src/bridge/decode-contracts.ts";
const wire = JSON.parse(
  readFileSync(
    new URL("../src/bridge/attachment_add.fixture", import.meta.url),
    "utf8",
  ),
);
test("unified async attachment fixture preserves exact result variants", () => {
  for (const value of [
    wire.ready,
    wire.cancelled,
    { status: "rejected", reason: "input_busy" },
    { status: "rejected", reason: "cleanup_failed" },
  ])
    assert.deepEqual(decodeAttachmentAddResult(value), value);
  assert.deepEqual(decodeAttachmentAddBegin(wire.accepted), wire.accepted);
  assert.deepEqual(
    decodeAttachmentAddAcceptance(wire.cancelled),
    wire.cancelled,
  );
  assert.deepEqual(decodeAttachmentCancelResult(wire.cleaned), wire.cleaned);
  assert.deepEqual(
    decodeAttachmentCancelResult(wire.cleanupFailed),
    wire.cleanupFailed,
  );
  assert.throws(() => decodeAttachmentAddAcceptance(wire.ready));
  assert.throws(() => decodeAttachmentAddResult(wire.accepted));
  assert.throws(() => decodeAttachmentCancelResult({ status: "cleaned" }));
  assert.throws(() =>
    decodeAttachmentCancelResult({ status: "cleanup_failed", released: false }),
  );
  assert.throws(() =>
    decodeAttachmentCancelResult({
      status: "cleaned",
      released: false,
      writerStopped: true,
    }),
  );
});
