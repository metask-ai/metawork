import fixture from "./base-view.json";
import { decodeWorkbenchSnapshot } from "../bridge/decode-contracts.ts";
import type {
  WorkbenchSnapshot,
  TaskView,
  RunView,
  SkillManagementView,
  McpManagementView,
  ScheduledTaskView,
  ViewScope,
  TaskSummary,
} from "../bridge/contracts.ts";

// Only synthetic demo content. This file never reads the installed app's store.
const base = decodeWorkbenchSnapshot(fixture);
export const modelNames = [
  "DeepSeek-V4.1-Flash-1017",
  "GLM-5.3-Flash",
  "Claude-Sonnet-4.5",
];
const model = modelNames[0];
export const demo: WorkbenchSnapshot = structuredClone(base);
demo.revision = "1";
demo.permissions.availableModes = ["manual", "auto_review", "full_access"];
demo.permissions.defaultMode = "auto_review";
Object.assign(demo.capabilities, {
  taskHistoryPersistence: true,
  taskHistoryPersistenceHealth: "ready",
  automaticWorkspaces: true,
  scheduledTasks: true,
  scheduledTaskPersistence: true,
  scheduledTaskPersistenceHealth: "ready",
  backgroundScheduleWake: true,
  localSkillManagement: true,
  skillManagementHealth: "ready",
  customProviderManagement: true,
  customProviderSecretCapture: true,
  customModelTest: true,
  mcpManagement: true,
  mcpConnectionApproval: true,
  mcpSecretCapture: true,
  mcpSecretMaxBytes: 4096,
  mcpOAuth: true,
});
demo.account.displayName = "Demo User";
try {
  demo.account.displayName =
    localStorage.getItem("metawork.demo.displayName")?.slice(0, 40).trim() ||
    "Demo User";
} catch {
  /* Storage may be disabled. */
}
demo.account.phoneHint = "138****0000";
demo.account.emailHint = "demo@example.test";
demo.automaticWorkspaceRoot = {
  generation: "1",
  mode: "system_default",
  canonicalRoot: "/Demo/MetaWork",
  health: "ready",
  redacted: false,
  canChoose: true,
  canReset: true,
  canRetry: false,
};
const originalModel = structuredClone(demo.models.providers[0].models[0]);
demo.models.providers[0].models = modelNames.map((id) => ({
  ...structuredClone(originalModel),
  id,
  displayName: id,
}));
demo.models.defaultSelection = { sourceId: "metask", modelId: model };
demo.models.metaskSelection = { sourceId: "metask", modelId: model };
demo.newTaskAdmission = {
  ...demo.newTaskAdmission,
  available: true,
  state: "ready",
  activeModelRef: { sourceId: "metask", modelId: model },
};
demo.skillCatalog = {
  availability: "ready",
  redacted: false,
  revision: "1",
  selectionRevision: "1",
  skills: [],
  issues: [],
};
const sourceSettings = structuredClone(base.skillManagement!.sourceSettings);
sourceSettings.entries.forEach((entry) => {
  entry.canSetEnabled = true;
  entry.enabled = entry.sourceId.includes("codex");
});
export function skillAsset(
  id: string,
  description: string,
  imported = false,
  importedSourceKind: "local_package" | "local_directory" = "local_package",
): SkillManagementView["assets"][number] {
  return {
    installId: imported ? id : null,
    sourceKind: imported ? importedSourceKind : "external",
    origin: { ecosystem: "agents", scope: "personal" },
    scope: { kind: "personal", workspaceId: null },
    managementState: imported ? "ready" : "externally_managed",
    skillId: id,
    skillPolicyKey: id,
    invocationName: id,
    displayName: id,
    description,
    argumentNames: [],
    maxValues: 0,
    canExport: imported,
    canReimport: imported,
    canUninstall: imported,
    canRetry: false,
    enabled: true,
    enablementState: "enabled",
    canSetEnabled: true,
    selectionRevision: "1",
    issueCodes: [],
  };
}
demo.skillManagement = {
  availability: "ready",
  enablementAvailability: "ready",
  sourceSettings,
  personalSourceDiscovery: null,
  assets: [
    skillAsset(
      "docx",
      "Create, read, edit, revise, and manage comments in Word documents.",
    ),
    skillAsset(
      "pptx",
      "Create, read, edit, combine, split, and refine PowerPoint presentations.",
    ),
    skillAsset(
      "xlsx",
      "Create, read, edit, clean, and format spreadsheets with formulas and charts.",
    ),
    skillAsset(
      "weekly-report",
      "将项目进展整理成每周工作报告，保留行动项和负责人。",
      true,
    ),
  ],
};
export function syncSkills() {
  demo.skillCatalog.skills = demo.skillManagement!.assets.map((a) => ({
    skillId: a.skillId!,
    invocationName: a.invocationName,
    displayName: a.displayName,
    description: a.description,
    argumentNames: a.argumentNames,
    maxValues: a.maxValues,
    enabled: !!a.enabled,
  }));
  demo.workspaces?.forEach((w) => {
    w.skillCatalog = structuredClone(demo.skillCatalog);
  });
  demo.tasks?.forEach((t) => {
    t.skillCatalog = structuredClone(demo.skillCatalog);
  });
}
export function server(
  id: string,
  name: string,
  enabled = false,
): McpManagementView["servers"][number] {
  return {
    id,
    displayName: name,
    namespace: id,
    transport: "streamable_http",
    authMode: "none",
    negotiation: "automatic",
    timeoutMs: 30000,
    connection: {
      kind: "streamable_http",
      endpoint: "https://example.test/mcp",
      headers: [],
      registrationKind: "none",
      clientId: null,
      tokenEndpointAuthMethod: null,
      clientSecretStatus: "not_required",
    },
    approvalStatus: "approved",
    authorizationStatus: "not_required",
    desiredEnabled: enabled,
    runtimeStatus: enabled ? "ready" : "disabled",
    newTaskAccess: enabled ? "available" : "unavailable",
    safeDiagnostic: "",
    connectionTest: { status: "untested", toolCount: 2, issueCount: 0 },
    tools: ["search", "read_document"].map((name) => ({
      name,
      discovered: true,
      desiredAllowed: true,
      availableToNewTasks: enabled,
    })),
  };
}
demo.mcp = {
  availability: "ready",
  managementHealth: "ready",
  operation: "idle",
  configurationApply: "idle",
  authorizationOperation: { kind: "idle" },
  desiredGeneration: "1",
  runtimeAlignment: "current",
  redacted: false,
  servers: [server("docs", "文档检索"), server("files", "项目文件服务")],
};
demo.workspaces = ["产品设计", "每周工作"].map((name, index) => ({
  ...structuredClone(base.workspaces[0]),
  id: String(index + 1),
  displayName: name,
  canonicalRoot: "/Demo/" + name,
  signals: { running: 0, attention: 0, failedOrInterrupted: 0 },
}));
const taskTemplate = structuredClone(base.taskPage!.task);
const runTemplate = structuredClone(taskTemplate.runs[0]);
export function makeTask(id: string, title: string, workspaceId: string) {
  const t = structuredClone(taskTemplate);
  Object.assign(t, {
    id,
    title,
    workspaceId,
    recentOrder: id,
    inputReady: true,
    currentRunId: "0",
    currentRunPhase: null,
    activeOperation: null,
    runs: [],
    inputSubmissions: [],
    approvalMode: "auto_review",
    availableApprovalModes: ["manual", "auto_review", "full_access"],
    skillCatalog: structuredClone(demo.skillCatalog),
    mcpAuthority: { kind: "unavailable", selection: null },
    modelIntent: {
      modelRef: structuredClone(demo.models.defaultSelection),
      selectionRevision: "3",
      state: "committed",
    },
  });
  t.binding.model = demo.models.defaultSelection!.modelId;
  return t;
}
export function makeRun(
  t: TaskView,
  text: string,
  response: string,
  phase: RunView["phase"] = "completed",
): RunView {
  const r = structuredClone(runTemplate);
  const done = phase === "completed";
  Object.assign(r, {
    id: String(t.runs.length + 1),
    phase,
    submittedAtUnixMs: String(Date.now()),
    finishedAtUnixMs: done ? String(Date.now()) : null,
    elapsedMs: done ? "2400" : null,
    execution: { ...r.execution, model: t.binding.model },
    input: { kind: "text", text, redacted: false },
    output: {
      commentary: [],
      response,
      responseKind: done ? "final" : null,
      provisional: "",
      redacted: false,
      provisionalRedacted: false,
    },
    activity: done ? null : { kind: "thinking" },
    terminal: done
      ? { outcome: "completed", cause: null, diagnosticDisposition: "absent" }
      : null,
    tools: [],
    outputs: [],
    fileChanges: { observation: done ? "complete" : "collecting", changes: [] },
  });
  return r;
}
demo.tasks = [
  [
    "1",
    "梳理产品需求与下一步计划",
    "1",
    "帮我梳理本周的产品设计工作。",
    "## 本周设计工作\n\n已整理成三个方向：\n\n1. **视觉规范**：统一字体、颜色、间距与组件状态。\n2. **核心流程**：打通新建任务、执行反馈和结果交付。\n3. **体验验证**：记录关键步骤的完成率和用户反馈。\n\n下一步可以从任务首页开始，逐个调整主要界面。",
  ],
  [
    "2",
    "会议纪要与行动项",
    "2",
    "整理一下今天的会议纪要。",
    "## 会议纪要\n\n团队确认先完成原型，再进行交互评审。\n\n| 行动项 | 负责人 | 时间 |\n| --- | --- | --- |\n| 整理任务页 | 设计团队 | 周三 |\n| 评审状态反馈 | 产品团队 | 周四 |\n| 完成可用性走查 | 项目团队 | 周五 |",
  ],
  [
    "3",
    "分析销售数据并生成报告",
    "2",
    "分析这周的销售表现。",
    "## 本周销售数据已经整理。\n\n- **总销售额**：128,400 元\n- **环比变化**：+12.6%\n- **表现最好的产品**：专业版\n\n这是演示内容，可继续发送消息体验任务流程。",
  ],
].map(([id, title, workspace, input, output]) => {
  const t = makeTask(id, title, workspace);
  t.runs = [makeRun(t, input, output)];
  t.currentRunId = "1";
  return t;
});
const report = demo.tasks[0].runs[0];
export const demoReportContent =
  "# 产品设计计划\n\n1. 统一视觉规范\n2. 完善任务交互\n3. 验证结果交付\n";
