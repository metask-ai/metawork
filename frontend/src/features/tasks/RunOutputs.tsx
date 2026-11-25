import { useId, useRef } from "react";
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
import { menuFile } from "./reply-files.ts";

type OutputPreview = (
  taskId: string,
  path: string,
  opener: HTMLButtonElement,
) => void;
type Output = DeliveredOutputView & { runId: string };

export function RunOutputs({
  outputs,
  taskId,
  disabled = false,
  onPreview,
}: {
  outputs: readonly Output[];
  taskId: string;
  disabled?: boolean;
  onPreview?: OutputPreview;
}) {
  if (!outputs.length) return null;
  return (
    <ul className="run-outputs-list">
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
              onPreview={onPreview}
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
