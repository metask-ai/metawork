// Verification-only aggregation over the current scoped data plane. This is not
// a Renderer state or atomic Product snapshot; command authority remains Host-owned.
import { fetchWorkbenchSnapshot } from "../frontend/src/bridge/snapshot/snapshot-client.ts";
import { initialViewScope } from "../frontend/src/bridge/contracts.ts";
import { decodeRunToolsPage } from "../frontend/src/bridge/decode-contracts.ts";
import {
  initialWorkbenchState,
  workbenchReducer,
} from "../frontend/src/workbench/store.ts";

function retryable(message) {
  return Object.assign(new Error(message), { retryableSnapshotRead: true });
}

// The probe shares the bridge connection with the real Renderer, and Tool page
// request ids must rise within a connection. The Renderer counts from 1 and
// reads only while a Run's details are open, which the verticals never do;
// starting from the clock keeps the probe above it and above an earlier probe
// process on the same connection.
let nextToolsRequest = BigInt(Date.now()) * 1_000_000n;

/**
 * Task pages carry a Run's Tool summary, not its records. The probe reads the
 * records page by page and gives them back as `run.tools`, the shape the
 * verticals assert on; a Run whose records change between pages is read again.
 */
async function readRunTools(invoke, generation, rejectCredential, taskId, run) {
  if (run.toolLog.count === "0") return [];
  for (let attempt = 0; attempt < 3; attempt++) {
    const tools = [];
    let revision = null;
    let total = null;
    let cursor = "0";
    do {
      const requestId = String(++nextToolsRequest);
      const result = await invoke("metawork.tasks.tools", {
        generation,
        requestId,
        taskId,
        runId: run.id,
        afterOrder: cursor,
      });
      if (result === null)
        throw retryable("Probe Tool page response was unavailable");
      rejectCredential(result);
      const page = decodeRunToolsPage(result, cursor);
      if (page.generation !== generation || page.requestId !== requestId)
        throw new Error("Probe Tool page answered another request");
      if (page.state === "missing")
        throw retryable("Probe Run left history during Tool collection");
      if (revision !== null && page.revision !== revision) {
        revision = null;
        break;
      }
      revision = page.revision;
      total = page.total;
      tools.push(...page.tools);
      cursor = page.nextAfterOrder;
    } while (cursor !== null);
    if (revision === null) continue;
    if (String(tools.length) !== total)
      throw new Error("Probe Tool pages disagree with their total");
    return tools;
  }
  throw retryable("Probe Tool records changed during paged collection");
}

export async function readProbeProductState(
  invoke,
  {
    forbidden = [],
    observeTaskView,
    taskId,
    mcpOnly = false,
    includeManagement = true,
    generation = "1",
  } = {},
) {
  function rejectCredential(value) {
    const encoded = JSON.stringify(value);
    if (forbidden.some((entry) => entry && encoded.includes(entry)))
      throw new Error("Host credential reached a projection probe");
  }
  async function read(scope) {
    const next = await fetchWorkbenchSnapshot(async (command, payload) => {
      const result = await invoke(command, payload);
      if (result === null)
        throw retryable("Probe snapshot response was unavailable");
      return result;
    }, scope);
    rejectCredential(next);
    return next;
  }
  async function withRunTools(task) {
    const runs = [];
    for (const run of task.runs)
      runs.push({
        ...run,
        tools: await readRunTools(
          invoke,
          generation,
          rejectCredential,
          task.id,
          run,
        ),
      });
    return { ...task, runs };
  }
  if (mcpOnly) return read({ ...initialViewScope, management: "mcp" });
  const index = await read(initialViewScope);
  const tasks = [];
  for (const summary of index.taskIndex) {
    if (taskId !== undefined && summary.id !== taskId) continue;
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
        if (view.taskPage && observeTaskView)
          observeTaskView({
            revision: view.revision,
            task: await withRunTools(state.snapshot.tasks[0]),
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
    if (retained) tasks.push(await withRunTools(retained));
  }
  // Live Run observations do not need unrelated management collections.
  const skills = includeManagement
    ? await read({ ...initialViewScope, management: "skills" })
    : null;
  const mcp = includeManagement
    ? await read({ ...initialViewScope, management: "mcp" })
    : null;
  const schedules = includeManagement
    ? await read({ ...initialViewScope, management: "schedules" })
    : null;
  const latest = await read(initialViewScope);
  const ids = new Set(latest.taskIndex.map((task) => task.id));
  return {
    ...latest,
    tasks: tasks.filter((task) => ids.has(task.id)),
    ...(includeManagement
      ? {
          skillManagement: skills.skillManagement,
          mcp: mcp.mcp,
          scheduledTasks: schedules.scheduledTasks,
        }
      : {}),
  };
}
