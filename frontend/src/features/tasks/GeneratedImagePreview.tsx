import { useEffect, useRef, useState } from "react";
import type { FilePreview, FileReferenceView } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

export type FilePreviewLoader = (
  taskId: string,
  runId: string,
  referenceId: string,
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
    setResult(null);
    if (!enabled || !load) return;
    let started = false;
    function request() {
      if (started) return;
      started = true;
      void load!(taskId, runId, reference.id).then(
        (value) => {
          if (current) setResult({ identity, value });
        },
        () => {
          if (current)
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
                observer?.disconnect();
              }
            },
            { rootMargin: "240px" },
          );
    if (observer && root.current) observer.observe(root.current);
    else request();
    return () => {
      current = false;
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
          <img
            src={`data:image/png;base64,${image.dataBase64}`}
            alt={reference.displayPath}
          />
        ) : (
          <span className="generated-image-placeholder" aria-live="polite">
            {!enabled
              ? t("file_preview.state.error")
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
