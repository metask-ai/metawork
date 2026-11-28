import { useLayoutEffect, useRef, type HTMLAttributes } from "react";
import { Radio } from "@base-ui/react/radio";
import { RadioGroup } from "@base-ui/react/radio-group";

import { Icon } from "./Icon.tsx";
import { Popover } from "./popover.tsx";
import {
  cn,
  controlBase,
  controlFocus,
  pickerCaptionText,
  pickerControlText,
} from "./utils.ts";

type TimePickerOptionsProps = {
  value: string;
  onValueChange: (value: string) => void;
  hourLabel: string;
  minuteLabel: string;
  disabled?: boolean;
};

type TimePickerProps = Pick<
  HTMLAttributes<HTMLDivElement>,
  "className" | "aria-label" | "aria-invalid" | "aria-describedby"
> &
  TimePickerOptionsProps;

function TimeColumn({
  value,
  count,
  label,
  disabled,
  onValueChange,
}: {
  value: string;
  count: number;
  label: string;
  disabled: boolean;
  onValueChange: (value: string) => void;
}) {
  const list = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const element = list.current;
    const selected = element?.querySelector<HTMLElement>(
      '[role="radio"][aria-checked="true"]',
    );
    if (element && selected) {
      element.scrollTop =
        selected.offsetTop - (element.clientHeight - selected.offsetHeight) / 2;
    }
  }, []);

  return (
    <div className="min-w-0">
      <div
        aria-hidden="true"
        className={cn(
          "pb-1 text-center text-(--ui-content-muted)",
          pickerCaptionText,
        )}
      >
        {label}
      </div>
      <RadioGroup
        ref={list}
        aria-label={label}
        value={value}
        onValueChange={onValueChange}
        disabled={disabled}
        className="ui-time-picker-scroll relative h-56 max-h-[calc(var(--available-height)-40px)] overflow-y-auto overscroll-contain"
      >
        {Array.from({ length: count }, (_, number) => {
          const part = String(number).padStart(2, "0");
          return (
            <Radio.Root
              key={part}
              value={part}
              nativeButton
              render={<button type="button" />}
              className="flex h-8 w-full items-center justify-center rounded-[6px] border-0 bg-transparent outline-none hover:bg-(--ui-action-hover-surface) focus-visible:bg-(--ui-action-hover-surface) data-checked:bg-(--ui-surface-panel-2)"
            >
              {part}
            </Radio.Root>
          );
        })}
      </RadioGroup>
    </div>
  );
}

export function TimePickerOptions({
  value,
  onValueChange,
  hourLabel,
  minuteLabel,
  disabled = false,
}: TimePickerOptionsProps) {
  const parts = value.split(":");
  return (
    <div className="grid grid-cols-2 gap-2">
      {[hourLabel, minuteLabel].map((label, index) => (
        <TimeColumn
          key={index}
          value={parts[index] || ""}
          count={index === 0 ? 24 : 60}
          label={label}
          disabled={disabled}
          onValueChange={(next) => {
            const updated = [parts[0] || "00", parts[1] || "00"];
            updated[index] = next;
            onValueChange(updated.join(":"));
          }}
        />
      ))}
    </div>
  );
}

export function TimePicker({
  value,
  onValueChange,
  hourLabel,
  minuteLabel,
  disabled = false,
  className,
  ...props
}: TimePickerProps) {
  const popup = useRef<HTMLDivElement>(null);
  return (
    <Popover.Root>
      <div
        role="group"
        className={cn(
          "inline-flex h-9 min-w-0 items-center rounded-[7px] px-2 data-disabled:opacity-50",
          pickerControlText,
          controlBase,
          controlFocus,
          className,
        )}
        data-disabled={disabled || undefined}
        {...props}
      >
        <Popover.Trigger
          type="button"
          disabled={disabled}
          aria-label={
            props["aria-label"]
              ? `${props["aria-label"]} ${value || "--:--"}`
              : undefined
          }
          className={cn(
            "flex h-8 w-full min-w-0 items-center justify-between gap-2 rounded-[6px] border-0 bg-transparent px-1 hover:bg-(--ui-action-hover-surface)",
            controlFocus,
          )}
        >
          <span>{value || "--:--"}</span>
          <Icon name="chevron" />
        </Popover.Trigger>
      </div>
      <Popover.Portal>
        <Popover.Positioner
          side="bottom"
          align="start"
          collisionPadding={12}
          className="z-[120]"
        >
          <Popover.Popup
            ref={popup}
            initialFocus={() =>
              popup.current?.querySelector<HTMLButtonElement>(
                '[role="radio"][aria-checked="true"]',
              ) ?? null
            }
            aria-label={props["aria-label"]}
            className={cn("w-48 p-2", pickerControlText)}
          >
            <TimePickerOptions
              value={value}
              hourLabel={hourLabel}
              minuteLabel={minuteLabel}
              disabled={disabled}
              onValueChange={onValueChange}
            />
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}
