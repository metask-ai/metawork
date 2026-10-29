import type { ComponentPropsWithoutRef } from "react";

import { CopyButton } from "../ui/CopyButton.tsx";
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
  copy,
  ...props
}: Omit<ComponentPropsWithoutRef<"pre">, "children"> & {
  value: string;
  copy?: {
    label: string;
    copiedLabel: string;
    failedLabel: string;
    onCopy: (value: string) => void | Promise<unknown>;
  };
}) {
  const code = (
    <pre
      className={cn("code-block-preview", className)}
      tabIndex={0}
      {...props}
    >
      {value}
    </pre>
  );
  if (!copy) return code;
  return (
    <div className="code-block-copyable">
      <CopyButton
        className="code-block-copy-action"
        copyLabel={copy.label}
        copiedLabel={copy.copiedLabel}
        failedLabel={copy.failedLabel}
        onCopy={() => copy.onCopy(value)}
      />
      {code}
    </div>
  );
}
