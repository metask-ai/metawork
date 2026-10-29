import type { ReactNode, Ref } from "react";

export function WindowTitlebar({
  className,
  children,
  ref,
}: {
  className: string;
  children: ReactNode;
  ref: Ref<HTMLElement>;
}) {
  return (
    <header ref={ref} className={className} data-native-window-drag="">
      {children}
    </header>
  );
}
