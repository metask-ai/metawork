import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { Button } from "../../components/ui/button.tsx";
import type {
  FileAction,
  FileActionHandler,
  FileActionState,
  DeliveredOutputView,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
export type OutputEditResult =
  "edit_prepared" | "edit_draft_busy" | "edit_too_long" | "edit_unavailable";
export type OutputEditHandler = (
  taskId: string,
  runId: string,
  outputId: string,
) => OutputEditResult;
type RowAction =
  Exclude<FileAction, "check_current" | "copy_path"> | "edit" | "preview";
type OutputPreview = (
  taskId: string,
  path: string,
  opener: HTMLButtonElement,
) => void;
export function RunOutputs({
  outputs,
  taskId,
  runId,
  disabled = false,
  onAction,
  onPrepareEdit,
  onPreview,
  layout = "outputs",
}: {
  outputs: readonly (DeliveredOutputView & { runId?: string })[];
  taskId?: string;
  runId?: string;
  disabled?: boolean;
  onAction?: FileActionHandler;
  onPrepareEdit?: OutputEditHandler;
  onPreview?: OutputPreview;
  layout?: "outputs" | "file-actions" | "conversation";
}) {
  const { t } = useI18n();
  if (outputs.length === 0) return null;
  const actionsOnly = layout === "file-actions";
  const rows = (
    <ul className="run-outputs-list">
      {outputs.map((output) => (
        <OutputRow
          key={output.id}
          output={output}
          taskId={taskId}
          runId={output.runId ?? runId}
          disabled={disabled}
          onAction={onAction}
          onPrepareEdit={onPrepareEdit}
          onPreview={onPreview}
          actionsOnly={actionsOnly}
        />
      ))}
    </ul>
  );
  if (layout !== "outputs") return rows;
  return (
    <section className="run-outputs" aria-label={t("outputs.title")}>
      <h3 className="run-outputs-title">{t("outputs.title")}</h3>
      {rows}
    </section>
  );
}
function OutputRow({
  output,
  taskId,
  runId,
  disabled,
  onAction,
  onPrepareEdit,
  onPreview,
  actionsOnly,
}: {
  output: DeliveredOutputView;
  taskId?: string;
  runId?: string;
  disabled: boolean;
  onAction?: FileActionHandler;
  onPrepareEdit?: OutputEditHandler;
  onPreview?: OutputPreview;
  actionsOnly: boolean;
}) {
  const { locale, t } = useI18n();
  const nameId = useId();
  const [pending, setPending] = useState<RowAction | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [state, setState] = useState<
    FileActionState | "file_changed" | "save_unknown" | OutputEditResult | null
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
    const controller = new AbortController();
    active.current = controller;
    setPending(action);
    setCancelling(false);
    setState(null);
    try {
      const result = await onAction(
        { kind: "output", taskId, runId, outputId: output.id },
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
        setState(
          onPrepareEdit?.(taskId, runId, output.id) ?? "edit_unavailable",
        );
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
    <li
      className={actionsOnly ? undefined : "run-output"}
      data-output-id={output.id}
    >
      {!actionsOnly && (
        <span className="run-output-icon" aria-hidden="true">
          <Icon name="skill-file" />
        </span>
      )}
      <div className="run-output-content">
        <p className="run-output-name" id={nameId}>
          {output.redacted
            ? t("outputs.hidden_path")
            : output.displayPath.split("/").at(-1)}
        </p>
        {!actionsOnly &&
          !output.redacted &&
          output.displayPath.includes("/") && (
            <p className="run-output-path">{output.displayPath}</p>
          )}
        {!actionsOnly && (
          <p className="run-output-meta">
            {output.updated
              ? t("outputs.updated")
              : t("outputs.delivered_size", {
                  bytes: formatInteger(locale, BigInt(output.sizeBytes)),
                })}
          </p>
        )}
        {onAction && taskId && runId && (
          <div className="run-output-actions">
            {!actionsOnly && output.open && (
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
            {!actionsOnly && onPreview && output.open === "browser" && (
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
            {!actionsOnly && (
              <Button
                variant="ghost"
                size="sm"
                aria-describedby={nameId}
                disabled={disabled || pending !== null || output.redacted}
                onClick={() => void perform("check")}
              >
                {t("outputs.check")}
              </Button>
            )}
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
            {!actionsOnly && onPrepareEdit && (
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
