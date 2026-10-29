import type { ComponentProps } from "react";

import { cn } from "./utils.ts";

export function Separator({
  className,
  orientation = "horizontal",
  ...props
}: ComponentProps<"div"> & { orientation?: "horizontal" | "vertical" }) {
  return (
    <div
      role="separator"
      aria-orientation={orientation}
      className={cn(
        orientation === "horizontal" ? "h-px w-full" : "h-full w-px",
        "shrink-0 bg-(--ui-border)",
        className,
      )}
      {...props}
    />
  );
}
