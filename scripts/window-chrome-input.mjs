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
      const titlebar = document.querySelector('header[data-metawork-window-drag]');
      if (!titlebar) throw new Error('Production titlebar is not mounted');
      const fixture = document.createElement('div');
      fixture.id = 'chrome-input-fixture';
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
      // Exercise the existing production ref binding, never install a test handler.
      titlebar.append(fixture, outside);
      document.body.append(portal);
      const adjacent = document.createElement('button');
      adjacent.id = 'chrome-adjacent';
      adjacent.style.cssText = 'position:absolute;left:301px;top:8px;width:1px;height:24px;padding:0;border:0';
      adjacent.hidden = true;
      fixture.append(adjacent);
      adjacent.addEventListener('pointerdown', event => {
        if (adjacent.dataset.mode === 'cancel') event.preventDefault();
        if (adjacent.dataset.mode === 'stop') event.stopPropagation();
      });
      adjacent.addEventListener('mousedown', event => {
        if (adjacent.dataset.mode === 'stop') event.stopPropagation();
      });
      window.__chromeInput = { events: [], calls: [] };
      const listener = event => window.__chromeInput.events.push({
        type:event.type, detail:event.detail, trusted:event.isTrusted,
        x:event.clientX, y:event.clientY, target:event.target.tagName, path:event.composedPath().filter(e => e.tagName).map(e => e.tagName + (e.id ? "#" + e.id : "")), windowBlur:event.type === "blur" && event.target === window,
        titlebar:event.composedPath().includes(titlebar),
        excluded:event.composedPath().some(e => e.matches?.('button,input,select,textarea,label,details,summary,a,[tabindex],[contenteditable],[inert],[data-metawork-window-drag-exclude]')),
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
    const cases = [
      ["default-pair", "pair"],
      ["slow-system-pair", "pair", 300, 20, 900],
      ["slow-system-timeout", "timeout", 300, 20, 900],
      ["distance-inside", "distance-inside"],
      ["distance-outside", "distance-outside"],
      ["triple-and-quad", "quad"],
      ["content-interruption", "content-reset"],
      ["control-interruption", "control-reset"],
      ["focus-interruption", "blur-reset"],
      ["native-edge-interruption", "browser-edge"],
      ...["normal", "disabled", "stop", "cancel"].map((mode) => [
        `adjacent-${mode}`,
        "browser-adjacent",
      ]),
      ["ordinary-drag", "drag"],
      ["button-svg", "no-drag", 400],
      ["disabled-button", "no-drag", 450],
      ["inert-wrapper", "no-drag", 500],
      ["portal-overlay", "no-drag", 550],
      ["focusable", "no-drag", 600],
      ["editable", "no-drag", 650],
      ["input", "no-drag", 700],
      ["marker-outside-native-band", "no-drag", 750, 100],
    ];
    for (const [
      name,
      inputCase,
      x = 300,
      y = 20,
      time = 0,
      dx = 0,
      dy = 0,
    ] of cases) {
      await webview.evaluate(
        `(() => {
          window.__chromeInput.events = []; window.__chromeInput.calls = [];
          const adjacent = document.querySelector('#chrome-adjacent');
          adjacent.hidden = !${JSON.stringify(name.startsWith("adjacent-"))};
          adjacent.disabled = ${JSON.stringify(name === "adjacent-disabled")};
          adjacent.dataset.mode = ${JSON.stringify(name.replace("adjacent-", ""))};
        })()`,
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
              "-BrowserGesture",
              "-OffsetX",
              String(dx),
              "-OffsetY",
              String(dy),
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
      const gestures = observed.calls.filter((c) =>
        c.command.endsWith(".gesture"),
      );
      const eligible = observed.events.filter(
        (e) =>
          e.type === "mousedown" &&
          e.titlebar &&
          !e.excluded &&
          (e.detail === 1 || e.detail === 2),
      );
      assert.deepEqual(
        gestures.map((c) => c.payload.action),
        eligible.map((e) =>
          e.detail === 2 ? "toggle_maximize" : "start_drag",
        ),
        `${name}: intent differs from browser count`,
      );
      assert.ok(
        observed.calls.every((c) => !c.command.endsWith(".pointer")),
        "retired protocol must not be emitted",
      );
      const toggleCount = gestures.filter(
        (c) => c.payload.action === "toggle_maximize" && c.payload.y < 40,
      ).length;
      assert.equal(
        native.maximized,
        toggleCount % 2 === 1,
        `${name}: native state differs from authorized intent`,
      );
      if (name === "default-pair" || name === "slow-system-pair") {
        assert.deepEqual(
          eligible.map((e) => e.detail),
          [1, 2],
        );
        assert.equal(native.maximized, true);
      }
      if (name.startsWith("adjacent-")) {
        const presses = observed.events.filter((e) => e.type === "pointerdown");
        assert.equal(presses.length, 3, "three real adjacent presses required");
        assert.ok(
          presses[1].path.some((p) => p.includes("#chrome-adjacent")),
          "middle press must hit adjacent control",
        );
        assert.ok(
          (Math.abs(presses[1].x - presses[0].x) * native.dpi) / 96 <=
            native.distanceWidth / 2,
        );
        assert.ok(presses[2].time - presses[0].time < native.timeMs);
        // WebView2 suppresses mousedown on a disabled button, but the browser
        // counter still advances: the two delivered title events are 1 and 3.
        if (name === "adjacent-disabled")
          assert.deepEqual(
            observed.events
              .filter((e) => e.type === "mousedown")
              .map((e) => e.detail),
            [1, 3],
          );
        else if (name !== "adjacent-cancel")
          assert.deepEqual(
            observed.events
              .filter((e) => e.type === "mousedown")
              .map((e) => e.detail),
            [1, 2, 3],
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
          finalAction: downs[1].detail === 2 ? "toggle_maximize" : "start_drag",
        };
      }
      if (name === "marker-outside-native-band")
        assert.equal(gestures[0].payload.action, "start_drag");
      if (inputCase === "no-drag" && y < 40) {
        assert.ok(
          gestures.length === 0,
          `${name}: excluded input was forwarded as drag`,
        );
      }
      evidence.cases.at(-1).passed = true;
      // Use observed OS metrics, testing both axes/directions without assuming
      // the old Host's closed rectangle or the child prototype's pixel boundary.
      if (name === "default-pair") {
        for (const [axis, size] of [
          ["x", native.distanceWidth],
          ["y", native.distanceHeight],
        ]) {
          const half = Math.floor(size / 2);
          for (const delta of new Set([
            -half - 1,
            -half,
            -Math.max(half - 1, 0),
            Math.max(half - 1, 0),
            half,
            half + 1,
          ]))
            cases.push([
              `distance-${axis}-${delta}`,
              "offset-pair",
              300,
              20,
              0,
              axis === "x" ? delta : 0,
              axis === "y" ? delta : 0,
            ]);
        }
      }
      process.stdout.write(
        `${name}: mousedown.detail=${JSON.stringify(observed.events.filter((e) => e.type === "mousedown").map((e) => e.detail))}\n`,
      );
    }
  } catch (error) {
    evidence.failure = String(error.stack ?? error);
    if (evidence.cases.length) evidence.cases.at(-1).passed = false;
    throw error;
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
