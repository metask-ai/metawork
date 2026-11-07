import type {
  ScheduledTaskCalendarFrequency,
  ScheduledTaskRecurrence,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Menu } from "../../components/ui/menu.tsx";
import { cn, controlFocus } from "../../components/ui/utils.ts";
import { useI18n } from "../../i18n/context.ts";

type Kind = "once" | "interval" | ScheduledTaskCalendarFrequency;
type Translate = ReturnType<typeof useI18n>["t"];

export function calendarDays(
  rule: Extract<ScheduledTaskRecurrence, { kind: "calendar" }>,
): number[] {
  if (rule.days) return rule.days;
  if (rule.frequency !== "weekly" && rule.frequency !== "monthly") return [];
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: rule.timezone,
    weekday: "short",
    day: "numeric",
  }).formatToParts(new Date(Number(rule.startAtUnixSeconds) * 1000));
  return [
    rule.frequency === "monthly"
      ? Number(parts.find((part) => part.type === "day")!.value)
      : ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(
          parts.find((part) => part.type === "weekday")!.value,
        ) + 1,
  ];
}

export function formatRecurrence(kind: Kind, days: number[], t: Translate) {
  const label = t(`scheduled.recurrence.${kind}`);
  if (kind !== "weekly" && kind !== "monthly") return label;
  return `${label} ${days.map((day) => (kind === "weekly" ? t(`scheduled.weekday.${day as 1 | 2 | 3 | 4 | 5 | 6 | 7}`) : t("scheduled.monthday", { day }))).join(t("scheduled.day_separator"))}`;
}

export function ScheduleRecurrencePicker({
  value,
  weekdays,
  monthDays,
  legacyKind,
  onKindChange,
  onDaysChange,
}: {
  value: Kind;
  weekdays: number[];
  monthDays: number[];
  legacyKind?: Kind;
  onKindChange: (kind: Kind) => void;
  onDaysChange: (kind: "weekly" | "monthly", days: number[]) => void;
}) {
  const { t } = useI18n();
  return (
    <Menu.Root>
      <Menu.Trigger
        title={formatRecurrence(
          value,
          value === "weekly" ? weekdays : monthDays,
          t,
        )}
        aria-label={t("scheduled.repeat")}
        className={cn(
          "scheduled-time-select flex h-10 min-w-0 items-center gap-2 px-3 text-left border",
          controlFocus,
        )}
      >
        <span className="truncate">
          {t("scheduled.repeat")}:{" "}
          {formatRecurrence(
            value,
            value === "weekly" ? weekdays : monthDays,
            t,
          )}
        </span>
        <span className="ml-auto">
          <Icon name="chevron" />
        </span>
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner align="start">
          <Menu.Popup className="scheduled-editor-neutral">
            {(["once", "daily"] as const).map((kind) => (
              <Menu.Item key={kind} onClick={() => onKindChange(kind)}>
                <span className="flex-1">
                  {t(`scheduled.recurrence.${kind}`)}
                </span>
                {value === kind && <Icon name="check" />}
              </Menu.Item>
            ))}
            {(["weekly", "monthly"] as const).map((kind) => {
              const days = kind === "weekly" ? weekdays : monthDays;
              return (
                <Menu.SubmenuRoot
                  key={kind}
                  onOpenChange={(open) => {
                    if (open) onKindChange(kind);
                  }}
                >
                  <Menu.SubmenuTrigger openOnHover={false}>
                    <span className="flex-1">
                      {t(`scheduled.recurrence.${kind}`)}
                    </span>
                    <Icon name="chevron-right" />
                  </Menu.SubmenuTrigger>
                  <Menu.Portal>
                    <Menu.Positioner side="right" align="start">
                      <Menu.Popup
                        aria-label={t(`scheduled.recurrence.${kind}`)}
                        className="scheduled-editor-neutral max-h-[min(320px,var(--available-height))] overflow-y-auto"
                      >
                        {Array.from(
                          { length: kind === "weekly" ? 7 : 31 },
                          (_, i) => i + 1,
                        ).map((day) => {
                          const checked = days.includes(day);
                          return (
                            <Menu.CheckboxItem
                              key={day}
                              checked={checked}
                              disabled={checked && days.length === 1}
                              closeOnClick={false}
                              onCheckedChange={(next) => {
                                if (!next && days.length === 1) return;
                                onDaysChange(
                                  kind,
                                  (next
                                    ? [...days, day]
                                    : days.filter((value) => value !== day)
                                  ).sort((a, b) => a - b),
                                );
                              }}
                            >
                              <span className="flex-1">
                                {kind === "weekly"
                                  ? t(
                                      `scheduled.weekday.${day as 1 | 2 | 3 | 4 | 5 | 6 | 7}`,
                                    )
                                  : t("scheduled.monthday", { day })}
                              </span>
                              <Menu.CheckboxItemIndicator>
                                <Icon name="check" />
                              </Menu.CheckboxItemIndicator>
                            </Menu.CheckboxItem>
                          );
                        })}
                      </Menu.Popup>
                    </Menu.Positioner>
                  </Menu.Portal>
                </Menu.SubmenuRoot>
              );
            })}
            {legacyKind && (
              <Menu.Item onClick={() => onKindChange(legacyKind)}>
                {t(`scheduled.recurrence.${legacyKind}`)}
              </Menu.Item>
            )}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  );
}
