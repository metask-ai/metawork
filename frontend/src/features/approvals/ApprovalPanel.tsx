import { useState, type ButtonHTMLAttributes } from "react";

import { CodeBlock } from "../../components/ui/CodeBlock.tsx";
import type {
  AskOption,
  PendingUi,
  UiResponsePayload,
} from "../../bridge/contracts.ts";
import { useI18n } from "../../i18n/context.ts";
import {
  optionAnswerSelected,
  selectedOptionIndex,
  serializeAnswerDrafts,
  textAnswerValue,
  updateOptionAnswer,
  updateTextAnswer,
  type AnswerDrafts,
} from "./answer-drafts.ts";
import type { UiResponsePhase } from "./response-state.ts";

export function ApprovalPanel({
  pending,
  busy,
  responsePhase,
  respond,
}: {
  pending: PendingUi;
  busy: boolean;
  responsePhase: UiResponsePhase;
  respond: (payload: UiResponsePayload) => void;
}) {
  const { t } = useI18n();
  const [answers, setAnswers] = useState<AnswerDrafts>([]);

  const responseInFlight =
    responsePhase === "sending" || responsePhase === "awaiting_snapshot";
  const actionDisabled = busy || responseInFlight;
  const serializedAnswers =
    pending.kind === "ask_question"
      ? serializeAnswerDrafts(pending.questions, answers)
      : null;

  function submitAnswers() {
    if (actionDisabled || !serializedAnswers) return;
    respond({ kind: "answers", answers: serializedAnswers });
  }

  return (
    <section
      id={`ui-request-${pending.requestId}`}
      tabIndex={-1}
      className="inline-request rounded-2xl border border-amber bg-amber/8 p-5"
      aria-busy={responseInFlight}
    >
      <p className="font-mono text-[10px] tracking-[0.14em] text-amber-ink uppercase">
        {t("approval.response_required", { id: pending.runId })}
      </p>
      {pending.redacted && (
        <p className="projection-note" role="note">
          {t("privacy.sensitive_hidden")}
        </p>
      )}
      {pending.kind === "permission" && (
        <div className="mt-4">
          <h3 className="font-semibold">
            {t("approval.allow_tool", { tool: pending.tool })}
          </h3>
          <CodeBlock label={t("approval.arguments")} value={pending.args} />
          <div className="mt-4 grid grid-cols-2 gap-2">
            <DecisionButton
              disabled={actionDisabled}
              onClick={() =>
                respond({ kind: "permission", permission: "deny_once" })
              }
            >
              {t("approval.deny")}
            </DecisionButton>
            <DecisionButton
              primary
              disabled={actionDisabled}
              onClick={() =>
                respond({ kind: "permission", permission: "allow_once" })
              }
            >
              {t("approval.allow_once")}
            </DecisionButton>
          </div>
        </div>
      )}
      {pending.kind === "ask_question" && (
        <div
          className="mt-4 space-y-5"
          onKeyDown={(event) => {
            if (
              event.key === "Enter" &&
              (event.metaKey || event.ctrlKey) &&
              serializedAnswers &&
              !actionDisabled
            ) {
              event.preventDefault();
              submitAnswers();
            }
          }}
        >
          {pending.questions.map((question, index) => (
            <div key={`${question.header}-${index}`}>
              <p className="text-sm font-semibold">{question.question}</p>
              {question.multi && question.options.length > 0 ? (
                <div className="mt-3 space-y-2">
                  {question.options.map((option, optionIndex) => (
                    <label
                      key={`${option.label}-${optionIndex}`}
                      className="flex items-start gap-3 rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                    >
                      <input
                        className="mt-1 accent-cobalt"
                        type="checkbox"
                        checked={optionAnswerSelected(
                          answers,
                          index,
                          optionIndex,
                        )}
                        onChange={(event) => {
                          setAnswers(
                            updateOptionAnswer(
                              answers,
                              index,
                              optionIndex,
                              true,
                              event.target.checked,
                            ),
                          );
                        }}
                      />
                      <span>
                        <span className="font-medium">{option.label}</span>
                        {option.description && (
                          <span className="mt-0.5 block text-xs leading-5 text-muted">
                            {option.description}
                          </span>
                        )}
                        {option.preview && (
                          <span className="approval-option-preview mt-1 block font-mono text-[10px] leading-5 text-muted">
                            {option.preview}
                          </span>
                        )}
                      </span>
                    </label>
                  ))}
                </div>
              ) : question.options.length > 0 ? (
                <>
                  <select
                    className="focus-ring mt-2 w-full rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                    value={selectedOptionIndex(answers, index) + 1}
                    onChange={(event) => {
                      const optionIndex = Number(event.target.value) - 1;
                      setAnswers(
                        updateOptionAnswer(
                          answers,
                          index,
                          optionIndex,
                          false,
                          optionIndex >= 0,
                        ),
                      );
                    }}
                  >
                    <option value="0">{t("approval.choose")}</option>
                    {question.options.map((option, optionIndex) => (
                      <option
                        key={`${option.label}-${optionIndex}`}
                        value={optionIndex + 1}
                      >
                        {option.label}
                      </option>
                    ))}
                  </select>
                  {selectedOptionIndex(answers, index) >= 0 &&
                    optionDetail(
                      question.options[selectedOptionIndex(answers, index)],
                    )}
                </>
              ) : (
                <input
                  className="focus-ring mt-2 w-full rounded-lg border border-rule bg-paper px-3 py-2 text-sm"
                  value={textAnswerValue(answers, index)}
                  onChange={(event) => {
                    setAnswers(
                      updateTextAnswer(answers, index, event.target.value),
                    );
                  }}
                />
              )}
            </div>
          ))}
          <DecisionButton
            primary
            disabled={actionDisabled || !serializedAnswers}
            onClick={submitAnswers}
          >
            {t("approval.send_answers")}
          </DecisionButton>
          <p className="approval-shortcut">{t("approval.submit_shortcut")}</p>
        </div>
      )}
      {responsePhase !== "idle" && (
        <p
          className="request-response-status"
          data-phase={responsePhase}
          role={responsePhase === "failed" ? "alert" : "status"}
          aria-live={responsePhase === "failed" ? "assertive" : "polite"}
        >
          {responsePhase === "sending"
            ? t("approval.sending")
            : responsePhase === "awaiting_snapshot"
              ? t("approval.awaiting_snapshot")
              : t("approval.retry_response")}
        </p>
      )}
    </section>
  );
}

function optionDetail(option: AskOption | undefined) {
  if (!option || (!option.description && !option.preview)) return null;
  return (
    <div className="approval-option-detail">
      {option.description && <p>{option.description}</p>}
      {option.preview && <code>{option.preview}</code>}
    </div>
  );
}

function DecisionButton({
  primary = false,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { primary?: boolean }) {
  return (
    <button
      {...props}
      className={`focus-ring rounded-lg px-3 py-2 text-sm font-semibold disabled:opacity-40 ${primary ? "bg-amber-ink text-white" : "border border-amber/60 text-amber-ink"}`}
    />
  );
}
