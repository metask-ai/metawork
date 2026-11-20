import type { RunManifest, RunView } from "../../bridge/contracts.ts";

/** One row of the conversation rail: a projected Run in manifest order. */
export type RailEntry = {
  runId: string;
  /** 1-based turn number in the Task, counted over projected Runs only. */
  turn: number;
  excerpt: string | null;
  submittedAtUnixMs: string | null;
};

export function railEntries(manifest: readonly RunManifest[]): RailEntry[] {
  return manifest.map((run, index) => ({
    runId: run.id,
    turn: index + 1,
    excerpt: run.excerpt,
    submittedAtUnixMs: run.submittedAtUnixMs,
  }));
}

/** Entries are display facts only; equal facts never need a new rail. */
export function sameRailEntries(
  a: readonly RailEntry[],
  b: readonly RailEntry[],
): boolean {
  return (
    a.length === b.length &&
    a.every(
      (entry, index) =>
        entry.runId === b[index]!.runId &&
        entry.excerpt === b[index]!.excerpt &&
        entry.submittedAtUnixMs === b[index]!.submittedAtUnixMs,
    )
  );
}

/**
 * The rail is worth showing once there is more than one turn and the
 * conversation does not already fit: some turn is still unloaded, or the
 * loaded ones overflow the viewport.
 */
export function railVisible(state: {
  runCount: number;
  olderHistory: boolean;
  scrollable: boolean;
}): boolean {
  return state.runCount >= 2 && (state.olderHistory || state.scrollable);
}

/** Rail row the reading position belongs to: the latest while following. */
export function railCurrentRun(
  entries: readonly RailEntry[],
  anchorRunId: string | null,
  followingLatest: boolean,
): string | null {
  if (followingLatest || anchorRunId === null)
    return entries.at(-1)?.runId ?? null;
  return entries.some((entry) => entry.runId === anchorRunId)
    ? anchorRunId
    : (entries.at(-1)?.runId ?? null);
}

const pageStep = 10;

/** Next active row for a rail key, or null when the key is not the rail's. */
export function railKeyTarget(
  key: string,
  active: number,
  count: number,
): number | null {
  if (count === 0) return null;
  const clamp = (value: number) => Math.min(count - 1, Math.max(0, value));
  switch (key) {
    case "ArrowUp":
      return clamp(active - 1);
    case "ArrowDown":
      return clamp(active + 1);
    case "PageUp":
      return clamp(active - pageStep);
    case "PageDown":
      return clamp(active + pageStep);
    case "Home":
      return 0;
    case "End":
      return count - 1;
    default:
      return null;
  }
}

/**
 * Rail scroll offset that brings a row fully into view, or null when it
 * already is. Rows sit at fixed `rowHeight` steps after `inset` of padding.
 */
export function railScrollForRow(
  index: number,
  geometry: {
    rowHeight: number;
    inset: number;
    viewHeight: number;
    scrollTop: number;
  },
): number | null {
  const top = geometry.inset + index * geometry.rowHeight;
  const bottom = top + geometry.rowHeight;
  if (top - geometry.inset < geometry.scrollTop)
    return Math.max(0, top - geometry.inset);
  if (bottom + geometry.inset > geometry.scrollTop + geometry.viewHeight)
    return bottom + geometry.inset - geometry.viewHeight;
  return null;
}

/**
 * The reading anchor that shows a Run's own message. The reading plan may
 * place that message inside an earlier Run (a transferred or anchored
 * submission), but it always keeps this identity.
 */
export function runMessageReadingId(
  run: Pick<RunView, "id" | "submission">,
): string {
  return run.submission
    ? `submission:${run.submission.operationId}`
    : `${run.id}:root`;
}

/** A jump waiting for its Run to join the loaded interval. */
export type PendingRailJump = { taskId: string; runId: string };

/** Whether a waiting jump still has a target in this Task's projection. */
export function pendingRailJumpValid(
  jump: PendingRailJump,
  taskId: string | null,
  manifest: readonly Pick<RunManifest, "id">[],
): boolean {
  return (
    jump.taskId === taskId && manifest.some((run) => run.id === jump.runId)
  );
}

/** Near jumps glide; far ones land at once, and reduced motion never glides. */
export function railScrollBehavior(
  distance: number,
  viewportHeight: number,
  reducedMotion: boolean,
): ScrollBehavior {
  return !reducedMotion && Math.abs(distance) <= 2 * viewportHeight
    ? "smooth"
    : "auto";
}

/** Reading position shared with the rail without re-rendering the conversation. */
export function createRailPosition() {
  let current: string | null = null;
  const listeners = new Set<() => void>();
  return {
    get: () => current,
    set(runId: string | null) {
      if (runId === current) return;
      current = runId;
      for (const listener of listeners) listener();
    },
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
}
export type RailPosition = ReturnType<typeof createRailPosition>;
