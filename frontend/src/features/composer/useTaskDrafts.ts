import { useCallback, useState } from "react";

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
import { emptyComposerDraft, type ComposerDraft } from "./slash.ts";

function useDrafts(
  activeId: string | null,
  readDraft: (id: string) => ComposerDraft,
  writeDraft: (id: string, value: ComposerDraft) => void,
  clearStoredDraft: (id: string) => void,
) {
  const [drafts, setDrafts] = useState<Record<string, ComposerDraft>>({});
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
      const source = readDraft(from);
      const target = readDraft(to);
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
    [clearStoredDraft, readDraft, writeDraft],
  );

  const pruneDraftCache = useCallback((validIds: ReadonlySet<string>) => {
    setDrafts((current) =>
      Object.fromEntries(
        Object.entries(current).filter(([id]) => validIds.has(id)),
      ),
    );
  }, []);

  return {
    draft,
    updateDraft,
    setDraft,
    clearDraft,
    moveDraft,
    pruneDraftCache,
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
      drafts.pruneDraftCache(valid);
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
