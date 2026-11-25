import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { mkdir, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { crc32, deflateRawSync } from "node:zlib";
import { enUS } from "../frontend/src/i18n/messages/en-US.ts";
import { zhCN } from "../frontend/src/i18n/messages/zh-CN.ts";

function officeWordFixture() {
  const documentType =
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml";
  const wordNamespace =
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
  const entries = {
    "[Content_Types].xml": `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="${documentType}"/></Types>`,
    "_rels/.rels":
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
    "word/document.xml": `<w:document xmlns:w="${wordNamespace}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>
      <w:p><w:r><w:t>MetaWork original fixture</w:t></w:r></w:p>
      <w:p><w:hyperlink r:id="rId1"><w:r><w:t>Example hyperlink</w:t></w:r></w:hyperlink></w:p>
      <w:p><w:fldSimple w:instr="PAGE"><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p>
      <w:p><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>TOC</w:instrText></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
    </w:body></w:document>`,
    "word/_rels/document.xml.rels":
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.invalid" TargetMode="External"/></Relationships>',
  };
  const local = [];
  const central = [];
  let offset = 0;
  for (const [entry, value] of Object.entries(entries)) {
    const name = Buffer.from(entry);
    const data = Buffer.from(value);
    const compressed = deflateRawSync(data);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(8, 8);
    header.writeUInt32LE(crc32(data), 14);
    header.writeUInt32LE(compressed.length, 18);
    header.writeUInt32LE(data.length, 22);
    header.writeUInt16LE(name.length, 26);
    const record = Buffer.alloc(46);
    record.writeUInt32LE(0x02014b50);
    record.writeUInt16LE(20, 4);
    header.copy(record, 6, 4, 30);
    record.writeUInt32LE(offset, 42);
    local.push(header, name, compressed);
    central.push(record, name);
    offset += header.length + name.length + compressed.length;
  }
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(central.length / 2, 8);
  end.writeUInt16LE(central.length / 2, 10);
  end.writeUInt32LE(
    central.reduce((length, part) => length + part.length, 0),
    12,
  );
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, ...central, end]);
}

