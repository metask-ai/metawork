import { Select as BaseSelect } from "@base-ui/react/select";
import type { ComponentProps, ReactNode } from "react";

import { Icon } from "./Icon.tsx";
import { cn, controlBase, controlFocus } from "./utils.ts";

export type SelectOption = {
  value: string;
  label: ReactNode;
  disabled?: boolean;
};

export function SelectField({
  value,
  options,
  placeholder,
  disabled,
  className,
  onValueChange,
  "aria-label": ariaLabel,
}: {
  value: string;
  options: SelectOption[];
  placeholder?: ReactNode;
  disabled?: boolean;
  className?: string;
  onValueChange: (value: string) => void;
  "aria-label"?: string;
}) {
  return (
    <Select.Root
      value={value}
      disabled={disabled}
      onValueChange={(nextValue) => {
        if (nextValue !== null) onValueChange(nextValue);
      }}
    >
      <Select.Trigger className={className} aria-label={ariaLabel}>
        <Select.Value placeholder={placeholder}>
          {options.find((option) => option.value === value)?.label}
        </Select.Value>
        <Select.Icon>
          <Icon name="chevron" />
        </Select.Icon>
      </Select.Trigger>
      <Select.Portal>
        <Select.Positioner>
          <Select.Popup>
            <Select.List>
              {options.map((option) => (
                <Select.Item
                  key={option.value}
                  value={option.value}
                  disabled={option.disabled}
                >
                  <Select.ItemText>{option.label}</Select.ItemText>
                  <Select.ItemIndicator>✓</Select.ItemIndicator>
                </Select.Item>
              ))}
            </Select.List>
          </Select.Popup>
        </Select.Positioner>
      </Select.Portal>
    </Select.Root>
  );
}

export const Select = {
  Root: BaseSelect.Root,
  Trigger: ({
    className,
    children,
    ...props
  }: ComponentProps<typeof BaseSelect.Trigger>) => (
    <BaseSelect.Trigger
      className={cn(
        "flex h-9 w-full items-center justify-between gap-2 rounded-[7px] px-3 text-sm",
        controlBase,
        controlFocus,
        className,
      )}
      {...props}
    >
      {children}
    </BaseSelect.Trigger>
  ),
  Value: BaseSelect.Value,
  Icon: BaseSelect.Icon,
  Portal: (props: ComponentProps<typeof BaseSelect.Portal>) => (
    <BaseSelect.Portal {...props} data-native-window-drag-exclude="" />
  ),
  Positioner: ({
    className,
    ...props
  }: ComponentProps<typeof BaseSelect.Positioner>) => (
    <BaseSelect.Positioner
      className={cn("z-[120] outline-none", className)}
      sideOffset={4}
      {...props}
    />
  ),
  Popup: ({ className, ...props }: ComponentProps<typeof BaseSelect.Popup>) => (
    <BaseSelect.Popup
      className={cn(
        "max-h-[var(--available-height)] min-w-[var(--anchor-width)] overflow-y-auto rounded-[7px] border border-(--ui-border) bg-(--ui-surface-panel) p-1 text-sm text-(--ui-content-primary) shadow-(--ui-shadow-overlay) outline-none",
        className,
      )}
      {...props}
    />
  ),
  List: BaseSelect.List,
  Group: BaseSelect.Group,
  GroupLabel: ({
    className,
    ...props
  }: ComponentProps<typeof BaseSelect.GroupLabel>) => (
    <BaseSelect.GroupLabel
      className={cn("px-2 py-1 text-xs text-(--ui-content-muted)", className)}
      {...props}
    />
  ),
  Item: ({
    className,
    children,
    ...props
  }: ComponentProps<typeof BaseSelect.Item>) => (
    <BaseSelect.Item
      className={cn(
        "relative flex min-h-8 cursor-default items-center rounded-[5px] px-2 py-1.5 outline-none data-highlighted:bg-(--ui-action-hover-surface) data-highlighted:text-(--ui-action-hover-content) data-disabled:pointer-events-none data-disabled:opacity-40",
        className,
      )}
      {...props}
    >
      {children}
    </BaseSelect.Item>
  ),
  ItemText: BaseSelect.ItemText,
  ItemIndicator: ({
    className,
    ...props
  }: ComponentProps<typeof BaseSelect.ItemIndicator>) => (
    <BaseSelect.ItemIndicator
      className={cn("absolute right-2 text-(--ui-action-primary)", className)}
      {...props}
    >
      ✓
    </BaseSelect.ItemIndicator>
  ),
};
