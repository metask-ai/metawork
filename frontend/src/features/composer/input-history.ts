import type {
  RunView,
  ViewScope,
  WorkbenchSnapshot,
} from "../../bridge/contracts.ts";
import { transferredRunIds } from "../../workbench/run-input.ts";

type HistoryRun = Pick<
  RunView,
  "id" | "input" | "submission" | "additionalInputs"
>;

function historyRun(run: RunView): HistoryRun {
  return {
    id: run.id,
    input: run.input,
    submission: run.submission,
    additionalInputs: run.additionalInputs,
  };
}

type Entry = {
  operationId: string | null;
  text: string | null;
  order: bigint | null;
};

function text(input: RunView["input"]): string | null {
  return input.kind === "text" && !input.redacted && input.text.trim()
    ? input.text
    : null;
}

function runEntries(run: HistoryRun, showRoot: boolean): Entry[] {
  return [
    ...(showRoot
      ? [
          {
            operationId: run.submission?.operationId ?? null,
            text: text(run.input),
            order: run.submission?.presentationOrder
              ? BigInt(run.submission.presentationOrder)
              : null,
          },
        ]
      : []),
    ...run.additionalInputs.map((input) => ({
      operationId: input.operationId,
      text: !input.redacted && input.text.trim() ? input.text : null,
      order: input.submission?.presentationOrder
        ? BigInt(input.submission.presentationOrder)
        : null,
    })),
  ];
}

function orderedTexts(entries: Entry[]): string[] {
  // A transferred message is still one submission. A withheld copy must never
  // be recovered from another representation of the same operation.
  const withheld = new Set(
    entries
      .filter((entry) => entry.text === null)
      .map((entry) => entry.operationId)
      .filter((id) => id !== null),
  );
  const seen = new Set<string>();
  const result: string[] = [];
  entries.sort((a, b) =>
    a.order === b.order
      ? 0
      : a.order === null
        ? -1
        : b.order === null
          ? 1
          : a.order < b.order
            ? -1
            : 1,
  );
  for (const entry of entries) {
    if (entry.operationId) {
      if (withheld.has(entry.operationId) || seen.has(entry.operationId))
        continue;
      seen.add(entry.operationId);
    }
    if (entry.text !== null && result.at(-1) !== entry.text)
      result.push(entry.text);
  }
  return result;
}

/** Capture current submissions first, then hydrate only the missing older Runs.
 * Reads never publish a Workbench view or advance the conversation reader. */
export async function loadTaskInputHistory(
  initial: WorkbenchSnapshot,
  taskId: string,
  fetchSnapshot: (scope: ViewScope) => Promise<WorkbenchSnapshot>,
  isCurrent: () => boolean,
): Promise<readonly string[]> {
  const task = initial.tasks.find((task) => task.id === taskId);
  const page = initial.taskPage;
  if (
    !task ||
    page?.task.id !== taskId ||
    initial.scope.taskId !== taskId ||
    !isCurrent()
  )
    throw new Error("Input history scope unavailable");
  const manifest = [...page.runManifest];
  // Retain just input records while paging, not every Run's tool/output bodies.
  const runs = new Map<string, HistoryRun>();
  const known = new Set(manifest.map((run) => run.id));
  for (const run of [...task.runs, ...(initial.historyPage?.runs ?? [])])
    if (known.has(run.id)) runs.set(run.id, historyRun(run));
  const waiting: Entry[] = task.inputSubmissions.map((input) => ({
    operationId: input.submission.operationId,
    text: text(input.input),
    order: input.submission.presentationOrder
      ? BigInt(input.submission.presentationOrder)
      : null,
  }));
  while (runs.size < manifest.length) {
    if (!isCurrent()) throw new Error("Input history scope changed");
    let index = manifest.length - 1;
    while (index >= 0 && runs.has(manifest[index]!.id)) index--;
    const beforeRunId = manifest[index + 1]?.id;
    if (!beforeRunId) throw new Error("Input history latest page missing");
    const next = await fetchSnapshot({
      taskId,
      beforeRunId,
      runLimit: initial.scope.runLimit,
      management: "none",
      search: false,
      searchQuery: "",
      searchCursor: null,
      receipts: [],
    });
    if (
      !isCurrent() ||
      next.securityEpoch !== initial.securityEpoch ||
      next.historyEpoch !== initial.historyEpoch
    )
      throw new Error("Input history authority changed");
    if (
      next.scope.taskId !== taskId ||
      next.historyPage?.beforeRunId !== beforeRunId ||
      next.taskPage?.task.id !== taskId
    )
      throw new Error("Input history page unavailable");
    const previousSize = runs.size;
    for (const run of next.historyPage.runs) {
      if (!known.has(run.id) || runs.has(run.id)) continue;
      const expected = manifest.find((item) => item.id === run.id)!;
      const observed = next.taskPage.runManifest.find(
        (item) => item.id === run.id,
      );
      if (observed?.contentVersion !== expected.contentVersion)
        throw new Error("Input history changed during read");
      runs.set(run.id, historyRun(run));
    }
    if (runs.size === previousSize)
      throw new Error("Input history page made no progress");
  }
  if (!isCurrent()) throw new Error("Input history scope changed");
  const transferred = transferredRunIds([...runs.values()]);
  return orderedTexts([
    ...manifest.flatMap((run) =>
      runEntries(runs.get(run.id)!, !transferred.has(run.id)),
    ),
    ...waiting,
  ]);
}
