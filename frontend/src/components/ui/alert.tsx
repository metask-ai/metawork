import type { HTMLAttributes } from "react";

import { cn } from "./utils.ts";

export function Alert({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div role="alert" className={cn("rounded-[8px] border border-(--ui-border) bg-(--ui-surface-panel) p-3 text-sm text-(--ui-content-primary)", className)} {...props} />;
}
