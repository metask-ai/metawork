import type { ComponentProps } from "react";

import { Icon } from "./Icon.tsx";
import { cn, controlFocus } from "./utils.ts";

export type SearchFieldProps = ComponentProps<"input"> & {
  /** Accessible name for the search input. */
  label: string;
};

// Framed search input shared by management surfaces. The container owns the
// frame and focus formula; consumers adjust width through className utilities.
export function SearchField({ className, label, ...props }: SearchFieldProps) {
  return (
    <label
      className={cn(
        "grid h-[38px] min-w-0 grid-cols-[auto_minmax(0,1fr)] items-center gap-2 rounded-[10px] border border-(--ui-border) bg-[color-mix(in_srgb,var(--ui-surface-panel)_72%,transparent)] px-3 text-(--ui-content-muted) transition-colors duration-120",
        controlFocus,
        className,
      )}
    >
      <Icon name="search" />
      <span className="sr-only">{label}</span>
      <input
        type="search"
        className="h-9 w-full min-w-0 border-0 bg-transparent text-sm text-(--ui-content-primary) outline-none placeholder:text-(--ui-content-muted)"
        {...props}
      />
    </label>
  );
}
