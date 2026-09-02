import { useCallback, useRef, useState } from "react";

import {
  clearNewTaskDraft,
  clearTaskDraft,
  newTaskDraftMoveDecision,
  pruneTaskDrafts,
  readNewTaskDraft,
  readTaskDraft,
  writeNewTaskDraft,
  writeTaskDraft,
} from "./drafts.ts";
import {
  emptyComposerDraft,
  type ComposerAttachment,
  type ComposerDraft,
} from "./slash.ts";

function useDrafts(
  activeId: string | null,
  readDraft: (id: string) => ComposerDraft,
  writeDraft: (id: string, value: ComposerDraft) => void,
  clearStoredDraft: (id: string) => void,
) {
  const [drafts, setDrafts] = useState<Record<string, ComposerDraft>>({});
  const draftsRef = useRef(drafts);
  draftsRef.current = drafts;
  const draft = activeId
    ? (drafts[activeId] ?? readDraft(activeId))
    : emptyComposerDraft();

  const updateDraft = useCallback(
    (value: ComposerDraft) => {
      if (!activeId) return;
      setDrafts((current) => ({ ...current, [activeId]: value }));
      writeDraft(activeId, value);
    },
    [activeId, writeDraft],
  );

  const setDraft = useCallback(
    (id: string, value: ComposerDraft) => {
      setDrafts((current) => ({ ...current, [id]: value }));
      writeDraft(id, value);
    },
    [writeDraft],
  );

  const clearDraft = useCallback(
    (id: string) => {
      setDrafts((current) => {
        if (!(id in current)) return current;
        const next = { ...current };
        delete next[id];
        return next;
      });
      clearStoredDraft(id);
    },
    [clearStoredDraft],
  );

  const moveDraft = useCallback(
    (from: string, to: string) => {
      if (from === to) return "same" as const;
      const source = drafts[from] ?? readDraft(from);
      const target = drafts[to] ?? readDraft(to);
      const decision = newTaskDraftMoveDecision(source, target);
      if (decision === "preserve_both") return decision;
      setDrafts((current) => {
        const next = { ...current };
        delete next[from];
        if (decision === "move") next[to] = source;
        return next;
      });
      clearStoredDraft(from);
      if (decision === "move") writeDraft(to, source);
      return decision;
    },
    [clearStoredDraft, drafts, readDraft, writeDraft],
  );

  const pruneDraftCache = useCallback((validIds: ReadonlySet<string>) => {
    const discarded: ComposerAttachment[] = [];
    for (const [id, draft] of Object.entries(draftsRef.current)) {
      if (validIds.has(id) || draft.kind !== "multimodal") continue;
      discarded.push(...draft.attachments);
    }
    setDrafts((current) =>
      Object.fromEntries(
        Object.entries(current).filter(([id]) => validIds.has(id)),
      ),
    );
    return discarded;
  }, []);

  const invalidateAttachments = useCallback(() => {
    setDrafts((current) => {
      let changed = false;
      const next = { ...current };
      for (const [id, value] of Object.entries(current)) {
        if (value.kind !== "multimodal") continue;
        const replacement: ComposerDraft = {
          kind: "text",
          text: value.text,
          attachmentsReloadRequired: true,
        };
        next[id] = replacement;
        changed = true;
      }
      return changed ? next : current;
    });
  }, []);

  return {
    draft,
    updateDraft,
    setDraft,
    clearDraft,
    moveDraft,
    pruneDraftCache,
    invalidateAttachments,
  };
}

export function useTaskDrafts(activeTaskId: string | null) {
  const drafts = useDrafts(
    activeTaskId,
    readTaskDraft,
    writeTaskDraft,
    clearTaskDraft,
  );

  const pruneDrafts = useCallback(
    (validTaskIds: readonly string[]) => {
      const valid = new Set(validTaskIds);
      pruneTaskDrafts(valid);
      return drafts.pruneDraftCache(valid);
    },
    [drafts.pruneDraftCache],
  );

  return { ...drafts, pruneDrafts };
}

export function useNewTaskDrafts(activeDraftId: string | null) {
  return useDrafts(
    activeDraftId,
    readNewTaskDraft,
    writeNewTaskDraft,
    clearNewTaskDraft,
  );
}
