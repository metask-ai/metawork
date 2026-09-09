import { runFileReferences } from "../../workbench/run-file-references.ts";
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";

import type {
  FileReferenceView,
  PendingUi,
  RunInputView,
  RunOutcome,
  RunView,
  TaskView,
  ToolView,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import {
  Activity,
  Conversation,
  Markdown,
  Message,
} from "../../components/ai/index.ts";
import { Icon } from "../../components/ui/Icon.tsx";
import { useI18n, type MessageId } from "../../i18n/context.ts";
import { RunProcess } from "./RunProcess.tsx";
import { RunFileChangesSummary } from "./RunFileChanges.tsx";
import {
  deriveRunPresentation,
  observeRunProcessDisclosure,
  toggleRunProcessDisclosure,
  type RunProcessDisclosure,
} from "./run-presentation.ts";

type ReadingState = { scrollTop: number; followingLatest: boolean };

function formatAttachmentSize(value: string) {
  const bytes = Number(value);
  if (!Number.isSafeInteger(bytes) || bytes <= 0) return value;
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.ceil(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function outcomeMessage(outcome: RunOutcome): MessageId {
  switch (outcome) {
    case "completed":
      return "run.terminal.completed";
    case "stopped":
    case "cancelled":
      return "run.terminal.stopped";
    case "interrupted":
      return "run.terminal.interrupted";
    case "failed":
    case "dependency_contract_failure":
      return "run.terminal.failed";
  }
}

function retryable(outcome: RunOutcome): boolean {
  return ["failed", "interrupted", "dependency_contract_failure"].includes(
    outcome,
  );
}

function terminalMessage(
  responseKind: RunView["output"]["responseKind"],
  outcome: RunOutcome,
): MessageId {
  if (responseKind !== "partial") return outcomeMessage(outcome);
  switch (outcome) {
    case "completed":
      return "run.terminal.partial_completed";
    case "stopped":
    case "cancelled":
      return "run.terminal.partial_stopped";
    case "interrupted":
      return "run.terminal.partial_interrupted";
    case "failed":
    case "dependency_contract_failure":
      return "run.terminal.partial_failed";
  }
}

function outcomeState(
  outcome: RunOutcome,
): "completed" | "stopped" | "failed" | "interrupted" {
  switch (outcome) {
    case "completed":
      return "completed";
    case "stopped":
    case "cancelled":
      return "stopped";
    case "interrupted":
      return "interrupted";
    case "failed":
    case "dependency_contract_failure":
      return "failed";
  }
}

function TaskInput({ input }: { input: RunInputView }) {
  const { t } = useI18n();
  const content =
    input.kind === "text" ? (
      <p className="task-input-copy">{input.text}</p>
    ) : input.kind === "skill" ? (
      <div className="task-skill-input">
        <span className="task-skill-token">
          /{input.invocationName}
          <small>{t("slash.group.skills")}</small>
        </span>
        {input.argumentValues.length > 0 && (
          <span className="task-skill-arguments">
            {input.argumentValues.map((value, index) => (
              <code key={index}>{value}</code>
            ))}
          </span>
        )}
      </div>
    ) : (
      <div className="task-multimodal-input">
        {input.text && <p className="task-input-copy">{input.text}</p>}
        <div className="task-input-attachments" role="list">
          {input.attachments.map((attachment, index) => (
            <span
              className="task-input-attachment"
              role="listitem"
              key={`${attachment.displayName}:${index}`}
            >
              <span aria-hidden="true">{attachment.format.toUpperCase()}</span>
              <strong dir="auto">{attachment.displayName}</strong>
              <small>
                {`${t("attachment.type.image")} · ${attachment.format.toUpperCase()}`}
                {` · ${formatAttachmentSize(attachment.sizeBytes)}`}
              </small>
            </span>
          ))}
        </div>
      </div>
    );

  return (
    <>
      {content}
      {input.redacted && (
        <p className="projection-note">{t("privacy.sensitive_hidden")}</p>
      )}
    </>
  );
}

export function TaskContent({
  task,
  revision,
  composerHasDraft,
  retryAvailable,
  responseDisabled,
  fileChangesEnabled,
  runDiagnosticsAvailable,
  onPrepareRetry,
  onOpenRunDiagnostics,
  onOpenTool,
  onPreviewFile,
  onReviewFileChanges,
  onRespond,
  renderPendingUi,
}: {
  task: TaskView | null;
  revision: string;
  composerHasDraft: boolean;
  retryAvailable: boolean;
  responseDisabled: boolean;
  fileChangesEnabled: boolean;
  runDiagnosticsAvailable: boolean;
  onPrepareRetry: (input: RunInputView) => void;
  onOpenRunDiagnostics: (runId: string, opener: HTMLButtonElement) => void;
  onOpenTool: (
    runId: string,
    toolId: string,
    opener: HTMLButtonElement,
  ) => void;
  onPreviewFile: (
    taskId: string,
    runId: string,
    reference: FileReferenceView,
    opener: HTMLButtonElement,
  ) => void;
  onReviewFileChanges: (
    taskId: string,
    runId: string,
    opener: HTMLButtonElement,
  ) => void;
  onRespond: (payload: UiResponsePayload) => void;
  renderPendingUi: (props: {
    taskId: string;
    pending: PendingUi;
    busy: boolean;
    respond: (payload: UiResponsePayload) => void;
  }) => ReactNode;
}) {
  const { t } = useI18n();
  const viewport = useRef<HTMLDivElement>(null);
  const reading = useRef(new Map<string, ReadingState>());
  const processDisclosure = useRef(new Map<string, RunProcessDisclosure>());
  const [, setDisclosureRevision] = useState(0);
  const previousTaskId = useRef<string | null>(null);
  const [showJumpLatest, setShowJumpLatest] = useState(false);
  const currentRun = task
    ? (task.runs.find((run) => run.id === task.currentRunId) ??
      task.runs.at(-1) ??
      null)
    : null;

  useLayoutEffect(() => {
    const node = viewport.current;
    if (!node) return;
    const taskId = task?.id ?? null;
    if (!taskId) {
      node.scrollTop = 0;
      setShowJumpLatest(false);
      previousTaskId.current = null;
      return;
    }
    if (previousTaskId.current !== taskId) {
      const saved = reading.current.get(taskId);
      node.scrollTop = saved?.scrollTop ?? node.scrollHeight;
      setShowJumpLatest(saved ? !saved.followingLatest : false);
      previousTaskId.current = taskId;
      return;
    }
    const saved = reading.current.get(taskId);
    if (!saved || saved.followingLatest) {
      node.scrollTop = node.scrollHeight;
      reading.current.set(taskId, {
        scrollTop: node.scrollTop,
        followingLatest: true,
      });
      setShowJumpLatest(false);
    }
  }, [task?.id, revision]);

  function updateReadingState() {
    const node = viewport.current;
    if (!node || !task) return;
    const followingLatest =
      node.scrollHeight - node.scrollTop - node.clientHeight <= 48;
    reading.current.set(task.id, {
      scrollTop: node.scrollTop,
      followingLatest,
    });
    setShowJumpLatest(!followingLatest);
  }

  function jumpToLatest() {
    const node = viewport.current;
    if (!node || !task) return;
    reading.current.set(task.id, {
      scrollTop: node.scrollHeight,
      followingLatest: true,
    });
    node.scrollTo({ top: node.scrollHeight, behavior: "smooth" });
    setShowJumpLatest(false);
  }

  return (
    <Conversation
      aria-label={task?.title}
      viewportRef={viewport}
      onViewportScroll={updateReadingState}
      jumpToLatest={
        showJumpLatest
          ? { label: t("task.jump_latest"), onClick: jumpToLatest }
          : undefined
      }
    >
      {task?.runs.map((run) => {
        const isCurrent = run.id === currentRun?.id;
        const terminal = run.terminal;
        const presentation = deriveRunPresentation(run);
        const fileReferences = runFileReferences(run);
        const disclosureKey = `${task.id}:${run.id}`;
        const disclosure = observeRunProcessDisclosure(
          processDisclosure.current.get(disclosureKey),
        );
        processDisclosure.current.set(disclosureKey, disclosure);

        function setProcessExpanded(expanded: boolean) {
          processDisclosure.current.set(
            disclosureKey,
            toggleRunProcessDisclosure(expanded),
          );
          setDisclosureRevision((value) => value + 1);
        }

        return (
          <section className="ai-exchange" key={`${task.id}:${run.id}`}>
            <Message role="user">
              <TaskInput input={run.input} />
            </Message>
            {(run.output.commentary.some(Boolean) ||
              run.output.provisional ||
              run.output.provisionalRedacted ||
              (run.output.redacted && !presentation.responseVisible)) && (
              <Message role="assistant" className="run-narrative">
                {run.output.commentary.map((commentary, index) =>
                  commentary ? (
                    <Markdown className="run-commentary-item" key={index}>
                      {commentary}
                    </Markdown>
                  ) : null,
                )}
                {run.output.provisional && (
                  <p className="run-provisional" aria-live="polite">
                    {run.output.provisional}
                  </p>
                )}
                {(run.output.provisionalRedacted ||
                  (run.output.redacted && !presentation.responseVisible)) && (
                  <p className="projection-note">
                    {t("privacy.sensitive_hidden")}
                  </p>
                )}
              </Message>
            )}
            {presentation.active && (
              <>
                <RunProcess
                  presentation={presentation}
                  expanded={disclosure.expanded}
                  onExpandedChange={setProcessExpanded}
                  onOpenTool={(tool: ToolView, opener) =>
                    onOpenTool(run.id, tool.id, opener)
                  }
                />
                {fileChangesEnabled && run.fileChanges && (
                  <RunFileChangesSummary
                    fileChanges={run.fileChanges}
                    onReview={(opener) =>
                      onReviewFileChanges(task.id, run.id, opener)
                    }
                  />
                )}
              </>
            )}
            {isCurrent && task.pendingUi && (
              <div className="ai-exchange-intervention">
                {renderPendingUi({
                  taskId: task.id,
                  pending: task.pendingUi,
                  busy: responseDisabled,
                  respond: onRespond,
                })}
              </div>
            )}
            {presentation.responseVisible && (
              <Message role="assistant">
                <Markdown className="agent-response">
                  {run.output.response}
                </Markdown>
                {run.output.redacted && (
                  <p className="projection-note">
                    {t("privacy.sensitive_hidden")}
                  </p>
                )}
              </Message>
            )}
            {fileReferences.length > 0 && (
              <footer className="ml-11 flex flex-wrap items-center gap-2 border-l-2 border-(--ui-border) py-1 pl-3">
                <span className="text-xs font-medium text-(--ui-content-muted)">
                  {t("file_preview.references")}
                </span>
                {fileReferences.map((reference) => (
                  <button
                    key={reference.id}
                    type="button"
                    className="focus-ring inline-flex min-h-11 max-w-full items-center gap-1.5 rounded-lg border border-(--ui-border) bg-(--ui-surface-panel) px-3 py-2 text-xs text-(--ui-content-primary) hover:bg-(--ui-action-hover-surface)"
                    title={reference.displayPath}
                    aria-label={t("file_preview.open", {
                      path: reference.displayPath,
                    })}
                    onClick={(event) =>
                      onPreviewFile(
                        task.id,
                        run.id,
                        reference,
                        event.currentTarget,
                      )
                    }
                  >
                    <Icon name="skill-file" />
                    <span className="max-w-72 truncate font-mono">
                      {reference.displayPath}
                    </span>
                  </button>
                ))}
              </footer>
            )}
            {!presentation.active && (
              <>
                <RunProcess
                  presentation={presentation}
                  expanded={disclosure.expanded}
                  onExpandedChange={setProcessExpanded}
                  onOpenTool={(tool: ToolView, opener) =>
                    onOpenTool(run.id, tool.id, opener)
                  }
                />
                {fileChangesEnabled && run.fileChanges && (
                  <RunFileChangesSummary
                    fileChanges={run.fileChanges}
                    onReview={(opener) =>
                      onReviewFileChanges(task.id, run.id, opener)
                    }
                  />
                )}
              </>
            )}
            {presentation.showTerminalNotice && terminal && (
              <Activity
                className={
                  terminal.cause === "provider_failure"
                    ? "run-terminal-activity"
                    : undefined
                }
                state={outcomeState(terminal.outcome)}
                label={t(
                  terminal.cause === "provider_failure"
                    ? "run.provider_failure.title"
                    : terminalMessage(
                        run.output.responseKind,
                        terminal.outcome,
                      ),
                )}
                detail={
                  terminal.cause === "provider_failure" ? (
                    <span className="run-terminal-detail">
                      <span>
                        {t(
                          run.output.responseKind === "partial"
                            ? "run.provider_failure.partial_impact"
                            : "run.provider_failure.no_response_impact",
                        )}
                      </span>
                      {run.tools.length > 0 && (
                        <span>
                          {t("run.provider_failure.review_tool_effects")}
                        </span>
                      )}
                    </span>
                  ) : terminal.cause ? (
                    t(`cause.${terminal.cause}`)
                  ) : terminal.outcome === "completed" &&
                    run.output.responseKind !== "partial" ? (
                    t("run.no_final_response")
                  ) : undefined
                }
                announce={isCurrent}
                action={
                  (isCurrent &&
                    retryAvailable &&
                    retryable(terminal.outcome)) ||
                  (terminal.cause === "provider_failure" &&
                    runDiagnosticsAvailable) ? (
                    <div className="run-terminal-actions">
                      {isCurrent &&
                        retryAvailable &&
                        retryable(terminal.outcome) && (
                          <button
                            className="ai-activity-retry focus-ring"
                            title={
                              composerHasDraft
                                ? t("run.review_draft_help")
                                : t("run.retry_help")
                            }
                            onClick={() => onPrepareRetry(run.input)}
                          >
                            {composerHasDraft
                              ? t("run.review_draft")
                              : t("run.prepare_retry")}
                          </button>
                        )}
                      {terminal.cause === "provider_failure" &&
                        runDiagnosticsAvailable && (
                          <button
                            className="ai-activity-details focus-ring"
                            onClick={(event) =>
                              onOpenRunDiagnostics(run.id, event.currentTarget)
                            }
                          >
                            {t("run.view_diagnostics")}
                          </button>
                        )}
                    </div>
                  ) : undefined
                }
              />
            )}
          </section>
        );
      })}
      {task && task.runs.length === 0 && (
        <div className="ai-conversation-empty">
          <h2>{t("task.empty_title")}</h2>
          <p>{t("task.created_empty_body")}</p>
        </div>
      )}
    </Conversation>
  );
}
