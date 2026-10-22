import type { DeliveredOutputView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";

export function RunOutputs({
  outputs,
}: {
  outputs: readonly DeliveredOutputView[];
}) {
  const { locale, t } = useI18n();
  if (outputs.length === 0) return null;
  return (
    <section className="run-outputs" aria-label={t("outputs.title")}>
      <h3 className="run-outputs-title">{t("outputs.title")}</h3>
      <ul className="run-outputs-list">
        {outputs.map((output) => (
          <li className="run-output" key={output.id} data-output-id={output.id}>
            <span className="run-output-icon" aria-hidden="true">
              <Icon name="skill-file" />
            </span>
            <div className="run-output-content">
              <p className="run-output-name">
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
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
