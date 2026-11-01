import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

// Runs only in the desktop harness's isolated profile and loopback provider.
export async function runModelErrorVertical({
  invoke,
  runPrepared,
  snapshot,
  poll,
  provider,
  connect,
  stop,
  restart,
  resize,
  dataRoot,
  evidenceDir,
}) {
  const timeout = 60_000;
  const hostOnlyCredential = "model-error-new-host-only-fixture-key";
  const instruction =
    "Show a safe model error without replaying this instruction.";
  const accepted = (result) =>
    assert.equal(
      result?.accepted,
      true,
      `fixture mutation was not accepted: ${JSON.stringify(result)}`,
    );
  await mkdir(evidenceDir, { recursive: true });
  const initial = await snapshot();
  const accountBefore = initial.account;
  const chosen = await invoke("metawork.workspaces.choose", {});
  assert.equal(chosen.selected, true);
  const ready = await snapshot();
  const workspace = ready.workspaces.find(
    (item) => item.id === chosen.workspaceId,
  );
  const created = await invoke("metawork.tasks.create", {
    workspace: {
      kind: "manual",
      workspaceId: workspace.id,
      expectedWorkspaceEpoch: workspace.epoch,
    },
    expectedExecutionGeneration: ready.newTaskAdmission.activeGeneration,
    expectedSelectionRevision: ready.newTaskAdmission.activeSelectionRevision,
    modelSelection: null,
    expectedSkillCatalogRevision: null,
    expectedSkillSelectionRevision: null,
    approvalMode: "manual",
  });
  accepted(created);
  const taskId = created.taskId;
  assert.equal(
    (
      await invoke("metawork.tasks.rename", {
        taskId,
        title: "Model error acceptance",
      })
    ).renamed,
    true,
  );
  await poll(
    async () => {
      const task = (await snapshot({ taskId })).tasks.find(
        (item) => item.id === taskId,
      );
      return task?.skillCatalog.availability === "ready";
    },
    timeout,
    "Task Skill catalog finishes asynchronous admission",
  );
  const servedBefore = provider.served;
  let entered = false;
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  provider.enqueue(async () => {
    entered = true;
    await gate;
    return {
      status: 401,
      body: JSON.stringify({
        error: {
          type: "authentication_error",
          message: `MODEL_ERROR_VERTICAL ${hostOnlyCredential} rejected`,
        },
      }),
    };
  });
  accepted(
    await runPrepared({
      taskId,
      expectedBindingEpoch: created.bindingEpoch,
      input: { kind: "text", text: instruction },
    }),
  );
  await poll(
    () => entered,
    timeout,
    "Core has captured the original request credential",
  );
  // Replace and verify the next execution credential while the original Core
  // request stays in flight. The new key is known to Host and absent from Core.
  let source = (await snapshot()).models.customProviders[0];
  accepted(
    await invoke("metawork.models.customProviders.replaceCredential", {
      providerId: source.id,
      expectedProviderRevision: source.providerRevision,
      apiKey: hostOnlyCredential,
    }),
  );
  provider.expectModelProbeCredential(hostOnlyCredential);
  source = (await snapshot()).models.customProviders[0];
  accepted(
    await invoke("metawork.models.customModels.test", {
      model: { sourceId: source.id, modelId: "claude-sonnet-4-20250514" },
      expectedProviderRevision: source.providerRevision,
      expectedSourceGeneration: source.sourceGeneration,
      expectedCatalogGeneration: source.catalogGeneration,
    }),
  );
  const connected = await poll(
    async () => {
      const current = await snapshot();
      return current.models.customProviders[0].models.some(
        (item) => item.testStatus === "connected",
      )
        ? current
        : null;
    },
    timeout,
    "replacement credential passes the explicit connection test",
  );
  source = connected.models.customProviders[0];
  accepted(
    await invoke("metawork.models.selectDefault", {
      sourceId: source.id,
      modelId: "claude-sonnet-4-20250514",
      expectedSelectionRevision: connected.models.selectionRevision,
      expectedSourceGeneration: source.sourceGeneration,
      expectedCatalogGeneration: source.catalogGeneration,
    }),
  );
  const prepared = await poll(
    async () => {
      const current = await snapshot();
      return current.models.customProviders[0].models.some(
        (item) => item.testStatus === "connected",
      ) &&
        current.newTaskAdmission.available &&
        current.newTaskAdmission.activeGeneration !==
          ready.newTaskAdmission.activeGeneration
        ? current
        : null;
    },
    timeout,
    "Host owns the newly verified execution key without changing the active Core request",
  );
  const modelsBefore = prepared.models;
  release();
  const readTask = async () =>
    (await snapshot({ taskId })).tasks.find((item) => item.id === taskId);
  const terminalTask = await poll(
    async () => {
      const task = await readTask();
      return task?.runs.at(-1)?.terminal ? task : null;
    },
    timeout,
    "real AgentCore model error reaches Product terminal",
  );
  const run = terminalTask.runs.at(-1);
  assert.equal(run.terminal.cause, "provider_failure");
  const detail = run.terminal.modelError;
  assert.equal(detail.category, "authentication");
  assert.equal(detail.httpStatus, 401);
  assert.equal(detail.source, "custom_provider");
  assert.equal(detail.recovery, "model_settings");
  assert.equal(
    detail.hostRedacted,
    true,
    "Host must mark its own credential cleaning",
  );
  assert.match(detail.message, /MODEL_ERROR_VERTICAL/);
  assert.equal(
    JSON.stringify(terminalTask).includes(hostOnlyCredential),
    false,
  );
  assert.equal(
    provider.served,
    servedBefore + 1,
    "request retryability must not replay a Run",
  );
  const after = await snapshot();
  assert.deepEqual(after.account, accountBefore);
  assert.deepEqual(
    after.models,
    modelsBefore,
    "model error must not invalidate catalog or test authority",
  );
  let webview = await connect();
  const selectTask = async () =>
    poll(
      () =>
        webview.evaluate(`(() => {
    const dialog=document.querySelector('[role=dialog]');
    const skip=dialog && [...dialog.querySelectorAll('button')].find(item=>/暂时跳过|Skip for now/.test(item.textContent));
    if(skip){skip.click();return false;}
    const row=[...document.querySelectorAll('.task-list-item')].find(item=>item.dataset.taskId===${JSON.stringify(taskId)});
    if(!row)return false; if(row.getAttribute('aria-current')!=='page'){row.click();return false;}
    return !!document.querySelector('.run-diagnostics');
  })()`),
      timeout,
      "Renderer displays the selected real failed Run",
    );
  const key = async (key, code, windowsVirtualKeyCode) => {
    for (const type of ["keyDown", "keyUp"])
      await webview.send("Input.dispatchKeyEvent", {
        type,
        key,
        code,
        windowsVirtualKeyCode,
        nativeVirtualKeyCode: windowsVirtualKeyCode,
        ...(type === "keyDown" && key === "Enter"
          ? { text: "\r", unmodifiedText: "\r" }
          : {}),
      });
  };
  try {
    await webview.send("Page.bringToFront");
    await webview.send("Emulation.setFocusEmulationEnabled", { enabled: true });
    await selectTask();
    assert.equal(
      await webview.evaluate(
        "document.querySelector('.model-error-message')===null",
      ),
      true,
    );
    await webview.evaluate(
      "document.querySelector('.run-diagnostics>summary').scrollIntoView({block:'center'});document.querySelector('.run-diagnostics>summary').focus()",
    );
    await key("Enter", "Enter", 13);
    console.log(
      "Model-error keyboard observation:",
      await webview.evaluate(
        `(() => ({focus:document.activeElement?.tagName, open:document.querySelector('.run-diagnostics')?.open, mounted:!!document.querySelector('.model-error-message')}))()`,
      ),
    );
    await poll(
      () =>
        webview.evaluate(
          "document.querySelector('.model-error-message')?.textContent.includes('MODEL_ERROR_VERTICAL')",
        ),
      timeout,
      "keyboard opens actual safe model error details",
    );
    assert.equal(
      await webview.evaluate(
        `document.querySelector('.run-diagnostics').textContent.includes(${JSON.stringify(hostOnlyCredential)})`,
      ),
      false,
    );
    for (const width of [1320, 390]) {
      await resize(width, 900);
      for (const theme of ["light", "dark"]) {
        await webview.evaluate(
          "new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))",
        );
        await webview.evaluate(
          `document.documentElement.dataset.theme=${JSON.stringify(theme)}; document.querySelector('.run-diagnostics').scrollIntoView({block:'center'})`,
        );
        assert.equal(
          await webview.evaluate(
            "(() => {const el=document.querySelector('.run-diagnostics'),r=el.getBoundingClientRect();return el.scrollWidth<=el.clientWidth+1 && r.left>=0 && r.right<=innerWidth+1 && el.querySelector('summary').getBoundingClientRect().height>=44;})()",
          ),
          true,
        );
        const png = await webview.send("Page.captureScreenshot", {
          format: "png",
          captureBeyondViewport: false,
        });
        await writeFile(
          path.join(evidenceDir, `${width}-${theme}.png`),
          Buffer.from(png.data, "base64"),
        );
      }
    }
    await webview.evaluate(
      "document.querySelector('.run-diagnostics>summary').focus()",
    );
    await key("Enter", "Enter", 13);
    await poll(
      () => webview.evaluate("!document.querySelector('.model-error-message')"),
      timeout,
      "keyboard collapse unmounts detail",
    );
    await webview.evaluate(`(() => {
      const button=[...document.querySelectorAll('.run-terminal-actions button')].find(item=>/打开模型设置|Open model settings/.test(item.textContent));
      if(!button || button.disabled)throw new Error('model settings recovery missing');button.click();
    })()`);
    assert.equal(provider.served, servedBefore + 1);
    await key("Escape", "Escape", 27);
    await webview.evaluate(`(() => {
      const button=[...document.querySelectorAll('.run-terminal-actions button')].find(item=>/重新填入指令|Copy instruction to Composer/.test(item.textContent));
      if(!button || button.disabled)throw new Error('prepare retry missing');button.click();
    })()`);
    await poll(
      () =>
        webview.evaluate(
          `(() => {const composer=document.querySelector('.composer-shell textarea');return composer?.value===${JSON.stringify(instruction)};})()`,
        ),
      timeout,
      "prepare retry only fills Composer",
    );
    assert.equal(provider.served, servedBefore + 1);
  } finally {
    webview.close();
  }
  const historyPath = path.join(
    dataRoot,
    "workbench",
    "workbench-history.sqlite",
  );
  const taskKey = Buffer.alloc(8);
  taskKey.writeBigUInt64BE(BigInt(taskId));
  const persisted = await poll(
    async () => {
      const database = new DatabaseSync(historyPath, { readOnly: true });
      try {
        const row = database
          .prepare(
            "SELECT model_error_json FROM runs WHERE task_id=? ORDER BY ordinal DESC LIMIT 1",
          )
          .get(taskKey);
        return row?.model_error_json ? JSON.parse(row.model_error_json) : null;
      } finally {
        database.close();
      }
    },
    timeout,
    "actual SQL writer commits safe error detail",
  );
  assert.equal(persisted.category, detail.category);
  assert.equal(persisted.source, detail.source);
  assert.equal(persisted.host_redacted, true);
  assert.equal(JSON.stringify(persisted).includes(hostOnlyCredential), false);
  await stop();
  assert.equal(
    (await readFile(historyPath)).includes(Buffer.from(hostOnlyCredential)),
    false,
  );
  const legacyPath = path.join(
    dataRoot,
    "workbench",
    "workbench-history.store",
  );
  const retiredBytes = Buffer.from(
    "retired, unreadable legacy source: preserve exact bytes\n",
  );
  await writeFile(legacyPath, retiredBytes);
  await restart();
  const restored = await readTask();
  assert.deepEqual(restored.runs.at(-1).terminal.modelError, detail);
  assert.deepEqual(await readFile(legacyPath), retiredBytes);
  assert.equal(
    provider.served,
    servedBefore + 1,
    "history restore must not contact provider",
  );
  webview = await connect();
  try {
    await selectTask();
    await webview.evaluate(
      "document.querySelector('.run-diagnostics>summary').click()",
    );
    await poll(
      () =>
        webview.evaluate(
          "document.querySelector('.model-error-message')?.textContent.includes('MODEL_ERROR_VERTICAL')",
        ),
      timeout,
      "cold history details remain visible",
    );
  } finally {
    webview.close();
  }
  await writeFile(
    path.join(evidenceDir, "result.json"),
    JSON.stringify(
      {
        platform: process.platform,
        taskId,
        runId: run.id,
        modelError: detail,
        hostCredentialScrubbed: true,
        accountAndModelsUnchanged: true,
        explicitSettingsAndComposerOnlyRetry: true,
        sqliteReopen: true,
        retiredStoreUnchanged: true,
        keyboardDisclosure: true,
        widths: [1320, 390],
        themes: ["light", "dark"],
      },
      null,
      2,
    ),
  );
  console.log(
    "Real AgentCore → Product → Bridge → Renderer → SQLite restart model-error acceptance passed:",
    evidenceDir,
  );
}
