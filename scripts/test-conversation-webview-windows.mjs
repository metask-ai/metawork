// Real WebView2 component acceptance. Host/Bridge/persistence have separate tests.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "vite";
import { buildAutomationDebugArtifact } from "./build.mjs";
import {
  allocateWebViewTestPort,
  connectTestWebView,
} from "./window-top-resize-paint.mjs";

assert.equal(process.platform, "win32");
const root = fileURLToPath(new URL("../", import.meta.url));
await buildAutomationDebugArtifact(root);
const evidence = path.join(root, ".tmp", "conversation-webview-evidence");
await mkdir(evidence, { recursive: true });
const bundle = await build({
  configFile: false,
  root,
  define: { "process.env.NODE_ENV": JSON.stringify("production") },
  build: {
    write: false,
    minify: true,
    lib: {
      entry: path.join(root, "scripts/fixtures/conversation-webview.tsx"),
      name: "ConversationProbe",
      formats: ["iife"],
    },
  },
});
const code = (Array.isArray(bundle) ? bundle[0] : bundle).output.find(
  (item) => item.type === "chunk",
).code;
const fixture = await realpath(
  await mkdtemp(path.join(tmpdir(), "metawork-conversation-webview-")),
);
assert.equal(path.dirname(fixture), await realpath(tmpdir()));
assert.ok(path.basename(fixture).startsWith("metawork-conversation-webview-"));
const port = await allocateWebViewTestPort();
const appCwd = path.join(root, "zig-out", "bin");
const app = spawn(path.join(appCwd, "metawork.exe"), [], {
  cwd: appCwd,
  windowsHide: true,
  stdio: ["ignore", "pipe", "pipe"],
  env: {
    ...process.env,
    APPDATA: fixture,
    LOCALAPPDATA: fixture,
    METAWORK_AUTOMATION: "1",
    METAWORK_AUTOMATION_WORKSPACE: fixture,
    WEBVIEW2_USER_DATA_FOLDER: path.join(fixture, "webview"),
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port} --remote-debugging-address=127.0.0.1`,
  },
});
let diagnostic = "";
app.stdout.on("data", (value) => (diagnostic += value));
app.stderr.on("data", (value) => (diagnostic += value));
const exited = new Promise((resolve) => app.once("exit", resolve));
async function poll(action, label) {
  let last;
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    try {
      const result = await action();
      if (result) return result;
    } catch (error) {
      last = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`${label}: ${last?.message ?? "timed out"}`);
}
let webview;
try {
  webview = await poll(() => connectTestWebView(port), "connect real WebView2");
  await poll(
    () =>
      webview.evaluate("Boolean(document.querySelector('.composer-shell'))"),
    "production shell loaded",
  );
  await poll(
    () =>
      webview.evaluate(`(() => {
      const dialog=document.querySelector('[role=dialog]');
      if(!dialog) return true;
      const skip=[...dialog.querySelectorAll('button')].find(button=>/暂时跳过|Skip for now/i.test(button.textContent));
      if(skip) skip.click();
      return false;
    })()`),
    "dismiss first-run dialog in the isolated profile",
  );
  // Exercise the production App -> scoped Bridge -> Host search before
  // replacing the reading surface with deterministic Conversation fixtures.
  await poll(
    () =>
      webview.evaluate(`(() => {
      const intro=[...document.querySelectorAll('[role=dialog]')].find(dialog=>!dialog.classList.contains('search-dialog'));
      const skip=intro && [...intro.querySelectorAll('button')].find(button=>/暂时跳过|Skip for now/i.test(button.textContent));
      if(skip){skip.click();return false;}
      if(document.querySelector('.search-dialog'))return document.activeElement?.getAttribute('role')==='combobox';
      const button=[...document.querySelectorAll('button[aria-label]')].find(button=>/^(搜索|Search)$/.test(button.getAttribute('aria-label')));
      button?.click();return false;
    })()`),
    "production global search opens after first-run admission and receives focus",
  );
  await webview.send("Input.insertText", {
    text: "no matching history in this isolated profile",
  });
  await poll(
    () =>
      webview.evaluate(
        `!!document.querySelector('.search-dialog input')?.value && !document.querySelector('.search-dialog [role=status]') && document.querySelectorAll('.search-dialog [role=option]').length===0`,
      ),
    "bounded Host search completes without a synchronization failure",
  );
  await webview.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "a",
    code: "KeyA",
    modifiers: 2,
    windowsVirtualKeyCode: 65,
  });
  await webview.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "a",
    code: "KeyA",
    modifiers: 2,
    windowsVirtualKeyCode: 65,
  });
  await webview.send("Input.insertText", { text: "界".repeat(200) });
  await poll(
    () =>
      webview.evaluate(
        `(() => { const input=document.querySelector('.search-dialog input');return input?.value.startsWith('界') && new TextEncoder().encode(input.value).length<=256 && !document.querySelector('.search-dialog [role=status]'); })()`,
      ),
    "production query preserves its Unicode byte bound",
  );
  for (const width of [1320, 390]) {
    await webview.send("Emulation.setDeviceMetricsOverride", {
      width,
      height: 812,
      deviceScaleFactor: 1,
      mobile: false,
    });
    for (const theme of ["light", "dark"]) {
      await webview.evaluate(
        `document.documentElement.dataset.theme=${JSON.stringify(theme)}`,
      );
      assert.equal(
        await webview.evaluate(
          `(() => {const r=document.querySelector('.search-dialog').getBoundingClientRect();return r.left>=-1 && r.right<=innerWidth+1;})()`,
        ),
        true,
      );
      const png = await webview.send("Page.captureScreenshot", {
        format: "png",
        captureBeyondViewport: false,
      });
      await writeFile(
        path.join(evidence, `search-${width}-${theme}.png`),
        Buffer.from(png.data, "base64"),
      );
    }
  }
  await webview.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "Escape",
    code: "Escape",
    windowsVirtualKeyCode: 27,
  });
  await webview.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "Escape",
    code: "Escape",
    windowsVirtualKeyCode: 27,
  });
  await poll(
    () => webview.evaluate(`!document.querySelector('.search-dialog')`),
    "production global search closes without retaining an old page",
  );
  await webview.send("Emulation.setDeviceMetricsOverride", {
    width: 1320,
    height: 812,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await webview.evaluate(code);
  await poll(
    () =>
      webview.evaluate(
        "document.querySelector('#conversation-fixture img')?.naturalWidth === 320",
      ),
    "actual image decoding",
  );
  await webview.evaluate(`(() => {
    const panel=document.querySelector('#conversation-fixture');
    const image=panel.querySelector('.generated-image-preview');
    const user=panel.querySelector('[data-operation-id=blue]');
    const text=panel.querySelector('[data-output-identity] p');
    const range=document.createRange();range.selectNodeContents(text);getSelection().removeAllRanges();getSelection().addRange(range);
    panel.querySelector('textarea').focus();
    const viewport=panel.querySelector('.ai-conversation-viewport');viewport.scrollTop=0;viewport.dispatchEvent(new Event('scroll',{bubbles:true}));
    window.__conversationObserved={image,user,text,selection:getSelection().toString(),top:text.getBoundingClientRect().top};
  })()`);
  for (const stage of ["later", "terminal"]) {
    await webview.evaluate(
      `conversationFixture.render(${JSON.stringify(stage)})`,
    );
    await poll(
      () =>
        webview.evaluate(
          `document.querySelector('#conversation-fixture').innerText.includes('ADJUSTING AFTER INTERJECTION')`,
        ),
      stage,
    );
    const observed = await webview.evaluate(`(() => {
      const panel=document.querySelector('#conversation-fixture'),before=window.__conversationObserved;
      const image=panel.querySelector('.generated-image-preview'),user=panel.querySelector('[data-operation-id=blue]');
      return {sameImage:image===before.image,sameUser:user===before.user,role:image.closest('.ai-message').dataset.role,before:!!(image.compareDocumentPosition(user)&Node.DOCUMENT_POSITION_FOLLOWING),loads:conversationFixture.loads(),selection:getSelection().toString()===before.selection,focus:document.activeElement===panel.querySelector('textarea'),shift:Math.abs(before.text.getBoundingClientRect().top-before.top)};
    })()`);
    assert.deepEqual(
      { ...observed, shift: 0 },
      {
        sameImage: true,
        sameUser: true,
        role: "assistant",
        before: true,
        loads: 1,
        selection: true,
        focus: true,
        shift: 0,
      },
    );
    assert.ok(observed.shift <= 1, JSON.stringify(observed));
  }
  await webview.evaluate("conversationFixture.render('paged')");
  await webview.evaluate(`(() => {
    const panel=document.querySelector('#conversation-fixture'),message=panel.querySelector('[data-reading-id="submission:continue"]');
    const viewport=panel.querySelector('.ai-conversation-viewport');viewport.scrollTop=0;viewport.dispatchEvent(new Event('scroll',{bubbles:true}));
    window.__pageAnchor=message.getBoundingClientRect().top;
  })()`);
  await webview.evaluate("conversationFixture.render('history')");
  await poll(
    () =>
      webview.evaluate(
        `Math.abs(document.querySelector('#conversation-fixture [data-reading-id="submission:continue"]').getBoundingClientRect().top-window.__pageAnchor)<=1`,
      ),
    "history refill preserves message reading anchor",
  );
  const tail = await webview.evaluate(
    `(() => {const panel=document.querySelector('#conversation-fixture'),run=panel.querySelector('[data-run-id="9"]'),message=panel.querySelector('[data-operation-id=continue]'),details=run.querySelector('.run-process');return {copies:panel.innerText.split('CONTINUE AFTER DETAILS').length-1,detailsBefore:!!(details?.compareDocumentPosition(message)&Node.DOCUMENT_POSITION_FOLLOWING)};})()`,
  );
  assert.equal(tail.copies, 1);
  assert.equal(tail.detailsBefore, true);
  await webview.evaluate(
    `document.querySelector('#conversation-fixture .generated-image-preview').scrollIntoView({block:'center'})`,
  );
  for (const width of [1320, 390]) {
    await webview.send("Emulation.setDeviceMetricsOverride", {
      width,
      height: 812,
      deviceScaleFactor: 1,
      mobile: false,
    });
    for (const theme of ["light", "dark"]) {
      await webview.evaluate(
        `document.documentElement.dataset.theme=${JSON.stringify(theme)}`,
      );
      assert.equal(
        await webview.evaluate(
          `document.querySelector('#conversation-fixture').scrollWidth<=innerWidth`,
        ),
        true,
      );
      const png = await webview.send("Page.captureScreenshot", {
        format: "png",
        captureBeyondViewport: false,
      });
      await writeFile(
        path.join(evidence, `${width}-${theme}.png`),
        Buffer.from(png.data, "base64"),
      );
    }
  }
  await webview.evaluate("conversationFixture.invalidate()");
  await poll(
    () =>
      webview.evaluate("!document.querySelector('#conversation-fixture img')"),
    "security invalidation removes image pixels",
  );
  await writeFile(
    path.join(evidence, "result.json"),
    JSON.stringify(
      {
        image:
          "stable assistant; one decode/load across later output and terminal",
        productionBoundedSearchBridge: true,
        unicodeSearchByteBound: true,
        selectionAndFocus: true,
        historyReadingAnchor: true,
        terminalDetailsBeforeContinuation: true,
        securityInvalidation: true,
        widths: [1320, 390],
        themes: ["light", "dark"],
      },
      null,
      2,
    ),
  );
  console.log(
    "Conversation real WebView2 component acceptance passed; no Host image-generation claim. Evidence:",
    evidence,
  );
} finally {
  webview?.close();
  app.kill();
  await exited;
  await writeFile(path.join(evidence, "app.log"), diagnostic);
  // Only this owned, resolved, prefix-checked temporary profile is removed.
  await rm(fixture, {
    recursive: true,
    force: true,
    maxRetries: 10,
    retryDelay: 200,
  });
}
