import { useState } from "react";

import { CodeBlock, ToolField } from "../../components/ai/index.ts";
import { Checkbox } from "../../components/ui/checkbox.tsx";
import { Button } from "../../components/ui/button.tsx";
import { Icon } from "../../components/ui/Icon.tsx";
import { Input } from "../../components/ui/input.tsx";
import { Select } from "../../components/ui/select.tsx";
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
      className="inline-request"
      aria-busy={responseInFlight}
    >
      <p className="font-mono text-[10px] tracking-[0.14em] text-ui-warning uppercase">
        {t("approval.response_required")}
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
          <ToolField label={t("approval.arguments")}>
            <CodeBlock value={pending.args} />
          </ToolField>
          <div className="mt-4 grid grid-cols-2 gap-2">
            {(pending.availableChoices ?? ["deny_once", "allow_once"]).map(
              (choice) => (
                <Button
                  key={choice}
                  variant={
                    choice === "allow_once" || choice === "allow_session"
                      ? "primary"
                      : "secondary"
                  }
                  size="md"
                  className="decision-button"
                  data-primary={
                    choice === "allow_once" || choice === "allow_session"
                  }
                  disabled={actionDisabled}
                  onClick={() =>
                    respond({ kind: "permission", permission: choice })
                  }
                >
                  {choice === "deny_once"
                    ? t("approval.deny")
                    : choice === "allow_once"
                      ? t("approval.allow_once")
                      : choice === "allow_session"
                        ? t("approval.allow_session")
                        : t("approval.deny_session")}
                </Button>
              ),
            )}
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
              <p
                id={`ui-question-${pending.requestId}-${index}`}
                className="text-sm font-semibold"
              >
                {question.question}
              </p>
              {question.multi && question.options.length > 0 ? (
                <div
                  className="mt-3 space-y-2"
                  role="group"
                  aria-labelledby={`ui-question-${pending.requestId}-${index}`}
                >
                  {question.options.map((option, optionIndex) => (
                    <label
                      key={`${option.label}-${optionIndex}`}
                      className="flex items-start gap-3 rounded-lg border border-ui-border bg-ui-panel px-3 py-2 text-sm"
                    >
                      <Checkbox.Root
                        checked={optionAnswerSelected(
                          answers,
                          index,
                          optionIndex,
                        )}
                        onCheckedChange={(checked) => {
                          setAnswers(
                            updateOptionAnswer(
                              answers,
                              index,
                              optionIndex,
                              true,
                              checked,
                            ),
                          );
                        }}
                      >
                        <Checkbox.Indicator>✓</Checkbox.Indicator>
                      </Checkbox.Root>
                      <span>
                        <span className="font-medium">{option.label}</span>
                        {option.description && (
                          <span className="mt-0.5 block text-xs leading-5 text-ui-muted">
                            {option.description}
                          </span>
                        )}
                        {option.preview && (
                          <span className="approval-option-preview mt-1 block font-mono text-[10px] leading-5 text-ui-muted">
                            {option.preview}
                          </span>
                        )}
                      </span>
                    </label>
                  ))}
                </div>
              ) : question.options.length > 0 ? (
                <>
                  <Select.Root
                    value={String(selectedOptionIndex(answers, index) + 1)}
                    onValueChange={(nextValue) => {
                      const optionIndex = Number(nextValue) - 1;
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
                    <Select.Trigger
                      className="mt-2 w-full"
                      aria-labelledby={`ui-question-${pending.requestId}-${index}`}
                    >
                      <Select.Value
                        placeholder={t("approval.choose")}
                        children={
                          selectedOptionIndex(answers, index) >= 0
                            ? question.options[
                                selectedOptionIndex(answers, index)
                              ]?.label
                            : t("approval.choose")
                        }
                      />
                      <Select.Icon>
                        <Icon name="chevron" />
                      </Select.Icon>
                    </Select.Trigger>
                    <Select.Portal>
                      <Select.Positioner>
                        <Select.Popup>
                          <Select.List>
                            <Select.Item value="0">
                              <Select.ItemText>
                                {t("approval.choose")}
                              </Select.ItemText>
                            </Select.Item>
                            {question.options.map((option, optionIndex) => (
                              <Select.Item
                                key={`${option.label}-${optionIndex}`}
                                value={String(optionIndex + 1)}
                              >
                                <Select.ItemText>
                                  {option.label}
                                </Select.ItemText>
                              </Select.Item>
                            ))}
                          </Select.List>
                        </Select.Popup>
                      </Select.Positioner>
                    </Select.Portal>
                  </Select.Root>
                  {selectedOptionIndex(answers, index) >= 0 &&
                    optionDetail(
                      question.options[selectedOptionIndex(answers, index)],
                    )}
                </>
              ) : (
                <Input
                  className="mt-2"
                  aria-labelledby={`ui-question-${pending.requestId}-${index}`}
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
          <Button
            variant="primary"
            size="md"
            className="decision-button"
            disabled={actionDisabled || !serializedAnswers}
            onClick={submitAnswers}
          >
            {t("approval.send_answers")}
          </Button>
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
