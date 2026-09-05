export type TaskPanelFocusTarget = {
  isConnected: boolean;
  focus: () => void;
  hasAttribute?: (name: string) => boolean;
};

function usable(target: TaskPanelFocusTarget | null): boolean {
  return Boolean(
    target?.isConnected && target.hasAttribute?.("disabled") !== true,
  );
}

export function taskPanelFocusReturnTarget(
  opener: TaskPanelFocusTarget | null,
  fallback: TaskPanelFocusTarget | null,
): TaskPanelFocusTarget | null {
  if (usable(opener)) return opener;
  return usable(fallback) ? fallback : null;
}

export function shouldDismissTaskPanelForEscape(
  open: boolean,
  key: string,
  defaultPrevented: boolean,
): boolean {
  return open && key === "Escape" && !defaultPrevented;
}
