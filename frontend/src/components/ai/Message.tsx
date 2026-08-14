import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "../ui/utils.ts";

export type AiMessageRole = "user" | "assistant" | "system";

export function Message({
  from,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & {
  from: AiMessageRole;
  children: ReactNode;
}) {
  return (
    <article
      className={cn("ai-message", `ai-message-${from}`, className)}
      data-from={from}
      {...props}
    >
      {children}
    </article>
  );
}

export function MessageContent({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & { children: ReactNode }) {
  return (
    <div className={cn("ai-message-content", className)} {...props}>
      {children}
    </div>
  );
}

export function MessageResponse({
  className,
  children,
  streaming = false,
  ...props
}: HTMLAttributes<HTMLDivElement> & {
  children: ReactNode;
  streaming?: boolean;
}) {
  return (
    <div
      className={cn("ai-message-response", className)}
      data-streaming={streaming}
      {...props}
    >
      {children}
    </div>
  );
}
