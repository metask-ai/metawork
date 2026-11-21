import type { HTMLAttributes } from "react";

import { cn } from "./utils.ts";

export function Badge({
  variant = "neutral",
  className,
  ...props
}: HTMLAttributes<HTMLSpanElement> & {
  variant?: "neutral" | "success";
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full border border-(--ui-border) bg-(--ui-surface-panel-2) px-2 py-0.5 text-xs font-medium",
        variant === "success"
          ? "text-(--ui-content-success)"
          : "text-(--ui-content-primary)",
        className,
      )}
      {...props}
    />
  );
}
