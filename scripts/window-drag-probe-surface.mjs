import assert from "node:assert/strict";
import path from "node:path";
import {
  connectTestWebView,
  probeTopResizePaint,
} from "./window-top-resize-paint.mjs";

export async function probeFixedDragSurface({
  port,
  runProbe,
  nativeLog,
  record,
  evidenceDir,
}) {
  let index = 0;
  const observedProbe = async (mode, args = []) => {
    const result = { name: `${++index}-${mode}`, arguments: args };
    const start = nativeLog().length;
    try {
      result.output = await runProbe(mode, [...args, "-KeepTopmost"]);
      result.native = nativeLog().slice(start);
      assert.doesNotMatch(
        result.native,
        /trace-overflow|CLEANUP FAILED|level=error|error:/,
      );
      result.passed = true;
    } catch (error) {
      result.output = error.stdout?.trim();
      result.native = nativeLog().slice(start);
      result.passed = false;
      result.error = String(error.stack ?? error);
      await record(result);
      throw error;
    }
    await record(result);
    return result.output;
  };
  await observedProbe("probe-layout");
  await probeTopResizePaint({
    port,
    runProbe: observedProbe,
    evidenceDir,
    fixedDrag: true,
  });
  await observedProbe("top-resize", ["-Repeat", "3"]);
  await observedProbe("probe-layout");

  const webview = await connectTestWebView(port, {
    htmlTitle: "Fixed native drag input probe",
  });
  try {
    await webview.evaluate(`(() => {
      const layer = document.createElement('div');
      layer.id='metawork-drag-animation';
      layer.style.cssText='position:fixed;inset:0 0 auto;height:40px;z-index:2147483647;pointer-events:none;background:repeating-linear-gradient(90deg,#116466 0 12px,#fff 12px 24px);animation:metaworkDragPaint 1s linear infinite';
      const style=document.createElement('style');style.id='metawork-drag-animation-style';
      style.textContent='@keyframes metaworkDragPaint { to { background-position-x:24px; } }';
      document.head.append(style);document.body.append(layer);
    })()`);
    await observedProbe("probe-animation", [
      "-OutputPath",
      path.join(evidenceDir, "drag-animation.png"),
    ]);
  } finally {
    try {
      await webview.evaluate(
        "document.getElementById('metawork-drag-animation')?.remove();document.getElementById('metawork-drag-animation-style')?.remove();",
      );
    } finally {
      webview.close();
    }
  }
  await observedProbe("probe-resources");
  await observedProbe("probe-layout");
}
