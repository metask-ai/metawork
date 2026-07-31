import type { MessageId } from "../i18n/context.ts";

export type StatusAudience =
  | { scope: "connection" }
  | { scope: "account" }
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
};

export type ShellStatusState = Readonly<Partial<Record<string, ShellStatus>>>;
export type ShellRoute = "workbench" | "skills" | "settings";

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
  if (audience.scope === "connection" || audience.scope === "account")
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
  const next = { ...state };
  if (
    status.tone === "quiet" &&
    status.audience.scope === "workspace" &&
    status.audience.workspaceId !== null
  )
    delete next["workspace:*"];
  next[statusKey(status.audience)] = status;
  return next;
}

export function statusVisibleInCommandBar(
  status: ShellStatus,
  context: {
    route: ShellRoute;
    workspaceId: string | null;
    taskId: string | null;
  },
): boolean {
  if (status.tone !== "attention") return false;
  if (status.audience.scope === "connection") return true;
  if (status.audience.scope === "account") return true;
  if (status.audience.scope === "skills") return context.route === "skills";
  if (status.audience.scope === "workspace")
    return (
      context.route !== "settings" &&
      (status.audience.workspaceId === null ||
        status.audience.workspaceId === context.workspaceId)
    );
  return (
    context.route === "workbench" && status.audience.taskId === context.taskId
  );
}

export function statusVisibleInAccountGate(status: ShellStatus): boolean {
  return status.tone === "attention" && status.audience.scope === "account";
}

export function selectCommandBarStatus(
  state: ShellStatusState,
  context: {
    route: ShellRoute;
    workspaceId: string | null;
    taskId: string | null;
  },
): ShellStatus | null {
  const candidates =
    context.route === "settings"
      ? [state.connection, state.account]
      : context.route === "skills"
        ? [state.connection, state.skills, state.account]
        : [
            state.connection,
            context.taskId === null
              ? undefined
              : state[`task:${context.taskId}`],
            context.workspaceId === null
              ? undefined
              : state[`workspace:${context.workspaceId}`],
            state["workspace:*"],
            state.account,
          ];
  return (
    candidates.find(
      (status): status is ShellStatus =>
        status !== undefined && statusVisibleInCommandBar(status, context),
    ) ?? null
  );
}

export function selectAccountGateStatus(
  state: ShellStatusState,
): ShellStatus | null {
  const status = state.account;
  return status !== undefined && statusVisibleInAccountGate(status)
    ? status
    : null;
}
