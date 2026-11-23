import {
  decodeRunToolsPage,
  decodeWorkbenchSnapshot,
} from "../../frontend/src/bridge/decode-contracts.ts";
import { productViewFixture } from "./product-view-fixture.mjs";
import { initialViewScope } from "../../frontend/src/bridge/contracts.ts";

const wireFields = { deriveTaskActions: false };

/** Decodes listed Tool records the way a page of `metawork.tasks.tools` is. */
export function decodeRunToolsFixture(tools) {
  return decodeRunToolsPage(
    {
      generation: "1",
      requestId: "1",
      state: "ready",
      securityEpoch: "1",
      revision: "1",
      total: String(tools.length),
      tools,
      nextAfterOrder: null,
    },
    "0",
  ).tools;
}

// The aggregate fixture keeps its own Run shape: records listed as `tools`
// are checked by the page decoder, and the summary fields are the source's.
function restoreRun(decoded, source) {
  const run = { ...decoded };
  if (!source) return run;
  if (!("fileReferences" in source)) delete run.fileReferences;
  if ("toolLog" in source) run.toolLog = source.toolLog;
  else delete run.toolLog;
  if ("tools" in source) run.tools = decodeRunToolsFixture(source.tools);
  return run;
}

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
      productViewFixture(
        state,
        {
          ...initialViewScope,
          taskId,
          management: "skills",
        },
        wireFields,
      ),
    );
    base = decoded;
    skillManagement = decoded.skillManagement;
    if (decoded.taskPage) {
      const sourceRuns =
        state.tasks.find((entry) => entry.id === taskId)?.runs ?? [];
      const restore = (run) =>
        restoreRun(
          run,
          sourceRuns.find((entry) => entry.id === run.id),
        );
      const task = {
        ...decoded.taskPage.task,
        runs: decoded.taskPage.task.runs.map(restore),
      };
      let cursor = decoded.taskPage.nextBeforeRunId;
      while (cursor) {
        const older = decodeWorkbenchSnapshot(
          productViewFixture(
            state,
            {
              ...initialViewScope,
              taskId,
              beforeRunId: cursor,
            },
            wireFields,
          ),
        );
        task.runs.unshift(...older.historyPage.runs.map(restore));
        cursor = older.historyPage.nextBeforeRunId;
      }
      tasks.push(task);
    }
  }
  mcp = decodeWorkbenchSnapshot(
    productViewFixture(
      state,
      { ...initialViewScope, management: "mcp" },
      wireFields,
    ),
  ).mcp;
  scheduledTasks = decodeWorkbenchSnapshot(
    productViewFixture(
      state,
      { ...initialViewScope, management: "schedules" },
      wireFields,
    ),
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
