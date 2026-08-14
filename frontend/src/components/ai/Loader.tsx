import type { HTMLAttributes } from "react";

import { cn } from "../ui/utils.ts";

export function Loader({
  label,
  className,
  ...props
}: HTMLAttributes<HTMLDivElement> & { label: string }) {
  return (
    <div
      className={cn("ai-loader", className)}
      role="status"
      aria-live="polite"
      {...props}
    >
      <span className="ai-loader-mark" aria-hidden="true">
        <span />
        <span />
        <span />
      </span>
      <span>{label}</span>
    </div>
  );
}
