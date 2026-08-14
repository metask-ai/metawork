import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "../ui/utils.ts";

export function Reasoning({
  open,
  className,
  children,
  ...props
}: Omit<HTMLAttributes<HTMLDetailsElement>, "open"> & {
  open?: boolean;
  children: ReactNode;
}) {
  return (
    <details
      className={cn("ai-reasoning", className)}
      data-open={open === true}
      open={open}
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
  label: string;
  status?: string;
  children?: ReactNode;
}) {
  return (
    <summary className={cn("ai-reasoning-trigger", className)} {...props}>
      <span>{label}</span>
      {status && <small>{status}</small>}
      {children}
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
