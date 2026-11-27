import { useEffect, useRef, useState, type CSSProperties } from "react";
import type { FilePreview, FileTarget } from "../../bridge/contracts.ts";
import {
  FileMenuScope,
  useFileMenuTrigger,
  type MenuFile,
} from "../../components/FileMenu.tsx";
import { previewImageCopy } from "../../components/preview-image-copy.ts";
import { PreviewImageView } from "../../components/PreviewImageView.tsx";
import { useI18n } from "../../i18n/context.ts";
import { DescribedFileCard } from "./DescribedFileCard.tsx";
import {
  menuFile,
  previewNotInline,
  type FileDescriber,
  type FilePreviewLoader,
} from "./reply-files.ts";

const maxWidth = 288;
const maxHeight = 180;

/** The box an image of this size is shown in, so nothing moves when it loads. */
function imageBox(size: { width: number; height: number }): CSSProperties {
  const scale = Math.min(1, maxWidth / size.width, maxHeight / size.height);
  return {
    width: `${Math.max(1, Math.round(size.width * scale))}px`,
    aspectRatio: `${size.width} / ${size.height}`,
  };
}

/** An image of the reply: one the Host generated, or one that was delivered. */
export function ReplyImage(props: {
  target: FileTarget;
  displayPath: string;
  /** Known before it loads, for an image that was described first. */
  size?: { width: number; height: number };
  openable?: boolean;
  enabled: boolean;
  load?: FilePreviewLoader;
  describe?: FileDescriber;
  onOpen?: (opener: HTMLButtonElement) => void;
}) {
  return (
    <FileMenuScope
      className="reply-media"
      resetKey={JSON.stringify(props.target)}
    >
      <ReplyImageContent {...props} />
    </FileMenuScope>
  );
}

function ReplyImageContent({
  target,
  displayPath,
  size,
  openable,
  enabled,
  load,
  describe,
  onOpen,
}: Parameters<typeof ReplyImage>[0]) {
  const root = useRef<HTMLElement | null>(null);
  const identity = JSON.stringify(target);
  const [result, setResult] = useState<{
    identity: string;
    value: FilePreview;
  } | null>(null);
  const [attempt, setAttempt] = useState(0);
  // What is not shown in place stays a card: asking again each time it comes
  // into view would move everything below it.
  const [notInline, setNotInline] = useState<string | null>(null);
  const asCard = notInline === identity;
  const preview =
    enabled && result?.identity === identity ? result.value : null;
  const menu = menuFile(target, displayPath, { openable });

  useEffect(() => {
    let current = true;
    let owned: FilePreview | undefined;
    let controller = new AbortController();
    let version = 0;
    setResult(null);
    if (!enabled || !load || asCard) return;
    let started = false;
    function request() {
      if (started) return;
      started = true;
      controller = new AbortController();
      const requestVersion = ++version;
      void load!(JSON.parse(identity) as FileTarget, {
        signal: controller.signal,
        priority: "prefetch",
      }).then(
        (value) => {
          if (!current || requestVersion !== version) {
            value.release?.();
          } else if (previewNotInline(value)) {
            value.release?.();
            setNotInline(identity);
          } else {
            owned = value;
            setResult({ identity, value });
          }
        },
        () => {
          if (current && requestVersion === version)
            setResult({
              identity,
              value: {
                state: "error",
                content: "",
                truncated: false,
                redacted: false,
              },
            });
        },
      );
    }
    const observer =
      typeof IntersectionObserver === "undefined"
        ? null
        : new IntersectionObserver(
            (entries) => {
              if (entries.some((entry) => entry.isIntersecting)) {
                request();
              } else if (started) {
                version++;
                controller.abort();
                owned?.release?.();
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
      owned?.release?.();
      observer?.disconnect();
    };
  }, [identity, enabled, load, attempt, asCard]);

  if (asCard)
    return (
      <DescribedFileCard
        target={target}
        displayPath={displayPath}
        openable={openable}
        describe={describe}
      />
    );
  return (
    <ImageFigure
      root={root}
      preview={preview}
      displayPath={displayPath}
      menu={menu}
      size={size}
      enabled={enabled}
      onOpen={onOpen}
      onFailure={() => {
        preview?.release?.();
        setResult({
          identity,
          value: {
            state: "error",
            content: "",
            truncated: false,
            redacted: false,
          },
        });
      }}
      onRetry={() => setAttempt((value) => value + 1)}
    />
  );
}

function ImageFigure({
  root,
  preview,
  displayPath,
  menu,
  size,
  enabled,
  onOpen,
  onFailure,
  onRetry,
}: {
  root: React.RefObject<HTMLElement | null>;
  preview: FilePreview | null;
  displayPath: string;
  menu: MenuFile;
  size?: { width: number; height: number };
  enabled: boolean;
  onOpen?: (opener: HTMLButtonElement) => void;
  onFailure: () => void;
  onRetry: () => void;
}) {
  const { t } = useI18n();
  // A rotated photograph is only known to be one once it is decoded.
  const [decoded, setDecoded] = useState<{
    id: string;
    width: number;
    height: number;
  } | null>(null);
  const image = preview?.image;
  const trigger = useFileMenuTrigger({
    ...menu,
    copyImage: previewImageCopy(image, decoded?.id === image?.id),
  });
  const state =
    image || preview?.state === "ready" ? undefined : preview?.state;
  const natural = image && decoded?.id === image.id ? decoded : (size ?? image);
  const content = image ? (
    <PreviewImageView
      image={image}
      alt={displayPath}
      onReady={(width, height) => setDecoded({ id: image.id, width, height })}
      onFailure={onFailure}
    />
  ) : (
    <span className="reply-image-placeholder" aria-live="polite">
      {!enabled
        ? t("file_preview.state.error")
        : preview?.reason
          ? t(`file_preview.state.${preview.reason}`)
          : state
            ? t(`file_preview.state.${state}`)
            : t("file_preview.loading")}
    </span>
  );
  return (
    <figure ref={root} className="reply-image">
      {onOpen && enabled ? (
        <button
          type="button"
          className="reply-image-open focus-ring"
          style={natural && imageBox(natural)}
          aria-label={t("file_preview.open", { path: displayPath })}
          onClick={(event) => onOpen(event.currentTarget)}
          {...trigger}
        >
          {content}
        </button>
      ) : (
        <div
          role="group"
          tabIndex={0}
          className="reply-image-open focus-ring"
          style={natural && imageBox(natural)}
          aria-label={displayPath}
          {...trigger}
        >
          {content}
        </div>
      )}
      {(state === "error" || state === "changing") && (
        <button
          type="button"
          className="reply-image-retry focus-ring"
          onClick={onRetry}
        >
          {t("file_preview.retry")}
        </button>
      )}
    </figure>
  );
}
