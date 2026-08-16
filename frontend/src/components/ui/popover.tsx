import { Popover as BasePopover } from "@base-ui/react/popover";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export const Popover = {
  Root: BasePopover.Root,
  Trigger: ({
    className,
    ...props
  }: ComponentProps<typeof BasePopover.Trigger>) => (
    <BasePopover.Trigger className={cn(focusRing, className)} {...props} />
  ),
  Portal: BasePopover.Portal,
  Positioner: ({
    className,
    ...props
  }: ComponentProps<typeof BasePopover.Positioner>) => (
    <BasePopover.Positioner
      className={cn("z-50 outline-none", className)}
      sideOffset={4}
      {...props}
    />
  ),
  Popup: ({
    className,
    ...props
  }: ComponentProps<typeof BasePopover.Popup>) => (
    <BasePopover.Popup
      className={cn(
        "rounded-[10px] border border-(--ui-border) bg-(--ui-surface-panel) p-4 text-sm text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none",
        className,
      )}
      {...props}
    />
  ),
  Title: ({
    className,
    ...props
  }: ComponentProps<typeof BasePopover.Title>) => (
    <BasePopover.Title className={cn("font-semibold", className)} {...props} />
  ),
  Description: ({
    className,
    ...props
  }: ComponentProps<typeof BasePopover.Description>) => (
    <BasePopover.Description
      className={cn("text-xs text-(--ui-content-muted)", className)}
      {...props}
    />
  ),
  Close: ({
    className,
    ...props
  }: ComponentProps<typeof BasePopover.Close>) => (
    <BasePopover.Close className={cn(focusRing, className)} {...props} />
  ),
};
