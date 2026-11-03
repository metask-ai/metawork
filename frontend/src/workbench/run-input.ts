import type { RunInputView, RunView } from "../bridge/contracts.ts";

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
