import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "../ui/utils.ts";

export function Intervention({
  kind,
  label,
  title,
  busy = false,
  status,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLElement> & {
  kind: "permission" | "clarification" | "confirmation" | "review";
  label: ReactNode;
  title: ReactNode;
  busy?: boolean;
  status?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section
      className={cn("ai-intervention", className)}
      data-kind={kind}
      aria-busy={busy}
      {...props}
    >
      <header className="ai-intervention-header">
        <p>{label}</p>
        <h3>{title}</h3>
      </header>
      <div className="ai-intervention-content">{children}</div>
      {status && <div className="ai-intervention-status">{status}</div>}
    </section>
  );
}
