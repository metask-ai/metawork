import { useEffect, useMemo, useRef } from "react";

import type { RunView, TaskView } from "../../bridge/contracts.ts";
import { formatInteger } from "../../i18n/formatters.ts";
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

const safeRunStatusLabels = new Set([
  "Queued",
  "Starting",
  "Generating response",
  "Executing tools",
  "Waiting for your input",
  "Retrying provider",
  "Compacting context",
  "Finishing",
]);

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

function wireInteger(value: string): bigint {
  try {
    return BigInt(value);
  } catch {
    return 0n;
  }
}

export function TaskOverview({
  task,
  focusRequest,
  onFocusPending,
}: {
  task: TaskView;
  focusRequest: InspectorFocusRequest;
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
        <h2 id="task-inspector-title">{t("inspector.title")}</h2>
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
                {isActiveRun(run) && safeRunStatusLabels.has(run.status) && (
                  <span>{run.status}</span>
                )}
                {run.cause && <small>{t(`cause.${run.cause}`)}</small>}
              </div>
            </div>
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
