import { useEffect, useRef, useState } from "react";
import type {
  FilePreview,
  FileReferenceView,
  FilePreviewLoadOptions,
  FileTarget,
} from "../../bridge/contracts.ts";
import {
  createTaskPanelPreviewTab,
  createTaskPanelWorkspaceTab,
} from "./task-panel-state.ts";
type FilePreviewIdentity = {
  tabId: string;
  target: FileTarget;
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
  target: FileTarget,
  options?: FilePreviewLoadOptions,
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
    tabId: string,
    target: FileTarget,
    reference: FileReferenceView,
  ) {
    const { taskId } = target;
    invalidate(tabId);
    const controller = new AbortController();
    controllers.current.set(tabId, controller);
    const requestGeneration = (generations.current.get(tabId) ?? 0) + 1;
    generations.current.set(tabId, requestGeneration);
    const identity: FilePreviewIdentity = {
      tabId,
      target,
      reference,
      requestGeneration,
    };
    setResources((current) => ({
      ...current,
      [tabId]: { kind: "loading", ...identity },
    }));
    void load(target, { signal: controller.signal, priority: "interactive" })
      .then((preview) => {
        if (
          controller.signal.aborted ||
          generations.current.get(tabId) !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        ) {
          preview.release?.();
          return;
        }
        setResources((current) => {
          const resource = current[tabId];
          if (!resource || resource.requestGeneration !== requestGeneration) {
            preview.release?.();
            return current;
          }
          return {
            ...current,
            [tabId]:
              preview.state === "ready"
                ? { ...resource, kind: "ready", preview }
                : { ...resource, kind: "failed", preview },
          };
        });
      })
      .catch(() => {
        if (
          controller.signal.aborted ||
          generations.current.get(tabId) !== requestGeneration ||
          activeTaskIdRef.current !== taskId
        )
          return;
        setResources((current) => {
          const resource = current[tabId];
          if (!resource || resource.requestGeneration !== requestGeneration)
            return current;
          return {
            ...current,
            [tabId]: {
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
  function refresh(
    taskId: string,
    runId: string,
    reference: FileReferenceView,
  ) {
    request(
      createTaskPanelPreviewTab(taskId, runId, reference).tabId,
      { kind: "reference", taskId, runId, fileReferenceId: reference.id },
      reference,
    );
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
    refresh(taskId, runId, reference);
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
    const { tabId } = createTaskPanelWorkspaceTab(
      taskId,
      workspaceId,
      workspaceEpoch,
      path,
    );
    if (!resourcesRef.current[tabId])
      refreshWorkspace(taskId, workspaceId, workspaceEpoch, path);
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
      tab.tabId,
      { kind: "workspace", taskId, workspaceId, workspaceEpoch, path },
      { id: path, title: tab.title, displayPath: path },
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
    refresh,
    close,
    clear,
  };
}
