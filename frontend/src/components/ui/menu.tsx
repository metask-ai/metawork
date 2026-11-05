import { Menu as BaseMenu } from "@base-ui/react/menu";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

type MenuItemProps = ComponentProps<typeof BaseMenu.Item> & {
  variant?: "default" | "danger";
};

export const Menu = {
  Root: BaseMenu.Root,
  Trigger: ({
    className,
    ...props
  }: ComponentProps<typeof BaseMenu.Trigger>) => (
    <BaseMenu.Trigger className={cn(focusRing, className)} {...props} />
  ),
  Portal: (props: ComponentProps<typeof BaseMenu.Portal>) => (
    <BaseMenu.Portal {...props} data-native-window-drag-exclude="" />
  ),
  Positioner: ({
    className,
    ...props
  }: ComponentProps<typeof BaseMenu.Positioner>) => (
    <BaseMenu.Positioner
      className={cn("z-50 outline-none", className)}
      sideOffset={4}
      {...props}
    />
  ),
  Popup: ({ className, ...props }: ComponentProps<typeof BaseMenu.Popup>) => (
    <BaseMenu.Popup
      className={cn(
        "grid min-w-40 rounded-[10px] border border-(--ui-border) bg-(--ui-surface-panel) p-[5px] text-[length:var(--text-label)] text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none",
        className,
      )}
      {...props}
    />
  ),
  Item: ({ className, variant = "default", ...props }: MenuItemProps) => (
    <BaseMenu.Item
      className={cn(
        "flex min-h-8 cursor-default items-center gap-2 rounded-[6px] border-0 bg-transparent px-[9px] py-0 text-left outline-none hover:bg-(--ui-action-hover-surface) data-highlighted:bg-(--ui-action-hover-surface) data-highlighted:text-(--ui-action-hover-content) data-disabled:pointer-events-none data-disabled:opacity-40 [&>svg]:size-[14px]",
        focusRing,
        variant === "danger" &&
          "text-(--metask-state-error) data-highlighted:text-(--metask-state-error)",
        className,
      )}
      {...props}
    />
  ),
  Group: BaseMenu.Group,
  GroupLabel: ({
    className,
    ...props
  }: ComponentProps<typeof BaseMenu.GroupLabel>) => (
    <BaseMenu.GroupLabel
      className={cn("px-2 py-1 text-xs text-(--ui-content-muted)", className)}
      {...props}
    />
  ),
  Separator: ({
    className,
    ...props
  }: ComponentProps<typeof BaseMenu.Separator>) => (
    <BaseMenu.Separator
      className={cn("my-1 h-px bg-(--ui-border)", className)}
      {...props}
    />
  ),
};