report.tools = [
  {
    id: "1",
    order: "1",
    name: "Read",
    input: '{"file_path":"需求梳理.md"}',
    progress: "",
    content: "# 产品需求\n\n统一视觉规范，完善任务交互，验证结果交付。",
    state: "completed",
    isError: false,
    elapsedMs: "18",
    inputTruncated: false,
    progressTruncated: false,
    contentTruncated: false,
    redacted: false,
    bash: null,
    presentation: {
      kind: "read",
      target: "需求梳理.md",
      offset: null,
      limit: null,
    },
    errorDetail: null,
    fileRefs: [
      { id: "1", title: "需求梳理.md", displayPath: "需求梳理.md" },
      { id: "2", title: "产品设计计划.md", displayPath: "产品设计计划.md" },
    ],
  },
];
report.outputs = [
  {
    id: "01010101010101010101010101010101",
    displayPath: "产品设计计划.md",
    sizeBytes: "246",
    redacted: false,
  },
];
report.fileChanges = {
  observation: "complete",
  changes: [
    {
      id: "1",
      order: "1",
      kind: "created",
      status: "applied",
      displayPath: "产品设计计划.md",
      fromDisplayPath: null,
      beforeBytes: "0",
      afterBytes: "246",
      diffAvailable: true,
      diffComplete: true,
      redacted: false,
    },
  ],
};
const binding = {
  status: "bound" as const,
  modelRef: { sourceId: "metask", modelId: model },
  sourceGeneration: "1",
  selectionRevision: "3",
  protocol: "anthropic_messages" as const,
};
demo.scheduledTasks = ["每日工作简报", "每周项目回顾"].map(
  (title, i): ScheduledTaskView => ({
    id: String(i + 1),
    epoch: "1",
    title,
    titleRedacted: false,
    permissionProfile: "approval_required",
    enabled: i === 0,
    health: i === 0 ? "ready" : "paused",
    failureReason: null,
    binding: structuredClone(binding),
    input: {
      kind: "text",
      text:
        i === 0
          ? "整理今天的待办事项和项目进展。"
          : "总结本周完成的工作和下周计划。",
      redacted: false,
    },
    recurrence: {
      kind: "interval",
      startAtUnixSeconds: String(Math.floor(Date.now() / 1000) + 3600),
      everySeconds: i === 0 ? "86400" : "604800",
    },
    nextRunAtUnixSeconds:
      i === 0 ? String(Math.floor(Date.now() / 1000) + 3600) : null,
    occurrences: [],
  }),
);
syncSkills();
export const listeners = new Set<(revision: string, epoch: string) => void>();
export function changed() {
  demo.revision = String(BigInt(demo.revision) + 1n);
  listeners.forEach((fn) => fn(demo.revision, demo.securityEpoch));
}
function summary(t: TaskView): TaskSummary {
  return {
    id: t.id,
    title: t.title,
    workspaceId: t.workspaceId,
    recentOrder: t.recentOrder,
    archived: t.archived,
    lifecycle: t.lifecycle,
    deletionStatus: t.deletionStatus,
    permissionReviewState: t.permissionReviewState,
    currentRunPhase: t.currentRunPhase,
    activeOperation: t.activeOperation,
    unreadCompletionRunId: t.unreadCompletionRunId,
    historyReadOnly: false,
    activeCompactPhase: null,
    lastCompactPhase: null,
    latestTerminal: t.runs.at(-1)?.terminal ?? null,
  };
}
const runVersions = new Map<string, { signature: string; version: number }>();
function runContentVersion(taskId: string, run: RunView) {
  const key = `${taskId}:${run.id}`,
    signature = JSON.stringify(run),
    previous = runVersions.get(key);
  if (previous?.signature === signature) return String(previous.version);
  const version = (previous?.version ?? 0) + 1;
  runVersions.set(key, { signature, version });
  return String(version);
}
export function snapshot(scope: ViewScope): WorkbenchSnapshot {
  const value = structuredClone(demo),
    t = value.tasks.find((t) => t.id === scope.taskId);
  value.scope = structuredClone(scope);
  value.taskIndex = value.tasks.map(summary);
  value.taskPage = t
    ? {
        beforeRunId: null,
        nextBeforeRunId:
          t.runs.length > scope.runLimit
            ? t.runs[t.runs.length - scope.runLimit]!.id
            : null,
        task: { ...t, runs: t.runs.slice(-Math.max(1, scope.runLimit)) },
        runManifest: t.runs.map((r) => ({
          id: r.id,
          contentVersion: runContentVersion(t.id, r),
          phase: r.phase,
          permissionProfile: r.permissionProfile,
          permissionInteraction: r.permissionInteraction,
          terminal: r.terminal,
        })),
      }
    : null;
  value.historyPage = null;
  if (t && scope.beforeRunId) {
    const end = t.runs.findIndex((run) => run.id === scope.beforeRunId);
    if (end > 0) {
      const start = Math.max(0, end - Math.max(1, scope.runLimit));
      value.historyPage = {
        beforeRunId: scope.beforeRunId,
        nextBeforeRunId: start > 0 ? t.runs[start]!.id : null,
        runs: t.runs.slice(start, end),
      };
    }
  }
  value.searchIndex = scope.search
    ? value.tasks.flatMap((t) =>
        t.runs.map((r) => ({
          taskId: t.id,
          runId: r.id,
          input: r.input,
          output: r.output,
        })),
      )
    : null;
  value.receipts = scope.receipts.map((r) => ({ ...r, observed: true }));
  Object.keys(value.blockVersions).forEach((key) => {
    value.blockVersions[key as keyof typeof value.blockVersions] =
      value.revision;
  });
  return value;
}

