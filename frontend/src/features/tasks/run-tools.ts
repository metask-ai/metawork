import { useCallback, useEffect, useState, useSyncExternalStore } from "react";
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
  /** The task page's `toolLog.revision` these pages answer. */
  revision: string | null;
  tools: ToolView[];
  nextAfterOrder: string | null;
  status: "idle" | "loading" | "ready" | "error";
  /** Read while the Run was active; its end may still settle records. */
  readWhileActive: boolean;
};

export const idleRunTools: RunToolsState = {
  revision: null,
  tools: [],
  nextAfterOrder: null,
  status: "idle",
  readWhileActive: false,
};

/** Run ids restart in every Task, and pages belong to one security epoch. */
export function runToolsKey(
  taskId: string,
  runId: string,
  securityEpoch: string | undefined,
): string {
  return `${securityEpoch ?? ""}:${taskId}:${runId}`;
}

type RunToolsRead = {
  loader: RunToolsLoader;
  taskId: string;
  runId: string;
  securityEpoch: string | undefined;
  /** Records up to this order are kept; the read starts after it. */
  cursor: string;
  /** Pages continue until they pass this order; null reads one page. */
  through: string | null;
  revision: string | null;
  active: boolean;
};

/**
 * Pages read per Run, owned by the Task view. A Run's details render from
 * one place while it is active and another once it ends, so the cache, not a
 * component, owns each read: a response always lands here, and the details
 * that mount next find it. One read per Run is in flight at a time.
 */
export class RunToolsCache {
  readonly #states = new Map<string, RunToolsState>();
  readonly #listeners = new Map<string, Set<() => void>>();
  readonly #reads = new Map<string, symbol>();
  readonly #requests = new Map<string, RunToolsRead>();

  get(key: string): RunToolsState {
    return this.#states.get(key) ?? idleRunTools;
  }

