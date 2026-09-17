import { useEffect, useState } from "react";

export type FilePreviewMode = "preview" | "source";

export type TaskPanelTabViewState = {
  previewMode: FilePreviewMode;
  scrollTop: number;
  expandedFiles: Record<string, boolean>;
};

const defaultViewState: TaskPanelTabViewState = {
  previewMode: "preview",
  scrollTop: 0,
  expandedFiles: {},
};

export function useTaskPanelViewStates(validTabIds: ReadonlySet<string>) {
  const [states, setStates] = useState<Record<string, TaskPanelTabViewState>>(
    {},
  );

  function stateFor(tabId: string): TaskPanelTabViewState {
    return states[tabId] ?? defaultViewState;
  }

  function update(
    tabId: string,
    updateState: (current: TaskPanelTabViewState) => TaskPanelTabViewState,
  ) {
    setStates((current) => ({
      ...current,
      [tabId]: updateState(current[tabId] ?? defaultViewState),
    }));
  }

  useEffect(() => {
    setStates((current) => {
      const next = Object.fromEntries(
        Object.entries(current).filter(([tabId]) => validTabIds.has(tabId)),
      );
      return Object.keys(next).length === Object.keys(current).length
        ? current
        : next;
    });
  }, [validTabIds]);

  return {
    stateFor,
    setPreviewMode(tabId: string, previewMode: FilePreviewMode) {
      update(tabId, (current) => ({ ...current, previewMode }));
    },
    setScrollTop(tabId: string, scrollTop: number) {
      update(tabId, (current) => ({ ...current, scrollTop }));
    },
    setFileExpanded(tabId: string, displayPath: string, expanded: boolean) {
      update(tabId, (current) => ({
        ...current,
        expandedFiles: { ...current.expandedFiles, [displayPath]: expanded },
      }));
    },
  };
}
