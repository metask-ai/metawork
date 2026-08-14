import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "../ui/utils.ts";

/**
 * Adapted from Vercel AI Elements 1.9.0.
 * Source: https://elements.ai-sdk.dev/api/registry/conversation.json
 *
 * The upstream `use-stick-to-bottom` dependency is intentionally omitted.
 * Scroll ownership remains with the product feature; this component owns
 * conversation presentation and accessibility semantics only.
 */
export function Conversation({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & { children: ReactNode }) {
  return (
    <section
      className={cn("ai-conversation", className)}
      role="log"
      aria-live="polite"
      {...props}
    >
      {children}
    </section>
  );
}

export function ConversationContent({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & { children: ReactNode }) {
  return (
    <div className={cn("ai-conversation-content", className)} {...props}>
      {children}
    </div>
  );
}

export function ConversationEmptyState({
  title = "No messages yet",
  description = "Start a conversation to see messages here",
  icon,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & {
  title?: string;
  description?: string;
  icon?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <div className={cn("ai-conversation-empty", className)} {...props}>
      {children ?? (
        <>
          {icon && <div className="ai-conversation-empty-icon">{icon}</div>}
          <div>
            <h3>{title}</h3>
            {description && <p>{description}</p>}
          </div>
        </>
      )}
    </div>
  );
}
