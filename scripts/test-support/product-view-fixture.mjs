// Synthetic aggregate builders for domain/interaction tests. Production only
// accepts the scoped wire; these builders are never imported by the Renderer.
import { readFileSync } from "node:fs";
const initialViewScope = {
  ...JSON.parse(
    readFileSync(
      new URL(
        "../../frontend/src/bridge/__fixtures__/product-view.fixture",
        import.meta.url,
      ),
      "utf8",
    ),
  ).scope,
  taskId: null,
  management: "none",
};
function taskHasSubmission(task, operationId) {
  return Boolean(
    task &&
    (task.inputSubmissions.some(
      (record) => record.submission.operationId === operationId,
    ) ||
      task.runs.some(
        (run) =>
          run.submission?.operationId === operationId ||
          run.additionalInputs.some(
            (input) => input.operationId === operationId,
          ),
      )),
  );
}

export function taskSummary(task) {
  const summary = {};
  for (const key of [
    "id",
    "signal",
    "recentOrder",
    "title",
    "workspaceId",
    "archived",
    "lifecycle",
    "deletionStatus",
    "permissionReviewState",
    "currentRunPhase",
    "activeOperation",
    "unreadCompletionRunId",
  ])
    if (Object.hasOwn(task, key)) summary[key] = task[key];
  const compact = task.compacts?.find(
    (entry) => entry.operationId === task.activeOperation?.id,
  );
  summary.historyReadOnly =
    task.continuationUnavailableReason === "history_read_only";
  summary.activeCompactPhase =
    task.activeOperation?.kind === "compact" ? (compact?.phase ?? null) : null;
  summary.lastCompactPhase = task.compacts?.at(-1)?.phase ?? null;
  const terminal = task.runs?.findLast((run) => run.terminal)?.terminal;
  summary.latestTerminal = terminal
    ? { outcome: terminal.outcome, cause: terminal.cause }
    : null;
  return summary;
}

function fixtureSignal(task, terminal) {
  if (task.currentRunPhase === "waiting_ui")
    return task.permissionReviewState === "reviewing" ? "running" : "attention";
  if (
    task.currentRunPhase ||
    ["compact", "restore"].includes(task.activeOperation?.kind)
  )
    return "running";
  if (task.deletionStatus === "failed") return "failed";
  if (terminal?.outcome === "interrupted") return "interrupted";
  if (["failed", "dependency_contract_failure"].includes(terminal?.outcome))
    return "failed";
  return null;
}

export function productViewFixture(
  state,
  scope = { ...initialViewScope, taskId: state.tasks[0]?.id ?? null },
) {
  scope = { ...initialViewScope, ...scope };
  const {
    tasks,
    workspaces,
    skillManagement,
    mcp,
    scheduledTasks,
    taskIndex: ignoredIndex,
    taskPage: ignoredPage,
    scope: ignoredScope,
    searchIndex: ignoredSearch,
    historyPage: ignoredHistory,
    securityEpoch: ignoredSecurityEpoch,
    historyEpoch: ignoredHistoryEpoch,
    receipts: ignoredReceipts,
    revision: ignoredRevision,
    blockVersions: ignoredVersions,
    reusedBlocks: ignoredReused,
    ...context
  } = structuredClone(state);
  context.mcpInstallation ??= { proposal: null, notice: null };
  const selected = tasks.find((task) => task.id === scope.taskId);
  const taskPage = selected
    ? {
        beforeRunId: null,
        nextBeforeRunId:
          selected.runs.length > scope.runLimit
            ? selected.runs.at(-scope.runLimit).id
            : null,
        runManifest: selected.runs.map((run) => ({
          contentVersion: run.contentVersion ?? "1",
          ...Object.fromEntries(
            [
              "id",
              "phase",
              "permissionProfile",
              "permissionInteraction",
              "terminal",
            ].map((key) => [key, run[key]]),
          ),
        })),
        task: { ...selected, runs: selected.runs.slice(-scope.runLimit) },
      }
    : null;
  return {
    revision: state.revision,
    blockVersions: Object.fromEntries(
      [
        "context",
        "workspaces",
        "taskIndex",
        "taskPage",
        "historyPage",
        "management",
        "searchIndex",
      ].map((name) => [name, state.revision === "0" ? "1" : state.revision]),
    ),
    reusedBlocks: [],
    securityEpoch: state.securityEpoch ?? "1",
    historyEpoch: state.historyEpoch ?? "1",
    scope: { ...scope },
    receipts: scope.receipts.map((query) => ({
      ...query,
      observed: taskHasSubmission(
        tasks.find((task) => task.id === query.taskId),
        query.operationId,
      ),
    })),
    context,
    workspaces,
    taskIndex: tasks.map(taskSummary),
    taskPage,
    historyPage:
      selected && scope.beforeRunId !== null
        ? (() => {
            const end = selected.runs.findIndex(
              (run) => run.id === scope.beforeRunId,
            );
            if (end < 0) throw new Error("Unknown fixture history cursor");
            const start = Math.max(0, end - scope.runLimit);
            return {
              beforeRunId: scope.beforeRunId,
              nextBeforeRunId: start > 0 ? selected.runs[start].id : null,
              runs: selected.runs.slice(start, end),
            };
          })()
        : null,
    searchIndex: scope.search
      ? (state.searchIndex ?? { stale: false, results: [], nextCursor: null })
      : null,
    management: {
      kind: scope.management,
      value:
        scope.management === "skills"
          ? skillManagement
          : scope.management === "mcp"
            ? mcp
            : scope.management === "schedules"
              ? scheduledTasks
              : null,
    },
  };
}

export function productStateFixture(
  state,
  scope = { ...initialViewScope, taskId: state.tasks[0]?.id ?? null },
) {
  const tasks = state.tasks.map((task) => ({
    ...task,
    signal: fixtureSignal(
      task,
      task.runs.findLast((run) => run.terminal)?.terminal,
    ),
  }));
  const wire = productViewFixture({ ...state, tasks }, scope);
  return {
    ...wire.context,
    revision: wire.revision,
    blockVersions: wire.blockVersions,
    securityEpoch: wire.securityEpoch,
    historyEpoch: wire.historyEpoch,
    scope: wire.scope,
    receipts: wire.receipts,
    searchIndex: wire.searchIndex,
    taskIndex: wire.taskIndex,
    taskPage: wire.taskPage,
    historyPage: wire.historyPage,
    tasks: wire.taskPage ? [wire.taskPage.task] : [],
    workspaces: wire.workspaces,
    skillManagement:
      scope.management === "skills" ? wire.management.value : null,
    mcp: scope.management === "mcp" ? wire.management.value : null,
    scheduledTasks:
      scope.management === "schedules" ? wire.management.value : null,
  };
}

// Keep the existing domain-field mutation cases while validating each consumer
// through the current strict wire decoder. The exact scoped Host fixture and
// transport tests separately exercise framing, scope and omissions.
