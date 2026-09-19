// Fixed HTML prototype only. CDP prepares fixture modes; all tested input comes
// from the repository's scoped Win32 probe. Native trace and OS outcomes agree.
import assert from "node:assert/strict";
import { connectTestWebView } from "./window-top-resize-paint.mjs";

export async function probeFixedDragInput({
  port,
  runProbe,
  nativeLog,
  record,
}) {
  const webview = await connectTestWebView(port, {
    htmlTitle: "Fixed native drag input probe",
  });
  const cases = [
    ["distance-matrix", "native-distance-matrix", 24, 6],
    ["pair", "pair", 2, 1],
    ["timeout", "timeout", 2, 0],
    ["slow-pair", "pair", 2, 1, 900],
    ["slow-timeout", "timeout", 2, 0, 900],
    ["quad", "quad", 4, 2],
    ["content", "content-reset", 2, 0],
    ["control", "control-reset", 2, 0],
    ["adjacent", "adjacent-reset", 2, 0],
    ["adjacent-disabled", "adjacent-reset", 2, 0],
    ["adjacent-cancel", "adjacent-reset", 2, 0],
    ["adjacent-stop", "adjacent-reset", 2, 0],
    ["edge", "edge-reset", 2, 0],
    ["blur", "blur-reset", 2, 0],
    ["blur-repair", "probe-blur-repair", 3, 1],
    ["blur-drag", "probe-blur-drag", 2, 0],
    ["drag", "drag", 1, 0],
    ["maximized-drag", "maximized-drag", 3, 1],
    ["control-no-drag", "no-drag", 0, 0, 0, 400],
    ["content-no-drag", "no-drag", 0, 0, 0, 300, 100],
  ];
  try {
    assert.equal(
      await webview.evaluate(
        `typeof cancelPointer === 'boolean' && typeof stopPropagation === 'boolean' && adjacent.id === 'adjacent'`,
      ),
      true,
      "Unexpected fixture",
    );
    for (const [
      name,
      inputCase,
      presses,
      toggles,
      time = 0,
      x = 300,
      y = 20,
    ] of cases) {
      await webview.evaluate(`adjacent.disabled=${name === "adjacent-disabled"};
        cancelPointer=${name === "adjacent-cancel"}; stopPropagation=${name === "adjacent-stop"};
        records.length=0;output.textContent='';modes();`);
      const start = nativeLog().length;
      const result = { name, inputCase };
      try {
        result.os = JSON.parse(
          await runProbe("input-case", [
            "-InputCase",
            inputCase,
            "-PointX",
            String(x),
            "-PointY",
            String(y),
            "-DoubleClickMilliseconds",
            String(time),
          ]),
        );
        result.dom = await webview.evaluate("records.slice()");
        result.native = nativeLog().slice(start);
        assert.equal(result.os.passed, true);
        assert.doesNotMatch(
          result.native,
          /trace-overflow|CLEANUP FAILED|level=error|error:/,
        );
        const received = [
          ...result.native.matchAll(
            /child-input tick=(\d+) msg=0x(a1|a3) .*?xy=0x([0-9a-f]+)/g,
          ),
        ];
        assert.equal(
          received.length,
          presses,
          `${name}: actual native presses`,
        );
        assert.equal(
          received.filter((press) => press[2] === "a3").length,
          toggles,
          `${name}: native double-click count`,
        );
        assert.equal(
          (result.native.match(/DRAG_PROBE toggle maximized=/g) ?? []).length,
          toggles,
          `${name}: toggle count`,
        );
        if (inputCase === "native-distance-matrix") {
          assert.equal(result.os.interruption.samples.length, 12);
          for (let i = 0; i < 12; i++) {
            const a = received[i * 2];
            const b = received[i * 2 + 1];
            assert.equal(a[2], "a1");
            assert.ok(Number(b[1]) - Number(a[1]) < result.os.timeMs);
            assert.equal(
              b[2] === "a3",
              result.os.interruption.samples[i].maximized,
            );
          }
        }
        if (inputCase === "adjacent-reset") {
          assert.ok(
            result.dom.some(
              (event) =>
                event.startsWith("pointerdown:") &&
                event.includes("trusted=true"),
            ),
          );
          assert.ok(
            result.dom.every((event) => event.includes("trusted=true")),
          );
          const hasMouseDown = result.dom.some((event) =>
            event.startsWith("mousedown:"),
          );
          assert.equal(
            hasMouseDown,
            !["adjacent-disabled", "adjacent-cancel"].includes(name),
          );
        }
        if (["drag", "maximized-drag", "probe-blur-drag"].includes(inputCase)) {
          assert.match(result.native, /msg=0x231/);
          assert.match(result.native, /msg=0x232/);
        }
        if (inputCase === "edge-reset")
          assert.equal(
            result.os.interruption.controlClass,
            "MetaWorkSystemWebViewTopResize",
          );
        result.passed = true;
      } catch (error) {
        result.native = nativeLog().slice(start);
        result.error = String(error.stack ?? error);
        result.passed = false;
        await record(result);
        throw error;
      }
      await record(result);
    }
  } finally {
    try {
      await webview.evaluate(
        "adjacent.disabled=false;cancelPointer=false;stopPropagation=false;modes();",
      );
    } finally {
      webview.close();
    }
  }
}
