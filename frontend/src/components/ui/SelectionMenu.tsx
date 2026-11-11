import type { ReactNode, Ref } from "react";

import { Icon } from "./Icon.tsx";
import { Select } from "./select.tsx";

export type SelectionMenuOption = {
  value: string;
  label: string;
  triggerLabel?: string;
  groupLabel?: string;
  description?: string;
  descriptionKind?: "text" | "code";
  disabled?: boolean;
  leading?: ReactNode;
  trailing?: ReactNode;
};

export function SelectionMenu({
  value,
  options,
  triggerId,
  triggerRef,
  placeholder,
  ariaLabel,
  ariaInvalid = false,
  ariaDescribedBy,
  title,
  helper,
  actionLabel,
  disabled,
  busy = false,
  compact = false,
  valueLayout = "compact",
  leading,
  triggerClassName = "",
  contentClassName = "",
  onValueChange,
}: {
  value: string;
  options: SelectionMenuOption[];
  triggerId?: string;
  triggerRef?: Ref<HTMLButtonElement>;
  placeholder: string;
  ariaLabel: string;
  ariaInvalid?: boolean;
  ariaDescribedBy?: string;
  title?: string;
  helper?: string;
  actionLabel?: string;
  disabled: boolean;
  busy?: boolean;
  compact?: boolean;
  valueLayout?: "compact" | "detailed";
  leading?: ReactNode;
  triggerClassName?: string;
  contentClassName?: string;
  onValueChange: (value: string) => void;
}) {
  const selected = options.find((option) => option.value === value);
  const groups: { label?: string; options: SelectionMenuOption[] }[] = [];
  for (const option of options) {
    if (groups.length === 0 || option.groupLabel) {
      groups.push({ label: option.groupLabel, options: [] });
    }
    groups[groups.length - 1].options.push(option);
  }

  return (
    <Select.Root
      value={value}
      disabled={disabled}
      onValueChange={(nextValue) => {
        if (nextValue !== null) onValueChange(nextValue);
      }}
    >
      <Select.Trigger
        id={triggerId}
        ref={triggerRef}
        className={`selection-trigger ${triggerClassName}`.trim()}
        aria-label={ariaLabel}
        aria-invalid={ariaInvalid || undefined}
        aria-describedby={ariaDescribedBy}
        aria-busy={busy || undefined}
        data-busy={busy || undefined}
        data-layout={valueLayout}
        title={title}
      >
        {leading && (
          <span className="selection-trigger-leading">{leading}</span>
        )}
        <span className="selection-trigger-value-slot">
          <Select.Value
            placeholder={
              <span className="selection-trigger-value">{placeholder}</span>
            }
          >
            <span className="selection-trigger-copy">
              <span className="selection-trigger-value">
                {selected?.triggerLabel || selected?.label || placeholder}
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
        </span>
        {valueLayout === "detailed" && selected?.trailing && (
          <span className="selection-trigger-trailing">
            {selected.trailing}
          </span>
        )}
        {actionLabel && !busy && (
          <span className="selection-trigger-action" aria-hidden="true">
            {actionLabel}
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
        <Select.Positioner
          side="bottom"
          align="start"
          sideOffset={6}
          collisionPadding={12}
        >
          <Select.Popup
            className={`selection-menu-content ${contentClassName}`.trim()}
            data-compact={compact || undefined}
          >
            <Select.List className="selection-menu-viewport">
              {helper && <div className="selection-menu-label">{helper}</div>}
              {groups.map((group, index) => (
                <Select.Group key={index}>
                  {group.label && (
                    <Select.GroupLabel className="selection-menu-label">
                      {group.label}
                    </Select.GroupLabel>
                  )}
                  {group.options.map((option) => (
                    <Select.Item
                      key={option.value}
                      className="selection-menu-item focus-ring"
                      value={option.value}
                      disabled={option.disabled}
                      label={option.label}
                    >
                      <Select.ItemIndicator className="selection-menu-indicator">
                        <Icon name="check" />
                      </Select.ItemIndicator>
                      <span className="selection-menu-item-copy">
                        <span className="selection-menu-item-label">
                          {option.leading && (
                            <span className="selection-menu-item-leading">
                              {option.leading}
                            </span>
                          )}
                          <Select.ItemText>{option.label}</Select.ItemText>
                        </span>
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
              ))}
            </Select.List>
          </Select.Popup>
        </Select.Positioner>
      </Select.Portal>
    </Select.Root>
  );
}
