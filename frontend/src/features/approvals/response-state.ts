import type { PendingUi, WorkbenchSnapshot } from "../../host/contracts.ts";

export type UiRequestIdentity = {
  sessionId: string;
  runId: string;
  requestId: string;
};

export type UiResponsePhase =
  "idle" | "sending" | "awaiting_snapshot" | "failed";

type UiResponseEntry = UiRequestIdentity & {
  phase: Exclude<UiResponsePhase, "idle">;
};

export type UiResponseStates = Readonly<Record<string, UiResponseEntry>>;

export const initialUiResponseStates: UiResponseStates = Object.freeze({});

export function uiRequestIdentity(
  sessionId: string,
  pending: PendingUi,
): UiRequestIdentity {
  return {
    sessionId,
    runId: pending.runId,
    requestId: pending.requestId,
  };
}

export function uiRequestKey(identity: UiRequestIdentity): string {
  return `${identity.sessionId}/${identity.runId}/${identity.requestId}`;
}

function sameIdentity(
  entry: UiResponseEntry,
  identity: UiRequestIdentity,
): boolean {
  return (
    entry.sessionId === identity.sessionId &&
    entry.runId === identity.runId &&
    entry.requestId === identity.requestId
  );
}

export function beginUiResponse(
  states: UiResponseStates,
  identity: UiRequestIdentity,
): UiResponseStates {
  const key = uiRequestKey(identity);
  const current = states[key];
  if (
    current &&
    (current.phase === "sending" || current.phase === "awaiting_snapshot")
  )
    return states;
  return {
    ...states,
    [key]: { ...identity, phase: "sending" },
  };
}

function transitionUiResponse(
  states: UiResponseStates,
  identity: UiRequestIdentity,
  phase: "awaiting_snapshot" | "failed",
): UiResponseStates {
  const key = uiRequestKey(identity);
  const current = states[key];
  if (
    !current ||
    current.phase !== "sending" ||
    !sameIdentity(current, identity)
  )
    return states;
  return {
    ...states,
    [key]: { ...identity, phase },
  };
}

export function acceptUiResponse(
  states: UiResponseStates,
  identity: UiRequestIdentity,
): UiResponseStates {
  return transitionUiResponse(states, identity, "awaiting_snapshot");
}

export function failUiResponse(
  states: UiResponseStates,
  identity: UiRequestIdentity,
): UiResponseStates {
  return transitionUiResponse(states, identity, "failed");
}

export function snapshotHasUiRequest(
  snapshot: WorkbenchSnapshot,
  identity: UiRequestIdentity,
): boolean {
  const pending = snapshot.sessions.find(
    (session) => session.id === identity.sessionId,
  )?.pendingUi;
  return (
    pending?.runId === identity.runId &&
    pending.requestId === identity.requestId
  );
}

export function observeUiResponseSnapshot(
  states: UiResponseStates,
  snapshot: WorkbenchSnapshot,
): UiResponseStates {
  let next: Record<string, UiResponseEntry> | null = null;
  for (const [key, entry] of Object.entries(states)) {
    if (snapshotHasUiRequest(snapshot, entry)) continue;
    if (!next) next = { ...states };
    delete next[key];
  }
  return next ?? states;
}

export function uiResponsePhase(
  states: UiResponseStates,
  identity: UiRequestIdentity,
): UiResponsePhase {
  const entry = states[uiRequestKey(identity)];
  return entry && sameIdentity(entry, identity) ? entry.phase : "idle";
}
