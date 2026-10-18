import type { AdditionalInputView, RunOutput } from "../../bridge/contracts.ts";

export type AssistantOutputDisposition =
  "commentary" | "provisional" | "final" | "partial";

export type AssistantOutputPart = {
  identity: string;
  ordinal: number;
  content: string;
  disposition: AssistantOutputDisposition;
};

export type RunReadingEntry =
  | {
      kind: "assistant";
      identity: string;
      parts: AssistantOutputPart[];
      redacted: boolean;
    }
  | { kind: "input"; identity: string; input: AdditionalInputView };

/** Submission anchors are independent of adoption and may outlive a tail. */
export function deriveRunReadingFlow(
  runId: string,
  output: RunOutput,
  inputs: readonly AdditionalInputView[],
): RunReadingEntry[] {
  const parts = deriveAssistantOutputParts(runId, output);
  const entries: RunReadingEntry[] = [];
  let start = 0;
  let prefixMax = 0;
  let lastAssistant:
    Extract<RunReadingEntry, { kind: "assistant" }> | undefined;

  function appendOutput(end: number) {
    if (end === start) return;
    lastAssistant = {
      kind: "assistant",
      identity: parts[start]!.identity,
      parts: parts.slice(start, end),
      redacted: false,
    };
    entries.push(lastAssistant);
    start = end;
  }

  // The canonical input array is strictly ordered by increasing input id.
  for (const input of inputs) {
    prefixMax = Math.max(prefixMax, input.afterOutputCount);
    appendOutput(Math.min(parts.length, prefixMax));
    entries.push({
      kind: "input",
      identity: `${runId}:input:${input.id}`,
      input,
    });
  }
  appendOutput(parts.length);
  if (output.redacted || output.provisionalRedacted) {
    if (lastAssistant) lastAssistant.redacted = true;
    else
      entries.push({
        kind: "assistant",
        identity: `${runId}:output:0`,
        parts: [],
        redacted: true,
      });
  }
  return entries;
}

/**
 * Derives Renderer-only identities without copying AgentCore segment identity
 * into the product surface. A provisional tail keeps its ordinal when Product
 * later classifies it as commentary or response.
 */
export function deriveAssistantOutputParts(
  runId: string,
  output: RunOutput,
): AssistantOutputPart[] {
  const parts = output.commentary.map(
    (content, ordinal): AssistantOutputPart => ({
      identity: `${runId}:output:${ordinal}`,
      ordinal,
      content,
      disposition: "commentary",
    }),
  );
  const ordinal = output.commentary.length;
  if (output.responseKind !== null) {
    parts.push({
      identity: `${runId}:output:${ordinal}`,
      ordinal,
      content: output.response,
      disposition: output.responseKind,
    });
  } else if (output.provisional || output.provisionalRedacted) {
    parts.push({
      identity: `${runId}:output:${ordinal}`,
      ordinal,
      content: output.provisional,
      disposition: "provisional",
    });
  }
  return parts;
}
