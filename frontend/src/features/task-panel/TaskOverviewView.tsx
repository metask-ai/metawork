import { useEffect, useId, useMemo, useRef, useState } from "react";

import type { RunView, TaskView, ToolView } from "../../bridge/contracts.ts";
import { CodeBlock } from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { formatInteger } from "../../i18n/formatters.ts";
import { useI18n, type I18nValue, type MessageId } from "../../i18n/context.ts";
import type { TaskOverviewSection } from "./task-panel-state.ts";

export type TaskOverviewFocusRequest = {
  taskId: string;
  section: TaskOverviewSection;
  runId?: string;
  toolId?: string;
  nonce: number;
} | null;

function selectedRun(
  task: TaskView,
  focusRequest: TaskOverviewFocusRequest,
): RunView | null {
  if (focusRequest?.taskId === task.id && focusRequest.runId) {
    const requested = task.runs.find((run) => run.id === focusRequest.runId);
    if (requested) return requested;
  }
  return (
    task.runs.find((run) => run.id === task.currentRunId) ??
    task.runs.at(-1) ??
    null
  );
}

function isActiveRun(run: RunView): boolean {
  return (
    run.phase === "queued" ||
    run.phase === "running" ||
    run.phase === "waiting_ui" ||
    run.phase === "stopping"
  );
}

function runActivityMessage(run: RunView): MessageId | null {
  if (run.phase !== "running") return null;
  switch (run.activity?.kind) {
    case "queued":
    case "starting":
      return "run.activity.starting";
    case "thinking":
      return "run.activity.thinking";
    case "writing_response":
      return "run.activity.writing_response";
    case "executing_tools":
      return "run.activity.executing_tools";
    case "retrying_provider":
      return "run.activity.retrying_provider";
    case "compacting_context":
      return "run.activity.compacting_context";
    case "finalizing":
      return "run.activity.finishing";
    case "waiting_user":
      return "task.phase.waiting_ui";
    case "stopping":
      return "task.phase.stopping";
    case "waiting_model":
    case undefined:
      return "run.activity.waiting_model";
  }
}

function runActivityDetail(
  run: RunView,
  locale: I18nValue["locale"],
  t: I18nValue["t"],
): string | null {
  if (run.activity?.kind === "executing_tools" && run.activity.inFlight) {
    const count = BigInt(run.activity.inFlight);
    return t(
      count === 1n
        ? "run.activity.tool_running_one"
        : "run.activity.tool_running_many",
      { count: formatInteger(locale, count) },
    );
  }
  if (
    run.activity?.kind === "retrying_provider" &&
    run.activity.attempt &&
    run.activity.max &&
    run.activity.delayMs
  ) {
    const values = {
      attempt: formatInteger(locale, BigInt(run.activity.attempt)),
      max: formatInteger(locale, BigInt(run.activity.max)),
      delay: formatInteger(locale, BigInt(run.activity.delayMs)),
    };
    return t(
      run.activity.delayMs === "0"
        ? "run.activity.retry_detail_now"
        : "run.activity.retry_detail",
      values,
    );
  }
  return null;
}

function runLabel(run: RunView): MessageId {
  switch (run.phase) {
    case "queued":
    case "running":
    case "waiting_ui":
    case "stopping":
      return `task.phase.${run.phase}`;
    case "completed":
    case "stopped":
    case "cancelled":
    case "interrupted":
    case "failed":
      return `outcome.${run.phase}`;
  }
}

function protocolMessage(
  protocol: RunView["execution"]["protocol"],
): MessageId {
  return `settings.custom_provider_protocol.${protocol}`;
}

function wireInteger(value: string): bigint {
  try {
    return BigInt(value);
  } catch {
    return 0n;
  }
}

