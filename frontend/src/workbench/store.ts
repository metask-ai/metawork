import {
  WORKBENCH_SCHEMA_VERSION,
  type WorkbenchSnapshot,
} from "../host/contracts.ts";

export type WorkbenchState = {
  snapshot: WorkbenchSnapshot;
  activeSessionId: string | null;
};

export type WorkbenchAction =
  | { type: "snapshot.accepted"; snapshot: WorkbenchSnapshot }
  | { type: "session.selected"; sessionId: string };

export const initialWorkbenchState: WorkbenchState = {
  snapshot: {
    schemaVersion: WORKBENCH_SCHEMA_VERSION,
    revision: "0",
    sessions: [],
  },
  activeSessionId: null,
};

export function workbenchReducer(
  state: WorkbenchState,
  action: WorkbenchAction,
): WorkbenchState {
  if (action.type === "session.selected") {
    if (
      !action.sessionId ||
      !state.snapshot.sessions.some(
        (session) => session.id === action.sessionId,
      )
    )
      return state;
    return { ...state, activeSessionId: action.sessionId };
  }
  const activeSessionId =
    state.activeSessionId &&
    action.snapshot.sessions.some(
      (session) => session.id === state.activeSessionId,
    )
      ? state.activeSessionId
      : (action.snapshot.sessions[0]?.id ?? null);
  return { snapshot: action.snapshot, activeSessionId };
}
