import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "../ui/utils.ts";

export function Message({
  role,
  streaming = false,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & {
  role: "user" | "assistant";
  streaming?: boolean;
  children: ReactNode;
}) {
  return (
    <article
      className={cn("ai-message", className)}
      data-role={role}
      data-streaming={role === "assistant" && streaming}
      {...props}
    >
      {children}
    </article>
  );
}
