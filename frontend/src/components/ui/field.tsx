import { Field as BaseField } from "@base-ui/react/field";
import type { ComponentProps } from "react";

import { cn, controlBase, focusRing } from "./utils.ts";

export const Field = {
  Root: ({ className, ...props }: ComponentProps<typeof BaseField.Root>) => (
    <BaseField.Root className={cn("flex w-full flex-col gap-1.5", className)} {...props} />
  ),
  Label: ({ className, ...props }: ComponentProps<typeof BaseField.Label>) => (
    <BaseField.Label className={cn("text-sm font-medium text-(--ui-content-primary)", className)} {...props} />
  ),
  Control: ({ className, ...props }: ComponentProps<typeof BaseField.Control>) => (
    <BaseField.Control className={cn("h-9 rounded-[7px] px-3 text-sm", controlBase, focusRing, className)} {...props} />
  ),
  Description: ({ className, ...props }: ComponentProps<typeof BaseField.Description>) => (
    <BaseField.Description className={cn("text-xs text-(--ui-content-muted)", className)} {...props} />
  ),
  Error: ({ className, ...props }: ComponentProps<typeof BaseField.Error>) => (
    <BaseField.Error className={cn("text-xs text-(--ui-content-error)", className)} {...props} />
  ),
};
