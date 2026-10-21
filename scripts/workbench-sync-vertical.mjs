import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { connectTestWebView } from "./window-top-resize-paint.mjs";
import { invokeWebViewBridge } from "./webview-bridge-probe.mjs";

// A real Host withdrawal while Renderer retains its generation. The probe
// uses only existing commands, mounted UI, and isolated WebView instrumentation.
export async function probeWorkbenchSyncRecovery(port, evidenceDir) {
  const webview = await connectTestWebView(port, { requestTimeoutMs: 15000 });
  async function until(expression) {
    const deadline = Date.now() + 15000;
    do {
      const value = await webview.evaluate(expression);
      if (value) return value;
      await new Promise((resolve) => setTimeout(resolve, 40));
    } while (Date.now() < deadline);
    throw new Error(`Workbench sync probe did not settle: ${expression}`);
  }
  try {
    await webview.send("Page.bringToFront");
    await webview.send("Emulation.setFocusEmulationEnabled", { enabled: true });
    await until(
      `document.querySelector('.sidebar-capability:not(:disabled)') !== null`,
    );
    await webview.evaluate(`(() => {
      [...document.querySelectorAll('.sidebar-capability')].find(e => /Skills|技能/.test(e.textContent)).click();
    })()`);
    await until(
      `document.querySelector('.skill-header-actions button:not(:disabled)') !== null`,
    );
    // Acquiring and withdrawing an independent Host generation avoids assuming
    // a particular numeric generation. Renderer receives no disconnect event.
    const connected = await invokeWebViewBridge(
      webview,
      "metawork.events.connect",
      {
        contractId: "metawork.renderer-bridge",
        contractRevision: 1,
      },
    );
    assert.equal(connected.accepted, true);
    const disconnected = await invokeWebViewBridge(
      webview,
      "metawork.events.disconnect",
      { generation: connected.generation },
    );
    assert.equal(disconnected.detached, true);
    await webview.evaluate(`(() => {
      const transport = window.chrome.webview;
      const post = transport.postMessage;
      window.__syncProbe = { calls: [], statuses: [] };
      window.__syncProbePost = post;
      transport.postMessage = function(message) {
        const envelope = typeof message === 'string' ? JSON.parse(message) : message;
        if (envelope.command) window.__syncProbe.calls.push({ command: envelope.command, payload: envelope.payload });
        return post.call(this, message);
      };
      document.querySelector('.skill-header-actions button:not(:disabled)').click();
    })()`);
    await until(
      `document.querySelector('.commandbar-alert:not([data-recovering="true"])') !== null`,
    );
    const evidence = { hostWithdrawal: connected.generation, cases: [] };
    for (const width of [1320, 390]) {
      await webview.send("Emulation.setDeviceMetricsOverride", {
        width,
        height: 812,
        deviceScaleFactor: 1,
        mobile: false,
      });
      await webview.send("Emulation.setEmulatedMedia", {
        features: [{ name: "prefers-reduced-motion", value: "reduce" }],
      });
      await webview.evaluate(
        `document.querySelector('.commandbar-alert > summary').focus()`,
      );
      for (const type of ["keyDown", "keyUp"])
        await webview.send("Input.dispatchKeyEvent", {
          type,
          key: "Enter",
          code: "Enter",
          windowsVirtualKeyCode: 13,
          ...(type === "keyDown" ? { text: "\r", unmodifiedText: "\r" } : {}),
        });
      const geometry = await until(`(() => {
        const notice = document.querySelector('.commandbar-alert');
        const panel = notice?.querySelector('.commandbar-alert-content');
        if (!notice?.open || !panel) return null;
        const r = panel.getBoundingClientRect();
        const retry = panel.querySelector('button').getBoundingClientRect();
        return { viewport: innerWidth, left: r.left, right: r.right, retryHeight: retry.height,
          overflow: document.documentElement.scrollWidth > innerWidth,
          bodyCards: document.querySelectorAll('.task-sync-failure').length,
          notices: document.querySelectorAll('.commandbar-alert').length,
          name: notice.querySelector('summary').getAttribute('aria-label') };
      })()`);
      assert.ok(geometry.left >= 0 && geometry.right <= geometry.viewport);
      assert.equal(geometry.overflow, false);
      assert.ok(geometry.retryHeight >= 44);
      assert.equal(geometry.bodyCards, 0);
      assert.equal(geometry.notices, 1);
      assert.ok(geometry.name);
      evidence.cases.push({ width, ...geometry });
      await mkdir(evidenceDir, { recursive: true });
      const screenshot = await webview.send("Page.captureScreenshot", {
        format: "png",
      });
      await writeFile(
        join(evidenceDir, `sync-failure-${width}.png`),
        Buffer.from(screenshot.data, "base64"),
      );
      await webview.send("Input.dispatchKeyEvent", {
        type: "keyDown",
        key: "Escape",
        code: "Escape",
        windowsVirtualKeyCode: 27,
      });
      assert.equal(
        await webview.evaluate(
          `document.querySelector('.commandbar-alert').open`,
        ),
        false,
      );
      assert.equal(
        await webview.evaluate(
          `document.activeElement === document.querySelector('.commandbar-alert > summary')`,
        ),
        true,
      );
    }
    await webview.evaluate(`(() => {
      window.__syncProbe.calls = [];
      window.__syncProbeObserver = new MutationObserver(() => {
        const notice = document.querySelector('.commandbar-alert');
        window.__syncProbe.statuses.push({ recovering: notice?.dataset.recovering, text: notice?.querySelector('summary')?.textContent });
      });
      window.__syncProbeObserver.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true });
      const notice = document.querySelector('.commandbar-alert');
      notice.open = true;
      notice.querySelector('.commandbar-alert-content button').click();
    })()`);
    await until(
      `document.querySelector('.commandbar-alert') === null && document.querySelector('.sidebar-capability').disabled === false`,
    );
    const result = await webview.evaluate(`window.__syncProbe`);
    const connectCalls = result.calls.filter(
      (c) => c.command === "metawork.events.connect",
    );
    const reads = result.calls.filter(
      (c) => c.command === "metawork.workbench.snapshot",
    );
    assert.equal(connectCalls.length, 1);
    assert.equal(reads.length, 6);
    const rebuildIndex = result.calls.findIndex(
      (c) => c.command === "metawork.events.connect",
    );
    assert.equal(
      result.calls
        .slice(0, rebuildIndex)
        .filter((c) => c.command === "metawork.workbench.snapshot").length,
      5,
    );
    assert.ok(
      result.calls
        .slice(rebuildIndex)
        .some((c) => c.command === "metawork.workbench.snapshot"),
    );
    assert.ok(result.calls.some((c) => c.command === "metawork.smoke.ping"));
    assert.equal(
      result.calls.filter(
        (c) => c.command.includes("skills") || c.command.includes("tasks"),
      ).length,
      0,
    );
    const firstRecovering = result.statuses.findIndex(
      (s) => s.recovering === "true",
    );
    assert.ok(firstRecovering >= 0);
    assert.equal(
      result.statuses
        .slice(firstRecovering)
        .some((s) => s.recovering === "false" && s.text),
      false,
    );
    Object.assign(evidence, result);
    await writeFile(
      join(evidenceDir, "sync-recovery.json"),
      JSON.stringify(evidence, null, 2),
    );
    process.stdout.write(
      `Workbench real Host withdrawal recovery passed: ${JSON.stringify(evidence.cases)}\n`,
    );
  } catch (error) {
    await mkdir(evidenceDir, { recursive: true });
    const observation = await webview
      .evaluate(
        `({ focused: document.hasFocus(), failure: document.querySelector(".connection-failure-content")?.textContent, active: document.activeElement?.outerHTML, notices: [...document.querySelectorAll(".commandbar-alert")].map(e => ({ open: e.open, html: e.outerHTML })), probe: window.__syncProbe })`,
      )
      .catch(() => null);
    await writeFile(
      join(evidenceDir, "sync-failure-debug.json"),
      JSON.stringify({ error: String(error), observation }, null, 2),
    );
    throw error;
  } finally {
    await webview
      .evaluate(
        `(() => {
      window.__syncProbeObserver?.disconnect();
      if (window.__syncProbePost) window.chrome.webview.postMessage = window.__syncProbePost;
      delete window.__syncProbe; delete window.__syncProbeObserver; delete window.__syncProbePost;
    })()`,
      )
      .catch(() => undefined);
    await webview
      .send("Emulation.clearDeviceMetricsOverride")
      .catch(() => undefined);
    webview.close();
  }
}
