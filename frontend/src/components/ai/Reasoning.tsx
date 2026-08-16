import type { HTMLAttributes, ReactNode } from "react";
import { useEffect, useRef, useState } from "react";

import { cn } from "../ui/utils.ts";

/**
 * Adapted from Vercel AI Elements 1.9.0.
 * Source: https://elements.ai-sdk.dev/api/registry/reasoning.json
 *
 * Native `<details>` replaces the upstream shadcn Collapsible primitive; no
 * AI SDK or Streamdown dependency is introduced.
 */
export function Reasoning({
  open,
  defaultOpen,
  isStreaming = false,
  onOpenChange,
  className,
  children,
  ...props
}: Omit<HTMLAttributes<HTMLDetailsElement>, "open" | "onToggle"> & {
  open?: boolean;
  defaultOpen?: boolean;
  isStreaming?: boolean;
  onOpenChange?: (open: boolean) => void;
  children: ReactNode;
}) {
  const [internalOpen, setInternalOpen] = useState(defaultOpen ?? isStreaming);
  const isControlled = open !== undefined;
  const resolvedOpen = isControlled ? open : internalOpen;
  const hasStreamed = useRef(isStreaming);

  useEffect(() => {
    if (isStreaming) hasStreamed.current = true;
    if (!isStreaming && hasStreamed.current && !isControlled) {
      const timer = window.setTimeout(() => setInternalOpen(false), 1000);
      return () => window.clearTimeout(timer);
    }
    return undefined;
  }, [isControlled, isStreaming]);

  return (
    <details
      className={cn("ai-reasoning", className)}
      data-open={resolvedOpen === true}
      open={resolvedOpen}
      onToggle={(event) => {
        const nextOpen = event.currentTarget.open;
        if (!isControlled) setInternalOpen(nextOpen);
        onOpenChange?.(nextOpen);
      }}
      {...props}
    >
      {children}
    </details>
  );
}

export function ReasoningTrigger({
  label,
  status,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & {
  label?: string;
  status?: string;
  children?: ReactNode;
}) {
  return (
    <summary className={cn("ai-reasoning-trigger", className)} {...props}>
      <span>{children ?? label ?? "Thinking"}</span>
      {status && <small>{status}</small>}
      <span className="ai-reasoning-chevron" aria-hidden="true">
        ▾
      </span>
    </summary>
  );
}

export function ReasoningContent({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & { children: ReactNode }) {
  return (
    <div className={cn("ai-reasoning-content", className)} {...props}>
      {children}
    </div>
  );
}
