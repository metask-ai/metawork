import { Menu as BaseMenu } from "@base-ui/react/menu";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export const Menu = {
  Root: BaseMenu.Root,
  Trigger: ({ className, ...props }: ComponentProps<typeof BaseMenu.Trigger>) => (
    <BaseMenu.Trigger className={cn(focusRing, className)} {...props} />
  ),
  Portal: BaseMenu.Portal,
  Positioner: ({ className, ...props }: ComponentProps<typeof BaseMenu.Positioner>) => (
    <BaseMenu.Positioner className={cn("z-50 outline-none", className)} sideOffset={4} {...props} />
  ),
  Popup: ({ className, ...props }: ComponentProps<typeof BaseMenu.Popup>) => (
    <BaseMenu.Popup className={cn("min-w-40 rounded-[8px] border border-(--ui-border) bg-(--ui-surface-panel) p-1 text-sm text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none", className)} {...props} />
  ),
  Item: ({ className, ...props }: ComponentProps<typeof BaseMenu.Item>) => (
    <BaseMenu.Item className={cn("flex min-h-8 cursor-default items-center rounded-[5px] px-2 py-1.5 outline-none data-highlighted:bg-(--ui-action-hover-surface) data-highlighted:text-(--ui-action-hover-content) data-disabled:pointer-events-none data-disabled:opacity-40", focusRing, className)} {...props} />
  ),
  Group: BaseMenu.Group,
  GroupLabel: ({ className, ...props }: ComponentProps<typeof BaseMenu.GroupLabel>) => (
    <BaseMenu.GroupLabel className={cn("px-2 py-1 text-xs text-(--ui-content-muted)", className)} {...props} />
  ),
  Separator: ({ className, ...props }: ComponentProps<typeof BaseMenu.Separator>) => (
    <BaseMenu.Separator className={cn("my-1 h-px bg-(--ui-border)", className)} {...props} />
  ),
};
