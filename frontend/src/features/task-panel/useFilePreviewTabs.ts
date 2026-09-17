import { useEffect, useRef, useState } from "react";

import type { FilePreview, FileReferenceView } from "../../bridge/contracts.ts";
import { createTaskPanelPreviewTab } from "./task-panel-state.ts";

type FilePreviewIdentity = {
  tabId: string;
  taskId: string;
  runId: string;
  reference: FileReferenceView;
  requestGeneration: number;
};

export type FilePreviewTabState =
  | (FilePreviewIdentity & { kind: "loading" })
  | (FilePreviewIdentity & { kind: "ready"; preview: FilePreview })
  | (FilePreviewIdentity & { kind: "failed"; preview: FilePreview });

type FilePreviewLoader = (
  taskId: string,
  runId: string,
  referenceId: string,
) => Promise<FilePreview>;

export function useFilePreviewTabs(
  activeTaskId: string | null,
  validTabIds: ReadonlySet<string>,
  load: FilePreviewLoader,
) {
  const [resources, setResourceState] = useState<
    Record<string, FilePreviewTabState>
  >({});
  const resourcesRef = useRef(resources);
  const generations = useRef(new Map<string, number>());
  const activeTaskIdRef = useRef(activeTaskId);
  activeTaskIdRef.current = activeTaskId;

  function setResources(
    update: (
      current: Record<string, FilePreviewTabState>,
    ) => Record<string, FilePreviewTabState>,
  ) {
    setResourceState((current) => {
      const next = update(current);
      resourcesRef.current = next;
      return next;
    });
  }

  function invalidate(tabId: string) {
    generations.current.set(tabId, (generations.current.get(tabId) ?? 0) + 1);
  }

  function request(
    taskId: string,
    runId: string,
    reference: FileReferenceView,
  ) {
    const tab = createTaskPanelPreviewTab(taskId, runId, reference);
    const requestGeneration = (generations.current.get(tab.tabId) ?? 0) + 1;
    generations.current.set(tab.tabId, requestGeneration);
    const identity: FilePreviewIdentity = {
      tabId: tab.tabId,
      taskId,
      runId,
      reference,
      requestGeneration,
    };
    setResources((current) => ({
      ...current,
      [tab.tabId]: { kind: "loading", ...identity },
    }));
    void load(taskId, runId, reference.id)
      .then((preview) => {
        if (
          generations.current.get(tab.tabId) !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setResources((current) => {
          const resource = current[tab.tabId];
          if (
            !resource ||
            resource.requestGeneration !== requestGeneration ||
            resource.taskId !== taskId ||
            resource.runId !== runId ||
            resource.reference.id !== reference.id
          )
            return current;
          return {
            ...current,
            [tab.tabId]:
              preview.state === "ready"
                ? { ...resource, kind: "ready", preview }
                : { ...resource, kind: "failed", preview },
          };
        });
      })
      .catch(() => {
        if (
          generations.current.get(tab.tabId) !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setResources((current) => {
          const resource = current[tab.tabId];
          if (!resource || resource.requestGeneration !== requestGeneration)
            return current;
          return {
            ...current,
            [tab.tabId]: {
              ...resource,
              kind: "failed",
              preview: {
                state: "error",
                content: "",
                truncated: false,
                redacted: false,
              },
            },
          };
        });
      });
  }

  function open(taskId: string, runId: string, reference: FileReferenceView) {
    const tab = createTaskPanelPreviewTab(taskId, runId, reference);
    const current = resourcesRef.current[tab.tabId];
    if (current) {
      if (
        current.reference.title !== reference.title ||
        current.reference.displayPath !== reference.displayPath
      )
        setResources((resources) => ({
          ...resources,
          [tab.tabId]: { ...current, reference },
        }));
      return;
    }
    request(taskId, runId, reference);
  }

  function close(tabId: string) {
    invalidate(tabId);
    setResources((current) => {
      if (!(tabId in current)) return current;
      const next = { ...current };
      delete next[tabId];
      return next;
    });
  }

  function clear() {
    for (const tabId of Object.keys(resourcesRef.current)) invalidate(tabId);
    setResources((current) =>
      Object.keys(current).length === 0 ? current : {},
    );
  }

  useEffect(() => {
    clear();
  }, [activeTaskId]);

  useEffect(() => {
    for (const tabId of Object.keys(resourcesRef.current))
      if (!validTabIds.has(tabId)) close(tabId);
  }, [validTabIds]);

  return { resources, open, refresh: request, close, clear };
}
