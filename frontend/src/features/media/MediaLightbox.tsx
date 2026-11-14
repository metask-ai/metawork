import { useEffect, useState } from "react";
import type {
  FilePreview,
  FilePreviewLoadOptions,
} from "../../bridge/contracts.ts";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { PreviewImageView } from "../../components/PreviewImageView.tsx";
import { useI18n } from "../../i18n/context.ts";

export type MediaViewerLoader = (
  attachmentToken: string,
  options?: FilePreviewLoadOptions,
) => Promise<FilePreview>;

export type MediaViewerTarget = { token: string; name: string };

/// The one viewer surface for an attachment, used from the draft chip. It is an
/// overlay rather than a Task Panel tab: an attachment original is immutable,
/// has no user-visible path to title a tab with and no refresh to offer, and a
/// draft has no Task identity at all. Closing it leaves the draft untouched.
export function MediaLightbox({
  target,
  load,
  onClose,
}: {
  target: MediaViewerTarget | null;
  load?: MediaViewerLoader;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const [result, setResult] = useState<{
    token: string;
    value: FilePreview;
  } | null>(null);
  const token = target?.token ?? null;
  const preview = result?.token === token ? result.value : null;

  useEffect(() => {
    let current = true;
    let owned: FilePreview | undefined;
    const controller = new AbortController();
    setResult(null);
    if (!token || !load) return;
    void load(token, {
      signal: controller.signal,
      priority: "interactive",
    }).then(
      (value) => {
        if (!current) {
          value.release?.();
          return;
        }
        owned = value;
        setResult({ token, value });
      },
      () => {
        if (current)
          setResult({
            token,
            value: {
              state: "error",
              content: "",
              truncated: false,
              redacted: false,
            },
          });
      },
    );
    return () => {
      current = false;
      controller.abort();
      owned?.release?.();
    };
  }, [token, load]);

  const image = preview?.state === "ready" ? preview.image : undefined;
  const failure = preview?.state === "ready" ? undefined : preview?.state;
  return (
    <Dialog.Root
      open={target !== null}
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <Dialog.Portal>
        <Dialog.Backdrop />
        <Dialog.Popup className="media-lightbox">
          <div className="media-lightbox-bar">
            <Dialog.Title className="media-lightbox-title" dir="auto">
              {target?.name ?? ""}
            </Dialog.Title>
            <Dialog.Close
              render={
                <Button
                  type="button"
                  variant="ghost"
                  size="icon"
                  aria-label={t("attachment.close_preview")}
                >
                  <Icon name="close" />
                </Button>
              }
            />
          </div>
          <div className="media-lightbox-body">
            {image ? (
              <PreviewImageView
                image={image}
                alt={target?.name ?? ""}
                onFailure={() =>
                  setResult(
                    token
                      ? {
                          token,
                          value: {
                            state: "error",
                            content: "",
                            truncated: false,
                            redacted: false,
                          },
                        }
                      : null,
                  )
                }
              />
            ) : (
              <p className="media-lightbox-state" aria-live="polite">
                {preview?.reason
                  ? t(`file_preview.state.${preview.reason}`)
                  : failure
                    ? t(`file_preview.state.${failure}`)
                    : t("file_preview.loading")}
              </p>
            )}
          </div>
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
