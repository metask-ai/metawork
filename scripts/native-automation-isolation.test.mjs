import assert from "node:assert/strict";
import test from "node:test";
import {
  assertNativeAutomationIsolation,
  nativeAutomationTokens,
} from "./native-automation-isolation.mjs";

test("Native automation scan accepts Native SDK product-runtime tokens", () => {
  assert.doesNotThrow(() =>
    assertNativeAutomationIsolation(
      Buffer.from("native-sdk-runtime\0zero://inline\0zero://app"),
      "fixture-binary",
    ),
  );
});

test("Native automation scan rejects every MetaWork automation token", () => {
  for (const token of nativeAutomationTokens) {
    assert.throws(
      () =>
        assertNativeAutomationIsolation(
          Buffer.concat([
            Buffer.from([0xff, 0x00]),
            Buffer.from(token),
            Buffer.from([0x00, 0xfe]),
          ]),
          "fixture-binary",
        ),
      (error) =>
        error instanceof Error &&
        error.message.includes(token) &&
        error.message.includes("fixture-binary"),
      `scanner must reject ${token}`,
    );
  }
});

test("Native automation scan accepts unrelated release bytes", () => {
  assert.doesNotThrow(() =>
    assertNativeAutomationIsolation(
      Buffer.from("metawork.tasks.create\0zero://app\0release"),
      "fixture-binary",
    ),
  );
});
