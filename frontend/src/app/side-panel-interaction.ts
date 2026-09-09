export type SidePanelFocusTarget = {
  isConnected: boolean;
  focus: () => void;
  hasAttribute?: (name: string) => boolean;
};

function usable(target: SidePanelFocusTarget | null): boolean {
  return Boolean(
    target?.isConnected && target.hasAttribute?.("disabled") !== true,
  );
}

export function sidePanelFocusReturnTarget(
  opener: SidePanelFocusTarget | null,
  fallback: SidePanelFocusTarget | null,
): SidePanelFocusTarget | null {
  if (usable(opener)) return opener;
  return usable(fallback) ? fallback : null;
}

export function shouldDismissSidePanelForEscape(
  open: boolean,
  key: string,
  defaultPrevented: boolean,
): boolean {
  return open && key === "Escape" && !defaultPrevented;
}
