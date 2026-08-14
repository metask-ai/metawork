import type {
  CompactView,
  PendingUi,
  RunInputView,
  RunView,
  TaskView,
  ToolView,
  UiRecord,
} from "../../bridge/contracts.ts";

export type AgentActivity =
  | {
      kind: "tool";
      id: string;
      order: string;
      value: ToolView;
    }
  | {
      kind: "pending_ui";
      id: string;
      order: string;
      value: PendingUi;
    }
  | {
      kind: "resolved_ui";
      id: string;
      order: string;
      value: UiRecord;
    };

export type AssistantProjection = {
  markdown: string;
  streaming: boolean;
  redacted: boolean;
};

export type RunEntry = {
  kind: "run";
  runId: string;
  input: RunInputView;
  activities: AgentActivity[];
  assistant: AssistantProjection | null;
  phase: RunView["phase"];
  outcome: RunView["outcome"];
  cause: RunView["cause"];
  usage: RunView["usage"];
};

export type CompactEntry = {
  kind: "compact";
  id: string;
  compact: CompactView;
};

export type ConversationEntry = RunEntry | CompactEntry;

function compareOrder(left: string, right: string): number {
  const leftOrder = BigInt(left);
  const rightOrder = BigInt(right);
  return leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0;
}

function activitiesForRun(run: RunView, task: TaskView): AgentActivity[] {
  const activities: AgentActivity[] = [
    ...run.tools.map((value) => ({
      kind: "tool" as const,
      id: value.id,
      order: value.order,
      value,
    })),
    ...task.uiHistory
      .filter((value) => value.runId === run.id)
      .map((value) => ({
        kind: "resolved_ui" as const,
        id: value.requestId,
        order: value.order,
        value,
      })),
  ];

  if (task.pendingUi?.runId === run.id) {
    activities.push({
      kind: "pending_ui",
      id: task.pendingUi.requestId,
      order: task.pendingUi.order,
      value: task.pendingUi,
    });
  }

  return activities.sort((left, right) =>
    compareOrder(left.order, right.order),
  );
}

export function projectRunEntry(run: RunView, task: TaskView): RunEntry {
  return {
    kind: "run",
    runId: run.id,
    input: run.input,
    activities: activitiesForRun(run, task),
    assistant:
      run.assistant.length > 0
        ? {
            markdown: run.assistant,
            streaming:
              run.phase === "queued" ||
              run.phase === "running" ||
              run.phase === "waiting_ui" ||
              run.phase === "stopping",
            redacted: run.assistantRedacted,
          }
        : null,
    phase: run.phase,
    outcome: run.outcome,
    cause: run.cause,
    usage: run.usage,
  };
}

export function projectConversation(
  task: TaskView | null,
): ConversationEntry[] {
  if (!task) return [];

  const entries: ConversationEntry[] = [];
  for (const run of task.runs) {
    entries.push(projectRunEntry(run, task));
    for (const compact of task.compacts) {
      if (compact.afterRunId === run.id) {
        entries.push({
          kind: "compact",
          id: compact.operationId,
          compact,
        });
      }
    }
  }
  return entries;
}
