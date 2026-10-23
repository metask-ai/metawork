import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { enUS } from "../frontend/src/i18n/messages/en-US.ts";
import { zhCN } from "../frontend/src/i18n/messages/zh-CN.ts";

// Drive the real settings/Composer and scripted Provider, never a second
// concurrent snapshot consumer. Installation and all authority are real.
export async function runOfficeInstallVertical({
  root,
  dataRoot,
  workspaceId,
  workspaceEpoch,
  invoke,
  snapshot,
  poll,
  provider,
  toolSse,
  textSse,
  connectWebView,
  restart,
  hostPid,
  evidenceDirectory,
}) {
  assert.equal(process.platform, "win32");
  assert.equal(process.arch, "x64");
  assert.equal(process.env.METAWORK_LOCAL_SKILL_ROOT, undefined);
  const input = JSON.parse(
    await readFile(
      path.join(
        root,
        "build_support/office-component-release.windows-x64.json",
      ),
      "utf8",
    ),
  );
  assert.ok(input.release, "A qualified main-pinned release is required");
  const store = path.join(dataRoot, "office/windows-x64");
  const evidence = {
    scope:
      "Real Windows Automation App/Core/Renderer, public HTTPS and strict signed installation; scripted Provider, not remote-model quality or clean machine",
    milestones: [],
    skills: [],
    runs: [],
  };
  const names = ["docx", "xlsx", "pptx"];
  const definitions = {};
  for (const name of names) {
    definitions[name] = {};
    for (const kind of ["basic", "full"]) {
      const filename = path.join(
        root,
        kind === "basic"
          ? "src/app/basic_office_skills"
          : "src/product/skill/assets",
        name,
        "SKILL.md",
      );
      const source = (await readFile(filename, "utf8")).replaceAll(
        "\r\n",
        "\n",
      );
      definitions[name][kind] = {
        description: source.match(/^description: (.+)$/mu)?.[1],
        bodyStart: source
          .replace(/^---\n[\s\S]*?\n---\n/u, "")
          .trim()
          .split("\n")[0],
      };
      assert.ok(definitions[name][kind].description);
    }
  }
  await mkdir(evidenceDirectory, { recursive: true });
  async function save() {
    await writeFile(
      path.join(evidenceDirectory, "office-install.json"),
      JSON.stringify(evidence, null, 2) + "\n",
    );
  }
  const labels = (key) => [enUS[key], zhCN[key]];
  let webview;
  let currentRoot;
  async function attach() {
    webview = await connectWebView();
    await webview.evaluate(`(() => {
      window.__officeInstallActions = []; window.__officeInstallInputs = [];
      const transport = chrome.webview, post = transport.postMessage;
      transport.postMessage = function(message) {
        const e = typeof message === 'string' ? JSON.parse(message) : message;
        if (e.command?.startsWith('metawork.office.')) window.__officeInstallActions.push({ command: e.command, payload: e.payload });
        if (e.command === 'metawork.tasks.sendInput') window.__officeInstallInputs.push(e.payload);
        return post.call(this, message);
      };
    })()`);
  }
  async function openSettings() {
    if (
      await webview.evaluate(
        `Boolean(document.querySelector('[data-office-component]'))`,
      )
    )
      return;
    await poll(
      () =>
        webview.evaluate(
          `Boolean(document.querySelector('.account-identity button'))`,
        ),
      20_000,
      "Office account menu",
    );
    await webview.evaluate(
      `document.querySelector('.account-identity button').click()`,
    );
    await poll(
      () =>
        webview.evaluate(`(() => {
        const button = [...document.querySelectorAll('.account-menu-item')].find(e => /Settings|设置/.test(e.textContent));
        if (!button) return false; button.click(); return true;
      })()`),
      5000,
      "Office settings menu",
    );
    await poll(
      () =>
        webview.evaluate(
          `Boolean(document.querySelector('[data-office-component]'))`,
        ),
      10_000,
      "Office settings opened",
    );
  }
  async function selectTask(id) {
    if (
      await webview.evaluate(
        `Boolean(document.querySelector('.settings-page'))`,
      )
    ) {
      await webview.evaluate(`(() => {
        const back = [...document.querySelectorAll('button')].find(e => ${JSON.stringify(labels("settings.back"))}.includes(e.textContent.trim()));
        if (!back) throw Error('Settings back button missing'); back.click();
      })()`);
    }
    await poll(
      () =>
        webview.evaluate(`(() => {
        const row = [...document.querySelectorAll('.task-list-item')].find(e => e.dataset.taskId === ${JSON.stringify(id)});
        if (!row) return false;
        if (row.getAttribute('aria-current') !== 'page') { row.click(); return false; }
        return Boolean(document.querySelector('.composer-shell textarea:not(:disabled)'));
      })()`),
      20_000,
      "Office Task selected",
    );
  }
  async function run(id, label, marker, fixtures) {
    provider.enqueue(...fixtures);
    await selectTask(id);
    const before = await webview.evaluate(
      `window.__officeInstallInputs.length`,
    );
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
      "Office input ready",
    );
    await webview.evaluate(`document.querySelector('.composer-send').click()`);
    const request = await poll(
      () => webview.evaluate(`window.__officeInstallInputs[${before}] ?? null`),
      5000,
      "Office input submitted",
    );
    assert.equal(request.taskId, id);
    evidence.runs.push({
      taskId: id,
      operationId: request.operationId,
      marker,
    });
    await poll(
      () => {
        if (provider.error) throw provider.error;
        return webview.evaluate(
          `document.body.innerText.includes(${JSON.stringify(marker)}) && document.querySelector('.composer-stop') === null`,
        );
      },
      120_000,
      `Office ${label} completed`,
    );
    assert.equal(
      await webview.evaluate(`window.__officeInstallInputs.length`),
      before + 1,
    );
    return request.operationId;
  }
  function verifyRuns(current, cold = false) {
    for (const expected of evidence.runs) {
      const run = current.tasks
        .find((task) => task.id === expected.taskId)
        ?.runs.find(
          (item) => item.submission?.operationId === expected.operationId,
        );
      assert.ok(run, `Submitted operation missing: ${expected.operationId}`);
      assert.equal(
        run.terminal?.outcome,
        "completed",
        JSON.stringify(run.terminal),
      );
      if (cold)
        assert.equal(
          run.id,
          expected.runId,
          "Cold recovery changed Run identity",
        );
      else expected.runId = run.id;
    }
  }
  function catalogIs(catalog, kind) {
    return (
      catalog?.availability === "ready" &&
      names.every((name) => {
        const skill = catalog.skills.find(
          (item) => item.invocationName === name,
        );
        return (
          skill?.enabled &&
          skill.description === definitions[name][kind].description
        );
      })
    );
  }
  async function createTask(title, catalog) {
    const current = await snapshot();
    const created = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },
      expectedExecutionGeneration: current.newTaskAdmission.activeGeneration,
      expectedSelectionRevision:
        current.newTaskAdmission.activeSelectionRevision,
      modelSelection: null,
      expectedSkillCatalogRevision: catalog.revision,
      expectedSkillSelectionRevision: catalog.selectionRevision,
      approvalMode: "full_access",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    await invoke("metawork.tasks.rename", { taskId: created.taskId, title });
    return created;
  }
  function result(payload, toolId) {
    const returned = payload.messages
      .flatMap((message) =>
        Array.isArray(message.content) ? message.content : [],
      )
      .findLast(
        (part) => part.type === "tool_result" && part.tool_use_id === toolId,
      );
    assert.ok(
      returned && returned.is_error !== true,
      `Tool failed: ${toolId}: ${JSON.stringify(returned)}`,
    );
    return returned;
  }
  async function skills(task, kind, tag, execute = false) {
    const fixtures = [];
    for (const name of names) {
      const toolId = `${tag}-${name}`;
      let historyLength;
      fixtures.push((payload) => {
        historyLength = payload.messages.length;
        return toolSse(`${tag}-invoke-${name}`, toolId, "Skill", { name });
      });
      fixtures.push((payload) => {
        result(payload, toolId);
        const strings = [];
        const visit = (value) => {
          if (typeof value === "string")
            strings.push(value.replaceAll("\r\n", "\n"));
          else if (Array.isArray(value)) value.forEach(visit);
          else if (value && typeof value === "object")
            Object.values(value).forEach(visit);
        };
        visit(payload.messages.slice(historyLength));
        const body = strings.findLast((text) =>
          text.includes(definitions[name][kind].bodyStart),
        );
        assert.ok(
          body,
          `Actual ${name} ${kind} instructions did not reach Provider`,
        );
        let resource = null;
        if (kind === "full") {
          resource = [
            ...body.matchAll(/Skill resource directory: `([^`]+)`/gu),
          ].at(-1)?.[1];
          assert.ok(
            resource && path.isAbsolute(resource),
            "Skill path was not expanded",
          );
          assert.equal(
            path.resolve(resource),
            path.join(currentRoot, "skills", name),
          );
        } else assert.ok(!body.includes("Skill resource directory:"));
        evidence.skills.push({ tag, name, kind, resource });
        return textSse(`${tag}-checked-${name}`, `${tag}_${name}_CHECKED`);
      });
    }
    // The execution path is selected from the actual complete Skill body and
    // checked against the App's committed component, never from dev selection.
    if (execute) {
      fixtures.push(() => {
        const resource = evidence.skills.findLast(
          (item) => item.tag === tag && item.name === "docx",
        ).resource;
        const entry = path.resolve(resource, "../../bin/office.exe");
        const script = `& '${entry.replaceAll("'", "''")}' selftest; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }`;
        return toolSse(`${tag}-selftest`, `${tag}-shell`, "Bash", {
          command: `powershell -NoProfile -NonInteractive -EncodedCommand ${Buffer.from(script, "utf16le").toString("base64")}`,
          description:
            "Check installed Office runtime through the actual Skill entry",
          timeout: 120000,
        });
      });
      fixtures.push((payload) => {
        const returned = result(payload, `${tag}-shell`);
        assert.match(
          JSON.stringify(returned.content),
          /status[\\"\s:]+success/u,
        );
        evidence.actualCoreShellSelftest = true;
        return textSse(`${tag}-shell-done`, `${tag}_SHELL_CHECKED`);
      });
    }
    // Each fixture response which only says CHECKED ends that model turn.
    // Queue the next request using a separate Composer turn so completion is
    // driven by Core's normal end_turn rather than an invented continuation.
    for (let index = 0; index < names.length; index++) {
      const name = names[index];
      await run(
        task.taskId,
        `Inspect ${kind} ${name} Skill (${tag})`,
        `${tag}_${name}_CHECKED`,
        fixtures.slice(index * 2, index * 2 + 2),
      );
    }
    if (execute)
      await run(
        task.taskId,
        `Execute installed Office selftest (${tag})`,
        `${tag}_SHELL_CHECKED`,
        fixtures.slice(6, 8),
      );
    await save();
  }
  try {
    await attach();
    const before = await poll(
      async () => {
        const current = await snapshot();
        const workspace = current.workspaces.find(
          (item) => item.id === workspaceId,
        );
        return catalogIs(workspace?.skillCatalog, "basic") ? current : null;
      },
      20_000,
      "Initial basic Office catalog",
    );
    assert.equal(before.office.current, null);
    assert.equal(before.office.operation, null);
    const basic = before.workspaces.find(
      (item) => item.id === workspaceId,
    ).skillCatalog;
    const oldTask = await createTask("Office before installation", basic);
    evidence.oldTask = oldTask;
    await skills(oldTask, "basic", "before");
    const oldCatalog = (await snapshot()).tasks.find(
      (item) => item.id === oldTask.taskId,
    ).skillCatalog;
    assert.ok(catalogIs(oldCatalog, "basic"));
    assert.deepEqual(
      await webview.evaluate(`window.__officeInstallActions`),
      [],
    );
    evidence.milestones.push(
      "Basic Skills and ordinary Task before installation",
    );
    await openSettings();
    await poll(
      () =>
        webview.evaluate(`(() => {
      const button = [...document.querySelectorAll('[data-office-component] button')].find(e => ${JSON.stringify(labels("office.install"))}.includes(e.textContent.trim()));
      if (!button || button.disabled) return false; button.click(); return true;
    })()`),
      10_000,
      "Real Office install button",
    );
    const installedRequest = await poll(
      () => webview.evaluate(`window.__officeInstallActions[0] ?? null`),
      5000,
      "Office install intent",
    );
    assert.equal(installedRequest.command, "metawork.office.install");
    assert.deepEqual(Object.keys(installedRequest.payload), [
      "expectedGeneration",
    ]);
    await poll(
      () =>
        webview.evaluate(
          `Boolean(document.querySelector('.settings-office-progress'))`,
        ),
      20_000,
      "Actual download progress",
    );
    evidence.installStartedAt = new Date().toISOString();
    evidence.installRequest = installedRequest;
    await run(
      oldTask.taskId,
      "Continue ordinary work while Office installs",
      "ORDINARY_DURING_INSTALL",
      [textSse("ordinary-during", "ORDINARY_DURING_INSTALL")],
    );
    await assert.rejects(readFile(path.join(store, "current.json")), {
      code: "ENOENT",
    });
    await stat(path.join(store, "pending.json"));
    evidence.milestones.push(
      "Actual Core ordinary Task completed during installation",
    );
    await openSettings();
    let previousPhase = null;
    const installation = await poll(
      async () => {
        if (provider.error) throw provider.error;
        const view = await webview.evaluate(`(() => {
        const group = document.querySelector('[data-office-component]');
        return { ready: group?.querySelector('.settings-office-status')?.dataset.ready === 'true',
          phase: group?.querySelector('.settings-office-operation [role=status]')?.textContent,
          error: group?.querySelector('[role=alert]')?.textContent,
          text: group?.textContent, progress: group?.querySelector('[role=progressbar]')?.getAttribute('aria-valuenow') };
      })()`);
        if (view.error) return view;
        if (view.phase !== previousPhase) {
          previousPhase = view.phase;
          evidence.milestones.push({
            phase: view.phase ?? "terminal",
            at: new Date().toISOString(),
            progress: view.progress,
          });
          await save();
          process.stdout.write(
            `Office App installation phase: ${view.phase ?? "terminal"}\n`,
          );
        }
        return view.ready ? view : null;
      },
      30 * 60_000,
      "Actual App strict public installation ready",
    );
    if (installation.error)
      throw Error(`Actual App installation failed: ${installation.error}`);
    const committed = JSON.parse(
      await readFile(path.join(store, "current.json"), "utf8"),
    );
    assert.equal(committed.archiveSha256, input.release.archiveSha256);
    currentRoot = path.join(store, "versions", committed.installId);
    const manifestBytes = await readFile(
      path.join(currentRoot, "office-runtime.json"),
    );
    assert.equal(
      createHash("sha256").update(manifestBytes).digest("hex"),
      input.release.manifestSha256,
    );
    const host = await readFile(path.join(store, "host.scope"));
    assert.equal(host.length, 24);
    assert.equal(host.subarray(0, 8).toString("ascii"), "MWOFS001");
    assert.equal(host.readUInt32LE(8), hostPid());
    assert.equal(host.readUInt32LE(12), 0);
    await assert.rejects(readFile(path.join(store, "pending.json")), {
      code: "ENOENT",
    });
    assert.deepEqual(await readdir(path.join(store, "staging")), []);
    evidence.committed = committed;
    evidence.componentManifestSha256 = input.release.manifestSha256;
    const after = await poll(
      async () => {
        const current = await snapshot();
        return catalogIs(
          current.workspaces.find((item) => item.id === workspaceId)
            ?.skillCatalog,
          "full",
        )
          ? current
          : null;
      },
      20_000,
      "Full Workspace catalog after installation",
    );
    assert.deepEqual(
      after.tasks.find((item) => item.id === oldTask.taskId).skillCatalog,
      oldCatalog,
    );
    await skills(oldTask, "basic", "still-basic");
    const newTask = await createTask(
      "Office after installation",
      after.workspaces.find((item) => item.id === workspaceId).skillCatalog,
    );
    evidence.newTask = newTask;
    await skills(newTask, "full", "new-full", true);
    const refreshed = await invoke("metawork.tasks.refreshSkillCatalog", {
      taskId: oldTask.taskId,
      expectedBindingEpoch: oldTask.bindingEpoch,
    });
    assert.equal(refreshed.accepted, true, JSON.stringify(refreshed));
    await poll(
      async () =>
        catalogIs(
          (await snapshot()).tasks.find((item) => item.id === oldTask.taskId)
            ?.skillCatalog,
          "full",
        ),
      20_000,
      "Explicit idle refresh adopts full catalog",
    );
    await skills(oldTask, "full", "refreshed-full");
    verifyRuns(await snapshot());
    evidence.milestones.push(
      "New Task full; existing Task unchanged until explicit refresh",
    );
    webview.close();
    webview = undefined;
    await restart();
    await attach();
    await openSettings();
    const coldStatus = await poll(
      async () => {
        const status = await webview.evaluate(`(() => {
          const group = document.querySelector('[data-office-component]');
          return { ready: group?.querySelector('.settings-office-status')?.dataset.ready === 'true',
            error: group?.querySelector('[role=alert]')?.textContent,
            downloading: Boolean(group?.querySelector('.settings-office-progress')) };
        })()`);
        return status.ready || status.error || status.downloading
          ? status
          : null;
      },
      10 * 60_000,
      "Installed component verified on cold startup",
    );
    assert.equal(
      coldStatus.downloading,
      false,
      "Cold startup started a new download",
    );
    assert.equal(
      coldStatus.error,
      undefined,
      `Cold component verification failed: ${coldStatus.error}`,
    );
    assert.deepEqual(
      JSON.parse(await readFile(path.join(store, "current.json"), "utf8")),
      committed,
    );
    assert.deepEqual(
      await webview.evaluate(`window.__officeInstallActions`),
      [],
    );
    const cold = await poll(
      async () => {
        const current = await snapshot();
        return catalogIs(
          current.workspaces.find((item) => item.id === workspaceId)
            ?.skillCatalog,
          "full",
        )
          ? current
          : null;
      },
      20_000,
      "Cold Workspace current catalog",
    );
    const prepared = await invoke("metawork.tasks.refreshSkillCatalog", {
      taskId: oldTask.taskId,
      expectedBindingEpoch: cold.tasks.find(
        (item) => item.id === oldTask.taskId,
      ).binding.epoch,
    });
    verifyRuns(cold, true);
    assert.equal(prepared.accepted, true, JSON.stringify(prepared));
    await skills(oldTask, "full", "cold-full", true);
    verifyRuns(await snapshot());
    assert.equal(provider.error, null);
    evidence.milestones.push(
      "Cold startup preserves component; explicit preparation and real Core Shell work without reinstallation",
    );
    evidence.passed = true;
    await openSettings();
    const screenshot = await webview.send("Page.captureScreenshot", {
      format: "png",
    });
    await writeFile(
      path.join(evidenceDirectory, "office-installed.png"),
      Buffer.from(screenshot.data, "base64"),
    );
    await save();
    return evidence;
  } catch (error) {
    evidence.failure = error.message;
    if (webview) {
      try {
        evidence.ui = await webview.evaluate(
          `({ body: document.body.innerText.slice(0,16000), actions: window.__officeInstallActions, inputs: window.__officeInstallInputs })`,
        );
        const screenshot = await webview.send("Page.captureScreenshot", {
          format: "png",
        });
        await writeFile(
          path.join(evidenceDirectory, "office-failure.png"),
          Buffer.from(screenshot.data, "base64"),
        );
      } catch (captureError) {
        evidence.captureFailure = captureError.message;
      }
    }
    await save();
    throw error;
  } finally {
    webview?.close();
  }
}
