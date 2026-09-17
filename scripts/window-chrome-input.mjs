// CDP records and prepares an isolated WebView. Every input under test comes
// from the Windows mouse probe, never CDP Input or synthetic DOM dispatch.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { connectTestWebView } from "./window-top-resize-paint.mjs";

export async function probeWindowChromeInput({ port, runProbe, evidenceDir }) {
  const webview = await connectTestWebView(port);
  const evidence = {
    runtime: await webview.send("Browser.getVersion"),
    cases: [],
  };
  try {
    await webview.evaluate(`(() => {
      const fixture = document.createElement('header');
      fixture.id = 'chrome-input-fixture';
      fixture.setAttribute('data-metawork-window-drag', '');
      fixture.style.cssText = 'position:fixed;inset:0 0 auto;height:40px;z-index:2147483647;background:white';
      fixture.innerHTML = '<button id="chrome-button" style="position:absolute;left:380px;top:8px;width:40px;height:24px"><svg width="30" height="20"><rect width="30" height="20"/></svg></button>'
        + '<button disabled style="position:absolute;left:430px;top:8px;width:40px;height:24px">off</button>'
        + '<div data-metawork-window-drag-exclude style="position:absolute;left:480px;top:8px;width:40px;height:24px"><div class="commandbar-inert-content" inert><button style="width:40px;height:24px">inert</button></div></div>'
        + '<span tabindex="0" style="position:absolute;left:580px;top:8px;width:40px;height:24px">focus</span>'
        + '<span contenteditable="" style="position:absolute;left:630px;top:8px;width:40px;height:24px">edit</span>'
        + '<input style="position:absolute;left:680px;top:8px;width:40px;height:24px">';
      // Production CSP rejects HTML inline styles; use CSSOM just like the paint probe.
      for (const element of fixture.querySelectorAll("[style]")) {
        const css = element.getAttribute("style");
        element.removeAttribute("style");
        element.style.cssText = css;
      }
      const portal = document.createElement('div');
      portal.id = 'chrome-input-portal';
      portal.style.cssText = 'position:fixed;left:530px;top:8px;width:40px;height:24px;z-index:2147483647;background:gray';
      const outside = document.createElement('div');
      outside.id = 'chrome-input-outside';
      outside.setAttribute('data-metawork-window-drag', '');
      outside.style.cssText = 'position:fixed;left:730px;top:80px;width:40px;height:40px;z-index:2147483647;background:white';
      document.body.append(fixture, portal, outside);
      window.__chromeInput = { events: [], calls: [] };
      const listener = event => window.__chromeInput.events.push({
        type:event.type, detail:event.detail, trusted:event.isTrusted,
        x:event.clientX, y:event.clientY, target:event.target.tagName, path:event.composedPath().filter(e => e.tagName).map(e => e.tagName + (e.id ? "#" + e.id : "")), windowBlur:event.type === "blur" && event.target === window,
        time:performance.now(),
      });
      for (const name of ['pointerdown', 'mousedown', 'mouseup', 'click', 'dblclick', 'blur'])
        window.addEventListener(name, listener, true);
      const transport = window.chrome.webview;
      const post = transport.postMessage;
      const observe = function(message) {
        const envelope = JSON.parse(message);
        if (envelope.command?.includes('windowChrome')) window.__chromeInput.calls.push(envelope);
        return post.call(this, message);
      };
      transport.postMessage = observe;
      if (transport.postMessage !== observe) throw new Error('Cannot observe test transport');
      window.__chromeInputCleanup = () => {
        transport.postMessage = post;
        for (const name of ['pointerdown', 'mousedown', 'mouseup', 'click', 'dblclick', 'blur'])
          window.removeEventListener(name, listener, true);
        fixture.remove(); portal.remove(); outside.remove();
      };
    })()`);
    for (const [name, inputCase, x = 300, y = 20, time = 0] of [
      ["default-pair", "pair"],
      ["slow-system-pair", "pair", 300, 20, 900],
      ["slow-system-timeout", "timeout", 300, 20, 900],
      ["distance-inside", "distance-inside"],
      ["distance-outside", "distance-outside"],
      ["triple-and-quad", "quad"],
      ["content-interruption", "content-reset"],
      ["control-interruption", "control-reset"],
      ["focus-interruption", "blur-reset"],
      ["ordinary-drag", "drag"],
      ["button-svg", "no-drag", 400],
      ["disabled-button", "no-drag", 450],
      ["inert-wrapper", "no-drag", 500],
      ["portal-overlay", "no-drag", 550],
      ["focusable", "no-drag", 600],
      ["editable", "no-drag", 650],
      ["input", "no-drag", 700],
      ["marker-outside-native-band", "no-drag", 750, 100],
    ]) {
      await webview.evaluate(
        `window.__chromeInput.events = []; window.__chromeInput.calls = []`,
      );
      let native;
      try {
        native = JSON.parse(
          (
            await runProbe("input-case", [
              "-InputCase",
              inputCase,
              "-PointX",
              String(x),
              "-PointY",
              String(y),
              "-DoubleClickMilliseconds",
              String(time),
              "-KeepTopmost",
            ])
          ).trim(),
        );
      } catch (error) {
        evidence.cases.push({
          name,
          failed: true,
          observed: await webview.evaluate("window.__chromeInput"),
          layout: await webview.evaluate(
            `Array.from(document.querySelectorAll("#chrome-input-fixture, #chrome-input-fixture button")).map(e => ({html:e.outerHTML,rect:e.getBoundingClientRect().toJSON(),pointer:getComputedStyle(e).pointerEvents}))`,
          ),
        });
        throw error;
      }
      const observed = await webview.evaluate("window.__chromeInput");
      evidence.cases.push({ name, native, ...observed });
      assert.ok(
        observed.events.some((e) => e.type === "pointerdown" && e.trusted),
      );
      assert.ok(
        observed.events
          .filter((e) => e.type === "pointerdown")
          .every((e) => e.detail === 0),
      );
      const pointers = observed.calls.filter((c) =>
        c.command.endsWith(".pointer"),
      );
      assert.ok(
        pointers.length > 0,
        `${name}: production pointer route was not reached`,
      );
      if (
        ["content-reset", "control-reset", "blur-reset"].includes(inputCase)
      ) {
        assert.deepEqual(
          pointers.map((c) => c.payload.phase),
          ["down", "reset", "down"],
        );
      }
      if (inputCase === "blur-reset") {
        const downs = observed.events.filter((e) => e.type === "mousedown");
        assert.equal(downs.length, 2);
        assert.ok(
          observed.events.some(
            (e) =>
              e.windowBlur && e.time > downs[0].time && e.time < downs[1].time,
          ),
        );
        assert.ok(
          downs[1].time - downs[0].time < native.timeMs,
          "Blur probe must interrupt within the OS interval",
        );
        evidence.browserBlurSequence = {
          counts: downs.map((e) => e.detail),
          intervalMs: downs[1].time - downs[0].time,
          equivalent: downs[1].detail !== 2,
        };
      }
      if (name === "marker-outside-native-band")
        assert.equal(pointers[0].payload.phase, "down");
      if (inputCase === "no-drag" && y < 40) {
        assert.ok(
          pointers.every((c) => c.payload.phase === "reset"),
          `${name}: excluded input was forwarded as drag`,
        );
      }
      process.stdout.write(
        `${name}: mousedown.detail=${JSON.stringify(observed.events.filter((e) => e.type === "mousedown").map((e) => e.detail))}\n`,
      );
    }
  } finally {
    await webview.evaluate("window.__chromeInputCleanup?.()");
    webview.close();
    if (evidenceDir) {
      await mkdir(evidenceDir, { recursive: true });
      await writeFile(
        path.join(evidenceDir, "window-chrome-input.json"),
        JSON.stringify(evidence, null, 2) + "\n",
      );
    }
  }
  return evidence;
}
