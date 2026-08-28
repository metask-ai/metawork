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

const failureOutcomes = new Set<NonNullable<RunView["outcome"]>>([
  "failed",
  "interrupted",
  "dependency_contract_failure",
]);

export type RunPresentation = {
  active: boolean;
  activity: RunActivity | null;
  responseVisible: boolean;
  processVisible: boolean;
  processDefaultExpanded: boolean;
  processCanCollapse: boolean;
  showTerminalNotice: boolean;
  tools: ToolView[];
  runningToolName: string | null;
  toolCount: number;
  failedToolCount: number;
};

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
  const processEvidenceVisible =
    run.output.commentary.length > 0 ||
    run.output.provisional.length > 0 ||
    run.output.provisionalRedacted ||
    (run.output.redacted && !responseVisible) ||
    tools.length > 0;
  const processVisible = active || processEvidenceVisible;
  const failure = run.outcome !== null && failureOutcomes.has(run.outcome);
  const processDefaultExpanded = active || failure || !responseVisible;

  return {
    active,
    activity,
    responseVisible,
    processVisible,
    processDefaultExpanded,
    processCanCollapse: processEvidenceVisible,
    showTerminalNotice:
      run.outcome !== null &&
      (run.output.responseKind === "partial" ||
        run.outcome !== "completed" ||
        !responseVisible),
    tools,
    runningToolName:
      activity?.kind === "executing_tools" && runningTools.length === 1
        ? runningTools[0]!.name
        : null,
    toolCount: tools.length,
    failedToolCount: tools.filter((tool) => tool.state === "failed").length,
  };
}

export type RunProcessDisclosure = {
  expanded: boolean;
  userToggled: boolean;
  wasActive: boolean;
};

export function observeRunProcessDisclosure(
  current: RunProcessDisclosure | undefined,
  presentation: RunPresentation,
  followingLatest: boolean,
): RunProcessDisclosure {
  if (!current) {
    return {
      expanded: presentation.processDefaultExpanded,
      userToggled: false,
      wasActive: presentation.active,
    };
  }
  if (presentation.active) {
    return {
      ...current,
      expanded: current.userToggled ? current.expanded : true,
      wasActive: true,
    };
  }
  return {
    ...current,
    expanded: shouldAutoCollapseRunProcess({
      presentation,
      wasActive: current.wasActive,
      followingLatest,
      userToggled: current.userToggled,
    })
      ? false
      : current.expanded,
    wasActive: false,
  };
}

export function toggleRunProcessDisclosure(
  current: RunProcessDisclosure,
  expanded: boolean,
): RunProcessDisclosure {
  return { ...current, expanded, userToggled: true };
}

export function shouldAutoCollapseRunProcess({
  presentation,
  wasActive,
  followingLatest,
  userToggled,
}: {
  presentation: RunPresentation;
  wasActive: boolean;
  followingLatest: boolean;
  userToggled: boolean;
}): boolean {
  return (
    wasActive &&
    !presentation.active &&
    presentation.processCanCollapse &&
    !presentation.processDefaultExpanded &&
    followingLatest &&
    !userToggled
  );
}
