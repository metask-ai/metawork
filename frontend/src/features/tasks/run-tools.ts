import { useCallback, useEffect, useRef, useState } from "react";
import type {
  RunToolLog,
  RunToolsPage,
  ToolView,
} from "../../bridge/contracts.ts";

/** Reads one page of a Run's Tool records after an activity order. */
export type RunToolsLoader = (
  taskId: string,
  runId: string,
  afterOrder: string,
) => Promise<RunToolsPage>;

/**
 * The pages of one Run read so far, in activity order. `nextAfterOrder` is
 * the cursor of the next unread page; null means the read reached the end.
 */
export type RunToolsState = {
  revision: string | null;
  tools: ToolView[];
  nextAfterOrder: string | null;
  status: "idle" | "loading" | "ready" | "error";
};

/**
 * Pages read per Run, owned by the Task view. A Run's details render from
 * one place while it is active and another once it ends; the cache keeps the
 * pages across that remount instead of reading them again.
 */
export type RunToolsCache = Map<string, RunToolsState>;

export const idleRunTools: RunToolsState = {
  revision: null,
  tools: [],
  nextAfterOrder: null,
  status: "idle",
};

/** Keeps the records up to `cursor` and puts the page after them. */
export function mergeRunToolsPage(
  state: RunToolsState,
  cursor: string,
  page: RunToolsPage,
): RunToolsState {
  const bound = BigInt(cursor);
  const kept = state.tools.filter((tool) => BigInt(tool.order) <= bound);
  return {
    revision: page.revision,
    tools: page.state === "ready" ? [...kept, ...page.tools] : [],
    nextAfterOrder: page.state === "ready" ? page.nextAfterOrder : null,
    status: "ready",
  };
}

/**
 * Within one security epoch a finished record never changes, so a newer
 * revision only has to be read from the first record still running, or after
 * the last record when the read had reached the end. Null: nothing loaded can
 * have changed; later records arrive through "show more".
 */
export function runToolsRefreshCursor(state: RunToolsState): string | null {
  const running = state.tools.findIndex((tool) => tool.state === "running");
  if (running >= 0)
    return running === 0 ? "0" : state.tools[running - 1]!.order;
  if (state.nextAfterOrder === null) return state.tools.at(-1)?.order ?? "0";
  return null;
}

export type RunToolsView = {
  tools: ToolView[];
  status: RunToolsState["status"];
  /** Records not yet read when more pages remain, else zero. */
  remaining: bigint;
  hasMore: boolean;
  loadMore: () => void;
  retry: () => void;
};

/**
 * Reads the Tool records of one Run while its execution details are open.
 * One request is in flight at a time; a response from another security epoch
 * is dropped.
 */
export function useRunTools(
  loader: RunToolsLoader | undefined,
  taskId: string,
  runId: string,
  securityEpoch: string | undefined,
  toolLog: RunToolLog,
  expanded: boolean,
  cache?: RunToolsCache,
): RunToolsView {
  const [state, setState] = useState<RunToolsState>(
    () => cache?.get(runId) ?? idleRunTools,
  );
  useEffect(() => {
    if (!cache) return;
    if (state.status === "idle") cache.delete(runId);
    else cache.set(runId, state);
  }, [cache, runId, state]);
  const inFlight = useRef(false);
  const lastCursor = useRef("0");
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const load = useCallback(
    (cursor: string) => {
      if (!loader || inFlight.current) return;
      inFlight.current = true;
      lastCursor.current = cursor;
      setState((current) => ({ ...current, status: "loading" }));
      loader(taskId, runId, cursor).then(
        (page) => {
          inFlight.current = false;
          if (!alive.current) return;
          if (
            securityEpoch !== undefined &&
            page.securityEpoch !== securityEpoch
          ) {
            setState((current) => ({ ...current, status: "error" }));
            return;
          }
          setState((current) => mergeRunToolsPage(current, cursor, page));
        },
        () => {
          inFlight.current = false;
          if (alive.current)
            setState((current) => ({ ...current, status: "error" }));
        },
      );
    },
    [loader, taskId, runId, securityEpoch],
  );
  useEffect(() => {
    // Closed details keep the pages read so reopening shows them at once;
    // the Task view drops them all when it goes away. A failed read starts
    // over the next time the details open.
    if (!expanded) {
      if (state.status === "error") setState(idleRunTools);
      return;
    }
    if (
      toolLog.count === "0" ||
      state.status === "loading" ||
      state.status === "error"
    )
      return;
    if (state.status === "idle") {
      load("0");
      return;
    }
    if (state.revision === toolLog.revision) return;
    const cursor = runToolsRefreshCursor(state);
    if (cursor === null)
      setState((current) => ({ ...current, revision: toolLog.revision }));
    else load(cursor);
  }, [expanded, toolLog.count, toolLog.revision, state, load]);
  const hasMore = state.nextAfterOrder !== null;
  const remaining = hasMore
    ? BigInt(toolLog.count) - BigInt(state.tools.length)
    : 0n;
  return {
    tools: expanded ? state.tools : [],
    status: state.status,
    remaining: remaining > 0n ? remaining : 0n,
    hasMore,
    loadMore: () => {
      if (state.nextAfterOrder !== null) load(state.nextAfterOrder);
    },
    retry: () => load(lastCursor.current),
  };
}
