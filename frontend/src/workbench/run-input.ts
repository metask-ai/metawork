import type { RunInputView } from "../bridge/contracts.ts";

export function runInputDisplay(input: RunInputView) {
  if (input.kind === "text") return input.text;
  const argumentsText = input.argumentValues.join(" ");
  return argumentsText
    ? `/${input.invocationName} ${argumentsText}`
    : `/${input.invocationName}`;
}
