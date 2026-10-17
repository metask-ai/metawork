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
  reloadPage,
  evidenceDir,
  reloadOnly = false,
}) {
  const webview = await connectTestWebView(port);
  const evidence = {
    runtime: await webview.send("Browser.getVersion"),
    cases: [],
    documents: [],
    clicks: [],
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
      const r = b.getBoundingClientRect(); return {x:Math.round(r.x+r.width/2), y:Math.round(r.y+r.height/2),
        width:innerWidth, height:innerHeight, maximized:document.documentElement.dataset.metaworkWindowMaximized};
    })()`),
      (value) => value !== null,
      `Clickable ${action}`,
    );
    evidence.clicks.push({ action, ...point });
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
  async function observeDocument() {
    await webview.evaluate(`(() => {
      const transport = window.chrome.webview;
      const post = transport.postMessage;
      window.__controlsProbe = {calls:[], inputs:[], generation:null};
      const inputTypes = ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'click', 'dblclick'];
      const observeInput = event => {
        const button = event.target.closest?.('[data-metawork-window-control]');
        if (window.__controlsProbe.inputs.length < 128) window.__controlsProbe.inputs.push({
          type:event.type, x:event.clientX, y:event.clientY, detail:event.detail,
          action:button?.dataset.metaworkWindowControl ?? null, disabled:button?.disabled ?? null,
          target:event.target.tagName, maximized:document.documentElement.dataset.metaworkWindowMaximized,
          width:innerWidth, height:innerHeight
        });
      };
      for (const type of inputTypes) document.addEventListener(type, observeInput, true);
      const observe = function(message) {
        const envelope = JSON.parse(message);
        if (envelope.command?.startsWith('metawork.host.windowChrome.')) {
          window.__controlsProbe.calls.push(envelope);
          if (envelope.payload?.generation && !window.__controlsProbe.generation) window.__controlsProbe.generation = envelope.payload.generation;
        }
        return post.call(this, message);
      };
      transport.postMessage = observe;
      if (transport.postMessage !== observe) throw new Error('Cannot observe controls transport');
      window.__controlsProbeCleanup = () => {
        for (const type of inputTypes) document.removeEventListener(type, observeInput, true);
        transport.postMessage = post; delete window.__controlsProbe;
      };
    })()`);
  }
  async function archiveDocument() {
    const observation = await webview
      .evaluate("window.__controlsProbe")
      .catch(() => null);
    if (observation) evidence.documents.push(observation);
    await webview
      .evaluate(
        "window.__controlsProbeCleanup?.(); delete window.__controlsProbeCleanup",
      )
      .catch(() => {});
  }
  async function setMaximized(maximized) {
    const before = await nativeState();
    await ready(before.maximized);
    if (before.maximized !== maximized) await click("toggle_maximize");
    const state = await until(
      nativeState,
      (value) =>
        value.visible && !value.minimized && value.maximized === maximized,
      "Maximize/restore",
    );
    await ready(maximized);
    return state;
  }
  async function reopen() {
    await openTray();
    const state = await until(
      nativeState,
      (value) => value.visible && !value.minimized,
      "SDK tray reopen",
    );
    await ready(state.maximized);
    return state;
  }
  async function hiddenAdmission(name, expectedMaximized) {
    const hidden = await until(
      nativeState,
      (value) => !value.visible,
      "User-close hide",
    );
    assert.equal(hidden.maximized, expectedMaximized);
    const rejected = [];
    for (const [command, payload] of [
      ...["minimize", "toggle_maximize", "close"].map((action) => [
        "control",
        { action },
      ]),
    ]) {
      const result = await invoke(command, payload);
      assert.equal(result.ok, false, `Hidden ${command} must be rejected`);
      assert.match(result.error, /WindowHidden/);
      assert.equal((await nativeState()).visible, false);
      rejected.push({ command, payload, result });
    }
    const refresh = await invoke("refresh");
    assert.equal(refresh.ok, true, "A hidden window may refresh");
    assert.equal(refresh.value.maximized, hidden.maximized);
    const reopened = await reopen();
    assert.equal(reopened.maximized, expectedMaximized);
    await setMaximized(!expectedMaximized);
    evidence.cases.push({
      name,
      hidden,
      reopened,
      rejected,
      refresh,
      passed: true,
    });
  }
  try {
    await observeDocument();
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
    if (!reloadOnly) {
      for (const maximized of [false, true]) {
        await setMaximized(maximized);
        await click("close");
        await hiddenAdmission(
          `button-close-${maximized ? "maximized" : "normal"}`,
          maximized,
        );
        await setMaximized(maximized);
        await runProbe("control-alt-f4", [
          "-WindowHandle",
          handle,
          "-KeepTopmost",
        ]);
        await hiddenAdmission(
          `alt-f4-${maximized ? "maximized" : "normal"}`,
          maximized,
        );
      }

      await setMaximized(true);
      await click("minimize");
      const minimized = await until(
        nativeState,
        (value) => value.minimized,
        "Renderer minimize",
      );
      const taskbarInput = await runProbe("control-taskbar-restore", [
        "-WindowHandle",
        handle,
      ]);
      evidence.taskbarInput = taskbarInput;
      const restored = await until(
        nativeState,
        (value) => value.visible && !value.minimized,
        "Real taskbar restore",
      );
      assert.equal(
        restored.maximized,
        true,
        "Taskbar restore must preserve maximization",
      );
      await ready(true);
      evidence.cases.push({
        name: "maximized-minimize-taskbar-restore",
        minimized,
        restored,
        passed: true,
      });

      for (const actions of [
        ["close", "toggle_maximize"],
        ["toggle_maximize", "close"],
      ]) {
        await setMaximized(false);
        const results = await webview.evaluate(`(async () => {
        let completion = 0;
        return Promise.all(${JSON.stringify(actions)}.map(async action => {
          try {
            const value = await window.zero.invoke('metawork.host.windowChrome.control', {generation:window.__controlsProbe.generation, action});
            return {action, ok:true, value, completion:++completion};
          } catch (error) { return {action, ok:false, error:String(error?.message ?? error), completion:++completion}; }
        }));
      })()`);
        assert.equal(results.find((r) => r.action === "close").ok, true);
        const toggle = results.find((r) => r.action === "toggle_maximize");
        if (!toggle.ok) assert.match(toggle.error, /WindowHidden/);
        const hidden = await until(
          nativeState,
          (value) => !value.visible,
          "Interleaved close",
        );
        const rejected = await invoke("control", { action: "toggle_maximize" });
        assert.equal(rejected.ok, false);
        assert.match(rejected.error, /WindowHidden/);
        assert.equal((await nativeState()).visible, false);
        const reopened = await reopen();
        await setMaximized(!reopened.maximized);
        evidence.cases.push({
          name: actions.join("-then-"),
          input: "existing Bridge, no barrier",
          results,
          hidden,
          rejected,
          passed: true,
        });
      }
    }
    await setMaximized(false);
    const oldGeneration = await webview.evaluate(
      "window.__controlsProbe.generation",
    );
    await archiveDocument();
    await webview.evaluate("window.__controlsReloadMarker = true");
    await reloadPage();
    await until(
      () =>
        webview
          .evaluate(
            "window.__controlsReloadMarker === undefined && document.documentElement.dataset.metaworkWindowChrome === 'ready'",
          )
          .catch(() => false),
      (value) => value,
      "New document handshake",
    );
    await observeDocument();
    await setMaximized(true);
    const newGeneration = await webview.evaluate(
      "window.__controlsProbe.generation",
    );
    assert.ok(newGeneration && newGeneration !== oldGeneration);
    const stale = await invoke("control", {
      generation: oldGeneration,
      action: "toggle_maximize",
    });
    assert.equal(stale.ok, false);
    assert.match(stale.error, /StaleWindowChromeDocument/);
    assert.equal((await nativeState()).maximized, true);
    await setMaximized(false);
    evidence.cases.push({
      name: "reload-new-session-and-stale-rejection",
      oldGeneration,
      newGeneration,
      stale,
      passed: true,
    });
    process.stdout.write(
      reloadOnly
        ? "Windows reload, stale generation rejection and real restore button passed.\n"
        : "Windows controls lifecycle matrix passed: close/Alt+F4, hidden admission, taskbar restore, interleaving, reload and real button recovery.\n",
    );
  } catch (error) {
    evidence.failure = String(error?.stack ?? error);
    throw error;
  } finally {
    await archiveDocument();
    webview.close();
    if (evidenceDir) {
      await mkdir(evidenceDir, { recursive: true });
      await writeFile(
        path.join(evidenceDir, "window-chrome-controls.json"),
        JSON.stringify(evidence, null, 2),
      );
    }
  }
}
