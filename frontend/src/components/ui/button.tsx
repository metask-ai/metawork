import { Button as BaseButton } from "@base-ui/react/button";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export type ButtonVariant = "primary" | "secondary" | "ghost" | "danger";
export type ButtonSize = "sm" | "md" | "lg" | "icon";

const variants: Record<ButtonVariant, string> = {
  primary: "bg-(--ui-action-primary) text-white hover:bg-(--ui-action-primary-hover) active:translate-y-px",
  secondary:
    "border border-(--ui-border) bg-(--ui-surface-panel) text-(--ui-content-primary) hover:bg-(--ui-surface-panel-2)",
  ghost:
    "bg-transparent text-(--ui-content-primary) hover:bg-(--ui-surface-panel-2)",
  danger: "bg-(--metask-state-error) text-white hover:brightness-95 active:translate-y-px",
};

const sizes: Record<ButtonSize, string> = {
  sm: "h-8 px-3 text-xs",
  md: "h-9 px-4 text-sm",
  lg: "h-11 px-5 text-sm",
  icon: "size-9 p-0",
};

export type ButtonProps = ComponentProps<typeof BaseButton> & {
  variant?: ButtonVariant;
  size?: ButtonSize;
};

export function Button({
  className,
  variant = "primary",
  size = "md",
  ...props
}: ButtonProps) {
  return (
    <BaseButton
      className={cn(
        "inline-flex shrink-0 items-center justify-center gap-2 rounded-[7px] font-medium leading-none select-none",
        focusRing,
        variants[variant],
        sizes[size],
        className,
      )}
      {...props}
    />
  );
}
