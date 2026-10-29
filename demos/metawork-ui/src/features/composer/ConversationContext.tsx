import type { TaskView } from "../../bridge/contracts.ts";
import { Popover } from "../../components/ui/popover.tsx";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";

export function ConversationContext({
  context,
}: {
  context: TaskView["context"];
}) {
  const { t, locale } = useI18n();
  const { pressure } = context;
  if (!pressure) return null;
  const warning = t(
    pressure.severity === "critical"
      ? "inspector.context_critical"
      : "inspector.context_warning",
  );
  const number = (value: string) => formatInteger(locale, BigInt(value));
  return (
    <div className="composer-context">
      <Popover.Root>
        <Popover.Trigger
          className="text-button focus-ring"
          data-severity={pressure.severity}
        >
          {warning}
        </Popover.Trigger>
        <Popover.Portal>
          <Popover.Positioner side="top" align="end">
            <Popover.Popup className="conversation-context-detail">
              <Popover.Title>{warning}</Popover.Title>
              <p className="projection-note">
                {t("conversation.context_observed")}
              </p>
              <p className="projection-note">
                {t("inspector.context_pressure_detail", {
                  current: number(pressure.currentTokens),
                  compact: number(pressure.autoCompactThreshold),
                  limit: number(pressure.blockingLimit),
                })}
              </p>
            </Popover.Popup>
          </Popover.Positioner>
        </Popover.Portal>
      </Popover.Root>
    </div>
  );
}
