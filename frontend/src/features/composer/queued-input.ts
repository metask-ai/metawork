import type {
  QueuedInputResult,
  QueuedInputView,
  SkillCatalogView,
} from "../../bridge/contracts.ts";
import { composerSessionStorage, decodeTaggedDraft } from "./drafts.ts";
import {
  composerDraftHasContent,
  maxSkillArguments,
  type ComposerDraft,
} from "./slash.ts";

const prefix = "metawork.queued-input-operation.v1.";
export type QueuedOperation = {
  operationId: string;
  kind: "queue" | "withdraw";
  intent: "queue" | "edit" | "discard";
  draftVersion: string;
  draft: Exclude<ComposerDraft, { kind: "multimodal" }> | null;
  phase: "unconfirmed" | "draft_conflict";
};
export function readQueuedOperation(taskId: string): QueuedOperation | null {
  try {
    const raw = composerSessionStorage()?.getItem(`${prefix}${taskId}`);
    if (!raw || new TextEncoder().encode(raw).length > 2 * 1024 * 1024)
      return null;
    const value = JSON.parse(raw);
    const keys = Object.keys(value).sort().join(",");
    if (
      keys !== "draft,draftVersion,intent,kind,operationId,phase" ||
      typeof value.operationId !== "string" ||
      !/^[!-~]{1,64}$/.test(value.operationId) ||
      typeof value.draftVersion !== "string" ||
      !/^[a-zA-Z0-9-]{1,64}$/.test(value.draftVersion) ||
      !["unconfirmed", "draft_conflict"].includes(value.phase) ||
      !(
        (value.kind === "queue" && value.intent === "queue") ||
        (value.kind === "withdraw" &&
          ["edit", "discard"].includes(value.intent))
      ) ||
      (value.phase === "draft_conflict" && value.intent !== "edit")
    )
      return null;
    const draft =
      value.draft === null
        ? null
        : decodeTaggedDraft(JSON.stringify(value.draft));
    if (
      draft?.kind === "multimodal" ||
      (value.intent === "discard" && draft !== null) ||
      (value.intent !== "discard" &&
        (!draft || !composerDraftHasContent(draft)))
    )
      return null;
    return { ...value, draft };
  } catch {
    return null;
  }
}
export function writeQueuedOperation(
  taskId: string,
  operation: QueuedOperation,
): boolean {
  try {
    const target = composerSessionStorage();
    if (!target) return false;
    const encoded = JSON.stringify(operation);
    if (new TextEncoder().encode(encoded).length > 2 * 1024 * 1024)
      return false;
    target.setItem(`${prefix}${taskId}`, encoded);
    return target.getItem(`${prefix}${taskId}`) === encoded;
  } catch {
    return false;
  }
}
export function clearQueuedOperation(taskId: string): void {
  try {
    composerSessionStorage()?.removeItem(`${prefix}${taskId}`);
  } catch {
    /* No request is ever replayed from this journal. */
  }
}
export function queuedInputDraft(
  input: QueuedInputView,
  catalog: SkillCatalogView,
): Exclude<ComposerDraft, { kind: "multimodal" }> {
  if (input.kind === "text") return { kind: "text", text: input.text };
  const descriptor =
    catalog.revision === input.catalogRevision &&
    catalog.selectionRevision === input.selectionRevision
      ? catalog.skills.find((skill) => skill.skillId === input.skillId)
      : null;
  return {
    kind: "skill",
    skillId: input.skillId,
    invocationName: input.invocationName,
    displayName: input.displayName,
    catalogRevision: input.catalogRevision,
    selectionRevision: input.selectionRevision,
    argumentNames: descriptor?.argumentNames ?? [],
    argumentValues: [...input.argumentValues],
    maxValues: Math.min(
      maxSkillArguments,
      Math.max(
        input.argumentValues.length,
        descriptor?.maxValues ?? maxSkillArguments,
      ),
    ),
  };
}
export function queuedOperationDecision(
  operation: QueuedOperation,
  receipt: QueuedInputResult | null,
  currentVersion: string,
  draftEmpty: boolean,
) {
  if (operation.phase === "draft_conflict") return "conflict" as const;
  if (
    !receipt ||
    receipt.operationId !== operation.operationId ||
    receipt.kind !== operation.kind
  )
    return "unconfirmed" as const;
  if (receipt.outcome === "rejected") return "rejected" as const;
  if (operation.kind === "queue")
    return currentVersion === operation.draftVersion
      ? ("clear" as const)
      : ("keep" as const);
  if (operation.intent === "discard") return "keep" as const;
  return currentVersion === operation.draftVersion && draftEmpty
    ? ("restore" as const)
    : ("conflict" as const);
}
