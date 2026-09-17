// Observe the real product Bridge; inputs come from the owned Windows mouse
// probe. Hidden-window requests intentionally exercise the existing protocol.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { connectTestWebView } from "./window-top-resize-paint.mjs";

export async function probeWindowChromeControls({
  port,
  runProbe,
  openTray,
  evidenceDir,
}) {
  const webview = await connectTestWebView(port);
  const evidence = {
    runtime: await webview.send("Browser.getVersion"),
    cases: [],
  };
  let handle;
  async function nativeState() {
    const state = JSON.parse(
      await runProbe("control-state", handle ? ["-WindowHandle", handle] : []),
    );
    handle ??= state.handle;
    assert.equal(
      state.handle,
      handle,
      "The startup window must survive hide/reopen",
    );
    return state;
  }
  async function until(read, accepts, label) {
    const deadline = Date.now() + 15_000;
    let last;
    do {
      last = await read();
      if (accepts(last)) return last;
      await new Promise((resolve) => setTimeout(resolve, 40));
    } while (Date.now() < deadline);
    throw new Error(`${label} did not settle: ${JSON.stringify(last)}`);
  }
  async function ready(maximized) {
    return until(
      () =>
        webview.evaluate(`(() => {
      const root = document.documentElement;
      const buttons = [...document.querySelectorAll('[data-metawork-window-control]')];
      const visible = buttons.filter(b => b.getClientRects().length > 0);
      return { ready:root.dataset.metaworkWindowChrome === 'ready',
        maximized:root.dataset.metaworkWindowMaximized,
        enabled:visible.length === 3 && visible.every(b => !b.disabled),
        toggle:visible.find(b => b.dataset.metaworkWindowControl === 'toggle_maximize')?.className };
    })()`),
      (value) =>
        value.ready &&
        value.enabled &&
        value.maximized === String(maximized) &&
        value.toggle?.includes(
          maximized ? "window-control-restore" : "window-control-maximize",
        ),
      "Renderer controls",
    );
  }
  async function click(action) {
    const point = await until(
      () =>
        webview.evaluate(`(() => {
      const b = [...document.querySelectorAll('[data-metawork-window-control]')]
        .find(b => b.dataset.metaworkWindowControl === ${JSON.stringify(action)} && !b.disabled && b.getClientRects().length > 0);
      if (!b) return null;
      const r = b.getBoundingClientRect(); return {x:Math.round(r.x+r.width/2), y:Math.round(r.y+r.height/2)};
    })()`),
      (value) => value !== null,
      `Clickable ${action}`,
    );
    await runProbe("control-click", [
      "-WindowHandle",
      handle,
      "-PointX",
      String(point.x),
      "-PointY",
      String(point.y),
      "-KeepTopmost",
    ]);
  }
  async function invoke(command, payload = {}) {
    return webview.evaluate(`(async () => {
      try { return {ok:true, value:await window.zero.invoke('metawork.host.windowChrome.' + ${JSON.stringify(command)},
        {generation:window.__controlsProbe.generation, ...${JSON.stringify(payload)}})}; }
      catch (error) { return {ok:false, error:String(error?.message ?? error)}; }
    })()`);
  }
  try {
    await webview.evaluate(`(() => {
      const transport = window.chrome.webview;
      const post = transport.postMessage;
      window.__controlsProbe = {calls:[], generation:null};
      const observe = function(message) {
        const envelope = JSON.parse(message);
        if (envelope.command?.startsWith('metawork.host.windowChrome.')) {
          window.__controlsProbe.calls.push(envelope);
          if (envelope.payload?.generation) window.__controlsProbe.generation = envelope.payload.generation;
        }
        return post.call(this, message);
      };
      transport.postMessage = observe;
      if (transport.postMessage !== observe) throw new Error('Cannot observe controls transport');
      window.__controlsProbeCleanup = () => { transport.postMessage = post; delete window.__controlsProbe; };
    })()`);
    const initial = await nativeState();
    await ready(initial.maximized);
    // A real button action supplies the existing document generation passively.
    await click("toggle_maximize");
    await until(
      nativeState,
      (value) => value.maximized !== initial.maximized,
      "Maximize button",
    );
    await ready(!initial.maximized);
    await until(
      () => webview.evaluate("window.__controlsProbe.generation"),
      (value) => !!value,
      "Observed generation",
    );
    await click("close");
    const hidden = await until(
      nativeState,
      (value) => !value.visible,
      "User-close hide",
    );
    for (const action of ["minimize", "toggle_maximize", "close"]) {
      const result = await invoke("control", { action });
      assert.equal(result.ok, false, `Hidden ${action} must be rejected`);
      assert.match(result.error, /WindowHidden/);
      assert.equal((await nativeState()).visible, false);
      evidence.cases.push({ name: `hidden-${action}`, result });
    }
    const refresh = await invoke("refresh");
    assert.equal(refresh.ok, true, "A hidden window may refresh");
    assert.equal(refresh.value.maximized, hidden.maximized);
    const reset = await invoke("pointer", { phase: "reset" });
    assert.equal(reset.ok, true, "A hidden window may reset its sequence");
    await openTray();
    const reopened = await until(
      nativeState,
      (value) => value.visible && !value.minimized,
      "SDK tray reopen",
    );
    await ready(reopened.maximized);
    await click("toggle_maximize");
    await until(
      nativeState,
      (value) => value.maximized !== reopened.maximized,
      "Reopened button",
    );
    await ready(!reopened.maximized);
    evidence.cases.push({
      name: "hide-reject-refresh-reset-reopen",
      hidden,
      reopened,
      refresh,
      reset,
      passed: true,
    });
    process.stdout.write(
      "Windows controls hidden admission, refresh/reset, SDK tray reopen and real button recovery passed.\n",
    );
  } finally {
    if (evidenceDir) {
      await mkdir(evidenceDir, { recursive: true });
      await writeFile(
        path.join(evidenceDir, "window-chrome-controls.json"),
        JSON.stringify(evidence, null, 2),
      );
    }
    await webview
      .evaluate(
        "window.__controlsProbeCleanup?.(); delete window.__controlsProbeCleanup",
      )
      .catch(() => {});
    webview.close();
  }
}
