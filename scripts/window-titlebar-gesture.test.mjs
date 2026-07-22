import assert from "node:assert/strict";
import test from "node:test";

import { WindowTitlebarGesture } from "../frontend/src/platform/window-titlebar-gesture.ts";

test("titlebar drag waits for movement and fires once", () => {
  const gesture = new WindowTitlebarGesture();
  gesture.begin(7, 100, 50);
  assert.equal(gesture.move(7, 102, 51, 1), null);
  assert.equal(gesture.move(7, 104, 50, 1), 1);
  assert.equal(gesture.move(7, 20, 20, 1), null);
  gesture.end(7);
});

test("titlebar pointer cancellation clears pending movement", () => {
  const gesture = new WindowTitlebarGesture();
  gesture.begin(7, 100, 50);
  gesture.cancel(7);
  assert.equal(gesture.move(7, 120, 80, 1), null);
});
