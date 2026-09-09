import type { FileReferenceView, RunView } from "../bridge/contracts.ts";

export function findRunFileReference(
  run: RunView,
  referenceId: string,
): FileReferenceView | undefined {
  for (const tool of run.tools) {
    const reference = tool.fileRefs.find((entry) => entry.id === referenceId);
    if (reference) return reference;
  }
}
