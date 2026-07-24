import * as Select from "@radix-ui/react-select";
import type { ReactNode } from "react";

import { Icon } from "./Icon.tsx";

export type SelectionMenuOption = {
  value: string;
  label: string;
  description?: string;
  descriptionKind?: "text" | "code";
  disabled?: boolean;
  trailing?: ReactNode;
};

export function SelectionMenu({
  value,
  options,
  placeholder,
  ariaLabel,
  title,
  helper,
  disabled,
  busy = false,
  valueLayout = "compact",
  leading,
  triggerClassName = "",
  contentClassName = "",
  onValueChange,
}: {
  value: string;
  options: SelectionMenuOption[];
  placeholder: string;
  ariaLabel: string;
  title?: string;
  helper?: string;
  disabled: boolean;
  busy?: boolean;
  valueLayout?: "compact" | "detailed";
  leading?: ReactNode;
  triggerClassName?: string;
  contentClassName?: string;
  onValueChange: (value: string) => void;
}) {
  const selected = options.find((option) => option.value === value);

  return (
    <Select.Root
      value={value}
      disabled={disabled}
      onValueChange={onValueChange}
    >
      <Select.Trigger
        className={`selection-trigger focus-ring ${triggerClassName}`.trim()}
        aria-label={ariaLabel}
        aria-busy={busy || undefined}
        data-busy={busy || undefined}
        data-layout={valueLayout}
        title={title}
      >
        {leading && (
          <span className="selection-trigger-leading">{leading}</span>
        )}
        <Select.Value
          className="selection-trigger-value-slot"
          placeholder={placeholder}
        >
          <span className="selection-trigger-copy">
            <span className="selection-trigger-value">
              {selected?.label || placeholder}
            </span>
            {valueLayout === "detailed" && selected?.description && (
              <small
                className="selection-trigger-detail"
                data-kind={selected.descriptionKind ?? "code"}
                title={selected.description}
              >
                {selected.description}
              </small>
            )}
          </span>
        </Select.Value>
        {valueLayout === "detailed" && selected?.trailing && (
          <span className="selection-trigger-trailing">
            {selected.trailing}
          </span>
        )}
        {busy ? (
          <span className="selection-trigger-busy" aria-hidden="true" />
        ) : (
          <Select.Icon className="selection-trigger-chevron">
            <Icon name="chevron" />
          </Select.Icon>
        )}
      </Select.Trigger>
      <Select.Portal>
        <Select.Content
          className={`selection-menu-content ${contentClassName}`.trim()}
          position="popper"
          side="bottom"
          align="start"
          sideOffset={6}
          collisionPadding={12}
        >
          <Select.ScrollUpButton className="selection-menu-scroll">
            <Icon name="chevron" />
          </Select.ScrollUpButton>
          <Select.Viewport className="selection-menu-viewport">
            <Select.Group>
              {helper && (
                <Select.Label className="selection-menu-label">
                  {helper}
                </Select.Label>
              )}
              {options.map((option) => (
                <Select.Item
                  key={option.value}
                  className="selection-menu-item focus-ring"
                  value={option.value}
                  disabled={option.disabled}
                  textValue={option.label}
                >
                  <Select.ItemIndicator className="selection-menu-indicator">
                    <Icon name="check" />
                  </Select.ItemIndicator>
                  <span className="selection-menu-item-copy">
                    <Select.ItemText>{option.label}</Select.ItemText>
                    {option.description && (
                      <small
                        data-kind={option.descriptionKind ?? "code"}
                        title={option.description}
                      >
                        {option.description}
                      </small>
                    )}
                  </span>
                  {option.trailing && (
                    <span className="selection-menu-item-trailing">
                      {option.trailing}
                    </span>
                  )}
                </Select.Item>
              ))}
            </Select.Group>
          </Select.Viewport>
          <Select.ScrollDownButton className="selection-menu-scroll is-down">
            <Icon name="chevron" />
          </Select.ScrollDownButton>
        </Select.Content>
      </Select.Portal>
    </Select.Root>
  );
}
