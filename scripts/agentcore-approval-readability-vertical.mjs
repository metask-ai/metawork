import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { translate } from "../frontend/src/i18n/runtime.ts";
import {
  assertTaskFlag,
  assertTaskArchived,
  assertUiResponseAccepted,
} from "../frontend/src/bridge/decode-contracts.ts";

function textContrast(foreground, background) {
  const rgb = foreground
    .slice(0, 3)
    .map(
      (value, index) =>
        value * foreground[3] + background[index] * (1 - foreground[3]),
    );
  const luminance = (channels) =>
    channels.reduce((sum, value, index) => {
      const channel = value / 255;
      const linear =
        channel <= 0.04045
          ? channel / 12.92
          : ((channel + 0.055) / 1.055) ** 2.4;
      return sum + linear * [0.2126, 0.7152, 0.0722][index];
    }, 0);
  const values = [luminance(rgb), luminance(background)].sort((a, b) => a - b);
  return (values[1] + 0.05) / (values[0] + 0.05);
}

// Real Product/Bridge/Core and shipped Renderer, with synthetic model replies.
// Device metrics/theme scenarios exercise WebView content, not OS chrome/input.
export async function runApprovalReadabilityVertical({
  invoke,
  snapshot,
  poll,
  provider,
  toolSse,
  textSse,
  workspaceId,
  workspaceEpoch,
  workspaceRoot,
  webview,
  evidenceDir,
  expectMissing,
}) {
  const command =
    'powershell -NoProfile -Command "Write-Output APPROVAL_READABILITY"';
  const purpose = "Agent 声称仅下载公开说明。";
  const reason = "用途说明与实际命令不一致，需要你确认是否执行。";
  const observations = [];
  const wait = (operation, label) => poll(operation, 20_000, label);
  const accepted = (result) =>
    assert.equal(result.accepted, true, JSON.stringify(result));
  const key = async (value, code, virtual, modifiers = 0) => {
    await webview.send("Input.dispatchKeyEvent", {
      type: "keyDown",
      key: value,
      code,
      windowsVirtualKeyCode: virtual,
      modifiers,
      ...(value === "Enter" ? { text: "\r", unmodifiedText: "\r" } : {}),
    });
    await webview.send("Input.dispatchKeyEvent", {
      type: "keyUp",
      key: value,
      code,
      windowsVirtualKeyCode: virtual,
      modifiers,
    });
  };
  const click = async (selector, text = null) => {
    const point = await wait(
      () =>
        webview.evaluate(`(() => {
      const elements = [...document.querySelectorAll(${JSON.stringify(selector)})];
      const element = ${text === null ? "elements[0]" : `elements.find(item => (item.getAttribute('aria-label') || item.textContent.trim()) === ${JSON.stringify(text)})`};
      if (!element || element.disabled || element.getAttribute('aria-disabled') === 'true') return null;
      element.scrollIntoView({block:'nearest'});
      const r = element.getBoundingClientRect();
      if (!r.width || !r.height || r.left < 0 || r.right > innerWidth || r.top < 0 || r.bottom > innerHeight) return null;
      const point = {x:r.x+r.width/2,y:r.y+r.height/2};
      const hit = document.elementFromPoint(point.x, point.y);
      return hit && element.contains(hit) ? point : null;
    })()`),
      `readability click ${selector}`,
    );
    for (const type of ["mousePressed", "mouseReleased"])
      await webview.send("Input.dispatchMouseEvent", {
        type,
        button: "left",
        clickCount: 1,
        ...point,
      });
  };
  const metrics = async (width, theme) => {
    await webview.send("Emulation.setDeviceMetricsOverride", {
      width,
      height: 1080,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await webview.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "reduce" }],
    });
    await webview.evaluate(
      `document.documentElement.dataset.theme=${JSON.stringify(theme)}`,
    );
  };
  const setLocale = async (locale) => {
    if (
      await webview.evaluate(
        `document.documentElement.lang === ${JSON.stringify(locale)}`,
      )
    )
      return;
    await metrics(1320, "light");
    const current = await webview.evaluate("document.documentElement.lang");
    if (
      await webview.evaluate(
        `document.querySelector('[aria-controls="workspace-sidebar"]')?.getAttribute('aria-expanded') === 'false'`,
      )
    )
      await click('[aria-controls="workspace-sidebar"]');
    await click(".account-identity-trigger");
    await click(".account-menu-item", translate(current, "settings.title"));
    await click("#settings-language");
    await click(
      '[role="option"]',
      translate(current, `app.language.${locale}`),
    );
    await wait(
      () =>
        webview.evaluate(
          `document.documentElement.lang === ${JSON.stringify(locale)}`,
        ),
      "readability language applied",
    );
    await click(".settings-back");
    await wait(
      () => webview.evaluate("!document.querySelector('.settings-page')"),
      "readability settings closed",
    );
  };
  await mkdir(evidenceDir, { recursive: true });
  const report = path.join(evidenceDir, "readability.json");
  await writeFile(
    report,
    JSON.stringify({ status: "running", fixtureModelOnly: true }),
  );
  await webview.send("Page.bringToFront");
  await webview.send("Emulation.setFocusEmulationEnabled", { enabled: true });
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
    expectedSkillCatalogRevision: null,
    expectedSkillSelectionRevision: null,
    approvalMode: "auto_review",
  });
  accepted(created);
  const taskId = created.taskId;
  assertTaskFlag(
    await invoke("metawork.tasks.rename", {
      taskId,
      title: "Approval readability audit",
    }),
    taskId,
    "renamed",
  );
  const readTask = async () =>
    (await snapshot()).tasks.find((task) => task.id === taskId);
  const setMode = async (targetMode) => {
    const before = await readTask();
    accepted(
      await invoke("metawork.tasks.setApprovalMode", {
        taskId,
        targetMode,
        expectedBindingEpoch: before.binding.epoch,
        expectedApprovalRevision: before.approvalRevision,
      }),
    );
    return wait(async () => {
      const current = await readTask();
      return current.approvalMode === targetMode && !current.approvalChange
        ? current
        : null;
    }, `readability mode ${targetMode}`);
  };
  const start = async (input, tool, args, userText = input) => {
    provider.enqueue(
      toolSse(input, `${input}-tool`, tool, args),
      textSse(`${input}-done`, "Readability fixture completed after denial."),
    );
    const before = await readTask();
    const result = await invoke("metawork.tasks.run", {
      taskId,
      expectedBindingEpoch: before.binding.epoch,
      input: { kind: "text", text: userText },
    });
    accepted(result);
    return wait(async () => {
      const task = await readTask();
      const run = task.runs.find((item) => item.id === result.runId);
      if (run?.terminal && !task.pendingUi)
        throw new Error(
          `Readability fixture ${input} reached ${run.phase} without a permission request`,
        );
      return task.pendingUi?.runId === result.runId &&
        task.permissionReviewState ===
          (task.approvalMode === "auto_review" ? "needs_user" : "idle")
        ? task
        : null;
    }, "readability pending request");
  };
  const show = async (requestId) => {
    await metrics(1320, "light");
    await webview.send("Page.reload");
    await wait(
      () =>
        webview.evaluate(
          "[...document.querySelectorAll('.task-approval-trigger')].some(control => !control.disabled)",
        ),
      "readability Renderer ready",
    );
    await click(`.task-list-item[data-task-id="${taskId}"]`);
    await wait(
      () =>
        webview.evaluate(
          `Boolean(document.getElementById('ui-request-${requestId}'))`,
        ),
      "readability card visible",
    );
  };
  const capture = async (task, name, locale, width, theme, expected) => {
    await setLocale(locale);
    await metrics(width, theme);
    const id = `ui-request-${task.pendingUi.requestId}`;
    const selector = `#${id}`;
    const view = await wait(
      () =>
        webview.evaluate(`(() => {
      const card = document.getElementById(${JSON.stringify(id)});
      if (!card) return null;
      card.scrollIntoView({block:'start'});
      const toggle = card.querySelector('.approval-details-toggle');
      const command = [...card.querySelectorAll('pre.code-block-preview')].find(code => !code.closest('.approval-request-details'));
      const actions = [...card.querySelectorAll('.ai-intervention-actions button')];
      const canvas = document.createElement('canvas').getContext('2d');
      const color = value => {
        canvas.clearRect(0,0,1,1); canvas.fillStyle=value; canvas.fillRect(0,0,1,1);
        const rgba=[...canvas.getImageData(0,0,1,1).data]; rgba[3]/=255; return rgba;
      };
      const background = element => {
        const layers=[];
        for(let item=element;item;item=item.parentElement) layers.push(color(getComputedStyle(item).backgroundColor));
        return layers.reverse().reduce((base,layer) => base.map((value,index) => layer[index]*layer[3]+value*(1-layer[3])), [255,255,255]);
      };
      const appearance = [...card.querySelectorAll('h3,.approval-purpose,.approval-purpose span,.approval-target,.approval-concern,.approval-concern span,.approval-unavailable,.approval-details-toggle,.ai-intervention-actions button')]
        .filter(item => item.textContent.trim() && item.getClientRects().length)
        .map(item => ({label:item.textContent.slice(0,80),foreground:color(getComputedStyle(item).color),background:background(item)}));
      return { title: card.querySelector('h3').textContent, text: card.textContent,
        fieldCount:card.querySelectorAll('.detail-field-label').length,
        mainRows:1+card.querySelector('.ai-intervention-content').children.length,
        visibleCode: command?.textContent ?? null, collapsed: toggle.getAttribute('aria-expanded') === 'false',
        width: innerWidth, pageWidth: document.documentElement.scrollWidth,
        buttons: actions.map(button => {const r=button.getBoundingClientRect(); return {label:button.getAttribute('aria-label') || button.textContent.trim(),left:r.left,right:r.right,height:r.height};}),
        appearance, reducedMotion:matchMedia('(prefers-reduced-motion: reduce)').matches,
        theme:document.documentElement.dataset.theme, locale:document.documentElement.lang };
    })()`),
      `readability ${name}`,
    );
    assert.equal(
      view.title,
      translate(
        locale,
        expected.tool === "Write"
          ? "approval.action.write"
          : "approval.action.command",
        { target: expected.target ? path.basename(expected.target) : "" },
      ),
    );
    assert.equal(view.locale, locale);
    assert.equal(view.theme, theme);
    assert.equal(view.pageWidth, width);
    assert.equal(view.reducedMotion, true);
    assert.equal(view.fieldCount, 0);
    assert.ok(
      view.mainRows <= (!expected.manual && !expected.technical ? 5 : 4),
    );
    assert.equal(view.collapsed, true);
    for (const item of view.appearance) {
      item.contrast = textContrast(item.foreground, item.background);
      assert.ok(item.contrast >= 4.5, JSON.stringify(item));
    }
    for (const button of view.buttons) {
      assert.ok(
        button.left >= -1 && button.right <= width + 1,
        JSON.stringify(button),
      );
      assert.ok(button.height >= 44, JSON.stringify(button));
    }
    assert.ok(view.buttons.length >= 2);
    for (const id of [
      "approval.manual_mode",
      "approval.handoff.call_failed",
      "approval.handoff.reviewer_concern",
      "approval.command_effects",
      "approval.scope_once",
      "approval.session_expiry",
      "approval.why_again",
    ])
      assert.ok(
        !view.text.includes(translate(locale, id)),
        `default card leaked ${id}`,
      );
    if (expected.tool !== "Write") {
      assert.ok(
        view.text.includes(translate(locale, "approval.agent_purpose")),
      );
      assert.equal(
        view.visibleCode,
        expected.fallback ? null : expected.command,
      );
      if (expected.fallback) {
        assert.ok(
          view.text.includes(translate(locale, "approval.purpose_unavailable")),
        );
        assert.ok(
          view.text.includes(translate(locale, "approval.command_unavailable")),
        );
      } else {
        assert.ok(view.text.includes(purpose));
      }
    } else {
      assert.ok(view.text.includes(expected.target));
      assert.equal(view.collapsed, true);
    }
    assert.equal(
      view.text.includes(translate(locale, "approval.reviewer_note")),
      !expected.manual && !expected.technical,
    );
    if (!expected.manual && !expected.technical)
      assert.ok(view.text.includes(reason));
    {
      await webview.evaluate(
        `document.querySelector(${JSON.stringify(selector + " .approval-details-toggle")}).focus()`,
      );
      await key("Tab", "Tab", 9);
      assert.equal(
        await webview.evaluate(
          `document.activeElement === document.querySelector(${JSON.stringify(selector + " .ai-intervention-actions button")})`,
        ),
        true,
      );
      await key("Tab", "Tab", 9, 8);
      const focus = await webview.evaluate(
        `(() => {const summary=document.querySelector(${JSON.stringify(selector + " .approval-details-toggle")}); const style=getComputedStyle(summary); return {active:document.activeElement===summary,outline:style.outlineStyle,width:parseFloat(style.outlineWidth)};})()`,
      );
      assert.equal(focus.active, true);
      assert.notEqual(focus.outline, "none");
      assert.ok(focus.width > 0);
      await key("Enter", "Enter", 13);
      assert.equal(
        await webview.evaluate(
          `document.querySelector(${JSON.stringify(selector + " .approval-details-toggle")}).getAttribute('aria-expanded') === 'true'`,
        ),
        true,
      );
      const expanded = await webview.evaluate(
        `document.querySelector(${JSON.stringify(selector + " .approval-request-details")}).textContent`,
      );
      assert.ok(expanded.includes(task.pendingUi.args));
      if (expected.manual || expected.technical)
        assert.ok(
          expanded.includes(
            translate(
              locale,
              expected.manual
                ? "approval.manual_mode"
                : "approval.handoff.call_failed",
            ),
          ),
        );
      if (expected.tool !== "Write")
        assert.ok(
          expanded.includes(translate(locale, "approval.command_effects")),
        );
      if (expected.fallback) {
        await webview.evaluate(
          `document.querySelector(${JSON.stringify(selector + " .approval-request-details pre")}).focus()`,
        );
        await key("ArrowDown", "ArrowDown", 40);
        await wait(
          () =>
            webview.evaluate(
              `document.querySelector(${JSON.stringify(selector + " .approval-request-details pre")}).scrollTop > 0`,
            ),
          "raw arguments keyboard scroll",
        );
        await webview.evaluate(
          `document.querySelector(${JSON.stringify(selector + " .approval-details-toggle")}).focus()`,
        );
      }
      await key("Enter", "Enter", 13);
      view.keyboard = focus;
      view.detailsText = expanded;
      assert.equal(
        await webview.evaluate(
          `Boolean(document.querySelector(${JSON.stringify(selector + " .approval-request-details")}))`,
        ),
        false,
      );
    }
    const png = await webview.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      path.join(evidenceDir, `${name}.png`),
      Buffer.from(png.data, "base64"),
    );
    view.reachableActions = await wait(
      () =>
        webview.evaluate(`(() => {
      const buttons=[...document.querySelectorAll(${JSON.stringify(selector + " .ai-intervention-actions button")})];
      buttons.at(-1).scrollIntoView({block:'center'});
      const points=buttons.map(button => {
        const r=button.getBoundingClientRect(), hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);
        return { label:button.getAttribute('aria-label') || button.textContent.trim(),
          visible:r.top>=0 && r.bottom<=innerHeight, hit:Boolean(hit && button.contains(hit)) };
      });
      return points.every(point => point.visible && point.hit) ? points : null;
    })()`),
      "approval actions reachable above composer",
    );
    if (expected.fallback) {
      const actions = await webview.send("Page.captureScreenshot", {
        format: "png",
        captureBeyondViewport: false,
      });
      await writeFile(
        path.join(evidenceDir, `${name}-actions.png`),
        Buffer.from(actions.data, "base64"),
      );
    }
    if (expected.tool === "Write") {
      await click(
        `${selector} button`,
        translate(locale, "approval.more_allow_options"),
      );
      const labels = [
        ...(task.pendingUi.availableChoices.includes("allow_session")
          ? [translate(locale, "approval.allow_session_file")]
          : []),
        ...(task.pendingUi.availableChoices.includes("deny_session")
          ? [translate(locale, "approval.deny_session_file")]
          : []),
      ];
      await wait(
        () =>
          webview.evaluate(`(() => {
        const items=[...document.querySelectorAll('.approval-choice-menu [role="menuitem"]')].filter(item=>item.getClientRects().length);
        const labels=${JSON.stringify(labels)};
        return items.length===labels.length && items.every(item=>labels.includes(item.textContent.trim()));
      })()`),
        "file Session menu preserves exact available choice",
      );
      await key("Escape", "Escape", 27);
      await wait(
        () =>
          webview.evaluate(
            `document.activeElement?.getAttribute('aria-label') === ${JSON.stringify(translate(locale, "approval.more_allow_options"))}`,
          ),
        "file Session menu restores focus",
      );
    }
    observations.push({ name, ...view });
  };
  const deny = async (task) => {
    assertUiResponseAccepted(
      await invoke("metawork.tasks.respondUi", {
        taskId,
        runId: task.pendingUi.runId,
        requestId: task.pendingUi.requestId,
        kind: "permission",
        permission: "deny_once",
      }),
      taskId,
      task.pendingUi.runId,
      task.pendingUi.requestId,
    );
    await wait(async () => {
      const current = await readTask();
      return !current.activeOperation &&
        current.runs.find((run) => run.id === task.pendingUi.runId)?.terminal
        ? current
        : null;
    }, "readability denial terminal");
  };
  try {
    let task = await start(
      "approval-readable-review",
      "Bash",
      {
        command,
        description: purpose,
      },
      "请检查审批请求，确认这条命令的用途。",
    );
    assert.equal(task.permissionReviewExplanation.cause, "reviewer_concern");
    assert.equal(task.permissionReviewExplanation.reason, reason);
    assert.equal(provider.readabilityReviewRequests, 1);
    await show(task.pendingUi.requestId);
    for (const locale of ["zh-CN", "en-US"])
      for (const width of [1320, 390])
        for (const theme of ["light", "dark"])
          await capture(
            task,
            `review-${locale}-${width}-${theme}`,
            locale,
            width,
            theme,
            { command },
          );
    task = await setMode("manual");
    assert.equal(task.permissionReviewExplanation, null);
    await show(task.pendingUi.requestId);
    await capture(task, "manual-zh-CN-1320-light", "zh-CN", 1320, "light", {
      manual: true,
      command,
    });
    await deny(task);
    const longCommand = `powershell -NoProfile -Command "Write-Output '${"x".repeat(8 * 1024)}'"`;
    task = await start("approval-readable-fallback", "Bash", {
      command: longCommand,
      description: purpose,
    });
    assert.equal(task.pendingUi.presentation, null);
    await show(task.pendingUi.requestId);
    await capture(task, "fallback-en-US-390-dark", "en-US", 390, "dark", {
      manual: true,
      fallback: true,
    });
    await deny(task);
    // Ordinary in-Workspace writes are already permitted by Core. Exercise
    // the file-target prompt with a sibling in this test's owned temp root.
    const target = path.resolve(workspaceRoot, "..", "approval-readable.txt");
    await expectMissing(target);
    task = await start("approval-readable-write", "Write", {
      file_path: target,
      content: "synthetic fixture",
    });
    assert.equal(task.pendingUi.presentation.kind, "write");
    assert.ok(task.pendingUi.availableChoices.includes("allow_session"));
    await show(task.pendingUi.requestId);
    for (const [locale, width, theme] of [
      ["zh-CN", 390, "light"],
      ["en-US", 1320, "dark"],
    ])
      await capture(
        task,
        `write-${locale}-${width}-${theme}`,
        locale,
        width,
        theme,
        {
          manual: true,
          tool: "Write",
          target: task.pendingUi.presentation.target,
        },
      );
    await deny(task);
    await expectMissing(target);
    await setMode("auto_review");
    task = await start(
      "approval-readable-service-failure",
      "Bash",
      { command, description: purpose },
      "请检查这条命令的审批服务故障提示。",
    );
    assert.equal(task.permissionReviewExplanation.cause, "call_failed");
    assert.equal(task.permissionReviewExplanation.reason, null);
    assert.equal(provider.technicalReviewRequests, 1);
    await show(task.pendingUi.requestId);
    for (const [locale, width, theme] of [
      ["zh-CN", 390, "light"],
      ["en-US", 1320, "dark"],
    ])
      await capture(
        task,
        `service-failure-${locale}-${width}-${theme}`,
        locale,
        width,
        theme,
        { technical: true, command },
      );
    await deny(task);
    await writeFile(
      report,
      JSON.stringify(
        { status: "passed", taskId, fixtureModelOnly: true, observations },
        null,
        2,
      ),
    );
    assertTaskArchived(
      await invoke("metawork.tasks.archive", { taskId, archived: true }),
      taskId,
      true,
    );
    assertTaskFlag(
      await invoke("metawork.tasks.delete", { taskId }),
      taskId,
      "deleting",
    );
    console.log(
      `Approval readability desktop WebView passed: ${observations.length} views; real scoped data, reviewer/manual/fallback/file sources, visible commands, keyboard and bounds. Fixture replies do not prove model judgment.`,
    );
  } catch (error) {
    await writeFile(
      report,
      JSON.stringify(
        {
          status: "failed",
          taskId,
          fixtureModelOnly: true,
          failure: error.message,
          observations,
        },
        null,
        2,
      ),
    );
    const image = await webview.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      path.join(evidenceDir, "failed.png"),
      Buffer.from(image.data, "base64"),
    );
    throw error;
  } finally {
    await webview.send("Emulation.clearDeviceMetricsOverride");
    await webview.send("Emulation.setEmulatedMedia", { features: [] });
    await webview.send("Emulation.setFocusEmulationEnabled", {
      enabled: false,
    });
  }
}
