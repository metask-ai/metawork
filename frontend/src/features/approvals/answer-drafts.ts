import type { AskQuestion } from "../../host/contracts.ts";

export type QuestionAnswerDraft =
  { kind: "text"; value: string } | { kind: "options"; selected: number[] };

export type AnswerDrafts = Array<QuestionAnswerDraft | undefined>;

function replaceDraft(
  drafts: AnswerDrafts,
  questionIndex: number,
  draft: QuestionAnswerDraft,
): AnswerDrafts {
  const next = [...drafts];
  next[questionIndex] = draft;
  return next;
}

export function updateTextAnswer(
  drafts: AnswerDrafts,
  questionIndex: number,
  value: string,
): AnswerDrafts {
  return replaceDraft(drafts, questionIndex, { kind: "text", value });
}

export function updateOptionAnswer(
  drafts: AnswerDrafts,
  questionIndex: number,
  optionIndex: number,
  multi: boolean,
  selected: boolean,
): AnswerDrafts {
  const current = drafts[questionIndex];
  const indices: number[] =
    current?.kind === "options" ? [...current.selected] : [];
  const next = multi
    ? selected
      ? [...new Set([...indices, optionIndex])].sort(
          (left, right) => left - right,
        )
      : indices.filter((index) => index !== optionIndex)
    : selected
      ? [optionIndex]
      : [];
  return replaceDraft(drafts, questionIndex, {
    kind: "options",
    selected: next,
  });
}

export function textAnswerValue(
  drafts: AnswerDrafts,
  questionIndex: number,
): string {
  const draft = drafts[questionIndex];
  return draft?.kind === "text" ? draft.value : "";
}

export function optionAnswerSelected(
  drafts: AnswerDrafts,
  questionIndex: number,
  optionIndex: number,
): boolean {
  const draft = drafts[questionIndex];
  return draft?.kind === "options" && draft.selected.includes(optionIndex);
}

export function selectedOptionIndex(
  drafts: AnswerDrafts,
  questionIndex: number,
): number {
  const draft = drafts[questionIndex];
  return draft?.kind === "options" ? (draft.selected[0] ?? -1) : -1;
}

export function serializeAnswerDrafts(
  questions: AskQuestion[],
  drafts: AnswerDrafts,
): string[] | null {
  if (questions.length === 0) return null;
  const answers: string[] = [];
  for (const [questionIndex, question] of questions.entries()) {
    const draft = drafts[questionIndex];
    if (question.options.length === 0) {
      if (draft?.kind !== "text" || draft.value.trim().length === 0)
        return null;
      answers.push(draft.value);
      continue;
    }
    if (draft?.kind !== "options" || draft.selected.length === 0) return null;
    if (!question.multi && draft.selected.length !== 1) return null;
    const labels: string[] = [];
    for (const optionIndex of draft.selected) {
      const label = question.options[optionIndex]?.label;
      if (label === undefined || label.trim().length === 0) return null;
      labels.push(label);
    }
    answers.push(labels.join(", "));
  }
  return answers;
}
