import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "../ui/utils.ts";

export function Activity({
  state,
  label,
  detail,
  action,
  announce = false,
  className,
  ...props
}: Omit<HTMLAttributes<HTMLElement>, "children"> & {
  state: "live" | "completed" | "stopped" | "failed" | "interrupted";
  label: ReactNode;
  detail?: ReactNode;
  action?: ReactNode;
  announce?: boolean;
}) {
  const live = state === "live";
  return (
    <section
      className={cn("ai-activity", className)}
      data-state={state}
      role={live || announce ? "status" : undefined}
      aria-live={live || announce ? "polite" : undefined}
      {...props}
    >
      <span className="ai-activity-mark" aria-hidden="true" />
      <div className="ai-activity-copy">
        <p>{label}</p>
        {detail && <span>{detail}</span>}
      </div>
      {action && <div className="ai-activity-action">{action}</div>}
    </section>
  );
}
