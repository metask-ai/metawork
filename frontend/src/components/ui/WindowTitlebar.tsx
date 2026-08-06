import type { ReactNode } from "react";
import { createPortal } from "react-dom";

export function WindowTitlebar({
  className,
  children,
}: {
  className: string;
  children: ReactNode;
}) {
  const dragRegion = (
    <span className="window-drag-region" data-metawork-window-drag="" />
  );
  return (
    <>
      {typeof document === "undefined"
        ? dragRegion
        : createPortal(dragRegion, document.body)}
      <header className={className}>{children}</header>
    </>
  );
}
