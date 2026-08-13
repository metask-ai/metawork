import type { HTMLAttributes } from "react";

import { cn } from "./utils.ts";

export function Spinner({
  className,
  ...props
}: HTMLAttributes<HTMLSpanElement>) {
  return (
    <span
      role="status"
      aria-label="Loading"
      className={cn(
        "inline-block size-4 animate-spin motion-reduce:animate-none rounded-full border-2 border-(--ui-border) border-t-(--ui-action-primary)",
        className,
      )}
      {...props}
    />
  );
}
