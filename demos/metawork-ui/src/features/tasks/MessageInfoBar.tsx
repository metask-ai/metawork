import { CopyButton } from "../../components/ui/CopyButton.tsx";
import { Tooltip } from "../../components/ui/tooltip.tsx";
import { useI18n } from "../../i18n/context.ts";
import type { RunTimestamp } from "./run-presentation.ts";

export function MessageInfoBar({
  role,
  time,
  model,
  latest = false,
  onCopy,
}: {
  role: "user" | "assistant";
  time?: RunTimestamp | null;
  model?: string;
  latest?: boolean;
  onCopy: () => void | Promise<unknown>;
}) {
  const { t } = useI18n();
  const copy = (
    <CopyButton
      className="message-info-copy"
      copyLabel={t(role === "user" ? "copy.input" : "copy.response")}
      copiedLabel={t("copy.copied")}
      failedLabel={t("copy.failed")}
      onCopy={onCopy}
    />
  );
  const metadata =
    time || model ? (
      <span className="message-info-metadata">
        {time && (
          <Tooltip.Root>
            <Tooltip.Trigger
              render={
                <time
                  dateTime={time.dateTime}
                  aria-label={time.absolute}
                  tabIndex={0}
                />
              }
            >
              {time.relative}
            </Tooltip.Trigger>
            <Tooltip.Portal>
              <Tooltip.Positioner side="top">
                <Tooltip.Popup>{time.absolute}</Tooltip.Popup>
              </Tooltip.Positioner>
            </Tooltip.Portal>
          </Tooltip.Root>
        )}
        {time && model && <span aria-hidden="true">·</span>}
        {model && (
          <span className="message-info-model" dir="auto">
            {model}
          </span>
        )}
      </span>
    ) : null;
  return (
    <div className="message-info-bar" data-role={role} data-latest={latest}>
      {role === "user" ? metadata : copy}
      {role === "user" ? copy : metadata}
    </div>
  );
}
