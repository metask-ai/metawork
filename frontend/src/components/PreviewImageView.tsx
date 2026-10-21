import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { useI18n } from "../i18n/context.ts";

// Image lifetime is supplied by the caller; this primitive owns DOM decoding only.
interface PreviewImageResource {
  id: string;
  width: number;
  height: number;
  readonly src: string;
  valid: () => boolean;
  subscribe: (listener: () => void) => () => void;
  beginDecode: (signal: AbortSignal) => Promise<() => void>;
}
export function PreviewImageView(props: {
  image: PreviewImageResource;
  alt: string;
  onFailure?: () => void;
}) {
  return <DecodedPreviewImage key={props.image.id} {...props} />;
}

function DecodedPreviewImage({
  image,
  alt,
  onFailure,
}: {
  image: PreviewImageResource;
  alt: string;
  onFailure?: () => void;
}) {
  const { t } = useI18n();
  const valid = useSyncExternalStore(image.subscribe, image.valid, image.valid);
  const [admitted, setAdmitted] = useState(false);
  const [ready, setReady] = useState(false);
  const [failed, setFailed] = useState(false);
  const [ratio, setRatio] = useState(`${image.width} / ${image.height}`);
  const permit = useRef<(() => void) | undefined>(undefined);
  const lifetime = useRef<AbortController | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const finish = () => {
    if (timer.current !== undefined) clearTimeout(timer.current);
    timer.current = undefined;
    permit.current?.();
    permit.current = undefined;
  };
  const failure = useRef(onFailure);
  failure.current = onFailure;
  useEffect(() => {
    const controller = new AbortController();
    lifetime.current = controller;
    setAdmitted(false);
    setReady(false);
    setFailed(false);
    if (!valid) {
      failure.current?.();
      return () => {
        controller.abort();
        finish();
      };
    }
    void image.beginDecode(controller.signal).then(
      (release) => {
        if (controller.signal.aborted || !image.valid()) {
          release();
          return;
        }
        permit.current = release;
        timer.current = setTimeout(() => {
          finish();
          setFailed(true);
          failure.current?.();
        }, 15_000);
        setAdmitted(true);
      },
      () => {
        if (!controller.signal.aborted) setFailed(true);
      },
    );
    return () => {
      controller.abort();
      finish();
    };
  }, [image, valid]);
  const reject = () => {
    if (lifetime.current?.signal.aborted) return;
    finish();
    setFailed(true);
    failure.current?.();
  };
  if (!valid || failed)
    return (
      <span className="file-preview-image-feedback">
        {t("file_preview.state.error")}
      </span>
    );
  return (
    <span
      className="file-preview-decoded"
      data-ready={ready}
      style={{ aspectRatio: ratio }}
      aria-busy={!ready}
    >
      <img
        decoding="async"
        src={admitted ? image.src : undefined}
        alt={alt}
        onError={reject}
        onLoad={(event) => {
          const element = event.currentTarget;
          void element.decode().then(() => {
            if (lifetime.current?.signal.aborted || !image.valid()) return;
            setRatio(`${element.naturalWidth} / ${element.naturalHeight}`);
            setReady(true);
            finish();
          }, reject);
        }}
      />
      {!ready && (
        <span className="file-preview-image-feedback">
          {t("file_preview.loading")}
        </span>
      )}
    </span>
  );
}
