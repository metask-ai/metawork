import { decodeWorkbenchSnapshot } from "../../frontend/src/bridge/decode-contracts.ts";
import { productViewFixture } from "./product-view-fixture.mjs";
import { initialViewScope } from "../../frontend/src/bridge/contracts.ts";
export function decodeProductStateFixture(state) {
  if (!Array.isArray(state.tasks)) return decodeWorkbenchSnapshot(state);
  const ids = state.tasks.map((task) => task.id);
  if (ids.length === 0) ids.push(null);
  let base;
  let skillManagement;
  let mcp;
  let scheduledTasks;
  const tasks = [];
  for (const taskId of ids) {
    const decoded = decodeWorkbenchSnapshot(
      productViewFixture(state, {
        ...initialViewScope,
        taskId,
        management: "skills",
      }),
    );
    base = decoded;
    skillManagement = decoded.skillManagement;
    if (decoded.taskPage) {
      const task = {
        ...decoded.taskPage.task,
        runs: [...decoded.taskPage.task.runs],
      };
      let cursor = decoded.taskPage.nextBeforeRunId;
      while (cursor) {
        const older = decodeWorkbenchSnapshot(
          productViewFixture(state, {
            ...initialViewScope,
            taskId,
            beforeRunId: cursor,
          }),
        );
        task.runs.unshift(...older.historyPage.runs);
        cursor = older.historyPage.nextBeforeRunId;
      }
      tasks.push(task);
    }
  }
  mcp = decodeWorkbenchSnapshot(
    productViewFixture(state, { ...initialViewScope, management: "mcp" }),
  ).mcp;
  scheduledTasks = decodeWorkbenchSnapshot(
    productViewFixture(state, { ...initialViewScope, management: "schedules" }),
  ).scheduledTasks;
  const {
    scope,
    taskIndex,
    taskPage,
    historyPage,
    securityEpoch,
    historyEpoch,
    blockVersions,
    searchIndex,
    receipts,
    ...fields
  } = base;
  return { ...fields, tasks, skillManagement, mcp, scheduledTasks };
}
