import assert from "node:assert/strict";
import test from "node:test";

import {
  invokeWebViewBridge,
  webViewBridgeExpression,
} from "./webview-bridge-probe.mjs";

test("Renderer bridge expression preserves command and payload exactly", async () => {
  const command = `metawork.test.'\n</script>`;
  const payload = {
    text: `quote: ' \" slash: \\ newline:\n`,
    nested: [1, true],
  };
  const calls = [];
  const window = {
    zero: {
      async invoke(...args) {
        calls.push(args);
        return { accepted: true };
      },
    },
  };
  const expression = webViewBridgeExpression(command, payload);
  const response = await Function("window", `return ${expression}`)(window);

  assert.deepEqual(calls, [[command, payload]]);
  assert.deepEqual(response, { ok: true, result: { accepted: true } });
});

test("Renderer bridge failures retain typed Host error details", async () => {
  const webview = {
    async evaluate() {
      return {
        ok: false,
        error: {
          code: "handler_failed",
          message: "StaleSnapshot",
          name: "Error",
        },
      };
    },
  };

  await assert.rejects(
    () => invokeWebViewBridge(webview, "metawork.workbench.snapshot.chunk", {}),
    (error) => {
      assert.equal(error.bridgeCommand, "metawork.workbench.snapshot.chunk");
      assert.deepEqual(error.bridgeResponseError, {
        code: "handler_failed",
        message: "StaleSnapshot",
        name: "Error",
      });
      return true;
    },
  );
});

test("Renderer bridge rejects malformed probe responses", async () => {
  await assert.rejects(
    () =>
      invokeWebViewBridge(
        { evaluate: async () => null },
        "metawork.workbench.snapshot",
        {},
      ),
    /invalid Renderer response/,
  );
});
