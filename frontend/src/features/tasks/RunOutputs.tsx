import {
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type RefObject,
} from "react";
import type { DeliveredOutputView } from "../../bridge/contracts.ts";
import {
  FileMenuScope,
  useFileMenuTrigger,
  useOpenFileMenu,
  type MenuFile,
} from "../../components/FileMenu.tsx";
import { FileTypeIcon } from "../../components/FileTypeIcon.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
import { fileName } from "./FileCard.tsx";
import { menuFile, type FileDescriber } from "./reply-files.ts";

type OutputPreview = (
  taskId: string,
  path: string,
  opener: HTMLButtonElement,
) => void;
type Output = DeliveredOutputView & { runId: string };

const none: ReadonlySet<string> = new Set();

/// The rows the file preview shows anything for, by what the Host says each
/// file holds now. Until it has answered, and for a file it does not preview,
/// a row is not a preview button, so clicking it does nothing.
function usePreviewableOutputs(
  root: RefObject<HTMLUListElement | null>,
  taskId: string,
  outputs: readonly Output[],
  describe: FileDescriber | undefined,
): ReadonlySet<string> {
  const [answered, setAnswered] = useState<{
    identity: string;
    ids: ReadonlySet<string>;
  } | null>(null);
  const focused = useRef<string | null>(null);
  const identity = JSON.stringify([
    taskId,
    outputs
      .filter((output) => !output.redacted)
      .map((output) => [
        output.runId,
        output.id,
        output.displayPath,
        output.sizeBytes,
        output.updated ?? false,
      ]),
  ]);
  useEffect(() => {
    if (!describe) return;
    const ask = describe;
    const controller = new AbortController();
    const [task, rows] = JSON.parse(identity) as [string, [string, string][]];
    void (async () => {
      const ids = new Set<string>();
      for (const [runId, outputId] of rows) {
        const result = await ask(
          { kind: "output", taskId: task, runId, outputId },
          { signal: controller.signal, priority: "prefetch" },
        ).catch(() => null);
        if (controller.signal.aborted) return;
        if (
          result?.state === "ready" &&
          (result.file.kind === "image" ||
            (result.file.kind === "file" && result.file.previewable))
        )
          ids.add(outputId);
      }
      // A row that becomes a button is a new element: keep the focus it held.
      focused.current =
        (root.current?.contains(document.activeElement) &&
          document.activeElement
            ?.closest("[data-output-id]")
            ?.getAttribute("data-output-id")) ||
        null;
      setAnswered({ identity, ids });
    })();
    return () => controller.abort();
  }, [root, identity, describe]);
  useLayoutEffect(() => {
    const id = focused.current;
    focused.current = null;
    if (id === null) return;
    const row = Array.from(
      root.current?.querySelectorAll<HTMLElement>("[data-output-id]") ?? [],
    )
      .find((item) => item.getAttribute("data-output-id") === id)
      ?.querySelector<HTMLElement>(".run-output-file");
    if (row && !row.contains(document.activeElement))
      row.focus({ preventScroll: true });
  }, [root, answered]);
  return describe && answered?.identity === identity ? answered.ids : none;
}

export function RunOutputs({
  outputs,
  taskId,
  disabled = false,
  onPreview,
  describe,
}: {
  outputs: readonly Output[];
  taskId: string;
  disabled?: boolean;
  onPreview?: OutputPreview;
  /** Asks the Host what each file holds now; only a previewable row previews. */
  describe?: FileDescriber;
}) {
  const root = useRef<HTMLUListElement>(null);
  const previewable = usePreviewableOutputs(
    root,
    taskId,
    outputs,
    onPreview && !disabled ? describe : undefined,
  );
  if (!outputs.length) return null;
  return (
    <ul ref={root} className="run-outputs-list">
      {outputs.map((output) => (
        <li key={output.id} className="run-output" data-output-id={output.id}>
          <FileMenuScope
            resetKey={JSON.stringify([
              taskId,
              output.runId,
              output.id,
              output.displayPath,
              output.redacted,
              output.open,
              output.sizeBytes,
              disabled,
              !!onPreview,
            ])}
          >
            <OutputRow
              output={output}
              taskId={taskId}
              disabled={disabled}
              onPreview={previewable.has(output.id) ? onPreview : undefined}
            />
          </FileMenuScope>
        </li>
      ))}
    </ul>
  );
}

function OutputRow({
  output,
  taskId,
  disabled,
  onPreview,
}: {
  output: Output;
  taskId: string;
  disabled: boolean;
  onPreview?: OutputPreview;
}) {
  const { t, locale } = useI18n();
  const opener = useRef<HTMLButtonElement>(null);
  const descriptionId = useId();
  const unavailable = disabled || output.redacted;
  const path = output.redacted ? "" : output.displayPath;
  const name = path ? fileName(path) : t("outputs.hidden_path");
  const dot = path ? name.lastIndexOf(".") : -1;
  const detail = output.updated
    ? t("outputs.updated")
    : t("outputs.delivered_size", {
        bytes: formatInteger(locale, BigInt(output.sizeBytes)),
      });
  const description = [path, detail].filter(Boolean).join(" · ");
  function preview() {
    if (onPreview && opener.current && !unavailable)
      onPreview(taskId, path, opener.current);
  }
  const file: MenuFile | null = unavailable
    ? null
    : {
        ...menuFile(
          { kind: "output", taskId, runId: output.runId, outputId: output.id },
          path,
          { openable: !!output.open },
        ),
        delivery: {
          opensInBrowser: output.open === "browser",
          viewSource:
            output.open === "browser" && onPreview ? preview : undefined,
        },
      };
  const openMenu = useOpenFileMenu();
  const trigger = useFileMenuTrigger(file);
  const contents = (
    <>
      <FileTypeIcon name={path ? name : ""} />
      <span className="run-output-name" dir="auto">
        <span>{dot > 0 ? name.slice(0, dot) : name}</span>
        {dot > 0 && <span>{name.slice(dot)}</span>}
      </span>
    </>
  );
  return (
    <div className="run-output-row">
      {onPreview && !unavailable ? (
        <button
          ref={opener}
          type="button"
          className="run-output-file focus-ring"
          aria-label={name}
          aria-describedby={descriptionId}
          title={description}
          onClick={preview}
          {...trigger}
        >
          {contents}
        </button>
      ) : (
        <span
          role="group"
          tabIndex={unavailable ? undefined : 0}
          className="run-output-file focus-ring"
          aria-label={name}
          aria-describedby={descriptionId}
          title={description}
          {...trigger}
        >
          {contents}
        </span>
      )}
      <span className="sr-only" id={descriptionId}>
        {description}
      </span>
      {openMenu && file && (
        <button
          type="button"
          className="run-output-more focus-ring"
          aria-label={t("outputs.more")}
          title={t("outputs.more")}
          aria-haspopup="menu"
          onClick={(event) => openMenu(file, event, true)}
          {...trigger}
        >
          <Icon name="more" />
        </button>
      )}
    </div>
  );
}
