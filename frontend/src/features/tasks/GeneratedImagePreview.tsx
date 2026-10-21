import { PreviewImageView } from "../../components/PreviewImageView.tsx";
import { useEffect, useRef, useState } from "react";
import type {
  FilePreview,
  FileReferenceView,
  FilePreviewLoadOptions,
} from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

export type FilePreviewLoader = (
  taskId: string,
  runId: string,
  referenceId: string,
  options?: FilePreviewLoadOptions,
) => Promise<FilePreview>;

export function GeneratedImagePreview({
  taskId,
  runId,
  reference,
  enabled,
  load,
  onOpen,
}: {
  taskId: string;
  runId: string;
  reference: FileReferenceView;
  enabled: boolean;
  load?: FilePreviewLoader;
  onOpen: (opener: HTMLButtonElement) => void;
}) {
  const { t } = useI18n();
  const root = useRef<HTMLElement | null>(null);
  const identity = `${taskId}:${runId}:${reference.id}`;
  const [result, setResult] = useState<{
    identity: string;
    value: FilePreview;
  } | null>(null);
  const [attempt, setAttempt] = useState(0);
  const preview =
    enabled && result?.identity === identity ? result.value : null;

  useEffect(() => {
    let current = true;
    let owned: FilePreview | undefined;
    let controller = new AbortController();
    let version = 0;
    setResult(null);
    if (!enabled || !load) return;
    let started = false;
    function request() {
      if (started) return;
      started = true;
      controller = new AbortController();
      const requestVersion = ++version;
      void load!(taskId, runId, reference.id, {
        signal: controller.signal,
        priority: "prefetch",
      }).then(
        (value) => {
          if (current && requestVersion === version) {
            owned = value;
            setResult({ identity, value });
          } else value.release?.();
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
  }, [taskId, runId, reference.id, identity, enabled, load, attempt]);

  const image = preview?.state === "ready" ? preview.image : undefined;
  const state = preview?.state === "ready" ? "unsupported" : preview?.state;
  return (
    <figure ref={root} className="generated-image-preview">
      <button
        type="button"
        className="generated-image-open focus-ring"
        disabled={!enabled}
        aria-label={t("file_preview.open", { path: reference.displayPath })}
        onClick={(event) => onOpen(event.currentTarget)}
      >
        {image ? (
          <PreviewImageView
            image={image}
            alt={reference.displayPath}
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
          />
        ) : (
          <span className="generated-image-placeholder" aria-live="polite">
            {!enabled
              ? t("file_preview.state.error")
              : preview?.reason
                ? t(`file_preview.state.${preview.reason}`)
                : state
                  ? t(`file_preview.state.${state}`)
                  : t("file_preview.loading")}
          </span>
        )}
      </button>
      {(state === "error" || state === "changing") && (
        <button
          type="button"
          className="generated-image-retry focus-ring"
          onClick={() => setAttempt((value) => value + 1)}
        >
          {t("file_preview.retry")}
        </button>
      )}
    </figure>
  );
}
