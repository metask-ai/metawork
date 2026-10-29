import type { RunInputView } from "../bridge/contracts.ts";

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
