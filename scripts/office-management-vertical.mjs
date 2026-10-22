import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { connectTestWebView } from "./window-top-resize-paint.mjs";
import { invokeWebViewBridge } from "./webview-bridge-probe.mjs";

// Real unpublished-release App path only. Positive install states are covered
// separately; this probe never inserts a development package into Main trust.
export async function probeOfficeManagement(port, evidenceDir) {
  const webview = await connectTestWebView(port, { requestTimeoutMs: 15000 });
  const evidence = {
    cases: [],
    scope: "actual App; no published Office release",
  };
  async function until(expression) {
    const deadline = Date.now() + 15000;
    do {
      const value = await webview.evaluate(expression);
      if (value) return value;
      await new Promise((resolve) => setTimeout(resolve, 40));
    } while (Date.now() < deadline);
    throw Error(`Office desktop state did not settle: ${expression}`);
  }
  async function openSettings() {
    await until(`document.querySelector('.account-identity button') !== null`);
    await webview.evaluate(
      `document.querySelector('.account-identity button').click()`,
    );
    await until(`document.querySelector('.account-menu-item') !== null`);
    await webview.evaluate(`(() => {
      const item = [...document.querySelectorAll('.account-menu-item')].find(e => /Settings|设置/.test(e.textContent));
      if (!item) throw Error('Settings menu missing'); item.click();
    })()`);
    await until(
      `document.querySelector('[data-office-component]') !== null && /Not installed|未安装/.test(document.querySelector('.settings-office-status').textContent)`,
    );
  }
  try {
    await webview.send("Page.enable");
    await webview.send("Page.addScriptToEvaluateOnNewDocument", {
      source: `
      window.__officeProbeErrors = [];
      addEventListener('error', e => window.__officeProbeErrors.push(e.message));
      addEventListener('unhandledrejection', e => window.__officeProbeErrors.push(String(e.reason)));
    `,
    });
    await webview.send("Page.bringToFront");
    await webview.send("Emulation.setFocusEmulationEnabled", { enabled: true });
    await openSettings();
    const denied = await invokeWebViewBridge(
      webview,
      "metawork.office.install",
      { expectedGeneration: "1" },
    );
    assert.equal(denied.accepted, false);
    const unpublished = await invokeWebViewBridge(
      webview,
      "metawork.office.install",
      { expectedGeneration: denied.generation },
    );
    assert.equal(unpublished.accepted, false);
    assert.equal(unpublished.reason, "unpublished");
    assert.equal(unpublished.operationId, null);
    evidence.install = unpublished;
    await assert.rejects(
      invokeWebViewBridge(webview, "metawork.office.install", {
        expectedGeneration: unpublished.generation,
        url: "https://example.invalid/",
      }),
    );
    for (const [action, reason] of [
      ["repair", "unpublished"],
      ["remove", "not_installed"],
      ["cleanup", "nothing_to_clean"],
      ["retry", "not_needed"],
    ]) {
      const result = await invokeWebViewBridge(
        webview,
        `metawork.office.${action}`,
        { expectedGeneration: unpublished.generation },
      );
      assert.equal(result.accepted, false);
      assert.equal(result.reason, reason);
    }
    const cancel = await invokeWebViewBridge(
      webview,
      "metawork.office.cancel",
      { operationId: "1" },
    );
    assert.equal(cancel.accepted, false);
    assert.equal(cancel.reason, "too_late");
    await webview.evaluate(`(() => {
      window.__officeCalls = [];
      const transport = chrome.webview, post = transport.postMessage;
      transport.postMessage = function(message) {
        const e = typeof message === 'string' ? JSON.parse(message) : message;
        if (e.command?.startsWith('metawork.office.')) window.__officeCalls.push(e.command);
        return post.call(this, message);
      };
    })()`);
    await mkdir(evidenceDir, { recursive: true });
    for (const width of [1320, 390]) {
      await webview.send("Emulation.setDeviceMetricsOverride", {
        width,
        height: 900,
        deviceScaleFactor: 1,
        mobile: false,
      });
      for (const theme of ["light", "dark"]) {
        await webview.send("Emulation.setEmulatedMedia", {
          features: [{ name: "prefers-reduced-motion", value: "reduce" }],
        });
        await webview.evaluate(
          `document.documentElement.dataset.theme=${JSON.stringify(theme)}`,
        );
        await until(
          `getComputedStyle(document.querySelector('.settings-page')).backgroundColor === ${JSON.stringify(theme === "dark" ? "rgb(18, 20, 27)" : "rgb(255, 255, 255)")}`,
        );
        const geometry = await webview.evaluate(`(async () => {
          const group = document.querySelector('[data-office-component]'); group.scrollIntoView({ block: 'center' });
          await new Promise(requestAnimationFrame);
          const box = group.getBoundingClientRect(); const button = group.querySelector('h3'); button.focus();
          const style = getComputedStyle(button);
          return { width: innerWidth, left: box.left, right: box.right, height: box.height,
            overflow: document.documentElement.scrollWidth > innerWidth,
            actions: group.querySelectorAll('button').length, focused: document.activeElement === button,
            outlineStyle: style.outlineStyle, outlineWidth: style.outlineWidth,
            background: getComputedStyle(document.querySelector('.settings-page')).backgroundColor,
            panelToken: getComputedStyle(group).getPropertyValue('--ui-surface-panel'), theme: document.documentElement.dataset.theme,
            reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
            body: group.textContent, shape: [...group.querySelectorAll('*')].map(e => e.tagName).join(',') };
        })()`);
        assert.equal(geometry.width, width);
        assert.equal(geometry.overflow, false);
        assert.ok(geometry.left >= 0 && geometry.right <= width);
        assert.ok(geometry.focused && geometry.reducedMotion);
        assert.equal(geometry.actions, 0);
        assert.match(geometry.body, /DOCX.*XLSX.*PPTX/);
        assert.match(geometry.body, /not yet published|尚未发布/);
        const screenshot = await webview.send("Page.captureScreenshot", {
          format: "png",
        });
        await writeFile(
          join(evidenceDir, `office-${width}-${theme}.png`),
          Buffer.from(screenshot.data, "base64"),
        );
        evidence.cases.push({ width, theme, ...geometry });
      }
      const pair = evidence.cases.slice(-2);
      assert.equal(pair[0].shape, pair[1].shape);
      assert.notEqual(pair[0].background, pair[1].background);
    }
    assert.deepEqual(await webview.evaluate(`window.__officeCalls`), []);
    await webview.send("Page.reload", { ignoreCache: true });
    await openSettings();
    evidence.afterReload = await webview.evaluate(
      `document.querySelector('[data-office-component]').textContent`,
    );
    assert.match(evidence.afterReload, /not yet published|尚未发布/);
    assert.deepEqual(await webview.evaluate(`window.__officeProbeErrors`), []);
    await writeFile(
      join(evidenceDir, "office-management.json"),
      JSON.stringify(evidence, null, 2),
    );
    return evidence;
  } catch (error) {
    await mkdir(evidenceDir, { recursive: true });
    await writeFile(
      join(evidenceDir, "office-failure.json"),
      JSON.stringify(
        await webview.evaluate(
          `({ url: location.href, ready: document.readyState, body: document.body.innerText, errors: window.__officeProbeErrors ?? [], html: document.documentElement.outerHTML.slice(0, 16000) })`,
        ),
        null,
        2,
      ),
    );
    const screenshot = await webview.send("Page.captureScreenshot", {
      format: "png",
    });
    await writeFile(
      join(evidenceDir, "office-failure.png"),
      Buffer.from(screenshot.data, "base64"),
    );
    throw error;
  } finally {
    webview.close();
  }
}
