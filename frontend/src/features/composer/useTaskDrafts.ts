import { useCallback, useState } from "react";

import {
  clearTaskDraft,
  pruneTaskDrafts,
  readTaskDraft,
  writeTaskDraft,
} from "./drafts.ts";

export function useTaskDrafts(activeTaskId: string | null) {
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const draft = activeTaskId
    ? (drafts[activeTaskId] ?? readTaskDraft(activeTaskId))
    : "";

  const updateDraft = useCallback(
    (value: string) => {
      if (!activeTaskId) return;
      setDrafts((current) => ({ ...current, [activeTaskId]: value }));
      writeTaskDraft(activeTaskId, value);
    },
    [activeTaskId],
  );

  const clearDraft = useCallback((taskId: string) => {
    setDrafts((current) => {
      if (!(taskId in current)) return current;
      const next = { ...current };
      delete next[taskId];
      return next;
    });
    clearTaskDraft(taskId);
  }, []);

  const pruneDrafts = useCallback((validTaskIds: readonly string[]) => {
    const valid = new Set(validTaskIds);
    pruneTaskDrafts(valid);
    setDrafts((current) =>
      Object.fromEntries(
        Object.entries(current).filter(([taskId]) => valid.has(taskId)),
      ),
    );
  }, []);

  return { draft, updateDraft, clearDraft, pruneDrafts };
}
