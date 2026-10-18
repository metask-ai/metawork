import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { protocolTextSse } from "../tests/fixtures/provider_protocol.mjs";

// Uses the existing desktop automation profile and process-local fixture vault.
// Page input stays on its owned WebView, independent of OS foreground focus.
export async function runModelSwitchVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  webview,
  evidenceDir,
}) {
  const timeout = 60_000;
  const targetModel = "gpt-4o-mini";
  const targetKey = "model-switch-owned-fixture-key";
  const requests = [];
  let fixtureError;
  let sourceEntered = false;
  let releaseSource;
  const sourceGate = new Promise((resolve) => {
    releaseSource = resolve;
  });
  const server = createServer(async (request, response) => {
    try {
      assert.equal(request.url, "/v1/responses");
      assert.ok(
        request.headers.authorization === `Bearer ${targetKey}`,
        "target credential mismatch",
      );
      let size = 0;
      const chunks = [];
      for await (const chunk of request) {
        size += chunk.length;
        assert.ok(size <= 2 * 1024 * 1024, "target fixture request limit");
        chunks.push(chunk);
      }
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      assert.equal(body.model, targetModel);
      if (body.stream === true) {
        requests.push(body);
        response.writeHead(200, {
          "content-type": "text/event-stream",
          connection: "close",
        });
        response.end(protocolTextSse("responses", "TARGET_DESKTOP_CONTEXT"));
      } else {
        response.writeHead(200, {
          "content-type": "application/json",
          connection: "close",
        });
        response.end(
          JSON.stringify({
            id: "response_probe",
            status: "completed",
            output: [
              {
                type: "message",
                role: "assistant",
                status: "completed",
                content: [{ type: "output_text", text: "OK", annotations: [] }],
              },
            ],
            usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
          }),
        );
      }
    } catch (error) {
      fixtureError ??= error;
      if (!response.headersSent)
        response.writeHead(400, { connection: "close" });
      response.end("invalid owned fixture request");
    }
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const endpoint = `http://127.0.0.1:${server.address().port}/v1/responses`;
  const accepted = (result) =>
    assert.equal(result.accepted, true, JSON.stringify(result));
  const wait = (operation, label) =>
    poll(
      async () => {
        if (fixtureError) throw fixtureError;
        return operation();
      },
      timeout,
      label,
    );
  const key = async (value, code, virtualKey) => {
    await webview.send("Input.dispatchKeyEvent", {
      type: "keyDown",
      key: value,
      code,
      windowsVirtualKeyCode: virtualKey,
    });
    await webview.send("Input.dispatchKeyEvent", {
      type: "keyUp",
      key: value,
      code,
      windowsVirtualKeyCode: virtualKey,
    });
  };
  const inspectRunModel = async (
    expectedModel,
    captureName,
    expectedProvider,
  ) => {
    const point = await wait(
      () =>
        webview.evaluate(
          `(() => { const trigger=[...document.querySelectorAll('button')].find(item=>/^(任务信息|Task information)$/.test(item.getAttribute('aria-label') ?? '')); if(!trigger) throw new Error('Task information trigger missing'); const r=trigger.getBoundingClientRect(), x=r.left+r.width/2,y=r.top+r.height/2; if(document.elementFromPoint(x,y)?.closest('button')!==trigger) return null; return {x,y}; })()`,
        ),
      "Task information trigger is clickable",
    );
    await webview.send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      button: "left",
      clickCount: 1,
      ...point,
    });
    await webview.send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      button: "left",
      clickCount: 1,
      ...point,
    });
    await wait(
      () =>
        webview.evaluate(
          `(() => { const panel=document.querySelector('.task-information'); if(!panel?.getClientRects().length) return false; const rows=[...panel.querySelectorAll('.task-facts > div')]; const fact=pattern=>rows.find(item=>pattern.test(item.querySelector('dt')?.textContent ?? ''))?.querySelector('dd')?.textContent; if(fact(/本轮模型|Current run model/)!==${JSON.stringify(expectedModel)}) throw new Error('Task information does not preserve the active Run model'); if(fact(/所选 Provider|Selected provider/)!==${JSON.stringify(expectedProvider)}) throw new Error('Task information does not retain the selected Provider'); if(fact(/本轮协议|Current run protocol/)!=='Anthropic Messages') throw new Error('Task information borrowed the new Provider protocol for an active Run'); const r=panel.getBoundingClientRect(); if(r.left< -1 || r.right>innerWidth+1 || panel.scrollWidth>panel.clientWidth+1) throw new Error('Task information overflows'); return true; })()`,
        ),
      "Task information shows the actual Run model",
    );
    const png = await webview.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      path.join(evidenceDir, `${captureName}.png`),
      Buffer.from(png.data, "base64"),
    );
    await key("Escape", "Escape", 27);
    await wait(
      () =>
        webview.evaluate(
          `!document.querySelector('.task-information')?.getClientRects().length`,
        ),
      "Task information closes",
    );
  };
  try {
    // Match the sync vertical: this probe owns WebView input, while native
    // foreground and system-key verification remain a separate gate.
    await webview.send("Page.bringToFront");
    await webview.send("Emulation.setFocusEmulationEnabled", { enabled: true });
    const initial = await snapshot();
    assert.equal(initial.models.customProviders.length, 1);
    const source = initial.models.customProviders[0];
    const chosen = await invoke("metawork.workspaces.choose", {});
    assert.equal(chosen.selected, true);
    const workspace = (await snapshot()).workspaces.find(
      (item) => item.id === chosen.workspaceId,
    );
    const admission = (await snapshot()).newTaskAdmission;
    const created = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId: workspace.id,
        expectedWorkspaceEpoch: workspace.epoch,
      },
      expectedExecutionGeneration: admission.activeGeneration,
      expectedSelectionRevision: admission.activeSelectionRevision,
      modelSelection: null,
      expectedSkillCatalogRevision: null,
      expectedSkillSelectionRevision: null,
      approvalMode: "manual",
    });
    accepted(created);
    const taskId = created.taskId;
    const readTask = async () =>
      (await snapshot()).tasks.find((item) => item.id === taskId);
    await invoke("metawork.tasks.rename", {
      taskId,
      title: "Model switch validation",
    });
    provider.enqueue(async () => {
      sourceEntered = true;
      await sourceGate;
      return textSse("model-switch-source", "SOURCE_DESKTOP_CONTEXT");
    });
    accepted(
      await invoke("metawork.tasks.run", {
        taskId,
        expectedBindingEpoch: created.bindingEpoch,
        input: { kind: "text", text: "ORIGINAL_DESKTOP_CONTEXT" },
      }),
    );
    await wait(() => sourceEntered, "original model Run entered");
    await wait(
      () =>
        webview.evaluate(
          `(() => { const row=[...document.querySelectorAll('.task-list-item')].find(item=>item.dataset.taskId===${JSON.stringify(taskId)}); if(!row) return false; if(row.getAttribute('aria-current')!=='page') {row.click();return false;} const label=document.querySelector('.composer-model-trigger')?.textContent ?? ''; return !!label && !/下一轮|Next run/.test(label); })()`,
        ),
      "the model selector has no next-run prefix during the original Run",
    );
    console.log("Model switch vertical: original Run is active.");
    accepted(
      await invoke("metawork.models.customProviders.update", {
        providerId: source.id,
        expectedProviderRevision: source.providerRevision,
        displayName: source.displayName,
        protocol: "openai_responses",
        normalizedBaseUrl: endpoint,
      }),
    );
    let currentSource = (await snapshot()).models.customProviders[0];
    accepted(
      await invoke("metawork.models.customProviders.replaceCredential", {
        providerId: source.id,
        expectedProviderRevision: currentSource.providerRevision,
        apiKey: targetKey,
      }),
    );
    currentSource = (await snapshot()).models.customProviders[0];
    accepted(
      await invoke("metawork.models.customModels.add", {
        providerId: source.id,
        expectedProviderRevision: currentSource.providerRevision,
        expectedCatalogGeneration: currentSource.catalogGeneration,
        model: { id: targetModel, displayName: "Target model" },
      }),
    );
    currentSource = (await snapshot()).models.customProviders[0];
    accepted(
      await invoke("metawork.models.customModels.test", {
        model: { sourceId: source.id, modelId: targetModel },
        expectedProviderRevision: currentSource.providerRevision,
        expectedSourceGeneration: currentSource.sourceGeneration,
        expectedCatalogGeneration: currentSource.catalogGeneration,
      }),
    );
    await wait(
      async () =>
        (await snapshot()).models.customProviders[0].models.some(
          (item) => item.id === targetModel && item.testStatus === "connected",
        ),
      "target model probe",
    );
    console.log("Model switch vertical: target probe connected.");
    // Source settings are separate user operations. Freeze the default after
    // those operations, then prove Task selection leaves it untouched.
    const defaultBeforeSelection = (await snapshot()).models.defaultSelection;
    await wait(
      async () =>
        webview.evaluate(
          `(() => { const row=[...document.querySelectorAll('.task-list-item')].find(item=>item.dataset.taskId===${JSON.stringify(taskId)}); if(!row) return false; if(row.getAttribute('aria-current')!=='page') {row.click();return false;} return !!document.querySelector('.composer-model-trigger:not(:disabled)'); })()`,
        ),
      "model selector on active Task",
    );
    await webview.evaluate(
      `document.querySelector('.composer-model-trigger').focus()`,
    );
    await key("ArrowDown", "ArrowDown", 40);
    await wait(
      () =>
        webview.evaluate(
          `!!document.querySelector('.composer-model-menu [role="option"]')`,
        ),
      "keyboard opens model menu",
    );
    await key("Escape", "Escape", 27);
    await wait(
      () =>
        webview.evaluate(
          `document.activeElement===document.querySelector('.composer-model-trigger')`,
        ),
      "Escape returns model focus",
    );
    await wait(
      () =>
        webview.evaluate(
          `(() => { const menu=document.querySelector('.composer-model-menu'); return document.querySelector('.composer-model-trigger').getAttribute('aria-expanded')==='false' && (!menu || menu.getBoundingClientRect().height===0); })()`,
        ),
      "model menu closes",
    );
    const views = [];
    await mkdir(evidenceDir, { recursive: true });
    for (const [name, width, theme] of [
      ["desktop-light", 1320, "light"],
      ["desktop-dark", 1320, "dark"],
      ["narrow-light", 390, "light"],
      ["narrow-dark", 390, "dark"],
    ]) {
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
        `document.documentElement.dataset.theme=${JSON.stringify(theme)}; document.querySelector('.composer-model-trigger').focus()`,
      );
      await key("ArrowDown", "ArrowDown", 40);
      const geometry = await wait(
        () =>
          webview.evaluate(
            `(() => { const menu=document.querySelector('.composer-model-menu'); const button=document.querySelector('.composer-model-trigger'); if(!menu || !button || !menu.getClientRects().length) return null; const m=menu.getBoundingClientRect(), b=button.getBoundingClientRect(); if(m.left< -1 || m.right>innerWidth+1 || b.left< -1 || b.right>innerWidth+1 || document.documentElement.scrollWidth>innerWidth) throw new Error('model controls overflow'); return {width:innerWidth,theme:document.documentElement.dataset.theme,reducedMotion:matchMedia('(prefers-reduced-motion: reduce)').matches,menuWidth:m.width,triggerHeight:b.height}; })()`,
          ),
        `model menu ${name}`,
      );
      const png = await webview.send("Page.captureScreenshot", {
        format: "png",
        captureBeyondViewport: false,
      });
      await writeFile(
        path.join(evidenceDir, `model-${name}.png`),
        Buffer.from(png.data, "base64"),
      );
      views.push(geometry);
      await key("Escape", "Escape", 27);
      await wait(
        () =>
          webview.evaluate(
            `(() => { const menu=document.querySelector('.composer-model-menu'); return document.querySelector('.composer-model-trigger').getAttribute('aria-expanded')==='false' && (!menu || menu.getBoundingClientRect().height===0); })()`,
          ),
        "model menu closes after capture",
      );
      await inspectRunModel(
        admission.activeModelRef.modelId,
        `model-information-${name}`,
        source.displayName,
      );
    }
    await webview.send("Emulation.setDeviceMetricsOverride", {
      width: 1320,
      height: 812,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await webview.evaluate(
      `document.querySelector('.composer-model-trigger').focus()`,
    );
    await key("ArrowDown", "ArrowDown", 40);
    const point = await wait(
      () =>
        webview.evaluate(
          `(() => { const option=[...document.querySelectorAll('.composer-model-menu [role="option"]')].find(item=>item.textContent.includes('Target model')); if(!option || option.getAttribute('aria-disabled')==='true') return null; if(option.textContent.trim()!=='Target model') throw new Error('Model option includes a Provider label'); option.scrollIntoView({block:'nearest'}); const r=option.getBoundingClientRect(), x=r.left+r.width/2,y=r.top+r.height/2; if(document.elementFromPoint(x,y)?.closest('[role="option"]')!==option) return null; return {x,y}; })()`,
        ),
      "target model menu option",
    );
    await webview.send("Input.dispatchMouseEvent", {
      type: "mousePressed",
      button: "left",
      clickCount: 1,
      ...point,
    });
    await webview.send("Input.dispatchMouseEvent", {
      type: "mouseReleased",
      button: "left",
      clickCount: 1,
      ...point,
    });
    const busy = await wait(async () => {
      const task = await readTask();
      return task.modelIntent?.modelRef.modelId === targetModel ? task : null;
    }, "Renderer saves Task model intent");
    assert.equal(busy.activeOperation.kind, "run");
    assert.equal(busy.runs[0].execution.protocol, "anthropic_messages");
    assert.equal(busy.binding.model, admission.activeModelRef.modelId);
    await wait(
      () =>
        webview.evaluate(
          `document.querySelector('.composer-model-trigger')?.textContent.trim()==='Target model'`,
        ),
      "Renderer shows only the selected model name",
    );
    const pending = await webview.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      path.join(evidenceDir, "model-selected.png"),
      Buffer.from(pending.data, "base64"),
    );
    await inspectRunModel(
      admission.activeModelRef.modelId,
      "model-information-after-selection",
      source.displayName,
    );
    releaseSource();
    await wait(async () => {
      const task = await readTask();
      return task.runs[0].terminal?.outcome === "completed" &&
        task.continuationRecoveryAvailable
        ? task
        : null;
    }, "source Run settles before rebind");
    const before = await readTask();
    accepted(
      await invoke("metawork.tasks.restore", {
        taskId,
        expectedBindingEpoch: before.binding.epoch,
      }),
    );
    const installed = await wait(async () => {
      const task = await readTask();
      return task.binding.protocol === "openai_responses" &&
        task.continuationAvailable
        ? task
        : null;
    }, "complete target connection installed");
    assert.equal(
      BigInt(installed.binding.epoch),
      BigInt(created.bindingEpoch) + 1n,
    );
    accepted(
      await invoke("metawork.tasks.run", {
        taskId,
        expectedBindingEpoch: installed.binding.epoch,
        input: { kind: "text", text: "Continue the original conversation." },
      }),
    );
    const final = await wait(async () => {
      const task = await readTask();
      return task.runs.length === 2 &&
        task.runs[1].terminal?.outcome === "completed"
        ? task
        : null;
    }, "target model Run completed");
    assert.equal(requests.length, 1);
    assert.ok(JSON.stringify(requests[0]).includes("ORIGINAL_DESKTOP_CONTEXT"));
    assert.ok(JSON.stringify(requests[0]).includes("SOURCE_DESKTOP_CONTEXT"));
    assert.equal(final.runs[0].execution.protocol, "anthropic_messages");
    assert.equal(final.runs[1].execution.protocol, "openai_responses");
    assert.ok(final.runs[1].output.response.includes("TARGET_DESKTOP_CONTEXT"));
    assert.deepEqual(
      (await snapshot()).models.defaultSelection,
      defaultBeforeSelection,
    );
    assert.ok(!JSON.stringify(await snapshot()).includes(targetKey));
    await writeFile(
      path.join(evidenceDir, "model-switch.json"),
      JSON.stringify(
        {
          taskId,
          sourceProtocol: final.runs[0].execution.protocol,
          targetProtocol: final.runs[1].execution.protocol,
          defaultUnchangedByTaskSelection: true,
          defaultAtTaskSelection: defaultBeforeSelection,
          contextPreserved: true,
          views,
        },
        null,
        2,
      ),
    );
    console.log(
      "Model switch desktop WebView vertical passed: busy Renderer selection, full endpoint/credential/protocol rebind, original context, immutable Runs, independent default, keyboard menu, themes and 390px. OS foreground input remains a separate gate.",
    );
  } finally {
    releaseSource();
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}
