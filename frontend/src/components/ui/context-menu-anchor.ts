import type { KeyboardEvent, MouseEvent } from "react";

/** Freeze a right-click's viewport position while retaining its owning element. */
export function createContextMenuAnchor(
  element: HTMLElement,
  x: number,
  y: number,
) {
  return {
    contextElement: element,
    getBoundingClientRect: () => ({
      x,
      y,
      left: x,
      top: y,
      right: x,
      bottom: y,
      width: 0,
      height: 0,
    }),
  };
}

export type ContextMenuAnchor =
  HTMLElement | ReturnType<typeof createContextMenuAnchor>;

export type ContextMenuEvent =
  MouseEvent<HTMLElement> | KeyboardEvent<HTMLElement>;

/**
 * Everything an element needs to open a context menu of its own: the secondary
 * button, the menu key and Shift+F10. Nothing without a menu.
 */
export function contextMenuProps(
  open: ((event: ContextMenuEvent) => void) | null | undefined,
) {
  if (!open) return {};
  return {
    "aria-keyshortcuts": "Shift+F10",
    onContextMenu: (event: MouseEvent<HTMLElement>) => open(event),
    onKeyDown: (event: KeyboardEvent<HTMLElement>) => {
      if (
        event.key === "ContextMenu" ||
        (event.shiftKey && event.key === "F10")
      )
        open(event);
    },
  };
}
