import type { PointerEventHandler, ReactNode } from "react";

import {
  titlebarPress,
  titlebarTargetIsInteractive,
  type WindowTitlebarClickCount,
} from "../../platform/window-chrome.ts";

export function WindowTitlebar({
  className,
  onBeginWindowDrag,
  onToggleWindowSize,
  onOpenWindowMenu,
  children,
}: {
  className: string;
  onBeginWindowDrag: (clicks: WindowTitlebarClickCount) => void;
  onToggleWindowSize?: () => void;
  onOpenWindowMenu?: () => void;
  children: ReactNode;
}) {
  const beginDrag: PointerEventHandler<HTMLElement> = (event) => {
    if (titlebarTargetIsInteractive(event.target)) return;
    const clicks = titlebarPress(event.button);
    if (clicks === null) return;
    onBeginWindowDrag(clicks);
  };

  return (
    <header
      className={className}
      onPointerDown={beginDrag}
      onDoubleClick={(event) => {
        if (
          !onToggleWindowSize ||
          event.button !== 0 ||
          titlebarTargetIsInteractive(event.target)
        )
          return;
        event.preventDefault();
        onToggleWindowSize();
      }}
      onContextMenu={(event) => {
        if (!onOpenWindowMenu || titlebarTargetIsInteractive(event.target))
          return;
        event.preventDefault();
        onOpenWindowMenu();
      }}
    >
      {children}
    </header>
  );
}
