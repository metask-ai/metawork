export type InspectorFocusTarget = {
  isConnected: boolean;
  focus: () => void;
  hasAttribute?: (name: string) => boolean;
};

function usable(target: InspectorFocusTarget | null): boolean {
  return Boolean(
    target?.isConnected && target.hasAttribute?.("disabled") !== true,
  );
}

export function inspectorFocusReturnTarget(
  opener: InspectorFocusTarget | null,
  fallback: InspectorFocusTarget | null,
): InspectorFocusTarget | null {
  if (usable(opener)) return opener;
  return usable(fallback) ? fallback : null;
}

export function shouldDismissInspectorForEscape(
  open: boolean,
  key: string,
  defaultPrevented: boolean,
): boolean {
  return open && key === "Escape" && !defaultPrevented;
}
