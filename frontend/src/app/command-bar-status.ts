import type { MessageId } from "../i18n/context.ts";

export type StatusAudience =
  | { scope: "connection" }
  | { scope: "account" }
  | { scope: "execution" }
  | { scope: "skills" }
  | { scope: "workspace"; workspaceId: string | null }
  | { scope: "task"; taskId: string };

export type ShellStatus = {
  id: MessageId;
  tone: "quiet" | "attention";
  audience: StatusAudience;
  values?: Record<string, string>;
  diagnostic?: string;
  sourceId?: MessageId;
  local?: boolean;
};

export type FeedbackEntry = ShellStatus & {
  key: string;
  lifecycle: "condition" | "result";
  cycle: number;
  dismissed: boolean;
};

export type FeedbackToken = { key: string; cycle: number; epoch: number };
export type ShellStatusState = {
  epoch: number;
  sequence: number;
  entries: Readonly<Partial<Record<string, FeedbackEntry>>>;
  announcement: { sequence: number; status: ShellStatus } | null;
};

export function createFeedbackState(epoch = 0): ShellStatusState {
  return { epoch, sequence: 0, entries: {}, announcement: null };
}

export function resetFeedback(state: ShellStatusState): ShellStatusState {
  return createFeedbackState(state.epoch + 1);
}

/** Projection invalidation clears diagnostics, not in-flight operation tokens. */
export function clearSecurityFeedback(
  state: ShellStatusState,
): ShellStatusState {
  const entries: Record<string, FeedbackEntry> = {};
  for (const [key, entry] of Object.entries(state.entries)) {
    if (entry && entry.audience.scope !== "account")
      entries[key] = { ...entry, diagnostic: undefined };
  }
  return { ...state, entries, announcement: null };
}
export type ShellRoute = "workbench" | "skills" | "mcp" | "scheduled-tasks";

type StatusDetails = Pick<ShellStatus, "values" | "diagnostic" | "sourceId">;

export function quietStatus(
  id: MessageId,
  audience: StatusAudience,
  details: StatusDetails = {},
): ShellStatus {
  return { id, tone: "quiet", audience, ...details };
}

export function attentionStatus(
  id: MessageId,
  audience: StatusAudience,
  details: StatusDetails = {},
): ShellStatus {
  return { id, tone: "attention", audience, ...details };
}

export function statusKey(audience: StatusAudience): string {
  if (
    audience.scope === "connection" ||
    audience.scope === "account" ||
    audience.scope === "execution"
  )
    return audience.scope;
  if (audience.scope === "skills") return audience.scope;
  if (audience.scope === "workspace")
    return `workspace:${audience.workspaceId ?? "*"}`;
  return `task:${audience.taskId}`;
}

function sameStatus(left: ShellStatus, right: ShellStatus): boolean {
  return (
    left.id === right.id &&
    left.tone === right.tone &&
    statusKey(left.audience) === statusKey(right.audience) &&
    left.diagnostic === right.diagnostic &&
    left.sourceId === right.sourceId &&
    left.local === right.local &&
    JSON.stringify(left.values) === JSON.stringify(right.values)
  );
}

function writeFeedback(
  state: ShellStatusState,
  entry: FeedbackEntry,
  announce: boolean,
): ShellStatusState {
  const sequence = state.sequence + 1;
  return {
    ...state,
    sequence,
    entries: { ...state.entries, [entry.key]: entry },
    announcement:
      announce && entry.tone === "attention"
        ? { sequence, status: entry }
        : state.announcement,
  };
}

/** A source observation is not evidence of a new business occurrence. */
export function observeFeedback(
  state: ShellStatusState,
  key: string,
  lifecycle: FeedbackEntry["lifecycle"],
  status: ShellStatus | null,
  announce = true,
): ShellStatusState {
  if (!status) {
    if (!state.entries[key]) return state;
    const entries = { ...state.entries };
    delete entries[key];
    return { ...state, entries };
  }
  const previous = state.entries[key];
  if (previous && sameStatus(previous, status)) return state;
  return writeFeedback(
    state,
    {
      ...status,
      key,
      lifecycle,
      cycle: previous?.cycle ?? state.sequence + 1,
      dismissed: false,
    },
    announce,
  );
}

/** Local display identity; it does not correlate an asynchronous Host result. */
export function beginFeedback(
  state: ShellStatusState,
  key: string,
  status: ShellStatus,
): { state: ShellStatusState; token: FeedbackToken } {
  const cycle = state.sequence + 1;
  return {
    state: writeFeedback(
      state,
      { ...status, key, lifecycle: "result", cycle, dismissed: false },
      false,
    ),
    token: { key, cycle, epoch: state.epoch },
  };
}

export function feedbackTokenCurrent(
  state: ShellStatusState,
  token: FeedbackToken,
): boolean {
  return (
    state.epoch === token.epoch &&
    state.entries[token.key]?.cycle === token.cycle
  );
}

export function settleFeedback(
  state: ShellStatusState,
  token: FeedbackToken,
  status: ShellStatus | null,
  announce = true,
): ShellStatusState {
  return feedbackTokenCurrent(state, token)
    ? observeFeedback(state, token.key, "result", status, announce)
    : state;
}

export function dismissFeedback(
  state: ShellStatusState,
  key: string,
  cycle: number,
): ShellStatusState {
  const entry = state.entries[key];
  if (!entry || entry.cycle !== cycle || entry.dismissed) return state;
  return {
    ...state,
    entries: { ...state.entries, [key]: { ...entry, dismissed: true } },
  };
}

/** Task history and local business results never enter the global collection. */
export function statusVisibleInCommandBar(status: ShellStatus): boolean {
  return (
    status.tone === "attention" &&
    !status.local &&
    ["connection", "account", "execution"].includes(status.audience.scope)
  );
}

export function selectCommandBarFeedback(
  state: ShellStatusState,
): FeedbackEntry[] {
  const scopes = ["connection", "execution", "account"];
  return Object.values(state.entries)
    .filter(
      (entry): entry is FeedbackEntry =>
        !!entry && !entry.dismissed && statusVisibleInCommandBar(entry),
    )
    .sort(
      (left, right) =>
        scopes.indexOf(left.audience.scope) -
        scopes.indexOf(right.audience.scope),
    );
}
