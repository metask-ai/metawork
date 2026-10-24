import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { enUS } from "../frontend/src/i18n/messages/en-US.ts";
import { zhCN } from "../frontend/src/i18n/messages/zh-CN.ts";

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
  async function audit() {
    await webview.evaluate(`(() => {
      window.__outputInputs = []; window.__outputActions = [];
      const transport = window.chrome.webview, post = transport.postMessage;
      transport.postMessage = function(message) {
        const envelope = typeof message === 'string' ? JSON.parse(message) : message;
        if (envelope.command === 'metawork.tasks.sendInput') window.__outputInputs.push(envelope.payload);
        if (envelope.command === 'metawork.outputs.action') window.__outputActions.push(envelope.payload);
        return post.call(transport, message);
      };
    })()`);
  }
  try {
    const admission = (await snapshot()).newTaskAdmission;
    const created = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },
      expectedExecutionGeneration: admission.activeGeneration,
      expectedSelectionRevision: admission.activeSelectionRevision,
      modelSelection: null,
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
          assert.equal(receipt.status, "verified_for_delivery");
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
    async function click(action, expected) {
      const before = await webview.evaluate(`window.__outputActions.length`);
      const buttons = labels(`outputs.${action}`);
      const expectedLabel = labels(`outputs.state.${expected}`);
      await poll(
        () =>
          webview.evaluate(`(() => {
        const row = document.querySelector('[data-output-id="${output.id}"]');
        const button = [...(row?.querySelectorAll('button') ?? [])].find(item => ${JSON.stringify(buttons)}.includes(item.textContent.trim()));
        if (!button || button.disabled) return false;
        button.click(); return true;
      })()`),
        15_000,
        `Output ${action} button`,
      );
      const request = await poll(
        () => webview.evaluate(`window.__outputActions[${before}] ?? null`),
        5000,
        `Output ${action} request`,
      );
      assert.equal(request.taskId, taskId);
      assert.equal(request.runId, delivered.id);
      assert.equal(request.outputId, output.id);
      await poll(
        () =>
          webview.evaluate(`(() => {
        const row = document.querySelector('[data-output-id="${output.id}"]');
        return ${JSON.stringify(expectedLabel)}.includes(row?.querySelector('.run-output-status')?.textContent.trim());
      })()`),
        35_000,
        `Output visible ${expected} status`,
      );
      evidence.states.push({ action, state: expected });
      return request;
    }
    await click("check", "ready");
    if (nativeOutputProbe) {
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
      await writeFile(source, `${content}changed before Save As`);
      const changed = await nativeOutputProbe({
        mode: "save",
        source,
        destination,
        trigger: () => click("save", "changed"),
      });
      assert.deepEqual(await readFile(destination), bytes);
      assert.deepEqual(
        (await readdir(workspaceRoot)).sort(),
        [...beforeNative, path.basename(destination)].sort(),
      );
      await writeFile(source, bytes);
      const revealed = await nativeOutputProbe({
        mode: "reveal",
        source,
        trigger: () => click("reveal", "revealed"),
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
        changedSourcePreservedTarget: changed,
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
    await writeFile(source, bytes);
    await click("check", "ready");
    const unsent = "Keep my unsent request. ";
    await webview.evaluate(
      `document.querySelector('.composer-shell textarea').focus()`,
    );
    await webview.send("Input.insertText", { text: unsent });
    const requestsBeforeEdit = provider.requests.length;
    await click("edit", "edit_prepared");
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
    const denied = await invoke("metawork.outputs.action", {
      ...checked,
      operationId: String(BigInt(checked.operationId) + 1n),
    });
    assert.equal(denied.state, "missing");
    assert.deepEqual(await readFile(source), bytes);
    evidence.deletedTaskRejectedAndSourcePreserved = true;
    assert.equal(provider.requests.length, callsBeforeChecks);
    evidence.fileActionsDidNotCallProvider = true;
    assert.equal(provider.error, null);
    await writeFile(
      path.join(evidenceDirectory, "output.json"),
      JSON.stringify(evidence, null, 2) + "\n",
    );
    return evidence;
  } catch (error) {
    await mkdir(evidenceDirectory, { recursive: true });
    if (webview) {
      const ui = await webview.evaluate(
        `({ body: document.body.innerText.slice(0, 16000), tasks: [...document.querySelectorAll('.task-list-item')].map(item => ({ id: item.dataset.taskId, current: item.getAttribute('aria-current') })), inputs: window.__outputInputs, actions: window.__outputActions })`,
      );
      await writeFile(
        path.join(evidenceDirectory, "output-failure.json"),
        JSON.stringify({ message: error.message, ...ui }, null, 2),
      );
      const screenshot = await webview.send("Page.captureScreenshot", {
        format: "png",
      });
      await writeFile(
        path.join(evidenceDirectory, "output-failure.png"),
        Buffer.from(screenshot.data, "base64"),
      );
    }
    throw error;
  } finally {
    webview?.close();
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
      assert.equal(receipt.status, "verified_for_delivery");
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