export function setDemoDisplayName(value: string) {
  const name = value.trim().slice(0, 40);
  if (!name) return;
  demo.account.displayName = name;
  try {
    localStorage.setItem("metawork.demo.displayName", name);
  } catch {
    /* In-memory editing still works. */
  }
  changed();
}
const hiddenDemoProjects = new Set<string>();
export function isDemoProjectHidden(root: string) {
  return hiddenDemoProjects.has(root);
}
export function setDemoProjectHidden(root: string, hidden: boolean) {
  if (hidden) hiddenDemoProjects.add(root);
  else hiddenDemoProjects.delete(root);
  changed();
}

if (
  typeof window !== "undefined" &&
  new URLSearchParams(window.location.search).get("qa") === "uiux"
) {
  const historyTask = makeTask("90", "UIUX QA · 长会话与代码排版", "1");
  const code = Array.from(
    { length: 20 },
    (_, index) => `const value${index + 1} = "${"sample ".repeat(24)}";`,
  ).join("\n");
  for (let index = 0; index < 8; index++) {
    const run = makeRun(
      historyTask,
      `模拟历史消息 ${index + 1}`,
      index === 7
        ? `## 代码排版验证\n\n以下仅用于检查复制按钮与滚动位置。\n\n\`\`\`javascript\n${code}\n\`\`\``
        : `## 第 ${index + 1} 轮结果\n\n这是一条模拟历史回复。\n\n${"用于检查向前加载与阅读位置。\n\n".repeat(4)}`,
    );
    historyTask.runs.push(run);
  }
  historyTask.runs[7]!.output.response =
    historyTask.runs[7]!.output.response.replace(
      "以下仅用于检查复制按钮与滚动位置。",
      "以下仅用于检查复制按钮与滚动位置。\n\n[产品设计计划.md](产品设计计划.md)\n\n[参考链接](https://example.com)",
    );
  historyTask.runs[7]!.tools = structuredClone(report.tools);
  historyTask.runs[7]!.outputs = structuredClone(report.outputs);
  historyTask.currentRunId = "8";
  const runningTask = makeTask("91", "UIUX QA · 双工具执行", "1");
  const running = makeRun(
    runningTask,
    "模拟两个工具运行",
    "已保留的部分结果。",
    "running",
  );
  const template = demo.tasks[0]!.runs[0]!.tools[0]!;
  running.tools = ["1", "2"].map((id) => ({
    ...structuredClone(template),
    id,
    state: "running",
  }));
  running.activity = { kind: "executing_tools", inFlight: "2" };
  runningTask.runs.push(running);
  runningTask.currentRunId = "1";
  runningTask.currentRunPhase = "running";
  runningTask.activeOperation = { kind: "run", id: "1" };
  demo.tasks.push(historyTask, runningTask);
  const schedule = structuredClone(demo.scheduledTasks![0]!);
  Object.assign(schedule, {
    id: "90",
    title: "UIUX QA · 跳过原因",
    health: "needs_attention",
    failureReason: "previous_task_running",
    enabled: false,
    nextRunAtUnixSeconds: null,
    occurrences: [
      {
        source: "timer",
        plannedAtUnixSeconds: String(Math.floor(Date.now() / 1000) - 60),
        triggeredAtUnixSeconds: String(Math.floor(Date.now() / 1000) - 60),
        result: "skipped",
        taskId: null,
        taskOutcome: null,
        reason: "previous_task_running",
      },
    ],
  });
  demo.scheduledTasks!.push(schedule);
}
