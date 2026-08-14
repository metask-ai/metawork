import type { HTMLAttributes, ReactNode } from "react";
import {
  CheckCircle,
  ChevronDown,
  Circle,
  Clock3,
  Wrench,
  XCircle,
} from "lucide-react";

import { cn } from "../ui/utils.ts";

export type AiToolState =
  | "running"
  | "completed"
  | "failed"
  | "approval-requested"
  | "approval-responded"
  | "input-streaming"
  | "output-denied"
  | "output-error";

type ToolStatus = {
  label: string;
  icon: ReactNode;
};

const statusMap: Record<AiToolState, ToolStatus> = {
  running: { label: "Running", icon: <Clock3 aria-hidden="true" /> },
  completed: { label: "Completed", icon: <CheckCircle aria-hidden="true" /> },
  failed: { label: "Error", icon: <XCircle aria-hidden="true" /> },
  "approval-requested": {
    label: "Awaiting approval",
    icon: <Clock3 aria-hidden="true" />,
  },
  "approval-responded": {
    label: "Approval responded",
    icon: <CheckCircle aria-hidden="true" />,
  },
  "input-streaming": {
    label: "Pending",
    icon: <Circle aria-hidden="true" />,
  },
  "output-denied": {
    label: "Denied",
    icon: <XCircle aria-hidden="true" />,
  },
  "output-error": { label: "Error", icon: <XCircle aria-hidden="true" /> },
};

/**
 * Adapted from Vercel AI Elements 1.9.0.
 * Source: https://elements.ai-sdk.dev/api/registry/tool.json
 *
 * AI SDK's ToolUIPart state is represented by the local generic state above;
 * feature code remains responsible for already-redacted field projections.
 */
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
  state,
  meta,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & {
  name: string;
  status?: string;
  state?: AiToolState;
  meta?: ReactNode;
  children?: ReactNode;
}) {
  const resolvedStatus = status ?? (state ? statusMap[state].label : "");
  const statusIcon = state ? statusMap[state].icon : <Wrench aria-hidden="true" />;

  return (
    <summary className={cn("ai-tool-header", className)} {...props}>
      <span className="ai-tool-identity">
        <span className="ai-tool-state" aria-hidden="true">
          {statusIcon}
        </span>
        <span className="ai-tool-name">{name}</span>
      </span>
      <span className="ai-tool-meta">
        <span className="ai-tool-status">{resolvedStatus}</span>
        {meta}
        {children}
        <span className="ai-tool-disclosure" aria-hidden="true">
          <ChevronDown />
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
