import { Switch as BaseSwitch } from "@base-ui/react/switch";
import type { ComponentProps } from "react";

import { cn, focusRing } from "./utils.ts";

export const Switch = {
  Root: ({ className, ...props }: ComponentProps<typeof BaseSwitch.Root>) => (
    <BaseSwitch.Root
      className={cn(
        "relative flex h-5 w-9 shrink-0 rounded-full bg-(--ui-border) p-0.5 transition-colors data-checked:bg-(--ui-action-primary) disabled:opacity-50",
        focusRing,
        className,
      )}
      {...props}
    />
  ),
  Thumb: ({ className, ...props }: ComponentProps<typeof BaseSwitch.Thumb>) => (
    <BaseSwitch.Thumb className={cn("size-4 rounded-full bg-(--ui-control-thumb) transition-transform data-checked:translate-x-4", className)} {...props} />
  ),
};
