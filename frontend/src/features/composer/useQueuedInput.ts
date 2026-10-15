import { useEffect, useRef, useState, type RefObject } from "react";
import type { BridgeClient } from "../../bridge/client.ts";
import type {
  QueuedInputReason,
  QueuedInputResult,
  TaskView,
  WorkbenchSnapshot,
} from "../../bridge/contracts.ts";
import { newComposerOperationId, taskDraftVersion } from "./drafts.ts";
import {
  clearQueuedOperation,
  queuedInputDraft,
  queuedOperationDecision,
  readQueuedOperation,
  writeQueuedOperation,
  type QueuedOperation,
} from "./queued-input.ts";
import {
  composerDraftHasContent,
  composerDraftToRunInput,
  type ComposerDraft,
} from "./slash.ts";

type Drafts = {
  getDraft: (id: string) => ComposerDraft;
  setDraft: (id: string, value: ComposerDraft) => void;
  clearDraft: (id: string) => void;
};
export function useQueuedInput({
  client,
  snapshot,
  ready,
  generation,
  generationRef,
  drafts,
  refresh,
}: {
  client: BridgeClient;
  snapshot: WorkbenchSnapshot;
  ready: boolean;
  generation: string;
  generationRef: RefObject<string>;
  drafts: Drafts;
  refresh: () => Promise<void>;
}) {
  const records = useRef<Record<string, QueuedOperation | null>>({});
  const busy = useRef(new Map<string, { id: string; generation: string }>());
  const errors = useRef<
    Record<string, QueuedInputReason | "storage_unavailable">
  >({});
  const quietVersions = useRef<Record<string, string>>({});
  const [, render] = useState(0);
  const current = useRef({ snapshot, drafts, ready, refresh });
  current.current = { snapshot, drafts, ready, refresh };
  const previousGeneration = useRef(generation);
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const publish = () => {
    if (alive.current) render((value) => value + 1);
  };

  function operation(taskId: string): QueuedOperation | null {
    return Object.hasOwn(records.current, taskId)
      ? records.current[taskId]!
      : readQueuedOperation(taskId);
  }
  function forget(taskId: string) {
    records.current[taskId] = null;
    clearQueuedOperation(taskId);
  }
  function settle(task: TaskView, receipt: QueuedInputResult | null): boolean {
    const pending = operation(task.id);
    if (!pending) return false;
    const loaded = records.current[task.id] === undefined;
    records.current[task.id] = pending;
    const draft = current.current.drafts.getDraft(task.id);
    const decision = queuedOperationDecision(
      pending,
      receipt,
      taskDraftVersion(task.id),
      !composerDraftHasContent(draft),
    );
    if (decision === "unconfirmed" || pending.phase === "draft_conflict")
      return loaded;
    if (busy.current.get(task.id)?.id === pending.operationId)
      busy.current.delete(task.id);
    if (decision === "rejected") errors.current[task.id] = receipt!.reason!;
    if (decision === "clear") {
      current.current.drafts.clearDraft(task.id);
      quietVersions.current[task.id] = taskDraftVersion(task.id);
    }
    if (decision === "restore")
      current.current.drafts.setDraft(
        task.id,
        queuedInputDraft(receipt!.input!, task.skillCatalog),
      );
    if (decision === "conflict") {
      const retained = {
        ...pending,
        phase: "draft_conflict" as const,
        draft: queuedInputDraft(receipt!.input!, task.skillCatalog),
      };
      records.current[task.id] = retained;
      writeQueuedOperation(task.id, retained);
    } else forget(task.id);
    return true;
  }

  useEffect(() => {
    if (previousGeneration.current !== generation) {
      const hadBusy = busy.current.size > 0;
      busy.current.clear();
      if (hadBusy) publish();
      previousGeneration.current = generation;
    }
    if (!ready || generation === "0") return;
    let changed = false;
    for (const task of snapshot.tasks)
      changed = settle(task, task.queuedInputResult) || changed;
    const ids = new Set(snapshot.tasks.map((task) => task.id));
    for (const id of Object.keys(records.current))
      if (!ids.has(id)) {
        clearQueuedOperation(id);
        delete records.current[id];
        delete errors.current[id];
        delete quietVersions.current[id];
        changed = true;
      }
    if (changed) publish();
  }, [snapshot, generation, ready]);

  function begin(taskId: string, pending: QueuedOperation): boolean {
    if (
      !current.current.ready ||
      generationRef.current === "0" ||
      operation(taskId) ||
      busy.current.has(taskId)
    )
      return false;
    delete errors.current[taskId];
    if (!writeQueuedOperation(taskId, pending)) {
      errors.current[taskId] = "storage_unavailable";
      publish();
      return false;
    }
    records.current[taskId] = pending;
    busy.current.set(taskId, {
      id: pending.operationId,
      generation: generationRef.current,
    });
    publish();
    return true;
  }
  async function submit(task: TaskView): Promise<void> {
    const draft = current.current.drafts.getDraft(task.id);
    const input = composerDraftToRunInput(draft);
    if (
      !input ||
      draft.kind === "multimodal" ||
      task.queuedInput ||
      task.currentRunPhase === "stopping" ||
      task.activeOperation?.kind !== "run"
    )
      return;
    const pending: QueuedOperation = {
      operationId: newComposerOperationId(),
      kind: "queue",
      intent: "queue",
      draftVersion: taskDraftVersion(task.id),
      draft,
      phase: "unconfirmed",
    };
    if (!begin(task.id, pending)) return;
    const sentGeneration = generationRef.current;
    try {
      const result = await client.queueInput(
        pending.operationId,
        task.id,
        task.binding.epoch,
        task.activeOperation.id,
        input,
      );
      if (
        alive.current &&
        generationRef.current === sentGeneration &&
        operation(task.id)?.operationId === pending.operationId
      ) {
        const latestTask = current.current.snapshot.tasks.find(
          (candidate) => candidate.id === task.id,
        );
        if (
          latestTask &&
          settle(latestTask, {
            operationId: pending.operationId,
            kind: "queue",
            outcome: result.accepted ? "queued" : "rejected",
            revision: result.revision,
            reason: result.reason,
            input: null,
          })
        )
          publish();
      }
    } catch {
      /* Ambiguous transport/encoding failures are resolved only by an actual snapshot refresh. */
    } finally {
      if (!alive.current) return;
      if (busy.current.get(task.id)?.id === pending.operationId) {
        busy.current.delete(task.id);
        publish();
      }
      await current.current.refresh().catch(() => undefined);
    }
  }
  async function withdraw(
    task: TaskView,
    intent: "edit" | "discard",
  ): Promise<void> {
    const queued = task.queuedInput;
    if (
      !queued ||
      (intent === "edit" &&
        composerDraftHasContent(current.current.drafts.getDraft(task.id)))
    )
      return;
    const pending: QueuedOperation = {
      operationId: newComposerOperationId(),
      kind: "withdraw",
      intent,
      draftVersion: taskDraftVersion(task.id),
      draft:
        intent === "edit"
          ? queuedInputDraft(queued.input, task.skillCatalog)
          : null,
      phase: "unconfirmed",
    };
    if (!begin(task.id, pending)) return;
    const sentGeneration = generationRef.current;
    try {
      const result = await client.withdrawQueuedInput(
        pending.operationId,
        task.id,
        queued.runId,
        queued.revision,
      );
      if (
        alive.current &&
        generationRef.current === sentGeneration &&
        operation(task.id)?.operationId === pending.operationId
      ) {
        const latestTask = current.current.snapshot.tasks.find(
          (candidate) => candidate.id === task.id,
        );
        if (
          latestTask &&
          settle(latestTask, {
            operationId: pending.operationId,
            kind: "withdraw",
            outcome: result.withdrawn ? "withdrawn" : "rejected",
            revision: result.revision,
            reason: result.reason,
            input: result.input,
          })
        )
          publish();
      }
    } catch {
      /* Keep the operation identity; never restore or resend based on an empty slot. */
    } finally {
      if (!alive.current) return;
      if (busy.current.get(task.id)?.id === pending.operationId) {
        busy.current.delete(task.id);
        publish();
      }
      await current.current.refresh().catch(() => undefined);
    }
  }
  function recover(taskId: string, restore: boolean): void {
    const pending = operation(taskId);
    if (!pending || busy.current.has(taskId)) return;
    const draft = current.current.drafts.getDraft(taskId);
    if (
      restore &&
      pending.draft &&
      (!composerDraftHasContent(draft) ||
        taskDraftVersion(taskId) === pending.draftVersion)
    )
      current.current.drafts.setDraft(taskId, pending.draft);
    forget(taskId);
    publish();
  }
  return {
    submit,
    withdraw,
    recover,
    operation,
    isBusy: (id: string) => busy.current.has(id),
    error: (id: string) => errors.current[id] ?? null,
    blocked: (id: string) => operation(id) !== null || busy.current.has(id),
    quietDraft: (id: string) =>
      quietVersions.current[id] === taskDraftVersion(id),
  };
}
