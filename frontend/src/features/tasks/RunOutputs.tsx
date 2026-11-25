import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { Button } from "../../components/ui/button.tsx";
import type {
  FileAction,
  FileActionHandler,
  FileActionState,
  DeliveredOutputView,
  FileTarget,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
export type FileReferenceResult =
  "edit_prepared" | "cancelled" | "edit_unavailable";
export type FileReferenceHandler = (
  target: FileTarget,
  displayPath: string,
  signal?: AbortSignal,
) => FileReferenceResult | Promise<FileReferenceResult>;
type RowAction =
  Exclude<FileAction, "check_current" | "copy_path"> | "edit" | "preview";
type OutputPreview = (
  taskId: string,
  path: string,
  opener: HTMLButtonElement,
) => void;
/** The outputs of a conversation, in the right panel. */
export function RunOutputs({
  outputs,
  taskId,
  runId,
  disabled = false,
  onAction,
  onReference,
  onPreview,
}: {
  outputs: readonly (DeliveredOutputView & { runId?: string })[];
  taskId?: string;
  runId?: string;
  disabled?: boolean;
  onAction?: FileActionHandler;
  onReference?: FileReferenceHandler;
  onPreview?: OutputPreview;
}) {
  if (outputs.length === 0) return null;
  return (
    <ul className="run-outputs-list">
      {outputs.map((output) => (
        <OutputRow
          key={output.id}
          output={output}
          taskId={taskId}
          runId={output.runId ?? runId}
          disabled={disabled}
          onAction={onAction}
          onReference={onReference}
          onPreview={onPreview}
        />
      ))}
    </ul>
  );
}
function OutputRow({
  output,
  taskId,
  runId,
  disabled,
  onAction,
  onReference,
  onPreview,
}: {
  output: DeliveredOutputView;
  taskId?: string;
  runId?: string;
  disabled: boolean;
  onAction?: FileActionHandler;
  onReference?: FileReferenceHandler;
  onPreview?: OutputPreview;
}) {
  const { locale, t } = useI18n();
  const nameId = useId();
  const [pending, setPending] = useState<RowAction | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [state, setState] = useState<
    | FileActionState
    | "file_changed"
    | "save_unknown"
    | FileReferenceResult
    | null
  >(null);
  const active = useRef<AbortController | null>(null);
  useEffect(() => {
    active.current?.abort();
    active.current = null;
    setPending(null);
    setState(null);
    return () => {
      active.current?.abort();
      active.current = null;
    };
  }, [
    taskId,
    runId,
    output.id,
    output.displayPath,
    output.redacted,
    output.sizeBytes,
    disabled,
  ]);
  const perform = async (action: RowAction, opener?: HTMLButtonElement) => {
    if (
      !onAction ||
      !taskId ||
      !runId ||
      disabled ||
      output.redacted ||
      active.current
    )
      return;
    const target: FileTarget = {
      kind: "output",
      taskId,
      runId,
      outputId: output.id,
    };
    const controller = new AbortController();
    active.current = controller;
    setPending(action);
    setCancelling(false);
    setState(null);
    try {
      const result = await onAction(
        target,
        action === "edit" || action === "preview" ? "check_current" : action,
        controller.signal,
      );
      if (
        action === "preview" &&
        result === "ready" &&
        opener?.isConnected &&
        !controller.signal.aborted &&
        active.current === controller
      ) {
        onPreview?.(taskId, output.displayPath, opener);
        return;
      }
      if (
        action === "edit" &&
        result === "ready" &&
        !controller.signal.aborted &&
        active.current === controller
      ) {
        const prepared = await onReference?.(
          target,
          output.displayPath,
          controller.signal,
        );
        if (active.current === controller)
          setState(prepared ?? "edit_unavailable");
        return;
      }
      if (active.current === controller)
        setState(
          controller.signal.aborted && action !== "save"
            ? "cancelled"
            : // Only `check` compares with what was delivered.
              result === "changed" && action !== "check"
              ? "file_changed"
              : result,
        );
    } catch {
      if (active.current === controller)
        setState(
          action === "save"
            ? "save_unknown"
            : controller.signal.aborted
              ? "cancelled"
              : "failed",
        );
    } finally {
      if (active.current === controller) {
        active.current = null;
        setPending(null);
      }
    }
  };
  return (
    <li className="run-output" data-output-id={output.id}>
      <span className="run-output-icon" aria-hidden="true">
        <Icon name="skill-file" />
      </span>
      <div className="run-output-content">
        <p className="run-output-name" id={nameId}>
          {output.redacted
            ? t("outputs.hidden_path")
            : output.displayPath.split("/").at(-1)}
        </p>
        {!output.redacted && output.displayPath.includes("/") && (
          <p className="run-output-path">{output.displayPath}</p>
        )}
        <p className="run-output-meta">
          {output.updated
            ? t("outputs.updated")
            : t("outputs.delivered_size", {
                bytes: formatInteger(locale, BigInt(output.sizeBytes)),
              })}
        </p>
        {onAction && taskId && runId && (
          <div className="run-output-actions">
            {output.open && (
              <Button
                type="button"
                variant="secondary"
                size="sm"
                aria-describedby={nameId}
                disabled={disabled || pending !== null || output.redacted}
                onClick={() => void perform("open")}
              >
                {t(
                  output.open === "browser"
                    ? "outputs.open_browser"
                    : "outputs.open",
                )}
              </Button>
            )}
            {onPreview && output.open === "browser" && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                aria-describedby={nameId}
                disabled={disabled || pending !== null || output.redacted}
                onClick={(event) =>
                  void perform("preview", event.currentTarget)
                }
              >
                {t("outputs.view_source")}
              </Button>
            )}
            <Button
              variant="ghost"
              size="sm"
              aria-describedby={nameId}
              disabled={disabled || pending !== null || output.redacted}
              onClick={() => void perform("check")}
            >
              {t("outputs.check")}
            </Button>
            <Button
              variant="ghost"
              size="sm"
              aria-describedby={nameId}
              disabled={disabled || pending !== null || output.redacted}
              onClick={() => void perform("reveal")}
            >
              {t("outputs.reveal")}
            </Button>
            <Button
              variant="ghost"
              size="sm"
              aria-describedby={nameId}
              disabled={disabled || pending !== null || output.redacted}
              onClick={() => void perform("save")}
            >
              {t("outputs.save")}
            </Button>
            {onReference && (
              <Button
                variant="ghost"
                size="sm"
                aria-describedby={nameId}
                disabled={disabled || pending !== null || output.redacted}
                onClick={() => void perform("edit")}
              >
                {t("outputs.edit")}
              </Button>
            )}
            {pending && (
              <Button
                variant="ghost"
                size="sm"
                disabled={cancelling}
                aria-describedby={nameId}
                onClick={() => {
                  active.current?.abort();
                  setCancelling(true);
                }}
              >
                {t("outputs.cancel")}
              </Button>
            )}
          </div>
        )}
        {(pending || state) && (
          <p className="run-output-status" role="status" aria-live="polite">
            {pending
              ? t(
                  cancelling
                    ? "outputs.cancelling"
                    : pending === "save"
                      ? "outputs.saving"
                      : "outputs.checking",
                )
              : state && t(`outputs.state.${state}`)}
          </p>
        )}
      </div>
    </li>
  );
}
