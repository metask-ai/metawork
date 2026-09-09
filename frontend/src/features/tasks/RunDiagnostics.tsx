import { useState } from "react";
import type { RunView } from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";

export function RunDiagnostics({ run }: { run: RunView }) {
  const { t } = useI18n();
  const [expanded, setExpanded] = useState(false);
  if (run.terminal?.cause !== "provider_failure") return null;
  return (
    <details
      className="run-diagnostics"
      onToggle={(event) => setExpanded(event.currentTarget.open)}
    >
      <summary className="focus-ring">{t("run.view_diagnostics")}</summary>
      {expanded && (
        <>
          <p>
            {t(
              run.terminal.diagnosticDisposition === "withheld"
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
                <code>provider_failure</code>
              </dd>
            </div>
          </dl>
        </>
      )}
    </details>
  );
}
