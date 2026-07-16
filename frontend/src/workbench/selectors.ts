import type { SessionView } from "../host/contracts.ts";
import type { WorkbenchState } from "./store.ts";

export function selectActiveSession(state: WorkbenchState): SessionView | null {
  return (
    state.snapshot.sessions.find(
      (session) => session.id === state.activeSessionId,
    ) ??
    state.snapshot.sessions[0] ??
    null
  );
}
