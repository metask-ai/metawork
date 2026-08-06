import assert from "node:assert/strict";
import test from "node:test";

import {
  assertDisconnected,
  decodeWindowChromeEnvironment,
} from "../frontend/src/bridge/decode-contracts.ts";

const environment = {
  generation: "7",
  insets: { top: 52, left: 72, bottom: 0, right: 138 },
  buttons: { x: 0, y: 0, width: 138, height: 52 },
  livePointerDrag: false,
  rendererControls: true,
  maximized: false,
};

test("window chrome environment is runtime-decoded at the Bridge boundary", () => {
  assert.deepEqual(decodeWindowChromeEnvironment(environment), environment);
  const fractionalDpiEnvironment = {
    ...environment,
    insets: { top: 32.8, left: 0, bottom: 0, right: 138.4 },
    buttons: { x: 1041.6, y: 0, width: 138.4, height: 32.8 },
  };
  assert.deepEqual(
    decodeWindowChromeEnvironment(fractionalDpiEnvironment),
    fractionalDpiEnvironment,
  );
  for (const malformed of [
    { ...environment, generation: "0" },
    { ...environment, insets: { ...environment.insets, top: -1 } },
    { ...environment, buttons: { ...environment.buttons, width: Infinity } },
    { ...environment, livePointerDrag: "false" },
    { ...environment, rendererControls: "true" },
    { ...environment, maximized: "false" },
  ])
    assert.throws(() => decodeWindowChromeEnvironment(malformed));
});

test("window chrome disconnect acknowledges the exact document generation", () => {
  assert.doesNotThrow(() =>
    assertDisconnected({ generation: "7", detached: true }, "7"),
  );
  assert.throws(() =>
    assertDisconnected({ generation: "8", detached: true }, "7"),
  );
});
