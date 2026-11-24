import { useCallback, useEffect, useRef, useState } from "react";
import type { FilePreviewVideo, FileTarget } from "../../bridge/contracts.ts";
import {
  FileMenuScope,
  useFileMenuTrigger,
} from "../../components/FileMenu.tsx";
import { useI18n } from "../../i18n/context.ts";
import { DescribedFileCard } from "./DescribedFileCard.tsx";
import { fileName } from "./FileCard.tsx";
import {
  menuFile,
  previewNotInline,
  type FileDescriber,
  type FilePreviewLoader,
} from "./reply-files.ts";

type Props = {
  target: FileTarget;
  displayPath: string;
  openable?: boolean;
  load: FilePreviewLoader;
  describe?: FileDescriber;
};

/** A video of the reply: one the Host generated, or one that was delivered. */
export function ReplyVideo(props: Props) {
  return (
    <FileMenuScope
      className="reply-media"
      resetKey={JSON.stringify(props.target)}
    >
      <ReplyVideoContent {...props} />
    </FileMenuScope>
  );
}

function ReplyVideoContent({
  target,
  displayPath,
  openable,
  load,
  describe,
}: Props) {
  const root = useRef<HTMLDivElement>(null);
  const [near, setNear] = useState(false);
  const [playable, setPlayable] = useState(false);
  const identity = JSON.stringify(target);
  const [notInline, setNotInline] = useState<string | null>(null);
  const trigger = useFileMenuTrigger(
    menuFile(target, displayPath, { openable }),
  );
  const asCard = notInline === identity;
  useEffect(() => {
    const element = root.current;
    if (!element || typeof IntersectionObserver === "undefined") {
      setNear(true);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => setNear(entries.some((entry) => entry.isIntersecting)),
      { rootMargin: "240px" },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [asCard]);
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
    <div
      ref={root}
      role="group"
      aria-label={fileName(displayPath)}
      // The player's own controls take the focus once there are any.
      tabIndex={near && playable ? -1 : 0}
      className="reply-video focus-ring"
      {...trigger}
    >
      {near && (
        <VideoPlayer
          key={identity}
          identity={identity}
          load={load}
          onPlayable={setPlayable}
          onNotInline={() => setNotInline(identity)}
        />
      )}
    </div>
  );
}

function VideoPlayer({
  identity,
  load,
  onPlayable,
  onNotInline,
}: {
  identity: string;
  load: FilePreviewLoader;
  onPlayable: (playable: boolean) => void;
  onNotInline: () => void;
}) {
  const { t } = useI18n();
  const [resource, setResource] = useState<FilePreviewVideo | null>(null);
  const [decoded, setDecoded] = useState(false);
  const [failed, setFailed] = useState(false);
  const video = useRef<HTMLVideoElement | null>(null);
  const release = useRef<(() => void) | undefined>(undefined);
  const callbacks = useRef({ onPlayable, onNotInline });
  callbacks.current = { onPlayable, onNotInline };
  const attach = useCallback((element: HTMLVideoElement | null) => {
    if (!element) video.current?.pause();
    video.current = element;
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    let unsubscribe: (() => void) | undefined;
    void load(JSON.parse(identity) as FileTarget, {
      signal: controller.signal,
      priority: "prefetch",
    }).then(
      (result) => {
        if (controller.signal.aborted || !result.video?.valid()) {
          result.release?.();
          if (controller.signal.aborted) return;
          if (previewNotInline(result)) callbacks.current.onNotInline();
          else setFailed(true);
          return;
        }
        release.current = result.release;
        unsubscribe = result.video.subscribe(() => {
          video.current?.pause();
          setResource(null);
          setFailed(true);
        });
        setResource(result.video);
      },
      () => {
        if (!controller.signal.aborted) setFailed(true);
      },
    );
    return () => {
      controller.abort();
      unsubscribe?.();
      release.current?.();
      release.current = undefined;
      callbacks.current.onPlayable(false);
    };
  }, [identity, load]);

  const shown = Boolean(resource?.valid()) && !failed;
  useEffect(() => {
    callbacks.current.onPlayable(shown && decoded);
  }, [shown, decoded]);

  return (
    <>
      {shown && resource && (
        <video
          ref={attach}
          src={resource.src}
          aria-label={t("video_preview.label")}
          controls
          playsInline
          preload="auto"
          disablePictureInPicture
          controlsList="nodownload noremoteplayback"
          hidden={!decoded}
          onLoadedData={() => setDecoded(true)}
          onError={() => {
            release.current?.();
            setFailed(true);
          }}
        />
      )}
      {failed && <p role="status">{t("video_preview.failed")}</p>}
    </>
  );
}
