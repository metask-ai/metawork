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
  hasTask = false,
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
  async function check(
    name,
    action,
    expectedGestures,
    verify = () => {},
    { browserInput = true } = {},
  ) {
    await webview.evaluate(
      "window.__chromeUi.events = []; window.__chromeUi.calls = [];",
    );
    const record = { name, before: await nativeState() };
    evidence.cases.push(record);
    try {
      await action();
      Object.assign(record, await webview.evaluate("window.__chromeUi"));
      record.after = await nativeState();
      // Native caption input can be consumed before WebView dispatch.
      if (browserInput)
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
        menu:document.querySelector('.account-menu')?.outerHTML,
        trigger:document.querySelector('.account-identity-trigger')?.outerHTML,
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
      "document.querySelector('.workbench-commandbar') && document.documentElement.dataset.metaworkWindowChrome === 'ready'",
    );
    const missingExclusions = await webview.evaluate(
      `Array.from(document.querySelectorAll('header[data-native-window-drag] :is(button,input,select,textarea,label,details,summary,a,[contenteditable]:not([contenteditable="false"]),[tabindex],[inert],[role="button"],[role="link"],[role="textbox"])')).filter(e => !e.closest('[data-native-window-drag-exclude]')).map(e => e.outerHTML)`,
    );
    assert.deepEqual(
      missingExclusions,
      [],
      "all titlebar controls need explicit SDK exclusions",
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
      const copy =
        '.message-info-bar[data-role=assistant][data-latest="true"] .message-info-copy';
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
    } else {
      await runProbe("control-layout");
      await until("innerWidth < 950");
      if (hasTask) {
        await businessClick(
          "workbench-select-task",
          ".task-list-item",
          "document.querySelector('.task-list-item[aria-current=page]')",
        );
      }
      const free = await webview.evaluate(`(() => {
        for (let x=160;x<600;x+=10) {
          const e = document.elementFromPoint(x,20);
          if(e?.closest('.workbench-commandbar') && !e.closest('button,input,[tabindex],[data-native-window-drag-exclude]')) return {x,y:20};
        }
        throw new Error('No real noninteractive titlebar point');
      })()`);
      await check(
        "workbench-title-drag",
        () =>
          runProbe("input-case", [
            "-InputCase",
            "drag",
            "-PointX",
            String(free.x),
            "-PointY",
            "20",
          ]),
        [],
        (record) => assert.notEqual(record.after.rect.Left, 100),
        { browserInput: false },
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
      await runProbe("control-layout", ["-ProbeWidth", "390"]);
      await until("innerWidth <= 390");
      evidence.mobileWidth =
        await webview.evaluate(`({width:innerWidth, scrollWidth:document.documentElement.scrollWidth,
        missingExclusions:Array.from(document.querySelectorAll('header[data-native-window-drag] button')).filter(e => !e.closest('[data-native-window-drag-exclude]')).map(e => e.outerHTML)})`);
      assert.ok(
        evidence.mobileWidth.scrollWidth <= evidence.mobileWidth.width,
        "390px window must not overflow horizontally",
      );
      assert.deepEqual(evidence.mobileWidth.missingExclusions, []);
      if (evidenceDir) {
        const shot = await webview.send("Page.captureScreenshot", {
          format: "png",
        });
        await writeFile(
          path.join(evidenceDir, "window-chrome-390.png"),
          Buffer.from(shot.data, "base64"),
        );
      }
      await runProbe("control-layout");
    }
    evidence.surface =
      await webview.evaluate(`({titlebar:document.querySelector('header').className,
      width:innerWidth,height:innerHeight,devicePixelRatio,language:document.documentElement.lang,
      surface:'workbench',hasTask:${hasTask}})`);
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
            : hasTask
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
    `Mounted ${conversation ? "Conversation copy/paste/selection/edit" : hasTask ? "Task Workbench/settings/narrow-window" : "Empty Workbench/settings/narrow-window"} input passed.\n`,
  );
}
