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
      const titlebar = document.querySelector('header[data-native-window-drag]');
      if (!titlebar) throw new Error('Production titlebar is not mounted');
      const fixture = document.createElement('div');
      fixture.id = 'chrome-input-fixture';
      fixture.style.cssText = 'position:fixed;inset:0 0 auto;height:40px;z-index:2147483647;background:white';
      fixture.innerHTML = '<button data-native-window-drag-exclude id="chrome-button" style="position:absolute;left:380px;top:8px;width:40px;height:24px"><svg width="30" height="20"><rect width="30" height="20"/></svg></button>'
        + '<button data-native-window-drag-exclude disabled style="position:absolute;left:430px;top:8px;width:40px;height:24px">off</button>'
        + '<div data-native-window-drag-exclude style="position:absolute;left:480px;top:8px;width:40px;height:24px"><div class="commandbar-inert-content" inert><button style="width:40px;height:24px">inert</button></div></div>'
        + '<span data-native-window-drag-exclude tabindex="0" style="position:absolute;left:580px;top:8px;width:40px;height:24px">focus</span>'
        + '<span data-native-window-drag-exclude contenteditable="" style="position:absolute;left:630px;top:8px;width:40px;height:24px">edit</span>'
        + '<input data-native-window-drag-exclude style="position:absolute;left:680px;top:8px;width:40px;height:24px">';
      // Production CSP rejects HTML inline styles; use CSSOM just like the paint probe.
      for (const element of fixture.querySelectorAll("[style]")) {
        const css = element.getAttribute("style");
        element.removeAttribute("style");
        element.style.cssText = css;
      }
      const portal = document.createElement('div');
      portal.id = 'chrome-input-portal';
      portal.setAttribute('data-native-window-drag-exclude', '');
      portal.style.cssText = 'position:fixed;left:530px;top:8px;width:40px;height:24px;z-index:2147483647;background:gray';
      const outside = document.createElement('div');
      outside.id = 'chrome-input-outside';
      outside.style.cssText = 'position:fixed;left:730px;top:80px;width:40px;height:40px;z-index:2147483647;background:white';
      // Declarations use the production SDK input path, never a test drag handler.
      titlebar.append(fixture);
      document.body.append(outside);
      document.body.append(portal);
      window.__chromeInput = { events: [], calls: [] };
      const listener = event => window.__chromeInput.events.push({
        type:event.type, detail:event.detail, trusted:event.isTrusted,
        x:event.clientX, y:event.clientY, target:event.target.tagName, path:event.composedPath().filter(e => e.tagName).map(e => e.tagName + (e.id ? "#" + e.id : "")), windowBlur:event.type === "blur" && event.target === window,
        titlebar:event.composedPath().includes(titlebar),
        excluded:event.composedPath().some(e => e.matches?.('button,input,select,textarea,label,details,summary,a,[tabindex],[contenteditable],[inert],[data-native-window-drag-exclude]')),
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
      ["default-pair", "pair", 300, 20, 0, true],
      ["slow-system-pair", "pair", 300, 20, 900, true],
      ["slow-system-timeout", "timeout", 300, 20, 900, false],
      ["distance-outside", "distance-outside", 300, 20, 0, false],
      ["ordinary-drag", "drag"],
      ["button-svg", "no-drag", 400],
      ["disabled-button", "no-drag", 450],
      ["inert-wrapper", "no-drag", 500],
      ["portal-overlay", "no-drag", 550],
      ["focusable", "no-drag", 600],
      ["editable", "no-drag", 650],
      ["input", "no-drag", 700],
      ["unmarked-content", "no-drag", 750, 100],
    ];
    for (const [
      name,
      inputCase,
      x = 300,
      y = 20,
      time = 0,
      maximized,
    ] of cases) {
      await webview.evaluate(
        "window.__chromeInput.events = []; window.__chromeInput.calls = [];",
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
      // Native caption input need not dispatch browser pointer events.
      // Excluded controls must still receive genuine input and never move the window.
      assert.equal(
        observed.calls.some((c) => /\.(gesture|pointer)$/.test(c.command)),
        false,
        "SDK drag must not use the application gesture Bridge",
      );
      if (maximized !== undefined)
        assert.equal(
          native.maximized,
          maximized,
          `${name}: native double-click result`,
        );
      if (inputCase === "no-drag") {
        assert.ok(
          observed.events.some((e) => e.type === "pointerdown" && e.trusted),
          `${name}: excluded content must receive real input`,
        );
        assert.equal(native.maximized, false);
        assert.equal(native.after.Left, native.before.Left);
        assert.equal(native.after.Top, native.before.Top);
      }
      evidence.cases.at(-1).passed = true;
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
