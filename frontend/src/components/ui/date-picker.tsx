import {
  useLayoutEffect,
  useRef,
  useState,
  type HTMLAttributes,
  type KeyboardEvent,
} from "react";

import { Button } from "./button.tsx";
import { Icon } from "./Icon.tsx";
import { Popover } from "./popover.tsx";
import {
  cn,
  controlFocus,
  pickerCaptionText,
  pickerControlText,
} from "./utils.ts";

type DatePickerProps = Pick<
  HTMLAttributes<HTMLDivElement>,
  "className" | "aria-label" | "aria-invalid" | "aria-describedby"
> & {
  value: string;
  today: string;
  locale: string;
  previousMonthLabel: string;
  nextMonthLabel: string;
  todayLabel: string;
  onValueChange: (value: string) => void;
};

// UTC day numbers keep calendar navigation independent of local clock changes.
const dayMs = 86_400_000;
const earliestDay = Date.parse("0001-01-01");
const latestDay = Date.parse("9999-12-31");

function shiftMonth(day: number, offset: number) {
  const date = new Date(day);
  const dayOfMonth = date.getUTCDate();
  date.setUTCDate(1);
  date.setUTCMonth(date.getUTCMonth() + offset + 1, 0);
  return date.setUTCDate(Math.min(dayOfMonth, date.getUTCDate()));
}

function dayAtKey(day: number, event: KeyboardEvent) {
  const weekday = (new Date(day).getUTCDay() + 6) % 7;
  switch (event.key) {
    case "ArrowLeft":
      return day - dayMs;
    case "ArrowRight":
      return day + dayMs;
    case "ArrowUp":
      return day - 7 * dayMs;
    case "ArrowDown":
      return day + 7 * dayMs;
    case "Home":
      return day - weekday * dayMs;
    case "End":
      return day + (6 - weekday) * dayMs;
    case "PageUp":
      return shiftMonth(day, event.shiftKey ? -12 : -1);
    case "PageDown":
      return shiftMonth(day, event.shiftKey ? 12 : 1);
    default:
      return null;
  }
}

