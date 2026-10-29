export type WorkspaceChoice =
  { selected: false } | { selected: true; workspaceId: string };

export type WorkspaceChoiceOutcome =
  | { kind: "cancelled" }
  | { kind: "selected"; result: Extract<WorkspaceChoice, { selected: true }> };

export async function chooseWorkspaceAndMigrateDraft({
  choose,
  refresh,
  migratableDraftId,
  moveDraft,
}: {
  choose: () => Promise<WorkspaceChoice>;
  refresh: () => Promise<void>;
  migratableDraftId: string | null;
  moveDraft: (sourceId: string, targetId: string) => unknown;
}): Promise<WorkspaceChoiceOutcome> {
  const result = await choose();
  if (!result.selected) return { kind: "cancelled" };

  // A picker result is not an authoritative product projection. Keep the
  // source draft untouched until the Host snapshot proves the Workspace.
  await refresh();
  if (migratableDraftId !== null && migratableDraftId !== result.workspaceId)
    moveDraft(migratableDraftId, result.workspaceId);

  return { kind: "selected", result };
}
