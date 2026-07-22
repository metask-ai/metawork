export type FirstSendWorkspace =
  | { kind: "ready"; workspaceId: string; workspaceEpoch: string }
  | { kind: "cancelled" };

export type WorkspaceAdmission = {
  workspaceId: string;
  workspaceEpoch: string;
};

export async function resolveFirstSendWorkspace({
  taskId,
  workspace,
  chooseWorkspace,
}: {
  taskId: string | null;
  workspace: WorkspaceAdmission | null;
  chooseWorkspace: () => Promise<WorkspaceAdmission | null>;
}): Promise<FirstSendWorkspace> {
  if (taskId !== null)
    return workspace !== null
      ? { kind: "ready", ...workspace }
      : { kind: "cancelled" };
  if (workspace !== null) return { kind: "ready", ...workspace };
  const selected = await chooseWorkspace();
  return selected ? { kind: "ready", ...selected } : { kind: "cancelled" };
}
