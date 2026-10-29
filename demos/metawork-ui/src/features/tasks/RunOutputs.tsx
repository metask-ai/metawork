import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { Button } from "../../components/ui/button.tsx";
import type {
  OutputAction,
  OutputActionHandler,
  OutputActionState,
  DeliveredOutputView,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { Ellipsis } from "lucide-react";
import { Menu } from "../../components/ui/menu.tsx";
import type { MarkdownReference } from "../../components/ai/Markdown.tsx";
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
  references,
}: {
  outputs: readonly DeliveredOutputView[];
  taskId?: string;
  runId?: string;
  disabled?: boolean;
  onAction?: OutputActionHandler;
  onPrepareEdit?: OutputEditHandler;
  references?: ReadonlyMap<string, MarkdownReference>;
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
            reference={references?.get(output.displayPath)}
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
  reference,
}: {
  output: DeliveredOutputView;
  taskId?: string;
  runId?: string;
  disabled: boolean;
  onAction?: OutputActionHandler;
  onPrepareEdit?: OutputEditHandler;
  reference?: MarkdownReference;
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
          {reference && !output.redacted ? (
            <button
              type="button"
              className="run-output-open focus-ring"
              aria-label={reference.label}
              disabled={disabled || pending !== null}
              onClick={(event) => reference.onOpen(event.currentTarget)}
            >
              {output.displayPath.split("/").at(-1)}
            </button>
          ) : output.redacted ? (
            t("outputs.hidden_path")
          ) : (
            output.displayPath.split("/").at(-1)
          )}
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
            {onPrepareEdit && (
              <Button
                variant="ghost"
                size="sm"
                className="run-output-edit"
                aria-describedby={nameId}
                disabled={disabled || pending !== null || output.redacted}
                onClick={() => void perform("edit")}
              >
                {t("outputs.edit")}
              </Button>
            )}
            <Menu.Root>
              <Menu.Trigger
                className="run-output-more"
                aria-label={`${t("outputs.title")} · ${output.displayPath.split("/").at(-1)}`}
                aria-describedby={nameId}
                disabled={disabled || pending !== null || output.redacted}
              >
                <Ellipsis size={18} aria-hidden="true" />
              </Menu.Trigger>
              <Menu.Portal>
                <Menu.Positioner align="end" collisionPadding={12}>
                  <Menu.Popup
                    className="run-output-menu"
                    aria-labelledby={nameId}
                  >
                    <Menu.Item onClick={() => void perform("check")}>
                      {t("outputs.check")}
                    </Menu.Item>
                    <Menu.Item onClick={() => void perform("reveal")}>
                      {t("outputs.reveal")}
                    </Menu.Item>
                    <Menu.Item onClick={() => void perform("save")}>
                      {t("outputs.save")}
                    </Menu.Item>
                  </Menu.Popup>
                </Menu.Positioner>
              </Menu.Portal>
            </Menu.Root>
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
