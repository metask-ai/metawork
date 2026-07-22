import { useEffect, useMemo, useRef } from "react";

import type { RunView, TaskView, ToolView } from "../../bridge/contracts.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { formatInteger, formatMilliseconds } from "../../i18n/formatters.ts";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import type { InspectorSection } from "./inspector-state.ts";

export type InspectorFocusRequest = {
  taskId: string;
  section: InspectorSection;
  nonce: number;
} | null;

function selectedRun(task: TaskView): RunView | null {
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

function toolLabel(tool: ToolView): MessageId {
  return tool.state === "running"
    ? "task.phase.running"
    : tool.state === "failed"
      ? "outcome.failed"
      : "outcome.completed";
}

function wireInteger(value: string): bigint {
  try {
    return BigInt(value);
  } catch {
    return 0n;
  }
}

export function TaskInspector({
  task,
  focusRequest,
  onClose,
  onFocusPending,
}: {
  task: TaskView;
  focusRequest: InspectorFocusRequest;
  onClose: () => void;
  onFocusPending: () => void;
}) {
  const { locale, t } = useI18n();
  const sectionRefs = useRef<Partial<Record<InspectorSection, HTMLElement>>>(
    {},
  );
  const run = selectedRun(task);
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
    };
  }, [run]);

  useEffect(() => {
    if (!focusRequest || focusRequest.taskId !== task.id) return;
    const section = sectionRefs.current[focusRequest.section];
    section?.scrollIntoView({ block: "nearest" });
    section?.focus({ preventScroll: true });
  }, [focusRequest, task.id]);

  return (
    <div className="inspector-frame">
      <header className="inspector-header">
        <div>
          <p>{t("inspector.eyebrow")}</p>
          <h2 id="task-inspector-title">{t("inspector.title")}</h2>
        </div>
        <button
          className="icon-button focus-ring"
          aria-label={t("inspector.close")}
          title={t("inspector.close")}
          onClick={onClose}
        >
          <Icon name="close" />
        </button>
      </header>

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

        {run && (
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
                  : "inspector.last_run",
              )}
            </p>
            <div className="inspector-run-state">
              <span className="inspector-state-line" aria-hidden="true" />
              <div>
                <strong>{t(runLabel(run))}</strong>
                {run.cause && <small>{t(`cause.${run.cause}`)}</small>}
              </div>
            </div>
          </section>
        )}

        {run && run.tools.length > 0 && (
          <section
            ref={(node) => {
              sectionRefs.current.tools = node ?? undefined;
            }}
            className="inspector-section"
            tabIndex={-1}
          >
            <p className="section-label">{t("inspector.tools")}</p>
            <ul className="inspector-tool-list">
              {run.tools.map((tool) => {
                const duration = wireInteger(tool.elapsedMs);
                return (
                  <li key={tool.id} data-state={tool.state}>
                    <span className="inspector-tool-state" aria-hidden="true" />
                    <span>
                      <strong>{tool.name}</strong>
                      <small>{t(toolLabel(tool))}</small>
                    </span>
                    {duration > 0n && (
                      <time>
                        {t("tool.duration_ms", {
                          count: formatMilliseconds(locale, duration),
                        })}
                      </time>
                    )}
                  </li>
                );
              })}
            </ul>
          </section>
        )}

        {usage && usage.total > 0n && (
          <section
            ref={(node) => {
              sectionRefs.current.usage = node ?? undefined;
            }}
            className="inspector-section inspector-usage"
            tabIndex={-1}
          >
            <p className="section-label">{t("inspector.context_usage")}</p>
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
          </section>
        )}
      </div>
    </div>
  );
}
