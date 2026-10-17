import { Tooltip as BaseTooltip } from "@base-ui/react/tooltip";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export const Tooltip = {
  Provider: BaseTooltip.Provider,
  Root: BaseTooltip.Root,
  Trigger: ({
    className,
    ...props
  }: ComponentProps<typeof BaseTooltip.Trigger>) => (
    <BaseTooltip.Trigger className={cn(focusRing, className)} {...props} />
  ),
  Portal: (props: ComponentProps<typeof BaseTooltip.Portal>) => (
    <BaseTooltip.Portal {...props} data-native-window-drag-exclude="" />
  ),
  Positioner: ({
    className,
    ...props
  }: ComponentProps<typeof BaseTooltip.Positioner>) => (
    <BaseTooltip.Positioner
      className={cn("z-50 outline-none", className)}
      sideOffset={6}
      {...props}
    />
  ),
  Popup: ({
    className,
    ...props
  }: ComponentProps<typeof BaseTooltip.Popup>) => (
    <BaseTooltip.Popup
      className={cn(
        "rounded-[6px] bg-(--ui-content-primary) px-2 py-1 text-xs text-(--ui-surface-panel) shadow-(--ui-shadow-overlay)",
        className,
      )}
      {...props}
    />
  ),
};
