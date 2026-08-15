import type { HTMLAttributes } from "react";

import { cn } from "./utils.ts";

const alertVariants = {
  neutral: "border-(--ui-border) bg-(--ui-surface-canvas) text-(--ui-content-muted)",
  warning:
    "border-[color-mix(in_srgb,var(--metask-state-warning)_25%,transparent)] bg-[color-mix(in_srgb,var(--metask-state-warning)_7%,transparent)] text-(--ui-content-warning)",
  danger:
    "border-(--ui-action-danger-border) bg-(--ui-action-danger-surface) text-(--ui-content-error)",
} as const;

export type AlertProps = HTMLAttributes<HTMLDivElement> & {
  variant?: keyof typeof alertVariants;
};

export function Alert({ className, variant = "neutral", ...props }: AlertProps) {
  return (
    <div
      role="alert"
      className={cn(
        "rounded-[10px] border p-3 text-sm",
        alertVariants[variant],
        className,
      )}
      {...props}
    />
  );
}
