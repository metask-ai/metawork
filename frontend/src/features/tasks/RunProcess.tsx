import { useId, type ReactNode } from "react";

import type { RunActivity, RunView, ToolView } from "../../bridge/contracts.ts";
import { Markdown } from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type I18nValue, type MessageId } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
import type { RunPresentation } from "./run-presentation.ts";

function activityMessage(activity: RunActivity): MessageId {
  switch (activity.kind) {
    case "queued":
    case "starting":
      return "run.activity.starting";
    case "waiting_model":
      return "run.activity.waiting_model";
    case "thinking":
      return "run.activity.thinking";
    case "writing_response":
      return "run.activity.writing_response";
    case "executing_tools":
      return "run.activity.executing_tools";
    case "retrying_provider":
      return "run.activity.retrying_provider";
    case "waiting_user":
      return "task.phase.waiting_ui";
    case "compacting_context":
      return "run.activity.compacting_context";
    case "finalizing":
      return "run.activity.finishing";
    case "stopping":
      return "task.phase.stopping";
  }
}

function activityDetail(
  activity: RunActivity,
  locale: I18nValue["locale"],
  t: I18nValue["t"],
): string | null {
  if (activity.kind === "executing_tools" && activity.inFlight) {
    const count = BigInt(activity.inFlight);
    return t(
      count === 1n
        ? "run.activity.tool_running_one"
        : "run.activity.tool_running_many",
      { count: formatInteger(locale, count) },
    );
  }
  if (
    activity.kind === "retrying_provider" &&
    activity.attempt &&
    activity.max &&
    activity.delayMs
  ) {
    const values = {
      attempt: formatInteger(locale, BigInt(activity.attempt)),
      max: formatInteger(locale, BigInt(activity.max)),
      delay: formatInteger(locale, BigInt(activity.delayMs)),
    };
    return t(
      activity.delayMs === "0"
        ? "run.activity.retry_detail_now"
        : "run.activity.retry_detail",
      values,
    );
  }
  return null;
}

function toolStateMessage(tool: ToolView): MessageId {
  switch (tool.state) {
    case "running":
      return "inspector.tool.running";
    case "completed":
      return "inspector.tool.completed";
    case "failed":
      return "inspector.tool.failed";
  }
}

function ProcessHeader({
  active,
  title,
  detail,
  collapsible,
  expanded,
  controls,
  onToggle,
}: {
  active: boolean;
  title: ReactNode;
  detail: ReactNode;
  collapsible: boolean;
  expanded: boolean;
  controls: string;
  onToggle: () => void;
}) {
  const content = (
    <>
      <span className="run-process-mark" aria-hidden="true" />
      <span
        className="run-process-heading"
        aria-live={active ? "polite" : undefined}
        aria-atomic={active ? "true" : undefined}
      >
        <strong>{title}</strong>
        {detail && <small>{detail}</small>}
      </span>
      {collapsible && (
        <span className="run-process-chevron">
          <Icon name="chevron" />
        </span>
      )}
    </>
  );

  return collapsible ? (
    <button
      type="button"
      className="run-process-header focus-ring"
      aria-expanded={expanded}
      aria-controls={expanded ? controls : undefined}
      onClick={onToggle}
    >
      {content}
    </button>
  ) : (
    <div className="run-process-header">{content}</div>
  );
}

function ProcessTool({
  tool,
  onOpen,
}: {
  tool: ToolView;
  onOpen?: () => void;
}) {
  const { locale, t } = useI18n();
  const elapsed = BigInt(tool.elapsedMs);
  const content = (
    <>
      <span className="run-process-tool-mark" aria-hidden="true" />
      <span className="run-process-tool-name">{tool.name}</span>
      <span className="run-process-tool-meta">
        <span>{t(toolStateMessage(tool))}</span>
        {tool.state !== "running" && elapsed > 0n && (
          <span>
            {t("inspector.tool.elapsed", {
              duration: formatInteger(locale, elapsed),
            })}
          </span>
        )}
        {onOpen && <Icon name="chevron-right" />}
      </span>
    </>
  );

  return (
    <li data-state={tool.state}>
      {onOpen ? (
        <button
          type="button"
          className="run-process-tool focus-ring"
          aria-label={t("run.process.open_tool", { name: tool.name })}
          onClick={onOpen}
        >
          {content}
        </button>
      ) : (
        <div className="run-process-tool">{content}</div>
      )}
    </li>
  );
}

function terminalDetail(
  presentation: RunPresentation,
  locale: I18nValue["locale"],
  t: I18nValue["t"],
): string | null {
  if (presentation.toolCount === 0) return null;
  const count = formatInteger(locale, BigInt(presentation.toolCount));
  const steps = t(
    presentation.toolCount === 1
      ? "run.process.tool_step_one"
      : "run.process.tool_step_many",
    { count },
  );
  if (presentation.failedToolCount === 0) return steps;
  return `${steps} · ${t("run.process.failed_steps", {
    count: formatInteger(locale, BigInt(presentation.failedToolCount)),
  })}`;
}

export function RunProcess({
  run,
  presentation,
  expanded,
  onExpandedChange,
  onOpenTool,
}: {
  run: RunView;
  presentation: RunPresentation;
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
  onOpenTool?: (tool: ToolView) => void;
}) {
  const { locale, t } = useI18n();
  const bodyId = useId();
  if (!presentation.processVisible) return null;

  const activity = presentation.activity;
  const title = activity
    ? t(activityMessage(activity))
    : t("run.process.title");
  const detail = activity
    ? (presentation.runningToolName ?? activityDetail(activity, locale, t))
    : terminalDetail(presentation, locale, t);
  const showBody = expanded && presentation.processCanCollapse;

  return (
    <section
      className="run-process"
      data-active={presentation.active}
      data-expanded={showBody}
    >
      <ProcessHeader
        active={presentation.active}
        title={title}
        detail={detail}
        collapsible={presentation.processCanCollapse}
        expanded={showBody}
        controls={bodyId}
        onToggle={() => onExpandedChange(!showBody)}
      />
      {showBody && (
        <div className="run-process-body" id={bodyId}>
          {run.output.commentary && (
            <div className="run-process-commentary">
              <Markdown>{run.output.commentary}</Markdown>
            </div>
          )}
          {run.output.provisional && (
            <div
              className="run-process-provisional"
              aria-label={t("run.process.live_output")}
            >
              <span>{t("run.process.live_output")}</span>
              <p>{run.output.provisional}</p>
            </div>
          )}
          {run.output.provisionalRedacted && (
            <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
          )}
          {presentation.tools.length > 0 && (
            <ul className="run-process-tools">
              {presentation.tools.map((tool) => (
                <ProcessTool
                  key={tool.id}
                  tool={tool}
                  onOpen={onOpenTool ? () => onOpenTool(tool) : undefined}
                />
              ))}
            </ul>
          )}
        </div>
      )}
    </section>
  );
}
