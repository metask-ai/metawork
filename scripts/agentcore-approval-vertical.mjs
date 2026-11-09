import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import assert from "node:assert/strict";

// Real Product/Bridge/Core integration; fixture model replies do not claim
// permission-review quality or replace Core with a fake implementation.
export async function runApprovalModeVertical({
  invoke,
  invokePreparedRun,
  snapshot,
  poll,
  provider,
  toolSse,
  textSse,
  backgroundTool,
  checkpoint,
  checkpointHealth,
  workspaceId,
  workspaceEpoch,
  markerPath,
  expectMissing,
  selectRenderedMode,
}) {
  const observations = [];
  const readTask = async (id) =>
    (await snapshot()).tasks.find((task) => task.id === id);
  const modelSnapshot = await snapshot();
  const create = async (workspace, title) => {
    const result = await invoke("metawork.tasks.create", {
      workspace,

      modelSelection: fixtureModelSelection(modelSnapshot),
      expectedSkillCatalogRevision: null,
      expectedSkillSelectionRevision: null,
      approvalMode: "manual",
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    await invoke("metawork.tasks.rename", { taskId: result.taskId, title });
    return readTask(result.taskId);
  };
  const task = await create(
    { kind: "manual", workspaceId, expectedWorkspaceEpoch: workspaceEpoch },
    "Approval mode audit",
  );
  const taskId = task.id;
  const initialDefaults = (await snapshot()).permissions;
  let revision = task.approvalRevision;
  let coreChanges = 0;
  let sessionId;
  const observe = (label, current) => {
    assert.equal(current.id, taskId);
    assert.equal(current.workspaceId, workspaceId);
    assert.equal(current.approvalRevision, revision);
    observations.push({
      label,
      taskId,
      mode: current.approvalMode,
      revision,
      bindingEpoch: current.binding.epoch,
      runs: current.runs.length,
      requests: current.uiHistory.length,
    });
    console.log(
      `AgentCore approval progress: ${label}; revision=${revision}; mode=${current.approvalMode}`,
    );
    return current;
  };
  const setMode = async (targetMode, renderer = false) => {
    const before = await readTask(taskId);
    const next =
      before.approvalMode === targetMode
        ? revision
        : String(BigInt(revision) + 1n);
    if (renderer) await selectRenderedMode(taskId, targetMode);
    else {
      const result = await invoke("metawork.tasks.setApprovalMode", {
        taskId,
        targetMode,
        expectedBindingEpoch: before.binding.epoch,
        expectedApprovalRevision: revision,
      });
      assert.deepEqual(result, {
        accepted: true,
        taskId,
        approvalRevision: next,
        reason: null,
      });
    }
    const current = await poll(
      async () => {
        const current = await readTask(taskId);
        if (current?.approvalResult?.outcome === "failed")
          throw new Error(
            `mode switch failed: ${JSON.stringify(current.approvalResult)}`,
          );
        return current?.approvalRevision === next &&
          current.approvalMode === targetMode &&
          !current.approvalChange
          ? current
          : null;
      },
      30_000,
      `approval ${before.approvalMode} to ${targetMode}`,
    );
    if (
      (before.approvalMode === "full_access") !==
      (targetMode === "full_access")
    )
      coreChanges++;
    revision = next;
    assert.deepEqual((await snapshot()).permissions, initialDefaults);
    return observe(`mode:${targetMode}`, current);
  };
  const start = async (input, entries) => {
    provider.enqueue(...entries);
    const current = await readTask(taskId);
    const result = await invokePreparedRun({
      taskId,
      expectedBindingEpoch: current.binding.epoch,
      input: { kind: "text", text: input },
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    return result.runId;
  };
  const pending = async (runId) =>
    poll(
      async () => {
        const current = await readTask(taskId);
        return current.pendingUi?.runId === runId ? current.pendingUi : null;
      },
      30_000,
      "mode audit permission request",
    );
  const answer = async (request, permission) =>
    invoke("metawork.tasks.respondUi", {
      taskId,
      runId: request.runId,
      requestId: request.requestId,
      kind: "permission",
      permission,
    });
  const terminal = async (
    runId,
    { noUi = false, phase = "completed" } = {},
  ) => {
    const current = await poll(
      async () => {
        const current = await readTask(taskId);
        if (noUi)
          assert.equal(
            current.pendingUi,
            null,
            "Session grant/no-prompt execution requested permission",
          );
        const run = current.runs.find((run) => run.id === runId);
        return run?.terminal && !current.activeOperation ? current : null;
      },
      30_000,
      `mode audit Run ${runId} terminal`,
    );
    const run = current.runs.find((run) => run.id === runId);
    assert.equal(run.phase, phase, JSON.stringify(run.terminal));
    if (phase === "cancelled") assert.equal(run.terminal.cause, "user_cancel");
    return observe(`run:${runId}:${phase}`, current);
  };
  const checkedCheckpoint = async (kind, id) => {
    const current = await readTask(taskId);
    const proof = await poll(
      () => checkpoint(taskId, kind, id, current.binding.epoch),
      30_000,
      "mode audit durable checkpoint",
    );
    if (sessionId)
      assert.equal(
        proof.sessionId,
        sessionId,
        "switch or restore replaced the logical Session",
      );
    else sessionId = proof.sessionId;
    assert.ok(sessionId);
    return proof;
  };
  const command = 'powershell -NoProfile -Command "Write-Output MODE_GRANT"';
  const runGrant = async (label) =>
    start(label, [
      toolSse(label, `${label}-tool`, "Bash", { command }),
      textSse(`${label}-done`, `${label} completed`),
    ]);
  const grantTerminal = async (
    runId,
    { denied = false, noUi = false } = {},
  ) => {
    const current = await terminal(runId, { noUi });
    const tool = current.runs
      .find((run) => run.id === runId)
      .tools.find((tool) => tool.name === "Bash");
    assert.ok(tool);
    assert.equal(tool.isError, denied);
    assert.equal(tool.state, denied ? "failed" : "completed");
    if (!denied) {
      assert.equal(tool.bash.result.exitCode, 0);
      assert.ok(tool.bash.result.stdout.includes("MODE_GRANT"));
    }
    return current;
  };
  const firstRun = await runGrant("mode-grant-seed");
  const firstRequest = await pending(firstRun);
  assert.deepEqual(firstRequest.presentation, {
    kind: "command",
    command,
    description: null,
  });
  assert.ok(firstRequest.availableChoices.includes("allow_session"));
  const initialGeneration = BigInt(firstRequest.policyGeneration);
  await answer(firstRequest, "allow_session");
  await grantTerminal(firstRun);
  await checkedCheckpoint("run", firstRun);

  const reviewRun = await start("mode-review-current-request", [
    toolSse("mode-review", "mode-review-tool", "Bash", {
      command: 'powershell -NoProfile -Command "Write-Output MODE_REVIEW"',
    }),
    textSse("mode-review-done", "mode review manual decision completed"),
  ]);
  const reviewRequest = await pending(reviewRun);
  await setMode("auto_review");
  await poll(
    async () => provider.reviewRequests === 1,
    30_000,
    "real review Completion admission",
  );
  await setMode("manual");
  provider.releaseReview();
  await new Promise((resolve) => setTimeout(resolve, 400));
  const stillPending = await readTask(taskId);
  assert.equal(stillPending.pendingUi?.requestId, reviewRequest.requestId);
  assert.equal(stillPending.permissionReviewState, "idle");
  assert.equal(
    stillPending.uiHistory.some(
      (entry) =>
        entry.requestId === reviewRequest.requestId &&
        entry.answeredBy === "reviewer",
    ),
    false,
  );
  assert.equal(provider.reviewRequests, 1);
  await answer(reviewRequest, "allow_once");
  await terminal(reviewRun);
  await setMode("manual");
  const reuseRun = await runGrant("mode-grant-noop-reuse");
  await grantTerminal(reuseRun, { noUi: true });

  const cancelledRun = await start("mode-switch-cancelled-tool", [
    toolSse("mode-cancel", "mode-cancel-tool", "Bash", {
      command: `powershell -NoProfile -Command "Set-Content -LiteralPath '${markerPath}' -Value unexpected"`,
    }),
  ]);
  await pending(cancelledRun);
  const switched = await setMode("full_access", true);
  assert.equal(switched.pendingUi, null);
  await terminal(cancelledRun, { phase: "cancelled" });
  await expectMissing(markerPath);
  await checkedCheckpoint("approval", revision);
  assert.equal(
    (await readTask(taskId)).runs.every(
      (run) => run.permissionProfile === "approval_required",
    ),
    true,
  );
  const fullRun = await runGrant("mode-full-continuation");
  const fullTask = await grantTerminal(fullRun, { noUi: true });
  assert.equal(
    fullTask.runs.find((run) => run.id === fullRun).permissionProfile,
    "full_access",
  );
  await checkedCheckpoint("run", fullRun);
  await setMode("manual");
  const denyRun = await runGrant("mode-grant-revoked");
  const revokedRequest = await pending(denyRun);
  assert.equal(
    BigInt(revokedRequest.policyGeneration),
    initialGeneration + BigInt(coreChanges),
  );
  assert.ok(revokedRequest.availableChoices.includes("deny_session"));
  await answer(revokedRequest, "deny_session");
  await grantTerminal(denyRun, { denied: true });
  await setMode("manual");
  const denyReuseRun = await runGrant("mode-deny-noop-reuse");
  await grantTerminal(denyReuseRun, { denied: true, noUi: true });
  await setMode("full_access");
  const denyRevokedRun = await runGrant("mode-deny-revoked");
  await grantTerminal(denyRevokedRun, { noUi: true });
  await setMode("manual");

  await setMode("full_access");
  const waitedRun = await start("mode-bash-output-exit", [
    toolSse("mode-background", "mode-background-tool", "Bash", {
      command:
        'powershell -NoProfile -Command "Start-Sleep -Seconds 3; Write-Output MODE_WAIT_EXIT"',
      run_in_background: true,
    }),
    backgroundTool("mode-wait", "mode-wait-tool", "BashOutput", {
      wait_ms: 10_000,
      until: "exit",
      max_bytes: 1024,
    }),
    (payload) => {
      const last = payload.messages
        .at(-1)
        .content.find(
          (part) =>
            part.type === "tool_result" &&
            part.tool_use_id === "mode-wait-tool",
        );
      assert.ok(last);
      assert.equal(last.is_error ?? false, false);
      const encoded =
        typeof last.content === "string"
          ? last.content
          : last.content.map((part) => part.text ?? "").join("");
      const result = JSON.parse(encoded);
      assert.equal(result.returned_on, "exit");
      assert.equal(result.status, "exited");
      assert.ok(result.waited_ms >= 200);
      assert.ok(result.stdout.includes("MODE_WAIT_EXIT"));
      observations.push({
        label: "BashOutput:exit",
        waitedMs: result.waited_ms,
        returnedOn: result.returned_on,
      });
      return textSse("mode-wait-done", "mode BashOutput wait completed");
    },
  ]);
  await terminal(waitedRun, { noUi: true });
  let cancelledJobId;
  const waitingRun = await start("mode-bash-output-cancel", [
    toolSse("mode-background-cancel", "mode-background-cancel-tool", "Bash", {
      command: 'powershell -NoProfile -Command "Start-Sleep -Seconds 30"',
      run_in_background: true,
    }),
    (payload) => {
      const result = payload.messages
        .at(-1)
        .content.find(
          (part) =>
            part.type === "tool_result" &&
            part.tool_use_id === "mode-background-cancel-tool",
        );
      assert.ok(result);
      const encoded =
        typeof result.content === "string"
          ? result.content
          : result.content.map((part) => part.text ?? "").join("");
      cancelledJobId = JSON.parse(encoded).job_id;
      assert.ok(cancelledJobId);
      return backgroundTool(
        "mode-wait-cancel",
        "mode-wait-cancel-tool",
        "BashOutput",
        {
          wait_ms: 30_000,
          until: "exit",
          max_bytes: 1024,
        },
      )(payload);
    },
  ]);
  await poll(
    async () => {
      const current = await readTask(taskId);
      return current.runs
        .find((run) => run.id === waitingRun)
        ?.tools.some(
          (tool) => tool.name === "BashOutput" && tool.state === "running",
        );
    },
    30_000,
    "BashOutput long wait in real Core",
  );
  const cancelStarted = Date.now();
  const beforeBusy = await readTask(taskId);
  const busyAck = await invoke("metawork.tasks.setApprovalMode", {
    taskId,
    targetMode: "manual",
    expectedBindingEpoch: beforeBusy.binding.epoch,
    expectedApprovalRevision: revision,
  });
  assert.equal(busyAck.accepted, true);
  const busyResult = await poll(
    async () => {
      const current = await readTask(taskId);
      return !current.approvalChange &&
        current.approvalResult?.outcome === "failed"
        ? current
        : null;
    },
    30_000,
    "active background job prevents checkpoint mutation",
  );
  assert.equal(busyResult.approvalResult.reason, "busy");
  assert.equal(busyResult.approvalMode, "full_access");
  assert.equal(busyResult.approvalRevision, revision);
  await terminal(waitingRun, { phase: "cancelled" });
  assert.equal(
    (await readTask(taskId)).runs.length,
    beforeBusy.runs.length,
    "switch replayed a Run",
  );
  observations.push({
    label: "BashOutput:cancel",
    elapsedMs: Date.now() - cancelStarted,
    switchFailure: "busy",
  });
  // A cancelled Run does not terminate Session-owned background jobs. Explicit
  // user execution uses the official tool before another switch is requested.
  const killRun = await start("mode-end-background-job", [
    toolSse("mode-kill", "mode-kill-tool", "KillShell", {
      job_id: cancelledJobId,
    }),
    (payload) => {
      const result = payload.messages
        .at(-1)
        .content.find(
          (part) =>
            part.type === "tool_result" &&
            part.tool_use_id === "mode-kill-tool",
        );
      assert.ok(result);
      assert.equal(result.is_error ?? false, false);
      const encoded =
        typeof result.content === "string"
          ? result.content
          : result.content.map((part) => part.text ?? "").join("");
      assert.equal(JSON.parse(encoded).status, "killed");
      return textSse("mode-kill-done", "mode background job explicitly ended");
    },
  ]);
  await terminal(killRun, { noUi: true });
  await setMode("manual");
  await checkedCheckpoint("approval", revision);

  const automatic = await create(
    { kind: "automatic" },
    "Automatic approval mode audit",
  );
  for (const targetMode of ["full_access", "manual"]) {
    const before = await readTask(automatic.id);
    const result = await invoke("metawork.tasks.setApprovalMode", {
      taskId: automatic.id,
      targetMode,
      expectedBindingEpoch: before.binding.epoch,
      expectedApprovalRevision: before.approvalRevision,
    });
    assert.equal(result.accepted, true, JSON.stringify(result));
    await poll(
      async () => {
        const current = await readTask(automatic.id);
        return current.approvalMode === targetMode &&
          current.approvalRevision === result.approvalRevision &&
          !current.approvalChange
          ? current
          : null;
      },
      30_000,
      "Automatic Workspace approval switch",
    );
    assert.equal(
      (await readTask(automatic.id)).workspaceId,
      automatic.workspaceId,
    );
  }
  const beforeRestart = await readTask(taskId);
  console.log(
    `AgentCore approval mode evidence before restart: ${JSON.stringify({ taskId, sessionId, revision, coreChanges, observations })}`,
  );
  return async function finishRestart() {
    const recovered = await readTask(taskId);
    assert.equal(recovered.approvalMode, "manual");
    assert.equal(recovered.approvalRevision, revision);
    assert.deepEqual(recovered.uiHistory, beforeRestart.uiHistory);
    assert.equal(recovered.runs.length, beforeRestart.runs.length);
    assert.equal((await readTask(automatic.id)).approvalMode, "manual");
    assert.equal((await readTask(automatic.id)).approvalRevision, "3");
    const ready = await poll(
      async () => {
        const current = await readTask(taskId);
        if (current.continuationRecoveryAvailable) return current;
        throw new Error(
          JSON.stringify({
            reason: current.continuationUnavailableReason,
            binding: current.binding,
            health: await checkpointHealth(taskId),
          }),
        );
      },
      30_000,
      "mode checkpoint recovery admission ready",
    );
    const restoration = await invoke("metawork.tasks.restore", {
      taskId,
      expectedBindingEpoch: ready.binding.epoch,
    });
    assert.equal(restoration.accepted, true, JSON.stringify(restoration));
    await poll(
      async () => (await readTask(taskId)).binding.availability === "available",
      30_000,
      "mode checkpoint attachment restore",
    );
    const continuedRun = await runGrant("mode-restart-grant-not-resurrected");
    const restoredRequest = await pending(continuedRun);
    assert.equal(
      BigInt(restoredRequest.policyGeneration),
      initialGeneration + BigInt(coreChanges),
    );
    await answer(restoredRequest, "allow_once");
    await grantTerminal(continuedRun);
    await checkedCheckpoint("run", continuedRun);
    for (const id of [taskId, automatic.id]) {
      await invoke("metawork.tasks.archive", { taskId: id, archived: true });
      await invoke("metawork.tasks.delete", { taskId: id });
      await poll(
        async () => !(await snapshot()).tasks.some((task) => task.id === id),
        30_000,
        "mode audit Task deletion",
      );
    }
    console.log(
      `AgentCore approval mode desktop passed: ${JSON.stringify({ taskId, sessionId, revision, coreChanges, observations })}`,
    );
  };
}
