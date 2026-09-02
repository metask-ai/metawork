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
  onReview: () => void;
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
  const changeCount = formatInteger(locale, BigInt(fileChanges.changes.length));
  const incomplete = fileChanges.observation === "incomplete";

  return (
    <section
      className="ml-11 flex min-h-12 items-center gap-3 border-l-2 border-(--ui-border) py-1 pl-3"
      aria-label={t("file_changes.title")}
    >
      <span
        className="grid size-8 shrink-0 place-items-center rounded-lg bg-(--ui-action-selected-surface) text-(--ui-action-selected-content)"
        aria-hidden="true"
      >
        <Icon name="file-diff" />
      </span>
      <span className="min-w-0 flex-1">
        <strong className="block text-sm font-medium text-(--ui-content-primary)">
          {t("file_changes.title")}
        </strong>
        <span className="block truncate text-xs text-(--ui-content-muted)">
          {fileChanges.changes.length === 0
            ? t("file_changes.incomplete_empty")
            : incomplete
              ? t("file_changes.summary_incomplete", { fileCount })
              : t("file_changes.summary", { fileCount, changeCount })}
        </span>
      </span>
      {fileChanges.changes.length > 0 && (
        <Button type="button" variant="ghost" size="sm" onClick={onReview}>
          {t("file_changes.review")}
          <Icon name="chevron-right" />
        </Button>
      )}
    </section>
  );
}
