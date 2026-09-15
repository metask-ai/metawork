import type { ToolView } from "../../bridge/contracts.ts";
import { CodeBlock } from "../../components/ai/index.ts";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
import { copyCodeText } from "./response-copy.ts";

export function ToolDetailView({ tool, id }: { tool: ToolView; id?: string }) {
  const { locale, t } = useI18n();
  const bash = tool.bash;
  const hasReadableDetails = bash?.command != null || bash?.result != null;
  const copy = {
    label: t("copy.code"),
    copiedLabel: t("copy.copied"),
    failedLabel: t("copy.failed"),
    onCopy: copyCodeText,
  };
  const field = (label: string, value: string) => (
    <div className="detail-field">
      <p className="detail-field-label">{label}</p>
      <CodeBlock aria-label={label} value={value} copy={copy} />
    </div>
  );
  const rawDetails = (["input", "content"] as const).map((name) =>
    tool[name] ? (
      <div key={name}>
        {field(
          t(`inspector.tool.${name === "content" ? "result" : name}`),
          tool[name],
        )}
      </div>
    ) : null,
  );

  return (
    <div
      className="run-process-tool-detail"
      id={id}
      role="region"
      aria-label={t("run.process.tool_detail", { name: tool.name })}
    >
      {bash?.command != null &&
        field(t("inspector.tool.command"), bash.command)}
      {tool.progress && field(t("inspector.tool.progress"), tool.progress)}
      {bash?.result && (
        <>
          <p className="detail-field-label">
            {t("inspector.tool.exit_code", {
              code: formatInteger(locale, BigInt(bash.result.exitCode)),
            })}
          </p>
          {(["stdout", "stderr"] as const).map((stream) => (
            <div key={stream}>
              {bash.result![stream] ? (
                field(t(`inspector.tool.${stream}`), bash.result![stream])
              ) : (
                <p className="projection-note">
                  {t(`inspector.tool.${stream}_empty`)}
                </p>
              )}
              {bash.result![`${stream}Incomplete`] && (
                <p className="projection-note">
                  {t(`inspector.tool.${stream}_incomplete`)}
                </p>
              )}
            </div>
          ))}
        </>
      )}
      {hasReadableDetails ? (
        <details className="tool-raw-details">
          <summary className="focus-ring">
            {t("inspector.tool.raw_details")}
          </summary>
          {rawDetails}
        </details>
      ) : (
        rawDetails
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
