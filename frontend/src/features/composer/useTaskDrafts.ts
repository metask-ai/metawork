import { useCallback, useState } from "react";

import {
  clearNewTaskDraft,
  clearTaskDraft,
  pruneTaskDrafts,
  readNewTaskDraft,
  readTaskDraft,
  writeNewTaskDraft,
  writeTaskDraft,
} from "./drafts.ts";

function useDrafts(
  activeId: string | null,
  readDraft: (id: string) => string,
  writeDraft: (id: string, value: string) => void,
  clearStoredDraft: (id: string) => void,
) {
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const draft = activeId ? (drafts[activeId] ?? readDraft(activeId)) : "";

  const updateDraft = useCallback(
    (value: string) => {
      if (!activeId) return;
      setDrafts((current) => ({ ...current, [activeId]: value }));
      writeDraft(activeId, value);
    },
    [activeId, writeDraft],
  );

  const setDraft = useCallback(
    (id: string, value: string) => {
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

  const pruneDraftCache = useCallback((validIds: ReadonlySet<string>) => {
    setDrafts((current) =>
      Object.fromEntries(
        Object.entries(current).filter(([id]) => validIds.has(id)),
      ),
    );
  }, []);

  return { draft, updateDraft, setDraft, clearDraft, pruneDraftCache };
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

export function useNewTaskDrafts(workspaceRoot: string | null) {
  return useDrafts(
    workspaceRoot,
    readNewTaskDraft,
    writeNewTaskDraft,
    clearNewTaskDraft,
  );
}
