import type {
  AdditionalInputView,
  RunOutput,
  WaitingInputView,
  FileReferenceView,
  TaskView,
} from "../../bridge/contracts.ts";
import { deriveRunPresentation } from "./run-presentation.ts";

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
  | { kind: "input"; identity: string; input: AdditionalInputView }
  | { kind: "submission"; identity: string; input: WaitingInputView }
  | { kind: "image"; identity: string; reference: FileReferenceView }
  | { kind: "local"; identity: string; operationId: string }
  | { kind: "supplement"; identity: string };

export type LocalReadingInput = {
  operationId: string;
  anchor: {
    anchorRunId: string | null;
    afterOutputCount: number;
    afterPresentationOrder: string;
    sequence: number;
  };
};

export function localReadingAnchor(
  task: TaskView | null,
  sequence: number,
): LocalReadingInput["anchor"] {
  const run = task?.runs.at(-1);
  let frontier = 0n;
  for (const item of task?.inputSubmissions ?? [])
    frontier = maxOrder(frontier, item.submission.presentationOrder);
  for (const record of task?.runs ?? []) {
    frontier = maxOrder(frontier, record.submission?.presentationOrder);
    for (const input of record.additionalInputs)
      frontier = maxOrder(frontier, input.submission?.presentationOrder);
    for (const tool of record.tools)
      for (const ref of tool.fileRefs)
        frontier = maxOrder(
          frontier,
          ref.presentationAnchor?.presentationOrder,
        );
  }
  return {
    anchorRunId: run?.id ?? null,
    afterOutputCount: run
      ? deriveAssistantOutputParts(run.id, run.output).length
      : 0,
    afterPresentationOrder: String(frontier),
    sequence,
  };
}
function maxOrder(current: bigint, value: string | null | undefined) {
  return value && BigInt(value) > current ? BigInt(value) : current;
}

/** Range association never hides a root unless another visible entry owns it. */
export function deriveTaskReadingPlan(
  task: TaskView,
  local: readonly LocalReadingInput[] = [],
) {
  const ids = new Set(task.runs.map((run) => run.id));
  const transferred = new Set(
    task.runs.flatMap((run) =>
      run.additionalInputs.flatMap((input) =>
        input.state === "transferred" && input.transferredToRunId
          ? [input.transferredToRunId]
          : [],
      ),
    ),
  );
  const additional = new Set(
    task.runs.flatMap((run) =>
      run.additionalInputs.map((input) => input.operationId),
    ),
  );
  const rootOperations = new Set(
    task.runs.flatMap((run) =>
      run.submission ? [run.submission.operationId] : [],
    ),
  );
  const submissions = [
    ...task.inputSubmissions.filter(
      (input) =>
        !rootOperations.has(input.submission.operationId) &&
        !additional.has(input.submission.operationId),
    ),
    ...task.runs.flatMap((run) =>
      run.submission?.anchorRunId &&
      ids.has(run.submission.anchorRunId) &&
      !additional.has(run.submission.operationId)
        ? [
            {
              submission: run.submission,
              input: run.input,
              state: "interrupted" as const,
              reason: null,
            },
          ]
        : [],
    ),
  ];
  const known = new Set([
    ...additional,
    ...rootOperations,
    ...submissions.map((s) => s.submission.operationId),
  ]);
  const pending = local.filter((input) => !known.has(input.operationId));
  const before: RunReadingEntry[] = [];
  const after: RunReadingEntry[] = [];
  for (const input of submissions)
    if (
      !input.submission.anchorRunId ||
      !ids.has(input.submission.anchorRunId)
    ) {
      const entry: RunReadingEntry = {
        kind: "submission",
        identity: `submission:${input.submission.operationId}`,
        input,
      };
      if (
        !input.submission.anchorRunId ||
        (task.runs[0] &&
          BigInt(input.submission.anchorRunId) < BigInt(task.runs[0].id))
      )
        before.push(entry);
      else after.push(entry);
    }
  for (const input of pending)
    if (
      !task.runs.length ||
      (input.anchor.anchorRunId && !ids.has(input.anchor.anchorRunId))
    ) {
      const entry: RunReadingEntry = {
        kind: "local",
        identity: `submission:${input.operationId}`,
        operationId: input.operationId,
      };
      if (
        task.runs[0] &&
        input.anchor.anchorRunId &&
        BigInt(input.anchor.anchorRunId) < BigInt(task.runs[0].id)
      )
        before.push(entry);
      else after.push(entry);
    }
  const runs = task.runs.map((run) => {
    const presentation = deriveRunPresentation(run);
    const entries = deriveRunReadingFlow(
      run.id,
      run.output,
      run.additionalInputs,
      submissions.filter((input) => input.submission.anchorRunId === run.id),
      run.tools
        .flatMap((tool) => tool.fileRefs)
        .filter((ref) => ref.generatedImage),
      pending.filter(
        (input) =>
          input.anchor.anchorRunId === run.id ||
          (input.anchor.anchorRunId === null && run === task.runs[0]),
      ),
    );
    const boundary = presentation.active
      ? entries.length
      : entries.reduce(
          (last, entry, index) =>
            entry.kind === "assistant" || entry.kind === "image"
              ? index + 1
              : last,
          0,
        );
    entries.splice(boundary, 0, {
      kind: "supplement",
      identity: `${run.id}:supplement`,
    });
    return {
      run,
      presentation,
      entries,
      showRoot:
        !transferred.has(run.id) &&
        !(run.submission && additional.has(run.submission.operationId)) &&
        !(run.submission?.anchorRunId && ids.has(run.submission.anchorRunId)),
    };
  });
  return { task, before, runs, after };
}

