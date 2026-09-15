import type { RunOutput } from "../../bridge/contracts.ts";

export type AssistantOutputDisposition =
  "commentary" | "provisional" | "final" | "partial";

export type AssistantOutputPart = {
  identity: string;
  ordinal: number;
  content: string;
  disposition: AssistantOutputDisposition;
};

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
