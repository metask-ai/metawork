import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "../ui/utils.ts";

export function Message({
  role,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & {
  role: "user" | "assistant";
  children: ReactNode;
}) {
  return (
    <article
      className={cn("ai-message", className)}
      data-role={role}
      {...props}
    >
      {children}
    </article>
  );
}
