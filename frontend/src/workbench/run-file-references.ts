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

// This is a Run-local presentation lookup, not filesystem identity. Repeated
// observations of one display path can open its current content through the
// latest reference; a basename shared by different paths is never guessed.
export function runFileReferenceLinks(
  run: RunView,
): Map<string, FileReferenceView> {
  const paths = new Map<string, FileReferenceView>();
  const tools = [...run.tools].sort((a, b) =>
    BigInt(a.order) < BigInt(b.order)
      ? -1
      : BigInt(a.order) > BigInt(b.order)
        ? 1
        : 0,
  );
  for (const tool of tools) {
    for (const reference of tool.fileRefs) {
      if (reference.displayPath) paths.set(reference.displayPath, reference);
    }
  }
  const candidates = new Map<string, FileReferenceView | null>();
  function add(alias: string, reference: FileReferenceView) {
    if (!alias) return;
    const previous = candidates.get(alias);
    candidates.set(
      alias,
      previous === undefined || previous?.displayPath === reference.displayPath
        ? reference
        : null,
    );
  }
  for (const [path, reference] of paths) {
    add(path, reference);
    add(`./${path}`, reference);
    add(path.split(/[\\/]/).at(-1) ?? "", reference);
  }
  return new Map(
    [...candidates].filter(
      (entry): entry is [string, FileReferenceView] => entry[1] !== null,
    ),
  );
}
