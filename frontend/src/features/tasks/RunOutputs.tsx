import { useEffect, useId, useRef, useState } from "react";
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

export function RunOutputs({
  outputs,
  taskId,
  runId,
  disabled = false,
  onAction,
}: {
  outputs: readonly DeliveredOutputView[];
  taskId?: string;
  runId?: string;
  disabled?: boolean;
  onAction?: OutputActionHandler;
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
}: {
  output: DeliveredOutputView;
  taskId?: string;
  runId?: string;
  disabled: boolean;
  onAction?: OutputActionHandler;
}) {
  const { locale, t } = useI18n();
  const nameId = useId();
  const [pending, setPending] = useState(false);
  const [state, setState] = useState<OutputActionState | null>(null);
  const active = useRef<AbortController | null>(null);
  useEffect(() => {
    active.current?.abort();
    active.current = null;
    setPending(false);
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
  const perform = async (action: OutputAction) => {
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
    setPending(true);
    setState(null);
    try {
      const result = await onAction(
        taskId,
        runId,
        output.id,
        action,
        controller.signal,
      );
      if (!controller.signal.aborted && active.current === controller)
        setState(result);
    } catch {
      if (!controller.signal.aborted && active.current === controller)
        setState("failed");
    } finally {
      if (active.current === controller) {
        active.current = null;
        setPending(false);
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
              disabled={disabled || pending || output.redacted}
              onClick={() => void perform("check")}
            >
              {t("outputs.check")}
            </Button>
            <Button
              variant="ghost"
              size="sm"
              aria-describedby={nameId}
              disabled={disabled || pending || output.redacted}
              onClick={() => void perform("reveal")}
            >
              {t("outputs.reveal")}
            </Button>
            {pending && (
              <Button
                variant="ghost"
                size="sm"
                onClick={() => {
                  active.current?.abort();
                  active.current = null;
                  setPending(false);
                  setState("cancelled");
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
              ? t("outputs.checking")
              : state && t(`outputs.state.${state}`)}
          </p>
        )}
      </div>
    </li>
  );
}
