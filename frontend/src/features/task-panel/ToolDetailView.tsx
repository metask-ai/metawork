import type { ToolView } from "../../bridge/contracts.ts";
import { CodeBlock } from "../../components/ai/index.ts";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";

export function ToolDetailView({ tool }: { tool: ToolView }) {
  const { locale, t } = useI18n();
  return (
    <div className="tool-detail-view">
      <header>
        <h3>{tool.name}</h3>
        <span>{t(`inspector.tool.${tool.state}`)}</span>
        {BigInt(tool.elapsedMs) > 0n && (
          <span>
            {t("inspector.tool.elapsed", {
              duration: formatInteger(locale, BigInt(tool.elapsedMs)),
            })}
          </span>
        )}
      </header>
      {(["input", "progress", "content"] as const).map(
        (field) =>
          tool[field] && (
            <div className="detail-field" key={field}>
              <p className="detail-field-label">
                {t(`inspector.tool.${field === "content" ? "result" : field}`)}
              </p>
              <CodeBlock
                aria-label={t(
                  `inspector.tool.${field === "content" ? "result" : field}`,
                )}
                value={tool[field]}
              />
            </div>
          ),
      )}
      {(tool.inputTruncated ||
        tool.progressTruncated ||
        tool.contentTruncated) && (
        <p className="projection-note">{t("inspector.tool.truncated")}</p>
      )}
      {tool.redacted && (
        <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
      )}
    </div>
  );
}
