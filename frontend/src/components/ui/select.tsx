import { Select as BaseSelect } from "@base-ui/react/select";
import type { ComponentProps, ReactNode } from "react";

import { cn, controlBase, focusRing } from "./utils.ts";

export type SelectOption = {
  value: string;
  label: ReactNode;
  disabled?: boolean;
};

export const Select = {
  Root: BaseSelect.Root,
  Trigger: ({
    className,
    children,
    ...props
  }: ComponentProps<typeof BaseSelect.Trigger>) => (
    <BaseSelect.Trigger
      className={cn(
        "flex h-9 w-full items-center justify-between gap-2 rounded-[7px] px-3 text-sm",
        controlBase,
        focusRing,
        className,
      )}
      {...props}
    >
      {children}
    </BaseSelect.Trigger>
  ),
  Value: BaseSelect.Value,
  Icon: BaseSelect.Icon,
  Portal: BaseSelect.Portal,
  Positioner: ({
    className,
    ...props
  }: ComponentProps<typeof BaseSelect.Positioner>) => (
    <BaseSelect.Positioner
      className={cn("z-50 outline-none", className)}
      sideOffset={4}
      {...props}
    />
  ),
  Popup: ({ className, ...props }: ComponentProps<typeof BaseSelect.Popup>) => (
    <BaseSelect.Popup
      className={cn(
        "max-h-[var(--available-height)] min-w-[var(--anchor-width)] overflow-y-auto rounded-[7px] border border-(--ui-border) bg-(--ui-surface-panel) p-1 text-sm text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none",
        className,
      )}
      {...props}
    />
  ),
  List: BaseSelect.List,
  Group: BaseSelect.Group,
  GroupLabel: ({
    className,
    ...props
  }: ComponentProps<typeof BaseSelect.GroupLabel>) => (
    <BaseSelect.GroupLabel
      className={cn("px-2 py-1 text-xs text-(--ui-content-muted)", className)}
      {...props}
    />
  ),
  Item: ({
    className,
    children,
    ...props
  }: ComponentProps<typeof BaseSelect.Item>) => (
    <BaseSelect.Item
      className={cn(
        "relative flex min-h-8 cursor-default items-center rounded-[5px] px-2 py-1.5 outline-none data-highlighted:bg-(--metask-primary-soft) data-highlighted:text-(--metask-primary-deep) data-disabled:pointer-events-none data-disabled:opacity-40",
        className,
      )}
      {...props}
    >
      {children}
    </BaseSelect.Item>
  ),
  ItemText: BaseSelect.ItemText,
  ItemIndicator: ({
    className,
    ...props
  }: ComponentProps<typeof BaseSelect.ItemIndicator>) => (
    <BaseSelect.ItemIndicator
      className={cn("absolute right-2 text-(--ui-action-primary)", className)}
      {...props}
    >
      ✓
    </BaseSelect.ItemIndicator>
  ),
};
