import type { LabelHTMLAttributes } from "react";

import { cn } from "./utils.ts";

export function Label({ className, ...props }: LabelHTMLAttributes<HTMLLabelElement>) {
  return <label className={cn("text-sm font-medium text-(--ui-content-primary)", className)} {...props} />;
}