function orderedTools(run: RunView): ToolView[] {
  return [...run.tools].sort((left, right) => {
    const leftOrder = BigInt(left.order);
    const rightOrder = BigInt(right.order);
    return leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0;
  });
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

function ToolProcessItem({
  tool,
  expanded,
  onToggle,
  summaryRef,
}: {
  tool: ToolView;
  expanded: boolean;
  onToggle: () => void;
  summaryRef: (node: HTMLElement | null) => void;
}) {
  const { locale, t } = useI18n();
  const detailId = useId();
  const hasDetails = Boolean(tool.input || tool.progress || tool.content);
  const truncated =
    tool.inputTruncated || tool.progressTruncated || tool.contentTruncated;
  const elapsed = wireInteger(tool.elapsedMs);
  const identity = (
    <>
      <span className="inspector-tool-state" aria-hidden="true" />
      <span className="inspector-tool-identity">
        <strong>{tool.name}</strong>
        <small>{t(toolStateMessage(tool))}</small>
      </span>
      <span className="inspector-tool-meta">
        {elapsed > 0n && (
          <span>
            {t("inspector.tool.elapsed", {
              duration: formatInteger(locale, elapsed),
            })}
          </span>
        )}
        {hasDetails && <Icon name="chevron" />}
      </span>
    </>
  );

  return (
    <li data-state={tool.state} data-expanded={expanded}>
      {hasDetails ? (
        <button
          ref={summaryRef}
          type="button"
          className="inspector-tool-summary focus-ring"
          aria-expanded={expanded}
          aria-controls={expanded ? detailId : undefined}
          onClick={onToggle}
        >
          {identity}
        </button>
      ) : (
        <div ref={summaryRef} className="inspector-tool-summary" tabIndex={-1}>
          {identity}
        </div>
      )}
      {expanded && hasDetails && (
        <div className="inspector-tool-detail" id={detailId}>
          {tool.input && (
            <div className="detail-field">
              <p className="detail-field-label">{t("inspector.tool.input")}</p>
              <CodeBlock
                aria-label={t("inspector.tool.input")}
                value={tool.input}
              />
            </div>
          )}
          {tool.progress && (
            <div className="detail-field">
              <p className="detail-field-label">
                {t("inspector.tool.progress")}
              </p>
              <CodeBlock
                aria-label={t("inspector.tool.progress")}
                value={tool.progress}
              />
            </div>
          )}
          {tool.content && (
            <div className="detail-field">
              <p className="detail-field-label">{t("inspector.tool.result")}</p>
              <CodeBlock
                aria-label={t("inspector.tool.result")}
                value={tool.content}
              />
            </div>
          )}
          {truncated && (
            <p className="projection-note">{t("inspector.tool.truncated")}</p>
          )}
          {tool.redacted && (
            <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
          )}
        </div>
      )}
    </li>
  );
}

function WorkProcess({
  taskId,
  runId,
  tools,
  focusToolId,
  focusNonce,
  sectionRef,
}: {
  taskId: string;
  runId: string;
  tools: ToolView[];
  focusToolId?: string;
  focusNonce?: number;
  sectionRef: (node: HTMLElement | null) => void;
}) {
  const { t } = useI18n();
  const [expandedToolId, setExpandedToolId] = useState<string | null>(null);
  const toolRefs = useRef(new Map<string, HTMLElement>());

  useEffect(() => {
    if (!focusToolId || !tools.some((tool) => tool.id === focusToolId)) return;
    setExpandedToolId(focusToolId);
    const frame = window.requestAnimationFrame(() => {
      const target = toolRefs.current.get(focusToolId);
      target?.scrollIntoView({ block: "nearest" });
      target?.focus({ preventScroll: true });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [focusNonce, focusToolId, runId, taskId]);

  return (
    <section
      ref={sectionRef}
      className="inspector-section inspector-work-process"
      tabIndex={-1}
    >
      <p className="section-label">{t("inspector.work_process")}</p>
      <ul className="inspector-tool-list">
        {tools.map((tool) => (
          <ToolProcessItem
            key={`${taskId}:${runId}:${tool.id}`}
            tool={tool}
            expanded={expandedToolId === tool.id}
            summaryRef={(node) => {
              if (node) toolRefs.current.set(tool.id, node);
              else toolRefs.current.delete(tool.id);
            }}
            onToggle={() =>
              setExpandedToolId((current) =>
                current === tool.id ? null : tool.id,
              )
            }
          />
        ))}
      </ul>
    </section>
  );
}

export function TaskOverviewView({
  task,
  permissionProfilesEnabled,
  focusRequest,
  onFocusPending,
}: {
  task: TaskView;
  permissionProfilesEnabled: boolean;
  focusRequest: TaskOverviewFocusRequest;
  onFocusPending: () => void;
}) {
  const { locale, t } = useI18n();
  const sectionRefs = useRef<Partial<Record<TaskOverviewSection, HTMLElement>>>(
    {},
  );
  const run = selectedRun(task, focusRequest);
  const latestRun = task.runs.at(-1) ?? null;
  const runIsLatest = run !== null && run.id === latestRun?.id;
  const providerFailureTerminal =
    run?.terminal?.cause === "provider_failure" ? run.terminal : null;
  const activityMessage = run ? runActivityMessage(run) : null;
  const activityDetail = run ? runActivityDetail(run, locale, t) : null;
  const tools = useMemo(() => (run ? orderedTools(run) : []), [run]);
  const usage = useMemo(() => {
    if (!run) return null;
    const input = wireInteger(run.usage.input);
    const output = wireInteger(run.usage.output);
    const cacheRead = wireInteger(run.usage.cacheRead);
    const cacheCreation = wireInteger(run.usage.cacheCreation);
    return {
      input,
      output,
      cacheRead,
      cacheCreation,
      total: input + output,
      hasAny: input > 0n || output > 0n || cacheRead > 0n || cacheCreation > 0n,
    };
  }, [run]);

  useEffect(() => {
    if (!focusRequest || focusRequest.taskId !== task.id) return;
    if (focusRequest.section === "work_process" && focusRequest.toolId) return;
    const section = sectionRefs.current[focusRequest.section];
    section?.scrollIntoView({ block: "nearest" });
    section?.focus({ preventScroll: true });
  }, [focusRequest, task.id]);

  return (
    <div className="task-overview-view">
      <div className="inspector-permission-profile">
        <span>{t("inspector.mcp_authority")}</span>
        <strong>
          {t(
            task.mcpAuthority.kind === "unavailable"
              ? "inspector.mcp_unavailable"
              : task.mcpAuthority.selection === "selected"
                ? "inspector.mcp_selected"
                : "inspector.mcp_none",
          )}
        </strong>
      </div>
      {permissionProfilesEnabled && (
        <div className="inspector-permission-profile">
          <span>{t("permission.task.label")}</span>
          <strong>{t(`permission.profile.${task.permissionProfile}`)}</strong>
        </div>
      )}
      <div className="inspector-sections">
        {task.pendingUi && (
          <section
            ref={(node) => {
              sectionRefs.current.attention = node ?? undefined;
            }}
            className="inspector-section is-attention"
            tabIndex={-1}
          >
            <p className="section-label">{t("inspector.needs_attention")}</p>
            <button
              className="attention-link focus-ring"
              onClick={onFocusPending}
            >
              <span>{t("inspector.response_required")}</span>
              <strong>{t("inspector.view_request")}</strong>
            </button>
          </section>
        )}

        {run && !providerFailureTerminal && (
          <section
            ref={(node) => {
              sectionRefs.current.summary = node ?? undefined;
            }}
            className="inspector-section inspector-run-summary"
            data-active={isActiveRun(run)}
            tabIndex={-1}
          >
            <p className="section-label">
              {t(
                isActiveRun(run)
                  ? "inspector.current_activity"
                  : runIsLatest
                    ? "inspector.last_run"
                    : "inspector.selected_run",
              )}
            </p>
            <div className="inspector-run-state">
              <span className="inspector-state-line" aria-hidden="true" />
              <div>
                <strong>{t(runLabel(run))}</strong>
                {isActiveRun(run) && activityMessage && (
                  <span>{t(activityMessage)}</span>
                )}
                {isActiveRun(run) && activityDetail && (
                  <span>{activityDetail}</span>
                )}
                {run.terminal?.cause && (
                  <small>{t(`cause.${run.terminal.cause}`)}</small>
                )}
              </div>
            </div>
          </section>
        )}

        {run && providerFailureTerminal && (
          <section
            ref={(node) => {
              sectionRefs.current.diagnostics = node ?? undefined;
            }}
            className="inspector-section inspector-run-diagnostics"
            tabIndex={-1}
          >
            <p className="section-label">{t("inspector.run_details")}</p>
            <div className="inspector-run-state">
              <span className="inspector-state-line" aria-hidden="true" />
              <div>
                <strong>{t("run.provider_failure.title")}</strong>
                <span>
                  {t(
                    run.output.responseKind === "partial"
                      ? "run.provider_failure.partial_impact"
                      : "run.provider_failure.no_response_impact",
                  )}
                </span>
              </div>
            </div>
            <p className="inspector-diagnostic-note">
              {t(
                providerFailureTerminal.diagnosticDisposition === "withheld"
                  ? "run.provider_failure.diagnostic_withheld"
                  : "run.provider_failure.diagnostic_absent",
              )}
            </p>
            <p className="section-label inspector-run-information-label">
              {t("inspector.run_information")}
            </p>
            <dl className="inspector-diagnostic-facts">
              <div>
                <dt>{t("inspector.diagnostic_model")}</dt>
                <dd>{run.execution.model}</dd>
              </div>
              <div>
                <dt>{t("inspector.diagnostic_protocol")}</dt>
                <dd>{t(protocolMessage(run.execution.protocol))}</dd>
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
          </section>
        )}

        {run && tools.length > 0 && (
          <WorkProcess
            key={`${task.id}:${run.id}`}
            taskId={task.id}
            runId={run.id}
            tools={tools}
            focusToolId={
              focusRequest?.taskId === task.id && focusRequest.runId === run.id
                ? focusRequest.toolId
                : undefined
            }
            focusNonce={focusRequest?.nonce}
            sectionRef={(node) => {
              sectionRefs.current.work_process = node ?? undefined;
            }}
          />
        )}

        {usage &&
          (usage.hasAny ||
            task.context.pressure !== null ||
            task.context.lastAutoCompact !== null) && (
            <section
              ref={(node) => {
                sectionRefs.current.usage = node ?? undefined;
              }}
              className="inspector-section inspector-context-usage"
              tabIndex={-1}
            >
              <p className="section-label">{t("inspector.context_usage")}</p>
              {task.context.pressure && (
                <div
                  className="inspector-context-pressure"
                  data-severity={task.context.pressure.severity}
                >
                  <strong>
                    {t(
                      task.context.pressure.severity === "critical"
                        ? "inspector.context_critical"
                        : "inspector.context_warning",
                    )}
                  </strong>
                  <span>
                    {t("inspector.context_pressure_detail", {
                      current: formatInteger(
                        locale,
                        wireInteger(task.context.pressure.currentTokens),
                      ),
                      compact: formatInteger(
                        locale,
                        wireInteger(task.context.pressure.autoCompactThreshold),
                      ),
                      limit: formatInteger(
                        locale,
                        wireInteger(task.context.pressure.blockingLimit),
                      ),
                    })}
                  </span>
                </div>
              )}
              {task.context.lastAutoCompact && (
                <div className="inspector-last-compact">
                  <strong>{t("inspector.last_auto_compact")}</strong>
                  <span>
                    {t("inspector.compact_token_change", {
                      before: formatInteger(
                        locale,
                        wireInteger(task.context.lastAutoCompact.beforeTokens),
                      ),
                      after: formatInteger(
                        locale,
                        wireInteger(task.context.lastAutoCompact.afterTokens),
                      ),
                    })}
                  </span>
                  <small>
                    {t("inspector.compact_items", {
                      dropped: formatInteger(
                        locale,
                        wireInteger(task.context.lastAutoCompact.dropped),
                      ),
                      kept: formatInteger(
                        locale,
                        wireInteger(task.context.lastAutoCompact.kept),
                      ),
                    })}
                  </small>
                </div>
              )}
              {usage.hasAny && (
                <div className="inspector-usage">
                  <p className="inspector-usage-total">
                    {formatInteger(locale, usage.total)}
                  </p>
                  <span>{t("inspector.tokens_this_run")}</span>
                  <dl>
                    <div>
                      <dt>{t("inspector.input_tokens")}</dt>
                      <dd>{formatInteger(locale, usage.input)}</dd>
                    </div>
                    <div>
                      <dt>{t("inspector.output_tokens")}</dt>
                      <dd>{formatInteger(locale, usage.output)}</dd>
                    </div>
                    {usage.cacheRead > 0n && (
                      <div>
                        <dt>{t("inspector.cache_read_tokens")}</dt>
                        <dd>{formatInteger(locale, usage.cacheRead)}</dd>
                      </div>
                    )}
                    {usage.cacheCreation > 0n && (
                      <div>
                        <dt>{t("inspector.cache_creation_tokens")}</dt>
                        <dd>{formatInteger(locale, usage.cacheCreation)}</dd>
                      </div>
                    )}
                  </dl>
                </div>
              )}
            </section>
          )}
      </div>
    </div>
  );
}
