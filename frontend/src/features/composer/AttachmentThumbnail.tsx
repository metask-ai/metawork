import { useEffect, useRef, useState } from "react";
import type {
  AttachmentThumbnailResult,
  FilePreviewLoadOptions,
} from "../../bridge/contracts.ts";
import { PreviewImageView } from "../../components/PreviewImageView.tsx";
import { useI18n } from "../../i18n/context.ts";

export type AttachmentThumbnailLoader = (
  attachmentToken: string,
  options?: FilePreviewLoadOptions,
) => Promise<AttachmentThumbnailResult>;

/// A staged image's chip thumbnail. It loads near the viewport, releases its
/// decoded resource when it leaves, and falls back to the format label the chip
/// has always shown when the Host has no derivative to give.
export function AttachmentThumbnail({
  token,
  label,
  formatLabel,
  load,
  onOpen,
}: {
  token: string;
  label: string;
  formatLabel: string;
  load?: AttachmentThumbnailLoader;
  /// Absent when this original cannot be opened in the viewer tier at all, so
  /// the chip shows the thumbnail without an entry that is certain to fail.
  onOpen?: (opener: HTMLButtonElement) => void;
}) {
  const { t } = useI18n();
  const root = useRef<HTMLSpanElement | null>(null);
  const [result, setResult] = useState<{
    token: string;
    value: AttachmentThumbnailResult;
  } | null>(null);
  const loaded = result?.token === token ? result.value : null;

  useEffect(() => {
    let current = true;
    let owned: AttachmentThumbnailResult | undefined;
    let controller = new AbortController();
    let version = 0;
    let started = false;
    setResult(null);
    if (!load) return;
    function request() {
      if (started) return;
      started = true;
      controller = new AbortController();
      const requested = ++version;
      void load!(token, {
        signal: controller.signal,
        priority: "prefetch",
      }).then(
        (value) => {
          if (current && requested === version) {
            owned = value;
            setResult({ token, value });
          } else if (value.state === "ready") value.release();
        },
        () => {
          if (current && requested === version)
            setResult({ token, value: { state: "error" } });
        },
      );
    }
    const observer =
      typeof IntersectionObserver === "undefined"
        ? null
        : new IntersectionObserver(
            (entries) => {
              if (entries.some((entry) => entry.isIntersecting)) request();
              else if (started) {
                version++;
                controller.abort();
                if (owned?.state === "ready") owned.release();
                owned = undefined;
                started = false;
                setResult(null);
              }
            },
            { rootMargin: "240px" },
          );
    if (observer && root.current) observer.observe(root.current);
    else request();
    return () => {
      current = false;
      controller.abort();
      if (owned?.state === "ready") owned.release();
      observer?.disconnect();
    };
  }, [token, load]);

  const image = loaded?.state === "ready" ? loaded.image : undefined;
  const content = image ? (
    <PreviewImageView
      image={image}
      alt={label}
      onFailure={() => setResult({ token, value: { state: "error" } })}
    />
  ) : (
    <span className="composer-attachment-kind" aria-hidden="true">
      {formatLabel}
    </span>
  );
  return (
    <span ref={root} className="composer-attachment-media">
      {image && onOpen ? (
        <button
          type="button"
          className="composer-attachment-open focus-ring"
          aria-label={t("attachment.open", { name: label })}
          onClick={(event) => onOpen(event.currentTarget)}
        >
          {content}
        </button>
      ) : (
        content
      )}
    </span>
  );
}
