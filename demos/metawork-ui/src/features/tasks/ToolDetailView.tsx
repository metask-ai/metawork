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

function ToolFact({ label, value }: { label: string; value: string }) {
  return (
    <div className="tool-detail-fact">
      <span>{label}</span>
      <code>{value}</code>
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

function SemanticToolDetails({ tool }: { tool: ToolView }) {
  const { locale, t } = useI18n();
  const presentation = tool.presentation;
  if (!presentation) return null;
  switch (presentation.kind) {
    case "read":
      return (
        <>
          {(presentation.offset || presentation.limit) && (
            <div className="tool-detail-facts">
              {presentation.offset && (
                <ToolFact
                  label={t("inspector.tool.start_line")}
                  value={formatInteger(locale, BigInt(presentation.offset))}
                />
              )}
              {presentation.limit && (
                <ToolFact
                  label={t("inspector.tool.line_limit")}
                  value={formatInteger(locale, BigInt(presentation.limit))}
                />
              )}
            </div>
          )}
          {tool.content && (
            <ToolField
              label={t("inspector.tool.read_content")}
              value={tool.content}
            />
          )}
        </>
      );
    case "glob":
    case "grep":
      return (
        <>
          {(presentation.scope ||
            (presentation.kind === "grep" && presentation.include)) && (
            <div className="tool-detail-facts">
              {presentation.scope && (
                <ToolFact
                  label={t("inspector.tool.scope")}
                  value={presentation.scope}
                />
              )}
              {presentation.kind === "grep" && presentation.include && (
                <ToolFact
                  label={t("inspector.tool.file_filter")}
                  value={presentation.include}
                />
              )}
            </div>
          )}
          {tool.content && (
            <ToolField
              label={t("inspector.tool.matches")}
              value={tool.content}
            />
          )}
        </>
      );
    case "bash_output":
      return presentation.result ? (
        <>
          <div className="tool-detail-facts">
            <ToolFact
              label={t("inspector.tool.process_status")}
              value={t(`inspector.tool.process_${presentation.result.status}`)}
            />
          </div>
          {presentation.result.stdout && (
            <ToolField
              label={t("inspector.tool.stdout")}
              value={presentation.result.stdout}
            />
          )}
          {presentation.result.stdoutIncomplete && (
            <p className="projection-note">
              {t("inspector.tool.stdout_incomplete")}
            </p>
          )}
          {presentation.result.stderr && (
            <ToolField
              label={t("inspector.tool.stderr")}
              value={presentation.result.stderr}
            />
          )}
          {presentation.result.stderrIncomplete && (
            <p className="projection-note">
              {t("inspector.tool.stderr_incomplete")}
            </p>
          )}
        </>
      ) : null;
    case "web_fetch":
      return (
        <>
          {(presentation.prompt || presentation.result?.bytes) && (
            <div className="tool-detail-facts">
              {presentation.prompt && (
                <ToolFact
                  label={t("inspector.tool.purpose")}
                  value={presentation.prompt}
                />
              )}
              {presentation.result?.bytes && (
                <ToolFact
                  label={t("inspector.tool.bytes")}
                  value={formatInteger(
                    locale,
                    BigInt(presentation.result.bytes),
                  )}
                />
              )}
            </div>
          )}
          {presentation.result?.content && (
            <ToolField
              label={t("inspector.tool.web_content")}
              value={presentation.result.content}
            />
          )}
        </>
      );
    case "write":
    case "edit":
    case "kill_shell":
    case "web_search":
      return null;
  }
}

function GenericToolDetails({ tool }: { tool: ToolView }) {
  return <RawToolFields tool={tool} names={["input", "content"]} />;
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
      {tool.errorDetail ? (
        <ToolField
          label={t("inspector.tool.error_detail")}
          value={tool.errorDetail}
        />
      ) : tool.isError ? (
        <RawToolFields tool={tool} names={["content"]} />
      ) : isBash ? (
        <BashToolDetails tool={tool} />
      ) : tool.presentation ? (
        <SemanticToolDetails tool={tool} />
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
