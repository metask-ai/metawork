import assert from "node:assert/strict";
import test from "node:test";

import {
  titlebarPress,
  titlebarTargetIsInteractive,
} from "../frontend/src/platform/window-chrome.ts";

test("titlebar delegates every primary press to native chrome", () => {
  assert.equal(titlebarPress(0), 1);
  assert.equal(titlebarPress(1), null);
  assert.equal(titlebarPress(2), null);
});

test("titlebar excludes controls and explicit no-drag regions", () => {
  const target = (match) => ({ closest: () => match });
  assert.equal(titlebarTargetIsInteractive(target(null)), false);
  assert.equal(titlebarTargetIsInteractive(target({})), true);
  assert.equal(titlebarTargetIsInteractive(null), false);
});
