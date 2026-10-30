import { useEffect, useRef, useState } from "react";
import type {
  FilePreview,
  FileReferenceView,
  FilePreviewLoadOptions,
} from "../../bridge/contracts.ts";
import {
  createTaskPanelPreviewTab,
  createTaskPanelWorkspaceTab,
} from "./task-panel-state.ts";
type FilePreviewIdentity = {
  tabId: string;
  taskId: string;
  runId: string | null;
  workspaceId: string | null;
  workspaceEpoch: string | null;
  reference: FileReferenceView;
  requestGeneration: number;
};
export type FilePreviewTabState =
  | (FilePreviewIdentity & {
      kind: "loading";
    })
  | (FilePreviewIdentity & {
      kind: "ready";
      preview: FilePreview;
    })
  | (FilePreviewIdentity & {
      kind: "failed";
      preview: FilePreview;
    });
type FilePreviewLoader = (
  taskId: string,
  runId: string,
  referenceId: string,
  options?: FilePreviewLoadOptions,
) => Promise<FilePreview>;
export function useFilePreviewTabs(
  activeTaskId: string | null,
  validTabIds: ReadonlySet<string>,
  load: FilePreviewLoader,
  loadWorkspace: (
    taskId: string,
    workspaceId: string,
    workspaceEpoch: string,
    path: string,
    options?: FilePreviewLoadOptions,
  ) => Promise<FilePreview>,
) {
  const [resources, setResourceState] = useState<
    Record<string, FilePreviewTabState>
  >({});
  const resourcesRef = useRef(resources);
  const generations = useRef(new Map<string, number>());
  const controllers = useRef(new Map<string, AbortController>());
  const activeTaskIdRef = useRef(activeTaskId);
  activeTaskIdRef.current = activeTaskId;
  function setResources(
    update: (
      current: Record<string, FilePreviewTabState>,
    ) => Record<string, FilePreviewTabState>,
  ) {
    const next = update(resourcesRef.current);
    resourcesRef.current = next;
    setResourceState(next);
  }
  function invalidate(tabId: string) {
    controllers.current.get(tabId)?.abort();
    controllers.current.delete(tabId);
    const resource = resourcesRef.current[tabId];
    if (resource && "preview" in resource) resource.preview.release?.();
    generations.current.set(tabId, (generations.current.get(tabId) ?? 0) + 1);
  }
  function request(
    taskId: string,
    runId: string | null,
    reference: FileReferenceView,
    workspaceId: string | null = null,
    workspaceEpoch: string | null = null,
  ) {
    const tab =
      workspaceId !== null
        ? createTaskPanelWorkspaceTab(
            taskId,
            workspaceId,
            workspaceEpoch!,
            reference.displayPath,
          )
        : createTaskPanelPreviewTab(taskId, runId!, reference);
    invalidate(tab.tabId);
    const controller = new AbortController();
    controllers.current.set(tab.tabId, controller);
    const requestGeneration = (generations.current.get(tab.tabId) ?? 0) + 1;
    generations.current.set(tab.tabId, requestGeneration);
    const identity: FilePreviewIdentity = {
      tabId: tab.tabId,
      taskId,
      runId,
      workspaceId,
      workspaceEpoch,
      reference,
      requestGeneration,
    };
    setResources((current) => ({
      ...current,
      [tab.tabId]: { kind: "loading", ...identity },
    }));
    const options: FilePreviewLoadOptions = {
      signal: controller.signal,
      priority: "interactive",
    };
    void (
      workspaceId !== null
        ? loadWorkspace(
            taskId,
            workspaceId,
            workspaceEpoch!,
            reference.displayPath,
            options,
          )
        : load(taskId, runId!, reference.id, options)
    )
      .then((preview) => {
        if (
          controller.signal.aborted ||
          generations.current.get(tab.tabId) !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        ) {
          preview.release?.();
          return;
        }
        setResources((current) => {
          const resource = current[tab.tabId];
          if (
            !resource ||
            resource.requestGeneration !== requestGeneration ||
            resource.taskId !== taskId ||
            resource.runId !== runId ||
            resource.reference.id !== reference.id
          ) {
            preview.release?.();
            return current;
          }
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
          controller.signal.aborted ||
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
  function openWorkspace(
    taskId: string,
    workspaceId: string,
    workspaceEpoch: string,
    path: string,
  ) {
    const tab = createTaskPanelWorkspaceTab(
      taskId,
      workspaceId,
      workspaceEpoch,
      path,
    );
    if (!resourcesRef.current[tab.tabId])
      request(
        taskId,
        null,
        { id: path, title: tab.title, displayPath: path },
        workspaceId,
        workspaceEpoch,
      );
  }
  function refreshWorkspace(
    taskId: string,
    workspaceId: string,
    workspaceEpoch: string,
    path: string,
  ) {
    const tab = createTaskPanelWorkspaceTab(
      taskId,
      workspaceId,
      workspaceEpoch,
      path,
    );
    request(
      taskId,
      null,
      { id: path, title: tab.title, displayPath: path },
      workspaceId,
      workspaceEpoch,
    );
  }
  function clear() {
    for (const controller of controllers.current.values()) controller.abort();
    controllers.current.clear();
    for (const tabId of Object.keys(resourcesRef.current)) invalidate(tabId);
    setResources((current) =>
      Object.keys(current).length === 0 ? current : {},
    );
  }
  useEffect(() => {
    clear();
    return () => {
      for (const controller of controllers.current.values()) controller.abort();
      controllers.current.clear();
      for (const resource of Object.values(resourcesRef.current)) {
        if ("preview" in resource) resource.preview.release?.();
      }
    };
  }, [activeTaskId]);
  useEffect(() => {
    for (const tabId of Object.keys(resourcesRef.current))
      if (!validTabIds.has(tabId)) close(tabId);
  }, [validTabIds]);
  return {
    resources,
    open,
    openWorkspace,
    refreshWorkspace,
    refresh: request,
    close,
    clear,
  };
}
