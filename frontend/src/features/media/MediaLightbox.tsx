import { useEffect, useState } from "react";
import type {
  FilePreview,
  FilePreviewLoadOptions,
  MediaTarget,
} from "../../bridge/contracts.ts";
import { Dialog } from "../../components/ui/dialog.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Button } from "../../components/ui/button.tsx";
import { PreviewImageView } from "../../components/PreviewImageView.tsx";
import { useI18n } from "../../i18n/context.ts";

export type MediaViewerLoader = (
  target: MediaTarget,
  options?: FilePreviewLoadOptions,
) => Promise<FilePreview>;

export type MediaViewerTarget = { media: MediaTarget; name: string };

/// The one viewer surface for an attachment, used from the draft chip and from
/// a sent message's chip. It is an overlay rather than a Task Panel tab: an
/// attachment original is immutable, has no user-visible path to title a tab
/// with and no refresh to offer, and a draft has no Task identity at all.
/// Closing it leaves the draft, or the transcript, untouched.
export function MediaLightbox({
  target,
  load,
  securityEpoch,
  onClose,
}: {
  target: MediaViewerTarget | null;
  load?: MediaViewerLoader;
  /// The security epoch the original is shown under. A newer one revokes it,
  /// so the viewer asks for it again in place.
  securityEpoch?: string;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const [result, setResult] = useState<{
    key: string;
    value: FilePreview;
  } | null>(null);
  const key = target ? JSON.stringify(target.media) : null;
  const preview = result?.key === key ? result.value : null;

  useEffect(() => {
    let current = true;
    let owned: FilePreview | undefined;
    const controller = new AbortController();
    setResult(null);
    if (!key || !load) return;
    void load(JSON.parse(key) as MediaTarget, {
      signal: controller.signal,
      priority: "interactive",
    }).then(
      (value) => {
        if (!current) {
          value.release?.();
          return;
        }
        owned = value;
        setResult({ key, value });
      },
      () => {
        if (current)
          setResult({
            key,
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
  }, [key, load, securityEpoch]);

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
                    key
                      ? {
                          key,
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
