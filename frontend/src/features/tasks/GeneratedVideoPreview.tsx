import { useCallback, useEffect, useRef, useState } from "react";
import type { FilePreviewVideo } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";
import type { FilePreviewLoader } from "./GeneratedImagePreview.tsx";

type Props = {
  taskId: string;
  runId: string;
  referenceId: string;
  load: FilePreviewLoader;
};

export function GeneratedVideoPreview(props: Props) {
  const root = useRef<HTMLDivElement>(null);
  const [near, setNear] = useState(false);
  useEffect(() => {
    const target = root.current;
    if (!target || typeof IntersectionObserver === "undefined") {
      setNear(true);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => setNear(entries.some((entry) => entry.isIntersecting)),
      { rootMargin: "240px" },
    );
    observer.observe(target);
    return () => observer.disconnect();
  }, []);
  return (
    <div ref={root} className="generated-video-preview">
      {near && <VideoPlayer {...props} />}
    </div>
  );
}

function VideoPlayer({ taskId, runId, referenceId, load }: Props) {
  const { t } = useI18n();
  const [resource, setResource] = useState<FilePreviewVideo | null>(null);
  const [decoded, setDecoded] = useState(false);
  const [failed, setFailed] = useState(false);
  const video = useRef<HTMLVideoElement | null>(null);
  const release = useRef<(() => void) | undefined>(undefined);
  const attach = useCallback((element: HTMLVideoElement | null) => {
    if (!element) video.current?.pause();
    video.current = element;
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    let unsubscribe: (() => void) | undefined;
    void load(taskId, runId, referenceId, {
      signal: controller.signal,
      priority: "prefetch",
    }).then(
      (result) => {
        if (controller.signal.aborted || !result.video?.valid()) {
          result.release?.();
          if (!controller.signal.aborted) setFailed(true);
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
    };
  }, [taskId, runId, referenceId, load]);

  return (
    <>
      {resource?.valid() && !failed && (
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
