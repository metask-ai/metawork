// Verification-only aggregation over the current scoped data plane. This is not
// a Renderer state or atomic Product snapshot; command authority remains Host-owned.
import { fetchWorkbenchSnapshot } from "../frontend/src/bridge/snapshot/snapshot-client.ts";
import { initialViewScope } from "../frontend/src/bridge/contracts.ts";
import {
  initialWorkbenchState,
  workbenchReducer,
} from "../frontend/src/workbench/store.ts";

function retryable(message) {
  return Object.assign(new Error(message), { retryableSnapshotRead: true });
}
export async function readProbeProductState(invoke, { forbidden = [] } = {}) {
  async function read(scope) {
    const next = await fetchWorkbenchSnapshot(async (command, payload) => {
      const result = await invoke(command, payload);
      if (result === null)
        throw retryable("Probe snapshot response was unavailable");
      return result;
    }, scope);
    const encoded = JSON.stringify(next);
    if (forbidden.some((value) => value && encoded.includes(value)))
      throw new Error("Host credential reached a projection probe");
    return next;
  }
  const index = await read(initialViewScope);
  const tasks = [];
  for (const summary of index.taskIndex) {
    let retained;
    for (let attempt = 0; attempt < 3; attempt++) {
      let state = initialWorkbenchState;
      let cursor = null;
      do {
        const view = await read({
          ...initialViewScope,
          taskId: summary.id,
          beforeRunId: cursor,
        });
        state = workbenchReducer(state, {
          type: "snapshot.accepted",
          snapshot: view,
          receivedAt: performance.now(),
        });
        if (!view.taskPage) break;
        cursor =
          view.historyPage?.nextBeforeRunId ??
          (cursor === null ? view.taskPage.nextBeforeRunId : null);
      } while (cursor !== null);
      retained = state.snapshot.tasks[0];
      if (
        !retained ||
        retained.runs.length === state.snapshot.taskPage.runManifest.length
      )
        break;
      if (attempt === 2)
        throw retryable("Probe history changed during scoped collection");
    }
    if (retained) tasks.push(retained);
  }
  const skills = await read({ ...initialViewScope, management: "skills" });
  const mcp = await read({ ...initialViewScope, management: "mcp" });
  const schedules = await read({
    ...initialViewScope,
    management: "schedules",
  });
  const latest = await read(initialViewScope);
  const ids = new Set(latest.taskIndex.map((task) => task.id));
  return {
    ...latest,
    tasks: tasks.filter((task) => ids.has(task.id)),
    skillManagement: skills.skillManagement,
    mcp: mcp.mcp,
    scheduledTasks: schedules.scheduledTasks,
  };
}
