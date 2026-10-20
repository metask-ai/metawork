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

export function productViewFixture(
  state,
  scope = { ...initialViewScope, taskId: state.tasks[0]?.id ?? null },
) {
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
    receipts: ignoredReceipts,
    ...context
  } = structuredClone(state);
  const selected = tasks.find((task) => task.id === scope.taskId);
  const taskPage = selected
    ? {
        beforeRunId: null,
        nextBeforeRunId:
          selected.runs.length > scope.runLimit
            ? selected.runs.at(-scope.runLimit).id
            : null,
        runManifest: selected.runs.map((run) =>
          Object.fromEntries(
            [
              "id",
              "phase",
              "permissionProfile",
              "permissionInteraction",
              "terminal",
            ].map((key) => [key, run[key]]),
          ),
        ),
        task: { ...selected, runs: selected.runs.slice(-scope.runLimit) },
      }
    : null;
  return {
    revision: state.revision,
    securityEpoch: state.securityEpoch ?? "1",
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
      ? tasks.flatMap((task) =>
          task.runs.map((run) => ({
            taskId: task.id,
            runId: run.id,
            input: run.input,
            output: run.terminal?.outcome === "completed" ? run.output : null,
          })),
        )
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
  const wire = productViewFixture(state, scope);
  return {
    ...wire.context,
    securityEpoch: wire.securityEpoch,
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
