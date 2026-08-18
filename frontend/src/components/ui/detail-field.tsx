import { useId, type HTMLAttributes, type ReactNode } from "react";

import { cn } from "./utils.ts";

export function DetailField({
  label,
  className,
  children,
  ...props
}: HTMLAttributes<HTMLDivElement> & {
  label: string;
  children: ReactNode;
}) {
  const labelId = useId();
  return (
    <div
      className={cn("detail-field", className)}
      role="group"
      aria-labelledby={labelId}
      {...props}
    >
      <p id={labelId} className="detail-field-label">
        {label}
      </p>
      {children}
    </div>
  );
}
