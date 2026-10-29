import { getDemoSkillSource, requestDemoSkillImport } from "./SkillPicker.tsx";
import {
  BridgeClient as HostBridgeClient,
  type NativeBridge,
} from "../bridge/client.ts";
import {
  commands as c,
  RENDERER_BRIDGE_CONTRACT_ID,
  RENDERER_BRIDGE_CONTRACT_REVISION,
} from "../bridge/commands.ts";
import type {
  AttachmentDescriptor,
  TaskRunInput,
  ViewScope,
  TaskView,
} from "../bridge/contracts.ts";
import {
  demo,
  demoReportContent,
  changed,
  listeners,
  makeTask,
  makeRun,
  server,
  skillAsset,
  snapshot,
  syncSkills,
} from "./state.ts";
import { AttachmentAddOperation } from "../bridge/attachment-receive.ts";
import { requestDemoWorkspace } from "./workspace-picker.ts";
export {
  BridgeCommandTimeoutError,
  RendererBridgeContractError,
} from "../bridge/client.ts";

// Simulates UI state only. There is no model, MCP, filesystem, account or timer connection.
const timers = new Map<string, ReturnType<typeof setInterval>>();
const attachments = new Map<string, AttachmentDescriptor>();
function describeFiles(
  files: { name: string; sizeBytes: string }[],
): AttachmentDescriptor[] {
  return files.map((f, i) => {
    const item: AttachmentDescriptor = {
      kind: "file",
      token: "demo-file-" + Date.now() + "-" + i,
      displayName: f.name,
      sizeBytes: f.sizeBytes,
    };
    attachments.set(item.token, item);
    return item;
  });
}
function chooseBrowserFiles(): Promise<
  | { status: "ready"; attachments: AttachmentDescriptor[] }
  | { status: "cancelled" }
