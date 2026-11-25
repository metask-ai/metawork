import { useMemo, type RefObject } from "react";
import { Popover } from "../../components/ui/popover.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import {
  AttachmentThumbnail,
  type AttachmentThumbnailLoader,
} from "../../components/AttachmentThumbnail.tsx";
import type { MediaTarget } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";
import type { ConversationFile } from "./conversation-files.ts";

export function ConversationFilePicker({
  files: getFiles,
  anchor,
  textareaRef,
  onClose,
  onChoose,
  onLoadEarlier,
  loading,
  loadThumbnail,
}: {
  files: () => readonly ConversationFile[];
  anchor: RefObject<HTMLButtonElement | null>;
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  onClose: () => void;
  onChoose: (file: ConversationFile, detail: string) => void;
  onLoadEarlier?: () => void;
  loading?: boolean;
  loadThumbnail?: AttachmentThumbnailLoader<MediaTarget>;
}) {
  const { t, locale } = useI18n();
  const files = useMemo(getFiles, [getFiles]);
  const dateFormat = useMemo(
    () =>
      new Intl.DateTimeFormat(locale === "pseudo" ? "en-US" : locale, {
        year: "numeric",
        month: "short",
        day: "numeric",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      }),
    [locale],
  );
  return (
    <Popover.Root
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Popover.Portal>
        <Popover.Positioner anchor={anchor} side="top" align="start">
          <Popover.Popup
            finalFocus={textareaRef}
            className="w-[min(22rem,calc(100vw-2rem))] p-1"
          >
            <Popover.Title className="px-3 py-2">
              {t("composer.reference_files")}
            </Popover.Title>
            <div className="max-h-[min(20rem,50vh)] overflow-y-auto">
              {files.map((file) => {
                const date = file.time ? new Date(Number(file.time)) : null;
                const time =
                  date && Number.isFinite(date.getTime())
                    ? dateFormat.format(date)
                    : null;
                const detail = [
                  file.path || t("composer.uploaded_file"),
                  time,
                  file.source.kind === "message_file" &&
                  file.source.attachment.index > 0
                    ? t("composer.upload_number", {
                        index: file.source.attachment.index + 1,
                      })
                    : null,
                ]
                  .filter(Boolean)
                  .join(" · ");
                return (
                  <Button
                    key={file.key}
                    variant="ghost"
                    type="button"
                    disabled={!file.available}
                    title={file.available ? detail : t("composer.old_file")}
                    className="h-auto w-full justify-start gap-3 px-3 py-2 text-start"
                    onClick={() => {
                      onClose();
                      onChoose(file, detail);
                    }}
                  >
                    <span className="conversation-file-icon" aria-hidden="true">
                      {file.imageFormat &&
                      file.source.kind === "message_file" ? (
                        <AttachmentThumbnail
                          target={file.source.attachment}
                          label={file.name}
                          formatLabel={file.imageFormat.toUpperCase()}
                          load={loadThumbnail}
                        />
                      ) : (
                        <Icon name={file.path ? "skill-file" : "upload"} />
                      )}
                    </span>
                    <span className="min-w-0">
                      <strong className="block truncate font-medium" dir="auto">
                        {file.name}
                      </strong>
                      <small
                        className="block truncate text-(--ui-content-muted)"
                        dir="auto"
                      >
                        {file.available ? detail : t("composer.old_file")}
                      </small>
                    </span>
                  </Button>
                );
              })}
              {!files.length && !loading && (
                <p className="px-3 py-2 text-sm">{t("composer.no_files")}</p>
              )}
            </div>
            {(onLoadEarlier || loading) && (
              <Button
                variant="ghost"
                size="sm"
                disabled={loading}
                onClick={onLoadEarlier}
              >
                {t(loading ? "composer.loading_files" : "composer.older_files")}
              </Button>
            )}
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}
