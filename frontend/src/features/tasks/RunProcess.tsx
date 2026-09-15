import { useEffect, useId, useState, type ReactNode } from "react";

import type { RunActivity, ToolView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type I18nValue, type MessageId } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
import { runElapsedSeconds, type RunPresentation } from "./run-presentation.ts";
import { ToolDetailView } from "./ToolDetailView.tsx";

const emptyExpandedToolIds: ReadonlySet<string> = new Set();

function toolActivityMessage(name: string | null): MessageId {
  switch (name) {
    case "Read":
    case "Glob":
    case "Grep":
    case "WebSearch":
    case "WebFetch":
      return "run.activity.inspecting_workspace";
    case "Write":
    case "Edit":
      return "run.activity.updating_content";
    case "Bash":
    case "BashOutput":
    case "KillShell":
      return "run.activity.running_operation";
    default:
      return "run.activity.executing_tools";
  }
}

function activityMessage(
  activity: RunActivity,
  runningToolName: string | null,
): MessageId {
  switch (activity.kind) {
    case "queued":
      return "run.activity.queued";
    case "starting":
      return "run.activity.starting";
    case "waiting_model":
      return "run.activity.waiting_model";
    case "thinking":
      return "run.activity.thinking";
    case "writing_response":
      return "run.activity.writing_response";
    case "executing_tools":
      return toolActivityMessage(runningToolName);
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

function toolDetailAvailable(tool: ToolView): boolean {
  return Boolean(
    tool.bash?.command != null ||
    tool.bash?.result != null ||
    tool.input ||
    tool.progress ||
    tool.content ||
    tool.inputTruncated ||
    tool.progressTruncated ||
    tool.contentTruncated ||
    tool.redacted,
  );
}

function toolSummary(tool: ToolView): string | null {
  const fileNames = tool.fileRefs
    .map((reference) => reference.displayPath)
    .join(", ");
  const summary = tool.bash?.description || tool.progress || fileNames;
  if (!summary) return null;
  return summary.length > 160 ? `${summary.slice(0, 160)}…` : summary;
}

function ProcessHeader({
  active,
  title,
  detail,
  elapsed,
  collapsible,
  expanded,
  controls,
  onToggle,
}: {
  active: boolean;
  title: ReactNode;
  detail: ReactNode;
  elapsed: ReactNode;
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
      {elapsed}
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

function RunElapsed({
  elapsedMs,
  receivedAt,
  synchronized,
}: {
  elapsedMs: string;
  receivedAt: number;
  synchronized: boolean;
}) {
  const { locale, t } = useI18n();
  const [now, setNow] = useState(() =>
    synchronized ? performance.now() : receivedAt,
  );
  useEffect(() => {
    if (!synchronized) return;
    const interval = window.setInterval(() => setNow(performance.now()), 1000);
    return () => window.clearInterval(interval);
  }, [synchronized]);
  const seconds = runElapsedSeconds(elapsedMs, receivedAt, now);
  const duration = `${formatInteger(locale, seconds / 60n)}:${String(seconds % 60n).padStart(2, "0")}`;
  // Outside the live region: elapsed seconds are not progress.
  return (
    <small className="run-process-elapsed" aria-live="off">
      {t("run.elapsed", { duration })}
    </small>
  );
}

function ProcessTool({
  tool,
  expanded,
  onExpandedChange,
}: {
  tool: ToolView;
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
}) {
  const { locale, t } = useI18n();
  const detailId = useId();
  const elapsed = BigInt(tool.elapsedMs);
  const hasDetails = toolDetailAvailable(tool);
  const summary = toolSummary(tool);
  const content = (
    <>
      <span className="run-process-tool-mark" aria-hidden="true" />
      <span className="run-process-tool-label">
        <span className="run-process-tool-name">{tool.name}</span>
        {summary && (
          <span className="run-process-tool-description" title={summary}>
            {summary}
          </span>
        )}
      </span>
      <span className="run-process-tool-meta">
        <span>{t(toolStateMessage(tool))}</span>
        {tool.state !== "running" && elapsed > 0n && (
          <span>
            {t("inspector.tool.elapsed", {
              duration: formatInteger(locale, elapsed),
            })}
          </span>
        )}
        {hasDetails && (
          <span className="run-process-tool-chevron" aria-hidden="true">
            <Icon name="chevron" />
          </span>
        )}
      </span>
    </>
  );

  return (
    <li data-state={tool.state}>
      {hasDetails ? (
        <button
          type="button"
          className="run-process-tool focus-ring"
          aria-label={t("run.process.toggle_tool", { name: tool.name })}
          aria-expanded={expanded}
          aria-controls={detailId}
          onClick={() => onExpandedChange(!expanded)}
        >
          {content}
        </button>
      ) : (
        <div className="run-process-tool">{content}</div>
      )}
      {hasDetails && expanded && <ToolDetailView id={detailId} tool={tool} />}
    </li>
  );
}

export function RunProcess({
  presentation,
  elapsedMs = null,
  snapshotReceivedAt = null,
  synchronized = true,
  requestingStop = false,
  expanded,
  onExpandedChange,
  expandedToolIds = emptyExpandedToolIds,
  onToolExpandedChange = () => {},
}: {
  presentation: RunPresentation;
  elapsedMs?: string | null;
  snapshotReceivedAt?: number | null;
  synchronized?: boolean;
  requestingStop?: boolean;
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
  expandedToolIds?: ReadonlySet<string>;
  onToolExpandedChange?: (toolId: string, expanded: boolean) => void;
}) {
  const { locale, t } = useI18n();
  const bodyId = useId();
  if (!presentation.processVisible) return null;

  const activity = presentation.activity;
  const unsynchronized = presentation.active && !synchronized;
  const stopPending =
    presentation.active && requestingStop && activity?.kind !== "stopping";
  const title = unsynchronized
    ? t("run.activity.unsynchronized")
    : stopPending
      ? t("run.activity.requesting_stop")
      : activity
        ? t(activityMessage(activity, presentation.runningToolName))
        : t("run.process.title");
  const detail =
    unsynchronized || stopPending
      ? null
      : activity
        ? activityDetail(activity, locale, t)
        : null;
  const showBody = expanded && presentation.processCanCollapse;

  return (
    <section
      className="run-process"
      data-active={presentation.active && synchronized}
      data-expanded={showBody}
    >
      <ProcessHeader
        active={presentation.active && synchronized}
        title={title}
        detail={detail}
        elapsed={
          presentation.active &&
          elapsedMs !== null &&
          snapshotReceivedAt !== null ? (
            <RunElapsed
              elapsedMs={elapsedMs}
              receivedAt={snapshotReceivedAt}
              synchronized={synchronized}
            />
          ) : null
        }
        collapsible={presentation.processCanCollapse}
        expanded={showBody}
        controls={bodyId}
        onToggle={() => onExpandedChange(!showBody)}
      />
      {showBody && (
        <div className="run-process-body" id={bodyId}>
          {presentation.tools.length > 0 && (
            <ul className="run-process-tools">
              {presentation.tools.map((tool) => (
                <ProcessTool
                  key={tool.id}
                  tool={tool}
                  expanded={expandedToolIds.has(tool.id)}
                  onExpandedChange={(nextExpanded) =>
                    onToolExpandedChange(tool.id, nextExpanded)
                  }
                />
              ))}
            </ul>
          )}
        </div>
      )}
    </section>
  );
}
