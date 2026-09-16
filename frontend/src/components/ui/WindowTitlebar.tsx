import type { ReactNode } from "react";

export function WindowTitlebar({
  className,
  children,
}: {
  className: string;
  children: ReactNode;
}) {
  return (
    <header className={className} data-metawork-window-drag="">
      {children}
    </header>
  );
}
