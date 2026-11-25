import type {
  HandoffCreate,
  InboxMessage,
  ModelRef,
} from "../../bridge/contracts.ts";
import { newComposerOperationId } from "../composer/drafts.ts";

export type MessageReference = {
  taskId: string;
  title?: string;
  message: InboxMessage;
};

const prefix = "metawork.handoff.v1.";
export type HandoffDraft = HandoffCreate & {
  title?: string;
  aliases: string[];
  model: ModelRef | null;
  pendingWorkspace: string | null;
};
export function handoffDraftKey(id: string) {
  return "handoff." + id;
}

export function newHandoffDraft(
  source: HandoffCreate["source"],
  storeId: string,
  title: string,
): HandoffDraft {
  return {
    source,
    storeId,
    title,
    operationId: newComposerOperationId(),
    aliases: [...new Set([source.referenced, source.canonical])],
    model: null,
    pendingWorkspace: null,
  };
}

export function saveHandoffDraft(draft: HandoffDraft) {
  window.localStorage.setItem(
    prefix + draft.operationId,
    JSON.stringify(draft),
  );
}
export function removeHandoffDraft(id: string) {
  window.localStorage.removeItem(prefix + id);
}

export function readHandoffDrafts(): HandoffDraft[] {
  const drafts: HandoffDraft[] = [];
  try {
    const storage = window.localStorage;
    for (let i = 0; i < storage.length; ++i) {
      const key = storage.key(i);
      if (!key?.startsWith(prefix)) continue;
      try {
        const v = JSON.parse(storage.getItem(key) ?? "null");
        if (
          v &&
          key === prefix + v.operationId &&
          /^[0-9a-f]{32}$/.test(v.operationId) &&
          /^[0-9a-f]{32}$/.test(v.storeId) &&
          /^[0-9a-f]{64}$/.test(v.source?.account) &&
          typeof v.source.referenced === "string" &&
          typeof v.source.canonical === "string" &&
          (v.title === undefined || typeof v.title === "string") &&
          Array.isArray(v.aliases) &&
          v.aliases.every((item: unknown) => typeof item === "string") &&
          (v.model === null ||
            (typeof v.model?.sourceId === "string" &&
              typeof v.model.modelId === "string")) &&
          (v.pendingWorkspace === null ||
            typeof v.pendingWorkspace === "string")
        )
          drafts.push(v);
      } catch {
        /* Another entry can still be resumed. */
      }
    }
  } catch {
    /* A new operation must persist successfully before it can start. */
  }
  return drafts;
}

export function matchingDrafts(
  drafts: HandoffDraft[],
  account: string,
  store: string,
  ...ids: string[]
) {
  return drafts.filter(
    (d) =>
      d.source.account === account &&
      d.storeId === store &&
      ids.some((id) => d.aliases.includes(id)),
  );
}

export function quoteMessage(message: InboxMessage, taskId: string) {
  const clean = (s: string) =>
    s.replace(/[\r\n\v\f\u001c-\u001e\u0085\u2028\u2029]+/g, " ");
  const sender = clean(message.fromName || message.fromPeerId);
  const date = new Date(Number(message.sentAtMs));
  const header = [
    sender,
    message.fromAgent && "Agent " + clean(message.fromAgent),
    Number.isFinite(date.getTime()) && date.toISOString(),
    "#" + clean(taskId),
  ]
    .filter(Boolean)
    .join(" · ");
  return [
    header,
    ...message.text.split(/\r\n|[\r\n\v\f\u001c-\u001e\u0085\u2028\u2029]/),
  ]
    .map((line) => "> " + line)
    .join("\n");
}