/** Order belongs to received facts; output slots remain canonical, including empty ones. */
export function deriveRunReadingFlow(
  runId: string,
  output: RunOutput,
  inputs: readonly AdditionalInputView[],
  submissions: readonly WaitingInputView[] = [],
  images: readonly FileReferenceView[] = [],
  local: readonly LocalReadingInput[] = [],
): RunReadingEntry[] {
  const parts = deriveAssistantOutputParts(runId, output);
  const entries: RunReadingEntry[] = [];
  let start = 0,
    prefixMax = 0;
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
  type Positioned = {
    anchor: number;
    order: bigint;
    localSequence: number;
    index: number;
    entry: RunReadingEntry;
  };
  const messages: Positioned[] = [
    ...inputs.map((input, index) => ({
      anchor: input.afterOutputCount,
      order: BigInt(input.submission?.presentationOrder ?? 0),
      localSequence: 0,
      index,
      entry: {
        kind: "input" as const,
        identity: input.operationId
          ? `submission:${input.operationId}`
          : `${runId}:input:${input.id}`,
        input,
      },
    })),
    ...submissions.map((input, index) => ({
      anchor: input.submission.afterOutputCount,
      order: BigInt(input.submission.presentationOrder ?? 0),
      localSequence: 0,
      index: inputs.length + index,
      entry: {
        kind: "submission" as const,
        identity: `submission:${input.submission.operationId}`,
        input,
      },
    })),
    ...images.map((reference, index) => ({
      anchor: reference.presentationAnchor?.afterOutputCount ?? parts.length,
      order: BigInt(reference.presentationAnchor?.presentationOrder ?? 0),
      localSequence: 0,
      index: inputs.length + submissions.length + index,
      entry: {
        kind: "image" as const,
        identity: `${runId}:image:${reference.id}`,
        reference,
      },
    })),
    ...local.map((input, index) => ({
      anchor: input.anchor.afterOutputCount,
      order: BigInt(input.anchor.afterPresentationOrder),
      localSequence: input.anchor.sequence + 1,
      index,
      entry: {
        kind: "local" as const,
        identity: `submission:${input.operationId}`,
        operationId: input.operationId,
      },
    })),
  ];
  messages.sort((a, b) =>
    a.order < b.order
      ? -1
      : a.order > b.order
        ? 1
        : a.localSequence - b.localSequence || a.index - b.index,
  );
  for (const message of messages) {
    prefixMax = Math.max(prefixMax, message.anchor);
    appendOutput(Math.min(parts.length, prefixMax));
    entries.push(message.entry);
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
