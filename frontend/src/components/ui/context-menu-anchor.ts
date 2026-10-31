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
