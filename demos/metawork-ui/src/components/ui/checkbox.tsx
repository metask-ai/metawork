import { Checkbox as BaseCheckbox } from "@base-ui/react/checkbox";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export const Checkbox = {
  Root: ({ className, ...props }: ComponentProps<typeof BaseCheckbox.Root>) => (
    <BaseCheckbox.Root
      className={cn(
        "flex size-4 shrink-0 items-center justify-center rounded-[4px] border border-(--ui-border) bg-(--ui-surface-panel) text-(--ui-content-on-primary) data-checked:border-(--ui-action-primary) data-checked:bg-(--ui-action-primary) data-indeterminate:border-(--ui-action-primary) data-indeterminate:bg-(--ui-action-primary)",
        focusRing,
        className,
      )}
      {...props}
    />
  ),
  Indicator: ({
    className,
    ...props
  }: ComponentProps<typeof BaseCheckbox.Indicator>) => (
    <BaseCheckbox.Indicator
      className={cn("text-xs leading-none", className)}
      {...props}
    />
  ),
};
