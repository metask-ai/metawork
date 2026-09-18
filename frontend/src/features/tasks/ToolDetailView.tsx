import type { ToolView } from "../../bridge/contracts.ts";
import { CodeBlock } from "../../components/ai/index.ts";
import { useI18n } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";

type RawFieldName = "input" | "content";

function ToolField({ label, value }: { label: string; value: string }) {
  return (
    <div className="detail-field">
      <p className="detail-field-label">{label}</p>
      <CodeBlock
        className="tool-evidence-surface"
        aria-label={label}
        value={value}
      />
    </div>
  );
}

function RawToolFields({
  tool,
  names,
}: {
  tool: ToolView;
  names: readonly RawFieldName[];
}) {
  const { t } = useI18n();
  return names.map((name) =>
    tool[name] ? (
      <ToolField
        key={name}
        label={t(`inspector.tool.${name === "content" ? "result" : name}`)}
        value={tool[name]}
      />
    ) : null,
  );
}

function BashToolDetails({ tool }: { tool: ToolView }) {
  const { locale, t } = useI18n();
  const bash = tool.bash;
  const hasReadableDetails = bash?.command != null || bash?.result != null;
  const hasUnparsedInput = Boolean(tool.input) && bash?.command == null;
  const hasUnparsedResult = tool.state !== "running" && bash?.result == null;
  const hasUnparsedDetails = hasUnparsedInput || hasUnparsedResult;
  const unparsedFields = (["input", "content"] as const).filter(
    (name) =>
      Boolean(tool[name]) &&
      (name === "input" ? bash?.command == null : bash?.result == null),
  );

  return (
    <>
      {bash?.command != null && (
        <ToolField label={t("inspector.tool.command")} value={bash.command} />
      )}
      {tool.progress && (
        <ToolField label={t("inspector.tool.progress")} value={tool.progress} />
      )}
      {bash?.result && (
        <>
          <p
            className="bash-exit-status"
            data-status={bash.result.exitCode === 0 ? "succeeded" : "failed"}
          >
            {t(
              bash.result.exitCode === 0
                ? "inspector.tool.command_succeeded"
                : "inspector.tool.command_failed",
              { code: formatInteger(locale, BigInt(bash.result.exitCode)) },
            )}
          </p>
          {bash.result.stdout && (
            <ToolField
              label={t("inspector.tool.stdout")}
              value={bash.result.stdout}
            />
          )}
          {bash.result.stdoutIncomplete && (
            <p className="projection-note">
              {t("inspector.tool.stdout_incomplete")}
            </p>
          )}
          {bash.result.stderr && (
            <ToolField
              label={t("inspector.tool.stderr")}
              value={bash.result.stderr}
            />
          )}
          {bash.result.stderrIncomplete && (
            <p className="projection-note">
              {t("inspector.tool.stderr_incomplete")}
            </p>
          )}
        </>
      )}
      {hasUnparsedDetails && hasReadableDetails && (
        <>
          <p className="projection-note">
            {t("inspector.tool.bash_partially_unparsed")}
          </p>
          {unparsedFields.length > 0 && (
            <details className="tool-unparsed-details">
              <summary className="focus-ring">
                {t("inspector.tool.unparsed_data")}
              </summary>
              <RawToolFields tool={tool} names={unparsedFields} />
            </details>
          )}
        </>
      )}
      {hasUnparsedDetails && !hasReadableDetails && (
        <>
          <p className="projection-note">{t("inspector.tool.bash_unparsed")}</p>
          <RawToolFields tool={tool} names={unparsedFields} />
        </>
      )}
    </>
  );
}

function GenericToolDetails({ tool }: { tool: ToolView }) {
  const { t } = useI18n();
  return (
    <>
      {tool.progress && (
        <ToolField label={t("inspector.tool.progress")} value={tool.progress} />
      )}
      <RawToolFields tool={tool} names={["input", "content"]} />
    </>
  );
}

export function ToolDetailView({ tool, id }: { tool: ToolView; id?: string }) {
  const { t } = useI18n();
  const isBash = tool.name === "Bash";

  return (
    <div
      className="run-process-tool-detail"
      id={id}
      role="region"
      aria-label={t("run.process.tool_detail", { name: tool.name })}
    >
      {isBash ? (
        <BashToolDetails tool={tool} />
      ) : (
        <GenericToolDetails tool={tool} />
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
