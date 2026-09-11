import type { RunFileChanges } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";

export function RunFileChangesSummary({
  fileChanges,
  onReview,
}: {
  fileChanges: RunFileChanges;
  onReview: (opener: HTMLButtonElement) => void;
}) {
  const { locale, t } = useI18n();
  const uniqueFiles = new Set(
    fileChanges.changes.map((change) => change.displayPath),
  ).size;
  if (
    fileChanges.changes.length === 0 &&
    fileChanges.observation !== "incomplete"
  )
    return null;

  const fileCount = formatInteger(locale, BigInt(uniqueFiles));
  const fileCountMessage = t(
    uniqueFiles === 1
      ? "file_changes.file_count.one"
      : "file_changes.file_count.other",
    { fileCount },
  );
  const incomplete = fileChanges.observation === "incomplete";

  if (fileChanges.changes.length === 0) {
    return (
      <p
        className="flex min-h-11 items-center gap-2 px-2 text-xs text-(--ui-content-warning)"
        role="status"
      >
        <span className="text-base" aria-hidden="true">
          <Icon name="warning" />
        </span>
        <span>{t("file_changes.incomplete_empty")}</span>
      </p>
    );
  }

  return (
    <Button
      type="button"
      variant="ghost"
      size="lg"
      className="h-11 w-full justify-start gap-2 px-2 text-left"
      onClick={(event) => onReview(event.currentTarget)}
    >
      <span className="text-base text-(--ui-content-muted)" aria-hidden="true">
        <Icon name="file-diff" />
      </span>
      <span className="min-w-0 flex flex-1 items-center gap-1.5 text-sm">
        <span className="font-medium text-(--ui-content-primary)">
          {t("file_changes.title")}
        </span>
        <span className="text-(--ui-content-muted)" aria-hidden="true">
          ·
        </span>
        <span className="shrink-0 font-normal text-(--ui-content-muted)">
          {fileCountMessage}
        </span>
        {incomplete && (
          <span className="flex min-w-0 items-center gap-1.5 font-normal text-(--ui-content-warning)">
            <span aria-hidden="true">·</span>
            <span className="truncate">
              {t("file_changes.incomplete_label")}
            </span>
          </span>
        )}
      </span>
      <span className="flex shrink-0 items-center gap-1 text-xs font-medium text-(--ui-content-primary)">
        {t("file_changes.review")}
        <span aria-hidden="true">
          <Icon name="chevron-right" />
        </span>
      </span>
    </Button>
  );
}
