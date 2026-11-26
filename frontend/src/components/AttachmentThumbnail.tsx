import { useEffect, useRef, useState } from "react";
import {
  PreviewImageView,
  type PreviewImageResource,
} from "./PreviewImageView.tsx";
import { useI18n } from "../i18n/context.ts";

/// What a loader hands back for one chip. The Host contract's own result is
/// assignable to this; stating it structurally keeps this primitive reusable
/// and off the Host client boundary.
export type AttachmentThumbnailOutcome =
  | { state: "ready"; image: PreviewImageResource; release: () => void }
  | { state: "missing" | "restricted" | "unsupported" | "error" | "capacity" };

/// The target is opaque here: this primitive forwards it and uses it only to
/// tell one chip's image from another's.
export type AttachmentThumbnailLoader<Target> = (
  target: Target,
  options?: { signal?: AbortSignal; priority?: "interactive" | "prefetch" },
) => Promise<AttachmentThumbnailOutcome>;

/// An image chip's thumbnail, for a staged draft and for an image a message
/// was already sent with. It loads near the viewport, releases its decoded
/// resource when it leaves, and falls back to the format label the chip has
/// always shown when the Host has no derivative to give.
export function AttachmentThumbnail<Target>({
  target,
  label,
  formatLabel,
  load,
  securityEpoch,
  onOpen,
}: {
  target: Target;
  label: string;
  formatLabel: string;
  load?: AttachmentThumbnailLoader<Target>;
  /// The security epoch the thumbnail is checked under. A newer one revokes
  /// what was delivered, so the chip asks again in place instead of showing a
  /// failure. Absent where the chip is remounted with its content anyway.
  securityEpoch?: string;
  /// Absent when this original cannot be opened in the viewer tier at all, so
  /// the chip shows the thumbnail without an entry that is certain to fail.
  onOpen?: (opener: HTMLButtonElement) => void;
}) {
  const { t } = useI18n();
  const root = useRef<HTMLSpanElement | null>(null);
  // The identity the Host resolves, flattened so an effect re-runs when the
  // chip starts standing for a different image.
  const key = JSON.stringify(target);
  const [result, setResult] = useState<{
    key: string;
    value: AttachmentThumbnailOutcome;
  } | null>(null);
  const loaded = result?.key === key ? result.value : null;

  useEffect(() => {
    let current = true;
    let owned: AttachmentThumbnailOutcome | undefined;
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
      void load!(JSON.parse(key) as Target, {
        signal: controller.signal,
        priority: "prefetch",
      }).then(
        (value) => {
          if (current && requested === version) {
            owned = value;
            setResult({ key, value });
          } else if (value.state === "ready") value.release();
        },
        () => {
          if (current && requested === version)
            setResult({ key, value: { state: "error" } });
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
  }, [key, load, securityEpoch]);

  const image = loaded?.state === "ready" ? loaded.image : undefined;
  const content = image ? (
    <PreviewImageView
      image={image}
      // The chip already names the file in text, and the viewer entry carries
      // its own label, so the thumbnail itself is decorative.
      alt=""
      onFailure={() => setResult({ key, value: { state: "error" } })}
    />
  ) : (
    <span className="composer-attachment-kind" aria-hidden="true">
      {formatLabel}
    </span>
  );
  return (
    <span ref={root} className="attachment-thumbnail">
      {image && onOpen ? (
        <button
          type="button"
          className="attachment-thumbnail-open focus-ring"
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
