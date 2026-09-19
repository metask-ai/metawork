// Exercise mounted product UI, not a substitute DOM fixture. CDP only reads
// layout/state and installs test observers; the Win32 probe supplies input.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { connectTestWebView } from "./window-top-resize-paint.mjs";

export async function probeWindowChromeUi({
  port,
  runProbe,
  evidenceDir,
  workbench = false,
  conversation = false,
}) {
  const webview = await connectTestWebView(port);
  const originalPixelRatio = await webview.evaluate("devicePixelRatio");
  const evidence = {
    runtime: await webview.send("Browser.getVersion"),
    cases: [],
    unverified: ["all dynamic action variants", "browser zoom", "mixed DPI"],
  };
  async function until(expression) {
    const deadline = Date.now() + 10_000;
    do {
      const value = await webview.evaluate(expression);
      if (value) return value;
      await new Promise((resolve) => setTimeout(resolve, 40));
    } while (Date.now() < deadline);
    throw new Error(`Product UI did not settle: ${expression}`);
  }
  const nativeState = async () => JSON.parse(await runProbe("control-state"));
  async function point(selector) {
    return until(`(() => {
      const element = [...document.querySelectorAll(${JSON.stringify(selector)})]
        .find(e => e.getClientRects().length && !e.disabled);
      if (!element || !element.getClientRects().length) return null;
      const r = element.getBoundingClientRect();
      const x = Math.round(r.x + r.width / 2), y = Math.round(r.y + r.height / 2);
      return element.contains(document.elementFromPoint(x,y)) ? {x,y} : null;
    })()`);
  }
  async function check(name, action, expectedGestures, verify = () => {}) {
    await webview.evaluate(
      "window.__chromeUi.events = []; window.__chromeUi.calls = [];",
    );
    const record = { name, before: await nativeState() };
    evidence.cases.push(record);
    try {
      await action();
      Object.assign(record, await webview.evaluate("window.__chromeUi"));
      record.after = await nativeState();
      assert.ok(
        record.events.some((e) => e.type === "pointerdown" && e.trusted),
      );
      assert.deepEqual(
        record.calls
          .filter((c) => c.command.endsWith(".gesture"))
          .map((c) => c.payload.action),
        expectedGestures,
      );
      await verify(record);
      record.passed = true;
    } catch (error) {
      Object.assign(record, await webview.evaluate("window.__chromeUi"));
      record.surface = await webview.evaluate(`({
        menu:document.querySelector('.account-gate-locale-menu')?.outerHTML,
        trigger:document.querySelector('.account-gate-locale-trigger')?.outerHTML,
        dialog:document.querySelector('.about-dialog')?.outerHTML,
      })`);
      record.passed = false;
      record.failure = String(error);
      throw error;
    }
  }
  async function click(selector) {
    const p = await point(selector);
    evidence.lastClick = { selector, ...p };
    const zoom =
      (await webview.evaluate("devicePixelRatio")) / originalPixelRatio;
    await runProbe("control-click", [
      "-PointX",
      String(Math.round(p.x * zoom)),
      "-PointY",
      String(Math.round(p.y * zoom)),
    ]);
  }
  async function businessClick(name, selector, settled) {
    await check(
      name,
      async () => {
        await click(selector);
        await until(`Boolean(${settled})`);
      },
      [],
      (record) => {
        assert.deepEqual(record.after.rect, record.before.rect);
        assert.equal(record.after.maximized, record.before.maximized);
        assert.equal(
          record.calls.filter((c) => c.command.endsWith(".control")).length,
          0,
        );
      },
    );
  }
  try {
    await until(
      `document.querySelector(${JSON.stringify(workbench ? ".workbench-commandbar" : ".account-gate-toolbar")}) && document.documentElement.dataset.metaworkWindowChrome === 'ready'`,
    );
    await webview.evaluate(`(() => {
      window.__chromeUi = {events:[],calls:[]};
      const observe = event => {
        const record = {
        type:event.type, detail:event.detail, trusted:event.isTrusted,
        x:event.clientX,y:event.clientY,
        path:event.composedPath().filter(e=>e.tagName).map(e=>e.tagName + '.' + String(e.className)),
        };
        window.__chromeUi.events.push(record);
        setTimeout(() => { record.defaultPrevented = event.defaultPrevented; }, 0);
      };
      for (const name of ['pointerdown','mousedown','click']) window.addEventListener(name,observe,true);
      const transport = window.chrome.webview, post = transport.postMessage;
      transport.postMessage = function(message) {
        const envelope = JSON.parse(message);
        if (envelope.command?.includes('windowChrome')) window.__chromeUi.calls.push(envelope);
        return post.call(this,message);
      };
      window.__chromeUiCleanup = () => {
        transport.postMessage = post;
        for (const name of ['pointerdown','mousedown','click']) window.removeEventListener(name,observe,true);
      };
    })()`);
    if (conversation) {
      const copy = '.response-copy-action[data-latest="true"]';
      const editor = ".ai-composer textarea";
      const expected = "metawork agentcore vertical complete";
      evidence.unverified = [
        "clipboard HTML semantics and large payloads",
        "mouse-drag text selection",
        "mixed DPI",
      ];
      await until(
        `document.querySelector('${copy}') && !document.querySelector('${editor}')?.disabled`,
      );
      assert.equal(
        await webview.evaluate(`document.querySelector('${editor}').value`),
        "",
        "Only an empty isolated draft may be edited",
      );
      await webview.evaluate(
        `document.querySelector('${copy}').scrollIntoView({block:'center'})`,
      );
      await businessClick(
        "conversation-copy-response",
        copy,
        `document.querySelector('${copy}').dataset.copyState === 'copied'`,
      );
      const copied = evidence.cases.at(-1);
      assert.ok(
        copied.events
          .filter((e) => ["pointerdown", "mousedown", "click"].includes(e.type))
          .every((e) => e.defaultPrevented === false),
        "Copy input must not be cancelled",
      );
      await check(
        "conversation-paste-select-clear",
        async () => {
          await click(editor);
          await until(
            `document.activeElement === document.querySelector('${editor}')`,
          );
          await runProbe("control-paste-select");
          const draft = await until(`(() => {
          const e = document.querySelector('${editor}');
          return e.value && e.selectionStart === 0 && e.selectionEnd === e.value.length
            ? {value:e.value,start:e.selectionStart,end:e.selectionEnd} : null;
        })()`);
          evidence.draft = draft;
          assert.equal(
            draft.value,
            expected,
            "Real clipboard paste must match the fixture response",
          );
          await runProbe("control-clear-selection");
          await until(`document.querySelector('${editor}').value === ''`);
        },
        [],
        (record) => {
          assert.deepEqual(record.after.rect, record.before.rect);
          assert.equal(
            record.calls.filter((c) => c.command.endsWith(".control")).length,
            0,
          );
          assert.ok(
            record.events
              .filter((e) =>
                ["pointerdown", "mousedown", "click"].includes(e.type),
              )
              .every((e) => e.defaultPrevented === false),
            "Editor input must not be cancelled",
          );
        },
      );
    } else if (workbench) {
      await runProbe("control-layout");
      await until("innerWidth < 950");
      await businessClick(
        "workbench-select-task",
        ".task-list-item",
        "document.querySelector('.task-list-item[aria-current=page]')",
      );
      const free = await webview.evaluate(`(() => {
        for (let x=160;x<600;x+=10) {
          const e = document.elementFromPoint(x,20);
          if(e?.closest('.workbench-commandbar') && !e.closest('button,input,[tabindex],[data-metawork-window-drag-exclude]')) return {x,y:20};
        }
        throw new Error('No real noninteractive titlebar point');
      })()`);
      await check(
        "workbench-title-drag",
        () =>
          runProbe("input-case", [
            "-BrowserGesture",
            "-InputCase",
            "drag",
            "-PointX",
            String(free.x),
            "-PointY",
            "20",
          ]),
        ["start_drag"],
        (record) => assert.notEqual(record.after.rect.Left, 100),
      );
      const panel = ".commandbar-task-panel-toggle";
      const expanded = await webview.evaluate(
        `document.querySelector('${panel}').getAttribute('aria-expanded')`,
      );
      await businessClick(
        "workbench-task-panel-action",
        panel,
        `document.querySelector('${panel}').getAttribute('aria-expanded') !== ${JSON.stringify(expanded)}`,
      );
      await businessClick(
        "workbench-task-panel-restore",
        panel,
        `document.querySelector('${panel}').getAttribute('aria-expanded') === ${JSON.stringify(expanded)}`,
      );
      await businessClick(
        "workbench-account-menu",
        ".account-identity-trigger",
        "document.querySelector('.account-identity-trigger').getAttribute('aria-expanded') === 'true'",
      );
      await businessClick(
        "workbench-settings-open",
        ".account-menu-item:has(.lucide-settings)",
        "Boolean(document.querySelector('.settings-page'))",
      );
      await check(
        "workbench-settings-inert-titlebar",
        () => click(".commandbar-leading-actions"),
        [],
        (record) => assert.deepEqual(record.after.rect, record.before.rect),
      );
      await businessClick(
        "workbench-settings-close",
        ".settings-back",
        "!document.querySelector('.settings-page')",
      );
      await runProbe("control-layout", ["-ProbeWidth", "600"]);
      evidence.narrowWidth = await webview.evaluate("innerWidth");
      await businessClick(
        "workbench-narrow-panel-action",
        panel,
        `document.querySelector('${panel}').getAttribute('aria-expanded') !== ${JSON.stringify(expanded)}`,
      );
      await businessClick(
        "workbench-narrow-panel-restore",
        panel,
        `document.querySelector('${panel}').getAttribute('aria-expanded') === ${JSON.stringify(expanded)}`,
      );
      await runProbe("control-layout");
    } else {
      // The input driver establishes 900x620 before each sequence. Title text is
      // left anchored in the real AccountGate and stays at the measured point.
      const title = await point(".account-gate-brand > span:last-child");
      assert.ok(
        title.y < 40,
        "Title text must intersect the native authorization band",
      );
      await check(
        "account-title-text-drag",
        () =>
          runProbe("input-case", [
            "-BrowserGesture",
            "-InputCase",
            "drag",
            "-PointX",
            String(title.x),
            "-PointY",
            String(title.y),
          ]),
        ["start_drag"],
        (record) => {
          assert.notEqual(record.after.rect.Left, 100);
          assert.ok(
            record.events.some(
              (e) => e.type === "mousedown" && e.path[0].startsWith("SPAN."),
            ),
          );
        },
      );
      await check(
        "account-title-text-double-click",
        () =>
          runProbe("input-case", [
            "-BrowserGesture",
            "-InputCase",
            "pair",
            "-PointX",
            String(title.x),
            "-PointY",
            String(title.y),
          ]),
        ["start_drag", "toggle_maximize"],
        (record) => assert.equal(record.after.maximized, true),
      );
      await click('[data-metawork-window-control="toggle_maximize"]');
      await until(
        "document.documentElement.dataset.metaworkWindowMaximized === 'false'",
      );
      await businessClick(
        "account-language-menu-open",
        ".account-gate-locale-trigger",
        "document.querySelector('.account-gate-locale-trigger').getAttribute('aria-expanded') === 'true'",
      );
      await businessClick(
        "account-language-portal-choice",
        ".account-gate-locale-menu .selection-menu-item",
        "document.querySelector('.account-gate-locale-trigger').getAttribute('aria-expanded') === 'false'",
      );
      await businessClick(
        "account-about-open",
        ".account-gate-about",
        "document.querySelector('.about-dialog:not([data-closed])')",
      );
      await check(
        "account-modal-body",
        () => click(".about-dialog-build code"),
        [],
        (record) => {
          assert.deepEqual(record.after.rect, record.before.rect);
          assert.ok(
            record.events
              .filter((e) => e.type === "mousedown")
              .every((e) => !e.path.some((p) => p.startsWith("HEADER."))),
          );
        },
      );
      await businessClick(
        "account-about-close",
        ".about-dialog-close",
        "!document.querySelector('.about-dialog:not([data-closed])')",
      );
      try {
        await runProbe("control-zoom-in");
        await until(`devicePixelRatio > ${originalPixelRatio}`);
        evidence.zoom = await webview.evaluate("devicePixelRatio");
        await businessClick(
          "account-zoomed-language-menu",
          ".account-gate-locale-trigger",
          "document.querySelector('.account-gate-locale-trigger').getAttribute('aria-expanded') === 'true'",
        );
        await businessClick(
          "account-zoomed-language-choice",
          ".account-gate-locale-menu .selection-menu-item",
          "document.querySelector('.account-gate-locale-trigger').getAttribute('aria-expanded') === 'false'",
        );
        evidence.unverified = evidence.unverified.filter(
          (item) => item !== "browser zoom",
        );
      } finally {
        await runProbe("control-zoom-reset");
        await until(`devicePixelRatio === ${originalPixelRatio}`);
      }
    }
    evidence.surface =
      await webview.evaluate(`({titlebar:document.querySelector('header').className,
      width:innerWidth,height:innerHeight,devicePixelRatio,language:document.documentElement.lang,
      readiness:document.querySelector('.account-gate')?.dataset.readiness ?? 'workbench'})`);
    evidence.passed = true;
  } catch (error) {
    evidence.passed = false;
    evidence.failure = String(error);
    throw error;
  } finally {
    if (evidenceDir) {
      await mkdir(evidenceDir, { recursive: true });
      await writeFile(
        path.join(
          evidenceDir,
          conversation
            ? "window-chrome-conversation.json"
            : workbench
              ? "window-chrome-workbench.json"
              : "window-chrome-ui.json",
        ),
        JSON.stringify(evidence, null, 2),
      );
    }
    await webview.evaluate("window.__chromeUiCleanup?.()").catch(() => {});
    webview.close();
  }
  process.stdout.write(
    `Mounted ${conversation ? "Conversation copy/paste/selection/edit" : workbench ? "Workbench/settings/narrow-window" : "AccountGate title/language/About modal"} input passed.\n`,
  );
}