  subscribe(key: string, listener: () => void): () => void {
    let listeners = this.#listeners.get(key);
    if (!listeners) this.#listeners.set(key, (listeners = new Set()));
    const own = listeners;
    own.add(listener);
    return () => {
      own.delete(listener);
      if (own.size === 0 && this.#listeners.get(key) === own)
        this.#listeners.delete(key);
    };
  }

  /** Pages a view already holds, as when it restores them. */
  set(key: string, state: RunToolsState) {
    this.#write(key, state);
  }

  /** Forgets one Run's pages; a read still in flight is dropped. */
  reset(key: string) {
    this.#reads.delete(key);
    this.#requests.delete(key);
    this.#write(key, idleRunTools);
  }

  /** Forgets every Run outside this Task and security epoch. */
  retain(taskId: string | undefined, securityEpoch: string | undefined) {
    const prefix =
      taskId === undefined ? null : runToolsKey(taskId, "", securityEpoch);
    for (const key of new Set([...this.#states.keys(), ...this.#reads.keys()]))
      if (prefix === null || !key.startsWith(prefix)) this.reset(key);
  }

  /** Nothing read can have changed; only the answered revision moves. */
  acknowledge(key: string, revision: string) {
    const state = this.get(key);
    if (state.status === "ready" && state.revision !== revision)
      this.#write(key, { ...state, revision });
  }

  read(key: string, request: RunToolsRead) {
    if (this.#reads.has(key)) return;
    const token = Symbol(key);
    this.#reads.set(key, token);
    this.#requests.set(key, request);
    this.#write(key, { ...this.get(key), status: "loading" });
    void this.#run(key, token, request);
  }

  /** Repeats the last read of a Run after it failed. */
  retry(key: string) {
    const request = this.#requests.get(key);
    if (request && this.get(key).status === "error") this.read(key, request);
  }

  async #run(key: string, token: symbol, request: RunToolsRead) {
    const pages: ToolView[] = [];
    let cursor = request.cursor;
    let next: string | null = null;
    let missing = false;
    try {
      for (;;) {
        const page = await request.loader(
          request.taskId,
          request.runId,
          cursor,
        );
        if (this.#reads.get(key) !== token) return;
        if (
          request.securityEpoch !== undefined &&
          page.securityEpoch !== request.securityEpoch
        )
          throw new Error("Tool page from another security epoch");
        if (page.state === "missing") {
          missing = true;
          break;
        }
        pages.push(...page.tools);
        next = page.nextAfterOrder;
        if (
          next === null ||
          request.through === null ||
          BigInt(next) >= BigInt(request.through)
        )
          break;
        cursor = next;
      }
    } catch {
      if (this.#reads.get(key) !== token) return;
      this.#reads.delete(key);
      this.#write(key, { ...this.get(key), status: "error" });
      return;
    }
    this.#reads.delete(key);
    const current = this.get(key);
    const bound = BigInt(request.cursor);
    this.#write(key, {
      revision: request.revision,
      tools: missing
        ? []
        : [
            ...current.tools.filter((tool) => BigInt(tool.order) <= bound),
            ...pages,
          ],
      nextAfterOrder: missing ? null : next,
      status: "ready",
      readWhileActive:
        request.active || (bound !== 0n && current.readWhileActive),
    });
  }

  #write(key: string, state: RunToolsState) {
    if (state === idleRunTools) this.#states.delete(key);
    else this.#states.set(key, state);
    for (const listener of [...(this.#listeners.get(key) ?? [])]) listener();
  }
}

/**
 * Within one security epoch, records change only while they run and, once,
 * when the Run ends and trusted receipts settle. A newer revision therefore
 * only has to be read from the first record still running, or after the last
 * record when the read had reached the end. Null: nothing read can have
 * changed; later records arrive through "show more".
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
 * A read answers the task page revision it was asked for, so a page newer
 * than the snapshot asks nothing more until the snapshot moves. After the Run
 * ends, what was read while it ran is read once more.
 */
export function useRunTools(
  loader: RunToolsLoader | undefined,
  taskId: string,
  runId: string,
  securityEpoch: string | undefined,
  toolLog: RunToolLog,
  expanded: boolean,
  active: boolean,
  cache?: RunToolsCache,
): RunToolsView {
  const [own] = useState(() => new RunToolsCache());
  const store = cache ?? own;
  const key = runToolsKey(taskId, runId, securityEpoch);
  const subscribe = useCallback(
    (listener: () => void) => store.subscribe(key, listener),
    [store, key],
  );
  const snapshot = useCallback(() => store.get(key), [store, key]);
  const state = useSyncExternalStore(subscribe, snapshot, snapshot);
  const request = useCallback(
    (cursor: string, through: string | null, revision: string | null) => {
      if (loader)
        store.read(key, {
          loader,
          taskId,
          runId,
          securityEpoch,
          cursor,
          through,
          revision,
          active,
        });
    },
    [store, key, loader, taskId, runId, securityEpoch, active],
  );
  useEffect(() => {
    // Closed details keep the pages read so reopening shows them at once;
    // the Task view drops them when it moves to another Task. A failed read
    // starts over the next time the details open.
    if (!expanded) {
      if (state.status === "error") store.reset(key);
      return;
    }
    if (!loader || state.status === "loading" || state.status === "error")
      return;
    if (state.status === "idle") {
      if (toolLog.count !== "0") request("0", null, toolLog.revision);
      return;
    }
    const last = state.tools.at(-1)?.order ?? null;
    if (!active && state.readWhileActive) {
      request("0", last, toolLog.revision);
      return;
    }
    if (state.revision === toolLog.revision) return;
    const cursor = runToolsRefreshCursor(state);
    if (cursor === null) store.acknowledge(key, toolLog.revision);
    else request(cursor, last, toolLog.revision);
  }, [
    expanded,
    loader,
    state,
    store,
    key,
    active,
    toolLog.count,
    toolLog.revision,
    request,
  ]);
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
      if (state.nextAfterOrder !== null && state.status === "ready")
        request(state.nextAfterOrder, null, state.revision);
    },
    retry: () => store.retry(key),
  };
}
