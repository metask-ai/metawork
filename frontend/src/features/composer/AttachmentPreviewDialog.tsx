import { useEffect, useRef, useState } from "react";

import type {
  FilePreview,
  FilePreviewLoadOptions,
} from "../../bridge/contracts.ts";
import { PreviewImageView } from "../../components/PreviewImageView.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Dialog } from "../../components/ui/dialog.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";

/** One image attachment chip the user opened; `key` is its exact identity. */
export type AttachmentPreviewTarget = {
  key: string;
  name: string;
  detail: string;
  /** False once the owning draft or Run no longer offers this image. */
  available: boolean;
  invalid: MessageId;
  opener: HTMLElement | null;
};

type Result =
  | { key: string; attempt: number; value: FilePreview }
  | { key: string; attempt: number; failed: true };

function feedback(
  preview: FilePreview | null,
  invalid: MessageId,
): { message: MessageId; retry: boolean } {
  if (!preview) return { message: "attachment.preview.failed", retry: true };
  switch (preview.state) {
    case "ready":
      return { message: "file_preview.state.unsupported", retry: false };
    case "missing":
      return { message: invalid, retry: false };
    case "restricted":
      return { message: "file_preview.state.restricted", retry: false };
    case "unsupported":
      return {
        message:
          preview.reason === "image_limit"
            ? "file_preview.state.image_limit"
            : preview.reason === "animated_image"
              ? "file_preview.state.animated_image"
              : "file_preview.state.unsupported",
        retry: false,
      };
    case "changing":
    case "error":
      return {
        message:
          preview.reason === "capacity"
            ? "file_preview.state.capacity"
            : "attachment.preview.failed",
        retry: true,
      };
  }
}

/** Modal image preview for one attachment chip; it never edits the draft. */
export function AttachmentPreviewDialog({
  target,
  load,
  onClose,
}: {
  target: AttachmentPreviewTarget | null;
  load: (options: FilePreviewLoadOptions) => Promise<FilePreview>;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const [attempt, setAttempt] = useState(0);
  const [result, setResult] = useState<Result | null>(null);
  const loader = useRef(load);
  loader.current = load;
  const key = target?.key ?? null;
  const available = Boolean(target?.available);

  useEffect(() => {
    setResult(null);
    if (key === null || !available) return;
    const controller = new AbortController();
    let owned: FilePreview | undefined;
    void loader
      .current({ signal: controller.signal, priority: "interactive" })
      .then(
        (value) => {
          if (controller.signal.aborted) {
            value.release?.();
            return;
          }
          owned = value;
          setResult({ key, attempt, value });
        },
        () => {
          if (!controller.signal.aborted)
            setResult({ key, attempt, failed: true });
        },
      );
    return () => {
      controller.abort();
      owned?.release?.();
    };
  }, [key, available, attempt]);

  if (!target) return null;
  const current =
    result && result.key === target.key && result.attempt === attempt
      ? result
      : null;
  const preview = current && "value" in current ? current.value : null;
  const image = preview?.state === "ready" ? preview.image : undefined;
  const failure = !target.available
    ? { message: target.invalid, retry: false }
    : current && !image
      ? feedback(preview, target.invalid)
      : null;

  return (
    <Dialog.Root
      open
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup
          className="attachment-preview-dialog"
          finalFocus={() => (target.opener?.isConnected ? target.opener : true)}
        >
          <div className="attachment-preview-header">
            <div className="attachment-preview-heading">
              <Dialog.Title
                className="attachment-preview-title"
                dir="auto"
                title={target.name}
              >
                {target.name}
              </Dialog.Title>
              <Dialog.Description>{target.detail}</Dialog.Description>
            </div>
            <Dialog.Close
              className="icon-button"
              aria-label={t("attachment.preview.close")}
            >
              <Icon name="close" />
            </Dialog.Close>
          </div>
          <div className="attachment-preview-body">
            {failure ? (
              <div className="attachment-preview-feedback" role="status">
                <p>{t(failure.message)}</p>
                {failure.retry && (
                  <Button
                    type="button"
                    variant="secondary"
                    onClick={() => setAttempt((value) => value + 1)}
                  >
                    {t("file_preview.retry")}
                  </Button>
                )}
              </div>
            ) : image ? (
              <div
                className="attachment-preview-frame"
                // Fit the whole image in the viewport without enlarging it.
                style={{
                  width: `min(100%, ${image.width}px, calc((100dvh - 10rem) * ${image.width} / ${image.height}))`,
                }}
              >
                <PreviewImageView
                  image={image}
                  alt={target.name}
                  onFailure={() => {
                    preview?.release?.();
                    setResult({ key: target.key, attempt, failed: true });
                  }}
                />
              </div>
            ) : (
              <p className="attachment-preview-feedback" aria-live="polite">
                {t("file_preview.loading")}
              </p>
            )}
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
