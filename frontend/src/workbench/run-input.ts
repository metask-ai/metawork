import type {
  MessageIdentity,
  RunInputView,
  RunView,
} from "../bridge/contracts.ts";

/** The identity of a Run's own message, which it had before the Run took it. */
export function runMessage(
  run: Pick<RunView, "id" | "submission">,
): MessageIdentity {
  return run.submission
    ? { kind: "submission", operationId: run.submission.operationId }
    : { kind: "run", runId: run.id };
}

/** Continuation roots are synthesized from the source additional inputs. */
export function transferredRunIds(
  runs: readonly Pick<RunView, "additionalInputs">[],
) {
  return new Set(
    runs.flatMap((run) =>
      run.additionalInputs.flatMap((input) =>
        input.state === "transferred" && input.transferredToRunId
          ? [input.transferredToRunId]
          : [],
      ),
    ),
  );
}

export function runInputDisplay(input: RunInputView) {
  if (input.kind === "text") return input.text;
  if (input.kind === "multimodal")
    return [
      input.skill ? `/${input.skill.invocationName}` : "",
      input.text ?? "",
      ...input.attachments.map((attachment) => attachment.displayName),
    ]
      .filter(Boolean)
      .join(" ");
  const argumentsText = input.argumentValues.join(" ");
  return argumentsText
    ? `/${input.invocationName} ${argumentsText}`
    : `/${input.invocationName}`;
}
