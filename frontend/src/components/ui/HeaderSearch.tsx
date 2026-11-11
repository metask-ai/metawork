import { useRef } from "react";

import { Icon } from "./Icon.tsx";
import { Input } from "./input.tsx";
import { Popover } from "./popover.tsx";
import { cn, controlFocus } from "./utils.ts";

export function HeaderSearch({
  label,
  clearLabel,
  value,
  onChange,
}: {
  label: string;
  clearLabel: string;
  value: string;
  onChange: (value: string) => void;
}) {
  const searchInput = useRef<HTMLInputElement>(null);
  return (
    <Popover.Root>
      <Popover.Trigger
        className="icon-button header-search-trigger"
        aria-label={label}
        title={label}
        data-active={value.trim() ? "true" : undefined}
      >
        <Icon name="search" />
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner side="left" align="center" sideOffset={-32}>
          <Popover.Popup
            aria-label={label}
            initialFocus={() => searchInput.current}
            className={cn(
              "w-[min(180px,calc(100vw-32px))] p-0 shadow-none",
              controlFocus,
            )}
          >
            <div className="header-search">
              <Icon name="search" />
              <Input
                ref={searchInput}
                type="search"
                aria-label={label}
                value={value}
                placeholder={label}
                onChange={(event) => onChange(event.target.value)}
              />
              {value && (
                <button
                  type="button"
                  className="focus-ring"
                  aria-label={clearLabel}
                  onClick={() => {
                    onChange("");
                    searchInput.current?.focus();
                  }}
                >
                  <Icon name="close" />
                </button>
              )}
            </div>
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}
