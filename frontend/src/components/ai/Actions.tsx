import type { ButtonHTMLAttributes, HTMLAttributes, ReactNode } from "react";

import { cn, focusRing } from "../ui/utils.ts";

export function MessageActions({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & { children: ReactNode }) {
  return (
    <div className={cn("ai-message-actions", className)} {...props}>
      {children}
    </div>
  );
}

export function MessageAction({
  className,
  children,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { children: ReactNode }) {
  return (
    <button className={cn("ai-message-action", focusRing, className)} {...props}>
      {children}
    </button>
  );
}
