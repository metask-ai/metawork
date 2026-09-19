import type {
  RunActivity,
  RunPhase,
  RunView,
  ToolView,
} from "../../bridge/contracts.ts";
import { translate, type Locale } from "../../i18n/runtime.ts";

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

export type RunTimestamp = {
  absolute: string;
  dateTime: string;
  relative: string;
};

export function formatRunTimestamp(
  locale: Locale,
  unixMs: string | null,
  nowUnixMs: number,
): RunTimestamp | null {
  if (unixMs === null) return null;
  const timestamp = Number(unixMs);
  if (!Number.isFinite(timestamp) || timestamp <= 0) return null;
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return null;
  const formatterLocale = locale === "pseudo" ? "en-US" : locale;
  const delta = timestamp - nowUnixMs;
  const absoluteDelta = Math.abs(delta);
  let unit: Intl.RelativeTimeFormatUnit = "second";
  let divisor = 1;
  if (absoluteDelta >= 365 * 24 * 60 * 60 * 1000) {
    unit = "year";
    divisor = 365 * 24 * 60 * 60 * 1000;
  } else if (absoluteDelta >= 30 * 24 * 60 * 60 * 1000) {
    unit = "month";
    divisor = 30 * 24 * 60 * 60 * 1000;
  } else if (absoluteDelta >= 24 * 60 * 60 * 1000) {
    unit = "day";
    divisor = 24 * 60 * 60 * 1000;
  } else if (absoluteDelta >= 60 * 60 * 1000) {
    unit = "hour";
    divisor = 60 * 60 * 1000;
  } else if (absoluteDelta >= 60 * 1000) {
    unit = "minute";
    divisor = 60 * 1000;
  }
  const relativeValue =
    unit === "second"
      ? 0
      : delta < 0
        ? Math.ceil(delta / divisor)
        : Math.floor(delta / divisor);
  return {
    absolute: new Intl.DateTimeFormat(formatterLocale, {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(date),
    dateTime: date.toISOString(),
    relative:
      absoluteDelta < 60 * 1000
        ? translate(locale, "time.just_now")
        : new Intl.RelativeTimeFormat(formatterLocale, {
            numeric: "auto",
            style: "long",
          }).format(relativeValue, unit),
  };
}

export const formatRunFinishedTime = formatRunTimestamp;

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
    processVisible: active || tools.length > 0,
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
