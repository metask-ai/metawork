import { useCallback, useRef, useState } from "react";

import {
  clearTaskDraft,
  newTaskDraftMoveDecision,
  pruneTaskDrafts,
  readNewTaskDraft,
  readTaskDraft,
  readNewTaskDraftRecord,
  writeNewTaskDraftRecord,
  type NewTaskDirectory,
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
  const activeRef = useRef(activeId);
  activeRef.current = activeId;
  const publish = useCallback((next: Record<string, ComposerDraft>) => {
    draftsRef.current = next;
    setDrafts(next);
  }, []);
  const draft = activeId
    ? (drafts[activeId] ?? readDraft(activeId))
    : emptyComposerDraft();
  const getDraft = useCallback(
    (id: string) => draftsRef.current[id] ?? readDraft(id),
    [readDraft],
  );
  const currentDraft = useCallback(
    (expectedId: string | null) => {
      if (!expectedId || expectedId !== activeRef.current) return null;
      return draftsRef.current[expectedId] ?? readDraft(expectedId);
    },
    [readDraft],
  );
  // Validate the frozen target before any effect; update the owned cache
  // synchronously so a second add never reads the previous React render.
  const commitDraft = useCallback(
    (expectedId: string | null, value: ComposerDraft): boolean => {
      if (!expectedId || expectedId !== activeRef.current) return false;
      publish({ ...draftsRef.current, [expectedId]: value });
      writeDraft(expectedId, value);
      return true;
    },
    [publish, writeDraft],
  );
  const updateDraft = useCallback(
    (value: ComposerDraft) => {
      commitDraft(activeRef.current, value);
    },
    [commitDraft],
  );
  const setDraft = useCallback(
    (id: string, value: ComposerDraft) => {
      publish({ ...draftsRef.current, [id]: value });
      writeDraft(id, value);
    },
    [publish, writeDraft],
  );
  const clearDraft = useCallback(
    (id: string) => {
      const next = { ...draftsRef.current };
      delete next[id];
      publish(next);
      clearStoredDraft(id);
    },
    [publish, clearStoredDraft],
  );
  const acknowledgeDraft = useCallback(
    (id: string, submitted: ComposerDraft) => {
      const current = getDraft(id);
      if (current === submitted) {
        clearDraft(id);
      } else if (
        current.kind === "multimodal" &&
        submitted.kind === "multimodal"
      ) {
        const sent = new Set(submitted.attachments.map(({ token }) => token));
        const attachments = current.attachments.filter(
          ({ token }) => !sent.has(token),
        );
        if (attachments.length !== current.attachments.length)
          setDraft(
            id,
            attachments.length
              ? { ...current, attachments }
              : { kind: "text", text: current.text },
          );
      }
    },
    [getDraft, clearDraft, setDraft],
  );
  const moveDraft = useCallback(
    (from: string, to: string) => {
      if (from === to) return "same" as const;
      const source = draftsRef.current[from] ?? readDraft(from);
      const target = draftsRef.current[to] ?? readDraft(to);
      const decision = newTaskDraftMoveDecision(source, target);
      if (decision === "preserve_both") return decision;
      const next = { ...draftsRef.current };
      delete next[from];
      if (decision === "move") next[to] = source;
      publish(next);
      clearStoredDraft(from);
      if (decision === "move") writeDraft(to, source);
      return decision;
    },
    [publish, clearStoredDraft, readDraft, writeDraft],
  );
  const pruneDraftCache = useCallback(
    (validIds: ReadonlySet<string>) => {
      const discarded: ComposerAttachment[] = [];
      for (const [id, value] of Object.entries(draftsRef.current)) {
        if (!validIds.has(id) && value.kind === "multimodal")
          discarded.push(...value.attachments);
      }
      publish(
        Object.fromEntries(
          Object.entries(draftsRef.current).filter(([id]) => validIds.has(id)),
        ),
      );
      return discarded;
    },
    [publish],
  );
  const invalidateAttachments = useCallback(() => {
    const next = { ...draftsRef.current };
    for (const [id, value] of Object.entries(next))
      if (value.kind === "multimodal") {
        next[id] = {
          kind: "text",
          text: value.text,
          attachmentsReloadRequired: true,
        };
      }
    publish(next);
  }, [publish]);
  return {
    draft,
    getDraft,
    currentDraft,
    commitDraft,
    updateDraft,
    setDraft,
    clearDraft,
    acknowledgeDraft,
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
  const [directories, setDirectories] = useState<
    Record<string, NewTaskDirectory>
  >({});
  const directoriesRef = useRef(directories);
  const getDirectory = useCallback(
    (id: string) =>
      directoriesRef.current[id] ?? readNewTaskDraftRecord(id).directory,
    [],
  );
  const write = useCallback(
    (id: string, content: ComposerDraft) => {
      writeNewTaskDraftRecord(id, { directory: getDirectory(id), content });
    },
    [getDirectory],
  );
  const clear = useCallback(
    (id: string) => write(id, emptyComposerDraft()),
    [write],
  );
  const drafts = useDrafts(activeDraftId, readNewTaskDraft, write, clear);
  const setDirectoryFor = useCallback(
    (id: string, directory: NewTaskDirectory) => {
      const next = { ...directoriesRef.current, [id]: directory };
      directoriesRef.current = next;
      setDirectories(next);
      writeNewTaskDraftRecord(id, { directory, content: drafts.getDraft(id) });
    },
    [drafts.getDraft],
  );
  const moveDraft = useCallback(
    (from: string, to: string) => {
      if (from === to) return "same" as const;
      const source = drafts.getDraft(from),
        target = drafts.getDraft(to);
      const sourceDirectory = getDirectory(from),
        targetDirectory = getDirectory(to);
      const decision = newTaskDraftMoveDecision(
        source,
        target,
        sourceDirectory.kind === "explicit",
        targetDirectory.kind === "explicit",
      );
      if (decision === "preserve_both") return decision;
      if (decision === "move") {
        drafts.setDraft(to, source);
        setDirectoryFor(to, sourceDirectory);
      }
      drafts.clearDraft(from);
      setDirectoryFor(from, { kind: "project_default" });
      return decision;
    },
    [
      drafts.getDraft,
      drafts.setDraft,
      drafts.clearDraft,
      getDirectory,
      setDirectoryFor,
    ],
  );
  return {
    ...drafts,
    moveDraft,
    directory: activeDraftId
      ? getDirectory(activeDraftId)
      : ({ kind: "project_default" } as NewTaskDirectory),
    setDirectory: (directory: NewTaskDirectory) => {
      if (activeDraftId) setDirectoryFor(activeDraftId, directory);
    },
  };
}
