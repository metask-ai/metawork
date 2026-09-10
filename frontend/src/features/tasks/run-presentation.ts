import type {
  RunActivity,
  RunPhase,
  RunView,
  ToolView,
} from "../../bridge/contracts.ts";

const nonTerminalPhases = new Set<RunPhase>([
  "queued",
  "running",
  "waiting_ui",
  "stopping",
]);

export type RunPresentation = {
  active: boolean;
  activity: RunActivity | null;
  responseVisible: boolean;
  processVisible: boolean;
  processCanCollapse: boolean;
  showTerminalNotice: boolean;
  tools: ToolView[];
  runningToolName: string | null;
  toolCount: number;
};

/** A display estimate since a Host sample, never a liveness observation. */
export function runElapsedSeconds(
  elapsedMs: string,
  receivedAt: number,
  now: number,
): bigint {
  return (
    (BigInt(elapsedMs) + BigInt(Math.floor(Math.max(0, now - receivedAt)))) /
    1000n
  );
}

function fallbackActivity(phase: RunPhase): RunActivity | null {
  switch (phase) {
    case "queued":
      return { kind: "queued" };
    case "running":
      return { kind: "waiting_model" };
    case "waiting_ui":
      return { kind: "waiting_user" };
    case "stopping":
      return { kind: "stopping" };
    case "completed":
    case "stopped":
    case "cancelled":
    case "interrupted":
    case "failed":
      return null;
  }
}

function orderedTools(tools: ToolView[]): ToolView[] {
  return [...tools].sort((left, right) => {
    const leftOrder = BigInt(left.order);
    const rightOrder = BigInt(right.order);
    return leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0;
  });
}

export function deriveRunPresentation(run: RunView): RunPresentation {
  const active = nonTerminalPhases.has(run.phase);
  const activity = active
    ? (run.activity ?? fallbackActivity(run.phase))
    : null;
  const tools = orderedTools(run.tools);
  const runningTools = tools.filter((tool) => tool.state === "running");
  const responseVisible = run.output.response.length > 0;
  const processCanCollapse = tools.length > 0;

  return {
    active,
    activity,
    responseVisible,
    processVisible: active || processCanCollapse,
    processCanCollapse,
    showTerminalNotice:
      run.terminal !== null &&
      (run.output.responseKind === "partial" ||
        run.terminal.outcome !== "completed" ||
        !responseVisible),
    tools,
    runningToolName:
      activity?.kind === "executing_tools" && runningTools.length === 1
        ? runningTools[0]!.name
        : null,
    toolCount: tools.length,
  };
}

export type RunProcessDisclosure = {
  expanded: boolean;
};

export function observeRunProcessDisclosure(
  current: RunProcessDisclosure | undefined,
): RunProcessDisclosure {
  if (current) return current;
  return { expanded: false };
}

export function toggleRunProcessDisclosure(
  expanded: boolean,
): RunProcessDisclosure {
  return { expanded };
}
