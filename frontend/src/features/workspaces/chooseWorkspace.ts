export type WorkspaceChoice =
  { selected: false } | { selected: true; workspaceId: string };

export type WorkspaceChoiceOutcome =
  | { kind: "cancelled" }
  | { kind: "conflict"; workspaceId: string }
  | { kind: "selected"; result: Extract<WorkspaceChoice, { selected: true }> };

export async function chooseWorkspaceWithDraft({
  choose,
  refresh,
  openDraft,
  sourceDraftId,
  moveDraft,
}: {
  choose: () => Promise<WorkspaceChoice>;
  refresh: () => Promise<void>;
  openDraft: boolean;
  sourceDraftId: string | null;
  moveDraft: (sourceId: string, targetId: string) => string;
}): Promise<WorkspaceChoiceOutcome> {
  const result = await choose();
  if (!result.selected) return { kind: "cancelled" };

  // A picker result is not an authoritative product projection. Keep the
  // source draft untouched until the Host snapshot proves the Workspace.
  await refresh();
  if (
    openDraft &&
    sourceDraftId !== null &&
    sourceDraftId !== result.workspaceId &&
    moveDraft(sourceDraftId, result.workspaceId) === "conflict"
  )
    return { kind: "conflict", workspaceId: result.workspaceId };

  return { kind: "selected", result };
}
