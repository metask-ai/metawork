import type { FileReferenceView, RunView } from "../bridge/contracts.ts";

export function runFileReferences(run: RunView): FileReferenceView[] {
  const seen = new Set<string>();
  const references: FileReferenceView[] = [];
  const tools = [...run.tools].sort((left, right) => {
    const leftOrder = BigInt(left.order);
    const rightOrder = BigInt(right.order);
    return leftOrder < rightOrder ? -1 : leftOrder > rightOrder ? 1 : 0;
  });
  for (const tool of tools) {
    for (const reference of tool.fileRefs) {
      if (seen.has(reference.id)) continue;
      seen.add(reference.id);
      references.push(reference);
    }
  }
  return references;
}
