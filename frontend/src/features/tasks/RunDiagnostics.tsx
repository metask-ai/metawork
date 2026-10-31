import { useState } from "react";
import type { RunView } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

export function RunDiagnostics({ run }: { run: RunView }) {
  const { t } = useI18n();
  const [expanded, setExpanded] = useState(false);
  const terminal = run.terminal;
  const modelError = terminal?.modelError;
  if (!terminal || (terminal.cause !== "provider_failure" && !modelError))
    return null;
  return (
    <details
      className="run-diagnostics"
      onToggle={(event) => setExpanded(event.currentTarget.open)}
    >
      <summary className="focus-ring">{t("run.view_diagnostics")}</summary>
      {expanded && (
        <>
          {modelError && (
            <>
              {terminal.cause !== "provider_failure" && (
                <p>{t("run.model_error.supplemental")}</p>
              )}
              <p className="model-error-message">
                {!modelError.message ||
                (modelError.hostRedacted &&
                  /^[*?\s]+$/.test(modelError.message))
                  ? t("run.model_error.message_hidden")
                  : modelError.message}
              </p>
              {modelError.truncated && (
                <p>{t("run.model_error.upstream_truncated")}</p>
              )}
              {modelError.hostRedacted && (
                <p>{t("run.model_error.host_redacted")}</p>
              )}
              {modelError.hostTruncated && (
                <p>{t("run.model_error.host_truncated")}</p>
              )}
            </>
          )}
          <p>
            {t(
              modelError
                ? terminal.diagnosticDisposition === "withheld"
                  ? "run.model_error.diagnostic_withheld"
                  : "run.model_error.diagnostic_absent"
                : terminal.diagnosticDisposition === "withheld"
                  ? "run.provider_failure.diagnostic_withheld"
                  : "run.provider_failure.diagnostic_absent",
            )}
          </p>
          <dl className="task-facts">
            <div>
              <dt>{t("inspector.diagnostic_model")}</dt>
              <dd>{run.execution.model}</dd>
            </div>
            <div>
              <dt>{t("inspector.diagnostic_protocol")}</dt>
              <dd>
                {t(
                  `settings.custom_provider_protocol.${run.execution.protocol}`,
                )}
              </dd>
            </div>
            <div>
              <dt>{t("inspector.diagnostic_run")}</dt>
              <dd>{run.id}</dd>
            </div>
            <div>
              <dt>{t("inspector.diagnostic_code")}</dt>
              <dd>
                <code>{terminal.cause ?? terminal.outcome}</code>
              </dd>
            </div>
            {modelError && (
              <>
                <div>
                  <dt>{t("run.model_error.category_label")}</dt>
                  <dd>
                    {t(`run.model_error.category.${modelError.category}`)}
                  </dd>
                </div>
                <div>
                  <dt>{t("run.model_error.agent_run")}</dt>
                  <dd>{modelError.agentRunId}</dd>
                </div>
                {(["code", "type", "requestId"] as const).map(
                  (field) =>
                    modelError[field] !== null && (
                      <div key={field}>
                        <dt>{t(`run.model_error.${field}`)}</dt>
                        <dd>
                          {modelError[field] || t("run.model_error.empty")}
                        </dd>
                      </div>
                    ),
                )}
                {modelError.httpStatus !== null && (
                  <div>
                    <dt>HTTP</dt>
                    <dd>{modelError.httpStatus}</dd>
                  </div>
                )}
                <div>
                  <dt>{t("run.model_error.attempts")}</dt>
                  <dd>{modelError.attempts}</dd>
                </div>
                <div>
                  <dt>{t("run.model_error.retry_label")}</dt>
                  <dd>{t(`run.model_error.retry.${modelError.retry}`)}</dd>
                </div>
                {modelError.retryAfterMs !== null && (
                  <div>
                    <dt>{t("run.model_error.retry_after")}</dt>
                    <dd>{modelError.retryAfterMs} ms</dd>
                  </div>
                )}
              </>
            )}
          </dl>
        </>
      )}
    </details>
  );
}
