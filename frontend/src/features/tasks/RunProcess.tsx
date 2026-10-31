import { useEffect, useId, useState, type ReactNode } from "react";

import type {
  RunActivity,
  RunFileChanges,
  ToolView,
} from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type I18nValue, type MessageId } from "../../i18n/context.ts";
import { formatInteger } from "../../i18n/formatters.ts";
import { runElapsedSeconds, type RunPresentation } from "./run-presentation.ts";
import { ToolDetailView } from "./ToolDetailView.tsx";

const emptyExpandedToolIds: ReadonlySet<string> = new Set();

function toolActivityMessage(name: string | null): MessageId | null {
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
      return null;
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
      return (
        (activity.inFlight === "1" && toolActivityMessage(runningToolName)) ||
        (activity.inFlight === null
          ? "run.activity.executing_tools"
          : activity.inFlight === "1"
            ? "run.activity.tool_running_one"
            : "run.activity.tool_running_many")
      );
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
  if (tool.errorDetail || tool.isError)
    return Boolean(
      tool.errorDetail ||
      tool.content ||
      tool.contentTruncated ||
      tool.redacted,
    );
  switch (tool.presentation?.kind) {
    case "write":
    case "edit":
    case "kill_shell":
    case "web_search":
      return false;
    case "read":
    case "glob":
    case "grep":
      return Boolean(
        tool.content ||
        tool.contentTruncated ||
        tool.redacted ||
        (tool.presentation.kind === "read" &&
          (tool.presentation.offset || tool.presentation.limit)),
      );
    case "bash_output":
      return Boolean(
        tool.presentation.result || tool.contentTruncated || tool.redacted,
      );
    case "web_fetch":
      return Boolean(
        tool.presentation.result ||
        tool.presentation.prompt ||
        tool.contentTruncated ||
        tool.redacted,
      );
  }
  if (tool.name === "Edit" || tool.name === "Write") return false;
  return Boolean(
    tool.bash?.command != null ||
    tool.bash?.result != null ||
    tool.input ||
    tool.content ||
    tool.inputTruncated ||
    tool.contentTruncated ||
    tool.redacted,
  );
}

function toolPresentationSummary(tool: ToolView): string | null {
  const presentation = tool.presentation;
  if (!presentation) return null;
  switch (presentation.kind) {
    case "read":
    case "write":
    case "edit":
      return presentation.target;
    case "glob":
    case "grep":
      return presentation.pattern;
    case "bash_output":
    case "kill_shell":
      return presentation.jobId;
    case "web_search":
      return presentation.query;
    case "web_fetch":
      return presentation.url;
  }
}

function fileMutationAuditPath(
  tool: ToolView,
  fileChanges: RunFileChanges | null,
): string | null {
  if ((tool.name !== "Edit" && tool.name !== "Write") || !fileChanges)
    return null;
  const referencePaths = new Set(
    tool.fileRefs.map((reference) => reference.displayPath),
  );
  if (referencePaths.size !== 1) return null;
  const matchingPaths = new Set(
    fileChanges.changes
      .map((change) => change.displayPath)
      .filter((path) => referencePaths.has(path)),
  );
  return matchingPaths.size === 1 ? [...matchingPaths][0]! : null;
}

function toolSummary(tool: ToolView): string | null {
  const fileNames = tool.fileRefs
    .map((reference) => reference.displayPath)
    .join(", ");
  const summary =
    tool.bash?.description ||
    fileNames ||
    toolPresentationSummary(tool) ||
    tool.progress;
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
  const duration = formatElapsedDuration(
    locale,
    runElapsedSeconds(elapsedMs, receivedAt, now),
  );
  // Outside the live region: elapsed seconds are not progress.
  return (
    <small className="run-process-elapsed" aria-live="off">
      {t("run.elapsed", { duration })}
    </small>
  );
}

function formatElapsedDuration(
  locale: I18nValue["locale"],
  seconds: bigint,
): string {
  return `${formatInteger(locale, seconds / 60n)}:${String(seconds % 60n).padStart(2, "0")}`;
}

function ProcessTool({
  tool,
  fileChanges,
  expanded,
  onExpandedChange,
  onReviewFileChanges,
}: {
  tool: ToolView;
  fileChanges: RunFileChanges | null;
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
  onReviewFileChanges?: (
    displayPath: string,
    opener: HTMLButtonElement,
  ) => void;
}) {
  const { locale, t } = useI18n();
  const detailId = useId();
  const elapsed = BigInt(tool.elapsedMs);
  const hasDetails = toolDetailAvailable(tool);
  const auditPath = fileMutationAuditPath(tool, fileChanges);
  const summary = toolSummary(tool);
  const content = (
    <>
      <span className="run-process-tool-mark" aria-hidden="true" />
      <span className="run-process-tool-label">
        <span className="run-process-tool-name">{tool.name}</span>
        {auditPath && onReviewFileChanges ? (
          <button
            type="button"
            className="run-process-tool-audit-link focus-ring"
            aria-label={t("file_changes.review_file", { path: auditPath })}
            onClick={(event) =>
              onReviewFileChanges(auditPath, event.currentTarget)
            }
          >
            {auditPath}
          </button>
        ) : summary ? (
          <span className="run-process-tool-description" title={summary}>
            {summary}
          </span>
        ) : null}
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
  reviewingPermission,
  fileChanges = null,
  elapsedMs = null,
  snapshotReceivedAt = null,
  synchronized = true,
  requestingStop = false,
  expanded,
  onExpandedChange,
  expandedToolIds = emptyExpandedToolIds,
  onToolExpandedChange = () => {},
  onReviewFileChanges,
}: {
  presentation: RunPresentation;
  reviewingPermission: boolean;
  fileChanges?: RunFileChanges | null;
  elapsedMs?: string | null;
  snapshotReceivedAt?: number | null;
  synchronized?: boolean;
  requestingStop?: boolean;
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
  expandedToolIds?: ReadonlySet<string>;
  onToolExpandedChange?: (toolId: string, expanded: boolean) => void;
  onReviewFileChanges?: (
    displayPath: string,
    opener: HTMLButtonElement,
  ) => void;
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
      : activity?.kind === "waiting_user" && reviewingPermission
        ? t("task.phase.reviewing")
        : activity
          ? t(
              activityMessage(activity, presentation.runningToolName),
              activity.kind === "executing_tools" && activity.inFlight !== null
                ? { count: formatInteger(locale, BigInt(activity.inFlight)) }
                : undefined,
            )
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
          ) : !presentation.active && elapsedMs !== null ? (
            <small className="run-process-elapsed" aria-live="off">
              {t("run.process.elapsed", {
                duration: formatElapsedDuration(
                  locale,
                  BigInt(elapsedMs) / 1000n,
                ),
              })}
            </small>
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
                  key={`tool-${tool.id}`}
                  tool={tool}
                  fileChanges={fileChanges}
                  expanded={expandedToolIds.has(tool.id)}
                  onExpandedChange={(nextExpanded) =>
                    onToolExpandedChange(tool.id, nextExpanded)
                  }
                  onReviewFileChanges={onReviewFileChanges}
                />
              ))}
            </ul>
          )}
        </div>
      )}
    </section>
  );
}
