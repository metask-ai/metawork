import type { ComponentPropsWithoutRef } from "react";

import { cn } from "../ui/utils.ts";

/**
 * AI-facing code and tool-output presentation primitive.
 *
 * This is deliberately a leaf: field labels belong to the surrounding
 * semantic field component, not to the code surface itself.
 */
export function CodeBlock({
  className,
  value,
  ...props
}: Omit<ComponentPropsWithoutRef<"pre">, "children"> & {
  value: string;
}) {
  return (
    <pre
      className={cn("code-block-preview", className)}
      tabIndex={0}
      {...props}
    >
      {value}
    </pre>
  );
}
