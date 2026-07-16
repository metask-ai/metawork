import {
  WORKBENCH_SCHEMA_VERSION,
  type WorkbenchSnapshot,
} from "../host/contracts.ts";

export type WorkbenchState = {
  snapshot: WorkbenchSnapshot;
  activeSessionId: string | null;
  activeWorkspaceRoot: string | null;
};

export type WorkbenchAction =
  | { type: "snapshot.accepted"; snapshot: WorkbenchSnapshot }
  | { type: "session.selected"; sessionId: string }
  | { type: "workspace.selected"; workspaceRoot: string };

export const initialWorkbenchState: WorkbenchState = {
  snapshot: {
    schemaVersion: WORKBENCH_SCHEMA_VERSION,
    revision: "0",
    sessions: [],
  },
  activeSessionId: null,
  activeWorkspaceRoot: null,
};

export function workbenchReducer(
  state: WorkbenchState,
  action: WorkbenchAction,
): WorkbenchState {
  if (action.type === "session.selected") {
    const session = state.snapshot.sessions.find(
      (candidate) => candidate.id === action.sessionId,
    );
    if (!session) return state;
    return {
      ...state,
      activeSessionId: action.sessionId,
      activeWorkspaceRoot: session.workspaceRoot,
    };
  }
  if (action.type === "workspace.selected")
    return action.workspaceRoot
      ? {
          ...state,
          activeWorkspaceRoot: action.workspaceRoot,
          activeSessionId:
            state.snapshot.sessions.find(
              (session) =>
                session.workspaceRoot === action.workspaceRoot &&
                !session.archived,
            )?.id ??
            state.snapshot.sessions.find(
              (session) => session.workspaceRoot === action.workspaceRoot,
            )?.id ??
            null,
        }
      : state;
  const requestedWorkspace = state.activeWorkspaceRoot;
  const activeSessionStillExists = action.snapshot.sessions.some(
    (session) => session.id === state.activeSessionId,
  );
  const activeSessionId = activeSessionStillExists
    ? state.activeSessionId
    : (action.snapshot.sessions.find(
        (session) =>
          session.workspaceRoot === requestedWorkspace && !session.archived,
      )?.id ??
      action.snapshot.sessions.find(
        (session) => session.workspaceRoot === requestedWorkspace,
      )?.id ??
      action.snapshot.sessions.find((session) => !session.archived)?.id ??
      action.snapshot.sessions[0]?.id ??
      null);
  const activeSession = action.snapshot.sessions.find(
    (session) => session.id === activeSessionId,
  );
  return {
    snapshot: action.snapshot,
    activeSessionId,
    activeWorkspaceRoot:
      state.activeWorkspaceRoot ?? activeSession?.workspaceRoot ?? null,
  };
}
