import { Combobox as BaseCombobox } from "@base-ui/react/combobox";
import type { ComponentProps } from "react";

import { cn, controlBase, focusRing } from "./utils.ts";

export const Combobox = {
  Root: BaseCombobox.Root,
  Label: ({
    className,
    ...props
  }: ComponentProps<typeof BaseCombobox.Label>) => (
    <BaseCombobox.Label
      className={cn(
        "text-sm font-medium text-(--ui-content-primary)",
        className,
      )}
      {...props}
    />
  ),
  InputGroup: ({
    className,
    ...props
  }: ComponentProps<typeof BaseCombobox.InputGroup>) => (
    <BaseCombobox.InputGroup
      className={cn(
        "relative flex h-9 w-full items-center rounded-[7px] data-focused:outline-2 data-focused:outline-offset-2 data-focused:outline-(--ui-focus-ring)",
        controlBase,
        className,
      )}
      {...props}
    />
  ),
  Input: ({
    className,
    ...props
  }: ComponentProps<typeof BaseCombobox.Input>) => (
    <BaseCombobox.Input
      className={cn(
        "h-full min-w-0 flex-1 bg-transparent px-3 text-sm outline-none",
        focusRing,
        className,
      )}
      {...props}
    />
  ),
  Trigger: ({
    className,
    children,
    ...props
  }: ComponentProps<typeof BaseCombobox.Trigger>) => (
    <BaseCombobox.Trigger
      className={cn(
        "flex size-8 items-center justify-center text-xs text-(--ui-content-muted)",
        focusRing,
        className,
      )}
      {...props}
    >
      {children ?? "⌄"}
    </BaseCombobox.Trigger>
  ),
  Clear: ({
    className,
    children,
    ...props
  }: ComponentProps<typeof BaseCombobox.Clear>) => (
    <BaseCombobox.Clear
      className={cn(
        "flex size-8 items-center justify-center text-xs text-(--ui-content-muted)",
        focusRing,
        className,
      )}
      {...props}
    >
      {children ?? "×"}
    </BaseCombobox.Clear>
  ),
  Portal: (props: ComponentProps<typeof BaseCombobox.Portal>) => (
    <BaseCombobox.Portal {...props} data-native-window-drag-exclude="" />
  ),
  Positioner: ({
    className,
    ...props
  }: ComponentProps<typeof BaseCombobox.Positioner>) => (
    <BaseCombobox.Positioner
      className={cn("z-50 outline-none", className)}
      sideOffset={4}
      {...props}
    />
  ),
  Popup: ({
    className,
    ...props
  }: ComponentProps<typeof BaseCombobox.Popup>) => (
    <BaseCombobox.Popup
      className={cn(
        "w-(--anchor-width) max-w-(--available-width) rounded-[7px] border border-(--ui-border) bg-(--ui-surface-panel) p-1 text-sm text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none",
        className,
      )}
      {...props}
    />
  ),
  List: ({ className, ...props }: ComponentProps<typeof BaseCombobox.List>) => (
    <BaseCombobox.List
      className={cn(
        "max-h-[var(--available-height)] overflow-y-auto",
        className,
      )}
      {...props}
    />
  ),
  Empty: ({
    className,
    ...props
  }: ComponentProps<typeof BaseCombobox.Empty>) => (
    <BaseCombobox.Empty
      className={cn("px-2 py-3 text-xs text-(--ui-content-muted)", className)}
      {...props}
    />
  ),
  Item: ({ className, ...props }: ComponentProps<typeof BaseCombobox.Item>) => (
    <BaseCombobox.Item
      className={cn(
        "flex min-h-8 cursor-default items-center rounded-[5px] px-2 py-1.5 outline-none data-highlighted:bg-(--ui-action-hover-surface) data-highlighted:text-(--ui-action-hover-content) data-disabled:pointer-events-none data-disabled:opacity-40",
        className,
      )}
      {...props}
    />
  ),
  ItemIndicator: ({
    className,
    ...props
  }: ComponentProps<typeof BaseCombobox.ItemIndicator>) => (
    <BaseCombobox.ItemIndicator
      className={cn("mr-2 text-(--ui-action-primary)", className)}
      {...props}
    >
      ✓
    </BaseCombobox.ItemIndicator>
  ),
};
