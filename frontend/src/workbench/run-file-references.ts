import type {
  FileReferenceView,
  RunView,
  ToolView,
} from "../bridge/contracts.ts";

/**
 * A reference the Run's page carries, or one on a Tool page already read.
 * Records that were never read are not searched; the Host owns the rest.
 */
export function findRunFileReference(
  run: RunView,
  referenceId: string,
  loadedTools: readonly ToolView[] = [],
): FileReferenceView | undefined {
  const references = run.fileReferences;
  for (const reference of [
    ...(references?.media ?? []),
    ...(references?.links ?? []),
  ])
    if (reference.id === referenceId) return reference;
  for (const tool of loadedTools) {
    const reference = tool.fileRefs.find((entry) => entry.id === referenceId);
    if (reference) return reference;
  }
}

// This is a Run-local presentation lookup, not filesystem identity. The Host
// already keeps the newest reference for each display path; a basename shared
// by different paths is never guessed.
export function runFileReferenceLinks(
  run: RunView,
): Map<string, FileReferenceView> {
  const paths = new Map<string, FileReferenceView>();
  for (const reference of run.fileReferences?.links ?? []) {
    if (reference.displayPath && !reference.generatedVideo)
      paths.set(reference.displayPath, reference);
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
    add(path.split(/[\/]/).at(-1) ?? "", reference);
  }
  return new Map(
    [...candidates].filter(
      (entry): entry is [string, FileReferenceView] => entry[1] !== null,
    ),
  );
}