export function DatePicker({
  value,
  today,
  locale,
  previousMonthLabel,
  nextMonthLabel,
  todayLabel,
  onValueChange,
  className,
  ...props
}: DatePickerProps) {
  const todayDay = Date.parse(today);
  const selectedDay = Date.parse(value);
  const [activeDay, setActiveDay] = useState(todayDay);
  const actions = useRef<{ close: () => void; unmount: () => void }>(null);
  const activeButton = useRef<HTMLButtonElement>(null);
  const focusActiveButton = useRef(false);

  useLayoutEffect(() => {
    if (!focusActiveButton.current) return;
    focusActiveButton.current = false;
    activeButton.current?.focus();
  }, [activeDay]);

  const calendarDate = new Date(activeDay);
  const month = calendarDate.getUTCMonth();
  calendarDate.setUTCDate(1);
  const firstVisibleDay =
    calendarDate.getTime() - ((calendarDate.getUTCDay() + 6) % 7) * dayMs;
  const fullDate = new Intl.DateTimeFormat(locale, {
    dateStyle: "full",
    timeZone: "UTC",
  });
  const shortDate = new Intl.DateTimeFormat(locale, {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone: "UTC",
  });
  const displayDate = Number.isFinite(selectedDay)
    ? shortDate.format(selectedDay)
    : "—";
  const heading = new Intl.DateTimeFormat(locale, {
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  }).format(calendarDate);
  const weekday = new Intl.DateTimeFormat(locale, {
    weekday: "short",
    timeZone: "UTC",
  });

  function select(day: number) {
    if (day < todayDay) return;
    if (day !== selectedDay)
      onValueChange(new Date(day).toISOString().slice(0, 10));
    actions.current?.close();
  }

  function navigate(event: KeyboardEvent<HTMLButtonElement>, day: number) {
    const next = dayAtKey(day, event);
    if (next === null) return;
    event.preventDefault();
    const boundedDay = Math.min(Math.max(next, earliestDay), latestDay);
    if (boundedDay === day) return;
    if (boundedDay === activeDay) {
      activeButton.current?.focus();
      return;
    }
    focusActiveButton.current = true;
    setActiveDay(boundedDay);
  }

  return (
    <Popover.Root
      actionsRef={actions}
      onOpenChange={(open) => {
        if (open)
          setActiveDay(Number.isFinite(selectedDay) ? selectedDay : todayDay);
      }}
    >
      <div role="group" className={cn(pickerControlText, className)} {...props}>
        <Popover.Trigger
          type="button"
          aria-label={
            props["aria-label"] && `${props["aria-label"]} ${displayDate}`
          }
          className={cn(
            "flex h-8 w-full min-w-0 items-center justify-between gap-2 rounded-[6px] border-0 bg-transparent px-1 hover:bg-(--ui-action-hover-surface)",
            controlFocus,
          )}
        >
          <span className="truncate">{displayDate}</span>
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
            initialFocus={activeButton}
            aria-label={props["aria-label"]}
            className={cn(
              "w-72 max-w-[var(--available-width)] max-h-[var(--available-height)] overflow-y-auto p-2",
              pickerControlText,
            )}
          >
            <div className="mb-1 flex items-center justify-between gap-1">
              <Button
                type="button"
                variant="ghost"
                size="icon"
                className="size-8"
                aria-label={previousMonthLabel}
                disabled={shiftMonth(activeDay, -1) < earliestDay}
                onClick={() => setActiveDay(shiftMonth(activeDay, -1))}
              >
                <span className="rotate-180">
                  <Icon name="chevron-right" />
                </span>
              </Button>
              <div aria-live="polite" className={pickerCaptionText}>
                {heading}
              </div>
              <Button
                type="button"
                variant="ghost"
                size="icon"
                className="size-8"
                aria-label={nextMonthLabel}
                disabled={shiftMonth(activeDay, 1) > latestDay}
                onClick={() => setActiveDay(shiftMonth(activeDay, 1))}
              >
                <Icon name="chevron-right" />
              </Button>
            </div>
            <table
              role="grid"
              aria-label={heading}
              className="w-full table-fixed border-separate border-spacing-0.5"
            >
              <thead>
                <tr>
                  {Array.from({ length: 7 }, (_, index) => (
                    <th
                      key={index}
                      scope="col"
                      className={cn(
                        "pb-1 text-center text-(--ui-content-muted)",
                        pickerCaptionText,
                      )}
                    >
                      {weekday.format(firstVisibleDay + index * dayMs)}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {Array.from({ length: 6 }, (_, week) => (
                  <tr key={week}>
                    {Array.from({ length: 7 }, (_, weekday) => {
                      const day =
                        firstVisibleDay + (week * 7 + weekday) * dayMs;
                      if (day < earliestDay || day > latestDay)
                        return <td key={day} />;
                      const date = new Date(day);
                      return (
                        <td key={day} aria-selected={day === selectedDay}>
                          <button
                            type="button"
                            ref={day === activeDay ? activeButton : undefined}
                            tabIndex={day === activeDay ? 0 : -1}
                            aria-label={fullDate.format(day)}
                            aria-current={day === todayDay ? "date" : undefined}
                            aria-disabled={day < todayDay || undefined}
                            data-outside-month={
                              date.getUTCMonth() !== month || undefined
                            }
                            data-selected={day === selectedDay || undefined}
                            onKeyDown={(event) => navigate(event, day)}
                            onClick={() => select(day)}
                            className={cn(
                              "flex h-8 w-full items-center justify-center rounded-[6px] border-0 bg-transparent hover:bg-(--ui-action-hover-surface) data-outside-month:text-(--ui-content-muted) data-selected:bg-(--ui-surface-panel-2) aria-[current=date]:ring-1 aria-[current=date]:ring-inset aria-[current=date]:ring-(--ui-border) aria-disabled:opacity-40 aria-disabled:hover:bg-transparent",
                              controlFocus,
                            )}
                          >
                            {date.getUTCDate()}
                          </button>
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="mt-1 flex justify-end border-t border-(--ui-border) pt-1">
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onClick={() => select(todayDay)}
              >
                {todayLabel}
              </Button>
            </div>
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}
