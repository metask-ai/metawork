import type { FileReferenceView, RunView } from "../bridge/contracts.ts";

/**
 * A reference the Run's page carries. References only on Tool records are
 * not searched; the Host resolves those when they are opened.
 */
export function findRunFileReference(
  run: RunView,
  referenceId: string,
): FileReferenceView | undefined {
  const references = run.fileReferences;
  for (const reference of [
    ...(references?.media ?? []),
    ...(references?.links ?? []),
  ])
    if (reference.id === referenceId) return reference;
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
    add(path.split(/[\\/]/).at(-1) ?? "", reference);
  }
  return new Map(
    [...candidates].filter(
      (entry): entry is [string, FileReferenceView] => entry[1] !== null,
    ),
  );
}
