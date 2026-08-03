export type WindowTitlebarClickCount = 1 | 2;

const interactiveTitlebarSelector =
  "button, input, select, textarea, label, details, a, [contenteditable='true'], [data-window-drag='exclude']";

export function titlebarTargetIsInteractive(target: EventTarget | null) {
  return (
    target !== null &&
    "closest" in target &&
    typeof target.closest === "function" &&
    target.closest(interactiveTitlebarSelector) !== null
  );
}

export function titlebarPress(button: number): WindowTitlebarClickCount | null {
  if (button !== 0) return null;
  return 1;
}
