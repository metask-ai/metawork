import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { Button } from "../../components/ui/button.tsx";
import type {
  OutputAction,
  OutputActionHandler,
  OutputActionState,
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
type RowAction = OutputAction | "edit";
export function RunOutputs({
  outputs,
  taskId,
  runId,
  disabled = false,
  onAction,
  onPrepareEdit,
}: {
  outputs: readonly DeliveredOutputView[];
  taskId?: string;
  runId?: string;
  disabled?: boolean;
  onAction?: OutputActionHandler;
  onPrepareEdit?: OutputEditHandler;
}) {
  const { t } = useI18n();
  if (outputs.length === 0) return null;
  return (
    <section className="run-outputs" aria-label={t("outputs.title")}>
      <h3 className="run-outputs-title">{t("outputs.title")}</h3>
      <ul className="run-outputs-list">
        {outputs.map((output) => (
          <OutputRow
            key={output.id}
            output={output}
            taskId={taskId}
            runId={runId}
            disabled={disabled}
            onAction={onAction}
            onPrepareEdit={onPrepareEdit}
          />
        ))}
      </ul>
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
}: {
  output: DeliveredOutputView;
  taskId?: string;
  runId?: string;
  disabled: boolean;
  onAction?: OutputActionHandler;
  onPrepareEdit?: OutputEditHandler;
}) {
  const { locale, t } = useI18n();
  const nameId = useId();
  const [pending, setPending] = useState<RowAction | null>(null);
  const [cancelling, setCancelling] = useState(false);
  const [state, setState] = useState<
    OutputActionState | "save_unknown" | OutputEditResult | null
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
  const perform = async (action: RowAction) => {
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
        taskId,
        runId,
        output.id,
        action === "edit" ? "check" : action,
        controller.signal,
      );
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
          controller.signal.aborted && action !== "save" ? "cancelled" : result,
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
          {t("outputs.delivered_size", {
            bytes: formatInteger(locale, BigInt(output.sizeBytes)),
          })}
        </p>
        {onAction && taskId && runId && (
          <div className="run-output-actions">
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
            {onPrepareEdit && (
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
