import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type {
  DeliveredOutputView,
  FileDescriptionResult,
  FileTarget,
} from "../../bridge/contracts.ts";
import { FileMenuScope } from "../../components/FileMenu.tsx";
import { FileTypeIcon } from "../../components/FileTypeIcon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { formatFileSize } from "../../i18n/formatters.ts";
import { FileCard, fileName } from "./FileCard.tsx";
import { ReplyImage } from "./ReplyImage.tsx";
import { ReplyVideo } from "./ReplyVideo.tsx";
import {
  descriptionFailure,
  menuFile,
  type FileDescriber,
  type FilePreviewLoader,
} from "./reply-files.ts";

type Descriptions = ReadonlyMap<string, FileDescriptionResult>;

/**
 * The files one reply delivered or changed and does not already show: images
 * and videos in place, everything else as a card. The Host says which is
 * which, by the content a file holds now, so nothing is arranged before all of
 * them were asked for.
 */
export function RunFiles({
  taskId,
  runId,
  outputs,
  enabled,
  describe,
  load,
  onOpen,
}: {
  taskId: string;
  runId: string;
  outputs: readonly DeliveredOutputView[];
  enabled: boolean;
  describe?: FileDescriber;
  load?: FilePreviewLoader;
  /** Absent while the Workspace cannot be browsed. */
  onOpen?: (displayPath: string, opener: HTMLButtonElement) => void;
}) {
  const { t } = useI18n();
  const root = useRef<HTMLDivElement>(null);
  const [described, setDescribed] = useState<Descriptions | null>(null);
  const focused = useRef<string | null>(null);
  const identity = JSON.stringify([
    taskId,
    runId,
    outputs.map((output) => [
      output.id,
      output.redacted,
      output.displayPath,
      // It was delivered again, or changed during the turn.
      output.sizeBytes,
      output.updated,
    ]),
  ]);
  const targetOf = (output: DeliveredOutputView): FileTarget => ({
    kind: "output",
    taskId,
    runId,
    outputId: output.id,
  });

  useEffect(() => {
    const element = root.current;
    if (!enabled || !describe || !element) return;
    const ask = describe;
    let controller: AbortController | null = null;
    const [task, run, rows] = JSON.parse(identity) as [
      string,
      string,
      [string, boolean][],
    ];
    async function describeAll() {
      const current = (controller = new AbortController());
      const next = new Map<string, FileDescriptionResult>();
      for (const [outputId, redacted] of rows) {
        if (redacted) continue;
        const result = await ask(
          { kind: "output", taskId: task, runId: run, outputId },
          { signal: current.signal, priority: "prefetch" },
        ).catch((): FileDescriptionResult => ({ state: "error", file: null }));
        if (current.signal.aborted) return;
        next.set(outputId, result);
      }
      // A card and a button are different elements: what held the focus in
      // the old arrangement holds it in the new one.
      focused.current =
        (root.current?.contains(document.activeElement) &&
          document.activeElement
            ?.closest("[data-output-id]")
            ?.getAttribute("data-output-id")) ||
        null;
      setDescribed(next);
    }
    if (typeof IntersectionObserver === "undefined") {
      void describeAll();
      return () => controller?.abort();
    }
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          if (!controller) void describeAll();
        } else {
          controller?.abort();
          controller = null;
        }
      },
      { rootMargin: "240px" },
    );
    observer.observe(element);
    return () => {
      observer.disconnect();
      controller?.abort();
    };
  }, [identity, enabled, describe]);

  useLayoutEffect(() => {
    const id = focused.current;
    focused.current = null;
    if (id === null) return;
    const card = root.current?.querySelector<HTMLElement>(
      `[data-output-id="${CSS.escape(id)}"] .file-card`,
    );
    if (card && !card.contains(document.activeElement))
      card.focus({ preventScroll: true });
  }, [described]);

  const images: React.ReactNode[] = [];
  const videos: React.ReactNode[] = [];
  const files: React.ReactNode[] = [];
  for (const output of outputs) {
    if (output.redacted) {
      files.push(
        <li key={output.id} data-output-id={output.id}>
          <FileCard
            name={t("outputs.hidden_path")}
            detail={output.updated ? [t("outputs.updated")] : []}
            menu={null}
          />
        </li>,
      );
      continue;
    }
    const result = described?.get(output.id);
    if (!result) {
      files.push(
        <li key={output.id} data-output-id={output.id} aria-busy="true">
          <FileSkeleton name={fileName(output.displayPath)} />
        </li>,
      );
      continue;
    }
    const target = targetOf(output);
    const openable = output.open !== undefined;
    if (result.state === "ready" && result.file.kind === "image") {
      const { width, height } = result.file;
      images.push(
        <ReplyImage
          key={output.id}
          target={target}
          displayPath={output.displayPath}
          size={{ width, height }}
          openable={openable}
          enabled={enabled}
          load={load}
          describe={describe}
          onOpen={onOpen && ((opener) => onOpen(output.displayPath, opener))}
        />,
      );
      continue;
    }
    if (
      result.state === "ready" &&
      result.file.kind === "video" &&
      load &&
      enabled
    ) {
      videos.push(
        <ReplyVideo
          key={output.id}
          target={target}
          displayPath={output.displayPath}
          openable={openable}
          load={load}
          describe={describe}
        />,
      );
      continue;
    }
    files.push(
      <li key={output.id} data-output-id={output.id}>
        <OutputCard
          output={output}
          target={target}
          openable={openable}
          result={result}
          onOpen={onOpen}
        />
      </li>,
    );
  }
  return (
    <div ref={root} className="run-files">
      {images}
      {videos}
      {files.length > 0 && <ul className="run-files-list">{files}</ul>}
    </div>
  );
}

function OutputCard({
  output,
  target,
  openable,
  result,
  onOpen,
}: {
  output: DeliveredOutputView;
  target: FileTarget;
  openable: boolean;
  result: FileDescriptionResult;
  onOpen?: (displayPath: string, opener: HTMLButtonElement) => void;
}) {
  const { locale, t } = useI18n();
  const ready = result.state === "ready";
  const previewable =
    ready && result.file.kind === "file" && result.file.previewable;
  return (
    <FileMenuScope resetKey={JSON.stringify(target)}>
      <FileCard
        name={fileName(output.displayPath)}
        detail={[
          ready
            ? formatFileSize(locale, result.file.sizeBytes)
            : t(descriptionFailure(result.state)),
          ...(output.updated ? [t("outputs.updated")] : []),
        ]}
        menu={menuFile(target, output.displayPath, {
          openable,
          available: ready,
        })}
        onOpen={
          previewable && onOpen
            ? (opener) => onOpen(output.displayPath, opener)
            : undefined
        }
      />
    </FileMenuScope>
  );
}

/** The card a file will probably be, before the Host said what it is. */
function FileSkeleton({ name }: { name: string }) {
  return (
    <div className="file-card" data-pending="true">
      <FileTypeIcon name={name} />
      <span className="file-card-text">
        <span className="file-card-name">{name}</span>
        <span className="file-card-detail" aria-hidden="true">
          {" "}
        </span>
      </span>
    </div>
  );
}