> {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.multiple = true;
    input.hidden = true;
    input.onchange = () => {
      const files = Array.from(input.files ?? []);
      input.remove();
      resolve(
        files.length
          ? {
              status: "ready",
              attachments: describeFiles(
                files.map((f) => ({ name: f.name, sizeBytes: String(f.size) })),
              ),
            }
          : { status: "cancelled" },
      );
    };
    input.oncancel = () => {
      input.remove();
      resolve({ status: "cancelled" });
    };
    document.body.append(input);
    input.click();
  });
}
let nextTask = 4;
const task = (id: string) => {
  const value = demo.tasks.find((t) => t.id === id);
  if (!value) throw new Error("演示任务不存在");
  return value;
};
function reply(text: string) {
  if (/失败|error/i.test(text))
    return "这是一条模拟的失败结果，用于调整错误反馈与重试入口。";
  return (
    "## 已整理你的任务\n\n收到：**" +
    text.slice(0, 160) +
    "**\n\n我会按以下步骤推进：\n\n1. 明确目标与交付形式。\n2. 整理相关资料与行动项。\n3. 检查结果并交付。\n\n> 当前是本地交互演示，回复为模拟内容。你可以继续追问、切换模型或打开执行详情。"
  );
}
function start(t: TaskView, input: TaskRunInput, operationId?: string) {
  const text =
    input.kind === "skill"
      ? "/" + input.skillId + " " + input.argumentValues.join(" ")
      : input.text;
  if (!t.title) t.title = text.slice(0, 24) || "新任务";
  const r = makeRun(t, text, "", "running");
  if (input.kind === "multimodal")
    r.input = {
      kind: "multimodal",
      text,
      redacted: false,
      attachments: input.attachmentTokens.flatMap((token) => {
        const f = attachments.get(token);
        return f
          ? [
              {
                kind: "file" as const,
                displayName: f.displayName,
                sizeBytes: f.sizeBytes,
                redacted: false,
              },
            ]
          : [];
      }),
    };
  r.submission = operationId
    ? {
        presentationOrder: r.id,
        operationId,
        receivedAtUnixMs: String(Date.now()),
        anchorRunId: r.id,
        afterOutputCount: 0,
      }
    : null;
  t.runs.push(r);
  t.currentRunId = r.id;
  t.currentRunPhase = "running";
  t.activeOperation = { kind: "run", id: r.id };
  if (text.includes("演示审批")) {
    r.phase = "waiting_ui";
    r.activity = { kind: "waiting_user" };
    t.currentRunPhase = "waiting_ui";
    t.pendingUi = {
      requestId: "1",
      runId: r.id,
      order: "1",
      redacted: false,
      kind: "permission",
      toolNamespace: "builtin",
      tool: "Write",
      toolBinding: "Write",
      args: '{"file_path":"设计说明.md","content":"本地演示内容"}',
      availableChoices: [
        "allow_once",
        "deny_once",
        "allow_session",
        "deny_session",
      ],
      policyGeneration: "1",
      canonicalArgumentsDigest: "demo-only",
      candidate: null,
    };
    changed();
    return r;
  }
  const full = reply(text);
  let index = 0;
  const interval = setInterval(() => {
    if (t.currentRunPhase !== "running") {
      clearInterval(interval);
      return;
    }
    index = Math.min(full.length, index + 18);
    r.output.response = full.slice(0, index);
    r.activity = { kind: "writing_response" };
    if (index === full.length) {
      clearInterval(interval);
      timers.delete(t.id);
      const failed = text.includes("演示失败");
      r.phase = failed ? "failed" : "completed";
      r.output.responseKind = "final";
      r.activity = null;
      r.terminal = {
        outcome: failed ? "failed" : "completed",
        cause: failed ? "provider_failure" : null,
        diagnosticDisposition: "absent",
      };
      r.elapsedMs = String(Date.now() - Number(r.submittedAtUnixMs));
      r.finishedAtUnixMs = String(Date.now());
      t.currentRunPhase = null;
      t.activeOperation = null;
      t.unreadCompletionRunId = r.id;
      demo.scheduledTasks?.forEach((s) =>
        s.occurrences
          .filter((o) => o.taskId === t.id)
          .forEach((o) => (o.taskOutcome = failed ? "failed" : "completed")),
      );
    }
    changed();
  }, 75);
  timers.set(t.id, interval);
  changed();
  return r;
}
const ok = { accepted: true, errorCode: "none", attemptId: null };
async function invoke(command: string, value: unknown): Promise<unknown> {
  const p = (value ?? {}) as Record<string, any>;
  if (command === c.connect)
    return {
      accepted: true,
      contractId: RENDERER_BRIDGE_CONTRACT_ID,
      contractRevision: RENDERER_BRIDGE_CONTRACT_REVISION,
      generation: "1",
      error: null,
      attachmentInput: { mode: "file_bytes", maxChunkBytes: "65536" },
    };
  if (command === c.disconnect)
    return { generation: p.generation, detached: true };
  if (command === c.ping || command === c.pingAck)
    return {
      sequence: p.sequence ?? 1,
      transport: "local-demo",
      origin: "demo",
      onMainThread: true,
    };
  if (command === c.createTask) {
    const t = makeTask(String(nextTask++), "", p.workspace?.workspaceId ?? "1");
    t.approvalMode = p.approvalMode;
    if (p.modelSelection?.targetModelRef) {
      t.binding.model = p.modelSelection.targetModelRef.modelId;
      t.modelIntent = {
        modelRef: p.modelSelection.targetModelRef,
        selectionRevision: demo.revision,
        state: "committed",
      };
    }
    demo.tasks.unshift(t);
    changed();
    return {
      accepted: true,
      taskId: t.id,
      bindingEpoch: "1",
      mcpAuthority: t.mcpAuthority,
      reason: null,
    };
  }
  if (command === c.sendInput) {
    start(task(p.taskId), p.input, p.operationId);
    return {
      taskId: p.taskId,
      operationId: p.operationId,
      outcome: "accepted",
      reason: null,
    };
  }
  if (command === c.run) {
    const r = start(task(p.taskId), p.input);
    return { accepted: true, taskId: p.taskId, runId: r.id, reason: null };
  }
  if (command === c.respondUi) {
    const t = task(p.taskId),
      r = t.runs.find((r) => r.id === p.runId)!;
    const allowed = p.permission.startsWith("allow");
    t.uiHistory.push({
      answeredBy: "user",
      reviewReason: null,
      requestId: p.requestId,
      runId: p.runId,
      order: "1",
      kind: "permission",
      state: allowed ? "allowed_once" : "denied",
      agentRequestId: "1",
      permission: null,
      detail: "Write 设计说明.md（本地演示）",
      itemCount: 1,
      detailTruncated: false,
      redacted: false,
    });
    t.pendingUi = null;
    t.activeOperation = null;
    t.currentRunPhase = null;
    r.phase = "completed";
    r.activity = null;
    r.terminal = {
      outcome: "completed",
      cause: null,
      diagnosticDisposition: "absent",
    };
    r.output.response = allowed
      ? "已收到允许。本轮演示已完成，没有写入真实工作区。"
      : "已拒绝本轮写入，演示任务结束。";
    r.output.responseKind = "final";
    r.elapsedMs = "2000";
    r.finishedAtUnixMs = String(Date.now());
    changed();
    return {
      taskId: t.id,
      runId: r.id,
      requestId: p.requestId,
      answered: true,
    };
  }
  if (command === c.stop || command === c.cancel) {
    const t = task(p.taskId);
    clearInterval(timers.get(t.id));
    const r = t.runs.at(-1);
    if (r) {
      r.phase = "stopped";
      r.output.responseKind = r.output.response ? "final" : null;
      r.activity = null;
      for (const tool of r.tools)
        if (tool.state === "running") {
          tool.state = "failed";
          tool.isError = true;
          tool.errorDetail = "本轮已停止，工具执行已取消。";
        }
      r.terminal = {
        outcome: "stopped",
        cause: "user_cancel",
        diagnosticDisposition: "absent",
      };
      r.finishedAtUnixMs = String(Date.now());
    }
    t.activeOperation = null;
    t.currentRunPhase = null;
    changed();
    return command === c.stop
      ? { taskId: t.id, stopRequested: true }
      : { taskId: t.id, runId: p.runId, cancelRequested: true };
  }
  if (command === c.renameTask) {
    task(p.taskId).title = p.title;
    changed();
    return { taskId: p.taskId, renamed: true };
  }
  if (command === c.archiveTask) {
    task(p.taskId).archived = p.archived;
    changed();
    return { taskId: p.taskId, archived: p.archived };
  }
  if (command === c.deleteTask) {
    demo.tasks = demo.tasks.filter((t) => t.id !== p.taskId);
    changed();
    return { taskId: p.taskId, deleting: true };
  }
  if (command === c.markTaskCompletionSeen) {
    task(p.taskId).unreadCompletionRunId = null;
    changed();
    return { taskId: p.taskId, runId: p.runId, marked: true };
  }
  if (command === c.setApprovalMode) {
    const t = task(p.taskId);
    t.approvalMode = p.targetMode;
    t.approvalRevision = String(Number(t.approvalRevision) + 1);
    changed();
    return {
      accepted: true,
      taskId: t.id,
      approvalRevision: t.approvalRevision,
      reason: null,
    };
  }
  if (command === c.selectTaskModel) {
    const t = task(p.taskId);
    t.binding.model = p.targetModelRef.modelId;
    t.modelIntent = {
      modelRef: p.targetModelRef,
      selectionRevision: demo.revision,
      state: "committed",
    };
    changed();
    return {
      accepted: true,
      taskId: t.id,
      selectionRevision: demo.revision,
      reason: null,
    };
  }
  if (command === c.chooseWorkspace) return requestDemoWorkspace();
  if (command === c.setSkillEnabled) {
    const a = demo.skillManagement!.assets.find(
      (a) => a.skillPolicyKey === p.skillPolicyKey,
    )!;
    a.enabled = p.state !== "disabled";
    a.enablementState = p.state;
    demo.skillCatalog.selectionRevision = String(
      Number(demo.skillCatalog.selectionRevision) + 1,
    );
    syncSkills();
    changed();
    return {
      applied: true,
      selectionRevision: demo.skillCatalog.selectionRevision,
      reason: null,
    };
  }
  if (command === c.setSkillSourceEnabled) {
    demo
      .skillManagement!.sourceSettings.entries.filter((e) =>
        e.sourceId.includes(p.brand ?? p.sourceBrand ?? p.sourceId),
      )
      .forEach((e) => (e.enabled = p.enabled));
    changed();
    return { applied: true, revision: demo.revision, reason: null };
  }
  if (command === c.refreshSkillCatalog) {
    syncSkills();
    changed();
    return { accepted: true, reason: null };
  }
  if (
    command === c.refreshTaskSkillCatalog ||
    command === c.refreshWorkspaceSkillCatalog
  ) {
    syncSkills();
    changed();
    return {
      accepted: true,
      reason: null,
      ...(p.taskId ? { taskId: p.taskId } : { workspaceId: p.workspaceId }),
    };
  }
  if (command === c.chooseSkillImport)
    return requestDemoSkillImport(
      p.kind === "directory" ? "directory" : "package",
    );
  if (command === c.releaseAttachment) return { released: true };
  if (
    command === c.installSkill ||
    command === c.reimportSkill ||
    command === c.retrySkill
  ) {
    if (
      !demo.skillManagement!.assets.some((a) => a.installId === "design-review")
    )
      demo.skillManagement!.assets.push(
        skillAsset(
          "design-review",
          "检查界面层级、交互反馈与视觉一致性。",
          true,
          getDemoSkillSource(String(p.previewId))?.kind === "directory"
            ? "local_directory"
            : "local_package",
        ),
      );
    syncSkills();
    changed();
    return {
      accepted: true,
      installId: "design-review",
      verificationPending: false,
      reason: null,
    };
  }
  if (command === c.uninstallSkill) {
    demo.skillManagement!.assets = demo.skillManagement!.assets.filter(
      (a) => a.installId !== p.installId,
    );
    syncSkills();
    changed();
    return {
      accepted: true,
      installId: p.installId,
      verificationPending: false,
      reason: null,
    };
  }
  if (command === c.skillDetail)
    return {
      available: true,
      definition:
        "---\nname: " +
        p.installId +
        "\ndescription: 本地演示技能\n---\n\n按目标整理工作，输出简洁的结果与行动项。",
      fileCount: 3,
      totalBytes: 2048,
      reason: null,
    };
  if (command === c.exportSkill) {
    const blob = new Blob(["# " + p.installId + "\n本地演示技能"], {
      type: "text/markdown",
    });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = p.installId + "-demo.md";
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
    return { exported: true, fileName: a.download, reason: null };
  }
  if (command.startsWith("metawork.mcp.")) {
    const m = demo.mcp!,
      s = m.servers.find((s) => s.id === p.serverId);
    if (
      command === c.mcpCreateStdioServer ||
      command === c.mcpCreateHttpServer
    ) {
      const n = server("service-" + (m.servers.length + 1), p.displayName);
      if (command === c.mcpCreateStdioServer) {
        n.transport = "stdio";
        n.connection = {
          kind: "stdio",
          command: p.command,
          arguments: p.arguments,
          cwd: p.cwd,
          environment: (p.environmentNames ?? []).map((name: string) => ({
            name,
            status: "missing",
          })),
        };
      } else if (n.connection?.kind === "streamable_http") {
        n.connection.endpoint = p.endpoint;
        n.authMode = p.authMode;
        n.connection.headers = (p.headerNames ?? []).map((name: string) => ({
          name,
          status: "missing",
        }));
        n.authorizationStatus =
          p.authMode === "oauth"
            ? "consent_required"
            : p.authMode === "static"
              ? "missing_static_secret"
              : "not_required";
      }
      m.servers.push(n);
    } else if (command === c.mcpSetServerEnabled && s) {
      s.desiredEnabled = p.enabled;
      s.runtimeStatus = p.enabled ? "ready" : "disabled";
      s.newTaskAccess = p.enabled ? "available" : "unavailable";
      s.tools.forEach(
        (t) => (t.availableToNewTasks = p.enabled && t.desiredAllowed),
      );
    } else if (command === c.mcpRemoveServer)
      m.servers = m.servers.filter((s) => s.id !== p.serverId);
    else if (command === c.mcpRenameServer && s) s.displayName = p.displayName;
    else if (command === c.mcpSetAllowedTools && s)
      s.tools.forEach((t) => (t.desiredAllowed = p.toolNames.includes(t.name)));
    else if (command === c.mcpTestConnection && s)
      s.connectionTest = {
        status: "connected",
        toolCount: s.tools.length,
        issueCount: 0,
      };
    else if (command === c.mcpApproveConnection && s)
      s.approvalStatus = "approved";
    else if (command === c.mcpCaptureSecret && s) {
      s.authorizationStatus = "ready";
      if (s.connection?.kind === "streamable_http")
        s.connection.headers.forEach((h) => (h.status = "set"));
    } else if (
      command === c.mcpUpdateHttpConnection &&
      s &&
      s.connection?.kind === "streamable_http"
    )
      s.connection.endpoint = p.endpoint;
    else if (command === c.mcpUpdateStdioConnection && s) {
      s.connection = {
        kind: "stdio",
        command: p.command,
        arguments: p.arguments,
        cwd: p.cwd,
        environment: [],
      };
    }
    m.desiredGeneration = String(Number(m.desiredGeneration) + 1);
    changed();
    if (command === c.mcpAuthorizeOAuth && s) {
      s.authorizationStatus = "authorizing";
      m.authorizationOperation = {
        kind: "awaiting_browser",
        serverId: s.id,
        operationId: "1",
      };
      setTimeout(() => {
        s.authorizationStatus = "ready";
        m.authorizationOperation = { kind: "idle" };
        changed();
      }, 1200);
      return { outcome: "started", operationId: "1" };
    }
    if (command === c.mcpCancelAuthorization) {
      m.authorizationOperation = { kind: "idle" };
      return { outcome: "cancelled" };
    }
    if (
      [
        c.mcpRefreshCatalog,
        c.mcpApplyConfiguration,
        c.mcpTestConnection,
      ].includes(command as never)
    )
      return { outcome: "started" };
    return { outcome: "saved", desiredGeneration: m.desiredGeneration };
  }
  if (command === c.createScheduledTask || command === c.updateScheduledTask) {
    let s = demo.scheduledTasks!.find((s) => s.id === p.scheduledTaskId);
    if (!s) {
      s = {
        ...structuredClone(demo.scheduledTasks![0]),
        id: String(
          Math.max(0, ...demo.scheduledTasks!.map((s) => Number(s.id))) + 1,
        ),
        occurrences: [],
      };
      demo.scheduledTasks!.push(s);
    }
    Object.assign(s, {
      title: p.title,
      input: { ...p.input, redacted: false },
      binding: { ...p.binding, status: "bound" },
      permissionProfile: p.permissionProfile,
      recurrence: p.recurrence,
      enabled: true,
      health: "ready",
      failureReason: null,
      nextRunAtUnixSeconds:
        p.recurrence.atUnixSeconds ?? p.recurrence.startAtUnixSeconds,
    });
    s.epoch = String(Number(s.epoch) + 1);
    changed();
    return { scheduledTaskId: s.id, epoch: s.epoch, accepted: true };
  }
  if (command === c.setScheduledTaskEnabled) {
    const s = demo.scheduledTasks!.find((s) => s.id === p.scheduledTaskId)!;
    s.enabled = p.enabled;
    s.health = p.enabled ? "ready" : "paused";
    s.epoch = String(Number(s.epoch) + 1);
    s.nextRunAtUnixSeconds = p.enabled
      ? String(Math.floor(Date.now() / 1000) + 3600)
      : null;
    changed();
    return { scheduledTaskId: s.id, epoch: s.epoch, enabled: s.enabled };
  }
  if (command === c.deleteScheduledTask) {
    demo.scheduledTasks = demo.scheduledTasks!.filter(
      (s) => s.id !== p.scheduledTaskId,
    );
    changed();
    return { scheduledTaskId: p.scheduledTaskId, deleted: true };
  }
  if (command === c.runScheduledTaskNow) {
    const s = demo.scheduledTasks!.find((s) => s.id === p.scheduledTaskId)!,
      t = makeTask(String(nextTask++), s.title, "2");
    demo.tasks.unshift(t);
    start(t, { kind: "text", text: s.input.text });
    s.occurrences.unshift({
      plannedAtUnixSeconds: String(Math.floor(Date.now() / 1000)),
      triggeredAtUnixSeconds: String(Math.floor(Date.now() / 1000)),
      source: "manual",
      result: "submitted",
      taskId: t.id,
      reason: null,
      taskOutcome: null,
    });
    changed();
    return { scheduledTaskId: s.id, taskId: t.id, accepted: true };
  }
  if (
    command === c.selectModelsDefault ||
    command === c.configureMetaskSelection
  ) {
    demo.models.defaultSelection = { sourceId: p.sourceId, modelId: p.modelId };
    demo.newTaskAdmission.activeModelRef = demo.models.defaultSelection;
    changed();
    return ok;
  }
  if (
    command === c.customProviderCreate ||
    command === c.builtinProviderCreate
  ) {
    const preset = demo.models.builtinProviderPresets.find(
      (v) => v.id === p.providerId,
    );
    demo.models.customProviders.push({
      id: "provider-" + (demo.models.customProviders.length + 1),
      builtinProviderId: preset?.id ?? null,
      displayName: p.displayName ?? preset?.displayName ?? "Demo Provider",
      protocol: p.protocol ?? preset?.protocol ?? "openai_chat_completions",
      normalizedBaseUrl: p.normalizedBaseUrl ?? p.baseUrl,
      state: "ready",
      credentialStatus: "ready",
      enabled: true,
      models: [],
      providerRevision: "1",
      sourceGeneration: "1",
      catalogGeneration: "1",
    });
    changed();
    return ok;
  }
  if (
    command.startsWith("metawork.models.custom") ||
    command === c.builtinProviderUpdateBaseUrl
  ) {
    const provider = demo.models.customProviders.find(
      (v) =>
        v.id === (p.providerId ?? p.selection?.sourceId ?? p.model?.sourceId),
    );
    if (command === c.customProviderRemove)
      demo.models.customProviders = demo.models.customProviders.filter(
        (v) => v !== provider,
      );
    if (provider) {
      if (command === c.customProviderUpdate)
        Object.assign(provider, {
          displayName: p.displayName,
          protocol: p.protocol,
          normalizedBaseUrl: p.normalizedBaseUrl,
        });
      if (command === c.builtinProviderUpdateBaseUrl)
        provider.normalizedBaseUrl = p.baseUrl;
      if (command === c.customModelAdd)
        provider.models.push({
          id: p.model.id,
          displayName: p.model.displayName ?? p.model.id,
          metadata:
            p.model.metadata ??
            structuredClone(demo.models.providers[0].models[0].metadata),
          metadataProvenance: "user_declared",
          testStatus: "untested",
          ready: true,
        });
      if (command === c.customModelRemove)
        provider.models = provider.models.filter(
          (m) => m.id !== p.selection.modelId,
        );
      if (command === c.customModelReplace) {
        const m = provider.models.find((m) => m.id === p.selection.modelId);
        if (m) Object.assign(m, p.replacement);
      }
      if (command === c.customModelTest) {
        const m = provider.models.find((m) => m.id === p.model.modelId);
        if (m) {
          m.testStatus = "connected";
          m.ready = true;
        }
      }
      provider.providerRevision = String(Number(provider.providerRevision) + 1);
    }
    // Credentials in command arguments are deliberately discarded.
    changed();
    return ok;
  }
  if (command === c.accountLogout) {
    demo.account.state = "signed_out";
    changed();
    return ok;
  }
  if (command === c.accountBeginLogin) {
    demo.account.state = "authenticated";
    changed();
    return ok;
  }
  if (
    command.startsWith("metawork.account.") ||
    command === c.modelsRefreshCatalog
  ) {
    changed();
    return ok;
  }
  if (
    [
      c.chooseAutomaticWorkspaceRoot,
      c.resetAutomaticWorkspaceRoot,
      c.retryAutomaticWorkspaceRoot,
    ].includes(command as never)
  ) {
    changed();
    return { outcome: "applied" };
  }
  if (command === c.openExternalLink) return { outcome: "opened" };
  throw new Error("此原生操作未接入演示。当前 demo 仅模拟界面交互。");
}
const bridge: NativeBridge = {
  invoke,
  on() {
    return () => {};
  },
};
export class BridgeClient extends HostBridgeClient {
  constructor() {
    super({ bridge });
  }
  override onWorkbenchRevision(
    consume: (revision: string, epoch: string) => void,
  ) {
    listeners.add(consume);
    return () => {
      listeners.delete(consume);
    };
  }
  override fetchSnapshot(scope: ViewScope) {
    return Promise.resolve(snapshot(scope));
  }
  override async outputAction(
    ...args: Parameters<HostBridgeClient["outputAction"]>
  ) {
    const action = args[3];
    if (action === "save") {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(
        new Blob([demoReportContent], { type: "text/markdown" }),
      );
      a.download = "产品设计计划-demo.md";
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      return "saved" as const;
    }
    return action === "reveal" ? ("unavailable" as const) : ("ready" as const);
  }
  override async fileChangeDiff(
    ..._args: Parameters<HostBridgeClient["fileChangeDiff"]>
  ) {
    return {
      status: "ready" as const,
      content:
        "@@ -0,0 +1,5 @@\n+# 产品设计计划\n+\n+1. 统一视觉规范\n+2. 完善任务交互\n+3. 验证结果交付\n",
      complete: true,
      redacted: false,
    };
  }
  override createAttachmentAdd(recover: () => Promise<void>) {
    return new AttachmentAddOperation(
      {
        begin: async (source) =>
          source.kind === "picker"
            ? chooseBrowserFiles()
            : source.kind === "file_bytes"
              ? { status: "ready", attachments: describeFiles(source.files) }
              : { status: "cancelled" },
        append: async () => ({ status: "accepted" }),
        finish: async () => ({ status: "cancelled" }),
        cancel: async () => ({ status: "cleaned", released: true }),
        recover,
      },
      65536,
    );
  }
  override async previewFile(
    ...args: Parameters<HostBridgeClient["previewFile"]>
  ) {
    const run = demo.tasks
      .find((task) => task.id === args[0])
      ?.runs.find((candidate) => candidate.id === args[1]);
    const reference = run?.tools
      .flatMap((tool) => tool.fileRefs)
      .find((candidate) => candidate.id === args[2]);
    const deliveredReport =
      reference?.displayPath === "产品设计计划.md" &&
      run?.outputs.some(
        (output) =>
          !output.redacted && output.displayPath === reference.displayPath,
      );
    return {
      state: "ready" as const,
      content: deliveredReport
        ? demoReportContent
        : "# 项目说明\n\n这是本地演示文件，用于预览阅读与右侧栏布局。\n\n## 任务\n- 梳理目标\n- 完成设计\n- 验证结果",
      truncated: false,
      redacted: false,
    };
  }
}