// The opened local page reports its URL after loading a sibling stylesheet
// and handling a click. The listener serves no Workspace files.
async function prepareBrowserFixture(workspaceRoot, relative, poll) {
  const token = randomUUID();
  let observation;
  const server = createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    if (url.pathname === "/" + token) {
      observation = Object.fromEntries(url.searchParams);
      observation.userAgent = request.headers["user-agent"];
    }
    response.writeHead(204).end();
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const stylesheet = token + ".css";
  try {
    await writeFile(
      path.join(workspaceRoot, path.dirname(relative), stylesheet),
      "h1 { color: rgb(1, 41, 81); }",
    );
  } catch (error) {
    server.close();
    throw error;
  }
  const endpoint = "http://127.0.0.1:" + server.address().port + "/" + token;
  const content = `<!doctype html><title>MetaWork browser file</title><link rel="stylesheet" href="${stylesheet}">
<h1>Static report from outputs</h1><button>Initial</button>
<script>
window.addEventListener("load", () => {
  const button = document.querySelector("button");
  button.addEventListener("click", () => { button.textContent = "Clicked"; });
  button.click();
  const params = new URLSearchParams({
    href: location.href,
    color: getComputedStyle(document.querySelector("h1")).color,
    text: button.textContent,
  });
  new Image().src = ${JSON.stringify(endpoint)} + "?" + params;
});
</script>`;
  return {
    content,
    observed: () => observation,
    async verify() {
      const result = await poll(
        () => observation,
        20_000,
        "Browser rendering the Workspace original",
      );
      assert.equal(
        fileURLToPath(result.href),
        path.join(workspaceRoot, relative),
      );
      assert.equal(result.color, "rgb(1, 41, 81)");
      assert.equal(result.text, "Clicked");
      assert.match(result.userAgent, /\b(?:Chrome|Edg|Firefox|Safari)\//);
      return result;
    },
    close: () => server.close(),
  };
}

// Real App/Core/Renderer; only Provider replies are scripted. Drive the normal
// Composer so a second snapshot reader cannot starve the window's one current
// snapshot. Read verification snapshots only after the UI has settled.
export async function runOutputDeliveryVertical({
  workspaceRoot,
  workspaceId,
  workspaceEpoch,
  catalog,
  invoke,
  snapshot,
  poll,
  provider,
  toolSse,
  textSse,
  nativeOutputProbe,
  nativeExistingActions = true,
  connectWebView,
  restart,
  evidenceDirectory,
}) {
  const relative = "results/交付 output 中文.txt";
  await mkdir(path.join(workspaceRoot, "results"), { recursive: true });
  const source = path.join(workspaceRoot, relative);
  const content = "MetaWork delivered output 中文\n";
  const bytes = Buffer.from(content);
  const digest = createHash("sha256").update(bytes).digest("hex");
  const evidence = {
    scope:
      "Real Windows App/Core/Renderer; fixture Provider, not remote-model quality or native Save As gestures",
    states: [],
  };
  const labels = (key) => [enUS[key], zhCN[key]];
  let webview;
  let browser;
  async function audit() {
    await webview.evaluate(`(() => {
      window.__outputInputs = []; window.__outputActions = [];
      const transport = window.chrome.webview, post = transport.postMessage;
      transport.postMessage = function(message) {
        const envelope = typeof message === 'string' ? JSON.parse(message) : message;
        if (envelope.command === 'metawork.tasks.sendInput') window.__outputInputs.push(envelope.payload);
        if (envelope.command === 'metawork.files.action') window.__outputActions.push(envelope.payload);
        return post.call(transport, message);
      };
    })()`);
  }
  try {
    const modelSnapshot = await snapshot();
    const created = await invoke("metawork.tasks.create", {
      projectId: null,
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },

      modelSelection: fixtureModelSelection(modelSnapshot),
      expectedSkillCatalogRevision: catalog.revision,
      expectedSkillSelectionRevision: catalog.selectionRevision,
      approvalMode: "full_access",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    const taskId = created.taskId;
    evidence.taskId = taskId;
    await invoke("metawork.tasks.rename", {
      taskId,
      title: "Output delivery audit",
    });
    const task = async () =>
      (await snapshot()).tasks.find((item) => item.id === taskId);
    async function select() {
      await poll(
        () =>
          webview.evaluate(`(() => {
        const row = [...document.querySelectorAll('.task-list-item')].find(item => item.dataset.taskId === ${JSON.stringify(taskId)});
        if (!row) return false;
        if (row.getAttribute('aria-current') !== 'page') { row.click(); return false; }
        return Boolean(document.querySelector('.composer-shell textarea:not(:disabled)'));
      })()`),
        20_000,
        "Output Task selected",
      );
    }
    async function attach() {
      webview = await connectWebView();
      await audit();
      await select();
    }
    await attach();
    async function run(label, marker, fixtures) {
      provider.enqueue(...fixtures);
      await select();
      const before = await webview.evaluate(`window.__outputInputs.length`);
      await webview.evaluate(
        `document.querySelector('.composer-shell textarea').focus()`,
      );
      await webview.send("Input.insertText", { text: label });
      await poll(
        () =>
          webview.evaluate(
            `Boolean(document.querySelector('.composer-send:not(:disabled)'))`,
          ),
        5000,
        "Output input enabled",
      );
      await webview.evaluate(
        `document.querySelector('.composer-send').click()`,
      );
      const input = await poll(
        () => webview.evaluate(`window.__outputInputs[${before}] ?? null`),
        10_000,
        "Output input submitted once",
      );
      assert.equal(input.taskId, taskId);
      await poll(
        () => {
          if (provider.error) throw provider.error;
          return webview.evaluate(
            `document.body.innerText.includes(${JSON.stringify(marker)}) && document.querySelector('.composer-stop') === null`,
          );
        },
        40_000,
        `Output ${label} rendered and settled`,
      );
      assert.equal(
        await webview.evaluate(`window.__outputInputs.length`),
        before + 1,
      );
      const settled = (await task()).runs.find(
        (item) => item.submission?.operationId === input.operationId,
      );
      assert.equal(
        settled?.terminal?.outcome,
        "completed",
        JSON.stringify(settled?.terminal),
      );
      return settled;
    }
    const ordinary = await run(
      "Create and read a file without delivering it",
      "OUTPUT_CREATED_ONLY",
      [
        toolSse("output-write", "output-write", "Write", {
          file_path: source,
          content,
        }),
        toolSse("output-read", "output-read", "Read", { file_path: source }),
        textSse(
          "output-link",
          `[Finished file](${source.replaceAll("\\", "/")}) OUTPUT_CREATED_ONLY`,
        ),
      ],
    );
    assert.deepEqual(await readFile(source), bytes);
    assert.equal(ordinary.outputs.length, 0);
    assert.ok(
      ordinary.fileChanges?.changes.some((item) => item.kind === "created"),
    );
    evidence.ordinaryRunId = ordinary.id;
    let receipt;
    const delivered = await run(
      "Explicitly deliver the checked file",
      "OUTPUT_DELIVERED",
      [
        toolSse("output-delivery", "output-delivery", "DeliverFile", {
          path: relative,
        }),
        (payload) => {
          const results = payload.messages
            .flatMap((message) =>
              Array.isArray(message.content) ? message.content : [],
            )
            .filter(
              (block) =>
                block.type === "tool_result" &&
                block.tool_use_id === "output-delivery",
            );
          assert.equal(results.length, 1);
          const value = results[0].content;
          const text =
            typeof value === "string"
              ? value
              : value.map((block) => block.text ?? "").join("");
          receipt = JSON.parse(text);
          assert.equal(receipt.status, "delivered");
          assert.equal(receipt.sha256, digest);
          assert.equal(receipt.size_bytes, bytes.length);
          assert.equal(receipt.path, relative);
          return textSse("output-done", "OUTPUT_DELIVERED");
        },
      ],
    );
    assert.ok(receipt);
    assert.equal(delivered.outputs.length, 1);
    const output = delivered.outputs[0];
    assert.match(output.id, /^[a-f0-9]{32}$/u);
    assert.equal(output.id, receipt.delivery_id);
    assert.equal(output.sizeBytes, String(bytes.length));
    assert.equal(output.redacted, false);
    assert.ok(output.displayPath.endsWith(relative));
    evidence.deliveredRunId = delivered.id;
    evidence.output = output;
    evidence.receiptSha256 = digest;
    const outsideName = `output-outside-${taskId}.txt`;
    const outside = path.join(path.dirname(workspaceRoot), outsideName);
    await writeFile(outside, "Existing outside Workspace file", { flag: "wx" });
    const rejected = await run(
      "Reject an escaping delivery path",
      "OUTPUT_REJECTED",
      [
        toolSse("output-reject", "output-reject", "DeliverFile", {
          path: `../${outsideName}`,
        }),
        textSse("output-rejected", "OUTPUT_REJECTED"),
      ],
    );
    assert.equal(rejected.outputs.length, 0);
    assert.equal(
      await readFile(outside, "utf8"),
      "Existing outside Workspace file",
    );
    evidence.escapingDeliveryRejected = true;
    const callsBeforeChecks = provider.requests.length;
    async function clickLabel(labels, selector = "button") {
      await poll(
        () =>
          webview.evaluate(`(() => {
        const button = [...document.querySelectorAll(${JSON.stringify(selector)})].findLast(item => !item.disabled && ${JSON.stringify(labels)}.some(label => item.textContent.trim().includes(label)));
        if (!button) return false;
        button.click(); return true;
      })()`),
        15_000,
        `Output button ${labels[0]}`,
      );
    }
    // Its row in the outputs list of the right panel.
    const listed = (id) => `.run-output[data-output-id="${id}"]`;
    // Its card in the reply.
    const card = (id) => `.run-files [data-output-id="${id}"] .file-card`;
    const statusOf = (id, list) =>
      list
        ? `document.querySelector(${JSON.stringify(listed(id))})?.querySelector('.run-output-status')`
        : `[...document.querySelectorAll(${JSON.stringify(card(id))})].at(-1)?.closest('.file-menu-scope')?.querySelector('.file-menu-status p')`;
    async function showMenu(id) {
      await poll(
        () =>
          webview.evaluate(`(() => {
        const card = [...document.querySelectorAll(${JSON.stringify(card(id))})].at(-1);
        card?.scrollIntoView({ block: 'center' });
        if (!card || card.dataset.pending) return false;
        const box = card.getBoundingClientRect();
        card.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: box.left + 8, clientY: box.top + 8 }));
        return true;
      })()`),
        20_000,
        "Delivered file card",
      );
      const items = await poll(
        () =>
          webview.evaluate(`(() => {
        const items = [...document.querySelectorAll('.file-menu [role="menuitem"]')];
        return items.length > 0 ? items.map(item => item.textContent.trim()) : null;
      })()`),
        5000,
        "Delivered file menu",
      );
      assert.equal(items.length, 5);
      for (const [index, key] of [
        "open",
        "reveal",
        "edit",
        "copy_path",
        "save",
      ].entries())
        assert.ok(
          labels(`outputs.${key}`).includes(items[index]),
          items[index],
        );
    }
    // `check` is in the outputs list; everything else is in the file's menu.
    // A file that was opened or shown in its folder answers for itself.
    async function click(action, expected, record = output) {
      const before = await webview.evaluate(`window.__outputActions.length`);
      const list = action === "check";
      if (list) {
        await clickLabel(labels("outputs.view"));
        await clickLabel(
          labels("outputs.check"),
          `${listed(record.id)} button`,
        );
      } else {
        await showMenu(record.id);
        await clickLabel(
          labels(`outputs.${action}`),
          '.file-menu [role="menuitem"]:not([aria-disabled="true"])',
        );
      }
      const request = await poll(
        () => webview.evaluate(`window.__outputActions[${before}] ?? null`),
        5000,
        `Output ${action} request`,
      );
      assert.deepEqual(request.target, {
        kind: "output",
        taskId,
        runId: record.runId ?? delivered.id,
        outputId: record.id,
      });
      const expectedLabel = expected && labels(`outputs.state.${expected}`);
      await poll(
        () =>
          webview.evaluate(
            expectedLabel
              ? `${JSON.stringify(expectedLabel)}.includes(${statusOf(record.id, list)}?.textContent.trim())`
              : `!${statusOf(record.id, list)}`,
          ),
        35_000,
        `Output visible ${expected ?? "silent"} status`,
      );
      evidence.states.push({ action, state: expected });
      return request;
    }
    await click("check", "ready");
    if (nativeOutputProbe && nativeExistingActions) {
      const beforeNative = await readdir(workspaceRoot);
      const destination = path.join(workspaceRoot, "另存 output 中文.txt");
      const saved = await nativeOutputProbe({
        mode: "save",
        source,
        destination,
        trigger: () => click("save", "saved"),
      });
      assert.deepEqual(await readFile(destination), bytes);
      const cancelled = await nativeOutputProbe({
        mode: "cancel",
        source,
        trigger: () => click("save", "cancelled"),
      });
      // What is saved is the file as it is now, not as it was delivered.
      const edited = `${content}changed before Save As`;
      await writeFile(source, edited);
      const changed = await nativeOutputProbe({
        mode: "save",
        source,
        destination,
        trigger: () => click("save", "saved"),
      });
      assert.equal(await readFile(destination, "utf8"), edited);
      assert.deepEqual(
        (await readdir(workspaceRoot)).sort(),
        [...beforeNative, path.basename(destination)].sort(),
      );
      await writeFile(source, bytes);
      const revealed = await nativeOutputProbe({
        mode: "reveal",
        source,
        trigger: () => click("reveal", null),
      });
      assert.equal(saved.dialogObserved, true);
      assert.equal(cancelled.dialogObserved, true);
      assert.equal(changed.dialogObserved, true);
      assert.equal(saved.overwriteConfirmed, false);
      assert.equal(changed.overwriteConfirmed, true);
      assert.equal(revealed.selectedFixture, true);
      evidence.native = {
        saved,
        cancelled,
        changedSourceSavedAsItIs: changed,
        revealed,
        savedSha256: createHash("sha256")
          .update(await readFile(destination))
          .digest("hex"),
      };
      evidence.scope =
        "Real Windows App/Core/Renderer and native Save As through scoped Win32 dialog controls, UIAutomation and Explorer selection; fixture Provider, not remote-model quality or physical mouse gestures";
    }
    await writeFile(source, `${content}changed`);
    await click("check", "changed");
    await unlink(source);
    await click("check", "missing");
    await writeFile(source, `${content}edited externally`);
    const unsent = "Keep my unsent request. ";
    await webview.evaluate(
      `document.querySelector('.composer-shell textarea').focus()`,
    );
    await webview.send("Input.insertText", { text: unsent });
    const requestsBeforeEdit = provider.requests.length;
    assert.equal(
      (await click("edit", "edit_prepared")).action,
      "check_current",
    );
    const draft = await webview.evaluate(
      `document.querySelector('.composer-shell textarea')?.value`,
    );
    assert.ok(
      draft.includes(unsent) && draft.includes(relative),
      JSON.stringify(draft),
    );
    assert.equal(draft.split(unsent).length, 2);
    assert.equal(provider.requests.length, requestsBeforeEdit);
    evidence.editDraftOnlyAndExistingTextPreserved = true;
    await writeFile(source, bytes);
    webview.close();
    webview = undefined;
    await restart();
    await attach();
    const restored = (await task()).runs.find(
      (item) => item.id === delivered.id,
    );
    assert.deepEqual(restored.outputs, [output]);
    const checked = await click("check", "ready");
    evidence.coldHistoryAndRecheck = true;
    assert.equal(provider.requests.length, callsBeforeChecks);
    evidence.fileActionsDidNotCallProvider = true;
    assert.equal(
      (await task()).conversationOutputs.find(
        (record) => record.id === output.id,
      )?.runId,
      delivered.id,
    );

    await writeFile(source, `${content}between turns`);
    const unchanged = await run(
      "Read without updating the output",
      "OUTPUT_INTERVAL_UNCHANGED",
      [textSse("interval-unchanged", "OUTPUT_INTERVAL_UNCHANGED")],
    );
    assert.equal(unchanged.outputs.length, 0);
    const updated = await run(
      "Observe the work in progress",
      "OUTPUT_INTERVAL_CHANGED",
      [
        async () => {
          await writeFile(source, `${content}during the turn`);
          return textSse("interval-changed", "OUTPUT_INTERVAL_CHANGED");
        },
      ],
    );
    assert.deepEqual(updated.outputs, [{ ...output, updated: true }]);
    assert.equal(
      (await task()).conversationOutputs.filter(
        (record) => record.id === output.id,
      ).length,
      1,
    );
    evidence.updatedExistingOutputId = output.id;
    await writeFile(source, bytes);

    const html = "results/hero 中文.html";
    browser = await prepareBrowserFixture(workspaceRoot, html, poll);
    const page = await run("Create a static report", "OUTPUT_HTML_CREATED", [
      toolSse("html-write", "html-write", "Write", {
        file_path: path.join(workspaceRoot, html),
        content: browser.content,
      }),
      textSse("html-created", "OUTPUT_HTML_CREATED"),
    ]);
    assert.equal(page.outputs.length, 0);
    const change = page.fileChanges.changes.find(
      (item) => item.displayPath === html,
    );
    assert.equal(change?.outputRegistrationAdmitted, true);
    const review = labels("file_changes.review");
    const register = labels("outputs.register");
    await clickLabel(review);
    await clickLabel(register, "#task-panel-tabpanel button");
    const htmlOutput = await poll(
      async () =>
        (await task()).conversationOutputs?.find(
          (record) => record.displayPath === html,
        ),
      15_000,
      "Manually registered HTML output",
    );
    assert.equal(htmlOutput.runId, page.id);
    await clickLabel(labels("outputs.view"));
    const htmlButtons = `#task-panel-tabpanel [data-output-id="${htmlOutput.id}"] button`;
    await clickLabel(labels("outputs.view_source"), htmlButtons);
    await poll(
      () =>
        webview.evaluate(
          `document.querySelector('.task-panel-code-source code')?.textContent === ${JSON.stringify(browser.content)} &&
            !document.querySelector('#task-panel-tabpanel iframe, #task-panel-tabpanel h1, #task-panel-tabpanel script')`,
        ),
      15_000,
      "HTML appears as inert source",
    );
    assert.equal(browser.observed(), undefined);
    if (nativeOutputProbe) {
      await clickLabel(labels("outputs.view"));
      await clickLabel(labels("outputs.open_browser"), htmlButtons);
      evidence.htmlBrowser = await browser.verify();
      assert.equal(
        await readFile(path.join(workspaceRoot, html), "utf8"),
        browser.content,
      );
    }
    evidence.registeredHtmlOutput = htmlOutput.id;
    if (nativeOutputProbe) {
      evidence.officeStage = "registering";
      const originalName = `results/MetaWork Office original ${taskId}-${process.pid}`;
      const wordPath = originalName + ".docx";
      const original = path.join(workspaceRoot, wordPath);
      const wordPackage = officeWordFixture();
      const cases = [
        { relative: wordPath, bytes: wordPackage },
        {
          relative: originalName + "-sheet.XLSX",
          bytes: await readFile(
            new URL(
              "../tests/fixtures/office/checked-summary.xlsx",
              import.meta.url,
            ),
          ),
        },
        {
          relative: originalName + "-slides.pptx",
          bytes: await readFile(
            new URL(
              "../tests/fixtures/office/metaskoffice-20261030/bar-multi-labels-metaskoffice-roundtrip.pptx",
              import.meta.url,
            ),
          ),
        },
        { relative: originalName + "-mismatch.xlsx", bytes: wordPackage },
        {
          relative: originalName + "-invalid.docx",
          bytes: "Not an Office document",
        },
      ];
      for (const fixture of cases) {
        await writeFile(
          path.join(workspaceRoot, fixture.relative),
          fixture.bytes,
        );
      }
      const officeRun = await run(
        "Deliver the Office documents",
        "OUTPUT_OFFICE_READY",
        [
          ...cases.map(({ relative }, index) =>
            toolSse(
              `${index}-office-deliver`,
              `${index}-office-deliver`,
              "DeliverFile",
              { path: relative },
            ),
          ),
          textSse("office-ready", "OUTPUT_OFFICE_READY"),
        ],
      );
      const [word, sheet, slides, mismatch, invalid] = cases.map(
        ({ relative }) => ({
          ...officeRun.outputs.find(
            (record) => record.displayPath === relative,
          ),
          runId: officeRun.id,
        }),
      );
      evidence.officeStage = "rejecting_mismatch";
      const expectOpen = (record, state) => click("open", state, record);
      await expectOpen(mismatch, "restricted");
      await expectOpen(invalid, "restricted");
      evidence.officeStage = "opening_original";
      evidence.office = await nativeOutputProbe({
        mode: "office",
        source: original,
        trigger: () => expectOpen(word, null),
      });
      assert.equal(evidence.office.openedOriginal, true);
      assert.equal(evidence.office.savedOriginal, true);
      const savedBytes = await readFile(original);
      assert.notDeepEqual(savedBytes, wordPackage);
      evidence.officeStage = "opening_workbook_and_slides";
      for (const record of [sheet, slides]) {
        const source = path.join(workspaceRoot, record.displayPath);
        const result = await nativeOutputProbe({
          mode: "office-view",
          source,
          trigger: () => expectOpen(record, null),
        });
        assert.equal(result.openedOriginal, true);
      }
      evidence.office.openedWorkbookAndSlides = true;
      evidence.officeStage = "working_from_saved_original";
      await click("edit", "edit_prepared", word);
      await poll(
        () =>
          webview.evaluate(
            `document.querySelector('.composer-shell textarea')?.value.includes(${JSON.stringify(wordPath)})`,
          ),
        10_000,
        "The Office edit draft references the Workspace original",
      );
      await run(" Verify the saved document.", "OUTPUT_OFFICE_SAVED_BYTES", [
        toolSse("office-saved", "office-saved", "DeliverFile", {
          path: wordPath,
        }),
        (payload) => {
          const blocks = payload.messages.at(-1).content;
          const result = blocks.find(
            (block) => block.tool_use_id === "office-saved",
          );
          assert.equal(result?.is_error ?? false, false);
          const content =
            typeof result.content === "string"
              ? result.content
              : result.content.map((block) => block.text ?? "").join("");
          assert.equal(
            JSON.parse(content).sha256,
            createHash("sha256").update(savedBytes).digest("hex"),
          );
          return textSse("office-saved-verified", "OUTPUT_OFFICE_SAVED_BYTES");
        },
      ]);
      evidence.office.nextTurnReadSavedOriginal = true;
      delete evidence.officeStage;
    }
    const screenshot = await webview.send("Page.captureScreenshot", {
      format: "png",
    });
    await mkdir(evidenceDirectory, { recursive: true });
    await writeFile(
      path.join(evidenceDirectory, "output.png"),
      Buffer.from(screenshot.data, "base64"),
    );
    await invoke("metawork.tasks.archive", { taskId, archived: true });
    await invoke("metawork.tasks.delete", { taskId });
    await poll(
      () =>
        webview.evaluate(
          `![...document.querySelectorAll('.task-list-item')].some(item => item.dataset.taskId === ${JSON.stringify(taskId)})`,
        ),
      15_000,
      "Output Task deleted from UI",
    );
    const lastAction = await webview.evaluate(
      "window.__outputActions.at(-1).operationId",
    );
    const denied = await invoke("metawork.files.action", {
      ...checked,
      operationId: String(BigInt(lastAction) + 1n),
    });
    assert.equal(denied.state, "missing");
    assert.deepEqual(await readFile(source), bytes);
    evidence.deletedTaskRejectedAndSourcePreserved = true;
    assert.equal(provider.error, null);
    await writeFile(
      path.join(evidenceDirectory, "output.json"),
      JSON.stringify(evidence, null, 2) + "\n",
    );
    return evidence;
  } catch (error) {
    await mkdir(evidenceDirectory, { recursive: true });
    let ui = null;
    if (webview) {
      ui = await webview
        .evaluate(
          `({ body: document.body.innerText.slice(0, 16000), tasks: [...document.querySelectorAll('.task-list-item')].map(item => ({ id: item.dataset.taskId, current: item.getAttribute('aria-current') })), inputs: window.__outputInputs, actions: window.__outputActions })`,
        )
        .catch(() => null);
      const screenshot = await webview
        .send("Page.captureScreenshot", {
          format: "png",
        })
        .catch(() => null);
      if (screenshot)
        await writeFile(
          path.join(evidenceDirectory, "output-failure.png"),
          Buffer.from(screenshot.data, "base64"),
        );
    }
    await writeFile(
      path.join(evidenceDirectory, "output-failure.json"),
      JSON.stringify({ message: error.message, ...evidence, ...ui }, null, 2),
    );
    throw error;
  } finally {
    browser?.close();
    webview?.close();
  }
}

// macOS automation exercises the real Bridge/Host and observes the default
// browser; the Windows vertical also drives the Renderer buttons directly.
export async function runOutputBrowserHostProbe({
  created,
  workspaceRoot,
  invoke,
  snapshot,
  poll,
  provider,
  toolSse,
  textSse,
}) {
  await invoke("metawork.tasks.rename", {
    taskId: created.taskId,
    title: "HTML browser fixture",
  });
  const relative = "results/hero 中文.HTM";
  await mkdir(path.join(workspaceRoot, "results"), { recursive: true });
  const browser = await prepareBrowserFixture(workspaceRoot, relative, poll);
  try {
    await writeFile(path.join(workspaceRoot, relative), browser.content, {
      flag: "wx",
    });
    provider.enqueue(
      toolSse("html-delivery", "html-delivery", "DeliverFile", {
        path: relative,
      }),
      textSse("html-delivered", "HTML_DELIVERED"),
    );
    const started = await invoke("metawork.tasks.run", {
      taskId: created.taskId,
      expectedBindingEpoch: created.bindingEpoch,
      input: { kind: "text", text: "Deliver the HTML fixture." },
    });
    assert.equal(started.accepted, true);
    const published = await poll(
      async () => {
        if (provider.error) throw provider.error;
        const task = (await snapshot()).tasks.find(
          (t) => t.id === created.taskId,
        );
        const run = task?.runs.find((r) => r.id === started.runId);
        return run?.terminal ? { task, run } : null;
      },
      60_000,
      "HTML delivery",
    );
    assert.equal(published.run.terminal.outcome, "completed");
    assert.equal(published.run.outputs[0].displayPath, relative);
    assert.equal(published.run.outputs[0].open, "browser");
    const opened = await invoke("metawork.files.action", {
      generation: "1",
      operationId: "1",
      target: {
        kind: "output",
        taskId: created.taskId,
        runId: started.runId,
        outputId: published.run.outputs[0].id,
      },
      action: "open",
    });
    assert.equal(opened?.state, "opened");
    const result = await browser.verify();
    assert.equal(
      await readFile(path.join(workspaceRoot, relative), "utf8"),
      browser.content,
    );
    return result;
  } finally {
    browser.close();
  }
}

// Office's platform probe shares the delivery owner. It proves the real App/Core
// receipt and cold-history projection; Renderer buttons remain a separate probe.
export async function runOfficeDeliveryHostProbe({
  created,
  workspaceRoot,
  fixture,
  invoke,
  snapshot,
  poll,
  provider,
  toolSse,
  textSse,
}) {
  await invoke("metawork.tasks.rename", {
    taskId: created.taskId,
    title: "Office delivery fixture",
  });
  const relative = "results/Office 中文.docx";
  await mkdir(path.join(workspaceRoot, "results"), { recursive: true });
  const bytes = await readFile(fixture);
  await writeFile(path.join(workspaceRoot, relative), bytes, { flag: "wx" });
  const digest = createHash("sha256").update(bytes).digest("hex");
  let receipt;
  provider.enqueue(
    toolSse("office-delivery", "office-delivery", "DeliverFile", {
      path: relative,
    }),
    (payload) => {
      const results = payload.messages
        .flatMap((m) => (Array.isArray(m.content) ? m.content : []))
        .filter(
          (b) =>
            b.type === "tool_result" && b.tool_use_id === "office-delivery",
        );
      assert.equal(results.length, 1);
      assert.equal(results[0].is_error ?? false, false);
      const content = results[0].content;
      receipt = JSON.parse(
        typeof content === "string"
          ? content
          : content.map((b) => b.text ?? "").join(""),
      );
      assert.equal(receipt.status, "delivered");
      assert.equal(receipt.path, relative);
      assert.equal(receipt.sha256, digest);
      assert.equal(receipt.size_bytes, bytes.length);
      return textSse("office-delivered", "OFFICE_DELIVERED");
    },
  );
  const started = await invoke("metawork.tasks.run", {
    taskId: created.taskId,
    expectedBindingEpoch: created.bindingEpoch,
    input: {
      kind: "text",
      text: "Deliver the finished Office fixture in results/Office 中文.docx.",
    },
  });
  assert.equal(started.accepted, true);
  const run = await poll(
    async () => {
      if (provider.error) throw provider.error;
      const task = (await snapshot()).tasks.find(
        (t) => t.id === created.taskId,
      );
      const run = task?.runs.find((r) => r.id === started.runId);
      return run?.terminal ? run : null;
    },
    60000,
    "Office actual DeliverFile completion",
  );
  assert.equal(run.terminal.outcome, "completed");
  assert.ok(receipt);
  assert.equal(run.outputs.length, 1);
  const output = run.outputs[0];
  assert.equal(output.id, receipt.delivery_id);
  assert.equal(output.sizeBytes, String(bytes.length));
  assert.deepEqual(await readFile(path.join(workspaceRoot, relative)), bytes);
  return { taskId: created.taskId, runId: run.id, output, digest };
}
