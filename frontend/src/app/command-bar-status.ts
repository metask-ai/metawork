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
  lifecycle: "condition" | "result" | "legacy";
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
export type ShellRoute = "workbench" | "skills" | "mcp" | "scheduled-tasks";

type ShellStatusContext = {
  route: ShellRoute;
  settingsOpen: boolean;
  workspaceId: string | null;
  taskId: string | null;
};

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

export function publishStatus(
  state: ShellStatusState,
  status: ShellStatus,
): ShellStatusState {
  const entries = { ...state.entries };
  if (
    status.tone === "quiet" &&
    status.audience.scope === "workspace" &&
    status.audience.workspaceId !== null
  )
    delete entries["legacy:workspace:*"];
  return observeFeedback(
    { ...state, entries },
    `legacy:${statusKey(status.audience)}`,
    "legacy",
    status,
  );
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

function commandBarScopes(context: ShellStatusContext): string[] {
  return context.settingsOpen
    ? ["connection", "execution", "account"]
    : context.route === "skills"
      ? ["connection", "skills", "execution", "account"]
      : [
          "connection",
          `task:${context.taskId}`,
          `workspace:${context.workspaceId}`,
          "workspace:*",
          "execution",
          "account",
        ];
}

export function statusVisibleInCommandBar(
  status: ShellStatus,
  context: ShellStatusContext,
): boolean {
  if (status.tone !== "attention") return false;
  if (status.local) return false;
  if (!commandBarScopes(context).includes(statusKey(status.audience)))
    return false;
  if (status.audience.scope === "connection") return true;
  if (status.audience.scope === "account") return true;
  if (status.audience.scope === "execution") return true;
  if (status.audience.scope === "skills")
    return !context.settingsOpen && context.route === "skills";
  if (status.audience.scope === "workspace")
    return (
      !context.settingsOpen &&
      (status.audience.workspaceId === null ||
        status.audience.workspaceId === context.workspaceId)
    );
  return (
    !context.settingsOpen &&
    context.route === "workbench" &&
    status.audience.taskId === context.taskId
  );
}

export function selectCommandBarStatus(
  state: ShellStatusState,
  context: ShellStatusContext,
): FeedbackEntry | null {
  return selectCommandBarFeedback(state, context)[0] ?? null;
}

export function selectCommandBarFeedback(
  state: ShellStatusState,
  context: ShellStatusContext,
): FeedbackEntry[] {
  const scopes = commandBarScopes(context);
  return Object.values(state.entries)
    .filter(
      (entry): entry is FeedbackEntry =>
        !!entry &&
        !entry.dismissed &&
        statusVisibleInCommandBar(entry, context),
    )
    .sort(
      (left, right) =>
        scopes.indexOf(statusKey(left.audience)) -
        scopes.indexOf(statusKey(right.audience)),
    );
}
