import type { HTMLAttributes, ReactNode } from "react";

import { Icon } from "../ui/Icon.tsx";
import { cn } from "../ui/utils.ts";

export type AiToolState = "running" | "completed" | "failed";

export function Tool({
  state,
  open,
  className,
  children,
  ...props
}: Omit<HTMLAttributes<HTMLDetailsElement>, "open"> & {
  state: AiToolState;
  open?: boolean;
  children: ReactNode;
}) {
  return (
    <details
      className={cn("ai-tool", className)}
      data-state={state}
      open={open}
      {...props}
    >
      {children}
    </details>
  );
}

export function ToolHeader({
  name,
  status,
  meta,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & {
  name: string;
  status: string;
  meta?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <summary className={cn("ai-tool-header", className)} {...props}>
      <span className="ai-tool-identity">
        <span className="ai-tool-state" aria-hidden="true" />
        <span className="ai-tool-name">{name}</span>
      </span>
      <span className="ai-tool-meta">
        <span className="ai-tool-status">{status}</span>
        {meta}
        {children}
        <span className="ai-tool-disclosure" aria-hidden="true">
          <Icon name="chevron" />
        </span>
      </span>
    </summary>
  );
}

export function ToolContent({
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & { children: ReactNode }) {
  return (
    <div className={cn("ai-tool-content", className)} {...props}>
      {children}
    </div>
  );
}

export function ToolField({
  label,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & {
  label: string;
  children: ReactNode;
}) {
  return (
    <div className={cn("ai-tool-field", className)} {...props}>
      <p className="ai-tool-field-label">{label}</p>
      {children}
    </div>
  );
}
