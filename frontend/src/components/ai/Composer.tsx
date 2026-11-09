import type { HTMLAttributes, ReactNode } from "react";

import { cn, controlFocus } from "../ui/utils.ts";

export function Composer({
  state = "normal",
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & {
  state?: "normal" | "running" | "intervention" | "unavailable";
  children: ReactNode;
}) {
  return (
    <div
      className={cn("ai-composer", controlFocus, className)}
      data-state={state}
      {...props}
    >
      {children}
    </div>
  );
}
